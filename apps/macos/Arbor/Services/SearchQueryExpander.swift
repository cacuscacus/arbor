import Foundation

/// Curated local MLX model presets backed by Arbor's Apple Silicon term-expansion benchmark
/// (`scripts/bench-mlx-expansion.py` on 24 bilingual ES/EN/dev queries).
nonisolated enum SearchExpansionModelPreset: String, CaseIterable, Identifiable, Sendable {
    case fast0_8B = "mlx-community/Qwen3.5-0.8B-4bit"
    case compact2B = "mlx-community/Qwen3.5-2B-4bit"
    case balanced2B8Bit = "mlx-community/Qwen3.5-2B-8bit"
    case accurate4B = "mlx-community/Qwen3.5-4B-4bit"
    case max9B = "mlx-community/Qwen3.5-9B-4bit"
    case custom = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast0_8B:
            return "Fast · Qwen3.5 0.8B (4-bit · ~0.7 GB · ~165ms)"
        case .compact2B:
            return "Compact · Qwen3.5 2B (4-bit · ~1.5 GB · ~205ms)"
        case .balanced2B8Bit:
            return "Balanced · Qwen3.5 2B (8-bit · ~2.4 GB · ~230ms) — Recommended"
        case .accurate4B:
            return "Accurate · Qwen3.5 4B (4-bit · ~2.9 GB · ~365ms)"
        case .max9B:
            return "Max · Qwen3.5 9B (4-bit · ~5.5 GB · 32+ GB Macs)"
        case .custom:
            return "Custom Hugging Face ID or local path…"
        }
    }

    var shortLabel: String {
        switch self {
        case .fast0_8B: return "0.8B 4-bit"
        case .compact2B: return "2B 4-bit"
        case .balanced2B8Bit: return "2B 8-bit"
        case .accurate4B: return "4B 4-bit"
        case .max9B: return "9B 4-bit"
        case .custom: return "Custom"
        }
    }

    static let idleUnloadPresetsMinutes = [2, 5, 10, 0]
}

/// Pure, deterministic post-processing for raw LLM expansion outputs:
/// strips `<think>` blocks, parses JSON arrays, removes generic stopwords,
/// deduplicates accent/case-insensitively, drops query echoes and verbose prose.
nonisolated enum SearchExpansionPostProcessor {
    static let genericStopwords: Set<String> = [
        "file", "files", "document", "documents", "doc", "docs", "folder", "dir",
        "directory", "data", "info", "information", "text", "pdf", "code", "item",
        "items", "thing", "archivo", "archivos", "documento", "documentos",
        "carpeta", "datos", "texto", "search", "query", "result", "results",
        "note", "notes", "list", "record", "records", "form", "page", "copy",
        "backup", "the", "and", "for", "with", "from", "para", "con", "los",
        "las", "del", "una", "uno",
    ]

    static func process(
        raw: String,
        originalQuery: String,
        maxTerms: Int = 5
    ) -> [String] {
        let extracted = extractArray(from: raw)
        return filter(terms: extracted, originalQuery: originalQuery, maxTerms: maxTerms)
    }

    static func filter(
        terms: [String],
        originalQuery: String,
        maxTerms: Int = 5
    ) -> [String] {
        let queryWords = Set(tokenize(normalize(originalQuery)))
        let normalizedQuery = normalize(originalQuery)
        var seen: Set<String> = []
        var cleaned: [String] = []
        let cap = max(1, maxTerms)

        for rawTerm in terms {
            let trimmed = rawTerm
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`,.;:()[]{}"))
            guard !trimmed.isEmpty else { continue }

            let norm = normalize(trimmed)
            guard !norm.isEmpty, norm.count >= 2, norm.count <= 28 else { continue }
            guard !seen.contains(norm) else { continue }
            guard !genericStopwords.contains(norm) else { continue }
            guard norm != normalizedQuery else { continue }

            let words = tokenize(norm)
            guard !words.isEmpty, words.count <= 2 else { continue }
            // Reject pure echoes of words already in the user's literal query.
            if !queryWords.isEmpty, words.allSatisfy({ queryWords.contains($0) }) {
                continue
            }

            seen.insert(norm)
            cleaned.append(trimmed.lowercased())
            if cleaned.count >= cap {
                break
            }
        }
        return cleaned
    }

    static func extractArray(from raw: String) -> [String] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip `<think>...</think>` blocks if emitted by reasoning-capable models.
        while let start = text.range(of: "<think>"),
              let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex)
        {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let parsed = decodeJSONStringArray(text) {
            return parsed
        }
        // Fallback: extract first `[...]` substring (handles ```json fences or wrapper prose).
        if let open = text.firstIndex(of: "["),
           let close = text[open...].firstIndex(of: "]")
        {
            let slice = String(text[open...close])
            if let parsed = decodeJSONStringArray(slice) {
                return parsed
            }
        }
        return []
    }

    private static func decodeJSONStringArray(_ s: String) -> [String]? {
        guard let data = s.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        return arr
    }

    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func tokenize(_ value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

/// Thread-safe bounded LRU cache for expanded query terms so re-typing or toggling scope is instant.
nonisolated final class SearchExpansionCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let modelID: String
        let mode: SearchMode
        let normalizedQuery: String
    }

    private let lock = NSLock()
    private let capacity: Int
    private var entries: [Key: [String]] = [:]
    private var order: [Key] = []

    init(capacity: Int = 128) {
        self.capacity = max(1, capacity)
    }

    func get(modelID: String, mode: SearchMode, query: String) -> [String]? {
        let key = Key(
            modelID: modelID,
            mode: mode,
            normalizedQuery: SearchExpansionPostProcessor.normalize(query)
        )
        lock.lock()
        defer { lock.unlock() }
        guard let value = entries[key] else { return nil }
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        return value
    }

    func set(modelID: String, mode: SearchMode, query: String, terms: [String]) {
        let key = Key(
            modelID: modelID,
            mode: mode,
            normalizedQuery: SearchExpansionPostProcessor.normalize(query)
        )
        lock.lock()
        defer { lock.unlock() }
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        } else if order.count >= capacity, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        entries[key] = terms
        order.append(key)
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        order.removeAll()
        lock.unlock()
    }
}
