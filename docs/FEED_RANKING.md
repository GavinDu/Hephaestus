# For You feed ranking: the client contract (Hephaestus #18)

The server owns feed order; the app renders it. This doc records that
contract as implemented, so a future ranking change has a verified
baseline to argue against. It does not propose new weights: the
backend ranker, its fixture tests, and its evaluation protocol
already exist (backend `docs/FEED_RANKING.md`,
`docs/FEED_RANKING_EVALUATION.md`,
`internal/api/feed_ranking_fixture_test.go`).

## What the client does: nothing to the order

`DiscoverView.load()` stores the `GET /v1/feed` response order
unchanged. The app sorts only topic lists and saved-ID sets, never
the feed itself, and the For You pager (docs/FOR_YOU_PAGER.md) pages
through the same returned order. Any order a user sees is therefore
fully explained by the server section below, plus the client's
scope/search state (For You vs Following vs Friends, search text).

## What the server does, in order (backend `handleFeed`)

Eligibility first, then ranking, then exploration, then
diversification. Every step below is read from the handler, not
assumed.

### 1. Eligibility (before any ranking)

A game reaches ranking only if all of these hold:

- Status ready, visibility public, not quarantined, moderation
  status neither `pending` nor `rejected`.
- Creator not blocked in either direction for this viewer.
- Game not marked not-interested by this viewer.
- None of its topics muted by this viewer (case-insensitive,
  `#`-prefix stripped).
- Scope filter: Following keeps only followed creators; Friends
  keeps only mutual follows. For You has no relationship filter.

Blocked/quarantined/ineligible games never reappear later: the
diversification step below only reorders the eligible list.

### 2. Ranking mode: cold start vs engagement

Count social signals: every indexed social event except
`player_ready` and `player_session_summary` (player diagnostics
are observability, not engagement evidence), plus reaction
counts. While the total is below 20, the feed is newest-first
with a stable sort. The 20-signal threshold is a guardrail
against overreacting to a handful of early events, not a learned
parameter.

At or above 20 signals, and only then, games sort by quality
score, ties broken newest-first:

- Base score: freshness `1 / (1 + ageHours / 24)` plus
  `0.03 * (reactions + weighted engagement)`, where weighted
  engagement counts completion 2, replay 1.5, share 1.25,
  save 1.25, quick_exit -0.5. Unknown event kinds contribute
  nothing.
- Rate terms, each smoothed so one early event cannot make a
  perfect score: tap rate `plays / (impressions + 3)` at 0.20,
  completion rate times duration-normalized completion quality
  at 0.18, replay rate times normalized replay quality at 0.10.
  Duration normalization is `duration / expected`, capped at 1,
  so a short game is not punished for being short and a long
  game is not rewarded for merely lasting longer.
- Penalties: quick-exit rate at 0.18, and a time-to-interactive
  penalty that is zero below 1.5s and ramps to a 0.15 cap at 6s.
  (TTI here is backend-observed; the iOS shell cannot measure
  first frame, per docs/PLAYER_HANDOFF.md.)

### 3. Exploration, then diversification

Both steps run on the ranked list, in this order:

- Exploration: a recent low-impression candidate (fewer than 3
  impressions) is promoted into every fifth position, keeping
  the ranked order inside each pool. Skipped entirely when
  either pool is empty.
- Diversification: creators are round-robined in score order,
  so one prolific creator cannot fill the feed. Each creator's
  internal order stays intact. This step runs in newest-first
  mode too, so even the cold-start feed is creator-interleaved.

Pagination (`limit` 1-50, default 20; cursor = last game ID of
the previous page) applies after all of the above, so a page
boundary never re-ranks.

### Rollback

`DQ_FEED_RANKING_ENABLED=false` (also `0`, `off`, `disabled`)
restores newest-first immediately; the default is enabled with
the cold-start fallback above. The flag is server-side: no app
update is needed to roll back.

## Gaps against the #18 acceptance criteria

Stated, not papered over:

- **Order is not debuggable from the client.** The feed
  response carries games, scope, cursor, and card state, but no
  ranking mode and no per-game score. The app cannot tell the
  user (or a log) whether a page was newest-first or
  engagement-ranked, or why a game placed where it did.
- **The evaluation protocol has not been run.** The backend
  evaluation doc specifies fixtures, metrics (completion/replay/
  quick-exit rates, creator diversity incl. HHI, freshness,
  safety, performance), and ship/revise/roll-back gates, and
  states itself that it does not claim the benchmark has run.
  Weights must not change on a single fixture or a small
  production sample.
- **Two issue-scope signals are not ranking inputs.**
  Topic relevance and relationship are filters/scope, not
  boosts: For You does not up-rank followed creators' games or
  topic matches. That is a deliberate scope gap, not an
  oversight to fix silently; it needs a decision if it is ever
  wanted.
- **Short-game fairness is partial.** Duration normalization
  handles completion quality, but the base score's freshness
  term still favors new games regardless of length. The
  evaluation's freshness metric is the check on that trade-off.

## What this doc does not cover

Personalized recommendation (no per-viewer model exists),
topic/relationship boosts (see gaps), and any client-side
re-ranking (there is none). If a future change adds any of
these, this doc's server section must be re-verified against
the handler, not edited from memory.
