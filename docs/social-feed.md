# Hephaestus social-feed implementation

## Current client behavior

- Compact-width windows use bottom navigation (Discover, Create, Library, Profile).
- Regular-width windows use a persistent sidebar and a two-column game discovery grid.
- Discover exposes For You, Following, and Friends feed scopes.
- For You is connected to the existing public feed API.
- Following and Friends show an explicit not-yet-connected state. They do not disguise the public catalog as a personalized/social feed.
- Save and recent-play state are currently local to the device.
- Game cards avoid fabricated creator names, avatars, engagement counts, or activity.
- The current player remains the immersive destination for a game.

## Backend contract needed to complete the social product

1. Authentication and stable account identity. The existing demo user ID header must not be treated as authentication.
2. Creator profiles and follow/unfollow relationships. Mutual follows can initially define Friends.
3. A published post/game model with immutable game-package version, creator ID, caption, topics, visibility, timestamps, moderation state, and remix attribution.
4. Cursor-paginated endpoints for For You, Following, and Friends.
5. Server-backed reactions, comments, saves, shares, reports, blocks, and creator/topic follows.
6. Event ingestion for feed impressions, play starts, normalized play duration, completion, replay, shares, follows, and negative feedback.
7. Server-side moderation/eligibility before content enters public recommendation feeds.

Suggested initial API shape (names are proposals, not implemented endpoints):

- GET /v1/feed?scope=for_you&cursor=...
- GET /v1/feed?scope=following&cursor=...
- GET /v1/feed?scope=friends&cursor=...
- POST /v1/posts (publish a validated immutable game version with caption/topics)
- POST /v1/users/{id}/follow and DELETE /v1/users/{id}/follow
- POST /v1/posts/{id}/reactions
- POST /v1/posts/{id}/comments
- POST /v1/events

The client should only enable a feed mode when the corresponding authenticated API is available. Publishing should be an explicit, validated server operation, not a local-only success message.
