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

/// Both the navigation search field and topic Apply use one host-owned
/// request gate. A disabled visible Apply button must not remain actionable
/// through a keyboard Search submit while a real GET is pending.
enum CreatorQuerySubmitPolicy {
    static func canSubmit(isLoading: Bool) -> Bool {
        !isLoading
    }
}
