import AppKit
import SwiftUI

/// Hooks the detail file table for:
/// - double-click → open
/// - delayed second click on an already-selected name → rename
///
/// On macOS 26 SwiftUI's `Table` is backed by `SwiftUIOutlineTableView` (an
/// `NSOutlineView` subclass), so outline views are valid detail tables. The
/// sidebar is an outline view too; the installer lives in the detail pane and
/// picks the table whose frame matches it, so the sidebar is never hooked.
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

        private var renameWorkItem: DispatchWorkItem?
        private var lastClickedRow: Int = -1
        private var lastClickAt: Date = .distantPast

        init(
            isRowSelected: @escaping (Int) -> Bool,
            onDoubleClickRow: @escaping (Int) -> Void,
            onRenameRow: @escaping (Int) -> Void
        ) {
            self.isRowSelected = isRowSelected
            self.onDoubleClickRow = onDoubleClickRow
            self.onRenameRow = onRenameRow
        }

        @objc func tableClicked(_ sender: Any?) {
            guard let table = sender as? NSTableView else { return }
            let row = table.clickedRow
            let column = table.clickedColumn
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
            // `clickedRow` is -1 here for SwiftUI's table (the double-click is
            // dispatched after SwiftUI resets it); resolve from the event.
            let row: Int
            if let event = NSApp.currentEvent {
                row = table.row(at: table.convert(event.locationInWindow, from: nil))
            } else {
                row = table.clickedRow
            }
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

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleInstall()
            installDragMonitor()
        }

        override func layout() {
            super.layout()
            scheduleInstallIfNeeded()
        }

        deinit {
            if let dragMonitor {
                NSEvent.removeMonitor(dragMonitor)
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

        private func installDragMonitor() {
            guard dragMonitor == nil else { return }
            // If the user starts dragging, don't fire the delayed rename.
            dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
                self?.coordinator?.cancelPendingRename()
                return event
            }
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
                scroll.contentView.contentInsets = NSEdgeInsets()
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
