import Foundation
import Security

/// Non-interactive SSH auth, made interactive: a unix-socket bridge between
/// the OpenSSH askpass protocol (used by the helper's `ssh` child for
/// password and key-passphrase prompts) and a secure prompt sheet in the app.
///
/// The app spawns the SFTP helper with:
///   SSH_ASKPASS_REQUIRE=force
///   SSH_ASKPASS=<this app's helper binary>   (enters askpass mode via env)
///   ARBOR_ASKPASS_SOCKET=<this service's socket path>
///
/// When ssh needs a secret it runs the askpass program, which connects here,
/// forwards the prompt, and blocks until the user answers (or a Keychain
/// entry answers automatically).
///
/// Threading: one thread per accepted connection (connections may overlap
/// when ssh retries). Prompts queue up; the UI shows one sheet at a time
/// (`currentPrompts.first`) and resolves queued prompts in order. Unanswered
/// prompts time out with a cancel reply so ssh never hangs forever.
nonisolated final class SSHAskpassService: @unchecked Sendable {
    static let shared = SSHAskpassService()

    struct Prompt: Identifiable, Sendable {
        let id: UUID
        /// The prompt string ssh produced, e.g. "alice@example.com's password:".
        let question: String
        /// Keychain account key (stable for the same secret).
        let account: String
        let submit: @Sendable (String, Bool) -> Void
        let cancel: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var socketFD: Int32 = -1
    private var socketPath: String?
    private var prompts: [Prompt] = []

    /// UI hook: fires on the handler thread; hop to the main actor in the view.
    var onPromptChange: (() -> Void)?

    private init() {}

    deinit { stop() }

    /// Environment to inherit by every SFTP helper process we spawn.
    func envForHelper() -> [String: String] {
        startIfNeeded()
        guard let socketPath, let helper = SSHHelperExecutable.url() else { return [:] }
        return [
            "SSH_ASKPASS_REQUIRE": "force",
            "SSH_ASKPASS": helper.path,
            "ARBOR_ASKPASS_SOCKET": socketPath,
        ]
    }

    var currentPrompts: [Prompt] {
        lock.lock(); defer { lock.unlock() }
        return prompts
    }

    // MARK: - Listener

    private func startIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard socketFD < 0 else { return }

        // sockaddr_un.sun_path holds 104 bytes on Darwin; keep the path short.
        let shortID = UUID().uuidString.prefix(8)
        let directory = NSTemporaryDirectory() + "aap-\(shortID)"
        guard directory.withCString({ mkdir($0, 0o700) }) == 0 else { return }
        let path = directory + "/s.sock"
        var address = sockaddr_un()
        // Darwin requires sun_len (first byte) for AF_UNIX addresses.
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < 104 else { return }
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: UInt8.self, capacity: 104) { buffer in
                for (index, byte) in pathBytes.enumerated() {
                    buffer[index] = byte
                }
                buffer[pathBytes.count] = 0
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        path.withCString { unlink($0) }
        let bindResult = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(fd, 8) == 0 else {
            close(fd)
            return
        }
        socketFD = fd
        socketPath = path

        let thread = Thread(target: self, selector: #selector(acceptLoop), object: nil)
        thread.name = "Arbor.Askpass"
        thread.start()
    }

    @objc private func acceptLoop() {
        while true {
            lock.lock()
            let fd = socketFD
            lock.unlock()
            guard fd >= 0 else { return }

            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            // One thread per connection: overlapping ssh retries must not
            // block each other's prompts behind a single handler.
            Thread.detachNewThreadSelector(#selector(handleConnection(_:)), toTarget: self, with: NSNumber(value: client))
        }
    }

    @objc private func handleConnection(_ number: NSNumber) {
        handle(client: number.int32Value)
    }

    /// One askpass invocation: read the forwarded prompt, resolve it, reply.
    private func handle(client: Int32) {
        defer { close(client) }
        let handle = FileHandle(fileDescriptor: client, closeOnDealloc: false)
        // See SSHTransport.readLine: read(upToCount:) waits for EOF on live
        // pipes; read until the newline ourselves.
        var requestData = Data()
        while requestData.last != 0x0A {
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            requestData.append(chunk)
            if requestData.count > 1 << 20 { return }
        }
        guard let object = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              let question = object["prompt"] as? String
        else { return }

        let account = Self.accountKey(for: question)
        if let secret = SSHKeychainStore.load(account: account) {
            writeReply(on: handle, json: ["secret": secret])
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        let id = UUID()
        let prompt = Prompt(
            id: id,
            question: question,
            account: account,
            submit: { [weak self] secret, remember in
                if remember {
                    SSHKeychainStore.save(secret, account: account)
                }
                self?.writeReply(on: handle, json: ["secret": secret])
                semaphore.signal()
            },
            cancel: { [weak self] in
                self?.writeReply(on: handle, json: ["cancelled": true])
                semaphore.signal()
            }
        )

        lock.lock()
        prompts.append(prompt)
        lock.unlock()
        notifyPromptChange()

        // Wait for the sheet (Keychain path returns above). Timeout keeps ssh
        // from hanging forever if the user walks away.
        let result = semaphore.wait(timeout: .now() + 300)
        lock.lock()
        prompts.removeAll { $0.id == id }
        lock.unlock()
        if result == .timedOut {
            writeReply(on: handle, json: ["cancelled": true])
        }
        notifyPromptChange()
    }

    /// Called by the sheet after resolving the prompt at the queue's head.
    func removePrompt(id: UUID) {
        lock.lock()
        prompts.removeAll { $0.id == id }
        lock.unlock()
        notifyPromptChange()
    }

    private func notifyPromptChange() {
        onPromptChange?()
    }

    private func writeReply(on handle: FileHandle, json: [String: Any]) {
        let payload = try? JSONSerialization.data(withJSONObject: json)
        var data = payload ?? Data()
        data.append(0x0A)
        try? handle.write(contentsOf: data)
    }

    func stop() {
        lock.lock()
        let fd = socketFD
        socketFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    // MARK: - Prompt interpretation

    /// Stable Keychain account for a given ssh prompt.
    static func accountKey(for question: String) -> String {
        if let range = question.range(of: "'s password:") {
            return "password:\(question[..<range.lowerBound])"
        }
        if question.hasPrefix("Enter passphrase for key "),
           let firstQuote = question.firstIndex(of: "'"),
           let lastQuote = question.lastIndex(of: "'"),
           firstQuote != lastQuote
        {
            let path = question[question.index(after: firstQuote)..<lastQuote]
            return "passphrase:\(path)"
        }
        return "prompt:\(question)"
    }
}

/// Login-keychain storage for remembered SSH secrets. Per-app access:
/// entries are only readable by Arbor.
nonisolated enum SSHKeychainStore {
    private static let service = "cacus.Arbor.ssh"

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ secret: String, account: String) {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
