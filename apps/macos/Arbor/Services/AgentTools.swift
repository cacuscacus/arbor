import AppKit
import Foundation
import Observation

// MARK: - Models

enum AgentLaunchHost: String, Codable, CaseIterable, Identifiable, Sendable {
    case embedded
    case terminalApp
    case ghostty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .embedded: return "Embedded Terminal"
        case .terminalApp: return "Terminal.app"
        case .ghostty: return "Ghostty"
        }
    }
}

struct AgentToolPreset: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    /// Executable for PATH detection / display (e.g. `opencode`). Launch still uses templates.
    var executable: String
    /// Optional absolute override when the binary is not on PATH.
    var executablePath: String?
    /// Shell command template with `{folder}`, `{prompt}`, `{selection}` placeholders.
    /// Substitutions are shell-escaped (including quotes).
    var promptTemplate: String
    /// Template used when the prompt sheet is empty / Quick Run.
    var quickRunTemplate: String
    var host: AgentLaunchHost
    var isEnabled: Bool
    /// Built-in presets cannot be deleted (can still be edited / disabled).
    var isBuiltIn: Bool

    static func builtinDefaults() -> [AgentToolPreset] {
        [
            AgentToolPreset(
                id: "opencode",
                name: "OpenCode",
                executable: "opencode",
                executablePath: nil,
                promptTemplate: "opencode --prompt {prompt} {folder}",
                quickRunTemplate: "opencode {folder}",
                host: .embedded,
                isEnabled: true,
                isBuiltIn: true
            ),
            AgentToolPreset(
                id: "kimi",
                name: "Kimi Code",
                executable: "kimi",
                executablePath: AgentPathDetector.defaultKimiPath()?.path,
                // Kimi uses process cwd (no project path arg) — always cd first.
                promptTemplate: "cd {folder} && kimi -p {prompt}",
                quickRunTemplate: "cd {folder} && kimi",
                host: .embedded,
                isEnabled: true,
                isBuiltIn: true
            ),
            AgentToolPreset(
                id: "cursor-agent",
                name: "Cursor Agent",
                executable: "agent",
                executablePath: nil,
                promptTemplate: "agent {prompt}",
                quickRunTemplate: "agent",
                host: .embedded,
                isEnabled: true,
                isBuiltIn: true
            ),
        ]
    }
}

// MARK: - PATH detection

enum AgentPathDetector {
    static func resolveExecutable(named name: String, override: String?) -> URL? {
        if let override, !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return which(name)
    }

