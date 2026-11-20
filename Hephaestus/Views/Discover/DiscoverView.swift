import AuthenticationServices
import AVFoundation
import Combine
import Foundation
import Network
import PhotosUI
import SwiftUI
import UIKit

/// Source-owned minimum for actual native Discover toolbar Button labels.
/// An external ToolbarItem wrapper's size is NOT its accessible hitbox.
enum DiscoverToolbarActionLayout {
    static let minimumHitSize: CGFloat = ArcadePulseTheme.minimumTarget
}

/// A real feed preference toggle must have a usable backend topic label.
/// Preserve the user's exact previously persisted muted key so an existing
/// choice can still be removed without changing its serialized value.
enum FeedPreferenceTopicPolicy {
    private static func usableLabel(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }

    static func availableTopics(
        feedTopics: [[String]], mutedTopics: Set<String>
    ) -> [String] {
        let realTopics = feedTopics.lazy.flatMap { $0 }.compactMap { raw -> String? in
            guard usableLabel(raw) else { return nil }
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let previouslyMuted = mutedTopics.filter(usableLabel)
        return Array(Set(Array(realTopics) + Array(previouslyMuted))).sorted()
    }
}

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

    /// Expire only the presently owned request. Revoke its generation BEFORE
    /// canceling the transport; a late task/cancellation callback cannot
    /// replace a newer Retry result or re-hide the recovery actions.
    @discardableResult
    func expireIfCurrent(_ requestGeneration: Int) -> Bool {
        guard isCurrent(requestGeneration) else { return false }
        generation += 1
        activeRequest?.cancel()
        activeRequest = nil
        return true
    }
}

/// The system's floating compact-height iPhone tabs occupy the lower
/// 64pt of the genuine 874x402 landscape window. A bottom-of-card Play CTA
/// must be able to scroll fully ABOVE them instead of hiding under chrome.
/// Do not reserve this extra space on portrait iPhones or any iPad layout.
enum FeedGridTabClearancePolicy {
    static let compactPhoneTrailingInset: CGFloat = 72

    static func trailingInset(isPhone: Bool, isCompactHeight: Bool) -> CGFloat {
        isPhone && isCompactHeight ? compactPhoneTrailingInset : 0
    }
}

