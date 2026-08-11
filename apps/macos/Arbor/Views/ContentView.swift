import AppKit
import SwiftUI

/// Root layout: tab bar + sidebar + file browser (optional horizontal split per tab)
/// and an optional embedded PTY terminal bound to the focused pane’s cwd.
/// Wired to Rust via FFI in a later pass.
struct ContentView: View {
    @State private var tabs: [BrowserTab]
    @State private var selectedTabID: BrowserTab.ID
    @State private var favorites = SidebarFavoritesStore.shared
    @State private var dragState = FileDragState()
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var sessionWindowID = UUID()
    @State private var restoredFrame: CGRect?
    @AppStorage(TerminalPreferences.isVisibleKey) private var isTerminalVisible = false
    @AppStorage(TerminalPreferences.followCwdKey) private var followCwd = true
    @State private var terminalRestartToken = UUID()
    @Bindable private var agentRun = AgentRunCoordinator.shared
    @State private var windowSort = WindowBrowserSortStore()

    init(rootDirectory: URL? = nil) {
        if rootDirectory == nil, let snapshot = BrowserSessionStore.shared.dequeuePendingWindow() {
            let material = snapshot.makeBrowserTabs()
            _tabs = State(initialValue: material.tabs)
            _selectedTabID = State(initialValue: material.selectedTabID)
            if let frame = snapshot.frame, frame.isReasonable {
                _restoredFrame = State(initialValue: frame.cgRect)
            } else {
                _restoredFrame = State(initialValue: nil)
            }
            return
        }

        let root = rootDirectory ?? WindowLaunchCoordinator.dequeueRoot()
        let tab = BrowserTab(root: root)
        _tabs = State(initialValue: [tab])
        _selectedTabID = State(initialValue: tab.id)
        _restoredFrame = State(initialValue: nil)
    }

