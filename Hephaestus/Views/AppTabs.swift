import PhotosUI
import SwiftUI
import UIKit

// MARK: - Shared pieces

/// Recently played games, persisted locally.
struct RecentGame: Codable, Identifiable {
    var id: String { gameID }
    var gameID: String
    var title: String
}

enum RecentGames {
    private static let key = "hephaestus.recentGames"

    static func record(gameID: String, title: String) {
        var list = load()
        list.removeAll { $0.gameID == gameID }
        list.insert(RecentGame(gameID: gameID, title: title), at: 0)
        list = Array(list.prefix(20))
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> [RecentGame] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([RecentGame].self, from: data)
        else { return [] }
        return list
    }

    static func remove(gameID: String) {
        persist(load().filter { $0.gameID != gameID })
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func persist(_ games: [RecentGame]) {
        guard let data = try? JSONEncoder().encode(games) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - Discover

/// Backend-backed social feeds use the verified bearer session when present.
/// UI subject decoding is only for self-action affordances; the backend authorizes every request.
struct DiscoverView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedFeed: SocialFeedScope = .forYou
    @State private var games: [FeedGame] = []
    @State private var playerRequest: PixiPlayerRequest?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var savedGameIDs = Set<String>()
    @State private var followedCreatorIDs = Set<String>()
    @State private var mutedTopics = Set<String>()
    @State private var isFeedPreferencesPresented = false
    @State private var likedGameIDs = Set<String>()
    @State private var loadGeneration = 0
    @State private var nextCursor: String?
    @State private var isLoadingMore = false
    @State private var commentsGame: FeedGame?
    @State private var reportingGame: FeedGame?
    @State private var profileRequest: CreatorProfileRequest?
    @State private var isCreatorDiscoveryPresented = false

    private var visibleGames: [FeedGame] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return games }
        return games.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var availableTopics: [String] {
        Array(Set(games.flatMap { $0.topics ?? [] }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty } + Array(mutedTopics))).sorted()
    }

