import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import Hephaestus

/// Native iPhone/iPad poster transport policy; no fake published game or
/// camera/simulator timing is needed to validate safe URL admission.
struct PlayerHoldPosterURLPolicyTests {
    private let production = URL(string: "https://games.example.test")!
    private let development = URL(string: "http://127.0.0.1:8080")!

    @Test func approvedPosterURLsPreserveHTTPSCDNAndLocalBackendHTTP() {
        let urls = [
            "https://games.example.test/v1/games/game-1/preview",
            "https://cdn.example.test/assets/poster.webp?sig=opaque%2Bvalue&v=3",
            "https://cdn.example.test:8443/image.png",
        ]
        for raw in urls {
            #expect(PlayerHoldPosterURLPolicy.admittedURL(
                raw, backendOrigin: production)?.absoluteString == raw)
        }
        #expect(PlayerHoldPosterURLPolicy.admittedURL(
            "http://127.0.0.1:8080/v1/games/game/preview",
            backendOrigin: development) != nil)
        #expect(PlayerHoldPosterURLPolicy.admittedURL(
            "http://127.0.0.1:80/v1/games/game/preview",
            backendOrigin: URL(string: "http://127.0.0.1")!) != nil)
        #expect(PlayerHoldPosterURLPolicy.admittedURL(
            "https://cdn.example.test/asset", backendOrigin: development) != nil)
    }

    @Test func rejectionPreservesSafeFallbackWithoutLoadingUnknownSources() {
        let unsafe = [
            "", "relative.png", "//cdn.example.test/poster.png",
            "file:///private/var/mobile/poster.png",
            "data:image/png;base64,AA==", "javascript:alert(1)",
            "ftp://cdn.example.test/poster.png", "http://remote.example.test/poster",
            "https://user:password@cdn.example.test/poster",
            "https://user@cdn.example.test/poster", "https://cdn.example.test/poster#fragment",
            "https://cdn.example.test/poster\n", " https://cdn.example.test/poster",
            "https://cdn.example.test/poster\t", "https://cdn.example.test/space path",
            "http://127.0.0.1:8081/poster", "http://localhost:8080/poster",
            String(repeating: "a", count: 2049)
        ]
        #expect(PlayerHoldPosterURLPolicy.admittedURL(nil, backendOrigin: production) == nil)
        for raw in unsafe {
            #expect(PlayerHoldPosterURLPolicy.admittedURL(raw, backendOrigin: production) == nil)
        }
        #expect(PlayerHoldPosterURLPolicy.admittedURL(
            "http://127.0.0.1:8080/poster", backendOrigin: production) == nil)
        #expect(PlayerHoldPosterURLPolicy.admittedURL(
            "http://127.0.0.1:8081/poster", backendOrigin: development) == nil)
        #expect(PlayerHoldPosterURLPolicy.admittedURL(
            "http://127.0.0.2:8080/poster", backendOrigin: development) == nil)
    }

    @Test func unrelatedHTTPAndEmbeddedCredentialsDeniedAcross160HostileVariants() {
        for i in 0..<160 {
            let suffix = "private-user-\(i)"
            let cleartext = "http://tracker-\(i).example.test/collect?game=\(suffix)"
            let credentials = "https://\(suffix):password@cdn.example.test/poster"
            let fragment = "https://cdn.example.test/poster#\(suffix)"
            #expect(PlayerHoldPosterURLPolicy.admittedURL(
                cleartext, backendOrigin: production) == nil)
            #expect(PlayerHoldPosterURLPolicy.admittedURL(
                credentials, backendOrigin: production) == nil)
            #expect(PlayerHoldPosterURLPolicy.admittedURL(
                fragment, backendOrigin: production) == nil)
        }
        // Both paths have the same string length but different origins:
        // a port swap must not widen cleartext HTTP admission.
        #expect(PlayerHoldPosterURLPolicy.admittedURL(
            "http://127.0.0.1:8080/ok", backendOrigin: development) != nil)
        #expect(PlayerHoldPosterURLPolicy.admittedURL(
            "http://127.0.0.1:8089/no", backendOrigin: development) == nil)
    }

    @Test func sameOriginPosterRedirectsRespectSignedQueriesDefaultPortsAndThreeHopBudget() {
        let original = URL(string: "https://cdn.example.test/assets/start.webp")!
        let signed = URL(string: "https://cdn.example.test:443/assets/one.webp?sig=opaque%2Bvalue")!
        let next = URL(string: "https://cdn.example.test/assets/two.webp?sig=another")!
        let hop = PlayerPosterRedirectHopPolicy.self

        #expect(hop.maximumRedirects == 3)
        #expect(hop.admittedHop(original: original, from: original, to: signed,
                                alreadyFollowed: 0, backendOrigin: production) == signed)
        #expect(hop.admittedHop(original: original, from: signed, to: next,
                                alreadyFollowed: 1, backendOrigin: production) == next)
        #expect(hop.admittedHop(original: original, from: next, to: original,
                                alreadyFollowed: 2, backendOrigin: production) == original)
        #expect(hop.admittedHop(original: original, from: next, to: original,
                                alreadyFollowed: 3, backendOrigin: production) == nil)
        #expect(hop.admittedHop(original: original, from: next, to: original,
                                alreadyFollowed: -1, backendOrigin: production) == nil)

        let devStart = URL(string: "http://127.0.0.1:8080/start.png")!
        let devNext = URL(string: "http://127.0.0.1:8080/next.png?sig=x")!
        #expect(hop.admittedHop(original: devStart, from: devStart, to: devNext,
                                alreadyFollowed: 0, backendOrigin: development) == devNext)
        #expect(hop.admittedHop(original: devStart, from: devStart, to: original,
                                alreadyFollowed: 0, backendOrigin: development) == nil)
    }

    @Test func crossOriginDowngradeCredentialAndFragmentDeniedFor160RedirectAttempts() {
        let original = URL(string: "https://cdn.example.test/assets/first.webp")!
        for i in 0..<160 {
            let hostile: [String] = [
                "https://cdn-\(i).example.test/escape",
                "https://cdn.example.test:8443/wrong-port",
                "http://cdn.example.test/downgrade",
                "https://token-\(i):secret@cdn.example.test/image",
                "https://cdn.example.test/asset#secret-\(i)",
                "https://cdn.example.test.evil.invalid/asset",
                "https://[::1]/poster-\(i)",
                "file:///private/poster-\(i)"
            ]
            for raw in hostile {
                guard let candidate = URL(string: raw) else { continue }
                #expect(PlayerPosterRedirectHopPolicy.admittedHop(
                    original: original, from: original, to: candidate,
                    alreadyFollowed: i % 3, backendOrigin: production
                ) == nil)
            }
            let wrongPrevious = URL(string: "https://other-\(i).example.test/from")!
            #expect(PlayerPosterRedirectHopPolicy.admittedHop(
                original: original, from: wrongPrevious, to: original,
                alreadyFollowed: 0, backendOrigin: production
            ) == nil)
        }
    }

    @Test func malformedPinnedOriginalCannotAuthorizeSafeLookingRedirect() {
        let safe = URL(string: "https://cdn.example.test/ok")!
        let disguised = URL(string: "https://cdn.example.test@outside.example.test/unsafe")!
        let fragments = URL(string: "https://cdn.example.test/poster#anchor")!
        #expect(PlayerPosterRedirectHopPolicy.admittedHop(
            original: disguised, from: disguised, to: safe,
            alreadyFollowed: 0, backendOrigin: production
        ) == nil)
        #expect(PlayerPosterRedirectHopPolicy.admittedHop(
            original: fragments, from: fragments, to: safe,
            alreadyFollowed: 0, backendOrigin: production
        ) == nil)
        // Policy-only fixture: AsyncImage does not call this decision method.
        // The secure transport, byte/pixel budget and cancellation remain #715.
    }

    @Test func initialOriginPortAndPinnedHopMustBeValidForEveryAcceptedRedirect() {
        let safe = URL(string: "https://cdn.example.test/ok")!
        let hop = PlayerPosterRedirectHopPolicy.self
        for port in [0, 65536, 99999] {
            guard let bad = URL(string: "https://cdn.example.test:\(port)/poster") else { continue }
            #expect(hop.admittedHop(original: bad, from: bad, to: bad,
                                    alreadyFollowed: 0, backendOrigin: production) == nil)
            #expect(hop.admittedHop(original: safe, from: safe, to: bad,
                                    alreadyFollowed: 0, backendOrigin: production) == nil)
        }
        let custom = URL(string: "https://cdn.example.test:8443/one")!
        let customNext = URL(string: "https://cdn.example.test:8443/two?token=opaque%2Bvalue")!
        #expect(hop.admittedHop(original: custom, from: custom, to: customNext,
                                alreadyFollowed: 2, backendOrigin: production) == customNext)
        #expect(hop.admittedHop(original: custom, from: custom, to: safe,
                                alreadyFollowed: 2, backendOrigin: production) == nil)
    }

}

