# Player integration (WKWebView)

## The short version

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