    private var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// Paths + focus + selection — drives debounced session persistence.
    private var sessionFingerprint: String {
        let tabPart = tabs.map { tab in
            let paths = tab.panes.map { $0.navigation.current.path }.joined(separator: "\u{1e}")
            let focus = tab.panes.firstIndex(where: { $0.id == tab.focusedPaneID }) ?? 0
            return "\(paths)\u{1f}\(focus)"
        }.joined(separator: "\u{1d}")
        let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) ?? 0
        return "\(tabPart)\u{1c}\(selectedIndex)"
    }

    /// Focused browser pane folder (fallback Home) — drives the embedded shell cwd.
    private var focusedFolderURL: URL {
        selectedTab?.navigation.current
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    var body: some View {
        Group {
            if isTerminalVisible {
                VSplitView {
                    browserSplit
                    TerminalPaneView(
                        cwd: focusedFolderURL,
                        followCwd: $followCwd,
                        restartToken: $terminalRestartToken
                    )
                    .frame(minHeight: 120)
                    .layoutPriority(-1)
                }
            } else {
                browserSplit
            }
        }
        .background(WindowChromeConfigurator())
        .background(
            SessionWindowFrameTracker(
                windowID: sessionWindowID,
                initialFrame: restoredFrame
            )
        )
        .focusEffectDisabled()
        .environment(windowSort)
        .focusedSceneValue(\.activeBrowserTab, selectedTab)
        .focusedSceneValue(\.windowBrowserSort, windowSort)
        .background {
            tabShortcuts
        }
        .sheet(item: $agentRun.request) { request in
            RunAgentSheet(
                folder: request.folder,
                selection: request.selection
            )
        }
        .alert(
            "Could not run agent",
            isPresented: Binding(
                get: { agentRun.launchError != nil },
                set: { if !$0 { agentRun.launchError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { agentRun.launchError = nil }
        } message: {
            Text(agentRun.launchError ?? "")
        }
        .onChange(of: sessionFingerprint, initial: true) { _, _ in
            publishSession()
        }
        .onDisappear {
            BrowserSessionStore.shared.removeWindow(id: sessionWindowID)
            BrowserSessionStore.shared.saveNow()
        }
    }

    /// Sidebar + detail; tab strip lives only in the detail column (Finder-style).
    private var browserSplit: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            if let tab = selectedTab {
                SidebarView(
                    navigation: tab.navigation,
                    favorites: favorites,
                    dragState: dragState,
                    onOpenInSplit: { url in
                        tab.openInSplit(folder: url)
                    }
                )
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
            }
        } detail: {
            // Keep every tab's browser mounted so @State (selection, view mode, …)
            // survives tab switches; only the active tab receives hits / focus values.
            // Within a tab, both split panes stay mounted for the same reason.
            ZStack {
                ForEach(tabs) { tab in
                    let active = tab.id == selectedTabID
                    TabDetailView(
                        tab: tab,
                        favorites: favorites,
                        dragState: dragState,
                        isActive: active
                    )
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    .accessibilityHidden(!active)
                    .zIndex(active ? 1 : 0)
                }
            }
            // Overlay (not a layout sibling) so folder icons *and* the HSplitView
            // divider sit under the glass island — same scroll-under feel as Finder.
            .overlay(alignment: .top) {
                detailTabChrome
            }
        }
        // Automatic style picks up Liquid Glass sidebar on Tahoe.
        .navigationSplitViewStyle(.automatic)
        // Focusing the PTY can collapse the sidebar; keep it while the terminal is open.
        .onChange(of: columnVisibility) { _, newValue in
            if isTerminalVisible, newValue == .detailOnly {
                columnVisibility = .all
            }
        }
    }

    /// Floating glass island of pills (+ trailing). Pills hide when only one tab remains;
    /// a small floating **+** stays so new tabs are still discoverable without ⌘T.
    @ViewBuilder
    private var detailTabChrome: some View {
        if tabs.count > 1 {
            HStack(spacing: 2) {
                ForEach(tabs) { tab in
                    TabBarItem(
                        tab: tab,
                        isSelected: tab.id == selectedTabID,
                        onSelect: { selectedTabID = tab.id },
                        onClose: { closeTab(id: tab.id) }
                    )
                    .frame(maxWidth: .infinity)
                }

                newTabButton
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            // Capsule → true horizontal pill (Finder tab strip), not a rounded rect.
            .glassEffect(.regular, in: Capsule(style: .continuous))
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 2)
        } else {
            HStack {
                Spacer(minLength: 0)
                newTabButton
                    .glassEffect(.regular, in: Circle())
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
    }

    private var newTabButton: some View {
        Button(action: openNewTab) {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .help("New Tab")
    }

    private var tabShortcuts: some View {
        Group {
            Button("") { openNewTab() }
                .keyboardShortcut("t", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)

            Button("") { closeSelectedTab() }
                .keyboardShortcut("w", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    private func openNewTab() {
        let root = selectedTab?.navigation.current
            ?? FileManager.default.homeDirectoryForCurrentUser
        let tab = BrowserTab(root: root)
        tabs.append(tab)
        selectedTabID = tab.id
    }

    private func closeSelectedTab() {
        closeTab(id: selectedTabID)
    }

    private func closeTab(id: BrowserTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }

        if tabs.count == 1 {
            NSApp.keyWindow?.close()
            return
        }

        tabs.remove(at: index)
        if selectedTabID == id {
            let nextIndex = min(index, tabs.count - 1)
            selectedTabID = tabs[nextIndex].id
        }
    }

    private func publishSession() {
        let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) ?? 0
        let tabSnaps = tabs.map { tab in
            BrowserTabSnapshot(
                panePaths: tab.panes.map { $0.navigation.current.path },
                focusedPaneIndex: tab.panes.firstIndex(where: { $0.id == tab.focusedPaneID }) ?? 0
            )
        }
        BrowserSessionStore.shared.updateWindow(
            id: sessionWindowID,
            snapshot: BrowserWindowSnapshot(
                frame: nil,
                selectedTabIndex: selectedIndex,
                tabs: tabSnaps
            )
        )
    }
}

/// Applies a restored `NSWindow` frame once and reports move/resize for session save.
private struct SessionWindowFrameTracker: NSViewRepresentable {
    let windowID: UUID
    let initialFrame: CGRect?

    func makeCoordinator() -> Coordinator {
        Coordinator(windowID: windowID)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view, initialFrame: initialFrame)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Coordinator {
        let windowID: UUID
        private var observers: [NSObjectProtocol] = []
        private var didApplyInitial = false
        private weak var observedWindow: NSWindow?

        init(windowID: UUID) {
            self.windowID = windowID
        }

        deinit {
            let center = NotificationCenter.default
            observers.forEach { center.removeObserver($0) }
        }

        func attach(to view: NSView, initialFrame: CGRect?) {
            DispatchQueue.main.async { [weak self] in
                self?.install(on: view, initialFrame: initialFrame, attemptsLeft: 20)
            }
        }

        private func install(on view: NSView, initialFrame: CGRect?, attemptsLeft: Int) {
            guard let window = view.window else {
                guard attemptsLeft > 0 else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.install(on: view, initialFrame: initialFrame, attemptsLeft: attemptsLeft - 1)
                }
                return
            }

            if observedWindow !== window {
                let center = NotificationCenter.default
                observers.forEach { center.removeObserver($0) }
                observers.removeAll()
                observedWindow = window
                ArborBrowserWindow.prepare(window)

                for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                    let token = center.addObserver(forName: name, object: window, queue: .main) {
                        [weak self] notification in
                        guard let self,
                              let win = notification.object as? NSWindow
                        else { return }
                        BrowserSessionStore.shared.updateFrame(id: self.windowID, frame: win.frame)
                    }
                    observers.append(token)
                }
            }

            if !didApplyInitial, let initialFrame, BrowserWindowFrame(initialFrame).isReasonable {
                window.setFrame(initialFrame, display: true)
                didApplyInitial = true
            }

            BrowserSessionStore.shared.updateFrame(id: windowID, frame: window.frame)
        }
    }
}

/// Detail column for one tab: single browser or horizontal dual-pane split.
///
/// Window toolbar/title attach here (outside `HSplitView`) so Liquid Glass samples
/// the full detail width. Putting `.toolbar` on a single pane child made the other
/// half go opaque and drew a hard horizontal title separator (cases 3–4).
private struct TabDetailView: View {
    @Bindable var tab: BrowserTab
    @Bindable var favorites: SidebarFavoritesStore
    var dragState: FileDragState
    var isActive: Bool

    var body: some View {
        Group {
            if tab.isSplit {
                HSplitView {
                    ForEach(tab.panes) { pane in
                        PaneBrowserHost(
                            tab: tab,
                            pane: pane,
                            favorites: favorites,
                            dragState: dragState,
                            isActive: isActive && tab.focusedPaneID == pane.id,
                            isVisible: isActive
                        )
                    }
                }
            } else if let pane = tab.panes.first {
                PaneBrowserHost(
                    tab: tab,
                    pane: pane,
                    favorites: favorites,
                    dragState: dragState,
                    isActive: isActive,
                    isVisible: isActive
                )
            }
        }
        .modifier(FocusedPaneWindowChromeModifier(isEnabled: isActive, tab: tab))
    }
}

private struct PaneBrowserHost: View {
    @Bindable var tab: BrowserTab
    @Bindable var pane: BrowserPane
    @Bindable var favorites: SidebarFavoritesStore
    var dragState: FileDragState
    var isActive: Bool
    /// Selected tab (true for both split panes when the tab is showing).
    var isVisible: Bool

    var body: some View {
        FileBrowserView(
            pane: pane,
            favorites: favorites,
            dragState: dragState,
            isActive: isActive,
            isVisible: isVisible,
            onOpenInSplit: { url in
                tab.openInSplit(folder: url)
            }
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                tab.focusPane(pane.id)
            }
        )
    }
}

/// Stable, full-width window chrome driven by the focused pane.
private struct FocusedPaneWindowChromeModifier: ViewModifier {
    var isEnabled: Bool
    @Bindable var tab: BrowserTab
    @Environment(WindowBrowserSortStore.self) private var windowSort

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            chromeBody(content: content)
        } else {
            content
        }
    }

    @ViewBuilder
    private func chromeBody(content: Content) -> some View {
        @Bindable var pane = tab.focusedPane
        let navigation = pane.navigation

        content
            // Keep a plain window title for Mission Control / the Window menu, but hide
            // the system toolbar title string (it can't italicize/emphasize one side).
            .navigationTitle(tab.title)
            .toolbar(removing: .title)
            // Do not set `.toolbarBackground(...)` — custom materials flatten Liquid Glass.
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    HStack(spacing: 2) {
                        Button {
                            pane.sendChrome(.back)
                        } label: {
                            Image(systemName: "chevron.backward")
                        }
                        .disabled(!navigation.canGoBack)
                        .help("Back")

                        Button {
                            pane.sendChrome(.forward)
                        } label: {
                            Image(systemName: "chevron.forward")
                        }
                        .disabled(!navigation.canGoForward)
                        .help("Forward")
                    }
                }

                ToolbarSpacer(.fixed)

                ToolbarItemGroup(placement: .navigation) {
                    HStack(spacing: 2) {
                        Button {
                            pane.sendChrome(.undo)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .disabled(!pane.undoStack.canUndo)
                        .help(pane.undoStack.undoActionName)

                        Button {
                            pane.sendChrome(.redo)
                        } label: {
                            Image(systemName: "arrow.uturn.forward")
                        }
                        .disabled(!pane.undoStack.canRedo)
                        .help(pane.undoStack.redoActionName)
                    }
                }

                // Sit next to chrome buttons (not `.principal` — that floated a center pill).
                ToolbarItem(placement: .navigation) {
                    SplitFolderTitleLabel(tab: tab, style: .toolbar)
                }
                .sharedBackgroundVisibility(.hidden)

                ToolbarSpacer(.flexible)

                ToolbarItemGroup(placement: .primaryAction) {
                    Picker("View", selection: $pane.displaySettings.viewMode) {
                        ForEach(BrowserViewMode.allCases) { mode in
                            Image(systemName: mode.systemImage)
                                .tag(mode)
                                .help(mode.title)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 72)
                    .help("List or icon view")

                    Menu {
                        BrowserSortMenuContent(store: windowSort)
                    } label: {
                        Label("Sort By", systemImage: "arrow.up.arrow.down")
                    }
                    .help("Sort By")

                    Button {
                        pane.sendChrome(.toggleSearch)
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .help("Search")
                }
            }
    }
}

/// Folder title for toolbar / tabs — split shows `left | right` with focus emphasis.
private struct SplitFolderTitleLabel: View {
    @Bindable var tab: BrowserTab
    var style: Style = .toolbar
    /// When false (unselected tab), avoid competing emphasis and don't steal clicks for pane focus.
    var allowsPaneFocusClicks: Bool = true

    enum Style {
        case toolbar
        case tab

        var font: Font {
            switch self {
            case .toolbar: return .headline
            case .tab: return .subheadline
            }
        }
    }

    var body: some View {
        if tab.isSplit, tab.panes.count >= 2 {
            HStack(spacing: style == .tab ? 4 : 6) {
                paneName(tab.panes[0])
                Text("|")
                    .font(style.font.weight(.regular))
                    .foregroundStyle(.tertiary)
                paneName(tab.panes[1])
            }
            .lineLimit(1)
            .help(tab.title)
        } else {
            Text(tab.focusedPane.folderDisplayName)
                .font(style.font.weight(style == .toolbar ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .help(tab.focusedPane.navigation.current.path)
        }
    }

    @ViewBuilder
    private func paneName(_ pane: BrowserPane) -> some View {
        let focused = pane.id == tab.focusedPaneID
        // Focused: semibold primary. Unfocused: italic + secondary (readable focus cue).
        let label = Text(pane.folderDisplayName)
            .font(focused ? style.font.weight(.semibold) : style.font.weight(.regular).italic())
            .foregroundStyle(focused ? Color.primary : Color.secondary)
            .lineLimit(1)

        if allowsPaneFocusClicks, tab.isSplit {
            Button {
                tab.focusPane(pane.id)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .help(focused ? pane.navigation.current.path : "Focus \(pane.folderDisplayName)")
        } else {
            label
                .help(pane.navigation.current.path)
        }
    }
}

/// One tab inside the floating island — selected state is a Finder-like inner pill.
private struct TabBarItem: View {
    @Bindable var tab: BrowserTab
    var isSelected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            SplitFolderTitleLabel(
                tab: tab,
                style: .tab,
                allowsPaneFocusClicks: isSelected
            )
            .opacity(isSelected ? 1 : 0.85)
            .frame(maxWidth: .infinity)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .opacity(isHovering || isSelected ? 0.9 : 0)
            .help("Close Tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Capsule(style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.14) : (isHovering ? Color.primary.opacity(0.07) : .clear))
        }
        .contentShape(Capsule(style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(tab.title)
        .animation(.snappy(duration: 0.15), value: isSelected)
        .animation(.snappy(duration: 0.12), value: isHovering)
        .animation(.snappy(duration: 0.15), value: tab.focusedPaneID)
    }
}


#Preview {
    ContentView(rootDirectory: FileManager.default.homeDirectoryForCurrentUser)
}