struct PlayerHoldPosterResponseBudgetTests {
    private typealias Budget = PlayerHoldPosterResponseBudget

    @Test func boundedStreamingRejectsOverflowMismatchAndTerminalFailure() {
        let cap = Budget.maximumBytes
        var exact = Budget(statusCode: 200, mimeType: "image/png", expectedLength: Int64(cap), contentEncoding: nil)!
        let chunkAccepted1 = exact.admitChunk(byteCount: cap - 1)
        #expect(chunkAccepted1)
        #expect(!exact.complete)
        let chunkAccepted2 = exact.admitChunk(byteCount: 1)
        #expect(chunkAccepted2)
        #expect(!exact.complete)
        let exactFinished = exact.finish(transportSucceeded: true)
        #expect(exactFinished)
        #expect(exact.complete)
        let chunkAccepted3 = exact.admitChunk(byteCount: 1)
        #expect(!chunkAccepted3)
        #expect(!exact.complete)
        let chunkAccepted4 = exact.admitChunk(byteCount: 0)
        #expect(!chunkAccepted4)
        var unknown = Budget(statusCode: 200, mimeType: "image/jpeg", expectedLength: -1, contentEncoding: "identity")!
        #expect(!unknown.complete)
        let chunkAccepted5 = unknown.admitChunk(byteCount: cap)
        #expect(chunkAccepted5)
        #expect(!unknown.complete)
        let unknownFinished = unknown.finish(transportSucceeded: true)
        #expect(unknownFinished)
        #expect(unknown.complete)
        let chunkAccepted6 = unknown.admitChunk(byteCount: Int.max)
        #expect(!chunkAccepted6)
        var negative = Budget(statusCode: 200, mimeType: "image/png", expectedLength: 4, contentEncoding: nil)!
        let chunkAccepted7 = negative.admitChunk(byteCount: -1)
        #expect(!chunkAccepted7)
        #expect(!negative.complete)
    }

