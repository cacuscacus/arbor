import Foundation
import SwiftUI

/// Queues the root folder for the next `ContentView` instance.
///
/// SwiftUI's `WindowGroup(for:)` reuses windows for equal values, so we cannot
/// key windows by folder URL when the user wants two windows on the same path.
@MainActor
enum WindowLaunchCoordinator {
    private static var pendingRoots: [URL] = []
    private static var openBrowserWindow: ((URL) -> Void)?
    private static var openBareBrowserWindow: (() -> Void)?
    private static var lastOpenAt: Date?

    /// Last focused browser folder — used by Dock menu when SwiftUI focus is unavailable.
    private(set) static var lastFocusedFolder: URL?

    static func noteFocusedFolder(_ url: URL) {
        lastFocusedFolder = url.standardizedFileURL
    }

    static func enqueueRoot(_ url: URL) {
        pendingRoots.append(url.standardizedFileURL)
    }

    static func dequeueRoot(
        fallback: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if pendingRoots.isEmpty {
            return fallback.standardizedFileURL
        }
        return pendingRoots.removeFirst()
    }

    /// Keeps a live `openWindow` handle so Dock reopen works with zero windows.
    static func install(openWindow: OpenWindowAction) {
        openBrowserWindow = { root in
            enqueueRoot(root)
            openWindow(id: "browser")
        }
        openBareBrowserWindow = {
            openWindow(id: "browser")
        }
        // First installed window opens any remaining restored WindowGroup instances.
        BrowserSessionStore.shared.openRemainingRestoredWindowsIfNeeded()
    }

    static func openNewWindow(cloning folder: URL? = nil) {
        // Guard against reopen + WindowGroup both firing in the same gesture.
        let now = Date()
        if let lastOpenAt, now.timeIntervalSince(lastOpenAt) < 0.45 {
            return
        }
        lastOpenAt = now

        let root = (folder ?? lastFocusedFolder ?? FileManager.default.homeDirectoryForCurrentUser)
            .standardizedFileURL
        openBrowserWindow?(root)
    }

    /// Session restore: open without debounce and without enqueueing a root —
    /// `ContentView` dequeues a full `BrowserWindowSnapshot` instead.
    static func openRestoredBrowserWindow() {
        openBareBrowserWindow?()
    }
}
