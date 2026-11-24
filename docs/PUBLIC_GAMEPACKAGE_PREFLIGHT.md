# Public GamePackage envelope preflight (#569)

Read-only source slice, ported from closed unmerged #347 without its old workflow edits.
Run against an operator-supplied trusted public HTTPS origin:

    python3 tools/test-feedback/verify-live-game-fixture.py --feed-url https://YOUR-TRUSTED-HOST/v1/feed --attempts 1

No authorization headers, game IDs, game hashes, creator data, raw bodies or arbitrary field names in output. A bounded 2 MB JSON body per request, strict duplicate-member/nonstandard-number rejection, no redirects, socket timeout, five distinct candidate packages per attempt. Only public-ready owner-linked inventory with existing moderation compatibility, exact same-origin package, v2 envelope shape and lowercase full hash/prefix consistency. URL validation rejects credentials, query, fragment, control characters, and nonstandard port. The trusted origin must be chosen by an operator; this is not a general SSRF defense for an untrusted URL service. The socket timeout is not a whole-request wall-clock deadline.

A successful result is **v2 shape only**; not canonical Go hash recalculation, deployed release proof, owner-profile admission, semantic runtime, authorization, GPU presentation, or score attestation. The CLI does not seed games, publish, or access private endpoints. The existing offline unittest discovery step picks up the tests; no mandatory live-smoke workflow changed. Actual live preflight gate remains #345/#368 and generator #513.

Rollback: revert this independent tooling commit only. Existing native #781 behavior is unchanged. No new feature branch while the repository is at its five-branch limit.
