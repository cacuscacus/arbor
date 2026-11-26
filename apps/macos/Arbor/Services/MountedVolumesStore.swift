import AppKit
import Foundation
import Observation

struct MountedVolume: Identifiable, Hashable {
    let url: URL
    let name: String
    let isEjectable: Bool
    let isRemovable: Bool
    let isInternal: Bool
    let isLocal: Bool
    let availableCapacity: Int64?

    var id: String { url.path }
    var itemRef: ItemRef { LocalFileLocation.item(for: url) }

    var canEject: Bool {
        guard url.path != "/" else { return false }
        return isEjectable || isRemovable || !isLocal
    }

    var systemImage: String {
        if url.path == "/" {
            return "internaldrive"
        }
        if !isLocal {
            return "externaldrive.connected.to.line.below"
        }
        if isEjectable || isRemovable {
            return "externaldrive"
        }
        return "internaldrive"
    }
}

/// Live list of mounted macOS volumes (internal disks, external USB drives, DMGs, network shares)
/// with automatic mount/unmount/rename refresh and safe Finder-equivalent Eject.
@MainActor
@Observable
final class MountedVolumesStore {
    static let shared = MountedVolumesStore()

    private(set) var volumes: [MountedVolume] = []
    private var observers: [NSObjectProtocol] = []

    private init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        }
    }

    func refresh() {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsEjectableKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
            .volumeIsBrowsableKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        var parsed: [MountedVolume] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.volumeIsBrowsable == false { continue }
            let rawName = values?.volumeName ?? url.lastPathComponent
            let name = rawName.isEmpty ? (url.path == "/" ? "Macintosh HD" : url.path) : rawName
            parsed.append(
                MountedVolume(
                    url: url,
                    name: name,
                    isEjectable: values?.volumeIsEjectable ?? false,
                    isRemovable: values?.volumeIsRemovable ?? false,
                    isInternal: values?.volumeIsInternal ?? (url.path == "/"),
                    isLocal: values?.volumeIsLocal ?? true,
                    availableCapacity: values?.volumeAvailableCapacityForImportantUsage
                )
            )
        }

        // Keep root volume first, then sort others alphabetically.
        parsed.sort { lhs, rhs in
            if lhs.url.path == "/" { return true }
            if rhs.url.path == "/" { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        volumes = parsed
    }

    func eject(_ volume: MountedVolume) async throws {
        try await Task.detached(priority: .userInitiated) {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
        }.value
        refresh()
    }
}
