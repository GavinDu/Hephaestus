import Foundation
import Testing
@testable import Hephaestus

/// The real immersive More menu, Accessibility5 Game actions sheet and
/// backend Block guard share this one already-used Creator navigation policy.
/// Pure tests do not synthesize a published game or issue a social write.
struct ArcadePulseCreatorBlockOwnerPolicyTests {
    @Test func missingOrWhitespaceOnlyPublicCreatorCannotOfferBlockAction() {
        let invalid: [String?] = [
            nil, "", " ", "\t", "\r\n", "   \n\t   ",
            "\u{0000}", "bad\u{0000}creator", "bad\ncreator"
        ]
        for owner in invalid {
            #expect(!ForYouPageLayout.hasNavigableCreator(ownerID: owner))
        }
    }

    @Test func realSourceCreatorIdentityRemainsEligible() {
        let genuine: [String?] = [
            "doodlequest", "public-owner-42", "艺术家", "creator🎮",
            "  published-owner  "
        ]
        for owner in genuine {
            #expect(ForYouPageLayout.hasNavigableCreator(ownerID: owner))
        }
    }

    @Test func noOwnerIsNeverReplacedWithFallbackUserOrAnonymousAction() {
        #expect(!ForYouPageLayout.hasNavigableCreator(ownerID: nil))
        #expect(!ForYouPageLayout.hasNavigableCreator(ownerID: ""))
        #expect(ForYouPageLayout.hasNavigableCreator(ownerID: "doodlequest"))
    }
}
