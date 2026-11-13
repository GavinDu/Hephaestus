# Bounded native verified-run notification ownership (Epic #202 / #205)

The real `PlayerWebView.Coordinator` now uses
`PlayerVerifiedRunNotificationGate` instead of an unbounded Set of run
identifiers. It records at most 32 recent IDs, permits at most two simultaneous
backend result lookups and keeps only the newest deferred ID, preserving
latest-result-wins behavior for in-page Play Again loops.

The Coordinator weakly refers to the exact pooled WKWebView. Every incoming
trusted main-frame result hint checks active attachment lease, game,
runtime-session binding and the narrow message schema. A backend result is
delivered only after `fetchVerifiedRunResult` independently reports
`isVerified`, the game matches, the result ID is latest and the host is
still attached. All lookup tasks are canceled and gates reset on dismantle
**and** legitimate new document navigation; older async completions cannot
revive a retired session or emit misleading fetch errors. This adapter does
NOT prove server attestation: generator #360 remains required.

Swift truth tables test the bounded queue, 100+ repeated results, deferred
latest-only delivery, duplicate suppression and detachment reset. Required
exact-head iPhone/iPad native CI and physical-device 50+ cycles are still
necessary. Eight retired WebKit session IDs remain a weak defense against
arbitrary old callbacks; a per-navigation nonce bound to attachment lease
is the future stronger trust contract. Keep #203, #205 and #202 open.

## Coordinator handoff / delayed-callback guard

A rapid Retry/Play may attach a new SwiftUI Coordinator to the **same**
pooled WKWebView before the old Coordinator's dismantle callback. A runtime
session match or nonterminal launch phase is not sufficient to authorize the
old Coordinator to change the prior sheet.

`PlayerHostCallbackDeliveryPolicy` now requires **both** the current
WebView attachment lease and a nonterminal launch state for incoming script
messages, deferred first-input callbacks, navigation and response decisions,
progress KVO, prewarm completion, navigation errors and WebContent death.
Stale navigation responses are canceled rather than allowed to affect the
new owner. Pure Swift tests reject old leases through 128 successive
handoffs and terminal/detached states.

This closes the delayed native UI-callback ownership gap found during
the PR #232 review, **not** the full document provenance problem: a
legitimate-looking stale same-origin message from an old document may still
be accepted by an active Coordinator after eight retired session IDs age
out. Native-issued per-document nonce/epoch attestation and physical
hardware validation remain mandatory in #203/#204/#205.
