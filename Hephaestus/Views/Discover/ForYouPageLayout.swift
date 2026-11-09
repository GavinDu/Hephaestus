import SwiftUI

/// Pure sizing policy for the full-screen For You pager.
/// Compact layouts fill the available width; regular layouts preserve a
/// portrait 9:16 stage with a readable maximum width.
enum ForYouPageLayout {
    static func stageWidth(containerWidth: CGFloat, containerHeight: CGFloat, isRegular: Bool, isLandscape: Bool = false) -> CGFloat {
        guard isRegular else { return containerWidth }
        // iPad landscape uses the available canvas. In portrait, a strict
        // phone-sized 9:16 stage left more than 40% of an iPad's usable
        // viewport empty in screenshot review. Widen the stage modestly,
        // but cap it so the video/game poster remains a focal element rather
        // than becoming an edge-to-edge stretched landscape canvas.
        if isLandscape { return min(containerWidth, 1_120) }
        return min(containerWidth * 0.78, min(containerHeight * 0.60, 680))
    }

    /// Page swipes must respond to quick, deliberate vertical flicks, not only
    /// slow 80-point drags. Require a real 35-point drag first so a tap on
    /// Play / Like cannot advance the feed. Predicted momentum counts only
    /// when it continues vertically in the same direction.
    static func pageOffsetForSwipe(translation: CGSize, predictedEndTranslation: CGSize) -> Int {
        let vertical = translation.height
        let horizontal = translation.width
        guard abs(vertical) >= 35, abs(vertical) > abs(horizontal) * 1.2 else { return 0 }
        let predicted = predictedEndTranslation.height
        let predictedIsVertical = abs(predicted) > abs(predictedEndTranslation.width) * 1.2
        let projectedTravel = predictedIsVertical && predicted * vertical > 0
            ? max(abs(vertical), abs(predicted)) : abs(vertical)
        guard projectedTravel >= 80 else { return 0 }
        return vertical < 0 ? 1 : -1
    }

    // All social feeds use the same immersive vertical pager whenever real
    // cards are available. Searching still exposes the compact grid.
    static func shouldShowImmersivePager(searchText: String, hasGames: Bool) -> Bool {
        hasGames && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // A failed cursor load must not spin background retries or replace the
    // settled page with the grid. The user can explicitly retry in place.
    static func shouldAutoLoadNextPage(hasCursor: Bool, isLoading: Bool,
                                       isLoadingMore: Bool, hasPaginationError: Bool) -> Bool {
        hasCursor && !isLoading && !isLoadingMore && !hasPaginationError
    }

    // Both a successful cursor response and its error must belong to the
    // currently selected scope AND request generation. Matching only the
    // generation can briefly expose a stale tab's pagination error.
    static func shouldApplyPaginationResult(
        requestedScope: SocialFeedScope, currentScope: SocialFeedScope,
        requestedGeneration: Int, currentGeneration: Int) -> Bool {
        requestedScope == currentScope && requestedGeneration == currentGeneration
    }

    // Play Next stays within its originating feed; an existing game should
    // not be replaced by an unrelated For You fetch after finishing a round.
    // Clear any search filter so the target card can become the settled page.
    static func contextAfterPlayingNext(currentScope: SocialFeedScope, nextGameID: String)
        -> (scope: SocialFeedScope, searchText: String, selectedGameID: String) {
        (currentScope, "", nextGameID)
    }

    static func mediaAccessibilityLabel(title: String) -> String {
        "Game artwork or preview for \(title). Use Play now to start."
    }

    static func contentMaxWidth(isRegular: Bool) -> CGFloat {
        isRegular ? 760 : .infinity
    }

    /// Keep the current page when it still exists; otherwise select the first
    /// available page. An empty feed intentionally has no selected page.
    static func reconciledSelection(currentID: String?, availableIDs: [String]) -> String? {
        guard !availableIDs.isEmpty else { return nil }
        if let currentID, availableIDs.contains(currentID) { return currentID }
        return availableIDs.first
    }

    /// Settled pages require a brief uninterrupted dwell before generating
    /// an impression; a rapid swipe or offscreen prefetch is not a view.
    static let impressionMinimumDwellMilliseconds = 700

    static func shouldTrackImpression(isSettled: Bool, dwellMilliseconds: Int = impressionMinimumDwellMilliseconds) -> Bool {
        isSettled && dwellMilliseconds >= impressionMinimumDwellMilliseconds
    }
}
