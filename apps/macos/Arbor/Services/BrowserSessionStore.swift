import AppKit
import Foundation

/// Loads / saves `BrowserSessionSnapshot` under Application Support and feeds
/// pending window snapshots into new `ContentView` instances at launch.
@MainActor
final class BrowserSessionStore {
    static let shared = BrowserSessionStore()

    private var pendingWindows: [BrowserWindowSnapshot] = []
    private var didOpenRemaining = false
    private var prepared = false

    private var windowOrder: [UUID] = []
    private var windows: [UUID: BrowserWindowSnapshot] = [:]
    private var pendingFrames: [UUID: CGRect] = [:]

    private var saveWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.45

    private init() {
        #if DEBUG
        BrowserSessionSnapshot.runSelfCheck()
        BrowserSort.runSelfCheck()
        #endif
    }

    // MARK: - Launch restore

    /// Call from `applicationWillFinishLaunching` before WindowGroup creates views.
    /// Also invoked lazily from `dequeuePendingWindow` if needed.
    func prepareForLaunch() {
        guard !prepared else { return }
        prepared = true

        guard let snapshot = loadFromDisk(), !snapshot.windows.isEmpty else {
            pendingWindows = []
            return
        }
        pendingWindows = snapshot.windows.filter { !$0.tabs.isEmpty }
    }

    func dequeuePendingWindow() -> BrowserWindowSnapshot? {
        prepareForLaunch()
        guard !pendingWindows.isEmpty else { return nil }
        return pendingWindows.removeFirst()
    }

    /// After `openWindow` is installed, open one WindowGroup window per remaining snapshot.
    func openRemainingRestoredWindowsIfNeeded() {
        guard !didOpenRemaining else { return }
        didOpenRemaining = true

        let count = pendingWindows.count
        guard count > 0 else { return }

        for _ in 0..<count {
            WindowLaunchCoordinator.openRestoredBrowserWindow()
        }
    }

    // MARK: - Live window tracking

    func updateWindow(id: UUID, snapshot: BrowserWindowSnapshot) {
        var next = snapshot
        if next.frame == nil {
            if let existing = windows[id]?.frame {
                next.frame = existing
            } else if let frame = pendingFrames.removeValue(forKey: id),
                      BrowserWindowFrame(frame).isReasonable
            {
                next.frame = BrowserWindowFrame(frame)
            }
        }
        if windows[id] == nil {
            windowOrder.append(id)
        }
        windows[id] = next
        scheduleSave()
    }

    func removeWindow(id: UUID) {
        windows.removeValue(forKey: id)
        pendingFrames.removeValue(forKey: id)
        windowOrder.removeAll { $0 == id }
        scheduleSave()
    }

    func updateFrame(id: UUID, frame: CGRect) {
        let boxed = BrowserWindowFrame(frame)
        guard boxed.isReasonable else { return }

        if var snap = windows[id] {
            snap.frame = boxed
            windows[id] = snap
            scheduleSave()
        } else {
            pendingFrames[id] = frame
        }
    }

    func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveNow()
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil

        let ordered = windowOrder.compactMap { id -> BrowserWindowSnapshot? in
            windows[id]
        }
        writeAtomically(BrowserSessionSnapshot(windows: ordered))
    }

    // MARK: - Disk I/O

    private static var supportDirectoryURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return root.appendingPathComponent("Arbor", isDirectory: true)
    }

    static var sessionFileURL: URL {
        supportDirectoryURL.appendingPathComponent("session.json", isDirectory: false)
    }

    private func loadFromDisk() -> BrowserSessionSnapshot? {
        let url = Self.sessionFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let snapshot = try BrowserSessionSnapshot.from(jsonData: data)
            return snapshot.windows.isEmpty ? nil : snapshot
        } catch {
            return nil
        }
    }

    /// Write-temp-then-rename so a crash mid-write leaves the previous good file.
    private func writeAtomically(_ snapshot: BrowserSessionSnapshot) {
        let dest = Self.sessionFileURL
        let dir = dest.deletingLastPathComponent()
        let temp = dir.appendingPathComponent("session.json.tmp", isDirectory: false)
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try snapshot.jsonData()
            if fm.fileExists(atPath: temp.path) {
                try fm.removeItem(at: temp)
            }
            try data.write(to: temp, options: Data.WritingOptions())
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: dest)
            }
        } catch {
            try? fm.removeItem(at: temp)
        }
    }
}

// MARK: - Path resolution & tab materialization

extension BrowserWindowSnapshot {
    /// Builds live tabs, substituting Home when a saved path is missing.
    @MainActor
    func makeBrowserTabs() -> (tabs: [BrowserTab], selectedTabID: BrowserTab.ID) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var built: [BrowserTab] = []

        for tabSnap in tabs {
            let roots = tabSnap.resolvedPaneRoots(fallback: home)
            guard !roots.isEmpty else { continue }
            built.append(
                BrowserTab(paneRoots: roots, focusedPaneIndex: tabSnap.focusedPaneIndex)
            )
        }

        if built.isEmpty {
            let tab = BrowserTab(root: home)
            return ([tab], tab.id)
        }

        let index = min(max(0, selectedTabIndex), built.count - 1)
        return (built, built[index].id)
    }
}

extension BrowserTabSnapshot {
    func resolvedPaneRoots(fallback: URL) -> [URL] {
        let paths = panePaths.isEmpty ? [fallback.path] : panePaths
        // Cap at dual-pane split for this MVP.
        let limited = Array(paths.prefix(2))
        return limited.map { Self.resolveDirectoryPath($0, fallback: fallback) }
    }

    static func resolveDirectoryPath(_ path: String, fallback: URL) -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url
        }
        return fallback.standardizedFileURL
    }
}
