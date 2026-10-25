import Combine
import Foundation

enum BackendAPIError: LocalizedError {
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message): message
        }
    }
}

// MARK: - Models (mirror the backend JSON; see docs/API.md)

struct Element: Codable {
    var name: String
    var role: String
}

struct FeedGame: Codable, Identifiable {
    var id: String
    var title: String
    var ownerID: String?
    var caption: String?
    var topics: [String]?
    var publishedAt: String?
    var publishedVersion: Int?
    var remixParentID: String?
    var moderationStatus: String?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, game_id, title, owner_id, caption, topics, published_at, published_version, remix_parent_id, moderation_status, created_at
    }

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
        caption = try? c.decode(String.self, forKey: .caption)
        topics = try? c.decode([String].self, forKey: .topics)
        publishedAt = try? c.decode(String.self, forKey: .published_at)
        publishedVersion = try? c.decode(Int.self, forKey: .published_version)
        remixParentID = try? c.decode(String.self, forKey: .remix_parent_id)
        moderationStatus = try? c.decode(String.self, forKey: .moderation_status)
        createdAt = try? c.decode(String.self, forKey: .created_at)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .game_id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(ownerID, forKey: .owner_id)
        try c.encodeIfPresent(caption, forKey: .caption)
        try c.encodeIfPresent(topics, forKey: .topics)
        try c.encodeIfPresent(publishedAt, forKey: .published_at)
        try c.encodeIfPresent(publishedVersion, forKey: .published_version)
        try c.encodeIfPresent(remixParentID, forKey: .remix_parent_id)
        try c.encodeIfPresent(moderationStatus, forKey: .moderation_status)
        try c.encodeIfPresent(createdAt, forKey: .created_at)
    }
}

struct FeedResponse: Codable {
    var games: [FeedGame]
    var next_cursor: String?
}

enum SocialFeedScope: String, CaseIterable, Identifiable {
    case forYou = "for_you"
    case following
    case friends
    var id: String { rawValue }
    var title: String {
        switch self { case .forYou: "For You"; case .following: "Following"; case .friends: "Friends" }
    }
}

struct SocialComment: Decodable, Identifiable {
    var id: String
    var game_id: String
    var user_id: String
    var body: String
    var created_at: String
}

struct CreatorProfile: Decodable {
    var creator_id: String
    var posts: [FeedGame]
    var post_count: Int
    var follower_count: Int
    var following_count: Int
    var is_following: Bool
    var is_friend: Bool
}

struct CreatorDiscoveryEntry: Decodable, Identifiable {
    var creator_id: String
    var post_count: Int
    var topics: [String]
    var id: String { creator_id }
}

struct CreatorDiscoveryResponse: Decodable {
    var creators: [CreatorDiscoveryEntry]
    var next_cursor: String?
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

/// Thin async client for the DoodleQuest backend. One shared instance.
/// Identity is derived from a Keychain-backed bearer token. The legacy
/// X-User-ID header is disabled unless a developer explicitly opts in.
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
        BackendConfig.applyAuthentication(to: &req)
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

    private struct ActionResponse: Decodable {
        var following: Bool?
        var saved: Bool?
        var accepted: Bool?
        var report_id: String?
        var status: String?
    }
    private struct FollowingResponse: Decodable { var creator_ids: [String] }
    private struct CommentsResponse: Decodable { var comments: [SocialComment] }
    private struct CommentResponse: Decodable { var comment: SocialComment }
    private struct PostResponse: Decodable { var post: FeedGame }
    private struct PublishBody: Encodable { var caption: String; var topics: [String]; var remix_parent_id: String? }
    private struct ReactionBody: Encodable { var reaction: String }
    private struct CommentBody: Encodable { var body: String }
    private struct ReportBody: Encodable { var reason: String }
    private struct FeedbackBody: Encodable { var kind: String }
    private struct TopicPreferencesBody: Encodable { var muted_topics: [String] }
    private struct TopicPreferencesResponse: Decodable { var muted_topics: [String] }
    struct FeedPreferences: Decodable { var muted_topics: [String]; var not_interested_game_ids: [String] }
    struct ModerationAppealResponse: Decodable {
        var appeal_id: String
        var status: String
        var message: String
    }
    struct ModerationContactResponse: Decodable {
        var contact_url: String
        var contact_email: String
        var appeals_endpoint: String
        var external_contact_configured: Bool
    }
    private struct ModerationAppealBody: Encodable { var reason: String }
    private struct EventBody: Encodable { var event_id: String; var game_id: String; var kind: String; var duration_ms: Int; var expected_duration_ms: Int }

    func fetchFeed(scope: SocialFeedScope = .forYou, cursor: String? = nil) async throws -> FeedResponse {
        var path = "v1/feed?scope=\(scope.rawValue)&limit=20"
        if let cursor, !cursor.isEmpty { path += "&cursor=\(cursor)" }
        let req = try makeRequest(path)
        return try await send(FeedResponse.self, req)
    }

    func fetchFollowingCreatorIDs() async throws -> Set<String> {
        let req = try makeRequest("v1/users/me/following")
        return Set(try await send(FollowingResponse.self, req).creator_ids)
    }

    func setFollowing(_ creatorID: String, following: Bool) async throws {
        let method = following ? "POST" : "DELETE"
        let req = try makeRequest("v1/users/\(creatorID)/follow", method: method)
        let _: ActionResponse = try await send(ActionResponse.self, req)
    }

    func fetchSavedGames() async throws -> [FeedGame] {
        let req = try makeRequest("v1/users/me/saved")
        return try await send(FeedResponse.self, req).games
    }

