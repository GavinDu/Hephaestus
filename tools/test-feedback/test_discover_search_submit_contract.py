"""Source contract for actual native Discover search, not a simulated feed."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DiscoverSearchSubmitContractTests(unittest.TestCase):
    def test_one_native_and_explicit_commit_owner(self):
        s = (ROOT / "Hephaestus/Views/Discover/DiscoverView.swift").read_text()
        self.assertIn('.onSubmit(of: .search, onSubmitSearch)', s)
        self.assertIn('onSubmitSearch: commitDiscoverSearch', s)
        self.assertIn('Button(action: commitDiscoverSearch)', s)
        self.assertIn('feed.grid.applySearch', s)
        fn = s.split("private func commitDiscoverSearch()", 1)[1].split(
            "private var activeSearchQuery", 1)[0]
        self.assertLess(fn.index("committedSearchQuery = searchText"),
                        fn.index("UIResponder.resignFirstResponder"))
        self.assertIn("feed.grid.clearSearch", s)

    def test_original_strict_native_menu_assertions_preserved(self):
        s = (ROOT / "HephaestusUITests/PlayerSmokeTests.swift").read_text()
        test = s.split("func testArcadePulseRealGridMoreMenuReadOnly()", 1)[1].split(
            "func testArcadePulseGameGridSocialActionsHaveTrue44ptTargets()", 1)[0]
        for required in ("keyboardSearch.tap()", "XCTAssertFalse(app.keyboards.firstMatch.exists",
                         "XCTAssertFalse(apply.exists", "grid.game.social.more",
                         "more.tap()", "XCTAssertTrue(notInterested.exists && notInterested.isHittable)",
                         "XCTAssertTrue(report.exists && report.isHittable)",
                         "arcade-pulse-real-grid-native-search-keyboard-remained"):
            self.assertIn(required, test)


if __name__ == "__main__":
    unittest.main()
