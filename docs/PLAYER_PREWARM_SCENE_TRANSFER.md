# Runtime Epic #202 — exactly-once prewarm scene transfer (#352)

## What is implemented

This is a **stacked draft** on native pure scene-ledger #357 (PR #358), which itself was rebased on the merged pool-owned strict WebKit listener #351 (PR #413). Neither the product's shipped poster nor its GPU frame-presentation contract is changed here.

The existing implementation set `isAttached=true` in `PlayerWebViewPool.take` before SwiftUI removed the pool handler and registered the Coordinator's handler. That transition could cause a genuine first-scene message to be rejected by the old owner while not yet delivered to the new owner.

To avoid WebKit callback loss on handler replacement, this change keeps **one WKScriptMessageHandler registered for the pooled WebView's entire lifetime**. Its static pool owner only retains a **weak** attached Coordinator delegate. Ownership is:
- **Speculative** before Play attachment: validate native main-frame, current WebView/URL, exact origin/port, document nonce, credential fingerprint, bounded schema-v2 first scene and record candidate.
- **Transferring(current nonzero lease)** after `take` but before Coordinator installation: keep the same strict pool callback admission even though the view is marked attached. Invalid/old lease, new document or navigation failure cannot transfer prior metrics.
- **Attached(current lease)** after synchronous `attachMessageReceiver`: consume the one bounded candidate only when game/URL/nonce/current credential/lease match and route all subsequent callbacks through the same handler to the Coordinator's existing origin, schema, session, and lease validation. Duplicate candidates are refused.
- **Retired/invalid** on recycle, auth rotation, eviction, failure, new document or stale lease: no detached callback may update the player.

The native Coordinator binds the transferred session and schema 2 and records **scene submission only**, not a trusted score, playable input, verified run, or GPU-composited frame.

**Security hardening review (2026-11-15):** the permanent handler checks the actual Keychain fingerprint at every WebKit callback **before** routing, not only when `take` begins; the Coordinator installation also synchronously checks the current auth scope. A mid-flight login/logout can invalidate the old pooled view and weak receiver before its notification is delivered. A pure routing policy rejects false credential epoch in all three phases, zero current attachment lease and contradictory detached state retaining a Coordinator/transfer lease. Swift negative tests cover each case; no raw credential is logged. A newly invalidated view is never entitled to deliver its queued script message.

## Senior game-engine architect skeptical review and limitations

The pure unit tests cover speculative→transferring→attached routing, stale lease rejection, no-receiver drop, duplicate scene, exactly-once consume and invalidation; existing #357 tests cover 160 nonce changes, malformed URL/gameID/credential/session/quality, invalid sequence. These tests do not prove WebKit message delivery order on an actual iPhone/iPad; the required dedicated simulator callback-before/after-attach/redirect/termination test and real device latency evidence are still acceptance blockers. Physical iPhone/iPad presentation + 50-cycle thermal checks are separate issues #276/#279.

The narrow handler is **not a generalized JS/native bridge**. It can receive the previously shipped single message name with a validated player metric or an opaque run lookup hint; the Coordinator remains the only run-result lookup owner. The immutable full package identity, schema-v2 producer deployment and first-callback-only admission (#286) still require verified integration. The shipping poster currently fades on navigation `didFinish`; do not close #353 on this PR.

If the native handler's `WKScriptMessageHandler` weak receiver or callback ownership fails in CI, fix source/actor isolation rather than removing tests or making new privileged bridge APIs. All seven exact-head GitHub Actions jobs and independent iPhone/iPad simulator evidence are mandatory before a merge/issue closure. Keep this PR **DRAFT** and #352 OPEN while checks or dedicated callback-order proof are missing.

## Rollout and dependency order

1. Merge #358 after seven exact-head required jobs pass, close only #357.
2. Retarget this stacked PR onto current main (reconstruct it if required to avoid duplicate commits), rerun *its own* seven required native jobs and dedicated WebKit callback tests.
3. Integrate attempt-bound poster-hold policy #406/#409 only after #352 is proved, then correct shipping poster #353 and separately validate actual GPU composition #276.

Rollback removes only the permanent routing/transfer delta; #413 pool-owned listener and #357 pure ledger remain available.