    func fetchSavedGameIDs() async throws -> Set<String> {
        let games = try await fetchSavedGames()
        return Set(games.map(\.id))
    }

    func setSaved(_ gameID: String, saved: Bool) async throws {
        let method = saved ? "POST" : "DELETE"
        let req = try makeRequest("v1/games/\(gameID)/save", method: method)
        let _: ActionResponse = try await send(ActionResponse.self, req)
    }

    func setReaction(_ gameID: String, reaction: String?) async throws {
        let req: URLRequest
        if let reaction {
            req = try makeRequest("v1/games/\(gameID)/reactions", method: "POST", body: ReactionBody(reaction: reaction))
        } else {
            req = try makeRequest("v1/games/\(gameID)/reactions", method: "DELETE")
        }
        let _: ActionResponse = try await send(ActionResponse.self, req)
    }

    func fetchComments(gameID: String) async throws -> [SocialComment] {
        let req = try makeRequest("v1/games/\(gameID)/comments")
        return try await send(CommentsResponse.self, req).comments
    }

    func addComment(gameID: String, body: String, idempotencyKey: String) async throws -> SocialComment {
        var req = try makeRequest("v1/games/\(gameID)/comments", method: "POST", body: CommentBody(body: body))
        req.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        return try await send(CommentResponse.self, req).comment
    }

    func deleteComment(gameID: String, commentID: String) async throws {
        let req = try makeRequest("v1/games/\(gameID)/comments/\(commentID)", method: "DELETE")
        let _: ActionResponse = try await send(ActionResponse.self, req)
    }

    func reportGame(gameID: String, reason: String) async throws {
        let req = try makeRequest("v1/games/\(gameID)/report", method: "POST", body: ReportBody(reason: reason))
        let _: ActionResponse = try await send(ActionResponse.self, req)
    }

    /// Submit an appeal for a creator-owned game that has been rejected or quarantined.
    /// The backend queues the appeal for moderator review; this does not restore publication.
    func submitModerationAppeal(gameID: String, reason: String) async throws -> ModerationAppealResponse {
        let boundedReason = String(reason.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(1000))
        guard !boundedReason.isEmpty else {
            throw BackendAPIError.invalidInput("Appeal reason is required.")
        }
        let req = try makeRequest(
            "v1/games/\(gameID)/moderation-appeals",
            method: "POST",
            body: ModerationAppealBody(reason: boundedReason)
        )
        return try await send(ModerationAppealResponse.self, req)
    }

    func fetchModerationContact() async throws -> ModerationContactResponse {
        let req = try makeRequest("v1/moderation/contact")
        return try await send(ModerationContactResponse.self, req)
    }

    func blockCreator(_ creatorID: String, blocked: Bool) async throws {
        let method = blocked ? "POST" : "DELETE"
        let req = try makeRequest("v1/users/\(creatorID)/block", method: method)
        let _: ActionResponse = try await send(ActionResponse.self, req)
    }

    func markNotInterested(gameID: String) async throws {
        let req = try makeRequest("v1/games/\(gameID)/feedback", method: "POST", body: FeedbackBody(kind: "not_interested"))
        let _: ActionResponse = try await send(ActionResponse.self, req)
    }

    func fetchFeedPreferences() async throws -> FeedPreferences {
        let req = try makeRequest("v1/users/me/preferences")
        return try await send(FeedPreferences.self, req)
    }

    func setMutedTopics(_ topics: [String]) async throws {
        let req = try makeRequest("v1/users/me/preferences/topics", method: "PUT",
                                  body: TopicPreferencesBody(muted_topics: topics))
        let _: TopicPreferencesResponse = try await send(TopicPreferencesResponse.self, req)
    }

    func resetFeedPreferences() async throws {
        let req = try makeRequest("v1/users/me/preferences", method: "DELETE")
        let _: ActionResponse = try await send(ActionResponse.self, req)
    }

    func trackSocialEvent(gameID: String, kind: String, durationMS: Int = 0, expectedMS: Int = 0, eventID: String = UUID().uuidString) async {
        guard let req = try? makeRequest("v1/telemetry/social-event", method: "POST",
                                         body: EventBody(event_id: eventID, game_id: gameID, kind: kind, duration_ms: durationMS, expected_duration_ms: expectedMS)) else { return }
        _ = try? await session.data(for: req)
    }

    func fetchCreatorProfile(id: String) async throws -> CreatorProfile {
        let req = try makeRequest("v1/users/\(id)")
        return try await send(CreatorProfile.self, req)
    }

    func fetchCreators(query: String = "", topic: String = "", cursor: String? = nil) async throws -> CreatorDiscoveryResponse {
        guard let components = URLComponents(url: url("v1/creators"), resolvingAgainstBaseURL: false) else {
            throw APIError.badStatus(-1)
        }
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: "20")]
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty { items.append(URLQueryItem(name: "q", value: trimmedQuery)) }
        if !trimmedTopic.isEmpty { items.append(URLQueryItem(name: "topic", value: trimmedTopic)) }
        if let cursor, !cursor.isEmpty { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        var requestComponents = components
        requestComponents.queryItems = items
        guard let requestURL = requestComponents.url else { throw APIError.badStatus(-1) }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        BackendConfig.applyAuthentication(to: &request)
        return try await send(CreatorDiscoveryResponse.self, request)
    }

    func publishPost(gameID: String, caption: String, topics: [String], remixParentID: String? = nil) async throws -> FeedGame {
        let body = PublishBody(caption: caption, topics: topics, remix_parent_id: remixParentID)
        let req = try makeRequest("v1/games/\(gameID)/publish", method: "POST", body: body)
        return try await send(PostResponse.self, req).post
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
