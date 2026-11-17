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
