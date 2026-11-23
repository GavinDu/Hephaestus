import Foundation
import Testing
@testable import Hephaestus

/// #731: the native WKWebView reducer is the ONLY production host authority.
/// These tests deliberately create no GamePackageTransport or asset download.
struct PlayerCurrentHostMilestoneProjectionTests {
    private let url = URL(string: "https://games.example.test/player?game=game-1&quality=low&presentation=play")!
    private let nonce = String(repeating: "a", count: 32)
    private let session = "session-1"

    private func project(_ phase: PlayerHostLaunchReducer.Phase,
                         lease: UInt64 = 9,
                         gameID: String = "game-1",
                         documentNonce: String? = nil,
                         sessionID: String? = nil,
                         ownsLease: Bool = true,
                         playerURL: URL? = nil) -> PlayerCurrentHostMilestone? {
        PlayerCurrentHostMilestoneProjection.project(
            phase: phase, gameID: gameID, playerURL: playerURL ?? url,
            attachmentLease: lease, nativeDocumentNonce: documentNonce,
            validatedRuntimeSessionID: sessionID,
            ownsCurrentAttachment: ownsLease
        )
    }

    @Test func nativeMilestonesDescribeTruthfulProgressAndNotGPUReadiness() {
        #expect(PlayerCurrentHostMilestoneProjection.gamePackageFormatVersion == "2.0")
        var reducer = PlayerHostLaunchReducer()
        #expect(project(reducer.phase)?.stage == .navigating)
        let mutationResultL31 = reducer.navigationFinished()
        #expect(mutationResultL31)
        #expect(project(reducer.phase)?.stage == .documentLoaded)
        // A real WebKit didFinish has not supplied a renderer submission.
        #expect(project(reducer.phase)?.stage != .rendererSubmitted)
        let mutationResultL35 = reducer.sceneSubmitted()
        #expect(mutationResultL35)
        // Renderer-submission claims need BOTH native nonce and bound session.
        #expect(project(reducer.phase) == nil)
        #expect(project(reducer.phase, documentNonce: nonce) == nil)
        #expect(project(reducer.phase, sessionID: session) == nil)
        let submitted = project(reducer.phase, documentNonce: nonce, sessionID: session)
        #expect(submitted?.stage == .rendererSubmitted)
        #expect(submitted?.attachmentLease == 9)
        #expect(submitted?.nativeDocumentNonce == nonce)
        #expect(submitted?.gameID == "game-1")
        let mutationResultL45 = reducer.firstInput(milliseconds: 80)
        #expect(mutationResultL45)
        #expect(project(reducer.phase, documentNonce: nonce, sessionID: session)?.stage == .firstInputAdmitted)
        let mutationResultL47 = !reducer.sceneSubmitted()
        #expect(mutationResultL47)
        reducer.detach()
        #expect(project(reducer.phase)?.stage == .stopped)
        #expect(project(reducer.phase, ownsLease: false) == nil)
    }

