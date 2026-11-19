import Foundation
import CoreGraphics
import Testing
@testable import Hephaestus

/// The UIKit label itself, not a decorative outer toolbar wrapper,
/// must reserve 44pt in BOTH dimensions on iPhone and iPad.
struct ArcadePulseDiscoverToolbarHitTargetTests {
    @Test func threeDiscoverToolbarActionsUseCanonicalFullTouchSize() {
        #expect(DiscoverToolbarActionLayout.minimumHitSize == ArcadePulseTheme.minimumTarget)
        #expect(DiscoverToolbarActionLayout.minimumHitSize >= CGFloat(44))
    }
}
