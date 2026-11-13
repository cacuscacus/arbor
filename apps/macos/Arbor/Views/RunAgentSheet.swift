import SwiftUI

struct RunAgentSheet: View {
    let context: ExecutionContext

    @Bindable private var tools = AgentToolsStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPresetID: String = ""
    @State private var prompt: String = ""
    @FocusState private var promptFocused: Bool

    private var enabledPresets: [AgentToolPreset] {
        tools.enabledPresets
    }

    private var selectedPreset: AgentToolPreset? {
        enabledPresets.first { $0.id == selectedPresetID } ?? enabledPresets.first
    }

    private var expandedPreview: String {
        guard let selectedPreset,
              let folder = context.intrinsicLocalDirectoryURL,
              let selection = context.intrinsicLocalSelectionURLs
        else { return "" }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = trimmed.isEmpty ? selectedPreset.quickRunTemplate : selectedPreset.promptTemplate
        return AgentCommandExpander.expand(
            template,
            folder: folder,
            prompt: trimmed,
            selection: selection
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Run Agent")
                .font(.title2.weight(.semibold))

            LabeledContent("Folder") {
                Text(context.workingDirectory.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(context.workingDirectory.path)
            }

            if !context.selection.isEmpty {
                LabeledContent("Selection") {
                    Text("\(context.selection.count) item\(context.selection.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
            }

            if enabledPresets.isEmpty {
                ContentUnavailableView(
                    "No tools enabled",
                    systemImage: "wrench.and.screwdriver",
                    description: Text("Enable a tool in Settings → Tools.")
                )
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Picker("Tool", selection: $selectedPresetID) {
                    ForEach(enabledPresets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }

                if let host = selectedPreset?.host {
                    Text("Host: \(host.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt")
                        .font(.headline)
                    TextEditor(text: $prompt)
                        .font(.body)
                        .focused($promptFocused)
                        .frame(minHeight: 90, maxHeight: 140)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(.separator)
                        }
                    Text("Leave empty for Quick Run (opens the agent REPL / TUI when the template allows).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !expandedPreview.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(expandedPreview)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            HStack {
                Button("Settings…") {
                    SettingsWindowController.shared.show()
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Quick Run" : "Run") {
                    run()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedPreset == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            selectedPresetID = tools.defaultPreset?.id ?? enabledPresets.first?.id ?? ""
            DispatchQueue.main.async {
                promptFocused = true
            }
        }
    }

    private func run() {
        guard let selectedPreset else { return }
        tools.defaultPresetID = selectedPreset.id
        AgentLauncher.launch(
            preset: selectedPreset,
            prompt: prompt,
            context: context
        )
        dismiss()
    }
}
