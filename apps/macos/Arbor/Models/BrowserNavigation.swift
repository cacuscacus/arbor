import Foundation
import CoreGraphics

/// One place in a pane’s Back/Forward history, including the scroll offset when we left it.
/// `scrollY` is distance scrolled **past** the natural top resting position (toolbar insets preserved).
struct FolderHistoryEntry: Equatable {
    var url: URL
    var scrollY: CGFloat

    init(url: URL, scrollY: CGFloat = 0) {
        self.url = url.standardizedFileURL
        self.scrollY = max(0, scrollY)
    }
}

/// How to place the scroll view after a navigation change.
enum FolderScrollRestore: Equatable {
    /// Rest at the system “top” (respects toolbar / safe-area content insets).
    case top
    /// Distance below that resting top.
    case offset(CGFloat)
}

/// Browser-style back/forward stack for folder navigation (Finder-like scroll restore).
@Observable
final class BrowserNavigation {
    private(set) var current: URL
    private var backStack: [FolderHistoryEntry] = []
    private var forwardStack: [FolderHistoryEntry] = []

    /// Live distance past the natural top for the open folder.
    var scrollY: CGFloat = 0

    private(set) var pendingScrollRestore: FolderScrollRestore?
    /// Bumped whenever a restore should be attempted.
    private(set) var scrollRestoreToken: UInt = 0

    init(initial: URL = FileManager.default.homeDirectoryForCurrentUser) {
        current = initial.standardizedFileURL
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func noteScrollY(_ y: CGFloat) {
        scrollY = max(0, y)
    }

    /// Records `current` (with live scroll) on the back stack and navigates to `url`.
    func go(to url: URL) {
        let target = url.standardizedFileURL
        guard target != current else { return }
        backStack.append(FolderHistoryEntry(url: current, scrollY: scrollY))
        forwardStack.removeAll()
        current = target
        scrollY = 0
        // New folder → natural top (do **not** force raw y=0; that sits under the toolbar).
        requestScrollRestore(.top)
    }

    @discardableResult
    func goBack() -> URL? {
        guard let previous = backStack.popLast() else { return nil }
        forwardStack.append(FolderHistoryEntry(url: current, scrollY: scrollY))
        current = previous.url
        scrollY = previous.scrollY
        requestScrollRestore(previous.scrollY < 1 ? .top : .offset(previous.scrollY))
        return previous.url
    }

    @discardableResult
    func goForward() -> URL? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(FolderHistoryEntry(url: current, scrollY: scrollY))
        current = next.url
        scrollY = next.scrollY
        requestScrollRestore(next.scrollY < 1 ? .top : .offset(next.scrollY))
        return next.url
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
