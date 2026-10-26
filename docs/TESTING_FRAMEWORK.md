# Testing Framework for the AI Coding Feedback Loop

Status: design. Implementation follows this document in phases; no phase
changes the simulator-gating rule without updating this document first.

## 1. Goal

Minimize physical-device and Xcode-simulator usage, and make every test
run — automated or manual — produce data the next AI coding iteration
can consume without re-running the same test to rediscover the same
failure.

Concretely: the default development loop runs with **no simulator at
all**. A simulator run is a scarce, gated resource. A physical-device
run is rarer still, reserved for what no automated layer can prove.
Every run, at every layer, emits a structured feedback artifact (see
§5). A run that produces no artifact is treated as if it never ran.

## 2. Non-goals

- This framework does not replace human judgment on touch feel,
  visual quality, or game feel. It makes those judgments cheaper by
  proving everything else first.
- It does not aim for 100% UI-test coverage. UI tests are the most
  expensive layer per assertion; they cover the paths where the app
  shell and the runtime meet, not every screen state.
- It does not introduce a new test runner for its own sake. It wires
  together runners that already exist and adds exactly one new
  artifact format (§5) plus one export (§6).

## 3. Principles

- **Verified, never asserted.** A claim about the app is backed by a
  test run, a browser draw, or a device log — not by "it should work".
- **Skip with reason, never silent pass.** A test that cannot run in
  its environment (no database, no simulator, no device) reports
  `skip` with a reason. An unmeasurable result is never reported as a
  pass. This is the same rule the backend CI already follows.
- **Deterministic replay.** Game behavior is replayable: seeded RNG,
  fixed-timestep simulation, and tick-stamped inputs, keyed by the
  game IR hash (`irHash`). A failure must be reproducible from its
  artifact alone, without the original device.
- **One artifact, one run.** Every test run — CI or manual, simulator
  or physical — produces one `test-feedback.json` (§5). The artifact
  is the unit of feedback, not a chat transcript or a screenshot dump.
- **Failures carry a class.** Every failure is classified (§5.3) so
  the next iteration knows whether it is fixing a contract, a render,
  a performance regression, a crash, or a flake — and does not chase
  the wrong layer.

## 4. Layers

Cost increases down the table. A change must pass each layer before
the next layer is spent on it.

### Layer 0 — No device, no simulator (default gate, every change)

| Suite | What it proves | Where it runs |
|---|---|---|
| Backend Go tests (`go test ./...`, `-race`) | API, feed, social graph, moderation, ranking contracts | Backend CI |
| `ios/GamePlayerCore` Swift package tests | Player contract and lifecycle (in the backend repo, contract testing only — see §8) | Backend CI (`ios-player-core.yml`) |
| Hephaestus unit tests (`HephaestusTests`) | App logic: API decoding, view models, feed-card parsing, state machines | Hephaestus CI (`xcode` job, no simulator UI run) |
| Browser playtests (Chromium + WebKit) | Games actually render and play in real browser engines; WebKit is the proxy for the iOS WKWebView engine | Backend CI |
| Playability kit | Per-game PLAYABLE / NEEDS_REVIEW verdicts with measured scorecards | Backend CI |

Layer 0 is the merge gate. If Layer 0 fails, no simulator time is
spent — the failure is already fully described by Layer 0 artifacts.

### Layer 1 — Simulator, gated (not per-PR by default)

- **What:** `HephaestusUITests`, starting with
  `PlayerSmokeTests.testDiscoverLaunchesPlayer`: Discover feed launches
  the player, the game loads, and the player reports health.
- **When:** manual dispatch, nightly schedule, and release gates —
  not every pull request. A PR that only changes Layer 0-provable
  behavior does not need a simulator run to merge.
- **Why gated:** simulator runs are slow, flaky in ways unrelated to
  the change (host load, simulator boot), and expensive in CI minutes.
  Gating them concentrates simulator time on changes that touch the
  app shell, the player web view, navigation, or device-specific
  behavior.
- **Escape hatch:** any PR may request a simulator run by dispatching
  the workflow manually, with the reason recorded in the run. The run
  still emits a §5 artifact; an undocumented simulator run is a
  process violation, not a shortcut.

### Layer 2 — Physical device, rarest

Reserved for what no automated layer can prove:

- Touch feel and gesture responsiveness.
- Orientation and safe-area behavior on representative iPhone and
  iPad hardware (including Split View / resizable windows on iPad,
  which the size-class layout already adapts to).
- Memory pressure, thermal behavior, and sustained frame pacing.
- Performance on low-end hardware and in Low Power Mode.

