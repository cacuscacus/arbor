import SwiftUI

struct FileBrowserView: View {
    let path: URL
    @State private var entries: [FileEntry] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(path: path)

            Divider()

            if let errorMessage {
                ContentUnavailableView(
                    "Could not open folder",
                    systemImage: "folder.badge.questionmark",
                    description: Text(errorMessage)
                )
            } else if entries.isEmpty {
                ContentUnavailableView(
                    "Empty folder",
                    systemImage: "folder",
                    description: Text(path.path)
                )
            } else {
                List(entries) { entry in
                    HStack {
                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                            .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                            .frame(width: 20)
                        Text(entry.name)
                        Spacer()
                        if !entry.isDirectory {
                            Text(entry.formattedSize)
                                .foregroundStyle(.secondary)
                                .font(.caption.monospacedDigit())
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear { reload() }
        .onChange(of: path) { _, _ in reload() }
    }

    private func reload() {
        // Temporary local listing. Replace with arbor-ffi once linked.
        do {
            entries = try LocalFileService.list(path: path)
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
    }
}

struct BreadcrumbBar: View {
    let path: URL

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(path.pathComponents.enumerated()), id: \.offset) { index, component in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(component == "/" ? "Macintosh HD" : component)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}
