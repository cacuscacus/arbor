import Foundation
import AppKit

enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case currentFolder = "This Folder"
    case global = "Global"

    var id: String { rawValue }
}

struct SearchHit: Identifiable, Hashable, Sendable {
    let id: URL
    let name: String
    let parentPath: String
    let isDirectory: Bool
    let isPackage: Bool

    var isBrowsable: Bool {
        isDirectory && !isPackage
    }

    func asFileEntry() -> FileEntry {
        LocalFileService.entry(at: id, location: parentPath)
            ?? FileEntry(
                id: id,
                name: name,
                isDirectory: isDirectory,
                isPackage: isPackage,
                size: 0,
                kind: isDirectory ? "Folder" : "Document",
                modified: nil,
                created: nil,
                location: parentPath
            )
    }
}

/// Filename search for the macOS UI. Prefers `fd`, then Spotlight (`mdfind`), then a walk fallback.
enum SearchService {
    nonisolated static let resultLimit = 500

    nonisolated static func search(
        query: String,
        scope: SearchScope,
        currentFolder: URL
    ) async throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        try Task.checkCancellation()

        let root: URL = {
            switch scope {
            case .currentFolder:
                return currentFolder.standardizedFileURL
            case .global:
                return FileManager.default.homeDirectoryForCurrentUser
            }
        }()

        if let hits = try await searchWithFd(query: trimmed, root: root) {
            return hits
        }

        if scope == .global, let hits = try await searchWithSpotlight(query: trimmed) {
            return hits
        }

        return try await searchWithEnumerator(query: trimmed, root: root)
    }

    // MARK: - fd

    nonisolated private static func searchWithFd(query: String, root: URL) async throws -> [SearchHit]? {
        guard let fd = resolveFdPath() else { return nil }

        let output = try await runProcess(
            executable: fd,
            arguments: [
                "--color=never",
                "--fixed-strings",
                "--ignore-case",
                "--max-results", "\(resultLimit)",
                "--exclude", ".git",
                "--exclude", "node_modules",
                "--exclude", "DerivedData",
                "--exclude", "target",
                "--exclude", ".build",
                query,
                root.path,
            ]
        )

        try Task.checkCancellation()
        return parsePathLines(output, relativeTo: root)
    }

    nonisolated private static func resolveFdPath() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/fd",
            "/usr/local/bin/fd",
            "\(home)/.kimi-code/bin/fd",
            "\(home)/.cargo/bin/fd",
            "\(home)/.local/bin/fd",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Spotlight

    nonisolated private static func searchWithSpotlight(query: String) async throws -> [SearchHit]? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let output = try await runProcess(
            executable: "/usr/bin/mdfind",
            arguments: [
                "-onlyin", home,
                "kMDItemFSName == '*\(escapeSpotlight(query))*'cd",
            ]
        )

        try Task.checkCancellation()
        var hits = parsePathLines(output, relativeTo: URL(fileURLWithPath: home))
        if hits.count > resultLimit {
            hits = Array(hits.prefix(resultLimit))
        }
        return hits
    }

    nonisolated private static func escapeSpotlight(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Fallback walk

    nonisolated private static func searchWithEnumerator(query: String, root: URL) async throws -> [SearchHit] {
        let needle = query.lowercased()
        let rootPath = root.path

        return try await Task.detached(priority: .userInitiated) {
            var hits: [SearchHit] = []
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .nameKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return []
            }

            let skipNames: Set<String> = [
                ".git", "node_modules", "DerivedData", "target", ".build", "Pods",
            ]

            while let next = enumerator.nextObject() as? URL {
                try Task.checkCancellation()

                if skipNames.contains(next.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }

                let name = next.lastPathComponent
                guard name.lowercased().contains(needle) else { continue }

                let values = try? next.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                let isDirectory = values?.isDirectory ?? false
                let isPackage = values?.isPackage ?? false
                let parent = next.deletingLastPathComponent().path
                let relativeParent: String = {
                    if parent == rootPath { return "." }
                    if parent.hasPrefix(rootPath + "/") {
                        return String(parent.dropFirst(rootPath.count + 1))
                    }
                    return parent
                }()

                hits.append(
                    SearchHit(
                        id: next,
                        name: name,
                        parentPath: relativeParent,
                        isDirectory: isDirectory,
                        isPackage: isPackage
                    )
                )

                if hits.count >= resultLimit {
                    break
                }
            }

            return hits
        }.value
    }

    // MARK: - Helpers

    nonisolated private static func parsePathLines(_ output: String, relativeTo root: URL) -> [SearchHit] {
        let rootPath = root.path
        var hits: [SearchHit] = []
        hits.reserveCapacity(min(resultLimit, 64))

        for line in output.split(whereSeparator: \.isNewline) {
            let path = String(line)
            guard !path.isEmpty else { continue }
            let url = URL(fileURLWithPath: path)
            var isDirectory = false
            var isPackage = false
            if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) {
                isDirectory = values.isDirectory ?? false
                isPackage = values.isPackage ?? false
            } else {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
                isDirectory = isDir.boolValue
            }

            let parent = url.deletingLastPathComponent().path
            let relativeParent: String = {
                if parent == rootPath { return "." }
                if parent.hasPrefix(rootPath + "/") {
                    return String(parent.dropFirst(rootPath.count + 1))
                }
                return parent
            }()

            hits.append(
                SearchHit(
                    id: url,
                    name: url.lastPathComponent,
                    parentPath: relativeParent,
                    isDirectory: isDirectory,
                    isPackage: isPackage
                )
            )
        }

        return hits
    }

    nonisolated private static func runProcess(executable: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    try process.run()
                    process.waitUntilExit()

                    let data = stdout.fileHandleForReading.readDataToEndOfFile()
                    let text = String(data: data, encoding: .utf8) ?? ""

                    // fd returns 1 when no matches — treat as empty success.
                    if process.terminationStatus == 0
                        || (executable.hasSuffix("/fd") && process.terminationStatus == 1)
                    {
                        continuation.resume(returning: text)
                    } else {
                        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        continuation.resume(
                            throwing: NSError(
                                domain: "ArborSearch",
                                code: Int(process.terminationStatus),
                                userInfo: [
                                    NSLocalizedDescriptionKey: err.isEmpty ? "Search failed" : err,
                                ]
                            )
                        )
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
