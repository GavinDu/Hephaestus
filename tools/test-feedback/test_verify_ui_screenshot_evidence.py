import importlib.util
import json
import struct
import tempfile
import unittest
import zlib
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "verify_ui_screenshot_evidence",
    Path(__file__).with_name("verify-ui-screenshot-evidence.py"),
)
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


def chunk(kind, payload):
    return (struct.pack(">I", len(payload)) + kind + payload +
            struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff))


def png(width, height, orientation=1, rgb=b"\x20\x50\x80", level=6, filter_type=0):
    # Small valid RGB PNG with TIFF/EXIF rotation metadata.
    original = rgb * width
    if filter_type == 0:
        encoded = original
    elif filter_type == 1:  # PNG Sub filter on a three-byte RGB pixel
        encoded = bytes((value - (original[i - 3] if i >= 3 else 0)) & 0xff
                        for i, value in enumerate(original))
    else:
        raise ValueError("Unsupported PNG fixture filter")
    rows = b"".join(bytes([filter_type]) + encoded for _ in range(height))
    tiff = (b"II\x2a\x00" + struct.pack("<I", 8) +
            struct.pack("<H", 1) + struct.pack("<HHI", 0x0112, 3, 1) +
            struct.pack("<H", orientation) + b"\x00\x00" +
            struct.pack("<I", 0))
    return (module.PNG_SIGNATURE +
            chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) +
            chunk(b"eXIf", tiff) +
            chunk(b"IDAT", zlib.compress(rows, level)) +
            chunk(b"IEND", b""))


