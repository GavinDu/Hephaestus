# Native result attestation provenance — Epic #202 / atomic #397

The production iOS `VerifiedRunResult` decoder previously treated `status == "verified" && result != nil` as sufficient for `PlayerGameSheet` / `PlayerResultSheet` to display a trusted result. That is **not** an independently replayed score: the generator historically accepted browser-controlled verdict fields and the current backend explicitly strips legacy `Verified` and `ActualScore`, disables browser POST verification and labels every live run provisional.

## Current narrow change

`VerifiedRunResult.isVerified` now additionally requires all three typed fields from the authenticated backend result response: `attested: true`, `rankingScope: "verified_only"`, `evidenceStatus: "verified"`. Missing or malformed fields fail closed. The existing session-bound, lease-checked and cancellation-safe coordinator fetch remains unchanged. The narrow JS message remains **only an opaque run-ID lookup hint**, not an attestation source. Neither client scores nor `verified:true` from page JavaScript are sufficient. This patch adds no score writes, does not claim to validate a signature, and does not create an attestor.

Swift Testing decodes a future result shape and rejects legacy status-only, null/missing provenance, provisional ranks, altered attestation, wrong status and absent results.

## Senior game-engine-architect challenge and exclusions

1. **Trust root:** the browser cannot supply this model. The native backend must supply fields only after independent server-side semantic replay and authenticated authorization. When that service is absent, all score-result UI remains hidden rather than promoting an old result.
2. **Deployed endpoint boundary:** generator [#447 / PR #448](https://github.com/GavinDu/html5-game-generator/pull/448) was merged as `5269b3778935c35f59d6928376099b45c097c2cf` and registers native `GET /v1/runs/{id}/result` on **source main**. The route returns 404 for missing or unauthorized runs and a fail-closed 503 (no score) for existing unverified runs. This is not proof the deployed service has been updated; verify authorized live deployment SHA separately. `GET /v1/runs/{id}` remains sensitive diagnostics and is NOT an alternative score API. A future independently replayed, persisted and version-bound positive attestation is still outstanding in generator #382/#429/#402.
3. **Identity and race:** existing native callback/attachment/session guards remain required. This decoder does not replace them and no JS message may bypass them.
4. **Rollout:** current published backend returns no independently verified run scores; the positive test documents a *future* typed contract, not real production success. Domain attestation, real-world iPhone/iPad presentation, GPU and lifecycle validation remain separate Epic gates.
5. **CI:** all exact-head GitHub Actions workflows, including iPhone/iPad native smoke and live published package prerequisites, must pass before this narrow PR merges. Do not waive failures. Physical devices are not implied by simulator CI.

Rollback: revert native decoder/test and this note; no storage migration or backend rollout.


## 2026-11-15 exact-head CI reconciliation

Historical draft PR #400 failed a real Xcode test assertion because an old `verifiedRunResultDecodesOutcomeAndRank` regression treated a legacy status-only JSON as independently verified. That test was corrected (the object still decodes but `isVerified` now correctly fails closed) without skipping it, and the three-field positive future contract remains covered. This clean rebased PR is based on current native main after strict prewarm v2 gate and permanent retry fixes merged; all new exact-head required native jobs must pass before issue #397 can close. Browser-emitted `verified: true` can never bypass the native server-only result lookup. No production attestor is claimed.
