import AppKit
import SwiftUI

/// Hooks the detail file table for:
/// - double-click → open
/// - delayed second click on an already-selected name → rename
///
/// On macOS 26 SwiftUI's `Table` is backed by `SwiftUIOutlineTableView` (an
/// `NSOutlineView` subclass), so outline views are valid detail tables. The
/// sidebar is an outline view too; the installer lives in the detail pane and
/// picks the table whose frame and view subtree match it, so the sidebar and
/// inactive tabs are never hooked.
struct TableInteractionInstaller: NSViewRepresentable {
    var rowCount: Int
    var nameColumnIndex: Int = 0
    var isRowSelected: (Int) -> Bool
    var onDoubleClickRow: (Int) -> Void
    var onRenameRow: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isRowSelected: isRowSelected,
            onDoubleClickRow: onDoubleClickRow,
            onRenameRow: onRenameRow
        )
    }

    func makeNSView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: InstallerView, context: Context) {
        context.coordinator.isRowSelected = isRowSelected
        context.coordinator.onDoubleClickRow = onDoubleClickRow
        context.coordinator.onRenameRow = onRenameRow
        context.coordinator.rowCount = rowCount
        context.coordinator.nameColumnIndex = nameColumnIndex
        nsView.coordinator = context.coordinator
        // Only re-hunt the table when the hook is missing; reassert the hooks on
        // every update because SwiftUI can rebuild the table's action wiring.
        nsView.scheduleInstallIfNeeded()
    }

    final class Coordinator: NSObject {
        var isRowSelected: (Int) -> Bool
        var onDoubleClickRow: (Int) -> Void
        var onRenameRow: (Int) -> Void
        var rowCount: Int = 0
        var nameColumnIndex: Int = 0

        /// Row under the pointer at mouse-down — fallback when SwiftUI resets
        /// `clickedRow` to -1 before `doubleAction` fires.
        var rowBeforeClick: Int = -1

        private var renameWorkItem: DispatchWorkItem?
        private var lastClickedRow: Int = -1
        private var lastClickAt: Date = .distantPast
        private weak var hookedTable: NSTableView?

        init(
            isRowSelected: @escaping (Int) -> Bool,
            onDoubleClickRow: @escaping (Int) -> Void,
            onRenameRow: @escaping (Int) -> Void
        ) {
            self.isRowSelected = isRowSelected
            self.onDoubleClickRow = onDoubleClickRow
            self.onRenameRow = onRenameRow
        }

        func attach(table: NSTableView) {
            hookedTable = table
        }

        func captureMouseDown(in table: NSTableView, event: NSEvent) {
            let point = table.convert(event.locationInWindow, from: nil)
            guard table.bounds.contains(point) else {
                rowBeforeClick = -1
                return
            }
            rowBeforeClick = table.row(at: point)
            if let scroll = table.enclosingScrollView {
                let clip = scroll.contentView
                DragDebugLog.log(
                    "table.mouseDown row=\(rowBeforeClick)"
                        + " origin.y=\(clip.bounds.origin.y)"
                        + " scrollInsets.top=\(scroll.contentInsets.top)"
                        + " clipInsets.top=\(clip.contentInsets.top)"
                )
            }
        }

        @objc func tableClicked(_ sender: Any?) {
            guard let table = sender as? NSTableView else { return }

            let rawRow = table.clickedRow
            let row = rawRow >= 0 ? rawRow : rowBeforeClick
            let column = table.clickedColumn
            if let scroll = table.enclosingScrollView {
                let clip = scroll.contentView
                DragDebugLog.log(
                    "table.clicked row=\(row) rawRow=\(rawRow) selected=\(table.selectedRow) col=\(column)"
                        + " origin.y=\(clip.bounds.origin.y)"
                        + " scrollInsets.top=\(scroll.contentInsets.top)"
                        + " clipInsets.top=\(clip.contentInsets.top)"
                )
            }

            guard row >= 0, row < rowCount else {
                cancelPendingRename()
                return
            }

            // Finder-like rename: second click on the name of an already-selected row.
            let now = Date()
            let isNameColumn = column == nameColumnIndex || column < 0
            let alreadySelected = isRowSelected(row)
            let isSlowSecondClick =
                row == lastClickedRow
                && alreadySelected
                && now.timeIntervalSince(lastClickAt) > 0.45
                && now.timeIntervalSince(lastClickAt) < 1.6

            lastClickedRow = row
            lastClickAt = now
            cancelPendingRename()

            guard isNameColumn, alreadySelected, isSlowSecondClick else { return }

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Abort if the user started a drag or changed selection meanwhile.
                guard self.isRowSelected(row) else { return }
                self.onRenameRow(row)
            }
            renameWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }

        @objc func tableDoubleClicked(_ sender: Any?) {
            cancelPendingRename()
            guard let table = sender as? NSTableView else { return }

            // `clickedRow` is sometimes -1 here for SwiftUI's table (the double-click
            // is dispatched after SwiftUI resets it); resolve from the event, then
            // fall back to the row captured on mouse-down.
            let rawClicked = table.clickedRow
            let row: Int
            if rawClicked >= 0 {
                row = rawClicked
            } else if let event = NSApp.currentEvent {
                let fromEvent = table.row(at: table.convert(event.locationInWindow, from: nil))
                row = fromEvent >= 0 ? fromEvent : rowBeforeClick
            } else {
                row = rowBeforeClick
            }
            let originY = table.enclosingScrollView?.contentView.bounds.origin.y ?? 0
            DragDebugLog.log("table.doubleClick rawClicked=\(rawClicked) resolved=\(row) origin.y=\(originY)")
            guard row >= 0, row < rowCount else { return }
            onDoubleClickRow(row)
        }

        func cancelPendingRename() {
            renameWorkItem?.cancel()
            renameWorkItem = nil
        }
    }

    final class InstallerView: NSView {
        var coordinator: Coordinator?
        private weak var hookedTable: NSTableView?
        private var attempts = 0
        private var dragMonitor: Any?
        private var mouseDownMonitor: Any?
        /// Last logged geometry — avoid flooding `/tmp/arbor-dnd.log` on every SwiftUI update.
        private var lastGeomKey: String = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleInstall()
            installEventMonitors()
        }

        override func layout() {
            super.layout()
            scheduleInstallIfNeeded()
        }

        deinit {
            if let dragMonitor {
                NSEvent.removeMonitor(dragMonitor)
            }
            if let mouseDownMonitor {
                NSEvent.removeMonitor(mouseDownMonitor)
            }
        }

        func scheduleInstallIfNeeded() {
            if let hookedTable, hookedTable.window === window {
                // SwiftUI may rebuild the NSTableView's action wiring during
                // updates; reassert it cheaply so double-click never goes stale.
                applyHooks(to: hookedTable)
                return
            }
            scheduleInstall()
        }

        func scheduleInstall() {
            attempts = 0
            tryInstall()
            DispatchQueue.main.async { [weak self] in
                self?.tryInstall()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.tryInstall()
            }
        }

        private func installEventMonitors() {
            if dragMonitor == nil {
                // If the user starts dragging, don't fire the delayed rename.
                dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
                    self?.coordinator?.cancelPendingRename()
                    return event
                }
            }
            if mouseDownMonitor == nil {
                mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                    self?.handleMouseDown(event)
                    return event
                }
            }
        }

        private func handleMouseDown(_ event: NSEvent) {
            guard let table = hookedTable,
                  table.window === event.window,
                  Self.isEffectivelyVisible(table)
            else { return }
            coordinator?.captureMouseDown(in: table, event: event)
        }

        private func tryInstall() {
            guard let coordinator else { return }
            guard let table = findDetailFileTable() else {
                if attempts < 8 {
                    attempts += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.tryInstall()
                    }
                }
                return
            }

            if let hookedTable, hookedTable !== table {
                if hookedTable.target === coordinator {
                    hookedTable.target = nil
                    hookedTable.action = nil
                    hookedTable.doubleAction = nil
                }
            }

            hookedTable = table
            coordinator.attach(table: table)
            applyHooks(to: table)
        }

        private func applyHooks(to table: NSTableView) {
            table.target = coordinator
            table.action = #selector(Coordinator.tableClicked(_:))
            table.doubleAction = #selector(Coordinator.tableDoubleClicked(_:))
            table.focusRingType = .none

            if let scroll = table.enclosingScrollView {
                // Leave scroll/clip content insets to SwiftUI + AppKit so the
                // table sits right below the toolbar (no extra padding gap) and
                // keeps its 28pt column-header clip inset.
                let clip = scroll.contentView
                let key =
                    "\(scroll.automaticallyAdjustsContentInsets)|\(scroll.contentInsets.top)"
                    + "|\(clip.contentInsets.top)|\(Int(clip.bounds.origin.y.rounded()))"
                if key != lastGeomKey {
                    lastGeomKey = key
                    DragDebugLog.log(
                        "table.geom autoAdj=\(scroll.automaticallyAdjustsContentInsets)"
                            + " scrollInsets.top=\(scroll.contentInsets.top)"
                            + " clipInsets.top=\(clip.contentInsets.top)"
                            + " origin.y=\(clip.bounds.origin.y)"
                    )
                }
            }
        }

        /// The table lives in a sibling subtree of this SwiftUI background view,
        /// so walking superviews (and stopping at NSSplitView) never found it.
        /// Search the window and pick the table that shares the closest ancestor
        /// with this installer (so split panes and mounted background tabs each
        /// hook their own table) and overlaps this pane's frame.
        private func findDetailFileTable() -> NSTableView? {
            guard let window, let root = window.contentView else { return nil }
            let targetFrame = convert(bounds, to: nil)
            guard targetFrame.width > 1, targetFrame.height > 1 else { return nil }

            var ancestorSteps: [ObjectIdentifier: Int] = [:]
            var cursor: NSView? = self
            var depth = 0
            while let node = cursor {
                ancestorSteps[ObjectIdentifier(node)] = depth
                depth += 1
                cursor = node.superview
            }

            func treeDistance(to table: NSTableView) -> Int {
                var node: NSView? = table
                var steps = 0
                while let current = node {
                    if let selfSteps = ancestorSteps[ObjectIdentifier(current)] {
                        return selfSteps + steps
                    }
                    steps += 1
                    node = current.superview
                }
                return Int.max
            }

            let selfVisible = Self.isEffectivelyVisible(self)
            var best: (table: NSTableView, visibilityMatch: Bool, treeDist: Int, overlap: CGFloat, distance: CGFloat)?

            func consider(_ table: NSTableView) {
                guard table.window === window, !table.isHiddenOrHasHiddenAncestor else { return }
                let frame = table.convert(table.bounds, to: nil)
                let intersection = frame.intersection(targetFrame)
                let overlap = intersection.isNull ? 0 : intersection.width * intersection.height
                guard overlap > 0 else { return }

                let visibilityMatch = Self.isEffectivelyVisible(table) == selfVisible
                let tDist = treeDistance(to: table)
                let distance = hypot(frame.midX - targetFrame.midX, frame.midY - targetFrame.midY)

                if let current = best {
                    let isBetter: Bool
                    if visibilityMatch != current.visibilityMatch {
                        isBetter = visibilityMatch
                    } else if tDist != current.treeDist {
                        isBetter = tDist < current.treeDist
                    } else if overlap != current.overlap {
                        isBetter = overlap > current.overlap
                    } else {
                        isBetter = distance < current.distance
                    }
                    if isBetter {
                        best = (table, visibilityMatch, tDist, overlap, distance)
                    }
                } else {
                    best = (table, visibilityMatch, tDist, overlap, distance)
                }
            }

            func visit(_ view: NSView) {
                if let table = view as? NSTableView {
                    consider(table)
                }
                for subview in view.subviews {
                    visit(subview)
                }
            }

            visit(root)
            return best?.table
        }

        /// Distinguishes the active tab from background tabs kept mounted with `.opacity(0)`.
        private static func isEffectivelyVisible(_ view: NSView) -> Bool {
            guard !view.isHiddenOrHasHiddenAncestor else { return false }
            var current: NSView? = view
            while let node = current {
                if node.alphaValue <= 0.01 { return false }
                if let layer = node.layer, layer.opacity <= 0.01 { return false }
                current = node.superview
            }
            return true
        }
    }
}
