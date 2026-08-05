import AppKit
import SwiftUI

/// Soft top underlap drawn **per split pane** (only effect under the toolbar in spit).
///
/// Native scroll-edge / Liquid Glass underlap only soft-blurs the leading `HSplitView`
/// column and would stack with this overlay. Split panes use a hard native edge and
/// this fade alone so both sides match without a double blur.
struct SplitToolbarUnderlapBlur: View {
    /// Cover the toolbar band and ease into the first icon row.
    var height: CGFloat = 96

    var body: some View {
        ZStack {
            // Primary: within-window blur of this pane’s icons.
            WithinWindowBlurView()

            // Soft Liquid Glass wash so it reads closer to the system toolbar edge.
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: 0))
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.9), location: 0.22),
                    .init(color: .black.opacity(0.45), location: 0.5),
                    .init(color: .black.opacity(0.12), location: 0.78),
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
        // Lighter than `.headerView` so it doesn’t muddy icons as much as a double blur.
        view.material = .toolTip
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = false
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .toolTip
        nsView.blendingMode = .withinWindow
        nsView.state = .active
        nsView.isEmphasized = false
    }
}
