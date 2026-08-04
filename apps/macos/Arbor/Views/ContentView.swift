import AppKit
import SwiftUI

/// Root layout: tab bar + sidebar + file browser (optional horizontal split per tab).
/// Wired to Rust via FFI in a later pass.
struct ContentView: View {
    @State private var tabs: [BrowserTab]
    @State private var selectedTabID: BrowserTab.ID
    @State private var favorites = SidebarFavoritesStore.shared
    @State private var dragState = FileDragState()
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    init(rootDirectory: URL? = nil) {
        let root = rootDirectory ?? WindowLaunchCoordinator.dequeueRoot()
        let tab = BrowserTab(root: root)
        _tabs = State(initialValue: [tab])
        _selectedTabID = State(initialValue: tab.id)
    }

    private var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar

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
            }
            // Automatic style picks up Liquid Glass sidebar on Tahoe.
            .navigationSplitViewStyle(.automatic)
        }
        .background(WindowChromeConfigurator())
        .focusEffectDisabled()
        .focusedSceneValue(\.activeBrowserTab, selectedTab)
        .background {
            tabShortcuts
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs) { tab in
                        TabBarItem(
                            tab: tab,
                            isSelected: tab.id == selectedTabID,
                            onSelect: { selectedTabID = tab.id },
                            onClose: { closeTab(id: tab.id) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }

            Button(action: openNewTab) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New Tab")
            .padding(.trailing, 8)
        }
        .frame(minHeight: 34)
        .background(.bar)
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

/// Single tab pill in the window tab bar.
private struct TabBarItem: View {
    @Bindable var tab: BrowserTab
    var isSelected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.caption2)
                .foregroundStyle(isSelected ? .primary : .secondary)

            Text(tab.title)
                .font(.callout)
                .lineLimit(1)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .opacity(isHovering || isSelected ? 0.7 : 0)
            .help("Close Tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.10) : (isHovering ? Color.primary.opacity(0.05) : .clear))
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(tab.navigation.current.path)
    }
}

#Preview {
    ContentView(rootDirectory: FileManager.default.homeDirectoryForCurrentUser)
}
