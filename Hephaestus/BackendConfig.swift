import Foundation
import Security

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
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var insert = query
        attributes.forEach { insert[$0.key] = $0.value }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func clearSessionToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: tokenService,
            kSecAttrAccount as String: tokenAccount
        ]
        SecItemDelete(query as CFDictionary)
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
