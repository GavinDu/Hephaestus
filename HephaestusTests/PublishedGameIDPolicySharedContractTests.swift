import Foundation
import Testing
@testable import Hephaestus

/// #653: native player, prewarm and verified-only leaderboard share one
/// public GamePackage ID grammar, but syntax alone never grants privileges.
struct PublishedGameIDPolicySharedContractTests {
    @Test func bothInstalledCallersShareAllCanonicalBoundaries() {
        #expect(PublishedGameIDPolicy.maximumUTF8Bytes == 128)
        for valid in ["A", "_", "-", "game-1", "GAME_2026",
                      String(repeating: "z", count: 128)] {
            #expect(PublishedGameIDPolicy.valid(valid))
            #expect(PlayerPublishedGameIDPolicy.valid(valid))
            #expect(VerifiedLeaderboardGameIDPolicy.valid(valid))
        }
        for invalid in ["", ".", "..", "a.b", "a/b", "a?b", "a#b", "a%b",
                        "a+b", "a=b", "a b", "\t", "\n",
                        "🤖", "e\u{301}", String(repeating: "z", count: 129)] {
            #expect(!PublishedGameIDPolicy.valid(invalid))
            #expect(!PlayerPublishedGameIDPolicy.valid(invalid))
            #expect(!VerifiedLeaderboardGameIDPolicy.valid(invalid))
        }
    }

    @Test func adversarial160IdentifiersAlwaysAgreeWithoutCopyingHugeInput() {
        for n in 0..<160 {
            let boundary = String(repeating: "x", count: n)
            let path = "bad/" + boundary
            let unicode = "🎮" + boundary
            let query = "game?" + boundary
            let ids = [boundary, path, unicode, query, "-" + boundary, "_" + boundary]
            for id in ids {
                let expected = PublishedGameIDPolicy.valid(id)
                #expect(PlayerPublishedGameIDPolicy.valid(id) == expected)
                #expect(VerifiedLeaderboardGameIDPolicy.valid(id) == expected)
            }
        }
        // A large already-created untrusted feed string must fail without
        // a second full-size UTF-8 array allocation by either native caller.
        let large = String(repeating: "G", count: 262_144)
        #expect(!PublishedGameIDPolicy.valid(large))
        #expect(!PlayerPublishedGameIDPolicy.valid(large))
        #expect(!VerifiedLeaderboardGameIDPolicy.valid(large))
    }

    @MainActor @Test func actualNativePlayerURLBuilderRejectsInvalidIDsBeforeNavigation() {
        for bad in ["", "../bad", "bad/id", "bad?x", "bad#hash", "🎮",
                    String(repeating: "a", count: 129)] {
            #expect(PlayerWebViewPool.playerURL(gameID: bad) == nil)
        }
        let gameID = String(repeating: "g", count: 128)
        let url = PlayerWebViewPool.playerURL(gameID: gameID)
        #expect(url != nil)
        let components = url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        }
        #expect(components?.path == "/player")
        #expect(components?.queryItems?.filter { $0.name == "game" }.count == 1)
        #expect(components?.queryItems?.first(where: { $0.name == "game" })?.value == gameID)
    }
}
