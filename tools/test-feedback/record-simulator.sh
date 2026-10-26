#!/bin/sh
# record-simulator.sh — simulator screen capture for a test-feedback run.
#
# Wraps the simulator video workflow from docs/TESTING_FRAMEWORK.md §5.4:
# boot the simulator, record its screen for the whole run, stop on exit,
# and keep the video only when the run failed (or when KEEP_VIDEO=1).
# Screenshots are taken on demand with: record-simulator.sh shot <device> <out.png>
#
# Usage:
#   RUN_ID=... DEVICE="iPhone 16" OUT_DIR=./feedback ./tools/test-feedback/record-simulator.sh \
#       xcodebuild test -scheme Hephaestus -destination 'platform=iOS Simulator,name=iPhone 16' ...
# The wrapped command's exit code is preserved. Video is written to
# $OUT_DIR/<run_id>.mp4 when kept, and deleted otherwise.
set -eu

DEVICE="${DEVICE:-iPhone 16}"
OUT_DIR="${OUT_DIR:-./feedback}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
KEEP_VIDEO="${KEEP_VIDEO:-0}"

if [ "${1:-}" = "shot" ]; then
    # record-simulator.sh shot <device> <out.png>
    xcrun simctl io "$2" screenshot "$3"
    exit 0
fi

if [ "$#" -eq 0 ]; then
    echo "usage: record-simulator.sh <command...>" >&2
    exit 2
fi

mkdir -p "$OUT_DIR"
VIDEO="$OUT_DIR/$RUN_ID.mp4"

xcrun simctl boot "$DEVICE" 2>/dev/null || true
# Record in the background; simctl stops recording when killed.
xcrun simctl io "$DEVICE" recordVideo "$VIDEO" &
REC_PID=$!
# Ensure the recorder is stopped even if the wrapped command is interrupted.
trap 'kill $REC_PID 2>/dev/null || true; wait $REC_PID 2>/dev/null || true' EXIT INT TERM

set +e
"$@"
STATUS=$?
set -e

kill $REC_PID 2>/dev/null || true
wait $REC_PID 2>/dev/null || true
trap - EXIT INT TERM

if [ "$STATUS" -ne 0 ] || [ "$KEEP_VIDEO" = "1" ]; then
    echo "record-simulator: kept video $VIDEO (exit=$STATUS)"
else
    rm -f "$VIDEO"
    echo "record-simulator: run passed, discarded video"
fi
exit "$STATUS"
