import AppKit
import SwiftUI

/// Finder-like rename field: focuses immediately and selects the base name
/// (excluding extension for files/packages).
struct RenameTextField: NSViewRepresentable {
    @Binding var text: String
    var isDirectory: Bool
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.focusRingType = .default
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submitted(_:))
        context.coordinator.field = field

        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            Self.selectName(in: field, isDirectory: isDirectory)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text, nsView.currentEditor() == nil {
            nsView.stringValue = text
        }
    }

    static func selectName(in field: NSTextField, isDirectory: Bool) {
        guard let editor = field.currentEditor() else {
            field.selectText(nil)
            return
        }
        let name = field.stringValue as NSString
        if isDirectory {
            editor.selectedRange = NSRange(location: 0, length: name.length)
            return
        }
        let ext = name.pathExtension
        if ext.isEmpty {
            editor.selectedRange = NSRange(location: 0, length: name.length)
        } else {
            let baseLength = name.length - ext.count - 1
            editor.selectedRange = NSRange(location: 0, length: max(0, baseLength))
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameTextField
        weak var field: NSTextField?

        init(parent: RenameTextField) {
            self.parent = parent
        }

        @objc func submitted(_ sender: NSTextField) {
            parent.text = sender.stringValue
            parent.onSubmit()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.text = field?.stringValue ?? parent.text
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}
