import Foundation

/// Provider-neutral file transfer, shared by the browser's own drops and by
/// drops onto the sidebar's favorite folders.
enum FileTransferService {
    struct Outcome {
        var transferred: [(from: ItemRef, to: ItemRef)] = []
        var failures: [(item: ItemRef, error: Error)] = []

        var isEmpty: Bool { transferred.isEmpty && failures.isEmpty }
    }

    /// Moves/copies `sources` into `destination`, skipping no-ops.
    ///
    /// Same-folder moves and moves onto themselves are skipped rather than
    /// reported as failures; everything else surfaces per item so callers can
    /// list what worked and what did not.
    static func transfer(
        _ sources: [ItemRef],
        into destination: ItemRef,
        operation: FileTransferOperation
    ) async -> Outcome {
        var outcome = Outcome()

        let provider: FileProvider
        do {
            provider = try FileProviderRegistry.shared.provider(for: destination)
        } catch {
            outcome.failures = sources.map { ($0, error) }
            return outcome
        }

        for source in sources {
            if source == destination { continue }
            // Moving inside the same folder is a no-op; copying still duplicates.
            if operation == .move, source.parent == destination { continue }
            do {
                let receipt = try await provider.transfer(
                    source,
                    into: destination,
                    operation: operation.providerOperation
                )
                outcome.transferred.append((receipt.from, receipt.to))
            } catch {
                outcome.failures.append((source, error))
            }
        }
        return outcome
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
