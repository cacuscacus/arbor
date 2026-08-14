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
    var onDeleteSelection: (() -> Void)? = nil
    @ViewBuilder var contextMenu: (FileEntry) -> MenuContent
    @ViewBuilder var emptySpaceMenu: () -> EmptyMenu

    var body: some View {
        // AppKit NSCollectionView — SwiftUI LazyVGrid cannot match Finder scroll cost.
        IconCollectionView(
            entries: entries,
            selection: $selection,
            renamingURL: $renamingURL,
            renameDraft: $renameDraft,
            iconMetrics: iconMetrics,
            currentFolder: currentFolder,
            dragState: dragState,
            onOpen: onOpen,
            onTransfer: onTransfer,
            onRequestRename: onRequestRename,
            onCommitRename: onCommitRename,
            onCancelRename: onCancelRename,
            onDeleteSelection: onDeleteSelection,
            contextMenu: contextMenu,
            emptySpaceMenu: emptySpaceMenu
        )
        // Reach under the toolbar glass like SwiftUI Table/list. Safe-area inset is
        // applied by NSScrollView.automaticallyAdjustsContentInsets instead.
        .ignoresSafeArea(.container, edges: .top)
        .dropIntoCurrentFolder(currentFolder, dragState: dragState, onTransfer: onTransfer)
        .scrollEdgeEffectStyle(.soft, for: .top)
        // Do not paint an opaque `.background` here — it kills Liquid Glass underlap.
        .focusEffectDisabled()
    }
}

// MARK: - Shared UI pieces

struct FileIconImage: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(size >= 48 ? .high : .medium)
            } else {
                Image(systemName: "doc")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(size >= 32 ? 6 : 1)
            }
        }
        .frame(width: size, height: size)
        .task(id: "\(url.path)|\(Int(size))") {
            if let cached = FileIcon.cached(for: url, size: size) {
                image = cached
            }
            FileIcon.load(for: url, size: size) { display in
                image = display.image
            }
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
