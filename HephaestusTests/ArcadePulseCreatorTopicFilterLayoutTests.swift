import SwiftUI
import Testing
@testable import Hephaestus

struct ArcadePulseCreatorTopicFilterLayoutTests {
    @Test func normalTextKeepsSearchFieldAndApplyAlongside() {
        for size in [DynamicTypeSize.xSmall, .small, .medium, .large, .xLarge] {
            #expect(!CreatorTopicFilterLayout.stacksActions(isRegularWidth: false, textSize: size))
            #expect(!CreatorTopicFilterLayout.stacksActions(isRegularWidth: true, textSize: size))
        }
    }

    @Test func compactXXLAndEveryAccessibilitySizeGetsFullWidthApply() {
        #expect(CreatorTopicFilterLayout.stacksActions(
            isRegularWidth: false, textSize: .xxLarge))
        #expect(!CreatorTopicFilterLayout.stacksActions(
            isRegularWidth: true, textSize: .xxLarge))
        for size in [DynamicTypeSize.accessibility1, .accessibility2,
                     .accessibility3, .accessibility4, .accessibility5] {
            #expect(CreatorTopicFilterLayout.stacksActions(
                isRegularWidth: false, textSize: size))
            #expect(CreatorTopicFilterLayout.stacksActions(
                isRegularWidth: true, textSize: size))
        }
        #expect(CreatorTopicFilterLayout.minimumTargetHeight >= 44)
    }
}
