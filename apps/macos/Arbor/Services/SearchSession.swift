import Foundation
import Observation

/// Observable search state and lifecycle owned by a `BrowserPane`.
///
/// Keeping search state on the pane (instead of SwiftUI view `@State`) lets tabs
/// run searches in the background, display live spinner/count badges in the tab bar,
/// promote an inline search into its own tab without losing hits, and cancel child
/// search processes immediately when a tab closes.
@MainActor
@Observable
final class SearchSession {
    var query = ""
    var scope: SearchScope = .currentFolder
    var mode: SearchMode = .name
    var isPresented = false
    /// Set when a tab is opened specifically for searching so the field focuses on appear.
    var focusRequestToken = 0
    /// Set when an in-flight search is promoted to a new tab and should resume streaming on appear.
    var needsResumeAfterAdopt = false

    private(set) var hits: [SearchHit] = []
    private(set) var countsByRing: [SearchRing: Int] = [:]
    private(set) var activeBackend: SearchBackendKind = .inMemory
    private(set) var stopReason: SearchStopReason?
    private(set) var elapsedSeconds: Double = 0
    private(set) var isSearching = false
    private(set) var errorMessage: String?

    var limitOverride: Int?
    var timeoutOverride: Double?
    var deepGlobalContentOverride: Bool?

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var elapsedTask: Task<Void, Never>?

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isActive: Bool {
        !trimmedQuery.isEmpty
    }

    var showsPanel: Bool {
        isPresented || isActive
    }

    var activeLimit: Int {
        limitOverride ?? SearchPreferencesStore.shared.resultLimit
    }

    /// Short badge text for the tab bar pill (e.g. `"82"`, `"500+"`).
    var badgeLabel: String? {
        guard isActive else { return nil }
        if case .limitReached = stopReason {
            return "\(hits.count)+"
        }
        if hits.count >= activeLimit {
            return "\(activeLimit)+"
        }
        return "\(hits.count)"
    }

    func requestFocus() {
        isPresented = true
        focusRequestToken &+= 1
    }

    /// Pre-seeds this session by adopting state from another pane's search (Open in Tab).
    func adopt(from source: SearchSession) {
        query = source.query
        scope = source.scope
        mode = source.mode
        isPresented = true
        hits = source.hits
        countsByRing = source.countsByRing
        activeBackend = source.activeBackend
        stopReason = source.stopReason
        elapsedSeconds = source.elapsedSeconds
        errorMessage = source.errorMessage
        limitOverride = source.limitOverride
        timeoutOverride = source.timeoutOverride
        deepGlobalContentOverride = source.deepGlobalContentOverride
        focusRequestToken &+= 1
    }

    func schedule(
        folder: URL?,
        seedEntries: [FileEntry],
        showHiddenFiles: Bool,
        immediate: Bool = false,
        onComplete: @escaping (Set<ItemRef>) -> Void,
        onCleared: @escaping () -> Void
    ) {
        searchTask?.cancel()
        elapsedTask?.cancel()

        let trimmed = trimmedQuery
        guard !trimmed.isEmpty else {
            isSearching = false
            hits = []
            countsByRing = [:]
            stopReason = nil
            elapsedSeconds = 0
            errorMessage = nil
            onCleared()
            return
        }

        guard let folder else {
            errorMessage = "Search is not available for this location."
            isSearching = false
            return
        }

        let currentScope = scope
        let currentMode = mode
        let options = SearchPreferencesStore.shared.makeOptions(
            showHiddenFiles: showHiddenFiles,
            resultLimitOverride: limitOverride,
            timeoutOverride: timeoutOverride,
            deepGlobalContentOverride: deepGlobalContentOverride
        )
        let debounceMs: Int = {
            if immediate { return 0 }
            if currentMode == .content { return trimmed.count < 3 ? 350 : 220 }
            if currentScope == .global, trimmed.count == 1 { return 340 }
            return 150
        }()

        isSearching = true
        errorMessage = nil
        stopReason = nil
        elapsedSeconds = 0
        switch (currentMode, currentScope) {
        case (.name, .global): activeBackend = .spotlight
        case (.name, .currentFolder): activeBackend = .fd
        case (.content, .global):
            activeBackend = options.deepGlobalContentScan ? .ripgrep : .spotlightContent
        case (.content, .currentFolder): activeBackend = .ripgrep
        }

        let startedAt = ContinuousClock.now
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { break }
                let delta = startedAt.duration(to: ContinuousClock.now)
                let secs = Double(delta.components.seconds) + Double(delta.components.attoseconds) / 1e18
                self.elapsedSeconds = max(0, secs)
            }
        }

        searchTask = Task { [weak self] in
            if debounceMs > 0 {
                try? await Task.sleep(for: .milliseconds(debounceMs))
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }

            do {
                let stream = SearchService.searchStream(
                    query: trimmed,
                    scope: currentScope,
                    mode: currentMode,
                    currentFolder: folder,
                    seedEntries: seedEntries,
                    options: options
                )
                for try await update in stream {
                    guard !Task.isCancelled else { return }
                    self.hits = update.hits
                    self.countsByRing = update.countsByRing
                    self.activeBackend = update.activeBackend
                    self.elapsedSeconds = update.elapsedSeconds
                    if !update.isRunning {
                        self.stopReason = update.stopReason
                        self.isSearching = false
                        self.elapsedTask?.cancel()
                        onComplete(Set(update.hits.map(\.id)))
                    }
                }
            } catch is CancellationError {
                // Superseded by a newer query or stopped/closed by the user.
            } catch {
                guard !Task.isCancelled else { return }
                self.hits = []
                self.countsByRing = [:]
                self.errorMessage = error.localizedDescription
                self.stopReason = nil
                self.isSearching = false
                self.elapsedTask?.cancel()
                onComplete([])
            }
        }
    }

    /// Stops an in-flight search while keeping all partial results visible.
    func stop() {
        guard isSearching else { return }
        searchTask?.cancel()
        elapsedTask?.cancel()
        isSearching = false
        stopReason = .stoppedByUser
    }

    /// Cancels everything without touching UI state (called on tab close).
    func cancel() {
        searchTask?.cancel()
        elapsedTask?.cancel()
        searchTask = nil
        elapsedTask = nil
        isSearching = false
    }

    func resetOverrides() {
        limitOverride = nil
        timeoutOverride = nil
        deepGlobalContentOverride = nil
    }

    func clear() {
        cancel()
        query = ""
        hits = []
        countsByRing = [:]
        stopReason = nil
        elapsedSeconds = 0
        limitOverride = nil
        timeoutOverride = nil
        deepGlobalContentOverride = nil
        errorMessage = nil
    }
}
