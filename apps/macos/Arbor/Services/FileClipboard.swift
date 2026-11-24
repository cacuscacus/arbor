import Foundation
import Observation

/// Finder-style "cut" for a later paste-as-move.
///
/// macOS convention is copy + ⌥⌘V, but a literal Cut is handier for moving
/// something far away, so Arbor supports both: ⌘X remembers the items and
/// ⌘V moves them into the current folder.
@MainActor
@Observable
final class FileClipboard {
    static let shared = FileClipboard()

    private(set) var cutItems: [ItemRef] = []

    private init() {}

    var hasCutItems: Bool { !cutItems.isEmpty }

    func cut(_ items: [ItemRef]) {
        cutItems = items
    }

    func clear() {
        cutItems = []
    }

    /// Takes the cut items and empties the clipboard (one paste per cut).
    func takeCutItems() -> [ItemRef] {
        let items = cutItems
        cutItems = []
        return items
    }
}
