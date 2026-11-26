import Foundation

/// Provider-neutral file transfer, shared by the browser's own drops,
/// clipboard paste/move, and drops onto the sidebar's favorite folders.
enum FileTransferService {
    struct ProgressUpdate: Sendable {
        let completedItems: Int
        let totalItems: Int
        let currentItemName: String?
        let completedBytes: Int64?
        let totalBytes: Int64?
    }

    struct Outcome {
        var transferred: [(from: ItemRef, to: ItemRef)] = []
        var failures: [(item: ItemRef, error: Error)] = []
        var wasCancelled: Bool = false

        var isEmpty: Bool { transferred.isEmpty && failures.isEmpty }
    }

    private nonisolated static let chunkedCopyByteThreshold: Int64 = 4 * 1024 * 1024
    private nonisolated static let chunkBufferSize = 1024 * 1024

    /// Runs `transfer` wrapped in a cancellable `Task` wired into
    /// `TransferProgressStore.shared` so slow local copies and SFTP jobs display
    /// a floating progress HUD with a Cancel button.
    @MainActor
    static func trackedTransfer(
        _ sources: [ItemRef],
        into destination: ItemRef,
        operation: FileTransferOperation
    ) async -> Outcome {
        let actionable = actionableSources(sources, destination: destination, operation: operation)
        guard !actionable.isEmpty else { return Outcome() }

        let verb = operation == .copy ? "Copying" : "Moving"
        let title: String
        if actionable.count == 1, let only = actionable.first {
            title = "\(verb) “\(only.name)”"
        } else {
            title = "\(verb) \(actionable.count) items to \(destination.name)"
        }

        let estimatedBytes = estimateLocalRegularBytes(for: actionable, destination: destination, operation: operation)
        let box = TransferTaskBox()
        let jobID = TransferProgressStore.shared.beginJob(
            title: title,
            operation: operation,
            totalItems: actionable.count,
            totalBytes: estimatedBytes
        ) {
            box.cancel()
        }

        let task = Task<Outcome, Never> {
            await transfer(
                actionable,
                into: destination,
                operation: operation
            ) { update in
                Task { @MainActor in
                    TransferProgressStore.shared.updateJob(
                        jobID,
                        completedItems: update.completedItems,
                        currentItemName: update.currentItemName,
                        completedBytes: update.completedBytes,
                        totalBytes: update.totalBytes
                    )
                }
            }
        }
        box.set(task)

        let outcome = await task.value
        TransferProgressStore.shared.finishJob(jobID)
        return outcome
    }

    /// Moves/copies `sources` into `destination`, skipping no-ops.
    ///
    /// Same-folder moves and moves onto themselves are skipped rather than
    /// reported as failures; everything else surfaces per item so callers can
    /// list what worked and what did not. Respects `Task.isCancelled`.
    static func transfer(
        _ sources: [ItemRef],
        into destination: ItemRef,
        operation: FileTransferOperation,
        onProgress: (@Sendable (ProgressUpdate) -> Void)? = nil
    ) async -> Outcome {
        var outcome = Outcome()
        let actionable = actionableSources(sources, destination: destination, operation: operation)
        guard !actionable.isEmpty else { return outcome }

        let provider: FileProvider
        do {
            provider = try FileProviderRegistry.shared.provider(for: destination)
        } catch {
            outcome.failures = actionable.map { ($0, error) }
            return outcome
        }

        let totalItems = actionable.count
        let totalBytes = estimateLocalRegularBytes(for: actionable, destination: destination, operation: operation)
        var completedBytes: Int64 = 0

        for (index, source) in actionable.enumerated() {
            if Task.isCancelled {
                outcome.wasCancelled = true
                break
            }

            onProgress?(ProgressUpdate(
                completedItems: index,
                totalItems: totalItems,
                currentItemName: source.name,
                completedBytes: totalBytes != nil ? completedBytes : nil,
                totalBytes: totalBytes
            ))

            do {
                let receipt: FileProviderTransferReceipt
                if let chunked = try await tryCrossVolumeChunkedCopy(
                    source: source,
                    destination: destination,
                    operation: operation,
                    baseBytes: completedBytes,
                    totalBytes: totalBytes,
                    itemIndex: index,
                    totalItems: totalItems,
                    onProgress: onProgress
                ) {
                    receipt = chunked.receipt
                    completedBytes += chunked.copiedBytes
                } else {
                    receipt = try await provider.transfer(
                        source,
                        into: destination,
                        operation: operation.providerOperation
                    )
                    if totalBytes != nil,
                       let url = source.localURL,
                       let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                       values.isRegularFile == true,
                       let size = values.fileSize
                    {
                        completedBytes += Int64(size)
                    }
                }
                outcome.transferred.append((receipt.from, receipt.to))
            } catch is CancellationError {
                outcome.wasCancelled = true
                break
            } catch {
                if Task.isCancelled {
                    outcome.wasCancelled = true
                    break
                }
                outcome.failures.append((source, error))
            }

            onProgress?(ProgressUpdate(
                completedItems: index + 1,
                totalItems: totalItems,
                currentItemName: source.name,
                completedBytes: totalBytes != nil ? completedBytes : nil,
                totalBytes: totalBytes
            ))
        }
        return outcome
    }

