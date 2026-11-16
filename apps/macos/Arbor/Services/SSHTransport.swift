import Foundation

nonisolated struct SSHRemoteEntry: Decodable, Sendable {
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: UInt64?
    let modified: UInt32?
    let permissions: UInt32?

    enum CodingKeys: String, CodingKey {
        case name
        case isDirectory = "is_directory"
        case isSymbolicLink = "is_symbolic_link"
        case size
        case modified
        case permissions
    }
}

nonisolated private struct SSHHelperResponse<Result: Decodable>: Decodable {
    let id: UInt64
    let result: Result?
    let error: SSHHelperError?
}

nonisolated private struct SSHHelperError: Decodable {
    let code: String
    let message: String
}

nonisolated private struct EmptyResponse: Decodable {}

nonisolated enum SSHTransportError: LocalizedError, Sendable {
    case helperUnavailable
    case hostKeyVerification(String)
    /// The recorded host key no longer matches: needs an explicit replace.
    case hostKeyChanged(String)
    case authentication(String)
    case connection(String)
    case remote(code: String, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            return "The Arbor SFTP helper is not available."
        case .hostKeyVerification(let message),
             .hostKeyChanged(let message),
             .authentication(let message),
             .connection(let message):
            return message
        case .remote(_, let message):
            return message
        case .invalidResponse:
            return "The SFTP helper returned an invalid response."
        }
    }
}

