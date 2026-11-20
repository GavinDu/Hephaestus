"""Fail closed on private game identity in free-form native player DevLog calls.

Requires #608 local load-failure redaction in this branch base.
Every native player DevLog call now must be identity-free.
This source guard runs in the iOS Xcode job's Python unittest discovery step.
"""
from pathlib import Path
import re
import unittest


PLAYER_SOURCE = (
    Path(__file__).resolve().parents[2]
    / "Hephaestus"
    / "Player"
    / "PixiPlayer.swift"
)
LOG_CALL = re.compile(r"DevLog\.(?:info|warn|error)\s*\(")


class PlayerLifecycleDevLogPrivacyTests(unittest.TestCase):
    def test_no_player_devlog_may_log_private_game_identity(self):
        lines = PLAYER_SOURCE.read_text(encoding="utf-8").splitlines()
        log_lines = [(index, line.strip()) for index, line in enumerate(lines, 1)
                     if LOG_CALL.search(line)]
        self.assertGreaterEqual(len(log_lines), 10, "Player log coverage unexpectedly disappeared")
        for index, line in log_lines:
            self.assertNotIn(
                "gameID", line,
                f"Private game identity reached local player DevLog at line {index}",
            )

    def test_lifecycle_events_use_typed_identity_free_log_helper(self):
        text = PLAYER_SOURCE.read_text(encoding="utf-8")
        events = [
            "prewarm", "navigationFinished(milliseconds: ms)",
            "autoReload(completedReloads: autoReloads)",
            "terminatedRepeatedly", "backgrounded", "foregrounded",
            "memoryWarning", "thermal(state)", "opened",
        ]
        for event in events:
            with self.subTest(event=event):
                self.assertIn("PlayerLocalLifecycleLog." + event, text)
        self.assertIn("enum PlayerLocalLifecycleLog", text)


if __name__ == "__main__":
    unittest.main()
