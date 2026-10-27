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
    var creatorDisplayName: String?
    var creatorAvatarURL: String?
    var previewPosterURL: String?
    var previewClipURL: String?
    var previewAspect: Double?
    var previewDurationMS: Int?
    var previewDominantColor: String?
    var previewStatus: String?
    var likeCount: Int?
    var playStarts: Int?
    var completions: Int?
    var replays: Int?
    var shares: Int?
    var viewerLiked: Bool?
    var viewerSaved: Bool?
    var viewerFollowing: Bool?

    enum CodingKeys: String, CodingKey {
        case id, game_id, title, owner_id, caption, topics, published_at, published_version, remix_parent_id, moderation_status, created_at
        case creatorDisplayName = "creator_display_name", creatorAvatarURL = "creator_avatar_url"
        case previewPosterURL = "preview_poster_url", previewClipURL = "preview_clip_url", previewAspect = "preview_aspect"
        case previewDurationMS = "preview_duration_ms", previewDominantColor = "preview_dominant_color", previewStatus = "preview_status"
        case likeCount = "like_count", playStarts = "play_starts", completions, replays, shares
        case viewerLiked = "viewer_liked", viewerSaved = "viewer_saved", viewerFollowing = "viewer_following"
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
        creatorDisplayName = try? c.decode(String.self, forKey: .creatorDisplayName)
        creatorAvatarURL = try? c.decode(String.self, forKey: .creatorAvatarURL)
        previewPosterURL = try? c.decode(String.self, forKey: .previewPosterURL)
        previewClipURL = try? c.decode(String.self, forKey: .previewClipURL)
        previewAspect = try? c.decode(Double.self, forKey: .previewAspect)
        previewDurationMS = try? c.decode(Int.self, forKey: .previewDurationMS)
        previewDominantColor = try? c.decode(String.self, forKey: .previewDominantColor)
        previewStatus = try? c.decode(String.self, forKey: .previewStatus)
        likeCount = try? c.decode(Int.self, forKey: .likeCount)
        playStarts = try? c.decode(Int.self, forKey: .playStarts)
        completions = try? c.decode(Int.self, forKey: .completions)
        replays = try? c.decode(Int.self, forKey: .replays)
        shares = try? c.decode(Int.self, forKey: .shares)
        viewerLiked = try? c.decode(Bool.self, forKey: .viewerLiked)
        viewerSaved = try? c.decode(Bool.self, forKey: .viewerSaved)
        viewerFollowing = try? c.decode(Bool.self, forKey: .viewerFollowing)
    }

    mutating func apply(card: FeedCard) {
        ownerID = card.creator.id.isEmpty ? ownerID : card.creator.id
        caption = card.caption ?? caption
        topics = card.topics ?? topics
        creatorDisplayName = card.creator.display_name
        creatorAvatarURL = card.creator.avatar_url
        previewPosterURL = card.preview.poster_url
        previewClipURL = card.preview.clip_url
        previewAspect = card.preview.aspect
        previewDurationMS = card.preview.duration_ms
        previewDominantColor = card.preview.dominant_color
        previewStatus = card.preview.status
        likeCount = card.stats?.likes
        playStarts = card.stats?.play_starts
        completions = card.stats?.completions
        replays = card.stats?.replays
        shares = card.stats?.shares
        viewerLiked = card.viewer.liked
        viewerSaved = card.viewer.saved
        viewerFollowing = card.viewer.following
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
        try c.encodeIfPresent(creatorDisplayName, forKey: .creatorDisplayName)
        try c.encodeIfPresent(creatorAvatarURL, forKey: .creatorAvatarURL)
        try c.encodeIfPresent(previewPosterURL, forKey: .previewPosterURL)
        try c.encodeIfPresent(previewClipURL, forKey: .previewClipURL)
        try c.encodeIfPresent(previewAspect, forKey: .previewAspect)
        try c.encodeIfPresent(previewDurationMS, forKey: .previewDurationMS)
        try c.encodeIfPresent(previewDominantColor, forKey: .previewDominantColor)
        try c.encodeIfPresent(previewStatus, forKey: .previewStatus)
        try c.encodeIfPresent(likeCount, forKey: .likeCount)
        try c.encodeIfPresent(playStarts, forKey: .playStarts)
        try c.encodeIfPresent(completions, forKey: .completions)
        try c.encodeIfPresent(replays, forKey: .replays)
        try c.encodeIfPresent(shares, forKey: .shares)
        try c.encodeIfPresent(viewerLiked, forKey: .viewerLiked)
        try c.encodeIfPresent(viewerSaved, forKey: .viewerSaved)
        try c.encodeIfPresent(viewerFollowing, forKey: .viewerFollowing)
    }
}

struct FeedCard: Decodable {
    struct Creator: Decodable { var id: String; var display_name: String?; var avatar_url: String? }
    struct Preview: Decodable {
        var poster_url: String?; var clip_url: String?; var aspect: Double?; var duration_ms: Int?
        var dominant_color: String?; var status: String?
    }
    struct Stats: Decodable { var likes: Int?; var play_starts: Int?; var completions: Int?; var replays: Int?; var shares: Int? }
    struct Viewer: Decodable { var liked: Bool; var saved: Bool; var following: Bool }
    var game_id: String
    var title: String
    var caption: String?
    var topics: [String]?
    var creator: Creator
    var preview: Preview
    var stats: Stats?
    var viewer: Viewer
}

