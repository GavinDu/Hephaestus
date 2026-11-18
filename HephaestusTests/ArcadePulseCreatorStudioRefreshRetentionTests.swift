import Testing
import Foundation
@testable import Hephaestus

/// Pure source constraints only. No real account tokens, private project
/// payloads, generator games or synthetic accepted backend results.
struct ArcadePulseCreatorStudioRefreshRetentionTests {
    private let owner = "fixture-owner-only"
    private let firstToken = "fixture-token-a"
    private let secondToken = "fixture-token-b"

    private func allows(
        hasRows: Bool = true,
        storedOwner: String? = "fixture-owner-only",
        currentOwner: String = "fixture-owner-only",
        previousToken: String? = "fixture-token-a",
        currentToken: String? = "fixture-token-a",
        previousFilter: String? = "all",
        currentFilter: String = "all"
    ) -> Bool {
        CreatorStudioRefreshRetentionPolicy.mayRetain(
            hasConfirmedProjects: hasRows,
            storedOwner: storedOwner, currentOwner: currentOwner,
            storedCredentialDigest: CreatorStudioRefreshRetentionPolicy.digest(previousToken),
            currentCredentialDigest: CreatorStudioRefreshRetentionPolicy.digest(currentToken),
            storedFilter: previousFilter, currentFilter: currentFilter
        )
    }

    @Test func sameOwnerCredentialAndFilterMayRetainRealConfirmedRows() {
        #expect(allows())
        #expect(allows(previousFilter: "ready", currentFilter: "ready"))
        #expect(!allows(hasRows: false))
    }

    @Test func otherOwnerOrCredentialAlwaysRevokesPriorRows() {
        #expect(!allows(currentOwner: "another-account"))
        #expect(!allows(currentOwner: ""))
        #expect(!allows(storedOwner: nil))
        #expect(!allows(currentToken: secondToken))
        #expect(!allows(previousToken: nil))
        #expect(!allows(currentToken: nil))
    }

    @Test func changingFilterCannotDisplayWrongProjects() {
        #expect(!allows(previousFilter: "draft", currentFilter: "ready"))
        #expect(!allows(previousFilter: nil, currentFilter: "all"))
    }

    @Test func tokenFingerprintDoesNotRetainRawBearerCredential() {
        let digest = CreatorStudioRefreshRetentionPolicy.digest(firstToken)
        #expect(digest != nil)
        #expect(digest != firstToken)
        #expect(digest == CreatorStudioRefreshRetentionPolicy.digest(firstToken))
        #expect(digest != CreatorStudioRefreshRetentionPolicy.digest(secondToken))
        #expect(CreatorStudioRefreshRetentionPolicy.digest(nil) == nil)
        #expect(CreatorStudioRefreshRetentionPolicy.digest("") == nil)
    }

    @Test func unauthorizedServerResponsesRequireImmediateVisibleRevocation() {
        #expect(CreatorStudioErrorPresentation.mustRevokeVisibleProjects(
            for: APIError.badStatus(401)
        ))
        #expect(CreatorStudioErrorPresentation.mustRevokeVisibleProjects(
            for: APIError.badStatus(403)
        ))
        #expect(!CreatorStudioErrorPresentation.mustRevokeVisibleProjects(
            for: APIError.badStatus(429)
        ))
        #expect(!CreatorStudioErrorPresentation.mustRevokeVisibleProjects(
            for: URLError(.timedOut)
        ))
    }
}
