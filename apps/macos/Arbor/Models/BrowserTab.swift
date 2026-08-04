import Foundation

/// One Finder-style browser tab: identity + its own navigation stack.
/// Selection / display remain in `FileBrowserView` `@State` for v1; keep inactive
/// tab views mounted so that state is preserved across switches.
@Observable
final class BrowserTab: Identifiable {
    let id: UUID
    let navigation: BrowserNavigation

    init(id: UUID = UUID(), root: URL) {
        self.id = id
        navigation = BrowserNavigation(initial: root)
    }

    /// Folder name for the tab bar (volume root shows a friendly label).
    var title: String {
        let url = navigation.current
        if url.path == "/" { return "Macintosh HD" }
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }
}
