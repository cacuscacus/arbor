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
    var onOpenInSplit: ((ItemRef) -> Void)? = nil
    /// Moves/copies dropped files into a favorite folder. Returns an error
    /// message when part of the transfer failed.
    var onTransferFiles: (([ItemRef], ItemRef, FileTransferOperation) async -> String?)?

    @State private var draggingFavoriteID: UUID?
    @State private var dropTargetIndex: Int?
    /// Favorite row highlighted as a *transfer* target (files dropped on it).
    @State private var transferTargetID: UUID?
    @State private var transferErrorMessage: String?
    @State private var sshLocations = SSHLocationStore.shared
    @State private var volumesStore = MountedVolumesStore.shared
    @State private var showingSSHLocationSheet = false
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

                locationsHeader
                    .padding(.top, 12)

                ForEach(volumesStore.volumes) { volume in
                    volumeRow(volume)
                }

                ForEach(sshLocations.locations) { profile in
                    sshLocationRow(profile)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .scrollContentBackground(.hidden)
        .focusEffectDisabled()
        .sheet(isPresented: $showingSSHLocationSheet) {
            SSHLocationSheet(store: sshLocations) { root in
                navigation.go(to: root)
            }
        }
        .alert(
            "Could not move items",
            isPresented: Binding(
                get: { transferErrorMessage != nil },
                set: { if !$0 { transferErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { transferErrorMessage = nil }
        } message: {
            Text(transferErrorMessage ?? "")
        }
        .background {
            DragSessionEndedCleaner {
                // Delay past DropDelegate.performDrop so insert index / urls
                // aren't cleared mid-drop.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(listSpring) {
                        draggingFavoriteID = nil
                        dropTargetIndex = nil
                        transferTargetID = nil
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
        .onChange(of: dragState.items) { _, items in
            if !items.isEmpty, dropTargetIndex == nil, draggingFavoriteID == nil {
                withAnimation(interactiveSpring) {
                    dropTargetIndex = favorites.items.count
                }
            }
            if items.isEmpty, draggingFavoriteID == nil {
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

    private func makeFavoriteDropDelegate(
        item: FavoriteItem,
        insertIndex: Int
    ) -> SidebarFavoriteDropDelegate {
        SidebarFavoriteDropDelegate(
            destination: item,
            index: insertIndex,
            dragState: dragState,
            draggingFavoriteID: $draggingFavoriteID,
            dropTargetIndex: $dropTargetIndex,
            transferTargetID: $transferTargetID,
            transferErrorMessage: $transferErrorMessage,
            favorites: favorites,
            animation: interactiveSpring,
            onTransferFiles: onTransferFiles
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
        guard draggingFavoriteID == nil, transferTargetID == nil else { return [] }
        let existing = Set(favorites.items.map(\.itemRef))
        let result = dragState.items
            .filter { !existing.contains($0) }
            .compactMap {
                FileProviderRegistry.shared.intrinsicLocalURL(for: $0)
            }
            .filter { url in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      isDir.boolValue
                else { return false }
                return true
            }
        #if DEBUG
        SidebarDropDebug.log("items=\(dragState.items.map(\.path)) pending=\(result.map(\.path))")
        #endif
        return result
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

    private var locationsHeader: some View {
        HStack {
            Text("Locations")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            Button {
                showingSSHLocationSheet = true
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .help("Add SSH Location…")
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private func sshLocationRow(_ profile: SSHLocationProfile) -> some View {
        let isCurrent = profile.root == navigation.current
        return Button {
            navigation.go(to: profile.root)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.displayName)
                        .lineLimit(1)
                    Text(profile.endpoint.displayDestination)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
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
        .contextMenu {
            Button("Open in New Window") {
                WindowLaunchCoordinator.openNewWindow(cloning: profile.root)
            }
            if let onOpenInSplit {
                Button("Open in Split") {
                    onOpenInSplit(profile.root)
                }
            }
            Divider()
            Button("Remove SSH Location", role: .destructive) {
                sshLocations.remove(id: profile.id)
            }
        }
    }

    private func favoriteRow(_ item: FavoriteItem, dropIndex: Int, isLifted: Bool) -> some View {
        let isCurrent = item.itemRef == navigation.current
        let isTransferTarget = transferTargetID == item.id

        return Button {
            navigation.go(to: item.itemRef)
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
                .fill(
                    isTransferTarget
                        ? Color.accentColor.opacity(0.18)
                        : (isCurrent ? Color.primary.opacity(0.08) : Color.clear)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isTransferTarget ? Color.accentColor.opacity(0.7) : Color.clear,
                            lineWidth: 1
                        )
                }
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
            delegate: makeFavoriteDropDelegate(item: item, insertIndex: dropIndex)
        )
        .contextMenu {
            Button("Open in New Window") {
                WindowLaunchCoordinator.openNewWindow(cloning: item.itemRef)
            }
            if let onOpenInSplit {
                Button("Open in Split") {
                    onOpenInSplit(item.itemRef)
                }
            }
            if FileProviderRegistry.shared.intrinsicLocalURL(for: item.itemRef) != nil {
                Button("Open Terminal Here") {
                    WorkspaceActions.openTerminal(
                        context: ExecutionContext(workingDirectory: item.itemRef)
                    )
                }
                .help("Opens Terminal.app in this folder")
                Button("Run Agent Here…") {
                    AgentRunCoordinator.shared.presentRunAgent(
                        context: ExecutionContext(workingDirectory: item.itemRef)
                    )
                }
                Button("Open in Cursor") {
                    WorkspaceActions.openInCursor(at: item.itemRef)
                }
            }
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

    private func volumeRow(_ volume: MountedVolume) -> some View {
        let isCurrent = volume.itemRef == navigation.current
        return HStack(spacing: 4) {
            Button {
                navigation.go(to: volume.itemRef)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: volume.systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(volume.name)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if volume.canEject {
                Button {
                    ejectVolume(volume)
                } label: {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Eject \(volume.name)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isCurrent ? Color.primary.opacity(0.08) : Color.clear)
        }
        .help(volumeHelp(volume))
        .contextMenu {
            Button("Open in New Window") {
                WindowLaunchCoordinator.openNewWindow(cloning: volume.itemRef)
            }
            if let onOpenInSplit {
                Button("Open in Split") {
                    onOpenInSplit(volume.itemRef)
                }
            }
            if volume.canEject {
                Divider()
                Button("Eject \"\(volume.name)\"") {
                    ejectVolume(volume)
                }
            }
        }
    }

    private func volumeHelp(_ volume: MountedVolume) -> String {
        if let free = volume.availableCapacity {
            let formatted = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            return "\(volume.url.path) — \(formatted) available"
        }
        return volume.url.path
    }

    private func ejectVolume(_ volume: MountedVolume) {
        let wasInsideVolume = navigation.current.path.hasPrefix(volume.url.path) && volume.url.path != "/"
        Task {
            do {
                try await volumesStore.eject(volume)
                if wasInsideVolume {
                    navigation.go(to: LocalFileLocation.item(for: FileManager.default.homeDirectoryForCurrentUser))
                }
            } catch {
                transferErrorMessage = "Could not eject \(volume.name): \(error.localizedDescription)"
            }
        }
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
        DragAutoScrollController.shared.noteDropHover()
        withAnimation(animation) {
            dropTargetIndex = index
        }
        if !dragState.items.isEmpty || info.hasItemsConforming(to: [.fileURL]),
           draggingFavoriteID == nil
        {
            return DropProposal(operation: .copy)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        DragAutoScrollController.shared.endDragSession()
        // Capture before any cleaner / async work can wipe state.
        let favoriteID = draggingFavoriteID
        let fileItems = dragState.items
        let committedIndex = dropTargetIndex ?? index

        withAnimation(animation) {
            dropTargetIndex = nil
            draggingFavoriteID = nil
        }

        if !fileItems.isEmpty {
            dragState.clear()
            withAnimation(animation) {
                _ = favorites.insert(items: fileItems, at: committedIndex)
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

/// Drop behavior for one favorite row.
///
/// Two different gestures land here:
/// - dragging a favorite (the row's drag payload is a UUID string) reorders
///   the list, exactly like dropping in the gaps;
/// - dragging files (from the browser or another app) moves/copies them into
///   that favorite's folder, like dropping onto a folder in Finder.
private struct SidebarFavoriteDropDelegate: DropDelegate {
    let destination: FavoriteItem
    let index: Int
    let dragState: FileDragState
    @Binding var draggingFavoriteID: UUID?
    @Binding var dropTargetIndex: Int?
    @Binding var transferTargetID: UUID?
    @Binding var transferErrorMessage: String?
    let favorites: SidebarFavoritesStore
    let animation: Animation
    let onTransferFiles: (([ItemRef], ItemRef, FileTransferOperation) async -> String?)?

    /// Favorites are dragged as text; anything else here is a file drag.
    private var isFileDrag: Bool { draggingFavoriteID == nil }

    private var reorderDelegate: SidebarDropDelegate {
        SidebarDropDelegate(
            index: index,
            dragState: dragState,
            draggingFavoriteID: $draggingFavoriteID,
            dropTargetIndex: $dropTargetIndex,
            favorites: favorites,
            animation: animation
        )
    }

    private func carriesFiles(_ info: DropInfo) -> Bool {
        !dragState.items.isEmpty || info.hasItemsConforming(to: [.fileURL])
    }

    private func decision(_ info: DropInfo) -> SidebarDropDecision {
        SidebarDropRouting.decision(
            isDraggingFavorite: !isFileDrag,
            carriesFiles: carriesFiles(info),
            canTransfer: onTransferFiles != nil
        )
    }

    func validateDrop(info: DropInfo) -> Bool {
        if decision(info) == .transferFiles {
            return true
        }
        return reorderDelegate.validateDrop(info: info)
    }

    func dropEntered(info: DropInfo) {
        if decision(info) == .transferFiles {
            withAnimation(animation) {
                transferTargetID = destination.id
                dropTargetIndex = nil
            }
            return
        }
        reorderDelegate.dropEntered(info: info)
    }

    func dropExited(info: DropInfo) {
        if transferTargetID == destination.id {
            withAnimation(animation) { transferTargetID = nil }
            return
        }
        reorderDelegate.dropExited(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DragAutoScrollController.shared.noteDropHover()
        if decision(info) == .transferFiles, transferTargetID == destination.id {
            return DropProposal(operation: FileTransferOperation.fromModifierFlags.dropOperation)
        }
        return reorderDelegate.dropUpdated(info: info)
    }

    func performDrop(info: DropInfo) -> Bool {
        DragAutoScrollController.shared.endDragSession()
        if decision(info) == .transferFiles {
            transferTargetID = nil
            let operation = FileTransferOperation.fromModifierFlags
            let items = dragState.items
            dragState.clear()

            if !items.isEmpty {
                let filtered = items.filter { $0 != destination.itemRef }
                guard !filtered.isEmpty else { return true }
                Task { @MainActor in
                    if let message = await onTransferFiles?(filtered, destination.itemRef, operation) {
                        transferErrorMessage = message
                    }
                }
                return true
            }

            let providers = info.itemProviders(for: [.fileURL])
            guard !providers.isEmpty else { return false }
            Task { @MainActor in
                let refs = await Self.loadItemRefs(from: providers)
                    .filter { $0 != destination.itemRef }
                guard !refs.isEmpty else { return }
                if let message = await onTransferFiles?(refs, destination.itemRef, operation) {
                    transferErrorMessage = message
                }
            }
            return true
        }
        return reorderDelegate.performDrop(info: info)
    }

    private static func loadItemRefs(from providers: [NSItemProvider]) async -> [ItemRef] {
        await withCheckedContinuation { continuation in
            let group = DispatchGroup()
            let lock = NSLock()
            var refs: [ItemRef] = []
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    defer { group.leave() }
                    guard let url else { return }
                    lock.lock()
                    refs.append(LocalFileLocation.item(for: url))
                    lock.unlock()
                }
            }
            group.notify(queue: .main) {
                continuation.resume(returning: refs)
            }
        }
    }
}

private struct SidebarSectionFileDropDelegate: DropDelegate {
    let dragState: FileDragState
    @Binding var dropTargetIndex: Int?
    let favorites: SidebarFavoritesStore
    let animation: Animation

    func validateDrop(info: DropInfo) -> Bool {
        !dragState.items.isEmpty || info.hasItemsConforming(to: [.fileURL])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DragAutoScrollController.shared.noteDropHover()
        return DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        DragAutoScrollController.shared.endDragSession()
        // Honor the live preview index — previously this always appended.
        let committedIndex = dropTargetIndex ?? favorites.items.count
        let items = dragState.items
        dragState.clear()

        if !items.isEmpty {
            withAnimation(animation) {
                _ = favorites.insert(items: items, at: committedIndex)
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


#if DEBUG
enum SidebarDropDebug {
    static func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/arbor-sidebar-debug.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else { try? data.write(to: url) }
    }
}
#endif
