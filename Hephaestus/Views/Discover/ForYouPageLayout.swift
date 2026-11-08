import SwiftUI

/// Pure sizing policy for the full-screen For You pager.
/// Compact layouts fill the available width; regular layouts preserve a
/// portrait 9:16 stage with a readable maximum width.
enum ForYouPageLayout {
    static func stageWidth(containerWidth: CGFloat, containerHeight: CGFloat, isRegular: Bool, isLandscape: Bool = false) -> CGFloat {
        guard isRegular else { return containerWidth }
        // iPad portrait keeps a focused 9:16 viewer; landscape uses the
        // available canvas so the feed feels intentional in either posture.
        if isLandscape { return min(containerWidth, 1_120) }
        return min(containerWidth, min(containerHeight * 9 / 16, 560))
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
