# Native result attestation provenance — Epic #202 / atomic #397

The production iOS `VerifiedRunResult` decoder previously treated `status == "verified" && result != nil` as sufficient for `PlayerGameSheet` / `PlayerResultSheet` to display a trusted result. That is **not** an independently replayed score: the generator historically accepted browser-controlled verdict fields and the current backend explicitly strips legacy `Verified` and `ActualScore`, disables browser POST verification and labels every live run provisional.

## Current narrow change

`VerifiedRunResult.isVerified` now additionally requires all three typed fields from the authenticated backend result response: `attested: true`, `rankingScope: "verified_only"`, `evidenceStatus: "verified"`. Missing or malformed fields fail closed. The existing session-bound, lease-checked and cancellation-safe coordinator fetch remains unchanged. The narrow JS message remains **only an opaque run-ID lookup hint**, not an attestation source. Neither client scores nor `verified:true` from page JavaScript are sufficient. This patch adds no score writes, does not claim to validate a signature, and does not create an attestor.

Swift Testing decodes a future result shape and rejects legacy status-only, null/missing provenance, provisional ranks, altered attestation, wrong status and absent results.

## Senior game-engine-architect challenge and exclusions

1. **Trust root:** the browser cannot supply this model. The native backend must supply fields only after independent server-side semantic replay and authenticated authorization. When that service is absent, all score-result UI remains hidden rather than promoting an old result.
2. **Endpoint mismatch:** native `GET /v1/runs/{id}/result` is not registered in the current generator route table. Its current `GET /v1/runs/{id}` is sensitive diagnostic evidence only, NOT an alternative verified-score API. Do **not** silently redirect native to the diagnostic endpoint. A separately reviewed, versioned, authorized result endpoint and canonical immutable full IR identity remain outstanding under generator #382/#429/#402.
3. **Identity and race:** existing native callback/attachment/session guards remain required. This decoder does not replace them and no JS message may bypass them.
4. **Rollout:** current published backend returns no independently verified run scores; the positive test documents a *future* typed contract, not real production success. Domain attestation, real-world iPhone/iPad presentation, GPU and lifecycle validation remain separate Epic gates.
5. **CI:** all exact-head GitHub Actions workflows, including iPhone/iPad native smoke and live published package prerequisites, must pass before this narrow PR merges. Do not waive failures. Physical devices are not implied by simulator CI.

Rollback: revert native decoder/test and this note; no storage migration or backend rollout.
