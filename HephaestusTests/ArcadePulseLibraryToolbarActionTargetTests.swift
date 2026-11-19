import CoreGraphics
import Testing
@testable import Hephaestus

/// Source policy for the actual inner Library toolbar Button label,
/// not a decorative wrapper or a synthetic signed-in/recent-game state.
struct ArcadePulseLibraryToolbarActionTargetTests {
    @Test func realClearRecentActionOwnsFullTouchRectangle() {
        #expect(LibraryToolbarActionLayout.minimumHitSize ==
                ArcadePulseTheme.minimumTarget)
        #expect(LibraryToolbarActionLayout.minimumHitSize >= CGFloat(44))
    }
}
