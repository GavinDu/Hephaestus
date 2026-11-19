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

    @Test func everyInvalidEarlySlotCanBeReplacedByLaterRealTopic() {
        let summary = ForYouSpotlightTopicPolicy.summary([
            "\u{0003}", "  ", "first", "\r", "second", "third", "fourth"
        ])
        #expect(summary?.visual == "#first  #second  #third")
        #expect(summary?.spoken == "Topics: first, second, third")
    }
}