    private var feedGridColumns: [GridItem] {
        if horizontalSizeClass == .regular {
            return [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
        }
        return [GridItem(.flexible())]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Picker("Feed", selection: $selectedFeed) {
                        ForEach(SocialFeedScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Social feed")
                    .onChange(of: selectedFeed) { _, _ in Task { await load() } }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("PLAYABLE STORIES", systemImage: "sparkles")
                            .font(.caption.weight(.bold))
                            .tracking(1.2)
                            .foregroundStyle(.purple)
                        Text("A little world, made by someone.")
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Discover tiny games, play a round, and save the ones you want to revisit.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)

                    if isLoading && games.isEmpty {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Finding something fun…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 64)
                    } else if let errorMessage, games.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("Couldn't load the feed")
                                .font(.headline)
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Try again") { Task { await load() } }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 44)
                    } else if visibleGames.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("No games found")
                                .font(.headline)
                            Text("Try a different title.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 44)
                    } else {
                        LazyVGrid(columns: feedGridColumns, alignment: .center, spacing: 18) {
                            ForEach(visibleGames) { game in
                                GameFeedCard(
                                    game: game,
                                    isSaved: savedGameIDs.contains(game.id),
                                    isLiked: likedGameIDs.contains(game.id),
                                    isFollowingCreator: game.ownerID.map { followedCreatorIDs.contains($0) } ?? false,
                                    canFollowCreator: game.ownerID != nil && game.ownerID != BackendConfig.currentUserID,
                                    onPlay: { play(game) },
                                    onToggleSaved: { toggleSaved(game) },
                                    onToggleLike: { toggleLike(game) },
                                    onToggleFollow: { if let id = game.ownerID { Task { await toggleFollow(id) } } },
                                    onOpenComments: { commentsGame = game },
                                    onOpenCreator: { if let id = game.ownerID { profileRequest = CreatorProfileRequest(id: id) } },
                                    onReport: { reportingGame = game },
                                    onBlockCreator: { if let id = game.ownerID { Task { await blockCreator(id) } } },
                                    onNotInterested: { Task { await markNotInterested(game) } },
                                    onImpression: { Task { await BackendAPI.shared.trackSocialEvent(gameID: game.id, kind: "impression") } }
                                )
                            }
                        }
                        .frame(maxWidth: 1120)
                        if nextCursor != nil && searchText.isEmpty {
                            Button {
                                Task { await loadMore() }
                            } label: {
                                if isLoadingMore { ProgressView() }
                                else { Text("Load more games") }
                            }
                            .frame(maxWidth: .infinity)
                            .buttonStyle(.bordered)
                            .disabled(isLoadingMore || isLoading)
                        }
                    }

                    if let errorMessage, !games.isEmpty {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Find a game")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isFeedPreferencesPresented = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Tune feed recommendations")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isCreatorDiscoveryPresented = true
                    } label: {
                        Image(systemName: "person.2")
                    }
                    .accessibilityLabel("Discover creators")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh games")
                    .disabled(isLoading)
                }
            }
            .refreshable { await load() }
            .task {
                savedGameIDs = Set(UserDefaults.standard.stringArray(forKey: "hephaestus.savedGames") ?? [])
                await load()
            }
            .fullScreenCover(item: $playerRequest) { request in
                PixiPlayerSheet(gameID: request.gameID, title: request.title)
            }
            .sheet(item: $commentsGame) { game in
                CommentsSheet(game: game)
            }
            .sheet(item: $reportingGame) { game in
                ReportGameSheet(game: game)
            }
            .sheet(item: $profileRequest) { request in
                CreatorProfileSheet(creatorID: request.id)
            }
            .sheet(isPresented: $isCreatorDiscoveryPresented) {
                CreatorDiscoverySheet()
            }
            .sheet(isPresented: $isFeedPreferencesPresented) {
                FeedPreferencesSheet(
                    availableTopics: availableTopics,
                    selectedTopics: mutedTopics,
                    onSave: { topics in saveMutedTopics(topics) },
                    onReset: { resetFeedPreferences() }
                )
            }
        }
    }

    private func play(_ game: FeedGame) {
        RecentGames.record(gameID: game.id, title: game.title)
        playerRequest = PixiPlayerRequest(gameID: game.id, title: game.title)
    }

    private func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore else { return }
        let requestedScope = selectedFeed
        let requestedGeneration = loadGeneration
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await BackendAPI.shared.fetchFeed(scope: requestedScope, cursor: cursor)
            guard requestedScope == selectedFeed, requestedGeneration == loadGeneration else { return }
            var seen = Set(games.map(\.id))
            games.append(contentsOf: page.games.filter { seen.insert($0.id).inserted })
            nextCursor = page.next_cursor.flatMap { $0.isEmpty ? nil : $0 }
        } catch {
            if requestedGeneration == loadGeneration {
                errorMessage = "Couldn't load more games: \(error.localizedDescription)"
            }
        }
    }

    private func toggleSaved(_ game: FeedGame) {
        let shouldSave = !savedGameIDs.contains(game.id)
        Task {
            do {
                try await BackendAPI.shared.setSaved(game.id, saved: shouldSave)
                if shouldSave { savedGameIDs.insert(game.id) } else { savedGameIDs.remove(game.id) }
                UserDefaults.standard.set(savedGameIDs.sorted(), forKey: "hephaestus.savedGames")
                if shouldSave { await BackendAPI.shared.trackSocialEvent(gameID: game.id, kind: "save") }
            } catch { errorMessage = "Couldn't update saved games: \(error.localizedDescription)" }
        }
    }

    private func toggleLike(_ game: FeedGame) {
        let shouldLike = !likedGameIDs.contains(game.id)
        Task {
            do {
                try await BackendAPI.shared.setReaction(game.id, reaction: shouldLike ? "like" : nil)
                if shouldLike { likedGameIDs.insert(game.id) } else { likedGameIDs.remove(game.id) }
            } catch { errorMessage = "Couldn't update reaction: \(error.localizedDescription)" }
        }
    }

    private func toggleFollow(_ creatorID: String) async {
        let shouldFollow = !followedCreatorIDs.contains(creatorID)
        do {
            try await BackendAPI.shared.setFollowing(creatorID, following: shouldFollow)
            if shouldFollow { followedCreatorIDs.insert(creatorID) } else { followedCreatorIDs.remove(creatorID) }
            if let gameID = games.first(where: { $0.ownerID == creatorID })?.id {
                await BackendAPI.shared.trackSocialEvent(gameID: gameID, kind: "follow")
            }
            await load()
        } catch { errorMessage = "Couldn't update follow: \(error.localizedDescription)" }
    }

    private func blockCreator(_ creatorID: String) async {
        do {
            try await BackendAPI.shared.blockCreator(creatorID, blocked: true)
            games.removeAll { $0.ownerID == creatorID }
        } catch { errorMessage = "Couldn't block creator: \(error.localizedDescription)" }
    }

    private func markNotInterested(_ game: FeedGame) async {
        do {
            try await BackendAPI.shared.markNotInterested(gameID: game.id)
            games.removeAll { $0.id == game.id }
        } catch { errorMessage = "Couldn't save feedback: \(error.localizedDescription)" }
    }

    private func saveMutedTopics(_ topics: [String]) {
        Task {
            do {
                try await BackendAPI.shared.setMutedTopics(topics)
                mutedTopics = Set(topics.map { $0.lowercased() })
                await load()
            } catch {
                errorMessage = "Couldn't update feed preferences: \(error.localizedDescription)"
            }
        }
    }

    private func resetFeedPreferences() {
        Task {
            do {
                try await BackendAPI.shared.resetFeedPreferences()
                mutedTopics.removeAll()
                await load()
            } catch {
                errorMessage = "Couldn't reset feed preferences: \(error.localizedDescription)"
            }
        }
    }

    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        errorMessage = nil
        do {
            let loadedGames = try await BackendAPI.shared.fetchFeed(scope: selectedFeed)
            guard generation == loadGeneration else { return }
            games = loadedGames.games
            nextCursor = loadedGames.next_cursor.flatMap { $0.isEmpty ? nil : $0 }
            if let ids = try? await BackendAPI.shared.fetchFollowingCreatorIDs(), generation == loadGeneration {
                followedCreatorIDs = ids
            }
            if let ids = try? await BackendAPI.shared.fetchSavedGameIDs(), generation == loadGeneration {
                savedGameIDs = ids
                UserDefaults.standard.set(ids.sorted(), forKey: "hephaestus.savedGames")
            }
            if let preferences = try? await BackendAPI.shared.fetchFeedPreferences(), generation == loadGeneration {
                mutedTopics = Set(preferences.muted_topics.map { $0.lowercased() })
            }
        } catch {
            if generation == loadGeneration { errorMessage = error.localizedDescription }
        }
    }
}

