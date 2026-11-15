# Game Package architecture: Hephaestus + Game Inventory

## Product model

Hephaestus is the social app; Game Inventory is the creation and publishing system. The social content object is a **versioned playable game**, not a standalone application or only a URL.

- Inventory service: creator inputs, AI pipeline, asset provenance, GameSpec, Game IR, validation, immutable versions, moderation, visibility and package delivery.
- Hephaestus: capture/import UI, creator flow, feed, profiles, play, share, remix, reporting/blocking, permissions and native application lifecycle.
- Runtime: the trusted PixiJS + Rapier interpreter/renderer served by the backend and hosted in a scoped iOS `WKWebView`. Only narrow, validated result/metric notices cross from the trusted runtime to native; no general-purpose native platform-control API is available to declarative game packages.

Backend: https://github.com/GavinDu/html5-game-generator  
Contract: [Game Package / Game IR v1](https://github.com/GavinDu/html5-game-generator/blob/main/docs/game-package-ir-v1.md).  
Current delivery contract: `GET /v1/games/{id}/package` returns package format `2.0`, `minRuntimeVersion`, canonical `ir`, asset descriptors and an IR hash; assets resolve by ID through `GET /v1/games/{id}/assets/{assetId}`. `POST /v1/game-ir/validate` is the server validation gate.

## Runtime decision

The shipped player uses **PixiJS + Rapier** in a backend-served page hosted in `WKWebView`. The app and backend share a versioned, engine-independent Game IR / Game Package contract. The previous native Swift interpreter and Defold target were retired during the single-runtime consolidation; do not restore either as a second runtime without an explicit architecture decision and a conformance plan.

The Game IR is declarative data, not arbitrary downloaded JavaScript, Lua, native libraries, or unrestricted imports. The app owns device permissions and native services. The shipping WebView is **narrowly bridged, not literally bridgeless**: a scoped, origin/main-frame/schema-validated `WKScriptMessageHandler` receives only known trusted-runtime performance and run-result notices, checked against the current game, navigation lease, session and document nonce as supported. It does **not** expose a general native command channel or permit arbitrary creator-executable code. Runtime quality is selected by URL parameter, and native telemetry uses ordinary HTTPS. A client-reported result or hash is **not** independent score attestation. Explicitly review the narrow handler under [Apple App Review Guideline 4.7.2](https://developer.apple.com/app-store/review/guidelines/) before release; do not extend native platform access without permission.

## Runtime boundary

A game package contains a versioned manifest and Game IR, bounded media assets with hashes/provenance, scenes, entities, components, input mappings, allowlisted event/action rules, and creator/remix lineage. The runtime must fail closed on unsupported package/IR versions, unsupported actions, invalid asset references, integrity failures, or resource-budget violations. It must not execute downloaded scripts or expose unrestricted native APIs.

Private/restricted package and asset delivery must authorize the request before returning bytes or a conditional `304`; responses are `private, no-store`. Public package/asset responses require revalidation. Asset bytes are checked against declared hashes before delivery.

## Refactor policy

Prefer a coherent architecture over backward compatibility. Make breaking changes to backend models, API endpoints, runtime behavior, and Swift models together when needed. Avoid long-lived dual paths, compatibility shims, and deprecated abstractions unless a concrete requirement demonstrates their value.

The HTML/GameShim legacy endpoints are transitional and are not a long-term fallback promise. Remove obsolete paths after the versioned Game Package/IR path passes its contract suite. If old published content needs preservation, use a one-time migration and report items that cannot be converted; do not keep parallel runtimes merely to avoid refactoring.

## Rollout and validation gates

1. **Contract:** schema, semantic validator, negative fixtures, package integrity, and resource budgets.
2. **Backend:** generate and persist canonical Game Package + IR; ensure immutable content identity and authorization-aware delivery.
3. **Runtime:** execute local golden fixtures for rendering, input, collision, score, and end-game rules in PixiJS + Rapier.
4. **iOS proof:** verify orientation, safe areas, memory/performance, lifecycle, offline behavior, and asset cleanup on real devices.
5. **Distribution:** fetch versioned packages, verify integrity/compatibility, revalidate cache, play, and return to the feed.
6. **Removal:** delete legacy GameShim/API paths after the canonical path passes tests; do not keep parallel implementations by default.
7. **Review:** document downloaded-content behavior and UGC controls for App Review. No engine choice guarantees approval.

## Social game object

A published game version has a stable identity and immutable content version. Social metrics and moderation state are server-side, not part of the content hash. Remix creates a child version with an explicit parent reference and asset/rule provenance. Players can play, share, save, and remix without installing another app.

## Golden fixture

Use Bobo's Rainbow as the shared fixture: validate its IR, exercise movement, collection, scoring and completion, and compare supported browser/iOS-hosted runtime behavior. Run browser playability tests in GitHub Actions and validate touch feel, orientation, memory, and frame pacing on physical iPhone/iPad devices.
