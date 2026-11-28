"""Regression guard for production WKWebView deferred telemetry lease admission.

#750 retains the #677 start-time authority, but sends through a bounded,
Coordinator-owned metric task registry. The source assertions must check
current actual task ownership, not the historical untracked Task spelling.
"""
from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[2] / "Hephaestus" / "Player" / "PixiPlayer.swift"


class NativeMetricDispatchLeaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text(encoding="utf-8")
        cls.start = cls.source.index("case .firstInput(let ms):")
        cls.end = cls.source.index("private func sameOrigin(", cls.start)
        cls.metric_switch = cls.source[cls.start:cls.end]

    def test_both_real_social_writes_check_native_lease_and_session_at_task_start(self):
        body = self.metric_switch
        for kind in ("player_first_input", "player_perf_window"):
            self.assertEqual(body.count('kind: "' + kind + '"'), 1)
        # One synchronous-UI callback; two separately owned, bounded sends.
        self.assertEqual(body.count("Task { @MainActor [weak self] in"), 1)
        self.assertEqual(body.count("registry.submit { [weak self, weak registry]"), 2)
        self.assertEqual(
            body.count("Task { @MainActor [weak self, weak registry] in"), 2
        )
        self.assertEqual(
            body.count("defer { registry?.complete(taskID: taskID, epoch: epoch) }"), 2
        )
        self.assertEqual(body.count("PlayerRuntimeMetricDispatchPolicy.mayStart("), 2)
        self.assertEqual(body.count("await BackendAPI.shared.trackSocialEvent("), 2)
        self.assertEqual(body.count("self.ownsCurrentMetricAttachment"), 2)
        self.assertEqual(body.count("self.launchLifecycle.permitsRuntimeEvents"), 2)
        self.assertEqual(body.count("currentSessionID: self.runtimeSessionID"), 2)
        self.assertEqual(body.count("taskCancelled: Task<Never, Never>.isCancelled"), 2)
        self.assertNotIn("Task { await BackendAPI.shared.trackSocialEvent(", body)
        self.assertNotIn('gameID: expectedGameID, kind: "player_', body)

    def test_pure_policy_requires_all_current_native_facts(self):
        src = self.source
        # Stop at the policy's own closing brace, not at the later metric
        # sequence gate: the new independent task owner is now in between.
        section = src.split("enum PlayerRuntimeMetricDispatchPolicy {", 1)[1].split(
            "\n}\n", 1
        )[0]
        for snippet in (
            "ownsCurrentAttachment && permitsRuntimeEvents && !taskCancelled",
            "PlayerNativeRuntimeIdentifierPolicy.validSessionID(expectedSessionID)",
            "currentSessionID == expectedSessionID",
        ):
            self.assertIn(snippet, section)
        self.assertNotIn("URLSession", section)
        self.assertNotIn("URLRequest(", section)
        self.assertNotIn("trackSocialEvent(", section)

    def test_no_unscoped_social_send_before_first_real_backend_call(self):
        body = self.metric_switch
        cases = (
            body.split("case .firstInput(let ms):", 1)[1].split("case .perfWindow(", 1)[0],
            body.split("case .perfWindow(", 1)[1],
        )
        for kind, case in zip(("player_first_input", "player_perf_window"), cases):
            task = case.index("registry.submit { [weak self, weak registry]")
            guard = case.index("guard let self, PlayerRuntimeMetricDispatchPolicy.mayStart(")
            call = case.index('kind: "' + kind + '"')
            complete = case.index("defer { registry?.complete(taskID: taskID, epoch: epoch) }")
            self.assertLess(task, complete)
            self.assertLess(complete, guard)
            self.assertLess(guard, call)
            self.assertIn("guard let validGameID, !Task<Never, Never>.isCancelled", case)
            self.assertIn("gameID: validGameID", case)
            self.assertNotIn("Task.detached", case)


if __name__ == "__main__":
    unittest.main()
