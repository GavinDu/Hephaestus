"""Approved immersive Store feed source contract; no synthetic media."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]


class ImmersiveStoreFeedContractTests(unittest.TestCase):
    def test_real_page_preserves_media_actions_and_truthful_metrics(self):
        s = (ROOT / "Hephaestus/Views/Discover/DiscoverView.swift").read_text()
        page = s.split("private struct ForYouGamePage: View", 1)[1]
        for token in ("ArcadePulsePlayCTA(immersiveFeed: true, action: onPlay)",
                      "count: game.likeCount", "count: game.shares",
                      "metric(game.shares)", "feed.actionRail",
                      "FeedPreviewPolicy.hasDisplayReadyClip", "Preview unavailable",
                      "accessibleSocialMenu(vertical: vertical)",
                      "feed.page.title.", "mediaLayer"):
            self.assertIn(token, page)

    def test_shared_play_preserves_existing_identifier_and_target(self):
        s = (ROOT / "Hephaestus/Views/Design/ArcadePulseTheme.swift").read_text()
        cta = s.split("struct ArcadePulsePlayCTA: View", 1)[1].split(
            "enum ArcadePulseCreatorAvatarURLPolicy", 1)[0]
        for token in ("var immersiveFeed = false", "ArcadePulseImmersiveFeedStyle.playGradient",
                      "ArcadePulseTheme.playHeight", 'accessibilityIdentifier("game.play")',
                      "Button(action: action)", "contrast == .increased"):
            self.assertIn(token, cta)


if __name__ == "__main__":
    unittest.main()
