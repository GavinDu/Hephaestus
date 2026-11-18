import Testing
@testable import Hephaestus

/// Only literal, actual source topic strings; no pretend published game.
struct ArcadePulseFeedPreferenceTopicPolicyTests {
    @Test func emptyOrInvalidSourcesDoNotMakeInventedPreferences() {
        #expect(FeedPreferenceTopicPolicy.availableTopics(
            feedTopics: [], mutedTopics: []).isEmpty)
        #expect(FeedPreferenceTopicPolicy.availableTopics(
            feedTopics: [["", "  ", "\n", "bad\nline", "\u{0000}"]],
            mutedTopics: ["", "\t", "bad\rchoice"]).isEmpty)
    }

    @Test func realBackendTopicsRetainCurrentLowercaseAndSortedSemantics() {
        #expect(FeedPreferenceTopicPolicy.availableTopics(
            feedTopics: [[" Puzzle ", "art", "puzzle"], ["艺术", "ART", "c++"]],
            mutedTopics: []).elementsEqual(["art", "c++", "puzzle", "艺术"]))
    }

    @Test func persistedMutedOnlyChoiceCanStillBeRemovedWithOriginalKey() {
        let topics = FeedPreferenceTopicPolicy.availableTopics(
            feedTopics: [["PUZZLE"]], mutedTopics: ["Custom Saved Topic", "foo\nbar"])
        #expect(topics == ["Custom Saved Topic", "puzzle"])
    }

    @Test func validUnicodeAndEmojiAreNotInventedOrSuppressed() {
        let topics = FeedPreferenceTopicPolicy.availableTopics(
            feedTopics: [[" ألعاب ", " 🎮 ", "  游戏 "]], mutedTopics: [])
        #expect(Set(topics) == Set(["ألعاب", "🎮", "游戏"]))
    }
}
