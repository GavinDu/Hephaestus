import Foundation
import Testing
@testable import Hephaestus

/// #608: a load-failure error is untrusted. Neither its NSError properties nor
/// the current game identity may enter free-form on-device DevLog records.
struct PlayerLoadFailureLocalLogPrivacyTests {
    @Test func localLogUsesOnlyExplicitSafeErrorCategories() {
        let privateID = "owner-private-game-with-auth-token"
        let privateURL = "https://private.example.invalid/v1/games/\(privateID)?bearer=never-log"
        let metadata: [String: Any] = [
            NSLocalizedDescriptionKey: "private game \(privateID) at \(privateURL)",
            NSLocalizedFailureReasonErrorKey: "Authorization bearer very-private-token",
            NSURLErrorFailingURLStringErrorKey: privateURL
        ]
        let foreign = NSError(domain: "creator-private-domain-\(privateID)",
                              code: 91, userInfo: metadata)
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                              userInfo: metadata)
        let forbidden = NSError(domain: PlayerLoadFailure.httpErrorDomain,
                                code: 403, userInfo: metadata)
        let messages = [
            PlayerLoadFailure.safeLocalLogMessage(for: foreign),
            PlayerLoadFailure.safeLocalLogMessage(for: timeout),
            PlayerLoadFailure.safeLocalLogMessage(for: forbidden)
        ]
        #expect(messages[0] == "player load failed: other_error category=unknown")
        #expect(messages[1] ==
                "player load failed: url_error_code=\(NSURLErrorTimedOut) category=network")
        #expect(messages[2] == "player load failed: http_status=403 category=accessDenied")
        for message in messages {
            #expect(message.count < 100)
            #expect(!message.contains(privateID))
            #expect(!message.contains(privateURL))
            #expect(!message.contains("private-domain"))
            #expect(!message.contains("Authorization"))
            #expect(!message.contains("bearer"))
            #expect(!message.contains("very-private-token"))
        }
    }

    @Test func localLogRejects160UntrustedDescriptionsAndInvalidCodes() {
        for index in 0..<160 {
            let secret = "owner-game-secret-\(index)"
            let userInfo: [String: Any] = [
                NSLocalizedDescriptionKey: "token=\(secret)",
                NSURLErrorFailingURLStringErrorKey: "https://untrusted.invalid/\(secret)"
            ]
            let code = index.isMultiple(of: 2) ? Int.max : Int.min
            let hostile = NSError(domain: "http://hostile.invalid/\(secret)",
                                  code: code, userInfo: userInfo)
            let local = PlayerLoadFailure.safeLocalLogMessage(for: hostile)
            #expect(local == "player load failed: other_error category=unknown")
            #expect(!local.contains(secret))
            #expect(!local.contains("token="))
            #expect(!local.contains("http"))
            #expect(local.count < 100)
        }
    }
}
