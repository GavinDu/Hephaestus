# One native published-game ID contract — successor #653

## Scope and source of truth

`PublishedGameIDPolicy.valid` is a pure, allocation-bounded Swift validator shared by the production **Pixi player/prewarm URL and Share** façade `PlayerPublishedGameIDPolicy` and the **verified-only leaderboard** façade `VerifiedLeaderboardGameIDPolicy`. Both historical wrappers remain source-compatible so no test or client is forced into an unrelated API migration.

Accepted public path/URL game identity: ASCII `[A-Za-z0-9_-]`, **1 through 128 UTF-8 bytes**, exactly as received. The implementation reads no more than byte 129 and rejects immediately; it never normalizes, trims, UTF-8 copies or decodes percent/URL escapes. It rejects dot paths/segments, slash, question mark, fragment, percent, whitespace, controls, Unicode and overlength. It is syntactic admission only, **not** a credential, moderation/publishing authorization, package IR integrity proof, or score/replay attestation.

## Cross-system boundary inventory

| Layer | Current native consumer / status | Contract check |
|---|---|---|
| iOS current player sheet | `PixiPlayerSheet` / `PlayerWebViewPool.playerURL` | Existing game ID guard routes into `PublishedGameIDPolicy` |
| iOS prewarm and Share | Player-pool and scene-ledger existing `PlayerPublishedGameIDPolicy` checks | One same predicate, unchanged WebKit/auth lifecycle |
| Native verified-only leaderboard | `BackendAPI.fetchUnavailableVerifiedLeaderboard` and its strict decoder | Old wrapper delegates to common predicate; no scores promoted |
| Offline CLI under original #569 / draft PR #648 | `verify-live-game-fixture.py` pending merge | Its proposed Python `SAFE_GAME_ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")` has the same **ASCII** language; original #569 remains unmerged because of required iPad UI gate |
| Go generator `GamePackage` | `GavinDu/html5-game-generator`, current `internal/api/package.go` | Server still authorizes requested published package and independently verifies Game IR/digest; this native source refactor **does not ratify** every server-side legacy ID or deployed tenant migration |

The Python fixture and the Go deployed/private inventory are not treated as verified integration proof. Native calls still require current credential epoch/lease, correct origin and published package compatibility. The source-contract test catches divergence between the two native caller wrappers and accidental reintroduction of array allocations.

## Acceptance, limitations and rollback

- 160+ hostile native-ID permutations, 128/129 boundary, 256 KiB large input, and URL guard checks in Swift Testing; Python source integration guard verifies real paths.
- Mandatory final-head GitHub Actions iOS build, iPhone/iPad WebKit smoke, iPad UI evaluator, native source/URL/backend/screenshot checks must all succeed before merge.
- Reverting this change restores the two original standalone validators and tests only, with no changed URLSession/JS trust or backend content.
- Physical iPhone/iPad performance, deployed private inventory, actual package readiness and server-owned score attestation remain distinct acceptance gates under #202/#288/#276/#279 and generator #360.
