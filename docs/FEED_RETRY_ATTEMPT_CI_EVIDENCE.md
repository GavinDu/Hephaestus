# Observable real feed Retry attempts — native iPad/iPhone CI slice

Parent: [Runtime Epic #202](https://github.com/GavinDu/Hephaestus/issues/202), [UI Epic #172](https://github.com/GavinDu/Hephaestus/issues/172), blocked background-prewarm [#277](https://github.com/GavinDu/Hephaestus/issues/277), independently testable [#327](https://github.com/GavinDu/Hephaestus/issues/327).

## Source failure and fix

[Native iPad evaluator #43609420425](https://github.com/GavinDu/Hephaestus/actions/runs/43609420425) on draft runtime prewarm #312 failed `PlayerSmokeTests.testArcadePulseStalledTransportReachesHonestRecovery` at line 414. Nine other simulator tests passed, including native portrait/landscape feed swipe score 100/100. The deliberate HTTP stall lasts 120 seconds but the test-only recovery watchdog fires in 3 seconds, so the old UI test attempted to observe a short-lived `Loading games` view within a six-second polling window after tapping Retry. That is nondeterministic: legitimate loading may finish before the snapshot. Importantly, this was **not** a verified background-prewarm regression, nor a pass.

The production Discover `load()` now increments a separate, monotonic, state-owned `feedRequestAttempt` **exactly once when it starts a new genuine `FeedRequestCoordinator.begin` transport**. The watchdog generation may be incremented again when expiring an old request; it never increments the visible attempt count. The existing recovery's real Retry button exposes `Request attempt N` as a short accessibility value (no bearer, URL, account, private game or device fingerprint). The SwiftUI state update occurs before clearing prior error and showing loading.

The mandatory stalled-feed native UI test reads the first attempt number, taps actual Retry, and waits for the genuine recovery button **to reappear with an advanced value** after a second deliberately stalled HTTP transport. It also requires the honest error text and the absence of `game.play`, preserving Library navigation and touch-target assertions. A no-op Retry would not advance the counter and the test fails. This avoids equating an ephemeral loading-frame snapshot with successful network retry.

## Senior game-engine architect acceptance and limitations

- Require exact-head Xcode, native player smoke, iPad evaluator, iPhone and iPad presentation smoke and backend contract jobs. No disabled tests, no synthetic feed game, no skipped assertions or inherited green head results.
- This is an observability and deterministic-test improvement, not network delivery proof, verified scoreboard/gameplay, or UI screenshot approval. Production timeouts remain 45 seconds; test-only `--ui-test-stalled-feed` remains 3 seconds, with only a deliberately stalled real Task.
- Do not merge or close blocked prewarm #277/#312 solely because this separate change passes. Rebuild/retest that branch against current main and examine its own seven required jobs.
- Live published feed fixtures (#288), real GPU-first-frame, 50+ physical iPhone/iPad lifecycle/thermal and App Review remain outside this slice.

Rollback removes only the attempt-counter accessibility value and the tightened test observation.
