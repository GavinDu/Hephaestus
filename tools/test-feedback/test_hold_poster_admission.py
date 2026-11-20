"""Guard the shipping PixiPlayer hold poster AsyncImage admission boundary."""
from pathlib import Path
import re
import unittest

SOURCE = (Path(__file__).resolve().parents[2] /
          "Hephaestus" / "Player" / "PixiPlayer.swift")


class NativeHoldPosterURLPolicySourceTests(unittest.TestCase):
    def test_hold_image_only_uses_admitted_url_in_every_display_branch(self):
        source = SOURCE.read_text(encoding="utf-8")
        start = source.index("struct PixiPlayerSheet: View {")
        sheet = source[start:]
        self.assertIn("enum PlayerHoldPosterURLPolicy", source)
        self.assertIn("private var admittedHoldPosterURL: URL?", sheet)
        self.assertIn("PlayerHoldPosterURLPolicy.admittedURL(", sheet)
        self.assertIn("holdPosterURL, backendOrigin: BackendConfig.baseURL", sheet)
        self.assertIn("if let holdURL = admittedHoldPosterURL {", sheet)
        self.assertEqual(sheet.count("if admittedHoldPosterURL != nil, holdVisible {"), 3)
        self.assertNotIn("URL(string: holdPosterURL)", sheet)
        self.assertNotIn("if holdPosterURL != nil, holdVisible {", sheet)

    def test_policy_bounds_and_rejects_untrusted_schemes(self):
        source = SOURCE.read_text(encoding="utf-8")
        policy = source.split("enum PlayerHoldPosterURLPolicy {", 1)[1].split(
            "// MARK: - Quality (performance control)", 1
        )[0]
        for required in (
            "raw.utf8.prefix(2049).count",
            "CharacterSet.controlCharacters.contains(scalar)",
            "CharacterSet.whitespacesAndNewlines.contains(scalar)",
            "components.fragment == nil",
            "components.user == nil",
            "components.password == nil",
            'scheme == "https"',
            'scheme == "http"',
            'backendOrigin.scheme?.lowercased() == "http"',
            "host.lowercased() == backendOrigin.host?.lowercased()",
            "(components.port ?? 80) == (backendOrigin.port ?? 80)",
        ):
            self.assertIn(required, policy)
        self.assertNotIn("URLSession.shared", policy)
        self.assertNotIn("evaluateJavaScript", policy)


if __name__ == "__main__":
    unittest.main()
