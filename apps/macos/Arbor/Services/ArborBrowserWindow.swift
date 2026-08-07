import AppKit

/// Marks and targets SwiftUI browser `WindowGroup` windows (not About / Settings).
enum ArborBrowserWindow {
    static let identifier = NSUserInterfaceItemIdentifier("arbor.browser")

    static func prepare(_ window: NSWindow) {
        window.identifier = identifier
    }

    static var all: [NSWindow] {
        NSApp.windows.filter { $0.identifier == identifier }
    }

    /// Newest browser window by `windowNumber` (creation order).
    static var newest: NSWindow? {
        all.max(by: { $0.windowNumber < $1.windowNumber })
    }

    /// Force a window onto the Space the user is currently looking at.
    ///
    /// When Arbor already has a window on another desktop, AppKit often activates
    /// that Space first; `openWindow` then creates the new window there. Briefly
    /// joining all Spaces, ordering front on the *current* Space, then leaving
    /// all-spaces pins the window where the user asked from (Dock → New Window).
    static func pinToActiveSpace(_ window: NSWindow) {
        var behavior = window.collectionBehavior
        behavior.insert(.canJoinAllSpaces)
        window.collectionBehavior = behavior

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        behavior.remove(.canJoinAllSpaces)
        behavior.insert(.moveToActiveSpace)
        window.collectionBehavior = behavior
    }
}
