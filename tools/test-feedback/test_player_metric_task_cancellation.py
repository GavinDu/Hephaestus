"""No detached native metric POST may survive WebKit owner revocation (#750)."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
PLAYER = ROOT / "Hephaestus/Player/PixiPlayer.swift"
BACKEND = ROOT / "Hephaestus/Backend/BackendAPI.swift"

class PlayerNativeMetricTaskSourceTest(unittest.TestCase):
    def test_task_registry_is_bounded_and_cancelled_at_four_real_host_paths(self):
        src = PLAYER.read_text()
        registry = src.split("final class PlayerNativeMetricTaskRegistry {", 1)[1].split(
            "/// Accept only trusted runtime metric kinds", 1
        )[0]
        self.assertIn("static let maximumInFlight = 2", registry)
        self.assertIn("tasks.count < Self.maximumInFlight", registry)
        self.assertIn("taskEpoch == epoch", registry)
        self.assertIn("task.cancel()", registry)
        self.assertIn("tasks.removeAll(keepingCapacity: false)", registry)

        coordinator = src.split("class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {", 1)[1]
        coordinator = coordinator.split("\n    }\n}", 1)[0]
        self.assertEqual(coordinator.count("registry.submit {"), 2)
        self.assertEqual(coordinator.count("metricTelemetryTasks.revoke()"), 4)
        for method, tail in (
            ("func stopObserving()", "launchLifecycle.detach()"),
            ("didStartProvisionalNavigation navigation: WKNavigation!", "PlayerWebViewPool.didStartDocumentNavigation(webView)"),
            ("private func reportNavigationFailure(_ error: Error)", "disarmPrewarmRecovery()"),
            ("func webViewWebContentProcessDidTerminate(_ webView: WKWebView)", "disarmPrewarmRecovery()"),
        ):
            relevant = coordinator.split(method, 1)[1].split(tail, 1)[0]
            self.assertIn("metricTelemetryTasks.revoke()", relevant, method)
        self.assertIn("defer { registry?.complete(taskID: taskID, epoch: epoch) }", coordinator)
        self.assertEqual(coordinator.count("PlayerRuntimeMetricDispatchPolicy.mayStart("), 2)

    def test_pool_retires_metric_owner_before_lease_or_credential_mutation(self):
        src = PLAYER.read_text()
        pool = src.split("enum PlayerWebViewPool {", 1)[1]
        for method, mutation in (
            ("static func take(url:", "attachmentLease &+= 1"),
            ("static func recycle(", "isAttached = false"),
            ("static func invalidateForSessionChange()", "pooledView = nil"),
        ):
            relevant = pool.split(method, 1)[1].split(mutation, 1)[0]
            self.assertIn("metricAttachment.retire()", relevant, method)
        attach = pool.split("static func attachMessageReceiver(", 1)[1].split(
            "attachedMessageReceiver = receiver", 1)[0]
        self.assertLess(attach.index("ownsAttachedNavigation("),
                        attach.index("metricAttachment.bind(metricRegistry)"))
        owns = pool.split("static func ownsCurrentMetricAttachment(", 1)[1].split(
            "static func recycle(", 1)[0]
        self.assertLess(owns.index("ensureCurrentCredentialScope()"),
                        owns.index("return ownsActiveAttachment("))
        self.assertEqual(src.count("ownsCurrentAttachment: self.ownsCurrentMetricAttachment,"), 2)
        self.assertIn("metricRegistry: context.coordinator.metricTelemetryTasks", src)
        self.assertIn("private weak var registry: PlayerNativeMetricTaskRegistry?", src)

    def test_backend_aborts_cooperative_cancel_before_post(self):
        src = BACKEND.read_text()
        method = src.split("func trackSocialEvent(gameID: String", 1)[1].split(
            "func fetchCreatorProfile(", 1
        )[0]
        self.assertEqual(method.count("Task<Never, Never>.isCancelled"), 2)
        self.assertIn("await session.data(for: req)", method)
        self.assertNotIn("Task.detached", method)

if __name__ == "__main__":
    unittest.main()
