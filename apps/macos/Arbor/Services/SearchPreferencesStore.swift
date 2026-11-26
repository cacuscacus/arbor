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

    /// Max file size (MB) scanned in content search (`0` = unlimited).
    var maxContentFileSizeMB: Int {
        didSet {
            let clamped = max(0, maxContentFileSizeMB)
            if clamped != maxContentFileSizeMB { maxContentFileSizeMB = clamped; return }
            defaults.set(maxContentFileSizeMB, forKey: Keys.maxContentFileSizeMB)
        }
    }

    var respectGitignoreInContent: Bool {
        didSet { defaults.set(respectGitignoreInContent, forKey: Keys.respectGitignoreInContent) }
    }

    var maxMatchesPerFile: Int {
        didSet {
            let clamped = max(1, maxMatchesPerFile)
            if clamped != maxMatchesPerFile { maxMatchesPerFile = clamped; return }
            defaults.set(maxMatchesPerFile, forKey: Keys.maxMatchesPerFile)
        }
    }

    var deepGlobalContentScan: Bool {
        didSet { defaults.set(deepGlobalContentScan, forKey: Keys.deepGlobalContentScan) }
    }

    var excludedNames: [String] {
        didSet { defaults.set(excludedNames, forKey: Keys.excludedNames) }
    }

    var excludedGlobalRelativePaths: [String] {
        didSet { defaults.set(excludedGlobalRelativePaths, forKey: Keys.excludedGlobalRelativePaths) }
    }

    // MARK: - Opt-in Local MLX Smart Expansion (OFF by default)

    var smartExpansionEnabled: Bool {
        didSet { defaults.set(smartExpansionEnabled, forKey: Keys.smartExpansionEnabled) }
    }

    var smartExpansionModelPreset: SearchExpansionModelPreset {
        didSet { defaults.set(smartExpansionModelPreset.rawValue, forKey: Keys.smartExpansionModelPreset) }
    }

    var smartExpansionCustomModelID: String {
        didSet { defaults.set(smartExpansionCustomModelID, forKey: Keys.smartExpansionCustomModelID) }
    }

    /// Minutes of inactivity before the isolated MLX helper unloads weights (`0` = keep loaded).
    var smartExpansionIdleUnloadMinutes: Int {
        didSet {
            let clamped = max(0, smartExpansionIdleUnloadMinutes)
            if clamped != smartExpansionIdleUnloadMinutes { smartExpansionIdleUnloadMinutes = clamped; return }
            defaults.set(smartExpansionIdleUnloadMinutes, forKey: Keys.smartExpansionIdleUnloadMinutes)
        }
    }

    /// Optional explicit path to a Python binary with `mlx_lm` installed (empty = auto-detect).
    var smartExpansionPythonPath: String {
        didSet { defaults.set(smartExpansionPythonPath, forKey: Keys.smartExpansionPythonPath) }
    }

    var resolvedSmartExpansionModelID: String {
        if smartExpansionModelPreset == .custom {
            let custom = smartExpansionCustomModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            return custom.isEmpty ? SearchExpansionModelPreset.balanced2B8Bit.rawValue : custom
        }
        return smartExpansionModelPreset.rawValue
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
        maxContentFileSizeMB = defaults.object(forKey: Keys.maxContentFileSizeMB) as? Int
            ?? SearchOptions.defaultMaxContentFileSizeMB
        respectGitignoreInContent = defaults.object(forKey: Keys.respectGitignoreInContent) as? Bool ?? true
        maxMatchesPerFile = defaults.object(forKey: Keys.maxMatchesPerFile) as? Int
            ?? SearchOptions.defaultMaxMatchesPerFile
        deepGlobalContentScan = defaults.object(forKey: Keys.deepGlobalContentScan) as? Bool ?? false
        excludedNames = defaults.stringArray(forKey: Keys.excludedNames) ?? SearchOptions.defaultExcludedNames
        excludedGlobalRelativePaths = defaults.stringArray(forKey: Keys.excludedGlobalRelativePaths)
            ?? SearchOptions.defaultExcludedGlobalRelativePaths
        smartExpansionEnabled = defaults.object(forKey: Keys.smartExpansionEnabled) as? Bool ?? false
        if let rawPreset = defaults.string(forKey: Keys.smartExpansionModelPreset),
           let parsed = SearchExpansionModelPreset(rawValue: rawPreset)
        {
            smartExpansionModelPreset = parsed
        } else {
            smartExpansionModelPreset = .balanced2B8Bit
        }
        smartExpansionCustomModelID = defaults.string(forKey: Keys.smartExpansionCustomModelID) ?? ""
        smartExpansionIdleUnloadMinutes = defaults.object(forKey: Keys.smartExpansionIdleUnloadMinutes) as? Int ?? 5
        smartExpansionPythonPath = defaults.string(forKey: Keys.smartExpansionPythonPath) ?? ""
    }

    func makeOptions(
        showHiddenFiles: Bool,
        resultLimitOverride: Int? = nil,
        timeoutOverride: Double? = nil,
        deepGlobalContentOverride: Bool? = nil,
        expandedTerms: [String] = []
    ) -> SearchOptions {
        SearchOptions(
            resultLimit: resultLimitOverride ?? resultLimit,
            timeoutSeconds: timeoutOverride ?? timeoutSeconds,
            maxVisitedNodes: maxVisitedNodes,
            maxDepth: maxDepth > 0 ? maxDepth : nil,
            progressiveScoping: progressiveScoping,
            excludedNames: excludedNames,
            excludedGlobalRelativePaths: excludedGlobalRelativePaths,
            showHiddenFiles: showHiddenFiles,
            maxContentFileSizeMB: maxContentFileSizeMB,
            respectGitignoreInContent: respectGitignoreInContent,
            maxMatchesPerFile: maxMatchesPerFile,
            deepGlobalContentScan: deepGlobalContentOverride ?? deepGlobalContentScan,
            expandedTerms: expandedTerms
        )
    }

    func resetDefaults() {
        resultLimit = SearchOptions.defaultResultLimit
        timeoutSeconds = SearchOptions.defaultTimeoutSeconds
        maxVisitedNodes = SearchOptions.defaultMaxVisitedNodes
        maxDepth = 0
        progressiveScoping = true
        openGlobalInNewTab = false
        maxContentFileSizeMB = SearchOptions.defaultMaxContentFileSizeMB
        respectGitignoreInContent = true
        maxMatchesPerFile = SearchOptions.defaultMaxMatchesPerFile
        deepGlobalContentScan = false
        excludedNames = SearchOptions.defaultExcludedNames
        excludedGlobalRelativePaths = SearchOptions.defaultExcludedGlobalRelativePaths
        smartExpansionEnabled = false
        smartExpansionModelPreset = .balanced2B8Bit
        smartExpansionCustomModelID = ""
        smartExpansionIdleUnloadMinutes = 5
        smartExpansionPythonPath = ""
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
        static let maxContentFileSizeMB = "arbor.search.maxContentFileSizeMB"
        static let respectGitignoreInContent = "arbor.search.respectGitignoreInContent"
        static let maxMatchesPerFile = "arbor.search.maxMatchesPerFile"
        static let deepGlobalContentScan = "arbor.search.deepGlobalContentScan"
        static let excludedNames = "arbor.search.excludedNames"
        static let excludedGlobalRelativePaths = "arbor.search.excludedGlobalRelativePaths"
        static let smartExpansionEnabled = "arbor.search.smartExpansionEnabled"
        static let smartExpansionModelPreset = "arbor.search.smartExpansionModelPreset"
        static let smartExpansionCustomModelID = "arbor.search.smartExpansionCustomModelID"
        static let smartExpansionIdleUnloadMinutes = "arbor.search.smartExpansionIdleUnloadMinutes"
        static let smartExpansionPythonPath = "arbor.search.smartExpansionPythonPath"
    }
}
