"""Check the actual native initial Play fallback, not a fabricated scene."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CompletedPrewarmReuseSourceTests(unittest.TestCase):
    def test_completed_unproven_scene_uses_fresh_webview_before_load(self):
        source = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        take = source.split("static func take(url: URL)", 1)[1].split(
            "static func ownsAttachedNavigation(", 1)[0]
        for proof in ("completedSpeculativeNavigation",
                      "PlayerCompletedPrewarmReusePolicy.permitsWarmHit(",
                      "sceneMilestoneLedger.candidate",
                      "currentNonce: documentEpochGate.currentNonce",
                      "credentialFingerprint: sessionFingerprint",
                      "hasTransferred: sceneMilestoneLedger.hasTransferred",
                      "if completedSpeculativeNavigation && !didFinish && !isAttached",
                      "retired.navigationDelegate = nil",
                      "retired.stopLoading()",
                      "currentURL = nil", "loadedURL = nil",
                      "prepareDocumentNavigation(view)"):
            self.assertIn(proof, take)
        self.assertLess(take.index("view = makeWebView()"),
                        take.index("retired.stopLoading()"))
        self.assertLess(take.index("pooledView = view"),
                        take.index("retired.stopLoading()"))
        self.assertIn("let shouldLoad = !didFinish && !alreadyLoading", take)
        mount = source.split("func makeUIView(context: Context) -> WKWebView", 1)[1].split(
            "func updateUIView(", 1)[0]
        self.assertLess(mount.index("PlayerWebViewPool.attachMessageReceiver("),
                        mount.index("webView.load(URLRequest(url: url))"))
        self.assertLess(mount.index("PlayerWebViewPool.offerAttachedPrewarmScene("),
                        mount.index("if handoff.shouldLoad"))
        self.assertNotIn("onFirstSceneRenderSubmit(", mount)

    def test_policy_keeps_identity_and_one_shot_bounds(self):
        source = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        policy = source.split("enum PlayerCompletedPrewarmReusePolicy {", 1)[1].split(
            "/// One live, cryptographically unpredictable", 1)[0]
        for proof in ("isSpeculative, navigationStarted, !hasTransferred",
                      "candidate.identity.isValid",
                      "candidate.identity.playerURL == expectedURL",
                      "candidate.identity.documentNonce == currentNonce",
                      "candidate.identity.credentialFingerprint == credentialFingerprint",
                      "(0...100_000).contains(candidate.sequence)",
                      "(0...3_600_000).contains(candidate.milliseconds)"):
            self.assertIn(proof, policy)


if __name__ == "__main__":
    unittest.main()
