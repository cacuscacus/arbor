import AppKit

/// Handles Dock reopen when no Arbor windows are visible.
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
}
