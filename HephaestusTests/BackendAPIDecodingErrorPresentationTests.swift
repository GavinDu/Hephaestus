import Foundation
import Testing
@testable import Hephaestus

/// Decode errors still fail normally; only their unsafe user-facing copy is
/// fixed. No real game/backend, app login or private fixture is constructed.
struct BackendAPIDecodingErrorPresentationTests {
    @Test func decodeErrorsHaveOneActionableNonIdentifyingMessage() {
        let expected = "Couldn't read the backend reply. Please try again."
        let underlying: [Error] = [
            NSError(
                domain: "https://private.example.test/v1/runs/privateRun",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey:
                    "secret=privateBearer; creator=hidden; game=unpublished"]
            ),
            URLError(.badServerResponse),
            DecodingError.dataCorrupted(
                .init(codingPath: [],
                      debugDescription:
                          "private owner URL, server field and token must not render")
            )
        ]
        for error in underlying {
            let displayed = APIError.decoding(error).localizedDescription
            #expect(displayed == expected)
            #expect(!displayed.contains("private"))
            #expect(!displayed.contains("secret"))
            #expect(!displayed.contains("token"))
            #expect(!displayed.contains("http"))
        }
    }

    @Test func oneHundredSixtyHostileDecodeErrorsCannotChangePresentation() {
        for index in 0..<160 {
            let secret = "privateCreator_RunToken_\(index)"
            let error = NSError(
                domain: "https://private.example.test/" + secret,
                code: index,
                userInfo: [NSLocalizedDescriptionKey:
                    "Owner private URL?token=" + secret]
            )
            let message = APIError.decoding(error).localizedDescription
            #expect(message == "Couldn't read the backend reply. Please try again.")
            #expect(!message.contains(secret))
            #expect(!message.contains("private.example.test"))
            #expect(!message.contains("Owner"))
        }
    }

    @Test func statusAndExistingValidatedInputErrorsRetainTheirBehavior() {
        #expect(APIError.badStatus(403).localizedDescription ==
                "Backend returned HTTP 403.")
        #expect(APIError.invalidInput("Invalid game identifier.").localizedDescription ==
                "Invalid game identifier.")
    }
}
