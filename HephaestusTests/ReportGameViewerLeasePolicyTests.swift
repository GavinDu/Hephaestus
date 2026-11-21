import Testing
@testable import Hephaestus

/// Pure lease checks only; tests never create a public game/account,
/// invoke the live moderation endpoint or fabricate a successful report.
struct ReportGameViewerLeasePolicyTests {
    @Test func currentViewerAndEpochOwnModerationResponse() {
        #expect(ReportGameViewerLeasePolicy.mayApply(
            initiatingViewerID: "viewer-a", currentViewerID: "viewer-a",
            initiatingEpoch: 4, currentEpoch: 4
        ))
    }

    @Test func switchingAccountsRevokesOldReportCompletion() {
        #expect(!ReportGameViewerLeasePolicy.mayApply(
            initiatingViewerID: "viewer-a", currentViewerID: "viewer-b",
            initiatingEpoch: 4, currentEpoch: 4
        ))
    }

    @Test func signOutRevokesOldReportCompletion() {
        #expect(!ReportGameViewerLeasePolicy.mayApply(
            initiatingViewerID: "viewer-a", currentViewerID: "",
            initiatingEpoch: 4, currentEpoch: 4
        ))
    }

    @Test func sameViewerReauthenticatedCannotConsumeOldResponse() {
        #expect(!ReportGameViewerLeasePolicy.mayApply(
            initiatingViewerID: "viewer-a", currentViewerID: "viewer-a",
            initiatingEpoch: 4, currentEpoch: 5
        ))
    }

    @Test func guestSessionRestartAlsoRevokesResponse() {
        #expect(ReportGameViewerLeasePolicy.mayApply(
            initiatingViewerID: "", currentViewerID: "",
            initiatingEpoch: 7, currentEpoch: 7
        ))
        #expect(!ReportGameViewerLeasePolicy.mayApply(
            initiatingViewerID: "", currentViewerID: "",
            initiatingEpoch: 7, currentEpoch: 8
        ))
    }
}
