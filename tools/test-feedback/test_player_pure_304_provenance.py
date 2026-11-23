"""#758 staged pure cache-provenance contract; no premature 304 shipping claim."""
from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[2] / "Hephaestus/Player/PixiPlayer.swift"

class PurePlayerRevalidationContractTests(unittest.TestCase):
    def test_pure_304_receipt_is_native_scoped_and_default_wiring_unchanged(self):
        src = SOURCE.read_text(encoding="utf-8")
        shipping = src.split("enum PlayerPrewarmResponsePolicy {", 1)[1].split(
            "/// Pure, native-owned cache provenance contract", 1
        )[0]
        # No misleading claim that unconnected helper already enforces 304.
        self.assertIn("static func shouldCacheResponse(statusCode: Int)", shipping)
        self.assertIn("statusCode < 400", shipping)
        self.assertNotIn("PlayerAuthorizedDocumentRevalidationPolicy", shipping)

        pure = src.split("enum PlayerAuthorizedDocumentRevalidationPolicy {", 1)[1].split(
            "/// A single failed main-frame navigation", 1
        )[0]
        self.assertIn("struct Authorized200Receipt: Equatable", pure)
        self.assertIn("static func authorized200(", pure)
        self.assertIn("static func admits304(", pure)
        self.assertIn("guard statusCode == 200", pure)
        self.assertIn("guard statusCode == 304", pure)
        for owner in (
            "credentialEpoch", "attachmentLease", "nativeDocumentNonce",
            "expectedPlayerURL", "backendOrigin", "isTrustedMainFrame",
            "hasAuthorizedCachedRepresentation", "ownsCurrentAttachment",
        ):
            self.assertIn(owner, pure)
        self.assertIn("receipt.immutablePlayerURL == expectedPlayerURL", pure)
        self.assertIn("receipt.nativeDocumentNonce == nativeDocumentNonce", pure)
        self.assertIn("receipt.attachmentLease == attachmentLease", pure)
        self.assertIn("receipt.credentialEpoch == credentialEpoch", pure)
        self.assertNotIn("Array(value.utf8)", pure)
        for forbidden in ("WKWebView(", "URLSession(", "DevLog.", "evaluateJavaScript", "PlayerTelemetry.report"):
            self.assertNotIn(forbidden, pure)

if __name__ == "__main__":
    unittest.main()
