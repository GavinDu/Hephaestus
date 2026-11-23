import SwiftUI
import Testing
@testable import Hephaestus

/// Pure text admission and layout only: no synthetic published FeedGame,
/// device screenshot, backend response or A5 physical tap is implied.
struct ArcadePulseForYouTopicOverlayPolicyTests {
    private func lines(
        short: Bool = false,
        vertical: UserInterfaceSizeClass? = .regular,
        size: DynamicTypeSize = .large
    ) -> Int {
        ForYouTopicOverlayPolicy.visibleLineLimit(
            shortViewport: short,
            verticalSizeClass: vertical,
            dynamicTypeSize: size
        )
    }

    @Test func roomyStageWrapsTwoLinesWithoutReducingFontSize() {
        #expect(lines() == 2)
        #expect(lines(vertical: nil) == 2)
        #expect(lines(size: .xLarge) == 2)
    }

    @Test func compactLandscapeAndStageManagerProtectPlayAndActionTargets() {
        #expect(lines(short: true) == 0)
        #expect(lines(vertical: .compact) == 0)
        #expect(lines(short: true, vertical: .compact) == 0)
        #expect(lines(short: true, size: .accessibility5) == 0)
    }

    @Test func enlargedAndAllAccessibilitySizesUseSeparateDetailsRoute() {
        #expect(lines(size: .xxLarge) == 0)
        #expect(lines(size: .xxxLarge) == 0)
        for size in [
            DynamicTypeSize.accessibility1, .accessibility2, .accessibility3,
            .accessibility4, .accessibility5
        ] {
            #expect(lines(size: size) == 0)
        }
    }

    @Test func immersiveVisibleAndSpokenTopicsShareThreeGenuineLabelsInOrder() {
        // Inputs are only sample topic strings to test the formatter. They
        // are not represented as genuine published games or server fixtures.
        let raw = [
            "", "bad\nline", "Puzzle", " 艺术 ", "bad\u{0000}name",
            "🎮", "fourth"
        ]
        let presented = GameMetadataTopicPolicy.presentation(raw, maxCount: 3)
        #expect(presented?.visual == "#Puzzle  #艺术  #🎮")
        #expect(presented?.spoken == "Topics: Puzzle, 艺术, 🎮")
        #expect(GameMetadataTopicPolicy.presentation(
            ["\t", "bad\nlabel", "\u{0000}"], maxCount: 3
        ) == nil)
    }
}
