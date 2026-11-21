import Testing
@testable import Hephaestus

/// Pure concurrency policy tests only. No generated private server feed,
/// fabricated account session, or substitute native screenshot is involved.
struct ArcadePulseViewerBoundPaginationTests {
    private func accepts(
        scope: SocialFeedScope = .following,
        currentScope: SocialFeedScope = .following,
        requestGeneration: Int = 10, currentGeneration: Int = 10,
        requestViewer: String = "viewer-a", currentViewer: String = "viewer-a",
        requestSession: Int = 3, currentSession: Int = 3,
        requestPage: Int = 5, currentPage: Int = 5
    ) -> Bool {
        ForYouPageLayout.shouldApplyViewerPaginationResult(
            requestedScope: scope, currentScope: currentScope,
            requestedGeneration: requestGeneration, currentGeneration: currentGeneration,
            requestedViewerID: requestViewer, currentViewerID: currentViewer,
            requestedSessionEpoch: requestSession, currentSessionEpoch: currentSession,
            requestedPaginationEpoch: requestPage, currentPaginationEpoch: currentPage
        )
    }

    @Test func actualSameViewerSameSessionCurrentCursorCanApply() {
        #expect(accepts())
        #expect(accepts(scope: .forYou, currentScope: .forYou,
                        requestViewer: "", currentViewer: ""))
    }

    @Test func oldPrivateFollowingPageCannotAppendAcrossViewerSwitch() {
        #expect(!accepts(requestViewer: "viewer-a", currentViewer: "viewer-b"))
        #expect(!accepts(requestViewer: "viewer-a", currentViewer: ""))
        #expect(!accepts(requestViewer: "", currentViewer: "viewer-a"))
    }

    @Test func returningToSameIDAfterNewLoginStillRevokesOldPage() {
        #expect(!accepts(requestSession: 3, currentSession: 4))
        #expect(!accepts(requestSession: 3, currentSession: 3,
                         requestPage: 5, currentPage: 6))
    }

    @Test func scopeGenerationAndRefreshEachRevokeOldPageOrError() {
        #expect(!accepts(scope: .following, currentScope: .forYou))
        #expect(!accepts(requestGeneration: 10, currentGeneration: 11))
        #expect(!accepts(requestPage: 5, currentPage: 6))
    }
}
