# Preview-to-game handoff design (Hephaestus #58)

Design proposal for making Play feel like the clip turning into the
game. This document is the design step; implementation follows after
review. It does not change any code.

## What already exists (do not rebuild)

The pooled-web-view half of #58 is already implemented in
`Hephaestus/Player/PixiPlayer.swift` (`PlayerWebViewPool`) and the
feed card:

- One pooled `WKWebView` on a shared `WKProcessPool` — so there is
  ever one live runtime view, and its process (and any warmed
  caches) survive across plays.
- Prewarm on finger-down: the feed card's simultaneous zero-distance
  drag gesture calls `PlayerWebViewPool.prewarm(gameID:)` without
  stealing the Play tap or changing its accessibility.
- `take(url:)` / `recycle(webView:)` on sheet open/dismiss: the
  sheet reuses the pooled view when its navigation already finished
  (including the case where the prewarmed navigation finished before
  the sheet attached its delegate, which delivers readiness after
  mount), and returns the view to the pool on dismiss.
- The preview stops when the player opens (`FeedPreviewPlayback`
  stops on player presentation), so a clip never plays under a game.
- The sheet already drives its loading indicator from
  `estimatedProgress` and its ready state from navigation finish.

What #58 still owes is the *feel* of the handoff, not the pool.

## Goals

- Tapping Play keeps the last preview frame on screen with a
  progress indicator, then crossfades to the live game when ready
  — no white flash, no black frame, no jump to a spinner.
- A swipe down (or close) returns to the same card and scroll
  position it came from.
- Tap-to-interactive is measured, against the 1.5 s median budget
  on Wi-Fi stated in #58 — and the measurement must say honestly
  what "interactive" means (see below).
- Only one live runtime exists at a time (already guaranteed by
  the pool; the handoff must not break it by warming a second view).

## The readiness problem (the one design decision that matters)

The shell is bridgeless: it can observe navigation finish and
estimated progress, but it **cannot** observe the runtime's first
frame. "The runtime reports ready" therefore has two possible
meanings, and the design must pick one:

1. **Navigation finished (implementable now, no runtime change).**
   The sheet already treats this as ready. The crossfade would run
   on navigation finish. Risk: the page may still be booting the
   game behind the crossfade, so the first visible game frame can
   lag the crossfade by the runtime's boot time. This is the honest
   version of "ready" the shell can offer today.
2. **First frame rendered (needs a runtime-side signal).** The
   runtime would have to expose readiness through a channel the
   shell can observe without a JS bridge — for example a
   same-document navigation, a document-title change on first
   frame, or a query the shell polls via the page URL. All of these
   are workarounds with their own fragility, and they need a runtime
   change plus a contract, not just app code. The probe gate already
   measures first-frame readiness from the browser side
   (`booted`/`frames`), so the signal exists — it is the
   shell-observable form of it that is missing.

Proposal: build the handoff on definition 1 now (crossfade on
navigation finish, with the last-frame hold covering the boot gap
visually), and treat definition 2 as a follow-up runtime contract
if the boot gap proves visible in practice. Do not fake definition
2 from the shell: reporting "ready" before the game can take input
would corrupt the tap-to-interactive measurement.

## Proposed shape

- **Last-frame hold:** when Play is tapped, snapshot the preview
  surface (the `FeedPreviewSurface` view for that card, or its
  poster when the clip never started) and use the snapshot as the
  sheet's backdrop. The snapshot is a still image, not a live view,
  so it costs one frame of memory and cannot keep playing — that is
  the point: it holds the eye while the game boots.
- **Progress indicator:** the existing `estimatedProgress`-driven
  indicator stays, drawn over the snapshot, not over a blank sheet.
  If the pooled navigation already finished (prewarm hit), the
  indicator is skipped entirely — the crossfade runs immediately.
- **Crossfade:** on navigation finish, fade the snapshot out over
  the live web view (short, ~200–300 ms, disabled under Reduce
  Motion, where the swap is instant). The web view itself is already
  mounted behind the snapshot, so the fade is a pure opacity
  animation, not a view swap.
- **Return:** sheet dismissal returns to the feed; scroll position
  preservation is existing `ScrollView` behavior and must be
  verified, not rebuilt — a regression test (manual, Layer 1) that
  dismissing the player lands back on the same card at the same
  offset.
- **Failure paths stay intact:** a prewarm failure must not poison
  the pool — `markFailed` already exists; the sheet's normal load
  path (fresh load + error card) is the fallback when the pooled
  view failed. A failed prewarm must never surface as a player
  error before the user taps Play.

## Measurement

- **Tap-to-interactive (shell definition):** tap timestamp →
  navigation-finish timestamp, recorded per play as player
  telemetry. This is measurable today and is the number the 1.5 s
  median budget should be judged against until definition 2 exists.
- **Time to first input:** runtime-side only (first input event in
  the game). Not measurable from the shell; do not approximate it
  from navigation finish. The #61 note already records this split.
- **Prewarm hit rate:** share of plays where `take(url:)` returned
  an already-finished navigation. This is the number that says
  whether finger-down prewarming earns its memory cost. Log it as
  telemetry, not as a user-facing metric.
- **Budget review:** #58 says to revisit the 1.5 s budget after
  prototype measurements. The measurements above are the prototype
  data; the budget decision belongs in the follow-up, not in this
  doc.

## Verification

- Layer 0: unit tests for the pool state machine (prewarm →
  take-finished → recycle → take-again) where that logic is already
  pure enough; the snapshot/crossfade choreography is view code
  and is verified by Layer 1.
- Layer 1 (gated): extend the player smoke test — prewarm a game,
  open the player, confirm no blank frame appears between tap and
  first game frame (screenshot comparison at tap + 500 ms, or a
  pixel-diff against the snapshot), dismiss, confirm the feed is
  back on the same card.
- Physical (Phase 4 checklist, per release): tap-to-interactive
  feel on a real device over Wi-Fi and cellular, and the
  swipe-down return, on iPhone and iPad.
- Rollback: the handoff is additive (snapshot + fade over the
  existing sheet). If it regresses, removing the snapshot layer
  restores today's sheet in one change.

## Open questions for review

1. Crossfade on navigation finish (proposal) vs waiting for a
   runtime first-frame signal (needs a runtime contract)? The
   proposal is definition 1 now, definition 2 as a follow-up.
2. Snapshot source when the clip never started (poster) vs when
   the card is mid-clip — is the poster acceptable as the hold
   frame, or should the hold be skipped when no clip frame exists?
3. Is the 1.5 s budget judged on the shell definition
   (navigation finish) or held until first-frame measurement
   exists?
