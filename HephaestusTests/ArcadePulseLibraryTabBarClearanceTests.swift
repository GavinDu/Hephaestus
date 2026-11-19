import CoreGraphics
import Testing
@testable import Hephaestus

/// Pure layout policy: reserve scroll-end clearance only where compact
/// iPhone tabs can cover the real Library sign-in panel. No fake saved games
/// or backend identity is involved.
struct ArcadePulseLibraryTabBarClearanceTests {
    @Test func compactPhoneHasEnoughTrailingScrollRoom() {
        let clearance = LibraryTabBarClearancePolicy.trailingScrollInset(
            isPhone: true, isCompactHeight: true
        )
        #expect(clearance >= 64)
        #expect(clearance == LibraryTabBarClearancePolicy.compactPhoneTrailingInset)
    }

    @Test func ordinaryPhoneAndIPadDoNotInheritCompactSpacer() {
        #expect(LibraryTabBarClearancePolicy.trailingScrollInset(
            isPhone: true, isCompactHeight: false
        ) == 0)
        #expect(LibraryTabBarClearancePolicy.trailingScrollInset(
            isPhone: false, isCompactHeight: true
        ) == 0)
        #expect(LibraryTabBarClearancePolicy.trailingScrollInset(
            isPhone: false, isCompactHeight: false
        ) == 0)
    }
}
