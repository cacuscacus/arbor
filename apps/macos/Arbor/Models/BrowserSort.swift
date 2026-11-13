import Foundation
import SwiftUI

/// Finder-like listing sort keys Arbor supports today.
enum BrowserSortKey: String, CaseIterable, Identifiable, Codable, Sendable {
    case name
    case kind
    case modified
    case created
    case size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .kind: return "Kind"
        case .modified: return "Date Modified"
        case .created: return "Date Created"
        case .size: return "Size"
        }
    }

    var systemImage: String {
        switch self {
        case .name: return "textformat"
        case .kind: return "doc.text"
        case .modified: return "clock"
        case .created: return "calendar"
        case .size: return "externaldrive"
        }
    }
}

/// Sort state shared by every pane in a browser window (including split).
struct BrowserSortDescriptor: Equatable, Codable, Sendable {
    var key: BrowserSortKey
    var ascending: Bool
    /// Finder “Keep folders on top” when sorting.
    var keepFoldersOnTop: Bool

    static let `default` = BrowserSortDescriptor(key: .name, ascending: true, keepFoldersOnTop: true)

    func togglingDirection() -> BrowserSortDescriptor {
        var copy = self
        copy.ascending.toggle()
        return copy
    }

    func selecting(_ key: BrowserSortKey) -> BrowserSortDescriptor {
        var copy = self
        if copy.key == key {
            copy.ascending.toggle()
        } else {
            copy.key = key
            // Dates/size usually feel better newest/largest first (Finder-ish).
            switch key {
            case .name, .kind:
                copy.ascending = true
            case .modified, .created, .size:
                copy.ascending = false
            }
        }
        return copy
    }
}

enum BrowserSort {
    static func sorted(_ entries: [FileEntry], by descriptor: BrowserSortDescriptor) -> [FileEntry] {
        entries.sorted { lhs, rhs in
            if descriptor.keepFoldersOnTop, lhs.isBrowsable != rhs.isBrowsable {
                return lhs.isBrowsable && !rhs.isBrowsable
            }
            let comparison = compare(lhs, rhs, key: descriptor.key)
            if comparison == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return descriptor.ascending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }
    }

    private static func compare(_ lhs: FileEntry, _ rhs: FileEntry, key: BrowserSortKey) -> ComparisonResult {
        switch key {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .kind:
            let kind = lhs.kind.localizedStandardCompare(rhs.kind)
            return kind == .orderedSame
                ? lhs.name.localizedStandardCompare(rhs.name)
                : kind
        case .modified:
            return lhs.modifiedForSort.compare(rhs.modifiedForSort)
        case .created:
            return lhs.createdForSort.compare(rhs.createdForSort)
        case .size:
            if lhs.sizeForSort == rhs.sizeForSort {
                return .orderedSame
            }
            return lhs.sizeForSort < rhs.sizeForSort ? .orderedAscending : .orderedDescending
        }
    }

    /// Maps SwiftUI `Table` column sort into our descriptor (folders-on-top preserved).
    static func descriptor(
        from tableSort: [KeyPathComparator<FileEntry>],
        keepingFoldersOnTop foldersOnTop: Bool
    ) -> BrowserSortDescriptor? {
        guard let first = tableSort.first else { return nil }
        let key: BrowserSortKey?
        if first.keyPath == \FileEntry.name { key = .name }
        else if first.keyPath == \FileEntry.kind { key = .kind }
        else if first.keyPath == \FileEntry.modifiedForSort { key = .modified }
        else if first.keyPath == \FileEntry.createdForSort { key = .created }
        else if first.keyPath == \FileEntry.sizeForSort { key = .size }
        else { key = nil }
        guard let key else { return nil }
        let ascending: Bool = {
            switch first.order {
            case .forward: return true
            case .reverse: return false
            @unknown default: return true
            }
        }()
        return BrowserSortDescriptor(key: key, ascending: ascending, keepFoldersOnTop: foldersOnTop)
    }

    static func tableSortOrder(for descriptor: BrowserSortDescriptor) -> [KeyPathComparator<FileEntry>] {
        let order: SortOrder = descriptor.ascending ? .forward : .reverse
        switch descriptor.key {
        case .name:
            return [.init(\.name, order: order)]
        case .kind:
            return [.init(\.kind, order: order)]
        case .modified:
            return [.init(\.modifiedForSort, order: order)]
        case .created:
            return [.init(\.createdForSort, order: order)]
        case .size:
            return [.init(\.sizeForSort, order: order)]
        }
    }

