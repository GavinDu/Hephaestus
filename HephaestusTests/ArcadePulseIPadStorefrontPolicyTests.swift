import Foundation
import Testing
@testable import Hephaestus

struct ArcadePulseIPadStorefrontPolicyTests {
    @Test func spaciousPublicIPadKeepsAtLeast55PercentMedia() {
        for width in [CGFloat(1240), 1320, 1408, 1600] {
            #expect(ForYouPageLayout.showsIPadStorefront(
                width: width, height: 820, isIPad: true, isRegular: true,
                isLargeText: false, scope: .forYou))
            #expect(ForYouPageLayout.storefrontStageWidth(containerWidth: width) / width >= 0.55)
            #expect(ForYouPageLayout.storefrontStageWidth(containerWidth: width) +
                    2 * ForYouPageLayout.storefrontPanelWidth(containerWidth: width) + 48 <= width)
        }
    }

    @Test func narrowShortLargeTextAndPrivateScopesCollapse() {
        #expect(!ForYouPageLayout.showsIPadStorefront(width: 1199, height: 820, isIPad: true, isRegular: true, isLargeText: false, scope: .forYou))
        #expect(!ForYouPageLayout.showsIPadStorefront(width: 1408, height: 650, isIPad: true, isRegular: true, isLargeText: false, scope: .forYou))
        #expect(!ForYouPageLayout.showsIPadStorefront(width: 1408, height: 820, isIPad: true, isRegular: true, isLargeText: true, scope: .forYou))
        #expect(!ForYouPageLayout.showsIPadStorefront(width: 1408, height: 820, isIPad: false, isRegular: true, isLargeText: false, scope: .forYou))
        #expect(!ForYouPageLayout.showsIPadStorefront(width: 1408, height: 820, isIPad: true, isRegular: false, isLargeText: false, scope: .forYou))
        for scope in [SocialFeedScope.following, .friends] {
            #expect(!ForYouPageLayout.showsIPadStorefront(width: 1408, height: 820, isIPad: true, isRegular: true, isLargeText: false, scope: scope))
            #expect(ForYouPageLayout.storefrontIDs(scope: scope, selectedID: "a", loadedIDs: ["a", "b"]).isEmpty)
        }
    }

    @Test func invalidPublishedIDsAreNeverExposedOrSelected() {
        let invalid = ["", " ", " bad", "bad ", "bad/id", "bad\nID", "bad\u{0000}id"]
        let loaded = ["a"] + invalid + ["b", "c", "d", "e"]
        #expect(ForYouPageLayout.storefrontIDs(scope: .forYou, selectedID: "a",
                    loadedIDs: loaded) == ["b", "c", "d"])
        for id in invalid {
            #expect(!ForYouPageLayout.canSelectStorefrontGame(
                scope: .forYou, displayedID: "a", currentSelectedID: "a",
                targetID: id, loadedIDs: loaded))
        }
    }

    @Test func selectionRequiresCurrentPageAndCurrentBoundedSubset() {
        let loaded = ["a", "b", "c", "d", "e"]
        #expect(ForYouPageLayout.canSelectStorefrontGame(
            scope: .forYou, displayedID: "a", currentSelectedID: "a",
            targetID: "b", loadedIDs: loaded))
        #expect(!ForYouPageLayout.canSelectStorefrontGame(
            scope: .forYou, displayedID: "a", currentSelectedID: "c",
            targetID: "b", loadedIDs: loaded))
        for id in ["a", "e", "missing"] {
            #expect(!ForYouPageLayout.canSelectStorefrontGame(
                scope: .forYou, displayedID: "a", currentSelectedID: "a",
                targetID: id, loadedIDs: loaded))
        }
        #expect(!ForYouPageLayout.canSelectStorefrontGame(
            scope: .friends, displayedID: "a", currentSelectedID: "a",
            targetID: "b", loadedIDs: loaded))
    }

    @Test func loadedPublicIDsOnlyInOrderNoDuplicatesOrActivePage() {
        #expect(ForYouPageLayout.storefrontIDs(scope: .forYou, selectedID: "a",
                    loadedIDs: ["a", "b", "", "b", "c", "d", "e"]) == ["b", "c", "d"])
        #expect(ForYouPageLayout.storefrontIDs(scope: .forYou, selectedID: "a",
                    loadedIDs: ["a"]).isEmpty)
    }
}
