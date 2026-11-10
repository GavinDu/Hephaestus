# Senior UI/UX challenger review — Arcade Pulse compact landscape

Epic #172, tasks #174 and #183, issue #170, PR #189.

**Verdict before change: REJECT.** Real unmodified iPhone landscape capture shows the native navigation title, search drawer, scope picker and system tab bar leaving too little room for the game. PR #187's exact native assertion measured 0.4269 media/pager ratio against the specified 0.55 gate. A 100/100 swipe score is insufficient.

## Tested design hypothesis

- In compact iPhone landscape with a settled real game, keep the system tab bar but move social feed scope/search/preferences/creator discovery/refresh into a compact floating native 44pt control overlay above media.
- Native bar and search drawer should not consume vertical space while settled gameplay media is visible; tapping Search opens a proper native sheet and returns to the existing filtered results.
- Maintain exactly one settled post and its accessible Play CTA, real game title, social actions, pagination, current scope and VoiceOver scroll navigation.
- No fake poster or gameplay screenshot; when preview media is unavailable, preserve the truthful placeholder and separately report media provenance.

## Exit criteria — do not weaken

1. Real iPhone 17 Pro portrait and landscape, and iPad portrait and landscape Xcode screenshot capture before and after a real feed swipe. Native full-screen PNGs must be inspected without cropping/rotating away failures.
2. **Actual media surface occupies >=55% of the real pager** in all four orientations. A floating control does not get counted as media.
3. All 44pt scope/search/overflow controls hittable in compact landscape; a verified search query opens existing search results, and the tab bar remains accessible.
4. Existing player handoff, in-game gestures and saved location remain safe. No second settled page bleeds through.
5. Required Xcode and player-presentation CI are green on the exact head, and a human screenshot review documents the outcome.

If this approach fails, prefer a fullscreen landscape feed *only after adding explicit accessible navigation back to app sections*, rather than removing the gate or deleting the header in an inaccessible way.
