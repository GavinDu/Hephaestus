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

    @Test func loadedPublicIDsOnlyInOrderNoDuplicatesOrActivePage() {
        #expect(ForYouPageLayout.storefrontIDs(scope: .forYou, selectedID: "a",
                    loadedIDs: ["a", "b", "", "b", "c", "d", "e"]) == ["b", "c", "d"])
        #expect(ForYouPageLayout.storefrontIDs(scope: .forYou, selectedID: "a",
                    loadedIDs: ["a"]).isEmpty)
    }
}
