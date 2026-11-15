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
}