    private static func actionableSources(
        _ sources: [ItemRef],
        destination: ItemRef,
        operation: FileTransferOperation
    ) -> [ItemRef] {
        sources.filter { source in
            if source == destination { return false }
            if operation == .move, source.parent == destination { return false }
            return true
        }
    }

    /// Estimates total byte size only when copying regular local files across
    /// volumes (same-volume APFS copies use near-instant copy-on-write clones).
    private static func estimateLocalRegularBytes(
        for sources: [ItemRef],
        destination: ItemRef,
        operation: FileTransferOperation
    ) -> Int64? {
        guard operation == .copy, let destURL = destination.localURL else { return nil }
        let destVolume = (try? destURL.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        var total: Int64 = 0
        var hasLargeCrossVolume = false
        for source in sources {
            guard let url = source.localURL,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .volumeIdentifierKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { return nil }
            total += Int64(size)
            let srcVolume = values.volumeIdentifier as? NSObject
            if let destVolume, let srcVolume, !destVolume.isEqual(srcVolume), Int64(size) >= chunkedCopyByteThreshold {
                hasLargeCrossVolume = true
            }
        }
        return hasLargeCrossVolume ? total : nil
    }

    /// Streams cross-volume copies of large regular local files (>= 4 MB) in
    /// 1 MB chunks so progress updates live and Cancel aborts immediately with
    /// partial-file cleanup. Same-volume copies stay on `FileManager.copyItem`
    /// to preserve instant APFS copy-on-write cloning.
    private static func tryCrossVolumeChunkedCopy(
        source: ItemRef,
        destination: ItemRef,
        operation: FileTransferOperation,
        baseBytes: Int64,
        totalBytes: Int64?,
        itemIndex: Int,
        totalItems: Int,
        onProgress: (@Sendable (ProgressUpdate) -> Void)?
    ) async throws -> (receipt: FileProviderTransferReceipt, copiedBytes: Int64)? {
        guard operation == .copy,
              let sourceURL = source.localURL,
              let destDirURL = destination.localURL
        else { return nil }

        let srcValues = try? sourceURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .volumeIdentifierKey,
        ])
        guard srcValues?.isRegularFile == true,
              srcValues?.isSymbolicLink != true,
              let fileSize = srcValues?.fileSize,
              Int64(fileSize) >= chunkedCopyByteThreshold
        else { return nil }

        let destValues = try? destDirURL.resourceValues(forKeys: [.volumeIdentifierKey])
        if let sVol = srcValues?.volumeIdentifier as? NSObject,
           let dVol = destValues?.volumeIdentifier as? NSObject,
           sVol.isEqual(dVol)
        {
            // Same APFS volume: let FileManager.copyItem perform an instant clone.
            return nil
        }

