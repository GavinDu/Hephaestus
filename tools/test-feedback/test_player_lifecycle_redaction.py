"""Block free-form player lifecycle DevLog regression without hiding #608.

#610 changes nine independent lifecycle sites. The one remaining load-failure
site belongs to existing #608 / PR #647, not to this source-only patch.
After #608 merges, zero remaining gameID sites is also acceptable.
"""

from pathlib import Path
import re
import unittest


PLAYER = Path(__file__).resolve().parents[2] / "Hephaestus" / "Player" / "PixiPlayer.swift"
CALL = re.compile(r"DevLog\.(?:info|warn|error)\s*\(")


class PlayerLifecycleDevLogPrivacyTests(unittest.TestCase):
    def test_only_existing_separate_load_failure_may_contain_game_identity(self):
        lines = PLAYER.read_text(encoding="utf-8").splitlines()
        logs = [(index, line.strip()) for index, line in enumerate(lines, 1)
                if CALL.search(line)]
        self.assertGreaterEqual(len(logs), 10)
        remaining = [(index, line) for index, line in logs if "gameID" in line]
        self.assertLessEqual(len(remaining), 1)
        for index, line in remaining:
            self.assertIn(
                'DevLog.error(.player, "player load failed for \\(gameID): \\(diagnostic)")',
                line,
                f"Unscoped private identity in native lifecycle log at line {index}"
            )

    def test_nine_event_categories_use_fixed_bounded_helpers(self):
        text = PLAYER.read_text(encoding="utf-8")
        expected = [
            "prewarm",
            "navigationFinished(milliseconds: ms)",
            "autoReload(completedReloads: autoReloads)",
            "terminatedRepeatedly",
            "backgrounded",
            "foregrounded",
            "memoryWarning",
            "thermal(state)",
            "opened",
        ]
        for event in expected:
            with self.subTest(event=event):
                self.assertIn("PlayerLocalLifecycleLog." + event, text)
        policy = text.split("enum PlayerLocalLifecycleLog {", 1)[1].split(
            "/// A game may not navigate", 1
        )[0]
        for forbidden in ("gameID", "localizedDescription", "absoluteString",
                          "URLRequest", "userInfo", "authToken"):
            self.assertNotIn(forbidden, policy)
        self.assertIn("min(3_600_000, max(0, milliseconds))", policy)
        self.assertIn("min(2, max(0, completedReloads))", policy)


if __name__ == "__main__":
    unittest.main()
