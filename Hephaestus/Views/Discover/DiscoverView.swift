import AuthenticationServices
import AVFoundation
import Combine
import Network
import PhotosUI
import SwiftUI
import UIKit

// MARK: - Discover

private struct PlayerResultPresentation: Identifiable {
    let game: FeedGame
    let result: VerifiedRunResult
    var id: String { result.runID }
}

/// One owner for in-flight Discover requests. A retry cancels the previous
/// transport, and only the newest generation may update visible game pages.
/// An old request can still complete after cancellation, so both checks matter.
@MainActor
final class FeedRequestCoordinator {
    private(set) var generation = 0
    private var activeRequest: Task<FeedResponse, Error>?

    func begin(_ fetch: @escaping @MainActor () async throws -> FeedResponse)
        -> (generation: Int, request: Task<FeedResponse, Error>) {
        generation += 1
        activeRequest?.cancel()
        let request = Task { try await fetch() }
        activeRequest = request
        return (generation, request)
    }

    func isCurrent(_ requestGeneration: Int) -> Bool {
        requestGeneration == generation
    }

    func finishIfCurrent(_ requestGeneration: Int) {
        guard isCurrent(requestGeneration) else { return }
        activeRequest = nil
    }
}

/// Keep the native search drawer out of compact iPhone landscape's tiny
/// media viewport. The floating 44pt search button opens an actual sheet,
/// while search results return to the standard native searchable grid.
private struct FeedSearchVisibilityModifier: ViewModifier {
    @Binding var text: String
    let hidesNativeSearch: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if hidesNativeSearch {
            content
        } else {
            content.searchable(text: $text, prompt: "Find a game")
        }
    }
}

