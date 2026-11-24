import Foundation
import AppKit
import UniformTypeIdentifiers
import QuickLookThumbnailing
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

    var providerOperation: FileProviderTransferOperation {
        switch self {
        case .move: return .move
        case .copy: return .copy
        }
    }
}

enum FileOperations {
    private static let localProvider = LocalFileProvider()

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
        let destination = destinationDirectory.standardizedFileURL
        let destinationRef = LocalFileLocation.item(for: destination)
        let uniqueSources = Array(Set(sources.map { $0.standardizedFileURL }))

        for source in uniqueSources {
            // Moving within the same folder is a no-op; copying still duplicates.
            if !copy, source.deletingLastPathComponent() == destination {
                continue
            }

            do {
                let receipt = try localProvider.transferSync(
                    LocalFileLocation.item(for: source),
                    into: destinationRef,
                    operation: copy ? .copy : .move
                )
                guard let target = receipt.to.localURL else {
                    throw FileProviderError.unsupportedVolume(receipt.to.volumeID)
                }
                result.transferred.append((source, target))
            } catch FileProviderError.notDirectory {
                result.failed.append((source, TransferError.destinationNotDirectory))
            } catch FileProviderError.cannotMoveIntoSelf {
                result.failed.append((source, TransferError.cannotMoveIntoSelf))
            } catch {
                result.failed.append((source, error))
            }
        }

        return result
    }

    @discardableResult
    static func createFolder(in directory: URL, named name: String = "untitled folder") throws -> URL {
        let entry = try localProvider.createDirectorySync(
            in: LocalFileLocation.item(for: directory),
            name: name
        )
        guard let url = entry.id.localURL else {
            throw FileProviderError.unsupportedVolume(entry.id.volumeID)
        }
        return url
    }

    @discardableResult
    static func createEmptyFile(in directory: URL, named name: String = "untitled.txt") throws -> URL {
        let entry = try localProvider.createFileSync(
            in: LocalFileLocation.item(for: directory),
            name: name
        )
        guard let url = entry.id.localURL else {
            throw FileProviderError.unsupportedVolume(entry.id.volumeID)
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
        do {
            let receipt = try localProvider.renameSync(
                LocalFileLocation.item(for: source),
                to: trimmed
            )
            guard receipt.from != receipt.to else {
                throw RenameError.unchanged
            }
            guard let destination = receipt.to.localURL else {
                throw FileProviderError.unsupportedVolume(receipt.to.volumeID)
            }
            return (source, destination)
        } catch FileProviderError.alreadyExists {
            throw RenameError.nameExists(trimmed)
        }
    }

    struct TrashResult {
        /// Original location → location inside Trash (for undo).
        var trashed: [(from: URL, trashURL: URL)] = []
        var failed: [(URL, Error)] = []
    }

    /// Moves items into the Trash. Returns trash URLs when available so Undo can restore them.
    static func trash(_ sources: [URL]) -> TrashResult {
        var result = TrashResult()
        let unique = Array(Set(sources.map { $0.standardizedFileURL }))

        for source in unique {
            do {
                let receipt = try localProvider.trashSync(LocalFileLocation.item(for: source))
                let trashURL = receipt.trashedItem?.localURL ?? source
                result.trashed.append((from: source, trashURL: trashURL))
            } catch {
                result.failed.append((source, error))
            }
        }

        return result
    }
}

/// Shared drag payload so multi-selection moves travel with a single dragged row/icon.
@Observable
final class FileDragState {
    var items: [ItemRef] = []

    func beginDragging(anchor: ItemRef, selection: Set<ItemRef>) -> [ItemRef] {
        let payload: [ItemRef]
        if selection.contains(anchor), selection.count > 1 {
            payload = Array(selection)
        } else {
            payload = [anchor]
        }
        items = payload
        return payload
    }

    func clear() {
        items = []
    }
}

enum FileIcon {
    /// Icon-view sizes request Quick Look content thumbnails; list/breadcrumb sizes stay type icons.
    static let thumbnailMinPoints: CGFloat = 32