class ScreenshotEvidenceTests(unittest.TestCase):
    def test_exif_swaps_display_dimensions(self):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory) / "frame.png"
            p.write_bytes(png(20, 10, 8))
            info = module.read_png_metadata(p)
            self.assertEqual((info["display_width"], info["display_height"]), (10, 20))
            p.write_bytes(png(10, 20, 8))
            self.assertEqual(module.read_png_metadata(p)["display_width"], 20)

    def fixture(self, folder, corrupt_fullscreen=False, omit=None,
                include_ipad_library=False):
        attachments = []
        library = ((module.IPAD_LIBRARY_PORTRAIT, module.IPAD_LIBRARY_LANDSCAPE)
                   if include_ipad_library else ())
        for name in (module.LANDSCAPE_PRIMARY +
                     module.LANDSCAPE_DIAGNOSTIC + module.PORTRAIT_PRIMARY + library):
            if name == omit:
                continue
            file = name + ".png"
            # Full screen raw portrait + EXIF 8 -> landscape displayed.
            # App-window raw landscape + EXIF 8 -> incorrect portrait displayed.
            rgb = b"\x50\x40\x20" if "after-swipe" in name else b"\x20\x50\x80"
            if name == module.IPAD_LIBRARY_PORTRAIT:
                payload = png(10, 20, 1, rgb=b"\x20\x50\x80")
            elif name == module.IPAD_LIBRARY_LANDSCAPE:
                payload = png(10, 20, 8, rgb=b"\x50\x40\x20")
            elif name in module.LANDSCAPE_PRIMARY:
                payload = png(10, 20, 1 if corrupt_fullscreen else 8, rgb=rgb)
            elif name in module.LANDSCAPE_DIAGNOSTIC:
                payload = png(20, 10, 8, rgb=rgb)
            else:
                payload = png(10, 20, 1, rgb=rgb)
            (folder / file).write_bytes(payload)
            attachments.append({"exportedFileName": file,
                                "suggestedHumanReadableName": name + "_0_TEST.png"})
        (folder / "manifest.json").write_text(json.dumps([{"attachments": attachments}]))

    def test_preferred_landscape_screen_is_verifiable_and_raw_bytes_are_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            output = Path(directory) / "review"
            source.mkdir()
            self.fixture(source)
            report = module.verify_and_copy(source, output)
            self.assertEqual(report["status"], "screen-orientation-verified")
            self.assertFalse(report["media_ready"])
            for name in module.LANDSCAPE_PRIMARY:
                self.assertTrue(report["verified"][name]["preferred_for_visual_review"])
                self.assertEqual((output / (name + ".raw.png")).read_bytes(),
                                 (source / (name + ".png")).read_bytes())
            for name in module.LANDSCAPE_DIAGNOSTIC:
                self.assertFalse(report["verified"][name]["preferred_for_visual_review"])

    def test_exact_duplicate_swipe_capture_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            source.mkdir()
            self.fixture(source)
            for before, after in (module.LANDSCAPE_PRIMARY, module.PORTRAIT_PRIMARY):
                (source / (after + ".png")).write_bytes(
                    (source / (before + ".png")).read_bytes())
                with self.assertRaisesRegex(ValueError, "duplicate raw screenshot bytes"):
                    module.verify_and_copy(source, Path(directory) / "out")
                # Restore the independent after-swipe frame for the next case.
                self.fixture(source)

    def test_reencoded_identical_screen_pixels_are_not_valid_swipe_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory) / "source"
            folder.mkdir()
            for before, after in (module.LANDSCAPE_PRIMARY, module.PORTRAIT_PRIMARY):
                self.fixture(folder)
                # The after image has the same raster, but a different PNG
                # compression level AND scanline filter. Raw SHA-256 and
                # decoded filtered-scanline digests cannot catch this replay.
                orientation = 8 if before in module.LANDSCAPE_PRIMARY else 1
                reused = png(10, 20, orientation=orientation,
                             rgb=b"\x20\x50\x80", level=9, filter_type=1)
                self.assertNotEqual(reused, (folder / (before + ".png")).read_bytes())
                (folder / (after + ".png")).write_bytes(reused)
                with self.assertRaisesRegex(ValueError, "duplicate decoded screenshot pixels"):
                    module.verify_and_copy(folder, Path(directory) / "out")

    def test_png_crc_corruption_rejected_before_visual_approval(self):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory) / "tampered.png"
            raw = bytearray(png(10, 20, 8))
            # First IHDR checksum: changing any byte must be a hard failure.
            raw[29] ^= 1
            p.write_bytes(raw)
            with self.assertRaisesRegex(ValueError, "invalid PNG chunk CRC"):
                module.read_png_metadata(p)

    def test_ipad_library_captures_required_with_raw_portrait_and_landscape(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory) / "source"
            review = Path(directory) / "review"
            folder.mkdir()
            self.fixture(folder, include_ipad_library=True)
            report = module.verify_and_copy(folder, review, require_ipad_library=True)
            self.assertTrue(report["ipad_library_required"])
            for name in (module.IPAD_LIBRARY_PORTRAIT, module.IPAD_LIBRARY_LANDSCAPE):
                self.assertIn(name, report["verified"])
                self.assertTrue(report["verified"][name]["preferred_for_visual_review"])
                self.assertEqual(
                    (review / (name + ".raw.png")).read_bytes(),
                    (folder / (name + ".png")).read_bytes(),
                )
            self.assertLess(
                report["verified"][module.IPAD_LIBRARY_PORTRAIT]["display_width"],
                report["verified"][module.IPAD_LIBRARY_PORTRAIT]["display_height"],
            )
            self.assertGreater(
                report["verified"][module.IPAD_LIBRARY_LANDSCAPE]["display_width"],
                report["verified"][module.IPAD_LIBRARY_LANDSCAPE]["display_height"],
            )

    def test_ipad_library_missing_or_wrong_orientation_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory) / "source"
            folder.mkdir()
            self.fixture(folder)
            # Pre-existing feed captures are insufficient to approve Library.
            with self.assertRaisesRegex(ValueError, "arcade-pulse-library-ipad-portrait: expected exactly one"):
                module.verify_and_copy(folder, Path(directory) / "out", require_ipad_library=True)
            self.fixture(folder, include_ipad_library=True)
            landscape = folder / (module.IPAD_LIBRARY_LANDSCAPE + ".png")
            landscape.write_bytes(png(10, 20, 1, rgb=b"\x50\x40\x20"))
            with self.assertRaisesRegex(ValueError, "arcade-pulse-library-ipad-landscape: full-screen capture does not display in landscape"):
                module.verify_and_copy(folder, Path(directory) / "out2", require_ipad_library=True)

    def test_ipad_library_reused_pixels_with_changed_exif_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory) / "source"
            folder.mkdir()
            self.fixture(folder, include_ipad_library=True)
            landscape = folder / (module.IPAD_LIBRARY_LANDSCAPE + ".png")
            # Different EXIF orientation and file bytes cannot disguise
            # the same reused portrait raster as a landscape capture.
            landscape.write_bytes(png(10, 20, 8, rgb=b"\x20\x50\x80"))
            with self.assertRaisesRegex(ValueError, "iPad Library portrait/landscape: duplicate decoded screenshot pixels"):
                module.verify_and_copy(folder, Path(directory) / "out", require_ipad_library=True)

    def test_malformed_landscape_or_missing_evidence_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "source"
            source.mkdir()
            self.fixture(source, corrupt_fullscreen=True)
            with self.assertRaisesRegex(ValueError, "does not display in landscape"):
                module.verify_and_copy(source, Path(directory) / "out")
            self.fixture(source, omit=module.LANDSCAPE_PRIMARY[0])
            with self.assertRaisesRegex(ValueError, "expected exactly one"):
                module.verify_and_copy(source, Path(directory) / "out2")


if __name__ == "__main__":
    unittest.main()
