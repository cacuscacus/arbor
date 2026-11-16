import XCTest
@testable import ArborPure

final class SourceLanguageTests: XCTestCase {
    func testWebExtensions() {
        XCTAssertEqual(SourceLanguage.detect(fileName: "a.ts")?.highlighterID, "typescript")
        XCTAssertEqual(SourceLanguage.detect(fileName: "a.tsx")?.displayName, "TSX")
        XCTAssertEqual(SourceLanguage.detect(fileName: "a.mjs")?.highlighterID, "javascript")
        XCTAssertEqual(SourceLanguage.detect(fileName: "a.jsx")?.highlighterID, "javascript")
    }

    func testPythonFamily() {
        XCTAssertEqual(SourceLanguage.detect(fileName: "main.py")?.highlighterID, "python")
        XCTAssertEqual(SourceLanguage.detect(fileName: "types.pyi")?.highlighterID, "python")
        XCTAssertEqual(SourceLanguage.detect(fileName: "Gemfile")?.highlighterID, nil)
        XCTAssertEqual(SourceLanguage.detect(fileName: "tool.rb")?.highlighterID, "ruby")
    }

    func testCompiledLanguages() {
        XCTAssertEqual(SourceLanguage.detect(fileName: "main.rs")?.highlighterID, "rust")
        XCTAssertEqual(SourceLanguage.detect(fileName: "main.go")?.highlighterID, "go")
        XCTAssertEqual(SourceLanguage.detect(fileName: "App.swift")?.highlighterID, "swift")
        XCTAssertEqual(SourceLanguage.detect(fileName: "lib.mm")?.displayName, "Objective-C++")
        XCTAssertEqual(SourceLanguage.detect(fileName: "x.cs")?.highlighterID, "csharp")
    }

    func testDataAndConfig() {
        XCTAssertEqual(SourceLanguage.detect(fileName: "package.json")?.highlighterID, "json")
        XCTAssertEqual(SourceLanguage.detect(fileName: "config.yaml")?.highlighterID, "yaml")
        XCTAssertEqual(SourceLanguage.detect(fileName: "Cargo.toml")?.highlighterID, "ini")
        XCTAssertEqual(SourceLanguage.detect(fileName: ".env.local")?.highlighterID, "ini")
        XCTAssertEqual(SourceLanguage.detect(fileName: "query.graphql")?.highlighterID, "graphql")
    }

    func testSpecialFileNames() {
        XCTAssertEqual(SourceLanguage.detect(fileName: "Dockerfile")?.highlighterID, "dockerfile")
        XCTAssertEqual(SourceLanguage.detect(fileName: "Makefile")?.highlighterID, "makefile")
        XCTAssertEqual(SourceLanguage.detect(fileName: "CMakeLists.txt")?.highlighterID, "cmake")
        XCTAssertEqual(SourceLanguage.detect(fileName: ".gitignore")?.displayName, "Git Ignore")
    }

    func testShellByExtension() {
        XCTAssertEqual(SourceLanguage.detect(fileName: "deploy.sh")?.highlighterID, "bash")
        XCTAssertEqual(SourceLanguage.detect(fileName: "setup.ps1")?.highlighterID, "powershell")
    }

    func testNonCodeFilesAreNotDetected() {
        XCTAssertNil(SourceLanguage.detect(fileName: "photo.png"))
        XCTAssertNil(SourceLanguage.detect(fileName: "notes.txt"))
        XCTAssertNil(SourceLanguage.detect(fileName: "archive.zip"))
        XCTAssertNil(SourceLanguage.detect(fileName: "README.md"))
    }

    func testShebangDetection() {
        XCTAssertEqual(
            SourceLanguage.detectFromShebang("#!/usr/bin/env python3")?.highlighterID, "python"
        )
        XCTAssertEqual(
            SourceLanguage.detectFromShebang("#!/bin/bash")?.highlighterID, "bash"
        )
        XCTAssertEqual(
            SourceLanguage.detectFromShebang("#!/usr/bin/env node")?.highlighterID, "javascript"
        )
        XCTAssertNil(SourceLanguage.detectFromShebang("just a comment"))
        XCTAssertNil(SourceLanguage.detectFromShebang(""))
    }

    func testCaseInsensitiveMatching() {
        XCTAssertEqual(SourceLanguage.detect(fileName: "DOCKERFILE")?.highlighterID, "dockerfile")
        XCTAssertEqual(SourceLanguage.detect(fileName: "Main.PY")?.highlighterID, "python")
    }
}
