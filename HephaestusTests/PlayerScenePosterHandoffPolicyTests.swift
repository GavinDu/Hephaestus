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

    private func readiness(
        expected: Int = 8, scene: Int? = nil, terminal: Int? = nil,
        valid: Bool = true, loaded: Bool = true,
        hasError: Bool = false, revoked: Bool = false
    ) -> PlayerFirstSceneWaitPolicy.State {
        PlayerFirstSceneWaitPolicy.state(
            currentAttempt: expected, acceptedSceneAttempt: scene,
            terminalAttempt: terminal, hasValidPlayerRequest: valid,
            navigationFinished: loaded, hasLoadError: hasError,
            sessionRevoked: revoked
        )
    }

    private func recover(
        expected: Int = 8, scene: Int? = nil, terminal: Int? = nil,
        valid: Bool = true, loaded: Bool = true,
        hasError: Bool = false, revoked: Bool = false,
        foreground: Bool = true
    ) -> Bool {
        PlayerFirstSceneWaitPolicy.shouldOfferNoSceneRecovery(
            state: readiness(expected: expected, scene: scene, terminal: terminal,
                             valid: valid, loaded: loaded,
                             hasError: hasError, revoked: revoked),
            navigationFinished: loaded, isForeground: foreground
        )
    }

    @Test func navigationFinishAloneCannotReleasePoster() {
        #expect(PlayerFirstSceneWaitPolicy.noSceneTimeoutMilliseconds == 12_000)
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
        #expect(!recover(foreground: false))
        #expect(!recover(valid: false))
        #expect(!recover(terminal: 8))
        #expect(recover(terminal: 7))
        #expect(!recover(loaded: false))
        #expect(!recover(scene: 8))
        #expect(recover(scene: nil))
        #expect(recover(scene: 7))
    }

    @Test func optionalPosterNeverControlsReadinessOrTimeout() {
        // No poster state is passed to the independent launch policy.
        #expect(readiness() == .waiting)
        #expect(readiness(loaded: false) == .waiting)
        #expect(readiness(scene: 8, loaded: false) == .waiting)
        #expect(readiness(scene: 8) == .ready)
        #expect(readiness(scene: 7) == .waiting)
        #expect(readiness(scene: 9) == .waiting)
        #expect(readiness(scene: 8, terminal: 8) == .unavailable)
        #expect(readiness(scene: 8, terminal: 7) == .ready)
        #expect(readiness(scene: 8, valid: false) == .unavailable)
        #expect(readiness(scene: 8, hasError: true) == .unavailable)
        #expect(readiness(scene: 8, revoked: true) == .unavailable)
        #expect(recover())
        #expect(!recover(loaded: false))
        #expect(!recover(foreground: false))
        #expect(!recover(scene: 8))
    }

    @Test func missingSceneTimeoutMustNotTriggerNetworkAutoReload() {
        // A renderer that never submits a scene is not proof of an offline
        // connection. The watchdog is manual recovery, not network retry.
        let category: PlayerLoadFailure.Category = .unknown
        #expect(PlayerLoadRetryPolicy.shouldOfferManualRetry(category: category))
        #expect(!PlayerLoadRetryPolicy.shouldRetryOnForeground(category: category))
        #expect(!PlayerLoadRetryPolicy.shouldRetryOnConnectivityRestored(
            wasOffline: true, isOffline: false, category: category,
            hasError: true, sessionRevoked: false
        ))
    }

    @Test func oneHundredSixtyStaleAttemptsNeverReleaseOrRevive() {
        for iteration in 0..<160 {
            let attempt = iteration + 1
            #expect(fade(expected: attempt, scene: attempt))
            #expect(!recover(expected: attempt, scene: attempt))
            #expect(!fade(expected: attempt, scene: nil))
            #expect(recover(expected: attempt, scene: nil))
            #expect(!recover(expected: attempt, scene: nil, foreground: false))
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
            #expect(readiness(expected: attempt, scene: attempt - 1) == .waiting)
            #expect(readiness(expected: attempt, scene: attempt, loaded: false) == .waiting)
            #expect(readiness(expected: attempt, scene: attempt) == .ready)
            #expect(readiness(expected: attempt, scene: attempt, terminal: attempt) == .unavailable)
            #expect(!recover(expected: attempt, terminal: attempt))
            #expect(recover(expected: attempt, terminal: attempt - 1))
            #expect(!recover(expected: attempt, valid: false))
        }
    }
}
