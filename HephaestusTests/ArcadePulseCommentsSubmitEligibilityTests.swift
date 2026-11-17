import Testing
@testable import Hephaestus

/// Shared native keyboard/button admission; no backend calls, private
/// draft logs or fabricated comments are involved in these source tests.
struct ArcadePulseCommentsSubmitEligibilityTests {
    @Test func textMayBeSentWhenEditorIsIdle() {
        #expect(CommentsSubmitEligibilityPolicy.canSend(
            draft: "  This game is fun.  ", isSubmitting: false))
    }

    @Test func emptyWhitespaceAndNewlineCannotSend() {
        for draft in ["", " ", "  \n \t  "] {
            #expect(!CommentsSubmitEligibilityPolicy.canSend(
                draft: draft, isSubmitting: false))
        }
    }

    @Test func keyboardRepeatCannotStartASecondFlight() {
        #expect(!CommentsSubmitEligibilityPolicy.canSend(
            draft: "A retryable draft", isSubmitting: true))
    }
}
