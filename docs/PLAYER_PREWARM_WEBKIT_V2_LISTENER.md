# Epic #202 / native pool-owned WKScriptMessageHandler for prewarm metrics — P0 #351

## Why this source change is necessary

Before this slice, `PlayerWebViewPool.makeWebView()` created `WKWebView` without any `hephaestusRunResult` handler and `PlayerWebView.makeUIView` installed the coordinator listener **only after** speculative navigation. A browser `first_scene_render_submit` metric emitted during prewarm could therefore be lost; `didFinish` is only navigation complete, **not** a GPU present nor a scene-ready signal.

This incremental source change layers on [pure admission #369 / draft PR #371](https://github.com/GavinDu/Hephaestus/pull/371). It installs one pool-owned `WKScriptMessageHandler` in the WKWebViewConfiguration **before** WKWebView creation, re-registers a single handler on a recycled unattached WebView before `prewarm(...).load`, and lets the already-shipping `makeUIView` remove that handler name before installing the attached coordinator listener. No additional JS-exposed native message name is added. The pool listener may observe only `player_metric:first_scene_render_submit`; all other message types, including verified-run notifications, are dropped.

`collectPrewarmMetric` requires:
- Message `webView` identity equals the one currently owned pool instance; not attached; actual view URL equals the exact current expected /player URL.
- WebKit-native `isMainFrame` and security-origin tuple (scheme, host, port) equal configured backend origin.
- Native current document nonce and `navigationStarted`, stable credential-scope fingerprint, exact expected game ID parsed from a native-origin URL.
- The strict pure #369 schema-v2 gate: bounded typed ms/sequence/session, exact field set, current 32-lowercase-hex nonce, single first scene observation.

On every new prepared/provisional navigation, failed/revoked navigation, credential invalidation, eviction, recycle, and WebContent termination, the captured scene snapshot resets. A stale prior document cannot borrow another game's metric. No raw game response, creator data or tokens are logged.

## Senior game engine / WebKit security review — explicit exclusions

1. **Not yet transfer:** This change stores a bounded observation inside the pool but does **not** expose an exactly-once consumed milestone to the SwiftUI sheet; that distinct lease-based handoff remains [#352](https://github.com/GavinDu/Hephaestus/issues/352) and pending ledger [#357](https://github.com/GavinDu/Hephaestus/issues/357). Do not fade the poster on this alone (#353).
2. **Schema 2 only:** Current shipped Pixi producer may still send schema 1; the pool intentionally drops it, never invents/auto-upgrades a nonce. Full schema-v2 producer negotiation #286 is a separate release gate.
3. **Visible frame:** First canvas scene submit is not GPU-composited first visual frame or touch interactive readiness. Physical iPhone/iPad cohort measurement remains #276/#204, 50-cycle thermal/memory #279.
4. **No new control capability:** The handler never evaluates arbitrary page code or grants a native API; it cannot notify of a verified run or write trusted scores. The existing attached coordinator remains the only run notification sink.
5. **Simulator acceptance pending:** To close #351, instrument a real test prewarm-before-attach with schema-v2 first scene emit; wrong-origin iframe, redirects/new navigation epoch, same-view retry, WebContent termination and credential rotation; confirm only one WK handler registration at a time, exact old-coordinator teardown semantics and no pooled WebView retention leak.
6. **CI:** All mandatory exact-head iPhone/iPad simulator, native URL/Xcode, backend/screenshot, live package fixture and iPad evaluator jobs must pass. The separately observed live canonical package mismatch #368/#288 is a real dependency; do not waive it. An assistant source challenger is not independent hardware or App Store certification.

**Deployment/rollback:** Rollback the listener integration without removing the narrow pure #369 gate; the legacy attached coordinator behavior and no-new-native-API guarantee are preserved. Until tests/physical evidence, keep this PR draft and Epic #202 open.


## 2026-11-15 clean-main rebased implementation
Ported the listener-only delta from historical draft PR #374 after atomic strict v2 parser PR #371 merged as 6b9974022a49fb9ed3c5bb46a641e0df47de5ee1. The pure gate and its negative tests were **not duplicated**; only the native pool listener, provenance policy, lifecycle resets and origin negative tests are introduced. Exact-head GitHub Actions on the fresh main-based PR must succeed; old PR #374 green results are not reused for this version. Live transfer #352, ledger #357 and poster readiness #353 remain open. Rollback is limited to new listener/provenance source and tests.

## WKSecurityOrigin default-port normalization — adversarial correction (2026-11-15)

The initial rebased origin policy compared `WKSecurityOrigin.port` against `backendURL.port ?? 443/80` without normalization. WebKit's origin implementation represents an omitted/default scheme port as `0` at its API boundary (see [WebKit source discussion](https://trac.webkit.org/timeline?daysback=4&from=2019-10-30) and [WebKit SecurityOrigin normalization](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/page/SecurityOrigin.cpp)). That would drop otherwise legitimate prewarm scene messages on ordinary HTTPS while pure tests that hardcode 443 falsely passed.

The reviewed correction maps **only** WebKit origin port `0` to the default port for its strictly matched `http`/ `https` protocol. The expected backend remains the exact actual configured port. A custom HTTPS 8443 or local HTTP 8123 must match exactly: an origin port of `0` does **not** bypass the custom-port check. Swift negative regressions now cover implicit/default 0, explicit scheme port, custom port and foreign default alias. The v2 nonce, main-frame, view identity, URL, game and credential checks are unchanged. New exact-head iPhone/iPad native GitHub Actions are required; no merged or device claim from source review.
