import XCTest
@testable import ArborPure

final class SearchQueryExpanderTests: XCTestCase {

    func testPostProcessorParsesCleanJSONAndStripsNoiseEchoesAndDuplicates() {
        let raw = """
        ["Electricity", "electricidad", "factura", "luz", "file", "document", "bill", "invoice", "bill", "a very long sentence explaining things", "utility"]
        """
        let terms = SearchExpansionPostProcessor.process(
            raw: raw,
            originalQuery: "factura luz",
            maxTerms: 5
        )
        XCTAssertEqual(terms, ["electricity", "electricidad", "bill", "invoice", "utility"])
    }

    func testPostProcessorStripsThinkTagsAndMarkdownFences() {
        let raw = """
        <think>Let me think about Spanish billing terms...</think>
        ```json
        ["lease", "rental", "tenancy", "arrendamiento", "contrato"]
        ```
        """
        let terms = SearchExpansionPostProcessor.process(
            raw: raw,
            originalQuery: "contrato alquiler",
            maxTerms: 5
        )
        XCTAssertEqual(terms, ["lease", "rental", "tenancy", "arrendamiento"])
    }

    func testPostProcessorDeduplicatesAccentsAndCase() {
        let terms = SearchExpansionPostProcessor.filter(
            terms: ["Energía", "energia", "ENERGIA", "recibo", "Recíbo"],
            originalQuery: "luz",
            maxTerms: 5
        )
        XCTAssertEqual(terms, ["energía", "recibo"])
    }

    func testExpansionCacheIsolatesByModelAndModeAndEvictsLRU() {
        let cache = SearchExpansionCache(capacity: 2)
        cache.set(modelID: "m1", mode: .name, query: "Factura Luz", terms: ["electricity", "bill"])
        cache.set(modelID: "m1", mode: .content, query: "factura luz", terms: ["kwh", "voltage"])

        XCTAssertEqual(cache.get(modelID: "m1", mode: .name, query: "factura luz"), ["electricity", "bill"])
        XCTAssertEqual(cache.get(modelID: "m1", mode: .content, query: "factura luz"), ["kwh", "voltage"])
        XCTAssertNil(cache.get(modelID: "m2", mode: .name, query: "factura luz"))

        // Touching `.name` makes `.content` the LRU; adding a 3rd entry evicts `.content`.
        _ = cache.get(modelID: "m1", mode: .name, query: "factura luz")
        cache.set(modelID: "m1", mode: .name, query: "tax return", terms: ["irs", "w2"])

        XCTAssertNotNil(cache.get(modelID: "m1", mode: .name, query: "factura luz"))
        XCTAssertNil(cache.get(modelID: "m1", mode: .content, query: "factura luz"))
        XCTAssertEqual(cache.get(modelID: "m1", mode: .name, query: "tax return"), ["irs", "w2"])
    }

    func testExpandedRingAlwaysSortsStrictlyBelowGlobalRing() {
        var merger = SearchRingMerger<String>(limit: 10)
        merger.insert(canonicalPath: "/expanded.pdf", ring: .expanded, item: "expanded")
        merger.insert(canonicalPath: "/global.pdf", ring: .global, item: "global")
        merger.insert(canonicalPath: "/local.pdf", ring: .currentFolderDirect, item: "local")
        XCTAssertEqual(merger.orderedItems, ["local", "global", "expanded"])
    }

    @MainActor
    func testSmartExpansionPreferencesAreStrictlyOptInByDefault() {
        let suiteName = "arbor.test.mlxPrefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SearchPreferencesStore(defaults: defaults)
        XCTAssertFalse(store.smartExpansionEnabled)
        XCTAssertEqual(store.smartExpansionModelPreset, .balanced2B8Bit)
        XCTAssertEqual(store.smartExpansionIdleUnloadMinutes, 5)
        XCTAssertEqual(store.resolvedSmartExpansionModelID, "mlx-community/Qwen3.5-2B-8bit")

        store.smartExpansionEnabled = true
        store.smartExpansionModelPreset = .custom
        store.smartExpansionCustomModelID = "mlx-community/my-custom-model"
        store.smartExpansionIdleUnloadMinutes = 10

        let reloaded = SearchPreferencesStore(defaults: defaults)
        XCTAssertTrue(reloaded.smartExpansionEnabled)
        XCTAssertEqual(reloaded.smartExpansionModelPreset, .custom)
        XCTAssertEqual(reloaded.resolvedSmartExpansionModelID, "mlx-community/my-custom-model")
        XCTAssertEqual(reloaded.smartExpansionIdleUnloadMinutes, 10)

        reloaded.resetDefaults()
        XCTAssertFalse(reloaded.smartExpansionEnabled)
        XCTAssertEqual(reloaded.smartExpansionModelPreset, .balanced2B8Bit)
    }
}
