#!/usr/bin/env python3
"""Regression checks for both XCTest and Swift Testing xcodebuild log styles."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("xcresult-to-feedback.py")


def parse(text):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        log = root / "xcode.log"
        out = root / "test-feedback.json"
        log.write_text(text, encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--log", str(log), "--out", str(out),
             "--run-id", "test-1", "--commit", "0123456789", "--prefix", "ipad-feed"],
            capture_output=True, text=True, check=False)
        if result.returncode != 0:
            raise AssertionError(result.stderr)
        return json.loads(out.read_text(encoding="utf-8"))


class TestFeedbackParser(unittest.TestCase):
    def test_real_xctest_passed_case_records_pass_not_skip(self):
        report = parse(
            "Test Case '-[HephaestusUITests.PlayerSmokeTests "
            "testDiscoverFeedUIEvaluationAndSwipe]' passed (50.577 seconds).\n"
            "** TEST SUCCEEDED **\n")
        self.assertEqual(report["summary"], {"pass": 1, "fail": 0, "skip": 0})
        self.assertEqual(report["cases"][0]["id"],
                         "ipad-feed.PlayerSmokeTests.testDiscoverFeedUIEvaluationAndSwipe")
        self.assertEqual(report["cases"][0]["duration_ms"], 50577)

    def test_newer_swift_testing_format_stays_compatible(self):
        report = parse(
            "Test case 'PlayerSmokeTests.testDiscoverLaunchesPlayer()' "
            "passed on 'iPhone 17 Pro' (2.352 seconds)\n")
        self.assertEqual(report["summary"], {"pass": 1, "fail": 0, "skip": 0})
        self.assertEqual(report["cases"][0]["id"],
                         "ipad-feed.PlayerSmokeTests.testDiscoverLaunchesPlayer")

    def test_retry_uses_last_result_even_across_formats(self):
        report = parse(
            "Test case 'PlayerSmokeTests.testDiscoverFeedUIEvaluationAndSwipe()' "
            "failed on 'iPad' (1.1 seconds)\n"
            "Test Case '-[HephaestusUITests.PlayerSmokeTests "
            "testDiscoverFeedUIEvaluationAndSwipe]' passed (3.512 seconds).\n")
        self.assertEqual(report["summary"], {"pass": 1, "fail": 0, "skip": 0})
        self.assertEqual(report["cases"][0]["duration_ms"], 3512)

    def test_latest_failed_xctest_does_not_pass_or_drop_screenshots(self):
        report = parse(
            "Test case 'PlayerSmokeTests.testDiscoverLaunchesPlayer()' "
            "passed on 'iPhone' (2.0 seconds)\n"
            "Test Case '-[HephaestusUITests.PlayerSmokeTests "
            "testDiscoverLaunchesPlayer]' failed (4.25 seconds).\n")
        self.assertEqual(report["summary"], {"pass": 0, "fail": 1, "skip": 0})
        self.assertEqual(report["cases"][0]["failure_class"], "unknown")

    def test_missing_log_remains_skip_and_started_without_result_fails(self):
        self.assertEqual(parse("irrelevant xcode output")["summary"]["skip"], 1)
        report = parse("SMOKE: app launched\nwaiting for result")
        self.assertEqual(report["summary"]["fail"], 1)
        self.assertEqual(report["cases"][0]["failure_class"], "timeout")


if __name__ == "__main__":
    unittest.main()
