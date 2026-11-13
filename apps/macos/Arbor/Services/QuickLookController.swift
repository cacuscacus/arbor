import AppKit
import Quartz

/// App-wide Quick Look driver (the preview panel is a single app-level panel).
///
/// Finder semantics we mirror:
/// - Space toggles Quick Look for the current selection.
/// - While open, Up/Down moves through the previewed items and keeps the
///   browser selection in sync.
/// - Space, Escape, or the panel's close button dismiss it.
///
/// Only local files can be previewed: the panel needs a file URL, so remote
/// items stay capability-gated by the caller.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    /// URLs currently offered to the panel, in listing order.
    private(set) var urls: [URL] = []

    /// Called when arrow keys move the preview, so the browser can follow.
    var onIndexChange: ((Int) -> Void)?

    private var monitor: Any?

    private var panel: QLPreviewPanel? { QLPreviewPanel.shared() }

    var isVisible: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return false }
        return panel?.isVisible ?? false
    }

    // MARK: - Presentation

    /// Space behavior: close if already showing these items, otherwise (re)open.
    func toggle(urls newURLs: [URL], startIndex: Int) {
        guard !newURLs.isEmpty else {
            close()
            return
        }
        if isVisible, newURLs == urls {
            close()
            return
        }
        show(urls: newURLs, startIndex: startIndex)
    }

    func show(urls newURLs: [URL], startIndex: Int) {
        guard !newURLs.isEmpty, let panel else { return }
        urls = newURLs

        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(startIndex, 0), newURLs.count - 1)
        panel.makeKeyAndOrderFront(nil)

        installMonitor()
        // Re-registering without removing would stack observers across reopens.
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: panel
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: panel
        )
    }

    /// Keep the open panel in sync when the browser selection changes.
    func sync(urls newURLs: [URL], startIndex: Int) {
        guard isVisible, let panel else { return }
        guard !newURLs.isEmpty else {
            close()
            return
        }
        let index = min(max(startIndex, 0), newURLs.count - 1)
        if newURLs == urls {
            if panel.currentPreviewItemIndex != index {
                panel.currentPreviewItemIndex = index
            }
            return
        }
        urls = newURLs
        panel.currentPreviewItemIndex = index
        panel.reloadData()
    }

    func close() {
        if let panel, isVisible {
            panel.orderOut(nil)
        }
        teardown()
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            guard urls.indices.contains(index) else { return nil }
            return urls[index] as NSURL
        }
    }

    // MARK: - Keyboard while the panel is key

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            // Typing shortcuts (⌘…) should still reach the app.
            let flags = event.modifierFlags.intersection([.command, .option, .control])
            guard flags.isEmpty else { return event }

            switch event.keyCode {
            case 49, 53: // space, escape
                self.close()
                return nil
            case 125: // down
                self.step(by: 1)
                return nil
            case 126: // up
                self.step(by: -1)
                return nil
            default:
                return event
            }
        }
    }

    private func step(by delta: Int) {
        guard urls.count > 1, let panel else { return }
        let next = min(max(panel.currentPreviewItemIndex + delta, 0), urls.count - 1)
        guard next != panel.currentPreviewItemIndex else { return }
        panel.currentPreviewItemIndex = next
        onIndexChange?(next)
    }

    @objc private func panelWillClose(_ note: Notification) {
        MainActor.assumeIsolated {
            teardown()
        }
    }

    private func teardown() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let panel {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willCloseNotification,
                object: panel
            )
            if panel.dataSource === self { panel.dataSource = nil }
            if panel.delegate === self { panel.delegate = nil }
        }
        urls = []
    }
}
