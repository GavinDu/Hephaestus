import Testing
@testable import Hephaestus

/// Real source strings only; no synthetic published game is inserted.
struct ArcadePulseForYouSpotlightTopicPolicyTests {
    @Test func invalidProducerStringsNeverBecomeGhostHashtags() {
        let samples: [[String]?] = [nil, [], ["", "   ", "\n", "bad\nline", "\u{0000}"]]
        for sample in samples {
            #expect(ForYouSpotlightTopicPolicy.summary(sample) == nil)
        }
    }

    @Test func threeGenuineLabelsFollowTheActualProducerOrder() {
        let topics = ["", " ", " Puzzle ", "bad\nline", "艺术", "action", "fourth"]
        let summary = ForYouSpotlightTopicPolicy.summary(topics)
        #expect(summary?.visual == "#Puzzle  #艺术  #action")
        #expect(summary?.spoken == "Topics: Puzzle, 艺术, action")
    }

    @Test func unicodeAndEmojiRetainGenuineSourceMeaningForVoiceOver() {
        let summary = ForYouSpotlightTopicPolicy.summary([" 🎮 ", " ألعاب ", " c++ "])
        #expect(summary?.visual == "#🎮  #ألعاب  #c++")
        #expect(summary?.spoken == "Topics: 🎮, ألعاب, c++")
    }
}
