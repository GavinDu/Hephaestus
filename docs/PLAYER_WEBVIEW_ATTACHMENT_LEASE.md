# WKWebView attachment lease — retry and hot handoff safety

Parent: [Hephaestus Epic #202](https://github.com/GavinDu/Hephaestus/issues/202), native lifecycle [#203](https://github.com/GavinDu/Hephaestus/issues/203).

The shipping SwiftUI player uses a **single pooled WKWebView**. When a
`.id(attempt)` retry remounts the `UIViewRepresentable`, SwiftUI is not
required to dismantle its former Coordinator before it mounts the new one.
A Coordinator cannot infer ownership merely from a reference to the shared
WKWebView object.

## Failure and repaired transition

```
Old Coordinator #1 (lease 1)  ────────────────┐
     WebView A                                │ delayed dismantle
New Coordinator #2 (lease 2)       ───────────┤ attached WebView A
     replaces delegate/message handler       │
OLD dismantle arrives                         ▼
     old lease != active lease ⇒ **no-op** (may stop its own observations)
     new delegate, handler, network and runtime remain unchanged
New Coordinator #2 eventually dismantles
     matching lease 2 ⇒ unregister active message handler and recycle A
```

A successful `take(url:)` increments an in-memory `UInt64` lease
and returns it to the *new* native Coordinator. The pool will only
recycle on `isAttached && pooledView === candidate &&
candidateLease == activeLease && candidateLease != 0`.
This is a pure policy with Swift Testing negative fixtures. The
`UIViewRepresentable` installs a new script handler by removing the
old `hephaestusRunResult` handler name **before adding the new one**,
because WebKit throws when registering a duplicate name. A retired
Coordinator's dismantle never removes its successor's handler.
The same lease gate is also applied to delayed `isLoading`/KVO
**prewarm handoff recovery**: a previously attached Coordinator may not
reload a WebView now owned by the next retry, even when the game URL
is byte-for-byte identical.

On credential change the old view is removed from the pool, so stale
dismantles also fail the exact pooled-view check. The handler proxy
holds its Coordinator weakly. Navigation, run verification, origin
allowlist and bounded prewarm policy remain unchanged. Do **not**
interpret an attached lease or navigation finish as first composited
frame or first accepted game input.

## Acceptance

- Xcode Swift unit test runs the ordered lease truth table: active,
  superseded same-view, future/zero epoch, detached and revoked pool.
- Required GitHub Actions iOS build, iPhone WebView and iPad player
  smoke, backend contract and UI evaluator must all pass on exact PR head.
- Physical-device 50+ open/close/retry/foreground transitions, memory
  growth and shader recovery remain pending #204/#205.
- This is one incremental ownership fix; it does **not** complete the
  single-authority native GamePlayerCore retirement/unification #203.
