import AuthenticationServices
import AVFoundation
import Combine
import CryptoKit
import Network
import PhotosUI
import SwiftUI
import UIKit



/// A spoken Library action must distinguish the saved and recently played
/// collections even when the same real title appears in both. Normalize
/// only the accessibility label, never account data or the visible title.
enum LibraryGameRowAccessibilityPolicy {
    enum Scope {
        case saved
        case recent
    }

    static func label(title: String, scope: Scope) -> String {
        let safeText = title.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        let spokenTitle = safeText
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        switch scope {
        case .saved:
            return spokenTitle.isEmpty
                ? "Play saved game" : "Play saved game: \(spokenTitle)"
        case .recent:
            return spokenTitle.isEmpty
                ? "Play recently played game" : "Play recently played game: \(spokenTitle)"
        }
    }
}

// MARK: - Library

/// Recently played games.
struct LibraryView: View {
    let onOpenProfile: () -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var recent: [RecentGame] = []
    @State private var recentScopeKey: String?
    @State private var saved: [FeedGame] = []
    @State private var savedOwnerID: String?
    // Keep a fingerprint, not a second copy of the bearer credential.
    @State private var savedSessionDigest: Data?
    @State private var errorMessage: String?
    @State private var playerRequest: PixiPlayerRequest?
    @State private var showClearRecentConfirmation = false
    @State private var savedRequestRevision = 0
    @State private var isLoadingSaved = true

    // Identity changes must hide previous-account local titles even if a
    // retained view has not yet handled the session notification.
    private var visibleRecent: [RecentGame] {
        recentScopeKey == RecentGames.storageKey(for: BackendConfig.currentUserID)
            ? recent : []
    }

    private var visibleSaved: [FeedGame] {
        LibrarySavedRequestPolicy.canDisplay(
            loadedOwner: savedOwnerID, currentOwner: BackendConfig.currentUserID,
            loadedSessionDigest: savedSessionDigest,
            currentSessionDigest: LibrarySavedRequestPolicy.digest(
                BackendConfig.loadSessionToken()
            )
        ) ? saved : []
    }

    /// Zero is a real fact only after the current account's request succeeds.
    /// The deliberately empty fail-closed list is not evidence of zero saves.
    private var confirmedSavedCount: Int? {
        LibrarySavedCountPolicy.confirmedCount(
            visibleCount: visibleSaved.count,
            isSignedIn: !BackendConfig.currentUserID.isEmpty,
            isLoading: isLoadingSaved,
            hasError: errorMessage != nil,
            currentSessionData: LibrarySavedRequestPolicy.canDisplay(
                loadedOwner: savedOwnerID, currentOwner: BackendConfig.currentUserID,
                loadedSessionDigest: savedSessionDigest,
                currentSessionDigest: LibrarySavedRequestPolicy.digest(
                    BackendConfig.loadSessionToken()
                )
            )
        )
    }

    /// Show only a count confirmed for the active account and credential epoch.
    /// Distinguish a true zero from a guest, pending, or failed request.
    private var savedCountCaption: LibrarySavedCountCaption.Presentation {
        LibrarySavedCountCaption.presentation(
            confirmedCount: confirmedSavedCount,
            signedIn: !BackendConfig.currentUserID.isEmpty,
            loading: isLoadingSaved
        )
    }

