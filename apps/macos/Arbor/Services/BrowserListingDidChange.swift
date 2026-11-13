import Foundation

/// Broadcast after filesystem mutations so every mounted browser pane can refresh
/// if it is showing an affected folder (critical for split view: destination-only
/// `@State` reload leaves the source pane stale).
enum BrowserListingDidChange {
    static let name = Notification.Name("ArborBrowserListingDidChange")
    static let folderItemsKey = "folderItems"
    /// Legacy key kept for one migration window while call sites finish moving.
    static let folderURLsKey = "folderURLs"

    static func post(folders: [ItemRef]) {
        let unique = Array(Set(folders))
        guard !unique.isEmpty else { return }
        NotificationCenter.default.post(
            name: name,
            object: nil,
            userInfo: [folderItemsKey: unique]
        )
    }

    /// Temporary bridge for remaining local URL posters.
    static func post(folderURLs: [URL]) {
        post(folders: folderURLs.map(LocalFileLocation.item(for:)))
    }

    static func folders(from note: Notification) -> [ItemRef] {
        if let items = note.userInfo?[folderItemsKey] as? [ItemRef] {
            return items
        }
        let urls = note.userInfo?[folderURLsKey] as? [URL] ?? []
        return urls.map(LocalFileLocation.item(for:))
    }
}
