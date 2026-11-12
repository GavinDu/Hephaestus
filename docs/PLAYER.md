# Player architecture and runtime contract

## Current runtime: PixiJS + Rapier in a bridgeless WKWebView

The iOS app hosts the backend-served player page at `/player?game={id}&quality={auto|high|low}` in a `WKWebView`. PixiJS renders the scene and Rapier provides physics. The backend serves the canonical Game Package and assets; the runtime interprets Game IR as declarative data.

The iOS shell intentionally exposes **no general-purpose JavaScript-to-native control bridge**:
- The production host **does** register a constrained `WKScriptMessageHandler` (`hephaestusRunResult`) for main-frame, same-origin, schema-checked, session-bound run-result notices and bounded performance metrics. This is one-way notification only; no arbitrary device/native operations can be invoked through Game IR.
- No user scripts or `evaluateJavaScript` control channel. Quality selection is passed only through a URL parameter.
- Native telemetry is sent through normal HTTPS requests and contains no bearer token, account identifier, or user-generated content. The web runtime also reports bounded diagnostics independently.
- The app owns native permissions and services; the game package cannot access arbitrary native APIs.

Do not restore the retired native Swift Game IR interpreter or introduce Defold as a second runtime without an explicit architecture decision and a cross-runtime conformance plan. The current shipped runtime and backend contract are authoritative; old Defold/native-interpreter text in historical commits is not the current implementation.

## Package contract

The backend serves `GET /v1/games/{id}/package` with package format v2.0, `minRuntimeVersion`, canonical `ir`, asset descriptors, and an IR hash. Asset URLs are backend-owned paths, not arbitrary remote URLs.

- Reject unsupported `packageFormatVersion`, `irVersion`, runtime requirements, and unsupported actions.
- Validate Game IR before execution and validate asset references/hashes before rendering.
- Do not evaluate arbitrary downloaded JavaScript, Lua, native libraries, or scripts.
- Check access before package/asset delivery, including conditional requests. Private/restricted responses use `private, no-store`; public responses require revalidation.
- If a package is invalid, unsupported, missing assets, or fails integrity validation, show a recoverable error and a safe way to exit.

Contract fixtures: [Game IR schema](https://github.com/GavinDu/html5-game-generator/blob/main/schemas/game-ir-v1.schema.json), [Bobo's Rainbow](https://github.com/GavinDu/html5-game-generator/blob/main/examples/game-ir-v1/bobos-rainbow.json), and [backend contract notes](https://github.com/GavinDu/html5-game-generator/blob/main/docs/game-package-ir-v1.md).

## iOS player lifecycle and UX

- Show loading progress, slow-load guidance, and explicit offline/load-failure states rather than an indefinite spinner.
- Preserve loaded gameplay during transient connectivity loss.
- Retry a failed load after connectivity returns or after foregrounding if the device is online; do not reload a successfully loaded game solely because the app was backgrounded.
- Recover from a terminated WebContent process with bounded automatic reload attempts, then show a retry/exit path.
- Respect Low Power Mode and serious/critical thermal pressure through the existing quality preference.
- Track player load latency, load failures, WebContent termination, memory warnings, and thermal pressure without sending account IDs, tokens, or content.
- **Measurement contract:** `TapToNavReady` is WK navigation completion, **not** a rendered first frame or time to interactive. The browser's `first_scene_render_submit` milestone (runtime PR #324) is recorded only after an explicit Pixi render completes and is at most a renderer submission signal; it is **not proof** of GPU/compositor presentation or accepted input. When the native one-way handler is attached it records the same bounded elapsed time. Prewarmed pages may emit before native attachment; rely on backend milestone and device evidence for completeness. Keep this distinct from `first_input` and full player readiness.
- Keep controls reachable, safe-area aware, accessible, and usable with Dynamic Type and reduced-motion preferences.

## Runtime-owned gameplay session timing (Epic #202 / #203)

Navigation completion is a **page-loading** event, not a gameplay input. The
native sheet now starts its quick-exit duration clock only after a validated,
session-bound `first_input` event arrives through the existing narrow,
origin-checked WKWebView metrics channel. It ignores malformed and repeated
milestones and does not invent an accepted input from a prewarmed navigation.
A user leaving while the game still displays a start card does **not** generate
a misleading gameplay quick-exit event. `TapToNavReady` remains separately
measured on navigation finish.

The backend owns gameplay start, run-completion and replay verification; the
native callback affects only the native short-session telemetry timestamp. This
does **not** mean full first-frame readiness, prewarm event completeness or
production host / `GamePlayerCore` state-machine unification is solved.
Those remain iPhone/iPad and architecture review gates under #203 and #204.

## Acceptance gates

1. **Contract:** valid, malformed, unsupported-version, unsupported-action, missing-asset, bad-hash, private-access-denied, and resource-budget fixtures.
2. **Cross-client behavior:** browser runtime and iOS-hosted player agree on package versioning and error categories.
3. **Lifecycle:** cold launch, load retry, offline/online transition, background/foreground, memory pressure, WebContent termination, and safe exit.
4. **UX/accessibility:** iPhone/iPad portrait and landscape, safe areas, large text, VoiceOver labels, focus, and reduced motion.
5. **Performance:** time-to-first-frame, memory, frame pacing, asset latency/failures, and representative game sizes.
6. **Security/moderation:** package authorization, cache revalidation, report/block/takedown distribution, and no arbitrary downloaded code execution.

## Validation

GitHub Actions builds the Xcode project, runs unit tests, and runs a Discover → Play smoke test against the configured backend. Simulator tests do not replace physical-device validation for touch handling, orientation, memory pressure, and frame pacing.
