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
}

// MARK: - Discover

/// The three feed destinations are visible now; social feeds stay honest until
/// authenticated account and relationship endpoints are available.
enum SocialFeedScope: String, CaseIterable, Identifiable {
    case forYou
    case following
    case friends

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forYou: "For You"
        case .following: "Following"
        case .friends: "Friends"
        }
    }
}

struct DiscoverView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedFeed: SocialFeedScope = .forYou
    @State private var games: [FeedGame] = []
    @State private var playerRequest: PixiPlayerRequest?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var feedLoadGeneration = 0
    @State private var followedCreatorIDs = Set<String>()
    @State private var isUpdatingFollow = false
    @State private var searchText = ""
    @State private var savedGameIDs = Set<String>()

    private var visibleGames: [FeedGame] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return games }
        return games.filter { $0.title.localizedCaseInsensitiveContains(query) }
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
                                    isFollowingCreator: game.ownerID.map { followedCreatorIDs.contains($0) } ?? false,
                                    canFollowCreator: game.ownerID != nil && game.ownerID != BackendConfig.userID,
                                    onPlay: { play(game) },
                                    onToggleSaved: { toggleSaved(game) },
                                    onToggleFollow: {
                                        if let ownerID = game.ownerID {
                                            Task { await toggleFollow(ownerID) }
                                        }
                                    }
                                )
                            }
                        }
                        .frame(maxWidth: 1120)
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
            .task(id: selectedFeed) {
                savedGameIDs = Set(UserDefaults.standard.stringArray(forKey: "hephaestus.savedGames") ?? [])
                await refreshFollowing()
                await load()
            }
            .fullScreenCover(item: $playerRequest) { request in
                PixiPlayerSheet(gameID: request.gameID, title: request.title)
            }
        }
    }

    private func play(_ game: FeedGame) {
        RecentGames.record(gameID: game.id, title: game.title)
        playerRequest = PixiPlayerRequest(gameID: game.id, title: game.title)
    }

    private func toggleSaved(_ game: FeedGame) {
        if savedGameIDs.contains(game.id) {
            savedGameIDs.remove(game.id)
        } else {
            savedGameIDs.insert(game.id)
        }
        UserDefaults.standard.set(savedGameIDs.sorted(), forKey: "hephaestus.savedGames")
    }

    private func refreshFollowing() async {
        do {
            followedCreatorIDs = try await BackendAPI.shared.fetchFollowingCreatorIDs()
        } catch {
            DevLog.warn(.api, "following list unavailable: \\(error.localizedDescription)")
        }
    }

    private func toggleFollow(_ creatorID: String) async {
        guard !isUpdatingFollow else { return }
        isUpdatingFollow = true
        defer { isUpdatingFollow = false }
        let shouldFollow = !followedCreatorIDs.contains(creatorID)
        do {
            try await BackendAPI.shared.setFollowing(creatorID, follow: shouldFollow)
            if shouldFollow {
                followedCreatorIDs.insert(creatorID)
            } else {
                followedCreatorIDs.remove(creatorID)
            }
            await load()
        } catch {
            errorMessage = "Couldn't update follow: \\(error.localizedDescription)"
        }
    }

    private func load() async {
        feedLoadGeneration += 1
        let generation = feedLoadGeneration
        isLoading = true
        defer {
            if generation == feedLoadGeneration {
                isLoading = false
            }
        }
        errorMessage = nil
        let scope: BackendAPI.FeedScope
        switch selectedFeed {
        case .forYou: scope = .forYou
        case .following: scope = .following
        case .friends: scope = .friends
        }
        do {
            let result = try await BackendAPI.shared.fetchFeed(scope: scope)
            guard generation == feedLoadGeneration else { return }
            games = result
        } catch {
            guard generation == feedLoadGeneration else { return }
            errorMessage = error.localizedDescription
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
    let game: FeedGame
    let isSaved: Bool
    let isFollowingCreator: Bool
    let canFollowCreator: Bool
    let onPlay: () -> Void
    let onToggleSaved: () -> Void
    let onToggleFollow: () -> Void

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
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                }
                .padding(18)
            }
            .frame(height: 220)
            .clipped()

            HStack(spacing: 10) {
                Label("Mini game", systemImage: "sparkles")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if canFollowCreator {
                    Button(action: onToggleFollow) {
                        Label(isFollowingCreator ? "Following" : "Follow",
                              systemImage: isFollowingCreator ? "person.fill.checkmark" : "person.badge.plus")
                            .font(.caption.weight(.semibold))
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isFollowingCreator ? "Unfollow creator" : "Follow creator")
                }
                Button(action: onToggleSaved) {
                    Label(isSaved ? "Saved" : "Save",
                          systemImage: isSaved ? "heart.fill" : "heart")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSaved ? Color.pink : Color.primary)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSaved ? "Remove saved game" : "Save game")
                ShareLink(item: "Play “\(game.title)” in Hephaestus (game ID: \(game.id))") {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Circle())
                }
                .accessibilityLabel("Share game")
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
            .padding(14)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 5)
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
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Your game is ready!").font(.title2)
            Button("Play now") {
                playerRequest = PixiPlayerRequest(gameID: gameID, title: "Your game")
            }
            .buttonStyle(.borderedProminent)
            Button("Make another") { reset() }
        }
        .padding()
    }

    private func reset() {
        phase = .pick
        pickerItem = nil
        imageData = nil
        previewImage = nil
        keywordsText = ""
        intentText = ""
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
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
                Section("Recently played") {
                    if recent.isEmpty {
                        Text("Nothing yet — play a game from Discover.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(recent) { game in
                        Text(game.title)
                    }
                }
            }
            .navigationTitle("Library")
            .refreshable { await load() }
            .task {
                await load()
            }
            .onAppear { recent = RecentGames.load() }
        }
    }

    private func load() async {
        recent = RecentGames.load()
    }
}

// MARK: - Profile

struct ProfileView: View {
    @State private var backendOK = false
    @State private var checked = false
    @State private var logEntries = DevLog.shared.count
    @State private var incidents: [BackendAPI.IncidentSummary] = []
    @State private var incidentsLoaded = false
    @State private var incidentsError: String?
    @AppStorage(PlayerQuality.defaultsKey) private var qualityRaw = PlayerQuality.auto.rawValue

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    HStack {
                        Text("User ID")
                        Spacer()
                        Text(BackendConfig.userID)
                            .foregroundStyle(.secondary)
                    }
                    Text("Parent-owned account — sign-in with Apple coming soon.")
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
                    if let incidentsError {
                        Text(incidentsError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if incidentsLoaded && incidents.isEmpty {
                        Text("No incidents reported — players are healthy.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(incidents.prefix(5)) { inc in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("×\(inc.count) \(inc.sampleName)\(inc.runtimeScope ? " · runtime-wide" : "")")
                                    .font(.subheadline)
                                Text(inc.games.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Button("Refresh player health") {
                        Task { await loadIncidents() }
                    }
                }
            }
            .navigationTitle("Profile")
            .onAppear { logEntries = DevLog.shared.count }
            .task {
                await BackendAPI.shared.checkHealth()
                backendOK = BackendAPI.shared.isHealthy
                checked = true
                await loadIncidents()
            }
        }
    }

    private func loadIncidents() async {
        do {
            incidents = try await BackendAPI.shared.fetchIncidents()
            incidentsError = nil
            incidentsLoaded = true
        } catch {
            incidentsError = "Couldn't load incidents: \(error.localizedDescription)"
            incidentsLoaded = true
        }
    }
}
