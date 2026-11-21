# Current accepted scene controls the real native hold poster — #765

**Parent:** successor [Runtime #642](https://github.com/GavinDu/Hephaestus/issues/642), NOT original #202. Split as narrow source implementation from original [#353](https://github.com/GavinDu/Hephaestus/issues/353) and broader #275; those remain open for real iPhone/iPad published-game, deployed schema-v2, screenshot and physical-device evidence.

## Production source behavior

Prior to this change, `PixiPlayerSheet.handleLoadFinish()` logged `TapToNavReady` and immediately faded the poster on WebKit navigation `didFinish`, even when no accepted Pixi `first_scene_render_submit` had arrived. The native Coordinator already checks current document nonce/session/attachment and feeds `firstSceneSubmittedForAttempt`; that state was recorded but ignored by the hold presentation.

This PR preserves existing separate navigation metrics and shifts only poster fade into `fadeHoldPosterAfterCurrentScene()`. The real native `onFirstSceneRenderSubmit` callback stores accepted current attempt and calls that function. `handleLoadFinish` also calls it for genuine prewarm where scene submission preceded navigation completion, **but nav finish alone never satisfies the pure scene-gate**. Requires loaded current attempt + real poster visible + accepted current attempt scene + no error or session revocation. Reduced Motion removes instantly; otherwise preserves 250ms animation/300ms delayed cleanup guarded by attempt and existing lease-sensitive state. No new event/message/runtime bridge, no second GamePackage/asset fetch and no score promotion.

A separate SwiftUI `.task(id: "\(attempt):\(isLoading)")` starts only after *real* navigation completion for an admitted visible poster. After 12 seconds without current accepted scene, it fails honestly to the existing fixed `The game has not drawn its first scene. Tap Retry or return to the feed.` user-visible native error and offers real Retry/Return-to-feed. Task is cancelled by SwiftUI on retry/phase changes/dismissal and guards current attempt, still-visible poster, no current scene, error state and credential revocation before mutation. No infinite spinner/legacy success fallback. The timeout is a **UX upper bound**, not proof of GPU frame timing or a physical performance p95.

## Evidence/tests and honest exclusions

Swift Testing: accepted/current/early prewarm scene; no nav-only poster fade; 160 attempts across stale/next epochs; error, no poster, postfade, revocation and timeout gate. Python source guard checks that the actual production navigation handler cannot directly set `holdOpacity=0`, only accepted callback can initiate fade, and actual SwiftUI timeout is bounded and shows fixed error. All mandatory exact final PR-head Xcode/iPhone/iPad/Player Presentation/backend screenshot jobs must succeed before merge; any genuine UI failure remains blocking. No test harness synthetic published game, score or creator.

**Not proven/remaining under #353:** deployed trusted schema-v2 generator #286, actual server-approved published package and poster CDN, physical cold/warm prewarm scene handoff on iPhone/iPad screenshots/VoiceOver, native GPU compositor present #276 and 50-cycle memory/thermal #279. Some older installed/legacy runtime may not send an accepted scene; the new behavior intentionally provides Retry rather than showing unverified blank gameplay. Validate real deployed source before broad rollout. Independently server-attested score/replay remains separate.

**Rollback:** revert only the pure poster gate, first-scene callback hook, native 12s watchdog and tests/docs. Do not relabel `first_scene_render_submit` as GPU-first-frame.
