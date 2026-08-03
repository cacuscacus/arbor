import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileTableView<MenuContent: View, EmptyMenu: View>: View {
    let entries: [FileEntry]
    @Binding var selection: Set<URL>
    @Binding var sortOrder: [KeyPathComparator<FileEntry>]
    @Binding var renamingURL: URL?
    @Binding var renameDraft: String
    var settings: BrowserDisplaySettings
    var relativeRoot: URL
    var showsLocation: Bool
    var dragState: FileDragState
    var onOpenRow: (FileEntry) -> Void
    var onTransfer: ([URL], URL, FileTransferOperation) -> Void
    var onRequestRename: (FileEntry) -> Void
    var onCommitRename: () -> Void
    var onCancelRename: () -> Void
    @ViewBuilder var contextMenu: (FileEntry) -> MenuContent
    @ViewBuilder var emptySpaceMenu: () -> EmptyMenu

    var body: some View {
        // Row-based Table so `.itemProvider` applies to the *entire* row.
        // Cell-only onDrag made drags from the name/columns start multi-select instead.
        Table(of: FileEntry.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { entry in
                HStack(spacing: 6) {
                    FileIconImage(url: entry.id, size: 16)

                    if renamingURL == entry.id {
                        RenameTextField(
                            text: $renameDraft,
                            isDirectory: entry.isDirectory && !entry.isPackage,
                            onSubmit: onCommitRename,
                            onCancel: onCancelRename
                        )
                        .frame(maxWidth: .infinity, minHeight: 22)
                    } else {
                        Text(entry.name)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onRequestRename(entry)
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .dropFolderTarget(entry: entry, dragState: dragState, onTransfer: onTransfer)
            }
            .width(min: 180, ideal: 280)

            if settings.showKind {
                TableColumn("Kind", value: \.kind) { entry in
                    Text(entry.kind)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 80, ideal: 120)
            }

            if settings.showSize {
                TableColumn("Size", value: \.sizeForSort) { entry in
                    Text(entry.formattedSize)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 70, ideal: 90)
            }

            if settings.showModified {
                TableColumn("Date Modified", value: \.modifiedForSort) { entry in
                    Text(entry.formatted(entry.modified))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 120, ideal: 160)
            }

            if settings.showCreated {
                TableColumn("Date Created", value: \.createdForSort) { entry in
                    Text(entry.formatted(entry.created))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 120, ideal: 160)
            }

            if settings.showRelativePath {
                TableColumn("Relative Path") { entry in
                    Text(entry.relativePath(to: relativeRoot))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.relativePath(to: relativeRoot))
                }
                .width(min: 140, ideal: 220)
            }

            if settings.showFullPath {
                TableColumn("Full Path", value: \.fullPath) { entry in
                    Text(entry.fullPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.fullPath)
                }
                .width(min: 180, ideal: 280)
            }

            if showsLocation {
                TableColumn("Location", value: \.location) { entry in
                    Text(entry.location)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.id.deletingLastPathComponent().path)
                }
                .width(min: 120, ideal: 200)
            }
        } rows: {
            ForEach(entries) { entry in
                TableRow(entry)
                    .itemProvider {
                        fileDragItemProvider(
                            for: entry,
                            selection: $selection,
                            dragState: dragState
                        )
                    }
                    .contextMenu {
                        contextMenu(entry)
                    }
            }
        }
        .contextMenu {
            emptySpaceMenu()
        }
        .background {
            TableDoubleClickInstaller(rowCount: entries.count) { row in
                guard entries.indices.contains(row) else { return }
                onOpenRow(entries[row])
            }
        }
    }
}

struct FileIconView<MenuContent: View, EmptyMenu: View>: View {
    let entries: [FileEntry]
    @Binding var selection: Set<URL>
    @Binding var renamingURL: URL?
    @Binding var renameDraft: String
    var dragState: FileDragState
    var onOpen: (FileEntry) -> Void
    var onTransfer: ([URL], URL, FileTransferOperation) -> Void
    var onRequestRename: (FileEntry) -> Void
    var onCommitRename: () -> Void
    var onCancelRename: () -> Void
    @ViewBuilder var contextMenu: (FileEntry) -> MenuContent
    @ViewBuilder var emptySpaceMenu: () -> EmptyMenu

