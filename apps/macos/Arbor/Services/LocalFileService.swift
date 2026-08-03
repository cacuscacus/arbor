import Foundation

struct FileEntry: Identifiable, Hashable {
    let id: URL
    let name: String
    let isDirectory: Bool
    let size: UInt64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

/// Temporary Swift-side listing until `arbor-ffi` is linked into the app.
enum LocalFileService {
    static func list(path: URL) throws -> [FileEntry] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .fileSizeKey,
            .isHiddenKey,
            .nameKey,
        ]

        let contents = try FileManager.default.contentsOfDirectory(
            at: path,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )

        var entries: [FileEntry] = contents.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            let size = UInt64(values?.fileSize ?? 0)
            return FileEntry(
                id: url,
                name: url.lastPathComponent,
                isDirectory: isDir,
                size: size
            )
        }

        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return entries
    }
}
