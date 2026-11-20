import Testing
@testable import Hephaestus

/// Only pure rendering policy; these tests never invent published feed games,
/// a backend response or a playable poster for native acceptance.
struct FeedEmptyStatePolicyTests {
    @Test func genuineSearchWithNoMatchingTitlePreservesSearchLanguage() {
        for query in ["puzzle", "  ribbon  ", "游戏", "🎮"] {
            #expect(FeedEmptyStatePolicy.isFiltered(searchQuery: query))
            #expect(FeedEmptyStatePolicy.title(searchQuery: query) == "No games found")
            #expect(FeedEmptyStatePolicy.guidance(
                searchQuery: query, canOpenLibrary: true) == "Try a different title.")
        }
    }

    @Test func successfulEmptyFeedNeverSuggestsChangingAnAbsentTitle() {
        for query in ["", " ", " \n\t "] {
            #expect(!FeedEmptyStatePolicy.isFiltered(searchQuery: query))
            #expect(FeedEmptyStatePolicy.title(searchQuery: query) == "No games to show yet")
            let guidance = FeedEmptyStatePolicy.guidance(
                searchQuery: query, canOpenLibrary: true)
            #expect(guidance.contains("Refresh"))
            #expect(guidance.contains("Library"))
            #expect(!guidance.contains("different title"))
        }
    }

    @Test func emptyFeedWithoutHostLibraryRouteDoesNotPromiseIt() {
        let guidance = FeedEmptyStatePolicy.guidance(
            searchQuery: "", canOpenLibrary: false)
        #expect(guidance == "Refresh to check for games in this feed.")
    }

    @Test func retainedCommittedSearchAfterRotationIsStillARealFilteredQuery() {
        // The Discover UI uses activeSearchQuery, not only UIKit's draft.
        // A committed genuine title must not become a fabricated empty feed
        // when the native search drawer drops its transient text.
        let appliedQuery = FeedCommittedSearchPolicy.effectiveQuery(
            draft: "", committed: "飘带补天"
        )
        #expect(FeedEmptyStatePolicy.isFiltered(searchQuery: appliedQuery))
        #expect(FeedEmptyStatePolicy.title(searchQuery: appliedQuery) == "No games found")
        #expect(FeedEmptyStatePolicy.guidance(
            searchQuery: appliedQuery, canOpenLibrary: true
        ) == "Try a different title.")
    }

    @Test func aFilteredResultNeverPromisesUnfilteredRecoveryActions() {
        let guidance = FeedEmptyStatePolicy.guidance(
            searchQuery: "  real game ", canOpenLibrary: false)
        #expect(guidance == "Try a different title.")
    }
}
