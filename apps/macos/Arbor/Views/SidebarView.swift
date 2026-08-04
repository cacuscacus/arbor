import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct SidebarView: View {
    @Bindable var navigation: BrowserNavigation
    @Bindable var favorites: SidebarFavoritesStore
    var dragState: FileDragState

    private var selection: Binding<FavoriteItem.ID?> {
        Binding(
            get: {
                favorites.items.first(where: {
                    $0.url == navigation.current.standardizedFileURL
                })?.id
            },
            set: { newValue in
                guard let newValue,
                      let item = favorites.items.first(where: { $0.id == newValue })
                else { return }
                navigation.go(to: item.url)
            }
        )
    }

    var body: some View {
        // Keep this a plain system sidebar List.
        // Avoid `.backgroundExtensionEffect()` here — on Tahoe it can draw the
        // list as a separate inset glass plate (visible edge + top seam).
        List(selection: selection) {
            Section("Favorites") {
                ForEach(favorites.items) { item in
                    Label(item.displayName, systemImage: item.systemImage)
                        .tag(item.id)
                        .contextMenu {
                            Button("Remove from Favorites", role: .destructive) {
                                favorites.remove(id: item.id)
                            }
                        }
                }
                .onMove(perform: favorites.move)
                .onInsert(of: [.fileURL], perform: insertFavorites)
            }

            Section("Places") {
                Label("Recents", systemImage: "clock")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
                Label("Volumes", systemImage: "externaldrive")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
                Label("Git Repositories", systemImage: "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        }
        .listStyle(.sidebar)
        // SwiftUI focus effects aren't enough — AppKit's NSOutlineView still
        // draws a focus ring around the whole list when it becomes key.
        .background(SidebarOutlineFocusRingRemover())
        .focusEffectDisabled()
        .overlay {
            if !dragState.urls.isEmpty {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1.5)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    private func insertFavorites(at index: Int, providers: [NSItemProvider]) {
        let dragged = dragState.urls
        if !dragged.isEmpty {
            dragState.clear()
            favorites.insert(urls: dragged, at: index)
            return
        }

        loadFileURLs(from: providers) { urls in
            favorites.insert(urls: urls, at: index)
        }
    }

    private func loadFileURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let value = item as? URL {
                    url = value
                } else {
                    url = nil
                }
                guard let url else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            completion(urls)
        }
    }
}

/// Walks up from an embedded SwiftUI host view and clears AppKit focus rings
/// on the sidebar outline / scroll view.
private struct SidebarOutlineFocusRingRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.isHidden = true
        DispatchQueue.main.async {
            Self.stripFocusRings(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            Self.stripFocusRings(from: nsView)
        }
    }

    private static func stripFocusRings(from view: NSView) {
        var current: NSView? = view
        while let node = current {
            node.focusRingType = .none
            if let scroll = node as? NSScrollView {
                scroll.focusRingType = .none
                scroll.borderType = .noBorder
                scroll.drawsBackground = false
                (scroll.documentView as? NSView)?.focusRingType = .none
            }
            if let table = node as? NSTableView {
                table.focusRingType = .none
            }
            current = node.superview
        }
    }
}

#Preview("Sidebar") {
    NavigationSplitView {
        SidebarView(
            navigation: BrowserNavigation(),
            favorites: SidebarFavoritesStore(),
            dragState: FileDragState()
        )
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
    } detail: {
        Text("Detail")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(width: 900, height: 560)
}
