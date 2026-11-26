import Foundation

nonisolated struct MLXExpansionResult: Sendable {
    let terms: [String]
    let elapsedMs: Double
    let modelID: String
    let fromCache: Bool
}

nonisolated enum MLXExpansionError: LocalizedError, Sendable {
    case runtimeNotFound
    case helperScriptMissing
    case helperFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .runtimeNotFound:
            return "mlx-lm Python runtime not found. Install with `brew install mlx-lm` or set a custom Python path in Settings → Search."
        case .helperScriptMissing:
            return "Bundled arbor_mlx_helper.py script is missing from Arbor.app."
        case .helperFailed(let detail):
            return detail
        case .timedOut:
            return "Local MLX expansion timed out."
        }
    }
}

/// Manages a persistent, isolated `arbor_mlx_helper.py` child process for opt-in local
/// MLX term expansion. Keeps quantized weights warm across searches (~230 ms/query on 2B-8bit)
/// and terminates the helper cleanly after the configured idle TTL so 0 MB Metal RAM is held at rest.
actor MLXExpansionService {
    static let shared = MLXExpansionService()
    private static let activeProcessLock = NSLock()
    private nonisolated(unsafe) static var activePID: pid_t = 0

    /// Synchronous shutdown hook called from `applicationWillTerminate` so no helper
    /// process is ever orphaned after Arbor quits.
    static nonisolated func terminateHelperSync() {
        activeProcessLock.lock()
        let pid = activePID
        activePID = 0
        activeProcessLock.unlock()
        if pid > 0 {
            kill(pid, SIGTERM)
        }
    }

    private let cache = SearchExpansionCache(capacity: 128)
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutReader: AsyncLineReader?
    private var activePythonPath: String?
    private var nextRequestID = 1
    private var idleUnloadTask: Task<Void, Never>?
    private(set) var loadedModelID: String?

    /// Resolves a usable `mlx_lm`-capable Python binary from an explicit override or standard Homebrew locations.
    static nonisolated func detectPythonPath(override: String = "") -> String? {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) {
            return trimmed
        }

        // 1. Parse shebang of `mlx_lm.generate` if installed via Homebrew or pipx/uv.
        let home = NSHomeDirectory()
        let cliCandidates = [
            "/opt/homebrew/bin/mlx_lm.generate",
            "/usr/local/bin/mlx_lm.generate",
            "\(home)/.local/bin/mlx_lm.generate",
        ]
        for cli in cliCandidates {
            if let shebangPython = parseShebangPython(at: cli),
               FileManager.default.isExecutableFile(atPath: shebangPython)
            {
                return shebangPython
            }
        }

        // 2. Scan Homebrew Cellar directly (even when PATH isn't inherited by GUI apps).
        let cellarDirs = ["/opt/homebrew/Cellar/mlx-lm", "/usr/local/Cellar/mlx-lm"]
        for dir in cellarDirs {
            if let versions = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                for ver in versions.sorted().reversed() {
                    let candidate = "\(dir)/\(ver)/libexec/bin/python"
                    if FileManager.default.isExecutableFile(atPath: candidate) {
                        return candidate
                    }
                }
            }
        }
        return nil
    }

    private static nonisolated func parseShebangPython(at path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256),
              let firstLine = String(data: data, encoding: .utf8)?.components(separatedBy: .newlines).first,
              firstLine.hasPrefix("#!")
        else { return nil }
        let raw = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.components(separatedBy: " ").first
    }

    private static nonisolated func resolveHelperScriptPath() -> String? {
        if let bundled = Bundle.main.path(forResource: "arbor_mlx_helper", ofType: "py") {
            return bundled
        }
        // Fallback for dev/CLI runs outside .app bundle.
        let devPaths = [
            "\(FileManager.default.currentDirectoryPath)/apps/macos/Arbor/Resources/arbor_mlx_helper.py",
        ]
        return devPaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    func expand(
        query: String,
        mode: SearchMode,
        modelID: String,
        pythonPathOverride: String = "",
        idleUnloadMinutes: Int = 5
    ) async throws -> MLXExpansionResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            return MLXExpansionResult(terms: [], elapsedMs: 0, modelID: modelID, fromCache: true)
        }

        if let cached = cache.get(modelID: modelID, mode: mode, query: trimmed) {
            return MLXExpansionResult(terms: cached, elapsedMs: 0, modelID: modelID, fromCache: true)
        }

        guard let pythonPath = Self.detectPythonPath(override: pythonPathOverride) else {
            throw MLXExpansionError.runtimeNotFound
        }
        guard let scriptPath = Self.resolveHelperScriptPath() else {
            throw MLXExpansionError.helperScriptMissing
        }

        try ensureProcessRunning(pythonPath: pythonPath, scriptPath: scriptPath)
        scheduleIdleUnload(minutes: idleUnloadMinutes)

        let reqID = nextRequestID
        nextRequestID += 1
        let payload: [String: Any] = [
            "op": "expand",
            "id": reqID,
            "query": trimmed,
            "mode": mode == .content ? "content" : "name",
            "model": modelID,
            "max_tokens": 48,
        ]

        let isColdLoad = (loadedModelID != modelID)
        let timeoutSeconds: Double = isColdLoad ? 120.0 : 10.0

        let response = try await sendRequest(payload, expectedID: reqID, timeoutSeconds: timeoutSeconds)
        scheduleIdleUnload(minutes: idleUnloadMinutes)

        guard let ok = response["ok"] as? Bool, ok else {
            let errText = response["error"] as? String ?? "MLX helper returned an error"
            throw MLXExpansionError.helperFailed(errText)
        }

        loadedModelID = response["model"] as? String ?? modelID
        let raw = response["raw"] as? String ?? ""
        let elapsedMs = response["elapsed_ms"] as? Double ?? 0
        let terms = SearchExpansionPostProcessor.process(
            raw: raw,
            originalQuery: trimmed,
            maxTerms: 5
        )
        cache.set(modelID: modelID, mode: mode, query: trimmed, terms: terms)
        return MLXExpansionResult(terms: terms, elapsedMs: elapsedMs, modelID: modelID, fromCache: false)
    }

    func unload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        terminateProcess()
    }

    func clearCache() {
        cache.clear()
    }

    // MARK: - Isolated Child Process Lifecycle

    private func ensureProcessRunning(pythonPath: String, scriptPath: String) throws {
        if let proc = process, proc.isRunning, activePythonPath == pythonPath {
            return
        }
        terminateProcess()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = ["-u", scriptPath]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        proc.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        // Drain stderr asynchronously so HF/MLX warnings never block the pipe buffer.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        try proc.run()
        Self.activeProcessLock.lock()
        Self.activePID = proc.processIdentifier
        Self.activeProcessLock.unlock()
        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutReader = AsyncLineReader(handle: stdoutPipe.fileHandleForReading)
        activePythonPath = pythonPath
        loadedModelID = nil
    }

    private func sendRequest(
        _ payload: [String: Any],
        expectedID: Int,
        timeoutSeconds: Double
    ) async throws -> [String: Any] {
        guard let stdinHandle, let stdoutReader else {
            throw MLXExpansionError.helperFailed("Helper pipes not initialized")
        }
        var lineData = try JSONSerialization.data(withJSONObject: payload)
        lineData.append(0x0A)
        try stdinHandle.write(contentsOf: lineData)

        let deadline = ContinuousClock.now + .milliseconds(Int(timeoutSeconds * 1000))
        while true {
            try Task.checkCancellation()
            let remaining = deadline - ContinuousClock.now
            let remainingSec = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            if remainingSec <= 0 {
                terminateProcess()
                throw MLXExpansionError.timedOut
            }
            guard let line = try await stdoutReader.nextLine(timeoutSeconds: remainingSec) else {
                terminateProcess()
                throw MLXExpansionError.helperFailed("MLX helper exited unexpectedly")
            }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                // Ignore any stray non-JSON stdout lines emitted by libraries.
                continue
            }
            if let id = obj["id"] as? Int, id == expectedID {
                return obj
            }
        }
    }

    private func scheduleIdleUnload(minutes: Int) {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        guard minutes > 0 else { return }
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    private func terminateProcess() {
        Self.activeProcessLock.lock()
        Self.activePID = 0
        Self.activeProcessLock.unlock()
        if let proc = process {
            if proc.isRunning {
                proc.terminate()
            }
        }
        process = nil
        stdinHandle = nil
        stdoutReader?.close()
        stdoutReader = nil
        activePythonPath = nil
        loadedModelID = nil
    }
}

