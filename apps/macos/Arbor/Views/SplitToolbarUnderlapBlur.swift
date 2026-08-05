import AppKit
import SwiftUI

/// Soft top underlap drawn **per split pane**.
///
/// Native scroll-edge blur only attaches to the leading `HSplitView` column, and a
/// single overlay spanning the split cannot sample the trailing column. Each pane
/// blurs its own content; `.ignoresSafeArea(.top)` lifts the fade into the toolbar band.
struct SplitToolbarUnderlapBlur: View {
    /// Tall enough to cover the toolbar underlap + a soft fade into the icon grid.
    var height: CGFloat = 120

    var body: some View {
        WithinWindowBlurView()
            .frame(maxWidth: .infinity)
            .frame(height: height, alignment: .top)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.95), location: 0.28),
                        .init(color: .black.opacity(0.55), location: 0.55),
                        .init(color: .black.opacity(0.18), location: 0.78),
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

/// Blurs sibling content beneath it within the same pane.
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
