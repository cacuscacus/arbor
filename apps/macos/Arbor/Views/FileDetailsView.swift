import SwiftUI

struct FileDetailsView: View {
    let details: FileDetails
    @Environment(\.dismiss) private var dismiss
    @State private var folderSize: FolderSizeSnapshot?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private var shouldCalculateFolderSize: Bool {
        details.isDirectory && details.localURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 36))
                    .foregroundStyle(details.isDirectory && !details.isPackage ? .blue : .secondary)
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(details.name)
                        .font(.headline)
                        .textSelection(.enabled)
                    Text(details.kind)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()

            Divider()

            Form {
                LabeledContent("Path") {
                    Text(details.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: 360, alignment: .trailing)
                }
                LabeledContent("Size") {
                    if shouldCalculateFolderSize {
                        HStack(spacing: 6) {
                            if folderSize == nil || folderSize?.isComplete == false {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                            Text(folderSize?.formattedSummary ?? "Calculating…")
                                .monospacedDigit()
                                .foregroundStyle(folderSize?.isComplete == true ? .primary : .secondary)
                                .help(exactBytesTooltip(for: folderSize?.totalBytes))
                        }
                    } else {
                        Text(details.formattedSize)
                            .monospacedDigit()
                            .help(exactBytesTooltip(for: details.size))
                    }
                }
                LabeledContent("Created", value: format(details.created))
                LabeledContent("Modified", value: format(details.modified))
                LabeledContent("Permissions", value: details.permissionsDescription)
                LabeledContent("Readable", value: details.isReadable ? "Yes" : "No")
                LabeledContent("Writable", value: details.isWritable ? "Yes" : "No")
                if details.isSymbolicLink {
                    LabeledContent("Symbolic Link", value: "Yes")
                }
                if details.isPackage {
                    LabeledContent("Package", value: "Yes")
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)

            Spacer(minLength: 0)

            HStack {
                Button("Copy File Path") {
                    WorkspaceActions.copyPaths([details.item])
                }
                if details.localURL != nil {
                    Button("Show in Finder") {
                        WorkspaceActions.revealInFinder([details.item])
                    }
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 480, height: 420)
        .task(id: details.item) {
            guard shouldCalculateFolderSize, let url = details.localURL else {
                folderSize = nil
                return
            }
            folderSize = FolderSizeSnapshot(totalBytes: 0, itemCount: 0, isComplete: false)
            let final = await FolderSizeCalculator.calculate(url: url) { snapshot in
                Task { @MainActor in
                    self.folderSize = snapshot
                }
            }
            if !Task.isCancelled {
                folderSize = final
            }
        }
    }

    private func exactBytesTooltip(for bytes: UInt64?) -> String {
        guard let bytes else { return "" }
        let formatted = NumberFormatter.localizedString(
            from: NSNumber(value: bytes),
            number: .decimal
        )
        return "\(formatted) bytes"
    }

    private var iconName: String {
        if details.isPackage { return "app.fill" }
        if details.isDirectory { return "folder.fill" }
        return "doc"
    }

    private func format(_ date: Date?) -> String {
        guard let date else { return "—" }
        return Self.dateFormatter.string(from: date)
    }
}
