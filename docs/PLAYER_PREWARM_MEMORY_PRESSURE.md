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


## Background eviction — independent Epic #202 slice #277

When the app enters the background, an unattached Play-triggered speculative `WKWebView` should not continue download, texture decode or hold a WebContent renderer until its normal 15-second TTL expires. The pool now registers `UIApplication.didEnterBackgroundNotification` lazily once alongside the existing memory-warning observer. The notification schedules a `MainActor` task, **rechecks current attachment ownership** at execution time, and reuses `discardUnattachedPrewarm()` only when a speculative view still exists. An attached game remains owned by its sheet even when a background event races with a Play navigation.

Native Swift Tests cover the unattached/attached × present/absent policy table. They do not prove the OS notification order, WebKit GPU memory actually reclaimed or foreground resume of a real game. Required merge gate: both exact-head iOS Xcode/unit, iPhone player smoke, iPad player/evaluator, native player-presentation and backend contract jobs successful, then senior game-engine architect source review. Real-device 50-cycle memory/thermal and credential cache revocation remain #279/#278 and parent #205; this narrow fix cannot close those issues.
