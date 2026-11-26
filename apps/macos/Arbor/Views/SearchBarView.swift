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
    var smartExpansionActive: Bool = false
    var isExpandingTerms: Bool = false
    var expandedTerms: [String] = []
    var expansionError: String? = nil
    var activeFilters: [SearchFilterToken] = []
    var onAddFilter: ((String) -> Void)? = nil
    var onRemoveFilter: ((Int) -> Void)? = nil
    var onToggleSmartExpansion: (() -> Void)? = nil
    var onDismissExpandedTerm: ((String) -> Void)? = nil
    var onStop: (() -> Void)? = nil
    var onOpenInTab: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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

                if let onAddFilter {
                    filterMenu(onAddFilter: onAddFilter)
                }

                if let onToggleSmartExpansion {
                    Button(action: onToggleSmartExpansion) {
                        Image(systemName: smartExpansionActive ? "sparkles" : "sparkles")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(smartExpansionActive ? Color.accentColor : Color.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(
                                smartExpansionActive
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(
                        smartExpansionActive
                            ? "Smart Expansion (Local MLX) active — click to pause for this tab"
                            : "Expand query with local MLX model (opt-in)"
                    )
                }

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

            if !activeFilters.isEmpty {
                filterChipsBar
            }

            if showsExpansionBar {
                expansionBar
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 2)
    }

    private func filterMenu(onAddFilter: @escaping (String) -> Void) -> some View {
        Menu {
            Menu("Kind") {
                Button("Folders (kind:folder)") { onAddFilter("kind:folder") }
                Button("Images (kind:image)") { onAddFilter("kind:image") }
                Button("PDFs (kind:pdf)") { onAddFilter("kind:pdf") }
                Button("Documents (kind:document)") { onAddFilter("kind:document") }
                Button("Code (kind:code)") { onAddFilter("kind:code") }
                Button("Videos (kind:video)") { onAddFilter("kind:video") }
                Button("Audio (kind:audio)") { onAddFilter("kind:audio") }
                Button("Archives (kind:archive)") { onAddFilter("kind:archive") }
            }

            Menu("Extension") {
                Button(".swift (ext:swift)") { onAddFilter("ext:swift") }
                Button(".ts / .tsx (ext:ts,tsx)") { onAddFilter("ext:ts,tsx") }
                Button(".rs (ext:rs)") { onAddFilter("ext:rs") }
                Button(".py (ext:py)") { onAddFilter("ext:py") }
                Button(".json (ext:json)") { onAddFilter("ext:json") }
                Button(".md (ext:md)") { onAddFilter("ext:md") }
                Button(".pdf (ext:pdf)") { onAddFilter("ext:pdf") }
                Button(".png / .jpg (ext:png,jpg)") { onAddFilter("ext:png,jpg") }
            }

            Menu("Size") {
                Button("Larger than 1 MB (size>1mb)") { onAddFilter("size>1mb") }
                Button("Larger than 10 MB (size>10mb)") { onAddFilter("size>10mb") }
                Button("Larger than 100 MB (size>100mb)") { onAddFilter("size>100mb") }
                Button("Smaller than 100 KB (size<100kb)") { onAddFilter("size<100kb") }
            }

            Menu("Modified") {
                Button("Today (modified:today)") { onAddFilter("modified:today") }
                Button("Last 24 hours (modified:24h)") { onAddFilter("modified:24h") }
                Button("Last 7 days (modified:7d)") { onAddFilter("modified:7d") }
                Button("Last 30 days (modified:30d)") { onAddFilter("modified:30d") }
                Button("Older than 1 year (modified>1y)") { onAddFilter("modified>1y") }
            }
        } label: {
            Image(systemName: activeFilters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(activeFilters.isEmpty ? Color.secondary : Color.accentColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add structured search filter (ext:, kind:, size>, modified:)")
    }

    private var filterChipsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(activeFilters.enumerated()), id: \.element.id) { index, filter in
                    HStack(spacing: 4) {
                        Image(systemName: filter.iconName)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(filter.displayLabel)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.primary)
                        if let onRemoveFilter {
                            Button {
                                onRemoveFilter(index)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove filter '\(filter.rawToken)'")
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75)
                    }
                }
            }
            .padding(.leading, 4)
            .padding(.bottom, 1)
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    private var showsExpansionBar: Bool {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return isExpandingTerms || !expandedTerms.isEmpty || (smartExpansionActive && expansionError != nil)
    }

    private var expansionBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            if isExpandingTerms {
                ProgressView()
                    .controlSize(.mini)
                Text("Expanding locally via MLX…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let expansionError, expandedTerms.isEmpty {
                Text(expansionError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else {
                Text("Related:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach(expandedTerms, id: \.self) { term in
                    HStack(spacing: 3) {
                        Text(term)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.primary)
                        if let onDismissExpandedTerm {
                            Button {
                                onDismissExpandedTerm(term)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove '\(term)' from expanded search")
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 0.75)
                    }
                }
            }
        }
        .padding(.leading, 4)
        .padding(.bottom, 1)
    }

    private var placeholder: String {
        switch (mode, scope) {
        case (.name, .currentFolder):
            return "Search — ext:swift, size>1mb, modified:7d"
        case (.name, .global):
            return "Search home — kind:pdf modified:7d"
        case (.content, .currentFolder):
            return "Search text — try auth ext:swift"
        case (.content, .global):
            return "Search text in home — invoice kind:pdf"
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
        let expandedCount = countsByRing[.expanded] ?? 0
        let expandedSuffix = expandedCount > 0 ? " · +\(Self.formatCount(expandedCount)) related" : ""

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
                    return "\(Self.formatCount(localCount)) in \(folderName) · \(Self.formatCount(globalCount)) in Home\(expandedSuffix) (\(backend.rawValue) · \(elapsed))"
                }
            }
            let directCount = hitCount - expandedCount
            if expandedCount > 0 {
                return "\(Self.formatCount(directCount)) direct\(expandedSuffix) in \(scopeLabel) (\(backend.rawValue) · \(elapsed))"
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
