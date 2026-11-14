# Native WebKit document-epoch challenge v2 — incremental Epic #202 / issue #203

## The risk in the shipping host

The pooled native WKWebView previously trusted page-generated schema-1
`sessionId`, alongside same-origin/main-frame/game/attachment checks.
The bounded retired-ID guard only remembers eight navigation epochs;
an old queued message after nine-plus different documents could become
the *first* accepted session in a new document. That is a document
freshness/control-plane problem, not independent game-result attestation.

## Implemented native production integration (this draft)

A pure `PlayerNativeDocumentEpochGate` holds **one** random nonce and
an explicitly-armed navigation-start bit. Each nonce is 16 bytes from
Swift `SystemRandomNumberGenerator` encoded as exactly 32 lowercase
hex characters, generated just before a trusted main-frame player load.
No user/account/token data or raw nonce is logged or sent to analytics.

`PlayerWebViewPool` owns the gate, including:
- `prewarm`: install a fresh `WKUserScript` at `documentStart`,
  **main frame only**, in the page content world before `load`.
- `take(url:)`: preserve an already-running/loaded prewarm's nonce,
  otherwise prepare a fresh challenge *before* the new load.
- `recoverUnobservedWarmupIfNeeded`: rotate nonce before its guarded
  recovery reload; old prewarm response cannot be attached as fresh.
- `didStartProvisionalNavigation`: both warmup and interactive
  navigation delegates consume the one armed start. A script-driven
  unexpected reload invalidates the old nonce instead of inheriting it.
- `markFailed`, retry recycle, memory pressure/unattached prewarm
  eviction, account/credential rotation and WebContent termination
  invalidate the nonce. No historical token array grows with gameplay.

The trusted generator [merged #372](https://github.com/GavinDu/html5-game-generator/pull/372)
supports `window.__hephaestusNativeBridge = {schema:2,documentNonce}`
emission for `player_metric` and `verified_run_available`; a malformed
advertised bridge fails closed. Native checks the current pooled view,
live attachment lease, origin, main frame, gameID, valid current
navigation nonce and exact schema-2 metric/result fields before binding
the first session or consuming metric sequence. Once a document has
successfully emitted v2, native rejects v1 for that same document.

## Compatibility and unresolved security

**Important:** this stage keeps native schema-1 messages when no
successful v2 event has yet been seen in a document. This preserves
older generator runtime versions during the two-repository rollout.
It means the old eight-ID stale-message race is NOT FULLY ELIMINATED
for legacy v1 traffic; a queued v1 message could still arrive before
the new document sends its first v2 event. Shipping strict v2 must
be explicitly negotiated after generator #372 and companion native CI:
once the installed native runtime requires v2, reject **all** schema-1
messages on any prepared document, including the first one, without
fallback. Do not describe this compatibility stage as cryptographic
attestation or full #203 completion.

This page-world nonce proves freshness against earlier queued
document messages that cannot see the next document's challenge.
It does NOT prove honest trusted JS if hostile same-origin executable
code is ever allowed. Continue banning user-authored scripts and
keep independent backend score attestation issue #360 open.

## Architect challenger and test plan

Three Swift Testing regressions exercise 160 random navigation epochs,
no reuse or unbounded retired list, invalid nonce format, fail-closed
unexpected self-navigation and exact versioned metric parsing with
strict field sets. The existing 128-lease callback test and lifecycle
regressions must remain intact. Additional release gates:
- Exact-head iOS build/unit, iPhone WebView smoke, iPad feed/player
  smoke and evaluator, presentation backend contract.
- Generator v2 source-extracted/Chromium/WebKit CI and compatibility
  test, with no unknown native-control messages.
- Post-rollout **strict-v2 mode** with 128+ *actual* WKWebView
  navigation/reload/prewarm/termination/credential-change tests,
  including message interleavings and unexpected redirects.
- Actual device iPhone/iPad GPU first-frame p50/p95, memory/thermal,
  resource teardown, private cache revocation and 50+ lifecycle loops.

The native PR is rebased on merged production main, with parser guards from #247 retained. Do not waive any required CI check,
do not merge a queued/failed head, and do not close Epic #202 or #203
until strict native v2 plus hardware and backend attestation acceptance.


## Strict-v2 admission policy (staged, NOT enabled in shipping host)

A senior game-engine architecture challenge identified a first-message
downgrade race: allowing schema 1 **until** the first schema-2 callback
lets a queued old-document v1 event potentially bind the fresh runtime
session before the correct document sends its challenge. Therefore
`PlayerNativeBridgeVersionGate` now has an explicit `.requireV2` policy:
it rejects schema 1 from the **first callback**, before session binding,
and remains strict even after a new navigation or gate reset. An invalid
v1 event cannot select compatibility. A 160-document pure-state test
combines the policy and per-document fresh nonce, including old-nonce
rejection. This only proves policy logic, **not** 160 actual WebKit loads.

The production Coordinator explicitly selects `.legacyCompatible` for
this staged branch because an older deployed generator still sends only
schema-1 notifications. Enabling strict v2 prematurely could suppress
the first-input and render-submit signals, indefinitely delaying the
poster or native result presentation. After the trusted generator
#372 producer passes exact-head CI and is deployed to the target runtime
origin, ship an explicit native release changing this policy to
`.requireV2`, then validate 128+ actual WebKit navigation/retry/
redirect/prewarm/credential-rotation scenarios and physical iPhone/iPad
outcomes. A missing/mismatched v2 capability should surface an explicit
runtime-update error rather than silently falling back. No engine
outcome may be trusted from the JS callback alone (#360).

## 2026-11-13 independent slice and current status

Parent [Hephaestus #203](https://github.com/GavinDu/Hephaestus/issues/203); scoped [#274](https://github.com/GavinDu/Hephaestus/issues/274), architectural [Epic #202](https://github.com/GavinDu/Hephaestus/issues/202). Rebuilt on main merge `c68d59578dfd9aa09baf6d923fd89c2f3c31f164` after metric-parser #247; retain `strictInt` to reject CFBoolean metadata and sequence. The generator v2 producer PR #372 is merged into its main but a deployed runtime may be older. Production retains `legacyCompatible` explicitly; do not advertise complete first-message v1 downgrade prevention until versioned deployment is verified and strict `.requireV2` ships with simulator and physical-device evidence.

**Independent merge gate:** both exact-head native iOS Xcode/player-smoke/iPad UI-evaluator and player-presentation iPhone/iPad/backend contract workflows must be completed-success. Scope excludes first-frame compositor observation, attested scores, WebKit 50-cycle devices, memory and revocable cache. Do not mark the broader parent or Epic as complete.
