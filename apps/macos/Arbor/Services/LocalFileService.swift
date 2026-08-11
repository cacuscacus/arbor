import Foundation
import AppKit

struct FileEntry: Identifiable, Hashable {
    let id: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let size: UInt64
    let kind: String
    let modified: Date?
    let created: Date?
    /// Relative or absolute location label (used in search results).
    let location: String

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

    var symbolName: String {
        if isPackage { return "app.fill" }
        if isDirectory { return "folder.fill" }
        return "doc"
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    func formatted(_ date: Date?) -> String {
        guard let date else { return "—" }
        return Self.dateFormatter.string(from: date)
    }

    func relativePath(to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = id.standardizedFileURL.path
        if path == rootPath { return "." }
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return path
    }
}

struct FileDetails: Hashable {
    let url: URL
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

    var path: String { url.path }

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

/// Temporary Swift-side listing until `arbor-ffi` is linked into the app.
enum LocalFileService {
    private static let listKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .fileSizeKey,
        .isHiddenKey,
        .nameKey,
        .localizedTypeDescriptionKey,
        .contentModificationDateKey,
        .creationDateKey,
    ]

    static func list(path: URL, showHiddenFiles: Bool = false) throws -> [FileEntry] {
        var options: FileManager.DirectoryEnumerationOptions = []
        if !showHiddenFiles {
            options.insert(.skipsHiddenFiles)
        }
        let contents = try FileManager.default.contentsOfDirectory(
            at: path,
            includingPropertiesForKeys: Array(listKeys),
            options: options
        )

        var entries: [FileEntry] = contents.compactMap { makeEntry(from: $0, location: ".") }

        entries.sort { lhs, rhs in
            if lhs.isBrowsable != rhs.isBrowsable {
                return lhs.isBrowsable && !rhs.isBrowsable
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return entries
    }

    static func entry(at url: URL, location: String = ".") -> FileEntry? {
        makeEntry(from: url, location: location)
    }

    static func details(for url: URL) throws -> FileDetails {
        let keys: Set<URLResourceKey> = [
            .nameKey,
            .localizedTypeDescriptionKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .isReadableKey,
            .isWritableKey,
        ]

        let values = try url.resourceValues(forKeys: keys)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let posix = attrs?[.posixPermissions] as? Int

        return FileDetails(
            url: url,
            name: values.name ?? url.lastPathComponent,
            kind: values.localizedTypeDescription ?? "Unknown",
            size: values.fileSize.map(UInt64.init),
            created: values.creationDate,
            modified: values.contentModificationDate,
            isDirectory: values.isDirectory ?? false,
            isPackage: values.isPackage ?? false,
            isSymbolicLink: values.isSymbolicLink ?? false,
            isReadable: values.isReadable ?? false,
            isWritable: values.isWritable ?? false,
            posixPermissions: posix
        )
    }

    private static func makeEntry(from url: URL, location: String) -> FileEntry? {
        let values = try? url.resourceValues(forKeys: listKeys)
        let isDir = values?.isDirectory ?? false
        let isPackage = values?.isPackage ?? false
        let size = UInt64(values?.fileSize ?? 0)
        let kind: String = {
            if let description = values?.localizedTypeDescription {
                return description
            }
            if isPackage { return "Application" }
            if isDir { return "Folder" }
            return url.pathExtension.isEmpty ? "Document" : url.pathExtension.uppercased()
        }()

        return FileEntry(
            id: url,
            name: values?.name ?? url.lastPathComponent,
            isDirectory: isDir,
            isPackage: isPackage,
            size: size,
            kind: kind,
            modified: values?.contentModificationDate,
            created: values?.creationDate,
            location: location
        )
    }
}

enum WorkspaceActions {
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

    static func copyName(_ url: URL) {
        copyNames([url])
    }

    static func copyNames(_ urls: [URL]) {
        let text = urls.map(\.lastPathComponent).joined(separator: "\n")
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

    /// Opens Cursor IDE on a folder (IDE launcher — not Cursor Agent CLI).
    static func openInCursor(at directory: URL) {
        openInApplication(named: "Cursor", path: directory)
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
        if entry.isBrowsable {
            return entry.id
        }
        return entry.id.deletingLastPathComponent()
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
        if browsable.count == 1, let only = browsable.first {
            return only.id
        }

        let parents = Set(entries.map { terminalDirectory(for: $0).standardizedFileURL.path })
        if parents.count == 1, let path = parents.first {
            return URL(fileURLWithPath: path)
        }

        return commonParent(of: entries.map(\.id)) ?? terminalDirectory(for: first)
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
