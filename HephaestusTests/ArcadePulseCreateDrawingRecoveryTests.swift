import Testing
@testable import Hephaestus

/// A lost HTTP response may mean work was accepted by the server. The only
/// permitted local recovery is to reveal the exact selected image and let
/// the person decide whether to submit a new analysis request.
struct ArcadePulseCreateDrawingRecoveryTests {
    @Test func analysisErrorWithActualDrawingCanReturnToEditor() {
        #expect(CreateDrawingRecoveryPolicy.canEditOriginalDrawing(
            after: .imageAnalysis, hasImageData: true, hasDecodedPreview: true
        ))
    }

    @Test func absentOrInvalidDrawingCannotPromisePreservation() {
        #expect(!CreateDrawingRecoveryPolicy.canEditOriginalDrawing(
            after: .imageAnalysis, hasImageData: false, hasDecodedPreview: true
        ))
        #expect(!CreateDrawingRecoveryPolicy.canEditOriginalDrawing(
            after: .imageAnalysis, hasImageData: true, hasDecodedPreview: false
        ))
        #expect(!CreateDrawingRecoveryPolicy.canEditOriginalDrawing(
            after: .imageAnalysis, hasImageData: false, hasDecodedPreview: false
        ))
    }

    @Test func uncertainAnalysisIsDisclosedBeforeAnotherManualPost() {
        let notice = CreateDrawingRecoveryPolicy.manualRetryNotice(
            priorAnalysisOutcomeUnconfirmed: true, hasSourceImage: true
        )
        #expect(notice != nil)
        #expect(notice?.contains("may have reached the service") == true)
        #expect(notice?.contains("starts a new request") == true)
        #expect(notice?.contains("does not resume") == true)
        // A fresh image or an explicit reset must not inherit stale
        // uncertainty from a completely different source selection.
        #expect(CreateDrawingRecoveryPolicy.manualRetryNotice(
            priorAnalysisOutcomeUnconfirmed: false, hasSourceImage: true
        ) == nil)
        #expect(CreateDrawingRecoveryPolicy.manualRetryNotice(
            priorAnalysisOutcomeUnconfirmed: true, hasSourceImage: false
        ) == nil)
    }

    @Test func failedAnalysisCannotDisplayRawProviderDiagnostics() {
        let message = CreateDrawingRecoveryPolicy.safeAnalysisFailureMessage
        let rawProviderURL = "https://private.example.invalid/ingest?token=SECRET-DO-NOT-SHOW"
        #expect(!message.contains(rawProviderURL))
        #expect(!message.contains("SECRET-DO-NOT-SHOW"))
        #expect(message.contains("Couldn't confirm"))
        #expect(message.contains("still on this device"))
    }

    @Test func failedRemoteWriteOrPollingMustNotOfferAutomaticResubmit() {
        for hasImage in [false, true] {
            for hasPreview in [false, true] {
                #expect(!CreateDrawingRecoveryPolicy.canEditOriginalDrawing(
                    after: .uncertainRemoteWork,
                    hasImageData: hasImage,
                    hasDecodedPreview: hasPreview
                ))
            }
        }
    }
}
