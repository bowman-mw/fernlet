# Fernlet — workout Live Activity + remaining phases, continuation prompt (2026-07-18)

Paste the block below into a fresh session to continue.

---

Continue the Fernlet build-out: ship the workout Live Activity (Feature B2/B3) and clear the
remaining planned tail. Read these memories first: `batch1-branch-review-2026-07-17` (has the full
fix history + residuals), `goal-presets-workout-liveactivity-plan-2026-07-17`,
`ux-batch-2026-07-17-session3`, `fernlet-domainmodel-clean-build-hazard`,
`run-fernlet-tests-in-batches`. The full Feature B design is
`Docs/Plan-Goal-Presets-And-Workout-LiveActivity-2026-07-17.md` — read it before writing code.

## Branch + state
- Working branch: `claude/batch1-ux-fixes`, tip `8c0439d`. NOT pushed; check `git status`/origin
  state before assuming anything. Branches STACK on main.
- Everything is green on this exact tip: clean build, full `FernletTests`, 14/14 touched UI tests,
  `Scripts/spm-wall-check.sh` PASSED. Two full review rounds are done (47 findings fixed, then a
  47-agent re-review whose 27 findings were also all fixed). Do not re-litigate; the residuals
  listed below are the complete known-open set.
- The in-app guided runner ALREADY EXISTS and is the state machine the Live Activity feeds from:
  `Fernlet/GuidedWorkout.swift` (`WorkoutSessionRunner`: ready/working/resting/done, injectable
  clock, `restStartedAt`/`restEndsAt`, one-shot `consumeCompletion()`), started from the Suggest
  sheet in `Fernlet/MoveView.swift` (a11y `workout.startGuided`; guided sheet close is
  `workout.guided.close`). `NSSupportsLiveActivities` is already true in Info.plist. There is zero
  ActivityKit code in the tree today.

## Work items, in order

### 1. Hoist the Start button to the Move tab root (small, do first)
Tester-verified discoverability gap: even the project owner had to ask how to start a workout. Add
a "Start today's workout" card on the Move tab ROOT that generates the day plan (reuse the exact
seam `WorkoutSuggestionSheet` uses) and opens the guided runner directly, absent/disabled with a
gentle reason on rest or cardio-only days (`guidableSession` already encodes the filter). Keep the
in-sheet button too. The card must respect `guidedCompletedSessionIDs` semantics (multi-session
days) added in commit `1c6c797`.

### 2. B2 — the Live Activity render (Dynamic Island + Lock Screen)
- **#1 pitfall first:** `WorkoutActivityAttributes: ActivityAttributes` MUST be member of BOTH the
  app target AND `FernletWidgets`. The app target uses Xcode 16 synced folder groups
  (`Fernlet/` auto-includes), but `FernletWidgets/` is its own target folder — a shared file
  likely needs explicit dual membership. Verify how `FernletWidgets/WidgetSharedModels.swift` is
  membered and mirror it; prove inclusion by referencing the type from both targets and building.
- `ContentState`: exerciseName, setNumber, totalSets, reps, phase, `restStartedAt`/`restEndsAt`,
  exerciseIndex, totalExercises. **Carry the W1 crash lesson: NEVER render
  `Date()...restEndsAt` — always the fixed `restStartedAt...restEndsAt` window, which
  `Text(timerInterval:)` clamps to 0:00 after expiry.** An inverted ClosedRange fatalErrors.
- `WorkoutLiveActivity: Widget` with `ActivityConfiguration(for:)` added to
  `FernletWidgetsBundle`: Lock Screen view (exercise, "Set X of Y", reps, rest countdown via
  `Text(timerInterval:)` — no push updates ever); Dynamic Island compact = countdown + set dot,
  expanded = exercise + set/reps + timer, minimal = timer glyph.
- App-side `WorkoutLiveActivityController`: `Activity.request` on start (guard
  `ActivityAuthorizationInfo().areActivitiesEnabled` — degrade to in-app-only silently),
  `activity.update` on each set/exercise transition, `activity.end` on finish AND abandon.
  Reconcile stale `Activity<WorkoutActivityAttributes>.activities` on launch (killed-app case).
  Hook the controller into the runner's transitions from where the runner is driven
  (GuidedWorkoutSheet actions), not by polling.
