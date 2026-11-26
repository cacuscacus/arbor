import Foundation
import Observation

/// Coordinates active file transfer jobs across windows so slow local copies
/// and remote SFTP transfers surface a Finder-style floating progress HUD with
/// an explicit Cancel button (delayed 350 ms to avoid flicker on instant moves).
@MainActor
@Observable
final class TransferProgressStore {
    static let shared = TransferProgressStore()

    struct Job: Identifiable {
        let id: UUID
        let title: String
        let operation: FileTransferOperation
        let totalItems: Int
        var completedItems: Int
        var currentItemName: String?
        var completedBytes: Int64?
        var totalBytes: Int64?
        var isVisible: Bool
        var isCancelling: Bool

        var fractionCompleted: Double? {
            TransferProgressFormatter.fractionCompleted(
                completedItems: completedItems,
                totalItems: totalItems,
                completedBytes: completedBytes,
                totalBytes: totalBytes
            )
        }

        var subtitle: String {
            TransferProgressFormatter.subtitle(
                completedItems: completedItems,
                totalItems: totalItems,
                currentItemName: currentItemName,
                completedBytes: completedBytes,
                totalBytes: totalBytes,
                isCancelling: isCancelling
            )
        }
    }

    private(set) var jobs: [Job] = []
    private var cancelHandlers: [UUID: () -> Void] = [:]
    private var revealTasks: [UUID: Task<Void, Never>] = [:]

    private init() {}

    var visibleJobs: [Job] {
        jobs.filter(\.isVisible)
    }

    @discardableResult
    func beginJob(
        title: String,
        operation: FileTransferOperation,
        totalItems: Int,
        totalBytes: Int64? = nil,
        onCancel: @escaping () -> Void
    ) -> UUID {
        let id = UUID()
        let showNow = TransferProgressFormatter.shouldRevealImmediately(
            totalItems: totalItems,
            totalBytes: totalBytes
        )
        let job = Job(
            id: id,
            title: title,
            operation: operation,
            totalItems: max(1, totalItems),
            completedItems: 0,
            currentItemName: nil,
            completedBytes: totalBytes != nil ? 0 : nil,
            totalBytes: totalBytes,
            isVisible: showNow,
            isCancelling: false
        )
        jobs.append(job)
        cancelHandlers[id] = onCancel

        if !showNow {
            let delayNs = UInt64(TransferProgressFormatter.delayedRevealThreshold * 1_000_000_000)
            revealTasks[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delayNs)
                guard !Task.isCancelled, let self else { return }
                if let index = self.jobs.firstIndex(where: { $0.id == id }) {
                    self.jobs[index].isVisible = true
                }
            }
        }
        return id
    }

    func updateJob(
        _ id: UUID,
        completedItems: Int? = nil,
        currentItemName: String? = nil,
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if let completedItems {
            jobs[index].completedItems = completedItems
        }
        if let currentItemName {
            jobs[index].currentItemName = currentItemName
        }
        if let completedBytes {
            jobs[index].completedBytes = completedBytes
        }
        if let totalBytes {
            jobs[index].totalBytes = totalBytes
        }
    }

    func cancelJob(_ id: UUID) {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            jobs[index].isCancelling = true
        }
        cancelHandlers[id]?()
    }

    func finishJob(_ id: UUID) {
        revealTasks.removeValue(forKey: id)?.cancel()
        cancelHandlers.removeValue(forKey: id)
        jobs.removeAll { $0.id == id }
    }
}
