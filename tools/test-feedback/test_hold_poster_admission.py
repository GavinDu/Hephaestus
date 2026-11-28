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
        # The live sheet has two guarded display paths: a backdrop and a
        # progress overlay. Check both rather than relying on an obsolete
        # pre-handoff third guard that no longer exists in production.
        self.assertEqual(sheet.count("if admittedHoldPosterURL != nil, holdVisible {"), 2)
        self.assertIn("if admittedHoldPosterURL != nil, holdVisible {\n                    holdBackdrop", sheet)
        self.assertIn(
            "if isLoading && loadError == nil, !prewarmHit {\n"
            "                    if admittedHoldPosterURL != nil, holdVisible {\n"
            "                        holdLoadingOverlay", sheet
        )
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


    def test_redirect_policy_pins_every_hop_to_original_native_origin(self):
        source = SOURCE.read_text(encoding="utf-8")
        policy = source.split("enum PlayerPosterRedirectHopPolicy {", 1)[1].split(
            "// MARK: - Quality (performance control)", 1
        )[0]
        for required in (
            "static let maximumRedirects = 3",
            "(0..<maximumRedirects).contains(alreadyFollowed)",
            "admittedUnambiguousURL(original, backendOrigin: backendOrigin)",
            "admittedUnambiguousURL(previous, backendOrigin: backendOrigin)",
            "admittedUnambiguousURL(proposed, backendOrigin: backendOrigin)",
            "let pinnedOrigin = originKey(start)",
            "originKey(prior) == pinnedOrigin",
            "originKey(next) == pinnedOrigin",
            "components.percentEncodedHost",
            "PlayerHoldPosterURLPolicy.admittedURL(",
            "(1...65_535).contains(port)",
        ):
            self.assertIn(required, policy)
        # This policy must stay independent of transport and readiness.
        # Actual delegate wiring and cancellation are separately scoped.
        for forbidden in ("URLSession.shared", "evaluateJavaScript", "WKWebView(", "firstSceneRenderSubmit"):
            self.assertNotIn(forbidden, policy)


    def test_future_response_budget_matches_generator_preview_and_has_no_decode(self):
        source = SOURCE.read_text(encoding="utf-8")
        policy = source.split("struct PlayerHoldPosterResponseBudget {", 1)[1].split(
            "// MARK: - Quality (performance control)", 1
        )[0]
        for required in (
            "maximumBytes = 2 * 1024 * 1024",
            "maximumDimension = 4096",
            "maximumPixels = 16_777_216",
            "statusCode == 200",
            "byteCount <= limit - receivedBytes",
            "rejected = true",
            "receivedBytes == declaredLength",
            "mutating func finish(transportSucceeded: Bool)",
            "guard !rejected, !finished, transportSucceeded, receivedBytes > 0",
            "finished && !rejected",
            "guard complete, data.count == receivedBytes",
            "CGImageSourceGetCount(source) == 1",
            "CGImageSourceCopyPropertiesAtIndex",
            "kCGImageSourceShouldCache: false",
            "width <= maximumPixels / height",
        ):
            self.assertIn(required, policy)
        for forbidden in ("CGImageSourceCreateImageAtIndex", "UIImage(data:", "URLSession.shared", "evaluateJavaScript"):
            self.assertNotIn(forbidden, policy)


if __name__ == "__main__":
    unittest.main()
