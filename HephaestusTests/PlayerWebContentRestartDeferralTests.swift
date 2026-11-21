import Foundation
import Testing
@testable import Hephaestus

/// #525: a dead WebKit process may be restarted automatically only when
/// the attached native host is foreground-active AND its network is online.
struct PlayerWebContentRestartDeferralTests {
    @Test func onlyActiveOnlinePlayerMaySpendTheBoundedCrashBudget() {
        for completed in [-1, 0, 1, 2, 3, Int.max] {
            let expected = completed == 0 || completed == 1
            #expect(PlayerWebContentTerminationPolicy.shouldAutoRestartNow(
                completedReloads: completed,
                isActiveAndForeground: true,
                isOffline: false
            ) == expected)
            for isActive in [false, true] {
                for isOffline in [false, true] {
                    let allowed = PlayerWebContentTerminationPolicy.shouldAutoRestartNow(
                        completedReloads: completed,
                        isActiveAndForeground: isActive,
                        isOffline: isOffline
                    )
                    #expect(allowed == (expected && isActive && !isOffline))
                }
            }
        }
    }

    @Test func repeatedTransitionCombinationsNeverRestartWhenInactiveOrOffline() {
        for iteration in 0..<160 {
            // Deliberately sweep invalid, budget-edge and exhausted counts.
            let completed = iteration % 5 - 1
            let isActive = iteration.isMultiple(of: 2)
            let isOffline = iteration.isMultiple(of: 3)
            let expected = (completed == 0 || completed == 1) && isActive && !isOffline
            #expect(PlayerWebContentTerminationPolicy.shouldAutoRestartNow(
                completedReloads: completed,
                isActiveAndForeground: isActive,
                isOffline: isOffline
            ) == expected)
        }
        #expect(!PlayerWebContentTerminationPolicy.shouldAutoRestartNow(
            completedReloads: Int.min,
            isActiveAndForeground: true,
            isOffline: false
        ))
    }
}
