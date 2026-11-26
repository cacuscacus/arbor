import AppKit
import Foundation
import Observation

/// Finder-compatible file clipboard integrating `NSPasteboard.general`:
/// - `⌘C` writes local file URLs to the system pasteboard (so you can paste into Finder, Slack, Mail)
///   and records the `ItemRef`s for remote/local paste inside Arbor.
/// - `⌘X` records a cut for one-shot paste-as-move.
/// - `⌘V` pastes as Copy (repeatable) or Move (after `⌘X`), automatically reading newer file URLs
///   copied externally in Finder.
/// - `⌘⌥V` moves copied files into the destination (Finder's "Move Items Here").
@MainActor
@Observable
final class FileClipboard {
    static let shared = FileClipboard()

    private(set) var items: [ItemRef] = []
    private(set) var intent: FileClipboardIntent = .copy
    private var state = FileClipboardState()
    /// Maps normalized path string -> original `ItemRef` (preserves remote/SSH volume IDs).
    private var refsByKey: [String: ItemRef] = [:]

    private init() {}

    var cutItems: [ItemRef] { intent == .cut ? items : [] }
    var hasCutItems: Bool { intent == .cut && !items.isEmpty }

    var canPaste: Bool {
        currentResolution(forceMove: false) != nil
    }

    var pasteCount: Int {
        currentResolution(forceMove: false)?.paths.count ?? 0
    }

    var defaultPasteIsMove: Bool {
        currentResolution(forceMove: false)?.isMove ?? false
    }

    func copy(_ targets: [ItemRef]) {
        guard !targets.isEmpty else { return }
        writeLocalURLsToSystemPasteboard(targets)
        record(targets, intent: .copy)
    }

    func cut(_ targets: [ItemRef]) {
        guard !targets.isEmpty else { return }
        writeLocalURLsToSystemPasteboard(targets)
        record(targets, intent: .cut)
    }

    func clear() {
        items = []
        intent = .copy
        refsByKey = [:]
        state.clear()
    }

    /// Resolves and consumes (when moving) the current clipboard payload.
    func takeForPaste(forceMove: Bool) -> (items: [ItemRef], operation: FileTransferOperation)? {
        guard let res = currentResolution(forceMove: forceMove) else { return nil }
        let resolvedRefs: [ItemRef] = res.paths.map { key in
            if let existing = refsByKey[key] {
                return existing
            }
            return LocalFileLocation.item(for: URL(fileURLWithPath: key))
        }
        guard !resolvedRefs.isEmpty else { return nil }

        if res.clearsInternalAfterPaste {
            clear()
        }
        return (resolvedRefs, res.isMove ? .move : .copy)
    }

    // MARK: - Internal helpers

    private func record(_ targets: [ItemRef], intent: FileClipboardIntent) {
        self.items = targets
        self.intent = intent
        var map: [String: ItemRef] = [:]
        var keys: [String] = []
        for ref in targets {
            let key = storageKey(for: ref)
            map[key] = ref
            keys.append(key)
        }
        self.refsByKey = map
        state.record(
            paths: keys,
            intent: intent,
            pasteboardChangeCount: NSPasteboard.general.changeCount
        )
    }

    private func storageKey(for ref: ItemRef) -> String {
        if let local = FileProviderRegistry.shared.intrinsicLocalURL(for: ref) {
            return local.standardizedFileURL.path
        }
        return "\(ref.volumeID.rawValue)::\(ref.path)"
    }

    private func writeLocalURLsToSystemPasteboard(_ targets: [ItemRef]) {
        let urls = targets.compactMap { FileProviderRegistry.shared.intrinsicLocalURL(for: $0) as NSURL? }
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls)
    }

    private func currentResolution(forceMove: Bool) -> FileClipboardResolution? {
        let pb = NSPasteboard.general
        let externalURLs = (pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL]) ?? []
        let externalPaths = externalURLs.map { $0.standardizedFileURL.path }

        return state.resolve(
            externalPasteboardPaths: externalPaths,
            currentPasteboardChangeCount: pb.changeCount,
            forceMove: forceMove
        )
    }
}
