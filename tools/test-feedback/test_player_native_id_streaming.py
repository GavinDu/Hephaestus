"""#743 native WebKit untrusted identifier validation: no full eager UTF-8 copy."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class PlayerNativeRuntimeIDNoEagerAllocationTests(unittest.TestCase):
    def test_real_shipping_policy_is_streaming_and_early_bounded(self):
        source = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        marker = "enum PlayerNativeRuntimeIdentifierPolicy {"
        self.assertEqual(source.count(marker), 1)
        policy = source.split(marker, 1)[1].split(
            "\nstruct PlayerRuntimeSessionBindingGate", 1
        )[0]
        self.assertNotIn("Array(value.utf8)", policy)
        self.assertNotIn("Array(value.utf8)", source)
        self.assertEqual(policy.count("for byte in value.utf8"), 2)
        self.assertEqual(policy.count("byteCount <= maximumBytes"), 2)
        self.assertEqual(policy.count("return byteCount > 0"), 2)

    def test_callers_continue_to_use_shared_native_policy(self):
        source = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        self.assertIn("PlayerNativeRuntimeIdentifierPolicy.validSessionID(sessionID)", source)
        self.assertIn("PlayerNativeRuntimeIdentifierPolicy.validRunID(runID)", source)
        self.assertIn("PlayerNativeRuntimeIdentifierPolicy.matchesRequestedRunID(", source)

if __name__ == "__main__":
    unittest.main()
