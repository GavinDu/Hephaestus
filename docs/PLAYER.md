# Player integration (WKWebView)

## Bundled-runtime player (current architecture, 2026-10-11)

The app no longer loads the remote `/player` page for HTML5 games. Instead:

- **Runtime ships in the app binary.** `Hephaestus/Player/Resources/bundled-player.html`
  contains the fixed GameShim v1 runtime (`window.HephaestusBoot`, `SHIM_VERSION =
  "gameshim/v1"`), extracted from the backend's browser player
  (`internal/api/web/player.html` in GavinDu/html5-game-generator). If the backend
  runtime changes, update this file and bump the version together with the manifest
  `shim` field.
- **Only game data comes from the network.** On Play, the app fetches
  `GET /v1/games/{id}/package` (the data-plane descriptor: manifest + runtime
  handshake + relative data URLs) and injects it into the shell via one-way
  `evaluateJavaScript` (base64-encoded JSON — no quoting hazards).
- **Handshake lives in Swift.** `BundledPlayerState` compares
  `package.runtime.required` against `bundledRuntimeVersion` *before* the WebView
  boots. Mismatch shows a native "update the app" screen; the game never loads.
- **Bridgeless by design.** No `WKScriptMessageHandlers` — game code can never call
  into native code (4.7.2 posture: no native API exposure to hosted content).
  Score submission uses plain `fetch()` from inside the shell, same as the browser.
- **Files:** `Hephaestus/Player/BundledPlayerView.swift` (package models, state
  machine, `BundledPlayerView`, `BundledPlayerSheet`) wired into Discover and
  Create via `BundledPlayerRequest`. The legacy `WebPlayerView`/`PlayerSheet`
  remain for the Godot section and as fallback.

**Xcode steps (must be done in Xcode, never by hand-editing the pbxproj):**
1. Add `Hephaestus/Player/BundledPlayerView.swift` to the Hephaestus target.
2. Add `Hephaestus/Player/Resources/bundled-player.html` to the target's
   Copy Bundle Resources (it is loaded via `Bundle.main.url(forResource:)`).

## The short version (legacy remote player)

Load `GET /player` in a WKWebView. It lists public games (HTML5 GameShim
bundles, played inline) plus a **GODOT VERSIONS** section linking to the
Godot 4.7 web builds at `/godot/{game}/`.

## App Store strategy (guideline 4.7)

Games are HTML5/WASM executed in WKWebView — no downloadable native code —
which keeps the app on the guideline 4.7 path (the same rule that allows
other game-creation apps). Verified 2026-10-06/07:

- Godot 4.3+ web export defaults to single-threaded and **works on iOS**.
- **GDScript only**: Godot 4 cannot export C# (or native GDExtension modules)
  to web. All Godot games must stay GDScript while web is the distribution
  path. Native iOS export remains a later, higher-performance option.

## What the player serves

| URL | Content |
|---|---|
| `/player` | Game list + inline HTML5 player (canvas 390×844) |
| `/v1/feed` | Public games JSON the player lists |
| `/v1/godot` | `[{id, title, ready, url}]` for the Godot builds |
| `/godot/{game}/` | Full Godot engine page (own HTML shell, not an iframe) |

The server sends `Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp` on `/godot/*` — required by the
Godot 4 web runtime. WKWebView respects these headers; no app-side work
needed. First load of a Godot game takes ~30–60s (server fetches/extracts a
~10MB zip on first request, then caches it).

## Native bridge surface (GameShim v1)

HTML5 games run against a small JS bridge injected before `game.js`. If the
app wants native hooks (haptics, share sheet, telemetry), expose them on
`window.webkit.messageHandlers` and mirror the existing `Shim.*` surface:
`Shim.audio.*`, `Shim.store.get/set`, `Shim.end({score, won, stats})`,
`Shim.log(event, data)`.

## Current games

- Bobo's Rainbow (HTML5 + Godot) — catch falling hearts, endless meta-levels
- Ribbon Mends the Sky (HTML5 + Godot) — tap-to-stitch sky holes, dodge demons
- Escape from the Injection (HTML5 + Godot) — 3-lane syringe dodge chase
