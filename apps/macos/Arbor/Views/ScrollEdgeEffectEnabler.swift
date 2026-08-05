import AppKit
import SwiftUI

/// Ensures AppKit scroll views get Tahoe’s native soft scroll-edge underlap.
///
/// The system soft edge is what non-split windows use under the toolbar. Custom
/// `NSVisualEffectView` overlays look different and can stack with leftover native
/// blur. On some hierarchies (notably the trailing `HSplitView` column) the edge
/// effect only attaches once the scroll view has a vertical scroller enabled.
struct ScrollEdgeEffectEnabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            Self.enableNativeSoftEdge(near: nsView)
        }
    }

    private static func enableNativeSoftEdge(near probe: NSView) {
        var root: NSView = probe
        for _ in 0..<14 {
            guard let parent = root.superview else { break }
            // Stay inside this split column / browser pane.
            if parent is NSSplitView { break }
            root = parent
        }

        for scroll in scrollViews(in: root) {
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
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
