/// Fail-closed SwiftUI presentation guard, separate from the runtime's
/// authoritative semantic game state. The coordinator checks WebView origin,
/// game and runtime session; this gate prevents an older SwiftUI view epoch
/// from mutating a newly retried or credential-revoked player sheet.
enum PlayerLaunchCallbackGate {
    static func accepts(expectedEpoch: Int, currentEpoch: Int, sessionRevoked: Bool) -> Bool {
        !sessionRevoked && expectedEpoch >= 0 && expectedEpoch == currentEpoch
    }
}