/// A deliberate empty state rather than showing the public catalog as a user's
/// Following or Friends feed before the social graph is connected.
private struct SocialFeedUnavailableView: View {
    let scope: SocialFeedScope
    let onExplore: () -> Void

    private var title: String {
        switch scope {
        case .forYou: "Discover games"
        case .following: "Your Following feed starts here"
        case .friends: "Your Friends feed starts here"
        }
    }

    private var message: String {
        switch scope {
        case .forYou:
            "Discover games from the wider community."
        case .following:
            "Posts from creators you follow will appear here when account and follow services are connected."
        case .friends:
            "Games from mutual follows and friend recommendations will appear here when the social graph is connected."
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: scope == .friends ? "person.2" : "person.crop.circle.badge.clock")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Explore For You", action: onExplore)
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
    }
}

/// A game-first social card. Until the API returns real preview assets and creator
/// metadata, the cover is a branded visual rather than fabricated artwork.
private struct GameFeedCard: View {
    @ScaledMetric(relativeTo: .largeTitle) private var coverHeight: CGFloat = 220
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
                        Label(creator, systemImage: "person.crop.circle")
                            .font(.caption.weight(.medium)).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View profile for \(creator)")
                } else {
                    Label("Mini game", systemImage: "sparkles").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if canFollowCreator {
                    Button(action: onToggleFollow) {
                        Label(isFollowingCreator ? "Following" : "Follow", systemImage: isFollowingCreator ? "person.fill.checkmark" : "person.badge.plus")
                            .font(.caption.weight(.semibold)).frame(minHeight: 44)
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
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Circle())
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
            .accessibilityIdentifier("game.play")
            .accessibilityHint("Opens this game in the player")
            .padding(14)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 5)
        .onAppear(perform: onImpression)
    }
}

private struct CreatorProfileRequest: Identifiable {
    let id: String
}

