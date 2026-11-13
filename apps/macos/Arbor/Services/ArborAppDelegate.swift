import AppKit

/// Dock menu + reopen when no Arbor windows are visible.
final class ArborAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Synchronous: pending snapshots must exist before WindowGroup builds ContentView.
        MainActor.assumeIsolated {
            _ = SSHLocationStore.shared
            BrowserSessionStore.shared.prepareForLaunch()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            // Open exactly one window ourselves. Returning `true` would also let
            // SwiftUI's WindowGroup create another → duplicate windows.
            // Do not re-run launch session restore here.
            Task { @MainActor in
                WindowLaunchCoordinator.openNewWindow(onActiveSpace: true)
            }
            return false
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            BrowserSessionStore.shared.saveNow()
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            BrowserSessionStore.shared.saveNow()
        }
    }

    /// Finder-style Dock right-click menu.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "New Window",
            action: #selector(newWindowFromDock(_:)),
            keyEquivalent: ""
        )
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func newWindowFromDock(_ sender: Any?) {
        Task { @MainActor in
            // Prefer the desktop the user is standing on, not the Space that
            // already hosts another Arbor window.
            WindowLaunchCoordinator.openNewWindow(onActiveSpace: true)
        }
    }
}
