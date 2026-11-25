"""DEBUG-only #805 document witness remains disjoint from game readiness."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DebugDocumentWitnessTests(unittest.TestCase):
    def test_injection_and_routing_are_opt_in_and_diagnostic_only(self):
        src = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        prepare = src.split("static func prepareDocumentNavigation(", 1)[1].split("static func didStartDocumentNavigation(", 1)[0]
        self.assertIn("#if DEBUG", prepare)
        self.assertIn('--ui-test-scene-trace', prepare)
        self.assertIn("type: 'debug_document_witness'", prepare)
        self.assertIn("injectionTime: .atDocumentStart", prepare)
        self.assertNotIn("first_scene_render_submit", prepare)
        self.assertNotIn("event.message", prepare)
        self.assertNotIn("event.reason", prepare)
        helper = src.split("private static func consumeDebugDocumentWitness(", 1)[1].split("#endif", 1)[0]
        for proof in ("documentEpochGate.acceptsV2(nonce)", "message.frameInfo.isMainFrame",
                      "message.frameInfo.request.url == url", "PlayerWebKitOriginPolicy.matches",
                      "sessionFingerprint == credentialFingerprint()", "sceneLaunchTrace.record(stage"):
            self.assertIn(proof, helper)
        for forbidden in ("onFirstScene", "nativeBridgeVersionGate", "PlayerTelemetry",
                          "sceneMilestoneLedger", "DevLog"):
            self.assertNotIn(forbidden, helper)
        route = src.split("private static func routeWebKitMessage(", 1)[1].split("private static func collectPrewarmMetric(", 1)[0]
        self.assertEqual(route.count("if consumeDebugDocumentWitness("), 2)
        self.assertEqual(route.count("#if DEBUG"), 2)
        self.assertLess(route.index("consumeDebugDocumentWitness("), route.index("collectPrewarmMetric(message)"))


if __name__ == "__main__":
    unittest.main()
