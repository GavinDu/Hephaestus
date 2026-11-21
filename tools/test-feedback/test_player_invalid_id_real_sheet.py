"""#645: the real player invalid-ID UI test is simulator-DEBUG-only."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class NativeInvalidIDUITestContract(unittest.TestCase):
    def test_entry_is_compile_time_debug_simulator_only(self):
        app = (ROOT / "Hephaestus/HephaestusApp.swift").read_text()
        self.assertIn("#if DEBUG && targetEnvironment(simulator)", app)
        self.assertIn('ProcessInfo.processInfo.arguments.contains("--ui-test-invalid-player-id")', app)
        self.assertIn('PixiPlayerSheet(gameID: "bad/id"', app)
        self.assertIn(".sheet(isPresented: $showingPlayer)", app)
        self.assertIn("ContentView()", app)
        self.assertNotIn("FeedGame(", app)
        self.assertNotIn("URLProtocol", app)
        self.assertNotIn("GamePackageTransport(", app)

    def test_real_player_native_rejection_and_share_guard_are_preserved(self):
        source = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        self.assertIn("guard PlayerPublishedGameIDPolicy.valid(gameID) else", source)
        self.assertIn('loadFailureCategory = .invalidPackage', source)
        self.assertIn('loadError = "This game has an invalid identifier. Return to the feed."', source)
        self.assertIn("if let url = playerURL", source)
        self.assertIn("if PlayerPublishedGameIDPolicy.valid(gameID) {", source)
        self.assertIn('ShareLink(item: shareURL)', source)
        self.assertIn('.accessibilityIdentifier("player.returnToFeed")', source)
        self.assertIn('.accessibilityIdentifier("player.error.message")', source)

    def test_both_real_iphone_ipad_smoke_paths_are_kept_strict(self):
        tests = (ROOT / "HephaestusUITests/PlayerSmokeTests.swift").read_text()
        self.assertIn("testInvalidPlayerIDShowsNativeRecoveryWithoutShare", tests)
        self.assertIn("testInvalidPlayerIDAccessibilityFiveKeepsReturnToFeed", tests)
        self.assertIn("XCTAssertFalse(app.webViews.firstMatch.exists", tests)
        self.assertIn('XCTAssertFalse(app.buttons["player.share"].exists', tests)
        self.assertIn('XCTAssertFalse(app.buttons["player.retry"].exists', tests)
        self.assertIn('XCTAssertTrue(returnButton.exists && returnButton.isHittable', tests)
        self.assertIn("XCTNSPredicateExpectation", tests)
        self.assertIn("XCTAttachment(screenshot: XCUIScreen.main.screenshot())", tests)
        # No test-only access-control bypass or global Xcode test skip.
        self.assertNotIn("XCTSkip", tests[
            tests.index("func testInvalidPlayerIDShowsNativeRecoveryWithoutShare"):
            tests.index("func testDiscoverLaunchesPlayer")
        ])

if __name__ == "__main__":
    unittest.main()
