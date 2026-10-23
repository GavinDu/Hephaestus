# Pending Implementation Backlog

This file tracks intentionally deferred work for Hephaestus. The current product is early and has few users, so prefer a small, usable implementation over production-scale infrastructure until real usage justifies the cost.

**Status key:** `[ ]` pending · `[~]` in progress · `[x]` completed  
**Review cadence:** revisit when onboarding external users, adding multiple backend instances, or preparing for public/App Store launch.

## P0 — Revisit before public launch or handling untrusted users

### [ ] Replace demo identity with authenticated identity
- **Current state:** backend requests use the `X-User-ID` demo header; clients can spoof another user.
- **Scope:** choose an authentication provider/flow; validate credentials server-side; derive actor identity from verified claims rather than a caller-controlled ID header; define account deletion and session expiry.
- **Acceptance criteria:** unauthenticated or invalid requests cannot act as another user; authorization is tested for feed, follow, publish, edit, delete, and moderation actions.
- **Trigger:** before inviting a broad public audience or storing meaningful personal/social data.

### [ ] Persist social relationships and user-owned state
- **Current state:** follow edges are process-local in `html5-game-generator`; they disappear on restart and are not shared across server replicas.
- **Scope:** add durable storage and migrations for follows; make follow/unfollow idempotent; define uniqueness, deletion behavior, and consistency expectations.
- **Acceptance criteria:** relationships survive restart/deploy; concurrent requests do not create duplicates; following/friends feeds agree with persisted relationships.
- **Trigger:** when test users expect relationships to persist, or before running more than one backend instance.
- **Related repository:** [html5-game-generator](https://github.com/GavinDu/html5-game-generator), API docs at `docs/social-feed-api.md`.

### [ ] Connect the iOS feed to backend social scopes
- **Current state:** the adaptive iOS UI exposes For You, Following, and Friends, but social-feed integration is incomplete.
- **Scope:** load each selected scope from the backend, implement follow/unfollow controls and refresh state, handle empty/error/loading states, and avoid stale results when users switch scopes quickly.
- **Acceptance criteria:** feed selection changes the request; following reflects actual server state; Friends means mutual follows; UI tests cover empty feeds, network failure, follow/unfollow, and switching scopes.
- **Dependency:** coordinate with the backend API in `html5-game-generator`. It may be implemented before durable storage as a development-only slice, but must not be represented as production-secure.

## P1 — Core social product capabilities

### [ ] Make a published game an immutable social post
- Separate editable creator drafts from published versions.
- Store creator identity, caption, topics, visibility, creation/publication time, runtime/package version, asset references, validation status, and optional remix parent/attribution.
- Existing shared links must continue to point to the published version even when the creator edits a draft.
- Acceptance: publication produces a stable version; validation failures cannot be published; remix attribution is preserved.

### [ ] Add durable social interactions
- Add reactions, comments, saves, shares, blocks, and user reports with server-side authorization.
- Define deletion, moderation, duplicate-request, and pagination behavior.
- Acceptance: interactions persist across sessions; blocked users/content are consistently hidden; tests cover authorization and abuse cases.

### [ ] Add user profiles and creator discovery
- Profile basics, public posts, follower/following counts, follow state, topic interests, and creator links.
- Add recommendations from followed creators and mutual-follow relationships only when sufficient real data exists.
- Do not fabricate avatars, popularity, or activity metrics.

### [ ] Add publishing safety and moderation gates
- Pipeline: draft → package validation → content/safety review → publish → distribution.
- Provide report/block flows, moderation actions, and an appeal/contact path appropriate to the release scope.
- Acceptance: unsafe or invalid packages cannot enter broad discovery; reports can be triaged; moderation decisions affect distribution.

## P2 — Feed quality and growth, driven by observed usage

### [ ] Instrument feed and play events
- Record impressions, starts, completions, replays, saves, shares, follows, reports, and quick exits with privacy-aware retention.
- Distinguish feed impressions from intentional plays; normalize engagement by game type/expected length.
- Acceptance: event definitions are documented, deduplicated where needed, and testable end-to-end.

### [ ] Evolve For You beyond newest-first
- Start with transparent rules: relevance, freshness, relationship, validated playability, creator diversity, and repetition penalty.
- Reserve some exposure for new creators; apply eligibility and moderation filters before ranking.
- Do not optimize solely for time spent; a short, satisfying game can be high quality.
- Acceptance: ranking is measurable, explainable enough to debug, and can be compared against a newest-first baseline.

### [ ] Add recommendation controls and feedback
- Not interested, topic controls, mute/block, and preference reset.
- Acceptance: feedback changes later recommendations and blocked content cannot leak into recommendations.

## P3 — Scale only when measurements justify it

### [ ] Multi-instance readiness and operational hardening
- Shared durable storage, migration/rollback strategy, rate limits, abuse monitoring, backup/restore, and service health metrics.
- Add queues/caching only when measured load or latency justifies them.
- Acceptance: documented recovery process and load tests based on observed usage rather than speculative scale.

### [ ] Revisit media delivery and package distribution
- Evaluate CDN/object storage, cache invalidation, package versioning, and download limits using real traffic and package-size metrics.
- Keep game execution sandboxed and validate asset references before loading or publishing.

## Current known constraints

- The backend's `X-User-ID` header is a development identity, **not authentication**.
- Social follow edges are in memory and are not durable.
- The For You feed is a public, newest-first catalog, not a personalized recommendation system.
- A small user count is a valid reason to defer infrastructure, but not to expose spoofable identity or unsafe user-generated content to an unrestricted public audience.

## Backlog maintenance

When work begins, change the item to `[~]` and link its PR/issue. When complete, mark `[x]` and record the PR or commit. Split an item if it becomes too large; do not mark a feature complete just because its UI exists.
