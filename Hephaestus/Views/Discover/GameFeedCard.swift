import SwiftUI

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

    private func expressionTag(_ title: String, count: Int) -> some View {
        Text("\(title) · \(count)")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.white.opacity(0.16), in: Capsule())
    }

    private func expressionAccessibilityLabel(_ expression: FeedPlayableExpression) -> String {
        let preserved = expression.preserved?.count ?? 0
        let invented = expression.invented?.count ?? 0
        let uncertain = expression.uncertain?.count ?? 0
        return [
            "Playable expression",
            expression.intent,
            expression.chosen_interpretation.map { "Interpretation: \($0)" },
            "Source shared",
            "Preserved claims: \(preserved)",
            "Invented claims: \(invented)",
            "Uncertain claims: \(uncertain)"
        ].compactMap { $0 }.joined(separator: ". ")
    }

    private func playableExpressionSummary(_ expression: FeedPlayableExpression) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("PLAYABLE EXPRESSION", systemImage: "sparkles")
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                Text("SOURCE SHARED")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.18), in: Capsule())
            }
            if let intent = expression.intent, !intent.isEmpty {
                Text(intent).font(.subheadline.weight(.medium)).lineLimit(2)
            }
            if let interpretation = expression.chosen_interpretation, !interpretation.isEmpty {
                Text("Interpretation · " + interpretation)
                    .font(.caption).foregroundStyle(.white.opacity(0.9)).lineLimit(2)
            }
            HStack(spacing: 6) {
                expressionTag("Preserved", count: expression.preserved?.count ?? 0)
                expressionTag("Invented", count: expression.invented?.count ?? 0)
                expressionTag("Uncertain", count: expression.uncertain?.count ?? 0)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(expressionAccessibilityLabel(expression))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
                if let poster = game.previewPosterURL, let url = URL(string: poster) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFit() }
                        else { LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .accessibilityHidden(true)
                }
                if previewPlayback.activeGameID == game.id && !reduceMotion {
                    FeedPreviewSurface(player: previewPlayback.player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                        .accessibilityHidden(true)
                }
                if (game.previewPosterURL == nil || game.previewPosterURL?.isEmpty == true)
                    && previewPlayback.activeGameID != game.id {
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
                    if let topics = game.topics, !topics.isEmpty {
                        Text(topics.prefix(3).map { "#\($0)" }.joined(separator: "  "))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                            .accessibilityLabel("Topics: " + topics.prefix(3).joined(separator: ", "))
                    }
                    if let expression = game.playableExpression, expression.source_visibility == "public" {
                        playableExpressionSummary(expression)
                    }

                }
                .padding(18)
            }
            .frame(height: coverHeight)
            .clipped()

            HStack(spacing: 10) {
                if let creator = game.ownerID, !creator.isEmpty {
                    ArcadePulseCreatorIdentity(
                        name: game.creatorDisplayName?.isEmpty == false
                            ? game.creatorDisplayName! : creator,
                        avatarURL: game.creatorAvatarURL,
                        foreground: .primary,
                        action: onOpenCreator
                    )
                } else {
                    Label("Mini game", systemImage: "sparkles").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if canFollowCreator {
                    Button(action: onToggleFollow) {
                        Label(isFollowingCreator ? "Following" : "Follow", systemImage: isFollowingCreator ? "person.fill.checkmark" : "person.badge.plus")
                            .font(.caption.weight(.semibold)).frame(minHeight: HephaestusDesign.minimumActionHeight)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isFollowingCreator ? "Unfollow creator" : "Follow creator")
                }
                Button(action: onToggleLike) {
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .foregroundStyle(isLiked ? Color.pink : Color.primary)
                        .frame(width: 36, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isLiked ? "Unlike game" : "Like game")
                Button(action: onOpenComments) {
                    Image(systemName: "bubble.right").frame(width: 36, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View comments")
                Menu {
                    Button("Not interested", systemImage: "hand.thumbsdown", action: onNotInterested)
                    if canFollowCreator {
                        Button("Block creator", systemImage: "person.crop.circle.badge.xmark", role: .destructive, action: onBlockCreator)
                    }
                    Button("Report game", systemImage: "flag", role: .destructive, action: onReport)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 36, height: 44)
                }
                .accessibilityLabel("More game options")
                Button(action: onToggleSaved) {
                    Label(isSaved ? "Saved" : "Save",
                          systemImage: isSaved ? "bookmark.fill" : "bookmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSaved ? Color.pink : Color.primary)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSaved ? "Remove saved game" : "Save game")
                ShareLink(item: shareURL) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(HephaestusDesign.elevatedBackground, in: Circle())
                }
                .simultaneousGesture(TapGesture().onEnded {
                    Task { await BackendAPI.shared.trackSocialEvent(gameID: game.id, kind: "share") }
                })
                .accessibilityLabel("Share \(game.title)")
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            ArcadePulsePlayCTA(action: onPlay)
            // Warming happens inside Discover's Play action, not in a
            // zero-distance touch recognizer that can steal grid scrolling.
            .padding(14)
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
