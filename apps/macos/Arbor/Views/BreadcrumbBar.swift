import SwiftUI
import UniformTypeIdentifiers

/// Finder-style path breadcrumbs shown under the file listing.
///
/// Each crumb navigates on click and accepts file drops (via
/// `FolderDropDelegate`). The drop target covers the crumb *and* the chevron
/// leading up to it, so the gaps in the bar are not dead zones — dropping on a
/// separator moves into the folder on its right, like Finder.
struct BreadcrumbBar: View {
    let directory: ItemRef
    var dragState: FileDragState = FileDragState()
    var statusSummary: String? = nil
    var onNavigate: (ItemRef) -> Void
    var onTransfer: (([ItemRef], ItemRef, FileTransferOperation) -> Void)? = nil

    @State private var targetedIndex: Int?

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
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                        HStack(spacing: 4) {
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

                            // The separator belongs to the crumb on its left: dropping
                            // on it moves up into that ancestor, which is what the
                            // gesture means when you drag from a deep folder.
                            if index < crumbs.count - 1 {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 3)
                        .frame(height: 22)
                        .contentShape(Rectangle())
                        .background {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(
                                    targetedIndex == index
                                        ? Color.accentColor.opacity(0.2)
                                        : Color.clear
                                )
                        }
                        .onDrop(
                            of: [.fileURL],
                            delegate: crumbDropDelegate(crumb: crumb, index: index)
                        )
                    }
                }
                .padding(.leading, 8)
                .padding(.vertical, 3)
            }

            if let statusSummary, !statusSummary.isEmpty {
                Text(statusSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.trailing, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .focusEffectDisabled()
        .onChange(of: dragState.items) { _, items in
            if items.isEmpty { targetedIndex = nil }
        }
    }

    private func crumbDropDelegate(
        crumb: (name: String, item: ItemRef),
        index: Int
    ) -> FolderDropDelegate {
        FolderDropDelegate(
            destination: crumb.item,
            dragState: dragState,
            isTargeted: Binding(
                get: { targetedIndex == index },
                set: { isTargeted in
                    if isTargeted {
                        targetedIndex = index
                    } else if targetedIndex == index {
                        targetedIndex = nil
                    }
                }
            ),
            onTransfer: { items, destination, operation in
                onTransfer?(items, destination, operation)
            }
        )
    }
}
