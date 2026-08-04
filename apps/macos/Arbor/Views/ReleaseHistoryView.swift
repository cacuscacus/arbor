import AppKit
import SwiftUI

/// Fetches and displays [`CHANGELOG.md`](https://github.com/cacuscacus/arbor/blob/main/CHANGELOG.md)
/// from the public GitHub repository.
struct ReleaseHistoryView: View {
    private static let changelogURL = URL(
        string: "https://raw.githubusercontent.com/cacuscacus/arbor/main/CHANGELOG.md"
    )!
    private static let githubChangelogURL = URL(
        string: "https://github.com/cacuscacus/arbor/blob/main/CHANGELOG.md"
    )!
    private static let githubReleasesURL = URL(
        string: "https://github.com/cacuscacus/arbor/releases"
    )!

    @State private var markdownSource = ""
    @State private var loadState: LoadState = .loading

    private enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 520)
        .task {
            await reload()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Release History")
                    .font(.headline)
                Text("Loaded from the Arbor repository on GitHub")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") {
                Task { await reload() }
            }
            .disabled(loadState == .loading)
            Menu("Open on GitHub") {
                Button("CHANGELOG.md") {
                    NSWorkspace.shared.open(Self.githubChangelogURL)
                }
                Button("Releases") {
                    NSWorkspace.shared.open(Self.githubReleasesURL)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView("Loading changelog…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Text("Couldn’t load release history")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack {
                    Button("Retry") {
                        Task { await reload() }
                    }
                    Button("Open on GitHub") {
                        NSWorkspace.shared.open(Self.githubChangelogURL)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            ScrollView {
                changelogText
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    private var changelogText: Text {
        if let attributed = try? AttributedString(
            markdown: markdownSource,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full
            )
        ) {
            return Text(attributed)
        }
        return Text(markdownSource)
    }

    private func reload() async {
        loadState = .loading
        do {
            var request = URLRequest(url: Self.changelogURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Arbor-macOS", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                throw URLError(.cannotDecodeContentData)
            }
            markdownSource = text
            loadState = .loaded
        } catch {
            loadState = .failed(
                "Check your network connection, or open the changelog on GitHub. (\(error.localizedDescription))"
            )
        }
    }
}

final class ReleaseHistoryWindowController {
    static let shared = ReleaseHistoryWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentViewController: NSHostingController(rootView: ReleaseHistoryView())
            )
            window.title = "Release History"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 640, height: 520))
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

#Preview {
    ReleaseHistoryView()
}
