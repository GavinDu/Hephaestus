# Pending implementation backlog

Last reconciled: 2026-10-23. This is a status ledger, not a claim that every item is production-ready. Items marked in progress must remain open until the referenced implementation is merged and verified.

## Security and account boundaries

- [ ] **#10 — Authenticated identity (deferred by product decision).** The app and backend still use the development `X-User-ID` identity. Do not treat it as authorization. Complete Sign in with Apple/session validation and cross-user authorization before public launch or storing meaningful personal data.
- [ ] **#11 — Durable follow graph (deferred by product decision).** Follow edges are written to the backend's local JSON snapshot, but there is no shared database, transactional guarantee, schema migration, or multi-instance consistency. Add shared durable storage and migration before multi-instance deployment or when users rely on relationships.

## Social product

- [x] **#12 — Feed scopes and follow controls.** The iOS client requests For You/Following/Friends, refreshes follow state from the backend, has loading/error/empty states, and guards feed requests against stale responses. Follow edges use local-file persistence only; demo identity remains spoofable.
- [ ] **#13 — Immutable published posts.** Publishing marks a game version and rejects republishing the same record. Still verify that later edits to game/package/assets cannot mutate an already-shared artifact; a dedicated immutable publication snapshot and regression test remain required.
- [ ] **#14 — Reactions, comments, saves, and sharing.** Core reactions/comments/saves/report/share-related APIs exist and local snapshot persistence is available. Backend PR #11 adds optional idempotent comment creation; it must pass CI and merge before considering duplicate-request handling complete. Local files are not shared storage.
- [ ] **#15 — Creator profiles and discovery.** Creator profile, public post list, counts, and follow state exist. Search/discovery of creators and topics is not yet complete; counts reflect only the current follow store.
- [ ] **#16 — Publishing safety and moderation.** Publishing is gated by package readiness and pending moderation; reports, blocks, moderation-token-gated actions, and delivery eligibility checks exist. Automated semantic review of captions/media, an auditable moderation history, and an appeal/contact workflow remain open.
- [ ] **#17 — Feed/gameplay telemetry.** Impression, play, completion, replay, share/save/follow and quick-exit signals are wired in the app/backend. Versioned schema, end-to-end deduplication, retention/access policy, and validated dashboards remain open.
- [ ] **#18 — Feed ranking.** Current ranking is explainable and diversifies creators. Backend PR #11 adds a newest-first fallback until at least 20 indexed event/reaction signals exist. Keep ranking behind evaluation and a documented rollback; do not optimize raw time spent as the sole success metric.
- [ ] **#19 — Recommendation controls.** Not-interested and block controls exist. Backend PR #11 adds topic mute/read/reset endpoints and persistence in the local social snapshot; iOS PR #23 adds the topic preference UI. Merge only after backend CI and iOS build/tests pass.
 
## Operations and delivery

- [ ] **#20 — Multi-instance operation and recovery.** Current JSON snapshot/JSONL event persistence is single-instance only. Operational notes describe decision triggers and a recovery checklist; a real backup/restore drill, measured load test, shared durable storage and migration/rollback plan remain required before scaling.
- [ ] **#21 — Media/package delivery.** Package/version endpoints and asset validation/size gates exist. Collect package-size, request-byte, latency, error-rate and cache metrics before deciding on object storage/CDN. Verify immutable cache keys, removed-content behavior, and unsafe asset URLs at both publish and load boundaries.

## Runtime architecture guardrail

The iOS player currently executes the data-defined Game IR through the PixiJS + Rapier runtime in a WKWebView. Do not restore a second native interpreter without a specific compatibility requirement and conformance plan. Keep validation vocabulary aligned with the runtime and reject unsafe asset references before they are fetched or rendered.

## Open PR reconciliation

- Hephaestus PR #23 contains the recommendation-control UI and stale-pagination hardening; it depends on backend PR #11.
- Hephaestus PR #8 is the earlier backlog-document PR; this file supersedes its intended documentation, but close that PR only after confirming its remaining diff has no unique useful content.
- Older feed/follow and reaction/comment PRs are superseded only where their unique behavior and tests are present in merged PR #22 or backend PR #10. Review their diffs before closing; never discard unique tests without porting them.
- Backend PR #11 must pass formatting, unit tests, race tests, static analysis and browser/playability checks before merge.

## Definition of done

For each issue, require: implementation on the canonical branch, tests that fail before the fix and pass afterward, successful CI, documentation that states remaining limits, and only then issue closure. Keep #10 and #11 open until explicitly authorized to revisit them.