    struct Display {
        let image: NSImage
        let isContentPreview: Bool
    }

    /// Cancels an in-flight Quick Look request when a collection item is reused.
    final class Request {
        fileprivate var cancelled = false
        fileprivate var qlRequest: QLThumbnailGenerator.Request?

        func cancel() {
            cancelled = true
            if let qlRequest {
                QLThumbnailGenerator.shared.cancel(qlRequest)
            }
        }
    }

    private enum Kind: String {
        case typeIcon = "icon"
        case thumbnail = "thumb"
    }

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

    private static func cacheKey(_ kind: Kind, item: ItemRef, size: CGFloat) -> NSString {
        let clamped = max(8, size.rounded())
        return "\(item.volumeID.rawValue)|\(item.path)|\(kind.rawValue)|\(Int(clamped * 2))" as NSString
    }

    /// Best available cached image: content thumbnail if present, otherwise type icon.
    static func cached(for item: ItemRef, size: CGFloat) -> NSImage? {
        cachedDisplay(for: item, size: size)?.image
    }

    static func cachedDisplay(for item: ItemRef, size: CGFloat) -> Display? {
        let clamped = max(8, size.rounded())
        if let thumb = cache.object(forKey: cacheKey(.thumbnail, item: item, size: clamped)) {
            return Display(image: thumb, isContentPreview: true)
        }
        if let icon = cache.object(forKey: cacheKey(.typeIcon, item: item, size: clamped)) {
            return Display(image: icon, isContentPreview: false)
        }
        return nil
    }

    /// Cached, resized **type** icon (Icon Services). Never mutates the shared `NSWorkspace` image.
    static func image(for item: ItemRef, size: CGFloat) -> NSImage {
        let clamped = max(8, size.rounded())
        let key = cacheKey(.typeIcon, item: item, size: clamped)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let workspaceIcon: NSImage
        if let url = FileProviderRegistry.shared.intrinsicLocalURL(for: item) {
            workspaceIcon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            workspaceIcon = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
                ?? NSImage()
        }
        let icon = (workspaceIcon.copy() as? NSImage) ?? workspaceIcon
        icon.size = NSSize(width: clamped, height: clamped)
        cache.setObject(icon, forKey: key, cost: Int(clamped * clamped * 4))
        return icon
    }

    /// Type icon immediately, then a Quick Look thumbnail when the size and file type warrant it.
    /// `completion` may fire more than once (placeholder, then preview). Always delivered on the main queue.
    @discardableResult
    static func load(
        for item: ItemRef,
        size: CGFloat,
        completion: @escaping (Display) -> Void
    ) -> Request {
        let request = Request()
        let clamped = max(8, size.rounded())
        let scale = NSScreen.main?.backingScaleFactor ?? 2

        let deliver: (Display) -> Void = { display in
            DispatchQueue.main.async {
                guard !request.cancelled else { return }
                completion(display)
            }
        }

        if let thumb = cache.object(forKey: cacheKey(.thumbnail, item: item, size: clamped)) {
            completion(Display(image: thumb, isContentPreview: true))
            return request
        }
        if let icon = cache.object(forKey: cacheKey(.typeIcon, item: item, size: clamped)) {
            completion(Display(image: icon, isContentPreview: false))
        }

        let wantsThumbnail = clamped >= thumbnailMinPoints
        queue.async {
            guard !request.cancelled else { return }

            if cache.object(forKey: cacheKey(.typeIcon, item: item, size: clamped)) == nil {
                let icon = image(for: item, size: clamped)
                deliver(Display(image: icon, isContentPreview: false))
            }

            guard let url = FileProviderRegistry.shared.intrinsicLocalURL(for: item) else {
                return
            }
            guard wantsThumbnail, !request.cancelled, isPreviewable(url) else { return }
            if cache.object(forKey: cacheKey(.thumbnail, item: item, size: clamped)) != nil { return }
            requestThumbnail(
                item: item,
                url: url,
                size: clamped,
                scale: scale,
                request: request,
                deliver: deliver
            )
        }
        return request
    }

