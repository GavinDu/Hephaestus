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

PR #247 reconstructs only the native metric validation, Swift tests and this
ADR on top of the already-merged native #228 launch reducer and #232
verified-run callback fixes. The original cumulative draft #237 must **not**
be merged or used as a CI substitute. This direct-from-main branch must pass
its own exact-head iOS build/unit, iPhone smoke, iPad player/feed evaluator
and backend presentation contract before merging. Audit any added generator
producer fields before adjusting the strict v1 parser; future schema versions
must negotiate explicitly, not silently accept additional native metadata.

The 3-file production + test implementation was compared to the original
draft's source and matched byte-for-byte before this ADR correction. Source
parity is not proof of runtime behavior: real iPhone/iPad stress, WebKit
navigation-race and visual-first-frame evidence remain separate gates.

The eight-document retired-session-ID cap is not cryptographic WebKit
document provenance; v2 challenge/nonce issue #203 remains open.
`first_scene_render_submit` is a Pixi renderer submission only, NOT an
actual GPU-composited first frame. Physical iPhone/iPad p50/p95,
thermal/memory and 50+ lifecycle cycles remain separate acceptance
evidence. Neither #204 nor Epic #202 closes on this patch.
