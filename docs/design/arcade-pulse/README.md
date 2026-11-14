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

## Comments native Send icon contrast (#178)

The original iPhone simulator screenshot from GitHub iOS run `43538047311` (artifact `player-smoke` `14092009874`; test `testArcadePulseCommentsSheetAndSafeAreaComposer`) shows an authentic zero-comment backend state, keyboard-safe composer with typed unsent text, and a **white paper-plane icon** on `playOrangeDeep` sRGB (1.0,0.48,0.30). White-on-orange is approximately **2.57:1**, below WCAG AA **3:1 for meaningful non-text controls**. The icon now uses black-on-orange (~**8.16:1**), retaining its real enabled/disabled semantics, >=44pt tap size and explicit VoiceOver label. This screenshot does **not** prove comment POST success or server-error recovery; both require actual backend validation on the updated PR head.
