import Foundation
import AppKit

nonisolated struct FileEntry: Identifiable, Hashable, Sendable {
    let id: ItemRef
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let size: UInt64
    let kind: String
    let modified: Date?
    let created: Date?
    /// Relative or absolute location label (used in search results).
    let location: String

    /// Temporary bridge for local-only AppKit and workspace APIs.
    var localURL: URL? {
        FileProviderRegistry.shared.intrinsicLocalURL(for: id)
    }

    /// Folders you can browse into (not packages like .app).
    var isBrowsable: Bool {
        isDirectory && !isPackage
    }

    var fullPath: String { id.path }

    var formattedSize: String {
        if isDirectory && !isPackage { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var modifiedForSort: Date { modified ?? .distantPast }
    var createdForSort: Date { created ?? .distantPast }
    var sizeForSort: UInt64 { (isDirectory && !isPackage) ? 0 : size }

    /// Finder dims hidden items when “Show Hidden Files” is on (~50% opacity).
    var listingOpacity: Double { isHidden ? 0.5 : 1 }

    var symbolName: String {
        if isPackage { return "app.fill" }
        if isDirectory { return "folder.fill" }
        return "doc"
    }

    nonisolated(unsafe) static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    func formatted(_ date: Date?) -> String {
        guard let date else { return "—" }
        return Self.dateFormatter.string(from: date)
    }

    func relativePath(to root: ItemRef) -> String {
        guard id.volumeID == root.volumeID else { return id.path }
        let rootPath = root.path
        let path = id.path
        if path == rootPath { return "." }
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return path
    }

}

struct FileDetails: Hashable {
    let item: ItemRef
    let name: String
    let kind: String
    let size: UInt64?
    let created: Date?
    let modified: Date?
    let isDirectory: Bool
    let isPackage: Bool
    let isSymbolicLink: Bool
    let isReadable: Bool
    let isWritable: Bool
    let posixPermissions: Int?

    var path: String { item.path }
    var localURL: URL? {
        FileProviderRegistry.shared.intrinsicLocalURL(for: item)
    }

    var formattedSize: String {
        guard let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var permissionsDescription: String {
        guard let posixPermissions else { return "—" }
        let mode = mode_t(posixPermissions)
        func bit(_ mask: mode_t, _ ch: Character) -> Character {
            (mode & mask) != 0 ? ch : "-"
        }
        return String([
            bit(0o400, "r"), bit(0o200, "w"), bit(0o100, "x"),
            bit(0o040, "r"), bit(0o020, "w"), bit(0o010, "x"),
            bit(0o004, "r"), bit(0o002, "w"), bit(0o001, "x"),
        ])
    }

}

nonisolated extension FileEntry {
    init(providerEntry: FileProviderEntry, location: String = ".") {
        id = providerEntry.id
        name = providerEntry.name
        isDirectory = providerEntry.isDirectory
        isPackage = providerEntry.isPackage
        isHidden = providerEntry.isHidden
        size = providerEntry.size
        kind = providerEntry.kind
        modified = providerEntry.modified
        created = providerEntry.created
        self.location = location
    }
}

extension FileDetails {
    init(providerDetails: FileProviderItemDetails) {
        item = providerDetails.item
        name = providerDetails.name
        kind = providerDetails.kind
        size = providerDetails.size
        created = providerDetails.created
        modified = providerDetails.modified
        isDirectory = providerDetails.isDirectory
        isPackage = providerDetails.isPackage
        isSymbolicLink = providerDetails.isSymbolicLink
        isReadable = providerDetails.isReadable
        isWritable = providerDetails.isWritable
        posixPermissions = providerDetails.posixPermissions
    }
}

/// Compatibility facade while call sites migrate from local URLs to ItemRef.
/// Filesystem reads now cross the FileProvider boundary.
enum LocalFileService {
    private static let provider = LocalFileProvider()

    static func list(path: URL, showHiddenFiles: Bool = false) throws -> [FileEntry] {
        try provider.listSync(
            directory: LocalFileLocation.item(for: path),
            options: FileProviderListingOptions(showHiddenFiles: showHiddenFiles)
        ).map { FileEntry(providerEntry: $0) }
    }

    static func entry(at url: URL, location: String = ".") -> FileEntry? {
        entry(at: LocalFileLocation.item(for: url), location: location)
    }

    static func entry(at item: ItemRef, location: String = ".") -> FileEntry? {
        try? FileEntry(
            providerEntry: provider.entrySync(at: item),
            location: location
        )
    }

    static func details(for url: URL) throws -> FileDetails {
        FileDetails(
            providerDetails: try provider.detailsSync(
                for: LocalFileLocation.item(for: url)
            )
        )
    }
}

enum WorkspaceActions {
    static func open(_ item: ItemRef) {
        Task {
            do {
                let provider = try FileProviderRegistry.shared.provider(for: item)
                let materialized = try await provider.materialize(item, for: .open)
                NSWorkspace.shared.open(materialized.url)
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    static func openMany(_ items: [ItemRef]) {
        for item in items {
            open(item)
        }
    }

    static func revealInFinder(_ items: [ItemRef]) {
        let urls = items.compactMap {
            FileProviderRegistry.shared.intrinsicLocalURL(for: $0)
        }
        guard urls.count == items.count else { return }
        revealInFinder(urls)
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func openMany(_ urls: [URL]) {
        for url in urls {
            NSWorkspace.shared.open(url)
        }
    }

    static func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func revealInFinder(_ url: URL) {
        revealInFinder([url])
    }

    static func copyPath(_ url: URL) {
        copyPaths([url])
    }

    static func copyPaths(_ urls: [URL]) {
        let text = urls.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func copyPaths(_ items: [ItemRef]) {
        let text = items.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func copyName(_ url: URL) {
        copyNames([url])
    }

    static func copyNames(_ urls: [URL]) {
        let text = urls.map(\.lastPathComponent).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func copyNames(_ items: [ItemRef]) {
        let text = items.map(\.name).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Opens Terminal.app with cwd set to `directory`.
    static func openTerminal(at directory: URL) {
        let dir = directory.standardizedFileURL
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", dir.path]
        try? process.run()
    }

    static func openTerminal(context: ExecutionContext) {
        guard let directory = context.intrinsicLocalDirectoryURL else { return }
        openTerminal(at: directory)
    }

    /// Opens Cursor IDE on a folder (IDE launcher — not Cursor Agent CLI).
    static func openInCursor(at directory: URL) {
        openInApplication(named: "Cursor", path: directory)
    }

    static func openInCursor(at item: ItemRef) {
        guard let directory = FileProviderRegistry.shared.intrinsicLocalURL(for: item) else {
            return
        }
        openInCursor(at: directory)
    }

    static func openInApplication(named appName: String, path: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appName, path.standardizedFileURL.path]
        try? process.run()
    }

    /// Runs `command` in Terminal.app after `cd` into `directory`, then leaves an interactive shell.
    static func runInTerminalApp(command: String, directory: URL) {
        let dir = AgentCommandExpander.shellEscape(directory.standardizedFileURL.path)
        let script = "cd \(dir) && \(command)"
        let source = """
        tell application "Terminal"
          activate
          do script \(applescriptString(script))
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        try? process.run()
    }

    private static func applescriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Runs `command` in Ghostty when installed; falls back to Terminal.app.
    static func runInGhostty(command: String, directory: URL) {
        let ghostty = URL(fileURLWithPath: "/Applications/Ghostty.app")
        guard FileManager.default.fileExists(atPath: ghostty.path) else {
            runInTerminalApp(command: command, directory: directory)
            return
        }
        let dir = directory.standardizedFileURL.path
        let wrapped = "cd \(AgentCommandExpander.shellEscape(dir)) && \(command); exec \"$SHELL\" -i"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-na", "Ghostty",
            "--args",
            "-e", "/bin/zsh", "-lc", wrapped,
        ]
        do {
            try process.run()
        } catch {
            runInTerminalApp(command: command, directory: directory)
        }
    }

    static func terminalDirectory(for entry: FileEntry) -> URL {
        guard let url = entry.localURL else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        if entry.isBrowsable {
            return url
        }
        return url.deletingLastPathComponent()
    }

    /// Best terminal cwd for a multi-selection (common parent, or single folder).
    static func terminalDirectory(for entries: [FileEntry]) -> URL {
        guard let first = entries.first else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        if entries.count == 1 {
            return terminalDirectory(for: first)
        }

        let browsable = entries.filter(\.isBrowsable)
        if browsable.count == 1, let only = browsable.first, let url = only.localURL {
            return url
        }

        let parents = Set(entries.map { terminalDirectory(for: $0).standardizedFileURL.path })
        if parents.count == 1, let path = parents.first {
            return URL(fileURLWithPath: path)
        }

        return commonParent(of: entries.compactMap(\.localURL)) ?? terminalDirectory(for: first)
    }

    static func executionContext(for entries: [FileEntry]) -> ExecutionContext {
        let directory = terminalDirectory(for: entries)
        return ExecutionContext(
            workingDirectory: LocalFileLocation.item(for: directory),
            selection: entries.map(\.id)
        )
    }

    static func commonParent(of urls: [URL]) -> URL? {
        guard let first = urls.first else { return nil }
        var prefix = first.deletingLastPathComponent().pathComponents
        for url in urls.dropFirst() {
            let parts = url.deletingLastPathComponent().pathComponents
            var i = 0
            while i < prefix.count, i < parts.count, prefix[i] == parts[i] {
                i += 1
            }
            prefix = Array(prefix.prefix(i))
            if prefix.isEmpty { return URL(fileURLWithPath: "/") }
        }
        return URL(fileURLWithPath: NSString.path(withComponents: prefix))
    }
}
