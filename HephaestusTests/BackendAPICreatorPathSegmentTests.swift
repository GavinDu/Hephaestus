import Foundation
import Testing
@testable import Hephaestus

/// Source-only creator path tests: no fake game, account or live backend.
/// The backend still authorizes all real profile, Follow and Block requests.
struct BackendAPICreatorPathSegmentTests {
    @Test func creatorPathSegmentPreservesSupportedOpaqueNamespacedIds() {
        let good: [(String, String)] = [
            ("a", "a"),
            ("creator-123_ABC", "creator-123_ABC"),
            ("apple:privateSubject", "apple%3AprivateSubject"),
            ("auth0|subject", "auth0%7Csubject"),
            ("google-oauth2|123", "google-oauth2%7C123"),
            ("github:123@id", "github%3A123%40id"),
            ("user.name~2", "user.name~2"),
            (String(repeating: "a", count: 128),
             String(repeating: "a", count: 128))
        ]
        for (creatorID, expected) in good {
            let segment = BackendAPICreatorPathSegmentPolicy.encoded(creatorID)
            #expect(segment == expected)
            let url = URL(string: "https://api.example.test/v1/users/\(expected)/follow")!
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            #expect(components?.percentEncodedPath == "/v1/users/\(expected)/follow")
            #expect(components?.query == nil)
            #expect(components?.fragment == nil)
        }
    }

    @Test func creatorPathSegmentRejectsMalformedOpaqueIdentity() {
        let bad = [
            "", ".", "..", "../me", "me/profile", "me\\profile",
            "owner?admin=1", "owner#fragment", "owner%2Fother",
            "auth0%7Csubject", "my creator", " creator", "creator\n",
            "owner\tname", "user+other", "user&admin", "é", "中",
            "private:123/", String(repeating: "a", count: 129)
        ]
        for creatorID in bad {
            #expect(BackendAPICreatorPathSegmentPolicy.encoded(creatorID) == nil)
        }
    }

    @MainActor @Test func malformedCreatorIdsFailBeforeAnyRequestAcross160Variants() async {
        for index in 0..<160 {
            let privateID = "owner_private_\(index)"
            // Every input is malformed and must be refused *before*
            // makeRequest/authentication/URLSession/network execution.
            let bad = index.isMultiple(of: 2)
                ? privateID + "/../me"
                : privateID + "?access_token=private"
            #expect(BackendAPICreatorPathSegmentPolicy.encoded(bad) == nil)
            do {
                try await BackendAPI.shared.setFollowing(bad, following: true)
                Issue.record("Unexpected Follow request for invalid creator path.")
            } catch APIError.invalidInput(let message) {
                #expect(message == "Invalid creator identifier.")
                #expect(!message.contains(privateID))
            } catch {
                Issue.record("Invalid Follow ID failed after request construction.")
            }
            do {
                try await BackendAPI.shared.blockCreator(bad, blocked: true)
                Issue.record("Unexpected Block request for invalid creator path.")
            } catch APIError.invalidInput(let message) {
                #expect(message == "Invalid creator identifier.")
                #expect(!message.contains(privateID))
            } catch {
                Issue.record("Invalid Block ID failed after request construction.")
            }
            do {
                _ = try await BackendAPI.shared.fetchCreatorProfile(id: bad)
                Issue.record("Unexpected profile request for invalid creator path.")
            } catch APIError.invalidInput(let message) {
                #expect(message == "Invalid creator identifier.")
                #expect(!message.contains(privateID))
            } catch {
                Issue.record("Invalid Profile ID failed after request construction.")
            }
        }
    }
}
