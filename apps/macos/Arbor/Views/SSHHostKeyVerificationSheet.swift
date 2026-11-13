import SwiftUI

struct SSHHostKeyVerificationSheet: View {
    let candidate: SSHHostKeyCandidate
    let onTrusted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isTrusting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Verify SSH Host Key", systemImage: "lock.shield")
                .font(.title2.weight(.semibold))

            Text("Arbor has never connected to \(candidate.knownHostsName). Verify one of these fingerprints with the server administrator before trusting it.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(candidate.fingerprints, id: \.self) { fingerprint in
                    Text(fingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            if candidate.hasExistingEntry {
                Label(
                    "A key is already recorded for this host. The key may have changed; Arbor will not replace it automatically. Resolve the entry in ~/.ssh/known_hosts first.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Trust and Connect") {
                    trust()
                }
                .buttonStyle(.borderedProminent)
                .disabled(candidate.hasExistingEntry || isTrusting)
            }
        }
        .padding(24)
        .frame(width: 600)
    }

    private func trust() {
        isTrusting = true
        errorMessage = nil
        Task {
            do {
                try await SSHHostKeyService.trust(candidate)
                await SSHTransportPool.shared.disconnect(candidate.id)
                onTrusted()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isTrusting = false
            }
        }
    }
}
