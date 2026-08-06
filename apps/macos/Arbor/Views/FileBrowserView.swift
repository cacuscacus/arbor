import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserView: View {
    @Bindable var pane: BrowserPane
    @Bindable var favorites: SidebarFavoritesStore
    var dragState: FileDragState
    /// When multiple tab / split browsers stay mounted, only the focused pane publishes scene focus values.
    var isActive: Bool = true
    /// Tab is selected (both split panes can be visible). Drives live directory watching.
    var isVisible: Bool = true
    /// Opens a folder in the other split pane (creates a split if needed).
    var onOpenInSplit: ((URL) -> Void)? = nil

    private var navigation: BrowserNavigation { pane.navigation }
    private var displaySettings: BrowserDisplaySettings { pane.displaySettings }
    private var undoStack: ArborUndoStack { pane.undoStack }

    @State private var entries: [FileEntry] = []
    @State private var selection = Set<URL>()
    @State private var sortOrder: [KeyPathComparator<FileEntry>] = [
        .init(\.name, comparator: .localizedStandard),
    ]
    @State private var errorMessage: String?
    @State private var details: FileDetails?
    @State private var multiInfo: MultiSelectionInfo?
    @State private var transferErrorTitle = "Transfer Failed"
    @State private var transferErrorMessage: String?
    @State private var createDialog: CreateItemDialog?
    @State private var newItemName = ""
    @State private var createErrorMessage: String?
    @State private var undoErrorMessage: String?
    @State private var renamingURL: URL?
    @State private var renameDraft = ""
    @State private var renameErrorMessage: String?
    @State private var selectionMarkedAt = Date.distantPast

    @State private var searchQuery = ""
    @State private var searchScope: SearchScope = .currentFolder
    @State private var searchHits: [SearchHit] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearchPresented = false

    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool

    private var path: URL { navigation.current }

    private var isSearchActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showsSearchPanel: Bool {
        isSearchPresented || isSearchActive
    }

    private var relativeRoot: URL {
        switch searchScope {
        case .currentFolder:
            return path
        case .global:
            return FileManager.default.homeDirectoryForCurrentUser
        }
    }

    private var visibleEntries: [FileEntry] {
        let base: [FileEntry] = {
            if isSearchActive {
                return searchHits.map { $0.asFileEntry() }
            }
            return entries
        }()
        return base.sorted(using: sortOrder)
    }

    var body: some View {
        browserScaffold
            .modifier(FileBrowserAlertsModifier(
                transferErrorTitle: transferErrorTitle,
                transferErrorMessage: $transferErrorMessage,
                createDialog: $createDialog,
                newItemName: $newItemName,
                createErrorMessage: $createErrorMessage,
                undoErrorMessage: $undoErrorMessage,
                renameErrorMessage: $renameErrorMessage,
                onConfirmCreate: confirmCreateItem
            ))
    }

    private var browserScaffold: some View {
        VStack(spacing: 0) {
            // Keep content swaps (browse ↔ search results) inside this slot so the
            // floating search overlay is NOT recreated with them — that was
            // stealing TextField focus after the first character.
            // `.id(path)` remounts the scroller at the system resting top when the
            // folder changes (Finder-like), without forcing raw NSScrollView y=0.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(isSearchActive ? "search:\(searchScope)" : path.path)

            if !isSearchActive {
                Divider()
                BreadcrumbBar(
                    path: path,
                    dragState: dragState,
                    onNavigate: { target in navigate(to: target) },
                    onTransfer: handleTransfer
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsSearchPanel {
                floatingSearchPanel
                    .padding(.top, 10)
                    .padding(.trailing, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.18), value: isSearchPresented && !isSearchActive)
        // Same system soft underlap the toolbar uses in non-split (Case 1). Applied on
        // the browser root + enabled on underlying NSScrollViews so trailing HSplit
        // columns get the effect too (AppKit often skips it without a vertical scroller).
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(ScrollEdgeEffectEnabler())
        .background {
            // Finder-like Back/Forward scroll memory (skip while search results are shown).
            if !isSearchActive {
                FolderScrollPositionBridge(
                    scrollY: Binding(
                        get: { navigation.scrollY },
                        set: { navigation.noteScrollY($0) }
                    ),
                    restoreToken: navigation.scrollRestoreToken,
                    consumeRestore: { navigation.consumePendingScrollRestore() }
                )
            }
        }
        // Window toolbar / title live on `TabDetailView` (outside HSplitView) so Liquid
        // Glass stays consistent across split panes. This view only reacts to chrome cmds.
        .modifier(FileBrowserFocusedSceneModifier(
            isActive: isActive,
            displaySettings: displaySettings,
            folderURL: navigation.current
        ))
        .onChange(of: pane.chromeCommandToken) { _, _ in
            guard isActive, let command = pane.consumeChromeCommand() else { return }
            handleChromeCommand(command)
        }
        .onChange(of: navigation.current, initial: true) { _, url in
            guard isActive else { return }
            WindowLaunchCoordinator.noteFocusedFolder(url)
        }
        .onChange(of: isActive) { _, active in
            if active {
                WindowLaunchCoordinator.noteFocusedFolder(navigation.current)
                if !isSearchPresented {
                    listFocused = true
                }
            }
        }
        .onAppear {
            reload()
            if isActive, !isSearchPresented {
                listFocused = true
            }
        }
        .background {
            FolderListingWatchActivator(
                path: (isVisible && !isSearchActive) ? path : nil
            ) {
                reload()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Cheap catch-up if a DispatchSource event was missed while unfocused.
            guard isVisible, !isSearchActive else { return }
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: BrowserListingDidChange.name)) { note in
            handleRemoteListingChange(BrowserListingDidChange.folders(from: note))
        }
        .onChange(of: navigation.current) { _, _ in
            cancelRename()
            selection = []
            if searchScope == .currentFolder, isSearchActive {
                scheduleSearch()
            } else if !isSearchActive {
                reload()
            }
            if !searchFocused && !isSearchPresented {
                listFocused = true
            }
        }
        .onChange(of: selection) { _, _ in
            selectionMarkedAt = Date()
            if let renamingURL, !selection.contains(renamingURL) {
                cancelRename()
            }
        }
        .onChange(of: searchQuery) { _, _ in
            scheduleSearch()
        }
        .onChange(of: searchScope) { _, _ in
            if isSearchActive {
                scheduleSearch()
            }
        }
        .sheet(item: $details) { info in
            FileDetailsView(details: info)
        }
        .sheet(item: $multiInfo) { info in
            MultiSelectionInfoView(info: info)
        }
        .background {
            shortcutButtons
        }
        .onKeyPress(keys: [.escape], phases: .down) { _ in
            guard isActive else { return .ignored }
            if renamingURL != nil {
                cancelRename()
                return .handled
            }
            if isSearchActive || searchFocused || isSearchPresented {
                dismissSearch()
                return .handled
            }
            if !selection.isEmpty {
                selection = []
                return .handled
            }
            return .ignored
        }
        .onKeyPress(keys: [.init("/")], phases: .down) { _ in
            guard isActive else { return .ignored }
            if searchFocused { return .ignored }
            presentSearch()
            return .handled
        }
        .onKeyPress(.return) {
            guard isActive else { return .ignored }
            if renamingURL != nil || searchFocused { return .ignored }
            return openSelection()
        }
        .onKeyPress(.delete) {
            guard isActive else { return .ignored }
            if renamingURL != nil || searchFocused { return .ignored }
            return moveSelectionToTrash()
        }
        // Keep keyboard focus for shortcuts, but never draw the accent focus ring
        // (it shows up as random light-blue lines, especially while resizing).
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
    }

    private var floatingSearchPanel: some View {
        SearchBarView(
            query: $searchQuery,
            scope: $searchScope,
            isSearching: isSearching,
            resultCount: isSearchActive ? searchHits.count : nil,
            focus: $searchFocused,
            onDismiss: dismissSearch
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    @ViewBuilder
    private var shortcutButtons: some View {
        if isActive {
            Group {
                Button("") { presentSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)

                Button("") { selectAllVisible() }
                    .keyboardShortcut("a", modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)

                Button("") { goToParent() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)

                Button("") { performUndo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)

                Button("") { performRedo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .opacity(0)
                    .allowsHitTesting(false)

                Button("") { goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)

                Button("") { goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)

                Button("") { _ = moveSelectionToTrash() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .opacity(0)
                    .allowsHitTesting(false)
            }
        }
    }

    private func handleChromeCommand(_ command: BrowserPaneChromeCommand) {
        switch command {
        case .back:
            goBack()
        case .forward:
            goForward()
        case .undo:
            performUndo()
        case .redo:
            performRedo()
        case .toggleSearch:
            if isSearchPresented && !isSearchActive {
                dismissSearch()
            } else {
                presentSearch()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let searchError, isSearchActive {
            ContentUnavailableView(
                "Search failed",
                systemImage: "exclamationmark.magnifyingglass",
                description: Text(searchError)
            )
        } else if isSearchActive {
            searchBody
        } else if let errorMessage {
            ContentUnavailableView(
                "Could not open folder",
                systemImage: "folder.badge.questionmark",
                description: Text(errorMessage)
            )
        } else if entries.isEmpty {
            ContentUnavailableView(
                "Empty folder",
                systemImage: "folder",
                description: Text(path.path)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .contextMenu { emptySpaceContextMenu }
            .onDrop(
                of: [.fileURL],
                delegate: FolderDropDelegate(
                    destination: path,
                    dragState: dragState,
                    isTargeted: nil,
                    onTransfer: handleTransfer
                )
            )
        } else {
            browserBody(entries: visibleEntries, showsLocation: false)
        }
    }

    @ViewBuilder
    private var searchBody: some View {
        if isSearching && searchHits.isEmpty {
            ProgressView("Searching…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searchHits.isEmpty {
            ContentUnavailableView(
                "No results",
                systemImage: "magnifyingglass",
                description: Text(emptySearchDescription)
            )
        } else {
            browserBody(entries: visibleEntries, showsLocation: true)
        }
    }

    @ViewBuilder
    private func browserBody(entries: [FileEntry], showsLocation: Bool) -> some View {
        switch displaySettings.viewMode {
        case .list:
            FileTableView(
                entries: entries,
                selection: $selection,
                sortOrder: $sortOrder,
                renamingURL: $renamingURL,
                renameDraft: $renameDraft,
                settings: displaySettings,
                relativeRoot: isSearchActive ? relativeRoot : path,
                currentFolder: isSearchActive ? nil : path,
                showsLocation: showsLocation,
                dragState: dragState,
                onOpenRow: { entry in
                    cancelRename()
                    openDoubleClicked(entry)
                },
                onTransfer: handleTransfer,
                onRequestRename: handleNameClick,
                onCommitRename: commitRename,
                onCancelRename: cancelRename,
                contextMenu: { entry in entryContextMenu(anchor: entry) },
                emptySpaceMenu: { emptySpaceContextMenu }
            )
        case .icons:
            FileIconView(
                entries: entries,
                selection: $selection,
                renamingURL: $renamingURL,
                renameDraft: $renameDraft,
                iconMetrics: displaySettings.iconMetrics,
                currentFolder: isSearchActive ? nil : path,
                dragState: dragState,
                onOpen: { entry in
                    cancelRename()
                    openDoubleClicked(entry)
                },
                onTransfer: handleTransfer,
                onRequestRename: handleNameClick,
                onCommitRename: commitRename,
                onCancelRename: cancelRename,
                contextMenu: { entry in entryContextMenu(anchor: entry) },
                emptySpaceMenu: { emptySpaceContextMenu }
            )
        }
    }

    @ViewBuilder
    private var emptySpaceContextMenu: some View {
        if !isSearchActive {
            Button("New Folder…") {
                beginCreateItem(.folder)
            }
            Button("New Empty File…") {
                beginCreateItem(.file)
            }
            Divider()
            Button("Run Agent Here…") {
                AgentRunCoordinator.shared.presentRunAgent(folder: path)
            }
            Button("Open in Cursor") {
                WorkspaceActions.openInCursor(at: path)
            }
        }
    }

    private var emptySearchDescription: String {
        switch searchScope {
        case .currentFolder:
            return "No matches in \(path.lastPathComponent)"
        case .global:
            return "No matches in your home folder"
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func entryContextMenu(anchor: FileEntry) -> some View {
        let targets = previewTargets(for: anchor)

        Button(targets.count == 1 ? "Open" : "Open \(targets.count) Items") {
            commitContextSelection(anchor: anchor)
            openTargets(previewTargets(for: anchor), fromDoubleClick: false)
        }

        if targets.count == 1, let only = targets.first, only.isBrowsable {
            Button("Open in New Window") {
                commitContextSelection(anchor: anchor)
                WindowLaunchCoordinator.openNewWindow(cloning: only.id)
            }
            if let onOpenInSplit {
                Button("Open in Split") {
                    commitContextSelection(anchor: anchor)
                    onOpenInSplit(only.id)
                }
            }
        }

        if isSearchActive, targets.count == 1, let only = targets.first, !only.isBrowsable {
            Button("Show Enclosing Folder") {
                commitContextSelection(anchor: anchor)
                navigate(to: only.id.deletingLastPathComponent())
                clearSearch()
            }
        }

        Button("Show in Finder") {
            commitContextSelection(anchor: anchor)
            WorkspaceActions.revealInFinder(previewTargets(for: anchor).map(\.id))
        }

        if targets.count == 1, let only = targets.first {
            Button("Rename") {
                commitContextSelection(anchor: anchor)
                beginRename(only)
            }
        }

        let folderTargets = targets.filter(\.isBrowsable)
        if !folderTargets.isEmpty {
            let toAdd = folderTargets.filter { !favorites.contains($0.id) }
            if !toAdd.isEmpty {
                Button(toAdd.count == 1 ? "Add to Favorites" : "Add to Favorites (\(toAdd.count))") {
                    commitContextSelection(anchor: anchor)
                    favorites.add(urls: toAdd.map(\.id))
                }
            }
        }

        Divider()

        Button(targets.count > 1 ? "Copy Paths" : "Copy Path") {
            commitContextSelection(anchor: anchor)
            WorkspaceActions.copyPaths(previewTargets(for: anchor).map(\.id))
        }
        Button(targets.count > 1 ? "Copy Names" : "Copy Name") {
            commitContextSelection(anchor: anchor)
            WorkspaceActions.copyNames(previewTargets(for: anchor).map(\.id))
        }

        Divider()

        Button("New Terminal Here") {
            commitContextSelection(anchor: anchor)
            let resolved = previewTargets(for: anchor)
            WorkspaceActions.openTerminal(at: WorkspaceActions.terminalDirectory(for: resolved))
        }
        .help(targets.count > 1 ? "Opens at the shared folder for this selection" : "")

        Button("Run Agent Here…") {
            commitContextSelection(anchor: anchor)
            let resolved = previewTargets(for: anchor)
            AgentRunCoordinator.shared.presentRunAgent(
                folder: WorkspaceActions.terminalDirectory(for: resolved),
                selection: resolved.map(\.id)
            )
        }

        Button("Open in Cursor") {
            commitContextSelection(anchor: anchor)
            let resolved = previewTargets(for: anchor)
            WorkspaceActions.openInCursor(at: WorkspaceActions.terminalDirectory(for: resolved))
        }

        Divider()

        Button(targets.count > 1 ? "Get Info (\(targets.count))…" : "Get Info…") {
            commitContextSelection(anchor: anchor)
            showInfo(for: previewTargets(for: anchor))
        }

        Divider()

        Button("Move to Trash", role: .destructive) {
            commitContextSelection(anchor: anchor)
            trashEntries(previewTargets(for: anchor))
        }
    }

    private func previewTargets(for anchor: FileEntry) -> [FileEntry] {
        if selection.contains(anchor.id), selection.count > 1 {
            let selected = visibleEntries.filter { selection.contains($0.id) }
            return selected.isEmpty ? [anchor] : selected
        }
        return [anchor]
    }

    private func commitContextSelection(anchor: FileEntry) {
        if !(selection.contains(anchor.id) && selection.count > 1) {
            selection = [anchor.id]
        }
    }

    // MARK: - Search / navigation

    private func scheduleSearch() {
        searchTask?.cancel()

        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isSearching = false
            searchHits = []
            searchError = nil
            reload()
            return
        }

        let query = trimmed
        let scope = searchScope
        let folder = path
        isSearching = true
        searchError = nil

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }

            do {
                let hits = try await SearchService.search(
                    query: query,
                    scope: scope,
                    currentFolder: folder
                )
                guard !Task.isCancelled else { return }
                searchHits = hits
                pruneSelection(to: Set(hits.map(\.id)))
                isSearching = false
                // Results rebuild the grid below; keep caret in the search field.
                if isSearchPresented {
                    searchFocused = true
                }
            } catch is CancellationError {
                // Superseded by a newer query.
            } catch {
                guard !Task.isCancelled else { return }
                searchHits = []
                selection = []
                searchError = error.localizedDescription
                isSearching = false
                if isSearchPresented {
                    searchFocused = true
                }
            }
        }
    }

    private func clearSearch() {
        searchTask?.cancel()
        searchQuery = ""
        searchHits = []
        searchError = nil
        isSearching = false
        searchFocused = false
        listFocused = true
        reload()
    }

    private func presentSearch() {
        isSearchPresented = true
        DispatchQueue.main.async {
            searchFocused = true
        }
    }

    private func dismissSearch() {
        clearSearch()
        isSearchPresented = false
        listFocused = true
    }

    private func reload() {
        do {
            entries = try LocalFileService.list(path: path)
            errorMessage = nil
            pruneSelection(to: Set(entries.map(\.id)))
        } catch {
            entries = []
            selection = []
            errorMessage = error.localizedDescription
        }
    }

    private func pruneSelection(to valid: Set<URL>) {
        selection = selection.intersection(valid)
    }

    private func selectAllVisible() {
        guard !searchFocused else { return }
        selection = Set(visibleEntries.map(\.id))
        listFocused = true
    }

    private func navigate(to url: URL) {
        navigation.go(to: url)
    }

    private func goBack() {
        navigation.goBack()
    }

    private func goForward() {
        navigation.goForward()
    }

    private func goToParent() {
        let parent = path.deletingLastPathComponent()
        if parent.path != path.path {
            navigate(to: parent)
        }
    }

    // MARK: - Open

    private func openSelection() -> KeyPress.Result {
        let targets = visibleEntries.filter { selection.contains($0.id) }
        guard !targets.isEmpty else { return .ignored }
        openTargets(targets, fromDoubleClick: false)
        return .handled
    }

    private func openDoubleClicked(_ entry: FileEntry) {
        selection = [entry.id]
        openTargets([entry], fromDoubleClick: true)
    }

    private func openTargets(_ targets: [FileEntry], fromDoubleClick: Bool) {
        guard !targets.isEmpty else { return }

        if targets.count == 1, let only = targets.first, only.isBrowsable {
            navigate(to: only.id)
            if isSearchActive {
                clearSearch()
            }
            return
        }

        let files = targets.filter { !$0.isBrowsable }
        let folders = targets.filter(\.isBrowsable)

        for file in files {
            WorkspaceActions.open(file.id)
        }
        if !folders.isEmpty {
            WorkspaceActions.openMany(folders.map(\.id))
        }

        _ = fromDoubleClick
    }

    private func showInfo(for targets: [FileEntry]) {
        if targets.count == 1, let only = targets.first {
            do {
                details = try LocalFileService.details(for: only.id)
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        multiInfo = MultiSelectionInfo(entries: targets)
    }

    private func handleTransfer(
        _ sources: [URL],
        into destination: URL,
        operation: FileTransferOperation
    ) {
        let result = FileOperations.transfer(sources, into: destination, operation: operation)
        if !result.failed.isEmpty {
            let names = result.failed.map { $0.0.lastPathComponent }.joined(separator: ", ")
            let verbPast = operation == .copy ? "copied" : "moved"
            transferErrorTitle = operation.failureTitle
            transferErrorMessage = result.transferred.isEmpty
                ? "Could not \(operation == .copy ? "copy" : "move"): \(names)"
                : "Some items could not be \(verbPast): \(names)"
        }

        let newSelection = Set(result.transferred.map(\.to))
        if !result.transferred.isEmpty {
            switch operation {
            case .move:
                undoStack.register(.move(result.transferred))
            case .copy:
                undoStack.register(.copy(result.transferred))
            }
        }
        if isSearchActive {
            scheduleSearch()
            selection = newSelection
        } else {
            reload()
            selection = newSelection
        }

        var affected = [destination]
        if operation == .move {
            affected.append(contentsOf: result.transferred.map {
                $0.from.deletingLastPathComponent()
            })
        }
        BrowserListingDidChange.post(folders: affected)
    }

    private func beginCreateItem(_ kind: CreateItemKind) {
        createDialog = CreateItemDialog(kind: kind)
        newItemName = kind.defaultName
    }

    private func confirmCreateItem() {
        guard let createDialog else { return }
        let name = newItemName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        do {
            let created: URL
            let isDirectory: Bool
            switch createDialog.kind {
            case .folder:
                created = try FileOperations.createFolder(in: path, named: name)
                isDirectory = true
            case .file:
                created = try FileOperations.createEmptyFile(in: path, named: name)
                isDirectory = false
            }
            self.createDialog = nil
            undoStack.register(.create(url: created, isDirectory: isDirectory))
            reload()
            selection = [created]
            BrowserListingDidChange.post(folders: [path])
        } catch {
            self.createDialog = nil
            createErrorMessage = error.localizedDescription
        }
    }

    private func performUndo() {
        guard undoStack.canUndo else { return }
        let result = undoStack.undo()
        if let error = result.errorMessage {
            undoErrorMessage = error
        }
        refreshAfterUndoRedo(
            selecting: result.restoredSelection,
            affectedFolders: result.affectedFolders
        )
    }

    private func performRedo() {
        guard undoStack.canRedo else { return }
        let result = undoStack.redo()
        if let error = result.errorMessage {
            undoErrorMessage = error
        }
        refreshAfterUndoRedo(
            selecting: result.restoredSelection,
            affectedFolders: result.affectedFolders
        )
    }

    private func refreshAfterUndoRedo(selecting newSelection: Set<URL>, affectedFolders: [URL]) {
        cancelRename()
        if isSearchActive {
            scheduleSearch()
        } else {
            reload()
        }
        selection = newSelection
        var folders = affectedFolders
        folders.append(path)
        folders.append(contentsOf: newSelection.map { $0.deletingLastPathComponent() })
        BrowserListingDidChange.post(folders: folders)
    }

    // MARK: - Trash

    @discardableResult
    private func moveSelectionToTrash() -> KeyPress.Result {
        let targets = visibleEntries.filter { selection.contains($0.id) }
        guard !targets.isEmpty else { return .ignored }
        trashEntries(targets)
        return .handled
    }

    private func trashEntries(_ entries: [FileEntry]) {
        guard !entries.isEmpty else { return }
        cancelRename()
        let result = FileOperations.trash(entries.map(\.id))

        if !result.failed.isEmpty {
            let names = result.failed.map { $0.0.lastPathComponent }.joined(separator: ", ")
            transferErrorTitle = "Move to Trash Failed"
            transferErrorMessage = result.trashed.isEmpty
                ? "Could not move to Trash: \(names)"
                : "Some items could not be moved to Trash: \(names)"
        }

        if !result.trashed.isEmpty {
            undoStack.register(.trash(result.trashed))
        }

        if isSearchActive {
            scheduleSearch()
        } else {
            reload()
        }
        selection = []
        BrowserListingDidChange.post(folders: result.trashed.map {
            $0.from.deletingLastPathComponent()
        })
    }

    // MARK: - Rename
    private func handleNameClick(_ entry: FileEntry) {
        if renamingURL == entry.id { return }

        if selection != [entry.id] {
            selection = [entry.id]
            return
        }

        // Ignore the click that just selected the item (and double-click opens).
        if Date().timeIntervalSince(selectionMarkedAt) < 0.5 {
            return
        }

        beginRename(entry)
    }

    private func beginRename(_ entry: FileEntry) {
        selection = [entry.id]
        renameDraft = entry.name
        renamingURL = entry.id
    }

    private func cancelRename() {
        renamingURL = nil
        renameDraft = ""
    }

    private func commitRename() {
        guard let renamingURL else { return }
        let url = renamingURL

        do {
            let result = try FileOperations.rename(url, to: renameDraft)
            cancelRename()
            if result.from != result.to {
                undoStack.register(.rename(from: result.from, to: result.to))
            }
            if isSearchActive {
                scheduleSearch()
            } else {
                reload()
            }
            selection = [result.to]
            BrowserListingDidChange.post(folders: [
                result.from.deletingLastPathComponent(),
                result.to.deletingLastPathComponent(),
            ])
        } catch FileOperations.RenameError.unchanged {
            cancelRename()
        } catch {
            renameErrorMessage = error.localizedDescription
            // Stay in rename mode so the user can fix the name.
        }
    }

    /// Other panes / tabs showing an affected folder should refresh without remounting.
    private func handleRemoteListingChange(_ folders: [URL]) {
        let affected = Set(folders.map(\.standardizedFileURL))
        guard affected.contains(path.standardizedFileURL) else { return }
        if isSearchActive {
            scheduleSearch()
        } else {
            reload()
        }
    }
}

private struct FileBrowserFocusedSceneModifier: ViewModifier {
    var isActive: Bool
    var displaySettings: BrowserDisplaySettings
    var folderURL: URL

    func body(content: Content) -> some View {
        // Always apply the same modifier chain so activating a split pane does not
        // remount the browser (which re-ran onAppear → reload and snapped scroll to top).
        content
            .focusedSceneValue(\.browserDisplaySettings, isActive ? displaySettings : nil)
            .focusedSceneValue(\.browserFolderURL, isActive ? folderURL : nil)
    }
}

private enum CreateItemKind {
    case folder
    case file

    var defaultName: String {
        switch self {
        case .folder: return "untitled folder"
        case .file: return "untitled.txt"
        }
    }
}

private struct CreateItemDialog: Identifiable {
    let id = UUID()
    let kind: CreateItemKind

    var title: String {
        switch kind {
        case .folder: return "New Folder"
        case .file: return "New Empty File"
        }
    }

    var placeholder: String { "Name" }

    var message: String {
        switch kind {
        case .folder: return "Enter a name for the new folder."
        case .file: return "Enter a name for the new file."
        }
    }
}

private struct FileBrowserAlertsModifier: ViewModifier {
    var transferErrorTitle: String
    @Binding var transferErrorMessage: String?
    @Binding var createDialog: CreateItemDialog?
    @Binding var newItemName: String
    @Binding var createErrorMessage: String?
    @Binding var undoErrorMessage: String?
    @Binding var renameErrorMessage: String?
    var onConfirmCreate: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(transferErrorTitle, isPresented: Binding(
                get: { transferErrorMessage != nil },
                set: { if !$0 { transferErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { transferErrorMessage = nil }
            } message: {
                Text(transferErrorMessage ?? "")
            }
            .alert(
                createDialog?.title ?? "New Item",
                isPresented: Binding(
                    get: { createDialog != nil },
                    set: { if !$0 { createDialog = nil } }
                )
            ) {
                TextField(createDialog?.placeholder ?? "Name", text: $newItemName)
                Button("Create", action: onConfirmCreate)
                    .disabled(newItemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { createDialog = nil }
            } message: {
                Text(createDialog?.message ?? "")
            }
            .alert("Could Not Create Item", isPresented: Binding(
                get: { createErrorMessage != nil },
                set: { if !$0 { createErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { createErrorMessage = nil }
            } message: {
                Text(createErrorMessage ?? "")
            }
            .alert("Undo Failed", isPresented: Binding(
                get: { undoErrorMessage != nil },
                set: { if !$0 { undoErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { undoErrorMessage = nil }
            } message: {
                Text(undoErrorMessage ?? "")
            }
            .alert("Rename Failed", isPresented: Binding(
                get: { renameErrorMessage != nil },
                set: { if !$0 { renameErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { renameErrorMessage = nil }
            } message: {
                Text(renameErrorMessage ?? "")
            }
    }
}

struct BreadcrumbBar: View {
    let path: URL
    var dragState: FileDragState = FileDragState()
    var onNavigate: (URL) -> Void
    var onTransfer: (([URL], URL, FileTransferOperation) -> Void)? = nil

    private var crumbs: [(name: String, url: URL)] {
        var result: [(String, URL)] = []
        var current = path.standardizedFileURL

        while true {
            let name = current.path == "/" ? "Macintosh HD" : current.lastPathComponent
            result.append((name, current))
            if current.path == "/" { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return result.reversed()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Button {
                        onNavigate(crumb.url)
                    } label: {
                        HStack(spacing: 4) {
                            Image(nsImage: FileIcon.image(for: crumb.url, size: 14))
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 14, height: 14)
                            Text(crumb.name)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(index == crumbs.count - 1 ? .primary : .secondary)
                    .help(crumb.url.path)
                    .onDrop(
                        of: [.fileURL],
                        delegate: FolderDropDelegate(
                            destination: crumb.url,
                            dragState: dragState,
                            isTargeted: nil,
                            onTransfer: { urls, destination, operation in
                                onTransfer?(urls, destination, operation)
                            }
                        )
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .focusEffectDisabled()
    }
}

struct MultiSelectionInfo: Identifiable {
    let id = UUID()
    let entries: [FileEntry]

    var fileCount: Int { entries.filter { !$0.isDirectory || $0.isPackage }.count }
    var folderCount: Int { entries.filter { $0.isBrowsable }.count }

    var totalSize: UInt64 {
        entries.reduce(into: UInt64(0)) { partial, entry in
            if !entry.isDirectory || entry.isPackage {
                partial += entry.size
            }
        }
    }
}

private struct MultiSelectionInfoView: View {
    let info: MultiSelectionInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(info.entries.count) Items Selected")
                .font(.headline)

            LabeledContent("Folders", value: "\(info.folderCount)")
            LabeledContent("Files", value: "\(info.fileCount)")
            LabeledContent(
                "Size",
                value: ByteCountFormatter.string(fromByteCount: Int64(info.totalSize), countStyle: .file)
            )

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320, height: 200)
    }
}

extension FileDetails: Identifiable {
    var id: URL { url }
}
