"""Native published GamePackage ID grammar must have exactly one owner (#653)."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
BACKEND = ROOT / "Hephaestus/Backend/BackendAPI.swift"
PLAYER = ROOT / "Hephaestus/Player/PixiPlayer.swift"

class NativePublishedIDSingleContractTests(unittest.TestCase):
    def test_one_shared_byte_bounded_predicate(self):
        backend = BACKEND.read_text()
        player = PLAYER.read_text()
        grammar = backend.split("enum PublishedGameIDPolicy {", 1)[1].split(
            "/// Source-compatible façade", 1
        )[0]
        self.assertIn("for byte in gameID.utf8", grammar)
        self.assertIn("bytes <= maximumUTF8Bytes", grammar)
        self.assertIn("static let maximumUTF8Bytes = 128", grammar)
        self.assertNotIn("Array(", grammar)
        leaderboard = backend.split("enum VerifiedLeaderboardGameIDPolicy {", 1)[1].split(
            "enum VerifiedLeaderboardWindow", 1
        )[0]
        launch = player.split("enum PlayerPublishedGameIDPolicy {", 1)[1].split(
            "struct PixiPlayerRequest", 1
        )[0]
        self.assertIn("PublishedGameIDPolicy.valid(value)", leaderboard)
        self.assertIn("PublishedGameIDPolicy.valid(gameID)", launch)
        for scoped in (leaderboard, launch):
            self.assertNotIn("Array(", scoped)
            self.assertNotIn("for byte in", scoped)

    def test_real_callers_do_not_bypass_validation(self):
        player = PLAYER.read_text()
        backend = BACKEND.read_text()
        self.assertIn("guard PlayerPublishedGameIDPolicy.valid(gameID) else { return nil }", player)
        self.assertIn("guard VerifiedLeaderboardGameIDPolicy.valid(gameID)", backend)
        self.assertIn("VerifiedLeaderboardGameIDPolicy.valid(requestedID)", backend)

if __name__ == "__main__":
    unittest.main()
