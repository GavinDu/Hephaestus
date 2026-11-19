import Foundation
import Testing
@testable import Hephaestus

/// No pretend POST response or private media: pure active-session UI reducer.
struct ArcadePulseCreatePublishAttemptGateTests {
    @Test func oneRealRequestIsAdmittedOnlyOnceWhileInFlight() {
        var gate = CreatePublishAttemptGate()
        #expect(gate.canBegin(for: "real-server-game-id"))
        let first = gate.begin(for: "real-server-game-id")
        let duplicate = gate.begin(for: "real-server-game-id")
        #expect(first)
        #expect(!duplicate)
        #expect(!gate.canBegin(for: "different-game-id"))
        #expect(gate.state == .inFlight)
    }

    @Test func lostPublishResponseCannotTriggerBlindRetry() {
        var gate = CreatePublishAttemptGate()
        let admitted = gate.begin(for: "real-server-game-id")
        #expect(admitted)
        gate.markUnconfirmed(for: "real-server-game-id")
        #expect(gate.state == .unconfirmed)
        #expect(!gate.canBegin(for: "real-server-game-id"))
        #expect(!gate.canBegin(for: "different-game-id"))
        let second = gate.begin(for: "real-server-game-id")
        #expect(!second)
        gate.acknowledge(for: "real-server-game-id")
        #expect(gate.state == .unconfirmed)
    }

    @Test func realAcknowledgementCannotBeResubmitted() {
        var gate = CreatePublishAttemptGate()
        let admitted = gate.begin(for: "real-server-game-id")
        #expect(admitted)
        gate.acknowledge(for: "wrong-game")
        #expect(gate.state == .inFlight)
        gate.acknowledge(for: "real-server-game-id")
        #expect(gate.state == .acknowledged)
        #expect(!gate.canBegin(for: "real-server-game-id"))
    }

    @Test func explicitLocalResetAndInvalidIDs() {
        var gate = CreatePublishAttemptGate()
        #expect(!gate.canBegin(for: "  \n  "))
        let admitted = gate.begin(for: "real-server-game-id")
        #expect(admitted)
        gate.markUnconfirmed(for: "wrong-game")
        #expect(gate.state == .inFlight)
        gate.resetForNewLocalGame()
        #expect(gate.state == .ready)
        #expect(gate.gameID == nil)
        #expect(gate.canBegin(for: "new-real-game-id"))
    }
}
