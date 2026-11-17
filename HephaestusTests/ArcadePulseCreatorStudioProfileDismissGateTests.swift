import Testing
@testable import Hephaestus

/// Source-only one-shot gate contract; the required native XCUITest verifies
/// actual modal ownership and real Apple sign-in after dismissal.
struct ArcadePulseCreatorStudioProfileDismissGateTests {
    @Test func normalStudioDoneNeverRoutesToProfile() {
        var gate = CreatorStudioProfileDismissGate()
        #expect(!gate.pendingProfileRoute)
        let firstDismiss = gate.consumeAfterStudioDismiss()
        #expect(!firstDismiss)
    }

    @Test func guestRouteWaitsForStudioDismissAndConsumesOnce() {
        var gate = CreatorStudioProfileDismissGate()
        let requested = gate.requestAfterStudioDismiss()
        #expect(requested)
        #expect(gate.pendingProfileRoute)
        let repeatedRequest = gate.requestAfterStudioDismiss()
        #expect(!repeatedRequest)
        let delivered = gate.consumeAfterStudioDismiss()
        #expect(delivered)
        #expect(!gate.pendingProfileRoute)
        let repeatedDismiss = gate.consumeAfterStudioDismiss()
        #expect(!repeatedDismiss)
        let futureRequest = gate.requestAfterStudioDismiss()
        #expect(futureRequest)
        let futureDismiss = gate.consumeAfterStudioDismiss()
        #expect(futureDismiss)
    }
}
