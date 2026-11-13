import AppKit
import SwiftUI

/// Routes Down/Up from the focused search field into the result list, Finder-style.
///
/// `NSTextField` consumes arrow keys before SwiftUI's `.onKeyPress` sees them, so a
/// local event monitor is the reliable hook. It only runs while the search field is
/// focused *and* there are results, and it swallows the arrow so the caret does not
/// move at the same time.
struct SearchResultKeyMonitor: NSViewRepresentable {
    var isActive: Bool
    var onMoveDown: () -> Void
    var onMoveUp: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.isActive = isActive
        context.coordinator.onMoveDown = onMoveDown
        context.coordinator.onMoveUp = onMoveUp
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.onMoveDown = onMoveDown
        context.coordinator.onMoveUp = onMoveUp
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var isActive = false
        var onMoveDown: (() -> Void)?
        var onMoveUp: (() -> Void)?

        private var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isActive else { return event }

                // Ignore shortcut-modified arrows; only plain Down/Up should
                // hand focus to the results.
                let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
                guard flags.isEmpty else { return event }

                switch event.keyCode {
                case 125: // down arrow
                    self.onMoveDown?()
                    return nil
                case 126: // up arrow
                    self.onMoveUp?()
                    return nil
                default:
                    return event
                }
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            uninstall()
        }
    }
}
