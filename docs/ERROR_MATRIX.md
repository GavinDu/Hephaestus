# Player error-category matrix (Hephaestus #53)

Cross-client matrix for how a player failure is classified, what the
user sees, and what the next action is. The governing rule is the one
from #53: **unsupported capabilities fail closed and never leave a
blank/black player screen**, and user-facing errors name the next
safe action without leaking backend details.

## The visibility boundary (read this first)

The iOS shell is bridgeless: it can only see WKWebView load errors.
It **cannot** see failures inside the page (a rejected package, an
unsupported IR version, a failed asset fetch). Those failures belong
to the web runtime, which records them to telemetry and renders its
own error state in the page. The shell must therefore never overlay
its own error on top of a page that loaded — `PlayerLoadingPolicy`
already enforces this for transient network loss, and the same logic
applies here: a loaded page owns its error display; the shell owns
only load failures and process termination.

Consequence: there are two error surfaces, not one. This matrix
keeps them separate. A row that says "shell: none" is not a gap — it
means the page is the surface for that failure.

## Matrix

### Delivery refusals (backend → runtime → page)

The backend's `deliverableGame` answers **404 for anything the viewer
may not see** — missing, restricted, quarantined, pending or rejected
moderation, and either-direction blocks are indistinguishable by
design. A distinct "denied" message would leak a game's existence,
so there is intentionally no authorization-failure category on any
client.

| Failure | Backend | Web runtime | iOS shell | User's next action |
| --- | --- | --- | --- | --- |
| Game not deliverable (missing, restricted, quarantined, pending/rejected moderation, blocked either direction) | 404 `game not found`, `private, no-store` | Package fetch fails with HTTP 404; page renders its error state | None (page loaded) | Close the player, return to feed |
| Game IR never published | 409 `Game IR has not been published` | Same as above | None | Close the player, return to feed |
| Published IR fails re-validation at the delivery boundary | 422 `published Game IR failed validation` | Same as above | None | Close the player, return to feed |
| Asset id not in the IR, or artifact content missing | 404 `asset not found in Game IR` / `asset content not found` | Asset load fails; page renders its error state | None | Close the player, return to feed |

### Runtime compatibility gates (web runtime, defense in depth)

The backend pins the format it serves, so these throws are second-line
defense — they exist so a stale or hand-built package can never boot
into a half-working game.

| Failure | Web runtime | iOS shell | User's next action |
| --- | --- | --- | --- |
| `packageFormatVersion` ≠ `2.0` | Throws `unsupported packageFormatVersion`; error state, telemetry `boot` | None | Close the player, return to feed |
| `minRuntimeVersion` invalid | Throws `invalid minRuntimeVersion`; error state, telemetry `boot` | None | Close the player, return to feed |
| Runtime older than `minRuntimeVersion` | Throws `game requires runtime X, current runtime is Y`; error state, telemetry `boot` | None | Update the app (the runtime ships with the backend player page, so this surfaces only for a stale cached page — a reload picks up the current runtime) |
| `irVersion` ∉ {1.0, 1.1, 1.2} | Throws `unsupported irVersion`; error state, telemetry `boot` | None | Close the player, return to feed |
| Entry scene missing | Throws `entry scene missing`; error state, telemetry `boot` | None | Close the player, return to feed |

### iOS shell failures (WKWebView load errors)

`PlayerLoadFailure` (`Hephaestus/Player/PixiPlayer.swift`) maps the
real `Error`, never a synthesized one, to exactly two fixed messages.
Raw detail goes to DevLog/telemetry, never the UI.

| Failure | Shell category | User-facing message | Next action |
| --- | --- | --- | --- |
| Not connected, timed out, connection lost, cannot find/connect host, DNS lookup failed | `network` | "Check your connection and try again." | Retry; the error card offers Return to feed and covers the full screen |
| Any other load error (incl. TLS, cancelled, unknown) | `unknown` | "The player couldn't load this game." | Retry or Return to feed |

Lifecycle rules around these rows (already implemented, stated here
so the matrix is complete):

- A loaded game is never reloaded just for backgrounding or
  connectivity loss (`PlayerLifecyclePolicy`).
- A failed load retries on foreground only when back online.
- The offline overlay shows only while loading without an error —
  it never covers a loaded game or an error card.
- WebContent process termination (`ios-webview-terminated`
  telemetry) reloads per policy; repeated termination is a failure
  signal, not a silent loop (see open items).

### Runtime health failures (in-page, recorded)

| Failure | Runtime behavior | iOS shell | User's next action |
| --- | --- | --- | --- |
| WebGL context lost | Recorded as `context` error; the frame freezes with a named error rather than a silent error storm or a black screen | None (page loaded) | Close and reopen the player |
| Render error repeating every frame | Recorded once as `render` (a frozen frame with a named error beats an error storm) | None | Close and reopen the player |
| Memory warning / thermal pressure during play | `ios-memory-warning` / `ios-thermal` telemetry; quality auto-steps down where supported | None unless the process terminates (row above) | None; quality reduction is automatic |

## Caching and restricted content (#53 requirement)

Verified server-side in `package.go`:

- Only ready, public, approved, unquarantined games get shared
  caching: a strong SHA-256 ETag with `public, max-age=0,
  must-revalidate`.
- Everything else (owner previews, restricted, quarantined,
  unapproved) gets `private, no-store` and `Vary: X-User-ID`, so a
  shared proxy can never serve one viewer's restricted content to
  another, and access checks run before any 304 answer.
- The `/player` shell itself carries no game data and stays open;
  it renders the runtime's error state when delivery refuses.

## What is not yet covered (open, not claimed)

- **Load-time asset integrity:** the package carries a SHA-256 per
  asset, but load-time re-hashing by the runtime was not verified
  for this matrix. Until it is, an integrity mismatch has no proven
  client-side category — it would surface as an asset load failure
  at best.
- **Resource-budget violations as a user-facing category:** upload
  caps exist server-side and memory/thermal pressure is telemetered,
  but there is no documented budget threshold that turns into a
  player-facing "too large" state.
- **Shared golden/negative fixtures:** backend validation tests and
  the playability kit exercise valid/invalid content, but a shared
  fixture set exercised by backend tests, the browser player, and
  the iOS player alike does not exist yet. This matrix is the spec
  such fixtures should be built against.
- **Repeated WebContent termination:** the reload policy exists, but
  no documented cap after which the shell stops retrying and shows
  the error card instead.
