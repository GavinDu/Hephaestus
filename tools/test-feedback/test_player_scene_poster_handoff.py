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
        self.assertIn("noSceneTimeoutMilliseconds: Int64 = 12_000", guard)

    def test_bounded_real_swiftui_timer_and_true_error_are_preserved(self):
        src = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        timer = src.split('.task(id: "\\(attempt):\\(isLoading)") {', 1)[1].split(
            ".task(id: attempt)", 1
        )[0]
        self.assertIn("let watchdogAttempt = attempt", timer)
        self.assertIn("try? await Task.sleep", timer)
        self.assertIn("guard !Task.isCancelled", timer)
        self.assertIn("watchdogAttempt == attempt", timer)
        self.assertIn("PlayerScenePosterHandoffPolicy.shouldOfferNoSceneRecovery", timer)
        self.assertIn("loadFailureCategory = .network", timer)
        self.assertIn(
            'loadError = "The game has not drawn its first scene. Tap Retry or return to the feed."',
            timer
        )
        self.assertNotIn("firstGPUFrame", timer)
        self.assertNotIn("PlayerLaunchCoordinator(", timer)

if __name__ == "__main__":
    unittest.main()
