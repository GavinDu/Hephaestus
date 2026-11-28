import SwiftUI
import Testing
@testable import Hephaestus

/// Source policy uses real SwiftUI Dynamic Type cases, not a fake game,
/// private comment, backend response or replacement UI screenshot.
struct CommentsHeaderTitleLayoutTests {
    @Test func standardAndExtraLargeTextUseTwoReadableHeaderLines() {
        #expect(CommentsHeaderTitleLayout.maxLines(for: .xSmall) == 2)
        #expect(CommentsHeaderTitleLayout.maxLines(for: .medium) == 2)
        #expect(CommentsHeaderTitleLayout.maxLines(for: .xxLarge) == 2)
        #expect(CommentsHeaderTitleLayout.maxLines(for: .xxxLarge) == 2)
    }

    @Test func accessibilityOneThroughFiveAllowThreeTitleLines() {
        let sizes: [DynamicTypeSize] = [
            .accessibility1, .accessibility2, .accessibility3,
            .accessibility4, .accessibility5
        ]
        for size in sizes {
            #expect(CommentsHeaderTitleLayout.maxLines(for: size) == 3)
        }
    }

    @Test func allSupportedTextSizesRemainBounded() {
        let sizes: [DynamicTypeSize] = [
            .xSmall, .small, .medium, .large, .xLarge, .xxLarge,
            .xxxLarge, .accessibility1, .accessibility2, .accessibility3,
            .accessibility4, .accessibility5
        ]
        for size in sizes {
            let limit = CommentsHeaderTitleLayout.maxLines(for: size)
            #expect((2...3).contains(limit))
        }
    }
}
