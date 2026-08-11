import AppKit
import Darwin
import Foundation
import SwiftUI

/// Watches a single directory for listing-relevant changes (Finder-like, scoped).
///
/// Uses `DispatchSource` on an `O_EVTONLY` descriptor — cheap for 1–2 visible panes.
/// Events are coalesced with a short debounce so bursts (`git checkout`, builds) do
/// not spam `readdir`. Nested changes deeper than the watched folder still generate
/// FS activity; we only watch the folder inode the user is viewing, not the whole volume.
@MainActor
final class FolderListingWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    private var debounceItem: DispatchWorkItem?
    /// Debounce window — Finder also coalesces; keeps listing O(n) cost off the hot path.
    private let debounce: TimeInterval = 0.2

    private(set) var onChange: (() -> Void)?

    func start(path: URL, onChange: @escaping () -> Void) {
        let standardized = path.standardizedFileURL.path
        self.onChange = onChange
        if standardized == watchedPath, source != nil {
            return
        }
        stopSourceOnly()
        watchedPath = standardized

        let fd = open(standardized, O_EVTONLY)
        guard fd >= 0 else {
            watchedPath = nil
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            // Omit `.attrib` / `.extend` — Spotlight, xattrs, and thumbnailers make these noisy.
            eventMask: [.write, .delete, .rename, .link, .revoke],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            self?.scheduleNotify()
        }
        src.setCancelHandler {
            close(fd)
        }
        source = src
        src.resume()
    }

    func stop() {
        onChange = nil
        stopSourceOnly()
    }

    private func stopSourceOnly() {
        debounceItem?.cancel()
        debounceItem = nil
        source?.cancel()
        source = nil
        watchedPath = nil
    }

    private func scheduleNotify() {
        debounceItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        debounceItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}

/// Invisible SwiftUI host that owns a `FolderListingWatcher` for a browser pane.
struct FolderListingWatchActivator: View {
    let path: URL?
    let onChange: () -> Void

    @State private var watcher = FolderListingWatcher()

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { sync() }
            .onChange(of: path?.path) { _, _ in sync() }
            .onDisappear { watcher.stop() }
    }

    private func sync() {
        if let path {
            watcher.start(path: path, onChange: onChange)
        } else {
            watcher.stop()
        }
    }
}
