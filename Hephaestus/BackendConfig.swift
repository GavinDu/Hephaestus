import Foundation
import Security

extension Notification.Name {
    /// No token or account details are included in this notification.
    static let hephaestusBackendSessionDidChange =
        Notification.Name("HephaestusBackendSessionDidChange")
}

/// Backend configuration for the Hephaestus iOS app.
///
/// Base URL for the Game IR package and game-generation APIs.
enum BackendConfig {
    /// Production backend (Replit deployment).
    static let baseURL = URL(
        string: "https://html-5-game-generator.replit.app"
    )!

    /// Local development override — uncomment to run against a local server.
    // static let baseURL = URL(string: "http://localhost:8080")!

    /// Display-only development identity. Production requests derive identity
    /// from a verified bearer token, never from a caller-controlled user ID.
    static let userID = "demo-parent"

    /// Explicit opt-in for local development only. Keep false in shipped builds.
    static let usesDevelopmentIdentity = false

    /// Best-effort local subject decoding for UI affordances only. The server
    /// remains the authority and verifies the token signature and expiry.
    static var currentUserID: String {
        guard let token = loadSessionToken(),
              let encodedPayload = token.split(separator: ".", omittingEmptySubsequences: false).first else {
            return usesDevelopmentIdentity ? userID : ""
        }
        var payload = String(encodedPayload)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = object["sub"] as? String,
              !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return usesDevelopmentIdentity ? userID : ""
        }
        return subject
    }

    private static let tokenService = Bundle.main.bundleIdentifier ?? "Hephaestus"
    private static let tokenAccount = "backend-bearer-token"

    /// Session tokens are stored in Keychain rather than UserDefaults.
    static func loadSessionToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    @discardableResult
    static func saveSessionToken(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        let previousToken = loadSessionToken()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: tokenAccount
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        let saved: Bool
        if status == errSecSuccess {
            saved = true
        } else if status == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            saved = SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        } else {
            return false
        }
        // Successful credential replacement invalidates every cached player
        // page. Never include token bytes, account ID, or token digest in
        // the notification, log or telemetry.
        if saved && previousToken != token {
            NotificationCenter.default.post(name: .hephaestusBackendSessionDidChange, object: nil)
        }
        return saved
    }

    static func clearSessionToken() {
        let hadSession = loadSessionToken() != nil
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: tokenAccount
        ]
        let result = SecItemDelete(query as CFDictionary)
        if hadSession && (result == errSecSuccess || result == errSecItemNotFound) {
            NotificationCenter.default.post(name: .hephaestusBackendSessionDidChange, object: nil)
        }
    }

    /// Attach a verified bearer session; the legacy identity header is
    /// sent only after explicit source-level opt-in for local development.
    static func applyAuthentication(to request: inout URLRequest) {
        if let token = loadSessionToken() {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        } else if usesDevelopmentIdentity {
            request.setValue(userID, forHTTPHeaderField: "X-User-ID")
        }
    }

    /// GameSpec questionnaire + engine decision maker.
    static var specQuestionnaireURL: URL {
        baseURL.appendingPathComponent("v1/spec/questionnaire")
    }
}
