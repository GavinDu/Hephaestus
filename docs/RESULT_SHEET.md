# Post-run sheet design (Hephaestus #60)

Design proposal for the sheet after a run: Play again, Next game,
Remix, Like. This document is the design step; implementation
follows after review. It does not change any code.

## The problem with the obvious design

The obvious design — "the app shows your result when the run ends" —
cannot be built honestly from the shell today, for two independent
reasons:

1. **The shell cannot observe a run ending.** The shell is
   bridgeless. It knows the player opened, how long it stayed open,
   and when it closed. It cannot know that a run ended, let alone
   whether it was won or what the score was. Run outcomes live in
   the runtime's `run_end` beacon (`won`, `score`, `durationMs`,
   `inputs`, `deadInputs`, `retries`), which the backend already
   receives and files (telemetry v2; a won run also records a
   social completion). The beacon never reaches the shell.
2. **There is no "my latest run" endpoint.** The backend keeps runs
   in a capped in-memory index for telemetry, and serves the
   leaderboard (v2, by window) — a board, not a receipt. A
   just-finished run may not be on the board at all, and matching a
   board row to "the run I just played" by timestamp under the demo
   identity (#10) is correlation, not identification. The app must
   not guess which board row was mine and present it as my result.

A third fact reframes the whole feature: **the game already shows
its result.** IR 1.2's experience block puts an in-canvas result
card in the game itself. The native sheet's job is therefore not to
display the result — it is to offer what the canvas cannot: native
actions (Play again, Next game, Remix, Like) after the run.

## Proposal: an actions sheet, not a result display

Build the sheet in two stages, and do not blur them:

### Stage 1 (implementable now, no backend or runtime change)

> Implementation note (2026-10-26): Stage 1 shipped as
> `PostRunSheet` in `Hephaestus/Views/AppTabs.swift`, triggered by
> the player sheet's session-end callback with
> `PostRunSheetPolicy` (the complement of the quick-exit
> boundary). It ships Play again, Next game, and Like. Remix is
> deferred: no Create entry point seeds a remix from an existing
> game yet (`publishPost` accepts `remix_parent_id`, but nothing
> in the app sets it), so a Remix button would have nowhere
> honest to go. It lands when a Create remix entry lands.

A sheet offered when the player closes after a real session — not
after every open, and not per run:

- **Trigger:** player close where the session lasted longer than
  the quick-exit threshold (the same `GameplayTelemetryPolicy`
  boundary that already distinguishes a bounce from a play). A
  bounce closes to the feed with no sheet; a real session closes
  to the sheet. Multiple runs in one session (the `retries` field
  exists because players retry) produce one sheet, not one per run.
- **Content, stated honestly:** the game title and the four
  actions — Play again (reopen the same game), Next game (advance
  to the next feed game), Remix (enter the Create flow with this
  game as the remix parent), Like (the game-level feedback action,
  which needs no run data). The sheet must **not** claim a win,
  a score, or a completion it did not observe. A neutral heading
  ("Thanks for playing" or just the game title) is honest; "You
  won!" from the shell is fabrication.
- **Why this is not a lesser version:** every action in #60's scope
  works at game level. Nothing in Play again / Next / Remix / Like
  needs the run's score. The result itself is already shown
  in-canvas, where it belongs.

### Stage 2 (needs a contract, not just app code)

A sheet that truthfully shows the run's outcome needs one of:

- **(A) A viewer-scoped latest-run endpoint.** The backend serves
  the latest `run_end` for (viewer, game). The app fetches it on
  player close and renders won/score/duration from the response.
  This is the cleanest design, but it needs backend work, and it
  is only as trustworthy as viewer identity — under the demo
  header (#10) it is best-effort, and it should be revisited when
  authenticated identity lands.
- **(B) A shell-observable runtime signal.** The runtime exposes
  run completion through a channel the shell can observe without a
  JS bridge — for example a navigation the shell's navigation
  delegate can see. This is the same class of workaround as the
  first-frame signal in the #58 handoff doc, with the same
  fragility, and it needs a runtime change plus a contract. It has
  one advantage over (A): it works even when the backend is
  unreachable at close time, because the signal is local.

Proposal: build Stage 1 now; choose between (A) and (B) when #10
lands or when a runtime contract is being cut for #58's
first-frame signal anyway — the two signals should share one
channel, not invent two.

## What the sheet must not do

- Must not infer a run outcome from session duration, from the
  leaderboard, or from the quick-exit flag. Duration is not a
  result; the leaderboard is not a receipt.
- Must not fire on a bounce (quick exit) or on an error close —
  a failed load closing to a "result" sheet would be nonsense.
- Must not duplicate the in-canvas result card's job. If Stage 2
  lands, the sheet shows the outcome once, in one place, and the
  canvas card remains the in-game moment.
- Must not block the return to feed: dismissing the sheet (swipe
  or close) lands back on the same card, as with the player sheet.

## Verification

- Layer 0: unit tests for the trigger policy (bounce → no sheet;
  real session → sheet; error close → no sheet; one sheet per
  player open regardless of retries).
- Layer 1 (gated): player smoke extension — play past the
  threshold, close, confirm the sheet appears with all four
  actions and no fabricated result; close within the threshold,
  confirm no sheet.
- Stage 2 verification belongs to its contract: a scripted run
  producing a known `run_end`, then the sheet showing exactly that
  outcome — never a leaderboard row guessed to be mine.

## Open questions for review

1. Stage 1 now (actions sheet, no claimed result) vs waiting for
   Stage 2 (true result display)? Proposal: Stage 1 now.
2. If Stage 2 is built, endpoint (A) or runtime signal (B) —
   or one shared channel with #58's first-frame signal?
3. Should "Next game" advance within the current feed order, or
   jump to a fresh recommendation? Proposal: current feed order,
   the card after the one just played.
