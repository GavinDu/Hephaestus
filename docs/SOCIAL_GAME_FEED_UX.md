# Social feed and game-first UX

## Product principle
Hephaestus is a social feed where the post is an experience you can play, not a link to a separate game catalog. The first action should be obvious: play. Saving and sharing stay adjacent to the playable content.

## Current implementation
- Discover is a scroll-first, lazy ScrollView feed rather than a plain List of titles.
- Cards use a consistent game-cover treatment, prominent title, primary Play action, Save, and native Share.
- Search filters the loaded feed locally; pull-to-refresh and toolbar refresh are available.
- Save state persists locally, while play history continues to populate Library.
- Loading, empty, search-empty, and network-error states are explicit.
- The player remains an immersive full-screen sheet so game controls have the full display and feed navigation does not compete with gameplay.
- The current backend feed model supplies only game ID and title. Cover art is therefore a branded placeholder, not falsely presented creator artwork.

## Feed-to-play journey
1. Browse cards without opening a detail page.
2. Tap Play now to open the game immediately in the immersive player.
3. Record the game in local recent history.
4. Close the player to return to the same feed position.
5. Save games locally or share a game reference.

## API contract needed for a richer social feed
Add fields additively to the feed response before displaying them in the client:
- `cover_url` or `preview_asset_url` — an approved, validated thumbnail/poster.
- `creator` — display name and optional avatar URL.
- `caption` — the creator's explanation or story behind the game.
- `created_at` and `version` — freshness and package identity.
- `play_count`, `like_count`, `remix_count` — only when backed by real server-side events.
- `tags` and `duration_estimate` — useful discovery metadata.
- `moderation_state` and `package_validation` — only publishable, validated packages enter the public feed.
The iOS app should decode these as optional fields during migration. Do not invent creator names, popularity counts, likes, or artwork when the backend has not supplied them.

## Next product iterations
1. Add real package preview art and creator/caption fields to the backend feed API.
2. Add server-backed reactions, sharing attribution, and remix lineage; keep local Save separate from public Like.
3. Add feed pagination and cursor-based loading; do not download the whole catalog into memory.
4. Cache feed metadata and preview images, use request cancellation on refresh, and show an offline/stale-feed state.
5. Add privacy-aware analytics for feed impression → play start → first meaningful input → completion/exit.
6. Revisit inline autoplay only after testing thermal load, memory pressure, accessibility, and battery. Default to user-initiated play rather than running many game runtimes while scrolling.

## Acceptance criteria
- A game can be started from the feed in one tap, with no intermediate detail screen.
- Returning from a game preserves scroll position.
- Save/unsave is immediate and survives app relaunch.
- Search, loading, empty, and offline/error states are accessible and testable.
- No fake engagement counts or ungrounded creator metadata appear.
- Feed cards have VoiceOver labels and at least 44pt interactive targets.
