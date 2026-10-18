import Foundation

/// Backend configuration for the Hephaestus iOS app.
///
/// Points at the DoodleQuest game-generation backend (Go). After adding this
/// file to the Xcode project, use `BackendConfig.baseURL` for API calls and
/// `BackendConfig.playerURL` for the WKWebView player.
enum BackendConfig {
    /// Production backend (Replit deployment).
    static let baseURL = URL(
        string: "https://html-5-game-generator.replit.app"
    )!

    /// Local development override — uncomment to run against a local server.
    // static let baseURL = URL(string: "http://localhost:8080")!

    /// The web player (game list + inline HTML5 player).
    /// Load in WKWebView.
    static var playerURL: URL {
        baseURL.appendingPathComponent("player")
    }

    /// User identity sent as the `X-User-ID` header. Stub for Sign in with
    /// Apple — the parent account owns creations.
    static let userID = "demo-parent"

    /// GameSpec questionnaire + engine decision maker.
    static var specQuestionnaireURL: URL {
        baseURL.appendingPathComponent("v1/spec/questionnaire")
    }
}
