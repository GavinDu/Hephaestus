import SwiftUI

/// Accessible native topic filter for the real Creator Discovery endpoint.
/// Keep the existing host's search/load generation and permission contracts.
enum CreatorTopicFilterLayout {
    static let minimumTargetHeight: CGFloat = 48

    static func stacksActions(isRegularWidth: Bool, textSize: DynamicTypeSize) -> Bool {
        textSize.isAccessibilitySize ||
            (!isRegularWidth && textSize >= .xxLarge)
    }
}

struct CreatorTopicFilterControls: View {
    @Binding var topicText: String
    let isLoading: Bool
    let onApply: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var stacked: Bool {
        CreatorTopicFilterLayout.stacksActions(
            isRegularWidth: horizontalSizeClass == .regular,
            textSize: dynamicTypeSize
        )
    }

    private var controlsLayout: AnyLayout {
        stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
    }

    var body: some View {
        controlsLayout {
            TextField("Filter by topic (optional)", text: $topicText)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(onApply)
                .frame(maxWidth: .infinity, minHeight: CreatorTopicFilterLayout.minimumTargetHeight)
                .accessibilityIdentifier("creator.discovery.topicInput")

            Button(action: onApply) {
                Text(isLoading ? "Searching…" : "Apply")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.black)
                    .frame(minWidth: 64,
                           maxWidth: stacked ? .infinity : nil,
                           minHeight: CreatorTopicFilterLayout.minimumTargetHeight)
            }
            .buttonStyle(.borderedProminent)
            .tint(ArcadePulseTheme.electricViolet)
            .disabled(isLoading)
            .accessibilityLabel(isLoading ? "Searching creators" : "Apply topic filter")
            .accessibilityIdentifier("creator.discovery.topicApply")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
