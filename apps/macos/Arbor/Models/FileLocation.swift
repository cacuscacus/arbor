import Foundation

/// Stable identifiers keep connection, volume, and visible location separate
/// from an item's path. Remote providers must never encode credentials here.
nonisolated struct ConnectionID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    nonisolated init(rawValue: String) {
        self.rawValue = rawValue
    }
}

nonisolated struct VolumeID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    nonisolated init(rawValue: String) {
        self.rawValue = rawValue
    }
}

nonisolated struct LocationID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    nonisolated init(rawValue: String) {
        self.rawValue = rawValue
    }
}

enum FileProviderKind: String, Codable, Hashable, Sendable {
    case local
    case ssh
}

nonisolated struct FileProviderCapabilities: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    static let list = Self(rawValue: 1 << 0)
    static let metadata = Self(rawValue: 1 << 1)
    static let create = Self(rawValue: 1 << 2)
    static let rename = Self(rawValue: 1 << 3)
    static let remove = Self(rawValue: 1 << 4)
    static let trash = Self(rawValue: 1 << 5)
    static let nativeWatch = Self(rawValue: 1 << 6)
    static let search = Self(rawValue: 1 << 7)
    static let localMaterialization = Self(rawValue: 1 << 8)
    static let transfer = Self(rawValue: 1 << 9)

    static let localDefault: Self = [
        .list,
        .metadata,
        .create,
        .rename,
        .remove,
        .trash,
        .nativeWatch,
        .search,
        .localMaterialization,
        .transfer,
    ]
}

struct FileVolume: Identifiable, Codable, Hashable, Sendable {
    let id: VolumeID
    let providerKind: FileProviderKind
    let connectionID: ConnectionID?
    let capabilities: FileProviderCapabilities
}

struct FileConnection: Identifiable, Codable, Hashable, Sendable {
    let id: ConnectionID
    let providerKind: FileProviderKind
    let displayName: String
}

struct FileLocation: Identifiable, Codable, Hashable, Sendable {
    let id: LocationID
    let displayName: String
    let root: ItemRef

    var volumeID: VolumeID { root.volumeID }
}

/// Provider-neutral identity. The local URL bridge exists only for the
/// incremental 6a migration and must not be used for remote items.
struct ItemRef: Codable, Hashable, Sendable {
    /// Filesystem identity is volume + path. A named Location is only a
    /// navigation root, so the same item keeps one identity across favorites.
    let volumeID: VolumeID
    let path: String

    nonisolated init(volumeID: VolumeID, path: String) {
        self.volumeID = volumeID
        self.path = Self.normalized(path)
    }

    nonisolated var name: String {
        guard path != "/" else { return "/" }
        return (path as NSString).lastPathComponent
    }

    nonisolated var parent: ItemRef? {
        guard path != "/" else { return nil }
        let parentPath = (path as NSString).deletingLastPathComponent
        return ItemRef(volumeID: volumeID, path: parentPath.isEmpty ? "/" : parentPath)
    }

    nonisolated func appending(component: String) -> ItemRef {
        let next = (path as NSString).appendingPathComponent(component)
        return ItemRef(volumeID: volumeID, path: next)
    }

    nonisolated private static func normalized(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        let standardized = (path as NSString).standardizingPath
        return standardized.hasPrefix("/") ? standardized : "/" + standardized
    }
}

enum LocalFileLocation {
    nonisolated static let locationID = LocationID(rawValue: "local:filesystem")
    nonisolated static let volumeID = volumeID(
        for: URL(fileURLWithPath: "/", isDirectory: true)
    )

    nonisolated static let volume = FileVolume(
        id: volumeID,
        providerKind: .local,
        connectionID: nil,
        capabilities: .localDefault
    )

    nonisolated static let location = FileLocation(
        id: locationID,
        displayName: "Macintosh HD",
        root: ItemRef(volumeID: volumeID, path: "/")
    )

    nonisolated static func item(for url: URL) -> ItemRef {
        ItemRef(
            volumeID: volumeID(for: url),
            path: url.standardizedFileURL.path
        )
    }

    nonisolated static func volumeID(for url: URL) -> VolumeID {
        var candidate = url.standardizedFileURL
        while true {
            let values = try? candidate.resourceValues(forKeys: [
                .volumeUUIDStringKey,
                .volumeURLKey,
            ])
            if let uuid = values?.volumeUUIDString, !uuid.isEmpty {
                return VolumeID(rawValue: "local:uuid:\(uuid)")
            }
            if let rootPath = values?.volume?.standardizedFileURL.path {
                return VolumeID(rawValue: "local:path:\(rootPath)")
            }
            guard candidate.path != "/" else { break }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { break }
            candidate = parent
        }
        return VolumeID(rawValue: "local:path:/")
    }
}

extension ItemRef {
    /// Temporary compatibility bridge for local-only AppKit and FileManager APIs.
    nonisolated var localURL: URL? {
        guard volumeID.rawValue.hasPrefix("local:") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}
