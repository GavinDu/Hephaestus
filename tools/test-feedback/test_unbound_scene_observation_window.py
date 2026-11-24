"""#805 independent unbound-window diagnostic, never attributed to the document."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class UnboundSceneObservationSourceTests(unittest.TestCase):
    def test_actual_router_observation_has_scope_and_identity_guards(self):
        src = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        observer = src.split("private static func observeUnboundSceneClaim(", 1)[1].split(
            "private static func routeWebKitMessage(", 1)[0]
        for proof in ("message.webView === view", "pooledView === view",
                      "documentEpochGate.navigationStarted", "view.url == url",
                      "message.frameInfo.isMainFrame", 'body["gameId"] as? String == expectedGameID',
                      "PlayerWebKitOriginPolicy.matches", "unboundSceneWindow.observe("):
            self.assertIn(proof, observer)
        self.assertNotIn("sceneLaunchTrace.record", observer)
        self.assertNotIn("DevLog.", observer)
        self.assertNotIn("PlayerTelemetry", observer)
        router = src.split("private static func routeWebKitMessage(", 1)[1].split(
            "private static func collectPrewarmMetric(", 1)[0]
        self.assertEqual(router.count("observeUnboundSceneClaim(message, view: view)"), 2)
        self.assertIn("credentialScopeCurrent: scopeIsCurrent", router)
        self.assertIn("case .drop:\n            return", router)
        self.assertEqual(src.count("unboundSceneWindow.reset()"), src.count("sceneLaunchTrace.reset()") + 1)

    def test_timeout_exports_separate_fixed_allowlist(self):
        src = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        timeout = src.split("static func timeoutSceneTrace(", 1)[1].split(
            "static func observeMainDocumentResponse(", 1)[0]
        self.assertIn('trace + "|unbound_window=" + unboundSceneWindow.freeze()', timeout)
        smoke = (ROOT / "HephaestusUITests/PlayerSmokeTests.swift").read_text()
        sanitizer = smoke.split("private func safePlayerSmokeSceneTrace(", 1)[1].split(
            "final class PlayerSmokeTests", 1)[0]
        self.assertIn('let prefix = "unbound_window="', sanitizer)
        self.assertIn("labels.allSatisfy({ allowedUnbound.contains($0) })", sanitizer)
        self.assertIn('labels == ["none"]', sanitizer)

if __name__ == "__main__":
    unittest.main()