A physical run is a checklist run (§7), not an exploratory session:
the tester follows the checklist, captures the artifact, and files
it. "I played it on my phone and it felt fine" without an artifact
does not close a physical-verification item.

## 5. The feedback artifact: `test-feedback.json` v1

One file per run. It is written by the test harness (CI or manual),
stored as a CI artifact, and indexed so a later coding iteration can
retrieve it by run id, commit, or game IR hash. The schema is
versioned; a consumer must reject an unknown major version rather
than guess.

```json
{
  "schema_version": 1,
  "run_id": "2026-10-25T21:00:00Z-hephaestus-abc123",
  "created_at": "2026-10-25T21:00:00Z",
  "commit": "b0a3ecd0c3cbff25ca8d1361017d2d1935208887",
  "repo": "GavinDu/Hephaestus",
  "layer": 1,
  "environment": {
    "kind": "simulator",
    "device": "iPhone 16",
    "os": "iOS 18.1",
    "app_version": "1.0",
    "build": "42",
    "backend": "https://html-5-game-generator.replit.app"
  },
  "game": {
    "id": "sample-rainbow-bear",
    "ir_hash": "sha256:…",
    "runtime_version": "2026.10.23.2"
  },
  "cases": [
    {
      "id": "player-smoke.discover-launches-player",
      "verdict": "fail",
      "failure_class": "render",
      "duration_ms": 12400,
      "replay": { "seed": 42, "inputs": [] },
      "logs": ["devlog.json", "telemetry.json"],
      "screenshots": ["launch-failed.png"],
      "detail": "Player web view stayed on the loading state past the 8s slow-load hint."
    }
  ],
  "summary": { "pass": 0, "fail": 1, "skip": 0 }
}
```

### 5.1 Fields

- `run_id`: unique per run; the correlation key for logs and
  telemetry. Simulator and physical runs must include it in DevLog
  and in every telemetry payload they send (see §6), so a failure
  can be joined to its server-side incidents without guessing.
- `layer`: 0, 1, or 2 (§4).
- `environment.kind`: `ci`, `simulator`, or `physical`.
- `game.ir_hash`: required when the case exercises a game; omitted
  for app-shell-only cases. This is what makes a failure replayable.
- `cases[].verdict`: `pass`, `fail`, or `skip`. `skip` requires a
  `detail` explaining why the case could not run.
- `cases[].replay`: seeded inputs sufficient to reproduce the case.
  For game cases this is the seed plus tick-stamped inputs; for
  app-shell cases it is the navigation steps taken.

### 5.2 Verdict rules

- A case that times out is `fail` with class `timeout`, not `skip`.
- A case that cannot start (simulator failed to boot, backend
  unreachable) is `skip` with the reason, and the run is marked
  inconclusive — it does not count as evidence for or against the
  change.
- A flaky case (passes on retry with no change) is reported as
  `fail` with class `flake` on its first failure, plus the retry
  outcome. Flakes are tracked as a metric (§9), not hidden by
  retries.

### 5.3 Failure classes

`compile`, `contract`, `render`, `perf`, `crash`, `timeout`,
`auth`, `network`, `flake`, `unknown`. A failure with class
`unknown` must carry enough logs for a human or a later iteration
to reclassify it; repeated `unknown` failures are themselves a
framework bug.

## 6. Logging: DevLog JSON export and telemetry correlation

Today `DevLog` exports plain text (`exportText()`), which is good
for a human reading a dump in chat and useless for a machine joining
a failure to its cause. Phase 1 adds, alongside the text export:

- `exportJSON()`: the same entries as structured objects —
  timestamp, level, category, message, and a `run_id` field set
  from the active test run when one exists.
- `PlayerTelemetry` includes `run_id` in every payload it sends
  (`/v1/telemetry/runtime-error`, perf, load-failed, terminated,
  memory-warning, thermal), so backend incidents
  (`GET /v1/telemetry/incidents`) can be filtered to one run.
- The Diagnostics UI (Profile → Diagnostics) gains an "Export test
  feedback" action that writes the §5 artifact for the current
  session: DevLog JSON + the run's telemetry + the session's
  screenshots, zipped with the artifact as the manifest.

The text export stays. Humans keep their dump; machines get the
JSON. Neither replaces the other.

## 7. Physical and simulator run checklists

A Layer 1 or Layer 2 run is not complete until its checklist is
filled in and its artifact is filed:

1. Record `run_id`, commit, device/simulator profile, app build.
2. Run the case list for the change (player smoke at minimum for
   player changes; the full UI suite for shell/navigation changes).
