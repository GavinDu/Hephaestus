# Epic #202 — native poster readiness reducer (#407)

## Why this atomic slice exists

Current `PlayerGameSheet.handleLoadFinish()` still performs a poster crossfade from `WKNavigationDelegate.didFinish`. A completed navigation is **not** a first Pixi scene submission, a first accepted input, or an actual GPU-composited visible frame. This bug cannot be safely corrected by assuming the browser sends a ready event: the first prewarmed callback may arrive **before** a SwiftUI coordinator mounts, and the deployed native bridge presently permits legacy schema-v1. A blank player must not be revealed on a timeout.

## Implemented pure source-only contract

`PlayerPosterSceneReadinessGate` lives in already compiled native `PixiPlayer.swift` and models exactly one current owner: bounded game ID, 32 lowercase hex document nonce, nonnegative attachment attempt and one of `holding`, `sceneSubmitted`, `revealed`, `recovery` or `retired`. A navigation-finish event can record its timing but **cannot** change `holding` into `sceneSubmitted`, and cannot authorize a crossfade. To record the first scene milestone, callers must supply *native-observed* main-frame, origin, credential and active attachment ownership, plus exact game/nonce/attempt. Duplicate/foreign events cannot replace or reveal a candidate. A timeout enters honest recovery and prevents later scene messages from revealing. A successful `consumeReveal` works once and only after acceptance. Reduced-motion changes animation style **after** acceptance, not the condition for reveal.

Swift Testing rejects foreign game, document nonce, attempt and each native-provenance flag; proves nav-finish alone never reveals, one-shot valid scene, timer failure stays fail-closed, old retired callbacks have no effect, and new attempt reset. All tests use native pure values, not fake `WKWebView` runtime messages.

## Senior game-engine-architect adversarial challenge — explicit integration gap

- **Not connected yet:** this pure gate is not invoked by the shipping `PlayerGameSheet`; current poster fade behavior is unchanged by this atomic PR. This is an independently testable prerequisite, not resolution of parent #353.
- **Source ordering:** integrate after #369 schema-v2 parser, #351 pool-owned pre-navigation listener, #357 one-slot nonce/game/credential ledger and #352 lease-bound transfer, with navigation completion retaining only `TapToNavReady`. `PlayerWebView` coordinator must emit **actual validated** current scene submit (or transferred pool candidate), never a JS `isTrusted` field.
- **Actual first frame:** `first_scene_render_submit` means a renderer submission, **not** GPU composition. Keep physical iPhone/iPad #276 open for true compositor-first-frame p50/p95.
- **Recovery:** on a fixed bounded timeout in a future integrated sheet, set actionable Retry/Return-to-feed and retain poster; no automatic fake release. Retry/session change must retire old gate before creating a new attempt. Explicitly test rapid game A→B, iPad lifecycle, preload before attach, WebContent death, authentication rotation and reduced-motion UX in required native simulators.
- **CI:** all required exact-head native GitHub Actions jobs and source review must pass before closing #407; parent #353 stays open pending actual integration and screenshot evidence. No paid Replit or missing-live-fixture bypass.

Rollback removes pure gate, native tests and this note; no app behavior changed.
