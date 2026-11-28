"""Offline schema tests only. Never substitute these rows for real UI/backend fixtures."""
import contextlib
import io
import json
import unittest
from unittest import mock
from urllib import error

import check_creator_discovery_contract as contract


def encode(value):
    return json.dumps(value).encode("utf-8")


class CreatorDiscoveryContractTests(unittest.TestCase):
    def setUp(self):
        self.valid = {
            "creators": [
                {"creator_id": "unit-test-owner", "post_count": 2, "topics": ["puzzle"]},
            ],
            "next_cursor": None,
        }

    def failure(self, value, category, status=200, content_type="application/json"):
        with self.assertRaises(contract.ContractError) as caught:
            contract.validate_response(status, content_type, encode(value))
        self.assertEqual(caught.exception.category, category)

    def test_real_schema_shape_accepts_empty_directory_and_valid_entries(self):
        self.assertEqual(contract.validate_response(
            200, "application/json; charset=utf-8",
            encode({"creators": [], "next_cursor": ""})), 0)
        self.assertEqual(contract.validate_response(
            200, "application/problem+json", encode(self.valid)), 1)
        # Forward-compatible additional metadata does not fabricate a creator.
        self.valid["version"] = 2
        self.assertEqual(contract.validate_response(
            200, "application/json", encode(self.valid)), 1)

    def test_html_http_200_is_not_empty_creator_directory(self):
        with self.assertRaises(contract.ContractError) as caught:
            contract.validate_response(200, "text/html", b"<html>app shell</html>")
        self.assertEqual(caught.exception.category, "html_instead_of_json")
        self.failure(self.valid, "non_json_content_type", content_type="text/plain")

    def test_malformed_json_or_non_object_root_fails(self):
        with self.assertRaises(contract.ContractError) as caught:
            contract.validate_response(200, "application/json", b"{not-json")
        self.assertEqual(caught.exception.category, "malformed_json")
        with self.assertRaises(contract.ContractError) as caught:
            contract.validate_response(200, "application/json", b"[]")
        self.assertEqual(caught.exception.category, "wrong_root_type")

    def test_reject_http_error_or_redirect_even_if_body_is_valid(self):
        self.failure(self.valid, "unexpected_http_status", status=404)
        self.failure(self.valid, "unexpected_redirect", status=302)
        self.assertIsNone(contract.RejectRedirects().redirect_request(
            None, None, 302, "redirect", {}, "https://other.invalid"))

    def test_redirect_classification_never_treats_target_as_success(self):
        cases = [
            ("/player?token=unit-secret", "same_origin_player"),
            ("https://html-5-game-generator.replit.app:443/player/", "same_origin_player"),
            ("/login?next=unit-secret", "same_origin_login"),
            ("//html-5-game-generator.replit.app/auth/login", "same_origin_login"),
            ("/player-other", "same_origin_other"),
            ("?token=unit-secret", "same_origin_other"),
            ("https://html-5-game-generator.replit.app:444/player", "cross_origin"),
            ("https://html-5-game-generator.replit.app:0/player", "cross_origin"),
            ("///player", "missing_or_invalid"),
            ("/player\n", "missing_or_invalid"),
            ("https://other.invalid/login?token=unit-secret", "cross_origin"),
            ("http://html-5-game-generator.replit.app/player", "insecure_or_non_https"),
            ("javascript:alert(1)", "insecure_or_non_https"),
            ("https:login", "missing_or_invalid"),
            ("https://user:secret@html-5-game-generator.replit.app/player", "missing_or_invalid"),
            ("https://html-5-game-generator.replit.app:bad/player", "missing_or_invalid"),
            ("https://[broken", "missing_or_invalid"),
            ("/player\\n", "missing_or_invalid"),
            ("/\\\\other.invalid", "missing_or_invalid"),
            (None, "missing_or_invalid"),
            ("", "missing_or_invalid"),
        ]
        for location, expected in cases:
            with self.subTest(location=location):
                self.assertEqual(contract.classify_redirect(location), expected)
                with self.assertRaises(contract.ContractError) as caught:
                    contract.validate_response(302, "application/json",
                                               encode(self.valid), location)
                self.assertEqual(caught.exception.category, "unexpected_redirect")
                self.assertEqual(caught.exception.http_status, 302)
                self.assertEqual(caught.exception.redirect_category, expected)

    def test_http_error_redirect_reports_fixed_category_without_follow_or_payload(self):
        failure = error.HTTPError(contract.PUBLIC_ENDPOINT, 302, "unit-secret",
                                  {"Location": "/player?token=unit-secret"},
                                  io.BytesIO(b"unit-secret-body"))
        opener = mock.Mock()
        opener.open.side_effect = failure
        output = io.StringIO()
        with mock.patch.object(contract.request, "build_opener", return_value=opener):
            with contextlib.redirect_stdout(output):
                self.assertEqual(contract.main(), 1)
        opener.open.assert_called_once()
        self.assertEqual(opener.open.call_args.args[0].get_header("Accept"), "application/json")
        self.assertEqual(output.getvalue().strip(),
                         "creator_schema_contract result=FAIL category=unexpected_redirect "
                         "http_status=302 redirect_category=same_origin_player")
        self.assertNotIn("unit-secret", output.getvalue())

    def test_redirect_handler_rejects_before_urllib_parses_malformed_location(self):
        req = contract.request.Request(contract.PUBLIC_ENDPOINT)
        handler = contract.RejectRedirects()
        for status in (301, 302, 303, 307, 308):
            with self.subTest(status=status):
                raw = {"Location": "https://[broken"}
                stream = io.BytesIO(b"never-read")
                with self.assertRaises(error.HTTPError) as caught:
                    getattr(handler, "http_error_" + str(status))(
                        req, stream, status, "redirect", raw)
                self.assertEqual(caught.exception.code, status)
                self.assertEqual(caught.exception.headers, raw)
                self.assertEqual(stream.tell(), 0)
                caught.exception.close()

    def test_nonstandard_redirect_response_is_not_read_or_followed(self):
        response = mock.MagicMock()
        response.status = 307
        response.headers = {"Location": "https://other.invalid/hidden?token=unit-secret"}
        response.__enter__.return_value = response
        opener = mock.Mock()
        opener.open.return_value = response
        output = io.StringIO()
        with mock.patch.object(contract.request, "build_opener", return_value=opener):
            with contextlib.redirect_stdout(output):
                self.assertEqual(contract.main(), 1)
        opener.open.assert_called_once()
        response.read.assert_not_called()
        self.assertEqual(output.getvalue().strip(),
                         "creator_schema_contract result=FAIL category=unexpected_redirect "
                         "http_status=307 redirect_category=cross_origin")

    def test_required_fields_and_cursor_cannot_be_missing_or_null(self):
        self.failure({"next_cursor": None}, "missing_or_invalid_creators")
        self.failure({"creators": None, "next_cursor": None},
                     "missing_or_invalid_creators")
        self.failure({"creators": {}, "next_cursor": None},
                     "missing_or_invalid_creators")
        self.failure({"creators": []}, "missing_or_invalid_cursor")
        self.failure({"creators": [], "next_cursor": 123},
                     "missing_or_invalid_cursor")

    def test_rows_require_private_id_type_count_and_topic_types(self):
        for bad, category in [
            (None, "invalid_creator_entry"),
            ({"post_count": 2, "topics": []}, "invalid_creator_id_type"),
            ({"creator_id": "", "post_count": 2, "topics": []}, "invalid_creator_id_type"),
            ({"creator_id": "x", "post_count": True, "topics": []}, "invalid_post_count_type"),
            ({"creator_id": "x", "post_count": -1, "topics": []}, "invalid_post_count_type"),
            ({"creator_id": "x", "post_count": 1.5, "topics": []}, "invalid_post_count_type"),
            ({"creator_id": "x", "post_count": 1, "topics": None}, "invalid_topics_type"),
            ({"creator_id": "x", "post_count": 1, "topics": ["puzzle", 4]},
             "invalid_topics_type"),
        ]:
            self.failure({"creators": [bad], "next_cursor": None}, category)

    def test_reject_oversized_body_without_parsing_or_logging_it(self):
        with self.assertRaises(contract.ContractError) as caught:
            contract.validate_response(
                200, "application/json", b"x" * (contract.MAX_BODY_BYTES + 1))
        self.assertEqual(caught.exception.category, "oversized_response")

    def test_stdout_contains_only_classification_never_error_payload(self):
        output = io.StringIO()
        with mock.patch.object(contract, "probe",
                               side_effect=contract.ContractError("non_json_content_type")):
            with contextlib.redirect_stdout(output):
                self.assertEqual(contract.main(), 1)
        self.assertEqual(
            output.getvalue().strip(),
            "creator_schema_contract result=FAIL category=non_json_content_type")
        self.assertNotIn("unit-test-owner", output.getvalue())
        with mock.patch.object(contract, "probe",
                               side_effect=contract.ContractError("unexpected_redirect", 302)):
            with contextlib.redirect_stdout(output):
                self.assertEqual(contract.main(), 1)
        self.assertIn("category=unexpected_redirect http_status=302", output.getvalue())
        self.assertNotIn("other.invalid", output.getvalue())


if __name__ == "__main__":
    unittest.main()
