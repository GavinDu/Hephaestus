import Testing
@testable import Hephaestus

@MainActor
struct PlayerFirstSceneTraceTests {
    @Test func onlyCurrentDocumentMayEmitEachFixedCategoryOnceAcross160Epochs() {
        var trace = PlayerFirstSceneTrace()
        var previous: String? = nil
        for cycle in 0..<160 {
            let nonce = String(repeating: "a", count: 28) + String(cycle + 4096, radix: 16)
            trace.prepare(nativeNonce: nonce)
            for stage in PlayerFirstSceneTrace.Stage.allCases {
                let stale = trace.record(stage, nativeNonce: previous)
                let missing = trace.record(stage, nativeNonce: nil)
                #expect(stale == nil)
                #expect(missing == nil)
                let value = trace.record(stage, nativeNonce: nonce)
                #expect(value == "player first-scene trace: " + stage.rawValue)
                #expect(value?.contains(nonce) == false)
                let duplicate = trace.record(stage, nativeNonce: nonce)
                #expect(duplicate == nil)
            }
            previous = nonce
            trace.invalidate()
            let retired = trace.record(.sheetCallbackInvoked, nativeNonce: nonce)
            #expect(retired == nil)
        }
    }

    @Test func malformedPreparedIdentityCannotRecord() {
        var trace = PlayerFirstSceneTrace()
        trace.prepare(nativeNonce: "not-a-native-nonce")
        let malformed = trace.record(.prepared, nativeNonce: "not-a-native-nonce")
        let missing = trace.record(.navigationStarted, nativeNonce: nil)
        #expect(malformed == nil)
        #expect(missing == nil)
    }
}
