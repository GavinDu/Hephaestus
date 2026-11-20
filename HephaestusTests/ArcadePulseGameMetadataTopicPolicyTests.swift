import Testing
@testable import Hephaestus

/// Pure checks of real backend topic-display policy, not an invented
/// published-game fixture or proof of native gameplay previews.
struct ArcadePulseGameMetadataTopicPolicyTests {
    @Test func missingOrOnlyUnusableTopicsShowNoMetadata() {
        let inputs: [[String]?] = [
            nil, [], ["", "  ", "\n", "bad\nline", "\u{0000}"]
        ]
        for input in inputs {
            #expect(GameMetadataTopicPolicy.presentation(input, maxCount: 4) == nil)
            #expect(GameMetadataTopicPolicy.presentation(input, maxCount: 5) == nil)
        }
    }

    @Test func ipadSpotlightKeepsFourGenuineLabelsAfterRejectingInvalidOnes() {
        let original = ["", "bad\nline", "Puzzle", " 艺术 ", "\u{0000}", " ألعاب ", "🎮", "fifth"]
        let output = GameMetadataTopicPolicy.presentation(original, maxCount: 4)
        #expect(output?.visual == "#Puzzle  #艺术  #ألعاب  #🎮")
        #expect(output?.spoken == "Topics: Puzzle, 艺术, ألعاب, 🎮")
        #expect(output?.visual.contains("fifth") == false)
        #expect(output?.spoken.contains("fifth") == false)
    }

    @Test func gameDetailsAllowsFiveButNeverAnInvalidSlot() {
        let original = ["", "A", "\t", " B ", "C", "D", "E", "F"]
        let output = GameMetadataTopicPolicy.presentation(original, maxCount: 5)
        #expect(output?.visual == "#A  #B  #C  #D  #E")
        #expect(output?.spoken == "Topics: A, B, C, D, E")
    }

    @Test func sharedGridDefaultStillReturnsExactlyThreeActualTopics() {
        let original = ["", "Arcade", "Games", "Art", "Extra", "Last"]
        #expect(GameFeedCardTopicPolicy.publicLabels(original) == ["Arcade", "Games", "Art"])
        #expect(GameFeedCardTopicPolicy.publicLabels(original, limit: 4) == [
            "Arcade", "Games", "Art", "Extra"
        ])
        #expect(GameFeedCardTopicPolicy.publicLabels(original, limit: 0).isEmpty)
    }
}
