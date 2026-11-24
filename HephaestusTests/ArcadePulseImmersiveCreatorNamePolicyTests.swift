import Testing
@testable import Hephaestus

/// Pure source-string policy only: the real backend still supplies the
/// game, owner, profile route and avatar. These tests do not fake a
/// published game, user account, live Creator Directory or native screenshot.
struct ArcadePulseImmersiveCreatorNamePolicyTests {
    @Test func immersiveSpotlightAndDetailsShareGridAdmittedName() {
        let cases: [(owner: String?, name: String?)] = [
            ("doodlequest", "  彩虹🎮  "),
            ("  艺术家  ", "ARTIST"),
            ("Creator.Case", nil),
            ("doodlequest", "  "),
            ("doodlequest", "bad\nname"),
            ("doodlequest", "bad\u{0000}name"),
            (nil, "A published name with no actual owner")
        ]
        for entry in cases {
            #expect(ForYouPageLayout.publicCreatorName(
                ownerID: entry.owner, displayName: entry.name
            ) == GameFeedCardCreatorIdentityPolicy.publicName(
                ownerID: entry.owner, displayName: entry.name
            ))
        }
    }

    @Test func invalidOwnerNeverOffersADeadImmersiveOrSpotlightProfile() {
        let invalidOwners: [String?] = [
            nil, "", "  ", "\n", "\u{0000}", "bad\nowner", "bad\u{007F}owner"
        ]
        for owner in invalidOwners {
            #expect(ForYouPageLayout.publicCreatorName(
                ownerID: owner, displayName: "Beautiful name"
            ) == nil)
        }
    }

    @Test func malformedPublicNameFallsBackToRealOwnerWithoutInventingIdentity() {
        let invalidNames: [String?] = [
            nil, "", " \n ", "bad\nname", "bad\u{0000}name", "name\u{007F}"
        ]
        for name in invalidNames {
            #expect(ForYouPageLayout.publicCreatorName(
                ownerID: "doodlequest", displayName: name
            ) == "doodlequest")
        }
        #expect(ForYouPageLayout.publicCreatorName(
            ownerID: nil, displayName: nil
        ) == nil)
    }

    @Test func legitimateNamesKeepUnicodeOrderAndCaseInSpokenAndVisibleLabel() {
        #expect(ForYouPageLayout.publicCreatorName(
            ownerID: "doodlequest", displayName: "  彩虹 🎮 Creator  "
        ) == "彩虹 🎮 Creator")
        #expect(ForYouPageLayout.publicCreatorName(
            ownerID: "Creator.Case", displayName: nil
        ) == "Creator.Case")
        #expect(ForYouPageLayout.publicCreatorName(
            ownerID: "  艺术家  ", displayName: " 艺术家 "
        ) == "艺术家")
    }
}