/// Backend-backed social feeds use the verified bearer session when present.
/// UI subject decoding is only for self-action affordances; the backend authorizes every request.
struct DiscoverView: View {
    // A live-feed outage must not trap the user on an empty swipe stage.
    // The host owns navigation, so this is an actual route to Library,
    // never a substitute game list or a fabricated preview.
    let onOpenLibrary: (() -> Void)?
    init(onOpenLibrary: (() -> Void)? = nil) {
        self.onOpenLibrary = onOpenLibrary
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedFeed: SocialFeedScope = .forYou
    @State private var compactSearchPresented = false
    @State private var compactSearchDraft = ""
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
    @State private var feedRequestCoordinator = FeedRequestCoordinator()
    @State private var nextCursor: String?
    @State private var isLoadingMore = false
    @State private var loadMoreError: String?
    @State private var commentsGame: FeedGame?
    @State private var detailGame: FeedGame?
    @State private var reportingGame: FeedGame?
    @State private var profileRequest: CreatorProfileRequest?
    @State private var isCreatorDiscoveryPresented = false
    @State private var settledForYouGameID: String?
    @State private var resultPresentation: PlayerResultPresentation?

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

    private var showsImmersivePager: Bool {
        ForYouPageLayout.shouldShowImmersivePager(
            searchText: searchText, hasGames: !visibleGames.isEmpty)
    }

    // The iPhone feed is content-first in both orientations. Search and
    // tablet-wide layouts still expose the segmented picker; portrait phone
    // scopes remain available in the labeled, 44pt toolbar menu.
    private var usesCompactFeedScopeMenu: Bool {
        ForYouPageLayout.prefersCompactScopeMenu(
            verticalSizeClass: verticalSizeClass,
            horizontalSizeClass: horizontalSizeClass,
            searchText: searchText)
    }

    /// Compact phone landscape floats critical controls over the media stage.
    /// The app's bottom tab bar still provides Create, Library and Profile.
    private var usesCompactLandscapeOverlay: Bool {
        UIDevice.current.userInterfaceIdiom == .phone &&
        ForYouPageLayout.usesCompactLandscapeOverlay(
            verticalSizeClass: verticalSizeClass,
            horizontalSizeClass: horizontalSizeClass,
            hasImmersivePager: showsImmersivePager)
    }

    private var compactLandscapeOverlay: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(SocialFeedScope.allCases) { scope in
                    Button {
                        selectedFeed = scope
                    } label: {
                        if selectedFeed == scope {
                            Label(scope.title, systemImage: "checkmark")
                        } else {
                            Text(scope.title)
                        }
                    }
                }
            } label: {
                Label(selectedFeed.title, systemImage: "rectangle.stack")
                    .font(.caption.weight(.bold))
                    .frame(minHeight: 44)
                    .padding(.horizontal, 10)
            }
            .accessibilityIdentifier("feed.landscape.scope")
            Button {
                compactSearchDraft = searchText
                compactSearchPresented = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Search games")
            .accessibilityIdentifier("feed.landscape.search")
            Menu {
                Button("Feed preferences", systemImage: "slider.horizontal.3") {
                    isFeedPreferencesPresented = true
                }
                Button("Discover creators", systemImage: "person.2") {
                    isCreatorDiscoveryPresented = true
                }
                Button("Refresh games", systemImage: "arrow.clockwise") {
                    Task { await load() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("More feed controls")
            .accessibilityIdentifier("feed.landscape.more")
        }
        .foregroundStyle(.white)
        .background(.black.opacity(0.72), in: Capsule())
    }

    private var compactSearchSheet: some View {
        NavigationStack {
            Form {
                TextField("Find a game", text: $compactSearchDraft)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { applyCompactSearch() }
                    .accessibilityIdentifier("feed.landscape.searchField")
            }
            .navigationTitle("Search games")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { compactSearchPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Search") { applyCompactSearch() }
                }
            }
        }
    }

    private func applyCompactSearch() {
        searchText = compactSearchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        compactSearchPresented = false
    }

    /// Feed stack, extracted from `body` so the body expression
    /// stays type-checkable: picker + pager/grid branches + the
    /// sheet/cover modifiers together timed out the compiler.
    private var feedContent: some View {
        VStack(spacing: 0) {
                if !usesCompactFeedScopeMenu {
                    Picker("Feed", selection: $selectedFeed) {
                        ForEach(SocialFeedScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Social feed")
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }

                if showsImmersivePager {
                    forYouPager
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        if usesCompactLandscapeOverlay {
                            compactLandscapeOverlay
                                .padding(.trailing, 12)
                                .padding(.top, 4)
                        }
                    }
                    .overlay(alignment: .top) {
                        if let loadMoreError {
                            HStack(spacing: 10) {
                                Image(systemName: "wifi.exclamationmark")
                                Text(loadMoreError)
                                    .font(.caption)
                                    .lineLimit(2)
                                Button("Retry") {
                                    Task { await loadMore() }
                                }
                                .font(.subheadline.weight(.semibold))
                            }
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .accessibilityIdentifier("feed.pagination.retry")
                        }
                    }
                } else {
                    ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
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
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Finding something fun…")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Loading games")
                            // A slow or suspended network request must not trap the
                            // player behind an unclickable skeleton. This retries
                            // with a NEW request, cancelling the previous one.
                            Button {
                                Task { await load() }
                            } label: {
                                Label("Retry loading", systemImage: "arrow.clockwise")
                                    .frame(minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("feed.retryLoading")

                            LazyVGrid(columns: feedGridColumns, alignment: .center, spacing: HephaestusDesign.sectionSpacing) {
                                ForEach(0..<(horizontalSizeClass == .regular ? 4 : 2), id: \.self) { _ in
                                    GameFeedCardSkeleton()
                                }
                            }
                        }
                        .frame(maxWidth: 1120)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    } else if let errorMessage, games.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.system(size: 38, weight: .medium))
                                .foregroundStyle(ArcadePulseTheme.neonMagenta)
                                .frame(width: 76, height: 76)
                                .background(ArcadePulseTheme.electricViolet.opacity(0.16),
                                            in: RoundedRectangle(cornerRadius: 20))
                                .accessibilityHidden(true)
                            Text("Couldn't load the feed")
                                .font(.system(.title2, design: .rounded).weight(.bold))
                                .foregroundStyle(.white)
                                .accessibilityAddTraits(.isHeader)
                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundStyle(ArcadePulseTheme.textSecondary)
                                .multilineTextAlignment(.center)
                            Text("You can still check Library for games you've saved.")
                                .font(.subheadline)
                                .foregroundStyle(ArcadePulseTheme.textSecondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                Task { await load() }
                            } label: {
                                Label("Try again", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(ArcadePulseTheme.electricViolet)
                            .accessibilityIdentifier("feed.error.retry")
                            if let onOpenLibrary {
                                Button(action: onOpenLibrary) {
                                    Label("Open Library", systemImage: "bookmark")
                                        .frame(maxWidth: .infinity, minHeight: 48)
                                }
                                .buttonStyle(.bordered)
                                .tint(ArcadePulseTheme.neonMagenta)
                                .accessibilityIdentifier("feed.error.library")
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: 520)
                        .background(ArcadePulseTheme.surface,
                                    in: RoundedRectangle(cornerRadius: ArcadePulseTheme.surfaceRadius))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("feed.error.recovery")
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
                                gridCard(for: game)
                            }
                        }
                        .frame(maxWidth: 1120)
                        if nextCursor != nil && searchText.isEmpty {
                            if let loadMoreError {
                                VStack(spacing: 8) {
                                    Label(loadMoreError, systemImage: "wifi.exclamationmark")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                    Button("Retry loading games") {
                                        Task { await loadMore() }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(isLoadingMore || isLoading)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 4)
                            } else {
                                Button {
                                    Task { await loadMore() }
                                } label: {
                                    if isLoadingMore { ProgressView("Loading more games…") }
                                    else { Text("Load more games") }
                                }
                                .frame(maxWidth: .infinity)
                                .buttonStyle(.bordered)
                                .disabled(isLoadingMore || isLoading)
                            }
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
                    }
                }
            // This observer remains active when compact landscape hides
            // the segmented picker. Clear old private feed cards before
            // requesting the newly selected social scope.
            .onChange(of: selectedFeed) { _, _ in
                FeedPreviewPlayback.shared.stop()
                settledForYouGameID = nil
                games = []
                nextCursor = nil
                loadMoreError = nil
                errorMessage = nil
                Task { await load() }
            }
            .background(ArcadePulseTheme.canvas)
            .preferredColorScheme(.dark)
            .navigationTitle(usesCompactFeedScopeMenu ? selectedFeed.title : "Discover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(usesCompactLandscapeOverlay ? .hidden : .visible, for: .navigationBar)
            .modifier(FeedSearchVisibilityModifier(
                text: $searchText, hidesNativeSearch: usesCompactLandscapeOverlay))
            .toolbar {
                if usesCompactFeedScopeMenu {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            ForEach(SocialFeedScope.allCases) { scope in
                                Button {
                                    selectedFeed = scope
                                } label: {
                                    if selectedFeed == scope {
                                        Label(scope.title, systemImage: "checkmark")
                                    } else {
                                        Text(scope.title)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "rectangle.stack")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityIdentifier("feed.scope.menu")
                        .accessibilityLabel("Social feed: \(selectedFeed.title). Change feed")
                    }
                }
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
    }

    /// Pager construction, extracted from feedContent for the same
    /// reason: sixteen closure arguments in one expression.
    private var forYouPager: some View {
                    ForYouPagerView(
                        settledGameID: $settledForYouGameID,
                        scope: selectedFeed,
                        games: visibleGames,
                        savedGameIDs: savedGameIDs,
                        likedGameIDs: likedGameIDs,
                        followedCreatorIDs: followedCreatorIDs,
                        onPlay: { play($0) },
                        onToggleSaved: { toggleSaved($0) },
                        onToggleLike: { toggleLike($0) },
                        onToggleFollow: { game in
                            if let id = game.ownerID { Task { await toggleFollow(id) } }
                        },
                        onOpenComments: { commentsGame = $0 },
                        onOpenCreator: { game in
                            if let id = game.ownerID { profileRequest = CreatorProfileRequest(id: id) }
                        },
                        onReport: { reportingGame = $0 },
                        onBlockCreator: { game in
                            if let id = game.ownerID { Task { await blockCreator(id) } }
                        },
                        onNotInterested: { game in Task { await markNotInterested(game) } },
                        onOpenDetails: { detailGame = $0 },
                        onImpression: { game in
                            Task { await BackendAPI.shared.trackSocialEvent(gameID: game.id, kind: "impression") }
                        },
                        onNearEnd: {
                            if ForYouPageLayout.shouldAutoLoadNextPage(
                                hasCursor: nextCursor != nil, isLoading: isLoading,
                                isLoadingMore: isLoadingMore, hasPaginationError: loadMoreError != nil
                            ) {
                                Task { await loadMore() }
                            }
                        }
                    )
    }

    /// Grid card construction, extracted from feedContent.
    private func gridCard(for game: FeedGame) -> some View {
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
                                    onImpression: { Task { await BackendAPI.shared.trackSocialEvent(gameID: game.id, kind: "impression") } },
                                    shouldAutoplayPreview: false
                                )
    }

    var body: some View {
        NavigationStack {
            feedContent
            .refreshable { await load() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { FeedPreviewPlayback.shared.stop() }
            }
            .onChange(of: playerRequest?.gameID) { _, gameID in
                if gameID != nil { FeedPreviewPlayback.shared.stop() }
            }
            .task {
                savedGameIDs = Set(UserDefaults.standard.stringArray(forKey: "hephaestus.savedGames") ?? [])
                if ProcessInfo.processInfo.arguments.contains("--ui-test-feed-error-state") {
                    // Deterministic visual QA of the network-error recovery,
                    // explicitly isolated from the normal LIVE-feed smoke.
                    // Never synthesize a feed game, player, or login session.
                    games = []
                    isLoading = false
                    errorMessage = "Test-only: public feed request unavailable."
                } else {
                    await load()
                }
            }
            .fullScreenCover(item: $playerRequest) { request in
                PixiPlayerSheet(gameID: request.gameID, title: request.title,
                                holdPosterURL: request.posterURL, tappedAt: request.tappedAt, onFinish: {
                    guard let game = games.first(where: { $0.id == request.gameID }) else { return }
                    resultPresentation = PlayerResultPresentation(game: game, result: $0)
                })
            }
            .sheet(item: $resultPresentation) { presentation in
                PlayerResultSheet(
                    game: presentation.game,
                    result: presentation.result,
                    isLiked: likedGameIDs.contains(presentation.game.id),
                    onPlayAgain: {
                        DispatchQueue.main.async { play(presentation.game) }
                    },
                    onNextGame: { Task { await advanceToNextGame(after: presentation.game) } },
                    onToggleLike: { toggleLike(presentation.game) }
                )
            }
            .sheet(isPresented: $compactSearchPresented) {
                compactSearchSheet
            }
            .sheet(item: $commentsGame) { game in
                CommentsSheet(game: game)
            }
            .sheet(item: $detailGame) { game in
                ArcadePulseGameDetailsSheet(game: game)
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
        // Prime the WebView on the actual Play action, rather than using a
        // zero-distance finger-drag recognizer on the card CTA. This keeps
        // vertical feed navigation independent of player prewarming.
        PlayerWebViewPool.prewarm(gameID: game.id)
        RecentGames.record(gameID: game.id, title: game.title)
        // #58: the tap timestamp and poster travel with the request so
        // the sheet can measure tap-to-nav-ready and hold the poster
        // over the web view until navigation finishes.
        playerRequest = PixiPlayerRequest(gameID: game.id, title: game.title,
                                          tappedAt: Date(), posterURL: game.previewPosterURL)
    }

    private func advanceToNextGame(after game: FeedGame) async {
        guard let index = visibleGames.firstIndex(where: { $0.id == game.id }) else {
            resultPresentation = nil
            return
        }
        if !visibleGames.indices.contains(index + 1), nextCursor != nil {
            await loadMore()
        }
        guard visibleGames.indices.contains(index + 1) else {
            resultPresentation = nil
            return
        }
        let nextGame = visibleGames[index + 1]
        resultPresentation = nil
        // Each social scope now has its own immersive pager. Play Next must
        // keep the same feed (including private Following/Friends results),
        // rather than switching to For You and selecting a game from another scope.
        let destination = ForYouPageLayout.contextAfterPlayingNext(
            currentScope: selectedFeed, nextGameID: nextGame.id)
        selectedFeed = destination.scope
        searchText = destination.searchText
        settledForYouGameID = destination.selectedGameID
    }

    private func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore else { return }
        let requestedScope = selectedFeed
        let requestedGeneration = feedRequestCoordinator.generation
        isLoadingMore = true
        loadMoreError = nil
        defer { isLoadingMore = false }
        do {
            let page = try await BackendAPI.shared.fetchFeed(scope: requestedScope, cursor: cursor)
            guard ForYouPageLayout.shouldApplyPaginationResult(
                requestedScope: requestedScope, currentScope: selectedFeed,
                requestedGeneration: requestedGeneration,
                currentGeneration: feedRequestCoordinator.generation) else { return }
            var seen = Set(games.map(\.id))
            games.append(contentsOf: page.games.filter { seen.insert($0.id).inserted })
            nextCursor = page.next_cursor.flatMap { $0.isEmpty ? nil : $0 }
        } catch {
            // An old Following/Friends page may fail after switching tabs.
            // Never show its private-scope error in a different feed.
            if ForYouPageLayout.shouldApplyPaginationResult(
                requestedScope: requestedScope, currentScope: selectedFeed,
                requestedGeneration: requestedGeneration,
                currentGeneration: feedRequestCoordinator.generation) {
                loadMoreError = "Couldn't load more games: \(error.localizedDescription)"
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
            repairPagerSelection()
        } catch { errorMessage = "Couldn't block creator: \(error.localizedDescription)" }
    }

    private func markNotInterested(_ game: FeedGame) async {
        do {
            try await BackendAPI.shared.markNotInterested(gameID: game.id)
            games.removeAll { $0.id == game.id }
            repairPagerSelection()
        } catch { errorMessage = "Couldn't save feedback: \(error.localizedDescription)" }
    }

    private func repairPagerSelection() {
        if let settledForYouGameID, games.contains(where: { $0.id == settledForYouGameID }) { return }
        settledForYouGameID = games.first?.id
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
        let requestedScope = selectedFeed
        let (generation, request) = feedRequestCoordinator.begin {
            try await BackendAPI.shared.fetchFeed(scope: requestedScope)
        }
        isLoading = true
        defer {
            if feedRequestCoordinator.isCurrent(generation) {
                isLoading = false
                feedRequestCoordinator.finishIfCurrent(generation)
            }
        }
        errorMessage = nil
        do {
            let loadedGames = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                request.cancel()
            }
            guard requestedScope == selectedFeed,
                  feedRequestCoordinator.isCurrent(generation) else { return }
            games = loadedGames.games
            nextCursor = loadedGames.next_cursor.flatMap { $0.isEmpty ? nil : $0 }
            repairPagerSelection()

            // The public game list is the critical path for rendering Discover.
            // Viewer metadata (following, saved games, preferences) is optional;
            // do not keep the entire feed behind its loading skeleton while those
            // secondary endpoints respond or recover from a transient outage.
            isLoading = false

            let hasServerViewerState = loadedGames.games.contains {
                $0.viewerLiked != nil || $0.viewerSaved != nil || $0.viewerFollowing != nil
            }
            if hasServerViewerState {
                followedCreatorIDs = Set(loadedGames.games.filter { $0.viewerFollowing == true }.compactMap(\.ownerID))
                savedGameIDs = Set(loadedGames.games.filter { $0.viewerSaved == true }.map(\.id))
                likedGameIDs = Set(loadedGames.games.filter { $0.viewerLiked == true }.map(\.id))
                UserDefaults.standard.set(savedGameIDs.sorted(), forKey: "hephaestus.savedGames")
            } else {
                if let ids = try? await BackendAPI.shared.fetchFollowingCreatorIDs(), feedRequestCoordinator.isCurrent(generation) {
                    followedCreatorIDs = ids
                }
                if let ids = try? await BackendAPI.shared.fetchSavedGameIDs(), feedRequestCoordinator.isCurrent(generation) {
                    savedGameIDs = ids
                    UserDefaults.standard.set(ids.sorted(), forKey: "hephaestus.savedGames")
                }
            }
            if let preferences = try? await BackendAPI.shared.fetchFeedPreferences(), feedRequestCoordinator.isCurrent(generation) {
                mutedTopics = Set(preferences.muted_topics.map { $0.lowercased() })
            }
        } catch {
            if requestedScope == selectedFeed && feedRequestCoordinator.isCurrent(generation) {
                errorMessage = error.localizedDescription
            }
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
        .background(HephaestusDesign.cardBackground, in: RoundedRectangle(cornerRadius: HephaestusDesign.sectionRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct ForYouGamePage: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsExpressionDetails = false
    // A URL in the feed does not establish that its image decoded successfully.
    // Keep accessibility/media audits tied to the exact poster that rendered.
    @State private var loadedPosterURL: String?
    @ObservedObject private var previewPlayback = FeedPreviewPlayback.shared

    let scope: SocialFeedScope
    let game: FeedGame
    let isSaved: Bool
    let isLiked: Bool
    let isFollowingCreator: Bool
    let canFollowCreator: Bool
    let isSettled: Bool
    let onPlay: () -> Void
    let onToggleSaved: () -> Void
    let onToggleLike: () -> Void
    let onToggleFollow: () -> Void
    let onOpenComments: () -> Void
    let onOpenCreator: () -> Void
    let onReport: () -> Void
    let onBlockCreator: () -> Void
    let onNotInterested: () -> Void
    let onOpenDetails: () -> Void
    let onImpression: () -> Void

    private var shareURL: URL {
        var components = URLComponents(url: BackendConfig.baseURL.appendingPathComponent("player"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "game", value: game.id)]
        return components.url ?? BackendConfig.baseURL
    }

    private var palette: [Color] {
        ArcadePulseTheme.fallbackPalette(gameID: game.id)
    }

    private var creatorName: String {
        guard let creator = game.ownerID, !creator.isEmpty else { return "Mini game" }
        return game.creatorDisplayName?.isEmpty == false ? game.creatorDisplayName! : creator
    }

    // A missing or stale version-bound poster is not a recorded preview.
    // Keep the card playable and say so, without inventing visual evidence.
    private var unavailablePreview: some View {
        VStack(spacing: dynamicTypeSize.isAccessibilitySize ? 6 : 12) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 38 : 60, weight: .medium))
            Text("Preview unavailable")
                // The decorative media hint must not become a giant label
                // covering the real game title and accessible Play action.
                .font(dynamicTypeSize.isAccessibilitySize ? .system(size: 15, weight: .semibold) : .subheadline.weight(.semibold))
            Text("Tap Play now to explore")
                .font(dynamicTypeSize.isAccessibilitySize ? .system(size: 12) : .caption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .foregroundStyle(.white.opacity(0.94))
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    private var mediaLayer: some View {
        ZStack {
            LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
            if let poster = game.previewPosterURL, let url = URL(string: poster) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                            .onAppear { loadedPosterURL = poster }
                    } else if phase.error == nil {
                        ProgressView("Loading preview")
                            .tint(.white)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        unavailablePreview
                            .onAppear { loadedPosterURL = nil }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            } else {
                unavailablePreview
                    .onAppear { loadedPosterURL = nil }
            }
            if previewPlayback.activeGameID == game.id && !reduceMotion {
                FeedPreviewSurface(player: previewPlayback.player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.02), location: 0),
                    .init(color: .black.opacity(0.08), location: 0.42),
                    .init(color: .black.opacity(0.88), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipped()
        .onChange(of: game.previewPosterURL) { _, _ in loadedPosterURL = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ForYouPageLayout.mediaAccessibilityLabel(
            title: game.title,
            hasPreviewMedia: loadedPosterURL != nil && loadedPosterURL == game.previewPosterURL
        ))
        .accessibilityIdentifier("feed.preview.media.\(game.id)")
        .accessibilityAddTraits(.isImage)
        .accessibilitySortPriority(100)
        // Preview media is decorative; it must not intercept vertical pager swipes.
        .allowsHitTesting(false)
    }

    // Short, truthful captions help first-time viewers recognize the actions,
    // like the familiar vertical rails in short-video feeds. Never invent
    // engagement counts when the backend has not provided verified totals.
    private func iconAction(_ symbol: String, label: String, caption: String? = nil,
                            action: @escaping () -> Void) -> some View {
        ArcadePulseAction(symbol: symbol, accessibilityLabel: label,
                          caption: caption, action: action)
    }

    private func sourceLabel(_ type: String) -> String {
        switch type {
        case "drawing": "a drawing"
        case "image": "a photo"
        case "video": "a video"
        case "audio": "a voice note"
        default: "a story"
        }
    }

    @ViewBuilder private func socialActionButtons(vertical: Bool) -> some View {
        iconAction(isSaved ? "bookmark.fill" : "bookmark",
                   label: isSaved ? "Remove from library" : "Save game",
                   caption: vertical ? "Save" : nil, action: onToggleSaved)
        iconAction(isLiked ? "heart.fill" : "heart",
                   label: isLiked ? "Unlike game" : "Like game",
                   caption: vertical ? "Like" : nil, action: onToggleLike)
        iconAction("bubble.right", label: "View comments",
                   caption: vertical ? "Comment" : nil, action: onOpenComments)
        Menu {
            Button("Game details", systemImage: "info.circle", action: onOpenDetails)
            Button("Report game", role: .destructive, action: onReport)
            Button("Not interested", action: onNotInterested)
            if game.ownerID != nil {
                Button("Block creator", role: .destructive, action: onBlockCreator)
            }
        } label: {
            VStack(spacing: 1) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                if vertical {
                    Text("More")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .frame(minWidth: 48, minHeight: vertical ? 58 : 44)
            .contentShape(Rectangle())
        }
        .foregroundStyle(.white)
        .accessibilityLabel("More game actions")
        .accessibilitySortPriority(70)
        ShareLink(item: shareURL) {
            VStack(spacing: 1) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                if vertical {
                    Text("Share")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .frame(minWidth: 48, minHeight: vertical ? 58 : 44)
            .contentShape(Rectangle())
        }
        .simultaneousGesture(TapGesture().onEnded {
            Task { await BackendAPI.shared.trackSocialEvent(gameID: game.id, kind: "share") }
        })
        .foregroundStyle(.white)
        .accessibilityLabel("Share \(game.title)")
    }

    @ViewBuilder private func socialActions(vertical: Bool) -> some View {
        if vertical {
            VStack(spacing: 5) { socialActionButtons(vertical: true) }
                .padding(4)
                .background(.black.opacity(0.3), in: Capsule())
                .accessibilityIdentifier("feed.actionRail")
        } else {
            HStack(spacing: 8) { socialActionButtons(vertical: false) }
        }
    }

    private func detailsOverlay(bottomInset: CGFloat) -> some View {
        let isCompact = verticalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: isCompact ? 6 : 14) {
            Spacer(minLength: isCompact ? 0 : 100)
            HStack(spacing: 8) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(scope.title.uppercased())
                        .accessibilityIdentifier("feed.scope.caption")
                        .font(.caption2.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.82))
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
                // The accessibility-XXXL screenshot previously put a huge,
                // truncated title over the preview and bottom controls.
                // Preserve the full VoiceOver text, but bound its visual size
                // within a two-line feed overlay.
                .font(dynamicTypeSize.isAccessibilitySize
                    ? .system(size: 22, weight: .bold, design: .rounded)
                    : .system(isCompact ? .title2 : .title, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.85 : 1)
                .accessibilityIdentifier("feed.page.title.\(game.id)")
                .accessibilitySortPriority(90)
            if !isCompact, let caption = game.caption, !caption.isEmpty {
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(2)
            }
            if !isCompact, let topics = game.topics, !topics.isEmpty {
                Text(topics.prefix(3).map { "#\($0)" }.joined(separator: "  "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .accessibilityLabel("Topics: " + topics.prefix(3).joined(separator: ", "))
            }
            if !isCompact, let expression = game.playableExpression, expression.source_visibility == "public" {
                Button { showsExpressionDetails = true } label: {
                    Label("Made from " + sourceLabel(expression.source_type), systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("feed.expression.details")
            }
            if !isCompact {
            HStack(spacing: 8) {
                ArcadePulseCreatorIdentity(
                    name: creatorName,
                    avatarURL: game.creatorAvatarURL,
                    foreground: ArcadePulseTheme.textPrimary,
                    action: onOpenCreator
                )
                .accessibilitySortPriority(80)
                Spacer(minLength: 4)
                if canFollowCreator {
                    Button(action: onToggleFollow) {
                        Label(isFollowingCreator ? "Following" : "Follow", systemImage: isFollowingCreator ? "person.fill.checkmark" : "person.badge.plus")
                            .font(.caption.weight(.bold))
                            .frame(minHeight: 44)
                            .padding(.horizontal, 10)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .accessibilityLabel(isFollowingCreator ? "Unfollow creator" : "Follow creator")
                    .accessibilitySortPriority(70)
                }
            }
            }
            if isCompact { socialActions(vertical: false) }
            HStack(spacing: 10) {
                ArcadePulsePlayCTA(action: onPlay)
                // Do not attach a zero-distance drag to Play. On short
                // landscape screens that button fills the lower swipe
                // start region and steals the parent page gesture.
                // Prewarm in the button's action instead.
            }
            .accessibilitySortPriority(60)
        }
        .padding(.horizontal, isCompact ? 10 : 20)
        .padding(.top, isCompact ? 4 : 24)
        .padding(.bottom, isCompact ? max(12, bottomInset + 8) : max(24, bottomInset + 12))
        .frame(maxWidth: ForYouPageLayout.contentMaxWidth(isRegular: horizontalSizeClass == .regular), maxHeight: .infinity, alignment: .bottomLeading)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    @ViewBuilder private func claimSection(_ title: String, claims: [FeedExpressionClaim]?) -> some View {
        if let claims, !claims.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                ForEach(Array(claims.enumerated()), id: \.offset) { _, claim in
                    Text(claim.text).font(.body)
                }
            }
        }
    }

    /// Tablet-only social context stays beside a large real playable preview,
    /// never on top of gameplay or in compact Split View. Use backend
    /// metadata only; mockup play counts, star ratings and creator figures
    /// are illustrative and must never appear as product facts.
    private var ipadContextPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("GAME SPOTLIGHT", systemImage: "gamecontroller.fill")
                .font(.caption.weight(.bold))
                .tracking(0.8)
                .foregroundStyle(ArcadePulseTheme.neonMagenta)

            Text(game.title)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(ArcadePulseTheme.textPrimary)
                .lineLimit(3)
                .minimumScaleFactor(0.85)

            if let owner = game.ownerID, !owner.isEmpty {
                ArcadePulseCreatorIdentity(
                    name: creatorName,
                    avatarURL: game.creatorAvatarURL,
                    foreground: ArcadePulseTheme.textPrimary,
                    action: onOpenCreator)
            }

            if let caption = game.caption, !caption.isEmpty {
                Text(caption)
                    .font(.subheadline)
                    .foregroundStyle(ArcadePulseTheme.textSecondary)
                    .lineLimit(5)
            }

            if let topics = game.topics, !topics.isEmpty {
                Text(topics.prefix(4).map { "#\($0)" }.joined(separator: "  "))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ArcadePulseTheme.neonMagenta)
                    .lineLimit(3)
            }

            Divider().overlay(ArcadePulseTheme.subtleBorder)

            Label("Swipe vertically to discover the next game.",
                  systemImage: "arrow.up.arrow.down")
                .font(.subheadline)
                .foregroundStyle(ArcadePulseTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if game.previewPosterURL == nil && game.previewClipURL == nil {
                Label("A recorded gameplay preview is not available yet.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(ArcadePulseTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            ArcadePulseTheme.surface,
            in: RoundedRectangle(cornerRadius: ArcadePulseTheme.surfaceRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ArcadePulseTheme.surfaceRadius, style: .continuous)
                .strokeBorder(ArcadePulseTheme.subtleBorder, lineWidth: 1)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feed.ipad.context")
    }

    var body: some View {
        GeometryReader { proxy in
            let isRegular = horizontalSizeClass == .regular
            let isLandscape = proxy.size.width > proxy.size.height
            let showsContext = ForYouPageLayout.showsIPadContextPanel(
                width: proxy.size.width, height: proxy.size.height,
                isRegular: isRegular, isAccessibilityText: dynamicTypeSize.isAccessibilitySize)
            let pageWidth = showsContext
                ? ForYouPageLayout.adaptiveLandscapeStageWidth(containerWidth: proxy.size.width)
                : ForYouPageLayout.stageWidth(containerWidth: proxy.size.width, containerHeight: proxy.size.height, isRegular: isRegular, isLandscape: isLandscape)
            ZStack {
                // The centered portrait stage is intentional on iPad, but
                // an empty white surround looks like a broken phone layout.
                // A low-contrast palette-tinted theater backdrop makes
                // portrait and landscape pages feel immersive without
                // inventing a poster or implying recorded gameplay exists.
                LinearGradient(
                    colors: [
                        ArcadePulseTheme.canvas,
                        palette[0].opacity(0.30),
                        palette[1].opacity(0.25)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                HStack(spacing: showsContext ? 12 : 0) {
                    Spacer(minLength: 0)
                    ZStack(alignment: .bottom) {
                        mediaLayer
                        VStack {
                            HStack {
                                if !dynamicTypeSize.isAccessibilitySize && !isLandscape {
                                    Label("SWIPE TO EXPLORE", systemImage: "arrow.up.arrow.down")
                                        .font(.caption2.weight(.bold))
                                        .tracking(0.8)
                                        .foregroundStyle(.white.opacity(0.9))
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 8)
                                        .background(.black.opacity(0.28), in: Capsule())
                                }
                                Spacer(minLength: 0)
                                if !dynamicTypeSize.isAccessibilitySize && isLandscape {
                                    // Keep the vertical-swipe hint visible on short iPhone
                                    // landscape viewports, opposite the title.
                                    // It is noninteractive and does not take
                                    // touch space away from the media stage.
                                    Label("SWIPE TO EXPLORE", systemImage: "arrow.up.arrow.down")
                                        .font(.caption2.weight(.bold))
                                        .tracking(0.8)
                                        .foregroundStyle(.white.opacity(0.9))
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 8)
                                        .background(.black.opacity(0.28), in: Capsule())
                                }
                                if !dynamicTypeSize.isAccessibilitySize, let orientation = game.orientationLabel {
                                    Text(orientation)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(.black.opacity(0.4), in: Capsule())
                                        .accessibilityIdentifier("feed.orientation")
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .allowsHitTesting(false)
                        HStack(alignment: .bottom, spacing: 0) {
                            detailsOverlay(bottomInset: proxy.safeAreaInsets.bottom)
                            if verticalSizeClass != .compact && !dynamicTypeSize.isAccessibilitySize {
                                socialActions(vertical: true)
                                    .padding(.trailing, 12)
                                    .padding(.bottom, max(24, proxy.safeAreaInsets.bottom + 12))
                            }
                        }
                    }
                    .frame(width: pageWidth, height: proxy.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: isRegular ? 24 : 0, style: .continuous))
                    if showsContext {
                        ipadContextPanel
                            .frame(width: ForYouPageLayout.contextPanelWidth(
                                containerWidth: proxy.size.width),
                                   height: proxy.size.height)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showsExpressionDetails) {
            NavigationStack {
                ScrollView {
                    if let expression = game.playableExpression, expression.source_visibility == "public" {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(expression.intent ?? game.title).font(.title2.bold())
                            if let interpretation = expression.chosen_interpretation {
                                Text("Game interpretation").font(.headline)
                                Text(interpretation)
                            }
                            claimSection("Preserved from the source", claims: expression.preserved)
                            claimSection("Invented for the game", claims: expression.invented)
                            claimSection("Uncertain interpretation", claims: expression.uncertain)
                        }.padding(24)
                    }
                }
                .navigationTitle("Behind this game")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsExpressionDetails = false } } }
            }
        }
        .onAppear {
            if isSettled && !reduceMotion && scenePhase == .active {
                FeedPreviewPlayback.shared.scheduleSettled(gameID: game.id, urlString: game.previewClipURL, reduceMotion: reduceMotion)
            }
        }
        .onDisappear { FeedPreviewPlayback.shared.stop(gameID: game.id) }
        .task(id: isSettled && scenePhase == .active) {
            guard isSettled && scenePhase == .active else { return }
            try? await Task.sleep(for: .milliseconds(ForYouPageLayout.impressionMinimumDwellMilliseconds))
            guard !Task.isCancelled else { return }
            if ForYouPageLayout.shouldTrackImpression(
                isSettled: isSettled,
                dwellMilliseconds: ForYouPageLayout.impressionMinimumDwellMilliseconds
            ) {
                onImpression()
            }
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            if shouldReduceMotion || !isSettled {
                FeedPreviewPlayback.shared.stop(gameID: game.id)
            } else {
                FeedPreviewPlayback.shared.scheduleSettled(gameID: game.id, urlString: game.previewClipURL, reduceMotion: shouldReduceMotion)
            }
        }
        // The card identity stays stable when a refreshed published version
        // replaces its approved media. Propagate the new URL immediately;
        // otherwise a settled page would keep playing the obsolete clip.
        .onChange(of: game.previewClipURL) { _, nextURL in
            if isSettled && scenePhase == .active && !reduceMotion {
                FeedPreviewPlayback.shared.scheduleSettled(
                    gameID: game.id, urlString: nextURL, reduceMotion: reduceMotion)
            } else {
                FeedPreviewPlayback.shared.stop(gameID: game.id)
            }
        }
        .onChange(of: isSettled) { _, shouldPlay in
            if shouldPlay && !reduceMotion && scenePhase == .active {
                FeedPreviewPlayback.shared.scheduleSettled(gameID: game.id, urlString: game.previewClipURL, reduceMotion: reduceMotion)
            } else {
                FeedPreviewPlayback.shared.stop(gameID: game.id)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && isSettled && !reduceMotion {
                FeedPreviewPlayback.shared.scheduleSettled(gameID: game.id, urlString: game.previewClipURL, reduceMotion: reduceMotion)
            } else if phase != .active {
                FeedPreviewPlayback.shared.stop(gameID: game.id)
            }
        }
    }
}

private struct ForYouPagerView: View {
    @Binding var settledGameID: String?
    // Diagnostic-only instrumentation: distinguish a gesture that never
    // arrived from one whose direction, or selected-page state, was wrong.
    @State private var diagnosticDragCount = 0
    @State private var diagnosticLastDragY = 0
    @State private var diagnosticLastOffset = 0
    let scope: SocialFeedScope
    let games: [FeedGame]
    let savedGameIDs: Set<String>
    let likedGameIDs: Set<String>
    let followedCreatorIDs: Set<String>
    let onPlay: (FeedGame) -> Void
    let onToggleSaved: (FeedGame) -> Void
    let onToggleLike: (FeedGame) -> Void
    let onToggleFollow: (FeedGame) -> Void
    let onOpenComments: (FeedGame) -> Void
    let onOpenCreator: (FeedGame) -> Void
    let onReport: (FeedGame) -> Void
    let onBlockCreator: (FeedGame) -> Void
    let onNotInterested: (FeedGame) -> Void
    let onOpenDetails: (FeedGame) -> Void
    let onImpression: (FeedGame) -> Void
    let onNearEnd: () -> Void

    /// Full-bleed pages serve all non-search social feeds, with the compact
    /// card reserved for search results and empty/error states.
    private func card(for game: FeedGame) -> some View {
        ForYouGamePage(
            scope: scope,
            game: game,
            isSaved: savedGameIDs.contains(game.id),
            isLiked: likedGameIDs.contains(game.id),
            isFollowingCreator: game.ownerID.map { followedCreatorIDs.contains($0) } ?? false,
            canFollowCreator: game.ownerID != nil && game.ownerID != BackendConfig.currentUserID,
            isSettled: game.id == settledGameID,
            onPlay: { onPlay(game) },
            onToggleSaved: { onToggleSaved(game) },
            onToggleLike: { onToggleLike(game) },
            onToggleFollow: { onToggleFollow(game) },
            onOpenComments: { onOpenComments(game) },
            onOpenCreator: { onOpenCreator(game) },
            onReport: { onReport(game) },
            onBlockCreator: { onBlockCreator(game) },
            onNotInterested: { onNotInterested(game) },
            onOpenDetails: { onOpenDetails(game) },
            onImpression: { onImpression(game) }
        )
    }

    /// Keep only the selected card in the SwiftUI and accessibility trees.
    /// ScrollView with a LazyVStack of adjacent cards leaked the next title
    /// into compact iPhone landscape, even after clipping and scrollTo
    /// alignment. A single-page renderer makes that failure impossible.
    private var selectedGame: FeedGame? {
        games.first(where: { $0.id == settledGameID }) ?? games.first
    }

    private var currentIndex: Int {
        games.firstIndex(where: { $0.id == selectedGame?.id }) ?? 0
    }

    private var pagerAccessibilityValue: String {
        #if DEBUG
        return "Drag \(diagnosticDragCount) dy \(diagnosticLastDragY) offset \(diagnosticLastOffset); Game \(games.isEmpty ? 0 : currentIndex + 1) of \(games.count)"
        #else
        return "Game \(games.isEmpty ? 0 : currentIndex + 1) of \(games.count)"
        #endif
    }

    private func movePage(by offset: Int) {
        guard !games.isEmpty, offset != 0 else { return }
        let targetIndex = min(max(currentIndex + offset, 0), games.count - 1)
        guard targetIndex != currentIndex else { return }
        // One state transition updates identity, media and accessible title
        // together. No stored scroll offset or intermediate card is exposed.
        withTransaction(Transaction(animation: nil)) {
            settledGameID = games[targetIndex].id
        }
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView(.vertical) {
                if let game = selectedGame {
                    card(for: game)
                        .frame(maxWidth: .infinity)
                        .frame(height: viewport.size.height)
                        .id(game.id)
                        .accessibilityElement(children: .contain)
                        .accessibilityHint("Swipe up for the next game")
                }
            }
            .accessibilityIdentifier("feed.forYou.pager")
            .accessibilityLabel("\(scope.title) game feed")
            .accessibilityValue(pagerAccessibilityValue)
            .accessibilityHint("Scroll up for the next game, or down for the previous game")
            .accessibilityScrollAction { edge in
                if edge == .top {
                    movePage(by: 1)
                } else if edge == .bottom {
                    movePage(by: -1)
                }
            }
            // The screen shows one card only. ScrollView exists for familiar
            // VoiceOver scroll semantics and UI automation; physical touch
            // navigation is owned by the high-priority drag gesture.
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
            .clipped()
            // Attach the physical page drag to the actual scroll viewport.
            // With compact landscape removing the scope picker, a gesture on
            // the outer GeometryReader could miss swipes begun on the page.
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 35)
                    .onEnded { value in
                        let offset = ForYouPageLayout.pageOffsetForSwipe(
                            translation: value.translation,
                            predictedEndTranslation: value.predictedEndTranslation
                        )
                        diagnosticDragCount += 1
                        diagnosticLastDragY = Int(value.translation.height)
                        diagnosticLastOffset = offset
                        movePage(by: offset)
                    }
            )
            .onAppear {
                settledGameID = ForYouPageLayout.reconciledSelection(
                    currentID: settledGameID,
                    availableIDs: games.map(\.id)
                )
            }
            .onChange(of: games.map(\.id)) { _, ids in
                settledGameID = ForYouPageLayout.reconciledSelection(
                    currentID: settledGameID,
                    availableIDs: ids
                )
            }
            .onChange(of: settledGameID) { _, id in
                guard let id, let index = games.firstIndex(where: { $0.id == id }) else { return }
                if index >= max(0, games.count - 2) { onNearEnd() }
            }
        }
    }
}

private struct ArcadePulseGameDetailsSheet: View {
    let game: FeedGame
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var playerRequest: PixiPlayerRequest?

    private var shareURL: URL {
        var components = URLComponents(url: BackendConfig.baseURL.appendingPathComponent("player"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "game", value: game.id)]
        return components?.url ?? BackendConfig.baseURL
    }

    private var preview: some View {
        ZStack {
            LinearGradient(colors: ArcadePulseTheme.fallbackPalette(gameID: game.id),
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let poster = game.previewPosterURL, let url = URL(string: poster) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        unavailablePreview
                    }
                }
            } else {
                unavailablePreview
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: horizontalSizeClass == .regular ? 335 : 240)
        .clipShape(RoundedRectangle(cornerRadius: ArcadePulseTheme.surfaceRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(game.previewPosterURL == nil
                            ? "Gameplay preview unavailable"
                            : "Game preview image or fallback for \(game.title)")
        .accessibilityIdentifier("game.details.preview")
    }

    private var unavailablePreview: some View {
        VStack(spacing: 10) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 38))
            Text("Preview unavailable")
                .font(.headline)
            Text("Play the actual game below")
                .font(.caption)
        }
        .foregroundStyle(.white)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    preview
                    Text(game.title)
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("game.details.title")
                    if let owner = game.ownerID, !owner.isEmpty {
                        Label(game.creatorDisplayName?.isEmpty == false
                              ? game.creatorDisplayName! : owner,
                              systemImage: "person.crop.circle")
                            .foregroundStyle(ArcadePulseTheme.textSecondary)
                    }
                    if let caption = game.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.body)
                            .foregroundStyle(ArcadePulseTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let topics = game.topics, !topics.isEmpty {
                        Text(topics.prefix(5).map { "#\($0)" }.joined(separator: "  "))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(ArcadePulseTheme.neonMagenta)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        if let orientation = game.orientationLabel {
                            Label(orientation, systemImage: "rotate.right")
                        }
                        if let version = game.publishedVersion {
                            Label("Published version \(version)", systemImage: "square.stack.3d.up")
                        }
                        if let remixParent = game.remixParentID, !remixParent.isEmpty {
                            Label("Published remix", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ArcadePulseTheme.textSecondary)
                    ArcadePulsePlayCTA {
                        playerRequest = PixiPlayerRequest(gameID: game.id, title: game.title)
                    }
                    ShareLink(item: shareURL) {
                        Label("Share game", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(ArcadePulseTheme.electricViolet)
                }
                .frame(maxWidth: horizontalSizeClass == .regular ? 800 : 560)
                .frame(maxWidth: .infinity)
                .padding(18)
            }
            .background(ArcadePulseTheme.canvas)
            .preferredColorScheme(.dark)
            .navigationTitle("Game details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fullScreenCover(item: $playerRequest) { request in
                PixiPlayerSheet(gameID: request.gameID, title: request.title)
            }
            .accessibilityIdentifier("game.details.root")
        }
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var profile: CreatorProfile?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var playerRequest: PixiPlayerRequest?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading creator…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let profile {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            VStack(alignment: .leading, spacing: 14) {
                                Label("ARCADE PULSE • CREATOR", systemImage: "sparkles")
                                    .font(.caption.weight(.bold))
                                    .tracking(1)
                                    .foregroundStyle(ArcadePulseTheme.neonMagenta)
                                HStack(alignment: .center, spacing: 14) {
                                    Image(systemName: "person.crop.circle.fill")
                                        .resizable()
                                        .scaledToFit()
                                        .foregroundStyle(ArcadePulseTheme.electricViolet)
                                        .frame(width: 64, height: 64)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(profile.creator_id)
                                            .font(.system(.title2, design: .rounded).weight(.bold))
                                            .lineLimit(2)
                                            .minimumScaleFactor(0.8)
                                        Text("Game creator")
                                            .font(.subheadline)
                                            .foregroundStyle(ArcadePulseTheme.textSecondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                HStack(spacing: 10) {
                                    creatorMetric("Games", value: profile.post_count)
                                    creatorMetric("Followers", value: profile.follower_count)
                                    creatorMetric("Following", value: profile.following_count)
                                }
                                if profile.creator_id != BackendConfig.currentUserID {
                                    Button {
                                        Task { await toggleFollow(profile.is_following) }
                                    } label: {
                                        Label(profile.is_following ? "Following" : "Follow creator",
                                              systemImage: profile.is_following ? "person.fill.checkmark" : "person.badge.plus")
                                            .font(.headline.weight(.semibold))
                                            .frame(maxWidth: .infinity, minHeight: 48)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(ArcadePulseTheme.electricViolet)
                                    .accessibilityIdentifier("creator.profile.follow")
                                }
                            }
                            .padding(18)
                            .background(ArcadePulseTheme.surface,
                                        in: RoundedRectangle(cornerRadius: ArcadePulseTheme.surfaceRadius))
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("creator.profile.header")

                            Text("Published games")
                                .font(.system(.title2, design: .rounded).weight(.bold))
                            if profile.posts.isEmpty {
                                ContentUnavailableView(
                                    "No public games yet",
                                    systemImage: "gamecontroller",
                                    description: Text("Published games from this creator will appear here."))
                            } else {
                                LazyVStack(spacing: 12) {
                                    ForEach(profile.posts) { game in
                                        creatorGameRow(game)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: horizontalSizeClass == .regular ? 850 : 540)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 20)
                    }
                    .accessibilityIdentifier("creator.profile.games")
                } else {
                    VStack(spacing: 14) {
                        ContentUnavailableView(
                            "Couldn't load creator",
                            systemImage: "person.crop.circle.badge.exclamationmark",
                            description: Text(errorMessage ?? "Please try again."))
                        Button("Try again") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .foregroundStyle(.white)
            .background(ArcadePulseTheme.canvas)
            .preferredColorScheme(.dark)
            .navigationTitle("Creator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await load() }
            .fullScreenCover(item: $playerRequest) { request in
                PixiPlayerSheet(gameID: request.gameID, title: request.title)
            }
        }
    }

    private func creatorMetric(_ label: String, value: Int) -> some View {
        VStack(spacing: 5) {
            Text(value.formatted())
                .font(.headline.weight(.bold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(ArcadePulseTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .accessibilityElement(children: .combine)
    }

    private func creatorGameRow(_ game: FeedGame) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                LinearGradient(colors: ArcadePulseTheme.fallbackPalette(gameID: game.id),
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if let poster = game.previewPosterURL, let url = URL(string: poster) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                        } else {
                            Image(systemName: "gamecontroller.fill")
                                .font(.title3)
                        }
                    }
                } else {
                    Image(systemName: "gamecontroller.fill")
                        .font(.title3)
                        .accessibilityLabel("Gameplay preview unavailable")
                }
            }
            .frame(width: 112, height: 116)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(game.title)
                    .font(.headline)
                    .lineLimit(2)
                if let caption = game.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(ArcadePulseTheme.textSecondary)
                        .lineLimit(3)
                }
                if let parent = game.remixParentID, !parent.isEmpty {
                    Label("Published remix", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(ArcadePulseTheme.neonMagenta)
                }
                Button {
                    playerRequest = PixiPlayerRequest(gameID: game.id, title: game.title)
                } label: {
                    Label("Play game", systemImage: "play.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(minWidth: 110, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(ArcadePulseTheme.playOrangeDeep)
                .accessibilityIdentifier("creator.game.play.\(game.id)")
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ArcadePulseTheme.surface,
                    in: RoundedRectangle(cornerRadius: ArcadePulseTheme.pillRadius))
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
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.headline)
                        .foregroundStyle(ArcadePulseTheme.playOrange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("COMMENTS ON")
                            .font(.caption2.weight(.bold))
                            .tracking(0.7)
                            .foregroundStyle(ArcadePulseTheme.neonMagenta)
                        Text(game.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text("\(comments.count)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(ArcadePulseTheme.textSecondary)
                        .accessibilityLabel("\(comments.count) loaded comments")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(ArcadePulseTheme.surface)

                if isLoading {
                    ProgressView("Loading comments…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if comments.isEmpty && errorMessage == nil {
                    ContentUnavailableView(
                        "No comments yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Start the conversation about this game."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(comments) { comment in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title2)
                                .foregroundStyle(ArcadePulseTheme.electricViolet)
                                .frame(width: 32, height: 32)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(comment.user_id)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(ArcadePulseTheme.neonMagenta)
                                Text(comment.body)
                                    .font(.body)
                                    .foregroundStyle(.white)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 8)
                        .listRowBackground(ArcadePulseTheme.surface.opacity(0.55))
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
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .accessibilityIdentifier("comments.list")
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .accessibilityIdentifier("comments.error")
                }
            }
            .background(ArcadePulseTheme.canvas)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 10) {
                    TextField("Add a comment…", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .submitLabel(.send)
                        .accessibilityIdentifier("comments.composer")
                    if isSubmitting {
                        ProgressView()
                            .frame(width: 44, height: 44)
                            .accessibilityLabel("Sending comment")
                    } else if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            Task { await submit() }
                        } label: {
                            Image(systemName: "paperplane.fill")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ArcadePulseTheme.playOrangeDeep)
                        .accessibilityLabel("Send comment")
                        .accessibilityIdentifier("comments.send")
                    } else {
                        // Disabled SwiftUI icon-buttons were misreported as enabled
                        // by XCUI in the sheet's safe-area inset. Make the unavailable
                        // action structurally non-interactive, not just greyed out.
                        Image(systemName: "paperplane.fill")
                            .frame(width: 44, height: 44)
                            .foregroundStyle(.white.opacity(0.42))
                            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("Enter a comment to enable Send")
                            .accessibilityIdentifier("comments.send.unavailable")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(ArcadePulseTheme.surface)
            }
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .preferredColorScheme(.dark)
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
