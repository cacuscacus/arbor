import SwiftUI

/// Root layout: sidebar + file browser. Wired to Rust via FFI in a later pass.
struct ContentView: View {
    @State private var navigation = BrowserNavigation()
    @State private var favorites = SidebarFavoritesStore()
    @State private var dragState = FileDragState()
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                navigation: navigation,
                favorites: favorites,
                dragState: dragState
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            FileBrowserView(
                navigation: navigation,
                favorites: favorites,
                dragState: dragState
            )
        }
        // Automatic style picks up Liquid Glass sidebar on Tahoe.
        .navigationSplitViewStyle(.automatic)
        .background(WindowChromeConfigurator())
        .focusEffectDisabled()
    }
}

#Preview {
    ContentView()
}
