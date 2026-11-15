# Attached WKWebView default origin ports — Epic #202 / native atomic #428

## Evidence and scope

The attached PlayerWebView.Coordinator.sameOrigin(_:) previously compared WKSecurityOrigin.port directly to the configured backend URL's 443 (HTTPS) / 80 (HTTP) default. WebKit security origin can report **0** for an implicit default port. In that case a legitimate backend page's strict metric or run-ID hint would be dropped before the schema, nonce and session checks ran. This is a **source correctness/security consistency** finding and not measured physical-device loss.

The new pure PlayerWebKitOriginPolicy.matches recognizes 0 **only** as 443 on HTTPS or 80 on HTTP, and compares it with the expected actual port. Explicit 8443/8123 still require 8443/8123 and reject observed zero. Non-HTTP scheme, wrong host/scheme, out-of-range ports and URL userinfo fail closed. The production Coordinator retains main-frame, pooled WebView/attachment lease, navigation-document nonce, runtime-session/game/schema and replay-result checks; there is no new script or native control surface.

Swift Testing provides positive 0/default and exact custom examples and negatives for custom-port alias, foreign host, HTTP/HTTPS downgrade, invalid ports, file URL and userinfo.

## Skeptical senior game-engine-architect review

- **Trust root:** a matching origin alone proves neither a genuine render nor a verified score. Browser-owned verified fields are not admitted by this helper. Runtime first-scene metrics remain renderer **submission**, not GPU-composited presentation.
- **Preserve strictness:** normalizing default WebKit origin port 0 must never normalize a different explicit port. An origin with wrong host, scheme or userinfo is rejected; the attached view must still be the active lease/document.
- **Integration:** generator schema-v2 deployment, pool-owned listener #351 / PR #413, first-v2-only policy #286 and exactly-once transfer #352 are separate. Reconcile helper reuse when merging listener but do not move a prewarm metric into the attached coordinator without a lease-bound ledger.
- **Acceptance:** all mandatory exact-head seven native GitHub Actions jobs, including iPhone/iPad presentation and genuine public fixture smoke, must pass before merge/issue close. No physical-device thermal, compositor or App Review 4.7 acceptance is inferred from simulator CI. Live public game/package mismatch #368 is a separate deployment blocker.

Rollback: revert only the pure origin helper, Coordinator wrapper and Swift test/document changes.
