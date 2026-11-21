"""#731: reject a second package/asset transport owner in production iOS."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]

class NativeSingleOwnerSourceContractTests(unittest.TestCase):
    def test_production_does_not_link_second_game_package_transport(self):
        project = (ROOT / "Hephaestus.xcodeproj/project.pbxproj").read_text()
        # Reusing the independent offline PlayerContract fixture is allowed;
        # importing and starting its download-owning actor is not.
        for forbidden in ("GamePlayerCore", "GamePackageTransport",
                          "PlayerLaunchCoordinator"):
            self.assertNotIn(forbidden, project)

    def test_current_host_projection_is_used_on_real_runtime_callbacks(self):
        player = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        self.assertIn("enum PlayerCurrentHostMilestoneProjection", player)
        self.assertIn("private var currentHostMilestone:", player)
        self.assertIn("milestone.stage == .rendererSubmitted", player)
        self.assertIn("currentHostMilestone?.stage == .firstInputAdmitted", player)
        handler = player.split("private func handleMetric(", 1)[1].split(
            "private func request", 1
        )[0]
        self.assertIn("PlayerCurrentHostMilestoneProjection.permitsMetricAdmission(", handler)
        self.assertLess(handler.index("permitsMetricAdmission("),
                        handler.index("metricSequenceGate.accept("))
        self.assertIn("currentNativeDocumentNonce", player)
        # A source-level regression should not quietly instantiate a second
        # coordinator, JS evaluator or package transport in this host.
        self.assertNotRegex(player, r"(?<![A-Za-z])PlayerLaunchCoordinator\s*\(")
        self.assertNotRegex(player, r"(?<![A-Za-z])GamePackageTransport\s*\(")
        self.assertNotRegex(player, r"(?<![A-Za-z])eval\s*\(")

    def test_projector_preserves_terminal_and_version_truth(self):
        player = (ROOT / "Hephaestus/Player/PixiPlayer.swift").read_text()
        self.assertIn('static let gamePackageFormatVersion = "2.0"', player)
        self.assertIn("case .navigationFailed, .webProcessTerminated: stage = .failed", player)
        self.assertIn("case .detached: stage = .stopped", player)
        self.assertIn("guard ownsCurrentAttachment, attachmentLease > 0", player)
        self.assertIn("let milestone = currentHostMilestone", player)

if __name__ == "__main__":
    unittest.main()
