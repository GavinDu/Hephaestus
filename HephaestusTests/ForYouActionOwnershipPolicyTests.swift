import Testing
@testable import Hephaestus

/// The pager, not its replaceable .id(game.id) child, owns native actions.
/// These pure checks don't create synthetic posts, sessions or social writes.
struct ForYouActionOwnershipPolicyTests {
    private func allowed(
        _ id: String = "real-id", selected: String? = "real-id",
        available: [String] = ["real-id"],
        requestedViewer: String = "", currentViewer: String = "",
        oldRevision: Int = 4, newRevision: Int = 4
    ) -> Bool {
        ForYouActionOwnershipPolicy.canPresent(
            requestedGameID: id,
            selectedGameID: selected,
            availableIDs: available,
            requestedViewerID: requestedViewer,
            currentViewerID: currentViewer,
            requestedRevision: oldRevision,
            currentRevision: newRevision
        )
    }

    @Test func realSettledPostMayShowForGuestOrSameAccount() {
        #expect(allowed())
        #expect(allowed(requestedViewer: "owner", currentViewer: "owner"))
    }

    @Test func staleSelectedGameAndMissingPublicGameCannotPresent() {
        #expect(!allowed(selected: "different-id"))
        #expect(!allowed(selected: nil))
        #expect(!allowed(available: []))
        #expect(!allowed(""))
        #expect(!allowed(" \n\t "))
    }

    @Test func logoutOrAccountSwitchRevokesPreviousActions() {
        #expect(!allowed(requestedViewer: "owner-a", currentViewer: ""))
        #expect(!allowed(requestedViewer: "owner-a", currentViewer: "owner-b"))
        #expect(!allowed(requestedViewer: "", currentViewer: "owner-a"))
    }

    @Test func sameViewerNewSessionRevisionStillRevokesSheetAndShare() {
        #expect(!allowed(requestedViewer: "owner-a", currentViewer: "owner-a",
                         oldRevision: 4, newRevision: 5))
        #expect(!allowed(oldRevision: 3, newRevision: 4))
    }
    @Test func invalidOrControlBearingOwnerNeverOffersDestructiveBlock() {
        let invalid: [String?] = [
            nil, "", " \t\n ", "\u{0000}", "bad\nowner",
            "bad\u{0000}owner"
        ]
        for owner in invalid {
            #expect(!ForYouActionOwnershipPolicy.canOfferCreatorBlock(
                ownerID: owner, viewerID: ""
            ))
            #expect(!ForYouActionOwnershipPolicy.canOfferCreatorBlock(
                ownerID: owner, viewerID: "signed-in-viewer"
            ))
        }
    }

    @Test func authenticatedPublisherCannotBlockOwnAccountEvenAfterWhitespace() {
        for owner in ["doodlequest", "艺术家", "creator🎮"] {
            #expect(!ForYouActionOwnershipPolicy.canOfferCreatorBlock(
                ownerID: owner, viewerID: owner
            ))
            #expect(!ForYouActionOwnershipPolicy.canOfferCreatorBlock(
                ownerID: "  \(owner)  ", viewerID: " \(owner) "
            ))
        }
    }

    @Test func otherGenuinePublisherPreservesReadOnlyBlockAffordance() {
        #expect(ForYouActionOwnershipPolicy.canOfferCreatorBlock(
            ownerID: "doodlequest", viewerID: "different-viewer"
        ))
        #expect(ForYouActionOwnershipPolicy.canOfferCreatorBlock(
            ownerID: "艺术家", viewerID: ""
        ))
        #expect(ForYouActionOwnershipPolicy.canOfferCreatorBlock(
            ownerID: "creator🎮", viewerID: "guest-other"
        ))
    }

}
