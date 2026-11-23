import Foundation
import Testing
@testable import Hephaestus

/// #758 is pure native provenance policy, not a simulated published game,
/// live WebKit cache, server authorization, or GPU presentation proof.
struct PlayerAuthorizedDocumentRevalidationPolicyTests {
    private typealias Policy = PlayerAuthorizedDocumentRevalidationPolicy
    private let origin = URL(string: "https://games.example.test")!
    private let playerURL = URL(string:
        "https://games.example.test/player?game=game-1&quality=low")!
    private let nonce = String(repeating: "a", count: 32)
    private let tag = "W/\"v1\""

    private func receipt(
        statusCode: Int = 200, gameID: String = "game-1",
        url: URL? = nil, backend: URL? = nil, nonceValue: String? = nil,
        epoch: UInt64 = 5, lease: UInt64 = 9,
        isMain: Bool = true, ownsLease: Bool = true,
        cached: Bool = true, etag: String? = "W/\"v1\""
    ) -> Policy.Authorized200Receipt? {
        Policy.authorized200(
            gameID: gameID, expectedPlayerURL: url ?? playerURL,
            responseURL: url ?? playerURL, backendOrigin: backend ?? origin,
            statusCode: statusCode, credentialEpoch: epoch,
            attachmentLease: lease, nativeDocumentNonce: nonceValue ?? nonce,
            etag: etag, ownsCurrentAttachment: ownsLease,
            isTrustedMainFrame: isMain,
            hasAuthorizedCachedRepresentation: cached
        )
    }

    private func accepts(
        _ proof: Policy.Authorized200Receipt?,
        statusCode: Int = 304, gameID: String = "game-1",
        url: URL? = nil, responseURL: URL? = nil,
        epoch: UInt64 = 5, lease: UInt64 = 9,
        nonceValue: String? = nil, isMain: Bool = true,
        ownsLease: Bool = true, cached: Bool = true,
        responseTag: String? = "W/\"v1\""
    ) -> Bool {
        Policy.admits304(
            receipt: proof, gameID: gameID,
            expectedPlayerURL: url ?? playerURL,
            responseURL: responseURL ?? url ?? playerURL,
            backendOrigin: origin, statusCode: statusCode,
            credentialEpoch: epoch, attachmentLease: lease,
            nativeDocumentNonce: nonceValue ?? nonce,
            responseETag: responseTag, ownsCurrentAttachment: ownsLease,
            isTrustedMainFrame: isMain,
            hasAuthorizedCachedRepresentation: cached
        )
    }

    @Test func exactNativeOwnerReceiptIsNecessaryButNeverSufficientAlone() {
        let proof = receipt()
        #expect(proof != nil)
        #expect(accepts(proof))
        #expect(!accepts(nil))
        #expect(!accepts(proof, isMain: false))
        #expect(!accepts(proof, ownsLease: false))
        #expect(!accepts(proof, cached: false))
        #expect(!accepts(proof, epoch: 6))
        #expect(!accepts(proof, lease: 10))
        #expect(!accepts(proof, nonceValue: String(repeating: "b", count: 32)))
        #expect(!accepts(proof, gameID: "game-2"))
        #expect(!accepts(proof, responseTag: "W/\"v2\""))
        // HTTP 304 may legally omit an ETag: native proof still must exist.
        #expect(accepts(proof, responseTag: nil))
        #expect(!accepts(proof, responseTag: "\nsecret"))
    }

    @Test func rejectColdOrNon200OriginAndNon304Reuse() {
        for status in [100, 101, 201, 206, 301, 302, 307, 308, 400, 401, 403, 500] {
            #expect(receipt(statusCode: status) == nil)
            #expect(!accepts(receipt(), statusCode: status))
        }
        #expect(receipt(statusCode: 200) != nil)
        #expect(receipt(isMain: false) == nil)
        #expect(receipt(ownsLease: false) == nil)
        #expect(receipt(cached: false) == nil)
        #expect(receipt(epoch: 0) == nil)
        #expect(receipt(lease: 0) == nil)
        #expect(receipt(nonceValue: "bad") == nil)
        #expect(receipt(nonceValue: String(repeating: "A", count: 32)) == nil)
        #expect(receipt(etag: "\r\nBearer secret") == nil)
        #expect(receipt(etag: String(repeating: "E", count: 129)) == nil)
    }

    @Test func immutableSameOriginURLAndExactGameIDAreRequired() {
        let proof = receipt()
        let wrongGame = URL(string:
            "https://games.example.test/player?game=game-2&quality=low")!
        let wrongQuality = URL(string:
            "https://games.example.test/player?game=game-1&quality=high")!
        let wrongOrigin = URL(string:
            "https://other.example.test/player?game=game-1&quality=low")!
        let redirectedLogin = URL(string:
            "https://games.example.test/login?game=game-1")!
        let withCredentials = URL(string:
            "https://user:secret@games.example.test/player?game=game-1&quality=low")!
        let withFragment = URL(string:
            "https://games.example.test/player?game=game-1&quality=low#token")!
        let modifiedPort = URL(string:
            "https://games.example.test:8443/player?game=game-1&quality=low")!
        for hostile in [wrongGame, wrongQuality, wrongOrigin,
                        redirectedLogin, withCredentials, withFragment, modifiedPort] {
            #expect(!accepts(proof, url: hostile))
            #expect(!accepts(proof, responseURL: hostile))
            #expect(receipt(url: hostile) == nil || hostile == wrongQuality)
        }
        #expect(receipt(backend: URL(string: "https://other.example.test")!) == nil)
        #expect(!accepts(proof, gameID: "bad/id"))
    }

    @Test func reject160StaleOwnerEpochsButAllowEachExactRotation() {
        for iteration in 0..<160 {
            let currentEpoch = UInt64(iteration + 1)
            let currentLease = UInt64(iteration + 100)
            let proof = receipt(epoch: currentEpoch, lease: currentLease)
            #expect(proof != nil)
            let exact = accepts(proof, epoch: currentEpoch, lease: currentLease)
            #expect(exact)
            let wrongEpoch = accepts(proof, epoch: currentEpoch + 1,
                                     lease: currentLease)
            let wrongLease = accepts(proof, epoch: currentEpoch,
                                     lease: currentLease + 1)
            #expect(!wrongEpoch)
            #expect(!wrongLease)
            #expect(!accepts(nil, epoch: currentEpoch, lease: currentLease))
        }
    }
}
