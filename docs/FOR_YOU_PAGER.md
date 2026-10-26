# For You pager design (Hephaestus #59)

Status: approved by Gavin 2026-10-26; implemented in `ForYouPagerView`
(`Hephaestus/Views/AppTabs.swift`, For You scope only, card grid kept
for other scopes and search).

Design proposal for the full-screen vertical pager for the For You feed.
This document is the design step; implementation follows after review.
It does not change any code.

## Problem

Today the Discover feed is a `ScrollView` + `LazyVStack` of cards
(`DiscoverView` / `GameFeedCard` in `Hephaestus/Views/AppTabs.swift`).
Cards share the screen, several previews can be near-visible at once,
and the single shared `FeedPreviewPlayback` player has to guess which
card owns the screen. The #62 Play feed epic wants a feed where one
game owns the screen at a time, like the short-form feeds users already
know — and where preview dwell, impression, and play intent are
unambiguous per page.

## Goals

- One game per screen, full-bleed, vertical paging with a settle
  animation. The settled page is the only page whose preview may play.
- Preview lifecycle follows the page, not scroll guesses: the settled
  page's clip autoplays (subject to the existing `FeedPreviewPolicy`:
  no autoplay on Low Power Mode, constrained network, or reduced
  motion); leaving a page stops its clip and reports its measured
  dwell (the #61 slice already reports dwell on stop — the pager just
  makes stop moments exact).
- Play, save, like, follow, share, comment, report, block, and
  not-interested actions work from the page without leaving it, and
  the player sheet opens over it exactly as today.
- The existing card content is reused, not redesigned: cover/poster,
  title, creator row, and action row move into the page unchanged in
  a first pass. Visual redesign is out of scope.
- iPad and accessibility are first-class, not retrofits (see below).

## Non-goals

- The post-run result sheet (#60) — a separate slice that needs a
  run-end signal from the runtime.
- Hand-made preview clips (#55) — content work, independent of the
  pager container.
- Feed ranking (#18) — the pager renders whatever order the backend
  returns; ranking changes stay server-side.
- Replacing the existing card feed everywhere: the pager is the For
  You experience. Saved games, creator profiles, and search keep
  their list layouts.

## Proposed shape

A new `ForYouPagerView`, used by the For You tab in place of the
current card list:

- Paging container: a vertical `ScrollView` with
  `scrollTargetLayout` + `scrollTargetBehavior(.paging)` (iOS 17+),
  one page per game, each page sized to the visible area. This is
  preferred over `TabView` + `PageTabViewStyle` because the feed
  already manages a shared preview player and per-page lifecycle,
  and scroll-target paging keeps that control in the feed's hands
  instead of inside a tab view's selection state.
- Page identity: the game id. The settled page is derived from the
  scroll position (scroll-target id), not from visibility heuristics.
  When the settled id changes: stop the previous page's preview
  (which reports its dwell), schedule the new page's preview.
- Prefetch: the feed already pages from the backend; the pager
  requests the next page of feed data when the user settles within
  two pages of the end, same as the current list's load-more trigger.
- Toolbar and chrome: the tab bar stays visible (the pager is a tab,
  not a full-screen takeover). The player sheet, share sheet, and
  moderation/report sheets open over the pager unchanged.
- End of feed: a terminal page ("You're all caught up") with an
  explicit refresh action, instead of an infinite spinner. Empty
  feed keeps the current empty state.
- Offline: if the device goes offline mid-pager, pages already loaded
  stay viewable; new pages show the existing offline treatment, and
  previews do not autoplay (existing policy).

## iPad and layout

- Pages are full-height but width-capped on regular size classes:
  the page content centers in a readable column (the same
  `stateCardMaxWidth`-style cap idea, sized for a game page) instead
  of stretching edge to edge on a 12.9" display. Compact width
  (iPhone, iPad Split View narrow) uses the full width.
- Safe areas: page content respects the top (status bar / Dynamic
  Island) and bottom (home indicator, tab bar) insets; the cover art
  may bleed under the top inset, but titles, creator rows, and
  action rows never sit under an inset.
- Orientation: portrait and landscape both page vertically; the page
  height follows the visible area on rotation, and the settled page
  is restored after rotation (by game id, not by pixel offset).

## Accessibility

- VoiceOver: each page exposes one accessibility element group —
  title, creator, and actions — in reading order; paging announces
  the new page's title on settle.
- Reduced motion: when `accessibilityReduceMotion` is set, paging
  settles without animation and previews never autoplay (existing
  policy), so the pager degrades to a swipeable list of still pages.
- Dynamic Type: page chrome uses semantic text styles, not fixed
  point sizes, so titles and action labels scale. (Fixed-size cover
  art and iconography are exempt; they are not text.)
- Touch targets: every page action keeps the 44pt minimum already
  enforced by `HephaestusDesign.minimumActionHeight`.

## Telemetry (unchanged kinds, exact moments)

- `impression`: when a page settles (replaces today's
  on-appear impression, which could fire for several near-visible
  cards at once).
- `preview_dwell`: when a page is left, with the measured dwell
  (the #61 slice's stop-based reporting; the pager makes the stop
  moment exact).
- `play_start`, `completion`, `replay`: unchanged — derived by the
  backend from runtime session events, not duplicated by the app.
- No new event kinds, no new identifiers, no user content in any
  payload.

## Verification

- Layer 0: unit tests for the settled-page derivation (scroll id ->
  page id, end-of-feed trigger distance, rotation restore by id)
  where that logic is pure enough to test without a view host.
- Layer 1 (gated, not per-PR by default once Phase 3 lands):
  extend the player smoke test with a pager pass — settle on a page,
  confirm its preview plays and the previous page's preview stops,
  open the player from a page, return to the same page.
- Physical (Phase 4 checklist, per release): paging feel, safe
  areas, and rotation on a representative iPhone and iPad.
- Rollback: the pager is a new view behind the For You tab only;
  if it regresses, the tab reverts to the card list in one change
  with no data migration.

## Open questions for review

1. Should the pager replace the For You tab outright, or ship
   behind a flag for one release? Proposal: outright, with the
   one-change revert above as the safety net — a flag doubles the
   feed code paths for a container change.
2. Page width cap on iPad: full-bleed cover with a capped content
   column (proposal), or a capped page including the cover?
3. Does the terminal "all caught up" page also offer a jump back to
   the top, or only refresh?
