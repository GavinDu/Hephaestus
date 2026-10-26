#!/usr/bin/env python3
"""Build a test-feedback.json artifact from a player-smoke run.

Per docs/TESTING_FRAMEWORK.md Phase 2b, this is the CI producer that
turns a smoke-test run into the artifact the feedback loop consumes.
It parses the xcodebuild log (the reliable, line-oriented record)
rather than the xcresult bundle's internal format, so it keeps working
across Xcode versions.

Usage:
    tools/test-feedback/xcresult-to-feedback.py \
        --log /tmp/smoke.log --out /tmp/test-feedback.json \
        --run-id <id> --commit <sha> [--video run.mp4] [--screenshot shot.png]

The producer is advisory by design: it never exits non-zero for a
missing or unparsable log. If no test cases can be found, it emits a
single `skip` case saying so — a skip with a reason, never a silent
pass and never a failure of the job that runs it. The CI step that
calls it must therefore also be `if: always()` and must not gate on
this script's output; the smoke test's own verdict remains the gate.

Test-case lines parsed (xcodebuild format):
    Test case 'PlayerSmokeTests.testDiscoverLaunchesPlayer()' passed on ...
    Test case 'PlayerSmokeTests.testDiscoverLaunchesPlayer()' failed on ...
A case that started (SMOKE: app launched) but has no result line is
reported as `fail` with class `timeout`, not dropped.
"""

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

CASE_RE = re.compile(
    r"Test case '([^']+)' (passed|failed) on '([^']+)' \(([\d.]+) seconds\)"
)
STARTED_RE = re.compile(r"SMOKE: app launched")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--repo", default="GavinDu/Hephaestus")
    parser.add_argument("--video", default=None)
    parser.add_argument("--screenshot", default=None)
    args = parser.parse_args()

    cases = []
    started = False
    try:
        text = Path(args.log).read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        text = ""
        print(f"xcresult-to-feedback: cannot read log: {exc}", file=sys.stderr)

    for match in CASE_RE.finditer(text):
        name, result, _device, seconds = match.groups()
        name = name[:-2] if name.endswith("()") else name
        case = {
            "id": f"player-smoke.{name}",
            "verdict": "pass" if result == "passed" else "fail",
            "duration_ms": int(float(seconds) * 1000),
        }
        if result == "failed":
            case["failure_class"] = "unknown"
            case["detail"] = (
                "Smoke test failed; see the smoke log and the failure "
                "screenshot attachment for the UI state at failure."
            )
        if args.screenshot and result == "failed":
            case["screenshots"] = [args.screenshot]
        if args.video and result == "failed":
            case["videos"] = [args.video]
        cases.append(case)
    if STARTED_RE.search(text) and not cases:
        cases.append({
            "id": "player-smoke.discover-launches-player",
            "verdict": "fail",
            "failure_class": "timeout",
            "detail": "Smoke test started but produced no result line; "
                      "treated as a timeout, not dropped.",
        })
    if not cases:
        cases.append({
            "id": "player-smoke.producer",
            "verdict": "skip",
            "detail": "No test-case result lines found in the smoke log; "
                      "the producer could not determine the run outcome.",
        })

    summary = {
        "pass": sum(1 for c in cases if c["verdict"] == "pass"),
        "fail": sum(1 for c in cases if c["verdict"] == "fail"),
        "skip": sum(1 for c in cases if c["verdict"] == "skip"),
    }
    artifact = {
        "schema_version": 1,
        "run_id": args.run_id,
        "created_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "commit": args.commit,
        "repo": args.repo,
        "layer": 1,
        "environment": {"kind": "simulator"},
        "cases": cases,
        "summary": summary,
    }
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(artifact, indent=2) + "\n")
    print(f"xcresult-to-feedback: wrote {out} "
          f"({summary['pass']} pass, {summary['fail']} fail, {summary['skip']} skip)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
