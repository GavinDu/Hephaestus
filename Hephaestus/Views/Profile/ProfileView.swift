import AuthenticationServices
import SwiftUI
import UIKit

// MARK: - Profile

/// Native Profile actions can return sensitive AuthServices/URLSession errors.
/// Never expose raw provider URLs, Apple identifiers, account tokens or the
/// server's exception text to the visible accessibility hierarchy.
enum ProfileErrorPresentation {
    enum Action { case appleSignIn, accountDeletion, moderationAppeal }

    static func message(for error: Error, action: Action) -> String {
        if let api = error as? APIError, case let .badStatus(status) = api {
            switch status {
            case 400:
                return "Please review the information and try again."
            case 401:
                return "Your session has expired. Sign in again from Profile."
            case 403:
                return "This account isn't permitted to complete the action."
            case 429:
                return "Too many requests. Try again in a little while."
            default: break
            }
        }
        if let network = error as? URLError {
            switch network.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "You're offline. Reconnect and check the current account status."
            case .secureConnectionFailed, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot:
                return "A secure connection couldn't be established. Check your network."
            case .timedOut:
                switch action {
                case .appleSignIn:
                    return "Apple sign-in is taking too long. Try again from Profile."
                case .accountDeletion:
                    return "Couldn't confirm whether account deletion completed. Check the account before retrying."
                case .moderationAppeal:
                    return "Couldn't confirm whether your appeal was received. Check moderation status before retrying."
                }
            default: break
            }
        }
        switch action {
        case .appleSignIn:
            return "Apple sign-in couldn't be completed. Try again from Profile."
        case .accountDeletion:
            return "Couldn't confirm whether account deletion completed. Check the account before retrying."
        case .moderationAppeal:
            return "Couldn't confirm whether your appeal was received. Check moderation status before retrying."
        }
    }
}

struct ProfileView: View {
    @State private var backendOK = false
    @State private var checked = false
    @State private var logEntries = DevLog.shared.count
    @AppStorage(PlayerQuality.defaultsKey) private var qualityRaw = PlayerQuality.auto.rawValue
    @State private var isModerationAppealPresented = false
    @State private var tokenDraft = BackendConfig.loadSessionToken() ?? ""
    @State private var sessionMessage: String?
    @State private var isDeleteAccountPresented = false

    private func signInWithAppleToken(_ identityToken: String) async {
        do {
            let response = try await BackendAPI.shared.signInWithApple(identityToken: identityToken)
            guard BackendConfig.saveSessionToken(response.access_token) else {
                sessionMessage = "Could not save the session securely to Keychain."
                return
            }
            tokenDraft = response.access_token
            sessionMessage = "Signed in with Apple. Session valid for 30 days."
            DevLog.info(.api, "signed in with Apple")
        } catch {
            sessionMessage = ProfileErrorPresentation.message(for: error, action: .appleSignIn)
            DevLog.error(.api, "Apple sign-in exchange failed; see redacted error category")
        }
    }