/// Non-blocking line reader for a child process's stdout FileHandle with timeout + cancellation.
private nonisolated final class AsyncLineReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var pendingLines: [String] = []
    private var eof = false
    private var waiter: CheckedContinuation<String?, Never>?

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            self?.ingest(chunk)
        }
    }

    private func ingest(_ chunk: Data) {
        lock.lock()
        if chunk.isEmpty {
            eof = true
            let w = waiter
            waiter = nil
            lock.unlock()
            w?.resume(returning: nil)
            return
        }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let line = String(data: lineData, encoding: .utf8) {
                pendingLines.append(line)
            }
        }
        if !pendingLines.isEmpty, let w = waiter {
            let next = pendingLines.removeFirst()
            waiter = nil
            lock.unlock()
            w.resume(returning: next)
            return
        }
        lock.unlock()
    }

    func nextLine(timeoutSeconds: Double) async throws -> String? {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { [self] in
                await self.readOneLine()
            }
            group.addTask {
                try await Task.sleep(for: .milliseconds(max(100, Int(timeoutSeconds * 1000))))
                throw MLXExpansionError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    private func readOneLine() async -> String? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                lock.lock()
                if !pendingLines.isEmpty {
                    let line = pendingLines.removeFirst()
                    lock.unlock()
                    cont.resume(returning: line)
                } else if eof {
                    lock.unlock()
                    cont.resume(returning: nil)
                } else {
                    waiter = cont
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let w = waiter
            waiter = nil
            lock.unlock()
            w?.resume(returning: nil)
        }
    }

    func close() {
        handle.readabilityHandler = nil
        lock.lock()
        eof = true
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: nil)
    }
}