    /// A stacked header leaves genuine account state readable at the largest
    /// text sizes instead of letting two competing columns truncate.
    private var savedGamesSectionHeader: some View {
        Group {
            if LibrarySavedCountLayout.stacks(
                for: dynamicTypeSize, compact: horizontalSizeClass == .compact
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Saved games")
                    savedCountStatus
                }
            } else {
                HStack {
                    Text("Saved games")
                    Spacer()
                    savedCountStatus
                }
            }
        }
    }

    private var savedCountStatus: some View {
        Text(savedCountCaption.visibleText)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("library.savedCount.status")
            .accessibilityLabel(savedCountCaption.accessibilityLabel)
    }

    /// When text is enormous and the available height is short, the guest
    /// needs the actual account route before the noninteractive arcade intro.
    /// Both sections remain present; iPad and normal text order never change.
    private var prioritizeGuestSignIn: Bool {
        LibraryGuestSignInPriorityPolicy.putsSignInFirst(
            isPhone: UIDevice.current.userInterfaceIdiom == .phone,
            isCompactHeight: verticalSizeClass == .compact,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
            isGuest: BackendConfig.currentUserID.isEmpty
        )
    }

    private var arcadeIntroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("YOUR ARCADE", systemImage: "gamecontroller.fill")
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(ArcadePulseTheme.neonMagenta)
                Text("Jump back into play")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("library.arcadePulse")
                Text("Saved and recently played games in one place.")
                    .font(.subheadline)
                    .foregroundStyle(ArcadePulseTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .listRowBackground(ArcadePulseTheme.surface)
        }
    }

    /// One actual Profile destination is owned by this control. In a short
    /// Accessibility5 landscape window it is hosted above the scroll view;
    /// in every other configuration it belongs to the Saved games row.
    /// Do not duplicate native accessibility actions or fake a signed-in state.
    private var guestSignInButton: some View {
        Button(action: onOpenProfile) {
            Label("Go to Profile to sign in", systemImage: "person.crop.circle")
                .font(.headline)
                .foregroundStyle(ArcadePulseTheme.onElectricViolet)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .tint(ArcadePulseTheme.electricViolet)
        .accessibilityIdentifier("library.signIn")
    }

    var body: some View {
        NavigationStack {
            List {
                if !prioritizeGuestSignIn {
                    arcadeIntroSection
                }
                // The empty-state recovery already explains fetch errors;
                // reserve this banner for failures while cards are visible.
                if let errorMessage, !visibleSaved.isEmpty {
                    Section {
                        Label(errorMessage, systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    if BackendConfig.currentUserID.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Sign in to see saved games", systemImage: "lock.fill")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text("Saved games belong to your account. Sign in from Profile to see and manage them here.")
                                .font(.subheadline)
                                .foregroundStyle(ArcadePulseTheme.textSecondary)
                            if !prioritizeGuestSignIn {
                                guestSignInButton
                            }
                        }
                        .padding(.vertical, 8)
                        .listRowBackground(ArcadePulseTheme.surface)
                    } else if isLoadingSaved && visibleSaved.isEmpty {
                        ProgressView("Loading saved games")
                            .frame(maxWidth: .infinity, minHeight: 80)
                            .listRowBackground(ArcadePulseTheme.surface)
                    } else if errorMessage != nil && visibleSaved.isEmpty {
                        VStack(spacing: 12) {
                            ContentUnavailableView(
                                "Saved games unavailable",
                                systemImage: "wifi.exclamationmark",
                                description: Text("Couldn't load your saved games. Check your connection and try again.")
                            )
                            Button {
                                Task { await load() }
                            } label: {
                                Label("Retry saved games", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("library.retrySaved")
                        }
                        .listRowBackground(ArcadePulseTheme.surface)
                    } else if visibleSaved.isEmpty {
                        ContentUnavailableView(
                            "No saved games yet",
                            systemImage: "bookmark",
                            description: Text("Save a game from Discover and it will be ready to play here.")
                        )
                    }
                    ForEach(visibleSaved) { game in
                        Button {
                            openGame(gameID: game.id, title: game.title)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "gamecontroller.fill")
                                    .font(.title3)
                                    .foregroundStyle(.white)
                                    .frame(width: 48, height: 48)
                                    .background(
                                        LinearGradient(colors: ArcadePulseTheme.fallbackPalette(gameID: game.id), startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(game.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                    if let caption = game.caption, !caption.isEmpty {
                                        Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "play.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(ArcadePulseTheme.playOrange)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(LibraryGameRowAccessibilityPolicy.label(
                            title: game.title, scope: .saved
                        ))
                        .accessibilityHint("Opens the game player")
                        .listRowBackground(ArcadePulseTheme.surface)
                        .contextMenu {
                            Button("Remove from saved", systemImage: "bookmark.slash", role: .destructive) {
                                Task { await removeSaved(game) }
                            }
                        }
                    }
                } header: {
                    savedGamesSectionHeader
                }

                if prioritizeGuestSignIn {
                    arcadeIntroSection
                }
                Section {
                    if visibleRecent.isEmpty {
                        ContentUnavailableView(
                            "No recent games",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("Games you play will appear here so you can jump back in.")
                        )
                    }
                    ForEach(visibleRecent) { game in
                        Button {
                            openGame(gameID: game.gameID, title: game.title)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.title3)
                                    .foregroundStyle(.white)
                                    .frame(width: 48, height: 48)
                                    .background(
                                        LinearGradient(colors: ArcadePulseTheme.fallbackPalette(gameID: game.gameID), startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(game.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                    Text("Recently played").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "play.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(ArcadePulseTheme.playOrange)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(LibraryGameRowAccessibilityPolicy.label(
                            title: game.title, scope: .recent
                        ))
                        .accessibilityHint("Opens the game player")
                        .listRowBackground(ArcadePulseTheme.surface)
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
                        Text("\(visibleRecent.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(BackendConfig.currentUserID.isEmpty
                         ? "Signed-out activity on this device. Cleared when you change accounts."
                         : "Recent activity for this account on this device.")
                        .fixedSize(horizontal: false, vertical: true)
                        // iPhone's translucent bottom tabs can visually cover
                        // the last line of the section footer. Keep enough
                        // trailing scroll space to read the privacy notice.
                        .padding(.bottom,
                                 UIDevice.current.userInterfaceIdiom == .phone ? 32 : 8)
                        .accessibilityIdentifier("library.privacyFooter")
                }
            }
            // A short iPhone landscape viewport can place the real saved-games
            // sign-in CTA beneath translucent system tabs. Reserve extra
            // SCROLLABLE trailing content space, not an overlay or a fake CTA:
            // the user can scroll the actual Library panel completely clear.
            // Regular iPad detail navigation keeps its native layout.
            .safeAreaInset(edge: .top, spacing: 0) {
                if prioritizeGuestSignIn {
                    // The old real CTA could disappear entirely from the
                    // Lazy List AX tree after a portrait→landscape rotation
                    // even after twelve physical swipes. Keep exactly the
                    // same real action in a measured, non-scrolling safe
                    // area instead of adding a second or test-only button.
                    guestSignInButton
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(ArcadePulseTheme.canvas)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: LibraryTabBarClearancePolicy.trailingScrollInset(
                        isPhone: UIDevice.current.userInterfaceIdiom == .phone,
                        isCompactHeight: verticalSizeClass == .compact
                    ))
                    .accessibilityHidden(true)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(ArcadePulseTheme.canvas)
            .preferredColorScheme(.dark)
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showClearRecentConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            // The inner Button, not only its ToolbarItem,
                            // must own a full native accessible touch target.
                            .frame(width: LibraryToolbarActionLayout.minimumHitSize,
                                   height: LibraryToolbarActionLayout.minimumHitSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear recent")
                    .accessibilityIdentifier("library.toolbar.clearRecent")
                    .disabled(visibleRecent.isEmpty)
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
            // Tabs may retain their child view while Discover saves/unsaves
            // another game. Refresh on each Library re-entry, not just mount.
            .onAppear { Task { await load() } }
            .onReceive(NotificationCenter.default.publisher(
                for: .hephaestusBackendSessionDidChange
            )) { _ in
                // Clear server-owned cards immediately, before scheduling
                // any asynchronous reload. Never display a prior account's
                // saved titles while the new session is being established.
                // Retire guest history before reading it regardless of
                // notification subscriber order with the root app view.
                RecentGames.clearGuestHistory()
                // Update the local Recent shelf synchronously as well.
                recent = RecentGames.load()
                recentScopeKey = RecentGames.storageKey(for: BackendConfig.currentUserID)
                savedRequestRevision += 1
                saved = []
                savedOwnerID = nil
                savedSessionDigest = nil
                errorMessage = nil
                isLoadingSaved = !BackendConfig.currentUserID.isEmpty
                playerRequest = nil
                Task { await load() }
            }
            .fullScreenCover(item: $playerRequest) { request in
                PixiPlayerSheet(gameID: request.gameID, title: request.title)
            }
        }
    }

    private func openGame(gameID: String, title: String) {
        // Library is another real Play entry. Record the actual requested
        // game in the current user's local shelf, never the global legacy key.
        RecentGames.record(gameID: gameID, title: title)
        recent = RecentGames.load()
        recentScopeKey = RecentGames.storageKey(for: BackendConfig.currentUserID)
        playerRequest = PixiPlayerRequest(gameID: gameID, title: title)
    }

    private func load() async {
        recent = RecentGames.load()
        recentScopeKey = RecentGames.storageKey(for: BackendConfig.currentUserID)
        savedRequestRevision += 1
        let revision = savedRequestRevision
        let owner = BackendConfig.currentUserID
        let credential = BackendConfig.loadSessionToken()

        guard !owner.isEmpty else {
            saved = []
            savedOwnerID = nil
            savedSessionDigest = nil
            errorMessage = nil
            isLoadingSaved = false
            return
        }

        isLoadingSaved = true
        defer {
            if LibrarySavedRequestPolicy.canApply(
                startedRevision: revision, currentRevision: savedRequestRevision,
                startedOwner: owner, currentOwner: BackendConfig.currentUserID,
                startedToken: credential, currentToken: BackendConfig.loadSessionToken()
            ) {
                isLoadingSaved = false
            }
        }
        do {
            let response = try await BackendAPI.shared.fetchSavedGames()
            guard !Task.isCancelled, LibrarySavedRequestPolicy.canApply(
                startedRevision: revision, currentRevision: savedRequestRevision,
                startedOwner: owner, currentOwner: BackendConfig.currentUserID,
                startedToken: credential, currentToken: BackendConfig.loadSessionToken()
            ) else { return }
            saved = response
            savedOwnerID = owner
            savedSessionDigest = LibrarySavedRequestPolicy.digest(credential)
            errorMessage = nil
        } catch {
            guard !Task.isCancelled, LibrarySavedRequestPolicy.canApply(
                startedRevision: revision, currentRevision: savedRequestRevision,
                startedOwner: owner, currentOwner: BackendConfig.currentUserID,
                startedToken: credential, currentToken: BackendConfig.loadSessionToken()
            ) else { return }
            saved = []
            savedOwnerID = owner
            savedSessionDigest = LibrarySavedRequestPolicy.digest(credential)
            errorMessage = "Couldn't load saved games. Check your connection and try again."
        }
    }

    private func removeSaved(_ game: FeedGame) async {
        let revision = savedRequestRevision
        let owner = BackendConfig.currentUserID
        let credential = BackendConfig.loadSessionToken()
        guard !owner.isEmpty else { return }
        do {
            try await BackendAPI.shared.setSaved(game.id, saved: false)
            guard LibrarySavedRequestPolicy.canApply(
                startedRevision: revision, currentRevision: savedRequestRevision,
                startedOwner: owner, currentOwner: BackendConfig.currentUserID,
                startedToken: credential, currentToken: BackendConfig.loadSessionToken()
            ) else { return }
            saved.removeAll { $0.id == game.id }
        } catch {
            guard LibrarySavedRequestPolicy.canApply(
                startedRevision: revision, currentRevision: savedRequestRevision,
                startedOwner: owner, currentOwner: BackendConfig.currentUserID,
                startedToken: credential, currentToken: BackendConfig.loadSessionToken()
            ) else { return }
            errorMessage = "Couldn't remove saved game. Please try again."
        }
    }
}

/// Make the actual native Library toolbar clear action target at least
/// 44pt square, independent of a ToolbarItem's decorative outer bounds.
enum LibraryToolbarActionLayout {
    static let minimumHitSize: CGFloat = ArcadePulseTheme.minimumTarget
}

/// Responsive Library header: don't force unrelated labels into a cramped row.
enum LibrarySavedCountLayout {
    static func stacks(for size: DynamicTypeSize, compact: Bool) -> Bool {
        size.isAccessibilitySize || (compact && (size == .xxLarge || size == .xxxLarge))
    }
}

/// Accessible, truthful presentation of the current account's confirmed
/// saved-game total. Display-only policy: no separate stale count cache.
enum LibrarySavedCountCaption {
    struct Presentation {
        let visibleText: String
        let accessibilityLabel: String
    }

    static func presentation(
        confirmedCount: Int?, signedIn: Bool, loading: Bool
    ) -> Presentation {
        if let count = confirmedCount, signedIn, !loading {
            return Presentation(visibleText: String(count),
                                accessibilityLabel: "\(count) saved games")
        }
        if !signedIn {
            return Presentation(visibleText: "Sign in",
                                accessibilityLabel: "Sign in to see saved-game count")
        }
        if loading {
            return Presentation(visibleText: "Loading",
                                accessibilityLabel: "Loading saved-game count")
        }
        return Presentation(visibleText: "Unavailable",
                            accessibilityLabel: "Saved games count unavailable")
    }
}

/// Keep the existing real Library CTA reachable on a short, huge-text
/// iPhone guest screen without dropping, shrinking or duplicating content.
/// Only visual order changes; identity and navigation are unchanged.
enum LibraryGuestSignInPriorityPolicy {
    static func putsSignInFirst(
        isPhone: Bool, isCompactHeight: Bool,
        isAccessibilitySize: Bool, isGuest: Bool
    ) -> Bool {
        isPhone && isCompactHeight && isAccessibilitySize && isGuest
    }
}

/// The system TabView can float over a compact iPhone landscape List.
/// A scroll-end inset is intentionally separate from the existing portrait
/// footer spacing: it must be enough for an actual 48pt CTA plus breathing
/// room above native tabs without taking space from the iPad sidebar.
enum LibraryTabBarClearancePolicy {
    static let compactPhoneTrailingInset: CGFloat = 72

    static func trailingScrollInset(isPhone: Bool, isCompactHeight: Bool) -> CGFloat {
        isPhone && isCompactHeight ? compactPhoneTrailingInset : 0
    }
}

/// A nil total means the backend has NOT confirmed a count for the current
/// account/session. In particular, a fail-closed empty shelf is not a zero.
enum LibrarySavedCountPolicy {
    static func confirmedCount(
        visibleCount: Int, isSignedIn: Bool, isLoading: Bool,
        hasError: Bool, currentSessionData: Bool
    ) -> Int? {
        guard isSignedIn, !isLoading, !hasError, currentSessionData else { return nil }
        return visibleCount
    }
}

/// An account's saved titles are private UI data. A completion from the
/// previous account, credential rotation or superseded refresh must never
/// change the currently visible Library. Do not log credential snapshots.
enum LibrarySavedRequestPolicy {
    static func digest(_ token: String?) -> Data? {
        guard let token, !token.isEmpty else { return nil }
        return Data(SHA256.hash(data: Data(token.utf8)))
    }

    static func canDisplay(
        loadedOwner: String?, currentOwner: String,
        loadedSessionDigest: Data?, currentSessionDigest: Data?
    ) -> Bool {
        guard let loadedOwner, !loadedOwner.isEmpty,
              let loadedSessionDigest, let currentSessionDigest else { return false }
        return loadedOwner == currentOwner &&
            loadedSessionDigest == currentSessionDigest
    }

    static func canApply(
        startedRevision: Int, currentRevision: Int,
        startedOwner: String, currentOwner: String,
        startedToken: String?, currentToken: String?
    ) -> Bool {
        startedRevision == currentRevision &&
        !startedOwner.isEmpty && startedOwner == currentOwner &&
        startedToken != nil && startedToken == currentToken
    }
}

// Profile and moderation appeal views live in Views/Profile/ProfileView.swift.
