import Foundation

/// Pure, one-attempt poster lifecycle for the native Pixi player.
/// No WebKit callbacks, score handling or GPU-compositor claims live here.
/// The caller must derive trust/ownership from native WebKit provenance,
/// the strict document gate, and the pool's current attachment lease.
struct PlayerPosterHoldPolicy {
    struct Attempt: Equatable {
        let gameID: String
        let playerURL: URL
        let documentNonce: String
        let credentialFingerprint: String
        let attachmentLease: UInt64

        var isValid: Bool {
            guard !gameID.isEmpty, gameID.utf8.count <= 128,
                  !credentialFingerprint.isEmpty,
                  credentialFingerprint.utf8.count <= 256,
                  attachmentLease != 0,
                  playerURL.scheme?.lowercased() == "https",
                  let host = playerURL.host, !host.isEmpty,
                  playerURL.user == nil, playerURL.password == nil,
                  documentNonce.utf8.count == 32 else { return false }
            return documentNonce.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            }
        }
    }

    enum State: Equatable {
        case holding
        case sceneSubmitted
        case recovery
        case retired
    }

    let attempt: Attempt
    private(set) var state: State
    private(set) var navigationFinished = false

    init(attempt: Attempt) {
        self.attempt = attempt
        state = attempt.isValid ? .holding : .retired
    }

    /// Navigation completion is useful timing data but NEVER a game-ready
    /// event. Even a valid current-document didFinish does not release cover.
    mutating func noteNavigationFinish(for offered: Attempt) {
        guard state == .holding, attempt == offered else { return }
        navigationFinished = true
    }

    /// A strictly validated, lease-owned first renderer submission may begin
    /// a *scene-submitted* cover transition. This is NOT a measurement of a
    /// GPU-composited first pixel, input readiness or app-store compliance.
    @discardableResult
    mutating func acceptTrustedSceneSubmission(
        for offered: Attempt,
        validatedByNativeGate: Bool,
        ownsCurrentAttachment: Bool
    ) -> Bool {
        guard state == .holding,
              attempt.isValid, offered == attempt,
              validatedByNativeGate, ownsCurrentAttachment else { return false }
        state = .sceneSubmitted
        return true
    }

    /// Called only after the host's bounded deadline really expires.
    /// A late scene event cannot resurrect a dismissed/failed attempt.
    @discardableResult
    mutating func markTimeout(for offered: Attempt, ownsCurrentAttachment: Bool) -> Bool {
        guard state == .holding, offered == attempt,
              ownsCurrentAttachment else { return false }
        state = .recovery
        return true
    }

    /// A live player may also fail after submitting a scene; recovery takes
    /// priority over any poster transition and cannot accept stale success.
    @discardableResult
    mutating func markFailure(for offered: Attempt, ownsCurrentAttachment: Bool) -> Bool {
        guard state != .retired, state != .recovery,
              offered == attempt, ownsCurrentAttachment else { return false }
        state = .recovery
        return true
    }

    /// Logout, game switch, pool eviction and sheet teardown are terminal.
    mutating func retire() {
        state = .retired
        navigationFinished = false
    }

    var mayBeginSceneSubmittedCrossfade: Bool {
        state == .sceneSubmitted
    }

    var mustShowRecovery: Bool {
        state == .recovery
    }

    var mustHoldPoster: Bool {
        state == .holding
    }
}
