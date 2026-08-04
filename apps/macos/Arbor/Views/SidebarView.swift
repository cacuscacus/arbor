import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Finder-like sidebar implemented with ScrollView — **not** SwiftUI `List`.
///
/// Favorites support live drag previews: surrounding rows slide out of the way
/// before drop, and newly pinned folders appear with a spring insert.
struct SidebarView: View {
    @Bindable var navigation: BrowserNavigation
    @Bindable var favorites: SidebarFavoritesStore
    var dragState: FileDragState

    @State private var draggingFavoriteID: UUID?
    @State private var dropTargetIndex: Int?
    @Namespace private var favoritesNamespace

    private let listSpring = Animation.spring(response: 0.34, dampingFraction: 0.84)
    private let interactiveSpring = Animation.interactiveSpring(response: 0.28, dampingFraction: 0.86)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader("Favorites")

                favoritesList

                // Drop zone after the last real/preview row.
                Color.clear
                    .frame(height: 12)
                    .contentShape(Rectangle())
                    .onDrop(
                        of: [.text, .fileURL],
                        delegate: makeDropDelegate(insertIndex: favorites.items.count)
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
        .background {
            DragSessionEndedCleaner {
                // Delay past DropDelegate.performDrop so insert index / urls
                // aren't cleared mid-drop.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(listSpring) {
                        draggingFavoriteID = nil
                        dropTargetIndex = nil
                    }
                    dragState.clear()
                }
            }
        }
        .onDrop(
            of: [.fileURL],
            delegate: SidebarSectionFileDropDelegate(
                dragState: dragState,
                dropTargetIndex: $dropTargetIndex,
                favorites: favorites,
                animation: listSpring
            )
        )
        .onChange(of: dragState.urls) { _, urls in
            if !urls.isEmpty, dropTargetIndex == nil, draggingFavoriteID == nil {
                withAnimation(interactiveSpring) {
                    dropTargetIndex = favorites.items.count
                }
            }
            if urls.isEmpty, draggingFavoriteID == nil {
                withAnimation(listSpring) {
                    dropTargetIndex = nil
                }
            }
        }
    }

    @ViewBuilder
    private var favoritesList: some View {
        let rows = previewRows
        let insertAt = dropTargetIndex ?? favorites.items.count
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                switch row {
                case .favorite(let item, let sourceIndex, let isLifted):
                    favoriteRow(item, dropIndex: sourceIndex, isLifted: isLifted)
                        .matchedGeometryEffect(id: item.id, in: favoritesNamespace)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading)).combined(with: .offset(y: -6)),
                                removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .leading))
                            )
                        )
                case .ghostAdd(let url):
                    // Ghosts must accept the drop — otherwise it falls through to
                    // the section delegate which always appended at the end.
                    ghostAddRow(url: url)
                        .onDrop(
                            of: [.fileURL],
                            delegate: makeDropDelegate(insertIndex: insertAt)
                        )
                        .transition(
                            .opacity
                                .combined(with: .scale(scale: 0.96, anchor: .leading))
                                .combined(with: .offset(y: -4))
                        )
                }
            }
        }
        .animation(interactiveSpring, value: rows.map(\.animationKey))
    }

    private func makeDropDelegate(insertIndex: Int) -> SidebarDropDelegate {
        SidebarDropDelegate(
            index: insertIndex,
            dragState: dragState,
            draggingFavoriteID: $draggingFavoriteID,
            dropTargetIndex: $dropTargetIndex,
            favorites: favorites,
            animation: interactiveSpring
        )
    }

    /// Live layout shown while dragging: either a provisional reorder, or ghost
    /// slots for folders about to be pinned from the browser.
    private var previewRows: [FavoritePreviewRow] {
        if let dragID = draggingFavoriteID,
           let from = favorites.items.firstIndex(where: { $0.id == dragID })
        {
            let hover = dropTargetIndex ?? from
            var items = favorites.items
            let moved = items.remove(at: from)
            var dest = max(0, min(hover, items.count + 1))
            if from < dest { dest -= 1 }
            dest = max(0, min(dest, items.count))
            items.insert(moved, at: dest)
            return items.map { item in
                let source = favorites.items.firstIndex(where: { $0.id == item.id }) ?? 0
                return .favorite(item, sourceIndex: source, isLifted: item.id == dragID)
            }
        }

        let pending = pendingAddURLs
        if !pending.isEmpty {
            let hover = min(max(dropTargetIndex ?? favorites.items.count, 0), favorites.items.count)
            var rows: [FavoritePreviewRow] = favorites.items.enumerated().map { index, item in
                .favorite(item, sourceIndex: index, isLifted: false)
            }
            rows.insert(contentsOf: pending.map { .ghostAdd($0) }, at: hover)
            return rows
        }

        return favorites.items.enumerated().map { index, item in
            .favorite(item, sourceIndex: index, isLifted: false)
        }
    }

    private var pendingAddURLs: [URL] {
        guard draggingFavoriteID == nil else { return [] }
        let existing = Set(favorites.items.map(\.url.path))
        return dragState.urls
            .map(\.standardizedFileURL)
            .filter { url in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      isDir.boolValue
                else { return false }
                return !existing.contains(url.path)
            }
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

    private func favoriteRow(_ item: FavoriteItem, dropIndex: Int, isLifted: Bool) -> some View {
        let isCurrent = item.url == navigation.current.standardizedFileURL

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
        .scaleEffect(isLifted ? 1.03 : 1.0)
        .opacity(isLifted ? 0.55 : 1)
        .shadow(color: isLifted ? .black.opacity(0.12) : .clear, radius: isLifted ? 6 : 0, y: isLifted ? 2 : 0)
        .zIndex(isLifted ? 1 : 0)
        .onDrag {
            draggingFavoriteID = item.id
            dropTargetIndex = dropIndex
            return NSItemProvider(object: item.id.uuidString as NSString)
        }
        .onDrop(
            of: [.text, .fileURL],
            delegate: makeDropDelegate(insertIndex: dropIndex)
        )
        .contextMenu {
            Button("Remove from Favorites", role: .destructive) {
                withAnimation(listSpring) {
                    favorites.remove(id: item.id)
                }
            }
        }
    }

    private func ghostAddRow(url: URL) -> some View {
        Label(url.lastPathComponent, systemImage: "folder")
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor.opacity(0.08))
                    }
            }
            .opacity(0.95)
    }

    private func placesRow(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
    }
}

