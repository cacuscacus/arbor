import SwiftUI

struct SSHHostKeyVerificationSheet: View {
    let candidate: SSHHostKeyCandidate
    let onTrusted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isTrusting = false
    @State private var errorMessage: String?

    private var isRotation: Bool { candidate.hasExistingEntry }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(
                isRotation ? "SSH Host Key Changed" : "Verify SSH Host Key",
                systemImage: "lock.shield"
            )
            .font(.title2.weight(.semibold))

            Text(
                isRotation
                    ? "The host key for \(candidate.knownHostsName) no longer matches the recorded one. This happens after a server reinstall or IP reuse. Confirm the new fingerprint with the server administrator before replacing the record."
                    : "Arbor has never connected to \(candidate.knownHostsName). Verify one of these fingerprints with the server administrator before trusting it."
            )
            .foregroundStyle(.secondary)

            if isRotation, !candidate.existingFingerprints.isEmpty {
                fingerprintSection(
                    title: "Recorded key",
                    fingerprints: candidate.existingFingerprints,
                    tint: .secondary
                )
            }

            fingerprintSection(
                title: isRotation ? "Offered by server" : "Fingerprints",
                fingerprints: candidate.fingerprints,
                tint: isRotation ? .primary : .secondary
            )

            if isRotation {
                Label(
                    "Arbor will remove the recorded key and store the new one in ~/.ssh/known_hosts. This is never done silently.",
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
                Button(isRotation ? "Replace and Connect" : "Trust and Connect") {
                    trust()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTrusting)
            }
        }
        .padding(24)
        .frame(width: 620)
    }

    private func fingerprintSection(
        title: String,
        fingerprints: [String],
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            ForEach(fingerprints, id: \.self) { fingerprint in
                Text(fingerprint)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func trust() {
        isTrusting = true
        errorMessage = nil
        Task {
            do {
                if isRotation {
                    try await SSHHostKeyService.replace(candidate)
                } else {
                    try await SSHHostKeyService.trust(candidate)
                }
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
