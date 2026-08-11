import Foundation
import AppKit
import UniformTypeIdentifiers
import SwiftUI

enum FileTransferOperation {
    case move
    case copy

    /// Finder-like: Option held → copy; otherwise move.
    static var fromModifierFlags: FileTransferOperation {
        NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    var dropOperation: DropOperation {
        switch self {
        case .move: return .move
        case .copy: return .copy
        }
    }

    var failureTitle: String {
        switch self {
        case .move: return "Move Failed"
        case .copy: return "Copy Failed"
        }
    }
}

enum FileOperations {
    enum TransferError: LocalizedError {
        case destinationNotDirectory
        case cannotMoveIntoSelf

        var errorDescription: String? {
            switch self {
            case .destinationNotDirectory:
                return "Destination is not a folder."
            case .cannotMoveIntoSelf:
                return "Cannot move a folder into itself."
            }
        }
    }

    struct TransferResult {
        var transferred: [(from: URL, to: URL)] = []
        var failed: [(URL, Error)] = []
    }

    static func transfer(
        _ sources: [URL],
        into destinationDirectory: URL,
        operation: FileTransferOperation
    ) -> TransferResult {
        switch operation {
        case .move:
            return move(sources, into: destinationDirectory)
        case .copy:
            return copy(sources, into: destinationDirectory)
        }
    }

    static func move(_ sources: [URL], into destinationDirectory: URL) -> TransferResult {
        perform(sources, into: destinationDirectory, copy: false)
    }

    static func copy(_ sources: [URL], into destinationDirectory: URL) -> TransferResult {
        perform(sources, into: destinationDirectory, copy: true)
    }

    private static func perform(
        _ sources: [URL],
        into destinationDirectory: URL,
        copy: Bool
    ) -> TransferResult {
        var result = TransferResult()
        let fm = FileManager.default
        let destination = destinationDirectory.standardizedFileURL

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: destination.path, isDirectory: &isDir), isDir.boolValue else {
            for source in sources {
                result.failed.append((source, TransferError.destinationNotDirectory))
            }
            return result
        }

        let uniqueSources = Array(Set(sources.map { $0.standardizedFileURL }))

        for source in uniqueSources {
            if source == destination {
                result.failed.append((source, TransferError.cannotMoveIntoSelf))
                continue
            }
            if destination.path.hasPrefix(source.path + "/") {
                result.failed.append((source, TransferError.cannotMoveIntoSelf))
                continue
            }
            // Moving within the same folder is a no-op; copying still duplicates.
            if !copy, source.deletingLastPathComponent() == destination {
                continue
            }

            let preferredName: String = {
                if copy, source.deletingLastPathComponent() == destination {
                    let nsName = source.lastPathComponent as NSString
                    let base = nsName.deletingPathExtension
                    let ext = nsName.pathExtension
                    return ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
                }
                return source.lastPathComponent
            }()

            let target = uniqueDestination(
                in: destination,
                preferredName: preferredName,
                fileManager: fm
            )

            do {
                if copy {
                    try fm.copyItem(at: source, to: target)
                } else {
                    try fm.moveItem(at: source, to: target)
                }
                result.transferred.append((source, target))
            } catch {
                result.failed.append((source, error))
            }
        }

        return result
    }

    @discardableResult
    static func createFolder(in directory: URL, named name: String = "untitled folder") throws -> URL {
        let fm = FileManager.default
        let url = uniqueDestination(in: directory, preferredName: name, fileManager: fm)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @discardableResult
    static func createEmptyFile(in directory: URL, named name: String = "untitled.txt") throws -> URL {
        let fm = FileManager.default
        let url = uniqueDestination(in: directory, preferredName: name, fileManager: fm)
        let created = fm.createFile(atPath: url.path, contents: Data(), attributes: nil)
        guard created else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    enum RenameError: LocalizedError {
        case emptyName
        case invalidName
        case nameExists(String)
        case unchanged

        var errorDescription: String? {
            switch self {
            case .emptyName:
                return "Name can’t be empty."
            case .invalidName:
                return "Name can’t contain a slash."
            case .nameExists(let name):
                return "An item named “\(name)” already exists."
            case .unchanged:
                return nil
            }
        }
    }

    /// Renames a file or folder. Returns the original and new URLs.
    static func rename(_ url: URL, to newName: String) throws -> (from: URL, to: URL) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RenameError.emptyName }
        guard !trimmed.contains("/") else { throw RenameError.invalidName }

        let source = url.standardizedFileURL
        let destination = source.deletingLastPathComponent().appendingPathComponent(trimmed)

        if destination == source {
            throw RenameError.unchanged
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            throw RenameError.nameExists(trimmed)
        }

        try fm.moveItem(at: source, to: destination)
        return (source, destination)
    }

