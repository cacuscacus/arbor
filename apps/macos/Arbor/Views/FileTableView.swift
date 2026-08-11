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
    /// Drop destination for empty space / non-folder rows (pane's current folder).
    var currentFolder: URL?
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
                        // `Text` is hittable by default and steals the mouse from
                        // `TableRow.itemProvider`, so drag never starts on the name.
                        // Pass hits through; rename is handled via AppKit clicks.
                        Text(entry.name)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .allowsHitTesting(false)
                    }
                }
                .opacity(entry.listingOpacity)
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
                        .opacity(entry.listingOpacity)
                }
                .width(min: 80, ideal: 120)
            }

            if settings.showSize {
                TableColumn("Size", value: \.sizeForSort) { entry in
                    Text(entry.formattedSize)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .opacity(entry.listingOpacity)
                }
                .width(min: 70, ideal: 90)
            }

            if settings.showModified {
                TableColumn("Date Modified", value: \.modifiedForSort) { entry in
                    Text(entry.formatted(entry.modified))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .opacity(entry.listingOpacity)
                }
                .width(min: 120, ideal: 160)
            }

            if settings.showCreated {
                TableColumn("Date Created", value: \.createdForSort) { entry in
                    Text(entry.formatted(entry.created))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .opacity(entry.listingOpacity)
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
                        .opacity(entry.listingOpacity)
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
                        .opacity(entry.listingOpacity)
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
                        .opacity(entry.listingOpacity)
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
        .dropIntoCurrentFolder(currentFolder, dragState: dragState, onTransfer: onTransfer)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background {
            TableInteractionInstaller(
                rowCount: entries.count,
                isRowSelected: { row in
                    guard entries.indices.contains(row) else { return false }
                    return selection.contains(entries[row].id)
                },
                onDoubleClickRow: { row in
                    guard entries.indices.contains(row) else { return }
                    onOpenRow(entries[row])
                },
                onRenameRow: { row in
                    guard entries.indices.contains(row) else { return }
                    onRequestRename(entries[row])
                }
            )
        }
        .focusEffectDisabled()
    }
}

