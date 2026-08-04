import AppKit
import Foundation

/// Manual Help → Check for Updates… against the public GitHub Releases API.
/// Does not download or replace the app — points users at the release page / brew.
enum UpdateCheckService {
    static let brewUpgradeCommand = "brew upgrade --cask arbor"

    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/cacuscacus/arbor/releases/latest"
    )!

    private struct LatestRelease {
        let tagName: String
        let htmlURL: URL
        let name: String?
    }

    /// Entry point from the Help menu. Shows an `NSAlert` when finished.
    static func checkForUpdates() {
        Task { @MainActor in
            await performCheck()
        }
    }

    @MainActor
    private static func performCheck() async {
        #if DEBUG
        AppVersion.runSelfChecks()
        #endif

        let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"

        do {
            let release = try await fetchLatestRelease()
            let latest = AppVersion.strippingVPrefix(release.tagName)
            switch AppVersion.compare(installed, latest) {
            case .orderedAscending:
                showUpdateAvailable(installed: installed, latest: latest, release: release)
            case .orderedSame, .orderedDescending:
                showUpToDate(installed: installed)
            }
        } catch {
            showFailure(error)
        }
    }

    private static func fetchLatestRelease() async throws -> LatestRelease {
        var request = URLRequest(url: latestReleaseURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Arbor-macOS", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tagName = json["tag_name"] as? String,
            !tagName.isEmpty,
            let htmlURLString = json["html_url"] as? String,
            let htmlURL = URL(string: htmlURLString)
        else {
            throw URLError(.cannotParseResponse)
        }

        return LatestRelease(
            tagName: tagName,
            htmlURL: htmlURL,
            name: json["name"] as? String
        )
    }

    @MainActor
    private static func showUpToDate(installed: String) {
        let alert = NSAlert()
        alert.messageText = "You’re up to date"
        alert.informativeText = "Arbor \(installed) is the latest release."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor
    private static func showUpdateAvailable(
        installed: String,
        latest: String,
        release: LatestRelease
    ) {
        let alert = NSAlert()
        alert.messageText = "\(latest) is available"
        var body = "You have \(installed)."
        if let name = release.name, !name.isEmpty, name != release.tagName {
            body += "\n\n\(name)"
        }
        body += "\n\nHomebrew: \(brewUpgradeCommand)"
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Copy Brew Command")
        alert.addButton(withTitle: "OK")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.htmlURL)
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(brewUpgradeCommand, forType: .string)
        default:
            break
        }
    }

    @MainActor
    private static func showFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t check for updates"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Releases on GitHub")

        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "https://github.com/cacuscacus/arbor/releases") {
            NSWorkspace.shared.open(url)
        }
    }
}
