import SwiftUI

struct SSHLocationSheet: View {
    @Bindable var store: SSHLocationStore
    var onAdded: (ItemRef) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: EndpointMode = .alias
    @State private var aliases: [OpenSSHConfigAlias] = []
    @State private var alias = ""
    @State private var host = ""
    @State private var user = ""
    @State private var port = "22"
    @State private var displayName = ""
    @State private var rootPath = "/"
    @State private var errorMessage: String?

    private enum EndpointMode: String, CaseIterable, Identifiable {
        case alias = "SSH Config Alias"
        case direct = "Host"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add SSH Location")
                .font(.title2.weight(.semibold))

            Form {
                Picker("Connection", selection: $mode) {
                    ForEach(EndpointMode.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                if mode == .alias {
                    if !aliases.isEmpty {
                        Picker("Known Alias", selection: $alias) {
                            Text("Choose or type below…").tag("")
                            ForEach(aliases) { candidate in
                                Text(candidate.name).tag(candidate.name)
                            }
                        }
                    }
                    TextField("Alias", text: $alias)
                        .textContentType(.URL)
                } else {
                    TextField("Host", text: $host)
                        .textContentType(.URL)
                    TextField("User (optional)", text: $user)
                        .textContentType(.username)
                    TextField("Port", text: $port)
                        .frame(width: 90)
                }

                TextField("Location Name", text: $displayName)
                TextField("Remote Folder", text: $rootPath)
                    .help("Use an absolute path. Home-folder expansion is resolved when SFTP connects.")
            }
            .formStyle(.grouped)

            Text("Authentication uses your OpenSSH configuration, ssh-agent, and default keys. Host keys are never accepted silently.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Location") { addLocation() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            aliases = await Task.detached {
                OpenSSHConfigDiscovery.discover()
            }.value
            if alias.isEmpty, aliases.count == 1 {
                alias = aliases[0].name
            }
        }
    }

    private func addLocation() {
        let endpoint: SSHEndpoint
        switch mode {
        case .alias:
            let value = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                errorMessage = "Enter an SSH config alias."
                return
            }
            endpoint = .openSSHConfigAlias(value)
        case .direct:
            let hostname = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hostname.isEmpty else {
                errorMessage = "Enter a host."
                return
            }
            guard let resolvedPort = UInt16(port), resolvedPort > 0 else {
                errorMessage = "Enter a valid port."
                return
            }
            let username = user.trimmingCharacters(in: .whitespacesAndNewlines)
            endpoint = .direct(
                host: hostname,
                user: username.isEmpty ? nil : username,
                port: resolvedPort
            )
        }

        let path = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else {
            errorMessage = "Remote Folder must be an absolute path for this first SSH slice."
            return
        }
        let title = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = SSHLocationProfile(
            displayName: title.isEmpty ? endpoint.displayDestination : title,
            endpoint: endpoint,
            rootPath: path
        )
        do {
            let added = try store.add(profile)
            onAdded(added.root)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
