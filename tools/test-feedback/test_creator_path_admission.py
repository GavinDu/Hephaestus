"""Fail CI if creator IDs reenter BackendAPI paths as raw URL syntax."""
from pathlib import Path
import re
import unittest

SOURCE = Path(__file__).resolve().parents[2] / "Hephaestus" / "Backend" / "BackendAPI.swift"


class NativeCreatorPathAdmissionTests(unittest.TestCase):
    def test_all_three_creator_routes_admit_single_encoded_segment(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn("enum BackendAPICreatorPathSegmentPolicy", source)
        for signature, route in (
            ("func setFollowing(_ creatorID:", 'v1/users/\\(segment)/follow'),
            ("func blockCreator(_ creatorID:", 'v1/users/\\(segment)/block'),
            ("func fetchCreatorProfile(id:", 'v1/users/\\(segment)'),
        ):
            body = source.split(signature, 1)[1].split("\n    }\n", 1)[0]
            self.assertIn("BackendAPICreatorPathSegmentPolicy.encoded(", body)
            self.assertIn("throw APIError.invalidInput", body)
            self.assertIn(route, body)
            self.assertNotRegex(body, r"v1/users/\\\((?:creatorID|id)\)")
        self.assertNotIn('v1/users/\\(creatorID)', source)
        self.assertNotIn('v1/users/\\(id)', source)

    def test_policy_rejects_reserved_or_percent_syntax_before_interpolation(self):
        source = SOURCE.read_text(encoding="utf-8")
        policy = source.split("enum BackendAPICreatorPathSegmentPolicy {", 1)[1].split(
            "/// Thin async client", 1
        )[0]
        self.assertIn("guard count < 128", policy)
        self.assertIn('creatorID != "."', policy)
        self.assertIn('creatorID != ".."', policy)
        self.assertIn('with: "%7C"', policy)
        self.assertIn('with: "%3A"', policy)
        self.assertIn('with: "%40"', policy)
        for forbidden in ('localizedDescription', 'URLSession', 'BackendConfig',
                          'httpBody', 'queryItems', 'URLRequest'):
            self.assertNotIn(forbidden, policy)


if __name__ == "__main__":
    unittest.main()
