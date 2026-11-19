import SwiftUI
import Testing
@testable import Hephaestus

/// Pure layout selection only. An authenticated Studio screen and native
/// iPhone/iPad/VoiceOver evidence must be verified separately under #268/#269.
struct ArcadePulseCreatorStudioProjectFilterLayoutTests {
    @Test func compactPhoneUsesNativeMenuAtOrdinaryAndMaximumType() {
        #expect(CreatorStudioProjectFilterLayout.usesMenu(
            horizontalSizeClass: .compact, dynamicTypeSize: .medium
        ))
        #expect(CreatorStudioProjectFilterLayout.usesMenu(
            horizontalSizeClass: .compact, dynamicTypeSize: .accessibility5
        ))
    }

    @Test func regularIPadKeepsSegmentsAtOrdinaryType() {
        #expect(!CreatorStudioProjectFilterLayout.usesMenu(
            horizontalSizeClass: .regular, dynamicTypeSize: .medium
        ))
        #expect(!CreatorStudioProjectFilterLayout.usesMenu(
            horizontalSizeClass: .regular, dynamicTypeSize: .xLarge
        ))
    }

    @Test func regularIPadCollapsesBeforeVeryLargeTextCrowdsFiveSegments() {
        #expect(CreatorStudioProjectFilterLayout.usesMenu(
            horizontalSizeClass: .regular, dynamicTypeSize: .xxLarge
        ))
        #expect(CreatorStudioProjectFilterLayout.usesMenu(
            horizontalSizeClass: .regular, dynamicTypeSize: .xxxLarge
        ))
    }

    @Test func largeTextIPadUsesNativeMenuInsteadOfClippingSegments() {
        #expect(CreatorStudioProjectFilterLayout.usesMenu(
            horizontalSizeClass: .regular, dynamicTypeSize: .accessibility1
        ))
        #expect(CreatorStudioProjectFilterLayout.usesMenu(
            horizontalSizeClass: .regular, dynamicTypeSize: .accessibility5
        ))
    }

    @Test func unknownWindowSizeFallsBackToReachableMenu() {
        #expect(CreatorStudioProjectFilterLayout.usesMenu(
            horizontalSizeClass: nil, dynamicTypeSize: .medium
        ))
    }
}