    #if DEBUG
    /// Lightweight invariants for sort + table mapping (called at launch in Debug).
    static func runSelfCheck() {
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let folder = FileEntry(
            id: LocalFileLocation.item(for: URL(fileURLWithPath: "/tmp/alpha-dir")),
            name: "alpha-dir",
            isDirectory: true,
            isPackage: false,
            isHidden: false,
            size: 0,
            kind: "Folder",
            modified: older,
            created: older,
            location: "/tmp"
        )
        let hiddenFile = FileEntry(
            id: LocalFileLocation.item(for: URL(fileURLWithPath: "/tmp/.beta")),
            name: ".beta",
            isDirectory: false,
            isPackage: false,
            isHidden: true,
            size: 10,
            kind: "Document",
            modified: newer,
            created: newer,
            location: "/tmp"
        )
        let file = FileEntry(
            id: LocalFileLocation.item(for: URL(fileURLWithPath: "/tmp/gamma")),
            name: "gamma",
            isDirectory: false,
            isPackage: false,
            isHidden: false,
            size: 20,
            kind: "Document",
            modified: newer,
            created: newer,
            location: "/tmp"
        )

        let byName = sorted(
            [file, folder, hiddenFile],
            by: BrowserSortDescriptor(key: .name, ascending: true, keepFoldersOnTop: true)
        )
        assert(byName.map(\.name) == ["alpha-dir", ".beta", "gamma"], "folders-on-top name sort")

        let byDate = sorted(
            [folder, file, hiddenFile],
            by: BrowserSortDescriptor(key: .modified, ascending: false, keepFoldersOnTop: false)
        )
        assert(byDate.map(\.name) == [".beta", "gamma", "alpha-dir"], "date sort without folders-on-top")

        let desc = BrowserSortDescriptor(key: .size, ascending: false, keepFoldersOnTop: true)
        let mapped = descriptor(from: tableSortOrder(for: desc), keepingFoldersOnTop: true)
        assert(mapped == desc, "table sort round-trip")

        assert(hiddenFile.listingOpacity == 0.5)
        assert(file.listingOpacity == 1)
    }
    #endif
}

/// One store per browser window. Split panes and tabs in that window share sort live;
/// changes also persist as launch defaults for new windows.
@Observable
final class WindowBrowserSortStore {
    var descriptor: BrowserSortDescriptor {
        didSet {
            guard descriptor != oldValue else { return }
            BrowserSortDescriptor.persist(descriptor)
        }
    }

    init(descriptor: BrowserSortDescriptor = .loadDefaults()) {
        self.descriptor = descriptor
    }

    func select(_ key: BrowserSortKey) {
        descriptor = descriptor.selecting(key)
    }

    func setKeepFoldersOnTop(_ enabled: Bool) {
        guard descriptor.keepFoldersOnTop != enabled else { return }
        var next = descriptor
        next.keepFoldersOnTop = enabled
        descriptor = next
    }
}

extension BrowserSortDescriptor {
    private enum DefaultsKey {
        static let key = "arbor.browser.sort.key"
        static let ascending = "arbor.browser.sort.ascending"
        static let foldersOnTop = "arbor.browser.sort.foldersOnTop"
    }

    static func loadDefaults() -> BrowserSortDescriptor {
        let defaults = UserDefaults.standard
        let key = BrowserSortKey(rawValue: defaults.string(forKey: DefaultsKey.key) ?? "") ?? .name
        let ascending: Bool = {
            if defaults.object(forKey: DefaultsKey.ascending) == nil { return true }
            return defaults.bool(forKey: DefaultsKey.ascending)
        }()
        let foldersOnTop: Bool = {
            if defaults.object(forKey: DefaultsKey.foldersOnTop) == nil { return true }
            return defaults.bool(forKey: DefaultsKey.foldersOnTop)
        }()
        return BrowserSortDescriptor(key: key, ascending: ascending, keepFoldersOnTop: foldersOnTop)
    }

    static func persist(_ descriptor: BrowserSortDescriptor) {
        let defaults = UserDefaults.standard
        defaults.set(descriptor.key.rawValue, forKey: DefaultsKey.key)
        defaults.set(descriptor.ascending, forKey: DefaultsKey.ascending)
        defaults.set(descriptor.keepFoldersOnTop, forKey: DefaultsKey.foldersOnTop)
    }
}

private struct WindowBrowserSortStoreFocusedKey: FocusedValueKey {
    typealias Value = WindowBrowserSortStore
}

extension FocusedValues {
    var windowBrowserSort: WindowBrowserSortStore? {
        get { self[WindowBrowserSortStoreFocusedKey.self] }
        set { self[WindowBrowserSortStoreFocusedKey.self] = newValue }
    }
}

/// Shared Sort By control for the toolbar and the View menu.
struct BrowserSortMenuContent: View {
    @Bindable var store: WindowBrowserSortStore

    var body: some View {
        ForEach(BrowserSortKey.allCases) { key in
            Button {
                store.select(key)
            } label: {
                if store.descriptor.key == key {
                    Label(
                        key.title,
                        systemImage: store.descriptor.ascending ? "chevron.up" : "chevron.down"
                    )
                } else {
                    Text(key.title)
                }
            }
        }

        Divider()

        Toggle(
            "Keep Folders on Top",
            isOn: Binding(
                get: { store.descriptor.keepFoldersOnTop },
                set: { store.setKeepFoldersOnTop($0) }
            )
        )
    }
}
