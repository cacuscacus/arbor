import Foundation

struct FileProviderListingOptions: Sendable, Equatable {
    var showHiddenFiles = false

    nonisolated init(showHiddenFiles: Bool = false) {
        self.showHiddenFiles = showHiddenFiles
    }
}

struct FileProviderEntry: Identifiable, Hashable, Sendable {
    let id: ItemRef
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let size: UInt64
    let kind: String
    let modified: Date?
    let created: Date?
}

struct FileProviderItemDetails: Hashable, Sendable {
    let item: ItemRef
    let name: String
    let kind: String
    let size: UInt64?
    let created: Date?
    let modified: Date?
    let isDirectory: Bool
    let isPackage: Bool
    let isSymbolicLink: Bool
    let isReadable: Bool
    let isWritable: Bool
    let posixPermissions: Int?
}

enum FileMaterializationPurpose: Sendable {
    case open
    case thumbnail
    case quickDiff
    case externalTool
}

enum FileMaterializationLifetime: Equatable, Sendable {
    /// The URL is the provider's native representation and needs no cleanup.
    case intrinsic
    /// Reserved for remote providers that download a managed temporary copy.
    case temporary
}

struct MaterializedFile: Sendable {
    let source: ItemRef
    let url: URL
    let lifetime: FileMaterializationLifetime
}

enum FileProviderTransferOperation: Sendable {
    case move
    case copy
}

struct FileProviderTransferReceipt: Hashable, Sendable {
    let from: ItemRef
    let to: ItemRef
}

struct FileProviderTrashReceipt: Hashable, Sendable {
    let original: ItemRef
    let trashedItem: ItemRef?

    var canRestore: Bool { trashedItem != nil }
}

enum FileProviderError: LocalizedError, Sendable {
    case unsupportedVolume(VolumeID)
    case unsupportedCapability(String)
    case itemNotFound(ItemRef)
    case permissionDenied(ItemRef)
    case notDirectory(ItemRef)
    case invalidName
    case alreadyExists(ItemRef)
    case cannotMoveIntoSelf
    case connectionRequired(ConnectionID)
    case authenticationRequired(ConnectionID)
    case hostKeyVerificationRequired(ConnectionID)
    case connectionLost(ConnectionID, message: String)
    case operationFailed(item: ItemRef, message: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVolume:
            return "This volume is not supported by the selected file provider."
        case .unsupportedCapability(let capability):
            return "This location does not support \(capability)."
        case .itemNotFound:
            return "The item could not be found."
        case .permissionDenied:
            return "You don’t have permission to access this item."
        case .notDirectory:
            return "The selected item is not a folder."
        case .invalidName:
            return "The name is empty or contains a slash."
        case .alreadyExists(let item):
            return "An item named “\(item.name)” already exists."
        case .cannotMoveIntoSelf:
            return "Cannot move a folder into itself."
        case .connectionRequired:
            return "Connect to this SSH location to browse its files."
        case .authenticationRequired:
            return "SSH authentication is required for this location."
        case .hostKeyVerificationRequired:
            return "The SSH host key must be verified before connecting."
        case .connectionLost(_, let message):
            return message
        case .operationFailed(_, let message):
            return message
        }
    }
}

