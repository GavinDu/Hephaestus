import SwiftUI
import Testing
@testable import Hephaestus

/// Independent native source policy for truthful, readable backend provenance.
/// Full screenshot/VoiceOver acceptance remains Epic #172 issue #269.
struct ArcadePulsePlayableExpressionLayoutTests {
    @Test func ordinaryDynamicTypeKeepsCompactProvenanceBadges() {
        for size in [DynamicTypeSize.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge] {
            #expect(!PlayableExpressionLayout.stacksMetadata(for: size))
        }
    }

    @Test func everyAccessibilityTextSizeStacksProvenanceBadges() {
        for size in [DynamicTypeSize.accessibility1, .accessibility2, .accessibility3,
            .accessibility4, .accessibility5
        ] {
            #expect(PlayableExpressionLayout.stacksMetadata(for: size))
        }
    }
}
