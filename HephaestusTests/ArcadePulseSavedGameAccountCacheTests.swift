import Foundation
import Testing
@testable import Hephaestus

/// Unit-only viewer isolation tests. Strings below are local policy inputs,
/// NOT fabricated backend-published games, accounts, or native UI evidence.
struct ArcadePulseSavedGameAccountCacheTests {
    private func withIsolatedDefaults(_ check: (UserDefaults) -> Void) {
        let suite = "hephaestus-tests-saved-cache-" + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("Could not create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        check(defaults)
    }

    @Test func cachedSavedStatusIsSeparateForEachAuthenticatedViewer() {
        withIsolatedDefaults { defaults in
            FeedSavedGameCache.save(["published-one"], for: "viewer-a", defaults: defaults)
            #expect(FeedSavedGameCache.load(for: "viewer-a", defaults: defaults) == ["published-one"])
            #expect(FeedSavedGameCache.load(for: "viewer-b", defaults: defaults).isEmpty)
            FeedSavedGameCache.save(["published-two"], for: "viewer-b", defaults: defaults)
            #expect(FeedSavedGameCache.load(for: "viewer-a", defaults: defaults) == ["published-one"])
            #expect(FeedSavedGameCache.load(for: "viewer-b", defaults: defaults) == ["published-two"])
            FeedSavedGameCache.save([], for: "viewer-a", defaults: defaults)
            #expect(FeedSavedGameCache.load(for: "viewer-a", defaults: defaults).isEmpty)
            #expect(FeedSavedGameCache.load(for: "viewer-b", defaults: defaults) == ["published-two"])
        }
    }

    @Test func anonymousGuestNeverPersistsOrReadsAuthenticatedSavedHints() {
        withIsolatedDefaults { defaults in
            FeedSavedGameCache.save(["account-only"], for: "viewer-a", defaults: defaults)
            FeedSavedGameCache.save(["guest-unconfirmed"], for: "", defaults: defaults)
            #expect(FeedSavedGameCache.storageKey(for: "") == nil)
            #expect(FeedSavedGameCache.load(for: "", defaults: defaults).isEmpty)
            #expect(FeedSavedGameCache.load(for: "viewer-a", defaults: defaults) == ["account-only"])
        }
    }

    @Test func globalLegacyAndGuestCacheAreNeverMigratedToAnotherViewer() {
        withIsolatedDefaults { defaults in
            defaults.set(["previous-viewer-game"], forKey: FeedSavedGameCache.legacyKey)
            defaults.set(["previous-guest-game"], forKey: "hephaestus.savedGames.guest")
            #expect(FeedSavedGameCache.load(for: "new-viewer", defaults: defaults).isEmpty)
            #expect(defaults.object(forKey: FeedSavedGameCache.legacyKey) == nil)
            #expect(defaults.object(forKey: "hephaestus.savedGames.guest") == nil)
            #expect(FeedSavedGameCache.load(for: "", defaults: defaults).isEmpty)
        }
    }

    @Test func keyIsStableAndDoesNotContainRawViewerIdentity() {
        let first = FeedSavedGameCache.storageKey(for: "creator@example.com")
        let same = FeedSavedGameCache.storageKey(for: "creator@example.com")
        let different = FeedSavedGameCache.storageKey(for: "other@example.com")
        #expect(first == same)
        #expect(first != different)
        #expect(first?.contains("creator@example.com") == false)
        #expect(first?.hasPrefix("hephaestus.savedGames.account.") == true)
    }

    @Test func oldViewerOrSupersededTransportCannotApplyCachedStatus() {
        #expect(FeedSavedGameCache.canApply(
            requestedViewerID: "account-a", currentViewerID: "account-a", ownsRequest: true
        ))
        #expect(!FeedSavedGameCache.canApply(
            requestedViewerID: "account-a", currentViewerID: "account-b", ownsRequest: true
        ))
        #expect(!FeedSavedGameCache.canApply(
            requestedViewerID: "account-a", currentViewerID: "account-a", ownsRequest: false
        ))
        #expect(!FeedSavedGameCache.canApply(
            requestedViewerID: "", currentViewerID: "account-a", ownsRequest: true
        ))
    }
}
