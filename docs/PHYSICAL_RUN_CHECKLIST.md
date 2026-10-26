# Physical run checklist

One checklist pass per release, not per PR. See `docs/TESTING_FRAMEWORK.md`
for the layer model: physical runs are Layer 2, the rarest layer, used
only for what a simulator cannot tell you.

## Before the run

- [ ] Record the run in the same shape as every other run: fill in
      `run_id`, `commit`, `repo`, and `layer: 2` in the run's
      `test-feedback.json` (schema: `tools/test-feedback/schema.json`).
      If the run cannot start, it is inconclusive, not a pass.
- [ ] Pick the device matrix for this release and write it down:
      one representative iPhone, one representative iPad (including a
      low-end device when the release touches rendering or memory).
- [ ] Decide what media this run needs. Physical screenshots work
      through XCUITest attachments on device and simulator alike.
      Physical video has no `simctl` equivalent, so pick one route
      before starting (docs/TESTING_FRAMEWORK.md §5.4):
      1. Control Center screen recording, started before the run,
         then imported into the artifact;
      2. the mirrored device captured on a Mac;
      3. in-app ReplayKit recording — future option only, it needs a
         permission prompt and a privacy decision first.
- [ ] Note the artifact archive location for this run. This is still
      an open decision in the framework doc (shared Drive folder,
      dedicated repository, or extended-retention CI artifacts) —
      write down where this run's artifact actually went, so the gap
      stays visible instead of silently assumed.

## During the run

For each device, check the item and record pass / fail / skip with a
reason. A skip needs a reason; a timeout is a failure, not a skip.

- [ ] Touch feel and gestures: taps, drags, and the player controls
      respond as on the simulator, with no missed or double inputs.
- [ ] Orientation and safe areas: portrait and landscape, plus the
      notch / Dynamic Island / home-indicator regions, on both
      iPhone and iPad. Include Split View and resizable windows on
      iPad where the app supports them.
- [ ] Memory pressure: a sustained play session shows no jetsam,
      no runaway growth in the DevLog, and recovers after backgrounding.
- [ ] Thermals and sustained frame pacing: frame time stays in the
      range the simulator run reported; note any throttling and the
      device temperature state if the run degrades over time.
- [ ] Low-end hardware and Low Power Mode: the player still boots
      and stays playable; record where quality steps down, if it does.
- [ ] Player lifecycle on device: background, foreground, lock, and
      unlock recover the player without a stale or frozen web view.

## After the run

- [ ] Attach one screenshot per failed case (the failure state) and
      one success screenshot at the key state as a baseline, as for
      simulator runs.
- [ ] File the run's `test-feedback.json` with its screenshots and
      video in the archive location noted above, and link it from
      the release notes.
- [ ] Feed failures into the next iteration with
      `tools/test-feedback/brief.py <test-feedback.json>` — the brief
      is an input document, not a diagnosis; the fix still has to be
      verified with a new run at the same layer.
- [ ] Report flakes and track them; do not hide them with retries.
      A case that flakes twice in a month is a quarantine candidate
      under the framework doc's proposed default — still run and
      reported, not blocking, until the flake is understood.
