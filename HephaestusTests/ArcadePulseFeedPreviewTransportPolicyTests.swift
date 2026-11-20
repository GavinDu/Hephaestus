import Foundation
import Testing
@testable import Hephaestus

/// Only source-level URL admission: no test game, network request, AVPlayer
/// playback or mock approved preview is created by these assertions.
struct ArcadePulseFeedPreviewTransportPolicyTests {
    @Test func acceptsCompleteHTTPSClipWithoutRewritingSignedQuery() {
        let signed = "https://media.example.invalid/approved/clip.m3u8?signature=opaque-keep-exact&expires=42"
        let allowed = FeedPreviewTransportPolicy.allowedClipURL(from: signed)
        #expect(allowed?.absoluteString == signed)
        #expect(FeedPreviewTransportPolicy.allowedClipURL(
            from: "HTTPS://media.example.invalid/clip.mp4") != nil)
        #expect(FeedPreviewTransportPolicy.allowedClipURL(
            from: "https://media.example.invalid:8443/clip.mp4") != nil)
    }

    @Test func neverStartsPublicAutoplayWithPlainHTTPOrNonNetworkSchemes() {
        let rejected = [
            "http://media.example.invalid/clip.mp4",
            "http://media.example.invalid/clip.mp4?token=secret",
            "file:///tmp/example.mp4",
            "ftp://media.example.invalid/clip.mp4",
            "data:video/mp4;base64,AA==",
            "javascript:alert(1)"
        ]
        for url in rejected {
            #expect(FeedPreviewTransportPolicy.allowedClipURL(from: url) == nil)
        }
    }

    @Test func rejectsMissingRelativeAndCredentialedClipLocations() {
        #expect(FeedPreviewTransportPolicy.allowedClipURL(from: nil) == nil)
        for url in [
            "", "/approved/clip.mp4", "//media.example.invalid/clip.mp4",
            "https://", "https:relative/clip.mp4",
            "https://user:password@media.example.invalid/clip.mp4",
            "https://username@media.example.invalid/clip.mp4"
        ] {
            #expect(FeedPreviewTransportPolicy.allowedClipURL(from: url) == nil)
        }
    }
}
