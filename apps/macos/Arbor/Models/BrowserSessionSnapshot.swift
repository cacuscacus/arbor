import CoreGraphics
import Foundation

/// Disk-backed snapshot of open browser windows (Codable for atomic JSON round-trips).
struct BrowserSessionSnapshot: Codable, Equatable, Sendable {
    var version: Int
    var windows: [BrowserWindowSnapshot]

    init(version: Int = 1, windows: [BrowserWindowSnapshot]) {
        self.version = version
        self.windows = windows
    }
}

struct BrowserWindowSnapshot: Codable, Equatable, Sendable {
    var frame: BrowserWindowFrame?
    var selectedTabIndex: Int
    var tabs: [BrowserTabSnapshot]

    init(frame: BrowserWindowFrame? = nil, selectedTabIndex: Int, tabs: [BrowserTabSnapshot]) {
        self.frame = frame
        self.selectedTabIndex = selectedTabIndex
        self.tabs = tabs
    }
}

struct BrowserTabSnapshot: Codable, Equatable, Sendable {
    /// Folder paths for panes (primary, optional secondary for split).
    var panePaths: [String]
    var focusedPaneIndex: Int

    init(panePaths: [String], focusedPaneIndex: Int = 0) {
        self.panePaths = panePaths
        self.focusedPaneIndex = focusedPaneIndex
    }
}

struct BrowserWindowFrame: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// Reject tiny or absurd frames before applying / persisting.
    var isReasonable: Bool {
        width >= 200 && height >= 200 && width <= 10_000 && height <= 10_000
            && x.isFinite && y.isFinite && width.isFinite && height.isFinite
    }
}

// MARK: - Encode / decode helpers (unit-testable without AppKit windows)

extension BrowserSessionSnapshot {
    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let jsonDecoder = JSONDecoder()

    func jsonData() throws -> Data {
        try Self.jsonEncoder.encode(self)
    }

    static func from(jsonData: Data) throws -> BrowserSessionSnapshot {
        try jsonDecoder.decode(BrowserSessionSnapshot.self, from: jsonData)
    }

    /// Pure round-trip check used by DEBUG self-checks and simple assertions.
    static func roundTripEquals(_ snapshot: BrowserSessionSnapshot) -> Bool {
        do {
            let data = try snapshot.jsonData()
            let decoded = try from(jsonData: data)
            return decoded == snapshot
        } catch {
            return false
        }
    }

    /// Asserts encode → decode identity for a representative fixture.
    @discardableResult
    static func assertRoundTrip() -> Bool {
        let fixture = BrowserSessionSnapshot(
            windows: [
                BrowserWindowSnapshot(
                    frame: BrowserWindowFrame(x: 80, y: 120, width: 1100, height: 700),
                    selectedTabIndex: 1,
                    tabs: [
                        BrowserTabSnapshot(panePaths: ["/tmp"], focusedPaneIndex: 0),
                        BrowserTabSnapshot(
                            panePaths: ["/tmp/a", "/tmp/b"],
                            focusedPaneIndex: 1
                        ),
                    ]
                ),
                BrowserWindowSnapshot(
                    frame: nil,
                    selectedTabIndex: 0,
                    tabs: [
                        BrowserTabSnapshot(panePaths: ["/Users"], focusedPaneIndex: 0),
                    ]
                ),
            ]
        )
        let ok = roundTripEquals(fixture)
        assert(ok, "BrowserSessionSnapshot JSON round-trip failed")
        return ok
    }
}

#if DEBUG
extension BrowserSessionSnapshot {
    static func runSelfCheck() {
        _ = assertRoundTrip()
    }
}
#endif
