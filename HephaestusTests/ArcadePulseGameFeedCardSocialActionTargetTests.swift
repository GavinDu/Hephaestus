import Foundation
import CoreGraphics
import Testing
@testable import Hephaestus

/// These are the actual 44pt interactive labels on a backend GameFeedCard.
/// This source test does not pretend a genuine published game was visible.
struct ArcadePulseGameFeedCardSocialActionTargetTests {
    @Test func gridSocialIconTouchTargetMeetsMinimumInBothDimensions() {
        #expect(GameFeedCardSocialActionLayout.minimumHitSize >= CGFloat(44))
        #expect(GameFeedCardSocialActionLayout.minimumHitSize ==
                ArcadePulseTheme.minimumTarget)
    }
}