struct FileIconView<MenuContent: View, EmptyMenu: View>: View {
    let entries: [FileEntry]
    @Binding var selection: Set<URL>
    @Binding var renamingURL: URL?
    @Binding var renameDraft: String
    var iconMetrics: IconViewMetrics
    /// Drop destination for empty canvas / non-folder icons (pane's current folder).
    var currentFolder: URL?
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
    /// Tight icon+label hit rects — not the full cell padding box.
    @State private var itemHitAreas: [URL: IconHitArea] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var dropTarget: URL?

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: iconMetrics.gridMinimum, maximum: iconMetrics.gridMaximum),
                spacing: iconMetrics.gridSpacing
            ),
        ]
    }

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
                        .dropIntoCurrentFolder(currentFolder, dragState: dragState, onTransfer: onTransfer)
                        .onTapGesture(count: 1) {
                            clearSelectionIfNeeded()
                        }
                        .gesture(marqueeGesture)

                    LazyVGrid(columns: columns, spacing: iconMetrics.gridSpacing) {
                        ForEach(entries) { entry in
                            IconCell(
                                entry: entry,
                                isSelected: selection.contains(entry.id),
                                isDropTarget: dropTarget == entry.id,
                                isRenaming: renamingURL == entry.id,
                                renameDraft: $renameDraft,
                                metrics: iconMetrics,
                                onIconTap: { handleIconClick(entry) },
                                onNameTap: { onRequestRename(entry) },
                                onCommitRename: onCommitRename,
                                onCancelRename: onCancelRename,
                                contextMenu: { contextMenu(entry) },
                                dragProvider: {
                                    fileDragItemProvider(
                                        for: entry,
                                        selection: $selection,
                                        dragState: dragState
                                    )
                                },
                                dropDelegate: entry.isBrowsable
                                    ? FolderDropDelegate(
                                        destination: entry.id,
                                        dragState: dragState,
                                        isTargeted: Binding(
                                            get: { dropTarget == entry.id },
                                            set: { active in
                                                if active {
                                                    dropTarget = entry.id
                                                } else if dropTarget == entry.id {
                                                    dropTarget = nil
                                                }
                                            }
                                        ),
                                        onTransfer: onTransfer
                                    )
                                    : nil
                            )
                            .gridCellAnchor(.top)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .onPreferenceChange(IconHitPreferenceKey.self) { itemHitAreas = $0 }
                }
                .frame(
                    minWidth: viewport.size.width,
                    minHeight: viewport.size.height,
                    alignment: .topLeading
                )
                .coordinateSpace(name: "iconCanvas")
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
        .dropIntoCurrentFolder(currentFolder, dragState: dragState, onTransfer: onTransfer)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(.background)
        .focusEffectDisabled()
        .onChange(of: entries.map(\.id)) { _, ids in
            let valid = Set(ids)
            itemHitAreas = itemHitAreas.filter { valid.contains($0.key) }
        }
    }

    private var gridMinHeight: CGFloat {
        let approxColumns = max(1, Int(floor(800 / Double(iconMetrics.cellWidth + iconMetrics.gridSpacing))))
        let rows = max(1, Int(ceil(Double(entries.count) / Double(approxColumns))))
        return CGFloat(rows) * (iconMetrics.cellHeight + iconMetrics.gridSpacing) + 32
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("iconCanvas"))
            .onChanged { value in
                if marqueeStart == nil {
                    // Only treat as item-drag if the press landed on icon/label, not cell padding.
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
        itemHitAreas.values.contains { $0.contains(point) }
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
        let hits = itemHitAreas.compactMap { id, area -> URL? in
            area.intersects(rect) ? id : nil
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

/// Tight hit region: icon thumbnail and/or name label only.
struct IconHitArea: Equatable {
    var icon: CGRect = .null
    var label: CGRect = .null

    func contains(_ point: CGPoint) -> Bool {
        (!icon.isNull && icon.insetBy(dx: -1, dy: -1).contains(point))
            || (!label.isNull && label.insetBy(dx: -1, dy: -1).contains(point))
    }

    func intersects(_ rect: CGRect) -> Bool {
        (!icon.isNull && icon.intersects(rect))
            || (!label.isNull && label.intersects(rect))
    }
}

private struct IconCell<MenuContent: View>: View {
    let entry: FileEntry
    let isSelected: Bool
    var isDropTarget: Bool = false
    var isRenaming: Bool = false
    @Binding var renameDraft: String
    var metrics: IconViewMetrics
    var onIconTap: () -> Void
    var onNameTap: () -> Void
    var onCommitRename: () -> Void
    var onCancelRename: () -> Void
    @ViewBuilder var contextMenu: () -> MenuContent
    var dragProvider: () -> NSItemProvider
    var dropDelegate: FolderDropDelegate?

    var body: some View {
        // Layout-only host: empty padding must not swallow clicks / marquee.
        Color.clear
            .frame(width: metrics.cellWidth, height: metrics.cellHeight)
            .allowsHitTesting(false)
            .overlay(alignment: .top) {
                interactiveContent
            }
    }

    @ViewBuilder
    private var interactiveContent: some View {
        let content = VStack(spacing: 6) {
            FileIconImage(url: entry.id, size: metrics.iconPoints)
                .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                .contentShape(Rectangle())
                .onTapGesture(perform: onIconTap)
                .background(hitProbe(part: .icon))

            if isRenaming {
                RenameTextField(
                    text: $renameDraft,
                    isDirectory: entry.isDirectory && !entry.isPackage,
                    onSubmit: onCommitRename,
                    onCancel: onCancelRename
                )
                .frame(width: metrics.labelWidth)
                .background(hitProbe(part: .label))
            } else {
                Text(entry.name)
                    .font(.system(size: metrics.labelFontSize))
                    .multilineTextAlignment(.center)
                    .lineLimit(metrics.lineLimit)
                    .truncationMode(.middle)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor)
                        }
                    }
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .frame(maxWidth: metrics.labelWidth, alignment: .top)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onNameTap)
                    .background(hitProbe(part: .label))
            }
        }
        .padding(.top, 6)
        .padding(.horizontal, 4)
        .opacity(entry.listingOpacity)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isDropTarget ? Color.accentColor.opacity(0.14) : Color.clear)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .contextMenu { contextMenu() }
        .onDrag(dragProvider)

        if let dropDelegate {
            content.onDrop(of: [.fileURL], delegate: dropDelegate)
        } else {
            content
        }
    }

    private enum HitPart { case icon, label }

    private func hitProbe(part: HitPart) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: IconHitPreferenceKey.self,
                value: [
                    entry.id: IconHitArea(
                        icon: part == .icon ? geo.frame(in: .named("iconCanvas")) : .null,
                        label: part == .label ? geo.frame(in: .named("iconCanvas")) : .null
                    ),
                ]
            )
        }
        .allowsHitTesting(false)
    }
}

private struct IconHitPreferenceKey: PreferenceKey {
    static var defaultValue: [URL: IconHitArea] = [:]

    static func reduce(value: inout [URL: IconHitArea], nextValue: () -> [URL: IconHitArea]) {
        for (id, area) in nextValue() {
            var merged = value[id] ?? IconHitArea()
            if !area.icon.isNull { merged.icon = area.icon }
            if !area.label.isNull { merged.label = area.label }
            value[id] = merged
        }
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

    /// Accept drops into the open folder (empty space / non-folder chrome).
    @ViewBuilder
    fileprivate func dropIntoCurrentFolder(
        _ folder: URL?,
        dragState: FileDragState,
        onTransfer: @escaping ([URL], URL, FileTransferOperation) -> Void
    ) -> some View {
        if let folder {
            self.onDrop(
                of: [.fileURL],
                delegate: FolderDropDelegate(
                    destination: folder,
                    dragState: dragState,
                    isTargeted: nil,
                    onTransfer: onTransfer
                )
            )
        } else {
            self
        }
    }
}
