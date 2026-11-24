import Foundation

/// Opt-in drag & drop diagnostics.
///
/// Enable with `ARBOR_DND_DEBUG=1` when launching the app; appends to
/// `/tmp/arbor-dnd.log`. Disabled by default, so it costs nothing in normal
/// use. The log is meant to diagnose "the drop did nothing" reports: it records
/// what the source published, what AppKit proposed as a target, and what the
/// drop actually resolved to.
nonisolated enum DragDebugLog {
    static let isEnabled: Bool =
        ProcessInfo.processInfo.environment["ARBOR_DND_DEBUG"] == "1"

    static func log(_ message: String) {
        guard isEnabled else { return }
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/arbor-dnd.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
