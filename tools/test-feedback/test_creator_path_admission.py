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
        # Scope this audit to the creator admission enum, not to later,
        # unrelated BackendAPI helpers inserted before the API client.
        policy = source.split("enum BackendAPICreatorPathSegmentPolicy {", 1)[1].split(
            "\n}\n\n", 1
        )[0]
        self.assertIn("guard byteCount < 128", policy)
        self.assertIn('creatorID != "."', policy)
        self.assertIn('creatorID != ".."', policy)
        self.assertIn("CharacterSet.controlCharacters.contains(scalar)", policy)
        self.assertIn("CharacterSet.whitespacesAndNewlines.contains(scalar)", policy)
        self.assertIn('scalar != "/"', policy)
        self.assertIn('scalar != "%"', policy)
        self.assertIn('scalar != "?"', policy)
        self.assertIn('scalar != "#"', policy)
        self.assertIn('Array("0123456789ABCDEF".utf8)', policy)
        self.assertIn("pathBytes.append(37)", policy)
        self.assertIn("String(bytes: pathBytes, encoding: .utf8)", policy)
        for forbidden in ('localizedDescription', 'URLSession', 'BackendConfig',
                          'httpBody', 'queryItems', 'URLRequest'):
            self.assertNotIn(forbidden, policy)


if __name__ == "__main__":
    unittest.main()
