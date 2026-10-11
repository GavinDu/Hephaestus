import Foundation

// MARK: - Models (mirror the backend JSON; see docs/API.md)

struct Element: Codable {
    var name: String
    var role: String
}

struct FeedGame: Codable, Identifiable {
    var id: String
    var title: String

    enum CodingKeys: String, CodingKey { case id, game_id, title }

    // The backend has used both "id" and "game_id" for games; accept either.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decode(String.self, forKey: .id), !v.isEmpty {
            id = v
        } else {
            id = try c.decode(String.self, forKey: .game_id)
        }
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled Game"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .game_id)
        try c.encode(title, forKey: .title)
    }
}

struct FeedResponse: Codable {
    var games: [FeedGame]
}

/// One Godot web build, from GET /v1/godot.
struct GodotGame: Codable, Identifiable {
    var id: String
    var title: String
    var ready: Bool
    var url: String // relative, e.g. "/godot/bobos-rainbow/"

    var absoluteURL: URL? {
        URL(string: url, relativeTo: BackendConfig.baseURL)?.absoluteURL
    }
}

struct IngestResult: Codable {
    var ingest_id: String
    var elements: [Element]
    var guessed_intent: String?
}

struct DesignDoc: Codable {
    var title: String
    var plot: String?
    var mechanics: String?
    var controls: [String]?
    var win_condition: String?
    var lose_condition: String?
    var music_mood: String?
}

struct JobStatus: Codable {
    var job_id: String
    var game_id: String
    var status: String // queued | running | awaiting_confirm | done | failed
    var design_doc: DesignDoc?
    var error: String?
}

struct GameDetail: Codable {
    var game_id: String
    var title: String?
    var status: String?
    var job_id: String?
}

struct CreateGameResponse: Codable {
    var game: GameDetail
    var job: JobStatus
}

// MARK: - API client

enum APIError: Error, LocalizedError {
    case badStatus(Int)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "Backend returned HTTP \(code)."
        case .decoding(let e): return "Couldn't read the backend reply: \(e.localizedDescription)"
        }
    }
}

/// Thin async client for the DoodleQuest backend. One shared instance;
/// the user id goes out as the X-User-ID header (stub for Sign in with Apple).
@MainActor
final class BackendAPI: ObservableObject {
    static let shared = BackendAPI()

    @Published private(set) var isHealthy = false

    private let session = URLSession.shared

    private func url(_ path: String) -> URL {
        URL(string: BackendConfig.baseURL.absoluteString + "/" + path)!
    }

    private func makeRequest(_ path: String, method: String = "GET", body: Encodable? = nil) throws -> URLRequest {
        var req = URLRequest(url: url(path))
        req.httpMethod = method
        req.setValue(BackendConfig.userID, forHTTPHeaderField: "X-User-ID")
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        return req
    }

    private func send<T: Decodable>(_ type: T.Type, _ req: URLRequest) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    // MARK: - Endpoints

    func checkHealth() async {
        do {
            let req = try makeRequest("healthz")
            let (data, _) = try await session.data(for: req)
            isHealthy = (try? JSONDecoder().decode([String: String].self, from: data))?["status"] == "ok"
        } catch {
            isHealthy = false
        }
    }

    func fetchFeed() async throws -> [FeedGame] {
        let req = try makeRequest("v1/feed")
        return try await send(FeedResponse.self, req).games
    }

    func fetchGodotGames() async throws -> [GodotGame] {
        let req = try makeRequest("v1/godot")
        return try await send([GodotGame].self, req)
    }

    struct IngestBody: Encodable {
        var images: [[String: String]]
        var keywords: [String]
    }

    /// Analyze a drawing photo. `imageData` should be JPEG/PNG bytes.
    func ingest(imageData: Data, keywords: [String]) async throws -> IngestResult {
        let dataURL = "data:image/jpeg;base64," + imageData.base64EncodedString()
        let body = IngestBody(images: [["data_url": dataURL]], keywords: keywords)
        let req = try makeRequest("v1/ingest", method: "POST", body: body)
        return try await send(IngestResult.self, req)
    }

    struct CreateGameBody: Encodable {
        var ingest_id: String
        var elements: [Element]
        var intent: String
    }

    func createGame(ingestID: String, elements: [Element], intent: String) async throws -> CreateGameResponse {
        let body = CreateGameBody(ingest_id: ingestID, elements: elements, intent: intent)
        let req = try makeRequest("v1/games", method: "POST", body: body)
        return try await send(CreateGameResponse.self, req)
    }

    func fetchJob(id: String) async throws -> JobStatus {
        let req = try makeRequest("v1/jobs/\(id)")
        return try await send(JobStatus.self, req)
    }

    struct EmptyBody: Encodable {}

    /// Confirm the design doc; generation resumes afterwards.
    func confirmGame(id: String) async throws {
        let req = try makeRequest("v1/games/\(id)/confirm", method: "POST", body: EmptyBody())
        let _: JobStatus = try await send(JobStatus.self, req)
    }
}
