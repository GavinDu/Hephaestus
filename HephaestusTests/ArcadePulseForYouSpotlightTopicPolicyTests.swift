import Testing
@testable import Hephaestus

/// Pure policy tests: no synthetic published game or Creator account.
struct ArcadePulseForYouSpotlightTopicPolicyTests {
    @Test func nonexistentOrOnlyInvalidDataRendersNoGhostHashtags() {
        let samples: [[String]?] = [
            nil, [], ["", " ", "\n", "bad\nline", "\u{0000}"]
        ]
        for sample in samples {
            #expect(ForYouSpotlightTopicPolicy.summary(sample)?.visual == nil)
            #expect(ForYouSpotlightTopicPolicy.summary(sample)?.spoken == nil)
        }
    }

    @Test func sourceOrderAndThreeGenuineLimitMatchVisualAndSpoken() {
        let topics = ["", " ", " Puzzle ", "bad\nline", "艺术", "action", "fourth"]
        let summary = ForYouSpotlightTopicPolicy.summary(topics)
        #expect(summary?.visual == "#Puzzle  #艺术  #action")
        #expect(summary?.spoken == "Topics: Puzzle, 艺术, action")
    }

    @Test func unicodeEmojiAndCaseArePreservedFromRealSourceTokens() {
        let summary = ForYouSpotlightTopicPolicy.summary([" 🎮 ", " ألعاب ", " c++ "])
        #expect(summary?.visual == "#🎮  #ألعاب  #c++")
        #expect(summary?.spoken == "Topics: 🎮, ألعاب, c++")
    }

    @Test func genuinelyLongTopicsSurviveFullSpokenAndSheetSummary() {
        let longTopic = String(repeating: "strategy-", count: 12) + "🎮"
        let summary = ForYouSpotlightTopicPolicy.summary([
            " ", longTopic, "艺术", "puzzle", "fourth"
        ])
        #expect(summary?.visual == "#\(longTopic)  #艺术  #puzzle")
        #expect(summary?.spoken == "Topics: \(longTopic), 艺术, puzzle")
        #expect(summary?.visual.contains("fourth") == false)
        #expect(summary?.spoken.contains("fourth") == false)
        // A real wrapped Text in the accessibility Actions sheet uses
        // these full values; shortening them for a compact overlay would
        // silently change the selected published game metadata.
    }

    @Test func everyInvalidEarlySlotCanBeReplacedByLaterRealTopic() {
        let summary = ForYouSpotlightTopicPolicy.summary([
            "\u{0003}", "  ", "first", "\r", "second", "third", "fourth"
        ])
        #expect(summary?.visual == "#first  #second  #third")
        #expect(summary?.spoken == "Topics: first, second, third")
    }
}
