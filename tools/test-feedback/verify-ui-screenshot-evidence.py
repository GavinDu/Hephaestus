#!/usr/bin/env python3
"""Validate iPhone/iPad XCTest screenshot orientation and publish reviewable raw PNGs.

XCTest's app-window attachment can export as a portrait-framed image with
large black bands even when the same simulator's full-screen capture is a
correct, readable landscape. Trust *full-screen* evidence for landscape,
but never rotate, alter, erase, or discard original PNGs.

All inspection uses Python's standard library; macOS runner needs no PIL.
This is a screenshot geometry/provenance gate, NOT gameplay/media approval.
"""
import argparse
import json
import shutil
import struct
import zlib
from pathlib import Path

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
LANDSCAPE_PRIMARY = (
    "feed-full-screen-before-swipe-landscape",
    "feed-full-screen-after-swipe-landscape",
)
LANDSCAPE_DIAGNOSTIC = (
    "feed-ui-evaluator-before-swipe-landscape",
    "feed-ui-evaluator-after-swipe-landscape",
)
PORTRAIT_PRIMARY = (
    "feed-ui-evaluator-before-swipe-portrait",
    "feed-ui-evaluator-after-swipe-portrait",
)


def tiff_orientation(data):
    """Return TIFF orientation from a PNG eXIf chunk; 1 if unspecified."""
    if len(data) < 8 or data[:2] not in (b"II", b"MM"):
        return 1
    endian = "<" if data[:2] == b"II" else ">"
    if struct.unpack_from(endian + "H", data, 2)[0] != 42:
        return 1
    offset = struct.unpack_from(endian + "I", data, 4)[0]
    if offset + 2 > len(data):
        return 1
    count = struct.unpack_from(endian + "H", data, offset)[0]
    for i in range(count):
        start = offset + 2 + 12 * i
        if start + 12 > len(data):
            return 1
        tag, kind, entries = struct.unpack_from(endian + "HHI", data, start)
        if tag == 0x0112 and kind == 3 and entries == 1:
            result = struct.unpack_from(endian + "H", data, start + 8)[0]
            return result if 1 <= result <= 8 else 1
    return 1


def read_png_metadata(path):
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError(f"{path.name}: not a PNG")
    pos = len(PNG_SIGNATURE)
    width = height = None
    orientation = 1
    complete = False
    while pos + 12 <= len(data):
        size = struct.unpack_from(">I", data, pos)[0]
        kind = data[pos + 4:pos + 8]
        end = pos + 12 + size
        if end > len(data):
            raise ValueError(f"{path.name}: truncated PNG chunk")
        payload = data[pos + 8:pos + 8 + size]
        expected_crc = struct.unpack_from(">I", data, end - 4)[0]
        if (zlib.crc32(kind + payload) & 0xffffffff) != expected_crc:
            raise ValueError(f"{path.name}: invalid PNG chunk CRC")
        if kind == b"IHDR":
            if size != 13:
                raise ValueError(f"{path.name}: invalid IHDR")
            width, height = struct.unpack_from(">II", payload)
        elif kind == b"eXIf":
            orientation = tiff_orientation(payload)
        elif kind == b"IEND":
            complete = True
            break
        pos = end
    if not complete or not width or not height or width > 8192 or height > 8192:
        raise ValueError(f"{path.name}: incomplete or implausible PNG")
    # EXIF orientations 5-8 swap the displayed width and height.
    shown = (height, width) if orientation >= 5 else (width, height)
    return {
        "raw_width": width, "raw_height": height,
        "exif_orientation": orientation,
        "display_width": shown[0], "display_height": shown[1],
    }


def exported_attachment(attachments, logical_name):
    matches = [
        item for item in attachments
        if (item.get("suggestedHumanReadableName") or "").startswith(logical_name + "_")
    ]
    if len(matches) != 1:
        raise ValueError(f"{logical_name}: expected exactly one screenshot attachment, found {len(matches)}")
    name = matches[0].get("exportedFileName", "")
    if not name or Path(name).name != name or not name.endswith(".png"):
        raise ValueError(f"{logical_name}: unexpected exported filename")
    return name


def verify_and_copy(attachments_dir, output_dir):
    manifest = json.loads((attachments_dir / "manifest.json").read_text())
    attachments = [x for entry in manifest for x in entry.get("attachments", [])]
    validated = {}
    output_dir.mkdir(parents=True, exist_ok=True)
    for logical in LANDSCAPE_PRIMARY + LANDSCAPE_DIAGNOSTIC + PORTRAIT_PRIMARY:
        src = attachments_dir / exported_attachment(attachments, logical)
        if not src.is_file():
            raise ValueError(f"{logical}: missing raw screenshot PNG")
        info = read_png_metadata(src)
        display_landscape = info["display_width"] > info["display_height"]
        if logical in LANDSCAPE_PRIMARY and not display_landscape:
            raise ValueError(f"{logical}: full-screen capture does not display in landscape")
        if logical in PORTRAIT_PRIMARY and display_landscape:
            raise ValueError(f"{logical}: portrait evidence displays in landscape")
        preferred = logical in LANDSCAPE_PRIMARY + PORTRAIT_PRIMARY
        target = output_dir / (logical + ".raw.png")
        shutil.copyfile(src, target)
        validated[logical] = {**info, "file": target.name, "preferred_for_visual_review": preferred}
    report = {
        "status": "screen-orientation-verified",
        "capture_source": "native XCTest xcresulttool export attachments",
        "screenshot_files_unchanged": True,
        "landscape_preferred": list(LANDSCAPE_PRIMARY),
        "app_window_landscape_diagnostic_only": list(LANDSCAPE_DIAGNOSTIC),
        "verified": validated,
        "media_ready": False,
        "note": "A correct screenshot orientation cannot establish an approved gameplay clip or poster.",
    }
    (output_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    try:
        report = verify_and_copy(args.input, args.out)
        print(json.dumps({"status": report["status"], "verified_count": len(report["verified"])}))
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        parser.exit(1, f"UI screenshot evidence failed: {error}\n")


if __name__ == "__main__":
    main()
