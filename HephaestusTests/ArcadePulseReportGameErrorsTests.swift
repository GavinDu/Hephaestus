import Foundation
import Testing
@testable import Hephaestus

/// The real moderation server owns report status; these tests cover
/// presentation truthfulness, never a fake accepted receipt.
struct ArcadePulseReportGameErrorsTests {
    @Test func reportErrorsNeverExposePrivateTransportInformation() {
        let sensitive = NSError(
            domain: "https://private.moderation.local/report",
            code: 503,
            userInfo: [NSLocalizedDescriptionKey:
                "https://private.moderation.local?token=privateReporter bearer hidden"]
        )
        let unknown = ReportGameErrorPresentation.message(for: sensitive)
        #expect(unknown.contains("Couldn't confirm"))
        for secret in ["private.moderation.local", "privateReporter", "bearer", "hidden", "503"] {
            #expect(!unknown.contains(secret))
        }
    }

    @Test func reportErrorsDistinguishKnownDenialsFromUnknownPostReceipt() {
        #expect(ReportGameErrorPresentation.message(
            for: APIError.badStatus(400)).contains("wasn't accepted"))
        #expect(ReportGameErrorPresentation.message(
            for: APIError.badStatus(401)).contains("Profile"))
        #expect(ReportGameErrorPresentation.message(
            for: APIError.badStatus(403)).contains("isn't permitted"))
        #expect(ReportGameErrorPresentation.message(
            for: APIError.badStatus(429)).contains("little while"))
        #expect(ReportGameErrorPresentation.message(
            for: URLError(.timedOut)).contains("whether your report was received"))
        let tls = ReportGameErrorPresentation.message(for: URLError(.secureConnectionFailed))
        #expect(tls.contains("secure connection"))
        #expect(!tls.localizedCaseInsensitiveContains("certificate"))
        #expect(ReportGameErrorPresentation.message(
            for: URLError(.notConnectedToInternet)).localizedCaseInsensitiveContains("offline"))
    }
}
