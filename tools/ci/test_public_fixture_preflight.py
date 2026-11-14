"""Offline unit tests for the actual native-smoke public fixture prerequisite."""
import unittest
from email.message import Message
from unittest.mock import patch

from public_fixture_preflight import (
    FixtureUnavailable,
    eligible_games,
    package_is_playable,
    package_url,
    network_read_json,
    verify_fixture,
)


FEED = "https://html-5-game-generator.replit.app/v1/feed"


def ready_game(**overrides):
    game = {
        "id": "published-game-123",
        "owner_id": "real-owner-456",
        "title": "Real title not logged",
        "status": "ready",
        "visibility": "public",
        "moderation_status": "approved",
        "published_version": 1,
    }
    game.update(overrides)
    return game


def published_package(**overrides):
    pkg = {
        "packageFormatVersion": "1",
        "minRuntimeVersion": "2026.10.23.2",
        "irVersion": "2.0",
        "gameId": "published-game-123",
        "ir": {"irVersion": "2.0", "game": {"title": "real"}},
    }
    pkg.update(overrides)
    return pkg


class PublicFixtureTests(unittest.TestCase):
    def test_accepts_actual_public_owner_and_matching_package(self):
        responses = {
            FEED: {"games": [ready_game()]},
            package_url(FEED, "published-game-123"): published_package(),
        }
        result = verify_fixture(FEED, responses.__getitem__)
        self.assertTrue(result["verified"])
        self.assertEqual(result["feed_games"], 1)
        self.assertEqual(result["eligible_games"], 1)
        self.assertEqual(result["packages_checked"], 1)
        self.assertEqual(result["package_errors"], 0)
        self.assertEqual(len(result["game_sha12"]), 12)
        self.assertNotIn("real-owner-456", repr(result))
        self.assertNotIn("published-game-123", repr(result))

    def test_missing_and_malformed_feed_are_not_passes(self):
        for invalid in ({}, {"games": None}, {"games": "not-an-array"},
                        [], {"cards": [ready_game()]}):
            with self.subTest(invalid=invalid):
                with self.assertRaises(FixtureUnavailable):
                    eligible_games(invalid)

    def test_empty_feed_is_not_ready(self):
        result = verify_fixture(FEED, lambda url: {"games": []})
        self.assertFalse(result["verified"])
        self.assertEqual(result["feed_games"], 0)
        self.assertEqual(result["packages_checked"], 0)

    def test_requires_owner_public_moderation_ready_and_published_version(self):
        mutations = [
            {"owner_id": ""}, {"owner_id": None}, {"status": "draft"},
            {"visibility": "private"}, {"moderation_status": "pending"},
            {"moderation_status": "rejected"}, {"moderation_status": "quarantined"},
            {"quarantined": True}, {"published_version": 0},
            {"published_version": None}, {"published_version": True},
            {"id": "", "game_id": ""}, {"owner_id": []},
        ]
        for change in mutations:
            with self.subTest(change=change):
                _, candidates = eligible_games({"games": [ready_game(**change)]})
                self.assertEqual(candidates, [])

    def test_real_game_id_or_legacy_game_id_accepted(self):
        game = ready_game()
        game.pop("id")
        game["game_id"] = "published-game-123"
        _, candidates = eligible_games({"games": [game]})
        self.assertEqual(len(candidates), 1)

    def test_package_requires_matching_id_and_real_nonempty_ir(self):
        invalid = [
            {"gameId": "other-game"},
            {"ir": None}, {"ir": {}}, {"ir": {"game": {}}},
            {"irVersion": ""}, {"packageFormatVersion": ""},
            {"minRuntimeVersion": None},
        ]
        for change in invalid:
            with self.subTest(change=change):
                self.assertFalse(package_is_playable(
                    published_package(**change), "published-game-123"))
        self.assertTrue(package_is_playable(published_package(), "published-game-123"))

    def test_invalid_package_never_claims_success(self):
        def read_json(url):
            if url == FEED:
                return {"games": [ready_game()]}
            return published_package(gameId="wrong-game")
        result = verify_fixture(FEED, read_json)
        self.assertFalse(result["verified"])
        self.assertEqual(result["package_errors"], 1)

    def test_package_error_does_not_hide_healthy_later_game(self):
        first = ready_game(id="game-1")
        second = ready_game(id="published-game-123")
        def read_json(url):
            if url == FEED:
                return {"games": [first, second]}
            if url == package_url(FEED, "game-1"):
                raise FixtureUnavailable("http_503")
            return published_package()
        result = verify_fixture(FEED, read_json)
        self.assertTrue(result["verified"])
        self.assertEqual(result["packages_checked"], 2)
        self.assertEqual(result["package_errors"], 1)

    def test_origin_locked_and_path_escaped(self):
        self.assertEqual(
            package_url(FEED, "one/two?x=1"),
            "https://html-5-game-generator.replit.app/v1/games/one%2Ftwo%3Fx%3D1/package",
        )
        for url in (
            "http://html-5-game-generator.replit.app/v1/feed",
            "https://user:secret@html-5-game-generator.replit.app/v1/feed",
            "https://html-5-game-generator.replit.app/other",
            "https://html-5-game-generator.replit.app/v1/feed?token=private",
            "https://html-5-game-generator.replit.app/v1/feed#secret",
        ):
            with self.subTest(url=url):
                with self.assertRaises(FixtureUnavailable):
                    package_url(url, "game")

    def test_malformed_network_json_and_html_200_fail_closed(self):
        class FakeResponse:
            status = 200

            def __init__(self, payload, content_type):
                self._payload = payload
                self.headers = Message()
                self.headers.add_header("Content-Type", content_type)

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, tb):
                return False

            def read(self, size):
                return self._payload[:size]

        for payload, content_type, expected in (
            (b"{invalid-json", "application/json", "invalid_json"),
            (b"<html>not a creator/game</html>", "text/html",
             "content_type_not_json"),
        ):
            with self.subTest(expected=expected):
                with patch("public_fixture_preflight.request.build_opener") as opener:
                    opener.return_value.open.return_value = FakeResponse(
                        payload, content_type)
                    with self.assertRaisesRegex(FixtureUnavailable, expected):
                        network_read_json(FEED)

    def test_nonobject_entries_are_ignored_not_promoted(self):
        total, candidates = eligible_games({
            "games": ["untrusted", None, [], {}, ready_game()]
        })
        self.assertEqual(total, 5)
        self.assertEqual(len(candidates), 1)


if __name__ == "__main__":
    unittest.main()
