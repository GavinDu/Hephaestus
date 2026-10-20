# Game Package architecture: Hephaestus + Game Inventory

## Product model

Hephaestus is the social app; the Game Inventory service is the creation and publishing system. The social content object is a **versioned playable game**, not a standalone application or only a URL.

- Inventory service: creator inputs, AI pipeline, asset provenance, GameSpec, Game IR, validation, immutable versions, moderation, visibility and package delivery.
- Hephaestus: capture/import UI, creator flow, feed, profiles, play, share, remix, reporting/blocking, permissions and native application lifecycle.
- Runtime: one preinstalled interpreter/renderer with a fixed capability surface. It never receives arbitrary native libraries or unrestricted device APIs from a game package.

Backend: https://github.com/GavinDu/html5-game-generator  
Contract: [Game Package / Game IR v1](https://github.com/GavinDu/html5-game-generator/blob/main/docs/game-package-ir-v1.md).  
Current delivery contract: `GET /v1/games/{id}/package` returns package version `2.0` with canonical `ir` plus asset descriptors; assets resolve by ID through `GET /v1/games/{id}/assets/{assetId}`. `POST /v1/game-ir/validate` is the server validation gate.

## Engine decision

Evaluate **Defold as the primary native iOS/iPadOS runtime** for declarative Game IR. The current HTML5/GameShim player is temporary test/reference infrastructure only, not a permanent fallback.

The canonical format is engine-independent Game IR, not Defold project files or generated HTML/JavaScript. Defold Live Update mounts compatible resources; it does not compile arbitrary JSON into scenes or make downloaded Lua scripts safe/App-Review-approved.

## Runtime boundary

The app ships the engine and approved gameplay capabilities. A game package contains a versioned manifest and Game IR, bounded media assets with hashes/provenance, scenes, entities, components, input mappings, allowlisted event/action rules and creator/remix lineage. It must not contain native binaries, dynamic libraries, arbitrary imports or unrestricted native API calls. The native app owns camera/photo permissions and passes only media the user has authorized.

## Refactor policy

Prefer a coherent architecture over backward compatibility. Make breaking changes to backend models, API endpoints and Swift models together when needed. Avoid long-lived dual paths, compatibility shims, legacy runtime fallbacks and deprecated abstractions unless a concrete requirement demonstrates their value.

The HTML5 player may serve as a temporary golden oracle. After Defold passes the Game IR acceptance suite, remove GameShim, the remote HTML player and obsolete Godot experiments. If old published content needs preservation, perform a one-time migration and explicitly report items that cannot be migrated.

## Rollout gates

1. **Contract:** schema, semantic validator, negative fixtures and resource budgets.
2. **Backend:** generate and persist canonical Game Package + IR; replace legacy GameShim generation/API as a coordinated breaking change.
3. **Defold interpreter:** load a local fixture and implement rendering, input, collision, score and end-game rules.
4. **iOS proof:** verify orientation, safe areas, memory/performance, lifecycle, offline behavior and asset cleanup on real devices.
5. **Distribution:** fetch versioned packages, verify integrity/compatibility, cache, play and return to the feed.
6. **Removal:** delete old runtime/API paths after the new path passes tests; do not keep parallel implementations by default.
7. **Review:** document downloaded-content behavior and UGC controls for App Review. No engine choice guarantees approval.

## Social game object

A published game version has a stable identity and immutable content version. Social metrics and moderation state are server-side, not part of the content hash. Remix creates a child version with an explicit parent reference and asset/rule provenance. Players can play, share, save and remix without installing another app.

## First vertical slice

Use Bobo's Rainbow: validate its IR, implement it in Defold, and test movement, collection, scoring and completion on physical devices. Use HTML5 only as a temporary test oracle if useful; do not delay the new runtime to maintain compatibility with legacy implementation details.
