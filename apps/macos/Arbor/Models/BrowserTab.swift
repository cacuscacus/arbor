import Foundation

/// Commands the window toolbar sends into the focused pane’s `FileBrowserView`.
enum BrowserPaneChromeCommand: Equatable {
    case back
    case forward
    case undo
    case redo
    case toggleSearch
    case quickLook
    case goToFolder
}

/// One folder pane inside a browser tab (primary, or a side of a split).
@Observable
final class BrowserPane: Identifiable {
    let id: UUID
    let navigation: BrowserNavigation
    /// Per-pane display prefs (kept on the pane so split chrome can bind without hopping views).
    var displaySettings = BrowserDisplaySettings()
    /// Per-pane undo stack (same reason as `displaySettings`).
    var undoStack = ArborUndoStack()
    /// Per-pane search state (kept on the pane so searches continue in background tabs).
    let search = SearchSession()

    /// Bumped when the window toolbar wants the focused browser to run `pendingChromeCommand`.
    private(set) var chromeCommandToken = 0
    private(set) var pendingChromeCommand: BrowserPaneChromeCommand?

    init(id: UUID = UUID(), root: ItemRef) {
        self.id = id
        navigation = BrowserNavigation(initial: root)
    }

    convenience init(id: UUID = UUID(), root: URL) {
        self.init(id: id, root: LocalFileLocation.item(for: root))
    }

    /// Short folder label for toolbar / tab titles (volume root → friendly name).
    var folderDisplayName: String {
        let item = navigation.current
        if let location = FileProviderRegistry.shared.location(containing: item),
           item == location.root
        {
            return location.displayName
        }
        if item.path == "/" {
            return item.volumeID.rawValue.hasPrefix("local:") ? "Macintosh HD" : "/"
        }
        return item.name.isEmpty ? item.path : item.name
    }

    func sendChrome(_ command: BrowserPaneChromeCommand) {
        pendingChromeCommand = command
        chromeCommandToken &+= 1
    }

    func consumeChromeCommand() -> BrowserPaneChromeCommand? {
        defer { pendingChromeCommand = nil }
        return pendingChromeCommand
    }
}

/// One Finder-style browser tab: identity + one or two panes (optional horizontal split).
/// Selection / search remain in `FileBrowserView` `@State` for v1; keep inactive
/// tab views (and both split panes) mounted so that state is preserved across switches.
@Observable
final class BrowserTab: Identifiable {
    let id: UUID
    /// Always 1 pane (single) or 2 panes (horizontal split).
    private(set) var panes: [BrowserPane]
    var focusedPaneID: BrowserPane.ID
    /// `true` when created via ⌘⇧F or "Open in Tab" for a dedicated search workflow.
    var isDedicatedSearchTab = false

    init(id: UUID = UUID(), root: ItemRef) {
        self.id = id
        let pane = BrowserPane(root: root)
        panes = [pane]
        focusedPaneID = pane.id
    }

    convenience init(id: UUID = UUID(), root: URL) {
        self.init(id: id, root: LocalFileLocation.item(for: root))
    }

    /// Restores a tab with one or two panes (horizontal split when `paneRoots.count > 1`).
    init(id: UUID = UUID(), paneRoots: [ItemRef], focusedPaneIndex: Int = 0) {
        self.id = id
        let roots = Array(paneRoots.prefix(2))
        precondition(!roots.isEmpty, "BrowserTab requires at least one pane root")
        let built = roots.map { BrowserPane(root: $0) }
        panes = built
        let index = min(max(0, focusedPaneIndex), built.count - 1)
        focusedPaneID = built[index].id
    }

    convenience init(id: UUID = UUID(), paneRoots: [URL], focusedPaneIndex: Int = 0) {
        self.init(
            id: id,
            paneRoots: paneRoots.map(LocalFileLocation.item(for:)),
            focusedPaneIndex: focusedPaneIndex
        )
    }

    var isSplit: Bool { panes.count > 1 }

    var focusedPane: BrowserPane {
        panes.first { $0.id == focusedPaneID } ?? panes[0]
    }

    /// Navigation for the focused pane (sidebar / new-tab clone).
    var navigation: BrowserNavigation { focusedPane.navigation }

    /// Active search session in this tab (prefers focused pane, falls back to any searching pane).
    var activeSearch: SearchSession? {
        if focusedPane.search.isActive || focusedPane.search.isSearching {
            return focusedPane.search
        }
        return panes.first { $0.search.isActive || $0.search.isSearching }?.search
    }

    /// Immediately cancels all running search processes in this tab (called when closing a tab).
    func cancelActiveSearches() {
        for pane in panes {
            pane.search.cancel()
        }
    }

    /// Plain title for accessibility / window title fallback.
    /// Split tabs list both pane folders: `left | right`.
    var title: String {
        if let active = activeSearch, active.isActive {
            return "Search: \(active.trimmedQuery)"
        }
        if isDedicatedSearchTab, focusedPane.search.isPresented {
            return "Search"
        }
        if isSplit {
            return panes.map(\.folderDisplayName).joined(separator: " | ")
        }
        return focusedPane.folderDisplayName
    }

    func focusPane(_ id: BrowserPane.ID) {
        guard panes.contains(where: { $0.id == id }) else { return }
        focusedPaneID = id
    }

    /// Opens `folder` in the other pane; enters split mode if needed.
    func openInSplit(folder: ItemRef) {
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

    func openInSplit(folder: URL) {
        openInSplit(folder: LocalFileLocation.item(for: folder))
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
