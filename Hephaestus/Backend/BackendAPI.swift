import Combine
import Foundation

// MARK: - Models (mirror the backend JSON; see docs/API.md)

struct Element: Codable {
    var name: String
    var role: String
}

struct FeedGame: Codable, Identifiable {
    var id: String
    var title: String
    var ownerID: String?

    enum CodingKeys: String, CodingKey { case id, game_id, title, owner_id }

    // The backend has used both "id" and "game_id" for games; accept either.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decode(String.self, forKey: .id), !v.isEmpty {
            id = v
        } else {
            id = try c.decode(String.self, forKey: .game_id)
        }
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled Game"
        ownerID = try? c.decode(String.self, forKey: .owner_id)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .game_id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(ownerID, forKey: .owner_id)
    }
}

struct FeedResponse: Codable {
    var games: [FeedGame]
}

struct GameSocialSummary: Decodable {
    var game_id: String
    var reaction_count: Int
    var comment_count: Int
    var reacted_by_me: Bool
}

struct GameReactionResponse: Decodable {
    var game_id: String
    var reaction_count: Int
    var reacted_by_me: Bool
}

struct GameComment: Codable, Identifiable {
    var id: String
    var game_id: String
    var user_id: String
    var text: String
    var created_at: String
}

struct GameCommentsResponse: Decodable {
    var comments: [GameComment]
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
        let method = req.httpMethod ?? "GET"
        let path = req.url?.path ?? "?"
        let started = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                DevLog.error(.api, "\(method) \(path) -> \(status) (\(ms)ms)")
                throw APIError.badStatus(status)
            }
            DevLog.info(.api, "\(method) \(path) -> \(status) (\(ms)ms, \(data.count) B)")
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                DevLog.error(.api, "\(method) \(path) decode failed: \(error.localizedDescription)")
                throw APIError.decoding(error)
            }
        } catch let err as APIError {
            throw err
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            DevLog.error(.api, "\(method) \(path) network error (\(ms)ms): \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Endpoints

    func checkHealth() async {
        do {
            let req = try makeRequest("healthz")
            let (data, _) = try await session.data(for: req)
            isHealthy = (try? JSONDecoder().decode([String: String].self, from: data))?["status"] == "ok"
            DevLog.info(.api, "healthz -> \(isHealthy ? "ok" : "unexpected body")")
        } catch {
            isHealthy = false
            DevLog.warn(.api, "healthz failed: \(error.localizedDescription)")
        }
    }

    enum FeedScope: String {
        case forYou = "for_you"
        case following
        case friends
    }

    func fetchFeed(scope: FeedScope = .forYou) async throws -> [FeedGame] {
        let req = try makeRequest("v1/feed?scope=\(scope.rawValue)")
        return try await send(FeedResponse.self, req).games
    }

    private struct FollowingResponse: Decodable {
        var creator_ids: [String]
    }

    func fetchFollowingCreatorIDs() async throws -> Set<String> {
        let req = try makeRequest("v1/users/me/following")
        return Set(try await send(FollowingResponse.self, req).creator_ids)
    }

    private struct FollowResponse: Decodable {
        var following: Bool
    }

    func setFollowing(_ creatorID: String, follow: Bool) async throws {
        let method = follow ? "POST" : "DELETE"
        let req = try makeRequest("v1/users/\(creatorID)/follow", method: method, body: EmptyBody())
        let _: FollowResponse = try await send(FollowResponse.self, req)
    }

    func fetchSocialSummary(gameID: String) async throws -> GameSocialSummary {
        let req = try makeRequest("v1/games/\(gameID)/social")
        return try await send(GameSocialSummary.self, req)
    }

    func setReaction(gameID: String, active: Bool) async throws -> GameReactionResponse {
        let method = active ? "POST" : "DELETE"
        let req = try makeRequest("v1/games/\(gameID)/reaction", method: method, body: EmptyBody())
        return try await send(GameReactionResponse.self, req)
    }

    func fetchComments(gameID: String) async throws -> [GameComment] {
        let req = try makeRequest("v1/games/\(gameID)/comments")
        return try await send(GameCommentsResponse.self, req).comments
    }

    func createComment(gameID: String, text: String) async throws -> GameComment {
        struct CommentBody: Encodable { var text: String }
        let req = try makeRequest("v1/games/\(gameID)/comments", method: "POST", body: CommentBody(text: text))
        return try await send(GameComment.self, req)
    }

    // MARK: - Player telemetry + incidents (detect-and-fix flow)

    /// One telemetry report, mirroring the web runtime's beacon payload
    /// so the backend files web and native player events in one store.
    struct PlayerTelemetryReport: Encodable {
        var gameId: String
        var runtimeVersion: String
        var kind: String
        var name: String
        var message: String
        var stack: String = ""
        var logTail: [String] = []
    }

    /// Fire-and-forget: telemetry must never fail the user, so errors
    /// are swallowed by design (the dev log keeps the local record).
    func postPlayerTelemetry(_ report: PlayerTelemetryReport) async {
        guard let req = try? makeRequest("v1/telemetry/runtime-error", method: "POST", body: report) else { return }
        _ = try? await session.data(for: req)
    }

    struct IncidentSummary: Decodable, Identifiable {
        var fingerprint: String
        var count: Int
        var games: [String]
        var sampleName: String
        var sampleMessage: String
        var lastSeen: String
        var runtimeScope: Bool
        var id: String { fingerprint }
    }

    private struct IncidentsResponse: Decodable {
        var incidents: [IncidentSummary]
    }

    /// Aggregated runtime-error incidents from the backend (web + iOS
    /// player events in one view), worst first.
    func fetchIncidents() async throws -> [IncidentSummary] {
        let req = try makeRequest("v1/telemetry/incidents")
        return try await send(IncidentsResponse.self, req).incidents
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
