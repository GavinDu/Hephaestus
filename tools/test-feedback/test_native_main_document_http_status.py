"""#691: actual prewarm AND attached player main-frame response gate."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
PLAYER = ROOT / "Hephaestus/Player/PixiPlayer.swift"

class NativeMainDocumentHTTPResponseGateTests(unittest.TestCase):
    def test_both_actual_delegate_sites_use_one_final_http_policy(self):
        src = PLAYER.read_text()
        self.assertIn("enum PlayerMainDocumentHTTPPolicy {", src)
        policy = src.split("enum PlayerMainDocumentHTTPPolicy {", 1)[1].split("enum PlayerPrewarmResponsePolicy", 1)[0]
        self.assertIn("(200...299).contains(statusCode) || statusCode == 304", policy)
        self.assertNotIn("statusCode < 400", policy)
        self.assertEqual(src.count("PlayerMainDocumentHTTPPolicy.permitsMainDocument("), 3)
        warmup = src.split("private final class WarmupDelegate:", 1)[1].split("/// Keeps gameplay portrait-shaped", 1)[0]
        self.assertIn("navigationResponse.isForMainFrame else", warmup)
        self.assertIn("navigationResponse.response as? HTTPURLResponse,", warmup)
        self.assertIn("PlayerMainDocumentHTTPPolicy.permitsMainDocument(", warmup)
        self.assertIn("PlayerWebViewPool.markFailed(", warmup)
        attached = src.split("final class Coordinator: NSObject", 1)[1]
        self.assertIn("navigationResponse.isForMainFrame else", attached)
        self.assertIn("navigationResponse.response as? HTTPURLResponse else", attached)
        self.assertIn("PlayerMainDocumentHTTPPolicy.permitsMainDocument(", attached)
        self.assertIn("reportNavigationFailure(PlayerLoadFailure.httpError(statusCode: 0))", attached)
        self.assertNotIn("response.statusCode >= 400 else", attached)

    def test_no_untrusted_location_or_browser_cred_leak_added(self):
        src = PLAYER.read_text()
        section = src.split("private final class WarmupDelegate:", 1)[1].split("/// Keeps gameplay portrait-shaped", 1)[0]
        self.assertNotIn('response.value(forHTTPHeaderField: "Location")', section)
        self.assertIn("decisionHandler(.cancel)", section)

if __name__ == "__main__":
    unittest.main()
