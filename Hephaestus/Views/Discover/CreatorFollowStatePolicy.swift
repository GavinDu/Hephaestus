import Foundation

/// A Follow POST may have reached the server even if its response is lost.
/// Only an authenticated, non-owner viewer may mutate, and any ambiguous
/// result requires an authoritative GET before another tap.
enum CreatorFollowStatePolicy {
    static func offersFollow(viewerID: String, creatorID: String) -> Bool {
        let viewer = viewerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let creator = creatorID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !viewer.isEmpty && !creator.isEmpty && viewer != creator
    }

    static func canSubmit(viewerID: String, creatorID: String,
                          isUpdating: Bool, needsConfirmation: Bool) -> Bool {
        offersFollow(viewerID: viewerID, creatorID: creatorID) &&
            !isUpdating && !needsConfirmation
    }

    /// A stale GET, changed viewer or GET started during another mutation
    /// cannot certify the current account's following relationship.
    static func mayApplyCreatorRead(
        requestRevision: Int, currentRevision: Int, sameViewer: Bool,
        startedWhileMutating: Bool, isPostWriteConfirmation: Bool
    ) -> Bool {
        requestRevision == currentRevision && sameViewer &&
            (!startedWhileMutating || isPostWriteConfirmation)
    }
}

/// Backend error bodies, raw URLs, bearer tokens and server job identifiers
/// are never valid native creator-profile or Follow presentation text.
enum CreatorProfileErrorPresentation {
    enum Action { case load, follow }

    static func message(for error: Error, action: Action) -> String {
        let guidance = action == .follow
            ? "Follow status is unconfirmed. Refresh to check before trying again."
            : "Try again to refresh this creator."
        if let api = error as? APIError, case let .badStatus(status) = api {
            switch status {
            case 401:
                return "Sign in again from Profile. " + guidance
            case 403:
                return "This creator action isn't permitted for your account. " + guidance
            case 429:
                return "Too many requests. Try again in a little while. " + guidance
            default:
                break
            }
        }
        if let network = error as? URLError {
            switch network.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "You're offline. Reconnect and try again. " + guidance
            case .secureConnectionFailed, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot:
                return "A secure connection couldn't be established. " + guidance
            case .timedOut:
                return "The creator service is taking too long. " + guidance
            default:
                break
            }
        }
        return "The creator service isn't available right now. " + guidance
    }
}
