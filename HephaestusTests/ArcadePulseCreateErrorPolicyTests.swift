import Foundation
import Testing
@testable import Hephaestus

/// Safe user-facing Create failures without leaked generator text or fake publication receipts.
struct ArcadePulseCreateErrorPolicyTests {
    @Test func arcadePulseCreateErrorCopyNeverLeaksProviderSecrets() {
        let sensitive = NSError(
            domain: "https://private.generator.local/v1/jobs",
            code: 503,
            userInfo: [NSLocalizedDescriptionKey:
                "https://private.generator.local?token=secretArtworkKey auth=hiddenAccount"]
        )
        let stages: [CreateErrorPresentation.Stage] = [
            .analyze, .generate, .poll, .confirm, .publish
        ]
        for stage in stages {
            let result = CreateErrorPresentation.message(for: sensitive, stage: stage)
            for secret in ["private.generator.local", "secretArtworkKey",
                           "hiddenAccount", "503", "auth="] {
                #expect(!result.contains(secret))
            }
            #expect(!result.isEmpty)
        }
        #expect(CreateErrorPresentation.failedJobMessage()
            .contains("game generator reported"))
        #expect(!CreateErrorPresentation.failedJobMessage().contains("job_id"))
        let unknownPublish = CreateErrorPresentation.message(
            for: sensitive, stage: .publish)
        #expect(unknownPublish.contains("Couldn't confirm"))
        #expect(unknownPublish.contains("My Projects"))
        #expect(!unknownPublish.contains("Submitted for moderation"))
    }

    @Test func arcadePulseCreateStagesExplainActualFailuresWithoutRawNetworkText() {
        let timeout = CreateErrorPresentation.message(
            for: URLError(.timedOut), stage: .publish)
        #expect(timeout.contains("whether your game was submitted"))
        #expect(!timeout.localizedCaseInsensitiveContains("timed out"))
        // A lost connection during POST may have submitted successfully;
        // never instruct a duplicate public publish without reconciliation.
        for interrupted in [URLError(.networkConnectionLost),
                            URLError(.notConnectedToInternet),
                            URLError(.secureConnectionFailed)] {
            let ambiguous = CreateErrorPresentation.message(
                for: interrupted, stage: .publish)
            #expect(ambiguous.contains("Couldn't confirm"))
            #expect(ambiguous.contains("My Projects"))
            #expect(!ambiguous.contains("Submitted for moderation"))
        }
        let offline = CreateErrorPresentation.message(
            for: URLError(.notConnectedToInternet), stage: .analyze)
        #expect(offline.localizedCaseInsensitiveContains("offline"))
        let tls = CreateErrorPresentation.message(
            for: URLError(.secureConnectionFailed), stage: .generate)
        #expect(tls.contains("secure connection"))
        #expect(!tls.localizedCaseInsensitiveContains("certificate"))
        let expired = CreateErrorPresentation.message(
            for: APIError.badStatus(401), stage: .poll)
        #expect(expired.contains("Profile"))
        let forbidden = CreateErrorPresentation.message(
            for: APIError.badStatus(403), stage: .confirm)
        #expect(forbidden.contains("isn't permitted"))
        let limited = CreateErrorPresentation.message(
            for: APIError.badStatus(429), stage: .publish)
        #expect(limited.contains("Too many requests"))
        let generic = CreateErrorPresentation.message(
            for: NSError(domain: "server", code: 500), stage: .generate)
        #expect(generic.contains("Game generation"))
    }

}
