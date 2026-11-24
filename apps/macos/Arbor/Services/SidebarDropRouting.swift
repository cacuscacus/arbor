import Foundation

/// What a drop on a sidebar favorite row should do.
nonisolated enum SidebarDropDecision: Equatable {
    /// Insert/reorder the favorites list (the drag carried a favorite).
    case reorderFavorites
    /// Move/copy the dragged files into that favorite's folder.
    case transferFiles
}

/// Routing rule shared by the sidebar drop delegate and its tests.
///
/// Favorites drag as text payloads, files drag as file URLs; a row must only
/// treat a drag as a file transfer when it actually carries files and a
/// handler exists, otherwise it falls back to the favorites behavior.
nonisolated enum SidebarDropRouting {
    static func decision(
        isDraggingFavorite: Bool,
        carriesFiles: Bool,
        canTransfer: Bool
    ) -> SidebarDropDecision {
        if isDraggingFavorite { return .reorderFavorites }
        if carriesFiles, canTransfer { return .transferFiles }
        return .reorderFavorites
    }
}