struct FeedResponse: Codable {
    var games: [FeedGame]
    var next_cursor: String?

    enum CodingKeys: String, CodingKey { case games, cards, next_cursor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var loaded = try c.decodeIfPresent([FeedGame].self, forKey: .games) ?? []
        let cards = (try? c.decode([FeedCard].self, forKey: .cards)) ?? []
        let byID = Dictionary(cards.map { ($0.game_id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in loaded.indices {
            if let card = byID[loaded[index].id] { loaded[index].apply(card: card) }
        }
        games = loaded
        next_cursor = try? c.decode(String.self, forKey: .next_cursor)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(games, forKey: .games)
        try c.encodeIfPresent(next_cursor, forKey: .next_cursor)
    }
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

struct VerifiedRunResult: Decodable, Identifiable {
    let runID: String
    let gameID: String
    let status: String
    let result: Outcome?
    let rank: Rank?

    var id: String { runID }

    struct Outcome: Decodable {
        let won: Bool
        let score: Int
        let durationMS: Int
        let completedAt: String?

        enum CodingKeys: String, CodingKey {
            case won, score
            case durationMS = "durationMs"
            case completedAt
        }
    }

    struct Rank: Decodable {
        let scope: String
        let position: Int
        let total: Int?
    }

    enum CodingKeys: String, CodingKey {
        case runID = "runId"
        case gameID = "gameId"
        case status, result, rank
    }

    var isVerified: Bool { status == "verified" && result != nil }
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
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "Backend returned HTTP \(code)."
        case .decoding(let e): return "Couldn't read the backend reply: \(e.localizedDescription)"
        case .invalidInput(let message): return message
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
    private struct EventBody: Encodable { var event_id: String; var game_id: String; var kind: String; var duration_ms: Int; var expected_duration_ms: Int; var preview_dwell_ms: Int = 0; var time_to_interactive_ms: Int = 0; var time_to_first_input_ms: Int = 0; var frame_time_p95_ms: Int = 0; var frame_time_avg_ms: Int = 0; var frame_count: Int = 0 }

    // MARK: - Sign in with Apple (#10)

    struct AppleSignInResponse: Decodable {
        var access_token: String
        var token_type: String
        var expires_in: Int
        var subject: String
    }
    struct DeleteAccountResponse: Decodable {
        var deleted: Bool
        var subject: String
    }
    private struct AppleSignInBody: Encodable { var identity_token: String }

    /// Exchanges a verified Apple identity token for a backend session
    /// token. The server verifies the token against Apple's keys; this
    /// method never invents an identity. The caller stores the returned
    /// access token in Keychain via BackendConfig.
    func signInWithApple(identityToken: String) async throws -> AppleSignInResponse {
        let req = try makeRequest("v1/auth/apple", method: "POST", body: AppleSignInBody(identity_token: identityToken))
        return try await send(AppleSignInResponse.self, req)
    }

    /// Deletes the signed-in account server-side (social data purged,
    /// subject tombstoned). The caller clears the local session after.
    func deleteAccount() async throws -> DeleteAccountResponse {
        let req = try makeRequest("v1/users/me", method: "DELETE")
        return try await send(DeleteAccountResponse.self, req)
    }

    func fetchFeed(scope: SocialFeedScope = .forYou, cursor: String? = nil) async throws -> FeedResponse {
        var path = "v1/feed?scope=\(scope.rawValue)&limit=20"
        if let cursor, !cursor.isEmpty { path += "&cursor=\(cursor)" }
        let req = try makeRequest(path)
        return try await send(FeedResponse.self, req)
    }

    func fetchVerifiedRunResult(runID: String) async throws -> VerifiedRunResult {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encodedRunID = runID.addingPercentEncoding(withAllowedCharacters: allowed), !encodedRunID.isEmpty else {
            throw APIError.invalidInput("Invalid run identifier.")
        }
        let req = try makeRequest("v1/runs/\(encodedRunID)/result")
        return try await send(VerifiedRunResult.self, req)
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

    func trackSocialEvent(gameID: String, kind: String, durationMS: Int = 0, expectedMS: Int = 0, previewDwellMS: Int = 0, timeToInteractiveMS: Int = 0, timeToFirstInputMS: Int = 0, frameTimeP95MS: Int = 0, frameTimeAvgMS: Int = 0, frameCount: Int = 0, eventID: String = UUID().uuidString) async {
        guard let req = try? makeRequest("v1/telemetry/social-event", method: "POST",
                                         body: EventBody(event_id: eventID, game_id: gameID, kind: kind, duration_ms: durationMS, expected_duration_ms: expectedMS, preview_dwell_ms: previewDwellMS, time_to_interactive_ms: timeToInteractiveMS, time_to_first_input_ms: timeToFirstInputMS, frame_time_p95_ms: frameTimeP95MS, frame_time_avg_ms: frameTimeAvgMS, frame_count: frameCount)) else { return }
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
        /// Test-feedback correlation id (docs/TESTING_FRAMEWORK.md §6);
        /// nil for ordinary sessions. Lets backend incidents be filtered
        /// to one simulator/physical run.
        var runId: String?
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
