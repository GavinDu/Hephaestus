# Accessibility XXXL native actions/share lifecycle — runtime Epic #202

Parent [Epic #202](https://github.com/GavinDu/Hephaestus/issues/202), UI [Epic #172](https://github.com/GavinDu/Hephaestus/issues/172), scoped [#331](https://github.com/GavinDu/Hephaestus/issues/331), blocked prewarm [#277](https://github.com/GavinDu/Hephaestus/issues/277).

## Evidence and independent source correction

[Native PR #312 required iOS workflow #43609420425](https://github.com/GavinDu/Hephaestus/actions/runs/43609420425) failed the Accessibility XXXL iPhone `testDiscoverFeedSupportsAccessibilityDynamicType` at its source line 1424. The first live Actions menu contained required Share/Save/Like/Comments/Details/Report entries; after an arbitrary outside coordinate tap and a second open, **Share game** did not reappear within the bounded wait. The [XCResult and screenshot artifact #14124033959](https://github.com/GavinDu/Hephaestus/actions/runs/43609420425/artifacts/14124033959) remains the relevant source evidence. The failure is not proof that speculative WebKit prewarm caused the regression and must not be bypassed.

Under Accessibility XXXL only, the native feed's `accessibleSocialMenu` now opens an explicitly dismissible mounted SwiftUI `NavigationStack`/List sheet, not a transient anchor-bound `Menu`. The visible **Game actions** button preserves its `feed.actions.accessible` identifier and 48+ pt minimum hit area. The list retains actual user-scoped Save/Like, Comments, Share, Details, Report, Not interested and permitted Block creator actions with ordinary localized labels; no fake social state or game data. A real `Done` action has `feed.actions.dismiss` and can close the sheet at any time. The compact social rail and existing system share wrapper are unchanged.

Choosing **Share game** snapshots that page's exact canonical game URL and game ID, sets a one-shot presentation intent, dismisses the actions sheet, and only its `onDismiss` closure triggers the mounted page's existing `ArcadePulseGameShareSheet` (a real `UIActivityViewController`) and share-event tracking for the **snapshotted game**, preventing a fast feed switch from redirecting the share. The snapshot is cleared when the native share presentation ends. No `ShareLink` is invoked from a disappearing native menu controller, no private bearer/header is passed to sharing, and repeated reentry cannot present two action sheets simultaneously.

The exact mandatory Dynamic Type test now *first* verifies six real action labels, explicitly taps Done (instead of an arbitrary potentially destructive coordinate), waits for actual dismissal, gates title/Play/tab geometry and takes its screenshot, **reopens** the real actions UI, finds the actual Share game control, taps it, verifies the actions sheet leaves, and requires an actual system sheet/popover/activity-list before capturing share evidence. No test is disabled, backend game is not mocked, and a screenshot of the source action menu alone does not count as a successful share.

## Senior game-engine architect / accessibility challenge

- Require exact current-head native iOS build/unit, iPad evaluator, iPhone/player-smoke, iPhone/iPad presentation and backend contracts to pass before closing #331. Never inherit #312's previously failed exact-head jobs.
- Challenge whether a SwiftUI `Button` inside an accessibility-sized List is 44+ points, whether real sharing preserves the current published game identity during rapid feed switches, whether iPad sheet/popover anchor is safe, and whether actions remount on rotation. Verify with simulator XCResult screenshots and actual VoiceOver; physical-device testing remains separate.
- Capturing a share event is not a verified game win; this UI fix does not change deterministic IR execution, native schema v2, WebKit memory, authenticated content or player first-composited-frame evidence.
- Follow-up: after this PR and the independent stalled-feed Retry observation PR #328 pass/merge, **rebase/rebuild and re-run** prewarm PR #312 on current main. Neither independent success cures a red job on #312 by itself. Parent #277/#288 and Epic #202 remain open.

Rollback reverts only accessibility-sized native actions presentation, two-state mounted-sheet handoff and strengthened native smoke; existing normal-type feed actions remain as previously shipped.
