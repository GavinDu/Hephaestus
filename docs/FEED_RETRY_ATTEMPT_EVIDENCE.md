# Epic #202 — genuine stalled Discover Retry observation (#327)

## Exact source defect

The production `FeedRequestCoordinator.begin` creates a new cancellation-scoped feed transport and increments its generation, while the watchdog also increments the generation to retire a timed-out request. XCUITest previously tapped Retry and then tried to detect an ephemeral `Loading games` accessibility element. The test's deliberate 3-second watchdog can finish between UI-tree queries, so a **real retry can be missed** even while all recovery behavior worked.

## Independently testable fix

- `DiscoverView` keeps a small nonsecret `FeedRequestAttemptCounter` (with UInt64 saturation) alongside genuine `FeedRequestCoordinator.begin` calls. The counter is unaffected by cancellation, task completion and watchdog generation changes, and saturates instead of overflowing.
- The existing 48-point `feed.error.retry` Button exposes a VoiceOver-friendly `accessibilityValue` such as `Request attempt 2`. This remains visible on the recovered error state and does not claim the network request succeeded.
- The stalled-transport UI smoke captures the actual previous attempt number, taps the real Retry control and waits for **the exact next attempt number** when the genuine 3-second timeout recovery reappears. It still asserts the actual recovery title/Library action and that no `game.play` exists. It keeps screenshot evidence before and after Retry, and never injects a fake game or feed.
- Swift Testing proves the counter changes on actual transport begins, **not** after timeout revocation, old completion, or cleanup.

## Adversarial senior game-engine-architect review

This is a **test observability and accessibility** change, **not** a remedy for the live backend feed/package outage, an engine readiness check or trusted game result. The counter is per-view, reset on a new Discover instance, and deliberately contains neither game ID nor bearer token. It must not be interpreted as a retry-success metric; an attempt means a new transport task was started. The UI still surfaces retry or Library with no fabricated content. The test must fail if a new `begin` is never executed.

Do not close #327 or merge before the exact PR-head mandatory native Actions pass: Xcode/Swift, player-smoke, iPad UI evaluator, URL tests, backend play contract, iPhone WebKit, and required iPad player smoke. A live publisher/package mismatch (#288/#345/#368) and physical iPhone/iPad GPU-present and thermal proof (#204/#276/#279) are separate release gates. Existing unrelated security PR #414 should be reconstructed/retested on a head containing this fix, not inherit status from this PR.

## Clean-current-main consolidation

The formerly separate draft PR #427 and PR #512 are consolidated into PR #512: pure saturating counter regression, real request ownership, the stable XCTest second-recovery assertion and both pre/post-retry screenshots. No backend response or published game is injected. The superseded PR #427 can close unmerged without losing its unique test evidence. The source is not a proof of server receipt or first-rendered frame.
