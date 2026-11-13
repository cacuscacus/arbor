import Foundation

/// Provider-neutral request context for terminals, agents, and external tools.
/// Phase 6a resolves only intrinsic local contexts; SSH execution is added in 6d.
struct ExecutionContext: Hashable, Sendable {
    let workingDirectory: ItemRef
    let selection: [ItemRef]

    nonisolated init(workingDirectory: ItemRef, selection: [ItemRef] = []) {
        self.workingDirectory = workingDirectory
        self.selection = selection
    }

    nonisolated var intrinsicLocalDirectoryURL: URL? {
        FileProviderRegistry.shared.intrinsicLocalURL(for: workingDirectory)
    }

    nonisolated var intrinsicLocalSelectionURLs: [URL]? {
        let urls = selection.compactMap {
            FileProviderRegistry.shared.intrinsicLocalURL(for: $0)
        }
        return urls.count == selection.count ? urls : nil
    }

    nonisolated var supportsLocalExecution: Bool {
        intrinsicLocalDirectoryURL != nil && intrinsicLocalSelectionURLs != nil
    }
}
