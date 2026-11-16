import SwiftUI
import Testing
@testable import Hephaestus

/// Pure source-level action contract. A real short creator ID must never
/// shrink the native hit target; backend identity and preview remain untouched.
struct ArcadePulseCreatorIdentityMinimumTargetTests {
    @Test func everyDynamicTypePreservesCreatorMinimumWidth() {
        for size in [
            DynamicTypeSize.xSmall, .small, .medium, .large,
            .xLarge, .xxLarge, .xxxLarge,
            .accessibility1, .accessibility2, .accessibility3,
            .accessibility4, .accessibility5
        ] {
            #expect(ArcadePulseCreatorIdentity.minimumHitWidth >= 44)
            #expect(ArcadePulseCreatorIdentity.avatarDimension(for: size) <=
                    ArcadePulseCreatorIdentity.minimumHitWidth)
            #expect(ArcadePulseCreatorIdentity.visibleNameLineLimit(for: size) ==
                    (size.isAccessibilitySize ? 2 : 1))
        }
    }

    @Test func shortNativeIdentityDoesNotForceFakeDisplayName() {
        #expect(ArcadePulseCreatorIdentity.minimumHitWidth ==
                ArcadePulseTheme.minimumTarget)
        #expect(ArcadePulseCreatorIdentity.avatarDimension(for: .large) == 26)
        #expect(ArcadePulseCreatorIdentity.avatarDimension(for: .accessibility5) == 32)
    }
}
