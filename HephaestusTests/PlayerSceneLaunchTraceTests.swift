import Foundation
import Testing
@testable import Hephaestus

@MainActor
struct PlayerSceneLaunchTraceTests {
    @Test func speculativeTransferAndBoundedFixedOutput() {
        var trace = PlayerSceneLaunchTrace()
        trace.begin(nonce: "private-native-key", lease: nil)
        trace.record(.navigationStarted, nonce: "private-native-key", lease: nil)
        trace.record(.prewarmAccepted, nonce: "private-native-key", lease: nil)
        trace.attach(nonce: "private-native-key", lease: 9)
        for _ in 0..<160 {
            trace.record(.navigationFinished, nonce: "private-native-key", lease: 9)
            trace.record(.bridgeRejected, nonce: "wrong", lease: 9)
            trace.record(.metricRejected, nonce: "private-native-key", lease: 8)
        }
        let handle = PlayerSceneLaunchTrace.Handle(nonce: "private-native-key", lease: 9)
        let result = trace.finishTimeout(handle)
        #expect(result == "prepared,navigationStarted,receiverAttached,navigationFinished,prewarmAccepted,timeout")
        trace.record(.deliveryInvoked, nonce: handle.nonce, lease: handle.lease)
        #expect(trace.finishTimeout(handle) == result)
        #expect(result?.contains("private-native-key") == false)
    }

    @Test func currentNonceAndLeaseResetAcrossRepeatedAttempts() {
        var trace = PlayerSceneLaunchTrace()
        for index in 1...160 {
            let old = PlayerSceneLaunchTrace.Handle(nonce: "old-\(index)", lease: UInt64(index))
            let current = PlayerSceneLaunchTrace.Handle(nonce: "new-\(index)", lease: UInt64(index + 1))
            trace.begin(nonce: old.nonce, lease: old.lease)
            trace.record(.reducerAccepted, nonce: old.nonce, lease: old.lease)
            trace.begin(nonce: current.nonce, lease: nil)
            trace.attach(nonce: old.nonce, lease: old.lease)
            trace.attach(nonce: current.nonce, lease: current.lease)
            trace.attach(nonce: current.nonce, lease: old.lease)
            trace.record(.attachedReceived, nonce: old.nonce, lease: current.lease)
            trace.record(.bridgeRejected, nonce: current.nonce, lease: old.lease)
            trace.record(.prewarmRejected, nonce: current.nonce, lease: nil)
            #expect(trace.finishTimeout(old) == nil)
            trace.record(.attachedReceived, nonce: current.nonce, lease: current.lease)
            trace.record(.bridgeAdmitted, nonce: current.nonce, lease: current.lease)
            trace.record(.metricRejected, nonce: current.nonce, lease: current.lease)
            #expect(trace.finishTimeout(current) ==
                    "prepared,receiverAttached,attachedReceived,bridgeAdmitted,metricRejected,timeout")
            trace.reset()
            #expect(trace.finishTimeout(current) == nil)
        }
    }

    @Test func cardinalityBoundAndCanonicalOrder() {
        var trace = PlayerSceneLaunchTrace()
        let handle = PlayerSceneLaunchTrace.Handle(nonce: "private", lease: 5)
        trace.begin(nonce: handle.nonce, lease: handle.lease)
        for _ in 0..<160 {
            for stage in PlayerSceneLaunchTrace.Stage.allCases.reversed() where stage != .timeout {
                trace.record(stage, nonce: handle.nonce, lease: handle.lease)
            }
        }
        let expected = PlayerSceneLaunchTrace.Stage.allCases.map(\.rawValue).joined(separator: ",")
        #expect(trace.finishTimeout(handle) == expected)
    }
}