    @State private var anchorID: URL?
    @State private var lastClickID: URL?
    @State private var lastClickAt: Date = .distantPast
    @State private var itemFrames: [URL: CGRect] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var dropTarget: URL?

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 8)]

    private var marqueeRect: CGRect? {
        guard let start = marqueeStart, let current = marqueeCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .frame(
                            minWidth: viewport.size.width,
                            minHeight: max(viewport.size.height, gridMinHeight),
                            alignment: .topLeading
                        )
                        .contentShape(Rectangle())
                        .contextMenu { emptySpaceMenu() }
                        .onTapGesture(count: 1) {
                            clearSelectionIfNeeded()
                        }
                        .gesture(marqueeGesture)

                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(entries) { entry in
                            IconCell(
                                entry: entry,
                                isSelected: selection.contains(entry.id),
                                isDropTarget: dropTarget == entry.id,
                                isRenaming: renamingURL == entry.id,
                                renameDraft: $renameDraft,
                                onIconTap: { handleIconClick(entry) },
                                onNameTap: { onRequestRename(entry) },
                                onCommitRename: onCommitRename,
                                onCancelRename: onCancelRename
                            )
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: IconFramePreferenceKey.self,
                                        value: [entry.id: geo.frame(in: .named("iconCanvas"))]
                                    )
                                }
                            )
                            .contextMenu { contextMenu(entry) }
                            .draggableFile(entry: entry, selection: $selection, dragState: dragState)
                            .dropFolderTarget(
                                entry: entry,
                                dragState: dragState,
                                onTransfer: onTransfer,
                                isTargeted: Binding(
                                    get: { dropTarget == entry.id },
                                    set: { active in
                                        if active {
                                            dropTarget = entry.id
                                        } else if dropTarget == entry.id {
                                            dropTarget = nil
                                        }
                                    }
                                )
                            )
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(
                    minWidth: viewport.size.width,
                    minHeight: viewport.size.height,
                    alignment: .topLeading
                )
                .coordinateSpace(name: "iconCanvas")
                .onPreferenceChange(IconFramePreferenceKey.self) { itemFrames = $0 }
                .overlay(alignment: .topLeading) {
                    if let marqueeRect {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(Color.accentColor.opacity(0.85), lineWidth: 1)
                            }
                            .frame(width: marqueeRect.width, height: marqueeRect.height)
                            .offset(x: marqueeRect.minX, y: marqueeRect.minY)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .background(.background)
    }

    private var gridMinHeight: CGFloat {
        let rows = max(1, Int(ceil(Double(entries.count) / 6.0)))
        return CGFloat(rows) * 112 + 32
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("iconCanvas"))
            .onChanged { value in
                if marqueeStart == nil {
                    if hitsItem(at: value.startLocation) { return }
                    marqueeStart = value.startLocation
                    if !NSEvent.modifierFlags.contains(.command) {
                        selection.removeAll()
                    }
                }
                guard marqueeStart != nil else { return }
                marqueeCurrent = value.location
                applyMarqueeSelection()
            }
            .onEnded { _ in
                marqueeStart = nil
                marqueeCurrent = nil
            }
    }

    private func hitsItem(at point: CGPoint) -> Bool {
        itemFrames.values.contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
    }

    private func clearSelectionIfNeeded() {
        if renamingURL != nil {
            onCancelRename()
        }
        selection.removeAll()
        lastClickID = nil
    }

    private func applyMarqueeSelection() {
        guard let rect = marqueeRect else { return }
        let hits = itemFrames.compactMap { id, frame -> URL? in
            frame.intersects(rect) ? id : nil
        }
        if NSEvent.modifierFlags.contains(.command) {
            selection.formUnion(hits)
        } else {
            selection = Set(hits)
        }
    }

    private func handleIconClick(_ entry: FileEntry) {
        if marqueeStart != nil { return }
        if renamingURL != nil {
            onCancelRename()
        }

        let modifiers = NSEvent.modifierFlags
        let now = Date()

        if modifiers.contains(.command) {
            if selection.contains(entry.id) {
                selection.remove(entry.id)
            } else {
                selection.insert(entry.id)
            }
            anchorID = entry.id
            lastClickID = entry.id
            lastClickAt = now
            return
        }

        if modifiers.contains(.shift), let anchorID,
           let anchorIndex = entries.firstIndex(where: { $0.id == anchorID }),
           let index = entries.firstIndex(where: { $0.id == entry.id })
        {
            let range = anchorIndex <= index ? anchorIndex...index : index...anchorIndex
            selection = Set(entries[range].map(\.id))
            lastClickID = entry.id
            lastClickAt = now
            return
        }

        if selection == [entry.id],
           lastClickID == entry.id,
           now.timeIntervalSince(lastClickAt) < 0.45
        {
            onOpen(entry)
            lastClickID = nil
            return
        }

        selection = [entry.id]
        anchorID = entry.id
        lastClickID = entry.id
        lastClickAt = now
    }
}

