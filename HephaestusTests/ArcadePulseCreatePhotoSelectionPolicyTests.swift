import Testing
@testable import Hephaestus

/// No test writes private photo bytes or relies on an artificial backend
/// game. Source ownership is represented by monotonic transfer generations.
struct ArcadePulseCreatePhotoSelectionPolicyTests {
    @Test func newestDecodedImageMayBeInstalledBeforeNewConsent() {
        #expect(CreatePhotoSelectionPolicy.mayCommitLoadedImage(
            requestEpoch: 4, currentEpoch: 4,
            hasBytes: true, hasDecodedPreview: true, wasCancelled: false
        ))
    }

    @Test func oldTransferCannotOverwriteNewerSelection() {
        #expect(!CreatePhotoSelectionPolicy.mayCommitLoadedImage(
            requestEpoch: 4, currentEpoch: 5,
            hasBytes: true, hasDecodedPreview: true, wasCancelled: false
        ))
    }

    @Test func cancelledTransferCannotReappearAfterReset() {
        #expect(!CreatePhotoSelectionPolicy.mayCommitLoadedImage(
            requestEpoch: 5, currentEpoch: 6,
            hasBytes: true, hasDecodedPreview: true, wasCancelled: true
        ))
        #expect(!CreatePhotoSelectionPolicy.mayCommitLoadedImage(
            requestEpoch: 5, currentEpoch: 5,
            hasBytes: true, hasDecodedPreview: true, wasCancelled: true
        ))
    }

    @Test func nilOrUndecodablePhotoCannotEnableUpload() {
        #expect(!CreatePhotoSelectionPolicy.mayCommitLoadedImage(
            requestEpoch: 7, currentEpoch: 7,
            hasBytes: false, hasDecodedPreview: false, wasCancelled: false
        ))
        #expect(!CreatePhotoSelectionPolicy.mayCommitLoadedImage(
            requestEpoch: 7, currentEpoch: 7,
            hasBytes: true, hasDecodedPreview: false, wasCancelled: false
        ))
    }
}
