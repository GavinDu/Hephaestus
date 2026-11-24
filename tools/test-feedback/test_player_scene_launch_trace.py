"""#805 fixed native scene observations: production source wiring, not live proof."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class SceneLaunchTraceContract(unittest.TestCase):
    def test_trace_is_owned_and_timeout_precedes_dismantle(self):
        src = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        policy = src.split("struct PlayerSceneLaunchTrace {", 1)[1].split("/// Terminal no-scene recovery", 1)[0]
        self.assertIn("self.nonce == nonce, self.lease == lease", policy)
        self.assertIn("!stages.contains(.timeout)", policy)
        self.assertIn("Stage.allCases.filter", policy)
        self.assertIn(".map(\\.rawValue).joined", policy)
        native = src.split("static func timeoutSceneTrace(", 1)[1].split("static func revokeDocumentNonce", 1)[0]
        self.assertIn("current.nonce == handle.nonce", native)
        self.assertIn("sceneTraceHandle(view, lease: handle.lease)", native)
        watchdog = src.split(".task(id: noSceneWatchdogIdentity)", 1)[1].split(".task(id: attempt)", 1)[0]
        self.assertLess(watchdog.index("timeoutSceneTrace(traceHandle)"), watchdog.index("terminalNoSceneAttempt = watchdogAttempt"))
        self.assertIn("owner.epoch == watchdogAttempt", watchdog)
        self.assertIn("unattributed_timeout", watchdog)

    def test_real_router_and_coordinator_observe_existing_gates(self):
        src = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        prewarm = src.split("private static func collectPrewarmMetric", 1)[1].split("private final class PoolMetricRouter", 1)[0]
        self.assertIn("documentEpochGate.acceptsV2", prewarm)
        self.assertIn("diagnosticAccepted = PlayerPrewarmSceneLedgerCapturePolicy.capture(", prewarm)
        self.assertIn(".prewarmRejected", prewarm)
        coordinator = src.split("let diagnosticHandle: PlayerSceneLaunchTrace.Handle?", 1)[1]
        self.assertIn("message.webView === view", coordinator)
        self.assertIn('body["documentNonce"] as? String == handle.nonce', coordinator)
        self.assertLess(coordinator.index("nativeBridgeVersionGate.didAccept(schema)"), coordinator.index("recordSceneTrace(.bridgeAdmitted"))
        self.assertLess(coordinator.index("recordSceneTrace(.deliveryInvoked"), coordinator.index("self.onFirstSceneRenderSubmit(milliseconds)"))
        smoke = (ROOT / "HephaestusUITests/PlayerSmokeTests.swift").read_text()
        self.assertIn('app.launchArguments.append("--ui-test-scene-trace")', smoke)
        self.assertIn("safePlayerSmokeSceneTrace(errorText.value as? String)", smoke)
        self.assertIn("XCTAssertFalse(failed.exists,", smoke)
        self.assertIn("XCTAssertFalse(loading.exists,", smoke)

if __name__ == "__main__":
    unittest.main()
