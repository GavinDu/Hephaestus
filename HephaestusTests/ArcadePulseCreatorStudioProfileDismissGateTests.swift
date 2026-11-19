import Testing
@testable import Hephaestus

/// One-shot source-owned navigation contract. The native XCTest below checks
/// genuine modal dismissal before actual Profile/Apple sign-in becomes hittable.
struct ArcadePulseCreatorStudioProfileDismissGateTests {
    @Test func normalStudioDoneNeverRoutesToProfile() {
        var gate = CreatorStudioProfileDismissGate()
        #expect(!gate.pendingProfileRoute)
        let dismissed = gate.consumeAfterStudioDismiss()
        #expect(!dismissed)
    }

    @Test func guestRouteMustWaitForNativeDismissalAndConsumeOnce() {
        var gate = CreatorStudioProfileDismissGate()
        let requested = gate.requestAfterStudioDismiss()
        #expect(requested)
        #expect(gate.pendingProfileRoute)
        let again = gate.requestAfterStudioDismiss()
        #expect(!again)
        let firstDismiss = gate.consumeAfterStudioDismiss()
        #expect(firstDismiss)
        #expect(!gate.pendingProfileRoute)
        let repeatDismiss = gate.consumeAfterStudioDismiss()
        #expect(!repeatDismiss)
        let nextRequest = gate.requestAfterStudioDismiss()
        #expect(nextRequest)
        let nextDismiss = gate.consumeAfterStudioDismiss()
        #expect(nextDismiss)
    }
}
