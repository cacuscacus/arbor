import AppKit
import SwiftUI

/// Hooks the detail file `NSTableView` for:
/// - double-click → open
/// - delayed second click on an already-selected name → rename
///
/// Never attaches to `NSOutlineView` (sidebar).
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
        nsView.scheduleInstall()
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
            guard let table = sender as? NSTableView, !(table is NSOutlineView) else { return }
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
            guard let table = sender as? NSTableView, !(table is NSOutlineView) else { return }
            let row = table.clickedRow
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
            scheduleInstall()
        }

        deinit {
            if let dragMonitor {
                NSEvent.removeMonitor(dragMonitor)
            }
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
            table.target = coordinator
            table.action = #selector(Coordinator.tableClicked(_:))
            table.doubleAction = #selector(Coordinator.tableDoubleClicked(_:))
            table.focusRingType = .none
        }

        private func findDetailFileTable() -> NSTableView? {
            var view: NSView? = superview
            while let current = view {
                if let table = current.asFileBrowserTable() {
                    return table
                }
                if let table = current.findFileBrowserTable() {
                    return table
                }
                if current is NSSplitView {
                    break
                }
                view = current.superview
            }
            return nil
        }
    }
}

private extension NSView {
    func asFileBrowserTable() -> NSTableView? {
        guard let table = self as? NSTableView, !(self is NSOutlineView) else {
            return nil
        }
        return table
    }

    func findFileBrowserTable() -> NSTableView? {
        if let table = asFileBrowserTable() {
            return table
        }
        for subview in subviews {
            if let table = subview.findFileBrowserTable() {
                return table
            }
        }
        return nil
    }
}
