import AppKit
import SwiftUI

/// Minimal window tweak only — do **not** paint custom titlebar / materials.
/// On macOS Tahoe, custom chrome kills Liquid Glass (flat beige bars).
struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            Self.apply(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            Self.apply(to: nsView.window)
        }
    }

    private static func apply(to window: NSWindow?) {
        guard let window else { return }
        // Leave titlebar / glass / backgrounds to the system.
        if let split = firstSplitView(in: window.contentView) {
            split.dividerStyle = .thin
            split.focusRingType = .none
        }
    }

    private static func firstSplitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView { return split }
        for child in view.subviews {
            if let found = firstSplitView(in: child) {
                return found
            }
        }
        return nil
    }
}
