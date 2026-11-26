import Foundation

/// High-level semantic file kinds for `kind:` structured search filters.
nonisolated enum SearchFileKind: String, CaseIterable, Hashable, Sendable {
    case folder
    case file
    case image
    case video
    case audio
    case pdf
    case document
    case code
    case archive
    case app

    var displayName: String {
        switch self {
        case .folder: return "Folder"
        case .file: return "File"
        case .image: return "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .pdf: return "PDF"
        case .document: return "Document"
        case .code: return "Code"
        case .archive: return "Archive"
        case .app: return "App"
        }
    }

    static func parse(_ raw: String) -> SearchFileKind? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "folder", "folders", "dir", "dirs", "directory", "carpeta", "carpetas":
            return .folder
        case "file", "files", "archivo", "archivos":
            return .file
        case "image", "images", "img", "photo", "photos", "pic", "imagen", "imagenes":
            return .image
        case "video", "videos", "movie", "movies":
            return .video
        case "audio", "music", "sound", "musica":
            return .audio
        case "pdf", "pdfs":
            return .pdf
        case "doc", "docs", "document", "documents", "documento", "documentos", "text":
            return .document
        case "code", "source", "src", "codigo":
            return .code
        case "archive", "archives", "zip", "compressed":
            return .archive
        case "app", "apps", "application", "applications":
            return .app
        default:
            return nil
        }
    }

    var extensions: Set<String> {
        switch self {
        case .folder, .file:
            return []
        case .image:
            return [
                "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "svg",
                "tif", "tiff", "bmp", "ico", "icns", "raw", "dng", "cr2", "nef", "psd", "avif",
            ]
        case .video:
            return ["mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "ts", "mts"]
        case .audio:
            return ["mp3", "wav", "flac", "aac", "m4a", "ogg", "aiff", "aif", "opus", "wma"]
        case .pdf:
            return ["pdf"]
        case .document:
            return [
                "pdf", "doc", "docx", "rtf", "rtfd", "pages", "odt", "txt",
                "md", "markdown", "xls", "xlsx", "numbers", "csv", "tsv",
                "ppt", "pptx", "key", "epub",
            ]
        case .code:
            return [
                "swift", "rs", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "pyi",
                "go", "rb", "java", "kt", "kts", "c", "h", "cpp", "cc", "cxx", "hpp",
                "m", "mm", "cs", "php", "sh", "zsh", "bash", "fish", "sql",
                "html", "htm", "css", "scss", "sass", "less", "json", "jsonc",
                "yaml", "yml", "toml", "xml", "plist", "vue", "svelte", "zig",
                "lua", "ex", "exs", "erl", "hs", "ml", "r", "dart", "scala",
                "dockerfile", "makefile", "gradle", "proto", "graphql", "tf",
            ]
        case .archive:
            return ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso", "pkg", "zst"]
        case .app:
            return ["app"]
        }
    }

    func matches(name: String, isDirectory: Bool, isPackage: Bool) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        switch self {
        case .folder:
            return isDirectory && !isPackage
        case .file:
            return !isDirectory || isPackage
        case .app:
            return ext == "app" || (isPackage && ext == "app")
        default:
            guard !isDirectory || isPackage else { return false }
            return extensions.contains(ext)
        }
    }

    /// Optional Spotlight `mdfind` predicate clause for fast native pushdown.
    var spotlightClause: String? {
        switch self {
        case .folder:
            return "kMDItemContentType == 'public.folder'"
        case .file:
            return "kMDItemContentType != 'public.folder'"
        case .image:
            return "kMDItemContentTypeTree == 'public.image'"
        case .video:
            return "kMDItemContentTypeTree == 'public.movie'"
        case .audio:
            return "kMDItemContentTypeTree == 'public.audio'"
        case .pdf:
            return "kMDItemContentType == 'com.adobe.pdf'"
        case .app:
            return "kMDItemContentType == 'com.apple.application-bundle'"
        case .archive:
            return "kMDItemContentTypeTree == 'public.archive'"
        case .document, .code:
            // Broad semantic categories rely on extension sets for exact consistency.
            let extClauses = extensions.sorted().map { "kMDItemFSName == '*.\($0)'cd" }
            return extClauses.isEmpty ? nil : "(\(extClauses.joined(separator: " || ")))"
        }
    }
}

