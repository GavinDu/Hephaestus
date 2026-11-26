"""#810: fixed redaction and post-failure-only evidence wiring."""
from pathlib import Path
import importlib.util
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
PATH = Path(__file__).with_name("observe-public-package-failure.py")
SPEC = importlib.util.spec_from_file_location("package_failure_observer", PATH)
observer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(observer)


class PackageFailureObserverTests(unittest.TestCase):
    def test_safe_shape_and_redaction(self):
        ready = "LIVE_FIXTURE_ENVELOPE_READY owner_present=true feed_count=3 eligible_count=2 package=v2_shape_only"
        absent = ("LIVE_FIXTURE_NOT_READY attempt=1: feed has owner-linked game(s) but no retrievable matching playable package "
                  "(feed_count=3, eligible_count=3, package_failure_breakdown=invalid_envelope_missing_package_format:3, "
                  "safe_package_keys=gameId|ir|assets:3); fixture #288 not ready")
        self.assertEqual(observer.classify(0, ready + "\n", ""), ready)
        self.assertEqual(observer.classify(1, "", absent + "\n::error private"), absent)
        for bad in (absent.replace("assets", "private_key"), absent + " private",
                    "Traceback: https://private.example", ready.replace("3", "secret")):
            self.assertEqual(observer.classify(1, "", bad), "PUBLIC_PACKAGE_DIAGNOSTIC_UNCLASSIFIED")
        self.assertEqual(observer.classify(0, ready + "\nsecret", ""), "PUBLIC_PACKAGE_DIAGNOSTIC_UNCLASSIFIED")
        self.assertEqual(observer.classify(2, "", absent), "PUBLIC_PACKAGE_DIAGNOSTIC_UNCLASSIFIED")

    def test_one_attempt_wall_deadline_and_no_raw_exception(self):
        with patch.object(observer.subprocess, "run", side_effect=subprocess.TimeoutExpired("private", 40)) as run, patch("builtins.print") as emit:
            self.assertEqual(observer.main(), 0)
            emit.assert_called_once_with("PUBLIC_PACKAGE_DIAGNOSTIC_DEADLINE")
            args, kwargs = run.call_args
            self.assertIn("--attempts", args[0])
            self.assertEqual(args[0][args[0].index("--attempts") + 1], "1")
            self.assertEqual(kwargs["timeout"], 40)
            self.assertTrue(kwargs["capture_output"])

    def test_native_job_does_not_depend_on_diagnostic(self):
        workflow = (ROOT / ".github/workflows/ios.yml").read_text()
        smoke = workflow.split("  player-smoke:", 1)[1].split("  public-package-failure-diagnostic:", 1)[0]
        job = workflow.split("  public-package-failure-diagnostic:", 1)[1].split("  ipad-feed-ui-evaluator:", 1)[0]
        self.assertNotIn("needs: public-package-failure-diagnostic", workflow)
        self.assertIn("xcodebuild test", smoke)
        self.assertIn("exit 1", smoke)
        self.assertIn("needs: player-smoke", job)
        self.assertIn("needs.player-smoke.result == 'failure'", job)
        self.assertIn("persist-credentials: false", job)
        self.assertIn("timeout-minutes: 3", job)
        self.assertNotIn("secrets.", job)


if __name__ == "__main__":
    unittest.main()
