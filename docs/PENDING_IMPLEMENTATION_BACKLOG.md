# Pending implementation backlog

Last reconciled: 2026-10-24. This is a status ledger, not a claim that every item is production-ready.

**Status key:** `[ ]` pending · `[~]` in progress · `[x]` implemented and validated within the stated scope.  
**Review triggers:** revisit when inviting external users, preparing public/App Store launch, adding backend replicas, or when measured traffic makes the current design insufficient. Prefer a small usable implementation over speculative infrastructure while the product has few users.

## P0 — Before broad public launch or meaningful personal data

- [ ] **#10 — Authenticated identity (deferred by product decision).** The app/backend still use caller-controlled `X-User-ID`; it is a development identity, not authorization. Add Sign in with Apple/session validation and derive actor identity from verified claims. Test cross-user authorization for feeds, follows, publishing, editing, deletion, and moderation.
- [ ] **#11 — Shared durable social graph (deferred by product decision).** Follow edges and social state use local JSON snapshot/event files. They can survive a single process restart but are not transactional shared storage and do not provide multi-instance consistency. Add shared storage, schema migrations, uniqueness guarantees, and a backup/restore drill before multi-instance deployment.

## P1 — Core social product

- [x] **#12 — Feed scopes and follow controls.** The iOS client supports For You/Following/Friends, refreshes follow state, and handles loading/error/empty states. Follow persistence is still single-instance local-file storage; Friends means mutual follows, not a production identity graph.
- [x] **#13 — Immutable published posts (core mutation guard).** Backend PR #13 merged and adds guards/regression tests preventing repair and difficulty-tuning endpoints from mutating published game IR. The current Go + browser validation workflow passed on PR #18 after merge. Keep the scope caveat: verify stable package/asset version pinning end-to-end before a broad public launch.
- [x] **#14 — Reactions, comments, saves, and sharing (single-instance scope).** Backend interactions, idempotent social-event IDs, comment idempotency, and author-only comment deletion are merged. Hephaestus PR #29 merged and its iOS build/test workflow passed. Cross-instance durability and authenticated authorization remain deferred under #10/#11.
- [x] **#15 — Creator profiles and discovery.** Backend creator discovery PR #12 and iOS creator UI PR #25 are merged. Profiles show eligible public posts and server-backed follow state/counts; no fabricated avatars or popularity metrics.
- [~] **#16 — Publishing safety and moderation.** Publishing is gated on package readiness and pending moderation; report/block endpoints, delivery eligibility checks, and structured report reasons/details are merged. Remaining: automated semantic review of captions/media, auditable moderation history, moderation operator workflow, and appeal/contact path. Required before broad public user-generated-content launch.
- [ ] **#17 — Feed/gameplay telemetry.** Impression, play, completion, replay, share/save/follow, and quick-exit signals are wired; social-event IDs are deduplicated by the backend within its bounded retained event window. Remaining: versioned event schema, documented retention/access policy, end-to-end validation, and privacy-aware dashboards/queries. Avoid collecting unnecessary personal data.
- [ ] **#18 — Feed ranking.** Keep ranking explainable and diverse, with newest-first fallback until enough real engagement signals exist. Evaluate against a baseline and document rollback; do not optimize raw time spent as the sole success metric. Depends on reliable telemetry and sufficient real usage data.
- [x] **#19 — Recommendation controls (current feature scope).** Not-interested and block controls plus muted-topic preferences and reset behavior are merged in Hephaestus PR #29; iOS build/test workflow passed. Validate that these controls influence any future ranking logic when #18 is implemented.

## P2/P3 — Driven by observed usage and operational need

- [ ] **#20 — Multi-instance operation and recovery.** Current JSON snapshot/JSONL event persistence is single-instance only. Before scaling, add shared durable storage, migration/rollback, measured load tests, and a verified backup/restore procedure.
- [ ] **#21 — Media/package delivery.** Package/version endpoints and asset validation/size gates exist. Measure package sizes, request bytes, latency, errors, and cache behavior before choosing object storage/CDN. Verify immutable cache keys, removed-content behavior, and unsafe asset URLs at both publish and load boundaries.

## Runtime architecture guardrail

The iOS player executes data-defined Game IR through the PixiJS + Rapier runtime in a WKWebView. Do not restore a second native interpreter without a concrete compatibility requirement and a conformance plan. Reject unsafe asset references before fetching or rendering.

## Open PR reconciliation

- Hephaestus PR #29 is merged and contains the reconciled feed-preferences/pagination/idempotency/backlog work, including author-only comment deletion. Its iOS build/test run passed.
- Hephaestus PR #30 was closed without merging because its author-only comment deletion change was folded into PR #29.
- Hephaestus PR #27 is merged and adds structured report reasons and optional details; it does not complete the full moderation roadmap.
- Hephaestus PR #8 is superseded by this reconciled ledger after its unique priority/trigger guidance has been retained here.
- Backend PR #13 is merged. A subsequent Go validation run on PR #18 completed successfully for Go tests/race/static analysis, Chromium, WebKit, and Playability Kit.
- Backend PR #16 (stabilize CI by serializing browser validation) was squash-merged after a fresh run passed all four jobs (Go tests/race/static analysis, Chromium, WebKit, Playability Kit). The merged main pipeline was separately validated in an isolated temporary checkout.
- Keep #10 and #11 open until explicitly authorized to revisit them.

## Definition of done

Close an issue only after the implementation is on the canonical branch, regression tests exercise the failure case, required CI passes, and documentation states remaining limits. A UI alone does not complete a backend/security requirement.
