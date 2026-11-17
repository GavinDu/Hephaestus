# Native single-card iPad portrait drag ownership — #462 / Epic #202

Source evidence: [required iPad UI evaluator run 43985504578, job 133712490515](https://github.com/GavinDu/Hephaestus/actions/runs/43985504578/job/133712490515) on unrelated draft origin PR #448 failed `testDiscoverFeedUIEvaluationAndSwipe` at line 1599: actual three-game iPad portrait pager reported `Drag 0 dy 0 offset 0; Game 1 of 3` before and after `pager.swipeUp()` and twenty seconds of real settle polling. The one hittable game stayed `sample-ribbon-sky`; viewport media occupancy was 0.7465. Original unmodified [iPad XCResult/screenshots #14287846666](https://github.com/GavinDu/Hephaestus/actions/runs/43985504578/artifacts/14287846666) retained.

## Source change

Production `ForYouPagerView` renders **one** genuine backend game card inside `ScrollView(.vertical).scrollDisabled(true)`. Physical `highPriorityGesture(DragGesture)` was attached to the disabled `ScrollView` and the failed case counted zero drag callbacks. Move the very same one-shot `ForYouPageLayout.pageOffsetForSwipe` reducer and diagnostic counters to a hit-testable `contentShape(Rectangle())` on the actual selected game card, **not** the `GeometryReader` and not both card and scroll view. Preserve the disabled-scroll one-card renderer, one transition per input, VoiceOver `accessibilityScrollAction` on the scroll view and all authentic server-game identity, media/CTA/overflow checks.

The existing unmodified `PlayerSmokeTests.testDiscoverFeedUIEvaluationAndSwipe` still drives real `pager.swipeUp()` and must prove an actually different published game with two consecutive stable viewport/hit-test samples and original full-screen screenshots. Pure unit checks ensure deliberate vertical drags reduce to exactly +/-1, while diagonal drags do not page. These source tests alone do **not** prove real iPad gesture dispatch; if CI still reports `Drag 0`, next design is a real explicit accessible paging action, not a fake state injection or skipped assertion.

## Skeptical game-engine/UI architect challenge

- Physical drag must not steal 44pt Play, Share, Like, creator or the future attached WebKit gameplay controls. Minimum distance remains 35pt and tap gestures remain separate. Check portrait/landscape, VoiceOver, large text and rotation.
- A disabled scroll view may still interfere with descendant gesture hit testing; this is a hypothesis backed by failure telemetry, **not** proven root cause. Any remaining failures must be diagnosed with real simulator artifacts and no silent fallback.
- No effect on game runtime/IR execution, trusted WebKit origin, replay attestation or GPU presentation. The unrelated origin PR #448 and this PR each need seven exact-head native CI successes and can close their atomic issues separately. Physical devices #276/#279 and App Review remain outstanding.

Rollback: restore prior `highPriorityGesture` at the scroll viewport and remove card-local gesture; retain failure artifacts and issue findings.
