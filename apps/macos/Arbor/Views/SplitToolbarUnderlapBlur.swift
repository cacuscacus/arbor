import AppKit
import SwiftUI

/// Full-width soft underlap for split detail — `HSplitView` only attaches native
/// scroll-edge blur to the leading column, so we draw one shared within-window blur.
struct SplitToolbarUnderlapBlur: View {
    var height: CGFloat = 72

    var body: some View {
        WithinWindowBlurView()
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.92), location: 0.35),
                        .init(color: .black.opacity(0.45), location: 0.7),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Blurs sibling content beneath it (both split panes) without flattening the window chrome.
private struct WithinWindowBlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .headerView
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = true
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .headerView
        nsView.blendingMode = .withinWindow
        nsView.state = .active
    }
}
