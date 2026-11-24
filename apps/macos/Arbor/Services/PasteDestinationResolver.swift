import Foundation

/// Where a paste (or a move) should land: the selected folder when exactly one
/// folder is selected, otherwise the folder being browsed.
nonisolated enum PasteDestinationResolver {
    static func resolve<Folder>(
        selectedFolders: [Folder],
        currentFolder: Folder
    ) -> Folder {
        if selectedFolders.count == 1, let only = selectedFolders.first {
            return only
        }
        return currentFolder
    }
}
