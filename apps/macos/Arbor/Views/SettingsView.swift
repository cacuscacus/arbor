import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable private var tools = AgentToolsStore.shared
    @State private var selectedPresetID: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedPresetID) {
                Section("Agent Tools") {
                    ForEach(tools.presets) { preset in
                        HStack {
                            Text(preset.name)
                            Spacer()
                            if !preset.isEnabled {
                                Text("Off")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            if tools.defaultPresetID == preset.id {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(preset.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        tools.addCustom(name: "Custom")
                        selectedPresetID = tools.presets.last?.id
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add custom tool")

                    Button {
                        if let id = selectedPresetID {
                            tools.remove(id)
                            selectedPresetID = tools.presets.first?.id
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedPresetIsBuiltIn)
                    .help("Remove custom tool")

                    Spacer()

                    Button("Reset Built-ins") {
                        tools.resetBuiltins()
                    }
                    .help("Restore OpenCode / Kimi / Cursor Agent defaults (keeps custom tools)")
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
        } detail: {
            if let binding = selectedPresetBinding {
                AgentPresetEditor(preset: binding, isDefault: tools.defaultPresetID == binding.wrappedValue.id) {
                    tools.defaultPresetID = binding.wrappedValue.id
                }
            } else {
                ContentUnavailableView(
                    "Agent Tools",
                    systemImage: "wrench.and.screwdriver",
                    description: Text("Select a tool to edit its command template and launch host.")
                )
            }
        }
        .navigationTitle("Settings")
        .frame(minWidth: 720, minHeight: 440)
        .onAppear {
            if selectedPresetID == nil {
                selectedPresetID = tools.defaultPreset?.id ?? tools.presets.first?.id
            }
        }
    }

    private var selectedPresetIsBuiltIn: Bool {
        guard let id = selectedPresetID,
              let preset = tools.presets.first(where: { $0.id == id })
        else { return true }
        return preset.isBuiltIn
    }

    private var selectedPresetBinding: Binding<AgentToolPreset>? {
        guard let id = selectedPresetID,
              let index = tools.presets.firstIndex(where: { $0.id == id })
        else { return nil }
        return Binding(
            get: { tools.presets[index] },
            set: { tools.update($0) }
        )
    }
}

private struct AgentPresetEditor: View {
    @Binding var preset: AgentToolPreset
    var isDefault: Bool
    var onMakeDefault: () -> Void

    var body: some View {
        Form {
            Section("Tool") {
                TextField("Name", text: $preset.name)
                Toggle("Enabled", isOn: $preset.isEnabled)
                if !isDefault {
                    Button("Make Default") {
                        onMakeDefault()
                    }
                } else {
                    LabeledContent("Default") {
                        Text("Yes")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Executable") {
                TextField("Command name", text: $preset.executable)
                    .help("Used for PATH detection (e.g. opencode, kimi, agent)")
                TextField("Path override", text: pathOverrideBinding)
                    .help("Absolute path when the binary is not on PATH")
                detectionRow
            }

            Section("Command templates") {
                Text("Placeholders: {folder} {prompt} {selection} — values are shell-escaped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("With prompt", text: $preset.promptTemplate)
                TextField("Quick run (no prompt)", text: $preset.quickRunTemplate)
                if !previewCommand.isEmpty {
                    LabeledContent("Preview") {
                        Text(previewCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Section("Launch host") {
                Picker("Run in", selection: $preset.host) {
                    ForEach(AgentLaunchHost.allCases) { host in
                        Text(host.title).tag(host)
                    }
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var pathOverrideBinding: Binding<String> {
        Binding(
            get: { preset.executablePath ?? "" },
            set: { preset.executablePath = $0.isEmpty ? nil : $0 }
        )
    }

    private var detectedPath: URL? {
        AgentPathDetector.resolveExecutable(named: preset.executable, override: preset.executablePath)
    }

    @ViewBuilder
    private var detectionRow: some View {
        if let detectedPath {
            LabeledContent("Detected") {
                Text(detectedPath.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
        } else if !preset.executable.isEmpty {
            LabeledContent("Detected") {
                Text("Not found on PATH")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var previewCommand: String {
        AgentCommandExpander.expand(
            preset.promptTemplate,
            folder: URL(fileURLWithPath: "/path/to/folder"),
            prompt: "organize files by topic",
            selection: []
        )
    }
}

final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Arbor Settings"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 780, height: 520))
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

#Preview {
    SettingsView()
}
