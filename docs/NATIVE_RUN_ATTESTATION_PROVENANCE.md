# Native verified-run attestation provenance — Epic #202 / atomic #397

## P0 security finding
Production native `VerifiedRunResult.isVerified` previously accepted `status == "verified" && result != nil`. Historical browser-controlled score/status fields do not prove independent deterministic server replay, and must not promote gameplay results as trusted. This source replacement is rebuilt on current iOS main, superseding outdated draft PR #414 without porting any unrelated changes.

## Narrow production correction
`VerifiedRunResult` now requires all of `status: "verified"`, non-null result, `attested: true`, `rankingScope: "verified_only"`, and `evidenceStatus: "verified"`. Missing, null, wrongly typed, provisional, and legacy fields fail closed; historical records still decode safely for diagnostics. Genuine server-result API response is the only acceptable provenance source; the narrow JS callback is a run-ID lookup hint, never a score or native attestation.

Native Swift Testing covers a future complete typed result, legacy status-only records, each missing/null/invalid provenance field, incorrect statuses and absent result, forged JavaScript-style `verified: true`. No bypass or mock positive production score is added.

## Senior game-engine-architect adversarial constraints
1. The new typed fields are **necessary but not sufficient** for authority: the generator must issue them only after independent server-owned deterministic replay, authorized identity/package snapshot, immutable full IR digest, version/seed/input trace binding, nonreplayable session issuance, durable verdict transitions, and permission checks. Generator #382/#428/#402 and associated issuance tickets remain open.
2. The browser must never be able to directly supply these fields to native UI. Preserve current origin, nonce, main-frame, lease, session and result-fetch identity gates; server TLS/auth and back-end version binding remain distinct security boundaries.
3. Source-only tests and simulator CI do not validate actual physical iPhone/iPad first compositor pixels, 50-cycle memory/thermal teardown or deployed backend rollout (native #204/#276/#279).
4. All required exact-head native CI jobs, including live iPhone/iPad player-smoke and iPad screenshot evaluator, must pass before merging/closing #397. Preserve authentic backend fixture failure evidence, never fake/skip an unready feed.
5. Rollback is limited to the typed native decoder, unit negative matrix and this design note; no persistence migration or score-authority claim.

The current backend does **not** independently issue positive verified gameplay outcomes. Empty verified-result UI is correct fail-closed behavior, not a regression to paper over.
