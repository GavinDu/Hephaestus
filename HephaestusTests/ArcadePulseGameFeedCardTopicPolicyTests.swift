import Testing
@testable import Hephaestus

/// Real published game metadata only. No fake live game, creator or backend.
struct ArcadePulseGameFeedCardTopicPolicyTests {
    @Test func noGenuineTopicsProducesNeitherVisualNorSpokenHashtag() {
        for topics: [String]? in [nil, [], ["", " \t ", "\n"]] {
            #expect(GameFeedCardTopicPolicy.publicLabels(topics).isEmpty)
            #expect(GameFeedCardTopicPolicy.visualSummary(topics) == nil)
            #expect(GameFeedCardTopicPolicy.accessibilitySummary(topics) == nil)
        }
    }

    @Test func malformedTopicsDoNotConsumeFirstThreeActualSlots() {
        let topics = ["", "  ", "puzzle", "bad\nlabel", "艺术", "action", "fourth"]
        #expect(GameFeedCardTopicPolicy.publicLabels(topics) == ["puzzle", "艺术", "action"])
        #expect(GameFeedCardTopicPolicy.visualSummary(topics) == "#puzzle  #艺术  #action")
        #expect(GameFeedCardTopicPolicy.accessibilitySummary(topics) ==
                "Topics: puzzle, 艺术, action")
    }

    @Test func rejectedControlsAndTrimmedUnicodeStayConsistentForVoiceOver() {
        let topics = ["  🎮  ", " \u{0000} hidden ", " ألعاب ", " c++ "]
        #expect(GameFeedCardTopicPolicy.publicLabels(topics) == ["🎮", "ألعاب", "c++"])
        #expect(GameFeedCardTopicPolicy.visualSummary(topics) == "#🎮  #ألعاب  #c++")
        #expect(GameFeedCardTopicPolicy.accessibilitySummary(topics) ==
                "Topics: 🎮, ألعاب, c++")
    }
}
