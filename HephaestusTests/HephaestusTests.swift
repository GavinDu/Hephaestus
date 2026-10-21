import Foundation
import Testing
@testable import Hephaestus

// The Game IR runtime test suite retired with the native Swift
// interpreter (removed 2026-10-20 in the single-runtime consolidation).
// Runtime conformance now lives with the PixiJS + Rapier runtime in the
// backend repository, which interprets the same Game IR packages.
// App-level tests will regrow around the WebView player and the
// creation flow.
struct HephaestusTests {
    @Test func backendConfigIsSane() {
        #expect(BackendConfig.baseURL.scheme == "https")
        #expect(!BackendConfig.userID.isEmpty)
    }

    @Test func devLogRecordsAndExports() {
        let before = DevLog.shared.count
        DevLog.info(.app, "test entry")
        #expect(DevLog.shared.count == before + 1)
        #expect(DevLog.shared.exportText().contains("test entry"))
    }
}