    @Test func onlySuccessfulTerminalTransportCanAuthorizeHeaders() {
        for length: Int64 in [-1, 4] {
            var failed = Budget(statusCode: 200, mimeType: "image/png", expectedLength: length, contentEncoding: nil)!
            let accepted = failed.admitChunk(byteCount: 4)
            #expect(accepted)
            #expect(!failed.complete)
            let failedFinish = failed.finish(transportSucceeded: false)
            #expect(!failedFinish)
            let revived = failed.finish(transportSucceeded: true)
            #expect(!revived)
            #expect(!failed.complete)
            var duplicate = Budget(statusCode: 200, mimeType: "image/png", expectedLength: length, contentEncoding: nil)!
            let acceptedDuplicate = duplicate.admitChunk(byteCount: 4)
            #expect(acceptedDuplicate)
            let firstFinish = duplicate.finish(transportSucceeded: true)
            #expect(firstFinish)
            let secondFinish = duplicate.finish(transportSucceeded: true)
            #expect(!secondFinish)
            #expect(!duplicate.complete)
        }
        var truncated = Budget(statusCode: 200, mimeType: "image/png", expectedLength: 4, contentEncoding: nil)!
        let shortChunk = truncated.admitChunk(byteCount: 3)
        #expect(shortChunk)
        let shortFinish = truncated.finish(transportSucceeded: true)
        #expect(!shortFinish)
        #expect(!truncated.complete)
        var empty = Budget(statusCode: 200, mimeType: "image/png", expectedLength: -1, contentEncoding: nil)!
        let emptyFinish = empty.finish(transportSucceeded: true)
        #expect(!emptyFinish)
        #expect(!empty.complete)
    }

