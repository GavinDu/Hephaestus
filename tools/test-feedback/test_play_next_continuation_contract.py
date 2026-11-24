"""Production wiring contract for real asynchronous Next Game navigation.
No invented game, account, result, HTTP response, or screenshot.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PlayNextContinuationContractTests(unittest.TestCase):
    def test_host_captures_lease_before_task_and_revalidates_after_await(self):
        source = (ROOT / "Hephaestus/Views/Discover/DiscoverView.swift").read_text()
        begin = source.split("private func beginAdvanceToNextGame(", 1)[1].split(
            "private func advanceToNextGame(", 1)[0]
        advance = source.split("private func advanceToNextGame(", 1)[1].split(
            "private func loadMore()", 1)[0]
        self.assertLess(begin.index("pendingPlayNext = operation"), begin.index("Task {"))
        self.assertEqual(advance.count("FeedPlayNextPolicy.isCurrent("), 2)
        self.assertGreater(advance.rindex("FeedPlayNextPolicy.isCurrent("), advance.index("await loadMore()"))
        self.assertGreater(advance.index("resultPresentation = nil"), advance.rindex("FeedPlayNextPolicy.isCurrent("))
        self.assertIn("visibleIDs: visibleGames.map(\\.id)", advance)
        self.assertLess(advance.index("guard let nextID else"), advance.index("resultPresentation = nil"))
        self.assertIn("playNextFeedback = FeedPlayNextFeedback(context: operation.context", advance)
        self.assertIn("playNextFeedback = nil", begin)
        self.assertIn("committedSearchQuery = destination.searchText", advance)
        self.assertIn("if pendingPlayNext?.id == operation.id", advance)
        self.assertIn("dismissesOnNextGame: false", source)

    def test_result_button_preserves_native_progress_and_parent_dismissal(self):
        source = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        sheet = source.split("struct PlayerResultSheet: View", 1)[1].split(
            "// MARK: - Verified-result WKWebView host", 1)[0]
        self.assertIn("if dismissesOnNextGame { dismiss() }", sheet)
        self.assertIn(".disabled(isAdvancingToNextGame)", sheet)
        self.assertIn("Finding next game", sheet)
        self.assertIn("player.result.nextFeedback", sheet)
        self.assertIn("ScrollView {", sheet)
        self.assertIn("Button(\"Done\") { dismiss() }", sheet)


if __name__ == "__main__":
    unittest.main()
