import Testing
@testable import Hephaestus

@MainActor
struct PlayerTerminalSceneRevocationPolicyTests {
    @Test func exactNativeHandleOnlyAcross160RepeatedSchedules() {
        for index in 1...160 {
            let nonce = String(repeating: "a", count: 32)
            let nextNonce = String(repeating: "b", count: 32)
            let current = PlayerSceneLaunchTrace.Handle(nonce: nonce, lease: UInt64(index))
            let staleNonce = PlayerSceneLaunchTrace.Handle(nonce: nextNonce, lease: current.lease)
            let staleLease = PlayerSceneLaunchTrace.Handle(nonce: nonce, lease: current.lease - 1)
            #expect(PlayerTerminalSceneRevocationPolicy.mayRetire(
                expected: current, current: current, ownsCurrentAttachment: true, hasCurrentStop: true))
            for stale in [staleNonce, staleLease] {
                #expect(!PlayerTerminalSceneRevocationPolicy.mayRetire(
                    expected: stale, current: current, ownsCurrentAttachment: true, hasCurrentStop: true))
            }
            #expect(!PlayerTerminalSceneRevocationPolicy.mayRetire(
                expected: current, current: current, ownsCurrentAttachment: false, hasCurrentStop: true))
            #expect(!PlayerTerminalSceneRevocationPolicy.mayRetire(
                expected: current, current: current, ownsCurrentAttachment: true, hasCurrentStop: false))
            #expect(!PlayerTerminalSceneRevocationPolicy.mayRetire(
                expected: nil, current: current, ownsCurrentAttachment: true, hasCurrentStop: true))
            #expect(!PlayerTerminalSceneRevocationPolicy.mayRetire(
                expected: current, current: nil, ownsCurrentAttachment: true, hasCurrentStop: true))
        }
    }

    @Test func malformedOrZeroIdentityNeverRetires() {
        for identity in [PlayerSceneLaunchTrace.Handle(nonce: "bad", lease: 1),
                         PlayerSceneLaunchTrace.Handle(nonce: String(repeating: "a", count: 32), lease: 0)] {
            #expect(!PlayerTerminalSceneRevocationPolicy.mayRetire(
                expected: identity, current: identity, ownsCurrentAttachment: true, hasCurrentStop: true))
        }
    }
}
