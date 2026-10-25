# Hephaestus

Hephaestus is the iOS app for a social platform where a playable game is a form of user expression. People can turn photos, drawings, videos, audio, stories, jokes, challenges, and strategies into interactive experiences, then play, share, save, and remix them.

**Game Inventory / creation backend:** [`GavinDu/html5-game-generator`](https://github.com/GavinDu/html5-game-generator) (Go). It owns generation, asset processing, validation, package versioning, moderation-aware delivery, and the canonical Game Package API.

**Current player runtime:** PixiJS + Rapier, served by the backend and hosted in iOS `WKWebView`. The app deliberately uses a bridgeless WebView: no script message handlers, no `evaluateJavaScript` control channel, and no native API exposed to downloaded game content. The shipped runtime interprets versioned, declarative Game IR; game packages are data and assets, not arbitrary downloaded scripts or native code.

**Package contract:** [Game Package and Game IR documentation](https://github.com/GavinDu/html5-game-generator/blob/main/docs/game-package-ir-v1.md), [schema](https://github.com/GavinDu/html5-game-generator/blob/main/schemas/game-ir-v1.schema.json), and [Bobo's Rainbow fixture](https://github.com/GavinDu/html5-game-generator/blob/main/examples/game-ir-v1/bobos-rainbow.json). Backend package format v2.0 includes `packageFormatVersion`, `minRuntimeVersion`, canonical `ir`, asset descriptors, and an IR hash. Unsupported formats, IR versions, actions, invalid asset references, and integrity failures must fail closed.

**App Store posture:** the runtime ships with the service/app experience; games are validated content interpreted by the shipped runtime. This architecture does not guarantee App Review approval. Review Apple's current guidelines against the actual product behavior before release.

## Project layout

- `Hephaestus/` — SwiftUI app source
  - `BackendConfig.swift` — backend base URL and session configuration
  - `Player/PixiPlayer.swift` — player sheet, bridgeless WebView host, load/retry/lifecycle policy
  - `Views/AppTabs.swift` — Discover/social UI, creator cards, save/share/comment/report actions
  - `Backend/BackendAPI.swift` — typed backend API and bearer-session handling
- `HephaestusTests/` — unit tests and policy tests
- `HephaestusUITests/` — Discover → Play smoke test
- `docs/` — API, player, game-spec, and package architecture notes

## Player behavior and guardrails

- iOS opens `/player?game={id}&quality={auto|high|low}` in a bridgeless `WKWebView`.
- Quality is passed as a URL parameter; the app does not inject JavaScript to control the runtime.
- The player shows progress, slow-load guidance, offline/error states, and retry controls; it does not cover a successfully loaded game just because connectivity drops.
- A failed load may retry after the app returns to foreground when connectivity is available. A loaded game is not reloaded solely because the app was backgrounded.
- Memory warnings, thermal pressure, load failures, and WebContent process termination are recorded as privacy-minimal diagnostics. Do not add account IDs, bearer tokens, or user content to telemetry.
- Backend delivery must check authorization before conditional responses; private/restricted content is `private, no-store`. Asset bytes are validated against declared hashes before delivery.
- Do not restore the retired native Swift interpreter or add Defold as a second runtime without an explicit architecture decision and a shared conformance plan.

## Requirements

- Xcode and Swift toolchain matching `.github/workflows/ios.yml`
- Platforms: iOS (primary), macOS, visionOS where the current targets support them

## Backend quick links

- Production: `https://html-5-game-generator.replit.app`
- Player: `https://html-5-game-generator.replit.app/player`
- API docs: [`docs/API.md`](docs/API.md)
- Package contract: [backend docs](https://github.com/GavinDu/html5-game-generator/blob/main/docs/game-package-ir-v1.md)

## Validation

GitHub Actions builds the Xcode project, runs unit tests, and runs the player smoke test. Device validation is still needed for touch feel, orientation/safe areas, memory pressure, and performance across representative iPhone/iPad hardware.
