import Foundation

/// SFTP-backed provider. The transport pool connects lazily, so restored
/// locations remain valid while offline and reconnect on their first operation.
struct SSHFileProvider: FileProvider, Sendable {
    let profile: SSHLocationProfile

    nonisolated var kind: FileProviderKind { .ssh }

    nonisolated var volume: FileVolume {
        FileVolume(
            id: profile.volumeID,
            providerKind: .ssh,
            connectionID: profile.connectionID,
            capabilities: [.list, .metadata, .create, .rename, .remove, .transfer]
        )
    }

    nonisolated func list(
        directory: ItemRef,
        options: FileProviderListingOptions
    ) async throws -> [FileProviderEntry] {
        try validate(directory)
        do {
            let connection = await SSHTransportPool.shared.connection(for: profile)
            let entries = try await connection.list(path: directory.path)
            return entries
                .filter { options.showHiddenFiles || !$0.name.hasPrefix(".") }
                .map { providerEntry($0, item: directory.appending(component: $0.name)) }
        } catch {
            throw map(error, item: directory)
        }
    }

    nonisolated func entry(at item: ItemRef) async throws -> FileProviderEntry {
        try validate(item)
        do {
            let connection = await SSHTransportPool.shared.connection(for: profile)
            return providerEntry(try await connection.stat(path: item.path), item: item)
        } catch {
            throw map(error, item: item)
        }
    }

    nonisolated func details(for item: ItemRef) async throws -> FileProviderItemDetails {
        try validate(item)
        do {
            let connection = await SSHTransportPool.shared.connection(for: profile)
            let remote = try await connection.stat(path: item.path)
            let permissions = remote.permissions.map(Int.init)
            return FileProviderItemDetails(
                item: item,
                name: remote.name,
                kind: kind(for: remote),
                size: remote.size,
                created: nil,
                modified: date(remote.modified),
                isDirectory: remote.isDirectory,
                isPackage: false,
                isSymbolicLink: remote.isSymbolicLink,
                isReadable: permissions.map { $0 & 0o400 != 0 } ?? true,
                isWritable: permissions.map { $0 & 0o200 != 0 } ?? true,
                posixPermissions: permissions
            )
        } catch {
            throw map(error, item: item)
        }
    }

    nonisolated func materialize(
        _ item: ItemRef,
        for purpose: FileMaterializationPurpose
    ) async throws -> MaterializedFile {
        throw FileProviderError.unsupportedCapability("local materialization")
    }

    nonisolated func createDirectory(
        in parent: ItemRef,
        name: String
    ) async throws -> FileProviderEntry {
        try await createDirectory(
            at: parent.appending(component: try validatedName(name)),
            createParentDirectories: false
        )
    }

    nonisolated func createFile(
        in parent: ItemRef,
        name: String,
        contents: Data
    ) async throws -> FileProviderEntry {
        try await createFile(
            at: parent.appending(component: try validatedName(name)),
            contents: contents,
            createParentDirectories: false
        )
    }

    nonisolated func createDirectory(
        at item: ItemRef,
        createParentDirectories: Bool
    ) async throws -> FileProviderEntry {
        try validate(item)
        guard !createParentDirectories else {
            throw FileProviderError.unsupportedCapability("recursive folder creation")
        }
        do {
            let connection = await SSHTransportPool.shared.connection(for: profile)
            try await connection.createDirectory(path: item.path)
            return try await entry(at: item)
        } catch {
            throw map(error, item: item)
        }
    }

    nonisolated func createFile(
        at item: ItemRef,
        contents: Data,
        createParentDirectories: Bool
    ) async throws -> FileProviderEntry {
        try validate(item)
        guard !createParentDirectories else {
            throw FileProviderError.unsupportedCapability("recursive file creation")
        }
        do {
            let connection = await SSHTransportPool.shared.connection(for: profile)
            try await connection.createFile(path: item.path, contents: contents)
            return try await entry(at: item)
        } catch {
            throw map(error, item: item)
        }
    }

    nonisolated func rename(
        _ item: ItemRef,
        to newName: String
    ) async throws -> FileProviderTransferReceipt {
        let name = try validatedName(newName)
        guard let parent = item.parent else {
            throw FileProviderError.operationFailed(item: item, message: "The location root cannot be renamed.")
        }
        return try await transfer(
            item,
            to: parent.appending(component: name),
            operation: .move,
            createParentDirectories: false,
            useUniqueDestination: false
        )
    }

    nonisolated func transfer(
        _ item: ItemRef,
        into destinationDirectory: ItemRef,
        operation: FileProviderTransferOperation
    ) async throws -> FileProviderTransferReceipt {
        try await transfer(
            item,
            to: destinationDirectory.appending(component: item.name),
            operation: operation,
            createParentDirectories: false,
            useUniqueDestination: true
        )
    }

