import Testing
@testable import Hephaestus

/// Pure presentation policy for genuine published For You topics; no
/// synthetic live game fixtures, network claims or screenshot substitutions.
struct ArcadePulseForYouSpotlightTopicPolicyTests {
    @Test func absentOrMalformedTopicsNeverCreateAnEmptyTagOrSpokenLabel() {
        let cases: [[String]?] = [
            nil, [], ["", "  ", "\t", "\n"],
            ["bad\nline", "\u{0000}", "malformed\rcontrol"]
        ]
        for topics in cases {
            #expect(ForYouSpotlightTopicPolicy.presentation(topics) == nil)
        }
    }

    @Test func invalidEarlierValuesCannotDisplaceLaterGenuineTopics() {
        let raw = ["", "  ", "arcade", "bad\nlabel", " 艺术 ", "action", "fourth"]
        let summary = ForYouSpotlightTopicPolicy.presentation(raw)
        #expect(summary?.visual == "#arcade  #艺术  #action")
        #expect(summary?.spoken == "Topics: arcade, 艺术, action")
        #expect(summary?.visual.contains("fourth") == false)
        #expect(summary?.spoken.contains("fourth") == false)
    }

    @Test func actualUnicodeCaseAndOrderAreIdenticalOnScreenAndInVoiceOver() {
        let summary = ForYouSpotlightTopicPolicy.presentation([
            "  🎮  ", " \u{0000} hidden ", " ألعاب ", " C++ ", "Later"
        ])
        #expect(summary?.visual == "#🎮  #ألعاب  #C++")
        #expect(summary?.spoken == "Topics: 🎮, ألعاب, C++")
    }

    @Test func noEagerPrefixBeforeValidation() {
        let summary = ForYouSpotlightTopicPolicy.presentation([
            "", "\u{0000}", "bad\nline", "First", "Second", "Third"
        ])
        #expect(summary?.visual == "#First  #Second  #Third")
        #expect(summary?.spoken == "Topics: First, Second, Third")
    }
}
