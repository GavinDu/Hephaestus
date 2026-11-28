"""Source wiring for independent bounded native poster transport #827."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Hephaestus/Player/PlayerBoundedHoldPosterTransport.swift"

class BoundedPosterTransportTests(unittest.TestCase):
    def test_transport_is_ephemeral_bounded_and_fail_closed(self):
        src = SOURCE.read_text()
        for marker in (
            "PlayerPosterRedirectHopPolicy.admittedHop(",
            "willPerformHTTPRedirection",
            "from == currentURL",
            'proposed.httpMethod == "GET"',
            "return Self.request(for: accepted)",
            "redirects.acceptsTerminalURL(response.url)",
            "URLSessionConfiguration.ephemeral",
            "configuration.httpCookieStorage = nil",
            "configuration.urlCredentialStorage = nil",
            "configuration.urlCache = nil",
            "session.invalidateAndCancel()",
            "session.bytes(",
            "delegate: redirects",
            "budget.admitChunk(byteCount: 1)",
            "budget.finish(transportSucceeded: transportSucceeded)",
            "budget.admitsEncodedHeader(data)",
            "transfer.finish(transportSucceeded: true)",
            "!Task.isCancelled",
        ):
            self.assertIn(marker, src)
        self.assertLess(src.index("budget.admitChunk(byteCount: 1)"), src.index("data.append(byte)"))
        self.assertLess(src.index("budget.finish(transportSucceeded: transportSucceeded)"), src.index("budget.admitsEncodedHeader(data)"))
        for forbidden in ("URLSession.shared", "UIImage(data:", "evaluateJavaScript", "DevLog.", "data(for:"):
            self.assertNotIn(forbidden, src)

if __name__ == "__main__":
    unittest.main()
