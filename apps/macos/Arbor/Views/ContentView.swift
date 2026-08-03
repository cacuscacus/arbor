import SwiftUI

/// Root layout: sidebar + file browser. Wired to Rust via FFI in a later pass.
struct ContentView: View {
    @State private var selectedPath: URL = FileManager.default.homeDirectoryForCurrentUser
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedPath: $selectedPath)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            FileBrowserView(path: $selectedPath)
        }
    }
}

#Preview {
    ContentView()
}
