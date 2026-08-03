import Foundation
import AppKit

/// One reversible filesystem change recorded by Arbor.
enum ArborUndoCommand: Equatable {
    /// Items were moved from `from` → `to`. Undo moves them back.
    case move([(from: URL, to: URL)])
    /// Items were copied from `from` → `to`. Undo trashes the copies at `to`.
    case copy([(from: URL, to: URL)])
    /// A new item was created. Undo trashes it; redo recreates an empty item.
    case create(url: URL, isDirectory: Bool)
    /// Item was renamed from → to. Undo/redo renames back and forth.
    case rename(from: URL, to: URL)

    var actionName: String {
        switch self {
        case .move: return "Move"
        case .copy: return "Copy"
        case .create: return "Create"
        case .rename: return "Rename"
        }
    }

    static func == (lhs: ArborUndoCommand, rhs: ArborUndoCommand) -> Bool {
        switch (lhs, rhs) {
        case (.move(let a), .move(let b)):
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { $0.from == $1.from && $0.to == $1.to }
        case (.copy(let a), .copy(let b)):
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { $0.from == $1.from && $0.to == $1.to }
        case (.create(let a, let ad), .create(let b, let bd)):
            return a == b && ad == bd
        case (.rename(let aFrom, let aTo), .rename(let bFrom, let bTo)):
            return aFrom == bFrom && aTo == bTo
        default:
            return false
        }
    }
}

struct ArborUndoApplyResult {
    var restoredSelection: Set<URL> = []
    var errorMessage: String?
}

@Observable
final class ArborUndoStack {
    private(set) var undoCommands: [ArborUndoCommand] = []
    private(set) var redoCommands: [ArborUndoCommand] = []

    var canUndo: Bool { !undoCommands.isEmpty }
    var canRedo: Bool { !redoCommands.isEmpty }

    var undoActionName: String {
        undoCommands.last.map { "Undo \($0.actionName)" } ?? "Undo"
    }

    var redoActionName: String {
        redoCommands.last.map { "Redo \($0.actionName)" } ?? "Redo"
    }

    func register(_ command: ArborUndoCommand) {
        switch command {
        case .move(let pairs), .copy(let pairs):
            guard !pairs.isEmpty else { return }
        case .create, .rename:
            break
        }
        undoCommands.append(command)
        redoCommands.removeAll()
    }

    @discardableResult
    func undo() -> ArborUndoApplyResult {
        guard let command = undoCommands.popLast() else {
            return ArborUndoApplyResult()
        }
        let result = invert(command)
        if result.errorMessage == nil {
            // For create, keep the original path/kind so redo can recreate it.
            redoCommands.append(command)
        } else {
            undoCommands.append(command)
        }
        return result
    }

    @discardableResult
    func redo() -> ArborUndoApplyResult {
        guard let command = redoCommands.popLast() else {
            return ArborUndoApplyResult()
        }
        let result = apply(command)
        if result.errorMessage == nil {
            // If create was recreated at a different unique path, register that.
            if case .create = command, let newURL = result.restoredSelection.first {
                let isDirectory: Bool
                if case .create(_, let dir) = command {
                    isDirectory = dir
                } else {
                    isDirectory = false
                }
                undoCommands.append(.create(url: newURL, isDirectory: isDirectory))
            } else if case .rename(let from, let to) = command,
                      let newURL = result.restoredSelection.first,
                      newURL != to
            {
                // Destination was adjusted (name conflict); keep undo accurate.
                undoCommands.append(.rename(from: from, to: newURL))
            } else {
                undoCommands.append(command)
            }
        } else {
            redoCommands.append(command)
        }
        return result
    }

    // MARK: - Apply / invert

    private func apply(_ command: ArborUndoCommand) -> ArborUndoApplyResult {
        switch command {
        case .move(let pairs):
            return transferPairs(pairs, operation: .move)
        case .copy(let pairs):
            return transferPairs(pairs, operation: .copy)
        case .create(let url, let isDirectory):
            return recreate(at: url, isDirectory: isDirectory)
        case .rename(let from, let to):
            return transferPairs([(from: from, to: to)], operation: .move)
        }
    }

