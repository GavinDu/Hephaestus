import SwiftUI
import Testing
@testable import Hephaestus

/// Source-only scalable iPad sidebar label policy, independent of full screen acceptance #338.
struct ArcadePulseSidebarPolicyTests {
    @Test func arcadePulseIPadSidebarKeepsReadableDestinationLabelsAtLargeText() {
        // Policy-only: original native screenshot and real route needed for
        // full accessibility acceptance #338, not a synthetic preview.
        #expect(ArcadePulseSidebarLabelPolicy.visibleLineLimit(for: .large) == 1)
        #expect(ArcadePulseSidebarLabelPolicy.visibleLineLimit(for: .xLarge) == 1)
        #expect(ArcadePulseSidebarLabelPolicy.visibleLineLimit(for: .xxLarge) == 2)
        #expect(ArcadePulseSidebarLabelPolicy.visibleLineLimit(for: .xxxLarge) == 2)
        #expect(ArcadePulseSidebarLabelPolicy.visibleLineLimit(for: .accessibility1) == 2)
        #expect(ArcadePulseSidebarLabelPolicy.visibleLineLimit(for: .accessibility5) == 2)
        #expect(ArcadePulseSidebarLabelPolicy.minimumHitHeight >= 44)
        #expect(ArcadePulseSidebarLabelPolicy.minimumHitHeight >= ArcadePulseTheme.minimumTarget)
    }

}
