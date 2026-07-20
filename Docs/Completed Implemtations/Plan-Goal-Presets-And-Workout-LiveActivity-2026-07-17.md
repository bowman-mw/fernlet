> **CLOSED 2026-07-19 — SHIPPED.** Feature A (goal preset cards) and Feature B1-B4 (guided-workout Live Activity, interactive Done-set/Skip-rest) are on `main`; the header's "planned only, nothing implemented" no longer applies. Only the real-device Live Activity verification remains (tracker). Live tracker: [RemainingWork-2026-07-19.md](../RemainingWork-2026-07-19.md).

# Plan — Goal presets + Workout Live Activity (2026-07-17)

Two tester-requested features, **planned only, nothing implemented**. Both build on code that already
exists. Written for a fresh session to execute. Related state: the UX batch tracker memory
`ux-batch-2026-07-16-state`; clean-build hazard `fernlet-domainmodel-clean-build-hazard`.

---

## Feature A — Goal & nutrition preset options (that match the workout options)

> "For the goal and nutrition, can there be default options to make the selection easier? It would be
> great if the options match the workout options."

### What exists today (facts, verified 2026-07-17)
- **`GoalType`** — `FernletKit/Sources/FernletDomainModel/WellbeingModels.swift:534`. Cases: `wellness,
  strength, weightManagement, mentalHealth, recovery, exploring, sportsPrep`. Has `displayName`,
  `tagline`, `isTrainingFocused`. It is the **one shared goal** that already drives BOTH:
  - **Nutrition** — `NutritionTargetCalculator.targets(for:)`
    (`FernletKit/Sources/FernletDomainModel/NutritionModels.swift:1566`): per-goal calorie multiplier
    (`adjustedCalories`) + protein g/kg (`proteinTarget`).
  - **Workout** — split recommendation (`WorkoutSplitRecommender`, `WorkoutProgram.swift:791`) and the
    per-goal split blurb `GoalType.defaultWorkoutSplitSummary` (currently a **private** extension in
    `Fernlet/MoveView.swift:752`).
- **Goal & nutrition Settings** — `Fernlet/SettingsSheet.swift:1023` (`generalTab`), reached via the
  "Goal & nutrition" `NavigationLink` (`SettingsSheet.swift:66`). Today the goal picker is a bare
  `Picker("Goal", selection: $store.settings.selectedGoal)` (`SettingsSheet.swift:1027`) + tagline,
  then `ProfileEditor` (Body & preferences) and the new `NutritionTargetsEditor`.
- **Workout "options"** = `WorkoutProfile` (`WorkoutProgram.swift:42`): `experience: ExperienceLevel`
  (beginner/intermediate/advanced), `trainingDaysPerWeek`, `selectedSplitID` (nil = auto), avoided
  muscles/movements, sport, interests. Set in the Move tab. Separately, `store.goals: [FitnessGoal]`
  are user-authored structured fitness goals (`.goals` sheet) — a different concept, leave alone.

### Interpretation
The goal→nutrition and goal→workout mappings already exist; the gap is **presentation**. The picker is a
terse dropdown that doesn't show what each goal configures, and nothing visibly ties the goal to the
workout setup. "Options match the workout options" ⇒ surface, per goal, the paired nutrition **and**
training setup so one choice reads as configuring both.

### Recommended design — goal preset cards
Replace the bare `Picker` with selectable **preset cards**, one per `GoalType`, each showing:
- Goal name + `tagline` (existing).
- **Nutrition:** one line (e.g. Strength → "Higher calories · ~1.7 g/kg protein"; Weight management →
  "Gentle deficit · higher protein"). Descriptive — do NOT recompute the math, just summarize it.
- **Training:** one line — the matching split (reuse `defaultWorkoutSplitSummary`).
- Selected state (moss border/checkmark), matching the app's card idiom (see the #7 cards / FernletCard).

This is the "match": picking one goal shows its paired nutrition + training plan side by side.

