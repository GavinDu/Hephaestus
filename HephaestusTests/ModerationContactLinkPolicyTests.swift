import Foundation
import Testing
@testable import Hephaestus

/// Pure link-admission cases only. No fabricated moderation server reply,
/// synthetic appeal, network request or external moderator account.
struct ModerationContactLinkPolicyTests {
    @Test func acceptsGenuineAbsoluteHTTPSContactWithoutChangingDestination() {
        let raw = "https://support.example.org/appeal?game=real-game"
        #expect(ModerationContactLinkPolicy.approvedURL(raw)?.absoluteString == raw)
        #expect(ModerationContactLinkPolicy.approvedURL(" HTTPS://support.example.org/path ")?.host
                == "support.example.org")
        #expect(ModerationContactLinkPolicy.approvedURL(
            "https://support.example.org/%E7%94%B3%E8%AF%89"
        )?.host == "support.example.org")
    }

    @Test func rejectsNonWebAndCredentialBearingExternalContact() {
        let invalid: [String?] = [
            nil, "", " ", "http://support.example.org/appeal",
            "file:///tmp/private", "javascript:alert(1)",
            "mailto:help@example.org", "ftp://support.example.org/appeal",
            "/relative/help", "//untrusted.example.org/help",
            "https://user:password@support.example.org/help",
            "https://user@support.example.org/help",
            "https://", "https:///no-host"
        ]
        for candidate in invalid {
            #expect(ModerationContactLinkPolicy.approvedURL(candidate) == nil)
        }
    }

    @Test func rejectsControlsEvenWhenPercentEncodedOrOutsideHost() {
        let unsafe = [
            "https://support.example.org/appeal\n",
            "https://support.example.org/appeal\u{0000}",
            "https://support.example.org/%0Aappeal",
            "https://support.example.org/help?next=%0D",
            "\thttps://support.example.org/help"
        ]
        for candidate in unsafe {
            #expect(ModerationContactLinkPolicy.approvedURL(candidate) == nil)
        }
    }

    @Test func externalContactDoesNotChangeInAppAppealCapability() {
        // This function only yields a trusted Link destination; it does not
        // produce an appeal acknowledgement or affect Submit button policy.
        #expect(ModerationContactLinkPolicy.approvedURL(nil) == nil)
        #expect(ModerationContactLinkPolicy.approvedURL("http://support.example.org") == nil)
        #expect(ModerationContactLinkPolicy.approvedURL(
            "https://support.example.org/appeal")?.scheme == "https")
    }
}
