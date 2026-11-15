import Foundation
import Testing
@testable import Hephaestus

private func posterAttempt(
    gameID: String = "published-game",
    playerURL: String = "https://games.example.test/player?game=published-game&quality=low",
    documentNonce: String = String(repeating: "a", count: 32),
    fingerprint: String = "credential-epoch-hash",
    lease: UInt64 = 17
) -> PlayerPosterHoldPolicy.Attempt {
    PlayerPosterHoldPolicy.Attempt(
        gameID: gameID,
        playerURL: URL(string: playerURL)!,
        documentNonce: documentNonce,
        credentialFingerprint: fingerprint,
        attachmentLease: lease
    )
}

@Test func playerPosterNavigationReadyNeverReleasesCover() {
    let current = posterAttempt()
    var poster = PlayerPosterHoldPolicy(attempt: current)
    #expect(current.isValid)
    #expect(poster.mustHoldPoster)
    #expect(!poster.mayBeginSceneSubmittedCrossfade)
    poster.noteNavigationFinish(for: current)
    #expect(poster.navigationFinished)
    #expect(poster.state == .holding)
    #expect(poster.mustHoldPoster)
    #expect(!poster.mayBeginSceneSubmittedCrossfade)

    // Repeated didFinish and a stale document cannot fake scene readiness.
    poster.noteNavigationFinish(for: current)
    poster.noteNavigationFinish(for: posterAttempt(documentNonce: String(repeating: "b", count: 32)))
    #expect(poster.state == .holding)
    #expect(!poster.mayBeginSceneSubmittedCrossfade)
}

@Test func playerPosterAcceptsOnlyOneTrustedCurrentAttachmentScene() {
    let current = posterAttempt()
    var poster = PlayerPosterHoldPolicy(attempt: current)
    // Prewarmed WebKit can submit its first scene before didFinish or
    // before SwiftUI attachment; a validated exact-once transfer is needed.
    let observedPosterTransition1 = !poster.acceptTrustedSceneSubmission(
        for: current, validatedByNativeGate: false, ownsCurrentAttachment: true)
    #expect(observedPosterTransition1)
    let observedPosterTransition2 = !poster.acceptTrustedSceneSubmission(
        for: current, validatedByNativeGate: true, ownsCurrentAttachment: false)
    #expect(observedPosterTransition2)
    #expect(poster.mustHoldPoster)
    let observedPosterTransition3 = poster.acceptTrustedSceneSubmission(
        for: current, validatedByNativeGate: true, ownsCurrentAttachment: true)
    #expect(observedPosterTransition3)
    #expect(poster.state == .sceneSubmitted)
    #expect(poster.mayBeginSceneSubmittedCrossfade)
    let observedPosterTransition4 = !poster.acceptTrustedSceneSubmission(
        for: current, validatedByNativeGate: true, ownsCurrentAttachment: true)
    #expect(observedPosterTransition4)
    poster.noteNavigationFinish(for: current)
    #expect(!poster.navigationFinished)
    // The first scene milestone is *not* compositor presentation.
    let observedPosterTransition5 = !poster.markTimeout(for: current, ownsCurrentAttachment: true)
    #expect(observedPosterTransition5)
    #expect(poster.mayBeginSceneSubmittedCrossfade)
}

@Test func playerPosterRejectsCrossGameNonceURLLeaseAndCredentialTransitions() {
    let current = posterAttempt()
    let foreign = [
        posterAttempt(gameID: "another-published-game"),
        posterAttempt(playerURL: "https://games.example.test/player?game=published-game&quality=high"),
        posterAttempt(documentNonce: String(repeating: "b", count: 32)),
        posterAttempt(fingerprint: "second-account-hash"),
        posterAttempt(lease: 18),
        posterAttempt(playerURL: "https://different.example.test/player?game=published-game&quality=low")
    ]
    var poster = PlayerPosterHoldPolicy(attempt: current)
    for wrong in foreign {
        poster.noteNavigationFinish(for: wrong)
        let observedPosterTransition6 = !poster.acceptTrustedSceneSubmission(
            for: wrong, validatedByNativeGate: true, ownsCurrentAttachment: true)
        #expect(observedPosterTransition6)
        let observedPosterTransition7 = !poster.markTimeout(for: wrong, ownsCurrentAttachment: true)
        #expect(observedPosterTransition7)
        let observedPosterTransition8 = !poster.markFailure(for: wrong, ownsCurrentAttachment: true)
        #expect(observedPosterTransition8)
        #expect(poster.state == .holding)
        #expect(!poster.navigationFinished)
    }
    let observedPosterTransition9 = poster.acceptTrustedSceneSubmission(
        for: current, validatedByNativeGate: true, ownsCurrentAttachment: true)
    #expect(observedPosterTransition9)
}

