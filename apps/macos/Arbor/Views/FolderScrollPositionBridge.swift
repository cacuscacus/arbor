import AppKit
import SwiftUI

/// Keeps a pane’s primary vertical `NSScrollView` offset in sync with `BrowserNavigation`
/// so Back/Forward can restore Finder-like scroll positions (icon grid and list/table).
///
/// `.top` remounts via content identity (no NSScrollView forcing). Mid-folder
/// Back/Forward restores use sticky offsets only.
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
        private var stickyRestoreY: CGFloat?

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
                stickyRestoreY = nil
                guard let restore = parent.consumeRestore(), let scrollView else { return }

        switch restore {
                case .top:
                    // Natural top comes from remounting browser content (`.id(path)`).
                    // Never force raw y=0 / inset math — both look wrong under Liquid Glass.
                    parent.scrollY = 0

                case .offset(let y):
                    stickyRestoreY = max(0, y)
                    applyStickyOffset()
                    DispatchQueue.main.async { [weak self] in
                        self?.applyStickyOffset()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.stickyRestoreY = nil
                    }
                }
                return
            }

            applyStickyOffset()
        }

        private func applyStickyOffset() {
            guard let y = stickyRestoreY, let scrollView, let parent else { return }
            isApplyingRestore = true
            Self.setScrollY(scrollView, y)
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
            stickyRestoreY = nil
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
                if self.stickyRestoreY != nil {
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
            let y = Self.currentScrollY(scrollView)
            if abs(parent.scrollY - y) > 0.5 {
                parent.scrollY = y
            }
        }

        private static func currentScrollY(_ scroll: NSScrollView) -> CGFloat {
            max(0, scroll.contentView.bounds.origin.y)
        }

        private static func setScrollY(_ scroll: NSScrollView, _ y: CGFloat) {
            let clip = scroll.contentView
            var origin = clip.bounds.origin
            origin.y = max(0, y)
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
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
