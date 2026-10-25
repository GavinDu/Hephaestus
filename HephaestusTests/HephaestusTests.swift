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