/// Comparison operators used by `size` and `modified` structured filters.
nonisolated enum SearchComparisonOp: String, Hashable, Sendable {
    case greaterThan = ">"
    case greaterOrEqual = ">="
    case lessThan = "<"
    case lessOrEqual = "<="
    case equal = "="
}

/// Structured filter predicate compiled from a single query token.
nonisolated enum SearchFilterPredicate: Hashable, Sendable {
    /// Positive (`negated: false`) or excluded (`negated: true`) lowercase extensions (no leading dot).
    case extensions([String], negated: Bool)
    /// Positive or excluded semantic kinds.
    case kinds([SearchFileKind], negated: Bool)
    /// File size comparison (`size>10mb`, `size<=500kb`).
    case sizeCompare(SearchComparisonOp, UInt64)
    /// Inclusive file size range (`size:100kb..5mb`).
    case sizeRange(min: UInt64, max: UInt64)
    /// Relative age: `within: true` means modified >= now - seconds (`modified:7d`, `modified<7d`);
    /// `within: false` means modified < now - seconds (`modified>30d`).
    case modifiedRelative(seconds: TimeInterval, within: Bool)
    /// Calendar boundary relative to start-of-day (`today`, `yesterday`).
    case modifiedSinceStartOfDay(daysBack: Int)
    /// Absolute date comparison (`modified>2026-01-01`, `modified<2026-06-01`).
    case modifiedDateCompare(SearchComparisonOp, Date)
    /// Inclusive absolute date range (`modified:2026-05`, `modified:2026-01-01..2026-06-30`).
    case modifiedDateRange(start: Date, end: Date)
}

/// A single recognized structured filter token inside a user's search query.
nonisolated struct SearchFilterToken: Identifiable, Hashable, Sendable {
    let id: String
    let rawToken: String
    let range: Range<String.Index>
    let displayLabel: String
    let iconName: String
    let predicate: SearchFilterPredicate
}

