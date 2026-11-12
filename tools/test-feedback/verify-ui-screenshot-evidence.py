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
import hashlib
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



def png_filtered_raster_sha256(path):
    """Hash bounded unfiltered PNG pixels, ignoring compression and metadata.

    This is deliberately NOT perceptual image similarity: it detects a reused
    capture that was re-encoded or given different EXIF/text metadata. Unsupported
    PNG layouts return None and still receive the original byte-level check.
    """
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError(f"{path.name}: not a PNG")
    width = height = bit_depth = color_type = interlace = None
    compressed = []
    pos = len(PNG_SIGNATURE)
    while pos + 12 <= len(data):
        size = struct.unpack_from(">I", data, pos)[0]
        kind = data[pos + 4:pos + 8]
        end = pos + 12 + size
        if end > len(data):
            raise ValueError(f"{path.name}: truncated PNG chunk")
        payload = data[pos + 8:pos + 8 + size]
        if kind == b"IHDR":
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(
                ">IIBBBBB", payload
            )
        elif kind == b"IDAT":
            compressed.append(payload)
        elif kind == b"IEND":
            break
        pos = end
    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color_type)
    if not channels or bit_depth != 8 or interlace != 0 or not compressed:
        return None
    # Constrain memory on untrusted artifacts before even decompressing.
    expected = height * (1 + width * channels)
    if expected > 96 * 1024 * 1024:
        return None
    decoder = zlib.decompressobj()
    raw = decoder.decompress(b"".join(compressed), expected + 1)
    if len(raw) != expected or not decoder.eof or decoder.unconsumed_tail:
        raise ValueError(f"{path.name}: invalid or oversized PNG raster")
    # PNG scanline filters (None, Sub, Up, Average, Paeth) can encode
    # exactly the same displayed pixels differently. Undo every filter so
    # alternate valid encodings cannot defeat the duplicate-capture gate.
    row_width = width * channels
    prior = bytes(row_width)
    digest = hashlib.sha256(struct.pack(">IIBB", width, height, bit_depth, color_type))
    for row in range(height):
        offset = row * (1 + row_width)
        filt = raw[offset]
        if filt > 4:
            raise ValueError(f"{path.name}: invalid PNG scanline filter")
        current = bytearray(raw[offset + 1:offset + 1 + row_width])
        if filt != 0:
            for i in range(row_width):
                left = current[i - channels] if i >= channels else 0
                up = prior[i]
                upper_left = prior[i - channels] if i >= channels else 0
                if filt == 1:
                    prediction = left
                elif filt == 2:
                    prediction = up
                elif filt == 3:
                    prediction = (left + up) // 2
                else:
                    pivot = left + up - upper_left
                    distances = (
                        abs(pivot - left), abs(pivot - up),
                        abs(pivot - upper_left)
                    )
                    prediction = (
                        left if distances[0] <= distances[1] and distances[0] <= distances[2]
                        else up if distances[1] <= distances[2]
                        else upper_left
                    )
                current[i] = (current[i] + prediction) & 0xff
        digest.update(current)
        prior = current
    return digest.hexdigest()

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
        validated[logical] = {**info, "file": target.name,
                              "sha256": hashlib.sha256(src.read_bytes()).hexdigest(),
                              "raster_scanlines_sha256": png_filtered_raster_sha256(src),
                              "preferred_for_visual_review": preferred}
    # A swipe test can report success while an export/capture pipeline silently
    # reuses the same PNG for both states. Reject exact duplicates independently
    # of geometry, orientation and the XCTest interaction score. Different byte
    # hashes still require human visual inspection; this is not perceptual visual QA.
    for before, after in ((LANDSCAPE_PRIMARY[0], LANDSCAPE_PRIMARY[1]),
                          (PORTRAIT_PRIMARY[0], PORTRAIT_PRIMARY[1])):
        if validated[before]["sha256"] == validated[after]["sha256"]:
            raise ValueError(f"{before} and {after}: duplicate raw screenshot bytes")
        first = validated[before]["raster_scanlines_sha256"]
        last = validated[after]["raster_scanlines_sha256"]
        if first is not None and first == last:
            raise ValueError(f"{before} and {after}: duplicate decoded screenshot pixels")
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
