import Foundation
import Testing
@testable import Hephaestus

// The Game IR runtime test suite retired with the native Swift
// interpreter (removed 2026-10-20 in the single-runtime consolidation).
// Runtime conformance now lives with the PixiJS + Rapier runtime in the
// backend repository, which interprets the same Game IR packages.
// App-level tests will regrow around the WebView player and the
// creation flow.
struct HephaestusTests {
    @Test func socialFeedScopesAreStableAndDistinct() {
        #expect(SocialFeedScope.allCases.map(\.rawValue) == ["for_you", "following", "friends"])
        #expect(SocialFeedScope.allCases.map(\.title) == ["For You", "Following", "Friends"])
    }

    @Test func moderationAppealAndContactResponsesDecode() throws {
        let appealJSON = """
        {"appeal_id":"appeal-1","status":"open","message":"queued for moderator review"}
        """.data(using: .utf8)!
        let appeal = try JSONDecoder().decode(BackendAPI.ModerationAppealResponse.self, from: appealJSON)
        #expect(appeal.appeal_id == "appeal-1")
        #expect(appeal.status == "open")

        let contactJSON = """
        {"contact_url":"https://example.test/moderation","contact_email":"safety@example.test","appeals_endpoint":"POST /v1/games/{id}/moderation-appeals","external_contact_configured":true}
        """.data(using: .utf8)!
        let contact = try JSONDecoder().decode(BackendAPI.ModerationContactResponse.self, from: contactJSON)
        #expect(contact.external_contact_configured)
        #expect(contact.contact_email == "safety@example.test")
    }

    @Test func productionRequestsDoNotTrustCallerSuppliedIdentity() {
        var request = URLRequest(url: URL(string: "https://example.test/v1/users/me")!)
        BackendConfig.applyAuthentication(to: &request)
        #expect(request.value(forHTTPHeaderField: "X-User-ID") == nil)
        if let token = BackendConfig.loadSessionToken() {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token)
        } else {
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
    }
    @Test func backendConfigIsSane() {
        #expect(BackendConfig.baseURL.scheme == "https")
        #expect(!BackendConfig.userID.isEmpty)
    }

    @Test func devLogRecordsAndExports() {
        let before = DevLog.shared.count
        DevLog.info(.app, "test entry")
        #expect(DevLog.shared.count == before + 1)
        #expect(DevLog.shared.exportText().contains("test entry"))
    }

