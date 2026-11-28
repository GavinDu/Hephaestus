"""Production source guard for fixed, nonce-owned first-scene diagnostics."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Hephaestus/Player/PixiPlayer.swift"

class FirstSceneTraceTests(unittest.TestCase):
    def test_trace_uses_native_owner_and_fixed_labels(self):
        src = SOURCE.read_text()
        trace = src.split("struct PlayerFirstSceneTrace {", 1)[1].split(
            "/// Compatibility façade", 1)[0]
        self.assertIn("nativeNonce == documentNonce", trace)
        self.assertIn("observed.insert(stage).inserted", trace)
        self.assertIn('"player first-scene trace: " + stage.rawValue', trace)
        self.assertIn("firstSceneTrace.prepare(nativeNonce: nonce)", src)
        self.assertEqual(src.count("documentEpochGate.invalidate()"), src.count(
            "documentEpochGate.invalidate()\n        firstSceneTrace.invalidate()"))
        emitter = src.split("private static func emitFirstSceneTrace(", 1)[1].split(
            "static func acceptsCurrentDocumentNonce", 1)[0]
        for marker in ("nonce == documentEpochGate.currentNonce",
                       "sessionFingerprint == credentialFingerprint()",
                       "ownsActiveAttachment(webView, lease: lease)",
                       "documentEpochGate.acceptsV2(nativeNonce)"):
            self.assertIn(marker, emitter)
        self.assertNotIn("PlayerTelemetry", emitter)
        self.assertIn("traceAttachedScene(.sheetCallbackInvoked, nonce: traceNonce)", src)
        self.assertIn("message.webView === view", src)
        self.assertIn("traceAttachedScene(.navigationFinished, nonce: traceNonce)", src)
        self.assertIn("traceAttachedScene(.metricAdmissionRejected, nonce: traceNonce)", src)
        self.assertLess(src.index("traceAttachedScene(.attachedBridgeAccepted, nonce: traceNonce)"),
                        src.index("handleMetric(body, runtimeSessionID: runtimeSessionID)"))
        self.assertIn("emitFirstSceneTrace(captured ? .speculativeAccepted : .speculativeRejected", src)

if __name__ == "__main__":
    unittest.main()