// MARK: - Preview model

private enum FavoritePreviewRow: Identifiable {
    case favorite(FavoriteItem, sourceIndex: Int, isLifted: Bool)
    case ghostAdd(URL)

    var id: String {
        switch self {
        case .favorite(let item, _, _):
            return "fav-\(item.id.uuidString)"
        case .ghostAdd(let url):
            return "ghost-\(url.path)"
        }
    }

    var animationKey: String { id }
}

// MARK: - Drop handling

private struct SidebarDropDelegate: DropDelegate {
    let index: Int
    let dragState: FileDragState
    @Binding var draggingFavoriteID: UUID?
    @Binding var dropTargetIndex: Int?
    let favorites: SidebarFavoritesStore
    let animation: Animation

    func validateDrop(info: DropInfo) -> Bool {
        true
    }

    func dropEntered(info: DropInfo) {
        withAnimation(animation) {
            dropTargetIndex = index
        }
    }

    func dropExited(info: DropInfo) {
        // Keep last hover; mouse-up cleaner resets.
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        withAnimation(animation) {
            dropTargetIndex = index
        }
        if !dragState.urls.isEmpty || info.hasItemsConforming(to: [.fileURL]),
           draggingFavoriteID == nil
        {
            return DropProposal(operation: .copy)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        // Capture before any cleaner / async work can wipe state.
        let favoriteID = draggingFavoriteID
        let fileURLs = dragState.urls
        let committedIndex = dropTargetIndex ?? index

        withAnimation(animation) {
            dropTargetIndex = nil
            draggingFavoriteID = nil
        }

        if !fileURLs.isEmpty {
            dragState.clear()
            withAnimation(animation) {
                _ = favorites.insert(urls: fileURLs, at: committedIndex)
            }
            return true
        }

        if info.hasItemsConforming(to: [.fileURL]) {
            loadFileURLs(from: info.itemProviders(for: [.fileURL])) { urls in
                withAnimation(animation) {
                    _ = favorites.insert(urls: urls, at: committedIndex)
                }
            }
            return true
        }

        if let favoriteID {
            withAnimation(animation) {
                favorites.relocate(id: favoriteID, to: committedIndex)
            }
            return true
        }

        let providers = info.itemProviders(for: [.text])
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String,
                  let id = UUID(uuidString: string)
            else { return }
            DispatchQueue.main.async {
                withAnimation(animation) {
                    favorites.relocate(id: id, to: committedIndex)
                }
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

private struct SidebarSectionFileDropDelegate: DropDelegate {
    let dragState: FileDragState
    @Binding var dropTargetIndex: Int?
    let favorites: SidebarFavoritesStore
    let animation: Animation

    func validateDrop(info: DropInfo) -> Bool {
        !dragState.urls.isEmpty || info.hasItemsConforming(to: [.fileURL])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        // Honor the live preview index — previously this always appended.
        let committedIndex = dropTargetIndex ?? favorites.items.count
        let urls = dragState.urls
        dragState.clear()

        if !urls.isEmpty {
            withAnimation(animation) {
                _ = favorites.insert(urls: urls, at: committedIndex)
            }
            withAnimation(animation) { dropTargetIndex = nil }
            return true
        }

        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var loaded: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                defer { group.leave() }
                guard let url else { return }
                lock.lock()
                loaded.append(url)
                lock.unlock()
            }
        }
        group.notify(queue: .main) {
            withAnimation(animation) {
                _ = favorites.insert(urls: loaded, at: committedIndex)
                dropTargetIndex = nil
            }
        }
        return true
    }
}

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
