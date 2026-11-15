import Foundation
import SwiftUI
import Testing
@testable import Hephaestus

/// Rebased creator Follow API ownership tests. Real iPhone/iPad authenticated
/// server evidence stays independently gated under Epic #172 issue #266.
struct ArcadePulseCreatorFollowRebaseTests {
    @Test func arcadePulseCreatorFollowStateRequiresServerConfirmation() {
        #expect(!CreatorFollowStatePolicy.offersFollow(viewerID: "", creatorID: "creator"))
        #expect(!CreatorFollowStatePolicy.offersFollow(viewerID: "owner", creatorID: "owner"))
        #expect(!CreatorFollowStatePolicy.offersFollow(viewerID: "owner", creatorID: ""))
        #expect(!CreatorFollowStatePolicy.offersFollow(viewerID: "viewer", creatorID: " \t "))
        #expect(!CreatorFollowStatePolicy.offersFollow(viewerID: " \n ", creatorID: "creator"))
        #expect(!CreatorFollowStatePolicy.offersFollow(viewerID: "owner", creatorID: " owner "))
        #expect(CreatorFollowStatePolicy.offersFollow(viewerID: "viewer", creatorID: "creator"))
        #expect(CreatorFollowStatePolicy.canSubmit(
            viewerID: "viewer", creatorID: "creator",
            isUpdating: false, needsConfirmation: false))
        #expect(!CreatorFollowStatePolicy.canSubmit(
            viewerID: "viewer", creatorID: "creator",
            isUpdating: true, needsConfirmation: false))
        #expect(!CreatorFollowStatePolicy.canSubmit(
            viewerID: "viewer", creatorID: "creator",
            isUpdating: false, needsConfirmation: true))
    }

    @Test func arcadePulseCreatorGetCannotClearAmbiguousFollowFromStaleRead() {
        #expect(CreatorFollowStatePolicy.mayApplyCreatorRead(
            requestRevision: 7, currentRevision: 7, sameViewer: true,
            startedWhileMutating: false, isPostWriteConfirmation: false))
        #expect(!CreatorFollowStatePolicy.mayApplyCreatorRead(
            requestRevision: 6, currentRevision: 7, sameViewer: true,
            startedWhileMutating: false, isPostWriteConfirmation: false))
        #expect(!CreatorFollowStatePolicy.mayApplyCreatorRead(
            requestRevision: 7, currentRevision: 7, sameViewer: false,
            startedWhileMutating: false, isPostWriteConfirmation: true))
        #expect(!CreatorFollowStatePolicy.mayApplyCreatorRead(
            requestRevision: 7, currentRevision: 7, sameViewer: true,
            startedWhileMutating: true, isPostWriteConfirmation: false))
        #expect(CreatorFollowStatePolicy.mayApplyCreatorRead(
            requestRevision: 7, currentRevision: 7, sameViewer: true,
            startedWhileMutating: true, isPostWriteConfirmation: true))
    }

    @Test func arcadePulseCreatorProfileErrorsArePrivacySafe() {
        let sensitive = NSError(
            domain: "https://private.creator.local/owner",
            code: 503,
            userInfo: [NSLocalizedDescriptionKey:
                "https://private.creator.local/token=secretCreator bearer=hidden"]
        )
        let load = CreatorProfileErrorPresentation.message(for: sensitive, action: .load)
        let follow = CreatorProfileErrorPresentation.message(for: sensitive, action: .follow)
        #expect(load.localizedCaseInsensitiveContains("try again"))
        #expect(follow.localizedCaseInsensitiveContains("unconfirmed"))
        for secret in ["private.creator.local", "secretCreator", "hidden", "503", "bearer"] {
            #expect(!load.contains(secret))
            #expect(!follow.contains(secret))
        }
        #expect(CreatorProfileErrorPresentation.message(
            for: APIError.badStatus(403), action: .follow).contains("isn't permitted"))
        #expect(CreatorProfileErrorPresentation.message(
            for: APIError.badStatus(401), action: .load).contains("Profile"))
        #expect(CreatorProfileErrorPresentation.message(
            for: APIError.badStatus(429), action: .follow).contains("Too many requests"))
        let tls = CreatorProfileErrorPresentation.message(
            for: URLError(.secureConnectionFailed), action: .load)
        #expect(tls.contains("secure connection"))
        #expect(!tls.localizedCaseInsensitiveContains("certificate"))
        #expect(CreatorProfileErrorPresentation.message(
            for: URLError(.timedOut), action: .follow).contains("taking too long"))
        #expect(CreatorProfileErrorPresentation.message(
            for: URLError(.notConnectedToInternet), action: .follow).contains("offline"))
    }


    @Test func creatorFollowForegroundMeetsNormalTextContrast() {
        #expect(ArcadePulseTheme.electricVioletContrastWithBlack >= 4.5)
    }

}
