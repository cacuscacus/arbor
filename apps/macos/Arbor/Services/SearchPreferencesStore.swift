import Foundation
import Observation

/// User-configurable search guardrails and progressive-scoping preferences.
/// Persisted in `UserDefaults` so Settings → Search and every browser pane stay in sync.
@MainActor
@Observable
final class SearchPreferencesStore {
    static let shared = SearchPreferencesStore()

    var resultLimit: Int {
        didSet {
            let clamped = max(1, resultLimit)
            if clamped != resultLimit { resultLimit = clamped; return }
            defaults.set(resultLimit, forKey: Keys.resultLimit)
        }
    }

    var timeoutSeconds: Double {
        didSet {
            let clamped = max(1, timeoutSeconds)
            if clamped != timeoutSeconds { timeoutSeconds = clamped; return }
            defaults.set(timeoutSeconds, forKey: Keys.timeoutSeconds)
        }
    }

    var maxVisitedNodes: Int {
        didSet {
            let clamped = max(1_000, maxVisitedNodes)
            if clamped != maxVisitedNodes { maxVisitedNodes = clamped; return }
            defaults.set(maxVisitedNodes, forKey: Keys.maxVisitedNodes)
        }
    }

    /// `0` means unlimited depth.
    var maxDepth: Int {
        didSet {
            let clamped = max(0, maxDepth)
            if clamped != maxDepth { maxDepth = clamped; return }
            defaults.set(maxDepth, forKey: Keys.maxDepth)
        }
    }

    var progressiveScoping: Bool {
        didSet { defaults.set(progressiveScoping, forKey: Keys.progressiveScoping) }
    }

    var openGlobalInNewTab: Bool {
        didSet { defaults.set(openGlobalInNewTab, forKey: Keys.openGlobalInNewTab) }
    }

    var excludedNames: [String] {
        didSet { defaults.set(excludedNames, forKey: Keys.excludedNames) }
    }

    var excludedGlobalRelativePaths: [String] {
        didSet { defaults.set(excludedGlobalRelativePaths, forKey: Keys.excludedGlobalRelativePaths) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        resultLimit = defaults.object(forKey: Keys.resultLimit) as? Int ?? SearchOptions.defaultResultLimit
        timeoutSeconds = defaults.object(forKey: Keys.timeoutSeconds) as? Double ?? SearchOptions.defaultTimeoutSeconds
        maxVisitedNodes = defaults.object(forKey: Keys.maxVisitedNodes) as? Int ?? SearchOptions.defaultMaxVisitedNodes
        maxDepth = defaults.object(forKey: Keys.maxDepth) as? Int ?? 0
        progressiveScoping = defaults.object(forKey: Keys.progressiveScoping) as? Bool ?? true
        openGlobalInNewTab = defaults.object(forKey: Keys.openGlobalInNewTab) as? Bool ?? false
        excludedNames = defaults.stringArray(forKey: Keys.excludedNames) ?? SearchOptions.defaultExcludedNames
        excludedGlobalRelativePaths = defaults.stringArray(forKey: Keys.excludedGlobalRelativePaths)
            ?? SearchOptions.defaultExcludedGlobalRelativePaths
    }

    func makeOptions(
        showHiddenFiles: Bool,
        resultLimitOverride: Int? = nil,
        timeoutOverride: Double? = nil
    ) -> SearchOptions {
        SearchOptions(
            resultLimit: resultLimitOverride ?? resultLimit,
            timeoutSeconds: timeoutOverride ?? timeoutSeconds,
            maxVisitedNodes: maxVisitedNodes,
            maxDepth: maxDepth > 0 ? maxDepth : nil,
            progressiveScoping: progressiveScoping,
            excludedNames: excludedNames,
            excludedGlobalRelativePaths: excludedGlobalRelativePaths,
            showHiddenFiles: showHiddenFiles
        )
    }

    func resetDefaults() {
        resultLimit = SearchOptions.defaultResultLimit
        timeoutSeconds = SearchOptions.defaultTimeoutSeconds
        maxVisitedNodes = SearchOptions.defaultMaxVisitedNodes
        maxDepth = 0
        progressiveScoping = true
        openGlobalInNewTab = false
        excludedNames = SearchOptions.defaultExcludedNames
        excludedGlobalRelativePaths = SearchOptions.defaultExcludedGlobalRelativePaths
    }

    static func parseCSVList(_ text: String) -> [String] {
        text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func formatCSVList(_ items: [String]) -> String {
        items.joined(separator: ", ")
    }

    private enum Keys {
        static let resultLimit = "arbor.search.resultLimit"
        static let timeoutSeconds = "arbor.search.timeoutSeconds"
        static let maxVisitedNodes = "arbor.search.maxVisitedNodes"
        static let maxDepth = "arbor.search.maxDepth"
        static let progressiveScoping = "arbor.search.progressiveScoping"
        static let openGlobalInNewTab = "arbor.search.openGlobalInNewTab"
        static let excludedNames = "arbor.search.excludedNames"
        static let excludedGlobalRelativePaths = "arbor.search.excludedGlobalRelativePaths"
    }
}
