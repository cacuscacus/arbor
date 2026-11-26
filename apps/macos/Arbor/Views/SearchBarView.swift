import SwiftUI

struct SearchBarView: View {
    @Binding var query: String
    @Binding var scope: SearchScope
    @Binding var mode: SearchMode
    var isSearching: Bool
    var resultCount: Int?
    var activeLimit: Int = SearchOptions.defaultResultLimit
    var stopReason: SearchStopReason? = nil
    var focus: FocusState<Bool>.Binding
    var onStop: (() -> Void)? = nil
    var onOpenInTab: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: mode == .content ? "doc.text.magnifyingglass" : "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(minWidth: 150, idealWidth: 210, maxWidth: 270)
                    .focused(focus)

                // Keep a stable trailing slot so ProgressView ↔ clear-button
                // swaps don't recreate the TextField and drop keyboard focus.
                ZStack {
                    if isSearching {
                        if let onStop {
                            Button(action: onStop) {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                            .buttonStyle(.plain)
                            .help("Stop search")
                        } else {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    } else if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .frame(width: 14, height: 14)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))

            Picker("Mode", selection: $mode) {
                Text("Name").tag(SearchMode.name)
                Text("Content").tag(SearchMode.content)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 132)
            .help("Search filenames or file contents")

            Picker("Scope", selection: $scope) {
                Text("Folder").tag(SearchScope.currentFolder)
                Text("Global").tag(SearchScope.global)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 132)
            .help("Search scope")

            Text(resultCount.map(resultLabel) ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 36, alignment: .trailing)
                .opacity(resultCount != nil && !query.isEmpty ? 1 : 0)
                .accessibilityHidden(resultCount == nil || query.isEmpty)

            if let onOpenInTab, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: onOpenInTab) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open search in a new tab")
            }

            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close search")
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 2)
    }

    private var placeholder: String {
        switch (mode, scope) {
        case (.name, .currentFolder):
            return "Search folder — try *.json"
        case (.name, .global):
            return "Search home — try blabla*.json"
        case (.content, .currentFolder):
            return "Search text in folder…"
        case (.content, .global):
            return "Search text across home…"
        }
    }

    private func resultLabel(_ count: Int) -> String {
        if case .limitReached = stopReason {
            return "\(count)+"
        }
        if count >= activeLimit {
            return "\(activeLimit)+"
        }
        return "\(count)"
    }
}

/// Bottom status bar shown while a search is active: live progress, elapsed time,
/// concentric ring breakdown, explicit Stop button, Load More / Continue, and Deep Scan (rg).
struct SearchStatusBanner: View {
    var scope: SearchScope
    var mode: SearchMode = .name
    var folderName: String
    var backend: SearchBackendKind
    var isSearching: Bool
    var hitCount: Int
    var countsByRing: [SearchRing: Int]
    var stopReason: SearchStopReason?
    var elapsedSeconds: Double
    var activeLimit: Int
    var onStop: () -> Void
    var onExpandLimit: (Int) -> Void
    var onContinueTimeout: () -> Void
    var onDeepScan: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            if isSearching {
                ProgressView()
                    .controlSize(.mini)
                Text(runningLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            } else {
                Image(systemName: statusIcon)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                Text(finishedLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isSearching {
                Button("Stop", action: onStop)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Stop searching and keep partial results")
            } else {
                if mode == .content,
                   scope == .global,
                   backend == .spotlightContent,
                   let onDeepScan
                {
                    Button("Deep Disk Scan (rg)", action: onDeepScan)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Scan unindexed code and text files across Home with ripgrep")
                }

                if case .limitReached(let limit) = stopReason,
                   let next = SearchOptions.nextExpandedLimit(after: limit)
                {
                    Button("Load up to \(Self.formatCount(next))") {
                        onExpandLimit(next)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                } else if case .timedOut = stopReason {
                    Button("Continue (+10s)", action: onContinueTimeout)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
        .background(.bar)
    }

    private var scopeLabel: String {
        switch scope {
        case .currentFolder: return folderName
        case .global: return "Home"
        }
    }

    private var unitSingular: String { mode == .content ? "file" : "match" }
    private var unitPlural: String { mode == .content ? "files" : "matches" }

    private var runningLabel: String {
        let elapsed = String(format: "%.1fs", elapsedSeconds)
        let matchPart = hitCount > 0 ? " · \(Self.formatCount(hitCount)) \(hitCount == 1 ? unitSingular : unitPlural)" : ""
        let verb = mode == .content ? "Scanning text in" : "Searching"
        return "\(verb) \(scopeLabel) (\(backend.rawValue))… \(elapsed)\(matchPart)"
    }

    private var finishedLabel: String {
        let elapsed = String(format: "%.1fs", elapsedSeconds)
        switch stopReason {
        case .limitReached(let limit):
            return "Showing first \(Self.formatCount(limit)) \(unitPlural) (limit reached · \(elapsed))"
        case .timedOut(let seconds):
            return "Stopped after \(Int(seconds.rounded()))s — showing \(Self.formatCount(hitCount)) partial \(hitCount == 1 ? unitSingular : unitPlural)"
        case .nodeLimitReached(let visited):
            return "Scan limit reached (\(Self.formatCount(visited)) items) — showing \(Self.formatCount(hitCount)) partial \(hitCount == 1 ? unitSingular : unitPlural)"
        case .stoppedByUser:
            return "Search stopped — showing \(Self.formatCount(hitCount)) partial \(hitCount == 1 ? unitSingular : unitPlural)"
        case .completed, nil:
            if scope == .global {
                let localCount = (countsByRing[.currentFolderDirect] ?? 0) + (countsByRing[.currentFolderSubtree] ?? 0)
                let globalCount = countsByRing[.global] ?? 0
                if localCount > 0, globalCount > 0 {
                    return "\(Self.formatCount(localCount)) in \(folderName) · \(Self.formatCount(globalCount)) in Home (\(backend.rawValue) · \(elapsed))"
                }
            }
            return "\(Self.formatCount(hitCount)) \(hitCount == 1 ? unitSingular : unitPlural) in \(scopeLabel) (\(backend.rawValue) · \(elapsed))"
        }
    }

    private var statusIcon: String {
        switch stopReason {
        case .limitReached, .timedOut, .nodeLimitReached:
            return "exclamationmark.circle"
        case .stoppedByUser:
            return "stop.circle"
        case .completed, nil:
            return "checkmark.circle"
        }
    }

    private var statusColor: Color {
        switch stopReason {
        case .limitReached, .timedOut, .nodeLimitReached:
            return .orange
        case .stoppedByUser:
            return .secondary
        case .completed, nil:
            return .secondary
        }
    }

    private static func formatCount(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}