### Implementation steps
1. **`GoalType` (FernletDomainModel — CLEAN build; grep every `GoalType` switch for exhaustiveness):**
   - Add `var nutritionSummary: String` (per-goal one-liner mirroring `adjustedCalories`/`proteinTarget`).
   - Promote `defaultWorkoutSplitSummary` from the private `MoveView` extension to a **public**
     `GoalType.trainingSummary` so Settings and Move share one source. (Already exhaustive; just move +
     make public, and update `MoveView.swift:602/752` to use it.)
2. **New `Fernlet/GoalPresetCards.swift`** — a card list/grid over `GoalType.allCases`, binding to
   `$store.settings.selectedGoal`, each card = name + tagline + nutritionSummary + trainingSummary.
3. **`Fernlet/SettingsSheet.swift` `generalTab`** — replace the `Picker` block with `GoalPresetCards(...)`.
4. **(Optional, gated on decision #1)** `WorkoutProfile.recommended(for goal: GoalType, experience:)`
   + a non-destructive "Set up matching training?" button on the card that applies goal-appropriate
   defaults (recommended split via `WorkoutSplitRecommender`, training days). **Never** silently
   overwrite `WorkoutProfile` — it carries safety fields (avoidedMuscles/Movements) and the user's split.

### Open decisions (confirm before building)
1. **Auto-apply matching workout defaults on goal change, or describe-only?** Recommend **describe-only +
   an explicit "apply" button** (WorkoutProfile has user safety fields; clobbering them is a footgun).
2. Card layout: single-column list vs 2-column grid (7 goals). List reads cleaner with two summary lines.
3. Don't duplicate `ExperienceLevel` here — keep it in the workout profile to avoid two sources of truth.

---

## Feature B — Workout Live Activity (Dynamic Island + Lock Screen)

> "A live widget like airlines use — Dynamic Island + a large temporary Lock Screen widget. Guide the
> user through their workout and time rest between sets. A timer, a start button, and the workout info
> (exercise, # of reps, set number)."

### What exists today (facts, verified 2026-07-17)
- **`NSSupportsLiveActivities` is ALREADY `<true/>` in `Fernlet/Info.plist:26`.** No plist change needed.
- **No ActivityKit code exists yet** — no `ActivityAttributes` / `DynamicIsland` anywhere.
- **Widget extension** `FernletWidgets/`: `FernletWidgetsBundle.swift`, `WidgetSharedModels.swift`,
  `WaterPlusOneIntent.swift` (an existing **App Intent** — the in-repo pattern to copy),
  `FernletWidgets.entitlements`, app group **`group.MBO.Fernlet`**. App↔widget bridge = JSON files in the
  group container (`Fernlet/WidgetBridge.swift`, `WidgetSnapshotFileStore`).
- **Workout model**: `SessionSuggestion` (`WorkoutProgram.swift:945`) holds `[PrescribedExercise]`
  (`WorkoutProgram.swift:924`): `name`, `sets: Int`, `reps: String`, `role: SlotRole`, `line` =
  "name - sets x reps". `progressedPrescription(baseSets:baseReps:completions:)` (`:1103`) computes the
  climbing reps/sets. The **Move tab already generates the day's suggested session**.
- **There is NO guided-session / rest-timer flow today** — the app only *logs* completed workouts
  (`MoveView` draftSets/draftReps). The runner below is NEW.

### Design

**B1 — Guided-session runner (NEW, app side).** `WorkoutSessionRunner` (`@Observable @MainActor`):
- Input: the day's `SessionSuggestion`.
- State: `exercises: [PrescribedExercise]`, `exerciseIndex`, `currentSet`, `phase (.ready/.working/
  .resting/.done)`, `restEndsAt: Date?`.
- Actions: `start()`, `completeSet()` (advance set → rest; after the last set → next exercise; after the
  last set of the last exercise → `.done`), `skipRest()`, `end()`.
- Rest duration: derive per `role` + goal (compound/strength longer, accessory/hypertrophy shorter). Add
  `restSeconds(for role: SlotRole, goal: GoalType)` — propose compound ≈150s, accessory ≈75s (decision #1).

**B2 — Live Activity (ActivityKit).**
- `WorkoutActivityAttributes: ActivityAttributes` — **MUST live in a source file whose target membership
  is BOTH the app AND `FernletWidgets`** (the app requests/updates it; the widget renders it). This is the
  classic ActivityKit setup pitfall — do this first. (`WidgetSharedModels.swift` is a candidate home;
  verify its membership — if widget-only, add a new shared file to both targets.)
  - Static: `workoutTitle: String`.
  - `ContentState`: `exerciseName`, `setNumber`, `totalSets`, `reps: String`, `phase`,
    `restEndsAt: Date?`, `exerciseIndex`, `totalExercises`.
- `WorkoutLiveActivity: Widget` with `ActivityConfiguration(for: WorkoutActivityAttributes.self)`, added
  to `FernletWidgetsBundle`:
  - **Lock Screen / expanded**: exercise name, "Set X of Y", reps; when resting, a countdown via
    **`Text(timerInterval: now...restEndsAt, countsDown: true)`** — this ticks natively, **no push
    updates needed for the timer**.
  - **Dynamic Island**: compact = rest countdown + a set dot; expanded = exercise + "Set X/Y" + reps +
    timer; minimal = timer glyph.
- App side `WorkoutLiveActivityController`: `Activity.request(...)` on start; `activity.update(...)` on
  each set/exercise transition; `activity.end(...)` on finish. Guard
  `ActivityAuthorizationInfo().areActivitiesEnabled`; on launch reconcile stale
  `Activity<WorkoutActivityAttributes>.activities` (from a killed app).

**B3 — Controlling it from the lock screen.** So the user can advance sets without opening the app:
- Use a **`LiveActivityIntent`** (App Intents, iOS 17+) — mirror `WaterPlusOneIntent`. Buttons: "Done
  set", "Skip rest". `perform()` runs in-process: mutate the runner + call `activity.update(...)`.
- **No push / no server** (matches the app's ethos). Push (APNs) is explicitly rejected — it needs a
  server + push token. The rest *timer* needs no updates anyway (`Text(timerInterval:)`); only discrete
  set/exercise transitions need an `update`, which the App Intent triggers.

**B4 — Start button + integration.**
- MoveView: a "Start guided workout" entry builds the day's `SessionSuggestion` and starts the runner +
  the Live Activity.
- In-app guided sheet (recommended): the same runner state (exercise/set/reps + rest timer + "Done set"),
  so the flow works in-app too and is the fallback when Live Activities are disabled.
- On `.done`: end the Activity and **log the workout** through the existing logging path so it still counts.

### Gotchas / notes
- **Shared target membership of `WorkoutActivityAttributes`** is the #1 ActivityKit pitfall — get it into
  both targets before anything else compiles.
- Interactive buttons = iOS 17+ `LiveActivityIntent`; copy `WaterPlusOneIntent`.
- Rest countdown = `Text(timerInterval:)`; never try to push every second.
- Live Activities need runtime auth (`areActivitiesEnabled`) — degrade gracefully (in-app timer still works).
- One active workout activity at a time; reconcile `Activity.activities` on launch.
- **Sim caveat**: Dynamic Island renders on iPhone 15 Pro+/17 Pro sims, but widget/Metal rendering has
  been flaky in the sim this project (`ux-batch-2026-07-16-state`, item #21 was a sim artifact) — verify
  the Live Activity on a **real device**.
- **S3 wall**: the runner is app-side; `WorkoutActivityAttributes` is a plain Codable value shared with
  the widget — no sealed-store access, no wall issue. Keep it out of the `Private*` modules.

### Open decisions (confirm before building)
1. Rest durations per role/goal — exact seconds (propose compound 150s / accessory 75s; or a user default
   with per-exercise override).
2. Auto-log the session on completion, or guide only? Recommend **log on finish**.
3. In-app guided sheet in v1, or Live-Activity-only? Recommend **both** (share the runner; sheet is the
   fallback).
4. Interactive lock-screen buttons in v1, or start-only first? Recommend **ship start + auto rest-timer
   first**, then add the "Done set / Skip rest" `LiveActivityIntent` as a fast follow.

---

## Suggested build order
A (goal presets) is small and self-contained — a good warm-up. B is larger; do B1 (runner) + B4 (in-app
sheet) first to prove the guided flow, then B2 (Live Activity render) + B3 (interactive buttons). Verify
B on a real device.
