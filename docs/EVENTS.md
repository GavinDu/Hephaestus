# Event definitions v1 (Hephaestus #17)

Versioned documentation of the events Hephaestus emits and the events
the backend derives, so feed exposure, intentional play, and
completion can be told apart in queries. This document describes what
is implemented today; anything marked open is a gap, not a promise.

## Streams

There are two distinct streams. Do not merge them in queries.

1. **Social events** — `POST /v1/telemetry/social-event`, sent by
   `BackendAPI.trackSocialEvent` (`Hephaestus/Backend/BackendAPI.swift`).
   These are engagement signals for the feed.
2. **Player telemetry** — `POST /v1/telemetry` (via
   `BackendAPI.postPlayerTelemetry`), sent by `PlayerTelemetry.report`
   (`Hephaestus/Player/PixiPlayer.swift`). These are health signals
   for the player itself (loads, failures, memory, thermals), filed
   in the same store as the web runtime's beacons. They are not
   engagement, and a player-telemetry row is never a play.

## Social event schema v1

One event per row. All fields are integers in milliseconds unless
noted; fields the sender does not set are sent as 0.

| Field | Meaning |
| --- | --- |
| `event_id` | UUID generated per send by the app. Intended as the dedupe key (see open items). |
| `game_id` | The game the event is about. |
| `kind` | One of the kinds below. |
| `duration_ms` | Elapsed time for kinds that carry one (see below). |
| `expected_duration_ms` | Expected length, for normalizing engagement by game type. Sent as 0 by iOS today (open). |
| `preview_dwell_ms` | Measured preview dwell, for `preview_dwell` only. |
| `time_to_interactive_ms`, `time_to_first_input_ms`, `frame_time_p95_ms`, `frame_time_avg_ms`, `frame_count` | Player performance fields. Sent as 0 by iOS today: time-to-interactive and frame time are runtime-side signals the bridgeless shell cannot observe (see #61), so they are not faked from the app side. |

## Social event kinds emitted by iOS

| Kind | When it fires | Fields that carry meaning |
| --- | --- | --- |
| `impression` | A feed card appears (`onImpression` in `DiscoverView`). An impression is exposure, not intent: several cards can impress while scrolling. | `game_id` only. |
| `preview_dwell` | A preview clip stops (scroll-away, feed change, backgrounding, constrained network). Measured from clip start, never the old fixed 700ms (see #61). | `preview_dwell_ms` (and `duration_ms`, same value). Clips that never started report nothing. |
| `save` | The user saves a game. | `game_id` only. |
| `share` | The user shares a game, from the feed card or from the player sheet. | `game_id` only. |
| `follow` | The user follows a creator. | `game_id` is the game on whose card the follow happened; the followed creator is resolved server-side from the follow action, not from this row alone. |
| `quick_exit` | The player sheet closes after a short session, per `GameplayTelemetryPolicy.shouldTrackQuickExit` (a threshold, not every close). Distinguishes a bounce from a real play. | `duration_ms`. |

Deliberately **not** emitted by iOS, and why:

- `play_start`, `completion`, `replay` — derived by the backend from
  the web runtime's `session_start` / `run_end` events. The app must
  not duplicate them: the shell cannot observe run end without a JS
  bridge, which the bridgeless posture forbids, and double-counting
  would corrupt completion rates. If a query needs plays, it reads
  the backend-derived rows, not app rows.
- `like`, `report`, `block`, `not_interested`, muted topics — these
  are actions with their own endpoints (`/v1/games/{id}/feedback`,
  follow/block/preference endpoints), not social-event kinds. Do not
  infer them from social events.

## Player telemetry kinds emitted by iOS

`runtimeVersion` is `ios-player-1.1`. Payloads carry game id, kind,
name, message, and the last 20 lines of the on-device dev log — never
account identifiers, tokens, or user content.

| Kind | Meaning |
| --- | --- |
| `perf` | `PlayerLoad`, `PlayerBackground`, `PlayerForeground` lifecycle marks. |
| `ios-load-failed` | The player failed to load (mapped failure; see #53). |
| `ios-webview-terminated` | The WebContent process terminated; the player reloads per policy. |
| `ios-memory-warning` | The app received a memory warning while playing. |
| `ios-thermal` | Thermal pressure reported while playing. |

## Privacy rules

- No event or telemetry payload carries an account identifier, an
  auth token, or user content (captions, comments, drawings).
- Identity today is the demo `X-User-ID` header (#10, open): events
  are attributable to a demo identity, not an authenticated user.
  Any retention or access policy must be revisited when #10 lands.
- The test-feedback export (Profile → Diagnostics) is a separate,
  user-initiated artifact, not an event stream, and is never sent
  automatically.

## Delivery semantics (read before querying)

- Social-event sends are fire-and-forget: a failed request is
  swallowed (`try?`), so counts are a lower bound on what happened
  on device, not an exact census.
- Every send generates a fresh `event_id`, so a retried or
  double-sent event would appear twice unless the server dedupes on
  `event_id`. Server-side dedupe on `event_id` is **not verified** —
  open item below. Until it is, treat near-duplicate rows (same
  game, kind, and millisecond window) as suspect.
- `expected_duration_ms` is 0 from iOS, so engagement normalized by
  expected length cannot be computed from iOS rows alone today; the
  backend must join expected length from the game record.

## Versioning

- This is schema v1. A new kind, a new field, or a changed meaning
  for an existing field requires a version bump here and a note of
  what changed and when.
- Removing a kind is a breaking change for dashboards: announce it
  in this document before removing the send site.

## Open items (#17 acceptance, not yet met)

- End-to-end validation of each kind (a scripted run producing one
  row of each kind, checked server-side) — not yet done.
- Server-side dedupe on `event_id`, or an explicit measurement of
  duplicate delivery — not verified.
- Retention period, data access, and dashboard queries distinguishing
  feed exposure vs play starts vs completion — not defined here;
  do not assume a policy that is not written down.
- `expected_duration_ms` population, so engagement can be normalized
  by game type and expected length.
- Revisit identity and retention when authenticated identity (#10)
  replaces the demo header.