    @Test func oneHundredSixtyHostileMetadataCombinationsFailClosed() {
        for cycle in 0..<160 {
            #expect(Budget(statusCode: 300 + cycle % 100, mimeType: "image/png", expectedLength: 1, contentEncoding: nil) == nil)
            #expect(Budget(statusCode: 200, mimeType: "image/gif", expectedLength: 1, contentEncoding: nil) == nil)
            #expect(Budget(statusCode: 200, mimeType: "image/jpeg", expectedLength: Int64(Budget.maximumBytes) + Int64(cycle) + 1, contentEncoding: nil) == nil)
            #expect(Budget(statusCode: 200, mimeType: "image/png", expectedLength: -2 - Int64(cycle), contentEncoding: nil) == nil)
            #expect(Budget(statusCode: 200, mimeType: "image/png", expectedLength: 1, contentEncoding: "gzip") == nil)
            #expect(!Budget.dimensionsAllowed(width: 4097 + cycle, height: 1))
            #expect(!Budget.dimensionsAllowed(width: 1, height: Int.max))
        }
        #expect(Budget.dimensionsAllowed(width: 4096, height: 4096))
        #expect(!Budget.dimensionsAllowed(width: 0, height: 1))
        #expect(Budget(statusCode: 200, mimeType: "image/png", expectedLength: 0, contentEncoding: nil) == nil)
    }

    private func encodedFixture(_ type: UTType) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 2, height: 2,
            bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func actualEncodedPNGAndJPEGHeadersMustMatchMIMEAndCount() throws {
        for (type, mime, wrongMIME) in [(UTType.png, "image/png", "image/jpeg"), (UTType.jpeg, "image/jpeg", "image/png")] {
            let data = try encodedFixture(type)
            var correct = try #require(Budget(statusCode: 200, mimeType: mime, expectedLength: Int64(data.count), contentEncoding: nil))
            #expect(!correct.admitsEncodedHeader(data))
            let chunkAccepted8 = correct.admitChunk(byteCount: data.count)
            #expect(chunkAccepted8)
            #expect(!correct.admitsEncodedHeader(data))
            let correctFinished = correct.finish(transportSucceeded: true)
            #expect(correctFinished)
            #expect(correct.admitsEncodedHeader(data))
            #expect(!correct.admitsEncodedHeader(Data(data.dropLast())))
            var wrong = try #require(Budget(statusCode: 200, mimeType: wrongMIME, expectedLength: -1, contentEncoding: nil))
            let chunkAccepted9 = wrong.admitChunk(byteCount: data.count)
            #expect(chunkAccepted9)
            let wrongFinished = wrong.finish(transportSucceeded: true)
            #expect(wrongFinished)
            #expect(!wrong.admitsEncodedHeader(data))
        }
        let corrupt = Data(repeating: 0, count: 32)
        var budget = try #require(Budget(statusCode: 200, mimeType: "image/png", expectedLength: 32, contentEncoding: nil))
        let chunkAccepted10 = budget.admitChunk(byteCount: corrupt.count)
        #expect(chunkAccepted10)
        let corruptFinished = budget.finish(transportSucceeded: true)
        #expect(corruptFinished)
        #expect(!budget.admitsEncodedHeader(corrupt))
    }
}
