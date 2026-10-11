import Foundation

/// Backend configuration for the Hephaestus iOS app.
///
/// Points at the DoodleQuest game-generation backend (Go). After adding this
/// file to the Xcode project, use `BackendConfig.baseURL` for API calls and
/// `BackendConfig.playerURL` for the WKWebView player.
enum BackendConfig {
    /// Production backend (Replit-hosted).
    static let baseURL = URL(
        string: "https://7ca9cb63-0317-4dd0-b084-5ef4df88cdaf-00-1i3fhaijkqyg1.riker.replit.dev"
    )!

    /// Local development override — uncomment to run against a local server.
    // static let baseURL = URL(string: "http://localhost:8080")!

    /// The web player (game list + inline HTML5 player + Godot versions).
    /// Load in WKWebView.
    static var playerURL: URL {
        baseURL.appendingPathComponent("player")
    }

    /// User identity sent as the `X-User-ID` header. Stub for Sign in with
    /// Apple — the parent account owns creations.
    static let userID = "demo-parent"

    /// Godot web builds served by the backend (`GET /v1/godot` lists them).
    static var godotListURL: URL {
        baseURL.appendingPathComponent("v1/godot")
    }

    /// GameSpec questionnaire + engine decision maker.
    static var specQuestionnaireURL: URL {
        baseURL.appendingPathComponent("v1/spec/questionnaire")
    }
}
