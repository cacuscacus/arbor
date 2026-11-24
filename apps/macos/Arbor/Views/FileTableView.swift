import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileTableView<MenuContent: View, EmptyMenu: View>: View {
    @State private var dropTargetRow: ItemRef?
    let entries: [FileEntry]
    @Binding var selection: Set<ItemRef>
    @Binding var sortOrder: [KeyPathComparator<FileEntry>]
    @Binding var renamingItem: ItemRef?
    @Binding var renameDraft: String
    var settings: BrowserDisplaySettings
    var relativeRoot: ItemRef
    /// Drop destination for empty space / non-folder rows (pane's current folder).
    var currentFolder: ItemRef?
    var showsLocation: Bool
    var dragState: FileDragState
    var onOpenRow: (FileEntry) -> Void
    var onTransfer: ([ItemRef], ItemRef, FileTransferOperation) -> Void
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
                    FileIconImage(item: entry.id, size: 16)

                    if renamingItem == entry.id {
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
            }
            .width(min: 180, ideal: 280)

            if settings.showKind {
                TableColumn("Kind", value: \.kind) { entry in
                                        Text(entry.kind)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .opacity(entry.listingOpacity)
                        .modifier(DropRowHighlight(isTargeted: dropTargetRow == entry.id))
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
                        .modifier(DropRowHighlight(isTargeted: dropTargetRow == entry.id))
                }
                .width(min: 70, ideal: 90)
            }

            if settings.showModified {
                TableColumn("Date Modified", value: \.modifiedForSort) { entry in
                                        Text(entry.formatted(entry.modified))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .opacity(entry.listingOpacity)
                        .modifier(DropRowHighlight(isTargeted: dropTargetRow == entry.id))
                }
                .width(min: 120, ideal: 160)
            }

            if settings.showCreated {
                TableColumn("Date Created", value: \.createdForSort) { entry in
                                        Text(entry.formatted(entry.created))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .opacity(entry.listingOpacity)
                        .modifier(DropRowHighlight(isTargeted: dropTargetRow == entry.id))
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
                        .modifier(DropRowHighlight(isTargeted: dropTargetRow == entry.id))
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
                        .modifier(DropRowHighlight(isTargeted: dropTargetRow == entry.id))
                }
                .width(min: 180, ideal: 280)
            }

            if showsLocation {
                TableColumn("Location", value: \.location) { entry in
                                        Text(entry.location)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.id.parent?.path ?? entry.id.path)
                        .opacity(entry.listingOpacity)
                        .modifier(DropRowHighlight(isTargeted: dropTargetRow == entry.id))
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
        .dropIntoCurrentFolder(
            currentFolder,
            dragState: dragState,
            resolveDestination: {
                FileTableRowResolver.folder(under: NSEvent.mouseLocation, entries: entries)
            },
            onDropTargetChange: { target in
                dropTargetRow = target
            },
            onTransfer: onTransfer
        )
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
    @Binding var selection: Set<ItemRef>
    @Binding var renamingItem: ItemRef?
    @Binding var renameDraft: String
    var iconMetrics: IconViewMetrics
    /// Drop destination for empty canvas / non-folder icons (pane's current folder).
    var currentFolder: ItemRef?
    var dragState: FileDragState
    var onOpen: (FileEntry) -> Void
    var onTransfer: ([ItemRef], ItemRef, FileTransferOperation) -> Void
    var onRequestRename: (FileEntry) -> Void
    var onCommitRename: () -> Void
    var onCancelRename: () -> Void
    var onDeleteSelection: (() -> Void)? = nil
    var onQuickLook: (() -> Void)? = nil
    @ViewBuilder var contextMenu: (FileEntry) -> MenuContent
    @ViewBuilder var emptySpaceMenu: () -> EmptyMenu

    var body: some View {
        // AppKit NSCollectionView — SwiftUI LazyVGrid cannot match Finder scroll cost.
        IconCollectionView(
            entries: entries,
            selection: $selection,
            renamingItem: $renamingItem,
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
            onQuickLook: onQuickLook,
            contextMenu: contextMenu,
            emptySpaceMenu: emptySpaceMenu
        )
        // Reach under the toolbar glass like SwiftUI Table/list. Safe-area inset is
        // applied by NSScrollView.automaticallyAdjustsContentInsets instead.
        .ignoresSafeArea(.container, edges: .top)
        .dropIntoCurrentFolder(
            currentFolder,
            dragState: dragState,
            resolveDestination: {
                FileTableRowResolver.folder(under: NSEvent.mouseLocation, entries: entries)
            },
            onTransfer: onTransfer
        )
        .scrollEdgeEffectStyle(.soft, for: .top)
        // Do not paint an opaque `.background` here — it kills Liquid Glass underlap.
        .focusEffectDisabled()
    }
}

// MARK: - Shared UI pieces

struct FileIconImage: View {
    let item: ItemRef
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
        .task(id: "\(item.volumeID.rawValue)|\(item.path)|\(Int(size))") {
            if let cached = FileIcon.cached(for: item, size: size) {
                image = cached
            }
            FileIcon.load(for: item, size: size) { display in
                image = display.image
            }
        }
    }
}

