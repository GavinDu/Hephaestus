import Testing
@testable import Hephaestus

/// Keyboard and the visible paperplane share one real submit() admission
/// rule. Pure tests never publish a comment to the public backend.
struct ArcadePulseCommentsSubmitEligibilityTests {
    @Test func nonemptyDraftCanSendWhileIdle() {
        #expect(CommentsSubmitEligibilityPolicy.canSend(
            draft: "  Nice game!  ", isSubmitting: false))
    }

    @Test func whitespaceAndNewlineCannotSend() {
        for draft in ["", "  ", " \n \t\n"] {
            #expect(!CommentsSubmitEligibilityPolicy.canSend(
                draft: draft, isSubmitting: false))
        }
    }

    @Test func secondKeyboardSendCannotSubmitInFlight() {
        #expect(!CommentsSubmitEligibilityPolicy.canSend(
            draft: "Unconfirmed comment", isSubmitting: true))
    }

    @Test func unicodeDraftIsPreserved() {
        #expect(CommentsSubmitEligibilityPolicy.canSend(
            draft: "  游戏很棒!  ", isSubmitting: false))
    }
}
