import AppKit
import SwiftUI

/// Hooks the detail file table for:
/// - double-click → open
/// - delayed second click on an already-selected name → rename
/// - keeping the clip-view origin stable across selection (see below)
///
/// On macOS 26 SwiftUI's `Table` is backed by `SwiftUIOutlineTableView` (an
/// `NSOutlineView` subclass), so outline views are valid detail tables. The
/// sidebar is an outline view too; the installer lives in the detail pane and
/// picks the table whose frame matches it, so the sidebar is never hooked.
///
/// Scroll / selection jump: the table's clip view uses `contentInsets.top=28`
/// for the column header, so the resting origin at scroll-top is `-28`. AppKit
/// clamps that origin to `0` when it reveals a selected row, which scrolls the
/// list by a header height, slides the first rows under the titles, and moves
/// the row under the cursor. We capture the origin on mouse-down and restore it
/// after selection (sync + async), matching the icon-view fix from 1.7.3.
/// Chrome under the toolbar is layout padding on the SwiftUI `Table`, not a
/// scroll-view content inset — those insets put the resting origin at `-80`
/// and the clamp scrolled ~3 rows.
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

        /// Clip-view origin at mouse-down; restored after AppKit's selection reveal.
        var originBeforeClick: NSPoint?
        /// Row under the pointer at mouse-down — used when `clickedRow` is -1.
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

        func captureClickGeometry(in table: NSTableView, event: NSEvent) {
            guard let scroll = table.enclosingScrollView else { return }
            let clip = scroll.contentView
            originBeforeClick = clip.bounds.origin
            let point = table.convert(event.locationInWindow, from: nil)
            rowBeforeClick = table.row(at: point)
            DragDebugLog.log(
                "table.mouseDown row=\(rowBeforeClick)"
                    + " origin.y=\(clip.bounds.origin.y)"
                    + " scrollInsets.top=\(scroll.contentInsets.top)"
                    + " clipInsets.top=\(clip.contentInsets.top)"
            )
        }

        /// Undo AppKit clamping the clip origin to 0 when revealing selection.
        ///
        /// Restoring the origin stops the visual jump, but AppKit has already
        /// moved the selection to the row that sat under the pointer *after* the
        /// clamp. Put the selection back on the row the user actually pressed.
        func restoreOriginAfterSelectionIfNeeded() {
            guard let before = originBeforeClick,
                  let table = hookedTable,
                  let scroll = table.enclosingScrollView
            else { return }
            let clip = scroll.contentView
            let current = clip.bounds.origin
            guard abs(current.y - before.y) > 0.5 || abs(current.x - before.x) > 0.5 else {
                return
            }
            DragDebugLog.log("table.restore.origin from=\(current.y) to=\(before.y)")
            clip.setBoundsOrigin(before)
            scroll.reflectScrolledClipView(clip)
            fixSelectionAfterClamp(in: table)
        }

        /// The clamp changed which row is under the pointer, so AppKit selected
        /// a different row than the one pressed. Re-select the pressed row.
        /// Only for a plain click: keep modifier-driven multi-selection intact.
        private func fixSelectionAfterClamp(in table: NSTableView) {
            guard rowBeforeClick >= 0,
                  rowBeforeClick < rowCount,
                  NSEvent.modifierFlags.intersection([.shift, .command]).isEmpty,
                  table.selectedRow != rowBeforeClick
            else { return }
            DragDebugLog.log(
                "table.selection.fix from=\(table.selectedRow) to=\(rowBeforeClick)"
            )
            table.selectRowIndexes(
                IndexSet(integer: rowBeforeClick),
                byExtendingSelection: false
            )
        }

        /// AppKit often clamps *after* our action runs — restore now and on the
        /// next turns. Keep `originBeforeClick` until the next mouse-down so a
        /// double-click's second press can reuse / refresh the capture.
        func restoreOriginGuarded() {
            restoreOriginAfterSelectionIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.restoreOriginAfterSelectionIfNeeded()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.restoreOriginAfterSelectionIfNeeded()
            }
        }

        @objc func tableClicked(_ sender: Any?) {
            guard let table = sender as? NSTableView else { return }
            restoreOriginAfterSelectionIfNeeded()

            var row = table.clickedRow
            let column = table.clickedColumn
            if rowBeforeClick >= 0,
               NSEvent.modifierFlags.intersection([.shift, .command]).isEmpty,
               rowBeforeClick != row
            {
                // clickedRow reflects the post-clamp layout; the pressed row is
                // what the user aimed at.
                row = rowBeforeClick
            } else if row < 0, rowBeforeClick >= 0 {
                row = rowBeforeClick
            }
            if let scroll = table.enclosingScrollView {
                let clip = scroll.contentView
                DragDebugLog.log(
                    "table.clicked row=\(row) col=\(column)"
                        + " origin.y=\(clip.bounds.origin.y)"
                        + " scrollInsets.top=\(scroll.contentInsets.top)"
                        + " clipInsets.top=\(clip.contentInsets.top)"
                )
            }
            restoreOriginGuarded()

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
            // Undo any clamp before resolving the row from the event location.
            restoreOriginAfterSelectionIfNeeded()

            // `clickedRow` is -1 here for SwiftUI's table (the double-click is
            // dispatched after SwiftUI resets it); resolve from the event, then
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
            DragDebugLog.log("table.doubleClick rawClicked=\(rawClicked) resolved=\(row)")
            restoreOriginGuarded()
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
            guard let table = hookedTable, table.window === event.window else { return }
            let pointInTable = table.convert(event.locationInWindow, from: nil)
            guard table.bounds.contains(pointInTable) else { return }
            coordinator?.captureClickGeometry(in: table, event: event)
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

            // No safe-area content inset on the table's scroll view: with an
            // inset its resting origin is negative (-80 observed) and AppKit
            // clamps it to 0 when revealing the selected row, scrolling the
            // list by the chrome height. The chrome gap is padding above.
            if let scroll = table.enclosingScrollView {
                scroll.automaticallyAdjustsContentInsets = false
                if scroll.contentInsets.top != 0 || scroll.contentInsets.bottom != 0 {
                    scroll.contentInsets = NSEdgeInsets()
                }
                // Do NOT touch scroll.contentView.contentInsets: NSTableView uses
                // it to reserve the header height (28pt); zeroing it drew the
                // first row underneath the column titles.
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
        /// Search the window instead and pick the table whose frame matches this
        /// pane — split view has two tables and each installer must hook its own.
        private func findDetailFileTable() -> NSTableView? {
            guard let window, let root = window.contentView else { return nil }
            let targetFrame = convert(bounds, to: nil)
            guard targetFrame.width > 1, targetFrame.height > 1 else { return nil }

            var best: (table: NSTableView, overlap: CGFloat, distance: CGFloat)?

            func consider(_ table: NSTableView) {
                guard table.window === window, !table.isHiddenOrHasHiddenAncestor else { return }
                let frame = table.convert(table.bounds, to: nil)
                let intersection = frame.intersection(targetFrame)
                let overlap = intersection.isNull ? 0 : intersection.width * intersection.height
                guard overlap > 0 else { return }
                let distance = hypot(frame.midX - targetFrame.midX, frame.midY - targetFrame.midY)
                if let current = best {
                    if overlap > current.overlap
                        || (overlap == current.overlap && distance < current.distance)
                    {
                        best = (table, overlap, distance)
                    }
                } else {
                    best = (table, overlap, distance)
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
    }
}
