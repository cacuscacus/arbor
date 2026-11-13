import Foundation

nonisolated struct SSHHostKeyCandidate: Identifiable, Sendable {
    let id: ConnectionID
    let host: String
    let port: UInt16
    let knownHostsName: String
    let keyLines: String
    let fingerprints: [String]
    let hasExistingEntry: Bool
}

nonisolated enum SSHHostKeyService {
    static func inspect(_ profile: SSHLocationProfile) async throws -> SSHHostKeyCandidate {
        try await Task.detached {
            let endpoint = try resolvedEndpoint(profile.endpoint)
            let knownHostsName = endpoint.port == 22
                ? endpoint.host
                : "[\(endpoint.host)]:\(endpoint.port)"
            let existing = try run(
                "/usr/bin/ssh-keygen",
                arguments: ["-F", knownHostsName],
                acceptFailure: true
            )
            let keyLines = try run(
                "/usr/bin/ssh-keyscan",
                arguments: [
                    "-T", "10",
                    "-p", String(endpoint.port),
                    endpoint.host,
                ]
            )
            let usableLines = keyLines
                .split(separator: "\n")
                .filter { !$0.hasPrefix("#") }
                .joined(separator: "\n")
            guard !usableLines.isEmpty else {
                throw SSHTransportError.connection("The host did not return an SSH host key.")
            }
            let fingerprints = try run(
                "/usr/bin/ssh-keygen",
                arguments: ["-lf", "-"],
                standardInput: Data((usableLines + "\n").utf8)
            )
            .split(separator: "\n")
            .map(String.init)

            return SSHHostKeyCandidate(
                id: profile.connectionID,
                host: endpoint.host,
                port: endpoint.port,
                knownHostsName: knownHostsName,
                keyLines: usableLines + "\n",
                fingerprints: fingerprints,
                hasExistingEntry: !existing
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            )
        }.value
    }

    static func trust(_ candidate: SSHHostKeyCandidate) async throws {
        try await Task.detached {
            guard !candidate.hasExistingEntry else {
                throw SSHTransportError.hostKeyVerification(
                    "An existing key is already recorded for this host. Resolve the changed key in ~/.ssh/known_hosts before reconnecting."
                )
            }
            let fileManager = FileManager.default
            let sshDirectory = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh", isDirectory: true)
            try fileManager.createDirectory(
                at: sshDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let knownHosts = sshDirectory.appendingPathComponent("known_hosts")
            if !fileManager.fileExists(atPath: knownHosts.path) {
                guard fileManager.createFile(
                    atPath: knownHosts.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw SSHTransportError.connection("Could not create ~/.ssh/known_hosts.")
                }
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: knownHosts.path
            )
            let handle = try FileHandle(forWritingTo: knownHosts)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(candidate.keyLines.utf8))
        }.value
    }

    private static func resolvedEndpoint(_ endpoint: SSHEndpoint) throws -> (
        host: String,
        port: UInt16
    ) {
        switch endpoint {
        case .direct(let host, _, let port):
            return (host, port)
        case .openSSHConfigAlias(let alias):
            let configuration = try run("/usr/bin/ssh", arguments: ["-G", alias])
            var host: String?
            var port: UInt16 = 22
            for line in configuration.split(separator: "\n") {
                let pair = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard pair.count == 2 else { continue }
                switch pair[0].lowercased() {
                case "hostname": host = String(pair[1])
                case "port": port = UInt16(pair[1]) ?? 22
                default: break
                }
            }
            guard let host, !host.isEmpty else {
                throw SSHTransportError.connection("OpenSSH could not resolve alias “\(alias)”.")
            }
            return (host, port)
        }
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        standardInput: Data? = nil,
        acceptFailure: Bool = false
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        if let standardInput {
            let input = Pipe()
            process.standardInput = input
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: standardInput)
            try input.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        process.waitUntilExit()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0, !acceptFailure {
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHTransportError.connection(
                message?.isEmpty == false ? message! : "SSH host-key inspection failed."
            )
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }
}
