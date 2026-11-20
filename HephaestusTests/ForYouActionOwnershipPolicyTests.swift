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
}
