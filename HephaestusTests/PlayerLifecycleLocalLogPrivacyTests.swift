import Foundation
import Testing
@testable import Hephaestus

/// P0 #610: local player lifecycle logs must not embed a private game ID.
/// The separately scoped load-failure branch #608 is not changed here.
struct PlayerLifecycleLocalLogPrivacyTests {
    @Test func lifecycleDiagnosticMessagesAreFixedAndBounded() {
        let hidden = "private-owner-game-credential-token-123"
        let sample = [
            PlayerLocalLifecycleLog.prewarm,
            PlayerLocalLifecycleLog.terminatedRepeatedly,
            PlayerLocalLifecycleLog.backgrounded,
            PlayerLocalLifecycleLog.foregrounded,
            PlayerLocalLifecycleLog.memoryWarning,
            PlayerLocalLifecycleLog.opened,
            PlayerLocalLifecycleLog.thermal(.serious),
            PlayerLocalLifecycleLog.thermal(.critical),
            PlayerLocalLifecycleLog.thermal(.nominal)
        ]
        #expect(PlayerLocalLifecycleLog.thermal(.serious) ==
                "thermal state serious while player open")
        #expect(PlayerLocalLifecycleLog.thermal(.critical) ==
                "thermal state critical while player open")
        for value in sample {
            #expect(!value.contains(hidden))
            #expect(!value.contains("credential"))
            #expect(!value.contains("gameID"))
            #expect(!value.contains("https://"))
            #expect(value.count < 96)
        }
    }

    @Test func lifecycleTimingAndRestartLogsFailClosedAcross160HostileValues() {
        #expect(PlayerLocalLifecycleLog.navigationFinished(milliseconds: -1) ==
                "player navigation finished in 0ms")
        #expect(PlayerLocalLifecycleLog.navigationFinished(milliseconds: Int.max) ==
                "player navigation finished in 3600000ms")
        #expect(PlayerLocalLifecycleLog.autoReload(completedReloads: Int.min) ==
                "web content process terminated; auto-reload 0/2")
        #expect(PlayerLocalLifecycleLog.autoReload(completedReloads: Int.max) ==
                "web content process terminated; auto-reload 2/2")
        for iteration in 0..<160 {
            let hidden = "private_run_owner_game_\(iteration)"
            let timing = PlayerLocalLifecycleLog.navigationFinished(
                milliseconds: iteration * 100_000)
            let reload = PlayerLocalLifecycleLog.autoReload(
                completedReloads: iteration - 80)
            #expect(!timing.contains(hidden))
            #expect(!reload.contains(hidden))
            #expect(timing.count < 96)
            #expect(reload.count < 96)
            #expect(!reload.contains("https"))
        }
    }
}
