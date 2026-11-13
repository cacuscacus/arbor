import AppKit
import SwiftUI

/// Finder-style **Go to Folder…** sheet (⇧⌘G).
///
/// Accepts absolute paths, `~`, and bare names resolved against the folder you
/// are browsing. Tab completes the last component; Return navigates.
struct GoToFolderSheet: View {
    let currentDirectory: URL
    var onGo: (URL, URL?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var suggestion: String?
    /// Guards against Return being delivered twice (onSubmit + default action).
    @State private var didSubmit = false
    @FocusState private var fieldFocused: Bool

    private var resolver: GoToFolderResolver {
        GoToFolderResolver(currentDirectory: currentDirectory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Folder")
                .font(.headline)

            TextField("Folder path", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .focused($fieldFocused)
                .onKeyPress(.return) {
                    submit()
                    return .handled
                }
                .onChange(of: text) { _, _ in
                    error = nil
                    suggestion = nil
                }
                .onKeyPress(.tab) {
                    complete()
                    return .handled
                }

            HStack(spacing: 6) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .lineLimit(2)
                } else if let suggestion {
                    Label("Tab: \(suggestion)", systemImage: "arrow.right.to.line")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(currentDirectory.path)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 16)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Go") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        // AppKit-level so Return/Esc work in optimized builds too: SwiftUI's
        // `.onKeyPress` on this container is not delivered when the inner
        // NSTextField owns the key window's first responder.
        .background(
            SheetKeyMonitor(
                onReturn: submit,
                onEscape: { dismiss() }
            )
        )
        .onAppear {
            fieldFocused = true
            prefill()
        }
    }

    private func prefill() {
        // Finder starts with the current folder so typing a name appends to it.
        text = currentDirectory.path.hasSuffix("/")
            ? currentDirectory.path
            : currentDirectory.path + "/"
    }

    private func complete() {
        guard let completion = resolver.completion(for: text) else { return }
        text = completion
        suggestion = completion
    }

    private func submit() {
        guard !didSubmit else { return }
        do {
            let (folder, selection) = try resolver.resolveReveal(text)
            didSubmit = true
            onGo(folder, selection)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}


/// Local key monitor for a modal sheet. Return commits, Esc cancels — regardless
/// of which control currently owns first responder.
private struct SheetKeyMonitor: NSViewRepresentable {
    var onReturn: () -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onReturn = onReturn
        context.coordinator.onEscape = onEscape
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onReturn = onReturn
        context.coordinator.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var onReturn: (() -> Void)?
        var onEscape: (() -> Void)?
        private var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let flags = event.modifierFlags.intersection([.command, .option, .control])
                guard flags.isEmpty else { return event }
                switch event.keyCode {
                case 36, 76: // Return, keypad Enter
                    self.onReturn?()
                    return nil
                case 53: // Escape
                    self.onEscape?()
                    return nil
                default:
                    return event
                }
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { uninstall() }
    }
}
