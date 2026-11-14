# Session-isolated player WebKit website data

Parent [Hephaestus Epic #202](https://github.com/GavinDu/Hephaestus/issues/202) · P1 cache / lifecycle [#205](https://github.com/GavinDu/Hephaestus/issues/205) · native launch contract [#203](https://github.com/GavinDu/Hephaestus/issues/203).

## Trust boundary and ownership

The iOS app stores the native backend bearer in Keychain. Prior to this change, the production `PlayerWebViewPool` constructed a vanilla `WKWebViewConfiguration`, which implicitly used the **default persistent** `WKWebsiteDataStore`. Replacing the WKWebView or loading blank HTML after a user switch does not itself prove all website cookies/cache/IndexedDB were revoked. The browser runtime can also retain a separate `sessionStorage` bearer; the native Keychain session and WebKit session are **not automatically equivalent**.

- Each player credential epoch now owns **one explicitly non-persistent WebKit data store**. Warm and attached player use that same store, preserving the same-page prewarm handoff. This store does not write website data to disk.
- `invalidateForSessionChange()` rotates both the store and `WKProcessPool` before future views can be created. It also stops loading and blanks the stale view as before. Old store instances may remain alive until their previous WebViews are released, but subsequent player sessions never receive the old store object.
- Other app browsing, native URLSession and any unrelated website data are untouched. This does not clear Safari or use `WKWebsiteDataStore.default().removeData(...)`, which could disrupt unrelated sessions.
- Unit tests verify separate factory calls are distinct and explicitly non-persistent. They do **not** establish actual data deletion timing, identity propagation, WebKit cache revocation or correctness of private-game auth.

## Required validation / rollout before closing #205

1. Test cold/prewarm/attached player, login, logout and native token replacement on **real iPhone and iPad**, including retained old WKWebView, WebContent process termination and 50+ open/swipe/close cycles. Confirm no cross-account cookies, IndexedDB, storage or private asset response can be read on a replacement page, including after app restart.
2. Confirm public games still load and protected group/private game fetches authenticate correctly. The existing native `BackendConfig.applyAuthentication` applies to URLSession, not automatically to WebKit subresource requests; the web runtime reads a separate `sessionStorage` token. This patch deliberately does **not** inject a Keychain bearer into JavaScript/URLs. Establish a backend-scoped, short-lived, HttpOnly/Secure/SameSite player session or equivalently safe authenticated asset transport before claiming protected play is supported.
3. Recheck moderation, takedown and eligibility at each package/asset request and prior to reuse of already-loaded content; bound offline reuse to explicit authorization proof. A non-persistent store is not an authorization gate and does not automatically invalidate CDN entries.
4. Verify shared WebKit process-pool isolation effects and review any sign-in UX regression before shipping. Use exact-head iPhone/iPad/Xcode GitHub Actions; **no bypass** on red or missing jobs.

**Architecture challenger verdict:** This narrows the cross-account data-retention surface without making data-only Game IR authoritative or claiming independent replay verification. #203/#205/#360/Epic #202 remain open until integrated and real-device evidence exists.
