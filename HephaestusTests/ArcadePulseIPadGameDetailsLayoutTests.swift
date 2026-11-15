import SwiftUI
import Testing
@testable import Hephaestus

/// Bounded native layout policy tests for the real adaptive iPad Game Details.
/// Full decoded poster and device signoff remain separate acceptance #264.
struct ArcadePulseIPadGameDetailsLayoutTests {
    @Test func arcadePulseIPadGameDetailsKeepsMediaAndActionsReadable() {
        #expect(ForYouPageLayout.showsIPadGameDetailsTwoColumn(
            width: 1_366, height: 1_024, isRegular: true, isLargeText: false))
        #expect(ForYouPageLayout.showsIPadGameDetailsTwoColumn(
            width: 1_194, height: 834, isRegular: true, isLargeText: false))
        // Portrait, compact Split View, short Stage Manager and high text
        // must have one readable scrolling detail column, not clipped media.
        #expect(!ForYouPageLayout.showsIPadGameDetailsTwoColumn(
            width: 1_024, height: 1_366, isRegular: true, isLargeText: false))
        #expect(!ForYouPageLayout.showsIPadGameDetailsTwoColumn(
            width: 860, height: 700, isRegular: true, isLargeText: false))
        #expect(!ForYouPageLayout.showsIPadGameDetailsTwoColumn(
            width: 1_366, height: 600, isRegular: true, isLargeText: false))
        #expect(!ForYouPageLayout.showsIPadGameDetailsTwoColumn(
            width: 1_366, height: 1_024, isRegular: true, isLargeText: true))
        #expect(!ForYouPageLayout.showsIPadGameDetailsTwoColumn(
            width: 1_366, height: 1_024, isRegular: false, isLargeText: false))
        for width: CGFloat in [960, 1_024, 1_194, 1_366] {
            let media = ForYouPageLayout.gameDetailsPreviewWidth(containerWidth: width)
            let content = min(width - 36, 1_200)
            let metadata = content - media - 24
            #expect(media >= 480)
            #expect(metadata >= 350)
            #expect(media + metadata + 24 <= content)
        }
        #expect(ForYouPageLayout.gameDetailsPreviewWidth(containerWidth: 20) == 0)
        // Landscape must only expand genuinely decoded source artwork;
        // a failed/loading/missing image must stay compact and truthful.
        #expect(ForYouPageLayout.gameDetailsPreviewHeight(
            containerHeight: 1_000, hasDecodedPoster: true) == 640)
        #expect(ForYouPageLayout.gameDetailsPreviewHeight(
            containerHeight: 760, hasDecodedPoster: true) >= 550)
        #expect(ForYouPageLayout.gameDetailsPreviewHeight(
            containerHeight: 620, hasDecodedPoster: true) >= 450)
        #expect(ForYouPageLayout.gameDetailsPreviewHeight(
            containerHeight: 1_000, hasDecodedPoster: false) == 335)
        #expect(ForYouPageLayout.gameDetailsPreviewHeight(
            containerHeight: 620, hasDecodedPoster: false) <= 250)
        #expect(ForYouPageLayout.gameDetailsPreviewHeight(
            containerHeight: 0, hasDecodedPoster: false) == 0)
        #expect(ForYouPageLayout.gameDetailsPreviewHeight(
            containerHeight: 0, hasDecodedPoster: true) == 0)
        // Native Share is now black on solid violet, never low-contrast
        // violet on purple in the actual iPad details view.
        #expect(ArcadePulseTheme.electricVioletContrastWithBlack >= 4.5)
        // Genuine decoded artwork can use the otherwise wasted portrait iPad
        // viewport. Missing posters stay compact, never upscale fake media.
        let largePoster = ForYouPageLayout.gameDetailsSingleColumnPreviewHeight(
            containerWidth: 1_024, containerHeight: 1_366,
            isIPad: true, isRegularWidth: true,
            hasDecodedPoster: true, isLargeText: false)
        #expect(largePoster >= 680)
        #expect(largePoster <= 720)
        let missingPoster = ForYouPageLayout.gameDetailsSingleColumnPreviewHeight(
            containerWidth: 1_024, containerHeight: 1_366,
            isIPad: true, isRegularWidth: true,
            hasDecodedPoster: false, isLargeText: false)
        #expect(missingPoster == 335)
        let xxlPoster = ForYouPageLayout.gameDetailsSingleColumnPreviewHeight(
            containerWidth: 1_024, containerHeight: 1_366,
            isIPad: true, isRegularWidth: true,
            hasDecodedPoster: true, isLargeText: true)
        #expect(xxlPoster <= 360)
        let narrowFallback = ForYouPageLayout.gameDetailsSingleColumnPreviewHeight(
            containerWidth: 430, containerHeight: 800,
            isIPad: true, isRegularWidth: false,
            hasDecodedPoster: false, isLargeText: false)
        #expect(narrowFallback == 240)
        let iPhonePoster = ForYouPageLayout.gameDetailsSingleColumnPreviewHeight(
            containerWidth: 390, containerHeight: 844,
            isIPad: false, isRegularWidth: false,
            hasDecodedPoster: true, isLargeText: false)
        #expect(iPhonePoster == 240)
    }

}