    struct TrashResult {
        /// Original location → location inside Trash (for undo).
        var trashed: [(from: URL, trashURL: URL)] = []
        var failed: [(URL, Error)] = []
    }

    /// Moves items into the Trash. Returns trash URLs when available so Undo can restore them.
    static func trash(_ sources: [URL]) -> TrashResult {
        var result = TrashResult()
        let fm = FileManager.default
        let unique = Array(Set(sources.map { $0.standardizedFileURL }))

        for source in unique {
            do {
                var resulting: NSURL?
                try fm.trashItem(at: source, resultingItemURL: &resulting)
                let trashURL = (resulting as URL?) ?? source
                result.trashed.append((from: source, trashURL: trashURL.standardizedFileURL))
            } catch {
                result.failed.append((source, error))
            }
        }

        return result
    }

    private static func uniqueDestination(
        in directory: URL,
        preferredName: String,
        fileManager: FileManager
    ) -> URL {
        var candidate = directory.appendingPathComponent(preferredName)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let nsName = preferredName as NSString
        let base = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        var index = 1
        repeat {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            let name = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
            candidate = directory.appendingPathComponent(name)
            index += 1
        } while fileManager.fileExists(atPath: candidate.path)

        return candidate
    }
}

/// Shared drag payload so multi-selection moves travel with a single dragged row/icon.
@Observable
final class FileDragState {
    var urls: [URL] = []

    func beginDragging(anchor: URL, selection: Set<URL>) -> [URL] {
        let payload: [URL]
        if selection.contains(anchor), selection.count > 1 {
            payload = Array(selection)
        } else {
            payload = [anchor]
        }
        urls = payload
        return payload
    }

    func clear() {
        urls = []
    }
}

enum FileIcon {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 2_048
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private static let queue = DispatchQueue(
        label: "cacus.Arbor.FileIcon",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private static func cacheKey(for url: URL, size: CGFloat) -> NSString {
        let clamped = max(8, size.rounded())
        return "\(url.standardizedFileURL.path)|\(Int(clamped * 2))" as NSString
    }

    /// Synchronous cache lookup only (never hits Icon Services).
    static func cached(for url: URL, size: CGFloat) -> NSImage? {
        cache.object(forKey: cacheKey(for: url, size: size))
    }

    /// Cached, resized file icon. Never mutates the shared `NSWorkspace` image.
    static func image(for url: URL, size: CGFloat) -> NSImage {
        let clamped = max(8, size.rounded())
        let key = cacheKey(for: url, size: clamped)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let workspaceIcon = NSWorkspace.shared.icon(forFile: url.path)
        let icon = (workspaceIcon.copy() as? NSImage) ?? workspaceIcon
        icon.size = NSSize(width: clamped, height: clamped)
        let cost = Int(clamped * clamped * 16)
        cache.setObject(icon, forKey: key, cost: cost)
        return icon
    }

    /// Cache hit → completion immediately on the calling queue; miss loads off-main.
    static func load(for url: URL, size: CGFloat, completion: @escaping (NSImage) -> Void) {
        if let cached = cached(for: url, size: size) {
            completion(cached)
            return
        }
        queue.async {
            let icon = image(for: url, size: size)
            DispatchQueue.main.async {
                completion(icon)
            }
        }
    }

    /// Warm icons for the first chunk of a listing (icon view scroll warm-up).
    static func prefetch(urls: [URL], size: CGFloat, limit: Int = 120) {
        let batch = Array(urls.prefix(limit))
        guard !batch.isEmpty else { return }
        queue.async {
            for url in batch {
                _ = image(for: url, size: size)
            }
        }
    }

    static func clearCache() {
        cache.removeAllObjects()
    }
}

/// Controls the system drag badge: move (no +) by default, copy (+) while Option is held.
struct FolderDropDelegate: DropDelegate {
    let destination: URL
    let dragState: FileDragState
    var isTargeted: Binding<Bool>?
    let onTransfer: ([URL], URL, FileTransferOperation) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        true
    }

    func dropEntered(info: DropInfo) {
        isTargeted?.wrappedValue = true
    }

    func dropExited(info: DropInfo) {
        isTargeted?.wrappedValue = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: FileTransferOperation.fromModifierFlags.dropOperation)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted?.wrappedValue = false
        let operation = FileTransferOperation.fromModifierFlags
        let urls = dragState.urls
        dragState.clear()
        let filtered = urls.filter {
            $0.standardizedFileURL != destination.standardizedFileURL
        }
        guard !filtered.isEmpty else { return false }
        onTransfer(filtered, destination, operation)
        return true
    }
}
