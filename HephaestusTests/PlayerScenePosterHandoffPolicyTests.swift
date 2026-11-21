import Foundation
import Testing
@testable import Hephaestus

/// #765 tests a real source-wired player poster policy, not a synthetic
/// published game, WebKit composited pixel or attested gameplay score.
struct PlayerScenePosterHandoffPolicyTests {
    private typealias Policy = PlayerScenePosterHandoffPolicy

    private func fade(
        expected: Int = 8, scene: Int? = 8,
        poster: Bool = true, visible: Bool = true, opacity: Double = 1,
        loaded: Bool = true, hasError: Bool = false, revoked: Bool = false
    ) -> Bool {
        Policy.mayFade(
            expectedAttempt: expected, acceptedSceneAttempt: scene,
            hasHoldPoster: poster, holdVisible: visible, holdOpacity: opacity,
            navigationFinished: loaded, hasLoadError: hasError,
            sessionRevoked: revoked
        )
    }

    private func recover(
        expected: Int = 8, scene: Int? = nil,
        poster: Bool = true, visible: Bool = true, loaded: Bool = true,
        hasError: Bool = false, revoked: Bool = false
    ) -> Bool {
        Policy.shouldOfferNoSceneRecovery(
            expectedAttempt: expected, acceptedSceneAttempt: scene,
            hasHoldPoster: poster, holdVisible: visible,
            navigationFinished: loaded, hasLoadError: hasError,
            sessionRevoked: revoked
        )
    }

    @Test func navigationFinishAloneCannotReleasePoster() {
        #expect(Policy.noSceneTimeoutMilliseconds == 12_000)
        #expect(!fade(scene: nil))
        #expect(!fade(scene: 7))
        #expect(fade())
        #expect(!fade(loaded: false))
        // Prewarm can submit the scene before didFinish; do not fade until
        // native navigation completion for that same current document.
        #expect(!fade(scene: 8, loaded: false))
        #expect(fade(scene: 8, loaded: true))
    }

    @Test func errorsAndRetiredSessionsCannotFadeOrTimeOut() {
        #expect(!fade(hasError: true))
        #expect(!fade(revoked: true))
        #expect(!fade(poster: false))
        #expect(!fade(visible: false))
        #expect(!fade(opacity: 0))
        #expect(!recover(hasError: true))
        #expect(!recover(revoked: true))
        #expect(!recover(poster: false))
        #expect(!recover(visible: false))
        #expect(!recover(loaded: false))
        #expect(!recover(scene: 8))
        #expect(recover(scene: nil))
        #expect(recover(scene: 7))
    }

    @Test func oneHundredSixtyStaleAttemptsNeverReleaseOrRevive() {
        for iteration in 0..<160 {
            let attempt = iteration + 1
            #expect(fade(expected: attempt, scene: attempt))
            #expect(!recover(expected: attempt, scene: attempt))
            #expect(!fade(expected: attempt, scene: nil))
            #expect(recover(expected: attempt, scene: nil))
            #expect(!fade(expected: attempt, scene: attempt - 1))
            #expect(recover(expected: attempt, scene: attempt - 1))
            #expect(!fade(expected: attempt, scene: attempt + 1))
            #expect(recover(expected: attempt, scene: attempt + 1))
            #expect(!fade(expected: attempt, scene: attempt,
                         loaded: false))
            #expect(!recover(expected: attempt, scene: nil,
                            loaded: false))
            #expect(!fade(expected: attempt, scene: attempt, revoked: true))
            #expect(!recover(expected: attempt, scene: nil, revoked: true))
        }
    }
}
