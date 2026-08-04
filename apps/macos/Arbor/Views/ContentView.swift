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
        .focusedSceneValue(\.activeBrowserTab, selectedTab)
        .background {
            tabShortcuts
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
            VStack(spacing: 0) {
                // Finder keeps the sidebar full-height; tabs sit only above the file list.
                detailTabBar

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

    /// Content-column tab strip: selected pill + trailing new-tab control (Finder-like).
    private var detailTabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs) { tab in
                        TabBarItem(
                            tab: tab,
                            isSelected: tab.id == selectedTabID,
                            onSelect: { selectedTabID = tab.id },
                            onClose: { closeTab(id: tab.id) }
                        )
                    }
                }
                .padding(.leading, 10)
                .padding(.vertical, 6)
            }

            Button(action: openNewTab) {
                Image(systemName: "plus")
                    .font(.body.weight(.medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .help("New Tab")
            .padding(.trailing, 10)
            .padding(.leading, 4)
        }
        .background {
            // Stay visually in the detail surface — avoid a full-width `.bar` that
            // chops the Liquid Glass sidebar / toolbar.
            Rectangle()
                .fill(.clear)
                .background(.ultraThinMaterial.opacity(0.35))
        }
        .overlay(alignment: .bottom) {
            Divider().opacity(0.55)
        }
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
                            isActive: isActive && tab.focusedPaneID == pane.id
                        )
                    }
                }
            } else if let pane = tab.panes.first {
                PaneBrowserHost(
                    tab: tab,
                    pane: pane,
                    favorites: favorites,
                    dragState: dragState,
                    isActive: isActive
                )
            }
        }
    }
}

private struct PaneBrowserHost: View {
    @Bindable var tab: BrowserTab
    @Bindable var pane: BrowserPane
    @Bindable var favorites: SidebarFavoritesStore
    var dragState: FileDragState
    var isActive: Bool

    var body: some View {
        FileBrowserView(
            navigation: pane.navigation,
            favorites: favorites,
            dragState: dragState,
            isActive: isActive,
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

/// Single tab control in the detail-column tab strip (Finder-like pill).
private struct TabBarItem: View {
    @Bindable var tab: BrowserTab
    var isSelected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(tab.title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(isHovering || isSelected ? 0.85 : 0)
            .help("Close Tab")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background {
            Capsule(style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.12) : (isHovering ? Color.primary.opacity(0.06) : .clear))
        }
        .contentShape(Capsule(style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(tab.navigation.current.path)
        .animation(.snappy(duration: 0.15), value: isSelected)
        .animation(.snappy(duration: 0.12), value: isHovering)
    }
}

#Preview {
    ContentView(rootDirectory: FileManager.default.homeDirectoryForCurrentUser)
}
