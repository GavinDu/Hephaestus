import Testing
@testable import Hephaestus

struct ArcadePulseCreatorDiscoveryResultsPolicyTests {
    @Test func onlyConfirmedCurrentQueriesCanPage() {
        #expect(CreatorDiscoveryResultsPolicy.allowsNextPage(
            resultsMatchCurrentSearch: true, hasNextCursor: true, isLoading: false))
        #expect(!CreatorDiscoveryResultsPolicy.allowsNextPage(
            resultsMatchCurrentSearch: false, hasNextCursor: true, isLoading: false))
        #expect(!CreatorDiscoveryResultsPolicy.allowsNextPage(
            resultsMatchCurrentSearch: true, hasNextCursor: true, isLoading: true))
        #expect(!CreatorDiscoveryResultsPolicy.allowsNextPage(
            resultsMatchCurrentSearch: true, hasNextCursor: false, isLoading: false))
    }

    @Test func onlyConfirmedEmptySuccessDisplaysNoCreators() {
        #expect(CreatorDiscoveryResultsPolicy.showsEmptyMessage(
            isLoading: false, hasResults: false, hasError: false))
        #expect(!CreatorDiscoveryResultsPolicy.showsEmptyMessage(
            isLoading: true, hasResults: false, hasError: false))
        #expect(!CreatorDiscoveryResultsPolicy.showsEmptyMessage(
            isLoading: false, hasResults: false, hasError: true))
        #expect(!CreatorDiscoveryResultsPolicy.showsEmptyMessage(
            isLoading: false, hasResults: true, hasError: false))
    }

    @Test func staleResultsAreNeverPresentedAsCurrentCreators() {
        #expect(CreatorDiscoveryResultsPolicy.sectionTitle(resultsMatchCurrentSearch: false)
                == "Previous results")
        #expect(CreatorDiscoveryResultsPolicy.sectionTitle(resultsMatchCurrentSearch: true)
                == "Creators")
    }
}
