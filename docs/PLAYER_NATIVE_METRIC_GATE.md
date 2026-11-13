# Native runtime metric delivery — constant-space acceptance

Parent: [Hephaestus Epic #202](https://github.com/GavinDu/Hephaestus/issues/202), truthful runtime milestones [#204](https://github.com/GavinDu/Hephaestus/issues/204).

The trusted Pixi runtime emits one globally increasing `sequence` for its narrow `player_metric` bridge notifications (`first_scene_render_submit`, `first_input`, `perf_window`). Native `PlayerWebView.Coordinator` already rejects non-main-frame origins, wrong game IDs, unexpected session IDs and malformed schemas.

Previously each *new* sequence ID was kept forever in `acceptedMetricIDs`; an unusually long-running session could retain a growing set of identifiers. A replay with a novel sequence could also record multiple `FirstSceneRenderSubmitted` first-milestones.

## Implementation

- A pure `PlayerRuntimeMetricSequenceGate` keeps only **three** integer high-water marks, keyed by an explicit allowlist of the trusted metric names. Equal or older per-kind sequences, unknown metrics and numbers outside `0...100000` fail closed. Cross-kind arrival need not be contiguous.
- A separate one-shot `PlayerFirstSceneRenderSubmissionGate` accepts only the **first valid** timestamp (`0...3600000` ms) for each attached Coordinator. This is *renderer submission*, never a claim of physical GPU present, a nonblank displayed frame, or first accepted user input.
- The existing `PlayerFirstInputGate` remains the one-shot owner for gameplay start. Its per-attempt clock is not reset by a duplicate metric.
- On dismantle, all native metric gates reset; the next Coordinator has new ownership. The message schema and backend social event IDs remain unchanged.
- The server-provided runtime already increments one global sequence counter; a per-kind monotonic gate is compatible with it. Delayed out-of-order old samples intentionally do not overwrite newer samples. These are telemetry-only data, not simulation events, so no gameplay outcomes are affected.

## Validation and limitations

Swift Testing covers duplicate, out-of-order, cross-kind, unknown-kind and boundary sequences, constant storage, reset and first-scene one-shot semantics. Gate merge on both exact-head native GitHub Actions workflows, including Xcode tests, player-smoke, iPad evaluator and backend presentation contract.

This fixes memory growth in the native **metric** channel. The separate run-result identifier Set is not made constant-space by this metric-only change. Bounding that path without suppressing legitimate verified runs, physical iPhone/iPad GPU-present observations, memory/thermal benchmarks, the authoritative launch-state reducer and 50-cycle teardown acceptance remain separate work. This PR does **not** close #204 or Epic #202.
