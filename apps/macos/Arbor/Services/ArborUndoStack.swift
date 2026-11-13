import Foundation

/// One reversible filesystem change recorded by Arbor.
enum ArborUndoCommand: Equatable {
    /// Items were moved from `from` → `to`. Undo moves them back.
    case move([(from: ItemRef, to: ItemRef)])
    /// Items were copied from `from` → `to`. Undo trashes the copies at `to`.
    case copy([(from: ItemRef, to: ItemRef)])
    /// A new item was created. Undo trashes it; redo recreates an empty item.
    case create(item: ItemRef, isDirectory: Bool)
    /// Item was renamed from → to. Undo/redo renames back and forth.
    case rename(from: ItemRef, to: ItemRef)
    /// Items were moved to Trash (`from` → `trashItem`). Undo restores when still present.
    case trash([(from: ItemRef, trashItem: ItemRef)])

    var actionName: String {
        switch self {
        case .move: return "Move"
        case .copy: return "Copy"
        case .create: return "Create"
        case .rename: return "Rename"
        case .trash: return "Move to Trash"
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
        case (.trash(let a), .trash(let b)):
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { $0.from == $1.from && $0.trashItem == $1.trashItem }
        default:
            return false
        }
    }
}

struct ArborUndoApplyResult {
    var restoredSelection: Set<ItemRef> = []
    var errorMessage: String?
    /// When redo/apply of `.trash` produces new Trash refs, the updated command to push undo.
    var rewrittenCommand: ArborUndoCommand?
    /// Parent folders whose listings may be stale after this apply/invert.
    var affectedFolders: [ItemRef] = []
}

@Observable
final class ArborUndoStack {
    private(set) var undoCommands: [ArborUndoCommand] = []
    private(set) var redoCommands: [ArborUndoCommand] = []
    private(set) var isApplying = false

