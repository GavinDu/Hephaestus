import Testing
@testable import Hephaestus

/// A visual-order-only policy. No test game, stored account or fake backend
/// session is needed to verify the 44pt guest route's priority.
struct ArcadePulseLibraryGuestSignInPriorityTests {
    @Test func compactPhoneGuestAtAccessibilityTypeGetsAccountRouteFirst() {
        #expect(LibraryGuestSignInPriorityPolicy.putsSignInFirst(
            isPhone: true, isCompactHeight: true,
            isAccessibilitySize: true, isGuest: true
        ))
    }

    @Test func allOtherContextsKeepExistingArcadeIntroFirst() {
        for isPhone in [false, true] {
            for compact in [false, true] {
                for accessibility in [false, true] {
                    for guest in [false, true] {
                        let expected = isPhone && compact && accessibility && guest
                        #expect(LibraryGuestSignInPriorityPolicy.putsSignInFirst(
                            isPhone: isPhone, isCompactHeight: compact,
                            isAccessibilitySize: accessibility, isGuest: guest
                        ) == expected)
                    }
                }
            }
        }
    }
}
