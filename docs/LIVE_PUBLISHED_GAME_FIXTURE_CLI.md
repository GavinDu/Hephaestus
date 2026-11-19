# Offline public fixture preflight source contract (issue #569)

This standard-library Python helper is a **read-only verifier** for real public feed and versioned package data. It never seeds a game, publisher, creator profile or mocked player response. It does not attest the digest using the Go canonical marshaler and never passes browser-reported scores as verified runs.

Usage for an authorized manual/deployment diagnostic: `python3 tools/test-feedback/verify-live-game-fixture.py --feed-url https://html-5-game-generator.replit.app/v1/feed --attempts 3 --timeout 10`.

Offline negative unit coverage runs automatically under the existing Xcode workflow's `python3 -m unittest discover -s tools/test-feedback -p "test_*.py" -v` step. No external connection is required for these tests. The CLI intentionally is **not** a mandatory live pre-smoke gate yet: #345 owns that separate integration once the deployed backend and genuine published fixture satisfy #288/#368. This keeps one atomic diagnostic slice independently testable without masking an upstream outage or making every unrelated source PR red on a stale deployment.

The parser checks HTTPS same-origin public feed and package endpoints, strict no-redirect, exact game IDs, bounded reads/timeouts, canonical GamePackage v2 envelope fields and redacted categorical errors. It does *not* validate arbitrary IR semantics, full Go canonical SHA computation, creator profile resolution, deployed server SHA, renderer/GPU first pixel, physical memory/thermal, or independent replay/score attestation.

Risk review: only fixed allowlisted package key names can appear in missing-format diagnostics. Full responses, token values, creator names, URLs, arbitrary exception messages and raw IR are not printed. Game identity for successful probes is a short digest, not a public identifier. Security and live release gates remain under #345/#288/#368, generator #491, and Epic #202.