import Foundation
import CoreGraphics

/// One place in a pane’s Back/Forward history, including the scroll offset when we left it.
struct FolderHistoryEntry: Equatable {
    var url: URL
    var scrollY: CGFloat

    init(url: URL, scrollY: CGFloat = 0) {
        self.url = url.standardizedFileURL
        self.scrollY = max(0, scrollY)
    }
}

/// Browser-style back/forward stack for folder navigation (Finder-like scroll restore).
@Observable
final class BrowserNavigation {
    private(set) var current: URL
    private var backStack: [FolderHistoryEntry] = []
    private var forwardStack: [FolderHistoryEntry] = []

    /// Live vertical scroll for the open folder (kept current by the browser views).
    var scrollY: CGFloat = 0

    /// Applied once after content for `current` finishes loading; then cleared.
    private(set) var pendingScrollRestoreY: CGFloat?
    /// Bumped whenever a restore should be attempted (including “scroll to top”).
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
        requestScrollRestore(0)
    }

    @discardableResult
    func goBack() -> URL? {
        guard let previous = backStack.popLast() else { return nil }
        forwardStack.append(FolderHistoryEntry(url: current, scrollY: scrollY))
        current = previous.url
        scrollY = previous.scrollY
        requestScrollRestore(previous.scrollY)
        return previous.url
    }

    @discardableResult
    func goForward() -> URL? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(FolderHistoryEntry(url: current, scrollY: scrollY))
        current = next.url
        scrollY = next.scrollY
        requestScrollRestore(next.scrollY)
        return next.url
    }

    func consumePendingScrollRestore() -> CGFloat? {
        defer { pendingScrollRestoreY = nil }
        return pendingScrollRestoreY
    }

    private func requestScrollRestore(_ y: CGFloat) {
        pendingScrollRestoreY = max(0, y)
        scrollRestoreToken &+= 1
    }
}
