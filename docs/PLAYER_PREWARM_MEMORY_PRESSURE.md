# Memory-pressure eviction for speculative player prewarm

Parent [Epic #202](https://github.com/GavinDu/Hephaestus/issues/202), resource ownership [#205](https://github.com/GavinDu/Hephaestus/issues/205).

The production player owns **one pooled WKWebView**. It prewarms only after the user presses Play and normally discards an unused speculative page after a bounded 15-second timer. A UIKit memory warning can arrive earlier and should release that avoidable work rather than retain a possibly large WebKit scene.

## Safety contract

- The process-wide observer is registered once when the pool is first used, not per game or per sheet.
- On `UIApplication.didReceiveMemoryWarningNotification`, a MainActor callback evaluates *current* pool state (not stale state captured before scheduling). It discards only when `pooledView != nil && !isAttached`.
- The existing `discardUnattachedPrewarm()` path cancels expiry, invalidates the prewarm epoch, stops loading, removes the stale view from the pool and disposes its transient document. It is intentionally reused instead of adding an independent pool teardown path.
- **An attached/interactively playing game is never automatically blanked or recycled by this observer**. Active sessions still report pressure through the sheet's existing telemetry, and normal retry / process termination recovery remains separate.
- Credential changes still invalidate both attached and speculative pools. The eviction path does not modify content hashes, game results, stored asset policy or the narrow WebKit run-result channel.

## Review / validation

Swift unit tests exercise unattached/attached × view-present/view-absent. Native Actions must additionally pass Xcode compilation and iPhone/iPad player smoke. This policy test does not prove OS delivery order or real-world memory reclaimed: retain #205 real iPhone/iPad 50+ open/close/swipe memory, thermal and context-loss evidence gates. This slice is safe to revert without changing package semantics.

## Background-only speculative teardown — scoped #277

One lazy process-level `UIApplication.didEnterBackgroundNotification` observer schedules its decision on `MainActor`. It checks **current** `isAttached` and pooled-view presence, then reuses `discardUnattachedPrewarm()` only for speculative unattached work. No attached playable `WKWebView` is blanked or discarded by this observer. The preexisting 15-second speculative TTL and memory-warning observer remain intact.

This integration branch was rebuilt from the newest native `main` **after merged document nonce #283 and nonpersistent WebKit credential-store #300**. It leaves the native session/store/nonce ownership path alone and never adds new message-handler capabilities. Old draft [#297](https://github.com/GavinDu/Hephaestus/pull/297) is not a safe merge gate because its unrelated live social-write iPhone smoke failed: source evidence in [workflow 43597582122](https://github.com/GavinDu/Hephaestus/actions/runs/43597582122), `PlayerSmokeTests.swift:319`, reported “Only a real loaded feed may trigger social error-state evaluation.” Tests must **not** skip this guard or invent a loaded feed; record actual feed HTTP/status, real published game identity, Retry states, screenshot/hierarchy and test-environment version.

The new exact-head native Xcode, mandatory iPhone/iPad player-smoke, iPad UI evaluator and presentation/backend jobs must all complete success before closing #277. Source truth-table only cannot establish actual UIKit event delivery ordering. Hardware GPU/audio/texture release, multiwindow iPad scenes, 50+ physical cycles, thermal impact and cache revocation remain #205/#278/#279 and Epic #202 release gates.
