import Darwin
import Foundation

nonisolated struct OpenSSHConfigAlias: Identifiable, Hashable, Sendable {
    let name: String
    let source: URL
    let line: Int

    var id: String { name }
}

nonisolated enum OpenSSHConfigDiscovery {
    static func discover() -> [OpenSSHConfigAlias] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        var visited = Set<URL>()
        var aliases: [String: OpenSSHConfigAlias] = [:]
        parse(
            file: root,
            depth: 0,
            visited: &visited,
            aliases: &aliases
        )
        return aliases.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func parse(
        file: URL,
        depth: Int,
        visited: inout Set<URL>,
        aliases: inout [String: OpenSSHConfigAlias]
    ) {
        guard depth <= 8 else { return }
        let canonical = file.standardizedFileURL
        guard visited.insert(canonical).inserted,
              let contents = try? String(contentsOf: canonical, encoding: .utf8)
        else { return }

        for (offset, rawLine) in contents.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ).enumerated() {
            let withoutComment = rawLine.split(separator: "#", maxSplits: 1).first ?? ""
            let fields = withoutComment.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let keyword = fields.first?.lowercased(), fields.count > 1 else {
                continue
            }

            switch keyword {
            case "host":
                for token in fields.dropFirst() where isConcreteAlias(token) {
                    aliases[token] = aliases[token] ?? OpenSSHConfigAlias(
                        name: token,
                        source: canonical,
                        line: offset + 1
                    )
                }
            case "include":
                for token in fields.dropFirst() {
                    let pattern = resolveInclude(token, relativeTo: canonical)
                    for included in expandGlob(pattern) {
                        parse(
                            file: included,
                            depth: depth + 1,
                            visited: &visited,
                            aliases: &aliases
                        )
                    }
                }
            default:
                continue
            }
        }
    }

    private static func isConcreteAlias(_ value: String) -> Bool {
        !value.hasPrefix("!")
            && !value.contains("*")
            && !value.contains("?")
            && !value.contains("[")
    }

    private static func resolveInclude(_ raw: String, relativeTo source: URL) -> String {
        let unquoted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let expanded = (unquoted as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return expanded
        }
        return source.deletingLastPathComponent()
            .appendingPathComponent(expanded)
            .path
    }

    private static func expandGlob(_ pattern: String) -> [URL] {
        guard pattern.contains("*") || pattern.contains("?") || pattern.contains("[") else {
            return [URL(fileURLWithPath: pattern)]
        }
        var matches = glob_t()
        let result = pattern.withCString {
            Darwin.glob($0, 0, nil, &matches)
        }
        guard result == 0 else {
            globfree(&matches)
            return []
        }
        defer { globfree(&matches) }
        guard let paths = matches.gl_pathv else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { index in
            guard let path = paths[index] else { return nil }
            return URL(fileURLWithPath: String(cString: path))
        }
    }
}
