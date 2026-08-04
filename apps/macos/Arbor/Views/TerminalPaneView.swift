import AppKit
import SwiftTerm
import SwiftUI

/// UserDefaults keys shared by the terminal pane and View menu commands.
enum TerminalPreferences {
    static let isVisibleKey = "arbor.terminal.isVisible"
    static let followCwdKey = "arbor.terminal.followCwd"
}

/// Bottom/side terminal chrome: header controls + SwiftTerm PTY host.
struct TerminalPaneView: View {
    /// Focused browser pane folder (shell cwd target).
    let cwd: URL
    @Binding var followCwd: Bool
    @Binding var restartToken: UUID

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            EmbeddedTerminalRepresentable(
                cwd: cwd,
                followCwd: followCwd
            )
            .id(restartToken)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text("Terminal")
                .font(.headline)
            Text(cwd.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(cwd.path)

            Spacer(minLength: 8)

            Toggle("Follow Folder", isOn: $followCwd)
                .toggleStyle(.checkbox)
                .help("When the browser navigates, cd the shell into the new folder")

            Button("Restart") {
                restartToken = UUID()
            }
            .help("Recreate the shell in the current folder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - SwiftTerm host

private struct EmbeddedTerminalRepresentable: NSViewRepresentable {
    let cwd: URL
    let followCwd: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 200))
        view.autoresizingMask = [.width, .height]
        view.processDelegate = context.coordinator
        context.coordinator.attach(view: view, cwd: cwd)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        context.coordinator.followCwd = followCwd
        // `.id(restartToken)` recreates the view for Restart; here only follow-cwd updates apply.
        if followCwd {
            context.coordinator.followDirectoryIfNeeded(view: nsView, cwd: cwd)
        }
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        nsView.terminate()
        nsView.processDelegate = nil
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var followCwd = true
        /// Last directory the shell was told to use (start or `cd`).
        var shellCwd: URL?
        private var didStart = false

        func attach(view: LocalProcessTerminalView, cwd: URL) {
            // Start after layout so the PTY gets a non-zero size.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                self.startIfNeeded(view: view, cwd: cwd)
            }
        }

        func startIfNeeded(view: LocalProcessTerminalView, cwd: URL) {
            guard !didStart else { return }
            didStart = true
            launch(view: view, cwd: cwd)
        }

        func followDirectoryIfNeeded(view: LocalProcessTerminalView, cwd: URL) {
            guard shellCwd?.standardizedFileURL != cwd.standardizedFileURL else { return }
            guard view.process.running else {
                startIfNeeded(view: view, cwd: cwd)
                return
            }
            sendCd(view: view, to: cwd)
        }

        private func launch(view: LocalProcessTerminalView, cwd: URL) {
            let directory = cwd.standardizedFileURL
            shellCwd = directory
            view.startProcess(
                executable: Self.userShell,
                args: ["-i"],
                environment: nil,
                execName: nil,
                currentDirectory: directory.path
            )
        }

        private func sendCd(view: LocalProcessTerminalView, to cwd: URL) {
            let directory = cwd.standardizedFileURL
            shellCwd = directory
            let escaped = Self.shellEscape(directory.path)
            let command = "cd \(escaped)\n"
            guard let data = command.data(using: .utf8) else { return }
            view.process.send(data: Array(data)[...])
        }

        static var userShell: String {
            if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty,
               FileManager.default.isExecutableFile(atPath: shell)
            {
                return shell
            }
            return "/bin/zsh"
        }

        /// Single-quote escape safe for `cd '…'`.
        static func shellEscape(_ path: String) -> String {
            "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        // MARK: LocalProcessTerminalViewDelegate

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            guard let directory else { return }
            shellCwd = URL(fileURLWithPath: directory, isDirectory: true)
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            // Shell exited — leave buffer as-is; user can Restart.
            didStart = false
        }
    }
}