        let targetURL = uniqueCopyDestination(in: destDirURL, sourceURL: sourceURL)
        let targetItem = ItemRef(volumeID: destination.volumeID, path: targetURL.path)

        let copiedBytes: Int64 = try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let reader = try FileHandle(forReadingFrom: sourceURL)
            defer { try? reader.close() }

            guard fm.createFile(atPath: targetURL.path, contents: nil, attributes: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }

            do {
                let writer = try FileHandle(forWritingTo: targetURL)
                defer { try? writer.close() }

                var written: Int64 = 0
                var lastEmit = Date.distantPast
                while true {
                    try Task.checkCancellation()
                    guard let chunk = try reader.read(upToCount: chunkBufferSize), !chunk.isEmpty else {
                        break
                    }
                    try writer.write(contentsOf: chunk)
                    written += Int64(chunk.count)

                    let now = Date()
                    if let onProgress, now.timeIntervalSince(lastEmit) >= 0.08 {
                        lastEmit = now
                        onProgress(ProgressUpdate(
                            completedItems: itemIndex,
                            totalItems: totalItems,
                            currentItemName: source.name,
                            completedBytes: baseBytes + written,
                            totalBytes: totalBytes
                        ))
                    }
                }

                // Preserve POSIX permissions and modification date.
                if let attrs = try? fm.attributesOfItem(atPath: sourceURL.path) {
                    var preserved: [FileAttributeKey: Any] = [:]
                    if let perms = attrs[.posixPermissions] { preserved[.posixPermissions] = perms }
                    if let mod = attrs[.modificationDate] { preserved[.modificationDate] = mod }
                    if let created = attrs[.creationDate] { preserved[.creationDate] = created }
                    if !preserved.isEmpty {
                        try? fm.setAttributes(preserved, ofItemAtPath: targetURL.path)
                    }
                }
                return written
            } catch {
                // Remove partial target file on cancellation or write failure.
                try? fm.removeItem(at: targetURL)
                throw error
            }
        }.value

        return (FileProviderTransferReceipt(from: source, to: targetItem), copiedBytes)
    }

    private static func uniqueCopyDestination(in directory: URL, sourceURL: URL) -> URL {
        let fm = FileManager.default
        let name = sourceURL.lastPathComponent
        let initial = directory.appendingPathComponent(name)
        if !fm.fileExists(atPath: initial.path) {
            return initial
        }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty ? name : ns.deletingPathExtension
        var index = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    /// Folders whose listings can be stale after `outcome`.
    static func affectedFolders(
        for outcome: Outcome,
        destination: ItemRef,
        operation: FileTransferOperation
    ) -> [ItemRef] {
        var folders = [destination]
        if operation == .move {
            folders.append(contentsOf: outcome.transferred.compactMap(\.from.parent))
        }
        return Array(Set(folders))
    }

    /// Human-readable failure summary, or nil when everything succeeded.
    static func failureMessage(for outcome: Outcome, operation: FileTransferOperation) -> String? {
        guard !outcome.failures.isEmpty else { return nil }
        let names = outcome.failures.map(\.item.name).joined(separator: ", ")
        let verb = operation == .move ? "move" : "copy"
        let verbPast = operation == .move ? "moved" : "copied"
        return outcome.transferred.isEmpty
            ? "Could not \(verb): \(names)"
            : "Some items could not be \(verbPast): \(names)"
    }
}

@MainActor
private final class TransferTaskBox {
    private var task: Task<FileTransferService.Outcome, Never>?
    private var cancelledEarly = false

    func set(_ task: Task<FileTransferService.Outcome, Never>) {
        self.task = task
        if cancelledEarly {
            task.cancel()
        }
    }

    func cancel() {
        cancelledEarly = true
        task?.cancel()
    }
}
