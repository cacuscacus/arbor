import SwiftUI

/// Floating glass transfer HUD shown in the bottom-right corner above the
/// breadcrumb bar while slow local copies or SFTP transfers are running.
struct TransferProgressOverlay: View {
    var store: TransferProgressStore = .shared

    var body: some View {
        let active = store.visibleJobs
        if !active.isEmpty {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(active) { job in
                    TransferProgressCard(job: job) {
                        store.cancelJob(job.id)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: active.map(\.id))
            .padding(.trailing, 14)
            .padding(.bottom, 36)
        }
    }
}

private struct TransferProgressCard: View {
    let job: TransferProgressStore.Job
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: job.operation == .copy ? "doc.on.doc" : "arrow.right.doc.on.clipboard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(job.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(job.isCancelling)
                .help("Cancel transfer")
            }

            if let fraction = job.fractionCompleted {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }

            Text(job.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
    }
}
