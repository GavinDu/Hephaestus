# Native player retry policy for permanent HTTP package failures

Parent [Epic #202](https://github.com/GavinDu/Hephaestus/issues/202), [full recovery matrix #280](https://github.com/GavinDu/Hephaestus/issues/280), scoped [#317](https://github.com/GavinDu/Hephaestus/issues/317).

## Problem and narrow change

The WKWebView player already maps HTTP errors into distinct, user-readable error categories but offered the same Retry button for *every* failure. A 401/403 account entitlement failure, 404/410 removed game, 400/409/413/422 invalid/oversized package or 426 unsupported runtime cannot be repaired by reloading the same URL on foreground. Previously the sheet's scene-foreground handler retried any load error whenever connectivity came back, repeatedly sending a futile request.

The shipping sheet now records the category **for the current navigation attempt**. Manual Retry appears only for a transient network failure or unknown recoverable WebContent error; auto-retry when returning from background requires a known network category, the existing connectivity check, a previous background transition and an actual failed load. No loaded game is reloaded merely because the app foregrounded. Successful navigation, a manual retry or auto retry clears the category. An account epoch change marks the result access denied, invalidates the WebView pool and still offers Return to feed; the player does not silently reinstall a previous session. Repeated WebContent termination remains explicitly manually retryable instead of looping on foreground.

User-facing explanation text remains the existing sanitized message, never raw failed URLs or tokens. No extra JS bridge, Game IR semantics or gameplay score code is introduced.

## Challenge and remaining gates

- Swift Testing asserts each permanent HTTP status 400/401/403/404/409/410/413/422/426 refuses both manual and automatic futile retry; 408/425/429/5xx transient statuses can retry; unknown and missing categories are manual-only.
- All seven *exact-head* required native CI tests on iPhone/iPad simulator, Xcode unit tests, iPad UI evaluator, presentation/backend contracts must pass before merging/closing #317. Do not reuse a green run from #312 or disable live fixture tests.
- A user may regain access after reauthentication or an updated package appears; this UI requires explicit Return to feed and reopening instead of automatic repeated attempts. A future full #280 acceptance matrix should implement dedicated sign-in/update actions, explicit 422 resource-budget detail, signed-out/private/no-access distinctions and deployed backend error fixtures.
- Actual physical iPhone/iPad screenshots, network offline/online races, first compositor frame and 50-cycle thermal results belong to #280/#204/#205/#276/#279 and Epic #202. This source-only policy is not Apple approval or independently reviewed hardware evidence.

Rollback is limited to the Swift retry policy, sheet category state and tests.
