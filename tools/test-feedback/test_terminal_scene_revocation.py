"""#770 source candidate: synchronous current-owner retirement, not measured hardware cleanup."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class TerminalSceneRevocationSourceTests(unittest.TestCase):
    def test_watchdog_freezes_trace_then_retires_before_terminal_state(self):
        src = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        watchdog = src.split(".task(id: noSceneWatchdogIdentity)", 1)[1].split(".task(id: attempt)", 1)[0]
        self.assertLess(watchdog.index("timeoutSceneTrace(traceHandle)"),
                        watchdog.index("retireTerminalSceneAttachment(traceHandle)"))
        self.assertLess(watchdog.index("retireTerminalSceneAttachment(traceHandle)"),
                        watchdog.index("terminalNoSceneAttempt = watchdogAttempt"))
        self.assertIn("owner.epoch == watchdogAttempt", watchdog)
        self.assertIn("loadFailureCategory = .unknown", watchdog)

    def test_exact_nonce_lease_and_stop_consumed_before_retirement(self):
        src = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        retire = src.split("static func retireTerminalSceneAttachment(", 1)[1].split("static func revokeDocumentNonce", 1)[0]
        for proof in ("sceneTraceHandle(view, lease: handle.lease)",
                      "ownsActiveAttachment(view, lease: handle.lease)",
                      "attachedReceiverLease == handle.lease", "let stop = attachedTerminalStop"):
            self.assertIn(proof, retire)
        self.assertLess(retire.index("attachedTerminalStop = nil"), retire.index("stop()"))
        self.assertLess(retire.index("stop()"), retire.index("recycle(view, lease: handle.lease)"))
        self.assertIn("pooledView = nil", retire)
        self.assertIn("terminalStop: { [weak coordinator = context.coordinator]", src)
        self.assertIn("coordinator?.stopObserving()", src)
        self.assertEqual(src.count("attachedReceiverLease = nil"), 4)
        self.assertEqual(src.count("attachedReceiverLease = nil\n        attachedTerminalStop = nil"), 4)
        self.assertNotIn("Task {", retire)

if __name__ == "__main__":
    unittest.main()
