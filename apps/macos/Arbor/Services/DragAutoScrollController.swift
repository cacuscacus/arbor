import AppKit

/// Keeps a drag session scrolling while the pointer rests near the top or
/// bottom edge of the list.
///
/// AppKit's built-in autoscroll follows mouse-moved events, so it stops as
/// soon as the pointer stops moving — dragging to the edge scrolls a little
/// and then stalls. This controller polls while the primary button is held
/// and scrolls on a timer, so a drag can travel the whole list.
///
/// The scroll view is captured on mouse-down (the press is always inside the
/// list) instead of hit-testing under the pointer: the floating chrome island
/// covers the top of the detail area, and hit-testing there would miss the
/// list exactly when the pointer is at the edge that matters.
@MainActor
final class DragAutoScrollController {
    static let shared = DragAutoScrollController()

    /// Distance from the edge (in points) where scrolling kicks in. The top
    /// band is taller because the list's scroll view starts at the window top
    /// and the floating breadcrumb chrome covers its first ~90 points.
    private let topBand: CGFloat = 132
    private let bottomBand: CGFloat = 56
    /// Points per tick at the closest edge; scales down towards the band's
    /// inner limit so the speed feels proportional to the pointer position.
    private let maxStep: CGFloat = 16
    private let tickInterval: TimeInterval = 1.0 / 60.0
    /// Autoscroll speeds up while the pointer is held at the edge, so a long
    /// list can be crossed quickly (Finder behaves the same way).
    private let maxAcceleration: CGFloat = 2.5

    private var timer: Timer?
    private var mouseMonitor: Any?
    private weak var activeScrollView: NSScrollView?
    private var edgeTicks = 0

    private init() {}

    /// Installs the mouse trigger once per process.
    func install() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown {
                self.captureScrollView(for: event)
            } else {
                self.finish()
            }
            return event
        }
    }

    private func captureScrollView(for event: NSEvent) {
        let locationInWindow = event.locationInWindow
        guard let hit = event.window?.contentView?.hitTest(locationInWindow) else {
            activeScrollView = nil
            return
        }
        var view: NSView? = hit
        while let current = view {
            if let scrollView = current as? NSScrollView {
                activeScrollView = scrollView
                break
            }
            view = current.superview
        }
        edgeTicks = 0
        beginPollingIfNeeded()
    }

    private func beginPollingIfNeeded() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        activeScrollView = nil
        edgeTicks = 0
    }

    private func tick() {
        // Polling only while the button is held keeps this off the idle path.
        guard NSEvent.pressedMouseButtons & 0x1 != 0 else {
            finish()
            return
        }
        guard isDragInProgress, let scrollView = activeScrollView else { return }

        let pointerInWindow = scrollView.window?.convertPoint(
            fromScreen: NSEvent.mouseLocation
        )
        guard let pointerInWindow else { return }
        let pointerInClip = scrollView.contentView.convert(pointerInWindow, from: nil)
        // Only scroll while the pointer is actually over this list.
        guard scrollView.contentView.bounds.contains(pointerInClip) else { return }
        scroll(scrollView, pointer: pointerInClip)
    }

    private var isDragInProgress: Bool {
        guard let items = NSPasteboard(name: .drag).pasteboardItems else { return false }
        return !items.isEmpty
    }

    private func scroll(_ scrollView: NSScrollView, pointer: NSPoint) {
        let clip = scrollView.contentView
        let height = clip.bounds.height
        guard height > 0 else { return }

        // The pointer arrives in the clip view's bounds space, which already
        // includes the scrolled origin; measure from the visible edges.
        let relativeY = pointer.y - clip.bounds.minY
        let distanceFromTop = relativeY
        let distanceFromBottom = height - relativeY

        let direction: CGFloat
        let proximity: CGFloat
        if distanceFromTop < topBand {
            direction = -1
            proximity = (topBand - max(0, distanceFromTop)) / topBand
        } else if distanceFromBottom < bottomBand {
            direction = 1
            proximity = (bottomBand - max(0, distanceFromBottom)) / bottomBand
        } else {
            edgeTicks = 0
            return
        }

        guard let documentView = scrollView.documentView else { return }
        edgeTicks += 1
        let acceleration = min(maxAcceleration, 1 + CGFloat(edgeTicks) * 0.06)
        let step = maxStep * max(0.15, min(1, proximity)) * acceleration
        let maxOriginY = max(0, documentView.bounds.height - height)
        var origin = clip.bounds.origin
        origin.y = min(max(0, origin.y + direction * step), maxOriginY)
        clip.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(clip)
    }
}
