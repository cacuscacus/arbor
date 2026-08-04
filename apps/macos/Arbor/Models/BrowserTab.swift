import Foundation

/// One folder pane inside a browser tab (primary, or a side of a split).
@Observable
final class BrowserPane: Identifiable {
    let id: UUID
    let navigation: BrowserNavigation

    init(id: UUID = UUID(), root: URL) {
        self.id = id
        navigation = BrowserNavigation(initial: root)
    }
}

/// One Finder-style browser tab: identity + one or two panes (optional horizontal split).
/// Selection / display remain in `FileBrowserView` `@State` for v1; keep inactive
/// tab views (and both split panes) mounted so that state is preserved across switches.
@Observable
final class BrowserTab: Identifiable {
    let id: UUID
    /// Always 1 pane (single) or 2 panes (horizontal split).
    private(set) var panes: [BrowserPane]
    var focusedPaneID: BrowserPane.ID

    init(id: UUID = UUID(), root: URL) {
        self.id = id
        let pane = BrowserPane(root: root)
        panes = [pane]
        focusedPaneID = pane.id
    }

    var isSplit: Bool { panes.count > 1 }

    var focusedPane: BrowserPane {
        panes.first { $0.id == focusedPaneID } ?? panes[0]
    }

    /// Navigation for the focused pane (sidebar / tab title / new-tab clone).
    var navigation: BrowserNavigation { focusedPane.navigation }

    /// Folder name for the tab bar (volume root shows a friendly label).
    var title: String {
        let url = navigation.current
        if url.path == "/" { return "Macintosh HD" }
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    func focusPane(_ id: BrowserPane.ID) {
        guard panes.contains(where: { $0.id == id }) else { return }
        focusedPaneID = id
    }

    /// Opens `folder` in the other pane; enters split mode if needed.
    func openInSplit(folder: URL) {
        if panes.count == 1 {
            let secondary = BrowserPane(root: folder)
            panes.append(secondary)
            focusedPaneID = secondary.id
            return
        }

        guard let other = panes.first(where: { $0.id != focusedPaneID }) else { return }
        other.navigation.go(to: folder)
        focusedPaneID = other.id
    }

    /// Enter split (clone focused cwd into the new pane) or leave split.
    func toggleSplit() {
        if isSplit {
            closeSplit()
        } else {
            let secondary = BrowserPane(root: focusedPane.navigation.current)
            panes.append(secondary)
        }
    }

    /// Collapse to a single pane, keeping the focused pane’s navigation.
    func closeSplit() {
        guard isSplit else { return }
        let kept = focusedPane
        panes = [kept]
        focusedPaneID = kept.id
    }
}