    nonisolated func transfer(
        _ item: ItemRef,
        to destination: ItemRef,
        operation: FileProviderTransferOperation,
        createParentDirectories: Bool,
        useUniqueDestination: Bool
    ) async throws -> FileProviderTransferReceipt {
        try validate(item)
        try validate(destination)
        guard item.volumeID == destination.volumeID else {
            throw FileProviderError.unsupportedCapability("cross-location transfer")
        }
        guard case .move = operation else {
            throw FileProviderError.unsupportedCapability("remote copy")
        }
        guard !createParentDirectories else {
            throw FileProviderError.unsupportedCapability("recursive destination creation")
        }

        var resolvedDestination = destination
        if useUniqueDestination {
            resolvedDestination = try await uniqueDestination(for: destination)
        } else if (try? await entry(at: destination)) != nil {
            throw FileProviderError.alreadyExists(destination)
        }

        do {
            let connection = await SSHTransportPool.shared.connection(for: profile)
            try await connection.rename(from: item.path, to: resolvedDestination.path)
            return FileProviderTransferReceipt(from: item, to: resolvedDestination)
        } catch {
            throw map(error, item: item)
        }
    }

    nonisolated func trash(_ item: ItemRef) async throws -> FileProviderTrashReceipt {
        throw FileProviderError.unsupportedCapability("Trash")
    }

    nonisolated func remove(_ item: ItemRef) async throws {
        try validate(item)
        do {
            let remote = try await entry(at: item)
            let connection = await SSHTransportPool.shared.connection(for: profile)
            try await connection.remove(
                path: item.path,
                isDirectory: remote.isDirectory,
                recursive: remote.isDirectory
            )
        } catch {
            throw map(error, item: item)
        }
    }

    nonisolated private func validate(_ item: ItemRef) throws {
        guard item.volumeID == profile.volumeID else {
            throw FileProviderError.unsupportedVolume(item.volumeID)
        }
    }

    nonisolated private func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", !trimmed.contains("/") else {
            throw FileProviderError.invalidName
        }
        return trimmed
    }

    nonisolated private func uniqueDestination(for item: ItemRef) async throws -> ItemRef {
        if (try? await entry(at: item)) == nil {
            return item
        }
        let name = item.name as NSString
        let stem = name.deletingPathExtension
        let extensionSuffix = name.pathExtension.isEmpty ? "" : ".\(name.pathExtension)"
        guard let parent = item.parent else { return item }
        for number in 2...10_000 {
            let candidate = parent.appending(component: "\(stem) \(number)\(extensionSuffix)")
            if (try? await entry(at: candidate)) == nil {
                return candidate
            }
        }
        throw FileProviderError.operationFailed(
            item: item,
            message: "Could not choose an available destination name."
        )
    }

    nonisolated private func providerEntry(
        _ remote: SSHRemoteEntry,
        item: ItemRef
    ) -> FileProviderEntry {
        FileProviderEntry(
            id: item,
            name: remote.name,
            isDirectory: remote.isDirectory,
            isPackage: false,
            isHidden: remote.name.hasPrefix("."),
            size: remote.size ?? 0,
            kind: kind(for: remote),
            modified: date(remote.modified),
            created: nil
        )
    }

    nonisolated private func kind(for remote: SSHRemoteEntry) -> String {
        if remote.isSymbolicLink { return "Symbolic Link" }
        if remote.isDirectory { return "Folder" }
        return "File"
    }

    nonisolated private func date(_ seconds: UInt32?) -> Date? {
        seconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    nonisolated private func map(_ error: Error, item: ItemRef) -> Error {
        guard let transport = error as? SSHTransportError else { return error }
        switch transport {
        case .hostKeyVerification:
            return FileProviderError.hostKeyVerificationRequired(profile.connectionID)
        case .hostKeyChanged:
            return FileProviderError.hostKeyChangedRequired(profile.connectionID)
        case .authentication:
            return FileProviderError.authenticationRequired(profile.connectionID)
        case .connection, .helperUnavailable:
            return FileProviderError.connectionLost(
                profile.connectionID,
                message: transport.localizedDescription
            )
        case .remote(let code, let message):
            switch code {
            case "not_found": return FileProviderError.itemNotFound(item)
            case "permission_denied": return FileProviderError.permissionDenied(item)
            case "already_exists": return FileProviderError.alreadyExists(item)
            case "not_directory": return FileProviderError.notDirectory(item)
            default: return FileProviderError.operationFailed(item: item, message: message)
            }
        case .invalidResponse:
            return FileProviderError.connectionLost(
                profile.connectionID,
                message: transport.localizedDescription
            )
        }
    }
}
