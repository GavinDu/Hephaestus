# Hephaestus

The iOS app for a social platform where a playable game is a form of user expression. A user can turn a photo, drawing, video, audio clip, story, joke, challenge or strategy into an interactive experience, then play, share and remix it.

**Game Inventory / creation backend:** [`GavinDu/html5-game-generator`](https://github.com/GavinDu/html5-game-generator) (Go). It owns generation, asset processing, validation, versioning and package delivery.

**Runtime direction:** evaluate **Defold as the fixed iOS/iPadOS game runtime**, with a versioned, engine-independent Game IR/Game Package as the durable content format. The bundled HTML5/GameShim player is temporary test/reference infrastructure only and should be removed after the Defold + Game IR path passes acceptance tests. Defold is a target direction, not yet integrated into this Xcode project.

**App Store posture:** ship the runtime with the app and treat shared games as validated content packages. The proposed v1 Game IR uses declarative scenes/components/rules rather than arbitrary downloaded Lua. Defold Live Update delivers/mounts resources; it does not itself make arbitrary generated scripts safe or guarantee App Review approval. Review applicable Apple guidelines for actual product behavior before release.

## Project layout

- `Hephaestus/` — SwiftUI app source
  - `BackendConfig.swift` — backend base URL + user identity config
- `docs/` — app and integration docs
  - `API.md` — backend endpoint reference
  - `GAME_SPEC.md` — current game questionnaire
  - `PLAYER.md` — current HTML5 player and migration notes
  - `GAME_PACKAGE_ARCHITECTURE.md` — target system boundaries and rollout gates

## Requirements

- Xcode 27 or later
- Swift 5
- Platforms: iOS (primary), macOS, visionOS

## Backend quick links

- Production: `https://html-5-game-generator.replit.app`
- Player: `…/player`
- API docs: `docs/API.md`
- Game Package contract proposal: [backend contract docs](https://github.com/GavinDu/html5-game-generator/blob/main/docs/game-package-ir-v1.md)
