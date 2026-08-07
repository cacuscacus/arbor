import AppKit
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
    /// How many newly opened windows should be pinned to the active Space.
    private static var pendingActiveSpacePins = 0
    /// `windowNumber` ceiling observed before `openWindow` — pin only newer windows.
    private static var activeSpacePinAfterWindowNumber = 0

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

    /// - Parameter onActiveSpace: When true (Dock → New Window), pin the created
    ///   window to the desktop the user is on, even if Arbor already has a window
    ///   on another virtual desktop.
    static func openNewWindow(cloning folder: URL? = nil, onActiveSpace: Bool = false) {
        // Guard against reopen + WindowGroup both firing in the same gesture.
        let now = Date()
        if let lastOpenAt, now.timeIntervalSince(lastOpenAt) < 0.45 {
            return
        }
        lastOpenAt = now

        let root = (folder ?? lastFocusedFolder ?? FileManager.default.homeDirectoryForCurrentUser)
            .standardizedFileURL
        if onActiveSpace {
            pendingActiveSpacePins += 1
            activeSpacePinAfterWindowNumber = NSApp.windows.map(\.windowNumber).max() ?? 0
        }
        openBrowserWindow?(root)
        if onActiveSpace {
            schedulePinNewestToActiveSpace()
        }
    }

    /// Session restore: open without debounce and without enqueueing a root —
    /// `ContentView` dequeues a full `BrowserWindowSnapshot` instead.
    static func openRestoredBrowserWindow() {
        openBareBrowserWindow?()
    }

    private static func schedulePinNewestToActiveSpace(attemptsLeft: Int = 40) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            guard pendingActiveSpacePins > 0 else { return }
            let threshold = activeSpacePinAfterWindowNumber
            let candidate = NSApp.windows
                .filter { $0.windowNumber > threshold }
                .filter { window in
                    window.identifier == ArborBrowserWindow.identifier
                        || window.styleMask.contains(.titled)
                }
                .max(by: { $0.windowNumber < $1.windowNumber })

            guard let window = candidate else {
                if attemptsLeft > 0 {
                    schedulePinNewestToActiveSpace(attemptsLeft: attemptsLeft - 1)
                } else {
                    pendingActiveSpacePins = 0
                }
                return
            }
            ArborBrowserWindow.prepare(window)
            ArborBrowserWindow.pinToActiveSpace(window)
            activeSpacePinAfterWindowNumber = max(activeSpacePinAfterWindowNumber, window.windowNumber)
            pendingActiveSpacePins = max(0, pendingActiveSpacePins - 1)
            if pendingActiveSpacePins > 0, attemptsLeft > 0 {
                schedulePinNewestToActiveSpace(attemptsLeft: attemptsLeft - 1)
            }
        }
    }
}
