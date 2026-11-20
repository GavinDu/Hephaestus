import CoreFoundation
import CoreGraphics
import Testing
@testable import Hephaestus

/// Real server-fed result count only. These tests do not add fictitious
/// published games, creators, media, or social actions.
struct GameGridSingleResultLayoutTests {
    private func shouldCenter(
        count: Int = 1,
        query: String = "ribbon",
        iPad: Bool = true,
        regular: Bool = true
    ) -> Bool {
        GameGridSingleResultLayout.centers(
            resultCount: count,
            searchText: query,
            isPad: iPad,
            isRegularWidth: regular
        )
    }

    @Test func oneActualFilteredResultCentersOnWideIPad() {
        #expect(shouldCenter())
        #expect(shouldCenter(query: "  ribbon  "))
        #expect(GameGridSingleResultLayout.maximumCardWidth == CGFloat(520))
    }

    @Test func zeroOrMultipleRealResultsKeepHonestGridOrEmptyState() {
        #expect(!shouldCenter(count: 0))
        #expect(!shouldCenter(count: 2))
        #expect(!shouldCenter(count: 20))
    }

    @Test func unfilteredFeedNeverFabricatesASearchLayout() {
        #expect(!shouldCenter(query: ""))
        #expect(!shouldCenter(query: "  \t\n "))
    }

    @Test func phonesAndCompactIPadStageManagerKeepNativeResponsiveGrid() {
        #expect(!shouldCenter(iPad: false))
        #expect(!shouldCenter(iPad: false, regular: false))
        #expect(!shouldCenter(regular: false))
    }
}
