# Player-only nonpersistent WebKit credential-epoch storage

Parent [Runtime Epic #202](https://github.com/GavinDu/Hephaestus/issues/202), [resource #205](https://github.com/GavinDu/Hephaestus/issues/205), broad [cache/revocation #278](https://github.com/GavinDu/Hephaestus/issues/278), independently closable [#298](https://github.com/GavinDu/Hephaestus/issues/298).

## Scope and implementation

The production `PlayerWebViewPool` previously instantiated `WKWebViewConfiguration()`, implicitly selecting WebKit's **persistent** default site data. Blank navigation after native logout does **not** prove that WebKit cookies or cached assets have been purged. New player configurations explicitly reference one `WKWebsiteDataStore.nonPersistent()` scoped to the current Keychain credential fingerprint and a `WKProcessPool` for that same epoch. One speculative+attached WKWebView continues across handoff as before. Native `invalidateForSessionChange()` retires the view, cancels navigation, invalidates the document epoch nonce and rotates both the in-memory store and process pool before any subsequent player page can be constructed.

No app-wide WebKit or Safari clearing, no bearer injection into web scripts, and no changes to Game IR/replay scores. Prior sessions may briefly remain alive until old WebContent is disposed; the new identity is given different storage *objects*.

## Senior game-engine architect adversarial review boundaries

- Source-level Swift tests prove non-persistence, fresh store object identity, correct configuration process pool, and change-purge policy. They cannot prove real cookie/site-data deletion timing or that old private responses cannot be displayed.
- The narrow source slice **does not** close [#278](https://github.com/GavinDu/Hephaestus/issues/278) or [#205](https://github.com/GavinDu/Hephaestus/issues/205): private/removed game authorization and per-asset moderation/cache revocation, native Keychain vs WebKit credentials, backend token exchange, WebContent survivor races, 50-cycle physical iPhone/iPad memory/thermal, and post-restart behavior remain separate design/test gates.
- Verify old versioned document nonce + prewarm/close/retry still work with this store factory; source patch starts from [merged nonce PR #283](https://github.com/GavinDu/Hephaestus/pull/283), and must be independently retested on the exact current head.
- **Merge gate:** native Xcode/unit, iPhone player smoke, iPad evaluator, iPhone/iPad presentation and backend contract workflows complete success on this PR head; no skips or inherited green claims.

Future protected-player authentication should use a narrowly scoped, expiring, server-authorized credential transport (for example secure HttpOnly cookie issued by the backend with proper SameSite/origin constraints), and reauthorize package and asset fetches after creator/account/moderation changes. Do not put native Keychain bearers in JS or URLs merely to make a page load. Release owners must verify App Review/privacy conditions and physical device behavior.

Rollback reverts this isolated factory/configuration patch, restoring old pool behavior (and its acknowledged persistence risk) without changing the runtime semantic engine.
