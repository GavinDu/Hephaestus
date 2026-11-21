import Testing
@testable import Hephaestus

/// Source-only account-transition policy. Tests use non-game sentinels;
/// no fake published game, account credentials or moderation response.
struct DiscoverViewerBoundSelectionPolicyTests {
    @Test func viewerChangeRevokesSelectedHostSheetIdentity() {
        let selected: String? = "existing-selection-sentinel"
        let after = DiscoverViewerBoundSelectionPolicy.selectionAfterTransition(
            selected, viewerChanged: true
        )
        #expect(after == nil)
    }

    @Test func ordinaryReloadOrRotationRetainsSameViewerSelection() {
        let selected: String? = "unchanged-selection-sentinel"
        let after = DiscoverViewerBoundSelectionPolicy.selectionAfterTransition(
            selected, viewerChanged: false
        )
        #expect(after == selected)
    }

    @Test func revocationIsIdempotentWhenAlreadyDismissed() {
        let selection: Int? = nil
        let first = DiscoverViewerBoundSelectionPolicy.selectionAfterTransition(
            selection, viewerChanged: true
        )
        let second = DiscoverViewerBoundSelectionPolicy.selectionAfterTransition(
            first, viewerChanged: true
        )
        #expect(first == nil)
        #expect(second == nil)
    }

    @Test func viewerChangeRevokesWithoutInspectingOrLeakingGameIdentity() {
        let previous: Int? = 7
        let after = DiscoverViewerBoundSelectionPolicy.selectionAfterTransition(
            previous, viewerChanged: true
        )
        #expect(after == nil)
    }
}
