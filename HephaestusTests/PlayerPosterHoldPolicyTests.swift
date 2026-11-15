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
    #expect(!poster.acceptTrustedSceneSubmission(
        for: current, validatedByNativeGate: false, ownsCurrentAttachment: true))
    #expect(!poster.acceptTrustedSceneSubmission(
        for: current, validatedByNativeGate: true, ownsCurrentAttachment: false))
    #expect(poster.mustHoldPoster)
    #expect(poster.acceptTrustedSceneSubmission(
        for: current, validatedByNativeGate: true, ownsCurrentAttachment: true))
    #expect(poster.state == .sceneSubmitted)
    #expect(poster.mayBeginSceneSubmittedCrossfade)
    #expect(!poster.acceptTrustedSceneSubmission(
        for: current, validatedByNativeGate: true, ownsCurrentAttachment: true))
    poster.noteNavigationFinish(for: current)
    #expect(!poster.navigationFinished)
    // The first scene milestone is *not* compositor presentation.
    #expect(!poster.markTimeout(for: current, ownsCurrentAttachment: true))
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
        #expect(!poster.acceptTrustedSceneSubmission(
            for: wrong, validatedByNativeGate: true, ownsCurrentAttachment: true))
        #expect(!poster.markTimeout(for: wrong, ownsCurrentAttachment: true))
        #expect(!poster.markFailure(for: wrong, ownsCurrentAttachment: true))
        #expect(poster.state == .holding)
        #expect(!poster.navigationFinished)
    }
    #expect(poster.acceptTrustedSceneSubmission(
        for: current, validatedByNativeGate: true, ownsCurrentAttachment: true))
}

@Test func playerPosterTimeoutFailureAndRetirementCannotBeResurrected() {
    let current = posterAttempt()
    var timedOut = PlayerPosterHoldPolicy(attempt: current)
    #expect(!timedOut.markTimeout(for: current, ownsCurrentAttachment: false))
    #expect(timedOut.markTimeout(for: current, ownsCurrentAttachment: true))
    #expect(timedOut.mustShowRecovery)
    #expect(!timedOut.mayBeginSceneSubmittedCrossfade)
    #expect(!timedOut.acceptTrustedSceneSubmission(
        for: current, validatedByNativeGate: true, ownsCurrentAttachment: true))
    #expect(!timedOut.markTimeout(for: current, ownsCurrentAttachment: true))

    var failed = PlayerPosterHoldPolicy(attempt: current)
    #expect(failed.acceptTrustedSceneSubmission(
        for: current, validatedByNativeGate: true, ownsCurrentAttachment: true))
    #expect(failed.markFailure(for: current, ownsCurrentAttachment: true))
    #expect(failed.mustShowRecovery)
    #expect(!failed.acceptTrustedSceneSubmission(
        for: current, validatedByNativeGate: true, ownsCurrentAttachment: true))
    failed.retire()
    #expect(failed.state == .retired)
    #expect(!failed.markFailure(for: current, ownsCurrentAttachment: true))
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
        #expect(!policy.acceptTrustedSceneSubmission(
            for: invalid, validatedByNativeGate: true, ownsCurrentAttachment: true))
    }

    let valid = posterAttempt(documentNonce: String(repeating: "f", count: 32))
    var active = PlayerPosterHoldPolicy(attempt: valid)
    for index in 0..<160 {
        let nonce = String(format: "%032x", index)
        let stale = posterAttempt(documentNonce: nonce)
        #expect(stale != valid)
        #expect(!active.acceptTrustedSceneSubmission(
            for: stale, validatedByNativeGate: true, ownsCurrentAttachment: true))
        #expect(active.mustHoldPoster)
    }
    active.retire()
    #expect(!active.acceptTrustedSceneSubmission(
        for: valid, validatedByNativeGate: true, ownsCurrentAttachment: true))
}
