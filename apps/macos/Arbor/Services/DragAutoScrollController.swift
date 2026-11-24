import AppKit

/// Pure scroll-step math for drag autoscroll, separated so it is unit-tested
/// without a live window.
nonisolated enum DragAutoScrollMath {
    struct StepResult: Equatable {
        /// Clamped next `bounds.origin.y` (equals `currentOriginY` when no scroll is needed).
        let nextOriginY: CGFloat
        /// True while the pointer sits inside the top or bottom scroll band.
        let inEdgeBand: Bool
        /// True when `nextOriginY` actually moves past the tolerance.
        var didMove: Bool { abs(delta) > 0.5 }
        let delta: CGFloat
    }

    /// Computes the next vertical clip-view origin for a drag-autoscroll tick.
    ///
    /// Respects `topInset` and `bottomInset` (e.g. `NSTableView`'s 28pt column
    /// header clip inset, whose resting top origin is `-28`, not `0`). Clamping
    /// against `0` instead of `-topInset` moved a resting table *down* by the
    /// header height whenever scrolling up at the top edge.
    static func nextOriginY(
        currentOriginY: CGFloat,
        clipHeight: CGFloat,
        documentHeight: CGFloat,
        topInset: CGFloat,
        bottomInset: CGFloat,
        isFlipped: Bool,
        pointerYInClip: CGFloat,
        topBand: CGFloat,
        bottomBand: CGFloat,
        maxStep: CGFloat,
        acceleration: CGFloat
    ) -> StepResult {
        guard clipHeight > 0 else {
            return StepResult(nextOriginY: currentOriginY, inEdgeBand: false, delta: 0)
        }

        let relativeY = pointerYInClip - currentOriginY
        let distanceFromTop = isFlipped ? relativeY : (clipHeight - relativeY)
        let distanceFromBottom = clipHeight - distanceFromTop

        let direction: CGFloat
        let proximity: CGFloat
        if distanceFromTop < topBand {
            // Scroll toward top of document.
            direction = isFlipped ? -1 : 1
            proximity = (topBand - max(0, distanceFromTop)) / max(1, topBand)
        } else if distanceFromBottom < bottomBand {
            // Scroll toward bottom of document.
            direction = isFlipped ? 1 : -1
            proximity = (bottomBand - max(0, distanceFromBottom)) / max(1, bottomBand)
        } else {
            return StepResult(nextOriginY: currentOriginY, inEdgeBand: false, delta: 0)
        }

        let minOriginY: CGFloat
        let maxOriginY: CGFloat
        if isFlipped {
            minOriginY = -topInset
            maxOriginY = max(minOriginY, documentHeight + bottomInset - clipHeight)
        } else {
            minOriginY = -bottomInset
            maxOriginY = max(minOriginY, documentHeight + topInset - clipHeight)
        }

        let step = maxStep * max(0.15, min(1, proximity)) * acceleration
        let proposed = currentOriginY + direction * step
        let clamped = min(max(minOriginY, proposed), maxOriginY)
        return StepResult(
            nextOriginY: clamped,
            inEdgeBand: true,
            delta: clamped - currentOriginY
        )
    }
}

/// Keeps a drag session scrolling while the pointer rests near the top or
/// bottom edge of a file list or icon grid.
///
/// AppKit's built-in autoscroll follows mouse-moved events, so it stops as
/// soon as the pointer stops moving — dragging to the edge scrolls a little
/// and then stalls. This controller polls on a timer **only while a real drag
/// session is active** (never on plain clicks: `NSPasteboard(name: .drag)`
/// retains items indefinitely after any prior drag on macOS, so inspecting it
/// caused clicks near the top or bottom edges to autoscroll mid-click).
@MainActor
final class DragAutoScrollController {
    static let shared = DragAutoScrollController()

