import AppKit
import SwiftUI

struct QuickDiffRequest: Identifiable {
    let id = UUID()
    let left: URL
    let right: URL
}

struct QuickDiffView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case sideBySide = "Side by Side"
        case unified = "Unified"

        var id: String { rawValue }
    }

    private enum Side {
        case left
        case right
    }

    let left: URL
    let right: URL

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .sideBySide
    @State private var document: QuickDiffDocument?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var leftScroll = ScrollPosition(edge: .top)
    @State private var rightScroll = ScrollPosition(edge: .top)
    @State private var leftOffsetY: CGFloat = 0
    @State private var rightOffsetY: CGFloat = 0
    @State private var leftMaxCharacters = 0
    @State private var rightMaxCharacters = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                if isLoading {
                    ProgressView("Comparing files…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Could Not Compare Files",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if let document {
                    diffContent(document)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 560, idealHeight: 700)
        .task(id: "\(left.path)\u{1f}\(right.path)") {
            await load()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Quick Diff")
                    .font(.headline)
                Text("\(left.lastPathComponent) ↔ \(right.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let document {
                HStack(spacing: 8) {
                    DiffCountBadge(text: "+\(document.addedCount)", color: .green)
                    DiffCountBadge(text: "−\(document.removedCount)", color: .red)
                    if document.changedCount > 0 {
                        DiffCountBadge(text: "~\(document.changedCount)", color: .orange)
                    }
                }
            }

            Picker("Layout", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func diffContent(_ document: QuickDiffDocument) -> some View {
        if document.addedCount == 0,
           document.removedCount == 0,
           document.changedCount == 0
        {
            ContentUnavailableView(
                "Files Are Identical",
                systemImage: "checkmark.circle",
                description: Text("No line differences found.")
            )
        } else {
            switch mode {
            case .sideBySide:
                sideBySide(document)
            case .unified:
                unified(document)
            }
        }
    }

    private func sideBySide(_ document: QuickDiffDocument) -> some View {
        GeometryReader { proxy in
            let columnWidth = max((proxy.size.width - 1) / 2, 220)
            HStack(spacing: 0) {
                diffColumn(document, side: .left, columnWidth: columnWidth)
                columnSeparator
                diffColumn(document, side: .right, columnWidth: columnWidth)
            }
        }
    }

    private func diffColumn(
        _ document: QuickDiffDocument,
        side: Side,
        columnWidth: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            fileHeader(side == .left ? document.leftURL : document.rightURL)
                .frame(width: columnWidth, alignment: .leading)
                .background(.bar)
            Divider()

            GeometryReader { proxy in
                let characters = side == .left ? leftMaxCharacters : rightMaxCharacters
                let lineWidth = max(proxy.size.width, contentWidth(characters: characters, gutter: 54))
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(spacing: 0) {
                        ForEach(document.rows) { row in
                            DiffLineCell(
                                number: side == .left ? row.oldLineNumber : row.newLineNumber,
                                text: side == .left ? row.oldText : row.newText,
                                tint: side == .left ? oldTint(for: row.kind) : newTint(for: row.kind)
                            )
                            .frame(width: lineWidth, alignment: .leading)
                        }
                    }
                    .frame(minHeight: proxy.size.height, alignment: .topLeading)
                }
                .scrollPosition(side == .left ? $leftScroll : $rightScroll)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top
                } action: { _, newValue in
                    mirrorVerticalScroll(from: side, offset: newValue)
                }
            }
        }
        .frame(width: columnWidth)
    }

    // Keeps both panes on the same lines while each keeps its own horizontal offset.
    private func mirrorVerticalScroll(from side: Side, offset: CGFloat) {
        switch side {
        case .left:
            leftOffsetY = offset
            guard abs(offset - rightOffsetY) > 0.5 else { return }
            rightOffsetY = offset
            rightScroll.scrollTo(y: offset)
        case .right:
            rightOffsetY = offset
            guard abs(offset - leftOffsetY) > 0.5 else { return }
            leftOffsetY = offset
            leftScroll.scrollTo(y: offset)
        }
    }

    private func unified(_ document: QuickDiffDocument) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                fileHeader(document.leftURL)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                fileHeader(document.rightURL)
            }
            .background(.bar)
            Divider()

            GeometryReader { proxy in
                let characters = max(leftMaxCharacters, rightMaxCharacters)
                let lineWidth = max(proxy.size.width, contentWidth(characters: characters, gutter: 120))
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(spacing: 0) {
                        ForEach(document.rows) { row in
                            unifiedRows(for: row)
                                .frame(width: lineWidth, alignment: .leading)
                        }
                    }
                    .frame(minHeight: proxy.size.height, alignment: .topLeading)
                }
            }
        }
    }

    @ViewBuilder
    private func unifiedRows(for row: QuickDiffRow) -> some View {
        switch row.kind {
        case .unchanged:
            UnifiedDiffLine(
                oldNumber: row.oldLineNumber,
                newNumber: row.newLineNumber,
                marker: " ",
                text: row.oldText ?? "",
                tint: .clear
            )
        case .removed:
            UnifiedDiffLine(
                oldNumber: row.oldLineNumber,
                newNumber: nil,
                marker: "−",
                text: row.oldText ?? "",
                tint: .red.opacity(0.12)
            )
        case .added:
            UnifiedDiffLine(
                oldNumber: nil,
                newNumber: row.newLineNumber,
                marker: "+",
                text: row.newText ?? "",
                tint: .green.opacity(0.12)
            )
        case .changed:
            VStack(spacing: 0) {
                UnifiedDiffLine(
                    oldNumber: row.oldLineNumber,
                    newNumber: nil,
                    marker: "−",
                    text: row.oldText ?? "",
                    tint: .red.opacity(0.12)
                )
                UnifiedDiffLine(
                    oldNumber: nil,
                    newNumber: row.newLineNumber,
                    marker: "+",
                    text: row.newText ?? "",
                    tint: .green.opacity(0.12)
                )
            }
        }
    }

    private var columnSeparator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
    }

    private func contentWidth(characters: Int, gutter: CGFloat) -> CGFloat {
        let measured = CGFloat(characters) * Self.monospacedAdvance + gutter + 16
        return min(measured, 20_000)
    }

    private static let monospacedAdvance: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }()

    private func fileHeader(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(url.lastPathComponent)
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .lineLimit(1)
            Text(url.deletingLastPathComponent().path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func oldTint(for kind: QuickDiffRow.Kind) -> Color {
        switch kind {
        case .removed: return .red.opacity(0.12)
        case .changed: return .orange.opacity(0.12)
        default: return .clear
        }
    }

    private func newTint(for kind: QuickDiffRow.Kind) -> Color {
        switch kind {
        case .added: return .green.opacity(0.12)
        case .changed: return .orange.opacity(0.12)
        default: return .clear
        }
    }

    private func load() async {
        isLoading = true
        document = nil
        errorMessage = nil
        leftMaxCharacters = 0
        rightMaxCharacters = 0
        do {
            let loaded = try await QuickDiffService.compare(left: left, right: right)
            for row in loaded.rows {
                leftMaxCharacters = max(leftMaxCharacters, row.oldText?.count ?? 0)
                rightMaxCharacters = max(rightMaxCharacters, row.newText?.count ?? 0)
            }
            document = loaded
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct DiffLineCell: View {
    let number: Int?
    let text: String?
    let tint: Color

    var body: some View {
        HStack(spacing: 0) {
            Text(number.map(String.init) ?? "")
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)
                .padding(.trailing, 8)
            Text(text ?? "")
                .foregroundStyle(text == nil ? .tertiary : .primary)
                .textSelection(.enabled)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 20)
        .background(tint)
    }
}

private struct UnifiedDiffLine: View {
    let oldNumber: Int?
    let newNumber: Int?
    let marker: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 0) {
            Text(oldNumber.map(String.init) ?? "")
                .frame(width: 46, alignment: .trailing)
            Text(newNumber.map(String.init) ?? "")
                .frame(width: 46, alignment: .trailing)
            Text(marker)
                .frame(width: 28)
            Text(text)
                .textSelection(.enabled)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.primary)
        .font(.system(size: 11, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 20)
        .background(tint)
    }
}

private struct DiffCountBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}
