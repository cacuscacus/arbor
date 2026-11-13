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
    /// Focused browser pane execution target.
    let context: ExecutionContext
    @Binding var followCwd: Bool
    @Binding var restartToken: UUID

    var body: some View {
        Group {
            if let cwd = context.intrinsicLocalDirectoryURL {
                localTerminal(cwd: cwd)
            } else {
                ContentUnavailableView(
                    "Terminal Unavailable",
                    systemImage: "terminal",
                    description: Text("This location does not support local execution.")
                )
                .overlay(alignment: .topTrailing) {
                    Button("Close") {
                        UserDefaults.standard.set(false, forKey: TerminalPreferences.isVisibleKey)
                    }
                    .padding(8)
                }
            }
        }
        .background(.background)
    }

    private func localTerminal(cwd: URL) -> some View {
        let bridge = EmbeddedTerminalBridge.shared
        return VStack(spacing: 0) {
            header(cwd: cwd)
            Divider()
            EmbeddedTerminalRepresentable(
                cwd: cwd,
                followCwd: followCwd,
                commandToken: bridge.enqueueToken,
                consumeCommand: { bridge.consume() }
            )
            .id(restartToken)
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        }
    }

    private func header(cwd: URL) -> some View {
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

            Button("Copy Output") {
                _ = EmbeddedTerminalBridge.shared.copyBufferToPasteboard()
            }
            .help("Copy the terminal buffer to the clipboard")

            Button("Restart") {
                restartToken = UUID()
            }
            .help("Recreate the shell in the current folder")

            Button("Close") {
                UserDefaults.standard.set(false, forKey: TerminalPreferences.isVisibleKey)
            }
            .help("Hide the terminal pane")
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
    let commandToken: UUID
    let consumeCommand: () -> String?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 200))
        view.autoresizingMask = [.width, .height]
        view.processDelegate = context.coordinator
        context.coordinator.attach(view: view, cwd: cwd)
        EmbeddedTerminalBridge.shared.bufferTextProvider = { [weak view] in
            guard let view else { return nil }
            let data = view.getTerminal().getBufferAsData()
            return String(data: data, encoding: .utf8)
        }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        context.coordinator.followCwd = followCwd
        // `.id(restartToken)` recreates the view for Restart; here only follow-cwd updates apply.
        if followCwd {
            context.coordinator.followDirectoryIfNeeded(view: nsView, cwd: cwd)
        }
        context.coordinator.deliverPendingCommandIfNeeded(
            view: nsView,
            token: commandToken,
            consume: consumeCommand
        )
        EmbeddedTerminalBridge.shared.bufferTextProvider = { [weak nsView] in
            guard let nsView else { return nil }
            let data = nsView.getTerminal().getBufferAsData()
            return String(data: data, encoding: .utf8)
        }
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        if EmbeddedTerminalBridge.shared.bufferTextProvider != nil {
            // Clear only if this view was the provider (best-effort).
            EmbeddedTerminalBridge.shared.bufferTextProvider = nil
        }
        nsView.terminate()
        nsView.processDelegate = nil
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var followCwd = true
        /// Last directory the shell was told to use (start or `cd`).
        var shellCwd: URL?
        private var requestedCwd: URL?
        private var didStart = false
        private var lastCommandToken: UUID?

        func attach(view: LocalProcessTerminalView, cwd: URL) {
            requestedCwd = cwd.standardizedFileURL
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
            requestedCwd = cwd.standardizedFileURL
            guard shellCwd?.standardizedFileURL != cwd.standardizedFileURL else { return }
            guard view.process.running else {
                startIfNeeded(view: view, cwd: cwd)
                return
            }
            sendCd(view: view, to: cwd)
        }

        func deliverPendingCommandIfNeeded(
            view: LocalProcessTerminalView,
            token: UUID,
            consume: () -> String?
        ) {
            guard lastCommandToken != token else { return }
            lastCommandToken = token
            guard let command = consume() else { return }

            // Wait briefly for a freshly shown PTY / interactive shell to accept input.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak view] in
                guard let self, let view else { return }
                guard let cwd = self.shellCwd ?? self.requestedCwd else { return }
                self.startIfNeeded(view: view, cwd: cwd)
                guard let data = command.data(using: .utf8) else { return }
                view.process.send(data: Array(data)[...])
            }
        }

        private func launch(view: LocalProcessTerminalView, cwd: URL) {
            let directory = cwd.standardizedFileURL
            shellCwd = directory
            // Login + interactive so ~/.zprofile (Homebrew `brew shellenv`) loads —
            // GUI apps inherit a stripped PATH; non-login `zsh -i` alone often lacks brew.
            view.startProcess(
                executable: Self.userShell,
                args: ["-il"],
                environment: Self.augmentedEnvironment(),
                execName: nil,
                currentDirectory: directory.path
            )
        }

        /// Inherit Arbor's environment and ensure common tool prefixes are on PATH.
        private static func augmentedEnvironment() -> [String] {
            var env = ProcessInfo.processInfo.environment
            let extras = [
                "/opt/homebrew/bin",
                "/opt/homebrew/sbin",
                "/usr/local/bin",
                NSHomeDirectory() + "/.local/bin",
                NSHomeDirectory() + "/.kimi-code/bin",
            ]
            let current = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            var parts = current.split(separator: ":").map(String.init)
            for prefix in extras.reversed() where !parts.contains(prefix) {
                parts.insert(prefix, at: 0)
            }
            env["PATH"] = parts.joined(separator: ":")
            return env.map { "\($0.key)=\($0.value)" }
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