@Test func playerPosterTimeoutFailureAndRetirementCannotBeResurrected() {
    let current = posterAttempt()
    var timedOut = PlayerPosterHoldPolicy(attempt: current)
    let observedPosterTransition10 = !timedOut.markTimeout(for: current, ownsCurrentAttachment: false)
    #expect(observedPosterTransition10)
    let observedPosterTransition11 = timedOut.markTimeout(for: current, ownsCurrentAttachment: true)
    #expect(observedPosterTransition11)
    #expect(timedOut.mustShowRecovery)
    #expect(!timedOut.mayBeginSceneSubmittedCrossfade)
    let observedPosterTransition12 = !timedOut.acceptTrustedSceneSubmission(
        for: current, validatedByNativeGate: true, ownsCurrentAttachment: true)
    #expect(observedPosterTransition12)
    let observedPosterTransition13 = !timedOut.markTimeout(for: current, ownsCurrentAttachment: true)
    #expect(observedPosterTransition13)

    var failed = PlayerPosterHoldPolicy(attempt: current)
    let observedPosterTransition14 = failed.acceptTrustedSceneSubmission(
        for: current, validatedByNativeGate: true, ownsCurrentAttachment: true)
    #expect(observedPosterTransition14)
    let observedPosterTransition15 = failed.markFailure(for: current, ownsCurrentAttachment: true)
    #expect(observedPosterTransition15)
    #expect(failed.mustShowRecovery)
    let observedPosterTransition16 = !failed.acceptTrustedSceneSubmission(
        for: current, validatedByNativeGate: true, ownsCurrentAttachment: true)
    #expect(observedPosterTransition16)
    failed.retire()
    #expect(failed.state == .retired)
    let observedPosterTransition17 = !failed.markFailure(for: current, ownsCurrentAttachment: true)
    #expect(observedPosterTransition17)
    failed.noteNavigationFinish(for: current)
    #expect(!failed.navigationFinished)
    #expect(!failed.mayBeginSceneSubmittedCrossfade)
}

@Test func playerPosterRejectsInvalidIdentityAnd160StaleDocumentReplays() {
    for invalid in [
        posterAttempt(playerURL: "http://games.example.test/player"),
        posterAttempt(documentNonce: String(repeating: "B", count: 32)),
        posterAttempt(documentNonce: "bad"),
        posterAttempt(fingerprint: ""),
        posterAttempt(lease: 0),
        posterAttempt(gameID: "")
    ] {
        #expect(!invalid.isValid)
        var policy = PlayerPosterHoldPolicy(attempt: invalid)
        #expect(policy.state == .retired)
        let observedPosterTransition18 = !policy.acceptTrustedSceneSubmission(
            for: invalid, validatedByNativeGate: true, ownsCurrentAttachment: true)
        #expect(observedPosterTransition18)
    }

    let valid = posterAttempt(documentNonce: String(repeating: "f", count: 32))
    var active = PlayerPosterHoldPolicy(attempt: valid)
    for index in 0..<160 {
        let suffix = String(index, radix: 16)
        let nonce = String(repeating: "0", count: 32 - suffix.count) + suffix
        let stale = posterAttempt(documentNonce: nonce)
        #expect(stale != valid)
        let observedPosterTransition19 = !active.acceptTrustedSceneSubmission(
            for: stale, validatedByNativeGate: true, ownsCurrentAttachment: true)
        #expect(observedPosterTransition19)
        #expect(active.mustHoldPoster)
    }
    active.retire()
    let observedPosterTransition20 = !active.acceptTrustedSceneSubmission(
        for: valid, validatedByNativeGate: true, ownsCurrentAttachment: true)
    #expect(observedPosterTransition20)
}


@Test func playerPosterTrustedRevealConsumesExactlyOnce() {
    let current = posterAttempt()
    var poster = PlayerPosterHoldPolicy(attempt: current)
    let noSceneReveal = poster.consumeReveal(for: current, ownsCurrentAttachment: true)
    #expect(!noSceneReveal)
    let valid = poster.acceptTrustedSceneSubmission(
        for: current, validatedByNativeGate: true, ownsCurrentAttachment: true
    )
    #expect(valid)
    let noRetiredLease = poster.consumeReveal(
        for: posterAttempt(lease: 19), ownsCurrentAttachment: true
    )
    #expect(!noRetiredLease)
    let notAttached = poster.consumeReveal(for: current, ownsCurrentAttachment: false)
    #expect(!notAttached)
    #expect(poster.mayBeginSceneSubmittedCrossfade)
    let firstReveal = poster.consumeReveal(for: current, ownsCurrentAttachment: true)
    #expect(firstReveal)
    #expect(poster.state == .revealed)
    #expect(!poster.mayBeginSceneSubmittedCrossfade)
    let doubleReveal = poster.consumeReveal(for: current, ownsCurrentAttachment: true)
    #expect(!doubleReveal)
    let postRevealScene = poster.acceptTrustedSceneSubmission(
        for: current, validatedByNativeGate: true, ownsCurrentAttachment: true
    )
    #expect(!postRevealScene)
    // An actual post-display WebContent failure still enters honest
    // recovery; reveal cannot be resurrected from the old attempt.
    let failed = poster.markFailure(for: current, ownsCurrentAttachment: true)
    #expect(failed)
    #expect(poster.mustShowRecovery)
    #expect(!poster.consumeReveal(for: current, ownsCurrentAttachment: true))
}

@Test func playerPosterMustBindGameIDToExactCanonicalPlayerURL() {
    let invalid = [
        posterAttempt(gameID: "other-game"),
        posterAttempt(playerURL: "https://games.example.test/player?game=other-game"),
        posterAttempt(playerURL: "https://games.example.test/player?game=published-game&game=other"),
        posterAttempt(playerURL: "https://games.example.test/player?quality=high"),
        posterAttempt(playerURL: "https://games.example.test/other?game=published-game"),
        posterAttempt(playerURL: "https://games.example.test/player?game=published-game#unexpected"),
    ]
    for attempt in invalid {
        #expect(!attempt.isValid)
        var reducer = PlayerPosterHoldPolicy(attempt: attempt)
        #expect(reducer.state == .retired)
        let accepted = reducer.acceptTrustedSceneSubmission(
            for: attempt, validatedByNativeGate: true, ownsCurrentAttachment: true
        )
        #expect(!accepted)
        #expect(!reducer.consumeReveal(for: attempt, ownsCurrentAttachment: true))
    }
}
