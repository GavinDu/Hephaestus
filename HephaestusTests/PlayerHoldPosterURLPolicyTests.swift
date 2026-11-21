import Foundation
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
}
