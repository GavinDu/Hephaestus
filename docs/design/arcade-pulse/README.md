# Arcade Pulse design reference images

Parent Epic: [Hephaestus #172](https://github.com/GavinDu/Hephaestus/issues/172)

These are **compressed preview copies** of approved design concepts generated in ChatGPT. They are visual direction only: the imaginary Aether Vale game/PixelRae creator, imagery, HUD, stats and counts are not shipping data. Actual app UI and gameplay evidence must come from native simulator/device screenshots, real approved game previews, API data and GitHub Actions checks. Do not treat concept images as passing screenshots or source artwork for gameplay. Full-resolution originals remain in the original design conversation archive.

| Task | Feature | Preview |
|---|---|---|
| #173 | Design tokens | [Overview](arcade_pulse_concept_contact_sheet.jpg) |
| #174 | iPhone feed | [iPhone feed](hephaestus_arcade_pulse_aether_vale.jpg) |
| #175 | iPad feed | [iPad feed](aether_vale_arcade_pulse_interface.jpg) |
| #176 | iPhone player | [Player](aether_vale_neon_skyspine_adventure.jpg) |
| #177 | iPad game details | [iPad detail](aether_vale_neon_skybound_adventure.jpg) |
| #178 | Comments | [Comments sheet](aether_vale_neon_comments.jpg) |
| #179 | Creator profile | [Creator profile](pixelrae_s_neon_creator_profile.jpg) |
| #180 | Create and remix | [Creation screen](hephaestus_create_build_remix_play.jpg) |
| #181 | iPad Creator Studio | [Studio](hephaestus_creator_studio_dashboard.jpg) |
| #182 | Navigation/search | [iPhone](hephaestus_arcade_pulse_aether_vale.jpg), [iPad](aether_vale_arcade_pulse_interface.jpg) |
| #183 | UI evaluator | [Concept overview](arcade_pulse_concept_contact_sheet.jpg), [iPhone CI evidence](current_iphone_ci_contact_sheet.jpg), [iPad CI evidence](current_ipad_ci_contact_sheet.jpg) |

## Screenshot verification rules
- Concepts are **desired composition only**; do not use them as expected pixel screenshots or assert an actual gameplay preview exists because a concept depicts one.
- Compare real iPhone and iPad simulator results captured as untouched, oriented full-screen files; preserve JSON metadata, test commit SHA, screenshot provenance, and before/after gestures.
- The two CI contact sheets are **historical screenshot summaries**, provided solely as comparison references and not a substitute for current exact-head evidence.
- The authoritative platform runtime remains bridgeless WKWebView with server-owned Game IR; do not add fake controls or metrics from concept art.

## Feed pagination failure safety and Retry accessibility (#174)

The load-more banner must never display raw `error.localizedDescription`: transport and backend errors may contain internal URLs, tokens or account metadata. `FeedErrorPresentation.paginationMessage(for:)` now reuses the same safe TLS/offline/timeout/default categories as initial feed loading. The authentic paginated server rows stay on screen while the error is shown, and the native Retry remains a real continuation of the cursor request with a >=44pt touch target. Pure Swift tests use a deliberately private error and prove it is not spoken or displayed. A successful retry must still come from the live backend, not a synthesized page.
