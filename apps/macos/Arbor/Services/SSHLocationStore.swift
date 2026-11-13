import Foundation
import Observation

private struct SSHLocationCatalog: Codable {
    var version = 1
    var locations: [SSHLocationProfile]
}

@MainActor
@Observable
final class SSHLocationStore {
    static let shared = SSHLocationStore()

    private(set) var locations: [SSHLocationProfile] = []
    private(set) var loadError: String?

    private init() {
        load()
        registerProviders()
    }

    @discardableResult
    func add(_ profile: SSHLocationProfile) throws -> SSHLocationProfile {
        guard !locations.contains(where: {
            $0.endpoint == profile.endpoint && $0.rootPath == profile.rootPath
        }) else {
            throw StoreError.duplicate
        }
        locations.append(profile)
        locations.sort {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        FileProviderRegistry.shared.register(
            SSHFileProvider(profile: profile),
            location: profile.location
        )
        try persist()
        return profile
    }

    func remove(id: LocationID) {
        guard let index = locations.firstIndex(where: { $0.id == id }) else { return }
        let removed = locations.remove(at: index)
        FileProviderRegistry.shared.unregister(volumeID: removed.volumeID)
        Task {
            await SSHTransportPool.shared.disconnect(removed.connectionID)
        }
        do {
            try persist()
        } catch {
            loadError = error.localizedDescription
        }
    }

    func profile(containing item: ItemRef) -> SSHLocationProfile? {
        locations.first {
            $0.volumeID == item.volumeID
                && (item.path == $0.rootPath
                    || item.path.hasPrefix($0.rootPath == "/" ? "/" : $0.rootPath + "/"))
        }
    }

    func profile(connectionID: ConnectionID) -> SSHLocationProfile? {
        locations.first { $0.connectionID == connectionID }
    }

    private func registerProviders() {
        for profile in locations {
            FileProviderRegistry.shared.register(
                SSHFileProvider(profile: profile),
                location: profile.location
            )
        }
    }

    private func load() {
        let url = catalogURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let catalog = try JSONDecoder().decode(SSHLocationCatalog.self, from: data)
            guard catalog.version == 1 else {
                throw StoreError.unsupportedVersion(catalog.version)
            }
            locations = catalog.locations
        } catch {
            loadError = error.localizedDescription
            backupCorruptCatalog(at: url)
        }
    }

    private func persist() throws {
        let url = catalogURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(
            SSHLocationCatalog(locations: locations)
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private var catalogURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("Arbor", isDirectory: true)
            .appendingPathComponent("connections-v1.json")
    }

    private func backupCorruptCatalog(at url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.deletingPathExtension()
            .appendingPathExtension("corrupt-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: backup)
    }

    enum StoreError: LocalizedError {
        case duplicate
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .duplicate:
                return "This SSH location already exists."
            case .unsupportedVersion(let version):
                return "Unsupported SSH location catalog version \(version)."
            }
        }
    }
}
