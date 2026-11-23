import SwiftUI

/// Public expression provenance is backend text, not a cover overlay.
/// Accessibility text requires a vertical metadata and counts layout.
enum PlayableExpressionLayout {
    static func stacksMetadata(for size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }
}

/// The feed grid displays only backend-owned topic strings. Reject malformed
/// labels before choosing the three visible slots so they do not displace a
/// later genuine tag; VoiceOver must announce the identical source subset.
enum GameFeedCardTopicPolicy {
    static func publicLabels(_ topics: [String]?, limit: Int = 3) -> [String] {
        guard limit > 0 else { return [] }
        let validated = (topics ?? []).lazy.compactMap { raw -> String? in
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty,
                  !label.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else { return nil }
            return label
        }
        return Array(validated.prefix(limit))
    }

    static func visualSummary(_ topics: [String]?) -> String? {
        let labels = publicLabels(topics)
        return labels.isEmpty ? nil : labels.map { "#\($0)" }.joined(separator: "  ")
    }

    static func accessibilitySummary(_ topics: [String]?) -> String? {
        let labels = publicLabels(topics)
        return labels.isEmpty ? nil : "Topics: " + labels.joined(separator: ", ")
    }
}

/// iPad Spotlight and Game Details show four/five original publisher topics,
/// not the three shown on grid cards. Use exactly one validated backend list
/// for visible and spoken content; no malformed topic consumes a slot.
enum GameMetadataTopicPolicy {
    struct Presentation: Equatable {
        let visual: String
        let spoken: String
    }

    static func presentation(_ topics: [String]?, maxCount: Int) -> Presentation? {
        let labels = GameFeedCardTopicPolicy.publicLabels(topics, limit: maxCount)
        guard !labels.isEmpty else { return nil }
        return Presentation(
            visual: labels.map { "#\($0)" }.joined(separator: "  "),
            spoken: "Topics: " + labels.joined(separator: ", ")
        )
    }
}

/// A tappable social icon must own the complete 44pt hit rectangle,
/// rather than only the surrounding HStack's layout. Actual compact width
/// and VoiceOver action ordering are independently tested on real cards.
enum GameFeedCardSocialActionLayout {
    static let minimumHitSize: CGFloat = ArcadePulseTheme.minimumTarget
}

