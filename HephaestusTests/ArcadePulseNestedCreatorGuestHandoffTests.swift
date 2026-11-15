import Testing
@testable import Hephaestus

/// Source-only one-shot ordering contract for two real native Creator sheets.
/// Real deployed Creator Discovery screenshot acceptance remains #323/#332.
struct ArcadePulseNestedCreatorGuestHandoffTests {
    @Test func guestProfileRouteRequiresBothDismissalsAndOnlyFiresOnce() {
        var gate = CreatorNestedGuestSignInGate()
        // Normal Done on Creator Discovery must not open Profile.
        #expect(!gate.isAwaitingDirectoryDismiss)
        let step1 = gate.consumeAfterDirectoryDismiss()
        #expect(!step1)
        // The child Creator sheet's onDismiss authorizes the outer closure.
        let step2 = gate.requestAfterInnerCreatorDismiss()
        #expect(step2)
        #expect(gate.isAwaitingDirectoryDismiss)
        // Repeated callbacks cannot schedule a duplicate host navigation.
        let step3 = gate.requestAfterInnerCreatorDismiss()
        #expect(!step3)
        let step4 = gate.consumeAfterDirectoryDismiss()
        #expect(step4)
        #expect(!gate.isAwaitingDirectoryDismiss)
        let step5 = gate.consumeAfterDirectoryDismiss()
        #expect(!step5)
        // A future real visitor can independently request sign-in again.
        let step6 = gate.requestAfterInnerCreatorDismiss()
        #expect(step6)
        let step7 = gate.consumeAfterDirectoryDismiss()
        #expect(step7)
        let step8 = gate.consumeAfterDirectoryDismiss()
        #expect(!step8)
    }
}
