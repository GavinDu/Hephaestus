import Testing
@testable import Hephaestus

/// Presentation-only policy: no synthetic published games, creators or backend.
struct ArcadePulseForYouSpotlightTopicPolicyTests {
    @Test func malformedOrMissingTopicsHaveNoVisibleOrSpokenTag() {
        let cases: [[String]?] = [
            nil, [], ["", "  ", "\t", "\n"],
            ["bad\nlabel", "\u{0000}", "malformed\rcontrol"]
        ]
        for topics in cases {
            #expect(ForYouSpotlightTopicPolicy.presentation(topics) == nil)
        }
    }

    @Test func malformedEntriesDoNotDisplaceLaterGenuineTopics() {
        let summary = ForYouSpotlightTopicPolicy.presentation(
            ["", "  ", "arcade", "bad\nlabel", " 艺术 ", "action", "fourth"]
        )
        #expect(summary?.visual == "#arcade  #艺术  #action")
        #expect(summary?.spoken == "Topics: arcade, 艺术, action")
        #expect(summary?.visual.contains("fourth") == false)
    }

    @Test func genuineUnicodeCaseAndOrderMatchVoiceOverExactly() {
        let summary = ForYouSpotlightTopicPolicy.presentation(
            ["  🎮  ", " \u{0000} hidden ", " ألعاب ", " C++ ", "later"]
        )
        #expect(summary?.visual == "#🎮  #ألعاب  #C++")
        #expect(summary?.spoken == "Topics: 🎮, ألعاب, C++")
    }

    @Test func validLabelsAreChosenAfterFilteringNotBefore() {
        let summary = ForYouSpotlightTopicPolicy.presentation(
            ["", "\u{0000}", "bad\nline", "First", "Second", "Third"]
        )
        #expect(summary?.visual == "#First  #Second  #Third")
        #expect(summary?.spoken == "Topics: First, Second, Third")
    }
}
