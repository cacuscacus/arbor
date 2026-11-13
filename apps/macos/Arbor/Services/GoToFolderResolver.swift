import Foundation

/// Resolves the text typed into **Go to Folder…** (⇧⌘G).
///
/// Finder accepts `~`, relative-looking names, and full paths. We resolve against
/// the current folder so `Documentos` works while browsing `test_file_structure`.
struct GoToFolderResolver {
    let currentDirectory: URL
    let fileManager: FileManager

    init(currentDirectory: URL, fileManager: FileManager = .default) {
        self.currentDirectory = currentDirectory
        self.fileManager = fileManager
    }

    enum Failure: LocalizedError {
        case empty
        case notFound(String)
        case notADirectory(String)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Enter a folder path."
            case .notFound(let path):
                return "“\(path)” doesn’t exist."
            case .notADirectory(let path):
                return "“\(path)” is a file, not a folder."
            }
        }
    }

    /// Expands `~` and resolves relative input against the current folder,
    /// without touching the disk beyond standardization.
    func expand(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        // A bare name refers to something inside the current folder.
        return currentDirectory.appendingPathComponent(expanded).standardizedFileURL
    }

    /// Returns the folder to navigate to. Files are rejected here; the caller
    /// handles “reveal the file’s folder” separately (see `resolveReveal`).
    func resolve(_ raw: String) throws -> URL {
        guard let url = expand(raw) else { throw Failure.empty }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw Failure.notFound(url.path)
        }
        guard isDirectory.boolValue else {
            throw Failure.notADirectory(url.path)
        }
        return url
    }

    /// For file input: the folder to open plus the file to select in it.
    func resolveReveal(_ raw: String) throws -> (folder: URL, selection: URL?) {
        guard let url = expand(raw) else { throw Failure.empty }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw Failure.notFound(url.path)
        }
        if isDirectory.boolValue {
            return (url, nil)
        }
        return (url.deletingLastPathComponent(), url)
    }

    /// Finder-style Tab completion: completes the last path component using the
    /// first directory entry that has the typed prefix.
    func completion(for raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasSuffix("/"), !trimmed.hasSuffix("~") else { return nil }

        // Resolve relative input against the current folder, exactly like
        // `expand` — otherwise "Im" is looked up under "/".
        let typedURL: URL
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            typedURL = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        } else {
            typedURL = currentDirectory.appendingPathComponent(trimmed)
        }
        let parent = typedURL.deletingLastPathComponent()
        let fragment = typedURL.lastPathComponent
        guard !fragment.isEmpty else { return nil }

        let children = (try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let candidates = children
            .map(\.lastPathComponent)
            .filter { name in
                name.range(of: fragment, options: [.caseInsensitive, .anchored]) != nil
                    && name != fragment
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        guard let match = candidates.first else { return nil }
        let isDirectory = (try? parent.appendingPathComponent(match).resourceValues(forKeys: [.isDirectoryKey]))?
            .isDirectory ?? false
        return parent.appendingPathComponent(match).path + (isDirectory ? "/" : "")
    }
}

#if DEBUG
extension GoToFolderResolver {
    /// Invariants for expansion, validation, reveal, and Tab completion.
    /// Runs on a throwaway temp directory so it never touches user folders.
    static func runSelfCheck() {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arbor-g2f-selfcheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let folder = root.appendingPathComponent("Alpha Folder", isDirectory: true)
        let file = root.appendingPathComponent("note.txt")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: file)
        } catch {
            assertionFailure("GoToFolder self-check setup failed: \(error)")
            return
        }

        let resolver = GoToFolderResolver(currentDirectory: root, fileManager: fm)

        assert(resolver.expand("   ") == nil, "blank input must not resolve")
        assert(
            resolver.expand("Alpha Folder")?.path == folder.path,
            "relative input resolves against the current folder"
        )
        assert(
            (try? resolver.resolve("Alpha Folder"))?.path == folder.path,
            "existing folder resolves"
        )
        assert((try? resolver.resolve("nope")) == nil, "missing path must fail")
        assert((try? resolver.resolve("note.txt")) == nil, "a file is not a folder")

        if let reveal = try? resolver.resolveReveal("note.txt") {
            assert(reveal.folder.path == root.path, "reveal opens the parent")
            assert(reveal.selection?.lastPathComponent == "note.txt", "reveal selects the file")
        } else {
            assertionFailure("resolveReveal failed for an existing file")
        }

        assert(
            resolver.completion(for: root.path + "/Al")
                == folder.path + "/",
            "Tab completes the unique prefix with a trailing slash"
        )
        assert(
            resolver.completion(for: "Al") == folder.path + "/",
            "Tab completion resolves relative input against the current folder"
        )
        assert(resolver.completion(for: root.path) == nil, "no completion for a directory itself")
    }
}
#endif
