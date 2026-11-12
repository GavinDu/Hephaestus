/// Pure presentation-only readiness checks for delayed work in the native
/// player sheet. They never decide whether the Game IR itself is ready:
/// navigation completion, first render submission and first accepted input
/// are separate runtime milestones.
enum PlayerTransientPresentationPolicy {
    static func mayFinishPosterFade(
        expectedEpoch: Int, currentEpoch: Int,
        sessionRevoked: Bool, isLoading: Bool, hasLoadError: Bool
    ) -> Bool {
        PlayerLaunchCallbackGate.accepts(
            expectedEpoch: expectedEpoch,
            currentEpoch: currentEpoch,
            sessionRevoked: sessionRevoked
        ) && !isLoading && !hasLoadError
    }

    static func mayShowSlowLoadHint(
        expectedEpoch: Int, currentEpoch: Int,
        sessionRevoked: Bool, isLoading: Bool, hasLoadError: Bool
    ) -> Bool {
        PlayerLaunchCallbackGate.accepts(
            expectedEpoch: expectedEpoch,
            currentEpoch: currentEpoch,
            sessionRevoked: sessionRevoked
        ) && isLoading && !hasLoadError
    }
}
