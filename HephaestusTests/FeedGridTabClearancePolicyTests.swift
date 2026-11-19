import Foundation
import CoreGraphics
import Testing
@testable import Hephaestus

/// Native TabView chrome must not leave the public grid's real Play control
/// permanently underneath floating compact iPhone landscape navigation.
/// This tests source policy only; XCUI validates original screen geometry.
struct FeedGridTabClearancePolicyTests {
    @Test func compactIPhoneReservesNativeTabAndBreathingRoom() {
        #expect(FeedGridTabClearancePolicy.trailingInset(isPhone: true,
                  isCompactHeight: true) == CGFloat(72))
        #expect(FeedGridTabClearancePolicy.compactPhoneTrailingInset >= CGFloat(64))
    }

    @Test func portraitPhoneAndIPadDoNotReceiveExtraBlankTail() {
        #expect(FeedGridTabClearancePolicy.trailingInset(isPhone: true,
                  isCompactHeight: false) == CGFloat(0))
        #expect(FeedGridTabClearancePolicy.trailingInset(isPhone: false,
                  isCompactHeight: true) == CGFloat(0))
        #expect(FeedGridTabClearancePolicy.trailingInset(isPhone: false,
                  isCompactHeight: false) == CGFloat(0))
    }
}
