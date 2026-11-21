"""Fail closed if BackendAPI transport DevLog reintroduces raw identifiers."""

from pathlib import Path
import unittest


SOURCE = (
    Path(__file__).resolve().parents[2] / "Hephaestus" / "Backend" / "BackendAPI.swift"
)


class BackendAPIDiagnosticSourceSafetyTests(unittest.TestCase):
    def test_transport_logging_only_uses_typed_redacted_policy(self):
        text = SOURCE.read_text(encoding="utf-8")
        shared_send = text.split("private func send<T: Decodable>", 1)[1].split(
            "// MARK: - Endpoints", 1
        )[0]
        self.assertEqual(
            shared_send.count("BackendAPIDiagnosticPolicy.message("), 4
        )
        for unsafe in (
            "let path = req.url?.path",
            "let method = req.httpMethod ??",
            "error.localizedDescription",
            "DevLog.error(.api, \"\\(method)",
            "DevLog.info(.api, \"\\(method)",
        ):
            self.assertNotIn(unsafe, shared_send)

        # The direct health check is not implemented through send<T>.
        health = text.split("func checkHealth() async", 1)[1].split(
            "func ", 1
        )[0]
        self.assertNotIn("error.localizedDescription", health)
        self.assertIn("BackendAPIDiagnosticPolicy.transportFailure", health)

    def test_formatting_never_interpolates_untrusted_url_or_error(self):
        text = SOURCE.read_text(encoding="utf-8")
        policy = text.split("enum BackendAPIDiagnosticPolicy {", 1)[1].split(
            "/// Thin async client", 1
        )[0]
        self.assertIn("enum Outcome", policy)
        self.assertIn("case decoding", policy)
        self.assertIn("case transport(TransportFailure)", policy)
        self.assertNotIn("localizedDescription", policy)
        self.assertNotIn("absoluteString", policy)
        self.assertNotIn("NSError.domain", policy)
        self.assertNotIn("debugDescription", policy)


if __name__ == "__main__":
    unittest.main()
