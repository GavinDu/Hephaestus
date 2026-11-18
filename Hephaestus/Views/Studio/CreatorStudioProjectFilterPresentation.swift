import SwiftUI

/// The owner-only Studio has five real project-status choices. Showing all
/// five as side-by-side segments on iPhone or at Accessibility Dynamic Type
/// risks clipped labels and undersized touch regions. Use the system menu
/// instead; leave filtering and authorization in CreatorStudioView.
enum CreatorStudioProjectFilterLayout {
    static func usesMenu(
        horizontalSizeClass: UserInterfaceSizeClass?,
        dynamicTypeSize: DynamicTypeSize
    ) -> Bool {
        horizontalSizeClass != .regular || dynamicTypeSize.isAccessibilitySize
    }
}

/// A single shared presentation modifier preserves the original Picker,
/// selection binding, refresh revision, and real backend request semantics.
struct CreatorStudioProjectFilterPresentation: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    func body(content: Content) -> some View {
        if CreatorStudioProjectFilterLayout.usesMenu(
            horizontalSizeClass: horizontalSizeClass,
            dynamicTypeSize: dynamicTypeSize
        ) {
            content
                .pickerStyle(.menu)
                .frame(
                    minWidth: ArcadePulseTheme.minimumTarget,
                    minHeight: ArcadePulseTheme.minimumTarget,
                    alignment: .leading
                )
                .accessibilityHint("Choose which real project statuses to show")
        } else {
            content.pickerStyle(.segmented)
        }
    }
}
