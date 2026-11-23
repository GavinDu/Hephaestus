"""Regression guard for the genuine native Accessibility5 feed Retry locator.

This reads committed XCTest source. It does not invent a published game,
HTTP response, user, artwork, native screenshot, or UI element.
"""
from pathlib import Path
import unittest


SMOKE_SOURCE = (
    Path(__file__).resolve().parents[2]
    / "HephaestusUITests"
    / "PlayerSmokeTests.swift"
)


class AccessibilityFeedRetryLocatorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        full_source = SMOKE_SOURCE.read_text(encoding="utf-8")
        name = "func testDiscoverFeedSupportsAccessibilityDynamicType() throws"
        start = full_source.index(name)
        next_method = full_source.find("\n    func ", start + len(name))
        cls.a5_test = full_source[start:next_method if next_method >= 0 else None]

    def test_real_pending_retry_matches_button_or_popup_button(self):
        self.assertIn(
            'let pendingRetry = app.descendants(matching: .any)'
            '["feed.retryLoading"].firstMatch',
            self.a5_test,
        )
        self.assertNotIn(
            'let pendingRetry = app.buttons["feed.retryLoading"]',
            self.a5_test,
        )

    def test_original_real_feed_and_native_touch_contract_is_not_weakened(self):
        for required in (
            "let feedDeadline = startedLoading.addingTimeInterval(120)",
            "Date().timeIntervalSince(lastRetry) >= 15",
            "Date().timeIntervalSince(startedLoading) > 20",
            "pendingRetry.exists && pendingRetry.isHittable && pendingRetry.isEnabled",
            "frame.width >= 44 && frame.height >= 44",
            "if valid && !play.exists",
            "point.tap()",
            "XCTAssertTrue(play.exists",
            'let mountedActionsDone = app.buttons["feed.actions.dismiss"].firstMatch',
            "let actionSheetMounted = mountedActionsDone.waitForExistence(timeout: 10)",
        ):
            with self.subTest(required=required):
                self.assertIn(required, self.a5_test)


if __name__ == "__main__":
    unittest.main()
