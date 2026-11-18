import SwiftUI
import Testing
@testable import Hephaestus

/// Native Apple AuthenticationServices remains authoritative. The policy
/// only controls the genuine SignInWithAppleButton's visual target height.
struct ArcadePulseProfileAppleSignInLayoutTests {
    @Test func standardDynamicTypeRetainsPlatformMinimum() {
        #expect(ProfileAppleSignInLayout.buttonHeight(for: .medium) == 44)
        #expect(ProfileAppleSignInLayout.buttonHeight(for: .xLarge) == 44)
    }

    @Test func enlargedTypeGetsAnIntentionallyLargerHitTarget() {
        #expect(ProfileAppleSignInLayout.buttonHeight(for: .xxLarge) == 56)
        #expect(ProfileAppleSignInLayout.buttonHeight(for: .xxxLarge) == 56)
    }

    @Test func accessibilitySizesAllKeepRealAppleControlTallEnough() {
        for size in [
            DynamicTypeSize.accessibility1,
            .accessibility2, .accessibility3, .accessibility4, .accessibility5
        ] {
            #expect(ProfileAppleSignInLayout.buttonHeight(for: size) == 64)
        }
    }
}
