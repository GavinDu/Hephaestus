"""Offline schema tests only. Never substitute these rows for real UI/backend fixtures."""
import contextlib
import io
import json
import unittest
from unittest import mock

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