- Tone: gentle, no streak/pressure language, matching the runner's copy.
- **Verify on a REAL DEVICE.** Simulator widget/Metal rendering has produced false alarms in this
  project before (#21 was a sim artifact). Sim can prove compile + request/update plumbing only.

### 3. B3 — interactive lock-screen buttons (fast-follow, only after B2 is device-verified)
"Done set" / "Skip rest" via `LiveActivityIntent`, mirroring `FernletWidgets/WaterPlusOneIntent`.
**Architectural flag:** the runner currently lives as view `@State` in MoveView — an intent's
`perform()` cannot reach it there. Either move runner ownership to a store-reachable seam (e.g.
FernletStore or a shared app-scoped controller) or route through the durable pending-action queue
the water button uses (`PendingWidgetActionQueue`), then update the Activity from the handler. Do
NOT regress the one-shot completion latch or multi-session logging semantics from `1c6c797`.

### 4. Undiagnosed tail from the 21-item batch (investigate, don't guess-fix)
- **#2 widget shows wrong state** — 3 co-equal hypotheses, never diagnosed. Reproduce first.
- **#10 bottom-bar jitter** — best surviving hypothesis: over-counted overflow calc in
  `FernletUIComponents.swift` ~470 (204pt computed vs 26pt real travel). Diagnose, then fix.
- **#3 water widget** — likely already fine ("+1 cup" is not representable; water is an Int
  bottle count). Verify with the tester before touching anything.
- **#21 widget watchdog crash** — re-check on a real device only; closed as sim artifact.

### 5. Small open items (deliberately deferred, all recorded — pick up opportunistically)
- Plaintext export JSON lingers in tmp until delete-all: purge after the share sheet completes.
- "Recent bites" windows to today only (empties at midnight) and polaroids have no tap-through.
- Second-device polaroids render as broken-looking placeholders for photos that live on the other
  device — needs "on your other device" treatment, not a fork-and-knife frame.
- Web-import source Link opens external Safari; app convention elsewhere is in-app SafariView.
- Generic unknown-key parking for `FernletSettings` (TODO in SettingsModel `init(from:)`) — the
  privacy-critical visibility case is closed; this is the systemic follow-up.
- PRODUCT DECISION, ask first: body photos are zero-friction when no Fernlet lock is configured
  (Private Hub forces lock setup; the strip doesn't). Ask before changing.
- Manual-verify on device: body-photo detail pop must NOT re-prompt Face ID (the UI suite runs
  with BYPASS_PRIVATE_LOCK so it can't pin this).

## How to work
- Ultracode is on: Workflow fan-outs with adversarial verification earned their keep twice over —
  the re-review caught a deterministic crash in the runner's rest screen that per-group tests
  could not see. Review after building B2, before device hand-off.
- ONE simulator at a time; heavy concurrent builds + sims + workflows saturate this host and
  SIGKILL background sim apps. UI-test failures on parallel clones: retry serially on an erased
  sim (`xcrun simctl shutdown all && xcrun simctl erase <dev>`) before believing them.
- Build: `xcodebuild build-for-testing -scheme Fernlet -destination 'platform=iOS
  Simulator,name=iPhone 17'`, prefix `caffeinate -dimsu`. Check exit codes via zsh
  `${pipestatus[1]}`, never a grep. CLEAN build for any `FernletDomainModel` stored-field/enum
  change (`ContentState` in the widget-shared file is NOT domain model).
- `Scripts/spm-wall-check.sh` before any push; the new Live Activity files must not touch
  `Private*` stores (plain Codable values only — the plan's §B2 note).
- Known flake: `ProximityRecipeShareCapTests.connectTimeoutSurfacesBusyPeerFailure` (passes alone).
- Failure detail: `xcrun xcresulttool get test-results test-details --test-id "Suite/test()"
  --path <xcresult>`.

Ask before starting only if a genuine product decision is open (B3 runner-ownership seam, the
no-lock body-photo gate); otherwise proceed.
