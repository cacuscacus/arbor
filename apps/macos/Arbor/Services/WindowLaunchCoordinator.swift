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
    }

    static func openNewWindow(cloning folder: URL? = nil) {
        let root = (folder ?? FileManager.default.homeDirectoryForCurrentUser)
            .standardizedFileURL
        openBrowserWindow?(root)
    }
}
