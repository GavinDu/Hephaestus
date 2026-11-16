import Testing
@testable import Hephaestus

/// A live transport status hint never authorizes a fabricated game,
/// superseded scope or stale request to expose a navigation action.
struct ArcadePulseFeedSlowLoadingPolicyTests {
    @Test func slowHintRequiresActiveCurrentEmptyTransport() {
        #expect(FeedSlowLoadingPolicy.canShowLibrary(
            isLoading: true, hasGames: false,
            ownsRequest: true, matchesScope: true))
        #expect(!FeedSlowLoadingPolicy.canShowLibrary(
            isLoading: false, hasGames: false,
            ownsRequest: true, matchesScope: true))
        #expect(!FeedSlowLoadingPolicy.canShowLibrary(
            isLoading: true, hasGames: true,
            ownsRequest: true, matchesScope: true))
        #expect(!FeedSlowLoadingPolicy.canShowLibrary(
            isLoading: true, hasGames: false,
            ownsRequest: false, matchesScope: true))
        #expect(!FeedSlowLoadingPolicy.canShowLibrary(
            isLoading: true, hasGames: false,
            ownsRequest: true, matchesScope: false))
    }
}
