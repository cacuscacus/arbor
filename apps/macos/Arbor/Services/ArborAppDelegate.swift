import AppKit

/// Dock menu + reopen when no Arbor windows are visible.
final class ArborAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            Task { @MainActor in
                WindowLaunchCoordinator.openNewWindow()
            }
        }
        return true
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
            WindowLaunchCoordinator.openNewWindow()
        }
    }
}
