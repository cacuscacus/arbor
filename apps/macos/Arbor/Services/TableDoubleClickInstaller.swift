import AppKit
import SwiftUI

/// Installs `NSTableView.doubleAction` so double-click works without
/// SwiftUI tap gestures (which break single-click selection on List/Table).
struct TableDoubleClickInstaller: NSViewRepresentable {
    var rowCount: Int
    var onDoubleClickRow: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDoubleClickRow: onDoubleClickRow)
    }

    func makeNSView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: InstallerView, context: Context) {
        context.coordinator.onDoubleClickRow = onDoubleClickRow
        context.coordinator.rowCount = rowCount
        nsView.coordinator = context.coordinator
        nsView.scheduleInstall()
    }

    final class Coordinator: NSObject {
        var onDoubleClickRow: (Int) -> Void
        var rowCount: Int = 0

        init(onDoubleClickRow: @escaping (Int) -> Void) {
            self.onDoubleClickRow = onDoubleClickRow
        }

        @objc func tableDoubleClicked(_ sender: Any?) {
            guard let table = sender as? NSTableView else { return }
            let row = table.clickedRow
            guard row >= 0, row < rowCount else { return }
            onDoubleClickRow(row)
        }
    }

    final class InstallerView: NSView {
        var coordinator: Coordinator?
        private weak var hookedTable: NSTableView?
        private var attempts = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleInstall()
        }

        override func layout() {
            super.layout()
            scheduleInstall()
        }

        func scheduleInstall() {
            attempts = 0
            tryInstall()
            // SwiftUI may materialize the NSTableView a moment later.
            DispatchQueue.main.async { [weak self] in
                self?.tryInstall()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.tryInstall()
            }
        }

        private func tryInstall() {
            guard let coordinator else { return }
            guard let table = findEnclosingTableView() else {
                if attempts < 8 {
                    attempts += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.tryInstall()
                    }
                }
                return
            }

            hookedTable = table
            table.target = coordinator
            table.doubleAction = #selector(Coordinator.tableDoubleClicked(_:))
        }

        private func findEnclosingTableView() -> NSTableView? {
            var view: NSView? = superview
            while let current = view {
                if let table = current as? NSTableView {
                    return table
                }
                if let table = current.findSubview(ofType: NSTableView.self) {
                    return table
                }
                view = current.superview
            }
            return window?.contentView?.findSubview(ofType: NSTableView.self)
        }
    }
}

private extension NSView {
    func findSubview<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T {
            return match
        }
        for subview in subviews {
            if let match = subview.findSubview(ofType: type) {
                return match
            }
        }
        return nil
    }
}
