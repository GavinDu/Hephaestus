import Foundation
import Testing
@testable import Hephaestus

/// The UI may trust an acknowledged mutation only when a current, same-viewer
/// server GET actually reports the requested relationship state.
struct ArcadePulseFollowAckReadConsistencyTests {
    @Test func acknowledgedFollowTrueNeedsServerTrue() {
        #expect(CreatorFollowStatePolicy.confirmsAcknowledgedTarget(
            expectedFollowing: true, observedFollowing: true))
        #expect(!CreatorFollowStatePolicy.confirmsAcknowledgedTarget(
            expectedFollowing: true, observedFollowing: false))
    }

    @Test func acknowledgedUnfollowFalseNeedsServerFalse() {
        #expect(CreatorFollowStatePolicy.confirmsAcknowledgedTarget(
            expectedFollowing: false, observedFollowing: false))
        #expect(!CreatorFollowStatePolicy.confirmsAcknowledgedTarget(
            expectedFollowing: false, observedFollowing: true))
    }

    @Test func unknownWriteOutcomeIsNotAnAcknowledgedTarget() {
        #expect(CreatorFollowStatePolicy.confirmsAcknowledgedTarget(
            expectedFollowing: nil, observedFollowing: false))
        #expect(CreatorFollowStatePolicy.confirmsAcknowledgedTarget(
            expectedFollowing: nil, observedFollowing: true))
        // A single ordinary GET does not prove a previous timed-out POST
        // was accepted by an eventually consistent backend. The write
        // remains unclaimed; only the current server relationship is shown.
        #expect(CreatorFollowStatePolicy.syncPendingMessage.contains("Refresh"))
        #expect(!CreatorFollowStatePolicy.syncPendingMessage.contains("succeeded"))
    }

    @Test func staleOrOtherViewerGetStillCannotResolvePendingPost() {
        #expect(!CreatorFollowStatePolicy.mayApplyCreatorRead(
            requestRevision: 4, currentRevision: 5,
            sameViewer: true, startedWhileMutating: true,
            isPostWriteConfirmation: true))
        #expect(!CreatorFollowStatePolicy.mayApplyCreatorRead(
            requestRevision: 5, currentRevision: 5,
            sameViewer: false, startedWhileMutating: true,
            isPostWriteConfirmation: true))
        #expect(CreatorFollowStatePolicy.mayApplyCreatorRead(
            requestRevision: 5, currentRevision: 5,
            sameViewer: true, startedWhileMutating: true,
            isPostWriteConfirmation: true))
    }

    @Test func pendingTargetNeverPermitsSecondFollowMutation() {
        for actual in [true, false] {
            for target in [true, false] where actual != target {
                #expect(!CreatorFollowStatePolicy.confirmsAcknowledgedTarget(
                    expectedFollowing: target, observedFollowing: actual))
                #expect(!CreatorFollowStatePolicy.canSubmit(
                    viewerID: "real-viewer", creatorID: "real-creator",
                    isUpdating: false, needsConfirmation: true))
            }
        }
    }
}