    private func invert(_ command: ArborUndoCommand) -> ArborUndoApplyResult {
        switch command {
        case .move(let pairs):
            let reversed = pairs.map { (from: $0.to, to: $0.from) }
            return transferPairs(reversed, operation: .move)
        case .copy(let pairs):
            return trashURLs(pairs.map(\.to))
        case .create(let url, _):
            return trashURLs([url])
        case .rename(let from, let to):
            return transferPairs([(from: to, to: from)], operation: .move)
        }
    }

    private func recreate(at url: URL, isDirectory: Bool) -> ArborUndoApplyResult {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        do {
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: parent.path, isDirectory: &isDir) || !isDir.boolValue {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }

            let target: URL
            if fm.fileExists(atPath: url.path) {
                target = uniqueURL(
                    in: parent,
                    preferredName: url.lastPathComponent,
                    fileManager: fm
                )
            } else {
                target = url
            }

            if isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: false)
            } else {
                let ok = fm.createFile(atPath: target.path, contents: Data(), attributes: nil)
                if !ok { throw CocoaError(.fileWriteUnknown) }
            }
            return ArborUndoApplyResult(restoredSelection: [target])
        } catch {
            return ArborUndoApplyResult(errorMessage: error.localizedDescription)
        }
    }

    private func transferPairs(
        _ pairs: [(from: URL, to: URL)],
        operation: FileTransferOperation
    ) -> ArborUndoApplyResult {
        var restored: Set<URL> = []
        var failures: [String] = []
        let fm = FileManager.default

        for pair in pairs {
            let source = pair.from.standardizedFileURL
            let destination = pair.to.standardizedFileURL
            let destinationParent = destination.deletingLastPathComponent()

            do {
                var isDir: ObjCBool = false
                if !fm.fileExists(atPath: destinationParent.path, isDirectory: &isDir) || !isDir.boolValue {
                    try fm.createDirectory(at: destinationParent, withIntermediateDirectories: true)
                }

                // If something already occupies the destination, pick a unique name
                // in that folder (keeps undo usable even if the tree changed).
                let finalDestination: URL
                if fm.fileExists(atPath: destination.path) {
                    finalDestination = uniqueURL(
                        in: destinationParent,
                        preferredName: destination.lastPathComponent,
                        fileManager: fm
                    )
                } else {
                    finalDestination = destination
                }

                switch operation {
                case .move:
                    try fm.moveItem(at: source, to: finalDestination)
                case .copy:
                    try fm.copyItem(at: source, to: finalDestination)
                }
                restored.insert(finalDestination)
            } catch {
                failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }

        var result = ArborUndoApplyResult(restoredSelection: restored)
        if !failures.isEmpty {
            result.errorMessage = failures.joined(separator: "\n")
        }
        return result
    }

    private func trashURLs(_ urls: [URL]) -> ArborUndoApplyResult {
        var failures: [String] = []
        let fm = FileManager.default

        for url in urls {
            do {
                var resulting: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &resulting)
            } catch {
                // Fallback to delete if trash isn't available for this volume.
                do {
                    try fm.removeItem(at: url)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        var result = ArborUndoApplyResult()
        if !failures.isEmpty {
            result.errorMessage = failures.joined(separator: "\n")
        }
        return result
    }

    private func uniqueURL(
        in directory: URL,
        preferredName: String,
        fileManager: FileManager
    ) -> URL {
        var candidate = directory.appendingPathComponent(preferredName)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let nsName = preferredName as NSString
        let base = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        var index = 1
        repeat {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            let name = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
            candidate = directory.appendingPathComponent(name)
            index += 1
        } while fileManager.fileExists(atPath: candidate.path)
        return candidate
    }
}