    var canUndo: Bool { !isApplying && !undoCommands.isEmpty }
    var canRedo: Bool { !isApplying && !redoCommands.isEmpty }

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
        case .trash(let pairs):
            guard !pairs.isEmpty else { return }
        case .create, .rename:
            break
        }
        undoCommands.append(command)
        redoCommands.removeAll()
    }

    @discardableResult
    func undo() async -> ArborUndoApplyResult {
        guard let command = undoCommands.popLast() else {
            return ArborUndoApplyResult()
        }
        isApplying = true
        defer { isApplying = false }
        let result = await invert(command)
        if result.errorMessage == nil || !result.restoredSelection.isEmpty {
            // Partial restores still consume the undo entry so we don't double-apply.
            redoCommands.append(command)
        } else {
            undoCommands.append(command)
        }
        return result
    }

    @discardableResult
    func redo() async -> ArborUndoApplyResult {
        guard let command = redoCommands.popLast() else {
            return ArborUndoApplyResult()
        }
        isApplying = true
        defer { isApplying = false }
        let result = await apply(command)
        if result.errorMessage == nil
            || result.rewrittenCommand != nil
            || !result.restoredSelection.isEmpty
        {
            if let rewritten = result.rewrittenCommand {
                undoCommands.append(rewritten)
            } else if case .create = command, let newItem = result.restoredSelection.first {
                let isDirectory: Bool
                if case .create(_, let dir) = command {
                    isDirectory = dir
                } else {
                    isDirectory = false
                }
                undoCommands.append(.create(item: newItem, isDirectory: isDirectory))
            } else if case .rename(let from, let to) = command,
                      let newItem = result.restoredSelection.first,
                      newItem != to
            {
                // Destination was adjusted (name conflict); keep undo accurate.
                undoCommands.append(.rename(from: from, to: newItem))
            } else {
                undoCommands.append(command)
            }
        } else {
            redoCommands.append(command)
        }
        return result
    }

    // MARK: - Apply / invert

    private func apply(_ command: ArborUndoCommand) async -> ArborUndoApplyResult {
        switch command {
        case .move(let pairs):
            return await transferPairs(pairs, operation: .move)
        case .copy(let pairs):
            return await transferPairs(pairs, operation: .copy)
        case .create(let item, let isDirectory):
            return await recreate(at: item, isDirectory: isDirectory)
        case .rename(let from, let to):
            return await transferPairs([(from: from, to: to)], operation: .move)
        case .trash(let pairs):
            // After undo, items are back at `from`. Trash them again and remember new trash URLs.
            let result = await trashItemsWithReceipts(pairs.map(\.from))
            var applyResult = ArborUndoApplyResult(
                affectedFolders: pairs.compactMap { $0.from.parent }
            )
            if !result.failed.isEmpty {
                let names = result.failed.map { $0.0.name }.joined(separator: ", ")
                applyResult.errorMessage = result.trashed.isEmpty
                    ? "Could not move to Trash: \(names)"
                    : "Some items could not be moved to Trash: \(names)"
            }
            if !result.trashed.isEmpty {
                applyResult.rewrittenCommand = .trash(result.trashed)
            }
            return applyResult
        }
    }

    private func invert(_ command: ArborUndoCommand) async -> ArborUndoApplyResult {
        switch command {
        case .move(let pairs):
            let reversed = pairs.map { (from: $0.to, to: $0.from) }
            return await transferPairs(reversed, operation: .move)
        case .copy(let pairs):
            return await trashItems(pairs.map(\.to))
        case .create(let item, _):
            return await trashItems([item])
        case .rename(let from, let to):
            return await transferPairs([(from: to, to: from)], operation: .move)
        case .trash(let pairs):
            // Restore from Trash → original locations (if still in Trash).
            let reversed = pairs.map { (from: $0.trashItem, to: $0.from) }
            var result = await transferPairs(reversed, operation: .move)
            if result.restoredSelection.isEmpty, result.errorMessage == nil {
                result.errorMessage = "Items are no longer in the Trash."
            } else if result.restoredSelection.count < pairs.count {
                let missing = pairs.count - result.restoredSelection.count
                let note = "\(missing) item\(missing == 1 ? "" : "s") could not be restored from Trash."
                if let existing = result.errorMessage {
                    result.errorMessage = existing + "\n" + note
                } else {
                    result.errorMessage = note
                }
            }
            return result
        }
    }

    private func recreate(at item: ItemRef, isDirectory: Bool) async -> ArborUndoApplyResult {
        guard let parent = item.parent else {
            return ArborUndoApplyResult(errorMessage: "Cannot recreate the location root.")
        }
        do {
            let provider = try FileProviderRegistry.shared.provider(for: parent)
            let entry: FileProviderEntry
            if isDirectory {
                entry = try await provider.createDirectory(
                    at: item,
                    createParentDirectories: true
                )
            } else {
                entry = try await provider.createFile(
                    at: item,
                    contents: Data(),
                    createParentDirectories: true
                )
            }
            return ArborUndoApplyResult(
                restoredSelection: [entry.id],
                affectedFolders: [parent]
            )
        } catch {
            return ArborUndoApplyResult(errorMessage: error.localizedDescription)
        }
    }

    private func transferPairs(
        _ pairs: [(from: ItemRef, to: ItemRef)],
        operation: FileProviderTransferOperation
    ) async -> ArborUndoApplyResult {
        var restored: Set<ItemRef> = []
        var failures: [String] = []
        var affected: [ItemRef] = []

        for pair in pairs {
            let source = pair.from
            let destination = pair.to
            if let parent = source.parent { affected.append(parent) }
            if let parent = destination.parent { affected.append(parent) }

            do {
                let provider = try FileProviderRegistry.shared.provider(for: source)
                let receipt = try await provider.transfer(
                    source,
                    to: destination,
                    operation: operation,
                    createParentDirectories: true,
                    useUniqueDestination: false
                )
                restored.insert(receipt.to)
            } catch FileProviderError.itemNotFound {
                failures.append("\(source.name): no longer exists")
            } catch {
                failures.append("\(source.name): \(error.localizedDescription)")
            }
        }

        var result = ArborUndoApplyResult(
            restoredSelection: restored,
            affectedFolders: affected
        )
        if !failures.isEmpty {
            result.errorMessage = failures.joined(separator: "\n")
        }
        return result
    }

    private func trashItems(_ items: [ItemRef]) async -> ArborUndoApplyResult {
        var failures: [String] = []
        var affected: [ItemRef] = []

        for item in items {
            if let parent = item.parent { affected.append(parent) }
            do {
                let provider = try FileProviderRegistry.shared.provider(for: item)
                _ = try await provider.trash(item)
            } catch {
                do {
                    let provider = try FileProviderRegistry.shared.provider(for: item)
                    guard provider.volume.capabilities.contains(.remove) else {
                        throw error
                    }
                    try await provider.remove(item)
                } catch {
                    failures.append("\(item.name): \(error.localizedDescription)")
                }
            }
        }

        var result = ArborUndoApplyResult(affectedFolders: affected)
        if !failures.isEmpty {
            result.errorMessage = failures.joined(separator: "\n")
        }
        return result
    }

    private func trashItemsWithReceipts(
        _ items: [ItemRef]
    ) async -> (
        trashed: [(from: ItemRef, trashItem: ItemRef)],
        failed: [(ItemRef, Error)]
    ) {
        var trashed: [(from: ItemRef, trashItem: ItemRef)] = []
        var failed: [(ItemRef, Error)] = []

        for item in items {
            do {
                let provider = try FileProviderRegistry.shared.provider(for: item)
                let receipt = try await provider.trash(item)
                if let trashItem = receipt.trashedItem {
                    trashed.append((from: item, trashItem: trashItem))
                } else {
                    failed.append((
                        item,
                        FileProviderError.operationFailed(
                            item: item,
                            message: "The Trash did not return a restorable item."
                        )
                    ))
                }
            } catch {
                failed.append((item, error))
            }
        }
        return (trashed, failed)
    }
}
