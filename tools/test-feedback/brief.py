#!/usr/bin/env python3
"""Render a next-iteration brief from a test-feedback.json artifact.

Per docs/TESTING_FRAMEWORK.md §11 step 5, the brief is an input document,
not a diagnosis: what failed, in which case, with which failure class,
the replay inputs, and the most relevant log lines. The iteration that
consumes it still has to verify its fix with a new run.

Usage:
    tools/test-feedback/brief.py <test-feedback.json> [--log-dir <dir>]

Log files named in a case's `logs` list are read from --log-dir (default:
the artifact's directory). For a DevLog JSON export, error lines come
first, then the lines immediately before the failure; for plain-text
logs, lines containing ERROR or WARN come first. A case with no usable
log file still gets a brief — it just says its logs are missing, so the
gap is visible instead of silently dropped.

Exit code is 0 even when the artifact reports failures: the brief is a
report, not a test gate. It exits 2 only when the artifact itself is
unreadable or fails basic validation (wrong schema version, missing
required fields, unknown verdict).
"""

import json
import sys
from pathlib import Path

FAILURE_CLASSES = {
    "compile", "contract", "render", "perf", "crash", "timeout",
    "auth", "network", "flake", "unknown",
}
VERDICTS = {"pass", "fail", "skip"}


def fail(msg):
    print(f"brief: {msg}", file=sys.stderr)
    raise SystemExit(2)


def relevant_lines(log_path, limit=5):
    """Pick the lines most likely to explain a failure, in order."""
    try:
        text = log_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    try:
        doc = json.loads(text)
        entries = doc.get("entries", [])
        lines = [
            f"[{e.get('timestamp', '?')}] [{e.get('category', '?')}] "
            f"{e.get('level', '')} {e.get('message', '')}".strip()
            for e in entries
        ]
        errors = [ln for ln in lines if "error" in ln.lower()]
        warns = [ln for ln in lines if "warn" in ln.lower()]
        picked, seen = [], set()
        for ln in errors + warns + lines[-limit:]:
            if ln not in seen:
                seen.add(ln)
                picked.append(ln)
        return picked[:limit] or lines[-limit:]
    except (ValueError, AttributeError):
        pass
    lines = text.splitlines()
    flagged = [ln for ln in lines if "ERROR" in ln or "WARN" in ln]
    picked, seen = [], set()
    for ln in flagged + lines[-limit:]:
        if ln not in seen:
            seen.add(ln)
            picked.append(ln)
    return picked[:limit] or None


def main(argv):
    if len(argv) < 2:
        fail("usage: brief.py <test-feedback.json> [--log-dir <dir>]")
    artifact_path = Path(argv[1])
    log_dir = artifact_path.parent
    if len(argv) > 2:
        if argv[2] == "--log-dir" and len(argv) > 3:
            log_dir = Path(argv[3])
        else:
            fail("--log-dir requires a directory")

    try:
        artifact = json.loads(artifact_path.read_text())
    except (OSError, ValueError) as exc:
        fail(f"cannot read artifact {artifact_path}: {exc}")

    if artifact.get("schema_version") != 1:
        fail(f"unsupported schema_version {artifact.get('schema_version')!r} (want 1)")
    for field in ("run_id", "commit", "repo", "layer", "cases", "summary"):
        if field not in artifact:
            fail(f"missing required field {field!r}")
    cases = artifact["cases"]
    for case in cases:
        if case.get("verdict") not in VERDICTS:
            fail(f"case {case.get('id')!r} has unknown verdict {case.get('verdict')!r}")
        if case.get("failure_class") and case["failure_class"] not in FAILURE_CLASSES:
            fail(f"case {case.get('id')!r} has unknown failure_class {case['failure_class']!r}")

    summary = artifact["summary"]
    lines = []
    lines.append(f"# Iteration brief: run {artifact['run_id']}")
    lines.append("")
    lines.append(f"- Repo: {artifact['repo']} @ {artifact['commit']}")
    lines.append(f"- Layer: {artifact['layer']} "
                 f"({['no device', 'simulator', 'physical'][artifact['layer']]})")
    env = artifact.get("environment", {})
    lines.append(f"- Environment: {env.get('kind', '?')} "
                 f"{env.get('device', '')} {env.get('os', '')}".rstrip())
    game = artifact.get("game", {})
    if game.get("id"):
        lines.append(f"- Game: {game['id']} (ir_hash: {game.get('ir_hash', 'n/a')})")
    lines.append(f"- Summary: {summary.get('pass', 0)} pass, "
                 f"{summary.get('fail', 0)} fail, {summary.get('skip', 0)} skip")
    lines.append("")

    failures = [c for c in cases if c["verdict"] == "fail"]
    skips = [c for c in cases if c["verdict"] == "skip"]
    if not failures:
        lines.append("No failures. Nothing to fix from this run.")
        if skips:
            lines.append("")
            lines.append("## Skipped (not evidence for or against the change)")
            for case in skips:
                lines.append(f"- {case['id']}: {case.get('detail', 'no reason given')}")
        print("\n".join(lines))
        return 0

    lines.append("## Failures (fix these, then verify with a new run at the same layer)")
    for case in failures:
        lines.append("")
        lines.append(f"### {case['id']} [{case.get('failure_class', 'unknown')}]")
        if case.get("detail"):
            lines.append(case["detail"])
        replay = case.get("replay", {})
        if replay:
            lines.append(f"Replay: seed={replay.get('seed', 'n/a')}, "
                         f"inputs={json.dumps(replay.get('inputs', []))}")
        for media_key in ("screenshots", "videos"):
            if case.get(media_key):
                lines.append(f"{media_key.capitalize()}: {', '.join(case[media_key])}")
        shown = False
        for name in case.get("logs", []):
            picked = relevant_lines(log_dir / name)
            if picked:
                lines.append(f"Relevant log lines ({name}):")
                lines.extend(f"  {ln}" for ln in picked)
                shown = True
        if not shown:
            lines.append("Logs: missing or unreadable — re-run with logging enabled "
                         "before diagnosing this failure.")
    if skips:
        lines.append("")
        lines.append("## Skipped (not evidence for or against the change)")
        for case in skips:
            lines.append(f"- {case['id']}: {case.get('detail', 'no reason given')}")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
