# Epic #202 — actual stalled feed Retry evidence (#327)

## Source and test finding

A transport watchdog increments the native feed coordinator's generation to invalidate an old callback; a real retry increments generation *and* begins a new Task. The old iPad/iPhone XCTest depended on briefly seeing a Loading games element, which can vanish during the genuine bounded timeout before a poll, falsely reporting no retry.

## Independent implementation

- The shipping FeedRequestCoordinator increments a bounded, saturating `startedRequestCount` exactly when `begin` creates a new async transport Task, not during watchdog expiry or stale-completion cleanup.
- The same native Discover view exposes `Request attempts N` only on real Retry controls as a non-secret VoiceOver-readable accessibility value. It does not include creator/game identity, auth material, a fake game or a claim of server receipt.
- The genuine iPad/iPhone stalled-feed UI test reads the last durable recovery count, taps the actual visible Retry, and requires exactly one new count **on another authentic recovered error state** inside the bounded timeout. It still asserts the real 44pt Retry and Library controls, that no game.play was invented, and captures pre/post retry native screenshots.
- Swift Testing covers 160 real coordinator begin/expire/cancel cycles and rejects fabricated starts on watchdog generation revocation.

## Senior game-engine architect challenge and limitations

This proves a new native fetch Task was started, not that an HTTP request reached or succeeded on the server. The counter is per view and saturates instead of overflowing; it does not prove a published GamePackage v2, GPU-present frame, server-verified score or physical-device stability. Both required native iOS and presentation workflows must be all-seven SUCCESS on the **exact final PR head**, including genuine iPhone and iPad player smoke, before merging and closing #327. Older conflicted drafts #599/#512 and their CI are not substitute evidence.
