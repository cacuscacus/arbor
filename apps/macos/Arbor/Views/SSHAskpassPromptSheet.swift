import SwiftUI

/// Secure prompt for SSH passwords and key passphrases, served through the
/// askpass bridge (see `SSHAskpassService`). Reached whenever OpenSSH needs a
/// secret the agent cannot provide. One sheet at a time; queued prompts
/// surface as each one resolves.
struct SSHAskpassPromptSheet: View {
    let prompt: SSHAskpassService.Prompt

    @Environment(\.dismiss) private var dismiss
    @State private var secret = ""
    @State private var remember = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("SSH Authentication", systemImage: "key.fill")
                .font(.title2.weight(.semibold))

            Text(prompt.question)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            SecureField("Password or passphrase", text: $secret)
                .focused($fieldFocused)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)

            Toggle("Remember in Keychain", isOn: $remember)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    SSHAskpassService.shared.removePrompt(id: prompt.id)
                    prompt.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Continue") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(secret.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            fieldFocused = true
        }
    }

    private func submit() {
        let value = secret
        secret = ""
        SSHAskpassService.shared.removePrompt(id: prompt.id)
        prompt.submit(value, remember)
        dismiss()
    }
}
