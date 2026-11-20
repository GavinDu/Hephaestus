import Foundation
import Testing
@testable import Hephaestus

/// The native .searchable drawer can lose transient text during a compact
/// landscape swipe. Search results are only real backend games, and remain
/// scoped to the latest user-committed title until explicit Clear search.
struct FeedCommittedSearchPolicyTests {
    @Test func committedResultSurvivesUIKitClearingTransientDraft() {
        #expect(FeedCommittedSearchPolicy.effectiveQuery(
            draft: "", committed: "飘带补天") == "飘带补天")
        #expect(FeedCommittedSearchPolicy.effectiveQuery(
            draft: " \n ", committed: "Real Game") == "Real Game")
    }

    @Test func newDraftTakesPrecedenceOverOlderCommittedQuery() {
        #expect(FeedCommittedSearchPolicy.effectiveQuery(
            draft: "New published title", committed: "Old published title")
            == "New published title")
    }

    @Test func explicitClearReturnsToUnfilteredPager() {
        #expect(FeedCommittedSearchPolicy.effectiveQuery(
            draft: "", committed: "").isEmpty)
        #expect(FeedCommittedSearchPolicy.effectiveQuery(
            draft: " Real game ", committed: "") == "Real game")
    }
}
