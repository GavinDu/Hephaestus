# DoodleQuest backend API (for the Hephaestus iOS app)

Base URL (production): `https://html-5-game-generator.replit.app`
Local dev: `http://localhost:8080`

Auth: pass the user id as the `X-User-ID` request header. If omitted the
server uses `demo-parent`. (Stub for Sign in with Apple; the parent account
owns creations.)

All JSON. Errors: `{"error": "..."}` with a non-2xx status.

## Health / player

| Method | Path | Notes |
|---|---|---|
| GET | `/healthz` | `{"status":"ok","service":"doodlequest"}` |
| GET | `/` | 302 → `/player` |
| GET | `/player` | Web player (HTML). Load in WKWebView — see `PLAYER.md`. |

## Game generation pipeline

```
POST /v1/ingest → POST /v1/games → (job runs) → POST /v1/games/{id}/confirm → GET /v1/jobs/{id} (poll)
```

| Method | Path | Body → Response |
|---|---|---|
| POST | `/v1/ingest` | `{images: [base64…], keywords: [str]}` → `{ingest_id, elements: [{name, role}], guessed_intent}` |
| POST | `/v1/games` | `{ingest_id?, elements: [{name, role}], intent?, keywords?}` → `202 {game, job}` (job runs async, pauses for confirm) |
| GET | `/v1/games/{id}` | → game object (status, title, elements, job_id, visibility) |
| POST | `/v1/games/{id}/confirm` | confirm the design doc; generation resumes |
| GET | `/v1/jobs/{id}` | → job status for polling |

## Game bundles (HTML5 / GameShim v1)

| Method | Path | Notes |
|---|---|---|
| GET | `/v1/games/{id}/bundle` | manifest.json |
| GET | `/v1/games/{id}/bundle/game.js` | game code (GameShim v1) |
| GET | `/v1/games/{id}/bundle/sprites/{sprite}` | sprite PNG |
| GET | `/v1/games/{id}/bundle/audio/theme.wav` | music |

## Feed, groups, leaderboard

| Method | Path | Body → Response |
|---|---|---|
| GET | `/v1/feed` | → `{games: [...]}` public games |
| POST | `/v1/groups` | create invite-based group |
| POST | `/v1/groups/{id}/join` | join a group |
| GET | `/v1/groups/{id}/games` | games shared with the group |
| POST | `/v1/games/{id}/visibility` | `{visibility: private\|group\|public}` |
| POST | `/v1/games/{id}/scores` | `{name, score, level}` → `{rank, name}` (best run per player, ranked by level then score) |
| GET | `/v1/games/{id}/leaderboard` | → `{scores: [{name, score, level}]}` top 10 |

## Godot versions

| Method | Path | Notes |
|---|---|---|
| GET | `/v1/godot` | → `[{id, title, ready, url}]` — Godot 4.7 web builds |
| GET | `/godot/{game}/` | Godot web export (index.html). Served with `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp` (required by the engine). First hit downloads/extracts a ~10MB zip, so allow ~30–60s. |

## GameSpec (engine decision maker)

| Method | Path | Body → Response |
|---|---|---|
| POST | `/v1/spec/decide` | GameSpec JSON → `{engine: "html5"\|"godot", rationale: [str], scores: {html5, godot}}` |
| GET | `/v1/spec/questionnaire` | → `{specVersion, factors: [...]}` — the 31-factor questionnaire; see `GAME_SPEC.md` |

GameSpec details: `internal/gamespec` in the backend repo
(`github.com/GavinDu/html5-game-generator`).
