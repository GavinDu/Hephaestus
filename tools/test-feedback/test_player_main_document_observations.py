"""Production native 200/304 observations are bounded, private and non-authoritative."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PlayerMainDocumentObservationsSourceTests(unittest.TestCase):
    def test_both_real_main_document_delegates_record_only_after_admission(self):
        source = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        delegates = source.split("decidePolicyFor navigationResponse: WKNavigationResponse,")[1:]
        self.assertEqual(len(delegates), 2)
        for delegate, lease in zip(delegates, ("nil", "attachmentLease")):
            delegate = delegate.split("func webView(_ webView: WKWebView, didFinish", 1)[0]
            self.assertLess(delegate.index("guard navigationResponse.isForMainFrame"),
                            delegate.index("PlayerMainDocumentHTTPPolicy.permitsMainDocument"))
            self.assertLess(delegate.index("PlayerMainDocumentHTTPPolicy.permitsMainDocument"),
                            delegate.index("PlayerWebViewPool.observeMainDocumentResponse("))
            self.assertIn(f"webView, response: response, lease: {lease}", delegate)
            self.assertIn("decisionHandler(.allow)", delegate.split(
                "PlayerWebViewPool.observeMainDocumentResponse(", 1)[1])

    def test_current_pool_context_and_fixed_log_payload(self):
        source = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        method = source.split("static func observeMainDocumentResponse(", 1)[1].split(
            "static func revokeDocumentNonce(", 1)[0]
        for proof in ("pooledView === webView", "response.url == currentURL",
                      "documentEpochGate.navigationStarted", "documentEpochGate.currentNonce != nil",
                      "ownsActiveAttachment(webView, lease: lease)", "guard !isAttached",
                      "statusCode: response.statusCode, isAttached: lease != nil",
                      "DevLog.info(.player, message)"):
            self.assertIn(proof, method)
        for forbidden in ("allHeaderFields", "value(forHTTPHeaderField", "absoluteString",
                          "PlayerTelemetry", "Authorized200Receipt"):
            self.assertNotIn(forbidden, method)
        prepare = source.split("static func prepareDocumentNavigation(", 1)[1].split(
            "static func didStartDocumentNavigation(", 1)[0]
        self.assertIn("mainDocumentResponseObservations.reset()", prepare)
        policy = source.split("struct PlayerMainDocumentResponseObservations {", 1)[1].split(
            "/// Compatibility façade", 1)[0]
        self.assertIn("observed.insert(kind).inserted", policy)
        self.assertEqual(policy.count('return "player HTTP observation:'), 4)
        self.assertNotIn("response.url", policy)
        self.assertNotIn("PlayerAuthorizedDocumentRevalidationPolicy", policy)


if __name__ == "__main__":
    unittest.main()
