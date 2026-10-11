import PhotosUI
import SwiftUI

// MARK: - Shared pieces

/// What the player sheet should open.
struct PlayerRequest: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
}

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
    }
}

// MARK: - Discover

/// Public games feed. HTML5 games open the web player; Godot builds open directly.
struct DiscoverView: View {
    @State private var games: [FeedGame] = []
    @State private var godotGames: [GodotGame] = []
    @State private var playerRequest: PlayerRequest?
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
                Section("Games") {
                    ForEach(games) { game in
                        HStack {
                            Text(game.title)
                            Spacer()
                            Button("Play") {
                                RecentGames.record(gameID: game.id, title: game.title)
                                playerRequest = PlayerRequest(title: game.title, url: BackendConfig.playerURL)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                Section("Godot versions") {
                    ForEach(godotGames) { game in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(game.title)
                                Text("Godot 4 engine build")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Play") {
                                if let url = game.absoluteURL {
                                    RecentGames.record(gameID: game.id, title: game.title)
                                    playerRequest = PlayerRequest(title: game.title, url: url)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                            .disabled(!game.ready)
                        }
                    }
                }
            }
            .navigationTitle("Discover")
            .refreshable { await load() }
            .task { await load() }
            .sheet(item: $playerRequest) { req in
                PlayerSheet(title: req.title, url: req.url)
            }
            .overlay {
                if isLoading && games.isEmpty && godotGames.isEmpty {
                    ProgressView("Loading games…")
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        async let feed = BackendAPI.shared.fetchFeed()
        async let godot = BackendAPI.shared.fetchGodotGames()
        do {
            games = try await feed
            godotGames = try await godot
        } catch {
            errorMessage = error.localizedDescription
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
    @State private var playerRequest: PlayerRequest?

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
            .sheet(item: $playerRequest) { req in
                PlayerSheet(title: req.title, url: req.url)
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
                    if let data = try? await newItem?.loadTransferable(type: Data.self) {
                        imageData = data
                        previewImage = data.flatMap { UIImage(data: $0) }
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
                playerRequest = PlayerRequest(title: "Your game", url: BackendConfig.playerURL)
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

/// Godot builds plus recently played games.
struct LibraryView: View {
    @State private var godotGames: [GodotGame] = []
    @State private var recent: [RecentGame] = []
    @State private var playerRequest: PlayerRequest?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
                Section("Godot builds") {
                    ForEach(godotGames) { game in
                        HStack {
                            Text(game.title)
                            Spacer()
                            Button("Play") {
                                if let url = game.absoluteURL {
                                    RecentGames.record(gameID: game.id, title: game.title)
                                    playerRequest = PlayerRequest(title: game.title, url: url)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                            .disabled(!game.ready)
                        }
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
                recent = RecentGames.load()
            }
            .onAppear { recent = RecentGames.load() }
            .sheet(item: $playerRequest) { req in
                PlayerSheet(title: req.title, url: req.url)
            }
        }
    }

    private func load() async {
        do {
            godotGames = try await BackendAPI.shared.fetchGodotGames()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Profile

struct ProfileView: View {
    @State private var backendOK = false
    @State private var checked = false

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
            }
            .navigationTitle("Profile")
            .task {
                await BackendAPI.shared.checkHealth()
                backendOK = BackendAPI.shared.isHealthy
                checked = true
            }
        }
    }
}
