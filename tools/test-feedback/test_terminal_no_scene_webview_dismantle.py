"""#770 production no-scene WebView unmount uses current lease teardown."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
PLAYER = ROOT / "Hephaestus/Player/PixiPlayer.swift"

class TerminalNoSceneMountedViewContract(unittest.TestCase):
    def test_real_sheet_unmounts_only_terminal_attempt(self):
        src = PLAYER.read_text()
        self.assertIn("enum PlayerTerminalNoSceneMountPolicy {", src)
        self.assertIn("terminalNoSceneAttempt = watchdogAttempt", src)
        self.assertIn("PlayerTerminalNoSceneMountPolicy.shouldMount(", src)
        self.assertIn("currentAttempt: attempt, terminalNoSceneAttempt: terminalNoSceneAttempt", src)
        self.assertIn("let url = playerURL {\n                    PlayerWebView(", src)
        # Every installed sheet callback must reject a timed-out epoch before
        # mutation, including late termination (which can otherwise auto-reload).
        callback_block = src.split("private var playerContent: some View {", 1)[1].split(
            ".id(attempt)", 1
        )[0]
        for callback in ("onProgress", "onLoadFinish", "onLoadFail", "onTerminate",
                         "onPrewarmHit", "onFirstSceneRenderSubmit", "onFirstInput",
                         "onVerifiedRun"):
            with self.subTest(callback=callback):
                closure = callback_block.split(callback + ": {", 1)[1]
                self.assertIn("guard terminalNoSceneAttempt != callbackEpoch,", closure.split("else { return }", 1)[0])
                self.assertIn("PlayerLaunchCallbackGate.accepts(", closure.split("else { return }", 1)[0])
        self.assertEqual(callback_block.count("guard terminalNoSceneAttempt != callbackEpoch,"), 8)
        self.assertIn("loadFailureCategory = .unknown", src)

    def test_real_dismantle_uses_old_coordinator_lease_not_new_sheet(self):
        src = PLAYER.read_text()
        dismantle = src.split("static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator)", 1)[1].split("final class Coordinator", 1)[0]
        self.assertIn("coordinator.stopObserving()", dismantle)
        self.assertIn("PlayerWebViewPool.ownsActiveAttachment(", dismantle)
        self.assertIn("lease: coordinator.attachmentLease", dismantle)
        self.assertIn("PlayerWebViewPool.recycle(webView, lease: coordinator.attachmentLease)", dismantle)
        recycle = src.split("static func recycle(_ webView: WKWebView, lease: UInt64)", 1)[1].split("private static func credentialFingerprint()", 1)[0]
        for fragment in ("guard ownsActiveAttachment(webView, lease: lease)", "attachedMessageReceiver = nil",
                         "documentEpochGate.invalidate()", "webView.stopLoading()", 'webView.loadHTMLString("", baseURL: nil)'):
            self.assertIn(fragment, recycle)

if __name__ == "__main__":
    unittest.main()
