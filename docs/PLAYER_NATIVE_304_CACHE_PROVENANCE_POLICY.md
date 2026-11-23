# Native authorized HTTP-200 → HTTP-304 cache provenance contract

**Atomic source slice:** [successor issue #758](https://github.com/GavinDu/Hephaestus/issues/758) under [Runtime Next Epic #642](https://github.com/GavinDu/Hephaestus/issues/642). **The real WebKit integration remains [#726](https://github.com/GavinDu/Hephaestus/issues/726) and is OPEN.** Original Epic #202 is historical requirements context, not an intake location.

## What this code proves

`PlayerAuthorizedDocumentRevalidationPolicy.authorized200` produces a value-only `Authorized200Receipt` for a **native-supplied** terminal HTTP 200 whose exact same-origin player URL and public game ID, main-frame, live current attachment, credential epoch, lease, native document nonce, optionally ETag and corroborated authorized cache representation were already validated by a trusted caller.

A candidate 304 is admitted by the **pure** `admits304` function only with matching receipt, current game identity, immutable player URL, native credential epoch, lease, document nonce and native evidence of the cached representation. The helper refuses fresh/cold 304, untrusted parent URL/port, foreign game, wrong quality or origin, wrong ETag, untrusted frame, replaced credential/document, old lease, invalid nonce and inapplicable non-304 HTTP codes. A 304 does **not** supply bytes and cannot prove rendering/first input/IR SHA/authorization from an untrusted page message.

## Explicit integration boundary and rollback

This PR deliberately **does not change** shipping `PlayerPrewarmResponsePolicy.shouldCacheResponse(statusCode:)`, which currently accepts `statusCode < 400`. That existing status-only behavior is not secured by an unused helper. Pending [#691/PR #693](https://github.com/GavinDu/Hephaestus/pull/693) would change 1xx/3xx handling, but its mandatory iPad Comments test is red and must not be bypassed.

To finish real [#726](https://github.com/GavinDu/Hephaestus/issues/726), a separate integration PR must obtain and **prove** actual `WKNavigationResponse` 200/cache representation behavior for both speculative and attached delegates, store/revoke receipts only with a trusted pool current-document owner, handle WebKit 304 that may never be directly surfaced, and enforce the new policy on both delegates. A credential-epoch change must invalidate cached proof *before* any 304 decision. If no positive native cache/provenance evidence exists, reject the 304 and recover safely. Do not fabricate a served game, owner identity, ETag, simulator screenshot or origin inventory.

## Tests and adversarial review

Swift Testing covers 160 stale native epoch/lease permutations, cold 304/no receipt, 200 vs 1xx/206/3xx/4xx, current auth/nonce/main-frame/same-origin, wrong quality and wrong game, poisoned ETag, wrong port/userinfo/fragment and missing cache representation. Python source guard confirms the shipping status admission function is **not** silently rewired or misrepresented as protected; no network, JS command or second package fetcher is introduced. Test sample URLs are **pure model fixtures only**, never published backend games or server-side score attestation.

Every required exact-final-head Xcode, iPhone, iPad, backend/presentation and screenshot GitHub Actions check must succeed before merging #758. It does **not** close #726, #203, #202 or #642. Reviewer should reject premature proof semantics. Rollback: remove one pure policy, tests and this design note; no production navigation or cache change.
