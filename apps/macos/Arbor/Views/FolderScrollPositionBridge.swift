import AppKit
import SwiftUI

/// Keeps a pane’s primary vertical `NSScrollView` offset in sync with `BrowserNavigation`
/// so Back/Forward can restore Finder-like scroll positions (icon grid and list/table).
///
/// Offsets are relative to the scroll view’s **natural top** (toolbar / contentInsets),
/// never raw `bounds.origin.y = 0`, which would park icons under the titlebar glass.
struct FolderScrollPositionBridge: NSViewRepresentable {
    @Binding var scrollY: CGFloat
    var restoreToken: UInt
    var consumeRestore: () -> FolderScrollRestore?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        DispatchQueue.main.async {
            context.coordinator.attach(near: nsView)
            context.coordinator.applyRestoreIfNeeded()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var parent: FolderScrollPositionBridge?
        private weak var scrollView: NSScrollView?
        private var boundsObserver: NSObjectProtocol?
        private var liveObserver: NSObjectProtocol?
        private var lastRestoreToken: UInt = 0
        private var isApplyingRestore = false
        /// Only sticky for mid-folder offsets while content height settles.
        private var stickyRestoreOffset: CGFloat?

        func attach(near probe: NSView) {
            guard let found = Self.primaryVerticalScrollView(near: probe) else { return }
            if scrollView !== found {
                detach()
                scrollView = found
                startObserving(found)
            }
        }

        func applyRestoreIfNeeded() {
            guard let parent else { return }
            if parent.restoreToken != lastRestoreToken {
                lastRestoreToken = parent.restoreToken
                stickyRestoreOffset = nil
                guard let restore = parent.consumeRestore(), let scrollView else { return }

                switch restore {
                case .top:
                    isApplyingRestore = true
                    Self.scrollToNaturalTop(scrollView)
                    parent.scrollY = 0
                    isApplyingRestore = false
                    // One follow-up after layout; do not stick to raw zero.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let scrollView = self.scrollView else { return }
                        self.isApplyingRestore = true
                        Self.scrollToNaturalTop(scrollView)
                        self.parent?.scrollY = 0
                        self.isApplyingRestore = false
                    }

                case .offset(let y):
                    stickyRestoreOffset = max(0, y)
                    applyStickyOffset()
                    DispatchQueue.main.async { [weak self] in
                        self?.applyStickyOffset()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.stickyRestoreOffset = nil
                    }
                }
                return
            }

            applyStickyOffset()
        }

        private func applyStickyOffset() {
            guard let y = stickyRestoreOffset, let scrollView, let parent else { return }
            isApplyingRestore = true
            Self.setScrollOffset(scrollView, y)
            parent.scrollY = y
            isApplyingRestore = false
        }

        func detach() {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            if let liveObserver {
                NotificationCenter.default.removeObserver(liveObserver)
            }
            boundsObserver = nil
            liveObserver = nil
            scrollView = nil
            stickyRestoreOffset = nil
        }

        private func startObserving(_ scroll: NSScrollView) {
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true

            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clip,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                if self.stickyRestoreOffset != nil {
                    self.applyStickyOffset()
                }
                self.publishScrollY()
            }

            liveObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didLiveScrollNotification,
                object: scroll,
                queue: .main
            ) { [weak self] _ in
                self?.publishScrollY()
            }
        }

        private func publishScrollY() {
            guard !isApplyingRestore, let scrollView, let parent else { return }
            let y = Self.currentScrollOffset(scrollView)
            if abs(parent.scrollY - y) > 0.5 {
                parent.scrollY = y
            }
        }

        /// Distance past the natural top (toolbar insets accounted for).
        private static func currentScrollOffset(_ scroll: NSScrollView) -> CGFloat {
            max(0, scroll.contentView.bounds.origin.y - naturalTopY(scroll))
        }

        private static func setScrollOffset(_ scroll: NSScrollView, _ offset: CGFloat) {
            let clip = scroll.contentView
            var origin = clip.bounds.origin
            origin.y = naturalTopY(scroll) + max(0, offset)
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
        }

        private static func scrollToNaturalTop(_ scroll: NSScrollView) {
            setScrollOffset(scroll, 0)
        }

        /// Resting top of the document under the toolbar / safe-area content insets.
        private static func naturalTopY(_ scroll: NSScrollView) -> CGFloat {
            let clip = scroll.contentView
            // Titlebar / Liquid Glass underlap lands in contentInsets on the scroll view
            // and sometimes also on the clip view.
            let insetTop = scroll.contentInsets.top + clip.contentInsets.top
            // Flipped clip views (SwiftUI / AppKit tables) use -inset as the top origin.
            if clip.isFlipped {
                return -insetTop
            }
            return insetTop
        }

        private static func primaryVerticalScrollView(near probe: NSView) -> NSScrollView? {
            var root: NSView = probe
            for _ in 0..<16 {
                guard let parent = root.superview else { break }
                if parent is NSSplitView { break }
                root = parent
            }

            let candidates = scrollViews(in: root).filter { scroll in
                scroll.bounds.height >= 80
            }

            return candidates.max { a, b in
                a.bounds.height * a.bounds.width < b.bounds.height * b.bounds.width
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
