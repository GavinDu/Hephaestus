# GameSpec v1 — the 31 standardized game factors

Every game is reduced to a GameSpec before generation. The iOS Create flow
can render its questionnaire UI directly from `GET /v1/spec/questionnaire`;
`POST /v1/spec/decide` routes the finished spec to an engine.

**Engines:** `html5` (simple games — easier to generate, instant load, better
perf) or `godot` (rich 2D effects / 3D — more work, more juice). Hard rules:
3D → godot; must-load-instantly → html5. Otherwise weighted scoring; ties go
to html5. The response includes a plain-language `rationale`.

**Preferences** are standing per-user defaults (difficulty, sound, art policy,
session length, perf budget, audience). The questionnaire only needs to ask
about them once; afterwards they're remembered.

| Factor | Group | Type | Default | Options / notes |
|---|---|---|---|---|
| title | identity | string |  | *required* |
| logline | identity | string |  | one-sentence pitch |
| audience | identity | enum | family | kids-3-5 / kids-4-7 / kids-8-12 / family / teens / adults · preference |
| sessionTargetSec | identity | int | 90 | seconds per sitting · preference |
| sourceKind | source | enum | kids-drawing | kids-drawing / text-prompt / remix |
| artPolicy | source | enum | preserve | preserve / polish / reimagine · preference — kid art is never replaced |
| archetype | gameplay | enum |  | *required* — catcher / dodger / tapper / runner / platformer / puzzle / shooter / racer / story / sandbox |
| coreLoop | gameplay | string |  | *required* — "verb the object" |
| win.type | gameplay | enum | endless | score-target / survival-time / completion / endless |
| lose | gameplay | enum | lives | lives / timer / caught / none |
| input | gameplay | enum-list |  | *required* — tap / drag / swipe / tilt / keys / multitouch |
| style | visual | enum | kid-drawing | kid-drawing / cartoon / pixel / vector-flat / realistic-3d |
| spriteCount | visual | int | 12 | simultaneous sprites on screen |
| particles | visual | enum | none | none / simple / rich |
| lighting | visual | bool | false | dynamic lighting / shadows |
| parallaxLayers | visual | int | 1 | background layers |
| screenShake | visual | bool | false |  |
| postFx | visual | bool | false | glow / blur / vignette |
| threeD | visual | bool | false | → forces godot |
| animation | visual | enum | tween | none / tween / skeletal / frame |
| musicMood | audio | enum | cheerful | cheerful / calm / tense / epic |
| sfx | audio | string-list |  | e.g. catch, miss, levelup |
| progression | systems | enum | endless-meta | none / levels / endless-meta |
| difficultyRamp | systems | float | 1.25 | speed multiplier per level |
| powerups | systems | string-list |  |  |
| combo | systems | bool | false | multiplier scoring |
| leaderboard | systems | bool | true |  |
| difficulty | systems | enum | easy | easy / normal / hard · preference |
| targets | platform | enum-list | web | web / ios / android / desktop |
| orientation | platform | enum | portrait | portrait / landscape |
| perfBudget | platform | enum | low-end | instant / low-end / mid / high · preference — instant forces html5 |

**Godot note:** when the decision is `godot`, the backend translates the
GameSpec into a RuntimeSpec (game-as-data JSON: entities, behaviors, systems)
consumed by a fixed GDScript loader. The app never needs to know this — it
just plays the resulting `/godot/{game}/` URL.
