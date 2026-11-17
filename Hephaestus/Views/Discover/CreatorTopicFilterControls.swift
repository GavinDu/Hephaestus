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
                // The Creator Discovery host owns ONE search submission
                // action for both this field and the navigation search bar.
                // A nested onSubmit plus outer onSubmit could reset twice,
                // and the old inner handler ignored the disabled Apply state.
                .frame(maxWidth: .infinity, minHeight: CreatorTopicFilterLayout.minimumTargetHeight)
                .accessibilityIdentifier("creator.discovery.topicInput")

            Button {
                if CreatorQuerySubmitPolicy.canSubmit(isLoading: isLoading) {
                    onApply()
                }
            } label: {
                // Native iPad/iPhone CI measured the old borderedProminent
                // accessibility Button at only 22pt despite a 48pt inner
                // Text frame. Own the real 48pt interactive surface here.
                Text(isLoading ? "Searching…" : "Apply")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .frame(minWidth: 64,
                           maxWidth: stacked ? .infinity : nil,
                           minHeight: CreatorTopicFilterLayout.minimumTargetHeight)
                    .background(
                        ArcadePulseTheme.electricViolet,
                        in: RoundedRectangle(cornerRadius: 15)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isLoading ? 0.65 : 1)
            .disabled(isLoading)
            .accessibilityLabel(isLoading ? "Searching creators" : "Apply topic filter")
            .accessibilityIdentifier("creator.discovery.topicApply")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
