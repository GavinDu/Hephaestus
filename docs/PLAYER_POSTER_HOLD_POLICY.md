# Pure poster readiness policy — runtime Epic #202 / atomic #406

## Source-level boundary

`PlayerPosterHoldPolicy` is a newly compiled, pure Swift value-state machine under `Hephaestus/Player`, with independent Swift Testing cases under `HephaestusTests`. The Xcode project uses file-system-synchronized root groups, so new Swift files are compiled by their respective native targets without changes to project.pbxproj.

A single attempt pins published game ID, exact HTTPS player URL, a 32-lowercase-hex native document nonce, credential fingerprint and a **nonzero current attachment lease**. Invalid identifiers and insecure URLs start retired. Only a native-validated, currently attached, exact identity's first `first_scene_render_submit` can move `holding` to `sceneSubmitted`, at most once. `WKNavigationDelegate.didFinish` is deliberately only a navigation timing fact; it leaves the poster held. A genuine host-provided timeout or failure moves to recovery. Cancellation/retirement is terminal and discards any previous readiness. No arbitrary JS/native command bridge or score write exists here.

## Senior game-engine architect challenger

- **Trust:** `validatedByNativeGate` and `ownsCurrentAttachment` are NOT evidence when supplied by page code. When this policy is wired, derive them solely from native WebKit trusted main-frame/origin/schema/nonce validation (#369), pool ledger (#357), authenticated session/credential and exact lease transfer (#351/#352). A web page cannot invoke this policy directly.
- **Readiness:** `sceneSubmitted` means a renderer submission event has been accepted. It is NOT the first physically composed canvas pixel, interactive input, app review approval, or benchmark result. See physical cohort #276.
- **Recovery:** no internal timer exists. The host must arm a bounded deadline, record which attempt it belongs to, and deliver a timeout only if the same attempt is still attached. Late scene callbacks after recovery/cancel cannot revive an invalid poster.
- **No shipping UI behavior change:** the current `PlayerGameSheet.handleLoadFinish` still fades the poster on navigation completion; this new pure policy is deliberately not wired. Actual integration and screenshot acceptance remain in #353 and dependent #351/#352. Do not close those issues or Epic #202 on this unit policy alone.
- **Regressions:** the Swift suite checks navigation-only holds, genuine prewarmed scene before navigation completion, duplicate events, stale game/URL/document nonce/lease/credential, timeout and post-failure terminal behavior, invalid identities and 160 stale nonces.
- **CI gate:** all exact-head native Xcode, iPhone player smoke, iPad feed/presentation and backend contract jobs must pass before merging/closing this small slice, even if an unrelated live fixture or runner capacity blocks it. No artificial feed game or bypass.

Rollback: remove one new source file, one new test file, this document. Production behavior, score semantics and existing WebKit lifecycles remain unchanged.