/// Locates the SFTP helper binary (bundled in the app, or the cargo build
/// tree during development). Shared by the transport (which spawns it) and
/// the askpass service (which ssh re-invokes as $SSH_ASKPASS).
nonisolated enum SSHHelperExecutable {
    static func url() -> URL? {
        let fileManager = FileManager.default
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/arbor-sftp-helper")
        if fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        // Development fallback. #filePath is absolute in local Xcode builds.
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Services
            .deletingLastPathComponent() // Arbor
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // apps
            .deletingLastPathComponent() // repository
        for configuration in ["release", "debug"] {
            let candidate = repository
                .appendingPathComponent("target/\(configuration)/arbor-sftp-helper")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

/// One long-lived helper process per SSH connection. Requests are serialized by
/// the actor while different hosts remain independent.
actor SSHTransportPool {
    static let shared = SSHTransportPool()

    private var connections: [ConnectionID: SSHTransportConnection] = [:]

    func connection(for profile: SSHLocationProfile) -> SSHTransportConnection {
        if let existing = connections[profile.connectionID] {
            return existing
        }
        let connection = SSHTransportConnection(profile: profile)
        connections[profile.connectionID] = connection
        return connection
    }

    func disconnect(_ connectionID: ConnectionID) async {
        guard let connection = connections.removeValue(forKey: connectionID) else { return }
        await connection.close()
    }
}

actor SSHTransportConnection {
    private let profile: SSHLocationProfile
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var readBuffer = Data()
    private var nextID: UInt64 = 1

    init(profile: SSHLocationProfile) {
        self.profile = profile
    }

    func list(path: String) throws -> [SSHRemoteEntry] {
        try request(method: "list", parameters: ["path": path])
    }

    func stat(path: String) throws -> SSHRemoteEntry {
        try request(method: "stat", parameters: ["path": path])
    }

    func createDirectory(path: String) throws {
        let _: EmptyResponse = try request(
            method: "create_directory",
            parameters: ["path": path]
        )
    }

    func createFile(path: String, contents: Data) throws {
        let _: EmptyResponse = try request(
            method: "create_file",
            parameters: [
                "path": path,
                "contents_base64": contents.base64EncodedString(),
            ]
        )
    }

    func rename(from: String, to: String) throws {
        let _: EmptyResponse = try request(
            method: "rename",
            parameters: ["from": from, "to": to]
        )
    }

    func remove(path: String, isDirectory: Bool, recursive: Bool = false) throws {
        let _: EmptyResponse = try request(
            method: "remove",
            parameters: [
                "path": path,
                "is_directory": isDirectory,
                "recursive": recursive,
            ]
        )
    }

    func close() {
        try? input?.close()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        input = nil
        output = nil
        errorOutput = nil
        readBuffer.removeAll(keepingCapacity: false)
    }

    private func request<Result: Decodable>(
        method: String,
        parameters: [String: Any]
    ) throws -> Result {
        try startIfNeeded()
        guard let input, let output else {
            throw SSHTransportError.connection("The SSH connection is unavailable.")
        }

        let id = nextID
        nextID &+= 1
        var payload = parameters
        payload["id"] = id
        payload["method"] = method
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)

        do {
            try input.write(contentsOf: data)
            guard let responseData = try readLine(from: output) else {
                throw startupOrConnectionError()
            }
            let response = try JSONDecoder().decode(
                SSHHelperResponse<Result>.self,
                from: responseData
            )
            guard response.id == id else {
                throw SSHTransportError.invalidResponse
            }
            if let error = response.error {
                throw SSHTransportError.remote(code: error.code, message: error.message)
            }
            guard let result = response.result else {
                throw SSHTransportError.invalidResponse
            }
            return result
        } catch {
            if process?.isRunning == false {
                close()
                throw startupOrConnectionError(fallback: error)
            }
            throw error
        }
    }

    private func startIfNeeded() throws {
        if process?.isRunning == true {
            return
        }
        close()

        guard let executable = SSHHelperExecutable.url() else {
            throw SSHTransportError.helperUnavailable
        }
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = helperArguments
        // Password / passphrase prompts are bridged back to the app via the
        // OpenSSH askpass protocol; ssh inherits these from the helper.
        // Merge with the current environment so SSH_AUTH_SOCK and friends
        // (agent, config paths) keep working.
        var helperEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in SSHAskpassService.shared.envForHelper() {
            helperEnvironment[key] = value
        }
        process.environment = helperEnvironment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw SSHTransportError.connection(error.localizedDescription)
        }
        self.process = process
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        errorOutput = errorPipe.fileHandleForReading
    }

    private var helperArguments: [String] {
        switch profile.endpoint {
        case .openSSHConfigAlias(let alias):
            return ["--destination", alias]
        case .direct(let host, let user, let port):
            var arguments = ["--destination", host, "--port", String(port)]
            if let user, !user.isEmpty {
                arguments += ["--user", user]
            }
            if let identity = profile.identityFile, !identity.isEmpty {
                arguments += ["--identity-file", identity]
            }
            return arguments
        }
    }

    private func readLine(from handle: FileHandle) throws -> Data? {
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer[..<newline]
                readBuffer.removeSubrange(...newline)
                return Data(line)
            }
            // macOS 26: FileHandle.read(upToCount:) on a LIVE pipe waits for
            // EOF instead of returning available data; availableData is the
            // correct blocking-until-data-or-EOF primitive.
            let chunk = handle.availableData
            if chunk.isEmpty {
                return readBuffer.isEmpty ? nil : readBuffer
            }
            readBuffer.append(chunk)
        }
    }

    private func startupOrConnectionError(fallback: Error? = nil) -> SSHTransportError {
        let stderr = (try? errorOutput?.readToEnd())
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = stderr?.isEmpty == false
            ? stderr!
            : fallback?.localizedDescription ?? "The SSH connection closed unexpectedly."
        let lower = message.lowercased()
        if lower.contains("remote host identification has changed")
            || lower.contains("host key verification failed")
            && lower.contains("offending")
        {
            return .hostKeyChanged(message)
        }
        if lower.contains("host key verification failed")
            || lower.contains("no matching host key") {
            return .hostKeyVerification(message)
        }
        if lower.contains("permission denied") || lower.contains("authentication") {
            return .authentication(message)
        }
        return .connection(message)
    }

}
