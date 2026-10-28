import SwiftUI

/// A game-first social card. Until the API returns real preview assets and creator
/// metadata, the cover is a branded visual rather than fabricated artwork.
private struct GameFeedCardSkeleton: View {
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

private struct GameFeedCard: View {
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
    var shouldAutoplayPreview: Bool = true

    private var shareURL: URL {
        var components = URLComponents(url: BackendConfig.baseURL.appendingPathComponent("player"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "game", value: game.id)]
        return components.url ?? BackendConfig.baseURL
    }

    private var palette: [Color] {
        let palettes: [[Color]] = [
            [Color(red: 0.31, green: 0.20, blue: 0.67), Color(red: 0.10, green: 0.55, blue: 0.69)],
            [Color(red: 0.86, green: 0.29, blue: 0.48), Color(red: 0.98, green: 0.57, blue: 0.31)],
            [Color(red: 0.10, green: 0.48, blue: 0.39), Color(red: 0.55, green: 0.69, blue: 0.30)],
            [Color(red: 0.16, green: 0.33, blue: 0.68), Color(red: 0.39, green: 0.63, blue: 0.92)],
            [Color(red: 0.49, green: 0.24, blue: 0.59), Color(red: 0.82, green: 0.40, blue: 0.63)]
        ]
        let seed = game.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palettes[seed % palettes.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
                if let poster = game.previewPosterURL, let url = URL(string: poster) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
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
                    Text("COMMUNITY GAME")
                        .font(.caption2.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.82))
                    Text(game.title)
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    if let caption = game.caption, !caption.isEmpty {
                        Text(caption).font(.subheadline).foregroundStyle(.white.opacity(0.94)).lineLimit(3)
                    }
                }
                .padding(18)
            }
            .frame(height: coverHeight)
            .clipped()

            HStack(spacing: 10) {
                if let creator = game.ownerID, !creator.isEmpty {
                    Button(action: onOpenCreator) {
                        HStack(spacing: 6) {
                            if let avatar = game.creatorAvatarURL, let url = URL(string: avatar) {
                                AsyncImage(url: url) { phase in
                                    if let image = phase.image { image.resizable().scaledToFill() }
                                    else { Image(systemName: "person.crop.circle.fill").resizable().scaledToFit() }
                                }
                                .frame(width: 22, height: 22)
                                .clipShape(Circle())
                                .accessibilityHidden(true)
                            } else {
                                Image(systemName: "person.crop.circle")
                            }
                            Text(game.creatorDisplayName?.isEmpty == false ? game.creatorDisplayName! : creator)
                                .font(.caption.weight(.medium)).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View profile for \(game.creatorDisplayName?.isEmpty == false ? game.creatorDisplayName! : creator)")
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

            Button(action: onPlay) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text("Play now")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.bold))
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(
                    LinearGradient(colors: palette, startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            // A simultaneous zero-distance drag starts warming on finger-down
            // without stealing the Button tap or changing its accessibility.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0).onChanged { _ in
                    PlayerWebViewPool.prewarm(gameID: game.id)
                }
            )
            .accessibilityIdentifier("game.play")
            .accessibilityHint("Opens this game in the player")
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
