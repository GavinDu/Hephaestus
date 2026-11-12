# ADR: Hephaestus game runtime for AI-generated 2D games

**Status:** Architecture decision proposed; incremental implementation merged, full epic NOT resolved  
**Date:** 2026-11-11  
**Epic:** [Hephaestus #202](https://github.com/GavinDu/Hephaestus/issues/202)  
**Shared ownership:** `GavinDu/Hephaestus` (iOS host, UX, lifecycle, telemetry) and `GavinDu/html5-game-generator` (IR, compiler, package, web interpreter).

## 1. Problem to solve

Hephaestus is a short-session, feed-native mini-game platform. AI-generated games differ more widely than the current subset of arcade/physics experiences: puzzle, branching narrative, turn-based/tactical strategy, animated interactions and custom controls should fit without a new native app binary per game. This must not turn into arbitrary remote code execution, broken replay verification, platform-specific gameplay or memory/latency regression.

The runtime must be (1) **extensible in capabilities**, (2) **deterministic in semantic gameplay**, (3) **bounded and secure**, (4) **fast and predictable on real iPhones/iPads**, (5) **owned by one executable contract** across publishing, simulation, replay and mobile host.

## 2. Observed baseline

- Shipping iOS player: SwiftUI + pooled, backend-hosted `/player?presentation=play` in WKWebView, in `Hephaestus/Player/PixiPlayer.swift`. One process pool, one interactive web view, native load and failure recovery, optional quality parameter and a guarded **one-way** message handler for verified-run and performance summaries. This is *not literally bridgeless*; the handler checks main-frame, same-origin, schema/session/game identity, and offers no general command/native APIs.
- Backend runtime: `internal/api/web/pixi-runtime.js` interprets Game IR with PixiJS, Rapier, WebAudio, rules, scene updates and telemetry in one ~2,900-line module. Rendering and physics use a fixed logical canvas; Rapier uses 60Hz steps.
- Backend IR: `internal/gameir/ir.go` and `schemas/game-ir-v1.schema.json`, versions 1.0–1.2, data-only with allowlisted actions/components and bounded content. Inputs currently tap, drag, keyboard. The former `holes_stitched` shortcut was removed by generator PR #323; regression tests now cover generic authored collectible behavior.
- Package: `internal/api/package.go` returns envelope v2.0 with a **short** `irHash` for verified run/leaderboard identity and a distinct **full** `irSha256` for content integrity. The historical `irHash`/`irSha256` incompatibility was fixed by generator PR #322 and validated using a real Go-exported Swift fixture. The production Xcode project STILL does not link that standalone Swift package; a passing isolated core test does not imply a correct native integration.
- Feed-to-player readiness: navigation finish is measurable, but not evidence of the first rendered frame or interactive readiness. See `docs/PLAYER_HANDOFF.md`.

### Architectural debt, not evidence of production failure
1. Duplicate iOS host lifecycle and standalone Swift Core contracts, even though the package hash incompatibility has been fixed.
2. The interpreter already implements a 60 Hz fixed semantic accumulator (`STEP_MS`, `simAcc`, `tickFrame`). Cross-browser seeded replay is enforced by PR #326; remaining gaps are broader genres, event order, throttled render pacing and visual RNG isolation.
3. One large interpreter limits test isolation and per-genre feature composition.
4. Narrow IR genres and inputs force game-specific runtime branches or unimplemented actions.
5. Asset loading and one pooled WKWebView are reasonable optimizations, but do not establish bounded memory, revocation or safe rapid-switch teardown.
6. No measured device-specific compositor-presented first frame, memory/thermal baseline or 15-minute hardware stability acceptance.


## 2A. Implementation state and ownership at the current checkpoint

The architecture is adopted only as a **proposed target** while Epic #202 remains open. Merged and fully CI-verified increments include: package hash (#322), removal of objective-specific collision recovery (#323), cross-browser fixed-tick state comparison (#326), terminal-state finality (#328), first scene *submission* and false-ready protection (#329/#339), server asset bytes (#330), held-control cancellation (#332), Swift capability preflight (#334), browser capabilities (#337), native validated metrics (#208), native first-input session timing (#210), bounded image decode (#338), rendering quality invariant replay (#340), and unattached prewarm expiry (#211). Check the PR links in Epic #202 for current merge evidence. These cannot substitute for physical iPhone/iPad measurements.

### Authoritative component responsibilities

| Component | Authority | Never do |
| --- | --- | --- |
| Go compiler/publisher | Authoritative schema, allowlist, full canonical IR integrity digest, byte budgets, authorization and moderation | Generate executable JS or silently downgrade an unsupported mechanic |
| Trusted browser interpreter | One 60 Hz semantic tick, deterministic seed/input replay, rules, score/objectives, stable terminal result, physics contacts when declared | Depend on screen refresh cadence or visual-only particle RNG for gameplay |
| Pixi/WebAudio adapter | Pixels, animation, sound playback and disposable asset ownership | Set canonical game score, win state, run ID or leaderboard identity |
| Standalone Swift GamePlayerCore | Independently tested package-envelope/IR compatibility validator and proposed launch-contract library | Claim to own shipping gameplay state until explicitly integrated into Hephaestus |
| Production Hephaestus SwiftUI/WKWebView | Navigation/failure recovery, prewarm, origin/main-frame/session-bound one-way metrics/run notification, physical lifecycle, native feed UX | Start gameplay on didFinish, duplicate game simulation, trust in-page result numbers or add arbitrary native command bridge |
| Backend verified-run service | Server-verified outcomes and leaderboard identity | Accept untrusted native UI outcome data |

### Lifecycle transition contract (proposal for issue #203)

`idle -> speculative_preload -> attached_navigation -> package_preflight -> essential_assets -> renderer_submit -> awaiting_start -> playing -> ended -> verified_handoff -> disposed`.

A failure at package/auth/render/physics can enter `recoverable_error` or `terminal_error`, never `ready`. A prewarm that is not attached expires; attachment invalidates the expiry generation. `WKNavigationDelegate.didFinish` is *navigation completion only*. The first scene-render-submission milestone indicates a submitted draw but **not** a GPU-presented frame; `first_input` is a separate bounded session-bound milestone. App backgrounding pauses user input and should not generate additional simulation ticks or keep held controls. Every transition must bind to one current game ID, immutable version and runtime session; verified results are fetched from the backend, not accepted from a page payload.

**Challenger-required negative paths:** rapid A→B→A switching, revocation while prewarmed, offline/private/removed assets, repeated WebContent termination, stale metric/run callbacks, abandoned prewarm, duplicate input, canceled gesture, untrusted capability, oversized/damaged compressed image, texture decode pressure, audio request abortion, unexpected renderer failure, and repeated 50+ close/enter cycles. CI browser tests are not actual-device thermal or memory proofs.

## 3. Decision

**Adopt an incremental, single-semantic-runtime architecture for 2D mini-games. Keep PixiJS (render) + optional Rapier2D (physics), backed by a declarative, typed, capability-gated Game IR. Do not introduce a parallel Defold/Unity/Godot/SpriteKit interpreter or accept arbitrary game-generated scripts without an independent ADR and cross-runtime proof.**

### Target components

```
Creator instructions + GameSpec
    |
    v
AI constrained compiler --> canonical IR + asset manifest + provenance
    |                      (typed, bounded, engine independent)
    v
Versioned package --> auth / moderation --> capability+budget preflight
    |
    v
Simulation core
  * virtual 60Hz tick + fixed command/event order
  * typed variables/objective state, safe semantic action DSL
  * deterministic entity IDs/spawn/despawn
  * host-seeded randomness; timestamped input traces
  * bounded work/tick, replay state fingerprints
    |
    +--- Pixi 2D scene/animation adapter (render-only)
    +--- Rapier2D adapter (only if declared)
    +--- WebAudio adapter (presentation only, user-gesture unlock)
    +--- input adapter (touch, hold, swipe, keyboard, controller -> semantic event)
    +--- accessibility/quality/diagnostics adapters
    |
    v
iOS WKWebView shell in SwiftUI (single active instance, prewarm, cancel,
failure and recovery, true readiness, safe exit back to feed)
```

The **semantic core** determines score, health, position, turn, collisions, objective state, terminal outcome and replay; renderer/quality may only change pixels/audio/presentation. If gameplay collision relies on Rapier, that engine's deterministic body/order inputs become part of the semantic state contract. Merely ticking Rapier at 60Hz does **not** prove semantic determinism.

## 4. IR growth policy

Do not immediately break v1.0–1.2 or call a proposal a shipped capability. First introduce fully versioned capability declarations (e.g. `logic.state.v1`, `logic.dialogue.v1`, `input.axis.v1`, `logic.turns.v1`, `render.timeline.v1`) with a capability registry **shipped in trusted runtime code**; never dynamically execute game-provided code.

Each slice needs:
1. A narrow formal semantic grammar, bounded typed values/references and resource costs.
2. Generator templates and negative validations for impossible, unsupported, or softlocking game definitions.
3. Schema + backend validator + package negotiation + actual runtime interpreter in the same release slice.
4. Seed+input replay determinism and cross-platform golden state/result fixtures.
5. Playability bot and screenshot evidence on real representative assets.
6. Old version compatibility and explicit unsupported capability recovery UI.

**Priority order:**
- **P0:** canonical hashes, capability/budget preflight, fixed-step correctness and first-frame state.
- **P1:** typed state machines, semantic input/hold, dialogue, compositor/optional-physics refactor.
- **P2:** grid and turn-based rules, animation timeline markers, checkpoints and accessibility metadata. A 3D runtime profile is out of scope until creator demand justifies a separate, benchmarked and policy-reviewed path.

A suggested envelope direction (illustrative, **not yet a schema**, and not emitted by the generator):

```json
{
  "packageFormatVersion": "2.0",
  "minRuntimeVersion": "2026.10.23.2",
  "irVersion": "1.3",
  "capabilities": [
    { "name": "logic.state", "version": 1 },
    { "name": "render.sprite", "version": 1 },
    { "name": "logic.dialogue", "version": 1 }
  ],
  "budgetProfile": "mobile-mini-v1",
  "irHash": "<short verified-run board key>",
  "irSha256": "<full canonical digest>",
  "ir": { "...": "existing Game IR fields plus validated extensions" },
  "assets": []
}
```

The exact fields and backward-compatible version migration need a cross-repo design review before implementation. Neither `irHash` nor `irSha256` may silently change its meaning. All capability codes must be fixed allowlisted identifiers; game packages carry no executable module content.

## 5. Library alternatives and decisions

| Candidate | Evaluation | Decision |
| --- | --- | --- |
| **PixiJS/WebGL** | Current real shipped 2D interpreter; broad 2D animation/sprites ecosystem; immediate conformance coverage. | **Retain** as presentation adapter, refactor boundaries. Use WebGL as production default pending target device evidence. |
| **Rapier2D/WASM** | Broad 2D collision, joints, CCD, stable stepping; physics cost not needed for every genre. Rapier states cross-platform determinism only under identical initial inputs and ordering. | **Retain, optional** and profile when loading; audit transient body lifecycle and spawn order. |
| **WebAudio** | Works with browser gesture unlock, shared audio buffers; can own runaway memory if retained globally. | **Retain** behind lifetime/budget adapter; pause/cleanup tests. |
| **SwiftUI/UIKit + WKWebView** | Gives native feed, safe areas, interruption handling and a single remote declarative mini-game runtime. WebContent process memory/first-frame visibility are constraints. | **Retain**, integrate with a truthfully documented contract; no arbitrary native bridge. |
| **SpriteKit/Metal custom interpreter** | Native draw/control potential but duplicates IR execution and QA; Metal adds major engine ownership. | **Reject for v1** unless benchmarks show an insurmountable WKWebView bottleneck and cross-runtime fidelity is proven. |
| **Defold/Godot/Unity** | Robust standalone game engines but likely duplicate conversion, packaging and conformance work for feed-sized mixed-genre mini-games. | **Reject as second interpreter now**; reconsider only with measured unsupported genre/device needs. |
| **WebGPU by default** | Potential gains but iOS/browser compatibility and renderer differences need device qualification. | **Not production default** until full renderer/asset and device matrix passes. |

References: [Pixi rendering docs](https://pixijs.download/dev/docs/rendering.html), [Rapier determinism](https://rapier.rs/docs/user_guides/javascript/determinism/), [Apple App Review Guidelines 4.7](https://developer.apple.com/app-store/review/guidelines/).

## 6. Security + App Store boundaries

Game packages are data-only. Disallow downloaded scripts, `eval`, dynamic executable plugins, arbitrary media URL fetches and any native API privilege available to game IR. Page navigation only on trusted origin. Document the existing narrow verified-result/metric JS handler precisely: validate origin, main frame, schema, size, session ID and game identity; re-query verified results server-side. Do not extend the handler to expose arbitrary device APIs. Review Apple Guideline 4.7.1–4.7.5 including UGC filtering/report/block, index + universal links and age controls in addition to general 2.5.2 restrictions. Approval cannot be presumed.

Delivery must reauthorize private/restricted content, handle moderation revocation in cached public content, verify full digest and mandatory asset bytes, and reject maliciously large decoded images/audio/physics assets, not only compressed transfer sizes.

## 7. Runtime states and expected user experience

`idle -> loading_package -> validating -> loading_critical_assets -> compiling_scene -> first_frame -> awaiting_player_start -> playing <-> paused -> completed`

Any eligible pre-ready state may transition to a typed `failed(reason, recoverability)`; background/interruption suspends deterministic time; safe exit always returns to the same feed post. WebContent termination has bounded automatic recovery attempts and can never silently generate a verified result.

Track **different** metrics: tap-to-nav-finish, tap-to-first-frame, tap-to-first-input-ready, time-to-first-accepted-input, and first meaningful gameplay tick. They are not synonyms. Prewarm may count as cache hit without being visually ready. Poster hold/crossfade must not hide indefinite loading, errors, or stale gameplay.

## 8. Measurement plan (budgets not yet ratified)

CI tests run Go/Swift/browser contracts, deterministic traces and screenshots; real devices are needed for physical touch, thermal, WebKit GPU memory and smoothness. Establish device cohorts for a low-tier supported iPhone, contemporary iPhone, compact/regular iPad. Test portrait/landscape, Wi-Fi/cellular, cold/warm prewarm, rapid swipe, background/foreground, power/thermal, 1/5/15-minute sessions, bad content, WebGL context loss and 50+ open/close cycles.

Collected artifacts: commit + IR SHA256 + runtime version, per-stage timeline, p50/p95 render frame time, long frames, first accepted input, peak resident memory, GPU texture count/bytes, audio/cache buffers, recoveries and outcome fingerprints. Preserve privacy by avoiding user content/account tokens in metrics.

Provisional product hypotheses (revisit **after** baseline): warm tap-to-first-interactive p50 ≤ 1.5s Wi-Fi, 60fps-target for mid-tier simple 2D games when foreground, 30fps-capable low mode, no repeated blank frames. These are **targets, not measurements**; device-specific p95, cold-start, memory and thermal budgets will be approved only from actual evidence. Low visual quality must not change score/health/collision/outcome.

## 9. Review challenger questions

1. **Can we prove semantic replay identical at throttled frame cadence, not just fixed recorded-frame playback?** If no, block new IR capabilities.
2. **Can the runtime eliminate the `holes_stitched` special case with a generic bounded collision primitive?** If no, block expansion to multiple genres.
3. **Should `GamePlayerCore` be integrated or retired?** Decide one authoritative host lifecycle; no parallel coordinators claimed as shipping.
4. **Can capability manifests prevent unimplemented control kinds and giant resource loads from publishing?** Show negative fixtures, not only schema checks.
5. **Does the first-frame signal remain presentation-only and compliant with 4.7?** Demonstrate it cannot expose a new native-control surface.
6. **Is optional Rapier actually faster for nonphysics games?** Profile real builds; do not trade deterministic fidelity for a guessed performance gain.
7. **Do moderated/private games remain revocable after caching and prewarming?** Validate race conditions, session changes and ETag behavior.
8. **Does generator-produced gameplay span arcade + puzzle + branching story + strategy without custom application code?** Require shipped playable representative fixtures before declaring the architecture successful.

## 10. Delivery and merge gates

Child issues: [P0 hash contract](https://github.com/GavinDu/html5-game-generator/issues/314), [P0 host integration](https://github.com/GavinDu/Hephaestus/issues/203), [P0 determinism](https://github.com/GavinDu/html5-game-generator/issues/315), [P0 benchmarks](https://github.com/GavinDu/Hephaestus/issues/204), [P0 negotiation/budgets](https://github.com/GavinDu/html5-game-generator/issues/316), [P1 modularity](https://github.com/GavinDu/html5-game-generator/issues/317), [P1 input](https://github.com/GavinDu/html5-game-generator/issues/318), [P1 story/state](https://github.com/GavinDu/html5-game-generator/issues/319), [P1 teardown](https://github.com/GavinDu/Hephaestus/issues/205), [P2 genre slices](https://github.com/GavinDu/html5-game-generator/issues/320).

Before closing epic: cross-runtime golden IR/version/hash matrix, seeded replay equality, type/error/asset security, app shell launch state and recovery, iPhone/iPad device evidence, measured budgets, App Review threat audit and all required green GitHub Actions. No production rollout from documentation alone.
