import Foundation
import CoreGraphics

/// One place in a pane’s Back/Forward history, including the scroll offset when we left it.
struct FolderHistoryEntry: Equatable {
    var item: ItemRef
    var scrollY: CGFloat

    init(item: ItemRef, scrollY: CGFloat = 0) {
        self.item = item
        self.scrollY = max(0, scrollY)
    }
}

/// How to place the scroll view after a navigation change.
enum FolderScrollRestore: Equatable {
    /// Rest at the default top (do not fight toolbar insets / soft-edge layout).
    case top
    /// Absolute vertical document offset to restore after content loads.
    case offset(CGFloat)
}

/// Browser-style back/forward stack for folder navigation (Finder-like scroll restore).
@Observable
final class BrowserNavigation {
    private(set) var current: ItemRef
    private var backStack: [FolderHistoryEntry] = []
    private var forwardStack: [FolderHistoryEntry] = []

    /// Live vertical scroll for the open folder (kept current by the browser views).
    /// Ignored by Observation so scroll ticks do not invalidate SwiftUI (major jank source).
    @ObservationIgnored
    var scrollY: CGFloat = 0

    private(set) var pendingScrollRestore: FolderScrollRestore?
    /// Bumped whenever a restore should be attempted.
    private(set) var scrollRestoreToken: UInt = 0

    init(initial: ItemRef) {
        current = initial
    }

    convenience init(initial: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(initial: LocalFileLocation.item(for: initial))
    }

    /// Local compatibility bridge while browser views migrate to ItemRef.
    var currentLocalURL: URL? { current.localURL }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func noteScrollY(_ y: CGFloat) {
        scrollY = max(0, y)
    }

    /// Records `current` (with live scroll) on the back stack and navigates.
    func go(to target: ItemRef) {
        guard target != current else { return }
        backStack.append(FolderHistoryEntry(item: current, scrollY: scrollY))
        forwardStack.removeAll()
        current = target
        scrollY = 0
        // Fresh folder: content `.id(path)` remounts at the system resting top.
        // Do not force NSScrollView y=0 — that parks icons under the toolbar glass.
        pendingScrollRestore = nil
    }

    func go(to url: URL) {
        go(to: LocalFileLocation.item(for: url))
    }

    @discardableResult
    func goBack() -> ItemRef? {
        guard let previous = backStack.popLast() else { return nil }
        // Snapshot before any view updates can publish a remounted scroller’s y=0.
        let leaving = FolderHistoryEntry(item: current, scrollY: scrollY)
        forwardStack.append(leaving)
        current = previous.item
        scrollY = previous.scrollY
        requestScrollRestore(previous.scrollY < 1 ? .top : .offset(previous.scrollY))
        return previous.item
    }

    @discardableResult
    func goForward() -> ItemRef? {
        guard let next = forwardStack.popLast() else { return nil }
        let leaving = FolderHistoryEntry(item: current, scrollY: scrollY)
        backStack.append(leaving)
        current = next.item
        scrollY = next.scrollY
        requestScrollRestore(next.scrollY < 1 ? .top : .offset(next.scrollY))
        return next.item
    }

    func consumePendingScrollRestore() -> FolderScrollRestore? {
        defer { pendingScrollRestore = nil }
        return pendingScrollRestore
    }

    private func requestScrollRestore(_ restore: FolderScrollRestore) {
        pendingScrollRestore = restore
        scrollRestoreToken &+= 1
    }
}
