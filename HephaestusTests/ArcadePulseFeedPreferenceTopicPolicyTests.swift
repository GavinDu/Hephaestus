import Testing
@testable import Hephaestus

/// Pure policy only. Never fabricate published feed games or saved choices.
struct ArcadePulseFeedPreferenceTopicPolicyTests {
    @Test func malformedAndBlankLabelsNeverBecomeOptions() {
        #expect(FeedPreferenceTopicPolicy.availableTopics(
            feedTopics: [], mutedTopics: []).isEmpty)
        #expect(FeedPreferenceTopicPolicy.availableTopics(
            feedTopics: [["", "  ", "\n", "bad\nline", "\u{0000}"]],
            mutedTopics: ["", "\t", "bad\rchoice"]).isEmpty)
    }

    @Test func genuineTopicsStaySortedAndCaseNormalized() {
        #expect(FeedPreferenceTopicPolicy.availableTopics(
            feedTopics: [[" Puzzle ", "art", "puzzle"], ["艺术", "ART", "c++"]],
            mutedTopics: []).elementsEqual(["art", "c++", "puzzle", "艺术"]))
    }

    @Test func mutedOnlyChoiceCanBeRemovedUsingItsOriginalKey() {
        let topics = FeedPreferenceTopicPolicy.availableTopics(
            feedTopics: [["PUZZLE"]], mutedTopics: ["Custom Saved Topic", "foo\nbar"])
        #expect(topics == ["Custom Saved Topic", "puzzle"])
    }

    @Test func unicodeAndEmojiLabelsRemainGenuine() {
        let actual = FeedPreferenceTopicPolicy.availableTopics(
            feedTopics: [[" ألعاب ", " 🎮 ", " 游戏 "]], mutedTopics: [])
        #expect(Set(actual) == Set(["ألعاب", "🎮", "游戏"]))
    }
}
