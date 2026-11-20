import Foundation
import Testing
@testable import Hephaestus

/// Pure current-Coordinator admission; never emits a social event or score.
struct PlayerRuntimeMetricDispatchPolicyTests {
    private func mayStart(
        owner: Bool = true, running: Bool = true, cancelled: Bool = false,
        expected: String = "session_current", current: String? = "session_current"
    ) -> Bool {
        PlayerRuntimeMetricDispatchPolicy.mayStart(
            ownsCurrentAttachment: owner,
            permitsRuntimeEvents: running,
            taskCancelled: cancelled,
            expectedSessionID: expected,
            currentSessionID: current
        )
    }

    @Test func onlyCurrentAttachmentAndCurrentDocumentSessionMayStartSocialMetrics() {
        #expect(mayStart())
        #expect(!mayStart(owner: false))
        #expect(!mayStart(running: false))
        #expect(!mayStart(cancelled: true))
        #expect(!mayStart(current: nil))
        #expect(!mayStart(expected: "old_session"))
        #expect(!mayStart(current: "successor_session"))
        #expect(!mayStart(expected: "", current: ""))
        #expect(!mayStart(expected: "bad session", current: "bad session"))
        #expect(!mayStart(expected: "too long \(String(repeating: "x", count: 129))",
                          current: "too long \(String(repeating: "x", count: 129))"))
        #expect(!mayStart(expected: "owner \n token", current: "owner \n token"))
        #expect(!mayStart(expected: "é", current: "é"))
    }

    @Test func staleAsyncMetricNeverAdmitsAfter160NavigationOrLeaseTransitions() {
        for cycle in 0..<160 {
            let retired = "old_runtime_\(cycle)"
            let successor = "new_runtime_\(cycle)"
            #expect(PlayerRuntimeMetricDispatchPolicy.mayStart(
                ownsCurrentAttachment: true, permitsRuntimeEvents: true,
                taskCancelled: false, expectedSessionID: retired,
                currentSessionID: retired
            ))
            // After a navigation, the same WebView can still be physically
            // present. A different valid document session must reject old work.
            #expect(!PlayerRuntimeMetricDispatchPolicy.mayStart(
                ownsCurrentAttachment: true, permitsRuntimeEvents: true,
                taskCancelled: false, expectedSessionID: retired,
                currentSessionID: successor
            ))
            // A new SwiftUI Coordinator can take the same view/URL. Its
            // attachment lease must not permit old tasks to emit metrics.
            #expect(!PlayerRuntimeMetricDispatchPolicy.mayStart(
                ownsCurrentAttachment: false, permitsRuntimeEvents: true,
                taskCancelled: false, expectedSessionID: retired,
                currentSessionID: retired
            ))
            // A detached/terminated launch or task cancellation also revokes.
            #expect(!PlayerRuntimeMetricDispatchPolicy.mayStart(
                ownsCurrentAttachment: true, permitsRuntimeEvents: false,
                taskCancelled: false, expectedSessionID: retired,
                currentSessionID: retired
            ))
            #expect(!PlayerRuntimeMetricDispatchPolicy.mayStart(
                ownsCurrentAttachment: true, permitsRuntimeEvents: true,
                taskCancelled: true, expectedSessionID: retired,
                currentSessionID: retired
            ))
        }
    }
}
