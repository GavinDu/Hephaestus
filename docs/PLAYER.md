# Player architecture and breaking runtime migration

## Target: Defold interpreter for Game IR

Hephaestus should ship one primary game runtime: a Defold-based iOS/iPadOS interpreter for the versioned, engine-independent Game IR defined by the Game Inventory backend.

- Backend contract: [Game IR v1](https://github.com/GavinDu/html5-game-generator/blob/main/docs/game-package-ir-v1.md), [schema](https://github.com/GavinDu/html5-game-generator/blob/main/schemas/game-ir-v1.schema.json), and [Bobo's Rainbow fixture](https://github.com/GavinDu/html5-game-generator/blob/main/examples/game-ir-v1/bobos-rainbow.json). The current package API is version 2.0 and returns canonical `ir` plus asset descriptors.
- The canonical package must not contain Defold project files, HTML/JavaScript source, arbitrary downloaded Lua, native libraries or unrestricted native API calls.
- The Defold runtime interprets an allowlisted set of scenes, entities, components, input bindings, events and actions. Unknown IR versions and unsupported capabilities fail closed.
- Defold Live Update is resource delivery/mounting, not a scene compiler; the runtime still implements Game IR semantics.
- The app owns device permissions and native services. Game packages receive only explicitly authorized assets through the bounded runtime interface.

## Breaking migration policy

Do not preserve the existing player/API shape merely for compatibility. Change backend package models, API contracts and Swift models together when the new contract is ready. Prefer deleting obsolete branches over maintaining two permanent runtimes.

The existing HTML5/GameShim player may be used temporarily as a test oracle, but it is not a long-term fallback promise. After Defold passes the contract suite:
1. Remove bundled GameShim JavaScript and related Swift package models/state.
2. Remove legacy remote HTML player and obsolete Godot paths/selection branches.
3. Replace the old package endpoint/model with the canonical versioned Game Package API.
4. If published legacy games matter, use a one-time conversion job and report games that cannot be converted; do not retain an old runtime without a demonstrated requirement.

Manage Xcode target membership and resource removal in Xcode or project tooling; do not hand-edit `pbxproj` blindly.

## Acceptance gates

1. **Contract:** schema + semantic validation, negative fixtures, resource budgets and package integrity checks.
2. **Interpreter:** local fixture executes movement, collision, collection, score, state changes and end-game rules.
3. **Determinism:** same fixture and input trace produce the same gameplay state transitions.
4. **iOS:** orientation, safe areas, memory, performance, lifecycle interruption/resume and asset cleanup pass on physical iPhone and iPad.
5. **Network/cache:** package integrity, offline cache, interrupted download and corrupt-package rejection work.
6. **Security/review:** no arbitrary script/native code execution; required moderation/report/block/takedown flows exist. No engine choice guarantees App Review approval.

## First vertical slice

Implement Bobo's Rainbow from a local Game IR fixture in Defold. Draw background/sprites, move the player by touch/drag, detect collection, update score and end the game at the target score. Add remote delivery only after the local interpreter and contract tests pass.


## Native Game IR player implementation

Hephaestus now decodes package version `2.0` (`gameId`, canonical `ir`, asset descriptors) and runs a native SwiftUI interpreter for Game IR `1.0`. The first playable subset renders entities and downloaded image assets, supports drag movement, detects player/pickup overlap, applies `add_score` and `destroy_entity`, displays score/status, and supports `end_game`/restart. Unsupported actions fail closed rather than executing downloaded code. The Xcode unit tests cover package decoding, collection/actions, and unsupported IR versions. Run the `Hephaestus` and `HephaestusTests` schemes locally to verify on the target simulator/device; no Xcode toolchain is available in this editing session.
