import Foundation

/// Browser-style back/forward stack for folder navigation.
@Observable
final class BrowserNavigation {
    private(set) var current: URL
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    init(initial: URL = FileManager.default.homeDirectoryForCurrentUser) {
        current = initial.standardizedFileURL
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Records `current` on the back stack and navigates to `url`.
    func go(to url: URL) {
        let target = url.standardizedFileURL
        guard target != current else { return }
        backStack.append(current)
        forwardStack.removeAll()
        current = target
    }

    @discardableResult
    func goBack() -> URL? {
        guard let previous = backStack.popLast() else { return nil }
        forwardStack.append(current)
        current = previous
        return previous
    }

    @discardableResult
    func goForward() -> URL? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(current)
        current = next
        return next
    }
}
