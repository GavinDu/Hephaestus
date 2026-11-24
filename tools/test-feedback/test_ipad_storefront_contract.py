"""Source guards for the actual iPad Storefront, never invented feed content."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]

class StorefrontContractTests(unittest.TestCase):
    def test_actual_page_uses_public_feed_and_existing_selection(self):
        s = (ROOT / "Hephaestus/Views/Discover/DiscoverView.swift").read_text()
        for token in ("ForYouPageLayout.storefrontIDs(", "loadedIDs: games.map(\\.id)",
                      "guard scope == .forYou, selectedGame?.id == game.id",
                      "settledGameID = id", "feed.ipad.storefront",
                      "Games in your current For You feed", "item.playStarts",
                      "No other games loaded yet.", "item.previewPosterURL"):
            self.assertIn(token, s)
        panel = s.split("private var ipadStorefrontPanel:", 1)[1].split("var body: some View", 1)[0]
        self.assertNotIn("BackendAPI.shared", panel)
        self.assertNotIn("Trending", panel)

if __name__ == "__main__":
    unittest.main()
