import Foundation

/// Maps file names/extensions to a highlight.js grammar and a display label.
///
/// This is the single source of truth for “is this a file we render as source
/// code?”. Anything not listed here keeps the system Quick Look.
nonisolated struct SourceLanguage: Equatable, Hashable, Sendable {
    /// highlight.js language id (must exist in the bundled grammar set).
    let highlighterID: String
    /// Human label shown in the preview header ("TypeScript", "Python", …).
    let displayName: String

    private static let byExtension: [String: SourceLanguage] = [
        // JavaScript family
        "js": .init(highlighterID: "javascript", displayName: "JavaScript"),
        "mjs": .init(highlighterID: "javascript", displayName: "JavaScript"),
        "cjs": .init(highlighterID: "javascript", displayName: "JavaScript"),
        "jsx": .init(highlighterID: "javascript", displayName: "JSX"),
        "ts": .init(highlighterID: "typescript", displayName: "TypeScript"),
        "mts": .init(highlighterID: "typescript", displayName: "TypeScript"),
        "cts": .init(highlighterID: "typescript", displayName: "TypeScript"),
        "tsx": .init(highlighterID: "typescript", displayName: "TSX"),

        // Python / Ruby / Perl / Lua / R
        "py": .init(highlighterID: "python", displayName: "Python"),
        "pyw": .init(highlighterID: "python", displayName: "Python"),
        "pyi": .init(highlighterID: "python", displayName: "Python"),
        "rb": .init(highlighterID: "ruby", displayName: "Ruby"),
        "gemspec": .init(highlighterID: "ruby", displayName: "Ruby"),
        "pl": .init(highlighterID: "perl", displayName: "Perl"),
        "lua": .init(highlighterID: "lua", displayName: "Lua"),
        "r": .init(highlighterID: "r", displayName: "R"),

        // Rust / Go / Swift / JVM
        "rs": .init(highlighterID: "rust", displayName: "Rust"),
        "go": .init(highlighterID: "go", displayName: "Go"),
        "swift": .init(highlighterID: "swift", displayName: "Swift"),
        "java": .init(highlighterID: "java", displayName: "Java"),
        "kt": .init(highlighterID: "kotlin", displayName: "Kotlin"),
        "kts": .init(highlighterID: "kotlin", displayName: "Kotlin"),
        "scala": .init(highlighterID: "scala", displayName: "Scala"),
        "groovy": .init(highlighterID: "groovy", displayName: "Groovy"),
        "gradle": .init(highlighterID: "groovy", displayName: "Gradle"),

        // C family
        "c": .init(highlighterID: "c", displayName: "C"),
        "h": .init(highlighterID: "c", displayName: "C Header"),
        "m": .init(highlighterID: "objectivec", displayName: "Objective-C"),
        "mm": .init(highlighterID: "objectivec", displayName: "Objective-C++"),
        "cpp": .init(highlighterID: "cpp", displayName: "C++"),
        "cc": .init(highlighterID: "cpp", displayName: "C++"),
        "cxx": .init(highlighterID: "cpp", displayName: "C++"),
        "hpp": .init(highlighterID: "cpp", displayName: "C++ Header"),
        "cs": .init(highlighterID: "csharp", displayName: "C#"),

        // Web / markup
        "html": .init(highlighterID: "xml", displayName: "HTML"),
        "htm": .init(highlighterID: "xml", displayName: "HTML"),
        "xhtml": .init(highlighterID: "xml", displayName: "XHTML"),
        "xml": .init(highlighterID: "xml", displayName: "XML"),
        "svg": .init(highlighterID: "xml", displayName: "SVG"),
        "plist": .init(highlighterID: "xml", displayName: "Property List"),
        "vue": .init(highlighterID: "xml", displayName: "Vue"),
        "svelte": .init(highlighterID: "xml", displayName: "Svelte"),

        // Styles
        "css": .init(highlighterID: "css", displayName: "CSS"),
        "scss": .init(highlighterID: "scss", displayName: "SCSS"),
        "less": .init(highlighterID: "less", displayName: "Less"),

        // Data / config
        "json": .init(highlighterID: "json", displayName: "JSON"),
        "jsonc": .init(highlighterID: "json", displayName: "JSON with Comments"),
        "json5": .init(highlighterID: "json", displayName: "JSON5"),
        "geojson": .init(highlighterID: "json", displayName: "GeoJSON"),
        "yaml": .init(highlighterID: "yaml", displayName: "YAML"),
        "yml": .init(highlighterID: "yaml", displayName: "YAML"),
        "toml": .init(highlighterID: "ini", displayName: "TOML"),
        "ini": .init(highlighterID: "ini", displayName: "INI"),
        "cfg": .init(highlighterID: "ini", displayName: "Config"),
        "conf": .init(highlighterID: "ini", displayName: "Config"),
        "properties": .init(highlighterID: "ini", displayName: "Properties"),
        "env": .init(highlighterID: "ini", displayName: "Environment"),
        "graphql": .init(highlighterID: "graphql", displayName: "GraphQL"),
        "gql": .init(highlighterID: "graphql", displayName: "GraphQL"),

        // Shell
        "sh": .init(highlighterID: "bash", displayName: "Shell"),
        "bash": .init(highlighterID: "bash", displayName: "Bash"),
        "zsh": .init(highlighterID: "bash", displayName: "Zsh"),
        "ksh": .init(highlighterID: "bash", displayName: "Ksh"),
        "fish": .init(highlighterID: "bash", displayName: "Fish"),
        "ps1": .init(highlighterID: "powershell", displayName: "PowerShell"),
        "bat": .init(highlighterID: "dos", displayName: "Batch"),
        "cmd": .init(highlighterID: "dos", displayName: "Batch"),

        // Databases / infra
        "sql": .init(highlighterID: "sql", displayName: "SQL"),
        "dockerfile": .init(highlighterID: "dockerfile", displayName: "Dockerfile"),
        "mk": .init(highlighterID: "makefile", displayName: "Makefile"),
        "cmake": .init(highlighterID: "cmake", displayName: "CMake"),
        "tf": .init(highlighterID: "ini", displayName: "Terraform"),
        "tfvars": .init(highlighterID: "ini", displayName: "Terraform"),

        // Diffs / misc
        "diff": .init(highlighterID: "diff", displayName: "Diff"),
        "patch": .init(highlighterID: "diff", displayName: "Patch"),
    ]

    /// Files whose whole name identifies the language.
    private static let byFileName: [String: SourceLanguage] = [
        "dockerfile": .init(highlighterID: "dockerfile", displayName: "Dockerfile"),
        "containerfile": .init(highlighterID: "dockerfile", displayName: "Containerfile"),
        "makefile": .init(highlighterID: "makefile", displayName: "Makefile"),
        "gnumakefile": .init(highlighterID: "makefile", displayName: "Makefile"),
        "cmakelists.txt": .init(highlighterID: "cmake", displayName: "CMake"),
        ".gitignore": .init(highlighterID: "plaintext", displayName: "Git Ignore"),
        ".gitattributes": .init(highlighterID: "plaintext", displayName: "Git Attributes"),
        ".editorconfig": .init(highlighterID: "ini", displayName: "EditorConfig"),
        ".env": .init(highlighterID: "ini", displayName: "Environment"),
    ]

    /// Extension-based lookup. `.env.local` style files resolve by last component.
    static func detect(fileName: String, fileExtension: String? = nil) -> SourceLanguage? {
        let name = fileName.lowercased()
        if let exact = byFileName[name] { return exact }

        let ext = (fileExtension ?? (name as NSString).pathExtension).lowercased()
        if let match = byExtension[ext] { return match }

        // `.env.local`, `.env.production`
        if name.hasPrefix(".env.") { return byFileName[".env"] }
        return nil
    }

    static func detect(url: URL) -> SourceLanguage? {
        detect(fileName: url.lastPathComponent, fileExtension: url.pathExtension)
    }

    /// Shebang detection for extension-less scripts (`#!/usr/bin/env python3`).
    static func detectFromShebang(_ firstLine: String) -> SourceLanguage? {
        guard firstLine.hasPrefix("#!") else { return nil }
        let lowered = firstLine.lowercased()
        if lowered.contains("python") { return byExtension["py"] }
        if lowered.contains("node") || lowered.contains("deno") || lowered.contains("bun") {
            return byExtension["js"]
        }
        if lowered.contains("ruby") { return byExtension["rb"] }
        if lowered.contains("bash") || lowered.contains("zsh") || lowered.contains("sh") {
            return byExtension["sh"]
        }
        if lowered.contains("perl") { return byExtension["pl"] }
        return nil
    }
}

#if DEBUG
extension SourceLanguage {
    static func runSelfCheck() {
        assert(detect(fileName: "a.ts")?.highlighterID == "typescript")
        assert(detect(fileName: "a.tsx")?.highlighterID == "typescript")
        assert(detect(fileName: "main.py")?.highlighterID == "python")
        assert(detect(fileName: "package.json")?.highlighterID == "json")
        assert(detect(fileName: "Dockerfile")?.highlighterID == "dockerfile")
        assert(detect(fileName: "Makefile")?.highlighterID == "makefile")
        assert(detect(fileName: ".env.local")?.highlighterID == "ini")
        assert(detect(fileName: "App.swift")?.highlighterID == "swift")
        assert(detect(fileName: "photo.png") == nil)
        assert(detect(fileName: "notes.txt") == nil)
        assert(detectFromShebang("#!/usr/bin/env python3")?.highlighterID == "python")
        assert(detectFromShebang("#!/bin/bash")?.highlighterID == "bash")
        assert(detectFromShebang("no shebang") == nil)
    }
}
#endif
