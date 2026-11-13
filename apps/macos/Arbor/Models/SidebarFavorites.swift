import Foundation
import AppKit
import SwiftUI

struct FavoriteItem: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var itemRef: ItemRef
    /// Optional custom label (e.g. "Home"). `nil` uses the folder name.
    var title: String?

    init(id: UUID = UUID(), itemRef: ItemRef, title: String? = nil) {
        self.id = id
        self.itemRef = itemRef
        self.title = title
    }

    init(url: URL, title: String? = nil) {
        self.init(itemRef: LocalFileLocation.item(for: url), title: title)
    }

    var displayName: String {
        if let title, !title.isEmpty { return title }
        if itemRef.name.isEmpty || itemRef.path == "/" {
            return itemRef.path
        }
        return itemRef.name
    }

    var systemImage: String {
        switch title {
        case "Home": return "house"
        case "Desktop": return "desktopcomputer"
        case "Documents": return "doc"
        case "Downloads": return "arrow.down.circle"
        default: return "folder"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case itemRef
        case path
        case title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title)
        if let item = try container.decodeIfPresent(ItemRef.self, forKey: .itemRef) {
            itemRef = item
        } else {
            let path = try container.decode(String.self, forKey: .path)
            itemRef = LocalFileLocation.item(for: URL(fileURLWithPath: path))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(itemRef, forKey: .itemRef)
        try container.encodeIfPresent(title, forKey: .title)
    }
}

@Observable
final class SidebarFavoritesStore {
    /// Shared across windows so favorites stay in sync (Finder-like).
    static let shared = SidebarFavoritesStore()

    private(set) var items: [FavoriteItem]

    init() {
        if let data = UserDefaults.standard.data(forKey: Keys.items),
           let decoded = try? JSONDecoder().decode([FavoriteItem].self, from: data),
           !decoded.isEmpty
        {
            items = decoded
        } else {
            items = Self.defaultItems()
            persist()
        }
    }

    /// Adds folders to favorites. Returns how many were newly added.
    @discardableResult
    func add(urls: [URL]) -> Int {
        insert(urls: urls, at: items.count)
    }

    @discardableResult
    func add(items itemRefs: [ItemRef]) -> Int {
        insert(items: itemRefs, at: items.count)
    }

    /// Inserts folders at `index` (e.g. drop position). Skips non-folders and duplicates.
    @discardableResult
    func insert(urls: [URL], at index: Int) -> Int {
        insert(items: urls.map(LocalFileLocation.item(for:)), at: index)
    }

    /// Provider-neutral insertion. Local entries are validated as directories;
    /// remote providers validate roots when their connection UI is added in 6b.
    @discardableResult
    func insert(items itemRefs: [ItemRef], at index: Int) -> Int {
        var added: [FavoriteItem] = []
        let existing = Set(items.map(\.itemRef))
        var seen = existing

        for item in itemRefs {
            if let url = item.localURL {
                guard isDirectory(url) else { continue }
            }
            guard !seen.contains(item) else { continue }
            seen.insert(item)
            added.append(FavoriteItem(
                itemRef: item,
                title: item.localURL.flatMap(defaultTitle(for:))
            ))
        }

        guard !added.isEmpty else { return 0 }

        let clamped = max(0, min(index, items.count))
        var updated = items
        updated.insert(contentsOf: added, at: clamped)
        items = updated
        persist()
        return added.count
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        var updated = items
        updated.move(fromOffsets: source, toOffset: destination)
        items = updated
        persist()
    }

    /// Move an existing favorite so it sits at `toIndex` (0...count).
    func relocate(id: UUID, to toIndex: Int) {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return }
        var updated = items
        let item = updated.remove(at: from)
        var destination = max(0, min(toIndex, updated.count + 1))
        if from < destination {
            destination -= 1
        }
        destination = max(0, min(destination, updated.count))
        updated.insert(item, at: destination)
        items = updated
        persist()
    }

    func contains(_ url: URL) -> Bool {
        contains(LocalFileLocation.item(for: url))
    }

    func contains(_ item: ItemRef) -> Bool {
        items.contains { $0.itemRef == item }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Keys.items)
    }

    private static func defaultItems() -> [FavoriteItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            FavoriteItem(url: home, title: "Home"),
            FavoriteItem(url: home.appendingPathComponent("Desktop"), title: "Desktop"),
            FavoriteItem(url: home.appendingPathComponent("Documents"), title: "Documents"),
            FavoriteItem(url: home.appendingPathComponent("Downloads"), title: "Downloads"),
        ]
    }

    private func defaultTitle(for url: URL) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        if url == home { return "Home" }
        let known: [(String, String)] = [
            ("Desktop", "Desktop"),
            ("Documents", "Documents"),
            ("Downloads", "Downloads"),
        ]
        for (component, title) in known {
            if url == home.appendingPathComponent(component).standardizedFileURL {
                return title
            }
        }
        return nil
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }

    private enum Keys {
        static let items = "arbor.sidebar.favorites"
    }
}
