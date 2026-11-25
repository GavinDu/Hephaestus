#!/usr/bin/env python3
"""Post-failure, read-only evidence. Not a native smoke or deployment verdict."""
import re
import subprocess
import sys
from pathlib import Path

PROBE = Path(__file__).with_name("verify-live-game-fixture.py")
FEED = "https://html-5-game-generator.replit.app/v1/feed"
# Only fixed ASCII categories from the existing preflight. Never echo a raw
# child error/traceback, response body, unknown key, URL, identity or value.
WORD = r"(?:gameId|game_id|packageFormatVersion|package_format_version|minRuntimeVersion|irVersion|ir|gameIR|irHash|irSha256|assets)"
CATEGORY = r"(?:http_[0-9]{3}|not_json|not_object|invalid_json|too_large|redirect|transport|unavailable|invalid_envelope_(?:not_object|game_id_mismatch|missing_package_format|unsupported_package_format|missing_min_runtime|missing_ir_version|missing_ir|missing_ir_ir_version|ir_version_mismatch|missing_full_ir_sha|short_ir_hash_mismatch|missing_assets_array))"
COUNT = r"[0-9]{1,8}"
SHAPE = rf"(?:none|{WORD}(?:\|{WORD})*)"
BREAKDOWN = rf"{CATEGORY}:{COUNT}(?:,{CATEGORY}:{COUNT})*"
SHAPES = rf"{SHAPE}:{COUNT}(?:,{SHAPE}:{COUNT})*"
READY = re.compile(rf"LIVE_FIXTURE_ENVELOPE_READY owner_present=true feed_count={COUNT} eligible_count={COUNT} package=v2_shape_only", re.ASCII)
FAILURE = re.compile(
    rf"LIVE_FIXTURE_NOT_READY attempt=1: (?:feed_failure={CATEGORY}|"
    rf"live feed lacks a games array|"
    rf"live feed HTTP 200 but no eligible owner-linked public ready game \(feed_count={COUNT}\); fixture #288 not ready|"
    rf"feed has owner-linked game\(s\) but no retrievable matching playable package "
    rf"\(feed_count={COUNT}, eligible_count={COUNT}, package_failure_breakdown={BREAKDOWN}"
    rf"(?:, safe_package_keys={SHAPES})?\); fixture #288 not ready)",
    re.ASCII,
)


def classify(returncode, stdout, stderr):
    # The CLI emits one substantive line per attempt. Never concatenate
    # arbitrary subprocess streams into CI output.
    if returncode == 0:
        lines = stdout.splitlines()
        if len(lines) == 1 and len(lines[0]) <= 2048 and READY.fullmatch(lines[0]):
            return lines[0]
    elif returncode == 1:
        lines = stderr.splitlines()
        if lines and len(lines[0]) <= 2048 and FAILURE.fullmatch(lines[0]):
            return lines[0]
    return "PUBLIC_PACKAGE_DIAGNOSTIC_UNCLASSIFIED"


def main():
    try:
        child = subprocess.run(
            [sys.executable, str(PROBE), "--feed-url", FEED,
             "--attempts", "1", "--timeout", "5", "--retry-seconds", "0"],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            timeout=40, check=False,
        )
    except subprocess.TimeoutExpired:
        print("PUBLIC_PACKAGE_DIAGNOSTIC_DEADLINE")
        return 0
    except OSError:
        print("PUBLIC_PACKAGE_DIAGNOSTIC_UNAVAILABLE")
        return 0
    print(classify(child.returncode, child.stdout, child.stderr))
    return 0


if __name__ == "__main__":
    sys.exit(main())
