import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Finder-like sidebar implemented with ScrollView — **not** SwiftUI `List`.
///
/// `List` / `.sidebar` is backed by `NSOutlineView`, which draws a focus ring that
/// fights the detail file table. Avoiding `List` removes that outline view.
struct SidebarView: View {
    @Bindable var navigation: BrowserNavigation
    @Bindable var favorites: SidebarFavoritesStore
    var dragState: FileDragState

    @State private var draggingFavoriteID: UUID?
    @State private var dropTargetIndex: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader("Favorites")

                ForEach(Array(favorites.items.enumerated()), id: \.element.id) { index, item in
                    favoriteRow(item, index: index)
                }

                // Trailing drop slot so users can drag to the end of the list.
                Color.clear
                    .frame(height: 10)
                    .contentShape(Rectangle())
                    .overlay(alignment: .top) {
                        if dropTargetIndex == favorites.items.count {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(height: 2)
                                .padding(.horizontal, 14)
                        }
                    }
                    .onDrop(
                        of: [.text, .fileURL],
                        delegate: SidebarDropDelegate(
                            index: favorites.items.count,
                            dragState: dragState,
                            draggingFavoriteID: $draggingFavoriteID,
                            dropTargetIndex: $dropTargetIndex,
                            favorites: favorites
                        )
                    )

                sectionHeader("Places")
                    .padding(.top, 12)

                placesRow("Recents", systemImage: "clock")
                placesRow("Volumes", systemImage: "externaldrive")
                placesRow("Git Repositories", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .scrollContentBackground(.hidden)
        .focusEffectDisabled()
        // Clear reorder insertion cue + drag flags when the mouse goes up
        // (cancelled drops often skip `dropExited` / `performDrop`).
        .background {
            DragSessionEndedCleaner {
                draggingFavoriteID = nil
                dropTargetIndex = nil
                dragState.clear()
            }
        }
        .onDrop(
            of: [.fileURL],
            delegate: SidebarSectionFileDropDelegate(
                dragState: dragState,
                favorites: favorites
            )
        )
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .textCase(.uppercase)
    }

    private func favoriteRow(_ item: FavoriteItem, index: Int) -> some View {
        let isCurrent = item.url == navigation.current.standardizedFileURL
        let showInsertion = dropTargetIndex == index && draggingFavoriteID != nil && draggingFavoriteID != item.id

        return Button {
            navigation.go(to: item.url)
        } label: {
            Label(item.displayName, systemImage: item.systemImage)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isCurrent ? Color.primary.opacity(0.08) : Color.clear)
        }
        .overlay(alignment: .top) {
            if showInsertion {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
                    .offset(y: -1)
            }
        }
        .opacity(draggingFavoriteID == item.id ? 0.35 : 1)
        .onDrag {
            draggingFavoriteID = item.id
            return NSItemProvider(object: item.id.uuidString as NSString)
        }
        .onDrop(
            of: [.text, .fileURL],
            delegate: SidebarDropDelegate(
                index: index,
                dragState: dragState,
                draggingFavoriteID: $draggingFavoriteID,
                dropTargetIndex: $dropTargetIndex,
                favorites: favorites
            )
        )
        .contextMenu {
            Button("Remove from Favorites", role: .destructive) {
                favorites.remove(id: item.id)
            }
        }
    }

    private func placesRow(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
    }
}

// MARK: - Drop handling

private struct SidebarDropDelegate: DropDelegate {
    let index: Int
    let dragState: FileDragState
    @Binding var draggingFavoriteID: UUID?
    @Binding var dropTargetIndex: Int?
    let favorites: SidebarFavoritesStore

    func validateDrop(info: DropInfo) -> Bool {
        true
    }

    func dropEntered(info: DropInfo) {
        if draggingFavoriteID != nil || info.hasItemsConforming(to: [.text]) {
            dropTargetIndex = index
        }
    }

    func dropExited(info: DropInfo) {
        if dropTargetIndex == index {
            dropTargetIndex = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if !dragState.urls.isEmpty || info.hasItemsConforming(to: [.fileURL]) {
            // Don't show reorder cue while pinning a folder from the browser.
            dropTargetIndex = nil
            return DropProposal(operation: .copy)
        }
        dropTargetIndex = index
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        // Capture then clear cues immediately so the blue insertion line can't stick.
        let favoriteID = draggingFavoriteID
        let fileURLs = dragState.urls
        dropTargetIndex = nil
        draggingFavoriteID = nil

        if !fileURLs.isEmpty {
            dragState.clear()
            favorites.insert(urls: fileURLs, at: index)
            return true
        }

        if info.hasItemsConforming(to: [.fileURL]) {
            loadFileURLs(from: info.itemProviders(for: [.fileURL])) { urls in
                favorites.insert(urls: urls, at: index)
            }
            return true
        }

        if let favoriteID {
            favorites.relocate(id: favoriteID, to: index)
            return true
        }

        let providers = info.itemProviders(for: [.text])
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String,
                  let id = UUID(uuidString: string)
            else { return }
            DispatchQueue.main.async {
                favorites.relocate(id: id, to: index)
            }
        }
        return true
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

/// Whole-sidebar fallback for file drops that miss a specific row.
private struct SidebarSectionFileDropDelegate: DropDelegate {
    let dragState: FileDragState
    let favorites: SidebarFavoritesStore

    func validateDrop(info: DropInfo) -> Bool {
        !dragState.urls.isEmpty || info.hasItemsConforming(to: [.fileURL])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let urls = dragState.urls
        dragState.clear()
        if !urls.isEmpty {
            favorites.add(urls: urls)
            return true
        }

        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    favorites.add(urls: [url])
                }
            }
        }
        return true
    }
}

/// Clears ephemeral drag UI when a mouse-up ends (or cancels) a drag session.
private struct DragSessionEndedCleaner: NSViewRepresentable {
    var onEnded: () -> Void

    final class Coordinator {
        var monitor: Any?
        var onEnded: () -> Void

        init(onEnded: @escaping () -> Void) {
            self.onEnded = onEnded
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onEnded: onEnded)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.onEnded = onEnded
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
            // Defer so DropDelegate.performDrop can run first.
            DispatchQueue.main.async {
                context.coordinator.onEnded()
            }
            return event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEnded = onEnded
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
