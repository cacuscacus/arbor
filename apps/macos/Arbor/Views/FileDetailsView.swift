import SwiftUI

struct FileDetailsView: View {
    let details: FileDetails
    @Environment(\.dismiss) private var dismiss

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

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
                LabeledContent("Size", value: details.formattedSize)
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
                Button("Copy Path") {
                    WorkspaceActions.copyPath(details.url)
                }
                Button("Show in Finder") {
                    WorkspaceActions.revealInFinder(details.url)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 480, height: 420)
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
