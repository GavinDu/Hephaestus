"""#765: production iPhone/iPad poster only releases after admitted scene."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class CurrentScenePosterSourceContract(unittest.TestCase):
    def test_navigation_finish_never_directly_fades_the_real_poster(self):
        src = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        nav = src.split("private func handleLoadFinish()", 1)[1].split(
            "private func fadeHoldPosterAfterCurrentScene()", 1
        )[0]
        self.assertIn("TapToNavReady", nav)
        self.assertIn("fadeHoldPosterAfterCurrentScene()", nav)
        self.assertNotIn("holdOpacity = 0", nav)
        self.assertNotIn("holdVisible = false", nav)
        self.assertNotIn("withAnimation(", nav)

    def test_scene_witness_is_real_current_coordinator_callback(self):
        src = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        callback = src.split("onFirstSceneRenderSubmit: { ms in", 1)[1].split(
            "onFirstInput:", 1
        )[0]
        self.assertIn("PlayerLaunchCallbackGate.accepts", callback)
        self.assertIn("firstSceneSubmittedForAttempt = (", callback)
        self.assertIn("fadeHoldPosterAfterCurrentScene()", callback)
        guard = src.split("enum PlayerScenePosterHandoffPolicy {", 1)[1].split(
            "/// First scene submission", 1
        )[0]
        self.assertIn("acceptedSceneAttempt == expectedAttempt", guard)
        self.assertIn("navigationFinished && !hasLoadError", guard)
        self.assertIn("!hasLoadError && !sessionRevoked", guard)
        policy = src.split("enum PlayerFirstSceneWaitPolicy {", 1)[1].split(
            "/// Terminal no-scene recovery", 1
        )[0]
        self.assertIn("noSceneTimeoutMilliseconds: Int64 = 12_000", policy)
        self.assertIn("terminalAttempt != currentAttempt", policy)
        self.assertIn("navigationFinished && acceptedSceneAttempt == currentAttempt", policy)
        self.assertNotIn("hasHoldPoster", policy)
        self.assertNotIn("holdVisible", policy)

    def test_bounded_real_swiftui_timer_and_true_error_are_preserved(self):
        src = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        self.assertIn(".task(id: noSceneWatchdogIdentity) {", src)
        identity = src.split("private var noSceneWatchdogIdentity: String {", 1)[1].split("private var playerURL", 1)[0]
        for key in ("attempt", "isLoading", "scenePhase", "firstSceneSubmittedForAttempt?.epoch", "sessionRevoked", "loadError != nil", "terminalNoSceneAttempt", "playerURL != nil"):
            self.assertIn(key, identity)
        timer = src.split('.task(id: noSceneWatchdogIdentity) {', 1)[1].split(
            ".task(id: attempt)", 1
        )[0]
        self.assertIn("let watchdogAttempt = attempt", timer)
        self.assertIn("try? await Task.sleep", timer)
        self.assertIn("guard !Task.isCancelled", timer)
        self.assertIn("watchdogAttempt == attempt", timer)
        self.assertIn("scenePhase == .active", timer)
        self.assertIn("isForeground: scenePhase == .active", timer)
        self.assertEqual(timer.count("PlayerFirstSceneWaitPolicy.shouldOfferNoSceneRecovery"), 2)
        self.assertNotIn("admittedHoldPosterURL", timer)
        self.assertNotIn("holdVisible else", timer)
        self.assertIn("terminalNoSceneAttempt = watchdogAttempt", timer)
        self.assertIn("loadFailureCategory = .unknown", timer)
        self.assertNotIn("loadFailureCategory = .network", timer)
        self.assertIn(
            'loadError = "The game has not drawn its first scene. Tap Retry or return to the feed."',
            timer
        )
        self.assertNotIn("firstGPUFrame", timer)
        self.assertNotIn("PlayerLaunchCoordinator(", timer)

    def test_missing_or_rejected_poster_still_has_native_holding_surface(self):
        src = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        sheet = src.split("struct PixiPlayerSheet: View {", 1)[1]
        readiness = sheet.split("private var firstSceneReadiness:", 1)[1].split(
            "private var noSceneWatchdogIdentity", 1
        )[0]
        for proof in ("currentAttempt: attempt", "acceptedSceneAttempt: firstSceneSubmittedForAttempt?.epoch",
                      "terminalAttempt: terminalNoSceneAttempt", "hasValidPlayerRequest: playerURL != nil",
                      "navigationFinished: !isLoading", "hasLoadError: loadError != nil",
                      "sessionRevoked: sessionRevoked"):
            self.assertIn(proof, readiness)
        self.assertNotIn("holdVisible", readiness)
        self.assertIn(".allowsHitTesting(firstSceneReadiness == .ready)", sheet)
        self.assertIn(".accessibilityHidden(firstSceneReadiness != .ready)", sheet)
        fallback = sheet.split("if firstSceneReadiness == .waiting,", 1)[1].split(
            "if PlayerLoadingPolicy.shouldShowOfflineOverlay", 1
        )[0]
        for proof in ("admittedHoldPosterURL == nil || !holdVisible", "PlayerStateCard",
                      "ProgressView()", "player.loading", "Preparing"):
            self.assertIn(proof, fallback)

if __name__ == "__main__":
    unittest.main()
