import Foundation

/// Interpreted filename query: plain substring or shell-style glob (`*`, `?`, `[…]`).
nonisolated struct FilenameSearchPattern: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// Case-insensitive substring of the filename (current default UX).
        case substring(String)
        /// Filename glob, e.g. `blabla*.json`, `*.md`, `report-??.txt`.
        case glob(String)
    }

    let kind: Kind

    init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.containsGlobMetacharacters(trimmed) {
            kind = .glob(trimmed)
        } else {
            kind = .substring(trimmed)
        }
    }

    private init(kind: Kind) {
        self.kind = kind
    }

    var literalText: String {
        switch kind {
        case .substring(let text), .glob(let text):
            return text
        }
    }

    /// Same text interpreted as a literal substring. A real filename such as
    /// `corchetes[1].txt` is otherwise treated as a glob character class and
    /// becomes unsearchable by its own name.
    var literalFallback: FilenameSearchPattern {
        switch kind {
        case .substring:
            return self
        case .glob:
            return FilenameSearchPattern(kind: .substring(literalText))
        }
    }

    var isEmpty: Bool {
        switch kind {
        case .substring(let s), .glob(let s):
            return s.isEmpty
        }
    }

    /// `true` when the query uses `*`, `?`, or a character class.
    var isGlob: Bool {
        if case .glob = kind { return true }
        return false
    }

    private static func containsGlobMetacharacters(_ value: String) -> Bool {
        var inClass = false
        for scalar in value.unicodeScalars {
            switch scalar {
            case "*", "?":
                if !inClass { return true }
            case "[":
                inClass = true
            case "]":
                if inClass { return true }
            default:
                break
            }
        }
        return false
    }
}
