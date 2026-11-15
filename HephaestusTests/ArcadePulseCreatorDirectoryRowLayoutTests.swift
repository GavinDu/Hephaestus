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

    @Test func realPublicGameCountsHaveCorrectSingularPlural() {
        #expect(CreatorDirectoryRowLayout.publicGameCount(0).contains("public games"))
        #expect(CreatorDirectoryRowLayout.publicGameCount(1) == "1 public game")
        #expect(CreatorDirectoryRowLayout.publicGameCount(2).contains("public games"))
    }
}
