import Foundation
import SwiftUI
import Testing
@testable import Hephaestus

/// Pure privacy/error-copy regression coverage; native account identity and
/// moderation status must come from genuine backend acknowledgments.
struct ArcadePulseProfileErrorRebaseTests {
    @Test func arcadePulseProfileErrorsNeverExposeAppleOrAccountSecrets() {
        let privateError = NSError(
            domain: "https://private.auth.local/accounts/owner",
            code: 503,
            userInfo: [NSLocalizedDescriptionKey:
                "https://private.auth.local?apple_identity_token=privateAppleToken bearer=hiddenOwner"]
        )
        let actions: [ProfileErrorPresentation.Action] = [
            .appleSignIn, .accountDeletion, .moderationAppeal
        ]
        for action in actions {
            let presented = ProfileErrorPresentation.message(for: privateError, action: action)
            for secret in ["private.auth.local", "privateAppleToken", "hiddenOwner",
                           "bearer", "503"] {
                #expect(!presented.contains(secret))
            }
            #expect(!presented.isEmpty)
        }
        let delete = ProfileErrorPresentation.message(for: privateError, action: .accountDeletion)
        #expect(delete.contains("Couldn't confirm"))
        #expect(!delete.contains("deleted successfully"))
        let appeal = ProfileErrorPresentation.message(for: privateError, action: .moderationAppeal)
        #expect(appeal.contains("Couldn't confirm"))
        #expect(!appeal.contains("Appeal submitted"))
    }

    @Test func arcadePulseProfileErrorsExplainAuthAndModerationUncertainty() {
        #expect(ProfileErrorPresentation.message(
            for: APIError.badStatus(401), action: .appleSignIn).contains("Profile"))
        #expect(ProfileErrorPresentation.message(
            for: APIError.badStatus(403), action: .accountDeletion).contains("isn't permitted"))
        #expect(ProfileErrorPresentation.message(
            for: APIError.badStatus(429), action: .moderationAppeal).contains("Too many"))
        let offline = ProfileErrorPresentation.message(
            for: URLError(.notConnectedToInternet), action: .accountDeletion)
        #expect(offline.localizedCaseInsensitiveContains("offline"))
        let secure = ProfileErrorPresentation.message(
            for: URLError(.secureConnectionFailed), action: .appleSignIn)
        #expect(secure.contains("secure connection"))
        #expect(!secure.localizedCaseInsensitiveContains("certificate"))
        let slowDelete = ProfileErrorPresentation.message(
            for: URLError(.timedOut), action: .accountDeletion)
        #expect(slowDelete.contains("whether account deletion completed"))
        let slowAppeal = ProfileErrorPresentation.message(
            for: URLError(.timedOut), action: .moderationAppeal)
        #expect(slowAppeal.contains("whether your appeal was received"))
        let apple = ProfileErrorPresentation.message(
            for: NSError(domain: "ASAuthorizationErrorDomain", code: 1001),
            action: .appleSignIn)
        #expect(apple.contains("Apple sign-in"))
    }
}
