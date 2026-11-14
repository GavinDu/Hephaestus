#!/usr/bin/env python3
"""Fail-closed provenance check for real native player return screenshots.

This verifies original full-screen screenshot attachments, intact PNG data
and stable display geometry. It does NOT certify that the pixels depict
gameplay or replace human visual review, which remains mandatory in #183.
"""
import argparse
import hashlib
import importlib.util
import json
import shutil
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "arcade_ui_png", Path(__file__).with_name("verify-ui-screenshot-evidence.py")
)
png_validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(png_validator)

ORIGIN_BEFORE = "arcade-pulse-player-origin-before-play"
ORIGIN_AFTER = "arcade-pulse-player-origin-after-return"


def verify_and_copy(attachments_dir: Path, output_dir: Path) -> dict:
    manifest = json.loads((attachments_dir / "manifest.json").read_text())
    attachments = [a for case in manifest for a in case.get("attachments", [])]
    output_dir.mkdir(parents=True, exist_ok=True)
    verified = {}
    for logical in (ORIGIN_BEFORE, ORIGIN_AFTER):
        exported = png_validator.exported_attachment(attachments, logical)
        src = attachments_dir / exported
        if not src.is_file():
            raise ValueError(f"{logical}: missing raw screenshot PNG")
        info = png_validator.read_png_metadata(src)
        if min(info["display_width"], info["display_height"]) < 300:
            raise ValueError(f"{logical}: implausibly small full-screen native capture")
        target = output_dir / (logical + ".raw.png")
        shutil.copyfile(src, target)
        verified[logical] = {
            **info,
            "file": target.name,
            "sha256": hashlib.sha256(src.read_bytes()).hexdigest(),
            "preferred_for_visual_review": True,
        }

    first = verified[ORIGIN_BEFORE]
    last = verified[ORIGIN_AFTER]
    if (first["display_width"], first["display_height"]) != (
        last["display_width"], last["display_height"]
    ):
        raise ValueError("Player exit changes native display geometry or orientation")
    # Same game and same frame may legitimately have exactly the same pixels.
    # Do NOT reject matching before/after rasters as a screenshot replay:
    # game identity, UI navigation and hit testing are enforced by native XCTest.
    report = {
        "status": "native-screenshot-metadata-verified",
        "capture_source": "XCUIScreen.main.screenshot via XCTest xcresulttool export",
        "screenshot_files_unchanged": True,
        "verified": verified,
        "game_identity_verified_by": "strict live native PlayerSmokeTests.testDiscoverLaunchesPlayer",
        "media_ready": False,
        "manual_visual_review_required": True,
        "note": "Matching display geometry is not proof of first presented gameplay frame.",
    }
    (output_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = verify_and_copy(args.input, args.out)
        print(json.dumps({"status": result["status"], "count": len(result["verified"])}))
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        parser.exit(1, f"Player handoff screenshot evidence failed: {error}\n")


if __name__ == "__main__":
    main()
