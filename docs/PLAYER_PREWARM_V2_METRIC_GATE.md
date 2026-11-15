# Epic #202 / native prewarm schema-v2 first-scene metric admission — atomic #369

## Purpose and scope
The shipping `PixiPlayer.swift` accepts narrow WebKit metrics after a player sheet attaches. Speculative `PlayerWebViewPool.prewarm` can complete before SwiftUI mounts the coordinator; the first render **submission** message may be lost. Full pre-navigation listener installation is [#351](https://github.com/GavinDu/Hephaestus/issues/351), exact-once transfer [#352](https://github.com/GavinDu/Hephaestus/issues/352), and poster handoff [#353](https://github.com/GavinDu/Hephaestus/issues/353).

This small slice delivers a pure `PlayerPrewarmV2SceneMetricGate` in the existing compiled native player source. It does **not** install a WKScriptMessageHandler or alter an active player's behavior. The future pool listener must supply *actual* native `message.frameInfo.isMainFrame`, same-origin result, current document epoch, and credential-scope ownership; these are native-provenance facts, never fields passed from JavaScript.

The gate accepts **only** an exact schema-v2 `player_metric` / `first_scene_render_submit` payload for the current, well-formed 32-lowercase-hex document challenge, matching expected published game and bounded nonempty runtime session. It delegates exact key-set/typed metrics and bounded ms to the existing `PlayerNativeMetricPayload.parse`, rejects numeric CFBoolean, out-of-range/duplicate sequence and all other metric/result types, and stores one validated `ms / sequence / session` snapshot. Subsequent payloads cannot replace the first observation; `reset()` erases it on navigation/credential scope changes. The pure guard does not itself authenticate message origin or manage WKWebView leases.

## Senior game-engine architect challenge
- **Security:** Enforce schema 2 unconditionally; no legacy schema 1 downgrade during speculative first-document collection. No independent score/run verification and no new privileged native control.
- **Truthful readiness:** `first_scene_render_submit` means the browser submitted to its renderer; it does **not** establish a GPU-composited frame, visible poster removal or interactive readiness. Do not fade a poster on this alone.
- **Ownership:** The pool must wire a single handler *before navigation*, ensure exactly-once ownership transfer to the attached player and unregister/reset on navigations, redirects, credential epoch changes, WebContent termination and memory-pressure eviction. Tests in #369 exercise only the pure gate; full #351/#352 requires simulator evidence and #276 physical-device compositor measurement.
- **Compatibility:** The deployed browser may still send schema 1. The gate must reject it and keep existing player path safe. Do not silently upgrade input messages; negotiate a preinstalled schema-v2 producer first under #286.
- **Release:** Seven required exact-head native GitHub CI jobs must all succeed before merging and closing #369, including iPhone/iPad simulator smoke and the real public package prerequisite (#288). No simulator test proves physical thermal/50-cycle health (#279).

Rollback is removing this source-only helper and tests; the shipping host remains unchanged until separately reviewed handler integration.
