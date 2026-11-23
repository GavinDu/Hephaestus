# Current native host milestone projection — atomic #731

**Scope:** successor runtime Epic [#642](https://github.com/GavinDu/Hephaestus/issues/642), original lifecycle [#203](https://github.com/GavinDu/Hephaestus/issues/203). This change makes a small **production-used** projection of the already-shipping WKWebView reducer. It does **not** claim the standalone `GamePlayerCore` actor is linked to the iOS app.

## One authoritative owner

- **SwiftUI/WKWebView pool:** owns one attached WebView, its monotonic lease, current native document nonce and credential epoch, and native navigation/termination.
- **Production Coordinator:** validates document origin/frame, current lease, nonce/schema/sequence and runtime session before reducer transitions.
- **Pixi runtime:** alone downloads/validates/decode assets and owns semantics. No extra `PlayerLaunchCoordinator`/transport is instantiated. The installed native code pins `GamePackage` format `2.0` as a static compatibility assertion.
- **Generator `ios/GamePlayerCore`:** retains offline Go/Swift contract tests; its actor has independent package/asset fetch responsibilities and must not be added on top of this WebView owner. Future integration requires a separate transport-substitution design and conformant fixtures.

## Truthful event projection

| Native reducer phase | Projected stage | What it proves | What it does not prove |
|---|---|---|---|
| navigating | navigating | Current lease was assigned | Page fetched / assets ready |
| documentLoaded | documentLoaded | WebKit navigation finished | IR valid / frame presented |
| sceneSubmitted | rendererSubmitted | Native-vetted current Pixi render submission, bound nonce/session | GPU-composited pixel |
| interactive | firstInputAdmitted | Native accepted the first typed input metric | Verified score / replay attestation |
| navigationFailed / webProcessTerminated | failed | Owner's terminal host error | Failure was transient or fixed |
| detached | stopped | Reducer explicitly detached | Freed GPU, WebAudio, RAM |

The projection accepts only the **current native attachment lease** and canonical game ID. Its current document nonce comes from `PlayerWebViewPool.currentNativeDocumentNonce`, not JavaScript; renderer/input stages require both a 32-hex native nonce and an already validated bound session. It rejects malformed URL/query and stale lease. Projection does not generate network, JS or new lifecycle events.

The Coordinator uses this gate before reporting accepted first-scene and first-input callbacks, even when WebKit delivers scene submission after first input. Existing native sequence/session/ownership gates remain in place.

## Evidence and rollback

- Swift unit tests cover normal and out-of-order transitions, 160 malicious identity/lease/nonce cases, 160 process-death/detach sequences and 160 epoch rotations.
- Python CI source guard rejects adding `GamePlayerCore`, `GamePackageTransport`, or `PlayerLaunchCoordinator` into production Xcode project and instantiation into native player.
- Required seven GitHub Actions jobs must pass **at the final PR SHA** before merge; no simulator screenshot implies physical iPhone/iPad GPU-present.
- **Rollback:** revert the isolated projector, read-only pool nonce accessor, two callback gates, Swift tests and Python guard; no Game IR, package request, asset loading or backend state is modified.
- Remaining independent acceptance: real published GamePackage fixture #288/#368; full native/Core unification #203; renderer/first GPU frame #276; hardware teardown #279; v2-first callback policy #286; independent Go replay attestation generator #360.

**Review challenger:** challenge any attempt to map `didFinish` to running, call a second package loader, trust a page-supplied nonce, or claim device certification from native CI. This atomic slice is not a full runtime rewrite.