/// Parsed representation of a raw search string split into free text + structured filters.
nonisolated struct ParsedSearchQuery: Equatable, Sendable {
    let rawQuery: String
    /// Remaining free-text search terms (with quotes unwrapped and filter tokens stripped).
    let textQuery: String
    let filters: [SearchFilterToken]

    var hasFilters: Bool { !filters.isEmpty }
    var isEmpty: Bool { textQuery.isEmpty && filters.isEmpty }
    var isFilterOnly: Bool { textQuery.isEmpty && !filters.isEmpty }

    /// Evaluates every filter predicate against file metadata.
    ///
    /// Positive `ext:` tokens across multiple filters are combined with OR
    /// (`ext:png ext:jpg` matches either), positive `kind:` tokens combine with OR,
    /// while different filter dimensions (ext AND kind AND size AND modified) and
    /// negated filters (`-ext:`, `-kind:`) are combined with AND.
    func matches(
        name: String,
        isDirectory: Bool,
        isPackage: Bool,
        size: UInt64,
        modified: Date?,
        now: Date = Date()
    ) -> Bool {
        guard !filters.isEmpty else { return true }

        let fileExt = (name as NSString).pathExtension.lowercased()
        var positiveExtensions: Set<String> = []
        var excludedExtensions: Set<String> = []
        var positiveKinds: [SearchFileKind] = []
        var excludedKinds: [SearchFileKind] = []

        for token in filters {
            switch token.predicate {
            case .extensions(let exts, let negated):
                if negated {
                    excludedExtensions.formUnion(exts)
                } else {
                    positiveExtensions.formUnion(exts)
                }

            case .kinds(let kinds, let negated):
                if negated {
                    excludedKinds.append(contentsOf: kinds)
                } else {
                    positiveKinds.append(contentsOf: kinds)
                }

            case .sizeCompare(let op, let target):
                guard !isDirectory || isPackage else { return false }
                switch op {
                case .greaterThan: if !(size > target) { return false }
                case .greaterOrEqual: if !(size >= target) { return false }
                case .lessThan: if !(size < target) { return false }
                case .lessOrEqual: if !(size <= target) { return false }
                case .equal: if !(size == target) { return false }
                }

            case .sizeRange(let minBytes, let maxBytes):
                guard !isDirectory || isPackage else { return false }
                if size < minBytes || size > maxBytes { return false }

            case .modifiedRelative(let seconds, let within):
                guard let modified else { return false }
                let cutoff = now.addingTimeInterval(-seconds)
                if within {
                    if modified < cutoff { return false }
                } else {
                    if modified >= cutoff { return false }
                }

            case .modifiedSinceStartOfDay(let daysBack):
                guard let modified else { return false }
                let calendar = Calendar.current
                let startOfToday = calendar.startOfDay(for: now)
                let cutoff = calendar.date(byAdding: .day, value: -daysBack, to: startOfToday) ?? startOfToday
                if modified < cutoff { return false }

            case .modifiedDateCompare(let op, let date):
                guard let modified else { return false }
                switch op {
                case .greaterThan: if !(modified > date) { return false }
                case .greaterOrEqual: if !(modified >= date) { return false }
                case .lessThan: if !(modified < date) { return false }
                case .lessOrEqual: if !(modified <= date) { return false }
                case .equal:
                    let calendar = Calendar.current
                    if !calendar.isDate(modified, inSameDayAs: date) { return false }
                }

            case .modifiedDateRange(let start, let end):
                guard let modified else { return false }
                if modified < start || modified > end { return false }
            }
        }

        if !positiveExtensions.isEmpty {
            guard !isDirectory || isPackage else { return false }
            if !positiveExtensions.contains(fileExt) { return false }
        }
        if !excludedExtensions.isEmpty && (!isDirectory || isPackage) {
            if excludedExtensions.contains(fileExt) { return false }
        }
        if !positiveKinds.isEmpty {
            if !positiveKinds.contains(where: { $0.matches(name: name, isDirectory: isDirectory, isPackage: isPackage) }) {
                return false
            }
        }
        if !excludedKinds.isEmpty {
            if excludedKinds.contains(where: { $0.matches(name: name, isDirectory: isDirectory, isPackage: isPackage) }) {
                return false
            }
        }

        return true
    }

    /// Removes the filter token at `index` from `rawQuery` and cleans up extra spaces.
    func removingFilter(at index: Int) -> String {
        guard filters.indices.contains(index) else { return rawQuery }
        var updated = rawQuery
        updated.removeSubrange(filters[index].range)
        return Self.collapseWhitespace(updated)
    }

    /// Appends a structured filter token cleanly to `rawQuery` (avoids duplicate identical tokens).
    func appendingFilter(_ token: String) -> String {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return rawQuery }
        let base = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            return trimmedToken
        }
        if filters.contains(where: { $0.rawToken.caseInsensitiveCompare(trimmedToken) == .orderedSame }) {
            return rawQuery
        }
        return "\(base) \(trimmedToken)"
    }

    // MARK: - Native Backend Pushdown Compilers

    /// Extra flags for `fd` (native extension, type, size, and mtime pruning).
    func fdArguments(now: Date = Date()) -> [String] {
        var args: [String] = []
        var positiveExts: [String] = []
        var positiveKinds: [SearchFileKind] = []

        for token in filters {
            switch token.predicate {
            case .extensions(let exts, let negated):
                if !negated {
                    positiveExts.append(contentsOf: exts)
                }
            case .kinds(let kinds, let negated):
                if !negated {
                    positiveKinds.append(contentsOf: kinds)
                }
            case .sizeCompare(let op, let bytes):
                switch op {
                case .greaterThan, .greaterOrEqual:
                    args.append(contentsOf: ["--size", "+\(bytes)b"])
                case .lessThan, .lessOrEqual:
                    args.append("--size=-\(bytes)b")
                case .equal:
                    break
                }
            case .sizeRange(let minBytes, let maxBytes):
                args.append(contentsOf: ["--size", "+\(minBytes)b", "--size=-\(maxBytes)b"])
            case .modifiedRelative(let seconds, let within):
                let secs = max(1, Int(seconds.rounded()))
                if within {
                    args.append(contentsOf: ["--changed-within", "\(secs)s"])
                } else {
                    args.append(contentsOf: ["--changed-before", "\(secs)s"])
                }
            case .modifiedSinceStartOfDay(let daysBack):
                let calendar = Calendar.current
                let startOfToday = calendar.startOfDay(for: now)
                let cutoff = calendar.date(byAdding: .day, value: -daysBack, to: startOfToday) ?? startOfToday
                let secs = max(1, Int(ceil(now.timeIntervalSince(cutoff))))
                args.append(contentsOf: ["--changed-within", "\(secs)s"])
            case .modifiedDateCompare(let op, let date):
                let iso = Self.isoDateFormatter.string(from: date)
                switch op {
                case .greaterThan, .greaterOrEqual:
                    args.append(contentsOf: ["--changed-within", iso])
                case .lessThan, .lessOrEqual:
                    args.append(contentsOf: ["--changed-before", iso])
                case .equal:
                    break
                }
            case .modifiedDateRange(let start, let end):
                args.append(contentsOf: [
                    "--changed-within", Self.isoDateFormatter.string(from: start),
                    "--changed-before", Self.isoDateFormatter.string(from: end),
                ])
            }
        }

        for ext in Array(Set(positiveExts)).sorted() {
            args.append(contentsOf: ["--extension", ext])
        }
        if positiveKinds.count == 1, let only = positiveKinds.first {
            switch only {
            case .folder:
                args.append(contentsOf: ["--type", "d"])
            case .file:
                args.append(contentsOf: ["--type", "f"])
            default:
                break
            }
        }
        return args
    }

    /// Extra `--glob` flags for `rg` to skip non-matching file extensions at SIMD speed.
    func ripgrepGlobArguments() -> [String] {
        var args: [String] = []
        var positiveExts: Set<String> = []
        var excludedExts: Set<String> = []
        var positiveKindExts: Set<String> = []
        var hasUnboundedKind = false

        for token in filters {
            switch token.predicate {
            case .extensions(let exts, let negated):
                if negated {
                    excludedExts.formUnion(exts)
                } else {
                    positiveExts.formUnion(exts)
                }
            case .kinds(let kinds, let negated) where !negated:
                for kind in kinds {
                    if kind.extensions.isEmpty {
                        hasUnboundedKind = true
                    } else {
                        positiveKindExts.formUnion(kind.extensions)
                    }
                }
            default:
                break
            }
        }

        if !positiveExts.isEmpty {
            for ext in positiveExts.sorted() {
                args.append(contentsOf: ["--glob", "*.\(ext)"])
            }
        } else if !hasUnboundedKind && !positiveKindExts.isEmpty {
            for ext in positiveKindExts.sorted() {
                args.append(contentsOf: ["--glob", "*.\(ext)"])
            }
        }

        for ext in excludedExts.sorted() {
            args.append(contentsOf: ["--glob", "!*.\(ext)"])
        }
        return args
    }

    /// Native Spotlight `mdfind` predicate clauses for Global search pushdown.
    /// Authoritative `matches(...)` still runs on every returned hit for 100% parity.
    func spotlightPredicateClauses(now: Date = Date()) -> [String] {
        var clauses: [String] = []
        var positiveExts: Set<String> = []
        var positiveKinds: [SearchFileKind] = []

        for token in filters {
            switch token.predicate {
            case .extensions(let exts, let negated):
                if !negated {
                    positiveExts.formUnion(exts)
                }
            case .kinds(let kinds, let negated):
                if !negated {
                    positiveKinds.append(contentsOf: kinds)
                }
            case .sizeCompare(let op, let bytes):
                let mdOp: String
                switch op {
                case .greaterThan: mdOp = ">"
                case .greaterOrEqual: mdOp = ">="
                case .lessThan: mdOp = "<"
                case .lessOrEqual: mdOp = "<="
                case .equal: mdOp = "=="
                }
                clauses.append("kMDItemFSSize \(mdOp) \(bytes)")
            case .sizeRange(let minBytes, let maxBytes):
                clauses.append("(kMDItemFSSize >= \(minBytes) && kMDItemFSSize <= \(maxBytes))")
            case .modifiedRelative(let seconds, let within):
                let secs = max(1, Int(seconds.rounded()))
                if within {
                    clauses.append("kMDItemFSContentChangeDate >= $time.now(-\(secs))")
                } else {
                    clauses.append("kMDItemFSContentChangeDate < $time.now(-\(secs))")
                }
            case .modifiedSinceStartOfDay(let daysBack):
                if daysBack == 0 {
                    clauses.append("kMDItemFSContentChangeDate >= $time.today")
                } else {
                    clauses.append("kMDItemFSContentChangeDate >= $time.today(-\(daysBack))")
                }
            case .modifiedDateCompare(let op, let date):
                let delta = Int((date.timeIntervalSince(now)).rounded())
                let mdOp: String
                switch op {
                case .greaterThan: mdOp = ">"
                case .greaterOrEqual: mdOp = ">="
                case .lessThan: mdOp = "<"
                case .lessOrEqual: mdOp = "<="
                case .equal: mdOp = ">="
                }
                clauses.append("kMDItemFSContentChangeDate \(mdOp) $time.now(\(delta))")
            case .modifiedDateRange(let start, let end):
                let startDelta = Int((start.timeIntervalSince(now)).rounded())
                let endDelta = Int((end.timeIntervalSince(now)).rounded())
                clauses.append("(kMDItemFSContentChangeDate >= $time.now(\(startDelta)) && kMDItemFSContentChangeDate <= $time.now(\(endDelta)))")
            }
        }

        if !positiveExts.isEmpty {
            let parts = positiveExts.sorted().map { "kMDItemFSName == '*.\($0)'cd" }
            clauses.append(parts.count == 1 ? parts[0] : "(\(parts.joined(separator: " || ")))")
        }

        if !positiveKinds.isEmpty {
            let kindClauses = positiveKinds.compactMap(\.spotlightClause)
            if !kindClauses.isEmpty {
                clauses.append(kindClauses.count == 1 ? kindClauses[0] : "(\(kindClauses.joined(separator: " || ")))")
            }
        }

        return clauses
    }

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static func collapseWhitespace(_ string: String) -> String {
        string
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .joined(separator: " ")
    }
}

