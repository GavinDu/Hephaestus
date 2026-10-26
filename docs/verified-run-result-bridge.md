# Verified Run Result Contract and WKWebView Bridge

## Status

Design proposal for Hephaestus issue #60. This document deliberately separates three things:

1. The runtime's local `run_end` observation.
2. The backend's authoritative run verification.
3. The native iOS result-sheet presentation.

The iOS result sheet must never display a score or win/loss state based only on JavaScript state.

## Existing flow

The Pixi runtime currently emits a telemetry-v2 `run_end` event containing `won`, `score`, `durationMs`, `inputs`, `deadInputs`, `retries`, and `seed`. For normal shell play it also submits the input trace to:

```text
POST /v1/games/{gameID}/runs
```

The existing submission contains the player name, score, outcome, duration, seed, IR hash, and input trace. The server is the only component that can decide whether that trace is valid for the published package.

The existing `POST /v1/telemetry/events` endpoint remains analytics-only. A telemetry `run_end` event must not by itself unlock the native result sheet.

## Verified result API

The run submission response should be extended to this shape without exposing the input trace back to the client:

```json
{
  "runId": "run_01J...",
  "gameId": "game-123",
  "status": "verified",
  "result": {
    "won": true,
    "score": 420,
    "durationMs": 12800,
    "completedAt": "2026-10-26T23:59:12Z"
  },
  "rank": {
    "scope": "weekly",
    "position": 7,
    "total": 184
  }
}
```

`rank` is optional and must be omitted when no leaderboard is configured. The response status values are:

- `verified`: the server replayed or otherwise validated the run and the result is displayable.
- `pending`: accepted for asynchronous verification; native must poll the result endpoint and must not display a result yet.
- `rejected`: the run is not displayable; include only a stable user-safe reason code such as `trace_mismatch`, `expired_package`, or `unsupported_runtime`.

The response must not echo arbitrary client claims as verified fields. For synchronous verification, the server computes `won`, `score`, and `durationMs` from the verified replay. For asynchronous verification, the same fields become available only from the result resource.

### Result resource

```text
GET /v1/runs/{runID}/result
```

Response:

```json
{
  "runId": "run_01J...",
  "gameId": "game-123",
  "status": "verified",
  "result": {
    "won": true,
    "score": 420,
    "durationMs": 12800,
    "completedAt": "2026-10-26T23:59:12Z"
  },
  "rank": { "scope": "weekly", "position": 7, "total": 184 }
}
```

The authenticated owner may read only their own run result. The API should return `404` for an unknown or unauthorized run ID rather than revealing whether another user's run exists.

### Idempotency and replay rules

- The client supplies an `Idempotency-Key` for run submission; retries return the same `runId` and do not create another leaderboard entry.
- `runId` is opaque, unguessable, and bound to `gameID`, authenticated user, published package version, and verification policy.
- A result is immutable after reaching `verified`, `rejected`, or `expired`.
- A duplicate bridge message for the same `runId` is ignored by native after the first accepted result.
- The telemetry `eventId` remains separate from `runId`; telemetry deduplication is not proof of run verification.

## JavaScript-to-native message envelope

The WebView may notify native only after the server has returned a `runId`. The message is a notification, not an assertion that native should trust:

```json
{
  "schema": 1,
  "type": "verified_run_available",
  "sessionId": "runtime-session-id",
  "gameId": "game-123",
  "runId": "run_01J..."
}
```

The JavaScript runtime should send this message only after `POST /v1/games/{id}/runs` returns a successful response. If verification is asynchronous, it sends the message when the result endpoint becomes `verified`, or native polls after receiving a `pending` run notification.

The message contains no score, no win/loss claim, no URL, no JavaScript source, and no command name. Native always fetches the result over the authenticated API and validates that `gameId` matches the currently presented player.

## WKWebView bridge design

### Registration

Create a dedicated `WKUserContentController` for the player configuration and register one handler name:

```text
hephaestusRunResult
```

The handler should be installed before loading `/player`. Do not use `evaluateJavaScript` as a control channel and do not add a general-purpose command dispatcher.

Use a weak proxy (`WeakScriptMessageHandler`) between `WKUserContentController` and the coordinator so the pooled `WKWebView` does not retain the player sheet or coordinator indefinitely. Remove the handler in `dismantleUIView` before recycling the WebView.

### Origin and frame checks

