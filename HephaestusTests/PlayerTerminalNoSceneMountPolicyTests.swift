import Testing
@testable import Hephaestus

/// #770 narrow pure mount/lease-path guard; not physical thermal evidence.
struct PlayerTerminalNoSceneMountPolicyTests {
    @Test func normalAndManualRetryMountButTerminalAttemptDoesNot() {
        let policy = PlayerTerminalNoSceneMountPolicy.self
        #expect(policy.shouldMount(currentAttempt: 0, terminalNoSceneAttempt: nil))
        #expect(!policy.shouldMount(currentAttempt: 8, terminalNoSceneAttempt: 8))
        #expect(policy.shouldMount(currentAttempt: 9, terminalNoSceneAttempt: 8))
        #expect(policy.shouldMount(currentAttempt: 7, terminalNoSceneAttempt: 8))
    }

    @Test func oneHundredSixtyTerminalRetryEpochsStayIsolated() {
        for attempt in 0..<160 {
            #expect(PlayerTerminalNoSceneMountPolicy.shouldMount(
                currentAttempt: attempt, terminalNoSceneAttempt: nil
            ))
            #expect(!PlayerTerminalNoSceneMountPolicy.shouldMount(
                currentAttempt: attempt, terminalNoSceneAttempt: attempt
            ))
            #expect(PlayerTerminalNoSceneMountPolicy.shouldMount(
                currentAttempt: attempt + 1, terminalNoSceneAttempt: attempt
            ))
            #expect(PlayerTerminalNoSceneMountPolicy.shouldMount(
                currentAttempt: attempt, terminalNoSceneAttempt: attempt + 1
            ))
        }
    }
}