/// A game-first social card. Until the API returns real preview assets and creator
/// metadata, the cover is a branded visual rather than fabricated artwork.
struct GameFeedCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                .frame(height: 168)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                .frame(width: 176, height: 18)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                .frame(width: 112, height: 13)
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                    .frame(width: 100, height: HephaestusDesign.minimumActionHeight)
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                    .frame(width: 86, height: HephaestusDesign.minimumActionHeight)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HephaestusDesign.cardBackground, in: RoundedRectangle(cornerRadius: HephaestusDesign.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: HephaestusDesign.cardRadius, style: .continuous).strokeBorder(HephaestusDesign.subtleBorder, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

struct GameFeedCard: View {
    @ScaledMetric(relativeTo: .largeTitle) private var coverHeight: CGFloat = 220
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var previewPlayback = FeedPreviewPlayback.shared
    let game: FeedGame
    let isSaved: Bool
    let isLiked: Bool
    let isFollowingCreator: Bool
    let canFollowCreator: Bool
    let onPlay: () -> Void
    let onToggleSaved: () -> Void
    let onToggleLike: () -> Void
    let onToggleFollow: () -> Void
    let onOpenComments: () -> Void
    let onOpenCreator: () -> Void
    let onReport: () -> Void
    let onBlockCreator: () -> Void
    let onNotInterested: () -> Void
    let onImpression: () -> Void
    // Poster-only grid cards must not compete with the settled For You
    // pager for the one shared AVQueuePlayer and decoder.
    var shouldAutoplayPreview: Bool = false

    private var shareURL: URL {
        var components = URLComponents(url: BackendConfig.baseURL.appendingPathComponent("player"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "game", value: game.id)]
        return components.url ?? BackendConfig.baseURL
    }

    private var palette: [Color] {
        ArcadePulseTheme.fallbackPalette(gameID: game.id)
    }

    private func expressionTag(_ title: String, count: Int?) -> some View {
        Text(PlayableExpressionClaimCountPresentation.visualLabel(
            category: title, count: count
        ))
            .font(.caption.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(PlayableExpressionClaimCountPresentation.accessibilityLabel(
                category: title, count: count
            ))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.white.opacity(0.16), in: Capsule())
    }

    private func expressionAccessibilityLabel(_ expression: FeedPlayableExpression) -> String {
        return [
            "Playable expression",
            expression.intent,
            expression.chosen_interpretation.map { "Interpretation: \($0)" },
            "Source shared",
            PlayableExpressionClaimCountPresentation.accessibilityLabel(
                category: "Preserved", count: expression.preserved?.count),
            PlayableExpressionClaimCountPresentation.accessibilityLabel(
                category: "Invented", count: expression.invented?.count),
            PlayableExpressionClaimCountPresentation.accessibilityLabel(
                category: "Uncertain", count: expression.uncertain?.count)
        ].compactMap { $0 }.joined(separator: ". ")
    }

    private func playableExpressionSummary(_ expression: FeedPlayableExpression) -> some View {
        // Ordinary sizes stay compact; accessibility text stacks genuine
        // classifications rather than shrinking them inside the poster.
        let metadataLayout = PlayableExpressionLayout.stacksMetadata(for: dynamicTypeSize)
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 6))
        return VStack(alignment: .leading, spacing: 8) {
            metadataLayout {
                Label("PLAYABLE EXPRESSION", systemImage: "sparkles")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                Text("SOURCE SHARED")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.18), in: Capsule())
            }
            if let intent = expression.intent, !intent.isEmpty {
                Text(intent)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let interpretation = expression.chosen_interpretation, !interpretation.isEmpty {
                Text("Interpretation · " + interpretation)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            metadataLayout {
                expressionTag("Preserved", count: expression.preserved?.count)
                expressionTag("Invented", count: expression.invented?.count)
                expressionTag("Uncertain", count: expression.uncertain?.count)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.72),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(expressionAccessibilityLabel(expression))
    }

    /// A backend media reference must be an absolute web URL. Never treat a
    /// relative path or a local-file/JavaScript scheme as approved poster art.
    static func validatedPosterURL(_ raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Decorative fallback is only rendered when no decoded real poster is
    /// available; it is NOT evidence of game play or a recorded preview.
    private var fallbackArtwork: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.12))
                .frame(width: 180, height: 180)
                .offset(x: 210, y: -80)
            Circle()
                .stroke(.white.opacity(0.18), lineWidth: 1)
                .frame(width: 220, height: 220)
                .offset(x: 180, y: -20)
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 64, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var posterArtwork: some View {
        if let posterURL = Self.validatedPosterURL(game.previewPosterURL) {
            AsyncImage(url: posterURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .empty:
                    ProgressView("Loading game artwork")
                        .tint(.white)
                        .foregroundStyle(.white)
                case .failure:
                    fallbackArtwork
                @unknown default:
                    fallbackArtwork
                }
            }
            .accessibilityHidden(true)
        } else {
            fallbackArtwork
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
                posterArtwork
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                // This grid card does not normally own the feed's shared
                // decoder. If explicitly enabled, keep the current poster
                // visible until AVPlayerLayer has a *real* decoded frame.
                if shouldAutoplayPreview &&
                    previewPlayback.activeGameID == game.id && !reduceMotion {
                    FeedPreviewSurface(
                        player: previewPlayback.player,
                        onReadyForDisplay: { [generation = previewPlayback.presentationGeneration] ready in
                            previewPlayback.reportDisplayReadiness(
                                gameID: game.id, generation: generation, ready: ready
                            )
                        }
                    )
                    .id(previewPlayback.presentationGeneration)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("COMMUNITY GAME")
                            .font(.caption2.weight(.bold))
                            .tracking(1.2)
                            .foregroundStyle(.white.opacity(0.82))
                        if let orientation = game.orientationLabel {
                            Text(orientation).font(.caption2.weight(.semibold))
                        }
                        if let parentID = game.remixParentID, !parentID.isEmpty {
                            Label("REMIX", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.white.opacity(0.18), in: Capsule())
                                .accessibilityLabel("Remix of another game")
                        }
                    }
                    Text(game.title)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    if let caption = game.caption, !caption.isEmpty {
                        Text(caption).font(.subheadline).foregroundStyle(.white.opacity(0.94)).lineLimit(3)
                    }
                    if let visualTopics = GameFeedCardTopicPolicy.visualSummary(game.topics) {
                        Text(visualTopics)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                            .accessibilityLabel(
                                GameFeedCardTopicPolicy.accessibilitySummary(game.topics) ?? ""
                            )
                    }
                }
                .padding(18)
            }
            .frame(height: coverHeight)
            .clipped()

            // Grid cards can be half an iPhone viewport wide. Keep the
            // authentic creator name on its own line, then wrap every
            // full-sized social action instead of squeezing six controls
            // into a single clipped horizontal row.
            VStack(alignment: .leading, spacing: 8) {
                if let creator = game.ownerID, !creator.isEmpty {
                    ArcadePulseCreatorIdentity(
                        name: game.creatorDisplayName?.isEmpty == false
                            ? game.creatorDisplayName! : creator,
                        avatarURL: game.creatorAvatarURL,
                        foreground: .primary,
                        action: onOpenCreator
                    )
                } else {
                    Label("Mini game", systemImage: "sparkles")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(
                        minimum: GameFeedCardSocialActionLayout.minimumHitSize
                    ), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    if canFollowCreator {
                        Button(action: onToggleFollow) {
                            Image(systemName: isFollowingCreator
                                  ? "person.fill.checkmark" : "person.badge.plus")
                                .frame(width: GameFeedCardSocialActionLayout.minimumHitSize,
                                       height: GameFeedCardSocialActionLayout.minimumHitSize)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isFollowingCreator ? "Unfollow creator" : "Follow creator")
                        .accessibilityIdentifier("grid.game.social.follow")
                    }
                    Button(action: onToggleLike) {
                        Image(systemName: isLiked ? "heart.fill" : "heart")
                            .foregroundStyle(isLiked ? Color.pink : Color.primary)
                            .frame(width: GameFeedCardSocialActionLayout.minimumHitSize,
                                   height: GameFeedCardSocialActionLayout.minimumHitSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isLiked ? "Unlike game" : "Like game")
                    .accessibilityIdentifier("grid.game.social.like")

                    Button(action: onOpenComments) {
                        Image(systemName: "bubble.right")
                            .frame(width: GameFeedCardSocialActionLayout.minimumHitSize,
                                   height: GameFeedCardSocialActionLayout.minimumHitSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View comments")
                    .accessibilityIdentifier("grid.game.social.comments")

                    Menu {
                        Button("Not interested", systemImage: "hand.thumbsdown",
                               action: onNotInterested)
                        if ForYouPageLayout.canOfferCreatorBlock(
                            ownerID: game.ownerID,
                            viewerID: BackendConfig.currentUserID
                        ) {
                            Button("Block creator", systemImage: "person.crop.circle.badge.xmark",
                                   role: .destructive, action: onBlockCreator)
                        }
                        Button("Report game", systemImage: "flag",
                               role: .destructive, action: onReport)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: GameFeedCardSocialActionLayout.minimumHitSize,
                                   height: GameFeedCardSocialActionLayout.minimumHitSize)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("More game options")
                    .accessibilityIdentifier("grid.game.social.more")

                    Button(action: onToggleSaved) {
                        Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                            .foregroundStyle(isSaved ? Color.pink : Color.primary)
                            .frame(width: GameFeedCardSocialActionLayout.minimumHitSize,
                                   height: GameFeedCardSocialActionLayout.minimumHitSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSaved ? "Remove saved game" : "Save game")
                    .accessibilityIdentifier("grid.game.social.save")

                    ShareLink(item: shareURL) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: GameFeedCardSocialActionLayout.minimumHitSize,
                                   height: GameFeedCardSocialActionLayout.minimumHitSize)
                            .background(HephaestusDesign.elevatedBackground, in: Circle())
                            .contentShape(Rectangle())
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        Task { await BackendAPI.shared.trackSocialEvent(
                            gameID: game.id, kind: "share"
                        ) }
                    })
                    .accessibilityLabel("Share \(game.title)")
                    .accessibilityIdentifier("grid.game.social.share")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            ArcadePulsePlayCTA(action: onPlay)
            // Warming happens inside Discover's Play action, not in a
            // zero-distance touch recognizer that can steal grid scrolling.
            .padding(14)

            // Render classification and intent AFTER real Play/Share/social
            // controls, OUTSIDE the poster/video clipped media stage.
            if let expression = game.playableExpression, expression.source_visibility == "public" {
                playableExpressionSummary(expression)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
            }
        }
        .background(HephaestusDesign.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HephaestusDesign.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: HephaestusDesign.cardRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 5)
        .onAppear {
            onImpression()
            if shouldAutoplayPreview && !reduceMotion {
                FeedPreviewPlayback.shared.schedule(gameID: game.id, urlString: game.previewClipURL, reduceMotion: reduceMotion)
            }
        }
        .onDisappear {
            FeedPreviewPlayback.shared.stop(gameID: game.id)
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            if shouldReduceMotion || !shouldAutoplayPreview {
                FeedPreviewPlayback.shared.stop(gameID: game.id)
            } else {
                FeedPreviewPlayback.shared.schedule(gameID: game.id, urlString: game.previewClipURL, reduceMotion: reduceMotion)
            }
        }
        .onChange(of: shouldAutoplayPreview) { _, shouldPlay in
            if shouldPlay && !reduceMotion && scenePhase == .active {
                FeedPreviewPlayback.shared.schedule(gameID: game.id, urlString: game.previewClipURL, reduceMotion: reduceMotion)
            } else {
                FeedPreviewPlayback.shared.stop(gameID: game.id)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && shouldAutoplayPreview && !reduceMotion {
                FeedPreviewPlayback.shared.schedule(gameID: game.id, urlString: game.previewClipURL, reduceMotion: reduceMotion)
            } else if phase != .active {
                FeedPreviewPlayback.shared.stop(gameID: game.id)
            }
        }
    }
}