// MARK: - Shared UI pieces

struct FileIconImage: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        Image(nsImage: FileIcon.image(for: url, size: size))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

private struct IconCell: View {
    let entry: FileEntry
    let isSelected: Bool
    var isDropTarget: Bool = false
    var isRenaming: Bool = false
    @Binding var renameDraft: String
    var onIconTap: () -> Void
    var onNameTap: () -> Void
    var onCommitRename: () -> Void
    var onCancelRename: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            FileIconImage(url: entry.id, size: 48)
                .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                .onTapGesture(perform: onIconTap)

            if isRenaming {
                RenameTextField(
                    text: $renameDraft,
                    isDirectory: entry.isDirectory && !entry.isPackage,
                    onSubmit: onCommitRename,
                    onCancel: onCancelRename
                )
                .frame(width: 92, height: 36)
            } else {
                Text(entry.name)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor)
                        }
                    }
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .frame(maxWidth: 92)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onNameTap)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(width: 104, height: 98)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isDropTarget ? Color.accentColor.opacity(0.14) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 1.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct IconFramePreferenceKey: PreferenceKey {
    static var defaultValue: [URL: CGRect] = [:]

    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Drag / drop helpers

private func fileDragItemProvider(
    for entry: FileEntry,
    selection: Binding<Set<URL>>,
    dragState: FileDragState
) -> NSItemProvider {
    if !selection.wrappedValue.contains(entry.id) {
        selection.wrappedValue = [entry.id]
    }
    let urls = dragState.beginDragging(anchor: entry.id, selection: selection.wrappedValue)
    if urls.count == 1, let url = urls.first {
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }
    let provider = NSItemProvider()
    for url in urls {
        provider.registerObject(url as NSURL, visibility: .all)
    }
    return provider
}

extension View {
    fileprivate func draggableFile(
        entry: FileEntry,
        selection: Binding<Set<URL>>,
        dragState: FileDragState
    ) -> some View {
        onDrag {
            fileDragItemProvider(for: entry, selection: selection, dragState: dragState)
        }
    }

    @ViewBuilder
    fileprivate func dropFolderTarget(
        entry: FileEntry,
        dragState: FileDragState,
        onTransfer: @escaping ([URL], URL, FileTransferOperation) -> Void,
        isTargeted: Binding<Bool>? = nil
    ) -> some View {
        if entry.isBrowsable {
            self.onDrop(
                of: [.fileURL],
                delegate: FolderDropDelegate(
                    destination: entry.id,
                    dragState: dragState,
                    isTargeted: isTargeted,
                    onTransfer: onTransfer
                )
            )
        } else {
            self
        }
    }
}
