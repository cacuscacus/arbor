import SwiftUI

/// Native scrollable list for Content Search (`rg` / Spotlight `kMDItemTextContent`) results.
/// Displays each matching file once with its relative path, match badge, and highlighted
/// line-numbered monospaced snippets.
struct ContentSearchResultsView<MenuContent: View>: View {
    let hits: [SearchHit]
    @Binding var selection: Set<ItemRef>
    var onOpen: (FileEntry) -> Void
    @ViewBuilder var contextMenu: (FileEntry) -> MenuContent

    @State private var lastClickedID: ItemRef?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(hits) { hit in
                    ContentSearchHitRow(
                        hit: hit,
                        isSelected: selection.contains(hit.id)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        selection = [hit.id]
                        lastClickedID = hit.id
                        onOpen(hit.entry)
                    }
                    .onTapGesture {
                        handleSelectionClick(hit.id)
                    }
                    .contextMenu {
                        contextMenu(hit.entry)
                    }
                }
            }
            // Clear the floating search panel at top-trailing while letting content scroll smoothly beneath it.
            .padding(.top, 56)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.001))
    }

    private func handleSelectionClick(_ id: ItemRef) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
            lastClickedID = id
        } else if flags.contains(.shift),
                  let anchor = lastClickedID,
                  let aIdx = hits.firstIndex(where: { $0.id == anchor }),
                  let bIdx = hits.firstIndex(where: { $0.id == id })
        {
            let range = min(aIdx, bIdx)...max(aIdx, bIdx)
            selection = Set(hits[range].map(\.id))
        } else {
            selection = [id]
            lastClickedID = id
        }
    }
}

private struct ContentSearchHitRow: View {
    let hit: SearchHit
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                FileIconImage(item: hit.id, size: 18)

                Text(hit.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !hit.parentPath.isEmpty {
                    Text(hit.parentPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Text(badgeText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.8), in: Capsule())

                if hit.entry.size > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(hit.entry.size), countStyle: .file))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            if hit.snippets.isEmpty {
                Text("Matched inside indexed document")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 26)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(hit.snippets.prefix(5)) { snippet in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(snippet.lineNumber)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 34, alignment: .trailing)

                            Text(highlightedText(for: snippet))
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.primary.opacity(0.9))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.035))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.06),
                    lineWidth: 1
                )
        }
    }

    private var badgeText: String {
        if hit.snippets.isEmpty {
            return "Spotlight"
        }
        let n = hit.snippets.count
        return n == 1 ? "1 line" : "\(n) lines"
    }

    private func highlightedText(for snippet: ContentMatchSnippet) -> AttributedString {
        var attributed = AttributedString(snippet.lineText)
        let chars = snippet.lineText
        guard snippet.matchLength > 0,
              snippet.matchStart >= 0,
              snippet.matchStart < chars.count
        else {
            return attributed
        }
        let clampedEnd = min(chars.count, snippet.matchStart + snippet.matchLength)
        let startStringIdx = chars.index(chars.startIndex, offsetBy: snippet.matchStart)
        let endStringIdx = chars.index(chars.startIndex, offsetBy: clampedEnd)

        if let startAttr = AttributedString.Index(startStringIdx, within: attributed),
           let endAttr = AttributedString.Index(endStringIdx, within: attributed),
           startAttr < endAttr
        {
            attributed[startAttr..<endAttr].backgroundColor = Color.accentColor.opacity(0.28)
            attributed[startAttr..<endAttr].foregroundColor = .primary
            attributed[startAttr..<endAttr].font = .system(size: 11.5, weight: .semibold, design: .monospaced)
        }
        return attributed
    }
}
