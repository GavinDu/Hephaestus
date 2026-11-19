import Testing
@testable import Hephaestus

/// Real Creator Discovery GET is owned by the parent view; a disabled Apply
/// cannot secretly be invoked by the native keyboard. No mock creators.
struct ArcadePulseCreatorQuerySubmitPolicyTests {
    @Test func idleCreatorQueryAllowsSearchAndClearingTopic() {
        #expect(CreatorQuerySubmitPolicy.canSubmit(isLoading: false))
    }

    @Test func busyCreatorQueryDisablesKeyboardAndVisibleApply() {
        #expect(!CreatorQuerySubmitPolicy.canSubmit(isLoading: true))
    }
}
