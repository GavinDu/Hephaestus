# Arcade Pulse: native theme foundation

Status: **incremental implementation of [#173](https://github.com/GavinDu/Hephaestus/issues/173)** under [UI redesign epic #172](https://github.com/GavinDu/Hephaestus/issues/172). This document defines code tokens, not a claim that every feature has been redesigned.

## Source of truth

`Hephaestus/Views/Design/ArcadePulseTheme.swift` owns the semantic Arcade Pulse colors, five stable ID-selected **decorative fallback** gradients, minimum action sizes, Play CTA, creator identity, and action icon controls. `HephaestusDesign` also moved here for legacy system cards/forms. No new runtime or server behavior is introduced.

| Semantic role | Value | Usage |
| --- | --- | --- |
| Canvas | `#0B0916` (approx.) | Discover stage and supporting matte |
| Surface / raised | deep purple neutral | Distinct panels and controls |
| Electric violet | violet | navigation/secondary emphasis |
| Neon magenta | pink | highlights only; not all text |
| Play/Create | orange gradient | black-label primary play action |
| Foreground | white / 86%-white | high legibility over image stages |
| Minimum touch | 44 pt | all native action controls |
| Play action | 48 pt | primary tap-to-game affordance |

**Dark discover, system-neutral forms:** the current implementation explicitly opts Discover into a dark color scheme and leaves Library/Create/Profile system form styling intact. Shared source artwork, color metadata and unapproved previews are never recolored to simulate gameplay. When no approved media is available, show the existing truthful `Preview unavailable` fallback.

**Accessibility:** Play CTA increases its text size for accessibility Dynamic Type, keeps a minimum 48-point target and switches to a uniform solid-orange fill when Increase Contrast is enabled. Action icons retain 48-point width and at least 44-point height with complete VoiceOver labels. The foundation introduces no infinite pulses or timed animations, so Reduce Motion retains current preview playback protection. The system's light/dark preference continues to control the neutral form screens.

**Do not reintroduce** zero-distance drag recognition on Play; this stole the parent page swipe in landscape and was fixed in #171. Prewarming occurs in the actual play action. Do not decorate game HTML/WKWebView with fake native HUD/joystick controls.

## Component adoption

- **Discover For You:** native shared Play CTA, creator identity, action icons, and stable fallback palettes; dark media stage.
- **Discover grid cards:** same Play CTA, creator identity and palette; no competing drag recognizer.
- **Create completion:** same Play CTA.
- **Remaining scope:** comment/creator sheet headers, generalized state panels, broader navigation polish, iPad context rails and media-occupancy work remain in #173/#174/#175/#178/#182.

## State/evidence matrix

| Feature/state | Required evidence | Release rule |
| --- | --- | --- |
| iPhone portrait For You (normal and large text) | untouched native before/after real swipe PNG, action geometry and page ID | exactly one visible post; Play and social actions reachable |
| iPhone compact landscape | full-screen raw PNG + EXIF-aware manifest; drag trace and viewport ratio | one real-page advance, correct orientation, no obstructed CTA |
| iPad portrait and landscape | original UI evaluator PNGs, stage width, rotation/scroll tests | one game at a time; no neighboring bleed |
| Preview media missing/loading | live feed UI log + screenshot | truthful placeholder; play remains available |
| Approved media (future) | version+IR hash, rights/moderation, captured native poster/clip | never infer approval from gradient or interaction score |
| Increased Contrast / Reduce Motion | system accessibility QA with native screenshots | solid legible Play action; no forced looping animation |
| Error, empty, permission denied | accessible actual state screenshot | actionable retry/consent and no invented content |

[PR #184](https://github.com/GavinDu/Hephaestus/pull/184) makes raw screenshot orientation and placeholder state independently auditable. The *UI evaluator's 100/100 interaction score is not a creative or preview approval*. All PR merges require exact-head native iPhone/iPad, presentation and Xcode checks plus manual screenshot review.

Design files listed in epic #172 are **illustrative** concepts from the user’s design conversation, not runtime screenshots or image assets approved for publication.
