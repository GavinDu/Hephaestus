import Foundation
import Testing
@testable import Hephaestus

/// Source-contract tests: no live owner, private run, network access or
/// fabricated published game is needed to validate local diagnostic privacy.
struct BackendAPIDiagnosticPolicyTests {
    @Test func sharedTransportLogsNeverPrintPrivatePathQueryHostOrNSErrorText() {
        let secret = "privateBearerRunGameCreator_12345"
        let hostileError = NSError(
            domain: "https://internal.example.test/" + secret,
            code: 503,
            userInfo: [
                NSLocalizedDescriptionKey: "token=" + secret + " private owner URL"
            ]
        )
        #expect(BackendAPIDiagnosticPolicy.transportFailure(for: hostileError) == .other)

        let pathKinds: [(String, String)] = [
            ("/v1/runs/" + secret + "/result", "run"),
            ("/v1/games/" + secret + "/save", "game"),
            ("/v1/users/" + secret + "/follow", "account"),
            ("/v1/creators/" + secret, "creator"),
            ("/v1/jobs/" + secret, "job"),
            ("/v1/feed", "feed"),
            ("/v1/ingest", "ingest"),
            ("/healthz", "health"),
            ("/private/" + secret, "other")
        ]

        for (path, expectedCategory) in pathKinds {
            let endpoint = URL(string:
                "https://user:" + secret + "@internal.example.test" + path +
                "?token=" + secret + "&owner=" + secret
            )!
            #expect(BackendAPIDiagnosticPolicy.routeBucket(for: endpoint) == expectedCategory)
            let outcomes: [BackendAPIDiagnosticPolicy.Outcome] = [
                .success(status: 200, bytes: 42),
                .rejected(status: 403),
                .decoding,
                .transport(BackendAPIDiagnosticPolicy.transportFailure(for: hostileError))
            ]
            for outcome in outcomes {
                let message = BackendAPIDiagnosticPolicy.message(
                    httpMethod: "GET", endpoint: endpoint,
                    elapsedMilliseconds: 24, outcome: outcome
                )
                #expect(!message.contains(secret))
                #expect(!message.contains("internal.example.test"))
                #expect(!message.contains("user:"))
                #expect(!message.contains("token="))
                #expect(!message.contains(path))
                #expect(!message.localizedCaseInsensitiveContains("owner="))
            }
        }
    }

    @Test func sharedTransportLogsBoundNumericFieldsAndClassifyOnlyKnownErrors() {
        let url = URL(string: "https://api.example.test/v1/feed")!
        let formatter = BackendAPIDiagnosticPolicy.self
        let bounded = formatter.message(
            httpMethod: "POST", endpoint: url, elapsedMilliseconds: Int.max,
            outcome: .success(status: Int.max, bytes: Int.max)
        )
        #expect(bounded == "POST feed -> 999 (600000ms, 100000000 B)")
        #expect(formatter.message(
            httpMethod: "UNKNOWN secret", endpoint: nil, elapsedMilliseconds: Int.min,
            outcome: .rejected(status: Int.min)
        ) == "OTHER other -> -1 (0ms)")
        #expect(formatter.message(
            httpMethod: "GET", endpoint: url, elapsedMilliseconds: -1,
            outcome: .decoding
        ) == "GET feed decode_failed (0ms)")
        let failures: [(URLError.Code, BackendAPIDiagnosticPolicy.TransportFailure)] = [
            (.timedOut, .timeout),
            (.notConnectedToInternet, .offline),
            (.cancelled, .cancelled),
            (.networkConnectionLost, .interrupted),
            (.cannotFindHost, .interrupted),
            (.cannotConnectToHost, .interrupted)
        ]
        for (code, category) in failures {
            #expect(formatter.transportFailure(for: URLError(code)) == category)
        }
        #expect(formatter.transportFailure(for: URLError(.badURL)) == .other)
    }

    @Test func sharedTransportLogsRedact160HostileDynamicRequests() {
        for iteration in 0..<160 {
            let unique = "private_game_\(iteration)_opaque"
            let endpoint = URL(string:
                "https://internal.example.test/v1/runs/" + unique +
                "/result?secret=" + unique + "&authorization=hidden"
            )!
            let badMethods: [String?] = ["POST/" + unique, "GET\n" + unique, nil]
            for badMethod in badMethods {
                let message = BackendAPIDiagnosticPolicy.message(
                    httpMethod: badMethod, endpoint: endpoint,
                    elapsedMilliseconds: iteration, outcome: .transport(.other)
                )
                #expect(message == "OTHER run transport_other (\(iteration)ms)")
                #expect(!message.contains(unique))
                #expect(!message.contains("internal.example.test"))
            }
        }
    }
}
