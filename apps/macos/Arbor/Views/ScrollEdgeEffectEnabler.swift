import AppKit
import SwiftUI

/// Ensures AppKit scroll views get Tahoe’s native soft scroll-edge underlap.
///
/// The system soft edge is what non-split windows use under the toolbar. Custom
/// `NSVisualEffectView` overlays look different and can stack with leftover native
/// blur. On some hierarchies (notably the trailing `HSplitView` column) the edge
/// effect only attaches once the scroll view has a vertical scroller enabled.
///
/// Re-scans when new scroll views appear (e.g. switching list ↔ icons) so each
/// AppKit scroller gets configured — not just the first one observed.
struct ScrollEdgeEffectEnabler: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Cheap if nothing new; picks up remounted AppKit icon/list scrollers.
        DispatchQueue.main.async {
            context.coordinator.enableNewScrollViews(near: nsView)
        }
    }

    final class Coordinator {
        private var configured = Set<ObjectIdentifier>()

        func enableNewScrollViews(near probe: NSView) {
            var root: NSView = probe
            for _ in 0..<14 {
                guard let parent = root.superview else { break }
                // Stay inside this split column / browser pane.
                if parent is NSSplitView { break }
                root = parent
            }

            for scroll in Self.scrollViews(in: root) {
                let id = ObjectIdentifier(scroll)
                guard !configured.contains(id) else { continue }
                configured.insert(id)
                scroll.hasVerticalScroller = true
                scroll.autohidesScrollers = true
                scroll.scrollerStyle = .overlay
                // Leave `automaticallyAdjustsContentInsets` alone so each scroll
                // view keeps its own inset strategy (SwiftUI `Table` uses native
                // safe-area insets; `IconCollectionView` uses flow `sectionInset`).
                scroll.drawsBackground = false
                scroll.contentView.drawsBackground = false
            }

            // Drop stale IDs for deallocated scroll views (ObjectIdentifier reuse risk is low
            // and next pass re-enables correctly if needed).
            if configured.count > 16 {
                configured = Set(
                    Self.scrollViews(in: root).map { ObjectIdentifier($0) }
                )
            }
        }

        private static func scrollViews(in root: NSView) -> [NSScrollView] {
            var found: [NSScrollView] = []
            var stack: [NSView] = [root]
            while let view = stack.popLast() {
                if let scroll = view as? NSScrollView {
                    found.append(scroll)
                }
                stack.append(contentsOf: view.subviews)
            }
            return found
        }
    }
}
