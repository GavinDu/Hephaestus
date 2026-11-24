"""Offline regression for the real-feed CI prerequisite; never mock the app."""

import importlib.util
import http.client
import io
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import patch
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
        "packageFormatVersion": "2.0",
        "minRuntimeVersion": "2026.10.23.2",
        "irVersion": "1.2",
        "ir": {"irVersion": "1.2", "game": {"id": game_id}},
        "irSha256": "a" * 64,
        "irHash": "a" * 12,
        "assets": [],
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
        value = self.pages[req.full_url]
        if isinstance(value, Exception):
            raise value
        return FakeResponse(value)


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
            (1, 1),
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
            {"quarantined": "false"},
            {"quarantined": 0},
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
            (b"<html>stale deployment</html>", "text/html", "feed_failure=not_json"),
            (b"{not-json", "application/json", "feed_failure=invalid_json"),
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


    def test_package_failure_breakdown_is_bounded_and_never_reveals_identity(self):
        feed = {"games": [public_game()]}
        failures = [
            (fixture.FixtureError("endpoint returned HTTP 404"), "http_404:1"),
            (fixture.FixtureError("endpoint returned HTTP 403"), "http_403:1"),
            (fixture.FixtureError("unexpected host/path"), "unavailable:1"),
            ((b"<html>no package</html>", "text/html"), "not_json:1"),
            ((b"{not-json", "application/json"), "invalid_json:1"),
            ({}, "invalid_envelope_game_id_mismatch:1"),
        ]
        for response, expected in failures:
            with self.subTest(category=expected):
                opener = FakeOpener({self.FEED: feed, self.PACKAGE: response})
                with self.assertRaises(fixture.FixtureError) as raised:
                    fixture.check_once(opener, self.FEED, 1)
                message = str(raised.exception)
                self.assertIn("package_failure_breakdown=" + expected, message)
                self.assertNotIn("sample-rainbow-bear", message)
                self.assertNotIn("published-creator", message)
                self.assertNotIn(self.PACKAGE, message)

    def test_package_envelope_failures_have_safe_fixed_field_categories(self):
        cases = [
            (None, "not_object"),
            ({}, "game_id_mismatch"),
            ({**valid_package(), "gameId": "other-private-game"}, "game_id_mismatch"),
            ({**valid_package(), "packageFormatVersion": ""}, "missing_package_format"),
            ({**valid_package(), "packageFormatVersion": "1.0"}, "unsupported_package_format"),
            ({**valid_package(), "packageFormatVersion": "3.0"}, "unsupported_package_format"),
            ({**valid_package(), "packageFormatVersion": None}, "missing_package_format"),
            ({**valid_package(), "minRuntimeVersion": None}, "missing_min_runtime"),
            ({**valid_package(), "irVersion": ""}, "missing_ir_version"),
            ({**valid_package(), "ir": {}}, "missing_ir"),
            ({**valid_package(), "ir": {"game": {}}}, "missing_ir_ir_version"),
            ({**valid_package(), "ir": {"irVersion": "1.1"}}, "ir_version_mismatch"),
            ({**valid_package(), "irSha256": ""}, "missing_full_ir_sha"),
            ({**valid_package(), "irSha256": "a" * 12}, "missing_full_ir_sha"),
            ({**valid_package(), "irSha256": "A" * 64}, "missing_full_ir_sha"),
            ({**valid_package(), "irHash": "b" * 12}, "short_ir_hash_mismatch"),
            ({**valid_package(), "assets": None}, "missing_assets_array"),
            ({**valid_package(), "assets": {}}, "missing_assets_array"),
        ]
        for payload, category in cases:
            with self.subTest(category=category):
                self.assertEqual(
                    fixture.package_invalid_reason(payload, "sample-rainbow-bear"),
                    category,
                )
                self.assertFalse(fixture.package_is_playable(payload, "sample-rainbow-bear"))
        self.assertIsNone(fixture.package_invalid_reason(valid_package(), "sample-rainbow-bear"))
        self.assertTrue(fixture.package_is_playable(valid_package(), "sample-rainbow-bear"))

    def test_missing_package_format_reports_only_allowlisted_wire_key_names(self):
        payload = valid_package()
        payload.pop("packageFormatVersion")
        payload["private_creator_personal_profile"] = "private-creator-secret"
        payload["tracking_token"] = "private-token-value"
        self.assertEqual(
            fixture.safe_package_field_presence(payload),
            "gameId|minRuntimeVersion|irVersion|ir|irHash|irSha256|assets",
        )
        opener = FakeOpener({
            self.FEED: {"games": [public_game()]},
            self.PACKAGE: payload,
        })
        with self.assertRaises(fixture.FixtureError) as raised:
            fixture.check_once(opener, self.FEED, 1.0)
        message = str(raised.exception)
        self.assertIn("invalid_envelope_missing_package_format:1", message)
        self.assertIn(
            "safe_package_keys=gameId|minRuntimeVersion|irVersion|ir|irHash|irSha256|assets:1",
            message,
        )
        for secret in (
            "sample-rainbow-bear", "published-creator", self.PACKAGE,
            "tracking_token", "private_creator_personal_profile",
            "private-creator-secret", "private-token-value",
        ):
            self.assertNotIn(secret, message)
        self.assertEqual(fixture.safe_package_field_presence({}), "none")
        self.assertEqual(fixture.safe_package_field_presence(None), "not_object")

    def test_package_error_classifier_never_echoes_arbitrary_exception_strings(self):
        self.assertEqual(fixture.package_failure_category("endpoint returned HTTP 404"), "http_404")
        self.assertEqual(fixture.package_failure_category("endpoint returned HTTP 200 see /secret"), "unavailable")
        self.assertEqual(fixture.package_failure_category("private endpoint user=creator"), "unavailable")
        self.assertEqual(fixture.package_failure_category("endpoint returned HTTP 500"), "http_500")



    def test_ambiguous_or_nonstandard_json_fails_at_any_depth(self):
        for raw in (b'{"games":[],"games":[]}',
                    b'{"games":[{"owner_id":"private","owner_id":"other"}]}',
                    b'{"games":[],"extra":NaN}',
                    b'{"games":[],"extra":Infinity}',
                    b'{"games":[],"extra":-Infinity}',
                    b'{"games":[],"extra":1e999}',
                    b'{"games":[' + b'[' * 1500 + b']' * 1500 + b']}'):
            with self.subTest(raw_length=len(raw)):
                with self.assertRaisesRegex(fixture.FixtureError, "feed_failure=invalid_json"):
                    fixture.check_once(FakeOpener({self.FEED: (raw, "application/json")}), self.FEED, 1)

    def test_explicit_depth_limit_is_decoder_independent_and_string_aware(self):
        depth = fixture.MAX_JSON_NESTING
        safe_string = '[{' * 100 + '"\\' + ']}' * 100
        safe = {"games": [], "text": safe_string}
        self.assertEqual(json.loads(fixture.enforce_json_nesting(json.dumps(safe).encode())), safe)
        allowed = b'[' * depth + b'0' + b']' * depth
        self.assertEqual(fixture.enforce_json_nesting(allowed), allowed.decode())
        for raw in (b'[' * (depth + 1) + b'0' + b']' * (depth + 1),
                    b'{"games":[],"extra":' + b'[' * depth + b'0' + b']' * depth + b'}',
                    '{"games":[]}'.encode("utf-16")):
            with self.subTest(raw_length=len(raw)):
                with self.assertRaisesRegex(fixture.FixtureError, "feed_failure=invalid_json"):
                    fixture.check_once(FakeOpener({self.FEED: (raw, "application/json")}), self.FEED, 1)

    def test_transport_errors_are_redacted_even_if_protocol_parser_has_private_text(self):
        for error in (http.client.BadStatusLine("private-wire-value"),
                      http.client.IncompleteRead(b"private-wire-value", 9),
                      ValueError("private-wire-value")):
            with self.subTest(category=type(error).__name__):
                opener = FakeOpener({self.FEED: error})
                with self.assertRaises(fixture.FixtureError) as raised:
                    fixture.check_once(opener, self.FEED, 1)
                self.assertEqual(str(raised.exception), "feed_failure=transport")
                self.assertNotIn("private-wire-value", str(raised.exception))

    def test_response_byte_bound_and_non_object(self):
        for raw, reason in ((b"x" * (fixture.MAX_JSON_BYTES + 1), "too_large"),
                            (b"[]", "not_object")):
            with self.subTest(reason=reason):
                with self.assertRaisesRegex(fixture.FixtureError, "feed_failure=" + reason):
                    fixture.check_once(FakeOpener({self.FEED: (raw, "application/json")}), self.FEED, 1)

    def test_redirect_handler_refuses_even_same_origin(self):
        handler = fixture.NoRedirect()
        for code in (301, 302, 303, 307, 308):
            for destination in (self.PACKAGE, "https://private.example.test/token"):
                with self.subTest(code=code):
                    with self.assertRaisesRegex(fixture.FixtureError, "redirected"):
                        handler.redirect_request(None, None, code, "", {}, destination)

    def test_multiple_unique_candidates_and_five_request_budget(self):
        games = [public_game(game_id="game-" + str(i)) for i in range(7)]
        pages = {self.FEED: {"games": [games[0], games[0], *games[1:]]}}
        for i in range(7):
            pages["https://games.example.test/v1/games/game-" + str(i) + "/package"] = (
                valid_package("game-" + str(i)) if i == 2 else {})
        opener = FakeOpener(pages)
        self.assertEqual(fixture.check_once(opener, self.FEED, 1), (8, 7))
        self.assertEqual(len(opener.urls), 4)
        pages["https://games.example.test/v1/games/game-2/package"] = {}
        pages["https://games.example.test/v1/games/game-5/package"] = valid_package("game-5")
        opener = FakeOpener(pages)
        with self.assertRaisesRegex(fixture.FixtureError, "game_id_mismatch:5"):
            fixture.check_once(opener, self.FEED, 1)
        self.assertEqual(len(opener.urls), 6)

    def test_public_endpoint_validation_is_fail_closed(self):
        self.assertTrue(fixture.valid_public_feed_url(self.FEED))
        self.assertTrue(fixture.valid_public_feed_url("https://games.example.test:443/v1/feed"))
        for url in ("http://games.example.test/v1/feed", "https://user:secret@games.example.test/v1/feed",
                    "https://@games.example.test/v1/feed", self.FEED + "?token=x", self.FEED + "#",
                    self.FEED + "/", "https://games.example.test:bad/v1/feed",
                    "https://games.example.test:444/v1/feed", "https://[bad/v1/feed",
                    "https://games.example.test/\tv1/feed", "https://games.example.test\\evil/v1/feed"):
            self.assertFalse(fixture.valid_public_feed_url(url))
            opener = FakeOpener({})
            with self.assertRaisesRegex(fixture.FixtureError, "invalid public feed endpoint"):
                fixture.check_once(opener, url, 1)
            self.assertEqual(opener.urls, [])

    def test_success_and_failure_cli_output_do_not_expose_identity(self):
        for package, expected_status, marker in ((valid_package(), 0, "package=v2_shape_only"),
                                                  ({}, 1, "invalid_envelope_game_id_mismatch")):
            opener = FakeOpener({self.FEED: {"games": [public_game()]}, self.PACKAGE: package})
            output, errors = io.StringIO(), io.StringIO()
            with patch.object(fixture.request, "build_opener", return_value=opener):
                with redirect_stdout(output), redirect_stderr(errors):
                    status = fixture.main(["--feed-url", self.FEED, "--attempts", "1"])
            self.assertEqual(status, expected_status)
            combined = output.getvalue() + errors.getvalue()
            self.assertIn(marker, combined)
            for forbidden in ("sample-rainbow-bear", "published-creator", self.PACKAGE, "game_sha12"):
                self.assertNotIn(forbidden, combined)


if __name__ == "__main__":
    unittest.main()
