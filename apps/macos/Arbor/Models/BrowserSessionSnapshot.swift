import CoreGraphics
import Foundation

/// Disk-backed snapshot of open browser windows (Codable for atomic JSON round-trips).
struct BrowserSessionSnapshot: Codable, Equatable, Sendable {
    var version: Int
    var windows: [BrowserWindowSnapshot]

    init(version: Int = 2, windows: [BrowserWindowSnapshot]) {
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
    /// Provider-neutral pane roots (primary, optional secondary for split).
    var paneItems: [ItemRef]
    var focusedPaneIndex: Int

    init(paneItems: [ItemRef], focusedPaneIndex: Int = 0) {
        self.paneItems = paneItems
        self.focusedPaneIndex = focusedPaneIndex
    }

    /// Compatibility initializer used by old fixtures and v1 path snapshots.
    init(panePaths: [String], focusedPaneIndex: Int = 0) {
        self.init(
            paneItems: panePaths.map {
                LocalFileLocation.item(for: URL(fileURLWithPath: $0))
            },
            focusedPaneIndex: focusedPaneIndex
        )
    }

    private enum CodingKeys: String, CodingKey {
        case paneItems
        case panePaths
        case focusedPaneIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        focusedPaneIndex = try container.decodeIfPresent(
            Int.self,
            forKey: .focusedPaneIndex
        ) ?? 0

        if let items = try container.decodeIfPresent([ItemRef].self, forKey: .paneItems) {
            paneItems = items
            return
        }
        let paths = try container.decodeIfPresent([String].self, forKey: .panePaths) ?? []
        paneItems = paths.map {
            LocalFileLocation.item(for: URL(fileURLWithPath: $0))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(paneItems, forKey: .paneItems)
        try container.encode(focusedPaneIndex, forKey: .focusedPaneIndex)
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

    /// v1 stored only local `panePaths`; v2 decodes them into local ItemRefs.
    @discardableResult
    static func assertLegacyPathMigration() -> Bool {
        let legacy = """
        {
          "version": 1,
          "windows": [{
            "selectedTabIndex": 0,
            "tabs": [{
              "focusedPaneIndex": 0,
              "panePaths": ["/tmp"]
            }]
          }]
        }
        """
        do {
            let decoded = try from(jsonData: Data(legacy.utf8))
            guard let item = decoded.windows.first?.tabs.first?.paneItems.first else {
                assertionFailure("Legacy session did not produce a pane item")
                return false
            }
            let ok = item.path == "/tmp" && item.localURL?.path == "/tmp"
            assert(ok, "Legacy panePaths migration produced the wrong ItemRef")
            return ok
        } catch {
            assertionFailure("Legacy session migration failed: \(error)")
            return false
        }
    }
}

#if DEBUG
extension BrowserSessionSnapshot {
    static func runSelfCheck() {
        _ = assertRoundTrip()
        _ = assertLegacyPathMigration()
    }
}
#endif
