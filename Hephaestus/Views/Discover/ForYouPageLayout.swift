import SwiftUI

/// Pure sizing policy for the full-screen For You pager.
/// Compact layouts fill the available width; regular layouts preserve a
/// portrait 9:16 stage with a readable maximum width.
enum ForYouPageLayout {
    static func stageWidth(containerWidth: CGFloat, containerHeight: CGFloat, isRegular: Bool) -> CGFloat {
        guard isRegular else { return containerWidth }
        return min(containerWidth, min(containerHeight * 9 / 16, 560))
    }
}
