# Hephaestus

The iOS app for the AI game-generation platform: turn kids' drawings into
playable games. Photograph a drawing → the backend generates a game → play
it in the app, share it, remix it.

**Backend:** `github.com/GavinDu/html5-game-generator` (Go) — game
generation pipeline, player, API. See `docs/API.md`.

**App Store strategy:** games run as HTML5/WASM inside WKWebView (App Store
guideline 4.7 path — no downloadable native code). Godot 4.7 web exports
(GDScript only) cover effect-heavy games; plain HTML5 canvas covers simple
ones. A server-side decision maker routes each game to the right engine.

## Project layout

- `Hephaestus/` — SwiftUI app source
  - `BackendConfig.swift` — backend base URL + user identity config
- `docs/` — synced progress from the backend project
  - `API.md` — backend endpoint reference
  - `GAME_SPEC.md` — the 31-factor game questionnaire
  - `PLAYER.md` — WKWebView player integration + App Store notes

## Requirements

- Xcode 27 or later
- Swift 5
- Platforms: iOS (primary), macOS, visionOS

## Backend quick links

- Production: `https://7ca9cb63-0317-4dd0-b084-5ef4df88cdaf-00-1i3fhaijkqyg1.riker.replit.dev`
- Player: `…/player`
- API docs: `docs/API.md`
