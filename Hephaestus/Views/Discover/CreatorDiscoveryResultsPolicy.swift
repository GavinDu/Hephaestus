import Foundation

/// Truthfulness rules for a real Creator Discovery GET. These decisions
/// distinguish a failed new query from a confirmed empty directory, without
/// fabricating or discarding the last backend-confirmed creator rows.
enum CreatorDiscoveryResultsPolicy {
    static func sectionTitle(resultsMatchCurrentSearch: Bool) -> String {
        resultsMatchCurrentSearch ? "Creators" : "Previous results"
    }

    static func showsEmptyMessage(isLoading: Bool,
                                  hasResults: Bool,
                                  hasError: Bool) -> Bool {
        !isLoading && !hasResults && !hasError
    }

    static func allowsNextPage(resultsMatchCurrentSearch: Bool,
                               hasNextCursor: Bool,
                               isLoading: Bool) -> Bool {
        resultsMatchCurrentSearch && hasNextCursor && !isLoading
    }
    /// Never offer a cursor-only retry for an auth/permission failure,
    /// malformed JSON, or a redirect. These require a new authorized query
    /// or deployment repair, not repeated use of the same cursor.
    static func isTransientPageFailure(_ error: Error) -> Bool {
        if let api = error as? APIError {
            if case let .badStatus(status) = api {
                return status == 429 || (500...599).contains(status)
            }
            return false
        }
        if let network = error as? URLError {
            switch network.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Retry only the failed page from an unchanged, backend-confirmed
    /// query. A fresh search, edited draft or superseded cursor must instead
    /// use the ordinary first-page search. Never invent a cursor.
    static func canRetryFailedPage(
        failedCursor: String?,
        nextCursor: String?,
        resultsMatchCurrentSearch: Bool,
        draftMatchesAppliedQuery: Bool
    ) -> Bool {
        guard resultsMatchCurrentSearch,
              draftMatchesAppliedQuery,
              let failedCursor,
              !failedCursor.isEmpty,
              failedCursor == nextCursor else { return false }
        return true
    }
}