The coordinator must accept a message only when all checks pass:

1. `message.name == "hephaestusRunResult"`.
2. `message.frameInfo.isMainFrame == true`.
3. `webView.url` has the configured HTTPS backend origin.
4. The message body is a dictionary or JSON object with exactly the supported fields.
5. `schema == 1` and `type == "verified_run_available"`.
6. `gameId` equals the player sheet's requested game ID.
7. `sessionId` equals the session identifier negotiated for this player instance.
8. `runId` is non-empty and bounded in length.

Origin checking is defense in depth only. It is not the verification boundary; the authenticated result fetch is authoritative.

### Swift flow

```swift
func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
) {
    guard message.name == "hephaestusRunResult",
          let body = message.body as? [String: Any],
          body["schema"] as? Int == 1,
          body["type"] as? String == "verified_run_available",
          body["gameId"] as? String == expectedGameID,
          body["sessionId"] as? String == sessionID,
          let runID = body["runId"] as? String,
          runID.count <= 128,
          isExpectedMainFrame(message) else { return }

    Task { @MainActor in
        guard acceptedRunIDs.insert(runID).inserted else { return }
        do {
            let result = try await BackendAPI.shared.fetchVerifiedRunResult(runID: runID)
            guard result.gameID == expectedGameID,
                  result.status == .verified else { return }
            onVerifiedResult(result)
        } catch {
            PlayerTelemetry.report(
                gameID: expectedGameID,
                kind: "ios-run-result-failed",
                name: "VerifiedRunResultFetchFailed",
                message: "run result was unavailable"
            )
        }
    }
}
```

The pseudocode is intentionally incomplete: `fetchVerifiedRunResult` must use the existing authenticated `BackendAPI` session and decode only the bounded result model. It must not accept a result object supplied by JavaScript.

### Lifecycle

- Generate a fresh native `sessionID` for each player presentation.
- Attach the message handler before `load(URLRequest(...))`.
- Keep the handler active while the page is attached.
- Cancel pending result fetches and clear accepted run IDs when the player is dismissed.
- Remove the handler before `PlayerWebViewPool.recycle`.
- On pooled WebView reuse, reject messages whose session ID or game ID does not match the new player instance.
- If the Web Content process terminates, discard pending result state and require a new verified message after reload.

## Native presentation rules

`PlayerResultSheet` should be presented only when `onVerifiedResult` supplies a verified result for the active game.

- `Play Again` starts a new player presentation and generates a new native/player session.
- `Next Game` dismisses the result sheet, selects the next For You card, and resumes that card's preview.
- `Like` uses the existing reaction endpoint and does not depend on the run result.
- `Remix` remains hidden or disabled until generated-game remixing is supported.
- If the user taps Done before a verified result arrives, dismiss the player without showing a result sheet.
- If verification is pending, show no score; optionally show a non-result toast such as “Your run is being verified.”

## Threat model and non-goals

The bridge is not an authentication mechanism. A modified page, injected script, or compromised runtime can send arbitrary bridge messages. That is acceptable because native treats the message as a run-ID hint and fetches the result from the authenticated backend.

The bridge must not:

- Execute JavaScript supplied by the page.
- Accept arbitrary native commands.
- Accept score, outcome, rank, URLs, or package data from the message.
- Bypass server verification because telemetry says `run_end` occurred.
- Reuse a result from a previous pooled WebView session.

## Rollout and fallback

1. Ship the backend result resource and idempotent run submission first.
2. Add bridge support behind a feature flag or minimum backend capability response.
3. Keep the current bridgeless player behavior when the capability is absent.
4. If the bridge is unavailable, keep gameplay functional and omit the result sheet rather than showing unverified data.
5. Add tests for malformed messages, wrong origin, wrong frame, wrong game, stale session, duplicate run ID, pending verification, rejected verification, and successful verification.

## Acceptance tests

- A valid `run_end` followed by a verified run response produces exactly one native result sheet.
- Duplicate bridge messages do not duplicate the sheet or leaderboard entry.
- A message with a client-provided score is ignored; native displays only the fetched score.
- A run from another game or pooled WebView session is ignored.
- A failed or pending verification never displays a score or win/loss result.
- A player load failure followed by Return to feed does not present the result sheet.
- Play Again creates a new player session; Next Game selects the following For You card; Like toggles the authenticated reaction.
