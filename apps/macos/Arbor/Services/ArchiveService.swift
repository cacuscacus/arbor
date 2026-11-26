import Foundation

nonisolated enum ArchiveServiceError: LocalizedError, Sendable {
    case emptySelection
    case unsupportedArchive(String)
    case dittoFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "No local items selected to compress."
        case .unsupportedArchive(let name):
            return "'\(name)' is not a supported .zip archive."
        case .dittoFailed(let detail):
            return detail.isEmpty ? "Archive operation failed." : detail
        }
    }
}

/// Finder-compatible `.zip` compression and extraction backed by `/usr/bin/ditto`.
/// Preserves macOS extended attributes, permissions, symlinks, and UTF-8 filenames,
/// and never overwrites existing items.
nonisolated enum ArchiveService {
    static func compress(urls: [URL], in directory: URL) async throws -> URL {
        guard !urls.isEmpty else { throw ArchiveServiceError.emptySelection }
        let destination = ArchiveNameResolver.uniqueArchiveURL(for: urls, in: directory)

        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if urls.count == 1, let only = urls.first {
                try runDitto(arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", only.path, destination.path])
                return destination
            }

            // For multi-selection, stage symlinks/hardlinks inside a temporary parent directory
            // or invoke zip-compatible staging so all items land cleanly at the archive root.
            let stageDir = fm.temporaryDirectory.appendingPathComponent("arbor-zip-\(UUID().uuidString)")
            try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: stageDir) }

            for url in urls {
                let target = stageDir.appendingPathComponent(url.lastPathComponent)
                try fm.copyItem(at: url, to: target)
            }
            try runDitto(arguments: ["-c", "-k", "--sequesterRsrc", stageDir.path, destination.path])
            return destination
        }.value
    }

    static func extract(archiveURL: URL, in directory: URL) async throws -> URL {
        guard ArchiveNameResolver.isSupportedArchive(archiveURL) else {
            throw ArchiveServiceError.unsupportedArchive(archiveURL.lastPathComponent)
        }
        let destination = ArchiveNameResolver.uniqueExtractionURL(for: archiveURL, in: directory)

        return try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            do {
                try runDitto(arguments: ["-x", "-k", archiveURL.path, destination.path])
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            return destination
        }.value
    }

    private static func runDitto(arguments: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = arguments
        let stderr = Pipe()
        proc.standardError = stderr
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ArchiveServiceError.dittoFailed(msg)
        }
    }
}
