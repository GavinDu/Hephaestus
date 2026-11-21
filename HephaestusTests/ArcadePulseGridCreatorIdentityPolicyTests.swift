import Testing
@testable import Hephaestus

/// Original backend creator strings only. No fictitious FeedGame, server
/// fixture, publisher account, avatar, follow or moderation write.
struct ArcadePulseGridCreatorIdentityPolicyTests {
    @Test func invalidOwnerNeverBecomesAnInteractiveProfile() {
        let invalid: [String?] = [
            nil, "", " ", "\n\t", "\u{0000}", "bad\nowner",
            "bad\u{0000}owner"
        ]
        for owner in invalid {
            #expect(GameFeedCardCreatorIdentityPolicy.publicName(
                ownerID: owner, displayName: "Visible real name"
            ) == nil)
        }
    }

    @Test func validOwnerAndPrintableNameStayGenuineAndReadable() {
        #expect(GameFeedCardCreatorIdentityPolicy.publicName(
            ownerID: "doodlequest", displayName: "  彩虹🎮  "
        ) == "彩虹🎮")
        #expect(GameFeedCardCreatorIdentityPolicy.publicName(
            ownerID: "  艺术家  ", displayName: "ARTIST"
        ) == "ARTIST")
        #expect(GameFeedCardCreatorIdentityPolicy.publicName(
            ownerID: "Creator.Case", displayName: nil
        ) == "Creator.Case")
    }

    @Test func UnusableDisplayNameFallsBackToRealOwnerOnly() {
        let invalid: [String?] = [
            nil, "", "  ", "\t\n", "bad\nname", "bad\u{0000}name"
        ]
        for name in invalid {
            #expect(GameFeedCardCreatorIdentityPolicy.publicName(
                ownerID: "doodlequest", displayName: name
            ) == "doodlequest")
        }
        #expect(GameFeedCardCreatorIdentityPolicy.publicName(
            ownerID: "艺术家", displayName: "\u{0000}"
        ) == "艺术家")
    }
}
