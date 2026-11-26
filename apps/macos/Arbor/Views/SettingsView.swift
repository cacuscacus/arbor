import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AgentToolsSettingsView()
                .tabItem {
                    Label("Agent Tools", systemImage: "wrench.and.screwdriver")
                }

            SearchSettingsView()
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
        }
        .frame(minWidth: 720, minHeight: 460)
    }
}

private struct SearchSettingsView: View {
    @Bindable private var prefs = SearchPreferencesStore.shared
    @State private var excludedNamesText = ""
    @State private var excludedGlobalPathsText = ""

    var body: some View {
        Form {
            limitsSection
            progressiveSection
            contentSearchSection
            exclusionsSection
            resetSection
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: syncTextFields)
    }

    @ViewBuilder
    private var limitsSection: some View {
        Section("Limits & Safety Guardrails") {
            Picker("Default result limit", selection: $prefs.resultLimit) {
                ForEach(SearchOptions.limitPresets, id: \.self) { count in
                    Text("\(count) matches").tag(count)
                }
            }
            .help("Stops streaming once this many valid matches are found. You can still load more inline.")

            Picker("Search timeout", selection: $prefs.timeoutSeconds) {
                ForEach(SearchOptions.timeoutPresets, id: \.self) { seconds in
                    Text("\(Int(seconds)) seconds").tag(seconds)
                }
            }
            .help("Prevents stalled Spotlight or disk walks from hanging the app; partial results are kept.")

            Picker("Max scanned entries (walk fallback)", selection: $prefs.maxVisitedNodes) {
                ForEach(SearchOptions.maxVisitedPresets, id: \.self) { count in
                    Text("\(NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)) items")
                        .tag(count)
                }
            }

            Picker("Maximum folder depth", selection: $prefs.maxDepth) {
                Text("Unlimited").tag(0)
                Text("6 levels").tag(6)
                Text("10 levels").tag(10)
                Text("20 levels").tag(20)
            }
        }
    }

    @ViewBuilder
    private var progressiveSection: some View {
        Section("Progressive Scoping & Tabs") {
            Toggle("Search current folder first while Global runs", isOn: $prefs.progressiveScoping)
                .help("Shows instant matches from your current folder on top while Global results stream underneath.")
            Toggle("Open Global searches in a new tab automatically", isOn: $prefs.openGlobalInNewTab)
                .help("Switching to Global opens a dedicated Search Tab so you can keep browsing in your current tab. You can also press ⌘⇧F anytime.")
        }
    }

    @ViewBuilder
    private var contentSearchSection: some View {
        Section("Content Search (grep)") {
            Picker("Max file size", selection: $prefs.maxContentFileSizeMB) {
                ForEach(SearchOptions.maxContentFileSizeMBPresets, id: \.self) { mb in
                    Text(mb == 0 ? "Unlimited" : "\(mb) MB").tag(mb)
                }
            }
            .help("Skips very large files (logs, bundles, datasets) during content search.")

            Picker("Snippets per file", selection: $prefs.maxMatchesPerFile) {
                ForEach(SearchOptions.maxMatchesPerFilePresets, id: \.self) { count in
                    Text("\(count) lines").tag(count)
                }
            }

            Toggle("Respect .gitignore rules", isOn: $prefs.respectGitignoreInContent)
                .help("Skips git-ignored build outputs and caches when searching file contents with ripgrep.")

            Toggle("Always use deep ripgrep scan for Global Content", isOn: $prefs.deepGlobalContentScan)
                .help("Default uses Spotlight's instant text index for Global Content; turn this on to scan disk with ripgrep by default.")
        }
    }

    @ViewBuilder
    private var exclusionsSection: some View {
        Section("Exclusions") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Excluded folder names (comma-separated)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: $excludedNamesText, prompt: Text(".git, node_modules, DerivedData, …"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitExclusions)
                    .onChange(of: excludedNamesText) { _, value in
                        prefs.excludedNames = SearchPreferencesStore.parseCSVList(value)
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Excluded Global paths under Home (comma-separated)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: $excludedGlobalPathsText, prompt: Text("Library/Caches, Library/CloudStorage, …"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitExclusions)
                    .onChange(of: excludedGlobalPathsText) { _, value in
                        prefs.excludedGlobalRelativePaths = SearchPreferencesStore.parseCSVList(value)
                    }
                Text("Skipped during Global searches to avoid cache storms and cloud downloads. Searching inside them directly still works.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var resetSection: some View {
        Section {
            HStack {
                Spacer()
                Button("Reset Search Defaults") {
                    prefs.resetDefaults()
                    syncTextFields()
                }
            }
        }
    }

    private func syncTextFields() {
        excludedNamesText = SearchPreferencesStore.formatCSVList(prefs.excludedNames)
        excludedGlobalPathsText = SearchPreferencesStore.formatCSVList(prefs.excludedGlobalRelativePaths)
    }

    private func commitExclusions() {
        prefs.excludedNames = SearchPreferencesStore.parseCSVList(excludedNamesText)
        prefs.excludedGlobalRelativePaths = SearchPreferencesStore.parseCSVList(excludedGlobalPathsText)
    }
}

private struct AgentToolsSettingsView: View {
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
            window.setContentSize(NSSize(width: 780, height: 540))
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
