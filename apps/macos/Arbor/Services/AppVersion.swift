import Foundation

/// SemVer-ish marketing version helpers for update checks.
///
/// Numeric dotted components are compared left-to-right; missing components are
/// treated as `0` (so `"1.1"` equals `"1.1.0"`). A leading `v`/`V` is stripped.
/// Pre-release / build metadata after `-` or `+` is ignored for ordering.
enum AppVersion {
    /// Compare two marketing / tag version strings.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let left = numericComponents(a)
        let right = numericComponents(b)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs < rhs { return .orderedAscending }
            if lhs > rhs { return .orderedDescending }
        }
        return .orderedSame
    }

    /// Strip a leading `v`/`V` and any pre-release / build suffix.
    static func normalizedCore(_ version: String) -> String {
        numericComponents(version).map(String.init).joined(separator: ".")
    }

    /// Tag / version string with a single leading `v`/`V` removed (if present).
    static func strippingVPrefix(_ version: String) -> String {
        var trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "v" || trimmed.first == "V" {
            trimmed.removeFirst()
        }
        return trimmed
    }

    private static func numericComponents(_ version: String) -> [Int] {
        var core = strippingVPrefix(version)
        if let dash = core.firstIndex(of: "-") {
            core = String(core[..<dash])
        }
        if let plus = core.firstIndex(of: "+") {
            core = String(core[..<plus])
        }
        return core.split(separator: ".", omittingEmptySubsequences: false).map { part in
            Int(part.filter(\.isNumber)) ?? 0
        }
    }

    #if DEBUG
    /// Assertion-based checks; called from update-check in Debug builds.
    static func runSelfChecks() {
        precondition(compare("1.1", "1.1.0") == .orderedSame)
        precondition(compare("v1.2.0", "1.2.0") == .orderedSame)
        precondition(compare("1.2.0", "1.3.0") == .orderedAscending)
        precondition(compare("1.10.0", "1.9.0") == .orderedDescending)
        precondition(compare("1.2.0-beta", "1.2.0") == .orderedSame)
        precondition(compare("2.0", "1.9.9") == .orderedDescending)
        precondition(compare("1.0.0", "1.0.0+build.1") == .orderedSame)
    }
    #endif
}