    private func deleteAccount() async {
        do {
            _ = try await BackendAPI.shared.deleteAccount()
            BackendConfig.clearSessionToken()
            tokenDraft = ""
            sessionMessage = "Account deleted. Your social data was removed."
            DevLog.info(.api, "account deleted")
        } catch {
            sessionMessage = ProfileErrorPresentation.message(for: error, action: .accountDeletion)
            DevLog.error(.api, "account deletion confirmation unavailable")
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    HStack {
                        Text("Session")
                        Spacer()
                        Label(BackendConfig.currentUserID.isEmpty ? "Not connected" : "Connected",
                              systemImage: BackendConfig.currentUserID.isEmpty ? "person.crop.circle.badge.xmark" : "checkmark.shield.fill")
                            .font(.subheadline)
                            .foregroundStyle(BackendConfig.currentUserID.isEmpty ? Color.secondary : Color.green)
                    }
                    if BackendConfig.currentUserID.isEmpty {
                        SignInWithAppleButton(.signIn) { request in
                            // Identity only: no name or email scope is requested.
                            // The backend sees just an opaque Apple identifier.
                            request.requestedScopes = []
                        } onCompletion: { result in
                            switch result {
                            case .success(let authorization):
                                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                                      let data = credential.identityToken,
                                      let identityToken = String(data: data, encoding: .utf8) else {
                                    sessionMessage = "Apple sign-in did not return an identity token."
                                    return
                                }
                                Task { await signInWithAppleToken(identityToken) }
                            case .failure(let error):
                                sessionMessage = ProfileErrorPresentation.message(
                                    for: error, action: .appleSignIn)
                                DevLog.error(.api, "Apple authentication attempt did not complete")
                            }
                        }
                        .signInWithAppleButtonStyle(.black)
                        .frame(height: 44)
                        .accessibilityLabel("Sign in with Apple")
                        Text("Sign in with Apple to publish, follow, and save. No name or email is requested; the backend only sees an opaque Apple identifier, and sessions last 30 days.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Button("Sign out", role: .destructive) {
                                BackendConfig.clearSessionToken()
                                tokenDraft = ""
                                sessionMessage = "Session cleared from this device."
                                DevLog.info(.api, "session cleared")
                            }
                            .buttonStyle(.bordered)
                            Button("Delete account", role: .destructive) {
                                isDeleteAccountPresented = true
                            }
                            .buttonStyle(.bordered)
                        }
                        .alert("Delete account?", isPresented: $isDeleteAccountPresented) {
                            Button("Delete account", role: .destructive) {
                                Task { await deleteAccount() }
                            }
                            Button("Keep account", role: .cancel) {}
                        } message: {
                            Text("This removes your follows, saves, reactions, comments, and preferences, and signs you out. Published games stay published under an opaque identifier that carries no personal data. This cannot be undone.")
                        }
                    }
                    if BackendConfig.usesDevelopmentIdentity {
                        SecureField("Short-lived session token (development only)", text: $tokenDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Session token")
                        Button("Save session") {
                            let token = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !token.isEmpty else {
                                sessionMessage = "Enter a session token first."
                                return
                            }
                            guard BackendConfig.saveSessionToken(token) else {
                                sessionMessage = "Could not save the session securely to Keychain."
                                return
                            }
                            tokenDraft = token
                            sessionMessage = "Session saved securely."
                            DevLog.info(.api, "session saved to Keychain")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let sessionMessage {
                        Text(sessionMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("session-status")
                    }
                }
                Section("Safety & moderation") {
                    Button {
                        isModerationAppealPresented = true
                    } label: {
                        Label("Appeal a moderation decision", systemImage: "exclamationmark.bubble")
                    }
                    Text("Use this if one of your games was rejected or quarantined. Appeals are reviewed by a moderator and do not automatically restore publication.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Backend") {
                    HStack {
                        Text("Status")
                        Spacer()
                        if checked {
                            Text(backendOK ? "Connected" : "Unreachable")
                                .foregroundStyle(backendOK ? .green : .red)
                        } else {
                            ProgressView()
                        }
                    }
                    HStack {
                        Text("Server")
                        Spacer()
                        Text(BackendConfig.baseURL.host ?? "")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Diagnostics") {
                    HStack {
                        Text("Session log")
                        Spacer()
                        Text("\(logEntries) entries")
                            .foregroundStyle(.secondary)
                    }
                    Button("Copy session log") {
                        UIPasteboard.general.string = DevLog.shared.exportText()
                        DevLog.info(.app, "session log copied (\(DevLog.shared.count) entries)")
                        logEntries = DevLog.shared.count
                    }
                    ShareLink(item: DevLog.shared.exportText()) {
                        Text("Share session log")
                    }
                    // Test-feedback export (docs/TESTING_FRAMEWORK.md §6):
                    // the structured JSON twin of the text log, for the
                    // AI coding feedback loop. Sharing it files the
                    // current session as a test-feedback artifact input:
                    // DevLog JSON (with run_id when a test run set one)
                    // plus the session header. Verified by the CI xcode
                    // job — see the repo's verification route.
                    Button("Copy test feedback (JSON)") {
                        UIPasteboard.general.string = DevLog.shared.exportJSON() ?? "test feedback unavailable"
                        DevLog.info(.app, "test feedback JSON copied")
                    }
                    ShareLink(item: DevLog.shared.exportJSON() ?? "test feedback unavailable") {
                        Text("Share test feedback (JSON)")
                    }
                    Button("Clear log", role: .destructive) {
                        DevLog.shared.clear()
                        logEntries = DevLog.shared.count
                    }
                }
                Section("Player health") {
                    HStack {
                        Text("Quality")
                        Spacer()
                        Text("\(qualityRaw) → \(PlayerQuality.effective(preference: PlayerQuality(rawValue: qualityRaw) ?? .auto))")
                            .foregroundStyle(.secondary)
                    }
                    Text("Server-wide incident aggregates are restricted to operators and are not fetched by the app. If you encounter a player issue, copy or share the session log above only after removing private information.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $isModerationAppealPresented) {
                ModerationAppealSheet()
            }

            .navigationTitle("Profile")
            .onAppear { logEntries = DevLog.shared.count }
            .task {
                await BackendAPI.shared.checkHealth()
                backendOK = BackendAPI.shared.isHealthy
                checked = true
            }
        }
    }

}


private struct ModerationAppealSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var gameID = ""
    @State private var reason = ""
    @State private var contact: BackendAPI.ModerationContactResponse?
    @State private var isSubmitting = false
    @State private var message: String?
    @State private var didSubmit = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Game") {
                    TextField("Game ID", text: $gameID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Why should this decision be reviewed?") {
                    TextEditor(text: $reason)
                        .frame(minHeight: 120)
                    Text("\(reason.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count)/1000 Unicode characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Text("Only the creator can appeal a rejected or quarantined game. Submitting an appeal adds it to the moderator queue; it does not republish the game.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let contact {
                    Section("Moderation contact") {
                        if !contact.contact_email.isEmpty {
                            LabeledContent("Email", value: contact.contact_email)
                                .textSelection(.enabled)
                        }
                        if !contact.contact_url.isEmpty, let url = URL(string: contact.contact_url) {
                            Link("Open moderation contact", destination: url)
                        }
                        if !contact.external_contact_configured {
                            Text("No external contact channel is configured. You can still submit an in-app appeal.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let message {
                    Section {
                        Text(message)
                            .foregroundStyle(didSubmit ? .green : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("profile.moderation.appealStatus")
                    }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Label("Submit appeal", systemImage: "paperplane")
                        }
                    }
                    .frame(minHeight: 48)
                    .accessibilityIdentifier("profile.moderation.submitAppeal")
                    .disabled(isSubmitting || gameID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              reason.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count > 1000 || didSubmit)
                }
            }
            .navigationTitle("Moderation appeal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadContact() }
        }
    }

    private func loadContact() async {
        do { contact = try await BackendAPI.shared.fetchModerationContact() }
        catch { /* Contact configuration is optional; appeal submission remains available. */ }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let result = try await BackendAPI.shared.submitModerationAppeal(
                gameID: gameID.trimmingCharacters(in: .whitespacesAndNewlines),
                reason: reason
            )
            didSubmit = true
            message = "Appeal submitted (\(result.appeal_id)). Status: \(result.status)."
        } catch {
            // The submit POST may have reached moderation before the
            // response was lost. Never fabricate a failed or accepted receipt.
            message = ProfileErrorPresentation.message(for: error, action: .moderationAppeal)
        }
    }
}
