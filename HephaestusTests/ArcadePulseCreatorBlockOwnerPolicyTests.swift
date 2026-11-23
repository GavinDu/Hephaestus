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

    @Test func authenticatedCreatorCannotBlockOwnPublisherIdentity() {
        for owner in ["doodlequest", "艺术家", "creator🎮"] {
            #expect(!ForYouPageLayout.canOfferCreatorBlock(
                ownerID: owner, viewerID: owner
            ))
            #expect(!ForYouPageLayout.canOfferCreatorBlock(
                ownerID: "  \(owner)  ", viewerID: " \(owner) "
            ))
        }
    }

    @Test func unrelatedCreatorAndGuestRetainExistingAuthorizationPresentation() {
        #expect(ForYouPageLayout.canOfferCreatorBlock(
            ownerID: "doodlequest", viewerID: "another-creator"
        ))
        #expect(ForYouPageLayout.canOfferCreatorBlock(
            ownerID: "艺术家", viewerID: "doodlequest"
        ))
        #expect(ForYouPageLayout.canOfferCreatorBlock(
            ownerID: "doodlequest", viewerID: ""
        ))
        #expect(ForYouPageLayout.canOfferCreatorBlock(
            ownerID: "doodlequest", viewerID: "   "
        ))
    }

    @Test func malformedOwnerCannotExposeDestructiveBlockForAnyViewer() {
        let owners: [String?] = [
            nil, "", " \n ", "bad\u{0000}creator", "bad\ncreator", "bad\tcreator"
        ]
        for owner in owners {
            #expect(!ForYouPageLayout.canOfferCreatorBlock(
                ownerID: owner, viewerID: ""
            ))
            #expect(!ForYouPageLayout.canOfferCreatorBlock(
                ownerID: owner, viewerID: "real-viewer"
            ))
        }
    }
}
