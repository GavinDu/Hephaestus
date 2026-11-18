import Testing
@testable import Hephaestus

/// Keyboard and button share one real Comments submit() admission rule.
/// These pure tests never post a comment or fabricate a public account.
struct ArcadePulseCommentsSubmitEligibilityTests {
    @Test func editableNonemptyDraftCanSendWhenIdle() {
        #expect(CommentsSubmitEligibilityPolicy.canSend(
            draft: "  Nice game!  ", isSubmitting: false))
    }

    @Test func blankWhitespaceOrNewlineCannotSend() {
        for draft in ["", " ", " \n \t \n "] {
            #expect(!CommentsSubmitEligibilityPolicy.canSend(
                draft: draft, isSubmitting: false))
        }
    }

    @Test func keyboardRepeatCannotStartASecondPendingMutation() {
        #expect(!CommentsSubmitEligibilityPolicy.canSend(
            draft: "Unconfirmed pending comment", isSubmitting: true))
    }

    @Test func nonEnglishPublicDraftIsNotDiscarded() {
        #expect(CommentsSubmitEligibilityPolicy.canSend(
            draft: "  游戏很棒!  ", isSubmitting: false))
    }
}
