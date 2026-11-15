# Native player recovery: permanent HTTP failure retry policy

Epic [#202](https://github.com/GavinDu/Hephaestus/issues/202), recovery parent [#280](https://github.com/GavinDu/Hephaestus/issues/280), independently testable slice [#317](https://github.com/GavinDu/Hephaestus/issues/317).

## Problem and scope
The production player previously showed Retry on every failed WebKit page and reloaded any error when returning to foreground, even when the same game remains inaccessible or permanently invalid. This PR rebuilds the narrow source/test changes from obsolete merge-conflicted PR #318 onto the current protected main. HTTP authorization (401/403), unavailable (404/410), invalid/oversized package (400/409/413/422) and incompatible runtime (426) are permanent for the current navigation; show only the truthful failure and Return to feed. Connectivity/transient server outcomes (408/425/429/5xx) remain recoverable; unknown WebContent errors can be retried manually only. Existing connectivity and foreground policy still guards automatic transient retry.

The category is tied to the active SwiftUI load attempt and reset on navigation success and retry. Account epoch invalidation remains a hard stop. No Game IR, trust bridge, verified score, native data model or backend contract changes.

## Adversarial senior game-engine-architect scope review
- Fail closed on permanent failures; never spin on background→foreground or silently reauthenticate. The existing sanitized error text and explicit Return to feed remain.
- Test the permanent/transient HTTP taxonomy, nil/unknown category, and existing foreground connectivity conditions. Verify no regression in native iPhone/iPad Player presentation suites on the exact head.
- This **does not** implement the full dedicated sign-in, update-app, package details or deployed HTTP response UX matrix of #280/#53; no physical device GPU/memory/thermal or App Store release claim. In a future #280 slice, inspect real 401/403/422/426 presentation and actions on iPhone+iPad.
- Merge and close #317 only after all seven required exact-head CI jobs pass. Do not waive unrelated mandatory feed-smoke failures. Rollback is limited to the two Swift files and this note.
