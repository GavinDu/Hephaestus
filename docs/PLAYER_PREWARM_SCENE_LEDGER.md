# Per-document prewarm first-scene milestone ownership ledger

> **2026-11-19 post-permanent-router clean-main reconstruction:** This PR extracts only the bounded one-slot ledger, 7 native lifecycle invalidations, 3 scoped Swift Testing cases, and this document from the older 28-file draft PR #358. Already merged #397 attestation, #451 ID guard, existing UI, workflow, and backend source must remain intact. The actual listener-to-ledger record and once-only consume across attachment are NOT wired in this pure slice; see #352. Require all seven newly triggered exact-head native CI checks before closure. Do not merge the stale broad PR #358.

Parents: [Epic #202](https://github.com/GavinDu/Hephaestus/issues/202), [pool-owned first-scene handoff #352](https://github.com/GavinDu/Hephaestus/issues/352), [pre-navigation collector #351](https://github.com/GavinDu/Hephaestus/issues/351), independently testable [#357](https://github.com/GavinDu/Hephaestus/issues/357).

## Exact source boundary

`PlayerPrewarmSceneMilestoneLedger` is a **pure**, bounded, volatile, one-candidate ownership reducer. The recorded identity requires the exact expected game ID, HTTPS player URL, validated 32-hex current-document nonce, credential scope fingerprint and nonempty bounded runtime session ID. The only permitted event is a main-frame, speculative-navigation-started, integer sequence 0..100000, first-scene submission with duration 0..3,600,000 ms. No result notification, client `verified` flag, arbitrary native script API, user-bearing token or player score is stored.

`record` is once per document, and `consume` requires a positive **current attachment lease**, current pooled WebView ownership, attached state and matching exact identity. Mismatched attempts do not let an old Coordinator consume the candidate; successful transfer consumes its only slot and prevents re-recording. `invalidate` clears both status and payload. The shipping `PlayerWebViewPool` now clears the ledger on document preparation/start, nonce revocation, failed navigation, recycle, session rotation and speculative prewarm discard (including memory/expiry). Credential fingerprints remain hashed, never raw bearer strings.

Swift Testing asserts malformed identity, frame/attach state, wrong game/package URL, nonce, auth fingerprint and runtime session, stale/current lease, 0 and maximum bounds, once-only consumption, reset and **160 consecutive real native nonce generator transitions**. No fake game is injected into a WebKit host.

## Senior game-engine architect adversarial boundary

This is the **pure storage/ownership rule** only. The schema-v2, native-provenance pool listener was independently merged in [PR #413](https://github.com/GavinDu/Hephaestus/pull/413) at `a13b384`, but this deliberately **pure ledger is not yet populated from the listener**; that exactly-once wire/handoff is tracked in [#352](https://github.com/GavinDu/Hephaestus/issues/352). The attached Coordinator does not yet consume this ledger; that is [#352](https://github.com/GavinDu/Hephaestus/issues/352). The hold poster still currently fades after navigation finish, to be corrected in [#353](https://github.com/GavinDu/Hephaestus/issues/353). First scene **submission** still does not prove compositor first pixel, input readiness, verified score or real-device p95.

Do not claim #351's dedicated callback-before-attach acceptance, #352 transfer, or #353 poster complete from passing these pure tests. #286 strict deployed v2 capability/nonce first-callback remains OPEN, as do #204/#276 GPU compositor metrics, server score attestation and physical iPhone/iPad thermal. Require all seven **exact-head** native Xcode/unit, iPhone and iPad player smoke, iPad feed evaluator, backend/presentation CI jobs SUCCESS before closing this scoped reducer. Assistant-led senior game-engine architect challenge is not independent human or hardware signoff.

Rollback removes only the ledger type, its pool invalidation calls and Swift unit tests/doc. No runtime first-scene message is trusted or emitted by this slice.


## Canonical game-query binding — 2026-11-15 architecture challenge

The previously drafted `Identity.isValid` checked HTTPS + nonempty gameID but did not prove the player URL actually contained that game. The source now requires exactly one `game` query value equal to `Identity.gameID`, and rejects a missing, duplicated, foreign, credential-in-URL or fragment-bearing URL before recording *even when observed and expected identities are both identical malformed copies*. Swift negative tests prove this fail-closed. A trusted main-frame callback still requires current nonce/credential/attachment provenance and a separately reviewed one-shot real transfer; this is only a pure candidate ledger, not a GPU first-pixel signal or a trusted run verdict.

## 2026-11-17 skeptical source hardening: path and byte identity

The initial pure ledger accepted `https://.../any-path?game=sky` when observed/expected invalid identities matched, and checked only `runtimeSessionID.utf8.count <=128` without the protocol's printable-ASCII requirement. Tightened the **independent ledger admission itself** to require canonical HTTPS `/player` path, nonempty host, no URL userinfo/fragment, exactly one `game` query matching the immutable game ID, game ID <=128 UTF-8 bytes, 32-hex native nonce, credential fingerprint 1..256 UTF-8 bytes, and printable ASCII runtime session ID 1..128 UTF-8 bytes. The pure Swift negative matrix now covers wrong path, duplicate/foreign game query, embedded credentials/fragment, spaced/emoji/overlength session, and overlength credential, even when the offered and expected identities are equally malformed.

This narrows candidate poisoning risk and aligns with separate #451 protocol ID validation without depending on draft #452. **No trust claim:** the pool listener still must validate actual main-frame origin/nonce and the attached Coordinator must lease-transfer exactly once (#352); the ledger is not yet wired. All seven new exact-head native required CI checks are mandatory before #357 can close. Failure in live iPhone/iPad smoke is not bypassed; poster and GPU release remain #353/#276.

## Post-ledger speculative capture slice (#561)

The native pool-owned, origin/main-frame/current-document-validated WebKit metric router now stages only a schema-v2 `first_scene_render_submit` in the one-slot ledger, through a pure transactional policy that commits both first-scene admission and the candidate together. Failed, duplicate, unsupported or stale callbacks modify neither state. The recorder was implemented separately under #561; current-lease attached consumption is the dependent #562 slice below. Both require their own exact-head CI. Real first composited GPU pixels are not established by JS render submission.

## Current-lease attached consumption (#562)

The attached native Coordinator receives a prewarm scene submission **only** after the permanent pool router has acknowledged the current attachment lease, and the candidate exactly matches the current URL/game, native document nonce, credential fingerprint and bounded session. The pool first *offers* a candidate without consuming it. The Coordinator stages its metric, scene, launch and session reducer checks on local copies and synchronously asks the pool to revalidate the current lease and commit the **same** offered candidate. Only then are the local reducers committed and the existing SwiftUI renderer-submitted callback delivered. A rejected Coordinator admission does not prematurely burn the one-slot ledger; duplicate or replaced candidates still cannot be consumed. Without an admitted candidate, the existing attached document callback must independently validate schema-v2/current-session messages; neither navigation `didFinish` nor prewarm-hit fabricates first frame readiness. This is not first GPU compositor presentation, which remains #204/#276, and it does not fade the poster (#353).