    @Test func currentNativeProofMustPrecedeMetricStateMutation() {
        // An unproven callback must not burn the first-scene or first-input
        // reducer slot and suppress the next legitimate current callback.
        for iteration in 0..<160 {
            let session = "session-\(iteration)"
            let legitimate = project(.documentLoaded,
                documentNonce: nonce, sessionID: session)
            #expect(PlayerCurrentHostMilestoneProjection.permitsMetricAdmission(
                legitimate, forSession: session
            ))
            #expect(!PlayerCurrentHostMilestoneProjection.permitsMetricAdmission(
                nil, forSession: session
            ))
            #expect(!PlayerCurrentHostMilestoneProjection.permitsMetricAdmission(
                project(.documentLoaded, sessionID: session), forSession: session
            ))
            #expect(!PlayerCurrentHostMilestoneProjection.permitsMetricAdmission(
                project(.documentLoaded, documentNonce: nonce), forSession: session
            ))
            #expect(!PlayerCurrentHostMilestoneProjection.permitsMetricAdmission(
                legitimate, forSession: "other-session"
            ))
            for dead in [PlayerHostLaunchReducer.Phase.navigationFailed,
                         PlayerHostLaunchReducer.Phase.detached] {
                #expect(!PlayerCurrentHostMilestoneProjection.permitsMetricAdmission(
                    project(dead, documentNonce: nonce, sessionID: session),
                    forSession: session
                ))
            }
        }
    }

    @Test func nativeProofRejectsHostileIdentityInvalidEpochAndExpiredAttachment() {
        for iteration in 0..<160 {
            let wrong = "bad/\(iteration)"
            let foreignURL = URL(string:
                "https://games.example.test/player?game=other-\(iteration)&quality=low")!
            #expect(project(.sceneSubmitted, gameID: wrong,
                            documentNonce: nonce, sessionID: session) == nil)
            #expect(project(.sceneSubmitted, lease: 0,
                            documentNonce: nonce, sessionID: session) == nil)
            #expect(project(.sceneSubmitted, documentNonce: nonce,
                            sessionID: session, ownsLease: false) == nil)
            #expect(project(.sceneSubmitted, documentNonce: nonce,
                            sessionID: session, playerURL: foreignURL) == nil)
            #expect(project(.sceneSubmitted, documentNonce: "not-hex-\(iteration)",
                            sessionID: session) == nil)
            #expect(project(.sceneSubmitted, documentNonce: nonce,
                            sessionID: "bad session\n") == nil)
            #expect(project(.sceneSubmitted, documentNonce: nonce,
                            sessionID: session)?.stage == .rendererSubmitted)
        }
        #expect(project(.interactive, documentNonce: String(repeating: "A", count: 32),
                        sessionID: session) == nil)
        #expect(project(.interactive, documentNonce: nonce,
                        sessionID: session)?.stage == .firstInputAdmitted)
        #expect(project(.navigationFailed)?.stage == .failed)
        #expect(project(.webProcessTerminated)?.stage == .failed)
    }

    @Test func reducerDoesNotResurrectDeadOrDetachedOwnerAcross160Reorderings() {
        for iteration in 0..<160 {
            var reducer = PlayerHostLaunchReducer()
            if iteration.isMultiple(of: 2) {
                let mutationResultL85 = reducer.firstInput(milliseconds: iteration + 1)
                #expect(mutationResultL85)
                let mutationResultL86 = reducer.sceneSubmitted()
                #expect(mutationResultL86)
                let mutationResultL87 = reducer.navigationFinished()
                #expect(mutationResultL87)
                #expect(project(reducer.phase, documentNonce: nonce,
                                sessionID: session)?.stage == .firstInputAdmitted)
            } else {
                let mutationResultL91 = reducer.navigationFinished()
                #expect(mutationResultL91)
                let mutationResultL92 = reducer.sceneSubmitted()
                #expect(mutationResultL92)
                let mutationResultL93 = !reducer.sceneSubmitted()
                #expect(mutationResultL93)
                let mutationResultL94 = reducer.firstInput(milliseconds: iteration + 1)
                #expect(mutationResultL94)
                #expect(project(reducer.phase, documentNonce: nonce,
                                sessionID: session)?.stage == .firstInputAdmitted)
            }
            if iteration.isMultiple(of: 3) {
                let mutationResultL99 = reducer.webProcessTerminated()
                #expect(mutationResultL99)
            } else {
                reducer.detach()
            }
            let mutationResultL103 = !reducer.sceneSubmitted()
            #expect(mutationResultL103)
            let mutationResultL104 = !reducer.firstInput(milliseconds: 77)
            #expect(mutationResultL104)
            let mutationResultL105 = !reducer.navigationFinished()
            #expect(mutationResultL105)
            #expect(project(reducer.phase, ownsLease: false) == nil)
            // A new navigation cannot revive the dead reducer. A genuinely
            // new Coordinator and native document nonce must be allocated.
            reducer.navigationStarted()
            #expect(!reducer.permitsRuntimeEvents)
        }
    }

    @Test func poolNonceGateRevokesOldDocumentBeforeNewRuntimeBinding() {
        var gate = PlayerNativeDocumentEpochGate()
        let old = gate.prepareNavigation()
        let mutationResultL117 = gate.didStartNavigation()
        #expect(mutationResultL117)
        #expect(gate.acceptsV2(old))
        for _ in 0..<160 {
            let fresh = gate.prepareNavigation()
            #expect(!gate.acceptsV2(old))
            #expect(!gate.acceptsV2(fresh))
            let mutationResultL123 = gate.didStartNavigation()
            #expect(mutationResultL123)
            #expect(gate.acceptsV2(fresh))
            gate.invalidate()
            #expect(!gate.acceptsV2(fresh))
        }
    }
}
