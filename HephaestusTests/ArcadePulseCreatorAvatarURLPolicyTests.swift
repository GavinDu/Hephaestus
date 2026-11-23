import Foundation
import Testing
@testable import Hephaestus

/// Pure initial-URL policy tests. These do not fabricate public creator,
/// avatar bytes, network redirects or device screenshot evidence.
struct ArcadePulseCreatorAvatarURLPolicyTests {
    private let backend = URL(string: "https://games.example.test/")!

    private func resolved(_ raw: String?) -> URL? {
        ArcadePulseCreatorAvatarURLPolicy.resolvedURL(
            raw: raw, backendBaseURL: backend
        )
    }

    @Test func legitimateHTTPSCDNAndBackendAvatarsPreserveTheirOrigins() {
        #expect(resolved("https://cdn.example.test/avatar/real.png?version=2")?.absoluteString
                == "https://cdn.example.test/avatar/real.png?version=2")
        #expect(resolved(" https://cdn.example.test/avatar/real.png ")?.host
                == "cdn.example.test")
        #expect(resolved("https://games.example.test/profile.png")?.host
                == "games.example.test")
    }

    @Test func relativePublisherAvatarResolvesToConfiguredHTTPSOriginOnly() {
        #expect(resolved("/avatars/real.png")?.absoluteString
                == "https://games.example.test/avatars/real.png")
        #expect(resolved("avatars/real.png")?.absoluteString
                == "https://games.example.test/avatars/real.png")
        #expect(resolved("/avatars/%E8%89%BA%E6%9C%AF%E5%AE%B6.png")?.host
                == "games.example.test")
    }

    @Test func missingInsecureCredentialsAndControlBearingSourcesAreRejected() {
        let invalid: [String?] = [
            nil, "", " ", "\n", "\t",
            "http://games.example.test/avatar.png",
            "file:///tmp/private.png", "ftp://games.example.test/a.png",
            "data:image/png;base64,AA", "javascript:alert(1)",
            "https://user:pass@games.example.test/a.png",
            "https://user@games.example.test/a.png",
            "//evil.example.test/steal.png",
            "\\evil.example.test/steal.png",
            "https://games.example.test/bad\nname.png",
            "https://games.example.test/%0Aavatar.png",
            "https://games.example.test/%0Davatar.png"
        ]
        for raw in invalid {
            #expect(resolved(raw) == nil, "Rejected unsafe initial creator avatar URL")
        }
    }

    @Test func insecureOrCredentialBearingBackendCannotBecomeRelativeAvatarOrigin() {
        for base in [
            URL(string: "http://games.example.test/")!,
            URL(string: "https://user:pass@games.example.test/")!
        ] {
            #expect(ArcadePulseCreatorAvatarURLPolicy.resolvedURL(
                raw: "/avatars/real.png", backendBaseURL: base
            ) == nil)
        }
    }
}
