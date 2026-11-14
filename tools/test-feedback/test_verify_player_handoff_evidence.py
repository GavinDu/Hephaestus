import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

FILE = Path(__file__).with_name("verify-player-handoff-evidence.py")
SPEC = importlib.util.spec_from_file_location("player_handoff", FILE)
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)

PNG_TEST = importlib.util.spec_from_file_location(
    "ui_png_fixture", Path(__file__).with_name("test_verify_ui_screenshot_evidence.py")
)
fixture_module = importlib.util.module_from_spec(PNG_TEST)
PNG_TEST.loader.exec_module(fixture_module)


class PlayerHandoffEvidenceTests(unittest.TestCase):
    def fixture(self, folder, omit=None, orientation_before=1,
                orientation_after=1, after_color=b"\x30\x50\x70"):
        entries = []
        for name in (module.ORIGIN_BEFORE, module.ORIGIN_AFTER):
            if name == omit:
                continue
            angle = orientation_before if name == module.ORIGIN_BEFORE else orientation_after
            color = b"\x20\x40\x60" if name == module.ORIGIN_BEFORE else after_color
            filename = name + ".png"
            (folder / filename).write_bytes(
                fixture_module.png(400, 700, orientation=angle, rgb=color)
            )
            entries.append({
                "exportedFileName": filename,
                "suggestedHumanReadableName": name + "_0_TEST.png"
            })
        (folder / "manifest.json").write_text(json.dumps([{"attachments": entries}]))

    def test_original_native_player_return_images_are_unchanged(self):
        with tempfile.TemporaryDirectory() as td:
            src, out = Path(td) / "src", Path(td) / "out"
            src.mkdir()
            self.fixture(src)
            report = module.verify_and_copy(src, out)
            self.assertEqual(report["status"], "native-screenshot-metadata-verified")
            self.assertFalse(report["media_ready"])
            self.assertTrue(report["manual_visual_review_required"])
            for name in (module.ORIGIN_BEFORE, module.ORIGIN_AFTER):
                self.assertEqual(
                    (src / (name + ".png")).read_bytes(),
                    (out / (name + ".raw.png")).read_bytes()
                )
            self.assertEqual(len(report["verified"]), 2)

    def test_missing_capture_and_tampered_png_fail_closed(self):
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "src"
            src.mkdir()
            self.fixture(src, omit=module.ORIGIN_AFTER)
            with self.assertRaisesRegex(ValueError, "expected exactly one"):
                module.verify_and_copy(src, Path(td) / "missing")
            self.fixture(src)
            path = src / (module.ORIGIN_BEFORE + ".png")
            corrupt = bytearray(path.read_bytes())
            corrupt[29] ^= 1
            path.write_bytes(corrupt)
            with self.assertRaisesRegex(ValueError, "invalid PNG chunk CRC"):
                module.verify_and_copy(src, Path(td) / "corrupt")

    def test_faked_rotation_is_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "src"
            src.mkdir()
            self.fixture(src, orientation_after=8)
            with self.assertRaisesRegex(ValueError, "geometry or orientation"):
                module.verify_and_copy(src, Path(td) / "rotated")

    def test_same_post_can_retain_identical_pixels(self):
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "src"
            src.mkdir()
            self.fixture(src, after_color=b"\x20\x40\x60")
            result = module.verify_and_copy(src, Path(td) / "out")
            before, after = module.ORIGIN_BEFORE, module.ORIGIN_AFTER
            self.assertEqual(
                result["verified"][before]["sha256"],
                result["verified"][after]["sha256"]
            )


if __name__ == "__main__":
    unittest.main()