3. On failure: capture the screenshot/video, the DevLog JSON
   export, and the backend incidents for the run id. Do not
   re-run to "see if it happens again" before filing — the first
   failure's artifact is the evidence.
4. File the artifact (CI artifact store for simulator runs; the
   shared archive for physical runs — see §10, open decision 1).
5. Write the verdict into the PR or issue: pass/fail/skip per case,
   with the artifact linked. A verdict without an artifact link is
   not a verdict.

## 8. Scope boundary: Hephaestus vs `GamePlayerCore`

Hephaestus is the dedicated product iOS app for iPhone and iPad
(universal target; size-class layout with compact tabs and an
expanded iPad sidebar). The iOS code in `html5-game-generator`
(`ios/GamePlayerCore`) is contract testing only: a Swift package
running player contract and lifecycle tests in backend CI. Product
iOS features must not grow there, and contract tests must not
depend on Hephaestus app code. The boundary is enforced by
repository: if a change needs app UI, it belongs in Hephaestus;
if it needs a player contract, it belongs in `GamePlayerCore`
(and is then consumed by Hephaestus).

## 9. Metrics (reviewed monthly, not per-run)

- Simulator minutes per merged PR (target: trending down as
  Layer 0 coverage grows).
- Physical runs per release (target: one checklist pass per
  release, not per PR).
- Flake rate per case (target: a case flaking twice in a month
  gets quarantined with a reason, not retried silently).
- Time from failure artifact to fix PR (the feedback-loop latency
  this framework exists to shorten).
- `unknown`-class failure rate (target: zero over a rolling month;
  anything else means the artifact is missing data).

## 10. Rollout phases

1. **Design (this document).** Agree the artifact schema and the
   gating rule before building.
2. **Phase 1 — Artifact + logging.** `test-feedback.json` schema
   (as a checked-in JSON Schema file), `DevLog.exportJSON()`,
   `run_id` in `PlayerTelemetry`, Diagnostics export action.
   No CI gating changes yet.
3. **Phase 2 — Artifact producers.** CI jobs (backend playtests,
   playability kit, Hephaestus unit tests) emit §5 artifacts as
   job artifacts. The brief generator (§11) is a script that
   renders a failed artifact into a next-iteration brief.
4. **Phase 3 — Simulator gating.** Move the player-smoke / UI-test
   job to manual dispatch + nightly + release. Per-PR CI runs
   Layer 0 only. Track simulator minutes per PR (§9) from this
   point.
5. **Phase 4 — Physical checklist.** The §7 checklist as a
   checked-in template, with an artifact archive location (see
   open decision 1). One checklist pass per release.

## 11. The AI feedback loop, step by step

1. A change is made (by a human or by an AI iteration).
2. Layer 0 runs. On failure, its artifact is the input to the
   next iteration — no simulator is spent.
3. If Layer 0 passes and the change touches the shell, player,
   or navigation, a Layer 1 run is dispatched. Its artifact
   joins the same feedback store.
4. The next iteration starts by reading the latest artifact for
   the change: verdicts, failure classes, replay inputs, logs.
   It does not re-run a simulator to rediscover a known failure.
5. The iteration brief generator renders, from an artifact: what
   failed, in which case, with which failure class, the replay
   inputs, and the five most relevant log lines (by category:
   crash and error lines first, then the lines immediately
   before the failure). The brief is an input document, not a
   diagnosis — the iteration still has to verify its fix with
   a new run.
6. A fix is verified by a new run at the same layer that caught
   the failure, producing a new artifact. The loop closes only
   when the new artifact shows `pass` for the previously
   failing case.

## 12. Open decisions

1. **Artifact archive location.** CI job artifacts expire; a
   physical run has no CI job at all. Candidates: a shared Drive
   folder, a dedicated repository, or extended-retention CI
   artifacts. Decision needed before Phase 4; Phase 1–3 can use
   CI artifacts alone.
2. **Simulator dispatch authority.** Manual dispatch by anyone, or
   restricted to release managers? Default proposed: anyone may
   dispatch, with the reason recorded — the cost control is the
   gating rule (§4), not permission.
3. **Retention.** How long are artifacts kept? Default proposed:
   90 days for simulator/physical artifacts, 30 days for Layer 0
   artifacts (which are cheap to regenerate).
4. **Quarantine policy for flaky UI cases.** Default proposed in
   §9 (quarantine after two flakes in a month, with a reason).
   Needs agreement that a quarantined case still runs and
   reports, but does not block.
