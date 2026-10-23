# Hephaestus social-feed implementation

## Current client behavior

- Compact-width windows use bottom navigation (Discover, Create, Library, Profile); regular-width windows use a sidebar and adaptive two-column discovery grid.
- For You, Following, and Friends call distinct backend feed scopes. Friends means mutual follows.
- Feed cards support creator profile views, follow/unfollow, like/unlike, comments, server-backed saves, sharing, reporting, blocking, and Not interested feedback.
- New games can be published with a caption and topics from the creation completion screen. Publication enters moderation and is not shown in public discovery until approved.
- Feed impressions and play starts are submitted as lightweight social events. Completion/replay/share events can be added where the player lifecycle can report them accurately.
- Creator profiles show public posts and real relationship counts returned by the backend. The UI does not fabricate engagement metrics or avatars.
- The native player remains the immersive destination for a game.

## Backend endpoints used

- `GET /v1/feed?scope=for_you|following|friends`
- `GET /v1/users/me/following`, `GET /v1/users/me/saved`
- `GET /v1/users/{id}`, `POST|DELETE /v1/users/{id}/follow`
- `POST /v1/games/{id}/publish`
- `POST|DELETE /v1/games/{id}/reactions`
- `GET|POST /v1/games/{id}/comments`
- `POST|DELETE /v1/games/{id}/save`
- `POST /v1/games/{id}/report`, `POST|DELETE /v1/users/{id}/block`
- `POST /v1/games/{id}/feedback`, `POST /v1/telemetry/social-event`

## Explicit limitations

- Authentication is still the development `X-User-ID` identity and is not trusted authentication.
- Follow relationships remain process-local by deliberate deferral. Social interactions use a lightweight server-side JSON snapshot when configured by the backend; this is not a substitute for a database or multi-instance shared storage.
- Moderation approval is an operator action guarded by `DQ_MODERATION_TOKEN`; no automated content classifier or moderation dashboard is claimed.
- For You uses a simple explainable freshness/engagement baseline, not machine-learned personalization. Recommendation quality should be evaluated against actual usage before adding complexity.
- Media delivery remains the existing backend package/asset endpoints. CDN/object storage should be adopted only when package size, bandwidth, and latency measurements justify it.
