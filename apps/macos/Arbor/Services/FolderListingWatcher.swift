import AppKit
import Darwin
import Foundation
import SwiftUI

/// Watches a single directory for listing-relevant changes (Finder-like, scoped).
///
/// Local volumes with `.nativeWatch` use `DispatchSource` on an `O_EVTONLY`
/// descriptor — cheap for 1–2 visible panes. Events are coalesced with a short
/// debounce so bursts (`git checkout`, builds) do not spam `readdir`.
///
/// Providers without `.nativeWatch` (SSH) poll only while their pane is visible.
@MainActor
final class FolderListingWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pollingTask: Task<Void, Never>?
    private var watchedDirectory: ItemRef?
    private var debounceItem: DispatchWorkItem?
    /// Debounce window — Finder also coalesces; keeps listing O(n) cost off the hot path.
    private let debounce: TimeInterval = 0.2

    private(set) var onChange: (() -> Void)?

    func start(directory: ItemRef, onChange: @escaping () -> Void) {
        self.onChange = onChange
        if directory == watchedDirectory, source != nil || pollingTask != nil {
            return
        }
        stopSourceOnly()
        watchedDirectory = directory

        guard Self.supportsNativeWatch(directory) else {
            pollingTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    self?.onChange?()
                }
            }
            return
        }
        guard let path = directory.localURL?.path else { return }

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            watchedDirectory = nil
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

    nonisolated static func supportsNativeWatch(_ directory: ItemRef) -> Bool {
        guard let provider = try? FileProviderRegistry.shared.provider(for: directory) else {
            return false
        }
        return provider.volume.capabilities.contains(.nativeWatch)
    }

    private func stopSourceOnly() {
        debounceItem?.cancel()
        debounceItem = nil
        source?.cancel()
        source = nil
        pollingTask?.cancel()
        pollingTask = nil
        watchedDirectory = nil
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
    let directory: ItemRef?
    let onChange: () -> Void

    @State private var watcher = FolderListingWatcher()

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { sync() }
            .onChange(of: directory) { _, _ in sync() }
            .onDisappear { watcher.stop() }
    }

    private func sync() {
        if let directory {
            watcher.start(directory: directory, onChange: onChange)
        } else {
            watcher.stop()
        }
    }
}
