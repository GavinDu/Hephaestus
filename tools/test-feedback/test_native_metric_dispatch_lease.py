"""Regression guard for production WKWebView deferred telemetry lease admission."""
from pathlib import Path
import re
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
        self.assertEqual(body.count("Task { @MainActor [weak self] in"), 3,
                         "one UI callback and two guarded backend writes")
        self.assertEqual(body.count("PlayerRuntimeMetricDispatchPolicy.mayStart("), 2)
        self.assertEqual(body.count("await BackendAPI.shared.trackSocialEvent("), 2)
        self.assertEqual(body.count("self.ownsLiveAttachment"), 2)
        self.assertEqual(body.count("self.launchLifecycle.permitsRuntimeEvents"), 2)
        self.assertEqual(body.count("currentSessionID: self.runtimeSessionID"), 2)
        self.assertEqual(body.count("Task<Never, Never>.isCancelled"), 2)
        self.assertNotIn("Task { await BackendAPI.shared.trackSocialEvent(", body)
        self.assertNotIn("gameID: expectedGameID, kind: \"player_", body)

    def test_pure_policy_requires_all_current_native_facts(self):
        src = self.source
        section = src.split("enum PlayerRuntimeMetricDispatchPolicy {", 1)[1].split(
            "/// Accept only trusted runtime metric kinds", 1)[0]
        for snippet in (
            "ownsCurrentAttachment && permitsRuntimeEvents && !taskCancelled",
            "PlayerNativeRuntimeIdentifierPolicy.validSessionID(expectedSessionID)",
            "currentSessionID == expectedSessionID",
        ):
            self.assertIn(snippet, section)
        self.assertNotIn("URLSession", section)
        self.assertNotIn("score", section.lower())

    def test_no_unscoped_social_send_before_first_real_backend_call(self):
        body = self.metric_switch
        for kind in ("player_first_input", "player_perf_window"):
            call = body.index('kind: "' + kind + '"')
            guard = body.rfind("guard let self, PlayerRuntimeMetricDispatchPolicy.mayStart(", 0, call)
            task = body.rfind("Task { @MainActor [weak self] in", 0, call)
            self.assertGreaterEqual(guard, task)
            self.assertGreater(task, 0)
            self.assertLess(call - task, 1000)


if __name__ == "__main__":
    unittest.main()