// MARK: - Row highlight

/// Tints the whole row of the folder that would receive the drop.
private struct DropRowHighlight: ViewModifier {
    let isTargeted: Bool

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.16) : Color.clear)
                .padding(.vertical, 1)
        }
    }
}

// MARK: - Drag / drop helpers

/// Maps the pointer to a folder row so a drop anywhere on a folder's row moves
/// into it (the cells themselves can't own drop targets: that breaks row drag).
nonisolated enum FileTableRowResolver {
    static func folder(under screenPoint: NSPoint, entries: [FileEntry]) -> ItemRef? {
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && $0.frame.contains(screenPoint)
        }),
            let hit = window.contentView?.hitTest(
                window.convertPoint(fromScreen: screenPoint)
            )
        else { return nil }

        var view: NSView? = hit
        while let current = view {
            if let table = current as? NSTableView {
                let pointInTable = table.convert(
                    window.convertPoint(fromScreen: screenPoint),
                    from: nil
                )
                let row = table.row(at: pointInTable)
                guard row >= 0, entries.indices.contains(row) else {
                    DragDebugLog.log("table.resolve no row (row=\(row))")
                    return nil
                }
                let entry = entries[row]
                return entry.isBrowsable ? entry.id : nil
            }
            view = current.superview
        }
        return nil
    }
}


private func fileDragItemProvider(
    for entry: FileEntry,
    selection: Binding<Set<ItemRef>>,
    dragState: FileDragState
) -> NSItemProvider {
    if !selection.wrappedValue.contains(entry.id) {
        selection.wrappedValue = [entry.id]
    }
    // Deliberately no `dragState` side effect here: SwiftUI calls this closure
    // while *preparing* a drag (on press, before the drag threshold), so
    // recording the payload here made the sidebar believe a folder was being
    // dragged to Favorites on a mere click. In-app drops read the URLs from the
    // pasteboard instead.
    //
    // Caveat: SwiftUI only asks for providers of rows it has realized, so a
    // selection extending past the viewport can lose its off-screen rows on
    // an external drop. The icon view builds its dragging items from the
    // selection itself, so it always carries every selected file.
    guard let url = FileProviderRegistry.shared.intrinsicLocalURL(for: entry.id) else {
        return NSItemProvider()
    }
    return FileDragPayload.provider(for: url)
}

extension View {
    fileprivate func draggableFile(
        entry: FileEntry,
        selection: Binding<Set<ItemRef>>,
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
        onTransfer: @escaping ([ItemRef], ItemRef, FileTransferOperation) -> Void,
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
        _ folder: ItemRef?,
        dragState: FileDragState,
        resolveDestination: (() -> ItemRef?)? = nil,
        onDropTargetChange: ((ItemRef?) -> Void)? = nil,
        onTransfer: @escaping ([ItemRef], ItemRef, FileTransferOperation) -> Void
    ) -> some View {
        if let folder {
            self.onDrop(
                of: [.fileURL],
                delegate: FolderDropDelegate(
                    destination: folder,
                    dragState: dragState,
                    isTargeted: nil,
                    resolveDestination: resolveDestination,
                    onDropTargetChange: onDropTargetChange,
                    onTransfer: onTransfer
                )
            )
        } else {
            self
        }
    }
}

