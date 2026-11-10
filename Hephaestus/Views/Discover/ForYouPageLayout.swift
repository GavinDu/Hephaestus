import SwiftUI

/// Pure sizing policy for the full-screen For You pager.
/// Compact layouts fill the available width; regular layouts preserve a
/// portrait 9:16 stage with a readable maximum width.
enum ForYouPageLayout {
    /// A stable per-game palette slot for truthful fallback artwork when no
    /// approved poster/clip exists. Hash through a larger prime first: reducing
    /// modulo a five-color palette inside the loop makes 31 ≡ 1 (mod 5)
    /// and reintroduces the same anagram/same-sum collisions as before.
    static func fallbackPaletteIndex(gameID: String, paletteCount: Int) -> Int {
        guard paletteCount > 0 else { return 0 }
        let hash = gameID.utf8.reduce(0) { partial, byte in
            (partial * 31 + Int(byte)) % 101
        }
        return hash % paletteCount
    }

    static func stageWidth(containerWidth: CGFloat, containerHeight: CGFloat, isRegular: Bool, isLandscape: Bool = false) -> CGFloat {
        guard isRegular else { return containerWidth }
        // iPad landscape uses the available canvas. Portrait simulator
        // screenshots showed a 680pt stage surrounded by unused space even
        // when the feed had room for gameplay artwork and touch controls.
        // Use most of the tablet width while preserving a portrait-focused
        // theater stage; never stretch the game's actual preview pixels.
        if isLandscape { return min(containerWidth, 1_120) }
        return min(containerWidth * 0.86, min(containerHeight * 0.64, 820))
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

    /// A media-first post should not lose an entire row to feed scopes on
    /// compact-width iPhones, in portrait *or* landscape. Keep one accessible
    /// toolbar menu; explicit search still restores the segmented picker.
    /// Regular-width iPad can retain its visible scope picker.
    static func prefersCompactScopeMenu(
        verticalSizeClass: UserInterfaceSizeClass?,
        horizontalSizeClass: UserInterfaceSizeClass? = nil,
        searchText: String
    ) -> Bool {
        (verticalSizeClass == .compact || horizontalSizeClass == .compact) &&
            searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Keep iPhone landscape's search and scope reachable without reducing
    /// the game media stage to a narrow letterboxed strip.
    static func usesCompactLandscapeOverlay(
        verticalSizeClass: UserInterfaceSizeClass?,
        horizontalSizeClass: UserInterfaceSizeClass?,
        hasImmersivePager: Bool
    ) -> Bool {
        // iPhone Plus/Pro Max can report a REGULAR horizontal class when landscape.
        // Height is the decisive signal; the caller checks phone idiom.
        hasImmersivePager && verticalSizeClass == .compact
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

    static func mediaAccessibilityLabel(title: String, hasPreviewMedia: Bool = true) -> String {
        // The simulator screenshot audit found legitimate fallback pages.
        // Do not imply a gameplay screenshot or recorded clip exists when
        // this feed card has neither a poster nor a clip URL.
        guard hasPreviewMedia else {
            return "Gameplay preview not available for \(title). Use Play now to start."
        }
        return "Game artwork or preview for \(title). Use Play now to start."
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