    static func which(_ name: String) -> URL? {
        let fm = FileManager.default
        var search: [String] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            NSHomeDirectory() + "/.local/bin",
            NSHomeDirectory() + "/.kimi-code/bin",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            search.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        var seen = Set<String>()
        for dir in search where seen.insert(dir).inserted {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func defaultKimiPath() -> URL? {
        which("kimi")
    }
}

// MARK: - Template expansion

enum AgentCommandExpander {
    /// Expand placeholders; each substituted value is single-quote shell-escaped.
    static func expand(
        _ template: String,
        folder: URL,
        prompt: String,
        selection: [URL]
    ) -> String {
        var result = template
        result = replaceToken(result, token: "{folder}", with: shellEscape(folder.path))
        result = replaceToken(result, token: "{prompt}", with: shellEscape(prompt))
        let selectionValue = selection
            .map { shellEscape($0.path) }
            .joined(separator: " ")
        result = replaceToken(result, token: "{selection}", with: selectionValue)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replaceToken(_ template: String, token: String, with value: String) -> String {
        template.replacingOccurrences(of: token, with: value)
    }

    /// Single-quote escape safe for POSIX shells.
    static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Store

@MainActor
@Observable
final class AgentToolsStore {
    static let shared = AgentToolsStore()

    private static let presetsKey = "arbor.agent.presets"
    private static let defaultPresetIDKey = "arbor.agent.defaultPresetID"

    private(set) var presets: [AgentToolPreset] = []
    var defaultPresetID: String {
        didSet { UserDefaults.standard.set(defaultPresetID, forKey: Self.defaultPresetIDKey) }
    }

    var enabledPresets: [AgentToolPreset] {
        presets.filter(\.isEnabled)
    }

    var defaultPreset: AgentToolPreset? {
        enabledPresets.first { $0.id == defaultPresetID } ?? enabledPresets.first
    }

    private init() {
        defaultPresetID = UserDefaults.standard.string(forKey: Self.defaultPresetIDKey) ?? "opencode"
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.presetsKey),
              let decoded = try? JSONDecoder().decode([AgentToolPreset].self, from: data),
              !decoded.isEmpty
        else {
            presets = AgentToolPreset.builtinDefaults()
            persist()
            return
        }
        presets = Self.mergeBuiltins(with: decoded)
    }

    func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: Self.presetsKey)
    }

    func update(_ preset: AgentToolPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
        persist()
    }

    func addCustom(name: String) {
        let id = "custom-\(UUID().uuidString.prefix(8))"
        let preset = AgentToolPreset(
            id: id,
            name: name.isEmpty ? "Custom" : name,
            executable: "echo",
            executablePath: nil,
            promptTemplate: "echo {prompt}",
            quickRunTemplate: "echo ready",
            host: .embedded,
            isEnabled: true,
            isBuiltIn: false
        )
        presets.append(preset)
        persist()
    }

    func remove(_ id: String) {
        guard let preset = presets.first(where: { $0.id == id }), !preset.isBuiltIn else { return }
        presets.removeAll { $0.id == id }
        if defaultPresetID == id {
            defaultPresetID = enabledPresets.first?.id ?? "opencode"
        }
        persist()
    }

    func resetBuiltins() {
        let custom = presets.filter { !$0.isBuiltIn }
        presets = AgentToolPreset.builtinDefaults() + custom
        persist()
    }

    private static func mergeBuiltins(with saved: [AgentToolPreset]) -> [AgentToolPreset] {
        let builtins = AgentToolPreset.builtinDefaults()
        var byID = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        var merged: [AgentToolPreset] = []
        for builtin in builtins {
            if var existing = byID.removeValue(forKey: builtin.id) {
                existing.isBuiltIn = true
                // Keep user edits; refresh empty kimi path from detector when missing.
                if existing.id == "kimi" {
                    if (existing.executablePath ?? "").isEmpty {
                        existing.executablePath = AgentPathDetector.defaultKimiPath()?.path
                    }
                    // Migrate pre-folder templates so right-click target is honored.
                    if existing.promptTemplate == "kimi -p {prompt}" {
                        existing.promptTemplate = builtin.promptTemplate
                    }
                    if existing.quickRunTemplate == "kimi" {
                        existing.quickRunTemplate = builtin.quickRunTemplate
                    }
                }
                merged.append(existing)
            } else {
                merged.append(builtin)
            }
        }
        merged.append(contentsOf: byID.values.filter { !$0.isBuiltIn }.sorted { $0.name < $1.name })
        return merged
    }
}

// MARK: - Run request / bridge

struct AgentRunRequest: Identifiable, Equatable {
    let id = UUID()
    var folder: URL
    var selection: [URL]
    /// When true, skip sheet and quick-run with default preset.
    var quickRun: Bool = false
}

/// Queues shell lines for the embedded PTY (consumed by `TerminalPaneView`).
@MainActor
@Observable
final class EmbeddedTerminalBridge {
    static let shared = EmbeddedTerminalBridge()

    private(set) var pendingCommand: String?
    private(set) var enqueueToken = UUID()
    /// Set by the mounted PTY host to export scrollback/screen text.
    var bufferTextProvider: (() -> String?)?

