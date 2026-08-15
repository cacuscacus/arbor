import Foundation

struct QuickDiffDocument: Sendable {
    let leftURL: URL
    let rightURL: URL
    let rows: [QuickDiffRow]
    let addedCount: Int
    let removedCount: Int
    let changedCount: Int
}

struct QuickDiffRow: Identifiable, Sendable {
    enum Kind: Sendable {
        case unchanged
        case added
        case removed
        case changed
    }

    let id: Int
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let oldText: String?
    let newText: String?
    let kind: Kind
}

enum QuickDiffError: LocalizedError, Sendable {
    case directory
    case unreadable(String)
    case tooLarge(String, Int)
    case tooManyLines(String, Int)
    case binary(String)
    case unsupportedEncoding(String)

    var errorDescription: String? {
        switch self {
        case .directory:
            return "Quick Diff compares files, not folders."
        case .unreadable(let name):
            return "Could not read “\(name)”."
        case .tooLarge(let name, let limitMB):
            return "“\(name)” is larger than the \(limitMB) MB Quick Diff limit."
        case .tooManyLines(let name, let limit):
            return "“\(name)” has more than \(limit.formatted()) lines."
        case .binary(let name):
            return "“\(name)” appears to be binary. Quick Diff currently supports text files."
        case .unsupportedEncoding(let name):
            return "“\(name)” is not valid UTF-8 text."
        }
    }
}

enum QuickDiffService {
    nonisolated static let maximumBytes = 2 * 1024 * 1024
    // Keeps worst-case (completely different files) comparisons responsive.
    nonisolated static let maximumLines = 10_000

    nonisolated static func compare(left: URL, right: URL) async throws -> QuickDiffDocument {
        try await Task.detached(priority: .userInitiated) {
            let leftLines = try readLines(from: left)
            try Task.checkCancellation()
            let rightLines = try readLines(from: right)
            try Task.checkCancellation()
            return buildDocument(
                leftURL: left,
                rightURL: right,
                oldLines: leftLines,
                newLines: rightLines
            )
        }.value
    }

    nonisolated private static func readLines(from url: URL) throws -> [String] {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true {
            throw QuickDiffError.directory
        }
        if let size = values?.fileSize, size > maximumBytes {
            throw QuickDiffError.tooLarge(url.lastPathComponent, maximumBytes / 1024 / 1024)
        }

        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw QuickDiffError.unreadable(url.lastPathComponent)
        }
        if data.count > maximumBytes {
            throw QuickDiffError.tooLarge(url.lastPathComponent, maximumBytes / 1024 / 1024)
        }
        if data.prefix(8_192).contains(0) {
            throw QuickDiffError.binary(url.lastPathComponent)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw QuickDiffError.unsupportedEncoding(url.lastPathComponent)
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n"), lines.last == "" {
            lines.removeLast()
        }
        if lines.count > maximumLines {
            throw QuickDiffError.tooManyLines(url.lastPathComponent, maximumLines)
        }
        return lines
    }

    nonisolated private static func buildDocument(
        leftURL: URL,
        rightURL: URL,
        oldLines: [String],
        newLines: [String]
    ) -> QuickDiffDocument {
        let difference = newLines.difference(from: oldLines)
        var removals: [Int: String] = [:]
        var insertions: [Int: String] = [:]

        for change in difference {
            switch change {
            case .remove(let offset, let element, _):
                removals[offset] = element
            case .insert(let offset, let element, _):
                insertions[offset] = element
            }
        }

        var rows: [QuickDiffRow] = []
        rows.reserveCapacity(max(oldLines.count, newLines.count))
        var oldIndex = 0
        var newIndex = 0
        var added = 0
        var removed = 0
        var changed = 0

        while oldIndex < oldLines.count || newIndex < newLines.count {
            let removedText = removals[oldIndex]
            let insertedText = insertions[newIndex]

            if let removedText, let insertedText {
                rows.append(QuickDiffRow(
                    id: rows.count,
                    oldLineNumber: oldIndex + 1,
                    newLineNumber: newIndex + 1,
                    oldText: removedText,
                    newText: insertedText,
                    kind: .changed
                ))
                oldIndex += 1
                newIndex += 1
                changed += 1
            } else if let removedText {
                rows.append(QuickDiffRow(
                    id: rows.count,
                    oldLineNumber: oldIndex + 1,
                    newLineNumber: nil,
                    oldText: removedText,
                    newText: nil,
                    kind: .removed
                ))
                oldIndex += 1
                removed += 1
            } else if let insertedText {
                rows.append(QuickDiffRow(
                    id: rows.count,
                    oldLineNumber: nil,
                    newLineNumber: newIndex + 1,
                    oldText: nil,
                    newText: insertedText,
                    kind: .added
                ))
                newIndex += 1
                added += 1
            } else if oldIndex < oldLines.count, newIndex < newLines.count {
                rows.append(QuickDiffRow(
                    id: rows.count,
                    oldLineNumber: oldIndex + 1,
                    newLineNumber: newIndex + 1,
                    oldText: oldLines[oldIndex],
                    newText: newLines[newIndex],
                    kind: .unchanged
                ))
                oldIndex += 1
                newIndex += 1
            } else if oldIndex < oldLines.count {
                let text = oldLines[oldIndex]
                rows.append(QuickDiffRow(
                    id: rows.count,
                    oldLineNumber: oldIndex + 1,
                    newLineNumber: nil,
                    oldText: text,
                    newText: nil,
                    kind: .removed
                ))
                oldIndex += 1
                removed += 1
            } else if newIndex < newLines.count {
                let text = newLines[newIndex]
                rows.append(QuickDiffRow(
                    id: rows.count,
                    oldLineNumber: nil,
                    newLineNumber: newIndex + 1,
                    oldText: nil,
                    newText: text,
                    kind: .added
                ))
                newIndex += 1
                added += 1
            }
        }

        return QuickDiffDocument(
            leftURL: leftURL,
            rightURL: rightURL,
            rows: rows,
            addedCount: added,
            removedCount: removed,
            changedCount: changed
        )
    }
}
