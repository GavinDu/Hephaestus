import SwiftUI
import Testing
@testable import Hephaestus

/// Layout-policy coverage only. Real directory creator, VoiceOver and
/// screenshot evidence remain independent Epic #172 release gates.
struct ArcadePulseCreatorDirectoryRowLayoutTests {
    @Test func standardTextKeepsCreatorAndCountSideBySide() {
        for textSize in [DynamicTypeSize.xSmall, .small, .medium, .large, .xLarge] {
            #expect(!CreatorDirectoryRowLayout.stacksHeader(
                isRegularWidth: false, textSize: textSize))
            #expect(!CreatorDirectoryRowLayout.stacksHeader(
                isRegularWidth: true, textSize: textSize))
        }
    }

    @Test func enlargedCompactAndEveryAccessibilitySizeStack() {
        #expect(CreatorDirectoryRowLayout.stacksHeader(
            isRegularWidth: false, textSize: .xxLarge))
        #expect(!CreatorDirectoryRowLayout.stacksHeader(
            isRegularWidth: true, textSize: .xxLarge))
        #expect(CreatorDirectoryRowLayout.stacksHeader(
            isRegularWidth: false, textSize: .xxxLarge))
        for textSize in [DynamicTypeSize.accessibility1, .accessibility2,
                         .accessibility3, .accessibility4, .accessibility5] {
            #expect(CreatorDirectoryRowLayout.stacksHeader(
                isRegularWidth: false, textSize: textSize))
            #expect(CreatorDirectoryRowLayout.stacksHeader(
                isRegularWidth: true, textSize: textSize))
        }
    }

    @Test func accessibilityRowIdentityUsesOnlyGenuineNonemptyBackendID() {
        #expect(CreatorDirectoryRowLayout.rowAccessibilityIdentifier(
            for: "doodlequest") == "creator.discovery.row.doodlequest")
        #expect(CreatorDirectoryRowLayout.rowAccessibilityIdentifier(
            for: "creator-123") == "creator.discovery.row.creator-123")
        #expect(CreatorDirectoryRowLayout.rowAccessibilityIdentifier(
            for: "创作者") == "creator.discovery.row.创作者")
        for invalid in ["", " ", "\t", " creator ", "\ncreator", "creator\n"] {
            #expect(CreatorDirectoryRowLayout.rowAccessibilityIdentifier(
                for: invalid) == nil)
        }
        // No order/index-based synthetic identifier, no fabricated account.
        #expect(CreatorDirectoryRowLayout.rowAccessibilityIdentifier(
            for: "doodlequest") ==
                CreatorDirectoryRowLayout.rowAccessibilityIdentifier(
                    for: "doodlequest"))
    }

    @Test func realPublicGameCountsHaveCorrectSingularPlural() {
        #expect(CreatorDirectoryRowLayout.publicGameCount(0).contains("public games"))
        #expect(CreatorDirectoryRowLayout.publicGameCount(1) == "1 public game")
        #expect(CreatorDirectoryRowLayout.publicGameCount(2).contains("public games"))
    }

    @Test func emptyOrNonPrintableServerTopicsDoNotBecomeHashtags() {
        #expect(CreatorDirectoryRowLayout.publicTopicSummary([]) == nil)
        #expect(CreatorDirectoryRowLayout.publicTopicSummary(["", " ", "\t", "\n"]) == nil)
        #expect(CreatorDirectoryRowLayout.publicTopicSummary(
            ["real", "bad\nlabel", " \u{0000} ", "legit"]
        ) == "#real  #legit")
    }

    @Test func firstFiveActualPublicTopicsIgnoreBlankEarlierSlots() {
        let topics = ["", " \t ", "art", "games", "design", "music", "science", "sixth"]
        #expect(CreatorDirectoryRowLayout.publicTopicSummary(topics) ==
                "#art  #games  #design  #music  #science")
    }

    @Test func genuineNonEnglishAndTrimmedTopicsKeepOriginalOrder() {
        #expect(CreatorDirectoryRowLayout.publicTopicSummary(
            ["  创意  ", "🎮", "c++", " ألعاب "]
        ) == "#创意  #🎮  #c++  #ألعاب")
    }
    @Test func actualRowVoiceOverLabelUsesExactlyVisibleFilteredTopics() {
        let topics = ["", "  游戏  ", " \t ", "art", "bad\nline", "design"]
        let summary = CreatorDirectoryRowLayout.publicTopicSummary(topics)
        #expect(summary == "#游戏  #art  #design")
        let label = CreatorDirectoryRowLayout.accessibilityLabel(
            creatorID: "server-owned-id", count: 2, topics: topics)
        #expect(label == "View creator server-owned-id, 2 public games, topics: #游戏  #art  #design")
        #expect(!label.contains("bad\nline"))
        #expect(CreatorDirectoryRowLayout.accessibilityLabel(
            creatorID: "server-owned-id", count: 0, topics: ["", "\n"]) ==
            "View creator server-owned-id, 0 public games")
    }
}
