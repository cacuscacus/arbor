import SwiftUI
import UniformTypeIdentifiers

/// Finder-style path breadcrumbs shown under the file listing.
///
/// Each crumb navigates on click, accepts drops (via `FolderDropDelegate`),
/// and resolves the volume root to the location's display name.
struct BreadcrumbBar: View {
    let directory: ItemRef
    var dragState: FileDragState = FileDragState()
    var onNavigate: (ItemRef) -> Void
    var onTransfer: (([ItemRef], ItemRef, FileTransferOperation) -> Void)? = nil

    private var crumbs: [(name: String, item: ItemRef)] {
        var result: [(String, ItemRef)] = []
        var current = directory
        let location = FileProviderRegistry.shared.location(containing: directory)

        while true {
            let name: String
            if current == location?.root {
                name = location?.displayName ?? current.name
            } else if current.path == "/" {
                name = current.volumeID.rawValue.hasPrefix("local:") ? "Macintosh HD" : "/"
            } else {
                name = current.name
            }
            result.append((name, current))
            if current == location?.root { break }
            guard let parent = current.parent else { break }
            current = parent
        }
        return result.reversed()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Button {
                        onNavigate(crumb.item)
                    } label: {
                        HStack(spacing: 4) {
                            Image(nsImage: FileIcon.image(for: crumb.item, size: 14))
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 14, height: 14)
                            Text(crumb.name)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(index == crumbs.count - 1 ? .primary : .secondary)
                    .help(crumb.item.path)
                    .onDrop(
                        of: [.fileURL],
                        delegate: FolderDropDelegate(
                            destination: crumb.item,
                            dragState: dragState,
                            isTargeted: nil,
                            onTransfer: { items, destination, operation in
                                onTransfer?(items, destination, operation)
                            }
                        )
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .focusEffectDisabled()
    }
}
