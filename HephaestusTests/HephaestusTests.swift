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