/// Async provider boundary. Batch aggregation and user-facing conflict UI live
/// above this API so local and SSH providers expose the same primitives.
nonisolated protocol FileProvider: Sendable {
    nonisolated var kind: FileProviderKind { get }
    nonisolated var volume: FileVolume { get }

    nonisolated func list(
        directory: ItemRef,
        options: FileProviderListingOptions
    ) async throws -> [FileProviderEntry]

    nonisolated func entry(at item: ItemRef) async throws -> FileProviderEntry
    nonisolated func details(for item: ItemRef) async throws -> FileProviderItemDetails
    nonisolated func materialize(
        _ item: ItemRef,
        for purpose: FileMaterializationPurpose
    ) async throws -> MaterializedFile

    nonisolated func createDirectory(in parent: ItemRef, name: String) async throws -> FileProviderEntry
    nonisolated func createFile(in parent: ItemRef, name: String, contents: Data) async throws -> FileProviderEntry
    nonisolated func createDirectory(
        at item: ItemRef,
        createParentDirectories: Bool
    ) async throws -> FileProviderEntry
    nonisolated func createFile(
        at item: ItemRef,
        contents: Data,
        createParentDirectories: Bool
    ) async throws -> FileProviderEntry
    nonisolated func rename(_ item: ItemRef, to newName: String) async throws -> FileProviderTransferReceipt
    nonisolated func transfer(
        _ item: ItemRef,
        into destinationDirectory: ItemRef,
        operation: FileProviderTransferOperation
    ) async throws -> FileProviderTransferReceipt
    nonisolated func transfer(
        _ item: ItemRef,
        to destination: ItemRef,
        operation: FileProviderTransferOperation,
        createParentDirectories: Bool,
        useUniqueDestination: Bool
    ) async throws -> FileProviderTransferReceipt
    nonisolated func trash(_ item: ItemRef) async throws -> FileProviderTrashReceipt
    nonisolated func remove(_ item: ItemRef) async throws
}

/// Synchronously routes stable volume identities to long-lived providers.
/// Persisted SSH facades register before session restoration.
nonisolated final class FileProviderRegistry: @unchecked Sendable {
    nonisolated static let shared = FileProviderRegistry()

    private let local = LocalFileProvider()
    private let lock = NSLock()
    private var providers: [VolumeID: any FileProvider] = [:]
    private var locations: [VolumeID: [LocationID: FileLocation]] = [:]

    nonisolated init() {
        providers[LocalFileLocation.volumeID] = local
        locations[LocalFileLocation.volumeID] = [
            LocalFileLocation.location.id: LocalFileLocation.location,
        ]
    }

    nonisolated func provider(for item: ItemRef) throws -> any FileProvider {
        lock.lock()
        let registered = providers[item.volumeID]
        lock.unlock()
        if let registered {
            return registered
        }
        if item.volumeID.rawValue.hasPrefix("local:") {
            return local
        }
        throw FileProviderError.unsupportedVolume(item.volumeID)
    }

    nonisolated func register(
        _ provider: any FileProvider,
        location: FileLocation? = nil
    ) {
        lock.lock()
        providers[provider.volume.id] = provider
        if let location {
            var byID = locations[provider.volume.id] ?? [:]
            byID[location.id] = location
            locations[provider.volume.id] = byID
        }
        lock.unlock()
    }

    nonisolated func unregister(volumeID: VolumeID) {
        guard !volumeID.rawValue.hasPrefix("local:") else { return }
        lock.lock()
        providers.removeValue(forKey: volumeID)
        locations.removeValue(forKey: volumeID)
        lock.unlock()
    }

    nonisolated func location(containing item: ItemRef) -> FileLocation? {
        lock.lock()
        let candidates = Array(locations[item.volumeID]?.values ?? [:].values)
        lock.unlock()
        return candidates
            .filter {
                item.path == $0.root.path
                    || item.path.hasPrefix($0.root.path == "/" ? "/" : $0.root.path + "/")
            }
            .max { $0.root.path.count < $1.root.path.count }
    }

    nonisolated func capabilities(for item: ItemRef) -> FileProviderCapabilities {
        (try? provider(for: item).volume.capabilities) ?? []
    }

    /// Native local URLs are safe for Finder, terminals, and local applications.
    /// Temporary remote materializations must never cross this boundary.
    nonisolated func intrinsicLocalURL(for item: ItemRef) -> URL? {
        guard capabilities(for: item).contains(.localMaterialization) else {
            return nil
        }
        return item.localURL
    }
}