    @Test func offlineOverlayOnlyAppearsWhileLoading() {
        #expect(PlayerLoadingPolicy.shouldShowOfflineOverlay(isOffline: true, isLoading: true, hasError: false))
        #expect(!PlayerLoadingPolicy.shouldShowOfflineOverlay(isOffline: true, isLoading: false, hasError: false))
        #expect(!PlayerLoadingPolicy.shouldShowOfflineOverlay(isOffline: true, isLoading: true, hasError: true))
        #expect(!PlayerLoadingPolicy.shouldShowOfflineOverlay(isOffline: false, isLoading: true, hasError: false))
    }
    @Test func playerLoadFailureMapsToFixedMessages() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline. https://example.test/player"])
        #expect(PlayerLoadFailure.category(for: offline) == .network)
        #expect(PlayerLoadFailure.userMessage(for: offline) == "Check your connection and try again.")
        // The raw detail (including the URL) must never reach the UI string.
        #expect(!PlayerLoadFailure.userMessage(for: offline).contains("example.test"))
        let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        #expect(PlayerLoadFailure.category(for: timedOut) == .network)
        let other = NSError(domain: "SomeOtherDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: "internal backend detail"])
        #expect(PlayerLoadFailure.category(for: other) == .unknown)
        #expect(PlayerLoadFailure.userMessage(for: other) == "The player couldn't load this game.")
        #expect(!PlayerLoadFailure.userMessage(for: other).contains("internal backend detail"))
    }
    @Test func previewDwellIsMeasuredNotFixed() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(FeedPreviewDwell.dwellMS(from: start, to: start.addingTimeInterval(2.5)) == 2_500)
        #expect(FeedPreviewDwell.dwellMS(from: start, to: start) == 0)
        // A clock jump backwards can never produce a negative dwell.
        #expect(FeedPreviewDwell.dwellMS(from: start, to: start.addingTimeInterval(-5)) == 0)
    }
    @Test func gameplayTelemetryQuickExitThresholdIsBounded() {
        #expect(GameplayTelemetryPolicy.shouldTrackQuickExit(durationMS: 0))
        #expect(GameplayTelemetryPolicy.shouldTrackQuickExit(durationMS: 4_999))
        #expect(!GameplayTelemetryPolicy.shouldTrackQuickExit(durationMS: 5_000))
        #expect(!GameplayTelemetryPolicy.shouldTrackQuickExit(durationMS: 12_000))
        #expect(!GameplayTelemetryPolicy.shouldTrackQuickExit(durationMS: -1))
    }
}


    @Test func feedGameDecodesSocialPostMetadata() throws {
        let json = """
        {
          "game_id": "game-1",
          "title": "Tiny Adventure",
          "owner_id": "creator-1",
          "caption": "A small story",
          "topics": ["puzzle", "family"],
          "published_version": 1,
          "moderation_status": "approved"
        }
        """.data(using: .utf8)!
        let game = try JSONDecoder().decode(FeedGame.self, from: json)
        #expect(game.id == "game-1")
        #expect(game.ownerID == "creator-1")
        #expect(game.caption == "A small story")
        #expect(game.topics == ["puzzle", "family"])
        #expect(game.publishedVersion == 1)
    }

    @Test func creatorDiscoveryDecodesSearchResultsAndCursor() throws {
        let json = """
        {
          "creators": [
            {
              "creator_id": "alice",
              "post_count": 3,
              "topics": ["puzzle", "family"]
            }
          ],
          "next_cursor": "alice"
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(CreatorDiscoveryResponse.self, from: json)
        #expect(response.creators.count == 1)
        #expect(response.creators[0].id == "alice")
        #expect(response.creators[0].post_count == 3)
        #expect(response.creators[0].topics == ["puzzle", "family"])
        #expect(response.next_cursor == "alice")
    }

    @Test func creatorDiscoveryDecodesEmptyResultsWithoutCursor() throws {
        let json = """
        {
          "creators": [],
          "next_cursor": ""
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(CreatorDiscoveryResponse.self, from: json)
        #expect(response.creators.isEmpty)
        #expect(response.next_cursor == "")
    }


@Test func playerForegroundRetryRequiresBackgroundErrorAndConnectivity() {
    #expect(PlayerLifecyclePolicy.shouldRetryAfterForeground(wasBackgrounded: true, isOffline: false, hasError: true))
    #expect(!PlayerLifecyclePolicy.shouldRetryAfterForeground(wasBackgrounded: true, isOffline: true, hasError: true))
    #expect(!PlayerLifecyclePolicy.shouldRetryAfterForeground(wasBackgrounded: true, isOffline: false, hasError: false))
    #expect(!PlayerLifecyclePolicy.shouldRetryAfterForeground(wasBackgrounded: false, isOffline: false, hasError: true))
}

@Test func feedResponseMergesVersionedCardsAndKeepsLegacyCompatibility() throws {
    let cardJSON = """
    {
      "games": [{"game_id":"game-1","title":"Orbit Garden","owner_id":"creator-1","caption":"Legacy caption"}],
      "cards": [{
        "game_id":"game-1","version":"7","title":"Orbit Garden","caption":"A cozy universe","topics":["space"],
        "creator":{"id":"creator-1","display_name":"Star Maker","avatar_url":"https://cdn.example.test/avatar.png"},
        "preview":{"poster_url":"https://cdn.example.test/poster.webp","clip_url":"https://cdn.example.test/clip.mp4","aspect":1.5,"duration_ms":6000,"dominant_color":"#334455","status":"ready"},
        "stats":{"likes":12,"play_starts":30,"completions":18},
        "viewer":{"liked":true,"saved":false,"following":true},
        "package":{"url":"/v1/games/game-1/package","min_runtime_version":"2026.10.23.2"}
      }],
      "next_cursor":"next"
    }
    """.data(using: .utf8)!
    let response = try JSONDecoder().decode(FeedResponse.self, from: cardJSON)
    #expect(response.games.count == 1)
    #expect(response.games[0].creatorDisplayName == "Star Maker")
    #expect(response.games[0].creatorAvatarURL == "https://cdn.example.test/avatar.png")
    #expect(response.games[0].previewPosterURL == "https://cdn.example.test/poster.webp")
    #expect(response.games[0].previewStatus == "ready")
    #expect(response.games[0].likeCount == 12)
    #expect(response.games[0].viewerLiked == true)
    #expect(response.games[0].viewerFollowing == true)
    #expect(response.next_cursor == "next")

    let legacyJSON = """
    {"games":[{"game_id":"old-game","title":"Old client payload"}]}
    """.data(using: .utf8)!
    let legacy = try JSONDecoder().decode(FeedResponse.self, from: legacyJSON)
    #expect(legacy.games.first?.id == "old-game")
    #expect(legacy.games.first?.previewPosterURL == nil)
    #expect(legacy.games.first?.viewerSaved == nil)
}


@Test func feedPreviewAutoplayRespectsMotionPowerAndNetworkPolicies() {
    #expect(FeedPreviewPolicy.shouldAutoplay(hasClip: true, reduceMotion: false, lowPowerMode: false, constrainedNetwork: false))
    #expect(!FeedPreviewPolicy.shouldAutoplay(hasClip: false, reduceMotion: false, lowPowerMode: false, constrainedNetwork: false))
    #expect(!FeedPreviewPolicy.shouldAutoplay(hasClip: true, reduceMotion: true, lowPowerMode: false, constrainedNetwork: false))
    #expect(!FeedPreviewPolicy.shouldAutoplay(hasClip: true, reduceMotion: false, lowPowerMode: true, constrainedNetwork: false))
    #expect(!FeedPreviewPolicy.shouldAutoplay(hasClip: true, reduceMotion: false, lowPowerMode: false, constrainedNetwork: true))
}

@Test func verifiedRunResultDecodesOutcomeAndRank() throws {
    let json = """
    {
      "runId": "run-1",
      "gameId": "game-1",
      "status": "verified",
      "result": {"won": true, "score": 420, "durationMs": 12800, "completedAt": "2026-10-26T23:59:12Z"},
      "rank": {"scope": "weekly", "position": 7, "total": 184}
    }
    """.data(using: .utf8)!
    let result = try JSONDecoder().decode(VerifiedRunResult.self, from: json)
    #expect(result.isVerified)
    #expect(result.runID == "run-1")
    #expect(result.gameID == "game-1")
    #expect(result.result?.score == 420)
    #expect(result.result?.durationMS == 12_800)
    #expect(result.rank?.position == 7)
}

@Test func unverifiedRunResultCannotBePresented() throws {
    let json = """
    {"runId":"run-2","gameId":"game-1","status":"pending","result":null}
    """.data(using: .utf8)!
    let result = try JSONDecoder().decode(VerifiedRunResult.self, from: json)
    #expect(!result.isVerified)
}
