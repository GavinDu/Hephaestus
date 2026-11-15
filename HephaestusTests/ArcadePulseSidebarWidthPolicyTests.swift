import SwiftUI
import Testing
@testable import Hephaestus

/// Source policy for genuine native sidebar words, not fabricated labels.
struct ArcadePulseSidebarWidthPolicyTests {
    @Test func ordinarySizesRetainCompactSidebarAndTouchTargets() {
        for size in [DynamicTypeSize.xSmall, .small, .medium, .large, .xLarge] {
            let widths = ArcadePulseSidebarWidthPolicy.widths(for: size)
            #expect(widths.minimum == 180)
            #expect(widths.ideal == 220)
            #expect(widths.maximum == 250)
            #expect(ArcadePulseSidebarLabelPolicy.visibleLineLimit(for: size) == 1)
        }
        #expect(ArcadePulseSidebarLabelPolicy.minimumHitHeight >= 44)
    }

    @Test func xxLargeStillOffersLegibleTwoLineDestinations() {
        for size in [DynamicTypeSize.xxLarge, .xxxLarge] {
            let widths = ArcadePulseSidebarWidthPolicy.widths(for: size)
            #expect(widths.minimum == 240)
            #expect(widths.ideal == 280)
            #expect(widths.maximum == 320)
            #expect(widths.minimum <= widths.ideal)
            #expect(widths.ideal <= widths.maximum)
            #expect(ArcadePulseSidebarLabelPolicy.visibleLineLimit(for: size) == 2)
        }
    }

    @Test func accessibilityFiveCannotUseTheTruncating250PointSidebar() {
        for size in [
            DynamicTypeSize.accessibility1, .accessibility2,
            .accessibility3, .accessibility4, .accessibility5
        ] {
            let widths = ArcadePulseSidebarWidthPolicy.widths(for: size)
            #expect(widths.minimum >= 320)
            #expect(widths.ideal >= 360)
            #expect(widths.maximum >= 400)
            #expect(widths.minimum <= widths.ideal)
            #expect(widths.ideal <= widths.maximum)
            #expect(ArcadePulseSidebarLabelPolicy.visibleLineLimit(for: size) == 2)
        }
    }
}
