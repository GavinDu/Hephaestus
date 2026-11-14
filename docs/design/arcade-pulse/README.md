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

## Native accessibility action contracts (#173 / #179)

- The Arcade Pulse Play CTA uses semantic SwiftUI `.headline` typography that grows with Dynamic Type, instead of a fixed 20pt font at accessibility sizes. Its visual hit target remains at least 48pt and it never attaches a gesture that steals feed paging.
- A playable `FeedGame` with no nonblank backend `ownerID` must **not** present an actionable creator/profile or Follow control. A generic `Mini game` label must not impersonate a navigable creator profile. Games remain playable independently of creator attribution.
- Real creator identity and profile navigation remain backed by the server; no test-only creator or fabricated follower count is inserted. Validate these semantics alongside real iPhone/iPad screenshots, VoiceOver labels/order, and oversized Dynamic Type at the exact PR head.

## Signed-out iPad Studio / Library contrast contract (#173 / #181)

The real Go to Profile to sign in CTA uses the shared `ArcadePulseTheme.electricViolet` solid fill and `onElectricViolet` **black** foreground. For the token's original sRGB components (0.57, 0.36, 0.99), calculated WCAG relative-luminance contrast is approximately **5.15:1 with black**, while white is approximately **4.08:1** and fails normal-text AA 4.5:1. The native iPad Studio and signed-out Library now share the same readable foreground token; pure Swift tests recompute the ratio from the source RGB token. Do not lighten the button text to follow a concept screenshot; real device high-contrast, VoiceOver and Dynamic Type screenshot acceptance remains required.
