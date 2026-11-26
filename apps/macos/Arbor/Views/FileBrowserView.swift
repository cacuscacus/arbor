import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserView: View {
    @Bindable var pane: BrowserPane
    @Bindable var favorites: SidebarFavoritesStore
    var dragState: FileDragState
    var isActive: Bool = true
    var isVisible: Bool = true
    var isDedicatedSearchTab: Bool = false
    var onOpenInSplit: ((ItemRef) -> Void)? = nil
    var onOpenSearchInTab: ((BrowserPane) -> Void)? = nil

    var body: some View {
        Group {
            if (try? FileProviderRegistry.shared.provider(for: pane.navigation.current)) != nil {
                LocalFileBrowserView(
                    pane: pane,
                    favorites: favorites,
                    dragState: dragState,
                    isActive: isActive,
                    isVisible: isVisible,
                    isDedicatedSearchTab: isDedicatedSearchTab,
                    onOpenInSplit: onOpenInSplit,
                    onOpenSearchInTab: onOpenSearchInTab,
                    localPath: FileProviderRegistry.shared.intrinsicLocalURL(
                        for: pane.navigation.current
                    )
                )
            } else {
                ContentUnavailableView {
                    Label("Location Unavailable", systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text("This location is preserved, but its file provider is not connected.")
                } actions: {
                    Button("Copy Path") {
                        WorkspaceActions.copyPaths([pane.navigation.current])
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .focusedSceneValue(\.browserFolderItem, isActive ? pane.navigation.current : nil)
    }
}

private struct LocalFileBrowserView: View {
    @Bindable var pane: BrowserPane
    @Bindable var favorites: SidebarFavoritesStore
    var dragState: FileDragState
    /// When multiple tab / split browsers stay mounted, only the focused pane publishes scene focus values.
    var isActive: Bool = true
    /// Tab is selected (both split panes can be visible). Drives live directory watching.
    var isVisible: Bool = true
    var isDedicatedSearchTab: Bool = false
    /// Opens a folder in the other split pane (creates a split if needed).
    var onOpenInSplit: ((ItemRef) -> Void)? = nil
    /// Promotes the active search into a dedicated Search Tab.
    var onOpenSearchInTab: ((BrowserPane) -> Void)? = nil
    let localPath: URL?

    private var navigation: BrowserNavigation { pane.navigation }
    private var displaySettings: BrowserDisplaySettings { pane.displaySettings }
    private var undoStack: ArborUndoStack { pane.undoStack }
    private var search: SearchSession { pane.search }
    private var capabilities: FileProviderCapabilities {
        FileProviderRegistry.shared.capabilities(for: navigation.current)
    }

    @State private var entries: [FileEntry] = []
    /// Sorted listing / search results — recomputed only when inputs change.
    @State private var visibleEntries: [FileEntry] = []
    @State private var selection = Set<ItemRef>()
    @State private var errorMessage: String?
    @State private var connectionRequired: ConnectionID?
    @State private var hostKeyRequired: ConnectionID?
    /// `hostKeyRequired` for a key that CHANGED (vs. a brand-new host).
    @State private var hostKeyChangedMode = false
    @State private var authenticationRequired: ConnectionID?
    @State private var hostKeyCandidate: SSHHostKeyCandidate?
    @State private var isLoading = false
    @State private var details: FileDetails?
    @State private var detailsTask: Task<Void, Never>?
    @State private var multiInfo: MultiSelectionInfo?
    @State private var quickDiffRequest: QuickDiffRequest?
    @State private var transferErrorTitle = "Transfer Failed"
    @State private var transferErrorMessage: String?
    @State private var permanentDeleteTargets: [FileEntry] = []
    @State private var createErrorMessage: String?
    @State private var undoErrorMessage: String?
    @State private var renamingItem: ItemRef?
    @State private var renameDraft = ""
    @State private var renameErrorMessage: String?
    @State private var selectionMarkedAt = Date.distantPast
    @State private var typeAheadMatcher = TypeAheadMatcher()
    @State private var scrollToItemRequest: (token: UUID, item: ItemRef)?

    @State private var listingTask: Task<Void, Never>?
    @State private var mutationTask: Task<Void, Never>?
    @State private var volumeAvailableBytes: Int64?
    @State private var showsGoToFolder = false
    /// Item to select once a navigation finishes (Go to Folder on a file).
    @State private var pendingSelection: ItemRef?

    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool
    @AppStorage(HiddenFilesPreference.key) private var showHiddenFiles = false
    @Environment(WindowBrowserSortStore.self) private var windowSort
    @Environment(\.hasFloatingTabBar) private var hasFloatingTabBar

    private var isSearchActive: Bool { search.isActive }
    private var showsSearchPanel: Bool { search.showsPanel }

    private var relativeRoot: ItemRef {
        switch search.scope {
        case .currentFolder:
            return navigation.current
        case .global:
            return LocalFileLocation.item(
                for: FileManager.default.homeDirectoryForCurrentUser
            )
        }
    }

    private var tableSortOrder: Binding<[KeyPathComparator<FileEntry>]> {
        Binding(
            get: { BrowserSort.tableSortOrder(for: windowSort.descriptor) },
            set: { newValue in
                if let next = BrowserSort.descriptor(
                    from: newValue,
                    keepingFoldersOnTop: windowSort.descriptor.keepFoldersOnTop
                ) {
                    windowSort.descriptor = next
                }
            }
        )
    }

    private func refreshVisibleEntries() {
        if isSearchActive {
            // Entries are already materialized off-main-thread by SearchService.
            // Keep concentric rings ordered (This Folder → Subfolders → Home → Related)
            // when progressive scoping or Smart Expansion is active so outer hits never
            // jump above closer literal matches.
            let hasExpanded = (search.countsByRing[.expanded] ?? 0) > 0
            if (search.scope == .global && SearchPreferencesStore.shared.progressiveScoping) || hasExpanded {
                var grouped: [FileEntry] = []
                grouped.reserveCapacity(search.hits.count)
                for ring in SearchRing.allCases {
                    let ringEntries = search.hits.compactMap { $0.ring == ring ? $0.entry : nil }
                    if !ringEntries.isEmpty {
                        grouped.append(contentsOf: BrowserSort.sorted(ringEntries, by: windowSort.descriptor))
                    }
                }
                visibleEntries = grouped
            } else {
                visibleEntries = BrowserSort.sorted(search.hits.map(\.entry), by: windowSort.descriptor)
            }
            return
        }
        visibleEntries = BrowserSort.sorted(entries, by: windowSort.descriptor)
    }

    var body: some View {
        browserScaffold
            .modifier(FileBrowserAlertsModifier(
                transferErrorTitle: transferErrorTitle,
                transferErrorMessage: $transferErrorMessage,
                createErrorMessage: $createErrorMessage,
                undoErrorMessage: $undoErrorMessage,
                renameErrorMessage: $renameErrorMessage,
                permanentDeleteTargets: $permanentDeleteTargets,
                onConfirmPermanentDelete: permanentlyDeletePendingItems
            ))
    }

    private var browserScaffold: some View {
        applyBrowserLifecycle(to: browserChrome)
    }

    private var browserChrome: some View {
        VStack(spacing: 0) {
            // Keep content swaps (browse ↔ search results) inside this slot so the
            // floating search overlay is NOT recreated with them — that was
            // stealing TextField focus after the first character.
            // `.id(path)` remounts the scroller at the system resting top when the
            // folder changes (Finder-like), without forcing raw NSScrollView y=0.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(
                    isSearchActive
                        ? "search:\(search.mode.rawValue):\(search.scope)"
                        : "\(navigation.current.volumeID.rawValue):\(navigation.current.path)"
                )

            if isSearchActive {
                Divider()
                SearchStatusBanner(
                    scope: search.scope,
                    mode: search.mode,
                    folderName: pane.folderDisplayName,
                    backend: search.activeBackend,
                    isSearching: search.isSearching,
                    hitCount: search.hits.count,
                    countsByRing: search.countsByRing,
                    stopReason: search.stopReason,
                    elapsedSeconds: search.elapsedSeconds,
                    activeLimit: search.activeLimit,
                    onStop: stopSearch,
                    onExpandLimit: { nextLimit in
                        search.limitOverride = nextLimit
                        scheduleSearch(immediate: true)
                    },
                    onContinueTimeout: {
                        let base = search.timeoutOverride ?? SearchPreferencesStore.shared.timeoutSeconds
                        search.timeoutOverride = base + 10
                        scheduleSearch(immediate: true)
                    },
                    onDeepScan: {
                        search.deepGlobalContentOverride = true
                        scheduleSearch(immediate: true)
                    }
                )
            } else {
                Divider()
                BreadcrumbBar(
                    directory: navigation.current,
                    dragState: dragState,
                    statusSummary: statusBarSummary,
                    onNavigate: { target in navigate(to: target) },
                    onTransfer: handleTransfer
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsSearchPanel {
                floatingSearchPanel
                    .padding(.top, 10)
                    // Leave room for the floating single-tab `+` glass button when 1 tab is open.
                    .padding(.trailing, hasFloatingTabBar ? 12 : 48)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.18), value: search.isPresented && !isSearchActive)
        .background {
            // Down/Up from the search field moves into the results (Finder-style).
            SearchResultKeyMonitor(
                isActive: isSearchActive && searchFocused && !visibleEntries.isEmpty,
                onMoveDown: { focusSearchResult(last: false) },
                onMoveUp: { focusSearchResult(last: true) }
            )
        }
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
        .modifier(FileBrowserFocusedSceneModifier(
            isActive: isActive,
            displaySettings: displaySettings,
            folderItem: navigation.current
        ))
    }

    private func applyBrowserLifecycle<Content: View>(to content: Content) -> some View {
        applyBrowserKeyHandling(
            to: applyBrowserSheets(
                to: applyBrowserListingObservers(
                    to: applyBrowserSessionObservers(to: content)
                )
            )
        )
    }

    private func applyBrowserSessionObservers<Content: View>(to content: Content) -> some View {
        content
            .onChange(of: pane.chromeCommandToken) { _, _ in
                guard isActive, let command = pane.consumeChromeCommand() else { return }
                handleChromeCommand(command)
            }
            .onChange(of: navigation.current, initial: true) { _, item in
                guard isActive else { return }
                WindowLaunchCoordinator.noteFocusedItem(item)
            }
            .onChange(of: isActive) { _, active in
                if active {
                    WindowLaunchCoordinator.noteFocusedItem(navigation.current)
                    if search.isPresented {
                        DispatchQueue.main.async { searchFocused = true }
                    } else {
                        listFocused = true
                    }
                }
            }
            .onChange(of: search.focusRequestToken) { _, _ in
                if isActive {
                    DispatchQueue.main.async { searchFocused = true }
                }
            }
            .onChange(of: showsGoToFolder) { _, presented in
                // Dismissing the sheet leaves AppKit without a first responder in
                // this pane, so Return/Space/Delete stop reaching the listing.
                guard !presented else { return }
                DispatchQueue.main.async {
                    if !search.isPresented { listFocused = true }
                }
            }
            .onAppear {
                reload()
                if search.isActive {
                    refreshVisibleEntries()
                    if search.needsResumeAfterAdopt || (search.hits.isEmpty && !search.isSearching) {
                        search.needsResumeAfterAdopt = false
                        scheduleSearch(immediate: true)
                    }
                }
                if isActive {
                    if search.isPresented {
                        DispatchQueue.main.async { searchFocused = true }
                    } else {
                        listFocused = true
                    }
                }
            }
            .onDisappear {
                listingTask?.cancel()
                detailsTask?.cancel()
                search.cancel()
                QuickLookController.shared.close()
                DocumentPreviewController.shared.close()
            }
            .background {
                FolderListingWatchActivator(
                    directory: (isVisible && !isSearchActive) ? navigation.current : nil
                ) {
                    reload()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                guard isVisible, !isSearchActive else { return }
                reload()
            }
    }

    private func applyBrowserListingObservers<Content: View>(to content: Content) -> some View {
        content
            .onChange(of: showHiddenFiles) { _, _ in
                if isSearchActive {
                    scheduleSearch()
                } else {
                    reload()
                }
            }
            .onChange(of: search.hits) { _, _ in
                refreshVisibleEntries()
            }
            .onChange(of: windowSort.descriptor) { _, _ in
                refreshVisibleEntries()
            }
            .onReceive(NotificationCenter.default.publisher(for: BrowserListingDidChange.name)) { note in
                handleRemoteListingChange(BrowserListingDidChange.folders(from: note))
            }
            .onChange(of: navigation.current) { _, _ in
                cancelRename()
                typeAheadMatcher.reset()
                // A folder change invalidates whatever preview is showing.
                QuickLookController.shared.close()
                DocumentPreviewController.shared.close()
                selection = []
                if search.scope == .currentFolder, isSearchActive {
                    scheduleSearch()
                } else if !isSearchActive {
                    reload()
                }
                if !searchFocused && !search.isPresented {
                    listFocused = true
                }
            }
            .onChange(of: selection) { _, _ in
                selectionMarkedAt = Date()
                syncQuickLookIfOpen()
                if let renamingItem, !selection.contains(renamingItem) {
                    cancelRename()
                }
            }
            .onChange(of: search.query) { _, _ in
                search.resetOverrides()
                refreshVisibleEntries()
                scheduleSearch()
            }
            .onChange(of: search.scope) { oldScope, newScope in
                search.resetOverrides()
                if newScope == .global,
                   oldScope != .global,
                   !isDedicatedSearchTab,
                   SearchPreferencesStore.shared.openGlobalInNewTab,
                   let onOpenSearchInTab
                {
                    onOpenSearchInTab(pane)
                    return
                }
                if isSearchActive {
                    scheduleSearch()
                }
            }
            .onChange(of: search.mode) { _, _ in
                search.resetOverrides()
                if isSearchActive {
                    scheduleSearch(immediate: true)
                }
            }
    }

    private func applyBrowserSheets<Content: View>(to content: Content) -> some View {
        content
            .sheet(item: $details) { info in
                FileDetailsView(details: info)
            }
            .sheet(item: $multiInfo) { info in
                MultiSelectionInfoView(info: info)
            }
            .sheet(item: $quickDiffRequest) { request in
                QuickDiffView(left: request.left, right: request.right)
            }
            .sheet(isPresented: $showsGoToFolder) {
                GoToFolderSheet(currentDirectory: goToFolderRoot) { folder, selection in
                    navigateToFolder(folder, selecting: selection)
                }
            }
            .sheet(item: $hostKeyCandidate) { candidate in
                SSHHostKeyVerificationSheet(candidate: candidate) {
                    hostKeyRequired = nil
                    hostKeyChangedMode = false
                    reload()
                }
            }
            .background {
                shortcutButtons
            }
    }

    private func applyBrowserKeyHandling<Content: View>(to content: Content) -> some View {
        content
            .onKeyPress(keys: [.escape], phases: .down) { _ in
                guard isActive else { return .ignored }
                if renamingItem != nil {
                    cancelRename()
                    return .handled
                }
                if isSearchActive || searchFocused || search.isPresented {
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
                if renamingItem != nil || searchFocused { return .ignored }
                return openSelection()
            }
            .onKeyPress(.space) {
                guard isActive else { return .ignored }
                // Only the text field itself should swallow Space — search
                // results stay previewable once focus moves to the listing.
                if renamingItem != nil || searchFocused { return .ignored }
                return toggleQuickLook()
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
    }

    private var floatingSearchPanel: some View {
        @Bindable var searchBinding = search
        return SearchBarView(
            query: $searchBinding.query,
            scope: $searchBinding.scope,
            mode: $searchBinding.mode,
            isSearching: search.isSearching,
            resultCount: isSearchActive ? search.hits.count : nil,
            activeLimit: search.activeLimit,
            stopReason: search.stopReason,
            focus: $searchFocused,
            smartExpansionActive: search.isSmartExpansionActive,
            isExpandingTerms: search.isExpandingTerms,
            expandedTerms: search.activeExpandedTerms,
            expansionError: search.expansionError,
            onToggleSmartExpansion: {
                search.toggleSmartExpansionForSession()
                if isSearchActive {
                    scheduleSearch(immediate: true)
                }
            },
            onDismissExpandedTerm: { term in
                search.dismissExpandedTerm(term)
                scheduleSearch(immediate: true, skipExpansionLaunch: true)
            },
            onStop: stopSearch,
            onOpenInTab: (!isDedicatedSearchTab && onOpenSearchInTab != nil)
                ? { onOpenSearchInTab?(pane) }
                : nil,
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
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(renamingItem != nil || searchFocused || selection.isEmpty)
                    .opacity(0)
                    .allowsHitTesting(false)

                Button("") { requestPermanentDeleteSelection() }
                    .keyboardShortcut(.delete, modifiers: [.command, .option])
                    .disabled(renamingItem != nil || searchFocused || selection.isEmpty || !capabilities.contains(.remove))
                    .opacity(0)
                    .allowsHitTesting(false)

                Button("") { beginCreateItem(.folder) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(isSearchActive || !capabilities.contains(.create))
                    .opacity(0)
                    .allowsHitTesting(false)

                Button("") {
                    let targets = selectedVisibleEntries()
                    guard !targets.isEmpty else { return }
                    showInfo(for: targets)
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(selection.isEmpty || !capabilities.contains(.metadata))
                .opacity(0)
                .allowsHitTesting(false)

                Button("") { _ = openSelection() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(renamingItem != nil || searchFocused || selection.isEmpty)
                    .opacity(0)
                    .allowsHitTesting(false)

                Button("") { _ = openSelection() }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(renamingItem != nil || searchFocused || selection.isEmpty)
                    .opacity(0)
                    .allowsHitTesting(false)

                Button("") { displaySettings.viewMode = .list }
                    .keyboardShortcut("1", modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)

                Button("") { displaySettings.viewMode = .icons }
                    .keyboardShortcut("2", modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)

                Button("") { presentQuickDiff(for: selectedVisibleEntries()) }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(!canQuickDiff(selectedVisibleEntries()))
                    .opacity(0)
                    .allowsHitTesting(false)

                Button("") { copySelection() }
                    .keyboardShortcut("c", modifiers: .command)
                    .disabled(renamingItem != nil || searchFocused || selection.isEmpty)
                    .opacity(0)
                    .allowsHitTesting(false)

                Button("") { cutSelection() }
                    .keyboardShortcut("x", modifiers: .command)
                    .disabled(renamingItem != nil || searchFocused || selection.isEmpty)
                    .opacity(0)
                    .allowsHitTesting(false)

                Button("") { pasteClipboard(forceMove: false) }
                    .keyboardShortcut("v", modifiers: .command)
                    .disabled(renamingItem != nil || searchFocused || !capabilities.contains(.transfer))
                    .opacity(0)
                    .allowsHitTesting(false)

                Button("") { pasteClipboard(forceMove: true) }
                    .keyboardShortcut("v", modifiers: [.command, .option])
                    .disabled(renamingItem != nil || searchFocused || !capabilities.contains(.transfer))
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
            if search.isPresented && !isSearchActive {
                dismissSearch()
            } else {
                presentSearch()
            }
        case .quickLook:
            _ = toggleQuickLook()
        case .goToFolder:
            presentGoToFolder()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let hostKeyRequired {
            hostKeyContent(connectionID: hostKeyRequired)
        } else if let authenticationRequired {
            authenticationContent(connectionID: authenticationRequired)
        } else if let connectionRequired {
            disconnectedContent(connectionID: connectionRequired)
        } else if isLoading && entries.isEmpty {
            ProgressView("Connecting…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let searchError = search.errorMessage, isSearchActive {
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
                description: Text(navigation.current.path)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .contextMenu { emptySpaceContextMenu }
            .onDrop(
                of: [.fileURL],
                delegate: FolderDropDelegate(
                    destination: navigation.current,
                    dragState: dragState,
                    isTargeted: nil,
                    onTransfer: handleTransfer
                )
            )
        } else {
            browserBody(entries: visibleEntries, showsLocation: false)
        }
    }

    private func disconnectedContent(connectionID: ConnectionID) -> some View {
        let profile = SSHLocationStore.shared.profile(connectionID: connectionID)
        return ContentUnavailableView {
            Label("SSH Location Disconnected", systemImage: "network.slash")
        } description: {
            VStack(spacing: 4) {
                Text(profile?.displayName ?? "SSH Location")
                Text(navigation.current.path)
                    .font(.caption.monospaced())
            }
        } actions: {
            Button("Reconnect") { reload() }
            Button("Copy Remote Path") {
                WorkspaceActions.copyPaths([navigation.current])
            }
        }
    }

    private func hostKeyContent(connectionID: ConnectionID) -> some View {
        ContentUnavailableView {
            Label(
                hostKeyChangedMode ? "SSH Host Key Changed" : "Verify SSH Host Key",
                systemImage: "lock.shield"
            )
        } description: {
            VStack(spacing: 4) {
                Text(
                    hostKeyChangedMode
                        ? "The recorded host key no longer matches. Review the new fingerprint and replace it explicitly."
                        : "Arbor will not accept a new or changed host key silently."
                )
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                }
            }
        } actions: {
            Button(hostKeyChangedMode ? "Review Replacement" : "Inspect Host Key") {
                inspectHostKey(connectionID: connectionID)
            }
            Button("Copy Remote Path") {
                WorkspaceActions.copyPaths([navigation.current])
            }
        }
    }

    private func authenticationContent(connectionID: ConnectionID) -> some View {
        let profile = SSHLocationStore.shared.profile(connectionID: connectionID)
        return ContentUnavailableView {
            Label("SSH Authentication Required", systemImage: "person.badge.key")
        } description: {
            Text("OpenSSH could not authenticate to \(profile?.endpoint.displayDestination ?? "this host"). Add the key to ssh-agent or update ~/.ssh/config, then retry.")
        } actions: {
            Button("Retry") { reload() }
        }
    }

    private func inspectHostKey(connectionID: ConnectionID) {
        guard let profile = SSHLocationStore.shared.profile(connectionID: connectionID) else {
            return
        }
        Task {
            do {
                hostKeyCandidate = try await SSHHostKeyService.inspect(profile)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var searchBody: some View {
        if search.isSearching && search.hits.isEmpty {
            VStack(spacing: 10) {
                ProgressView("Searching \(search.scope == .global ? "Home" : pane.folderDisplayName)…")
                    .controlSize(.small)
                if search.elapsedSeconds >= 0.4 {
                    Text(String(format: "%.1fs · %@", search.elapsedSeconds, search.activeBackend.rawValue))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("Stop", action: stopSearch)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if search.hits.isEmpty {
            ContentUnavailableView(
                "No results",
                systemImage: search.mode == .content ? "doc.text.magnifyingglass" : "magnifyingglass",
                description: Text(emptySearchDescription)
            )
        } else if search.mode == .content {
            ContentSearchResultsView(
                hits: search.hits,
                selection: $selection,
                extraTopPadding: (!search.activeExpandedTerms.isEmpty || search.isExpandingTerms) ? 26 : 0,
                onOpen: { entry in
                    cancelRename()
                    openDoubleClicked(entry)
                },
                contextMenu: { entry in entryContextMenu(anchor: entry) }
            )
        } else {
            browserBody(entries: visibleEntries, showsLocation: true)
        }
    }

    private var isTypeAheadActive: Bool {
        isActive
            && !searchFocused
            && renamingItem == nil
            && !showsGoToFolder
            && details == nil
            && multiInfo == nil
            && quickDiffRequest == nil
    }

    private func handleTypeAhead(_ characters: String) -> Int? {
        guard isTypeAheadActive, !visibleEntries.isEmpty else { return nil }
        let currentIndex = selection.count == 1
            ? visibleEntries.firstIndex(where: { selection.contains($0.id) })
            : nil
        guard let matched = typeAheadMatcher.match(
            typing: characters,
            at: Date(),
            candidates: visibleEntries.map(\.name),
            currentIndex: currentIndex
        ) else {
            return nil
        }
        selection = [visibleEntries[matched].id]
        return matched
    }

    @ViewBuilder
    private func browserBody(entries: [FileEntry], showsLocation: Bool) -> some View {
        switch displaySettings.viewMode {
        case .list:
            FileTableView(
                entries: entries,
                selection: $selection,
                sortOrder: tableSortOrder,
                renamingItem: $renamingItem,
                renameDraft: $renameDraft,
                settings: displaySettings,
                relativeRoot: relativeRoot,
                currentFolder: isSearchActive ? nil : navigation.current,
                showsLocation: showsLocation,
                dragState: dragState,
                isTypeAheadActive: isTypeAheadActive,
                scrollToItemRequest: scrollToItemRequest,
                onOpenRow: { entry in
                    cancelRename()
                    openDoubleClicked(entry)
                },
                onTransfer: handleTransfer,
                onRequestRename: handleNameClick,
                onCommitRename: commitRename,
                onCancelRename: cancelRename,
                onTypeAhead: handleTypeAhead,
                contextMenu: { entry in entryContextMenu(anchor: entry) },
                emptySpaceMenu: { emptySpaceContextMenu }
            )
        case .icons:
            FileIconView(
                entries: entries,
                selection: $selection,
                renamingItem: $renamingItem,
                renameDraft: $renameDraft,
                iconMetrics: displaySettings.iconMetrics,
                currentFolder: isSearchActive ? nil : navigation.current,
                dragState: dragState,
                isTypeAheadActive: isTypeAheadActive,
                scrollToItemRequest: scrollToItemRequest,
                onOpen: { entry in
                    cancelRename()
                    openDoubleClicked(entry)
                },
                onTransfer: handleTransfer,
                onRequestRename: handleNameClick,
                onCommitRename: commitRename,
                onCancelRename: cancelRename,
                onDeleteSelection: { _ = moveSelectionToTrash() },
                onQuickLook: { _ = toggleQuickLook() },
                onTypeAhead: handleTypeAhead,
                contextMenu: { entry in entryContextMenu(anchor: entry) },
                emptySpaceMenu: { emptySpaceContextMenu }
            )
        }
    }

    @ViewBuilder
    private var emptySpaceContextMenu: some View {
        if !isSearchActive {
            if capabilities.contains(.transfer), FileClipboard.shared.canPaste {
                let count = FileClipboard.shared.pasteCount
                let pasteLabel = FileClipboard.shared.defaultPasteIsMove
                    ? (count == 1 ? "Move Item Here" : "Move \(count) Items Here")
                    : (count == 1 ? "Paste Item" : "Paste \(count) Items")
                Button(pasteLabel) { pasteClipboard(forceMove: false) }
                    .keyboardShortcut("v", modifiers: .command)
                if !FileClipboard.shared.defaultPasteIsMove {
                    Button(count == 1 ? "Move Item Here" : "Move \(count) Items Here") {
                        pasteClipboard(forceMove: true)
                    }
                    .keyboardShortcut("v", modifiers: [.command, .option])
                }
                Divider()
            }
            if capabilities.contains(.create) {
                Button("New Folder…") {
                    beginCreateItem(.folder)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Empty File…") {
                    beginCreateItem(.file)
                }
                Divider()
            }
            let context = ExecutionContext(workingDirectory: navigation.current)
            if context.supportsLocalExecution {
                Button("Open Terminal Here") {
                    WorkspaceActions.openTerminal(context: context)
                }
                .help("Opens Terminal.app in this folder")
                Button("Run Agent Here…") {
                    AgentRunCoordinator.shared.presentRunAgent(context: context)
                }
                Button("Open in Cursor") {
                    WorkspaceActions.openInCursor(at: navigation.current)
                }
            }
        }
    }

    private var emptySearchDescription: String {
        switch search.scope {
        case .currentFolder:
            return "No matches in \(navigation.current.name)"
        case .global:
            return "No matches in your home folder"
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func entryContextMenu(anchor: FileEntry) -> some View {
        let targets = previewTargets(for: anchor)

        if canOpen(targets) {
            Button(targets.count == 1 ? "Open" : "Open \(targets.count) Items") {
                commitContextSelection(anchor: anchor)
                openTargets(previewTargets(for: anchor), fromDoubleClick: false)
            }
        }

        if targets.count == 1, let only = targets.first, !only.isBrowsable, let fileURL = only.localURL {
            openWithMenu(for: fileURL)
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

        if isSearchActive, targets.count == 1, let only = targets.first, let parent = only.id.parent {
            Button("Show Enclosing Folder") {
                commitContextSelection(anchor: anchor)
                pendingSelection = only.id
                clearSearch()
                navigate(to: parent)
            }
        }

        let localURLs = targets.compactMap(\.localURL)
        if localURLs.count == targets.count {
            Button("Show in Finder") {
                commitContextSelection(anchor: anchor)
                WorkspaceActions.revealInFinder(previewTargets(for: anchor).map(\.id))
            }
        }

        if targets.allSatisfy({ $0.localURL != nil }) {
            Button("Quick Look") {
                commitContextSelection(anchor: anchor)
                _ = toggleQuickLook()
            }
        }

        if canQuickDiff(targets) {
            Button("Quick Diff…") {
                commitContextSelection(anchor: anchor)
                presentQuickDiff(for: previewTargets(for: anchor))
            }
            .keyboardShortcut("d", modifiers: .command)
        }

        if capabilities.contains(.transfer), !targets.isEmpty {
            Button(targets.count == 1 ? "Copy" : "Copy \(targets.count) Items") {
                commitContextSelection(anchor: anchor)
                copySelection()
            }
            .keyboardShortcut("c", modifiers: .command)

            Button("Cut") {
                commitContextSelection(anchor: anchor)
                cutSelection()
            }
            .keyboardShortcut("x", modifiers: .command)
        }

        if localURLs.count == targets.count, !localURLs.isEmpty {
            if targets.count == 1, let onlyURL = localURLs.first, ArchiveNameResolver.isSupportedArchive(onlyURL) {
                Button("Extract Archive") {
                    commitContextSelection(anchor: anchor)
                    extractArchive(onlyURL)
                }
            }
            Button(targets.count == 1 ? "Compress \"\(targets[0].name)\"" : "Compress \(targets.count) Items") {
                commitContextSelection(anchor: anchor)
                compressItems(localURLs)
            }
        }

        if capabilities.contains(.rename),
           targets.count == 1,
           let only = targets.first
        {
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
                    favorites.add(items: toAdd.map(\.id))
                }
            }
        }

        Divider()

        Button(targets.count > 1 ? "Copy File Paths" : "Copy File Path") {
            commitContextSelection(anchor: anchor)
            WorkspaceActions.copyPaths(previewTargets(for: anchor).map(\.id))
        }
        Button(targets.count > 1 ? "Copy Names" : "Copy Name") {
            commitContextSelection(anchor: anchor)
            WorkspaceActions.copyNames(previewTargets(for: anchor).map(\.id))
        }

        Divider()

        if localURLs.count == targets.count {
            Button("Open Terminal Here") {
                commitContextSelection(anchor: anchor)
                let resolved = previewTargets(for: anchor)
                WorkspaceActions.openTerminal(
                    context: WorkspaceActions.executionContext(for: resolved)
                )
            }
            .help(targets.count > 1 ? "Opens at the shared folder for this selection" : "Opens Terminal.app in this folder")

            Button("Run Agent Here…") {
                commitContextSelection(anchor: anchor)
                let resolved = previewTargets(for: anchor)
                AgentRunCoordinator.shared.presentRunAgent(
                    context: WorkspaceActions.executionContext(for: resolved)
                )
            }

            Button("Open in Cursor") {
                commitContextSelection(anchor: anchor)
                let resolved = previewTargets(for: anchor)
                WorkspaceActions.openInCursor(
                    at: WorkspaceActions.executionContext(for: resolved).workingDirectory
                )
            }
        }

        Divider()

        if capabilities.contains(.metadata) {
            Button(targets.count > 1 ? "Get Info (\(targets.count))…" : "Get Info…") {
                commitContextSelection(anchor: anchor)
                showInfo(for: previewTargets(for: anchor))
            }
        }

        if capabilities.contains(.trash) {
            Divider()
            Button("Move to Trash", role: .destructive) {
                commitContextSelection(anchor: anchor)
                trashEntries(previewTargets(for: anchor))
            }
        } else if capabilities.contains(.remove) {
            Divider()
            Button("Delete Permanently…", role: .destructive) {
                commitContextSelection(anchor: anchor)
                permanentDeleteTargets = previewTargets(for: anchor)
            }
        }
    }

    private func previewTargets(for anchor: FileEntry) -> [FileEntry] {
        if selection.contains(anchor.id), selection.count > 1 {
            let selected = visibleEntries.filter { selection.contains($0.id) }
            return selected.isEmpty ? [anchor] : selected
        }
        return [anchor]
    }

    // MARK: - Quick Look

    /// URLs offered to Quick Look, plus the index to open on.
    ///
    /// Finder previews the whole listing when you press Space, so Up/Down walk
    /// the folder from the selected item. Anything without a local URL (remote
    /// providers) falls back to just the selection.
    private func quickLookPayload() -> (urls: [URL], startIndex: Int)? {
        let targets = selectedVisibleEntries()
        guard let anchor = targets.first, let anchorURL = anchor.localURL else { return nil }

        let allURLs = visibleEntries.compactMap(\.localURL)
        if allURLs.count == visibleEntries.count,
           let startIndex = allURLs.firstIndex(of: anchorURL)
        {
            return (allURLs, startIndex)
        }

        // Mixed/remote listing: preview only what can be previewed.
        let urls = targets.compactMap(\.localURL)
        guard urls.count == targets.count,
              let index = urls.firstIndex(of: anchorURL)
        else { return nil }
        return (urls, index)
    }

    /// Markdown and source code get Arbor's renderer (Quick Look shows raw
    /// text); everything else goes to the system preview panel.
    private func documentPreviewTarget() -> URL? {
        let targets = selectedVisibleEntries()
        guard targets.count == 1, let only = targets.first, !only.isBrowsable else { return nil }
        guard let url = only.localURL, DocumentPreviewController.previewKind(for: url) != nil else {
            return nil
        }
        return url
    }

    private func toggleQuickLook() -> KeyPress.Result {
        if let document = documentPreviewTarget() {
            QuickLookController.shared.close()
            DocumentPreviewController.shared.toggle(document)
            return .handled
        }

        guard let payload = quickLookPayload() else { return .ignored }
        DocumentPreviewController.shared.close()
        // Teardown nils the callback when the panel closes or the pane goes
        // away, so this strong capture is bounded.
        QuickLookController.shared.onIndexChange = { url in
            self.syncSelectionFromQuickLook(url: url)
        }
        QuickLookController.shared.toggle(urls: payload.urls, startIndex: payload.startIndex)
        return .handled
    }

    /// Arrow keys inside the panel move the panel; mirror that in the listing.
    /// Matching is by URL because the previewed set can be a subset of the
    /// visible entries (remote items have no local URL).
    private func syncSelectionFromQuickLook(url: URL) {
        guard let index = visibleEntries.firstIndex(where: { $0.localURL == url }) else { return }
        selection = [visibleEntries[index].id]
    }

    /// Keep the panel in step when the selection changes while it is open.
    private func syncQuickLookIfOpen() {
        guard QuickLookController.shared.isVisible else { return }
        guard let payload = quickLookPayload() else {
            QuickLookController.shared.close()
            return
        }
        QuickLookController.shared.sync(urls: payload.urls, startIndex: payload.startIndex)
    }

    // MARK: - Go to Folder

    /// Root used to resolve relative input and for the sheet's hint.
    private var goToFolderRoot: URL {
        if let local = navigation.current.localURL { return local }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private func presentGoToFolder() {
        guard capabilities.contains(.list) else { return }
        showsGoToFolder = true
    }

    private func navigateToFolder(_ folder: URL, selecting file: URL?) {
        let target = LocalFileLocation.item(for: folder)
        let selectionItem = file.map { LocalFileLocation.item(for: $0) }
        pendingSelection = selectionItem

        guard target != navigation.current else {
            // Already here: refresh, then select through `pendingSelection` so
            // the selection lands after the reload rebuilds the rows.
            reload()
            return
        }
        navigate(to: target)
    }

    /// Applied by `reload()` once the destination listing exists.
    private func applyPendingSelection() {
        guard let pending = pendingSelection else { return }
        guard entries.contains(where: { $0.id == pending }) else {
            // Destination may still be loading; keep it for the next reload.
            return
        }
        selection = [pending]
        pendingSelection = nil
    }

    private func commitContextSelection(anchor: FileEntry) {
        if !(selection.contains(anchor.id) && selection.count > 1) {
            selection = [anchor.id]
        }
    }

    private func selectedVisibleEntries() -> [FileEntry] {
        visibleEntries.filter { selection.contains($0.id) }
    }

    private func canQuickDiff(_ targets: [FileEntry]) -> Bool {
        targets.count == 2
            && targets.allSatisfy { !$0.isBrowsable && $0.localURL != nil }
    }

    private func canOpen(_ targets: [FileEntry]) -> Bool {
        if targets.count == 1, targets.first?.isBrowsable == true {
            return true
        }
        return capabilities.contains(.localMaterialization)
    }

    private func presentQuickDiff(for targets: [FileEntry]) {
        guard canQuickDiff(targets),
              let left = targets[0].localURL,
              let right = targets[1].localURL
        else { return }
        quickDiffRequest = QuickDiffRequest(
            left: left,
            right: right
        )
    }

    // MARK: - Search / navigation

    private func scheduleSearch(immediate: Bool = false, skipExpansionLaunch: Bool = false) {
        search.schedule(
            folder: localPath,
            seedEntries: entries,
            showHiddenFiles: showHiddenFiles,
            immediate: immediate,
            skipExpansionLaunch: skipExpansionLaunch,
            onComplete: { validIDs in
                pruneSelection(to: validIDs)
                if isActive, search.isPresented {
                    searchFocused = true
                }
            },
            onCleared: {
                reload()
            }
        )
    }

    /// Stops an in-flight search while preserving any partial hits already found.
    private func stopSearch() {
        search.stop()
        pruneSelection(to: Set(search.hits.map(\.id)))
    }

    /// Finder behavior: Down/Up from the search field hands focus to the results,
    /// selecting the first/last hit so Return opens it.
    private func focusSearchResult(last: Bool) {
        guard isSearchActive, !visibleEntries.isEmpty else { return }
        searchFocused = false
        listFocused = true
        let index = last ? visibleEntries.index(before: visibleEntries.endIndex) : visibleEntries.startIndex
        selection = [visibleEntries[index].id]
    }

    private func clearSearch() {
        search.clear()
        searchFocused = false
        listFocused = true
        reload()
    }

    private func presentSearch() {
        guard localPath != nil, capabilities.contains(.search) else {
            transferErrorTitle = "Search Unavailable"
            transferErrorMessage = "Search is currently supported on local folders only."
            return
        }
        search.isPresented = true
        DispatchQueue.main.async {
            searchFocused = true
        }
    }

    private func dismissSearch() {
        clearSearch()
        search.isPresented = false
        listFocused = true
    }

    private func reload() {
        listingTask?.cancel()
        isLoading = true

        let requestedDirectory = navigation.current
        let options = FileProviderListingOptions(showHiddenFiles: showHiddenFiles)
        listingTask = Task {
            do {
                let provider = try FileProviderRegistry.shared.provider(for: requestedDirectory)
                let providerEntries = try await provider.list(
                    directory: requestedDirectory,
                    options: options
                )
                try Task.checkCancellation()
                guard navigation.current == requestedDirectory else {
                    return
                }

                entries = providerEntries.map { FileEntry(providerEntry: $0) }
                errorMessage = nil
                connectionRequired = nil
                hostKeyRequired = nil
                hostKeyChangedMode = false
                authenticationRequired = nil
                isLoading = false
                pruneSelection(to: Set(entries.map(\.id)))
                refreshVisibleEntries()
                applyPendingSelection()
                refreshVolumeAvailableBytes()
            } catch is CancellationError {
                return
            } catch {
                guard navigation.current == requestedDirectory else {
                    return
                }
                entries = []
                selection = []
                errorMessage = error.localizedDescription
                isLoading = false
                switch error {
                case FileProviderError.connectionRequired(let connectionID),
                     FileProviderError.connectionLost(let connectionID, _):
                    connectionRequired = connectionID
                    hostKeyRequired = nil
                    hostKeyChangedMode = false
                    authenticationRequired = nil
                case FileProviderError.hostKeyVerificationRequired(let connectionID):
                    hostKeyRequired = connectionID
                    hostKeyChangedMode = false
                    connectionRequired = nil
                    authenticationRequired = nil
                case FileProviderError.hostKeyChangedRequired(let connectionID):
                    hostKeyRequired = connectionID
                    hostKeyChangedMode = true
                    connectionRequired = nil
                    authenticationRequired = nil
                case FileProviderError.authenticationRequired(let connectionID):
                    authenticationRequired = connectionID
                    connectionRequired = nil
                    hostKeyRequired = nil
                    hostKeyChangedMode = false
                default:
                    connectionRequired = nil
                    hostKeyRequired = nil
                    hostKeyChangedMode = false
                    authenticationRequired = nil
                }
                refreshVisibleEntries()
            }
        }
    }

    private func pruneSelection(to valid: Set<ItemRef>) {
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

    private func navigate(to item: ItemRef) {
        navigation.go(to: item)
    }

    private func goBack() {
        navigation.goBack()
    }

    private func goForward() {
        navigation.goForward()
    }

    private func goToParent() {
        if let parent = navigation.current.parent {
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
        guard files.isEmpty || capabilities.contains(.localMaterialization) else {
            return
        }

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
            detailsTask?.cancel()
            let requestedItem = only.id
            detailsTask = Task {
                do {
                    let provider = try FileProviderRegistry.shared.provider(for: requestedItem)
                    let providerDetails = try await provider.details(for: requestedItem)
                    try Task.checkCancellation()
                    details = FileDetails(providerDetails: providerDetails)
                } catch is CancellationError {
                    return
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }

        detailsTask?.cancel()
        multiInfo = MultiSelectionInfo(entries: targets)
    }

    private func handleTransfer(
        _ sourceItems: [ItemRef],
        into destinationItem: ItemRef,
        operation: FileTransferOperation
    ) {
        guard !sourceItems.isEmpty else { return }
        guard capabilities.contains(.transfer) else {
            transferErrorTitle = operation.failureTitle
            transferErrorMessage = "This location does not support file transfers."
            return
        }
        let sources = sourceItems
        let destination = destinationItem

        mutationTask = Task {
            let outcome = await FileTransferService.trackedTransfer(
                sources,
                into: destination,
                operation: operation
            )

            if let message = FileTransferService.failureMessage(
                for: outcome,
                operation: operation
            ) {
                transferErrorTitle = operation.failureTitle
                transferErrorMessage = message
            }

            let newSelection = Set(outcome.transferred.map(\.to))
            if !outcome.transferred.isEmpty {
                switch operation {
                case .move:
                    undoStack.register(.move(outcome.transferred))
                case .copy:
                    undoStack.register(.copy(outcome.transferred))
                }
            }

            selection = newSelection

            let affected = FileTransferService.affectedFolders(
                for: outcome,
                destination: destination,
                operation: operation
            )
            // The notification below reloads this pane when its folder is
            // affected; reloading here as well produced a double refresh that
            // made rows jump for a frame on drop.
            if !affected.contains(navigation.current) {
                if isSearchActive {
                    scheduleSearch()
                } else {
                    reload()
                }
            }
            BrowserListingDidChange.post(folders: affected)
        }
    }

    // MARK: - Copy / Cut / Paste & Archives

    private var statusBarSummary: String {
        let selected = visibleEntries.filter { selection.contains($0.id) }
        let selectedBytes = selected.reduce(UInt64(0)) { sum, entry in
            entry.isDirectory ? sum : sum + entry.size
        }
        return StatusBarSummary.format(
            itemCount: visibleEntries.count,
            selectedCount: selected.count,
            selectedBytes: selectedBytes,
            availableBytes: volumeAvailableBytes
        )
    }

    private func refreshVolumeAvailableBytes() {
        guard let localPath else {
            volumeAvailableBytes = nil
            return
        }
        Task.detached(priority: .utility) {
            let values = try? localPath.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let free = values?.volumeAvailableCapacityForImportantUsage
            await MainActor.run {
                self.volumeAvailableBytes = free
            }
        }
    }

    @ViewBuilder
    private func openWithMenu(for fileURL: URL) -> some View {
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
        if !apps.isEmpty {
            let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: fileURL)
            let sortedApps = apps.sorted { lhs, rhs in
                if lhs == defaultApp { return true }
                if rhs == defaultApp { return false }
                return lhs.deletingPathExtension().lastPathComponent
                    .localizedCaseInsensitiveCompare(rhs.deletingPathExtension().lastPathComponent) == .orderedAscending
            }
            Menu("Open With") {
                ForEach(sortedApps.prefix(12), id: \.self) { appURL in
                    let appName = appURL.deletingPathExtension().lastPathComponent
                    let isDefault = (appURL == defaultApp)
                    Button {
                        NSWorkspace.shared.open(
                            [fileURL],
                            withApplicationAt: appURL,
                            configuration: NSWorkspace.OpenConfiguration()
                        )
                    } label: {
                        Label {
                            Text(isDefault ? "\(appName) (default)" : appName)
                        } icon: {
                            Image(nsImage: Self.menuAppIcon(for: appURL))
                        }
                    }
                }
            }
        }
    }

    private static func menuAppIcon(for appURL: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    private func copySelection() {
        let targets = selectedVisibleEntries().map(\.id)
        guard !targets.isEmpty else { return }
        FileClipboard.shared.copy(targets)
    }

    private func cutSelection() {
        let targets = selectedVisibleEntries().map(\.id)
        guard !targets.isEmpty else { return }
        FileClipboard.shared.cut(targets)
    }

    /// Pastes copied/cut items (or external Finder pasteboard files) into the selected
    /// folder or the current folder. `forceMove == true` implements Finder's `⌘⌥V`.
    private func pasteClipboard(forceMove: Bool) {
        guard let payload = FileClipboard.shared.takeForPaste(forceMove: forceMove) else { return }
        let destination = PasteDestinationResolver.resolve(
            selectedFolders: selectedVisibleEntries().filter(\.isBrowsable).map(\.id),
            currentFolder: navigation.current
        )
        handleTransfer(payload.items, into: destination, operation: payload.operation)
    }

    private func compressItems(_ urls: [URL]) {
        guard let destinationDir = localPath ?? urls.first?.deletingLastPathComponent() else { return }
        mutationTask = Task {
            do {
                let archiveURL = try await ArchiveService.compress(urls: urls, in: destinationDir)
                let createdRef = LocalFileLocation.item(for: archiveURL)
                reload()
                selection = [createdRef]
                BrowserListingDidChange.post(folders: [LocalFileLocation.item(for: destinationDir)])
            } catch {
                transferErrorTitle = "Compress Failed"
                transferErrorMessage = error.localizedDescription
            }
        }
    }

    private func extractArchive(_ archiveURL: URL) {
        let destinationDir = localPath ?? archiveURL.deletingLastPathComponent()
        mutationTask = Task {
            do {
                let extractedURL = try await ArchiveService.extract(archiveURL: archiveURL, in: destinationDir)
                let createdRef = LocalFileLocation.item(for: extractedURL)
                reload()
                selection = [createdRef]
                BrowserListingDidChange.post(folders: [LocalFileLocation.item(for: destinationDir)])
            } catch {
                transferErrorTitle = "Extract Failed"
                transferErrorMessage = error.localizedDescription
            }
        }
    }

    private func requestPermanentDeleteSelection() {
        let targets = visibleEntries.filter { selection.contains($0.id) }
        guard !targets.isEmpty, capabilities.contains(.remove) else { return }
        permanentDeleteTargets = targets
    }

    private func beginCreateItem(_ kind: CreateItemKind) {
        guard capabilities.contains(.create), !isSearchActive else { return }
        cancelRename()
        typeAheadMatcher.reset()

        let parent = navigation.current
        let candidateName = UniqueItemNameResolver.uniqueName(
            preferred: kind.defaultName,
            existingNames: Set(entries.map(\.name)),
            isDirectory: kind == .folder
        )

        mutationTask = Task {
            do {
                let provider = try FileProviderRegistry.shared.provider(for: parent)
                let created: FileProviderEntry
                let isDirectory: Bool
                switch kind {
                case .folder:
                    created = try await provider.createDirectory(in: parent, name: candidateName)
                    isDirectory = true
                case .file:
                    created = try await provider.createFile(in: parent, name: candidateName, contents: Data())
                    isDirectory = false
                }
                undoStack.register(.create(item: created.id, isDirectory: isDirectory))

                let newEntry = FileEntry(providerEntry: created)
                if !entries.contains(where: { $0.id == newEntry.id }) {
                    entries.append(newEntry)
                    refreshVisibleEntries()
                }
                selection = [newEntry.id]
                scrollToItemRequest = (UUID(), newEntry.id)
                renameDraft = newEntry.name
                renamingItem = newEntry.id
                BrowserListingDidChange.post(folders: [parent])
            } catch {
                createErrorMessage = error.localizedDescription
            }
        }
    }

    private func performUndo() {
        guard undoStack.canUndo else { return }
        Task {
            let result = await undoStack.undo()
            if let error = result.errorMessage {
                undoErrorMessage = error
            }
            refreshAfterUndoRedo(
                selecting: result.restoredSelection,
                affectedFolders: result.affectedFolders
            )
        }
    }

    private func performRedo() {
        guard undoStack.canRedo else { return }
        Task {
            let result = await undoStack.redo()
            if let error = result.errorMessage {
                undoErrorMessage = error
            }
            refreshAfterUndoRedo(
                selecting: result.restoredSelection,
                affectedFolders: result.affectedFolders
            )
        }
    }

    private func refreshAfterUndoRedo(
        selecting selectedItems: Set<ItemRef>,
        affectedFolders affectedItems: [ItemRef]
    ) {
        cancelRename()
        if isSearchActive {
            scheduleSearch()
        } else {
            reload()
        }
        selection = selectedItems
        var folders = affectedItems
        folders.append(navigation.current)
        folders.append(contentsOf: selectedItems.compactMap(\.parent))
        BrowserListingDidChange.post(folders: folders)
    }

    // MARK: - Trash

    @discardableResult
    private func moveSelectionToTrash() -> KeyPress.Result {
        let targets = visibleEntries.filter { selection.contains($0.id) }
        guard !targets.isEmpty else { return .ignored }
        // Providers without Trash (e.g. SSH) permanently delete instead.
        guard capabilities.contains(.trash) else {
            guard capabilities.contains(.remove) else { return .ignored }
            permanentDeleteTargets = targets
            return .handled
        }
        trashEntries(targets)
        return .handled
    }

    private func trashEntries(_ entries: [FileEntry]) {
        guard !entries.isEmpty else { return }
        cancelRename()
        let items = entries.map(\.id)

        mutationTask = Task {
            var trashed: [ItemRef] = []
            var undoable: [(from: ItemRef, trashItem: ItemRef)] = []
            var failed: [(ItemRef, Error)] = []

            for item in items {
                do {
                    let provider = try FileProviderRegistry.shared.provider(for: item)
                    let receipt = try await provider.trash(item)
                    trashed.append(receipt.original)
                    if let trashItem = receipt.trashedItem {
                        undoable.append((receipt.original, trashItem))
                    }
                } catch {
                    failed.append((item, error))
                }
            }

            if !failed.isEmpty {
                let names = failed.map { $0.0.name }.joined(separator: ", ")
                transferErrorTitle = "Move to Trash Failed"
                transferErrorMessage = trashed.isEmpty
                    ? "Could not move to Trash: \(names)"
                    : "Some items could not be moved to Trash: \(names)"
            }

            if !undoable.isEmpty {
                undoStack.register(.trash(undoable))
            }

            if isSearchActive {
                scheduleSearch()
            } else {
                reload()
            }
            selection = []
            BrowserListingDidChange.post(folders: trashed.compactMap(\.parent))
        }
    }

    private func permanentlyDeletePendingItems() {
        let items = permanentDeleteTargets.map(\.id)
        permanentDeleteTargets = []
        guard !items.isEmpty else { return }
        mutationTask = Task {
            var removed: [ItemRef] = []
            var failed: [ItemRef] = []
            for item in items {
                do {
                    let provider = try FileProviderRegistry.shared.provider(for: item)
                    try await provider.remove(item)
                    removed.append(item)
                } catch {
                    failed.append(item)
                }
            }
            if !failed.isEmpty {
                transferErrorTitle = "Delete Failed"
                transferErrorMessage = "Could not permanently delete: \(failed.map(\.name).joined(separator: ", "))"
            }
            reload()
            selection = []
            BrowserListingDidChange.post(folders: removed.compactMap(\.parent))
        }
    }

    // MARK: - Rename
    private func handleNameClick(_ entry: FileEntry) {
        if renamingItem == entry.id { return }

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
        guard capabilities.contains(.rename) else { return }
        selection = [entry.id]
        renameDraft = entry.name
        renamingItem = entry.id
    }

    private func cancelRename() {
        renamingItem = nil
        renameDraft = ""
    }

    private func commitRename() {
        guard let renamingItem else { return }
        let source = renamingItem
        let draft = renameDraft
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            renameErrorMessage = FileOperations.RenameError.emptyName.localizedDescription
            return
        }
        guard !trimmed.contains("/") else {
            renameErrorMessage = FileOperations.RenameError.invalidName.localizedDescription
            return
        }

        mutationTask = Task {
            do {
                let provider = try FileProviderRegistry.shared.provider(for: source)
                let receipt = try await provider.rename(source, to: trimmed)
                cancelRename()
                if receipt.from != receipt.to {
                    undoStack.register(.rename(from: receipt.from, to: receipt.to))
                }
                if isSearchActive {
                    scheduleSearch()
                } else {
                    reload()
                }
                selection = [receipt.to]
                BrowserListingDidChange.post(folders: [
                    receipt.from.parent,
                    receipt.to.parent,
                ].compactMap { $0 })
            } catch FileProviderError.alreadyExists {
                renameErrorMessage = FileOperations.RenameError.nameExists(trimmed).localizedDescription
            } catch {
                renameErrorMessage = error.localizedDescription
            }
        }
    }

    /// Other panes / tabs showing an affected folder should refresh without remounting.
    private func handleRemoteListingChange(_ folders: [ItemRef]) {
        let affected = Set(folders)
        guard affected.contains(navigation.current) else { return }
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
    var folderItem: ItemRef

    func body(content: Content) -> some View {
        // Always apply the same modifier chain so activating a split pane does not
        // remount the browser (which re-ran onAppear → reload and snapped scroll to top).
        content
            .focusedSceneValue(\.browserDisplaySettings, isActive ? displaySettings : nil)
            .focusedSceneValue(\.browserFolderItem, isActive ? folderItem : nil)
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

private struct FileBrowserAlertsModifier: ViewModifier {
    var transferErrorTitle: String
    @Binding var transferErrorMessage: String?
    @Binding var createErrorMessage: String?
    @Binding var undoErrorMessage: String?
    @Binding var renameErrorMessage: String?
    @Binding var permanentDeleteTargets: [FileEntry]
    var onConfirmPermanentDelete: () -> Void

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
            .alert(
                "Delete Permanently?",
                isPresented: Binding(
                    get: { !permanentDeleteTargets.isEmpty },
                    set: { if !$0 { permanentDeleteTargets = [] } }
                )
            ) {
                Button("Cancel", role: .cancel) { permanentDeleteTargets = [] }
                Button("Delete", role: .destructive) { onConfirmPermanentDelete() }
            } message: {
                Text("This will permanently delete \(permanentDeleteTargets.count == 1 ? "“\(permanentDeleteTargets[0].name)”" : "\(permanentDeleteTargets.count) items"). This action cannot be undone.")
            }
    }
}

struct MultiSelectionInfo: Identifiable {
    let id = UUID()
    let entries: [FileEntry]

    var fileCount: Int { entries.filter { !$0.isDirectory || $0.isPackage }.count }
    var folderCount: Int { entries.filter { $0.isBrowsable }.count }

    var totalSize: UInt64 {
        entries.reduce(into: UInt64(0)) { partial, entry in
            if !entry.isDirectory {
                partial += entry.size
            }
        }
    }
}

private struct MultiSelectionInfoView: View {
    let info: MultiSelectionInfo
    @Environment(\.dismiss) private var dismiss
    @State private var folderBytes: UInt64 = 0
    @State private var isCalculatingFolders = false

    private var localFolderURLs: [URL] {
        info.entries.compactMap { entry in
            guard entry.isDirectory else { return nil }
            return FileProviderRegistry.shared.intrinsicLocalURL(for: entry.id)
        }
    }

    private var displayedSize: String {
        let total = info.totalSize + folderBytes
        let formatted = ByteCountFormatter.string(
            fromByteCount: Int64(min(total, UInt64(Int64.max))),
            countStyle: .file
        )
        return isCalculatingFolders ? "Calculating… \(formatted)" : formatted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(info.entries.count) Items Selected")
                .font(.headline)

            LabeledContent("Folders", value: "\(info.folderCount)")
            LabeledContent("Files", value: "\(info.fileCount)")
            LabeledContent("Size") {
                HStack(spacing: 6) {
                    if isCalculatingFolders {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(displayedSize)
                        .monospacedDigit()
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340, height: 210)
        .task(id: info.id) {
            let urls = localFolderURLs
            guard !urls.isEmpty else { return }
            isCalculatingFolders = true
            var accumulated: UInt64 = 0
            for url in urls {
                if Task.isCancelled { break }
                let base = accumulated
                let final = await FolderSizeCalculator.calculate(url: url) { snapshot in
                    Task { @MainActor in
                        self.folderBytes = base + snapshot.totalBytes
                    }
                }
                accumulated += final.totalBytes
                folderBytes = accumulated
            }
            if !Task.isCancelled {
                isCalculatingFolders = false
            }
        }
    }
}

extension FileDetails: Identifiable {
    var id: ItemRef { item }
}
