import Foundation
import Testing
@testable import Hephaestus

/// Pure identity/order sentinels; no synthetic published game or server result.
struct FeedPlayNextPolicyTests {
    private let presentationID = UUID()

    private func context(presentation: UUID? = nil, run: String = "run-a",
                         game: String = "game-a", viewer: String = "viewer-a",
                         session: Int = 2, scope: SocialFeedScope = .following,
                         query: String = "actual query", generation: Int = 4)
        -> FeedPlayNextContext {
        FeedPlayNextContext(presentationID: presentation ?? presentationID,
                            runID: run, gameID: game, viewerID: viewer,
                            sessionEpoch: session, scope: scope,
                            searchQuery: query, rootGeneration: generation)
    }

    @Test func currentOperationUsesFreshIdentityOrderAfterAppendOrReorder() {
        let operation = FeedPlayNextOperation(context: context())
        #expect(FeedPlayNextPolicy.isCurrent(operation, pending: operation, current: context()))
        #expect(FeedPlayNextPolicy.nextGameID(after: "game-a", visibleIDs: ["game-a"]) == nil)
        #expect(FeedPlayNextPolicy.nextGameID(after: "game-a", visibleIDs: ["game-a", "game-b"]) == "game-b")
        #expect(FeedPlayNextPolicy.nextGameID(after: "game-a", visibleIDs: ["game-c", "game-a", "game-d"]) == "game-d")
    }

    @Test func absentOriginOrOnlyDuplicatesDoesNotSelectAnotherGame() {
        #expect(FeedPlayNextPolicy.nextGameID(after: "game-a", visibleIDs: ["game-b", "game-c"]) == nil)
        #expect(FeedPlayNextPolicy.nextGameID(after: "game-a", visibleIDs: ["game-a", "game-a"]) == nil)
        #expect(FeedPlayNextPolicy.nextGameID(after: "game-a", visibleIDs: []) == nil)
        #expect(FeedPlayNextPolicy.nextGameID(after: "game-a", visibleIDs: ["game-a", "game-a", "game-b"]) == "game-b")
    }

    @Test func everyContextDimensionAndDismissalRevokesOldNavigation() {
        let operation = FeedPlayNextOperation(context: context())
        let replacements = [
            context(presentation: UUID()), context(run: "run-b"),
            context(game: "game-b"), context(viewer: "viewer-b"),
            context(viewer: ""), context(session: 3), context(scope: .forYou),
            context(query: "new search"), context(generation: 5)
        ]
        for replacement in replacements {
            #expect(!FeedPlayNextPolicy.isCurrent(operation, pending: operation, current: replacement))
        }
        #expect(!FeedPlayNextPolicy.isCurrent(operation, pending: operation, current: nil))
        #expect(!FeedPlayNextPolicy.isCurrent(operation, pending: nil, current: context()))
    }

    @Test func replacementOperationCannotBeRetiredByPreviousOneEvenWithSameContext() {
        let old = FeedPlayNextOperation(context: context())
        let replacement = FeedPlayNextOperation(context: context())
        #expect(!FeedPlayNextPolicy.isCurrent(old, pending: replacement, current: context()))
        #expect(FeedPlayNextPolicy.isCurrent(replacement, pending: replacement, current: context()))
    }
}
