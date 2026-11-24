import Foundation
import Testing
@testable import Hephaestus

struct PlayerCompletedPrewarmReusePolicyTests {
    @Test func onlyCurrentUnconsumedScenePermitsCompletedWarmHit() throws {
        let url = try #require(URL(string: "https://example.com/player?game=game_1"))
        let otherURL = try #require(URL(string: "https://example.com/player?game=game_2"))
        let nonce = String(repeating: "a", count: 32)
        let wrongNonce = String(repeating: "b", count: 32)
        let identity = PlayerPrewarmSceneMilestoneLedger.Identity(
            gameID: "game_1", playerURL: url, documentNonce: nonce,
            credentialFingerprint: "scope", runtimeSessionID: "session_1"
        )
        let scene = PlayerPrewarmSceneMilestoneLedger.Submission(
            identity: identity, sequence: 1, milliseconds: 300
        )
        for _ in 0..<160 {
            for flags in 0..<8 {
                let started = flags & 1 != 0
                let speculative = flags & 2 != 0
                let transferred = flags & 4 != 0
                let result = PlayerCompletedPrewarmReusePolicy.permitsWarmHit(
                    scene, expectedURL: url, currentNonce: nonce,
                    credentialFingerprint: "scope", navigationStarted: started,
                    isSpeculative: speculative, hasTransferred: transferred
                )
                #expect(result == (started && speculative && !transferred))
            }
            for (candidate, expectedURL, currentNonce, scope) in [
                (nil as PlayerPrewarmSceneMilestoneLedger.Submission?, url, nonce, "scope"),
                (scene, otherURL, nonce, "scope"),
                (scene, url, wrongNonce, "scope"),
                (scene, url, nonce, "other")
            ] {
                #expect(!PlayerCompletedPrewarmReusePolicy.permitsWarmHit(
                    candidate, expectedURL: expectedURL, currentNonce: currentNonce,
                    credentialFingerprint: scope, navigationStarted: true,
                    isSpeculative: true, hasTransferred: false
                ))
            }
        }
    }

    @Test func invalidSceneCannotQualify() throws {
        let url = try #require(URL(string: "https://example.com/player?game=game_1"))
        let nonce = String(repeating: "a", count: 32)
        let identity = PlayerPrewarmSceneMilestoneLedger.Identity(
            gameID: "game_1", playerURL: url, documentNonce: nonce,
            credentialFingerprint: "scope", runtimeSessionID: "session_1"
        )
        for (sequence, milliseconds) in [(-1, 1), (100_001, 1), (1, -1), (1, 3_600_001)] {
            let scene = PlayerPrewarmSceneMilestoneLedger.Submission(
                identity: identity, sequence: sequence, milliseconds: milliseconds
            )
            #expect(!PlayerCompletedPrewarmReusePolicy.permitsWarmHit(
                scene, expectedURL: url, currentNonce: nonce,
                credentialFingerprint: "scope", navigationStarted: true,
                isSpeculative: true, hasTransferred: false
            ))
        }
    }
}
