# Pending implementation backlog

Last reconciled: 2026-10-23. This is a status ledger, not a claim that every item is production-ready.

**Status key:** `[ ]` pending · `[~]` in progress · `[x]` completed  
**Review triggers:** revisit when inviting external users, preparing public/App Store launch, adding backend replicas, or when measured traffic makes the current design insufficient. Prefer a small usable implementation over speculative infrastructure while the product has few users.

## P0 — Before broad public launch or meaningful personal data

- [ ] **#10 — Authenticated identity (deferred by product decision).** The app/backend still use caller-controlled `X-User-ID`; it is a development identity, not authorization. Add Sign in with Apple/session validation and derive actor identity from verified claims. Test cross-user authorization for feeds, follows, publishing, editing, deletion, and moderation.
- [ ] **#11 — Shared durable social graph (deferred by product decision).** Follow edges and social state use local JSON snapshot/event files. They can survive a single process restart but are not transactional shared storage and do not provide multi-instance consistency. Add shared storage, schema migrations, uniqueness guarantees, and a backup/restore drill before multi-instance deployment.

## P1 — Core social product

- [x] **#12 — Feed scopes and follow controls.** The iOS client supports For You/Following/Friends, refreshes follow state, and handles loading/error/empty states. Follow persistence is still single-instance local-file storage; Friends means mutual follows, not a production identity graph.
- [~] **#13 — Immutable published posts.** Backend PR #13 adds repair/tuning guards and regression tests for published games. Do not mark complete until CI can run and pass and publication/package/asset immutability is verified end-to-end. Existing shared links must continue to refer to the published version; edits should create a new draft/remix.
- [~] **#14 — Reactions, comments, saves, and sharing.** Backend interactions and local snapshot persistence exist. PR #29 carries idempotent comment creation; PR #30 adds author-only comment deletion. Retarget/revalidate #30 after #29 merges. Cross-instance durability and authenticated authorization remain open.
- [x] **#15 — Creator profiles and discovery.** Backend creator discovery PR #12 and iOS creator UI PR #25 are merged. Profiles show eligible public posts and server-backed follow state/counts; no fabricated avatars or popularity metrics.
- [~] **#16 — Publishing safety and moderation.** Publishing is gated on package readiness and pending moderation; report/block endpoints and delivery eligibility checks exist. PR #27 adds structured report reasons/details. Automated semantic review of captions/media, auditable moderation history, and an appeal/contact workflow remain open.
- [ ] **#17 — Feed/gameplay telemetry.** Impression, play, completion, replay, share/save/follow and quick-exit signals are wired. Still define a versioned schema, end-to-end deduplication, retention/access policy, and validated dashboards. Avoid collecting unnecessary personal data.
- [ ] **#18 — Feed ranking.** Keep ranking explainable and diverse, with a newest-first fallback until enough real engagement signals exist. Evaluate against a baseline and document rollback; do not optimize raw time spent as the sole success metric.
- [~] **#19 — Recommendation controls.** Not-interested and block controls exist. PR #29 adds topic mute/read/reset UI against backend preference endpoints. Merge only after iOS build, unit tests, and player smoke checks pass.

## P2/P3 — Driven by observed usage and operational need

- [ ] **#20 — Multi-instance operation and recovery.** Current JSON snapshot/JSONL event persistence is single-instance only. Before scaling, add shared durable storage, migration/rollback, measured load tests, and a verified backup/restore procedure.
- [ ] **#21 — Media/package delivery.** Package/version endpoints and asset validation/size gates exist. Measure package sizes, request bytes, latency, errors, and cache behavior before choosing object storage/CDN. Verify immutable cache keys, removed-content behavior, and unsafe asset URLs at both publish and load boundaries.

## Runtime architecture guardrail

The iOS player executes data-defined Game IR through the PixiJS + Rapier runtime in a WKWebView. Do not restore a second native interpreter without a concrete compatibility requirement and a conformance plan. Reject unsafe asset references before fetching or rendering.

## Open PR reconciliation

- Hephaestus PR #29 is the reconciled feed-preferences/pagination/idempotency/backlog PR; it replaces conflicted PR #23.
- Hephaestus PR #30 is stacked on #29 for author-only comment deletion; retarget it to `main` and rerun checks after #29 merges.
- Hephaestus PR #27 adds structured report reasons and optional details; it does not complete the full moderation roadmap.
- Hephaestus PR #8 is superseded by this reconciled ledger after its unique priority/trigger guidance has been retained here.
- Backend PR #13 must remain open until a successful Go validation, race/static analysis, and Chromium/WebKit playability run is available. Its latest Actions jobs failed before exposing any job steps/logs, so that failure is not yet attributable to source code.
- Keep #10 and #11 open until explicitly authorized to revisit them.

## Definition of done

Close an issue only after the implementation is on the canonical branch, regression tests exercise the failure case, required CI passes, and documentation states remaining limits. A UI alone does not complete a backend/security requirement.
