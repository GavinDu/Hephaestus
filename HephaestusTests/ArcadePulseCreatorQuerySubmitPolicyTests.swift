import Testing
@testable import Hephaestus

/// The same state policy controls the visible Apply button, the topic
/// keyboard Search action, and the navigation-search keyboard submit.
/// It must not issue a second reset GET during an already running search.
struct ArcadePulseCreatorQuerySubmitPolicyTests {
    @Test func idleSearchAllowsUserSubmissionIncludingClearingTopic() {
        #expect(CreatorQuerySubmitPolicy.canSubmit(isLoading: false))
    }

    @Test func pendingSearchDisablesBothKeyboardAndVisibleApply() {
        #expect(!CreatorQuerySubmitPolicy.canSubmit(isLoading: true))
    }
}
