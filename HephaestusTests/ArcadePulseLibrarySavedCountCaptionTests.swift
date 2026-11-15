import SwiftUI
import Testing
@testable import Hephaestus

/// Independent source regression for truthful Library count labels.
/// This separate Swift Testing file is picked up by the Xcode file-system
/// synchronized HephaestusTests target without editing its project file.
struct ArcadePulseLibrarySavedCountCaptionTests {
    @Test func arcadePulseLibrarySavedCountCaptionNamesRealCurrentViewerState() {
        let signedOut = LibrarySavedCountCaption.presentation(
            confirmedCount: nil, signedIn: false, loading: true)
        #expect(signedOut.visibleText == "Sign in")
        #expect(signedOut.accessibilityLabel.contains("Sign in"))
        #expect(!signedOut.visibleText.contains("0"))
        let loading = LibrarySavedCountCaption.presentation(
            confirmedCount: nil, signedIn: true, loading: true)
        #expect(loading.visibleText == "Loading")
        #expect(loading.accessibilityLabel == "Loading saved-game count")
        let failed = LibrarySavedCountCaption.presentation(
            confirmedCount: nil, signedIn: true, loading: false)
        #expect(failed.visibleText == "Unavailable")
        #expect(failed.accessibilityLabel == "Saved games count unavailable")
        let trueEmpty = LibrarySavedCountCaption.presentation(
            confirmedCount: 0, signedIn: true, loading: false)
        #expect(trueEmpty.visibleText == "0")
        #expect(trueEmpty.accessibilityLabel == "0 saved games")
        let positive = LibrarySavedCountCaption.presentation(
            confirmedCount: 8, signedIn: true, loading: false)
        #expect(positive.visibleText == "8")
        #expect(positive.accessibilityLabel == "8 saved games")
        // Revoked or loading sessions cannot reveal a retained old count.
        #expect(LibrarySavedCountCaption.presentation(
            confirmedCount: 8, signedIn: false, loading: false).visibleText == "Sign in")
        #expect(LibrarySavedCountCaption.presentation(
            confirmedCount: 8, signedIn: true, loading: true).visibleText == "Loading")
        // An unknown total must remain distinct from confirmed zero.
        #expect(failed.visibleText != trueEmpty.visibleText)
    }

    @Test func libraryCountStacksAtAccessibilitySizesAndCompactXXL() {
        for size in [DynamicTypeSize.accessibility1, .accessibility2, .accessibility3,
                     .accessibility4, .accessibility5] {
            #expect(LibrarySavedCountLayout.stacks(for: size, compact: true))
            #expect(LibrarySavedCountLayout.stacks(for: size, compact: false))
        }
        #expect(LibrarySavedCountLayout.stacks(for: .xxLarge, compact: true))
        #expect(LibrarySavedCountLayout.stacks(for: .xxxLarge, compact: true))
        #expect(!LibrarySavedCountLayout.stacks(for: .large, compact: true))
        #expect(!LibrarySavedCountLayout.stacks(for: .xxLarge, compact: false))
    }

}