/// A submitted real game title must stay filtered after UIKit collapses the
/// native searchable drawer during device rotation / ScrollView swipes.
/// Drafting a new query takes precedence; explicit Clear search ends it.
enum FeedCommittedSearchPolicy {
    static func effectiveQuery(draft: String, committed: String) -> String {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? committed.trimmingCharacters(in: .whitespacesAndNewlines)
                               : trimmed
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

/// A guest request from nested Creator details can change the app's Profile
/// destination ONLY after the inner sheet and outer directory both dismiss.
/// Normal Done and repeated callbacks are never sign-in navigation.
struct CreatorNestedGuestSignInGate {
    private(set) var isAwaitingDirectoryDismiss = false

    mutating func requestAfterInnerCreatorDismiss() -> Bool {
        guard !isAwaitingDirectoryDismiss else { return false }
        isAwaitingDirectoryDismiss = true
        return true
    }

    mutating func consumeAfterDirectoryDismiss() -> Bool {
        guard isAwaitingDirectoryDismiss else { return false }
        isAwaitingDirectoryDismiss = false
        return true
    }
}

/// Backend-backed social feeds use the verified bearer session when present.
/// UI subject decoding is only for self-action affordances; the backend authorizes every request.
struct DiscoverView: View {
    // A live-feed outage must not trap the user on an empty swipe stage.
    // The host owns navigation, so this is an actual route to Library,
    // never a substitute game list or a fabricated preview.
    let onOpenLibrary: (() -> Void)?
    let onOpenProfile: (() -> Void)?
    init(onOpenLibrary: (() -> Void)? = nil,
         onOpenProfile: (() -> Void)? = nil) {
        self.onOpenLibrary = onOpenLibrary
        self.onOpenProfile = onOpenProfile
    }

    // One functional set of recovery actions across all orientations.
    // Compact iPhone landscape lays these out side by side so neither button
    // disappears underneath the persistent bottom tab navigation.
    private var feedRecoveryRetry: some View {
        Button {
            Task { await load() }
        } label: {
            Label("Try again", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(ArcadePulseRecoveryButtonStyle())
        .accessibilityIdentifier("feed.error.retry")
    }

    @ViewBuilder private var feedRecoveryLibrary: some View {
        if let onOpenLibrary {
            Button(action: onOpenLibrary) {
                Label("Open Library", systemImage: "bookmark")
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .tint(ArcadePulseTheme.neonMagenta)
            .accessibilityIdentifier("feed.error.library")
        }
    }

    /// Genuine Retry and Library routes while a live request is slow.
    /// Never misreport informational waiting as an outage or a playable game.
    private var feedLoadingRetry: some View {
        Button {
            Task { await load() }
        } label: {
            Label("Retry loading", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(ArcadePulseRecoveryButtonStyle())
        .accessibilityIdentifier("feed.retryLoading")
    }

    @ViewBuilder private var feedSlowLibrary: some View {
        if let onOpenLibrary {
            Button(action: onOpenLibrary) {
                Label("Open Library", systemImage: "bookmark")
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .tint(ArcadePulseTheme.neonMagenta)
            .accessibilityIdentifier("feed.loading.library")
        }
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
    // Transport errors are rendered in the empty-feed recovery surface.
    // Social-action failures need their own visible alert while the live
    // game remains on screen; otherwise users get no response to a failed tap.
    @State private var socialActionError: String?
    @State private var didPresentSocialErrorFixture = false
    @State private var socialMutationGate = FeedSocialMutationGate()
    @State private var socialMutationEpoch = 0
    @State private var isLoading = false
    @State private var isSlowLoading = false
    @State private var searchText = ""
    // The native searchable draft can disappear on rotation; keep the actual
    // user-submitted filter until they explicitly clear it.
    @State private var committedSearchQuery = ""
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
    @State private var openProfileAfterCreatorDismiss = false
    @State private var nestedGuestSignInGate = CreatorNestedGuestSignInGate()
    @State private var settledForYouGameID: String?
    @State private var resultPresentation: PlayerResultPresentation?

    private var activeSearchQuery: String {
        FeedCommittedSearchPolicy.effectiveQuery(
            draft: searchText, committed: committedSearchQuery)
    }

    private var visibleGames: [FeedGame] {
        let query = activeSearchQuery
        guard !query.isEmpty else { return games }
        return games.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var availableTopics: [String] {
        FeedPreferenceTopicPolicy.availableTopics(
            feedTopics: games.compactMap { $0.topics },
            mutedTopics: mutedTopics
        )
    }

    private var feedGridColumns: [GridItem] {
        if horizontalSizeClass == .regular {
            return [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
        }
        return [GridItem(.flexible())]
    }

    private var showsImmersivePager: Bool {
        ForYouPageLayout.shouldShowImmersivePager(
            searchText: activeSearchQuery, hasGames: !visibleGames.isEmpty)
    }

    // The iPhone feed is content-first in both orientations. Search and
    // tablet-wide layouts still expose the segmented picker; portrait phone
    // scopes remain available in the labeled, 44pt toolbar menu.
    private var usesCompactFeedScopeMenu: Bool {
        ForYouPageLayout.prefersCompactScopeMenu(
            verticalSizeClass: verticalSizeClass,
            horizontalSizeClass: horizontalSizeClass,
            searchText: activeSearchQuery)
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
                compactSearchDraft = activeSearchQuery
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
        committedSearchQuery = searchText
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
                    // Keep real loading/error actions reachable at Accessibility XXXL.
                    // A decorative hero above a failed request previously pushed Retry
                    // below the iPhone viewport, leaving the feed unusable.
                    if !games.isEmpty || (!isLoading && errorMessage == nil) {
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
                    }

                    // A real title query must survive UIKit's native
                    // search drawer collapse until explicit user clearing.
                    if !committedSearchQuery.isEmpty {
                        HStack {
                            Spacer(minLength: 0)
                            Button {
                                searchText = ""
                                committedSearchQuery = ""
                            } label: {
                                Label("Clear search", systemImage: "xmark.circle")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(minHeight: ArcadePulseTheme.minimumTarget)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("feed.grid.clearSearch")
                        }
                    }

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
                            // A delayed response is not necessarily an
                            // outage. Retain real transport while offering
                            // a genuine Library escape after the early hint.
                            if isSlowLoading {
                                Text(onOpenLibrary == nil
                                     ? "Still connecting to the live feed. You can retry."
                                     : "Still connecting to the live feed. You can retry or open Library.")
                                    .font(.subheadline)
                                    .foregroundStyle(ArcadePulseTheme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("feed.loading.slow")
                            }
                            if verticalSizeClass == .compact {
                                HStack(spacing: 12) {
                                    feedLoadingRetry
                                    if isSlowLoading { feedSlowLibrary }
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 12) {
                                    feedLoadingRetry
                                    if isSlowLoading { feedSlowLibrary }
                                }
                            }

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
                        // iPhone compact landscape has a short safe-area stage.
                        // Keep both real recovery actions above the fold instead
                        // of letting an ornamental icon and extra prose push
                        // Library below the immediately reachable viewport.
                        VStack(spacing: verticalSizeClass == .compact ? 10 : 16) {
                            if verticalSizeClass != .compact {
                                Image(systemName: "wifi.exclamationmark")
                                    .font(.system(size: 38, weight: .medium))
                                    .foregroundStyle(ArcadePulseTheme.neonMagenta)
                                    .frame(width: 76, height: 76)
                                    .background(ArcadePulseTheme.electricViolet.opacity(0.16),
                                                in: RoundedRectangle(cornerRadius: 20))
                                    .accessibilityHidden(true)
                            }
                            Text("Couldn't load the feed")
                                .font(.system(verticalSizeClass == .compact ? .headline : .title2,
                                              design: .rounded).weight(.bold))
                                .foregroundStyle(.white)
                                .accessibilityAddTraits(.isHeader)
                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundStyle(ArcadePulseTheme.textSecondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            if verticalSizeClass != .compact {
                                Text("You can still check Library for games you've saved.")
                                    .font(.subheadline)
                                    .foregroundStyle(ArcadePulseTheme.textSecondary)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if verticalSizeClass == .compact {
                                HStack(spacing: 12) {
                                    feedRecoveryRetry
                                    feedRecoveryLibrary
                                }
                            } else {
                                feedRecoveryRetry
                                feedRecoveryLibrary
                            }
                        }
                        .padding(verticalSizeClass == .compact ? 14 : 24)
                        .frame(maxWidth: 520)
                        .background(ArcadePulseTheme.surface,
                                    in: RoundedRectangle(cornerRadius: ArcadePulseTheme.surfaceRadius))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, verticalSizeClass == .compact ? 8 : 32)
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
                        if nextCursor != nil && activeSearchQuery.isEmpty {
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
.padding(.bottom, 28 + FeedGridTabClearancePolicy.trailingInset(
                    isPhone: UIDevice.current.userInterfaceIdiom == .phone,
                    isCompactHeight: verticalSizeClass == .compact
                ))
                        }
                        // Real filtered grid ScrollView owner after rotation:
                        // never swipe the floating native tab bar.
                        .accessibilityIdentifier("feed.grid.scroll")
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
            .onSubmit(of: .search) {
                committedSearchQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
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
                            .frame(width: DiscoverToolbarActionLayout.minimumHitSize,
                                   height: DiscoverToolbarActionLayout.minimumHitSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Tune feed recommendations")
                    .accessibilityIdentifier("feed.toolbar.preferences")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isCreatorDiscoveryPresented = true
                    } label: {
                        Image(systemName: "person.2")
                            .frame(width: DiscoverToolbarActionLayout.minimumHitSize,
                                   height: DiscoverToolbarActionLayout.minimumHitSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Discover creators")
                    .accessibilityIdentifier("feed.toolbar.creators")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: DiscoverToolbarActionLayout.minimumHitSize,
                                   height: DiscoverToolbarActionLayout.minimumHitSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh games")
                    .accessibilityIdentifier("feed.toolbar.refresh")
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
                        pendingSocialMutations: Set(socialMutationGate.pending.keys),
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
                            if let id = game.ownerID,
                               ForYouActionOwnershipPolicy.canOfferCreatorBlock(
                                   ownerID: id, viewerID: BackendConfig.currentUserID
                               ) { Task { await blockCreator(id) } }
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
                                    canFollowCreator: ForYouPageLayout.hasNavigableCreator(ownerID: game.ownerID) && game.ownerID != BackendConfig.currentUserID,
                                    onPlay: { play(game) },
                                    onToggleSaved: { toggleSaved(game) },
                                    onToggleLike: { toggleLike(game) },
                                    onToggleFollow: { if let id = game.ownerID { Task { await toggleFollow(id) } } },
                                    onOpenComments: { commentsGame = game },
                                    onOpenCreator: { if let id = game.ownerID { profileRequest = CreatorProfileRequest(id: id) } },
                                    onReport: { reportingGame = game },
                                    onBlockCreator: {
                                        if let id = game.ownerID,
                                           ForYouActionOwnershipPolicy.canOfferCreatorBlock(
                                               ownerID: id, viewerID: BackendConfig.currentUserID
                                           ) { Task { await blockCreator(id) } }
                                    },
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
            .onReceive(NotificationCenter.default.publisher(
                for: .hephaestusBackendSessionDidChange
            )) { _ in
                // Viewer-specific social status and pending writes are not
                // reusable on sign-out or account replacement.
                socialMutationEpoch &+= 1
                socialMutationGate.revokeAll()
                savedGameIDs.removeAll()
                likedGameIDs.removeAll()
                followedCreatorIDs.removeAll()
                mutedTopics.removeAll()
                games.removeAll()
                settledForYouGameID = nil
                nextCursor = nil
                loadMoreError = nil
                errorMessage = nil
                socialActionError = nil
                FeedPreviewPlayback.shared.stop()
                Task { await load() }
            }
            .onChange(of: games.count) { _, count in
                // A display-only failure fixture for native iPhone/iPad UI
                // review. The game must still be from the live backend;
                // never inject a game or mutate the social relationship.
                if count > 0, !didPresentSocialErrorFixture,
                   ProcessInfo.processInfo.arguments.contains(
                       "--ui-test-social-action-error-state") {
                    didPresentSocialErrorFixture = true
                    socialWriteFailure("Saving this game")
                }
            }
            .alert("Couldn't update this action", isPresented: Binding(
                get: { socialActionError != nil },
                set: { if !$0 { socialActionError = nil } }
            )) {
                Button("OK", role: .cancel) { socialActionError = nil }
            } message: {
                Text(socialActionError ?? "Try again.")
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
                    errorMessage = FeedErrorPresentation.message(for: URLError(.secureConnectionFailed))
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
            .modifier(ArcadePulseGameDetailsPresentation(selection: $detailGame))
            .sheet(item: $reportingGame) { game in
                ReportGameSheet(game: game)
            }
            .sheet(item: $profileRequest, onDismiss: {
                if openProfileAfterCreatorDismiss {
                    openProfileAfterCreatorDismiss = false
                    // Only the host owns native Profile navigation; never
                    // replace it with an inert in-sheet authentication CTA.
                    onOpenProfile?()
                }
            }) { request in
                CreatorProfileSheet(
                    creatorID: request.id,
                    onRequestSignIn: onOpenProfile == nil ? nil : {
                        openProfileAfterCreatorDismiss = true
                        profileRequest = nil
                    })
            }
            .sheet(isPresented: $isCreatorDiscoveryPresented, onDismiss: {
                // Host Profile is a root destination, never presented under
                // an active nested Creator or Directory sheet.
                if nestedGuestSignInGate.consumeAfterDirectoryDismiss() {
                    onOpenProfile?()
                }
            }) {
                CreatorDiscoverySheet(
                    onRequestSignIn: onOpenProfile == nil ? nil : {
                        // Only after inner Creator onDismiss may the outer
                        // directory begin dismissing. No arbitrary delay.
                        if nestedGuestSignInGate.requestAfterInnerCreatorDismiss() {
                            isCreatorDiscoveryPresented = false
                        }
                    }
                )
            }
            .sheet(isPresented: $isFeedPreferencesPresented) {
                FeedPreferencesSheet(
                    availableTopics: availableTopics,
                    selectedTopics: mutedTopics,
                    onSave: { topics in await saveMutedTopics(topics) },
                    onReset: { await resetFeedPreferences() }
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
                loadMoreError = FeedErrorPresentation.paginationMessage(for: error)
            }
        }
    }

    private func socialWriteFailure(_ action: String, error: Error? = nil) {
        socialActionError = FeedSocialErrorPresentation.message(
            action: action, error: error,
            signedIn: !BackendConfig.currentUserID.isEmpty)
    }

    private func toggleSaved(_ game: FeedGame) {
        guard let lease = socialMutationGate.begin(.save, id: game.id) else { return }
        let shouldSave = !savedGameIDs.contains(game.id)
        let viewerID = BackendConfig.currentUserID
        let epoch = socialMutationEpoch
        Task {
            defer { socialMutationGate.finish(.save, id: game.id, lease: lease) }
            do {
                try await BackendAPI.shared.setSaved(game.id, saved: shouldSave)
                guard epoch == socialMutationEpoch,
                      viewerID == BackendConfig.currentUserID else { return }
                if shouldSave { savedGameIDs.insert(game.id) } else { savedGameIDs.remove(game.id) }
                UserDefaults.standard.set(savedGameIDs.sorted(), forKey: "hephaestus.savedGames")
                if shouldSave {
                    await BackendAPI.shared.trackSocialEvent(gameID: game.id, kind: "save")
                }
            } catch {
                guard epoch == socialMutationEpoch,
                      viewerID == BackendConfig.currentUserID else { return }
                socialWriteFailure("Saving this game", error: error)
            }
        }
    }

    private func toggleLike(_ game: FeedGame) {
        guard let lease = socialMutationGate.begin(.like, id: game.id) else { return }
        let shouldLike = !likedGameIDs.contains(game.id)
        let viewerID = BackendConfig.currentUserID
        let epoch = socialMutationEpoch
        Task {
            defer { socialMutationGate.finish(.like, id: game.id, lease: lease) }
            do {
                try await BackendAPI.shared.setReaction(
                    game.id, reaction: shouldLike ? "like" : nil)
                guard epoch == socialMutationEpoch,
                      viewerID == BackendConfig.currentUserID else { return }
                if shouldLike { likedGameIDs.insert(game.id) } else { likedGameIDs.remove(game.id) }
            } catch {
                guard epoch == socialMutationEpoch,
                      viewerID == BackendConfig.currentUserID else { return }
                socialWriteFailure("Liking this game", error: error)
            }
        }
    }

    private func toggleFollow(_ creatorID: String) async {
        guard let lease = socialMutationGate.begin(.follow, id: creatorID) else { return }
        defer { socialMutationGate.finish(.follow, id: creatorID, lease: lease) }
        let viewerID = BackendConfig.currentUserID
        let epoch = socialMutationEpoch
        let shouldFollow = !followedCreatorIDs.contains(creatorID)
        do {
            try await BackendAPI.shared.setFollowing(creatorID, following: shouldFollow)
            guard epoch == socialMutationEpoch,
                  viewerID == BackendConfig.currentUserID else { return }
            if shouldFollow { followedCreatorIDs.insert(creatorID) }
            else { followedCreatorIDs.remove(creatorID) }
            if let gameID = games.first(where: { $0.ownerID == creatorID })?.id {
                await BackendAPI.shared.trackSocialEvent(gameID: gameID, kind: "follow")
            }
            guard epoch == socialMutationEpoch,
                  viewerID == BackendConfig.currentUserID else { return }
            await load()
        } catch {
            guard epoch == socialMutationEpoch,
                  viewerID == BackendConfig.currentUserID else { return }
            socialWriteFailure("Following this creator", error: error)
        }
    }

    private func blockCreator(_ creatorID: String) async {
        guard ForYouActionOwnershipPolicy.canOfferCreatorBlock(
            ownerID: creatorID, viewerID: BackendConfig.currentUserID
        ) else { return }
        let viewerID = BackendConfig.currentUserID
        let epoch = socialMutationEpoch
        do {
            try await BackendAPI.shared.blockCreator(creatorID, blocked: true)
            guard epoch == socialMutationEpoch,
                  viewerID == BackendConfig.currentUserID else { return }
            games.removeAll { $0.ownerID == creatorID }
            repairPagerSelection()
        } catch {
            guard epoch == socialMutationEpoch,
                  viewerID == BackendConfig.currentUserID else { return }
            socialWriteFailure("Blocking this creator", error: error)
        }
    }

    private func markNotInterested(_ game: FeedGame) async {
        let viewerID = BackendConfig.currentUserID
        let epoch = socialMutationEpoch
        do {
            try await BackendAPI.shared.markNotInterested(gameID: game.id)
            guard epoch == socialMutationEpoch,
                  viewerID == BackendConfig.currentUserID else { return }
            games.removeAll { $0.id == game.id }
            repairPagerSelection()
        } catch {
            guard epoch == socialMutationEpoch,
                  viewerID == BackendConfig.currentUserID else { return }
            socialWriteFailure("Saving your feedback", error: error)
        }
    }

    private func repairPagerSelection() {
        if let settledForYouGameID, games.contains(where: { $0.id == settledForYouGameID }) { return }
        settledForYouGameID = games.first?.id
    }

    private func saveMutedTopics(_ topics: [String]) async -> Bool {
        // Native UI-only failure simulation. Never alter backend preferences
        // to exercise a declined request or fabricate feed/game content.
        if ProcessInfo.processInfo.arguments.contains(
            "--ui-test-feed-preferences-failure-state") { return false }
        let epoch = socialMutationEpoch
        let viewer = BackendConfig.currentUserID
        do {
            try await BackendAPI.shared.setMutedTopics(topics)
            guard epoch == socialMutationEpoch,
                  viewer == BackendConfig.currentUserID else { return false }
            mutedTopics = Set(topics.map { $0.lowercased() })
            // An acknowledged mutation can close the modal immediately;
            // the subsequent feed refresh must not block its confirmation.
            Task { await load() }
            return true
        } catch {
            // The sheet owns its error text and stays open; a presenting
            // feed alert can be lost behind a dismissing modal.
            return false
        }
    }

    private func resetFeedPreferences() async -> Bool {
        if ProcessInfo.processInfo.arguments.contains(
            "--ui-test-feed-preferences-failure-state") { return false }
        let epoch = socialMutationEpoch
        let viewer = BackendConfig.currentUserID
        do {
            try await BackendAPI.shared.resetFeedPreferences()
            guard epoch == socialMutationEpoch,
                  viewer == BackendConfig.currentUserID else { return false }
            mutedTopics.removeAll()
            Task { await load() }
            return true
        } catch {
            return false
        }
    }

    private func load() async {
        let requestedScope = selectedFeed
        // Native tests can stall only the HTTP transport, never inject a
        // success response, game card, creator, screenshot or media asset.
        #if DEBUG
        let testingEarlySlowHint = ProcessInfo.processInfo.arguments.contains(
            "--ui-test-stalled-feed-early-hint"
        )
        let testingStalledTransport = testingEarlySlowHint ||
            ProcessInfo.processInfo.arguments.contains("--ui-test-stalled-feed")
        #else
        let testingEarlySlowHint = false
        let testingStalledTransport = false
        #endif
        let (generation, request) = feedRequestCoordinator.begin {
            if testingStalledTransport {
                try await Task.sleep(for: .seconds(120))
                throw URLError(.timedOut)
            }
            return try await BackendAPI.shared.fetchFeed(scope: requestedScope)
        }
        isLoading = true
        isSlowLoading = false
        errorMessage = nil

        // Nonterminal hint: keep the genuine request running to its own
        // hard deadline. Scope and request ownership prevent stale callbacks.
        let slowHint = Task { @MainActor in
            do {
                try await Task.sleep(for:
                    testingStalledTransport ? .milliseconds(650) : .seconds(15))
            } catch { return }
            guard FeedSlowLoadingPolicy.canShowLibrary(
                isLoading: isLoading,
                hasGames: !games.isEmpty,
                ownsRequest: feedRequestCoordinator.isCurrent(generation),
                matchesScope: requestedScope == selectedFeed
            ) else { return }
            isSlowLoading = true
        }

        // Production retains the original 45s bounded transport budget.
        // Native DEBUG-only terminal-stall tests get 10s per attempt:
        // XCUITest sometimes needs several seconds to observe a freshly
        // restarted real request; a 3s second deadline races that assertion.
        let watchdog = Task { @MainActor in
            do {
                try await Task.sleep(for:
                    testingEarlySlowHint ? .seconds(70) :
                    (testingStalledTransport ? .seconds(10) : .seconds(45)))
            } catch { return }
            guard isLoading, games.isEmpty,
                  requestedScope == selectedFeed,
                  feedRequestCoordinator.expireIfCurrent(generation) else { return }
            isLoading = false
            isSlowLoading = false
            errorMessage =
                "The game feed is taking too long to load. Try again or open Library."
        }
        defer {
            slowHint.cancel()
            watchdog.cancel()
            if feedRequestCoordinator.isCurrent(generation) {
                isLoading = false
                isSlowLoading = false
                feedRequestCoordinator.finishIfCurrent(generation)
            }
        }
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
            isSlowLoading = false

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
                errorMessage = FeedErrorPresentation.message(for: error)
            }
        }
    }
}

/// A slow-loading Library escape is presentational only: never create a
/// new game, authorize a media preview or alter request ownership.
enum FeedSlowLoadingPolicy {
    static func canShowLibrary(
        isLoading: Bool, hasGames: Bool,
        ownsRequest: Bool, matchesScope: Bool
    ) -> Bool {
        isLoading && !hasGames && ownsRequest && matchesScope
    }
}

/// User-facing Discover error copy. Never claim the feed loaded, and avoid
/// surfacing raw TLS/transport jargon as the primary recovery explanation.
/// The UI still exposes Retry and the actual saved-game Library route.
enum FeedErrorPresentation {
    /// Only the cursor request failed. Keep the settled real post on screen,
    /// expose the existing Retry, and never surface transport descriptions
    /// that could contain backend hostnames, paths, bearer data, or TLS jargon.
    static func paginationMessage(for error: Error) -> String {
        "Couldn't load more games. " + message(for: error)
    }

    static func message(for error: Error) -> String {
        switch (error as? URLError)?.code {
        case .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot:
            return "The game service couldn't establish a secure connection. Check your network and try again."
        case .notConnectedToInternet, .networkConnectionLost:
            return "You seem to be offline. Check your internet connection and try again."
        case .timedOut:
            return "The game service is taking too long to respond. Try again."
        default:
            return "The game feed isn't available right now. Try again in a moment."
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

/// Keep system sharing anchored to a mounted feed view. Embedding ShareLink
/// directly inside a SwiftUI Menu can dismiss its presenter before the
/// UIActivityViewController appears on some iOS releases.
private struct ArcadePulseGameShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
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
    let isSavePending: Bool
    let isLikePending: Bool
    let isFollowPending: Bool
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
    let onOpenAccessibleActions: () -> Void
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
    // When no approved media exists, make the blank stage feel intentionally
    // designed, but NEVER present a made-up screenshot as gameplay. All copy
    // comes from the live game; the fallback is visually distinct from media.
    private var unavailablePreview: some View {
        // The feed footer already displays the game title and Play action.
        // Keep fallback content short and above that footer, especially for
        // long localized titles and compact landscape.
        GeometryReader { geometry in
            let condensed = verticalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize
            VStack(spacing: condensed ? 6 : 10) {
                ZStack {
                    Circle()
                        .strokeBorder(.white.opacity(0.20), lineWidth: 1)
                        .frame(width: condensed ? 74 : 110, height: condensed ? 74 : 110)
                    Circle()
                        .fill(.white.opacity(0.07))
                        .frame(width: condensed ? 62 : 88, height: condensed ? 62 : 88)
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: condensed ? 28 : 40, weight: .medium))
                }
                Text("Preview unavailable")
                    .font(condensed ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .lineLimit(2)
                if !condensed {
                    Text("Tap Play now to try the real game")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                }
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .frame(maxWidth: min(320, max(120, geometry.size.width - 32)))
            .position(x: geometry.size.width / 2,
                      y: geometry.size.height * (condensed ? 0.34 : 0.32))
        }
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
                // Do NOT place an opaque black surface over the genuine poster
                // before the clip's first video frame exists. A new version
                // of the same game must also create a fresh readiness lease.
                FeedPreviewSurface(
                    player: previewPlayback.player,
                    onReadyForDisplay: { [generation = previewPlayback.presentationGeneration] ready in
                        previewPlayback.reportDisplayReadiness(
                            gameID: game.id, generation: generation, ready: ready)
                    }
                )
                .id(previewPlayback.presentationGeneration)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            hasPreviewMedia: (loadedPosterURL != nil && loadedPosterURL == game.previewPosterURL) ||
                FeedPreviewPolicy.hasDisplayReadyClip(
                    activeGameID: previewPlayback.activeGameID,
                    displayedGameID: previewPlayback.displayedGameID,
                    expectedGameID: game.id
                )
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

    // A network lease suppresses duplicate taps, but suppression without
    // feedback feels like an unresponsive control. Keep progress visible,
    // descriptive to VoiceOver and at least as tappable-sized as the rail.
    private func pendingAction(_ text: String, key: String, vertical: Bool) -> some View {
        VStack(spacing: 3) {
            ProgressView()
                .tint(.white)
                .controlSize(.small)
            Text(text)
                .font(.caption2.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(minWidth: 48, minHeight: vertical ? 58 : 44)
        .foregroundStyle(.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text + ", in progress")
        .accessibilityIdentifier("feed.social.pending." + key)
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
        if isSavePending {
            pendingAction(isSaved ? "Removing…" : "Saving…", key: "save", vertical: vertical)
        } else {
            iconAction(isSaved ? "bookmark.fill" : "bookmark",
                       label: isSaved ? "Remove from library" : "Save game",
                       caption: vertical ? "Save" : nil, action: onToggleSaved)
        }
        if isLikePending {
            pendingAction(isLiked ? "Unliking…" : "Liking…", key: "like", vertical: vertical)
        } else {
            iconAction(isLiked ? "heart.fill" : "heart",
                       label: isLiked ? "Unlike game" : "Like game",
                       caption: vertical ? "Like" : nil, action: onToggleLike)
        }
        iconAction("bubble.right", label: "View comments",
                   caption: vertical ? "Comment" : nil, action: onOpenComments)
        Menu {
            Button("Game details", systemImage: "info.circle", action: onOpenDetails)
            Button("Report game", role: .destructive, action: onReport)
            Button("Not interested", action: onNotInterested)
            if ForYouActionOwnershipPolicy.canOfferCreatorBlock(
                ownerID: game.ownerID, viewerID: BackendConfig.currentUserID
            ) {
                Button("Block creator", role: .destructive, action: onBlockCreator)
            }
        } label: {
            ArcadePulseActionGlyph(symbol: "ellipsis", caption: vertical ? "More" : nil)
        }
        .foregroundStyle(.white)
        .accessibilityLabel("More game actions")
        .accessibilitySortPriority(70)
        ShareLink(item: shareURL) {
            ArcadePulseActionGlyph(symbol: "square.and.arrow.up",
                                   caption: vertical ? "Share" : nil)
        }
        .simultaneousGesture(TapGesture().onEnded {
            Task { await BackendAPI.shared.trackSocialEvent(gameID: game.id, kind: "share") }
        })
        .foregroundStyle(.white)
        .accessibilityLabel("Share \(game.title)")
    }

    /// A labeled menu is critical for low-vision users who enlarge text but
    /// do not use VoiceOver. Do not force them to interpret five unlabeled
    /// symbols or let a tall rail obscure the one-post preview/Play target.
    // At Accessibility XXXL, an anchored SwiftUI Menu can disappear or fail
    // to reopen while its native menu controller is dismissing. A real,
    // explicitly dismissible native sheet keeps the same social actions
    // reachable across repeated openings, rotation and Dynamic Type.
    private func accessibleSocialMenu(vertical: Bool) -> some View {
        Button(action: onOpenAccessibleActions) {
            Group {
                if vertical {
                    VStack(spacing: 3) {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.title2)
                        Text("Actions").font(.caption.weight(.bold))
                    }
                    .frame(minWidth: 88, minHeight: 68)
                } else {
                    Label("Actions", systemImage: "ellipsis.circle.fill")
                        .font(.headline)
                        .frame(minWidth: 112, minHeight: 48)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.black.opacity(0.52), in: Capsule())
        .accessibilityLabel("Game actions")
        .accessibilityIdentifier("feed.actions.accessible")
    }

    @ViewBuilder private func socialActions(vertical: Bool) -> some View {
        if ArcadePulseActionGlyph.usesAccessibleMenu(for: dynamicTypeSize) {
            accessibleSocialMenu(vertical: vertical)
        } else if vertical {
            VStack(spacing: 5) { socialActionButtons(vertical: true) }
                .padding(4)
                .background(.black.opacity(0.3), in: Capsule())
                .accessibilityIdentifier("feed.actionRail")
        } else {
            HStack(spacing: 8) { socialActionButtons(vertical: false) }
        }
    }

    private func detailsOverlay(bottomInset: CGFloat, shortViewport: Bool,
                                compactLandscapeTitleWidth: CGFloat? = nil) -> some View {
        // Stage Manager can retain a regular vertical size class even when
        // the usable window is short. Preserve reachable Play and actions.
        let isCompact = shortViewport || verticalSizeClass == .compact ||
            dynamicTypeSize >= .xxLarge
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
                // On short iPhone landscape screens a long bilingual game title
                // previously crossed the centered "Preview unavailable" text.
                // Give the real title a legible left-hand column without
                // hiding it, shrinking the Play CTA, or shifting fake media.
                .frame(maxWidth: compactLandscapeTitleWidth, alignment: .leading)
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
            // Only real, navigable creator IDs deserve a profile button.
            // A missing owner was previously shown as "Mini game" with a
            // dead "View profile for Mini game" VoiceOver action.
            if !isCompact, ForYouPageLayout.hasNavigableCreator(ownerID: game.ownerID) {
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
                        HStack(spacing: 6) {
                            if isFollowPending {
                                ProgressView().tint(.white).controlSize(.small)
                            }
                            Label(isFollowPending ? "Updating…" :
                                  (isFollowingCreator ? "Following" : "Follow"),
                                  systemImage: isFollowingCreator ? "person.fill.checkmark" : "person.badge.plus")
                                .font(.caption.weight(.bold))
                        }
                        .frame(minHeight: 44)
                        .padding(.horizontal, 10)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .disabled(isFollowPending)
                    .accessibilityLabel(isFollowPending ? "Updating follow" :
                                        (isFollowingCreator ? "Unfollow creator" : "Follow creator"))
                    .accessibilityValue(isFollowPending ? "In progress" : "")
                    .accessibilityIdentifier("feed.creator.follow")
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
                isRegular: isRegular, isAccessibilityText: dynamicTypeSize.isAccessibilitySize,
                isLargeText: dynamicTypeSize >= .xxLarge)
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
                                if !dynamicTypeSize.isAccessibilitySize {
                                    // Keep guidance on the LEADING edge in both
                                    // orientations. The floating landscape scope /
                                    // search / More controls own the top trailing edge;
                                    // putting the hint there obscured those controls
                                    // in original full-screen simulator screenshots.
                                    Label("SWIPE TO EXPLORE", systemImage: "arrow.up.arrow.down")
                                        .font(.caption2.weight(.bold))
                                        .tracking(0.8)
                                        .foregroundStyle(.white.opacity(0.9))
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 8)
                                        .background(.black.opacity(0.28), in: Capsule())
                                        .accessibilityIdentifier("feed.swipeHint")
                                    if isLandscape, let orientation = game.orientationLabel {
                                        Text(orientation)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 8)
                                            .background(.black.opacity(0.4), in: Capsule())
                                            .accessibilityIdentifier("feed.orientation")
                                    }
                                }
                                Spacer(minLength: 0)
                                if !isLandscape && !dynamicTypeSize.isAccessibilitySize,
                                   let orientation = game.orientationLabel {
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
                            detailsOverlay(
                                bottomInset: proxy.safeAreaInsets.bottom,
                                shortViewport: ForYouPageLayout.usesShortIPadViewport(
                                    height: proxy.size.height,
                                    isIPad: UIDevice.current.userInterfaceIdiom == .pad),
                                compactLandscapeTitleWidth: UIDevice.current.userInterfaceIdiom == .phone &&
                                    verticalSizeClass == .compact
                                    ? pageWidth * 0.36 : nil)
                            if verticalSizeClass != .compact &&
                               dynamicTypeSize < .xxLarge &&
                               !ForYouPageLayout.usesShortIPadViewport(
                                   height: proxy.size.height,
                                   isIPad: UIDevice.current.userInterfaceIdiom == .pad) {
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

/// A view replacement in the swipe feed must not erase an Accessibility5
/// action sheet or let it write to a game/account that is no longer selected.
/// The pager, not an individual page with .id(game.id), owns presentation.
enum ForYouActionOwnershipPolicy {
    /// Fail closed in the stable pager even after the original game page
    /// disappears: invalid publisher IDs and authenticated self-Block are
    /// never actionable, including deferred callbacks after sheet dismissal.
    static func canOfferCreatorBlock(ownerID: String?, viewerID: String) -> Bool {
        guard let ownerID else { return false }
        let owner = ownerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty,
              !owner.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return false }
        let viewer = viewerID.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewer.isEmpty || owner != viewer
    }

    static func canPresent(
        requestedGameID: String,
        selectedGameID: String?,
        availableIDs: [String],
        requestedViewerID: String,
        currentViewerID: String,
        requestedRevision: Int,
        currentRevision: Int
    ) -> Bool {
        !requestedGameID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        requestedGameID == selectedGameID &&
        availableIDs.contains(requestedGameID) &&
        requestedViewerID == currentViewerID &&
        requestedRevision == currentRevision
    }
}

private struct ForYouActionsRequest: Identifiable {
    let id: String
    let viewerID: String
    let sessionRevision: Int
}

/// A second destination must start after the native Actions sheet dismisses.
/// No timer-based handoff and no network write on a superseded game or viewer.
private enum ForYouDeferredAction {
    case save, like, comments, details, report, notInterested, blockCreator
}

private struct ForYouDeferredRequest {
    let request: ForYouActionsRequest
    let action: ForYouDeferredAction
}

/// The real public-game action list is presented from the stable pager.
/// Keep the same native rows and handlers, not a new set of fake social data.
private struct ForYouGameActionsSheet: View {
    let game: FeedGame
    let isSaved: Bool
    let isLiked: Bool
    let onDismiss: () -> Void
    let onToggleSaved: () -> Void
    let onToggleLike: () -> Void
    let onOpenComments: () -> Void
    let onShare: () -> Void
    let onOpenDetails: () -> Void
    let onReport: () -> Void
    let onNotInterested: () -> Void
    let onBlockCreator: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Social actions") {
                    Button(isSaved ? "Remove from library" : "Save game",
                           systemImage: isSaved ? "bookmark.fill" : "bookmark",
                           action: onToggleSaved)
                    Button(isLiked ? "Unlike game" : "Like game",
                           systemImage: isLiked ? "heart.fill" : "heart",
                           action: onToggleLike)
                    Button("View comments", systemImage: "bubble.right",
                           action: onOpenComments)
                    Button("Share game", systemImage: "square.and.arrow.up",
                           action: onShare)
                    Button("Game details", systemImage: "info.circle",
                           action: onOpenDetails)
                    Button("Report game", role: .destructive, action: onReport)
                }
                Section("Feed preferences") {
                    Button("Not interested", systemImage: "eye.slash",
                           action: onNotInterested)
                    if ForYouActionOwnershipPolicy.canOfferCreatorBlock(
                        ownerID: game.ownerID, viewerID: BackendConfig.currentUserID
                    ) {
                        Button("Block creator", role: .destructive,
                               action: onBlockCreator)
                    }
                }
            }
            .environment(\.defaultMinListRowHeight, 44)
            .navigationTitle("Game actions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDismiss)
                        .accessibilityIdentifier("feed.actions.dismiss")
                }
            }
        }
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("feed.actions.sheet")
    }
}

private struct ForYouPagerView: View {
    @Binding var settledGameID: String?
    // Diagnostic-only instrumentation: distinguish a gesture that never
    // arrived from one whose direction, or selected-page state, was wrong.
    @State private var diagnosticDragCount = 0
    @State private var diagnosticLastDragY = 0
    @State private var diagnosticLastOffset = 0
    @State private var activeActions: ForYouActionsRequest?
    @State private var queuedAction: ForYouDeferredRequest?
    @State private var queuedShare: ForYouActionsRequest?
    // The presented item is the verified selected game, never a Bool that
    // can outlive its queued request and mount an empty native sheet.
    @State private var activeShare: ForYouActionsRequest?
    @State private var sessionRevision = 0
    let scope: SocialFeedScope
    let games: [FeedGame]
    let savedGameIDs: Set<String>
    let likedGameIDs: Set<String>
    let followedCreatorIDs: Set<String>
    let pendingSocialMutations: Set<FeedSocialMutationGate.Key>
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
            canFollowCreator: ForYouPageLayout.hasNavigableCreator(ownerID: game.ownerID) && game.ownerID != BackendConfig.currentUserID,
            isSavePending: pendingSocialMutations.contains(.init(kind: .save, id: game.id)),
            isLikePending: pendingSocialMutations.contains(.init(kind: .like, id: game.id)),
            isFollowPending: game.ownerID.map {
                pendingSocialMutations.contains(.init(kind: .follow, id: $0))
            } ?? false,
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
            onOpenAccessibleActions: { requestActions(for: game) },
            onImpression: { onImpression(game) }
        )
    }

    private func canPresent(_ request: ForYouActionsRequest) -> Bool {
        ForYouActionOwnershipPolicy.canPresent(
            requestedGameID: request.id,
            selectedGameID: settledGameID,
            availableIDs: games.map(\.id),
            requestedViewerID: request.viewerID,
            currentViewerID: BackendConfig.currentUserID,
            requestedRevision: request.sessionRevision,
            currentRevision: sessionRevision
        )
    }

    private func requestActions(for game: FeedGame) {
        let request = ForYouActionsRequest(
            id: game.id,
            viewerID: BackendConfig.currentUserID,
            sessionRevision: sessionRevision
        )
        guard canPresent(request) else { return }
        activeActions = request
    }

    private func queueAction(_ request: ForYouActionsRequest, _ action: ForYouDeferredAction) {
        guard canPresent(request) else {
            retireActions()
            return
        }
        // Never present a second sheet over the first native dismiss animation.
        queuedShare = nil
        queuedAction = ForYouDeferredRequest(request: request, action: action)
        activeActions = nil
    }

    private func deliverDismissedAction(_ pending: ForYouDeferredRequest) {
        guard canPresent(pending.request),
              let game = games.first(where: { $0.id == pending.request.id }) else {
            return
        }
        switch pending.action {
        case .save: onToggleSaved(game)
        case .like: onToggleLike(game)
        case .comments: onOpenComments(game)
        case .details: onOpenDetails(game)
        case .report: onReport(game)
        case .notInterested: onNotInterested(game)
        case .blockCreator:
            if ForYouActionOwnershipPolicy.canOfferCreatorBlock(
                ownerID: game.ownerID, viewerID: pending.request.viewerID
            ) {
                onBlockCreator(game)
            }
        }
    }

    private func requestShare(_ request: ForYouActionsRequest) {
        guard canPresent(request) else {
            retireActions()
            return
        }
        queuedAction = nil
        queuedShare = request
        activeActions = nil
    }

    private func shareURL(for gameID: String) -> URL {
        var parts = URLComponents(
            url: BackendConfig.baseURL.appendingPathComponent("player"),
            resolvingAgainstBaseURL: false
        )!
        parts.queryItems = [URLQueryItem(name: "game", value: gameID)]
        return parts.url ?? BackendConfig.baseURL
    }

    private func retireActions() {
        activeActions = nil
        queuedAction = nil
        queuedShare = nil
        activeShare = nil
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
                if let activeActions, activeActions.id != id { retireActions() }
                if let queuedAction, queuedAction.request.id != id { retireActions() }
                if let queuedShare, queuedShare.id != id { retireActions() }
                if let activeShare, activeShare.id != id { retireActions() }
                guard let id, let index = games.firstIndex(where: { $0.id == id }) else { return }
                if index >= max(0, games.count - 2) { onNearEnd() }
            }
        }
        // The stable pager lives across per-game .id(game.id) page rebuilds.
        // Each real action revalidates selected game + viewer revision, so a
        // stale sheet cannot mutate an earlier game after a swipe or logout.
        .sheet(item: $activeActions, onDismiss: {
            if let pending = queuedAction {
                queuedAction = nil
                // The final game/viewer check runs AFTER native dismissal.
                deliverDismissedAction(pending)
            }
            if let request = queuedShare {
                if canPresent(request) {
                    // Present ONLY the exact validated game+viewer request.
                    // A Boolean sheet with conditional content produced a
                    // blank native modal on the original iPhone A5 smoke.
                    activeShare = request
                    Task {
                        await BackendAPI.shared.trackSocialEvent(
                            gameID: request.id, kind: "share")
                    }
                } else {
                    queuedShare = nil
                }
            }
        }) { request in
            if canPresent(request),
               let game = games.first(where: { $0.id == request.id }) {
                ForYouGameActionsSheet(
                    game: game,
                    isSaved: savedGameIDs.contains(game.id),
                    isLiked: likedGameIDs.contains(game.id),
                    onDismiss: { activeActions = nil },
                    onToggleSaved: { queueAction(request, .save) },
                    onToggleLike: { queueAction(request, .like) },
                    onOpenComments: { queueAction(request, .comments) },
                    onShare: { requestShare(request) },
                    onOpenDetails: { queueAction(request, .details) },
                    onReport: { queueAction(request, .report) },
                    onNotInterested: { queueAction(request, .notInterested) },
                    onBlockCreator: { queueAction(request, .blockCreator) }
                )
            } else {
                ContentUnavailableView(
                    "Game actions unavailable",
                    systemImage: "hand.raised",
                    description: Text("This game is no longer the selected post.")
                )
                .onAppear { retireActions() }
            }
        }
        .sheet(item: $activeShare, onDismiss: {
            queuedShare = nil
        }) { request in
            // Validity was checked AFTER the previous Actions sheet dismissed.
            // The SwiftUI sheet must never mount empty conditional content;
            // session/page changes cancel this concrete presentation item.
            ArcadePulseGameShareSheet(url: shareURL(for: request.id))
        }
        .onChange(of: scope) { _, _ in retireActions() }
        .onChange(of: games.map(\.id)) { _, ids in
            if let request = activeActions, !ids.contains(request.id) { retireActions() }
            if let queuedAction, !ids.contains(queuedAction.request.id) { retireActions() }
            if let request = queuedShare, !ids.contains(request.id) { retireActions() }
            if let request = activeShare, !ids.contains(request.id) { retireActions() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .hephaestusBackendSessionDidChange
        )) { _ in
            sessionRevision += 1
            retireActions()
        }
    }
}

/// iPad's default form-sheet is narrow even when the app's landscape window
/// has room for two columns. Present genuine Game Details in the full iPad
/// window; preserve the existing sheet/dismiss experience on iPhone.
private struct ArcadePulseGameDetailsPresentation: ViewModifier {
    @Binding var selection: FeedGame?

    @ViewBuilder
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content.fullScreenCover(item: $selection) { game in
                ArcadePulseGameDetailsSheet(game: game)
            }
        } else {
            content.sheet(item: $selection) { game in
                ArcadePulseGameDetailsSheet(game: game)
            }
        }
    }
}

private struct ArcadePulseGameDetailsSheet: View {
    let game: FeedGame
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    @State private var playerRequest: PixiPlayerRequest?
    // URL presence is not proof the actual poster loaded. Only a decoded
    // image expands the portrait media stage; failures retain an honest,
    // compact "Preview unavailable" card and accessible Play / Share.
    @State private var hasDecodedPoster = false

    private var shareURL: URL {
        var components = URLComponents(url: BackendConfig.baseURL.appendingPathComponent("player"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "game", value: game.id)]
        return components?.url ?? BackendConfig.baseURL
    }

    private func preview(height: CGFloat) -> some View {
        ZStack {
            // The gradient is merely a fallback, never a recorded preview.
            LinearGradient(colors: ArcadePulseTheme.fallbackPalette(gameID: game.id),
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let poster = game.previewPosterURL, let url = URL(string: poster) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                            .onAppear { hasDecodedPoster = true }
                    } else {
                        unavailablePreview
                            .onAppear { hasDecodedPoster = false }
                    }
                }
            } else {
                unavailablePreview
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: ArcadePulseTheme.surfaceRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasDecodedPoster
                            ? "Game artwork for \(game.title)"
                            : "Gameplay preview unavailable for \(game.title)")
        .accessibilityValue(hasDecodedPoster ? "Poster displayed" : "Preview unavailable")
        .accessibilityIdentifier("game.details.preview")
    }

    private var unavailablePreview: some View {
        VStack(spacing: 10) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 38))
            Text("Preview unavailable")
                .font(.headline)
            Text("Use Play to launch the actual game")
                .font(.caption)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
    }

    /// Shared actual feed metadata; no fabricated ratings, counts, game
    /// release dates, updates or suggested games to fill empty tablet space.
    private var metadataAndActions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(game.title)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("game.details.title")
            if let owner = game.ownerID, !owner.isEmpty {
                Label(game.creatorDisplayName?.isEmpty == false
                      ? game.creatorDisplayName! : owner,
                      systemImage: "person.crop.circle")
                    .foregroundStyle(ArcadePulseTheme.textSecondary)
            }
            // Play and Share must be reachable before optional long
            // creator-provided descriptions, topics or version metadata.
            ArcadePulsePlayCTA {
                playerRequest = PixiPlayerRequest(gameID: game.id, title: game.title)
            }
            ShareLink(item: shareURL) {
                Label("Share game", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .foregroundStyle(ArcadePulseTheme.onElectricViolet)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(
                        ArcadePulseTheme.electricViolet,
                        in: RoundedRectangle(
                            cornerRadius: ArcadePulseTheme.pillRadius,
                            style: .continuous
                        )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: ArcadePulseTheme.pillRadius))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the native system sharing options")
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

        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func adaptiveLayout(size: CGSize) -> some View {
        let twoColumn = ForYouPageLayout.showsIPadGameDetailsTwoColumn(
            width: size.width, height: size.height,
            isRegular: horizontalSizeClass == .regular,
            isLargeText: dynamicTypeSize >= .xxLarge
        )
        if twoColumn {
            HStack(alignment: .top, spacing: 24) {
                preview(height: ForYouPageLayout.gameDetailsPreviewHeight(
                    containerHeight: size.height,
                    hasDecodedPoster: hasDecodedPoster))
                    .frame(width: ForYouPageLayout.gameDetailsPreviewWidth(
                        containerWidth: size.width))
                metadataAndActions
            }
            .frame(maxWidth: 1_200, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("game.details.twoColumn")
        } else {
            VStack(alignment: .leading, spacing: 18) {
                preview(height: ForYouPageLayout.gameDetailsSingleColumnPreviewHeight(
                    containerWidth: size.width,
                    containerHeight: size.height,
                    isIPad: UIDevice.current.userInterfaceIdiom == .pad,
                    isRegularWidth: horizontalSizeClass == .regular,
                    hasDecodedPoster: hasDecodedPoster,
                    isLargeText: dynamicTypeSize >= .xxLarge
                ))
                metadataAndActions
            }
            .frame(maxWidth: 800)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("game.details.singleColumn")
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    adaptiveLayout(size: geometry.size)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(18)
                }
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

enum CreatorDiscoveryErrorPresentation {
    static func message(for error: Error, isPagination: Bool) -> String {
        let prefix = isPagination
            ? "Couldn't load more creators. "
            : "Couldn't load creators. "
        if let apiError = error as? APIError,
           case let .badStatus(status) = apiError {
            switch status {
            case 401: return prefix + "Your session may have expired. Open Profile and try again."
            case 403: return prefix + "This request isn't permitted. Try another search."
            case 429: return prefix + "Too many requests. Try again in a little while."
            default: break
            }
        }
        if let network = error as? URLError {
            switch network.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return prefix + "You're offline. Reconnect and try again."
            case .secureConnectionFailed, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot:
                return prefix + "A secure connection couldn't be established. Check your network."
            case .timedOut:
                return prefix + "The creator service is taking too long. Try again."
            default: break
            }
        }
        return prefix + "The creator service isn't available right now. Try again."
    }
}

private struct CreatorDiscoverySheet: View {
    let onRequestSignIn: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var topicText = ""
    @State private var creators: [CreatorDiscoveryEntry] = []
    @State private var nextCursor: String?
    @State private var profileRequest: CreatorProfileRequest?
    @State private var openProfileAfterNestedCreatorDismiss = false
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadGeneration = 0
    // Retry ONLY a failed transient request for the still-current page.
    // The cursor is a backend navigation token, never synthetic or logged.
    @State private var failedPaginationCursor: String?
    // A new query must not present previously confirmed creators as current.
    @State private var resultsMatchCurrentSearch = false
    @State private var appliedSearchText = ""
    @State private var appliedTopicText = ""

    private var canRetryFailedPage: Bool {
        errorMessage != nil && CreatorDiscoveryResultsPolicy.canRetryFailedPage(
            failedCursor: failedPaginationCursor,
            nextCursor: nextCursor,
            resultsMatchCurrentSearch: resultsMatchCurrentSearch,
            draftMatchesAppliedQuery: searchText == appliedSearchText &&
                topicText == appliedTopicText
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    CreatorTopicFilterControls(
                        topicText: $topicText,
                        isLoading: isLoading
                    ) {
                        submitCreatorQueryFromUI()
                    }
                } header: {
                    Text("Topic")
                } footer: {
                    Text("Search creators by ID or public game title. Topic filtering is an exact match.")
                }

                if isLoading {
                    // Reset search is different from pagination. Never expose
                    // prior search rows as results for a pending new query.
                    HStack { Spacer(); ProgressView("Finding creators…"); Spacer() }
                        .accessibilityIdentifier("creator.discovery.searching")
                } else if creators.isEmpty {
                    if CreatorDiscoveryResultsPolicy.showsEmptyMessage(
                        isLoading: isLoading,
                        hasResults: !creators.isEmpty,
                        hasError: errorMessage != nil
                    ) {
                        ContentUnavailableView(
                            "No creators found",
                            systemImage: "person.2",
                            description: Text("Try another search or topic.")
                        )
                    }
                } else {
                    Section(CreatorDiscoveryResultsPolicy.sectionTitle(
                        resultsMatchCurrentSearch: resultsMatchCurrentSearch
                    )) {
                        if !resultsMatchCurrentSearch {
                            Label(
                                "These are previous results. The current search could not be confirmed.",
                                systemImage: "clock.arrow.circlepath"
                            )
                            .font(.subheadline)
                            .foregroundStyle(ArcadePulseTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("creator.discovery.previousResults")
                        }
                        ForEach(creators) { creator in
                            Button {
                                profileRequest = CreatorProfileRequest(id: creator.creator_id)
                            } label: {
                                CreatorDirectoryRow(
                                    creatorID: creator.creator_id,
                                    publicGameCount: creator.post_count,
                                    topics: creator.topics
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(CreatorDirectoryRowLayout.rowAccessibilityIdentifier(
                                for: creator.creator_id) == nil)
                            .accessibilityLabel(
                                CreatorDirectoryRowLayout.rowAccessibilityIdentifier(
                                    for: creator.creator_id) == nil
                                ? "Creator unavailable: invalid public identity"
                                : CreatorDirectoryRowLayout.accessibilityLabel(
                                    creatorID: creator.creator_id,
                                    count: creator.post_count,
                                    topics: creator.topics
                                )
                            )
                            .accessibilityIdentifier(
                                CreatorDirectoryRowLayout.rowAccessibilityIdentifier(
                                    for: creator.creator_id) ?? "creator.discovery.invalidRow"
                            )
                        }
                    }
                    if CreatorDiscoveryResultsPolicy.allowsNextPage(
                        resultsMatchCurrentSearch: resultsMatchCurrentSearch,
                        hasNextCursor: nextCursor != nil,
                        isLoading: isLoading || isLoadingMore,
                        hasError: errorMessage != nil,
                        draftMatchesAppliedQuery: searchText == appliedSearchText &&
                            topicText == appliedTopicText
                    ) {
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
                        Button(canRetryFailedPage ? "Retry this page" : "Try again") {
                            let retryPage = canRetryFailedPage
                            Task { await load(reset: !retryPage) }
                        }
                            .frame(minWidth: 44, minHeight: 48)
                            .accessibilityIdentifier("creator.discovery.retry")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Creators")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search creators or games")
            // Both native fields route through ONE host-owned Search action.
            .onSubmit(of: .search) {
                submitCreatorQueryFromUI()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await load(reset: true) }
            .task { await load(reset: true) }
            .sheet(item: $profileRequest, onDismiss: {
                // A guest route can advance only after this real child
                // profile is gone. The outer host owns app navigation.
                if openProfileAfterNestedCreatorDismiss {
                    openProfileAfterNestedCreatorDismiss = false
                    onRequestSignIn?()
                }
            }) { request in
                CreatorProfileSheet(
                    creatorID: request.id,
                    onRequestSignIn: onRequestSignIn == nil ? nil : {
                        openProfileAfterNestedCreatorDismiss = true
                        profileRequest = nil
                    }
                )
            }
        }
    }

    /// Mark the native UI busy synchronously before starting the real GET.
    /// Two Search/Apply callbacks in one run-loop cannot duplicate a reset.
    private func submitCreatorQueryFromUI() {
        guard CreatorQuerySubmitPolicy.canSubmit(isLoading: isLoading) else { return }
        isLoading = true
        Task { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        if reset {
            loadGeneration += 1
            appliedSearchText = searchText
            appliedTopicText = topicText
            nextCursor = nil
            failedPaginationCursor = nil
            resultsMatchCurrentSearch = false
            isLoading = true
            isLoadingMore = false
        } else {
            guard nextCursor != nil, !isLoadingMore, !isLoading,
                  resultsMatchCurrentSearch, searchText == appliedSearchText,
                  topicText == appliedTopicText else { return }
            isLoadingMore = true
        }
        let generation = loadGeneration
        defer {
            if generation == loadGeneration {
                if reset { isLoading = false } else { isLoadingMore = false }
            }
        }
        errorMessage = nil
        failedPaginationCursor = nil
        do {
            let response = try await BackendAPI.shared.fetchCreators(
                query: appliedSearchText,
                topic: appliedTopicText,
                cursor: reset ? nil : nextCursor
            )
            guard generation == loadGeneration else { return }
            if reset {
                creators = response.creators
                // Only the winning generation confirms these live rows.
                resultsMatchCurrentSearch = true
            } else {
                var seen = Set(creators.map(\.creator_id))
                creators.append(contentsOf: response.creators.filter { seen.insert($0.creator_id).inserted })
            }
            nextCursor = response.next_cursor.flatMap { $0.isEmpty ? nil : $0 }
        } catch {
            guard generation == loadGeneration else { return }
            if !reset && CreatorDiscoveryResultsPolicy.isTransientPageFailure(error) {
                failedPaginationCursor = nextCursor
            }
            errorMessage = CreatorDiscoveryErrorPresentation.message(
                for: error, isPagination: !reset
            )
        }
    }
}

/// Keep truthful creator statistics legible in compact windows and at
/// accessibility text sizes. This is a sizing policy, not a data source.
enum CreatorMetricLayout {
    static func stacksMetrics(isRegularWidth: Bool, typeSize: DynamicTypeSize) -> Bool {
        typeSize.isAccessibilitySize || (!isRegularWidth && typeSize >= .xxxLarge)
    }
}

private struct CreatorProfileSheet: View {
    let creatorID: String
    let onRequestSignIn: (() -> Void)?

    init(creatorID: String, onRequestSignIn: (() -> Void)? = nil) {
        self.creatorID = creatorID
        self.onRequestSignIn = onRequestSignIn
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var profile: CreatorProfile?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var isFollowUpdating = false
    @State private var followStatusNeedsRefresh = false
    /// Only set after a successfully acknowledged POST; never guess the
    /// outcome of a timed-out or lost-response write.
    @State private var expectedFollowingAfterWrite: Bool?
    @State private var profileLoadRevision = 0
    @State private var followMutationRevision = 0
    @State private var playerRequest: PixiPlayerRequest?

    private var stacksCreatorMetrics: Bool {
        CreatorMetricLayout.stacksMetrics(
            isRegularWidth: horizontalSizeClass == .regular,
            typeSize: dynamicTypeSize
        )
    }

    private var creatorMetricsLayout: AnyLayout {
        stacksCreatorMetrics
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
    }

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
                                creatorMetricsLayout {
                                    creatorMetric("Games", value: profile.post_count)
                                    creatorMetric("Followers", value: profile.follower_count)
                                    creatorMetric("Following", value: profile.following_count)
                                }
                                .accessibilityIdentifier("creator.profile.metrics")
                                if BackendConfig.currentUserID.isEmpty {
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("Sign in from Profile to follow this creator.")
                                            .font(.subheadline)
                                            .foregroundStyle(ArcadePulseTheme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .accessibilityIdentifier("creator.profile.signInHint")
                                        if let onRequestSignIn {
                                            Button(action: onRequestSignIn) {
                                                Label("Go to Profile to sign in",
                                                      systemImage: "person.crop.circle")
                                                    .font(.headline.weight(.semibold))
                                                    .foregroundStyle(.black)
                                                    .frame(maxWidth: .infinity, minHeight: 48)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(ArcadePulseTheme.electricViolet)
                                            .accessibilityIdentifier("creator.profile.openProfile")
                                        }
                                    }
                                } else if CreatorFollowStatePolicy.offersFollow(
                                    viewerID: BackendConfig.currentUserID,
                                    creatorID: profile.creator_id
                                ) {
                                    Button {
                                        Task { await toggleFollow(profile.is_following) }
                                    } label: {
                                        Label(isFollowUpdating ? "Updating follow status…" :
                                              (followStatusNeedsRefresh ? "Refresh status before following" :
                                               (profile.is_following ? "Following" : "Follow creator")),
                                              systemImage: profile.is_following ?
                                                "person.fill.checkmark" : "person.badge.plus")
                                            .font(.headline.weight(.semibold))
                                            // White-on-violet misses AA for normal text;
                                            // preserve the shared >4.5:1 foreground.
                                            .foregroundStyle(ArcadePulseTheme.onElectricViolet)
                                            .frame(maxWidth: .infinity, minHeight: 48)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(ArcadePulseTheme.electricViolet)
                                    .disabled(!CreatorFollowStatePolicy.canSubmit(
                                        viewerID: BackendConfig.currentUserID,
                                        creatorID: profile.creator_id,
                                        isUpdating: isFollowUpdating,
                                        needsConfirmation: followStatusNeedsRefresh
                                    ))
                                    .accessibilityIdentifier("creator.profile.follow")
                                }
                            }
                            .padding(18)
                            .background(ArcadePulseTheme.surface,
                                        in: RoundedRectangle(cornerRadius: ArcadePulseTheme.surfaceRadius))
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("creator.profile.header")

                            if let errorMessage {
                                VStack(alignment: .leading, spacing: 10) {
                                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                                        .font(.subheadline)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Button {
                                        Task { await load() }
                                    } label: {
                                        Label(followStatusNeedsRefresh ?
                                              "Refresh follow status" : "Try again",
                                              systemImage: "arrow.clockwise")
                                            .frame(maxWidth: .infinity, minHeight: 48)
                                    }
                                    .buttonStyle(ArcadePulseRecoveryButtonStyle())
                                    .accessibilityIdentifier("creator.profile.retryLoad")
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(ArcadePulseTheme.surface,
                                            in: RoundedRectangle(cornerRadius: 14))
                                .accessibilityIdentifier("creator.profile.error")
                            }

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
                            .frame(minWidth: 44, minHeight: 48)
                            .accessibilityIdentifier("creator.profile.retryLoad")
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
            .onChange(of: creatorID) { _, _ in
                // This sheet may be reused for a different real Creator.
                // Invalidate all old owner/write callbacks before refreshing.
                profileLoadRevision += 1
                followMutationRevision += 1
                profile = nil
                errorMessage = nil
                isLoading = true
                isFollowUpdating = false
                followStatusNeedsRefresh = false
                expectedFollowingAfterWrite = nil
                Task { await load() }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .hephaestusBackendSessionDidChange
            )) { _ in
                // Invalid old viewer callbacks cannot change the next viewer.
                profileLoadRevision += 1
                followMutationRevision += 1
                profile = nil
                errorMessage = nil
                isLoading = true
                isFollowUpdating = false
                followStatusNeedsRefresh = false
                expectedFollowingAfterWrite = nil
                Task { await load() }
            }
            .fullScreenCover(item: $playerRequest) { request in
                PixiPlayerSheet(gameID: request.gameID, title: request.title)
            }
        }
    }

    private func creatorMetric(_ label: String, value: Int) -> some View {
        // All labels and numbers come from a real creator response; never
        // truncate an accessible number or shrink it to fit three columns.
        let readableCount = value.formatted()
        return Group {
            if stacksCreatorMetrics {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(ArcadePulseTheme.textSecondary)
                    Spacer(minLength: 8)
                    Text(readableCount)
                        .font(.headline.weight(.bold))
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 5) {
                    Text(readableCount)
                        .font(.headline.weight(.bold))
                        .monospacedDigit()
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(ArcadePulseTheme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(readableCount)")
    }

    private func creatorGameRow(_ game: FeedGame) -> some View {
        // A fixed side-by-side 112pt poster used to squeeze genuine backend
        // titles and Play at XXL/XXXL, especially on compact iPads.
        let stacked = CreatorGameRowLayout.prefersStacked(
            isIPad: UIDevice.current.userInterfaceIdiom == .pad,
            isRegularWidth: horizontalSizeClass == .regular,
            isEnlargedText: dynamicTypeSize >= .xxLarge,
            isAccessibilityText: dynamicTypeSize.isAccessibilitySize
        )
        let layout: AnyLayout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
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
            .frame(width: stacked ? nil : 112, height: stacked ? 152 : 116)
            .frame(maxWidth: stacked ? .infinity : nil)
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
                        // Existing deep orange is not AA-readable with
                        // white normal-size text. Black is approximately 8:1.
                        .foregroundStyle(.black)
                        .frame(minWidth: stacked ? nil : 110,
                               maxWidth: stacked ? .infinity : nil,
                               minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(ArcadePulseTheme.playOrangeDeep)
                .accessibilityIdentifier("creator.game.play.\(game.id)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ArcadePulseTheme.surface,
                    in: RoundedRectangle(cornerRadius: ArcadePulseTheme.pillRadius))
    }

    private func load(confirmingFollow: Bool = false) async {
        profileLoadRevision += 1
        let revision = profileLoadRevision
        let viewer = BackendConfig.currentUserID
        let startedWhileMutating = isFollowUpdating
        // An in-place refresh must not discard genuine published games.
        if profile == nil { isLoading = true }
        defer {
            if revision == profileLoadRevision { isLoading = false }
        }
        do {
            let fetched = try await BackendAPI.shared.fetchCreatorProfile(id: creatorID)
            guard CreatorFollowStatePolicy.mayApplyCreatorRead(
                requestRevision: revision, currentRevision: profileLoadRevision,
                sameViewer: viewer == BackendConfig.currentUserID,
                startedWhileMutating: startedWhileMutating,
                isPostWriteConfirmation: confirmingFollow
            ) else { return }
            profile = fetched
            // A read replica may return the PREVIOUS state immediately
            // after an acknowledged Follow POST. Keep its genuine games
            // visible but do not claim the mutation is confirmed or enable
            // another write until a same-owner GET matches our target.
            if CreatorFollowStatePolicy.confirmsAcknowledgedTarget(
                expectedFollowing: expectedFollowingAfterWrite,
                observedFollowing: fetched.is_following
            ) {
                errorMessage = nil
                followStatusNeedsRefresh = false
                expectedFollowingAfterWrite = nil
            } else {
                followStatusNeedsRefresh = true
                errorMessage = CreatorFollowStatePolicy.syncPendingMessage
            }
        } catch {
            guard CreatorFollowStatePolicy.mayApplyCreatorRead(
                requestRevision: revision, currentRevision: profileLoadRevision,
                sameViewer: viewer == BackendConfig.currentUserID,
                startedWhileMutating: startedWhileMutating,
                isPostWriteConfirmation: confirmingFollow
            ) else { return }
            errorMessage = CreatorProfileErrorPresentation.message(for: error, action: .load)
        }
    }

    private func toggleFollow(_ currentlyFollowing: Bool) async {
        let viewer = BackendConfig.currentUserID
        guard CreatorFollowStatePolicy.canSubmit(
            viewerID: viewer, creatorID: creatorID,
            isUpdating: isFollowUpdating, needsConfirmation: followStatusNeedsRefresh
        ) else { return }
        // Pre-write in-flight GET must not overwrite new relationship state.
        profileLoadRevision += 1
        followMutationRevision += 1
        let revision = followMutationRevision
        isFollowUpdating = true
        defer {
            if revision == followMutationRevision { isFollowUpdating = false }
        }
        do {
            try await BackendAPI.shared.setFollowing(creatorID, following: !currentlyFollowing)
            guard revision == followMutationRevision,
                  viewer == BackendConfig.currentUserID else { return }
            followStatusNeedsRefresh = true
            expectedFollowingAfterWrite = !currentlyFollowing
            await load(confirmingFollow: true)
        } catch {
            guard revision == followMutationRevision,
                  viewer == BackendConfig.currentUserID else { return }
            // A dropped response does not prove a Follow POST failed.
            // Never set an *acknowledged* target after a lost response.
            expectedFollowingAfterWrite = nil
            followStatusNeedsRefresh = true
            errorMessage = CreatorProfileErrorPresentation.message(
                for: error, action: .follow)
        }
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
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("report.error")
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
                        .frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                                .accessibilityLabel("Submitting report")
                        } else {
                            Text("Submit")
                        }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(isSubmitting || submitted)
                    .accessibilityIdentifier("report.submit")
                }
            }
        }
    }

    private func submit() async {
        guard !isSubmitting, !submitted else { return }
        isSubmitting = true
        errorMessage = nil
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
            // A lost moderation POST response is not confirmed rejection.
            // Preserve the user's original reason and detailed report.
            errorMessage = ReportGameErrorPresentation.message(for: error)
        }
    }
}

/// Show fixed native copy, never raw URLSession/NSError localizedDescription
/// that could expose backend URLs, account identifiers or tokens.
enum CommentsErrorPresentation {
    enum Action: Equatable { case load, post, delete }

    /// A failed or pending fetch does not authorize a verified zero count.
    static func showsConfirmedCount(isLoading: Bool, loadFailed: Bool) -> Bool {
        !isLoading && !loadFailed
    }

    static func message(for error: Error, action: Action, signedIn: Bool) -> String {
        if let apiError = error as? APIError,
           case let .badStatus(status) = apiError {
            if status == 401 { return "Your session has expired. Sign in again from Profile." }
            if status == 403 { return "This comment action isn't allowed for this account." }
            if status == 429 { return "Too many requests. Try again in a little while." }
        }
        if !signedIn && action != .load {
            return "Sign in from Profile to manage your comments."
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .secureConnectionFailed:
                return "A secure connection couldn't be established. Check your network."
            case .notConnectedToInternet, .networkConnectionLost:
                if action == .post {
                    return "You're offline. Comment delivery is unconfirmed. Your draft is saved for retry."
                }
                if action == .delete {
                    return "You're offline. Comment deletion is unconfirmed. Refresh comments to check."
                }
                return "You're offline. Reconnect, then try again."
            case .timedOut:
                if action == .post {
                    return "Couldn't confirm whether your comment was sent. Your draft is saved for retry."
                }
                if action == .delete {
                    return "Couldn't confirm whether this comment was deleted. Refresh comments to check."
                }
                return "Loading comments is taking too long. Try again."
            default:
                break
            }
        }
        switch action {
        case .load: return "Comments aren't available right now. Try again."
        case .post:
            return "Couldn't confirm whether your comment was sent. Your draft is saved for retry."
        case .delete:
            return "Couldn't confirm whether this comment was deleted. Refresh comments to check."
        }
    }
}

/// Native keyboard Send and paperplane share a single real-backend admission
/// policy. The existing submit() owns idempotency and viewer epoch; no second
/// network entry point and no test-generated public comment are introduced.
enum CommentsSubmitEligibilityPolicy {
    static func canSend(draft: String, isSubmitting: Bool) -> Bool {
        !isSubmitting && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Only a request that started after the last destructive mutation can
/// reconcile a lost DELETE response. An older or overlapping GET may contain
/// a valid-but-stale list and must not unlock a duplicate DELETE.
enum CommentsDeleteReadPolicy {
    static func mayApply(
        readViewer: Int, currentViewer: Int,
        readMutation: Int, currentMutation: Int,
        startedDuringDeletion: Bool,
        readGeneration: Int, currentGeneration: Int
    ) -> Bool {
        readViewer == currentViewer &&
        readMutation == currentMutation &&
        !startedDuringDeletion &&
        readGeneration == currentGeneration
    }
}

private struct CommentsSheet: View {
    let game: FeedGame
    @Environment(\.dismiss) private var dismiss
    @State private var comments: [SocialComment] = []
    @State private var draft = ""
    @State private var errorMessage: String?
    @State private var isLoadFailure = false
    /// Revokes UI ownership of all private comments when the viewer changes.
    @State private var viewerEpoch = 0
    @State private var isLoading = true
    @State private var isSubmitting = false
    @State private var pendingIdempotencyKey: String?
    @State private var pendingBody: String?
    @State private var deletingCommentIDs = Set<String>()
    // A DELETE can reach the server even when its response is lost. Prevent
    // a second destructive write until a fresh real comment GET reconciles.
    @State private var unconfirmedDeletionIDs = Set<String>()
    @State private var deletionRevision = 0
    @State private var commentsLoadGeneration = 0

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
                    // Unknown while loading/transport failed: do not display
                    // a misleading 0 as if the server confirmed emptiness.
                    if CommentsErrorPresentation.showsConfirmedCount(
                        isLoading: isLoading, loadFailed: isLoadFailure) {
                        Text("\(comments.count)")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(ArcadePulseTheme.textSecondary)
                            .accessibilityLabel("\(comments.count) loaded comments")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(ArcadePulseTheme.surface)
                // One stable AX identity for the actual game-bound native
                // Comments sheet. SwiftUI may combine "COMMENTS ON", the
                // published title and loaded count into one spoken node.
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("comments.sheet.gameHeader")

                if isLoading {
                    ProgressView("Loading comments…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isLoadFailure && comments.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: HephaestusDesign.stateIconSize))
                            .accessibilityHidden(true)
                        Text("Couldn't load comments").font(.headline)
                        Text(errorMessage ?? "Comments aren't available right now.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(ArcadePulseTheme.textSecondary)
                            .accessibilityIdentifier("comments.error")
                        Button("Try again") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                            .frame(minWidth: 120, minHeight: 44)
                            .accessibilityIdentifier("comments.retry")
                    }
                    .padding(24)
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
                                .disabled(deletingCommentIDs.contains(comment.id) ||
                                          unconfirmedDeletionIDs.contains(comment.id))
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .accessibilityIdentifier("comments.list")
                }

                if let errorMessage, !(isLoadFailure && comments.isEmpty) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("comments.error")
                        if !unconfirmedDeletionIDs.isEmpty {
                            Button {
                                Task { await load() }
                            } label: {
                                Label("Refresh comments to check", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("comments.refreshDeletionStatus")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                }
            }
            .background(ArcadePulseTheme.canvas)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 10) {
                    TextField("Add a comment…", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .submitLabel(.send)
                        .onSubmit {
                            guard CommentsSubmitEligibilityPolicy.canSend(
                                draft: draft, isSubmitting: isSubmitting
                            ) else { return }
                            Task { await submit() }
                        }
                        // Sending owns the draft until the server confirms;
                        // disable edits so the completion cannot erase a
                        // second message typed during the in-flight request.
                        .disabled(isSubmitting)
                        .accessibilityIdentifier("comments.composer")
                    if isSubmitting {
                        ProgressView()
                            .frame(width: 44, height: 44)
                            .accessibilityLabel("Sending comment")
                    } else if CommentsSubmitEligibilityPolicy.canSend(
                        draft: draft, isSubmitting: isSubmitting
                    ) {
                        Button {
                            Task { await submit() }
                        } label: {
                            Image(systemName: "paperplane.fill")
                                // The actual XCTest iPhone keyboard screenshot
                                // showed a white plane on deep orange (~2.57:1).
                                // Black increases icon contrast above 3:1.
                                .foregroundStyle(.black)
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
            .onReceive(NotificationCenter.default.publisher(
                for: .hephaestusBackendSessionDidChange
            )) { _ in
                // Account-owned comment bodies, draft, error messages,
                // deletion state and idempotency token cannot cross viewers.
                viewerEpoch &+= 1
                comments.removeAll()
                draft = ""
                errorMessage = nil
                isLoadFailure = false
                isLoading = false
                isSubmitting = false
                pendingIdempotencyKey = nil
                pendingBody = nil
                deletingCommentIDs.removeAll()
                unconfirmedDeletionIDs.removeAll()
                deletionRevision &+= 1
                commentsLoadGeneration &+= 1
                dismiss()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func load() async {
        let epoch = viewerEpoch
        commentsLoadGeneration &+= 1
        let loadGeneration = commentsLoadGeneration
        let mutationRevision = deletionRevision
        let beganWhileDeleting = !deletingCommentIDs.isEmpty
        isLoading = true
        isLoadFailure = false
        do {
            let loaded = try await BackendAPI.shared.fetchComments(gameID: game.id)
            guard !Task.isCancelled,
                  CommentsDeleteReadPolicy.mayApply(
                    readViewer: epoch, currentViewer: viewerEpoch,
                    readMutation: mutationRevision, currentMutation: deletionRevision,
                    startedDuringDeletion: beganWhileDeleting,
                    readGeneration: loadGeneration, currentGeneration: commentsLoadGeneration
                  ) else {
                // A stale GET must not clear uncertainty, but the most recent
                // same-viewer request may still retire its own spinner.
                if epoch == viewerEpoch, loadGeneration == commentsLoadGeneration {
                    isLoading = false
                }
                return
            }
            comments = loaded
            // A new GET after the DELETE settles reflects server deletion status; only then may
            // the user decide to retry deletion of a still-existing comment.
            unconfirmedDeletionIDs.removeAll()
            errorMessage = nil
            isLoading = false
        } catch {
            guard !Task.isCancelled,
                  CommentsDeleteReadPolicy.mayApply(
                    readViewer: epoch, currentViewer: viewerEpoch,
                    readMutation: mutationRevision, currentMutation: deletionRevision,
                    startedDuringDeletion: beganWhileDeleting,
                    readGeneration: loadGeneration, currentGeneration: commentsLoadGeneration
                  ) else {
                if epoch == viewerEpoch, loadGeneration == commentsLoadGeneration {
                    isLoading = false
                }
                return
            }
            isLoading = false
            isLoadFailure = true
            errorMessage = CommentsErrorPresentation.message(
                for: error, action: .load, signedIn: !BackendConfig.currentUserID.isEmpty)
        }
    }

    private func submit() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CommentsSubmitEligibilityPolicy.canSend(
            draft: body, isSubmitting: isSubmitting
        ) else { return }
        let epoch = viewerEpoch
        isSubmitting = true
        if pendingBody != body {
            pendingIdempotencyKey = UUID().uuidString
            pendingBody = body
        }
        let key = pendingIdempotencyKey ?? UUID().uuidString
        pendingIdempotencyKey = key
        do {
            let comment = try await BackendAPI.shared.addComment(
                gameID: game.id, body: body, idempotencyKey: key)
            guard epoch == viewerEpoch, !Task.isCancelled else { return }
            if !comments.contains(where: { $0.id == comment.id }) {
                comments.append(comment)
            }
            draft = ""
            pendingIdempotencyKey = nil
            pendingBody = nil
            errorMessage = nil
            isLoadFailure = false
            isSubmitting = false
        } catch {
            guard epoch == viewerEpoch, !Task.isCancelled else { return }
            isSubmitting = false
            isLoadFailure = false
            // Uncertain delivery retains the same idempotency key and draft
            // so retry doesn't duplicate a comment on the real server.
            errorMessage = CommentsErrorPresentation.message(
                for: error, action: .post, signedIn: !BackendConfig.currentUserID.isEmpty)
        }
    }

    private func delete(_ comment: SocialComment) async {
        guard comment.user_id == BackendConfig.currentUserID,
              !deletingCommentIDs.contains(comment.id),
              !unconfirmedDeletionIDs.contains(comment.id) else { return }
        let epoch = viewerEpoch
        // Revoke any list GET already in flight before the DELETE begins.
        deletionRevision &+= 1
        deletingCommentIDs.insert(comment.id)
        do {
            try await BackendAPI.shared.deleteComment(gameID: game.id, commentID: comment.id)
            guard epoch == viewerEpoch, !Task.isCancelled else { return }
            deletingCommentIDs.remove(comment.id)
            comments.removeAll { $0.id == comment.id }
            unconfirmedDeletionIDs.remove(comment.id)
            errorMessage = nil
            isLoadFailure = false
        } catch {
            guard epoch == viewerEpoch, !Task.isCancelled else { return }
            deletingCommentIDs.remove(comment.id)
            unconfirmedDeletionIDs.insert(comment.id)
            isLoadFailure = false
            errorMessage = CommentsErrorPresentation.message(
                for: error, action: .delete, signedIn: !BackendConfig.currentUserID.isEmpty)
        }
    }
}

private struct FeedPreferencesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let availableTopics: [String]
    let selectedTopics: Set<String>
    let onSave: ([String]) async -> Bool
    let onReset: () async -> Bool
    @State private var selected = Set<String>()
    @State private var isUpdating = false
    @State private var updateError: String?
    @State private var presentationEpoch = 0

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
                        .disabled(isUpdating)
                    }
                }
                if isUpdating {
                    Section {
                        ProgressView("Confirming your preferences…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("feed.preferences.updating")
                    }
                }
                if let updateError {
                    Section {
                        Label(updateError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("feed.preferences.error")
                        Text("Your selections are still editable. Retry when the service is available.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button {
                        guard !isUpdating else { return }
                        isUpdating = true
                        updateError = nil
                        let epoch = presentationEpoch
                        Task {
                            let confirmed = await onSave(selected.sorted())
                            guard epoch == presentationEpoch else { return }
                            isUpdating = false
                            if confirmed {
                                dismiss()
                            } else {
                                updateError = "Couldn't confirm the new preferences. The sheet is still open."
                            }
                        }
                    } label: {
                        Label(isUpdating ? "Saving preferences…" : "Save preferences",
                              systemImage: isUpdating ? "arrow.triangle.2.circlepath" : "checkmark")
                            .frame(minHeight: 44)
                    }
                    .disabled(isUpdating)
                    .accessibilityIdentifier("feed.preferences.save")
                    Button(role: .destructive) {
                        guard !isUpdating else { return }
                        isUpdating = true
                        updateError = nil
                        let epoch = presentationEpoch
                        Task {
                            let confirmed = await onReset()
                            guard epoch == presentationEpoch else { return }
                            isUpdating = false
                            if confirmed {
                                selected.removeAll()
                                dismiss()
                            } else {
                                updateError = "Couldn't confirm resetting recommendations. Your selections are still shown."
                            }
                        }
                    } label: {
                        Label("Reset recommendations", systemImage: "arrow.counterclockwise")
                            .frame(minHeight: 44)
                    }
                    .disabled(isUpdating)
                    .accessibilityIdentifier("feed.preferences.reset")
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
            .onReceive(NotificationCenter.default.publisher(
                for: .hephaestusBackendSessionDidChange
            )) { _ in
                // Drop private muted-topic selections as soon as the viewer
                // changes; a late old-account response cannot re-open it.
                presentationEpoch &+= 1
                selected.removeAll()
                updateError = nil
                isUpdating = false
                dismiss()
            }
        }
    }
}