    func enqueue(_ command: String) {
        var line = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        if !line.hasSuffix("\n") { line.append("\n") }
        pendingCommand = line
        enqueueToken = UUID()
    }

    func consume() -> String? {
        let value = pendingCommand
        pendingCommand = nil
        return value
    }

    @discardableResult
    func copyBufferToPasteboard() -> Bool {
        guard let text = bufferTextProvider?()?.trimmingCharacters(in: .newlines),
              !text.isEmpty
        else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }
}

@MainActor
@Observable
final class AgentRunCoordinator {
    static let shared = AgentRunCoordinator()

    var request: AgentRunRequest?
    var launchError: String?

    func presentRunAgent(folder: URL, selection: [URL] = [], quickRun: Bool = false) {
        if quickRun {
            guard let preset = AgentToolsStore.shared.defaultPreset else {
                launchError = "No agent tools are enabled. Open Settings to configure one."
                return
            }
            AgentLauncher.launch(
                preset: preset,
                folder: folder,
                prompt: "",
                selection: selection
            )
            return
        }
        request = AgentRunRequest(folder: folder, selection: selection, quickRun: false)
    }

    func dismiss() {
        request = nil
    }
}

// MARK: - Launcher

enum AgentLauncher {
    @MainActor
    static func launch(
        preset: AgentToolPreset,
        folder: URL,
        prompt: String,
        selection: [URL]
    ) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = trimmedPrompt.isEmpty ? preset.quickRunTemplate : preset.promptTemplate
        var command = AgentCommandExpander.expand(
            template,
            folder: folder.standardizedFileURL,
            prompt: trimmedPrompt,
            selection: selection.map(\.standardizedFileURL)
        )
        command = resolveLeadingExecutable(in: command, preset: preset)

        guard !command.isEmpty else {
            AgentRunCoordinator.shared.launchError = "Command template expanded to an empty string."
            return
        }

        if AgentPathDetector.resolveExecutable(
            named: preset.executable,
            override: preset.executablePath
        ) == nil, !preset.executable.isEmpty {
            AgentRunCoordinator.shared.launchError =
                "Could not find “\(preset.executable)” on PATH. Set a path override in Settings → Tools."
            return
        }

        switch preset.host {
        case .embedded:
            UserDefaults.standard.set(true, forKey: TerminalPreferences.isVisibleKey)
            // Defer so the terminal view can mount before we inject the line.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                EmbeddedTerminalBridge.shared.enqueue(command)
            }
        case .terminalApp:
            WorkspaceActions.runInTerminalApp(command: command, directory: folder)
        case .ghostty:
            WorkspaceActions.runInGhostty(command: command, directory: folder)
        }
    }

    /// Prefer absolute binary path so GUI-spawned shells without Homebrew still work.
    private static func resolveLeadingExecutable(in command: String, preset: AgentToolPreset) -> String {
        let name = preset.executable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let resolved = AgentPathDetector.resolveExecutable(
                  named: name,
                  override: preset.executablePath
              )
        else {
            return command
        }

        let absolute = AgentCommandExpander.shellEscape(resolved.path)
        return replaceExecutableToken(in: command, name: name, with: absolute)
    }

    /// Replaces bare `name` tokens (start of command, after `&&`, etc.) with an absolute path.
    private static func replaceExecutableToken(in command: String, name: String, with absolute: String) -> String {
        var result = ""
        var index = command.startIndex
        while index < command.endIndex {
            if command[index...].hasPrefix(name) {
                let end = command.index(index, offsetBy: name.count)
                let beforeOK: Bool = {
                    if index == command.startIndex { return true }
                    let previous = command[command.index(before: index)]
                    return previous.isWhitespace || previous == "&" || previous == ";"
                }()
                let afterOK = end == command.endIndex || command[end].isWhitespace
                if beforeOK && afterOK {
                    result += absolute
                    index = end
                    continue
                }
            }
            result.append(command[index])
            index = command.index(after: index)
        }
        return result
    }
}
