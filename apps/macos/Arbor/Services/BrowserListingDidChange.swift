import Foundation

/// Broadcast after filesystem mutations so every mounted browser pane can refresh
/// if it is showing an affected folder (critical for split view: destination-only
/// `@State` reload leaves the source pane stale).
enum BrowserListingDidChange {
    static let name = Notification.Name("ArborBrowserListingDidChange")
    static let folderURLsKey = "folderURLs"

    static func post(folders: [URL]) {
        let unique = Array(Set(folders.map(\.standardizedFileURL)))
        guard !unique.isEmpty else { return }
        NotificationCenter.default.post(
            name: name,
            object: nil,
            userInfo: [folderURLsKey: unique]
        )
    }

    static func folders(from note: Notification) -> [URL] {
        note.userInfo?[folderURLsKey] as? [URL] ?? []
    }
}
