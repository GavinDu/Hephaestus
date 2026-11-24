"""Source guards for the actual iPad Storefront, never invented feed content."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]

class StorefrontContractTests(unittest.TestCase):
    def test_actual_page_uses_public_feed_and_existing_selection(self):
        s = (ROOT / "Hephaestus/Views/Discover/DiscoverView.swift").read_text()
        for token in ("ForYouPageLayout.storefrontIDs(", "loadedIDs: games.map(\\.id)",
                      "ForYouPageLayout.canSelectStorefrontGame(", "currentSelectedID: selectedGame?.id",
                      "settledGameID = id", "feed.ipad.storefront",
                      "Games in your current For You feed", "item.playStarts",
                      "No other games loaded yet.", "item.previewPosterURL"):
            self.assertIn(token, s)
        panel = s.split("private var ipadStorefrontPanel:", 1)[1].split("var body: some View", 1)[0]
        self.assertNotIn("BackendAPI.shared", panel)
        self.assertNotIn("Trending", panel)

    def test_identity_policy_is_shared_by_row_admission_and_selection(self):
        layout = (ROOT / "Hephaestus/Views/Discover/ForYouPageLayout.swift").read_text()
        self.assertIn("for id in loadedIDs where PublishedGameIDPolicy.valid(id)", layout)
        selection = layout.split("static func canSelectStorefrontGame(", 1)[1].split("static func contextPanelWidth", 1)[0]
        self.assertIn("currentSelectedID == displayedID", selection)
        self.assertIn("PublishedGameIDPolicy.valid(targetID)", selection)
        self.assertIn("storefrontIDs(scope: scope", selection)
        self.assertIn(".contains(targetID)", selection)

if __name__ == "__main__":
    unittest.main()
