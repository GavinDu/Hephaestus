import Testing
@testable import Hephaestus

@MainActor
struct PlayerUnboundSceneObservationWindowTests {
    @Test func onlyUnboundClaimsAndCanonicalBoundedOutput() {
        let current = String(repeating: "a", count: 32)
        let other = String(repeating: "b", count: 32)
        var window = PlayerUnboundSceneObservationWindow()
        for _ in 0..<160 {
            window.observe(schema: 2, nonce: current, currentNonce: current)
        }
        #expect(window.freeze() == "none")
        window.observe(schema: 1, nonce: nil, currentNonce: current)
        #expect(window.freeze() == "none")
        window.reset()
        for _ in 0..<160 {
            window.observe(schema: 99, nonce: other, currentNonce: current)
            window.observe(schema: 2, nonce: other, currentNonce: current)
            window.observe(schema: 2, nonce: "private-invalid", currentNonce: current)
            window.observe(schema: 1, nonce: nil, currentNonce: current)
            window.observe(schema: 2, nonce: current, currentNonce: current)
        }
        let output = window.freeze()
        #expect(output == "legacySchema,invalidV2Nonce,mismatchedV2Nonce,unknownSchema")
        #expect(!output.contains(current))
        #expect(!output.contains(other))
        #expect(!output.contains("private-invalid"))
        window.reset()
        window.observe(schema: 1, nonce: nil, currentNonce: nil)
        #expect(window.freeze() == "none")
    }

    @Test func resetAndFreezeAcrossRepeatedNavigationWindows() {
        var window = PlayerUnboundSceneObservationWindow()
        let current = String(repeating: "a", count: 32)
        for _ in 0..<160 {
            window.reset()
            window.observe(schema: 1, nonce: nil, currentNonce: current)
            #expect(window.freeze() == "legacySchema")
            window.observe(schema: 2, nonce: nil, currentNonce: current)
            #expect(window.freeze() == "legacySchema")
            window.reset()
            #expect(window.freeze() == "none")
        }
    }
}
