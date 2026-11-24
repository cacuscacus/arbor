import AppKit

/// Builds the drag payload for files.
///
/// SwiftUI's `TableRow.itemProvider` / `onDrag` asks each row for its own
/// provider and turns every returned provider into one `NSDraggingItem`, so a
/// provider must describe **exactly one file**. Registering several URLs on a
/// single provider silently keeps only one (`NSItemProvider` stores one object
/// per type) — the bug that made multi-file drags deliver the same file over
/// and over.
///
/// `suggestedName` is what browsers use to name dropped files; without it
/// WebKit invents a generic name.
nonisolated enum FileDragPayload {
    /// One provider describing `url` as a file, with its name attached.
    ///
    /// Deliberately registers the URL only (like Finder): offering the file's
    /// *contents* as an extra representation makes WebKit drop handlers build
    /// a `File` from that data and lose the name.
    static func provider(for url: URL) -> NSItemProvider {
        let provider = NSItemProvider(object: url as NSURL)
        provider.suggestedName = url.lastPathComponent
        return provider
    }

    /// Provider per URL, preserving order. `providers(for:) == []` for no URLs.
    static func providers(for urls: [URL]) -> [NSItemProvider] {
        urls.map(provider(for:))
    }

    /// Pasteboard payload for one file: the file URL plus the legacy
    /// filename list older drop targets still read.
    static func pasteboardItem(for url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setPropertyList(
            [url.path],
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        )
        return item
    }

    /// Pasteboard items for an AppKit dragging session (icon view): one per
    /// file, never one item carrying a list.
    static func draggingItems(
        for urls: [URL],
        frame: NSRect,
        contents: NSImage?
    ) -> [NSDraggingItem] {
        urls.map { url in
            let item = NSDraggingItem(pasteboardWriter: pasteboardItem(for: url))
            item.setDraggingFrame(frame, contents: contents)
            return item
        }
    }
}