    /// Distance inside the visible content area (in points) where autoscroll engages.
    private let edgeBand: CGFloat = 48
    /// Points per tick at the closest edge; scales down towards the band's
    /// inner limit so the speed feels proportional to the pointer position.
    private let maxStep: CGFloat = 16
    private let tickInterval: TimeInterval = 1.0 / 60.0
    /// Autoscroll speeds up while the pointer is held at the edge, so a long
    /// list can be crossed quickly (Finder behaves the same way).
    private let maxAcceleration: CGFloat = 2.5

    private var timer: Timer?
    private var mouseMonitor: Any?
    /// Scroll view under the initial press, kept as a fallback if a real drag
    /// starts from this press and moves over floating chrome.
    private weak var candidateScrollView: NSScrollView?
    /// Scroll view currently being autoscrolled by an active drag session.
    private weak var activeScrollView: NSScrollView?
    /// True only while an explicit AppKit/SwiftUI drag session is active.
    private var isDragSessionActive = false
    /// True while a drop delegate is actively receiving hover updates.
    private var isDropHovering = false
    private var edgeTicks = 0

    private init() {}

    /// Installs the mouse monitor once per process.
    func install() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown {
                // Record candidate scroll view only — NEVER start scrolling or
                // timers on mouse-down; wait for a real drag session to start.
                self.candidateScrollView = Self.scrollView(under: event)
            } else {
                self.endDragSession()
            }
            return event
        }
    }

    /// Called when an internal AppKit drag session begins (e.g. icon view).
    func beginDragSession(in scrollView: NSScrollView? = nil) {
        isDragSessionActive = true
        if let scrollView {
            activeScrollView = scrollView
        } else if activeScrollView == nil {
            activeScrollView = candidateScrollView ?? Self.scrollView(underScreenPoint: NSEvent.mouseLocation)
        }
        edgeTicks = 0
        beginPollingIfNeeded()
    }

    /// Called by drop delegates (`dropEntered` / `dropUpdated` / `validateDrop`)
    /// whenever a real drag session hovers over a scrollable pane. Works for
    /// both internal drags and external drags from Finder/other apps.
    func noteDropHover(in scrollView: NSScrollView? = nil) {
        isDropHovering = true
        isDragSessionActive = true
        if let scrollView {
            activeScrollView = scrollView
        } else if let underPointer = Self.scrollView(underScreenPoint: NSEvent.mouseLocation) {
            activeScrollView = underPointer
        } else if activeScrollView == nil {
            activeScrollView = candidateScrollView
        }
        beginPollingIfNeeded()
    }

    /// Called when a drag leaves a drop target. If the pointer is no longer
    /// inside the tracked scroll view (e.g. external drag moved back to Finder),
    /// stop polling.
    func noteDropExited() {
        isDropHovering = false
        guard let scrollView = activeScrollView,
              let window = scrollView.window
        else {
            endDragSession()
            return
        }
        let pointerInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointerInClip = scrollView.contentView.convert(pointerInWindow, from: nil)
        if !Self.isPointerInHorizontalAndChromeBounds(pointerInClip, scrollView: scrollView) {
            endDragSession()
        }
    }

    /// Called when a drag session finishes, drops, or the mouse button lifts.
    func endDragSession() {
        timer?.invalidate()
        timer = nil
        activeScrollView = nil
        candidateScrollView = nil
        isDragSessionActive = false
        isDropHovering = false
        edgeTicks = 0
    }

    private func beginPollingIfNeeded() {
        guard timer == nil, activeScrollView != nil else { return }
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard isDragSessionActive,
              NSEvent.pressedMouseButtons & 0x1 != 0,
              let scrollView = activeScrollView,
              let window = scrollView.window,
              window.isVisible
        else {
            endDragSession()
            return
        }

        let pointerInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointerInClip = scrollView.contentView.convert(pointerInWindow, from: nil)

        guard Self.isPointerInHorizontalAndChromeBounds(pointerInClip, scrollView: scrollView) else {
            edgeTicks = 0
            if !isDropHovering {
                endDragSession()
            }
            return
        }

        scroll(scrollView, pointer: pointerInClip)
    }

    /// Allows the pointer to sit inside the clip view or slightly above its top
    /// edge (over floating chrome/toolbar) while staying within its horizontal span.
    private static func isPointerInHorizontalAndChromeBounds(
        _ pointerInClip: NSPoint,
        scrollView: NSScrollView
    ) -> Bool {
        let bounds = scrollView.contentView.bounds
        guard pointerInClip.x >= bounds.minX, pointerInClip.x <= bounds.maxX else {
            return false
        }
        let chromeAllowance: CGFloat = 56
        if scrollView.contentView.isFlipped {
            return pointerInClip.y >= bounds.minY - chromeAllowance && pointerInClip.y <= bounds.maxY
        } else {
            return pointerInClip.y >= bounds.minY && pointerInClip.y <= bounds.maxY + chromeAllowance
        }
    }

    private func scroll(_ scrollView: NSScrollView, pointer: NSPoint) {
        let clip = scrollView.contentView
        guard let documentView = scrollView.documentView else { return }

        let topInset = clip.contentInsets.top
        let bottomInset = clip.contentInsets.bottom
        // Account for header inset (table) or floating chrome overlap (icon view).
        let topBand = Self.effectiveTopBand(for: scrollView, baseBand: edgeBand)
        let bottomBand = bottomInset + edgeBand

        let acceleration = min(maxAcceleration, 1 + CGFloat(edgeTicks + 1) * 0.06)
        let result = DragAutoScrollMath.nextOriginY(
            currentOriginY: clip.bounds.origin.y,
            clipHeight: clip.bounds.height,
            documentHeight: documentView.bounds.height,
            topInset: topInset,
            bottomInset: bottomInset,
            isFlipped: clip.isFlipped,
            pointerYInClip: pointer.y,
            topBand: topBand,
            bottomBand: bottomBand,
            maxStep: maxStep,
            acceleration: acceleration
        )

        guard result.inEdgeBand else {
            edgeTicks = 0
            return
        }
        guard result.didMove else {
            return
        }

        edgeTicks += 1
        var proposedOrigin = clip.bounds.origin
        proposedOrigin.y = result.nextOriginY
        let constrained = clip.constrainBoundsRect(
            NSRect(origin: proposedOrigin, size: clip.bounds.size)
        ).origin
        guard abs(constrained.y - clip.bounds.origin.y) > 0.5 else { return }
        clip.setBoundsOrigin(constrained)
        scrollView.reflectScrolledClipView(clip)
    }

    private static func effectiveTopBand(for scrollView: NSScrollView, baseBand: CGFloat) -> CGFloat {
        let clipTopInset = scrollView.contentView.contentInsets.top
        if clipTopInset > 0 {
            return clipTopInset + baseBand
        }
        // Views like IconCollectionView extend under the floating toolbar/tab chrome
        // with zero clip inset; add the chrome overlap so hovering just below the
        // chrome triggers upward autoscroll.
        if let window = scrollView.window, let contentView = window.contentView {
            let chrome = max(0, contentView.bounds.height - window.contentLayoutRect.height)
            let scrollTopInWindow = scrollView.convert(scrollView.bounds, to: nil).maxY
            let overlap = max(0, scrollTopInWindow - window.contentLayoutRect.maxY)
            return min(overlap, chrome) + baseBand
        }
        return baseBand
    }

    private static func scrollView(under event: NSEvent) -> NSScrollView? {
        guard let hit = event.window?.contentView?.hitTest(event.locationInWindow) else {
            return nil
        }
        return enclosingScrollView(of: hit)
    }

    private static func scrollView(underScreenPoint screenPoint: NSPoint) -> NSScrollView? {
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && $0.frame.contains(screenPoint)
        }),
            let hit = window.contentView?.hitTest(window.convertPoint(fromScreen: screenPoint))
        else { return nil }
        return enclosingScrollView(of: hit)
    }

    private static func enclosingScrollView(of view: NSView) -> NSScrollView? {
        var current: NSView? = view
        while let node = current {
            if let scroll = node as? NSScrollView {
                return scroll
            }
            current = node.superview
        }
        return nil
    }
}
