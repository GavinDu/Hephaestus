# Native player metric POST task ownership — #750 / successor #642

## Source-verified problem
The installed `PlayerWebView.Coordinator` accepted `first_input` and `perf_window` with native state/lease validation but launched unretained Swift `Task` blocks for the corresponding telemetry POST. After start, a legitimate document restart, sheet exit or WebContent death could leave that request in flight even if old browser messages were rejected. Already-shipped verified-run result lookups had explicit retained/cancelled task handles; metrics did not.

## Single owner and bounded cancellation
A **single Coordinator-owned**, `@MainActor` `PlayerNativeMetricTaskRegistry` retains at most **two** metric Task handles. New metric windows arriving while both slots are in flight are dropped without a queue. The registry allocates monotonic task IDs with an epoch, removes completed slots by exact ID/epoch, and cancels/revokes all handles at native stop, new document navigation, accepted navigation failure and WebContent-process termination. Each completion is keyed so an old epoch cannot remove a newer task. Existing per-kind sequence gates and `PlayerRuntimeMetricDispatchPolicy` (live attachment, session, document and cancellation) remain mandatory before any POST starts.

The actor task snapshots only a vetted `gameID`, rather than retaining the old Coordinator across `URLSession.data(for:)`. The POST uses the *same* event ID `ios-metric:{session}:{kind}:{sequence}`; backend request contents, authentication and score/display state do not change. `BackendAPI.trackSocialEvent` checks task cancellation before building a request and just before the cooperative URLSession send. It does **not** reinterpret cancellation as server-side deletion or a verified/attested gameplay event.

## Adversarial acceptance and rollback
- 160 pure deterministic revoke/late-finish rotations; concurrency 2/3 admission; old task cancellation, exact completion, no stale-generation removal. No mock server, fake publisher or score.
- Python source-contract test verifies both real player metric callsites, the maximum pending budget, and all **four** native lifecycle revocations plus pre-send cancellation.
- Exact final-head GitHub Actions native iPhone/iPad/Xcode/URL/player smoke must be SUCCESS before squash/issue closure. A failed real backend/Comments assertion is not waived.
- Undo only `PlayerNativeMetricTaskRegistry`, Coordinator dispatch/cancel calls, the cooperative cancellation checks in `BackendAPI` and the narrow tests.
- Larger parent #685 remains open for explicit sign-out/credential-epoch revalidation during flight, server-side idempotency/retention, in-flight POST transport evidence and physical iPhone/iPad 50-cycle memory acceptance. Client cancellation cannot retract an HTTP POST already accepted by the server. No new JS/native privileged bridge or GamePlayerCore parallel fetcher.