/// Pure, forgiving parser for Arbor's structured search query language:
/// - `ext:swift`, `ext:ts,tsx`, `-ext:lock`
/// - `kind:image`, `kind:pdf,doc`, `-kind:folder`
/// - `size>10mb`, `size<=500kb`, `size:100kb..5mb`
/// - `modified:today`, `modified:7d`, `modified:24h`, `modified>2026-01-01`, `modified:2026-05`
/// - Quoted strings (`"size>10mb"`) are preserved verbatim as free text.
nonisolated enum SearchQueryParser {
    static func parse(_ rawQuery: String) -> ParsedSearchQuery {
        let tokens = tokenize(rawQuery)
        var filters: [SearchFilterToken] = []
        var textParts: [String] = []

        for (idx, piece) in tokens.enumerated() {
            if !piece.isQuoted, let filter = parseFilterToken(piece.text, range: piece.range, ordinal: idx) {
                filters.append(filter)
            } else {
                let text = piece.unquotedText
                if !text.isEmpty {
                    textParts.append(text)
                }
            }
        }

        let textQuery = textParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedSearchQuery(rawQuery: rawQuery, textQuery: textQuery, filters: filters)
    }

    // MARK: - Tokenizer

    private struct RawPiece {
        let text: String
        let range: Range<String.Index>
        let isQuoted: Bool

        var unquotedText: String {
            guard isQuoted else { return text }
            if text.count >= 2, text.first == "\"", text.last == "\"" {
                return String(text.dropFirst().dropLast())
            }
            if text.first == "\"" {
                return String(text.dropFirst())
            }
            return text
        }
    }

    private static func tokenize(_ input: String) -> [RawPiece] {
        var result: [RawPiece] = []
        var index = input.startIndex

        while index < input.endIndex {
            while index < input.endIndex, input[index].isWhitespace {
                index = input.index(after: index)
            }
            guard index < input.endIndex else { break }

            let start = index
            if input[index] == "\"" {
                index = input.index(after: index)
                while index < input.endIndex, input[index] != "\"" {
                    index = input.index(after: index)
                }
                if index < input.endIndex, input[index] == "\"" {
                    index = input.index(after: index)
                }
                result.append(RawPiece(text: String(input[start..<index]), range: start..<index, isQuoted: true))
            } else {
                while index < input.endIndex, !input[index].isWhitespace {
                    index = input.index(after: index)
                }
                result.append(RawPiece(text: String(input[start..<index]), range: start..<index, isQuoted: false))
            }
        }
        return result
    }

    // MARK: - Filter Token Parsing

    private static func parseFilterToken(
        _ raw: String,
        range: Range<String.Index>,
        ordinal: Int
    ) -> SearchFilterToken? {
        let isNegated = raw.hasPrefix("-") && raw.count > 2
        let body = isNegated ? String(raw.dropFirst()) : raw
        let lower = body.lowercased()

        // 1. ext:<values>
        if lower.hasPrefix("ext:") {
            let valueStr = String(body.dropFirst(4))
            return parseExtensionFilter(valueStr, raw: raw, range: range, negated: isNegated, ordinal: ordinal)
        }

        // 2. kind:<values>
        if lower.hasPrefix("kind:") {
            let valueStr = String(body.dropFirst(5))
            return parseKindFilter(valueStr, raw: raw, range: range, negated: isNegated, ordinal: ordinal)
        }

        // 3. size> / size>= / size< / size<= / size= / size:
        if !isNegated, lower.hasPrefix("size") {
            let rest = String(body.dropFirst(4))
            if let token = parseSizeFilter(rest, raw: raw, range: range, ordinal: ordinal) {
                return token
            }
        }

        // 4. modified: / modified> / modified< / mod:
        if !isNegated {
            if lower.hasPrefix("modified") {
                let rest = String(body.dropFirst(8))
                if let token = parseModifiedFilter(rest, raw: raw, range: range, ordinal: ordinal) {
                    return token
                }
            } else if lower.hasPrefix("mod:") || lower.hasPrefix("mod>") || lower.hasPrefix("mod<") {
                let rest = String(body.dropFirst(3))
                if let token = parseModifiedFilter(rest, raw: raw, range: range, ordinal: ordinal) {
                    return token
                }
            }
        }

        return nil
    }

    private static func parseExtensionFilter(
        _ valueStr: String,
        raw: String,
        range: Range<String.Index>,
        negated: Bool,
        ordinal: Int
    ) -> SearchFilterToken? {
        let parts = valueStr
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". \t")).lowercased() }
            .filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "_" || $0 == "-" } }
        guard !parts.isEmpty else { return nil }

        let unique = Array(NSOrderedSet(array: parts)).compactMap { $0 as? String }
        let labelList = unique.map { ".\($0)" }.joined(separator: ", ")
        let label = negated ? "not \(labelList)" : "ext: \(labelList)"
        return SearchFilterToken(
            id: "ext-\(ordinal)-\(raw)",
            rawToken: raw,
            range: range,
            displayLabel: label,
            iconName: "tag",
            predicate: .extensions(unique, negated: negated)
        )
    }

    private static func parseKindFilter(
        _ valueStr: String,
        raw: String,
        range: Range<String.Index>,
        negated: Bool,
        ordinal: Int
    ) -> SearchFilterToken? {
        let rawParts = valueStr.split(separator: ",").map(String.init)
        guard !rawParts.isEmpty else { return nil }
        var parsedKinds: [SearchFileKind] = []
        for part in rawParts {
            guard let kind = SearchFileKind.parse(part) else { return nil }
            if !parsedKinds.contains(kind) {
                parsedKinds.append(kind)
            }
        }
        guard !parsedKinds.isEmpty else { return nil }

        let names = parsedKinds.map(\.displayName).joined(separator: ", ")
        let label = negated ? "not \(names)" : "kind: \(names)"
        return SearchFilterToken(
            id: "kind-\(ordinal)-\(raw)",
            rawToken: raw,
            range: range,
            displayLabel: label,
            iconName: "square.grid.2x2",
            predicate: .kinds(parsedKinds, negated: negated)
        )
    }

    private static func parseSizeFilter(
        _ rest: String,
        raw: String,
        range: Range<String.Index>,
        ordinal: Int
    ) -> SearchFilterToken? {
        guard let first = rest.first, [">", "<", "=", ":"].contains(first) else { return nil }

        // Handle range `size:100kb..5mb`
        if rest.hasPrefix(":"), let dots = rest.range(of: "..") {
            let lhsStr = String(rest[rest.index(after: rest.startIndex)..<dots.lowerBound])
            let rhsStr = String(rest[dots.upperBound...])
            guard let lo = parseByteSize(lhsStr), let hi = parseByteSize(rhsStr), lo <= hi else {
                return nil
            }
            let loFmt = ByteCountFormatter.string(fromByteCount: Int64(min(lo, UInt64(Int64.max))), countStyle: .file)
            let hiFmt = ByteCountFormatter.string(fromByteCount: Int64(min(hi, UInt64(Int64.max))), countStyle: .file)
            return SearchFilterToken(
                id: "size-\(ordinal)-\(raw)",
                rawToken: raw,
                range: range,
                displayLabel: "size: \(loFmt)–\(hiFmt)",
                iconName: "internaldrive",
                predicate: .sizeRange(min: lo, max: hi)
            )
        }

        let (op, valueStr) = extractOperatorAndValue(rest, defaultOp: .equal)
        guard let op, let bytes = parseByteSize(valueStr) else { return nil }
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
        return SearchFilterToken(
            id: "size-\(ordinal)-\(raw)",
            rawToken: raw,
            range: range,
            displayLabel: "size \(op.rawValue) \(formatted)",
            iconName: "internaldrive",
            predicate: .sizeCompare(op, bytes)
        )
    }

    private static func parseByteSize(_ raw: String) -> UInt64? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }

        var split = s.startIndex
        while split < s.endIndex, (s[split].isNumber || s[split] == ".") {
            split = s.index(after: split)
        }
        let numStr = String(s[..<split])
        let unitStr = String(s[split...])
        guard let number = Double(numStr), number >= 0, number.isFinite else { return nil }

        let multiplier: Double
        switch unitStr {
        case "", "b", "bytes": multiplier = 1
        case "k", "kb": multiplier = 1_000
        case "m", "mb": multiplier = 1_000_000
        case "g", "gb": multiplier = 1_000_000_000
        case "t", "tb": multiplier = 1_000_000_000_000
        case "kib": multiplier = 1_024
        case "mib": multiplier = 1_024 * 1_024
        case "gib": multiplier = 1_024 * 1_024 * 1_024
        case "tib": multiplier = 1_024 * 1_024 * 1_024 * 1_024
        default: return nil
        }

        let total = number * multiplier
        guard total <= Double(UInt64.max) else { return nil }
        return UInt64(total.rounded())
    }

    private static func parseModifiedFilter(
        _ rest: String,
        raw: String,
        range: Range<String.Index>,
        ordinal: Int
    ) -> SearchFilterToken? {
        guard let first = rest.first, [">", "<", "=", ":"].contains(first) else { return nil }

        // 1. Date range `modified:2026-01-01..2026-06-30`
        if rest.hasPrefix(":"), let dots = rest.range(of: "..") {
            let lhs = String(rest[rest.index(after: rest.startIndex)..<dots.lowerBound])
            let rhs = String(rest[dots.upperBound...])
            guard let startBounds = parseAbsoluteDateBounds(lhs),
                  let endBounds = parseAbsoluteDateBounds(rhs),
                  startBounds.start <= endBounds.end
            else { return nil }
            return SearchFilterToken(
                id: "mod-\(ordinal)-\(raw)",
                rawToken: raw,
                range: range,
                displayLabel: "modified: \(lhs)–\(rhs)",
                iconName: "clock",
                predicate: .modifiedDateRange(start: startBounds.start, end: endBounds.end)
            )
        }

        let (op, valueStr) = extractOperatorAndValue(rest, defaultOp: nil)
        let lowerVal = valueStr.lowercased()
        guard !lowerVal.isEmpty else { return nil }

        // 2. Named relative keywords (`modified:today`, `modified:yesterday`, `modified:week`, `modified:month`, `modified:year`)
        if op == nil {
            switch lowerVal {
            case "today", "hoy":
                return SearchFilterToken(
                    id: "mod-\(ordinal)-\(raw)",
                    rawToken: raw,
                    range: range,
                    displayLabel: "modified: today",
                    iconName: "clock",
                    predicate: .modifiedSinceStartOfDay(daysBack: 0)
                )
            case "yesterday", "ayer":
                return SearchFilterToken(
                    id: "mod-\(ordinal)-\(raw)",
                    rawToken: raw,
                    range: range,
                    displayLabel: "modified: since yesterday",
                    iconName: "clock",
                    predicate: .modifiedSinceStartOfDay(daysBack: 1)
                )
            case "week", "semana":
                return SearchFilterToken(
                    id: "mod-\(ordinal)-\(raw)",
                    rawToken: raw,
                    range: range,
                    displayLabel: "modified: last 7d",
                    iconName: "clock",
                    predicate: .modifiedRelative(seconds: 7 * 86_400, within: true)
                )
            case "month", "mes":
                return SearchFilterToken(
                    id: "mod-\(ordinal)-\(raw)",
                    rawToken: raw,
                    range: range,
                    displayLabel: "modified: last 30d",
                    iconName: "clock",
                    predicate: .modifiedRelative(seconds: 30 * 86_400, within: true)
                )
            case "year", "anio", "año":
                return SearchFilterToken(
                    id: "mod-\(ordinal)-\(raw)",
                    rawToken: raw,
                    range: range,
                    displayLabel: "modified: last 365d",
                    iconName: "clock",
                    predicate: .modifiedRelative(seconds: 365 * 86_400, within: true)
                )
            default:
                break
            }
        }

        // 3. Relative duration (`7d`, `24h`, `2w`, `6m`, `1y`)
        if let duration = parseRelativeDuration(lowerVal) {
            let within: Bool
            let label: String
            switch op {
            case nil, .lessThan, .lessOrEqual, .equal:
                within = true
                label = "modified: last \(duration.label)"
            case .greaterThan, .greaterOrEqual:
                within = false
                label = "modified > \(duration.label) ago"
            }
            return SearchFilterToken(
                id: "mod-\(ordinal)-\(raw)",
                rawToken: raw,
                range: range,
                displayLabel: label,
                iconName: "clock",
                predicate: .modifiedRelative(seconds: duration.seconds, within: within)
            )
        }

        // 4. Absolute ISO date (`YYYY`, `YYYY-MM`, `YYYY-MM-DD`)
        if let bounds = parseAbsoluteDateBounds(lowerVal) {
            if let op {
                let targetDate: Date
                switch op {
                case .greaterThan: targetDate = bounds.end
                case .greaterOrEqual: targetDate = bounds.start
                case .lessThan: targetDate = bounds.start
                case .lessOrEqual: targetDate = bounds.end
                case .equal: targetDate = bounds.start
                }
                return SearchFilterToken(
                    id: "mod-\(ordinal)-\(raw)",
                    rawToken: raw,
                    range: range,
                    displayLabel: "modified \(op.rawValue) \(valueStr)",
                    iconName: "clock",
                    predicate: .modifiedDateCompare(op, targetDate)
                )
            } else {
                return SearchFilterToken(
                    id: "mod-\(ordinal)-\(raw)",
                    rawToken: raw,
                    range: range,
                    displayLabel: "modified: \(valueStr)",
                    iconName: "clock",
                    predicate: .modifiedDateRange(start: bounds.start, end: bounds.end)
                )
            }
        }

        return nil
    }

    private static func extractOperatorAndValue(
        _ rest: String,
        defaultOp: SearchComparisonOp?
    ) -> (SearchComparisonOp?, String) {
        var cursor = rest
        if cursor.hasPrefix(":") {
            cursor = String(cursor.dropFirst())
        }
        if cursor.hasPrefix(">=") {
            return (.greaterOrEqual, String(cursor.dropFirst(2)))
        }
        if cursor.hasPrefix("<=") {
            return (.lessOrEqual, String(cursor.dropFirst(2)))
        }
        if cursor.hasPrefix(">") {
            return (.greaterThan, String(cursor.dropFirst(1)))
        }
        if cursor.hasPrefix("<") {
            return (.lessThan, String(cursor.dropFirst(1)))
        }
        if cursor.hasPrefix("=") {
            return (.equal, String(cursor.dropFirst(1)))
        }
        return (defaultOp, cursor)
    }

    private static func parseRelativeDuration(_ value: String) -> (seconds: TimeInterval, label: String)? {
        guard value.count >= 2 else { return nil }
        let unit = value.last!
        let numberPart = String(value.dropLast())
        guard let count = Int(numberPart), count > 0 else { return nil }
        let unitSeconds: TimeInterval
        switch unit {
        case "h": unitSeconds = 3_600
        case "d": unitSeconds = 86_400
        case "w": unitSeconds = 7 * 86_400
        case "m": unitSeconds = 30 * 86_400
        case "y": unitSeconds = 365 * 86_400
        default: return nil
        }
        return (Double(count) * unitSeconds, "\(count)\(unit)")
    }

    private static func parseAbsoluteDateBounds(_ value: String) -> (start: Date, end: Date)? {
        let parts = value.split(separator: "-")
        guard (1...3).contains(parts.count) else { return nil }
        guard let year = Int(parts[0]), (1970...2999).contains(year) else { return nil }

        let calendar = Calendar.current
        if parts.count == 1 {
            guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let next = calendar.date(byAdding: .year, value: 1, to: start)
            else { return nil }
            return (start, next.addingTimeInterval(-0.001))
        }
        guard let month = Int(parts[1]), (1...12).contains(month) else { return nil }
        if parts.count == 2 {
            guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let next = calendar.date(byAdding: .month, value: 1, to: start)
            else { return nil }
            return (start, next.addingTimeInterval(-0.001))
        }
        guard let day = Int(parts[2]), (1...31).contains(day) else { return nil }
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              let next = calendar.date(byAdding: .day, value: 1, to: start)
        else { return nil }
        return (start, next.addingTimeInterval(-0.001))
    }
}
