"""Offline regression for the real-feed CI prerequisite; never mock the app."""

import importlib.util
import io
import json
import pathlib
from email.message import Message
import unittest


SCRIPT = pathlib.Path(__file__).with_name("verify-live-game-fixture.py")
SPEC = importlib.util.spec_from_file_location("live_fixture_preflight", SCRIPT)
fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)


def public_game(**overrides):
    game = {
        "game_id": "sample-rainbow-bear",
        "owner_id": "published-creator",
        "status": "ready",
        "visibility": "public",
        "moderation_status": "approved",
        "quarantined": False,
    }
    game.update(overrides)
    return game


def valid_package(game_id="sample-rainbow-bear"):
    return {
        "gameId": game_id,
        "packageFormatVersion": "1.0",
        "minRuntimeVersion": "2026.10.23.2",
        "irVersion": "1.2",
        "ir": {"irVersion": "1.2", "game": {"id": game_id}},
    }


class FakeResponse:
    def __init__(self, payload):
        self.status = 200
        self.headers = Message()
        if isinstance(payload, tuple):
            raw, content_type = payload
            self.headers["Content-Type"] = content_type
            self.payload = io.BytesIO(raw)
        else:
            self.headers["Content-Type"] = "application/json; charset=utf-8"
            self.payload = io.BytesIO(json.dumps(payload).encode())

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self, size):
        return self.payload.read(size)


class FakeOpener:
    def __init__(self, pages):
        self.pages = pages
        self.urls = []

    def open(self, req, timeout):
        self.urls.append(req.full_url)
        if req.full_url not in self.pages:
            raise fixture.FixtureError("unexpected host/path")
        return FakeResponse(self.pages[req.full_url])


class LiveGameFixtureTests(unittest.TestCase):
    FEED = "https://games.example.test/v1/feed"
    PACKAGE = "https://games.example.test/v1/games/sample-rainbow-bear/package"

    def test_public_owner_linked_game_requires_retrievable_real_package(self):
        opener = FakeOpener({
            self.FEED: {"games": [public_game()]},
            self.PACKAGE: valid_package(),
        })
        self.assertEqual(
            fixture.check_once(opener, self.FEED, 3.0),
            ("sample-rainbow-bear", 1, 1),
        )
        self.assertEqual(opener.urls, [self.FEED, self.PACKAGE])

    def test_nonpublic_or_unusable_entries_are_not_published_fixtures(self):
        for bad in [
            {"owner_id": ""},
            {"game_id": "../../path"},
            {"visibility": "private"},
            {"status": "draft"},
            {"moderation_status": "pending"},
            {"moderation_status": "rejected"},
            {"quarantined": True},
        ]:
            with self.subTest(bad=bad):
                opener = FakeOpener({self.FEED: {"games": [public_game(**bad)]}})
                with self.assertRaisesRegex(fixture.FixtureError, "no eligible"):
                    fixture.check_once(opener, self.FEED, 1)

    def test_http_200_empty_feed_is_not_playable(self):
        with self.assertRaisesRegex(fixture.FixtureError, "no eligible"):
            fixture.check_once(FakeOpener({self.FEED: {"games": []}}), self.FEED, 1)

    def test_missing_games_array_does_not_count_as_ready(self):
        with self.assertRaisesRegex(fixture.FixtureError, "games array"):
            fixture.check_once(FakeOpener({self.FEED: {"status": "ok"}}), self.FEED, 1)

    def test_legacy_inventory_without_moderation_field_still_uses_public_gate(self):
        game = public_game()
        game.pop("moderation_status")
        self.assertEqual(fixture.candidates_in_feed({"games": [game]}), [game["game_id"]])

    def test_malformed_json_and_http_200_html_are_not_playable(self):
        for payload, content_type, expected in (
            (b"<html>stale deployment</html>", "text/html", "not JSON"),
            (b"{not-json", "application/json", "not valid JSON"),
        ):
            with self.subTest(expected=expected):
                opener = FakeOpener({
                    self.FEED: (payload, content_type),
                })
                with self.assertRaisesRegex(fixture.FixtureError, expected):
                    fixture.check_once(opener, self.FEED, 1)

    def test_legacy_public_unset_moderation_does_not_trigger_false_outage(self):
        for moderation in (None, "", "approved"):
            with self.subTest(moderation=moderation):
                self.assertEqual(
                    fixture.candidates_in_feed({
                        "games": [public_game(moderation_status=moderation)]
                    }),
                    ["sample-rainbow-bear"],
                )

    def test_unknown_moderation_is_rejected(self):
        for moderation in ("pending", "rejected", "quarantined"):
            self.assertEqual(
                fixture.candidates_in_feed({
                    "games": [public_game(moderation_status=moderation)]
                }),
                [],
            )

    def test_owner_linked_feed_with_missing_or_mismatched_package_fails(self):
        for pkg in [{}, valid_package("other-game"),
                    {**valid_package(), "ir": {}},
                    {**valid_package(), "ir": "script"},
                    {**valid_package(), "irVersion": ""},
                    {**valid_package(), "ir": {"irVersion": "1.1"}},
                    {**valid_package(), "minRuntimeVersion": ""}]:
            with self.subTest(package=pkg):
                opener = FakeOpener({
                    self.FEED: {"games": [public_game()]},
                    self.PACKAGE: pkg,
                })
                with self.assertRaisesRegex(fixture.FixtureError, "no retrievable"):
                    fixture.check_once(opener, self.FEED, 1)
                self.assertEqual(opener.urls, [self.FEED, self.PACKAGE])


if __name__ == "__main__":
    unittest.main()
