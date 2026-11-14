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

## App background eviction

A Play-triggered **unattached** prewarm must not continue network fetch, GPU decode or retain a WebKit renderer when the app enters the background. A process-wide `UIApplication.didEnterBackgroundNotification` observer now reevaluates the **current** `isAttached` and `pooledView` state on `MainActor`, then calls the same `discardUnattachedPrewarm()` operation as the memory-warning observer. It is registered once when the pool is initialized. The existing fifteen-second timeout remains an upper bound during foreground use.

The observer never discards an attached game; `onDisappear` / Coordinator retirement remains the only normal end of that presentation. Pure Swift truth-table tests cover unattached/attached and view-present/view-absent. **This is not proof of real background notification ordering, GPU memory reclamation or persistent WebKit cache revocation.** Validate via iPhone/iPad instrumentation and #205's 50+ lifecycle and private-content revocation gates. App/scene-specific multiwindow behavior requires separate validation.