struct LocalFileProvider: FileProvider, Sendable {
    nonisolated let kind: FileProviderKind = .local
    nonisolated let volume: FileVolume = LocalFileLocation.volume

    nonisolated private static let listKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .fileSizeKey,
        .isHiddenKey,
        .nameKey,
        .localizedTypeDescriptionKey,
        .contentModificationDateKey,
        .creationDateKey,
    ]

    nonisolated func list(
        directory: ItemRef,
        options: FileProviderListingOptions
    ) async throws -> [FileProviderEntry] {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let entries = try listSync(directory: directory, options: options)
            try Task.checkCancellation()
            return entries
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated func entry(at item: ItemRef) async throws -> FileProviderEntry {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let entry = try entrySync(at: item)
            try Task.checkCancellation()
            return entry
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated func details(for item: ItemRef) async throws -> FileProviderItemDetails {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let details = try detailsSync(for: item)
            try Task.checkCancellation()
            return details
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated func materialize(
        _ item: ItemRef,
        for purpose: FileMaterializationPurpose
    ) async throws -> MaterializedFile {
        guard volume.capabilities.contains(.localMaterialization) else {
            throw FileProviderError.unsupportedCapability("local materialization")
        }
        return try await detached {
            _ = try entrySync(at: item)
            guard let url = item.localURL else {
                throw FileProviderError.unsupportedVolume(item.volumeID)
            }
            return MaterializedFile(source: item, url: url, lifetime: .intrinsic)
        }
    }

    nonisolated func createDirectory(
        in parent: ItemRef,
        name: String
    ) async throws -> FileProviderEntry {
        try await detached {
            try createDirectorySync(in: parent, name: name)
        }
    }

    nonisolated func createFile(
        in parent: ItemRef,
        name: String,
        contents: Data = Data()
    ) async throws -> FileProviderEntry {
        try await detached {
            try createFileSync(in: parent, name: name, contents: contents)
        }
    }

    nonisolated func createDirectory(
        at item: ItemRef,
        createParentDirectories: Bool
    ) async throws -> FileProviderEntry {
        try await detached {
            try createDirectorySync(
                at: item,
                createParentDirectories: createParentDirectories
            )
        }
    }

    nonisolated func createFile(
        at item: ItemRef,
        contents: Data = Data(),
        createParentDirectories: Bool
    ) async throws -> FileProviderEntry {
        try await detached {
            try createFileSync(
                at: item,
                contents: contents,
                createParentDirectories: createParentDirectories
            )
        }
    }

    nonisolated func rename(
        _ item: ItemRef,
        to newName: String
    ) async throws -> FileProviderTransferReceipt {
        try await detached {
            try renameSync(item, to: newName)
        }
    }

    nonisolated func transfer(
        _ item: ItemRef,
        into destinationDirectory: ItemRef,
        operation: FileProviderTransferOperation
    ) async throws -> FileProviderTransferReceipt {
        try await detached {
            try transferSync(item, into: destinationDirectory, operation: operation)
        }
    }

    nonisolated func transfer(
        _ item: ItemRef,
        to destination: ItemRef,
        operation: FileProviderTransferOperation,
        createParentDirectories: Bool,
        useUniqueDestination: Bool
    ) async throws -> FileProviderTransferReceipt {
        try await detached {
            try transferSync(
                item,
                to: destination,
                operation: operation,
                createParentDirectories: createParentDirectories,
                useUniqueDestination: useUniqueDestination
            )
        }
    }

    nonisolated func trash(_ item: ItemRef) async throws -> FileProviderTrashReceipt {
        try await detached {
            try trashSync(item)
        }
    }

    nonisolated func remove(_ item: ItemRef) async throws {
        try await detached {
            try removeSync(item)
        }
    }

    nonisolated func listSync(
        directory: ItemRef,
        options: FileProviderListingOptions = .init()
    ) throws -> [FileProviderEntry] {
        let url = try localURL(for: directory)
        var enumerationOptions: FileManager.DirectoryEnumerationOptions = []
        if !options.showHiddenFiles {
            enumerationOptions.insert(.skipsHiddenFiles)
        }

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(Self.listKeys),
                options: enumerationOptions
            )
            var entries = contents.compactMap { makeEntry(from: $0) }
            entries.sort { lhs, rhs in
                let lhsBrowsable = lhs.isDirectory && !lhs.isPackage
                let rhsBrowsable = rhs.isDirectory && !rhs.isPackage
                if lhsBrowsable != rhsBrowsable {
                    return lhsBrowsable && !rhsBrowsable
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return entries
        } catch {
            throw map(error, item: directory)
        }
    }

    nonisolated func entrySync(at item: ItemRef) throws -> FileProviderEntry {
        let url = try localURL(for: item)
        guard let entry = makeEntry(from: url) else {
            throw FileProviderError.itemNotFound(item)
        }
        return entry
    }

    nonisolated func detailsSync(for item: ItemRef) throws -> FileProviderItemDetails {
        let url = try localURL(for: item)
        let keys: Set<URLResourceKey> = [
            .nameKey,
            .localizedTypeDescriptionKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .isReadableKey,
            .isWritableKey,
        ]

        do {
            let values = try url.resourceValues(forKeys: keys)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return FileProviderItemDetails(
                item: item,
                name: values.name ?? url.lastPathComponent,
                kind: values.localizedTypeDescription ?? "Unknown",
                size: values.fileSize.map(UInt64.init),
                created: values.creationDate,
                modified: values.contentModificationDate,
                isDirectory: values.isDirectory ?? false,
                isPackage: values.isPackage ?? false,
                isSymbolicLink: values.isSymbolicLink ?? false,
                isReadable: values.isReadable ?? false,
                isWritable: values.isWritable ?? false,
                posixPermissions: attrs?[.posixPermissions] as? Int
            )
        } catch {
            throw map(error, item: item)
        }
    }

    nonisolated func createDirectorySync(
        in parent: ItemRef,
        name: String
    ) throws -> FileProviderEntry {
        let validatedName = try validate(name: name)
        let parentURL = try localURL(for: parent)
        try requireDirectory(parent, url: parentURL)
        let target = uniqueDestination(in: parentURL, preferredName: validatedName)

        do {
            try FileManager.default.createDirectory(
                at: target,
                withIntermediateDirectories: false
            )
            guard let entry = makeEntry(from: target) else {
                throw FileProviderError.itemNotFound(LocalFileLocation.item(for: target))
            }
            return entry
        } catch let error as FileProviderError {
            throw error
        } catch {
            throw map(error, item: LocalFileLocation.item(for: target))
        }
    }

    nonisolated func createFileSync(
        in parent: ItemRef,
        name: String,
        contents: Data = Data()
    ) throws -> FileProviderEntry {
        let validatedName = try validate(name: name)
        let parentURL = try localURL(for: parent)
        try requireDirectory(parent, url: parentURL)
        let target = uniqueDestination(in: parentURL, preferredName: validatedName)

        guard FileManager.default.createFile(
            atPath: target.path,
            contents: contents,
            attributes: nil
        ) else {
            throw FileProviderError.operationFailed(
                item: LocalFileLocation.item(for: target),
                message: CocoaError(.fileWriteUnknown).localizedDescription
            )
        }
        guard let entry = makeEntry(from: target) else {
            throw FileProviderError.itemNotFound(LocalFileLocation.item(for: target))
        }
        return entry
    }

    nonisolated func createDirectorySync(
        at item: ItemRef,
        createParentDirectories: Bool
    ) throws -> FileProviderEntry {
        guard let parent = item.parent else {
            throw FileProviderError.invalidName
        }
        _ = try validate(name: item.name)
        let target = try localURL(for: item)
        let parentURL = try localURL(for: parent)
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: target.path) else {
            throw FileProviderError.alreadyExists(item)
        }
        if createParentDirectories {
            try fileManager.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true
            )
        } else {
            try requireDirectory(parent, url: parentURL)
        }
        do {
            try fileManager.createDirectory(
                at: target,
                withIntermediateDirectories: false
            )
            guard let entry = makeEntry(from: target) else {
                throw FileProviderError.itemNotFound(item)
            }
            return entry
        } catch let error as FileProviderError {
            throw error
        } catch {
            throw map(error, item: item)
        }
    }

    nonisolated func createFileSync(
        at item: ItemRef,
        contents: Data = Data(),
        createParentDirectories: Bool
    ) throws -> FileProviderEntry {
        guard let parent = item.parent else {
            throw FileProviderError.invalidName
        }
        _ = try validate(name: item.name)
        let target = try localURL(for: item)
        let parentURL = try localURL(for: parent)
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: target.path) else {
            throw FileProviderError.alreadyExists(item)
        }
        if createParentDirectories {
            try fileManager.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true
            )
        } else {
            try requireDirectory(parent, url: parentURL)
        }
        guard fileManager.createFile(
            atPath: target.path,
            contents: contents,
            attributes: nil
        ) else {
            throw FileProviderError.operationFailed(
                item: item,
                message: CocoaError(.fileWriteUnknown).localizedDescription
            )
        }
        guard let entry = makeEntry(from: target) else {
            throw FileProviderError.itemNotFound(item)
        }
        return entry
    }

    nonisolated func renameSync(
        _ item: ItemRef,
        to newName: String
    ) throws -> FileProviderTransferReceipt {
        let validatedName = try validate(name: newName)
        let sourceURL = try localURL(for: item)
        let destinationURL = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(validatedName)
            .standardizedFileURL

        if destinationURL == sourceURL {
            return FileProviderTransferReceipt(from: item, to: item)
        }
        let destination = ItemRef(volumeID: item.volumeID, path: destinationURL.path)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw FileProviderError.alreadyExists(destination)
        }

        do {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            return FileProviderTransferReceipt(from: item, to: destination)
        } catch {
            throw map(error, item: item)
        }
    }

    nonisolated func transferSync(
        _ item: ItemRef,
        into destinationDirectory: ItemRef,
        operation: FileProviderTransferOperation
    ) throws -> FileProviderTransferReceipt {
        let sourceURL = try localURL(for: item)
        let destinationURL = try localURL(for: destinationDirectory)
        try requireDirectory(destinationDirectory, url: destinationURL)

        if sourceURL == destinationURL
            || destinationURL.path.hasPrefix(sourceURL.path + "/")
        {
            throw FileProviderError.cannotMoveIntoSelf
        }

        let preferredName: String = {
            if case .copy = operation,
               sourceURL.deletingLastPathComponent() == destinationURL {
                let nsName = sourceURL.lastPathComponent as NSString
                let base = nsName.deletingPathExtension
                let ext = nsName.pathExtension
                return ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
            }
            return sourceURL.lastPathComponent
        }()
        let targetURL = uniqueDestination(in: destinationURL, preferredName: preferredName)
        return try transferSync(
            item,
            to: ItemRef(volumeID: destinationDirectory.volumeID, path: targetURL.path),
            operation: operation,
            createParentDirectories: false,
            useUniqueDestination: false
        )
    }

    /// Exact-destination primitive used by provider-aware undo/redo.
    nonisolated func transferSync(
        _ item: ItemRef,
        to requestedDestination: ItemRef,
        operation: FileProviderTransferOperation,
        createParentDirectories: Bool,
        useUniqueDestination: Bool
    ) throws -> FileProviderTransferReceipt {
        let sourceURL = try localURL(for: item)
        let requestedURL = try localURL(for: requestedDestination)
        let parentURL = requestedURL.deletingLastPathComponent()
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw FileProviderError.itemNotFound(item)
        }

        if createParentDirectories {
            var isDirectory: ObjCBool = false
            if !fileManager.fileExists(atPath: parentURL.path, isDirectory: &isDirectory)
                || !isDirectory.boolValue
            {
                try fileManager.createDirectory(
                    at: parentURL,
                    withIntermediateDirectories: true
                )
            }
        } else {
            try requireDirectory(
                LocalFileLocation.item(for: parentURL),
                url: parentURL
            )
        }

        let destinationURL: URL
        if useUniqueDestination, fileManager.fileExists(atPath: requestedURL.path) {
            destinationURL = uniqueDestination(
                in: parentURL,
                preferredName: requestedURL.lastPathComponent
            )
        } else {
            destinationURL = requestedURL
        }

        do {
            switch operation {
            case .move:
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            case .copy:
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }
            return FileProviderTransferReceipt(
                from: item,
                to: ItemRef(volumeID: requestedDestination.volumeID, path: destinationURL.path)
            )
        } catch {
            throw map(error, item: item)
        }
    }

    nonisolated func trashSync(_ item: ItemRef) throws -> FileProviderTrashReceipt {
        let url = try localURL(for: item)
        do {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return FileProviderTrashReceipt(
                original: item,
                trashedItem: (resulting as URL?).map(LocalFileLocation.item(for:))
            )
        } catch {
            throw map(error, item: item)
        }
    }

    nonisolated func removeSync(_ item: ItemRef) throws {
        let url = try localURL(for: item)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw map(error, item: item)
        }
    }

    nonisolated func ensureDirectorySync(_ item: ItemRef) throws {
        let url = try localURL(for: item)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw FileProviderError.notDirectory(item)
            }
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        } catch {
            throw map(error, item: item)
        }
    }

    nonisolated private func detached<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            // Filesystem mutations are not safely interruptible once started.
            // Always return their receipt so callers can reconcile UI/undo state.
            return try work()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private func localURL(for item: ItemRef) throws -> URL {
        guard let url = item.localURL else {
            throw FileProviderError.unsupportedVolume(item.volumeID)
        }
        return url
    }

    nonisolated private func validate(name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw FileProviderError.invalidName
        }
        return trimmed
    }

    nonisolated private func requireDirectory(_ item: ItemRef, url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw FileProviderError.itemNotFound(item)
        }
        guard isDirectory.boolValue else {
            throw FileProviderError.notDirectory(item)
        }
    }

    nonisolated private func uniqueDestination(
        in directory: URL,
        preferredName: String
    ) -> URL {
        let fileManager = FileManager.default
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

    nonisolated private func makeEntry(from url: URL) -> FileProviderEntry? {
        let values = try? url.resourceValues(forKeys: Self.listKeys)
        let isDirectory = values?.isDirectory ?? false
        let isPackage = values?.isPackage ?? false
        let kind: String = {
            if let description = values?.localizedTypeDescription {
                return description
            }
            if isPackage { return "Application" }
            if isDirectory { return "Folder" }
            return url.pathExtension.isEmpty ? "Document" : url.pathExtension.uppercased()
        }()

        return FileProviderEntry(
            id: LocalFileLocation.item(for: url),
            name: values?.name ?? url.lastPathComponent,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isHidden: (values?.isHidden == true) || url.lastPathComponent.hasPrefix("."),
            size: UInt64(values?.fileSize ?? 0),
            kind: kind,
            modified: values?.contentModificationDate,
            created: values?.creationDate
        )
    }

    nonisolated private func map(_ error: Error, item: ItemRef) -> FileProviderError {
        let nsError = error as NSError
        switch (nsError.domain, nsError.code) {
        case (NSCocoaErrorDomain, NSFileNoSuchFileError):
            return .itemNotFound(item)
        case (NSCocoaErrorDomain, NSFileReadNoPermissionError):
            return .permissionDenied(item)
        default:
            return .operationFailed(item: item, message: error.localizedDescription)
        }
    }
}
