import SwiftUI

/// Backend-grounded Creator Discovery rows — never substitute a fake creator
/// or synthetic engagement metrics when the directory endpoint is unavailable.
enum CreatorDirectoryRowLayout {
    /// A native UI test may address a real server row by the same genuine
    /// public ID used to load CreatorProfile. No index, invented user or
    /// guessed row count may substitute for a malformed backend identity.
    static func rowAccessibilityIdentifier(for creatorID: String) -> String? {
        let trimmed = creatorID.trimmingCharacters(in: .whitespacesAndNewlines)
        // The row is an actual navigation action, not a decorative label.
        // A nonempty ID with embedded NUL/newline/control characters can
        // pass trimming yet cannot be a reliable public profile destination
        // or a stable native accessibility identifier. Use the same public
        // creator-admission rule as the feed before exposing a tappable row.
        guard trimmed == creatorID,
              ForYouPageLayout.hasNavigableCreator(ownerID: creatorID)
        else { return nil }
        return "creator.discovery.row.\(creatorID)"
    }

    static func stacksHeader(isRegularWidth: Bool, textSize: DynamicTypeSize) -> Bool {
        textSize.isAccessibilitySize ||
            (!isRegularWidth && textSize >= .xxLarge)
    }

    /// A negative server count cannot truthfully describe public games.
    /// Preserve the real Creator identity and route, but never substitute
    /// zero or announce an impossible number in VoiceOver.
    static func publicGameCount(_ count: Int) -> String {
        guard count >= 0 else { return "Public game count unavailable" }
        let formatted = count.formatted()
        return count == 1 ? "\(formatted) public game" : "\(formatted) public games"
    }

    /// Only a real, printable server topic earns a public "#" label.
    /// Validate BEFORE taking five so invalid earlier tokens cannot hide a
    /// later genuine topic. The backend still owns every displayed string.
    static func publicTopicSummary(_ topics: [String]) -> String? {
        let visible = topics.lazy.compactMap { raw -> String? in
            let topic = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !topic.isEmpty,
                  !topic.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else { return nil }
            return "#\(topic)"
        }.prefix(5)
        let summary = visible.joined(separator: "  ")
        return summary.isEmpty ? nil : summary
    }

    /// The parent Creator row button provides an explicit accessibility
    /// label; it must include the very same filtered topics visible on screen
    /// or VoiceOver users will lose all real topic information.
    static func accessibilityLabel(
        creatorID: String,
        count: Int,
        topics: [String]
    ) -> String {
        let base = "View creator \(creatorID), \(publicGameCount(count))"
        guard let summary = publicTopicSummary(topics) else { return base }
        return base + ", topics: " + summary
    }
}

struct CreatorDirectoryRow: View {
    let creatorID: String
    let publicGameCount: Int
    let topics: [String]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var stacksHeader: Bool {
        CreatorDirectoryRowLayout.stacksHeader(
            isRegularWidth: horizontalSizeClass == .regular,
            textSize: dynamicTypeSize
        )
    }

    private var headerLayout: AnyLayout {
        stacksHeader
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            headerLayout {
                Text(creatorID)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                if !stacksHeader {
                    Spacer(minLength: 8)
                }
                Text(CreatorDirectoryRowLayout.publicGameCount(publicGameCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let topicSummary = CreatorDirectoryRowLayout.publicTopicSummary(topics) {
                Text(topicSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.vertical, 5)
    }
}