private struct CreatorDiscoverySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var topicText = ""
    @State private var creators: [CreatorDiscoveryEntry] = []
    @State private var nextCursor: String?
    @State private var profileRequest: CreatorProfileRequest?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadGeneration = 0
    @State private var appliedSearchText = ""
    @State private var appliedTopicText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Filter by topic (optional)", text: $topicText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { Task { await load(reset: true) } }
                        Button("Apply") { Task { await load(reset: true) } }
                            .disabled(isLoading)
                    }
                } header: {
                    Text("Topic")
                } footer: {
                    Text("Search creators by ID or public game title. Topic filtering is an exact match.")
                }

                if isLoading && creators.isEmpty {
                    HStack { Spacer(); ProgressView("Finding creators…"); Spacer() }
                } else if creators.isEmpty && errorMessage == nil {
                    ContentUnavailableView(
                        "No creators found",
                        systemImage: "person.2",
                        description: Text("Try another search or topic.")
                    )
                } else {
                    Section("Creators") {
                        ForEach(creators) { creator in
                            Button {
                                profileRequest = CreatorProfileRequest(id: creator.creator_id)
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(creator.creator_id)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text("\(creator.post_count) games")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if !creator.topics.isEmpty {
                                        Text(creator.topics.prefix(5).map { "#\($0)" }.joined(separator: "  "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("View creator \(creator.creator_id), \(creator.post_count) public games")
                        }
                    }
                    if nextCursor != nil {
                        Section {
                            Button {
                                Task { await load(reset: false) }
                            } label: {
                                HStack {
                                    Spacer()
                                    if isLoadingMore { ProgressView() }
                                    else { Text("Load more creators") }
                                    Spacer()
                                }
                            }
                            .disabled(isLoadingMore || isLoading)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                        Button("Try again") { Task { await load(reset: true) } }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Creators")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search creators or games")
            .onSubmit(of: .search) { Task { await load(reset: true) } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await load(reset: true) }
            .task { await load(reset: true) }
            .sheet(item: $profileRequest) { request in
                CreatorProfileSheet(creatorID: request.id)
            }
        }
    }

    private func load(reset: Bool) async {
        if reset {
            loadGeneration += 1
            appliedSearchText = searchText
            appliedTopicText = topicText
            nextCursor = nil
            isLoading = true
            isLoadingMore = false
        } else {
            guard nextCursor != nil, !isLoadingMore, !isLoading else { return }
            isLoadingMore = true
        }
        let generation = loadGeneration
        defer {
            if generation == loadGeneration {
                if reset { isLoading = false } else { isLoadingMore = false }
            }
        }
        errorMessage = nil
        do {
            let response = try await BackendAPI.shared.fetchCreators(
                query: appliedSearchText,
                topic: appliedTopicText,
                cursor: reset ? nil : nextCursor
            )
            guard generation == loadGeneration else { return }
            if reset {
                creators = response.creators
            } else {
                var seen = Set(creators.map(\.creator_id))
                creators.append(contentsOf: response.creators.filter { seen.insert($0.creator_id).inserted })
            }
            nextCursor = response.next_cursor.flatMap { $0.isEmpty ? nil : $0 }
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = "Couldn't load creators: \(error.localizedDescription)"
        }
    }
}

private struct CreatorProfileSheet: View {
    let creatorID: String
    @Environment(\.dismiss) private var dismiss
    @State private var profile: CreatorProfile?
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading { ProgressView("Loading creator…") }
                else if let profile {
                    List {
                        Section("Creator") {
                            LabeledContent("Creator ID", value: profile.creator_id)
                            LabeledContent("Published games", value: "\(profile.post_count)")
                            LabeledContent("Followers", value: "\(profile.follower_count)")
                            LabeledContent("Following", value: "\(profile.following_count)")
                            Button(profile.is_following ? "Unfollow" : "Follow") {
                                Task { await toggleFollow(profile.is_following) }
                            }
                            .disabled(profile.creator_id == BackendConfig.currentUserID)
                        }
                        Section("Public games") {
                            if profile.posts.isEmpty { Text("No public games yet.").foregroundStyle(.secondary) }
                            ForEach(profile.posts) { game in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(game.title).font(.headline)
                                    if let caption = game.caption, !caption.isEmpty { Text(caption).font(.subheadline).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Couldn't load creator", systemImage: "person.crop.circle.badge.exclamationmark", description: Text(errorMessage ?? "Please try again."))
                }
            }
            .navigationTitle("Creator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do { profile = try await BackendAPI.shared.fetchCreatorProfile(id: creatorID); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func toggleFollow(_ currentlyFollowing: Bool) async {
        do {
            try await BackendAPI.shared.setFollowing(creatorID, following: !currentlyFollowing)
            await load()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct ReportGameSheet: View {
    let game: FeedGame
    @Environment(\.dismiss) private var dismiss
    @State private var selectedReason = "Unsafe or inappropriate content"
    @State private var details = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var submitted = false

    private let reasons = [
        "Unsafe or inappropriate content",
        "Harassment or bullying",
        "Personal information",
        "Broken or misleading game",
        "Other"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Report") {
                    Text(game.title).font(.headline)
                    Picker("Reason", selection: $selectedReason) {
                        ForEach(reasons, id: \.self) { reason in
                            Text(reason).tag(reason)
                        }
                    }
                    TextField("Additional details (optional)", text: $details, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section {
                    Text("Reports are reviewed by moderators. Only include information needed to explain the concern.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
                if submitted {
                    Section {
                        Label("Report submitted", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Report game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Submit") { Task { await submit() } }
                        .disabled(isSubmitting || submitted)
                }
            }
        }
    }

    private func submit() async {
        guard !isSubmitting, !submitted else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = trimmedDetails.isEmpty ? selectedReason : "\(selectedReason): \(trimmedDetails)"
        var boundedReason = ""
        for character in reason {
            let next = String(character)
            guard boundedReason.utf8.count + next.utf8.count <= 500 else { break }
            boundedReason.append(character)
        }
        do {
            try await BackendAPI.shared.reportGame(gameID: game.id, reason: boundedReason)
            submitted = true
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't submit report: \(error.localizedDescription)"
        }
    }
}

private struct CommentsSheet: View {
    let game: FeedGame
    @Environment(\.dismiss) private var dismiss
    @State private var comments: [SocialComment] = []
    @State private var draft = ""
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var pendingIdempotencyKey: String?
    @State private var pendingBody: String?
    @State private var deletingCommentIDs = Set<String>()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isLoading { ProgressView().padding() }
                List(comments) { comment in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(comment.user_id).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(comment.body)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if comment.user_id == BackendConfig.currentUserID {
                            Button(role: .destructive) {
                                Task { await delete(comment) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .disabled(deletingCommentIDs.contains(comment.id))
                        }
                    }
                }
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red).padding(.horizontal) }
                HStack {
                    TextField("Add a comment…", text: $draft, axis: .vertical).textFieldStyle(.roundedBorder)
                    Button("Send") { Task { await submit() } }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                }
                .padding()
            }
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do { comments = try await BackendAPI.shared.fetchComments(gameID: game.id); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func submit() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        if pendingBody != body {
            pendingIdempotencyKey = UUID().uuidString
            pendingBody = body
        }
        let key = pendingIdempotencyKey ?? UUID().uuidString
        pendingIdempotencyKey = key
        do {
            let comment = try await BackendAPI.shared.addComment(gameID: game.id, body: body, idempotencyKey: key)
            if !comments.contains(where: { $0.id == comment.id }) {
                comments.append(comment)
            }
            draft = ""
            pendingIdempotencyKey = nil
            pendingBody = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func delete(_ comment: SocialComment) async {
        guard comment.user_id == BackendConfig.userID,
              !deletingCommentIDs.contains(comment.id) else { return }
        deletingCommentIDs.insert(comment.id)
        defer { deletingCommentIDs.remove(comment.id) }
        do {
            try await BackendAPI.shared.deleteComment(gameID: game.id, commentID: comment.id)
            comments.removeAll { $0.id == comment.id }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't delete comment: \(error.localizedDescription)"
        }
    }
}

// MARK: - Create

/// Photograph a drawing → analyze → generate → confirm → play.
struct CreateView: View {
    enum Phase {
        case pick
        case analyzing
        case review(result: IngestResult, image: UIImage)
        case generating(JobStatus)
        case confirming(JobStatus)
        case done(gameID: String)
        case failed(String)
    }

    @State private var phase: Phase = .pick
    @State private var pickerItem: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var previewImage: UIImage?
    @State private var keywordsText = ""
    @State private var intentText = ""
    @State private var publishCaption = ""
    @State private var publishTopics = ""
    @State private var publishMessage: String?
    @State private var isPublishing = false
    @State private var playerRequest: PixiPlayerRequest?

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .pick:
                    pickView
                case .analyzing:
                    ProgressView("Analyzing drawing…")
                case .review(let result, let image):
                    reviewView(result: result, image: image)
                case .generating(let job):
                    ProgressView("Generating game… (\(job.status))")
                        .task(id: job.job_id) { await pollJob(job.job_id) }
                case .confirming(let job):
                    confirmingView(job: job)
                case .done(let gameID):
                    doneView(gameID: gameID)
                case .failed(let message):
                    VStack(spacing: 16) {
                        Text("Something went wrong").font(.headline)
                        Text(message).foregroundStyle(.secondary)
                        Button("Start over") { reset() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }
            }
            .navigationTitle("Create")
            .fullScreenCover(item: $playerRequest) { req in
                PixiPlayerSheet(gameID: req.gameID, title: req.title)
            }
        }
    }

    private var pickView: some View {
        VStack(spacing: 20) {
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 220)
                    .overlay {
                        VStack {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                            Text("No drawing selected")
                                .foregroundStyle(.secondary)
                        }
                    }
            }

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("Choose a drawing", systemImage: "photo.badge.plus")
            }
            .buttonStyle(.bordered)
            .onChange(of: pickerItem) { _, newItem in
                Task {
                    guard let newItem else { return }
                    if let data = try? await newItem.loadTransferable(type: Data.self) {
                        imageData = data
                        previewImage = UIImage(data: data)
                    }
                }
            }

            TextField("Keywords (comma separated)", text: $keywordsText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            Button("Analyze drawing") {
                Task { await analyze() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(imageData == nil)

            Spacer()
        }
        .padding()
    }

    private func reviewView(result: IngestResult, image: UIImage) -> some View {
        List {
            Section("Drawing") {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Section("Elements found") {
                ForEach(result.elements, id: \.name) { el in
                    HStack {
                        Text(el.name)
                        Spacer()
                        Text(el.role).foregroundStyle(.secondary)
                    }
                }
            }
            Section("What should the game be about?") {
                TextField("Intent", text: $intentText)
            }
            Section {
                Button("Generate game") {
                    Task { await generate(result: result) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func confirmingView(job: JobStatus) -> some View {
        List {
            Section("Design doc") {
                if let doc = job.design_doc {
                    Text(doc.title).font(.headline)
                    if let plot = doc.plot { Text(plot) }
                    if let mechanics = doc.mechanics {
                        Text("How it plays: \(mechanics)")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("The design is ready to review.")
                }
            }
            Section {
                Button("Looks good — build it") {
                    Task { await confirm(job: job) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func doneView(gameID: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Your game is ready!").font(.title2)
            Button("Play now") {
                playerRequest = PixiPlayerRequest(gameID: gameID, title: "Your game")
            }
            .buttonStyle(.borderedProminent)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Share it with the community").font(.headline)
                TextField("Add a caption", text: $publishCaption, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                TextField("Topics, separated by commas", text: $publishTopics)
                    .textFieldStyle(.roundedBorder)
                Text("Published games enter moderation before appearing in public feeds.")
                    .font(.caption).foregroundStyle(.secondary)
                if let publishMessage {
                    Text(publishMessage).font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    Task { await publish(gameID: gameID) }
                } label: {
                    if isPublishing { ProgressView() }
                    else { Label("Publish game", systemImage: "paperplane.fill") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPublishing)
            }
            .frame(maxWidth: 420)
            Button("Make another") { reset() }
        }
        .padding()
    }

    private func publish(gameID: String) async {
        isPublishing = true
        defer { isPublishing = false }
        let topics = publishTopics.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        do {
            _ = try await BackendAPI.shared.publishPost(gameID: gameID, caption: publishCaption, topics: topics)
            publishMessage = "Submitted for moderation. The post appears in feeds after approval."
        } catch {
            publishMessage = "Couldn't publish: \(error.localizedDescription)"
        }
    }

    private func reset() {
        phase = .pick
        pickerItem = nil
        imageData = nil
        previewImage = nil
        keywordsText = ""
        intentText = ""
        publishCaption = ""
        publishTopics = ""
        publishMessage = nil
    }

    private func analyze() async {
        guard let imageData else { return }
        phase = .analyzing
        let keywords = keywordsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            let result = try await BackendAPI.shared.ingest(imageData: imageData, keywords: keywords)
            intentText = result.guessed_intent ?? ""
            if let image = UIImage(data: imageData) {
                phase = .review(result: result, image: image)
            } else {
                phase = .failed("Couldn't read the selected image.")
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func generate(result: IngestResult) async {
        do {
            let resp = try await BackendAPI.shared.createGame(
                ingestID: result.ingest_id,
                elements: result.elements,
                intent: intentText
            )
            phase = .generating(resp.job)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func pollJob(_ jobID: String) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            do {
                let job = try await BackendAPI.shared.fetchJob(id: jobID)
                switch job.status {
                case "awaiting_confirm":
                    phase = .confirming(job)
                    return
                case "done":
                    phase = .done(gameID: job.game_id)
                    return
                case "failed":
                    phase = .failed(job.error ?? "Generation failed.")
                    return
                default:
                    phase = .generating(job)
                }
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
        }
    }

    private func confirm(job: JobStatus) async {
        do {
            try await BackendAPI.shared.confirmGame(id: job.game_id)
            phase = .generating(job)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Library

/// Recently played games.
struct LibraryView: View {
    @State private var recent: [RecentGame] = []
    @State private var saved: [FeedGame] = []
    @State private var errorMessage: String?
    @State private var playerRequest: PixiPlayerRequest?
    @State private var showClearRecentConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    if saved.isEmpty {
                        ContentUnavailableView(
                            "No saved games yet",
                            systemImage: "bookmark",
                            description: Text("Save a game from Discover and it will be ready to play here.")
                        )
                    }
                    ForEach(saved) { game in
                        Button {
                            playerRequest = PixiPlayerRequest(gameID: game.id, title: game.title)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "gamecontroller.fill")
                                    .font(.title3)
                                    .foregroundStyle(.white)
                                    .frame(width: 48, height: 48)
                                    .background(
                                        LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(game.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                    if let caption = game.caption, !caption.isEmpty {
                                        Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.tint)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the game player")
                        .contextMenu {
                            Button("Remove from saved", systemImage: "bookmark.slash", role: .destructive) {
                                Task { await removeSaved(game) }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Saved games")
                        Spacer()
                        Text("\(saved.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }

                Section {
                    if recent.isEmpty {
                        ContentUnavailableView(
                            "No recent games",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("Games you play will appear here so you can jump back in.")
                        )
                    }
                    ForEach(recent) { game in
                        Button {
                            playerRequest = PixiPlayerRequest(gameID: game.gameID, title: game.title)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.title3)
                                    .foregroundStyle(.white)
                                    .frame(width: 48, height: 48)
                                    .background(
                                        LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(game.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                    Text("Recently played").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.tint)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the game player")
                        .contextMenu {
                            Button("Remove from recent", systemImage: "clock.badge.xmark", role: .destructive) {
                                RecentGames.remove(gameID: game.gameID)
                                recent.removeAll { $0.gameID == game.gameID }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Recently played")
                        Spacer()
                        Text("\(recent.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear recent", systemImage: "trash") {
                        showClearRecentConfirmation = true
                    }
                    .disabled(recent.isEmpty)
                    .accessibilityHint("Removes recent games from this device")
                }
            }
            .confirmationDialog("Clear recently played games?", isPresented: $showClearRecentConfirmation, titleVisibility: .visible) {
                Button("Clear Recent Games", role: .destructive) {
                    RecentGames.clear()
                    recent.removeAll()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This only clears your local recent-games list. Saved games are not affected.")
            }
            .refreshable { await load() }
            .task { await load() }
            .fullScreenCover(item: $playerRequest) { request in
                PixiPlayerSheet(gameID: request.gameID, title: request.title)
            }
        }
    }

    private func load() async {
        recent = RecentGames.load()
        do {
            saved = try await BackendAPI.shared.fetchSavedGames()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't load saved games: \(error.localizedDescription)"
        }
    }

    private func removeSaved(_ game: FeedGame) async {
        do {
            try await BackendAPI.shared.setSaved(game.id, saved: false)
            saved.removeAll { $0.id == game.id }
        } catch {
            errorMessage = "Couldn't remove saved game: \(error.localizedDescription)"
        }
    }
}

// MARK: - Profile

struct ProfileView: View {
    @State private var backendOK = false
    @State private var checked = false
    @State private var logEntries = DevLog.shared.count
    @AppStorage(PlayerQuality.defaultsKey) private var qualityRaw = PlayerQuality.auto.rawValue
    @State private var isModerationAppealPresented = false
    @State private var tokenDraft = BackendConfig.loadSessionToken() ?? ""
    @State private var sessionMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    HStack {
                        Text("Session")
                        Spacer()
                        Label(BackendConfig.currentUserID.isEmpty ? "Not connected" : "Connected",
                              systemImage: BackendConfig.currentUserID.isEmpty ? "person.crop.circle.badge.xmark" : "checkmark.shield.fill")
                            .font(.subheadline)
                            .foregroundStyle(BackendConfig.currentUserID.isEmpty ? Color.secondary : Color.green)
                    }
                    SecureField("Short-lived bearer session token", text: $tokenDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Bearer session token")
                    HStack {
                        Button("Save session") {
                            let token = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !token.isEmpty else {
                                sessionMessage = "Enter a session token first."
                                return
                            }
                            guard BackendConfig.saveSessionToken(token) else {
                                sessionMessage = "Could not save the session securely to Keychain."
                                return
                            }
                            tokenDraft = token
                            sessionMessage = "Session saved securely. New API requests will use bearer authentication."
                            DevLog.info(.api, "bearer session token saved to Keychain")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Sign out", role: .destructive) {
                            BackendConfig.clearSessionToken()
                            tokenDraft = ""
                            sessionMessage = "Session cleared from this device."
                            DevLog.info(.api, "bearer session token cleared")
                        }
                        .buttonStyle(.bordered)
                    }
                    if let sessionMessage {
                        Text(sessionMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("session-status")
                    }
                    Text("Until Sign in with Apple is connected, paste a short-lived token from the trusted sign-in provider. Tokens are kept in Keychain; the app does not trust X-User-ID for production identity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Safety & moderation") {
                    Button {
                        isModerationAppealPresented = true
                    } label: {
                        Label("Appeal a moderation decision", systemImage: "exclamationmark.bubble")
                    }
                    Text("Use this if one of your games was rejected or quarantined. Appeals are reviewed by a moderator and do not automatically restore publication.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Backend") {
                    HStack {
                        Text("Status")
                        Spacer()
                        if checked {
                            Text(backendOK ? "Connected" : "Unreachable")
                                .foregroundStyle(backendOK ? .green : .red)
                        } else {
                            ProgressView()
                        }
                    }
                    HStack {
                        Text("Server")
                        Spacer()
                        Text(BackendConfig.baseURL.host ?? "")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Diagnostics") {
                    HStack {
                        Text("Session log")
                        Spacer()
                        Text("\(logEntries) entries")
                            .foregroundStyle(.secondary)
                    }
                    Button("Copy session log") {
                        UIPasteboard.general.string = DevLog.shared.exportText()
                        DevLog.info(.app, "session log copied (\(DevLog.shared.count) entries)")
                        logEntries = DevLog.shared.count
                    }
                    ShareLink(item: DevLog.shared.exportText()) {
                        Text("Share session log")
                    }
                    Button("Clear log", role: .destructive) {
                        DevLog.shared.clear()
                        logEntries = DevLog.shared.count
                    }
                }
                Section("Player health") {
                    HStack {
                        Text("Quality")
                        Spacer()
                        Text("\(qualityRaw) → \(PlayerQuality.effective(preference: PlayerQuality(rawValue: qualityRaw) ?? .auto))")
                            .foregroundStyle(.secondary)
                    }
                    Text("Server-wide incident aggregates are restricted to operators and are not fetched by the app. If you encounter a player issue, copy or share the session log above only after removing private information.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $isModerationAppealPresented) {
                ModerationAppealSheet()
            }

            .navigationTitle("Profile")
            .onAppear { logEntries = DevLog.shared.count }
            .task {
                await BackendAPI.shared.checkHealth()
                backendOK = BackendAPI.shared.isHealthy
                checked = true
            }
        }
    }

}


private struct ModerationAppealSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var gameID = ""
    @State private var reason = ""
    @State private var contact: BackendAPI.ModerationContactResponse?
    @State private var isSubmitting = false
    @State private var message: String?
    @State private var didSubmit = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Game") {
                    TextField("Game ID", text: $gameID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Why should this decision be reviewed?") {
                    TextEditor(text: $reason)
                        .frame(minHeight: 120)
                    Text("\(reason.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count)/1000 Unicode characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Text("Only the creator can appeal a rejected or quarantined game. Submitting an appeal adds it to the moderator queue; it does not republish the game.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let contact {
                    Section("Moderation contact") {
                        if !contact.contact_email.isEmpty {
                            LabeledContent("Email", value: contact.contact_email)
                                .textSelection(.enabled)
                        }
                        if !contact.contact_url.isEmpty, let url = URL(string: contact.contact_url) {
                            Link("Open moderation contact", destination: url)
                        }
                        if !contact.external_contact_configured {
                            Text("No external contact channel is configured. You can still submit an in-app appeal.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let message {
                    Section {
                        Text(message)
                            .foregroundStyle(didSubmit ? .green : .secondary)
                    }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Label("Submit appeal", systemImage: "paperplane")
                        }
                    }
                    .disabled(isSubmitting || gameID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              reason.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count > 1000 || didSubmit)
                }
            }
            .navigationTitle("Moderation appeal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadContact() }
        }
    }

    private func loadContact() async {
        do { contact = try await BackendAPI.shared.fetchModerationContact() }
        catch { /* Contact configuration is optional; appeal submission remains available. */ }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let result = try await BackendAPI.shared.submitModerationAppeal(
                gameID: gameID.trimmingCharacters(in: .whitespacesAndNewlines),
                reason: reason
            )
            didSubmit = true
            message = "Appeal submitted (\(result.appeal_id)). Status: \(result.status)."
        } catch {
            message = "Couldn't submit appeal: \(error.localizedDescription)"
        }
    }
}



private struct FeedPreferencesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let availableTopics: [String]
    let selectedTopics: Set<String>
    let onSave: ([String]) -> Void
    let onReset: () -> Void
    @State private var selected = Set<String>()

    var body: some View {
        NavigationStack {
            List {
                Section("Hide topics") {
                    if availableTopics.isEmpty {
                        Text("Topics will appear here as games with topics enter your feed.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(availableTopics, id: \.self) { topic in
                        Toggle(topic, isOn: Binding(
                            get: { selected.contains(topic) },
                            set: { isMuted in
                                if isMuted { selected.insert(topic) }
                                else { selected.remove(topic) }
                            }
                        ))
                    }
                }
                Section {
                    Button("Save preferences") {
                        onSave(selected.sorted())
                        dismiss()
                    }
                    Button("Reset recommendations", role: .destructive) {
                        selected.removeAll()
                        onReset()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Tune your feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { selected = selectedTopics }
        }
    }
}