    /// Warm **type** icons only (cheap). Thumbnails are generated on demand for visible cells.
    static func prefetch(items: [ItemRef], size: CGFloat, limit: Int = 120) {
        let batch = Array(items.prefix(limit))
        guard !batch.isEmpty else { return }
        queue.async {
            for item in batch {
                _ = image(for: item, size: size)
            }
        }
    }

    static func clearCache() {
        cache.removeAllObjects()
    }

    private static func isPreviewable(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey])
        if values?.isDirectory == true || values?.isPackage == true { return false }
        if let type = values?.contentType {
            return type.conforms(to: .image)
                || type.conforms(to: .pdf)
                || type.conforms(to: .movie)
                || type.conforms(to: .video)
                || type.conforms(to: .mpeg4Movie)
                || type.conforms(to: .quickTimeMovie)
                || type.conforms(to: .svg)
                || type.conforms(to: .rawImage)
        }
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp",
             "raw", "dng", "cr2", "nef",
             "pdf", "svg",
             "mp4", "mov", "m4v":
            return true
        default:
            return false
        }
    }

    private static func requestThumbnail(
        item: ItemRef,
        url: URL,
        size: CGFloat,
        scale: CGFloat,
        request: Request,
        deliver: @escaping (Display) -> Void
    ) {
        let qlRequest = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: scale,
            representationTypes: [.lowQualityThumbnail, .thumbnail]
        )
        request.qlRequest = qlRequest
        let thumbKey = cacheKey(.thumbnail, item: item, size: size)

        QLThumbnailGenerator.shared.generateRepresentations(for: qlRequest) { representation, type, _ in
            guard !request.cancelled, let representation else { return }
            let image = representation.nsImage
            if type == .thumbnail {
                cache.setObject(image, forKey: thumbKey, cost: Int(size * size * 16))
            }
            deliver(Display(image: image, isContentPreview: true))
        }
    }
}

/// Controls the system drag badge: move (no +) by default, copy (+) while Option is held.
struct FolderDropDelegate: DropDelegate {
    let destination: ItemRef
    let dragState: FileDragState
    var isTargeted: Binding<Bool>?
    /// When set, a folder row under the pointer wins over the pane's folder
    /// (so dropping anywhere on a folder row moves into it).
    var resolveDestination: (() -> ItemRef?)?
    /// Reports the folder currently under the pointer so rows can highlight.
    var onDropTargetChange: ((ItemRef?) -> Void)?
    let onTransfer: ([ItemRef], ItemRef, FileTransferOperation) -> Void

    private var effectiveDestination: ItemRef {
        resolveDestination?() ?? destination
    }

    func validateDrop(info: DropInfo) -> Bool {
        true
    }

    func dropEntered(info: DropInfo) {
        isTargeted?.wrappedValue = true
        onDropTargetChange?(resolveDestination?() ?? destination)
    }

    func dropExited(info: DropInfo) {
        isTargeted?.wrappedValue = false
        onDropTargetChange?(nil)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onDropTargetChange?(resolveDestination?() ?? destination)
        return DropProposal(operation: FileTransferOperation.fromModifierFlags.dropOperation)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted?.wrappedValue = false
        onDropTargetChange?(nil)
        let operation = FileTransferOperation.fromModifierFlags
        let destination = effectiveDestination
        let items = dragState.items
        dragState.clear()
        let filtered = items.filter {
            $0 != destination
        }
        if !filtered.isEmpty {
            onTransfer(filtered, destination, operation)
            return true
        }

        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var loaded: [ItemRef] = []
        for provider in providers {
            group.enter()
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                defer { group.leave() }
                guard let url = object as? URL else { return }
                lock.lock()
                loaded.append(LocalFileLocation.item(for: url))
                lock.unlock()
            }
        }
        group.notify(queue: .main) {
            let external = loaded.filter { $0 != destination }
            guard !external.isEmpty else { return }
            onTransfer(external, destination, operation)
        }
        return true
    }
}

