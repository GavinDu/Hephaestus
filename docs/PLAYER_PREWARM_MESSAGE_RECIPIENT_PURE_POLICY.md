# Pure pooled WebKit callback recipient policy — Epic #202 / atomic #479

## Source-level contract

`PlayerPrewarmMessageOwnershipPolicy` is a **pure Swift function** that selects `speculative`, `attached` or `drop` given **native-owned** attachment status, transferring lease, current lease, attached receiver presence and credential-epoch freshness. It performs no WebKit installation, packet parsing, URL fetches, browser/native bridge commands, score writes or side effects.

Only a detached pool with no transfer and no stale attached receiver may route to the speculative collector; during the `take()`→Coordinator acknowledgement window an attached positive exact current transfer lease must still route through the collector; after transfer is nil an attached positive-lease current receiver may route to the attached Coordinator. All stale/mismatched/zero current leases, detached stale receiver/transfer and old credential epochs drop. Swift Testing covers the original handoff truth table and 160 consecutive foreign/valid lease combinations.

## Skeptical senior game-engine architect limitations

This *policy alone does not receive or authenticate* `WKScriptMessage`. Its booleans **must** be supplied only by the native pool, current retained WebView, trusted main-frame/origin/document nonce and credential ledger; JavaScript must not supply or override them. A current routing recipient does not imply a trusted first scene, input-readiness, GPU compositor frame, or a server-owned verified score.

The original stacked draft [#431](https://github.com/GavinDu/Hephaestus/pull/431) attempted both this policy and a larger replacement of WebKit's handler plus once-only scene ledger transfer. This PR splits **only** the policy out; it does **not** install a permanent handler. The actual integration [#352](https://github.com/GavinDu/Hephaestus/issues/352) must be rebuilt on the merged [#357](https://github.com/GavinDu/Hephaestus/issues/357) ledger, preserving its hardened URL/game-ID/ASCII/nonce trust, and must pass iPhone/iPad callback-before/after-attachment screenshots and exact-head GitHub Actions. Poster hold [#353](https://github.com/GavinDu/Hephaestus/issues/353), strict v2 rollout [#286](https://github.com/GavinDu/Hephaestus/issues/286), physical GPU [#276](https://github.com/GavinDu/Hephaestus/issues/276), thermal [#279](https://github.com/GavinDu/Hephaestus/issues/279) and server attestation #382 remain open.

## Validation / release / rollback

All seven required exact-head Xcode, native URL tests, iPhone WebView smoke, iPad feed/player smoke, presentation backend and player-smoke workflows must pass before squash merge and closing this atom **only**. No fake published-game fixtures, skipped tests or paid Replit model. Rollback removes this pure type and two scoped Swift Testing cases; shipping runtime behavior remains unchanged.
