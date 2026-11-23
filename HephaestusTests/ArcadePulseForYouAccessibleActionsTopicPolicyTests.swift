import Testing
@testable import Hephaestus

/// Pure backend topic-string presentation contract only. These samples
/// are never published games, accounts, screenshots or synthetic feed rows.
struct ArcadePulseForYouAccessibleActionsTopicPolicyTests {
    @Test func absentAndControlOnlyTopicsOmitTheWholeActionsSection() {
        let missing: [[String]?] = [
            nil, [], ["", "  ", "\n"], ["bad\nline", "\u{0000}", "bad\rvalue"]
        ]
        for labels in missing {
            #expect(ForYouAccessibleActionsTopicPolicy.summary(labels) == nil)
        }
    }

    @Test func invalidEarlyLabelsDoNotDisplaceLaterGenuineBackendTopics() {
        let result = ForYouAccessibleActionsTopicPolicy.summary([
            "", "bad\nline", "  Puzzle  ", "\u{0000}", " 艺术 ", "🎮", "fourth"
        ])
        #expect(result?.visual == "#Puzzle  #艺术  #🎮")
        #expect(result?.spoken == "Topics: Puzzle, 艺术, 🎮")
        #expect(result?.visual.contains("fourth") == false)
    }

    @Test func longLegitimateLatinAndUnicodeNamesStayCompleteInSheetAndVoiceOver() {
        let long = String(repeating: "strategy-", count: 14) + "🎮"
        let result = ForYouAccessibleActionsTopicPolicy.summary([
            long, "ألعاب", "  C++  ", "fourth"
        ])
        #expect(result?.visual == "#\(long)  #ألعاب  #C++")
        #expect(result?.spoken == "Topics: \(long), ألعاب, C++")
    }

    @Test func actionsSheetAndExistingCanonicalMetadataShareTheExactSubset() {
        let cases: [[String]?] = [
            nil, [], ["real"], ["A", "B", "C", "D"],
            [" \n ", "🎨", "坏\u{0000}标签", "艺术", "Arabic"]
        ]
        for labels in cases {
            #expect(ForYouAccessibleActionsTopicPolicy.summary(labels)
                    == GameMetadataTopicPolicy.presentation(labels, maxCount: 3))
        }
    }
}
