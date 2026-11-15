import Foundation

/// Never surface raw URLSession/moderation exception bodies in accessible UI.
/// Missing replies may be ambiguous: moderation might have received the POST.
enum ReportGameErrorPresentation {
    static func message(for error: Error) -> String {
        if let api = error as? APIError, case let .badStatus(status) = api {
            switch status {
            case 400:
                return "The report wasn't accepted. Review its details and try again."
            case 401:
                return "Your session has expired. Sign in again from Profile, then retry."
            case 403:
                return "This account isn't permitted to submit the report."
            case 429:
                return "Too many reports have been sent. Try again in a little while."
            default: break
            }
        }
        if let network = error as? URLError {
            switch network.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "You're offline. Your report wasn't confirmed. Reconnect before retrying."
            case .secureConnectionFailed, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot:
                return "A secure connection couldn't be established. Your report wasn't confirmed."
            case .timedOut:
                return "Couldn't confirm whether your report was received. The request took too long."
            default: break
            }
        }
        return "Couldn't confirm whether your report was received. Review the details before retrying."
    }
}
