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
            // SwiftUI `Text(AttributedString(markdown:))` collapses block structure;
            // render Keep a Changelog line-by-line instead.
            ScrollView {
                ChangelogDocumentView(source: markdownSource)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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

// MARK: - Changelog layout

private struct ChangelogDocumentView: View {
    let source: String

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(Array(ChangelogBlock.parse(source).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ChangelogBlock) -> some View {
        switch block {
        case .h1(let text):
            inlineText(text)
                .font(.title.weight(.semibold))
                .padding(.top, 4)
                .padding(.bottom, 2)
        case .h2(let text):
            inlineText(text)
                .font(.title2.weight(.semibold))
                .padding(.top, 14)
                .padding(.bottom, 2)
        case .h3(let text):
            inlineText(text)
                .font(.headline)
                .padding(.top, 8)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .foregroundStyle(.secondary)
                inlineText(text)
                    .font(.body)
            }
            .padding(.leading, 4)
        case .paragraph(let text):
            inlineText(text)
                .font(.body)
                .foregroundStyle(.primary.opacity(0.92))
        case .spacer:
            Spacer()
                .frame(height: 6)
        }
    }

    private func inlineText(_ markdownLine: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: markdownLine,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return Text(attributed)
        }
        return Text(markdownLine)
    }
}

private enum ChangelogBlock {
    case h1(String)
    case h2(String)
    case h3(String)
    case bullet(String)
    case paragraph(String)
    case spacer

    static func parse(_ source: String) -> [ChangelogBlock] {
        var blocks: [ChangelogBlock] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if blocks.last.map({ if case .spacer = $0 { return true }; return false }) != true {
                    blocks.append(.spacer)
                }
                continue
            }
            // Skip reference-style link definitions at the bottom (`[1.0.0]: https://...`).
            if trimmed.hasPrefix("[") && trimmed.contains("]: http") {
                continue
            }
            if trimmed.hasPrefix("### ") {
                blocks.append(.h3(String(trimmed.dropFirst(4))))
            } else if trimmed.hasPrefix("## ") {
                blocks.append(.h2(String(trimmed.dropFirst(3))))
            } else if trimmed.hasPrefix("# ") {
                blocks.append(.h1(String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("- ") {
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
            } else {
                blocks.append(.paragraph(trimmed))
            }
        }

        while let last = blocks.last, case .spacer = last {
            blocks.removeLast()
        }
        return blocks
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
        // Always rebuild content when shown so Refresh / relaunch pick up formatter fixes
        // even if the window was created earlier in the session.
        window?.contentViewController = NSHostingController(rootView: ReleaseHistoryView())
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

#Preview {
    ReleaseHistoryView()
}
