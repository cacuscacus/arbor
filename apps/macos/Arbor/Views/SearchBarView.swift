import SwiftUI

struct SearchBarView: View {
    @Binding var query: String
    @Binding var scope: SearchScope
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
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(minWidth: 160, idealWidth: 220, maxWidth: 280)
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

            Picker("Scope", selection: $scope) {
                Text("Folder").tag(SearchScope.currentFolder)
                Text("Global").tag(SearchScope.global)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 140)
            .help("Search scope")

            Text(resultCount.map(resultLabel) ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 40, alignment: .trailing)
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
        switch scope {
        case .currentFolder:
            return "Search folder — try *.json"
        case .global:
            return "Search home — try blabla*.json"
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
/// concentric ring breakdown, explicit Stop button, and Load More / Continue controls.
struct SearchStatusBanner: View {
    var scope: SearchScope
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
            } else if case .limitReached(let limit) = stopReason,
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

    private var runningLabel: String {
        let elapsed = String(format: "%.1fs", elapsedSeconds)
        let matchPart = hitCount > 0 ? " · \(Self.formatCount(hitCount)) \(hitCount == 1 ? "match" : "matches")" : ""
        return "Searching \(scopeLabel) (\(backend.rawValue))… \(elapsed)\(matchPart)"
    }

    private var finishedLabel: String {
        let elapsed = String(format: "%.1fs", elapsedSeconds)
        switch stopReason {
        case .limitReached(let limit):
            return "Showing first \(Self.formatCount(limit)) matches (limit reached · \(elapsed))"
        case .timedOut(let seconds):
            return "Stopped after \(Int(seconds.rounded()))s — showing \(Self.formatCount(hitCount)) partial \(hitCount == 1 ? "match" : "matches")"
        case .nodeLimitReached(let visited):
            return "Scan limit reached (\(Self.formatCount(visited)) items) — showing \(Self.formatCount(hitCount)) partial \(hitCount == 1 ? "match" : "matches")"
        case .stoppedByUser:
            return "Search stopped — showing \(Self.formatCount(hitCount)) partial \(hitCount == 1 ? "match" : "matches")"
        case .completed, nil:
            if scope == .global {
                let localCount = (countsByRing[.currentFolderDirect] ?? 0) + (countsByRing[.currentFolderSubtree] ?? 0)
                let globalCount = countsByRing[.global] ?? 0
                if localCount > 0, globalCount > 0 {
                    return "\(Self.formatCount(localCount)) in \(folderName) · \(Self.formatCount(globalCount)) in Home (\(elapsed))"
                }
            }
            return "\(Self.formatCount(hitCount)) \(hitCount == 1 ? "match" : "matches") in \(scopeLabel) (\(backend.rawValue) · \(elapsed))"
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
