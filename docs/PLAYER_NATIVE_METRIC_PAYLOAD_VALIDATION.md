# Typed native metric admission before sequence consumption — Epic #202 / issue #204

## Failure confirmed in the shipping WebKit Coordinator branch

`PlayerWebView.Coordinator.handleMetric` called the mutable per-kind
`metricSequenceGate.accept(metric:sequence:)` before checking individual
`ms` / `frameTimeP95Ms` / `frameTimeAvgMs` / `frameCount`
values. A malformed trusted-runtime event with maximum sequence 100000
and a negative or missing millisecond value therefore consumed the
high-water mark without producing a milestone. A following legitimate
lower-sequence first-frame, first-input or performance event was
discarded. The risk is diagnostic/observability, not semantic scoring.

## Incremental production change

- Add a closed, typed v1 `PlayerNativeMetricPayload` parser with only three
  valid payload shapes. Require the existing common WebKit message keys
  and exactly the metric-specific keys shipped by the trusted
  `pixi-runtime.js` `sendNativeMetric` producer.
- Validate schema, event type, domain, bounds and required fields before
  calling the per-kind monotonic sequence gate. A malformed event never
  mutates the high-water mark.
- Retain existing origin/main-frame/gameID/runtime-session/attachment lease
  checks, native launch reducer transitions, first-render one-shot,
  first-input one-shot and 60 Hz gameplay interpreter unchanged.
- Swift Testing regression feeds an invalid maximum sequence then a valid
  lower sequence for every kind, duplicate/out-of-order events, schema
  mismatch, conflicting cross-kind fields, unknown kind, impossible values
  and document-epoch reset.

## Senior game-engine architect challenger / release limits

This code is in a separate *stacked draft* on #232, itself a child of
native #228. It must not merge on either parent's historical CI:
merge #228 after full exact-head workflows, reconstruct/reverify #232
on merged main and merge it, then reconstruct/reverify this PR on that
new main. Required native workflows: Xcode build/unit, iPhone WebView
smoke, iPad player smoke, iPad feed UI evaluator and backend
presentation contract. Audit any added producer fields before changing
this strict v1 contract; later schema versions must explicitly negotiate
instead of silently accepting privileged metadata.

## Stacked-branch validation sequence

This draft temporarily targets `main` so the complete required native
Actions workflows can exercise the source and Swift tests before parent
merges. Its current compare-to-main view **includes** the unmerged #228
launch reducer and #232 verified-run callback changes. That cumulative CI
must not be mistaken for approval of an independently integrated #237.
When #228 and #232 are merged, the #237 branch must be reconstructed as
a minimal three-file commit atop their merged main, rerun exact-head
checks, and receive a final adversarial review before merging.

The eight-document retired-session-ID cap is not cryptographic WebKit
document provenance; v2 challenge/nonce issue #203 remains open.
`first_scene_render_submit` is a Pixi renderer submission only, NOT an
actual GPU-composited first frame. Physical iPhone/iPad p50/p95,
thermal/memory and 50+ lifecycle cycles remain separate acceptance
evidence. Neither #204 nor Epic #202 closes on this patch.
