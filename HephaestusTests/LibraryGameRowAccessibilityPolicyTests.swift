import Foundation
import Testing
@testable import Hephaestus

/// Pure AX-label policy tests. No fabricated published game, backend
/// response, account, screenshot or actual VoiceOver interaction is created.
struct LibraryGameRowAccessibilityPolicyTests {
    @Test func sameActualTitleIsDistinguishableAcrossSavedAndRecentCollections() {
        let title = "飘带补天 Ribbon Mends the Sky"
        #expect(LibraryGameRowAccessibilityPolicy.label(
            title: title, scope: .saved
        ) == "Play saved game: 飘带补天 Ribbon Mends the Sky")
        #expect(LibraryGameRowAccessibilityPolicy.label(
            title: title, scope: .recent
        ) == "Play recently played game: 飘带补天 Ribbon Mends the Sky")
    }

    @Test func realUnicodeCaseAndEmojiRemainVerbatimInSpokenGameName() {
        let title = "游戏 🎮 Puzzle aBc"
        let label = LibraryGameRowAccessibilityPolicy.label(
            title: title, scope: .saved
        )
        #expect(label == "Play saved game: 游戏 🎮 Puzzle aBc")
    }

    @Test func spokenActionNormalizesControlsWithoutMutatingTheVisibleTitle() {
        let title = "  Genuine\tRibbon\nGame\u{0000}   🎮  "
        #expect(LibraryGameRowAccessibilityPolicy.label(
            title: title, scope: .recent
        ) == "Play recently played game: Genuine Ribbon Game 🎮")
        #expect(title.contains("\n"))
    }

    @Test func emptyAndWhitespaceOnlyTitlesNeverInventAName() {
        for title in ["", " ", "\t\n", "\u{0000}"] {
            #expect(LibraryGameRowAccessibilityPolicy.label(
                title: title, scope: .saved
            ) == "Play saved game")
            #expect(LibraryGameRowAccessibilityPolicy.label(
                title: title, scope: .recent
            ) == "Play recently played game")
        }
    }

    @Test func sourceTitleIsNotPrefixedWithAnInventedOwnerOrEngagement() {
        let spoken = LibraryGameRowAccessibilityPolicy.label(
            title: "Real title", scope: .saved
        )
        #expect(spoken == "Play saved game: Real title")
        #expect(!spoken.contains("likes"))
        #expect(!spoken.contains("creator"))
    }
}
