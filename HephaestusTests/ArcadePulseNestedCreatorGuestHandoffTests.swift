import Testing
@testable import Hephaestus

/// Source-only one-shot ordering contract for two real native Creator sheets.
/// Real deployed Creator Discovery screenshot acceptance remains #323/#332.
struct ArcadePulseNestedCreatorGuestHandoffTests {
    @Test func guestProfileRouteRequiresBothDismissalsAndOnlyFiresOnce() {
        var gate = CreatorNestedGuestSignInGate()
        // Normal Done on Creator Discovery must not open Profile.
        #expect(!gate.isAwaitingDirectoryDismiss)
        #expect(!gate.consumeAfterDirectoryDismiss())
        // The child Creator sheet's onDismiss authorizes the outer closure.
        #expect(gate.requestAfterInnerCreatorDismiss())
        #expect(gate.isAwaitingDirectoryDismiss)
        // Repeated callbacks cannot schedule a duplicate host navigation.
        #expect(!gate.requestAfterInnerCreatorDismiss())
        #expect(gate.consumeAfterDirectoryDismiss())
        #expect(!gate.isAwaitingDirectoryDismiss)
        #expect(!gate.consumeAfterDirectoryDismiss())
        // A future real visitor can independently request sign-in again.
        #expect(gate.requestAfterInnerCreatorDismiss())
        #expect(gate.consumeAfterDirectoryDismiss())
        #expect(!gate.consumeAfterDirectoryDismiss())
    }
}
