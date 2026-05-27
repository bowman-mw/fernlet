# Fernlet — Move Refactor & Trainer Integration: Codex Implementation Prompts

**Companion document to:** `move-refactor-and-trainer-integration-plan.md` (the design) and `apple-fitness-and-healthkit-research.md` (the research findings).

**Audience:** A coding assistant (Codex, Claude Code, Cursor, etc.) that you hand one prompt at a time. Each prompt is scoped to a single Codex run, includes acceptance criteria, and lists the tests it must add or update.

**Status:** Last revised 2026-05-23. Phases M1–M3 are implementable now. M4–M7 depend on Phase 7 of `ImplementationPlan.md` (proximity handshake). M8 (live workouts) and M9 (WorkoutKit) are additive and can land independently of the trainer work.

---

## How to use this document

1. Open the relevant prompt section.
2. Copy the prompt block verbatim (everything inside the fenced `prompt` block) into your coding assistant.
3. After the assistant completes the work, run the test suite. Do not advance to the next prompt until all named tests pass and the project builds.
4. Each prompt declares its dependencies. Do not skip ahead within a phase.
5. After completing each prompt, update `FileIndex.md` if new files were added.

---

## Conventions every prompt enforces

These conventions are repeated in shortened form in each prompt; the full list lives here for reference.

- **Target:** iOS 26.0 minimum. No `@available` fallbacks for iOS 17 or 18 features. Apple Intelligence is a hard requirement.
- **HealthKit:** Use `HKWorkoutBuilder` and `HKLiveWorkoutBuilder` exclusively. The convenience initializer `HKWorkout(activityType:start:end:…)` is deprecated in iOS 17 and must not appear anywhere in the codebase.
- **SwiftUI Testing framework:** New tests use Swift Testing (`@Test`, `#expect`) matching the existing `FernletTests.swift` style, not XCTest.
- **Codable migration:** Every model change must remain backwards-compatible with previously persisted JSON. Use `decodeIfPresent` with sensible defaults for every new field. Add a round-trip test that loads an old JSON snapshot (literal string in the test) and asserts the new fields populate defaults.
- **FileIndex updates:** When adding a file, append a row to `FileIndex.md` in the same table that lists the file's directory peers.
- **Naming:** New view files end in `View.swift`. New service files end in `Service.swift`. New repositories end in `Repository.swift`. New tests end in `Tests.swift` and live in the `FernletTests` target.
- **No deprecated focus tag references:** Do not add new references to `Workout.focusTag`, `Workout.focusColorName`, `WorkoutFocusTag`, or `FernletSettings.workoutFocusTags`. They are slated for removal in M3.
- **Repository writes:** All persistence goes through `FernletStore` and its `repository`. Do not write directly to UserDefaults, JSON, or Core Data from views.
- **Threading:** `HealthKitService` methods are `@MainActor` per the existing protocol. Anchored queries deliver on the HealthKit-supplied background queue; hop to the main actor before mutating store state.
- **Error handling:** HealthKit failures should not block local saves. Log a `Workout`-tagged audit record and continue.

---

## Phase index

| Phase | Title | Status | Dep |
|---|---|---|---|
| M1 | Local refactor — modes, activity types, muscle groups | Ready | — |
| M2 | HealthKit `HKWorkout` read/write | Ready | M1 |
| M3 | Deprecated-field cleanup | Ready | M1, M2 |
| M4 | Trainer plan data model (no transport) | Ready | M1 |
| M5 | Diff engine + multi-trainer plan selection UI | Ready | M4 |
| M6 | Proximity transport (depends on `ImplementationPlan.md` Phase 7) | Gated | M4, M5, Phase 7 |
| M7 | Trainer audit log + revoke + privacy filter | Ready | M6 |
| M8 | Live workout sessions on iPhone | Ready | M2 |
| M9 | WorkoutKit "Send to Apple Watch" | Ready | M4 |

---

# Phase M1 — Local refactor

## Prompt M1.1 — Add `WorkoutMode` and `MuscleGroup` taxonomy

**Depends on:** none
**Files to modify:** `Fernlet/Fernlet/Models.swift`
**Files to create:** `Fernlet/FernletTests/MoveRefactorTests.swift`

```prompt
You are working in the Fernlet iOS SwiftUI project. Target iOS 26.0+, Apple Intelligence required, Swift Testing framework. Read `move-refactor-and-trainer-integration-plan.md` §4.1, §4.2, and §E of `apple-fitness-and-healthkit-research.md` for context.

In `Models.swift`, add these public types near the existing `WorkoutType` enum:

1. `enum WorkoutMode: String, Codable, CaseIterable, Identifiable` with cases `.strengthTraining` and `.activity`. Add `id`, `label` (user-facing: "Strength Training" / "Workouts"), `pickerTitle`, `searchPlaceholder`, and `addLabel` computed properties matching the legacy `WorkoutLogMode` shape so the existing `MoveView` keeps compiling. Do not delete `WorkoutLogMode` yet — leave it as a `@available(*, deprecated)` typealias to `WorkoutMode` so other prompts can migrate at their own pace.

2. `enum MuscleGroup: String, Codable, CaseIterable, Identifiable` with cases: `chest`, `upperBack`, `lats`, `lowerBack`, `traps`, `frontDelts`, `sideDelts`, `rearDelts`, `biceps`, `triceps`, `forearms`, `abs`, `obliques`, `quads`, `hamstrings`, `glutes`, `calves`, `adductors`, `abductors`, `fullBody`. Each case gets a `displayName` (e.g., "Front Delts") and a `region: BodyRegion` mapping.

3. `enum BodyRegion: String, Codable, CaseIterable` with cases `.upper`, `.lower`, `.core`, `.full`. Mapping: chest/upperBack/lats/lowerBack/traps/frontDelts/sideDelts/rearDelts/biceps/triceps/forearms → .upper; quads/hamstrings/glutes/calves/adductors/abductors → .lower; abs/obliques → .core; fullBody → .full.

4. `enum MovementPattern: String, Codable, CaseIterable` with cases `.push`, `.pull`, `.hinge`, `.squat`, `.lunge`, `.carry`, `.twist`, `.isolation`, `.locomotion`. No fancy properties; just the enum.

5. `enum Equipment: String, Codable, CaseIterable, Identifiable` with cases `.barbell`, `.dumbbell`, `.machine`, `.cable`, `.bodyweight`, `.kettlebell`, `.band`, `.bench`, `.cardio`, `.none`. Each has a `displayName`.

Create the test file `FernletTests/MoveRefactorTests.swift`. Add Swift Testing tests:

- `@Test func workoutModeRoundTripsCodable()` — encode/decode each case.
- `@Test func muscleGroupAllRegionsCovered()` — every `MuscleGroup` case maps to a `BodyRegion`.
- `@Test func bodyRegionAllCasesUsed()` — every `BodyRegion` case has at least one `MuscleGroup` mapping to it.
- `@Test func muscleGroupRoundTripsCodable()` — encode/decode each case.
- `@Test func equipmentDisplayNamesNonEmpty()` — every `Equipment` case has a non-empty `displayName`.

After this prompt completes, update `FileIndex.md` to add a row for `MoveRefactorTests.swift` under the Tests section.

Do not touch `Workout`, `ExerciseTarget`, `WorkoutExercises.json`, or `MoveView.swift` yet. Those are in subsequent prompts.
```

---

## Prompt M1.2 — Add `WorkoutActivityType` enum + HK mapping

**Depends on:** M1.1
**Files to modify:** `Models.swift`
**Files to create:** `Fernlet/Fernlet/ActivityTypeCatalog.swift`, `FernletTests/ActivityTypeCatalogTests.swift`

```prompt
You are working in the Fernlet iOS SwiftUI project. Target iOS 26.0+. Read §6.5 of `move-refactor-and-trainer-integration-plan.md` and §B of `apple-fitness-and-healthkit-research.md`.

In `Models.swift`, add:

```swift
enum WorkoutActivityType: String, Codable, CaseIterable, Identifiable {
    case running, walking, hiking, cycling, indoorCycling
    case yoga, pilates, barre, dance, socialDance
    case swimmingPool, swimmingOpenWater, rowing, elliptical, stairClimbing, stairs
    case hiit, kickboxing, martialArts, climbing, jumpRope
    case tennis, basketball, soccer, pickleball, badminton, tableTennis, racquetball, squash
    case coreTraining, flexibility, mindAndBody, taiChi
    case functionalStrengthTraining, traditionalStrengthTraining
    case crossTraining, mixedCardio, preparationAndRecovery, cooldown
    case other

    var id: String { rawValue }
    var displayName: String { /* "Running", "Walking", "Indoor Cycling", "Pool Swim", etc. */ }
    var systemImage: String { /* SF Symbol: figure.run, figure.walk, etc. */ }
    var expectsDistance: Bool { /* true for running, walking, hiking, cycling, swimming, rowing outdoor, paddleSports, etc. */ }
    var expectsPace: Bool { /* true for running, walking, hiking */ }
    var defaultDurationMinutes: Int { /* 30 for strength, 45 for cardio, 60 for yoga/pilates/mindAndBody */ }
    var fernletCategory: WorkoutType { /* maps to existing WorkoutType.upper/.lower/.fullBody/.cardio */ }
}
```

Mapping notes for `fernletCategory`:
- Running/walking/hiking/cycling/indoorCycling/swimming/rowing/elliptical/stairClimbing/stairs/jumpRope/hiit/crossTraining/mixedCardio → `.cardio`
- Yoga/pilates/barre/dance/socialDance/flexibility/mindAndBody/taiChi/coreTraining → `.fullBody`
- functionalStrengthTraining/traditionalStrengthTraining → `.fullBody` (refined later by exercise muscle groups)
- All sports → `.cardio`
- Other/preparationAndRecovery/cooldown/kickboxing/martialArts/climbing → `.fullBody`

Create `ActivityTypeCatalog.swift`:

```swift
import Foundation
import HealthKit

enum ActivityTypeCatalog {
    static let allTypes: [WorkoutActivityType] = WorkoutActivityType.allCases

    static func search(_ query: String) -> [WorkoutActivityType] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return allTypes }
        return allTypes.filter { type in
            type.displayName.lowercased().contains(trimmed)
                || type.rawValue.lowercased().contains(trimmed)
        }
    }

    // Bidirectional mapping with HealthKit
    static func hkActivityType(for type: WorkoutActivityType) -> HKWorkoutActivityType { /* full mapping per research §6.5 */ }
    static func fernletType(for hk: HKWorkoutActivityType) -> WorkoutActivityType { /* inverse; default to .other */ }
}
```

Tests in new file `ActivityTypeCatalogTests.swift`:

- `@Test func allActivityTypesRoundTripCodable()`
- `@Test func everyActivityTypeHasDisplayNameAndSymbol()` — assert non-empty for every case.
- `@Test func hkMappingRoundTrips()` — for every `WorkoutActivityType`, mapping to HK and back returns the same case (except `.other` which is the catch-all).
- `@Test func searchMatchesByDisplayName()` — `ActivityTypeCatalog.search("yoga")` returns at least `.yoga`.
- `@Test func searchIsCaseInsensitive()` — "YOGA" and "yoga" return the same results.
- `@Test func searchEmptyReturnsAll()` — empty query returns all types.
- `@Test func everyActivityTypeMapsToFernletCategory()` — no case crashes.

Update `FileIndex.md` to add rows for both new files.
```

---

## Prompt M1.3 — Refactor `ExerciseTarget` to carry muscle groups, equipment, and movement pattern

**Depends on:** M1.1
**Files to modify:** `Models.swift`, `Fernlet/Fernlet/WorkoutExercises.json`
**Files to create:** none

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §4 of `move-refactor-and-trainer-integration-plan.md` and §E of `apple-fitness-and-healthkit-research.md`.

Currently `ExerciseTarget` (in `Models.swift`) has fields: `name`, `category: WorkoutType`, `muscles: [String]`, `inputKind: ExerciseInputKind`.

Refactor to:

```swift
struct ExerciseTarget: Identifiable, Codable, Equatable {
    var id: String { name }
    var name: String
    var primaryMuscles: Set<MuscleGroup>     // 1–2 entries typically
    var secondaryMuscles: Set<MuscleGroup>   // 0–3 entries typically
    var equipment: Equipment
    var movementPattern: MovementPattern
    var inputKind: ExerciseInputKind         // unchanged

    // Computed for backwards compat — derives from primary muscles
    var bodyRegion: BodyRegion {
        let regions = Set(primaryMuscles.map { $0.region })
        if regions == [.upper] { return .upper }
        if regions == [.lower] { return .lower }
        if regions == [.core] { return .core }
        return .full
    }

    // Computed for backwards compat — used by existing WorkoutType-aware code
    var category: WorkoutType {
        switch bodyRegion {
        case .upper: return .upper
        case .lower: return .lower
        case .core: return .fullBody
        case .full: return .fullBody
        }
    }

    // Legacy decoder: if old JSON has `muscles: [String]` and `category: String`, parse them
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        inputKind = try container.decodeIfPresent(ExerciseInputKind.self, forKey: .inputKind) ?? .strength
        equipment = try container.decodeIfPresent(Equipment.self, forKey: .equipment) ?? .none
        movementPattern = try container.decodeIfPresent(MovementPattern.self, forKey: .movementPattern) ?? .isolation
        if let prim = try container.decodeIfPresent(Set<MuscleGroup>.self, forKey: .primaryMuscles) {
            primaryMuscles = prim
            secondaryMuscles = try container.decodeIfPresent(Set<MuscleGroup>.self, forKey: .secondaryMuscles) ?? []
        } else {
            // Legacy path: convert [String] muscles to MuscleGroup best-effort
            let legacy = try container.decodeIfPresent([String].self, forKey: .legacyMuscles) ?? []
            primaryMuscles = Set(legacy.compactMap(MuscleGroup.fromLegacyString))
            secondaryMuscles = []
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name, primaryMuscles, secondaryMuscles, equipment, movementPattern, inputKind
        case legacyMuscles = "muscles"
    }
}
```

Add an extension on `MuscleGroup`:
```swift
extension MuscleGroup {
    static func fromLegacyString(_ s: String) -> MuscleGroup? {
        switch s.lowercased() {
        case "chest": return .chest
        case "triceps": return .triceps
        case "biceps": return .biceps
        case "shoulders": return .frontDelts  // map ambiguous to front for legacy
        case "back": return .upperBack
        case "lats": return .lats
        case "core": return .abs
        case "quads": return .quads
        case "hamstrings": return .hamstrings
        case "glutes": return .glutes
        case "calves": return .calves
        case "full body": return .fullBody
        case "legs": return .quads  // map ambiguous legacy to quads
        case "cardio", "mobility", "balance", "coordination", "sport", "class": return nil
        default: return nil
        }
    }
}
```

Now rewrite `WorkoutExercises.json`. Use the new schema (`primaryMuscles`, `secondaryMuscles`, `equipment`, `movementPattern`). Move the class/sport/outdoor-locomotion entries OUT — they are now `WorkoutActivityType` cases, not strength catalog entries. Keep only true strength + treadmill exercises. Expand the catalog to roughly 40 well-categorized entries covering common gym lifts. Example entry shape:

```json
{
  "name": "Bench press",
  "primaryMuscles": ["chest"],
  "secondaryMuscles": ["triceps", "frontDelts"],
  "equipment": "barbell",
  "movementPattern": "push",
  "inputKind": "strength"
}
```

Entries to include at minimum (use your judgment on muscles):
- Pushes: Bench press, Incline bench press, Overhead press, Dumbbell bench press, Push-up, Dip, Cable fly, Lateral raise, Front raise, Triceps pushdown, Skullcrusher, Close-grip bench
- Pulls: Pull-up, Chin-up, Lat pulldown, Barbell row, Dumbbell row, Cable row, Face pull, Biceps curl, Hammer curl, Preacher curl, Rear delt fly, Shrug
- Squats: Back squat, Front squat, Goblet squat, Leg press, Hack squat, Bulgarian split squat, Lunge, Step-up, Leg extension
- Hinges: Deadlift, Romanian deadlift, Hip thrust, Glute bridge, Good morning, Hyperextension, Leg curl
- Core: Plank, Side plank, Hanging leg raise, Ab wheel, Cable crunch, Russian twist, Pallof press
- Calves: Standing calf raise, Seated calf raise
- Treadmill: Treadmill walk, Treadmill run (these stay because they have a structured input form distinct from a "Workouts" mode activity)
- Full body: Burpee, Kettlebell swing, Clean, Snatch, Thruster, Turkish get-up

Note: Outdoor walk, outdoor run, bike, row erg, all class entries (Pilates class, Yoga class, etc.), and all sport entries (Tennis, Basketball, etc.) are REMOVED from this file. They belong to `WorkoutActivityType` for the "Workouts" mode.

Add tests in the existing `MoveRefactorTests.swift`:

- `@Test func exerciseTargetDecodesNewSchema()` — decode a literal JSON string in the new format; assert primary/secondary muscles populate.
- `@Test func exerciseTargetDecodesLegacySchema()` — decode a literal old-format JSON string; assert legacy `muscles` strings convert to `primaryMuscles` best-effort and `secondaryMuscles` is empty.
- `@Test func bundledExerciseCatalogLoads()` — `WorkoutExerciseCatalog.baseExercises` is non-empty and every entry has at least one `primaryMuscle`.
- `@Test func bundledCatalogContainsNoClasses()` — no exercise in `baseExercises` has `inputKind == .none` AND a name matching /class|tennis|basketball|soccer|pickleball|outdoor (walk|run)|bike|row erg/i.
- `@Test func bundledCatalogHasReasonableSize()` — count is at least 35.

Do not change `MoveView.swift` yet.
```

---

## Prompt M1.4 — Update `Workout` struct with `mode`, `activityType`, distance/energy, muscle-group cache

**Depends on:** M1.1, M1.2, M1.3
**Files to modify:** `Models.swift`
**Files to create:** none

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §4.3 of `move-refactor-and-trainer-integration-plan.md`.

Update the `Workout` struct in `Models.swift`. The current struct is at approximately line 1496. Add these new fields (all optional or with defaults so old JSON still decodes):

```swift
var mode: WorkoutMode = .strengthTraining
var activityType: WorkoutActivityType?
var distanceMiles: Double?
var activeEnergyKcal: Double?
var effort: Int?                         // 1–10, Apple Watch "Effort" rating, see research §G
var muscleGroups: Set<MuscleGroup> = []   // aggregated from logged exercises, drives chrome/category
var healthKitUUID: UUID?
var plannedWorkoutID: UUID?

// DEPRECATED — decode-only. Stop reading or writing in new code.
@available(*, deprecated, message: "Use mode/activityType instead. Will be removed in M3.")
var focusTag: String = ""

@available(*, deprecated, message: "Will be removed in M3.")
var focusColorName: WorkoutTagColor = .moss
```

Update `init(from:)` to `decodeIfPresent` all new fields. Defaults:
- `mode = .strengthTraining` (safe default for legacy logs)
- `activityType = nil`
- `distanceMiles, activeEnergyKcal, effort = nil`
- `muscleGroups = []` (populated lazily on first read by re-scanning `exercises` if empty)
- `healthKitUUID, plannedWorkoutID = nil`
- Continue decoding `focusTag` and `focusColorName` with their existing defaults for backwards compat.

Add a designated initializer signature that accepts every new field with defaults so existing call sites keep compiling.

Add a derived property:

```swift
var inferredCategory: WorkoutType {
    // 1. If activity-mode, defer to activity type
    if mode == .activity, let activityType {
        return activityType.fernletCategory
    }
    // 2. If we have muscle groups, aggregate to a region
    if !muscleGroups.isEmpty {
        let regions = muscleGroups.map { $0.region }
        let upper = regions.filter { $0 == .upper }.count
        let lower = regions.filter { $0 == .lower }.count
        let core = regions.filter { $0 == .core }.count
        let total = max(upper + lower + core, 1)
        if Double(upper) / Double(total) >= 0.7 { return .upper }
        if Double(lower) / Double(total) >= 0.7 { return .lower }
        if Double(core) / Double(total) >= 0.7 { return .fullBody }  // core surfaces as fullBody given existing enum
        return .fullBody
    }
    // 3. Fallback to legacy text-based inference
    return WorkoutExerciseCatalog.inferredCategory(for: self)
}
```

Add tests to `MoveRefactorTests.swift`:

- `@Test func workoutDecodesLegacyJSONWithoutModeOrActivityType()` — given a literal old-format JSON string, assert `mode == .strengthTraining`, `activityType == nil`, `focusTag` populated, no crash.
- `@Test func workoutRoundTripsWithNewFields()` — encode/decode an activity-mode workout with distance, energy, effort populated; assert all preserved.
- `@Test func inferredCategoryFavorsActivityTypeWhenActivityMode()` — activity-mode workout with activityType `.cycling` returns `.cardio`.
- `@Test func inferredCategoryAggregatesMuscleGroups()` — strength workout with muscleGroups = {chest, triceps, frontDelts} returns `.upper`.
- `@Test func inferredCategoryFallsBackToTextWhenEmpty()` — strength workout with no muscle groups falls back to existing `WorkoutExerciseCatalog.inferredCategory`.
- `@Test func workoutPreservesFocusTagForLegacyDecode()` — old JSON with focusTag populates the deprecated field but doesn't break the new fields.
```

---

## Prompt M1.5 — Rebuild `WorkoutSheet`: new kind chips, search-bar swap, remove focus tag

**Depends on:** M1.1, M1.2, M1.3, M1.4
**Files to modify:** `Fernlet/Fernlet/MoveView.swift`
**Files to create:** `Fernlet/Fernlet/ActivityPickerSection.swift`

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §3 and §5 of `move-refactor-and-trainer-integration-plan.md` and §A and §G of `apple-fitness-and-healthkit-research.md`.

Refactor `WorkoutSheet` in `MoveView.swift`:

1. **Replace `WorkoutLogMode` everywhere with `WorkoutMode`.** The old enum had `.exercises` and `.class`. The new enum has `.strengthTraining` and `.activity`. Map any remaining usage of `.exercises` → `.strengthTraining` and `.class` → `.activity`. Delete the old `enum WorkoutLogMode { case exercises; case class }` block once nothing references it (search the whole project; the deprecation typealias in M1.1 should let the build pass through this prompt).

2. **Update the Kind chip row in `WorkoutSheet`:**
```swift
SheetField("Kind") {
    FlowLayout(spacing: 8) {
        ForEach(WorkoutMode.allCases) { mode in
            Button(mode.label) { logMode = mode }
                .buttonStyle(ChipButtonStyle(selected: logMode == mode))
        }
    }
}
```

3. **Conditionally render the body based on `logMode`:**
   - If `.strengthTraining`: keep the existing `WorkoutExerciseBuilder` and `LoggedExerciseRow` list. Drive the picker search via `WorkoutExerciseCatalog.search(query)` and only show strength/treadmill exercises.
   - If `.activity`: render `ActivityPickerSection` (new file, see below). Below it, render duration/distance/energy/effort fields conditionally based on the selected activity's `expectsDistance` / etc.

4. **DELETE** the entire focus-tag chip block (currently lines ~151–162 in `MoveView.swift`):
```swift
// REMOVE THIS:
if !store.settings.workoutFocusTags.isEmpty {
    SheetField("Focus tag") { ... }
}
```

5. **Update the save action.** Build the `Workout` with the new fields:
```swift
var workout = Workout(
    name: workoutName,
    type: inferredCategory,
    mode: logMode,
    activityType: logMode == .activity ? selectedActivityType : nil,
    exercises: exerciseText,
    distanceMiles: logMode == .activity ? Double(distance) : nil,
    activeEnergyKcal: logMode == .activity ? Double(energyKcal) : nil,
    rpe: Double(rpe),
    notes: notes,
    duration: Int(duration),
    intensity: intensity,
    effort: Int(effort),
    muscleGroups: logMode == .strengthTraining ? aggregatedMuscleGroups : []
)
```
Where `aggregatedMuscleGroups` is computed from the `exerciseRows`:
```swift
private var aggregatedMuscleGroups: Set<MuscleGroup> {
    exerciseRows.reduce(into: Set<MuscleGroup>()) { acc, row in
        acc.formUnion(row.exercise.primaryMuscles)
        acc.formUnion(row.exercise.secondaryMuscles)
    }
}
```

6. **`saveDisabled` rule update:**
   - `.strengthTraining`: workout name non-empty AND `exerciseRows` non-empty.
   - `.activity`: `selectedActivityType != nil` AND (`duration` parses to int > 0 OR `distance` parses to double > 0).

7. **Create `ActivityPickerSection.swift`** as a new file in the Fernlet target:

```swift
import SwiftUI

struct ActivityPickerSection: View {
    @Binding var selectedActivityType: WorkoutActivityType?
    @Binding var duration: String
    @Binding var distance: String
    @Binding var energyKcal: String
    @Binding var effort: String
    @State private var query: String = ""

    var body: some View {
        // Search field (matches ExerciseSearchPicker styling)
        // Result list of activity cards with SF Symbol + display name
        // When selected, show Duration / Distance (if expectsDistance) / Energy / Effort (1-10 slider) rows
    }
}
```

The picker should:
- Show a horizontal grid of the user's last 5 used activity types ("Recent") at the top.
- Below: a scrollable list of all activity types, filtered by `query`.
- When an activity is selected, fill in default duration from `activityType.defaultDurationMinutes`.
- The Effort field is a slider 1–10 with labels "Easy" and "All-out" at the endpoints.

Recent activity persistence: store as `[String]` (raw values) under `@AppStorage("fernlet.recentActivityTypes")`. Capped at 5 entries. Updated whenever a new activity is selected for save.

8. **Tests:** Add to `MoveRefactorTests.swift`:

- `@Test func saveDisabledStrengthRequiresNameAndExercises()` — assert disabled state for empty name, empty exercises, both fields populated.
- `@Test func saveDisabledActivityRequiresTypeAndDurationOrDistance()` — assert disabled state for missing type, missing both duration and distance, type + duration populated, type + distance populated.
- `@Test func aggregatedMuscleGroupsCombinesPrimaryAndSecondary()` — given a list of WorkoutExerciseEntry with known muscle groups, assert the aggregated Set contains the union of primaries and secondaries.

UI tests in `FernletUITests/FernletUITests.swift`:
- `func testKindToggleChangesSearchPlaceholder()` — toggle from Strength Training to Workouts, assert the search field's placeholder text changes.
- `func testFocusTagFieldNoLongerVisible()` — open the workout sheet, assert no view with label "Focus tag" is present.
- `func testActivityModeRequiresTypeBeforeSave()` — in activity mode, the Save button is disabled until a type is picked.

Update `FileIndex.md` for `ActivityPickerSection.swift`.
```

---

## Prompt M1.6 — Settings cleanup: remove focus-tag section, add Apple Fitness status row

**Depends on:** M1.5
**Files to modify:** `Fernlet/Fernlet/SettingsSheet.swift`
**Files to create:** none

```prompt
You are working in the Fernlet iOS SwiftUI project.

In `SettingsSheet.swift`, find `moveTab` (currently around line 417). The section currently named "Workout focus tags" (lines ~417–484) must be removed entirely:

- Delete the `SectionLabel("Workout focus tags")` heading.
- Delete the VStack body that renders the empty state, the `ForEach(store.settings.workoutFocusTags)`, the new-tag text field, color picker, and "Add focus tag" button.
- Delete the state vars `newWorkoutFocusTagName` and `newWorkoutFocusTagColor`.
- Delete the methods `addWorkoutFocusTag()` and `removeWorkoutFocusTag(_:)`.
- Do NOT delete `FernletStore.setWorkoutFocusTags` yet — it stays until M3.

Replace the deleted section with an "Apple Fitness sync" row:

```swift
SectionLabel("Apple Fitness sync")
VStack(alignment: .leading, spacing: 10) {
    Text("When enabled, Fernlet writes your logged workouts to Apple Health so they appear in the Fitness app, and pulls workouts logged elsewhere back into Fernlet.")
        .font(.callout.italic())
        .foregroundStyle(Color.slate)
        .fernletWrappingText()

    // Status row showing current HealthCapability.workoutLogging authorization,
    // with a button to request authorization. Mirror the style of the existing
    // permissions rows in OnboardingPermissionsView.
}
.padding(14)
.background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
```

The status row should display "Not requested", "Authorized", or "Denied" based on the snapshot from `HealthKitService`. Since `HealthCapability.workoutLogging` is added in M2.1, for now use a placeholder string "Available after Apple Fitness integration lands (M2)" and a disabled button. M2.1 will wire it up.

Tests in `MoveRefactorTests.swift`:
- `@Test func settingsSheetMoveTabNoLongerReferencesFocusTags()` — string-search the source of `SettingsSheet.swift` (read the file from disk in the test) and assert no occurrence of "workoutFocusTags", "addWorkoutFocusTag", or "removeWorkoutFocusTag" outside of the `setWorkoutFocusTags` method (which lives on the store and stays until M3).

UI test addition in `FernletUITests`:
- `func testSettingsMoveTabHasNoFocusTagsSection()` — open Settings → Move tab, assert no row with label "Workout focus tags" is present.
```

---

## Prompt M1.7 — Update `QuickExerciseSheet` and `WorkoutSuggestion.workout(intensity:)` for new `Workout` shape

**Depends on:** M1.4
**Files to modify:** `Fernlet/Fernlet/MoveView.swift`, `Fernlet/Fernlet/Scoring.swift`
**Files to create:** none

```prompt
You are working in the Fernlet iOS SwiftUI project.

The `Workout` struct gained a `mode: WorkoutMode` field in M1.4 with a default of `.strengthTraining`. Existing constructors should compile, but they should now explicitly state intent for clarity.

In `MoveView.swift`, find `QuickExerciseSheet` (around line 298). The `store.addWorkout(Workout(...))` call (around line 359) should pass `mode: .strengthTraining` explicitly. Also populate `muscleGroups` from `entry.exercise.primaryMuscles.union(entry.exercise.secondaryMuscles)`.

In `Scoring.swift`, find `WorkoutSuggestion.workout(intensity:)` (around line 308). Update to:

```swift
func workout(intensity: WorkoutIntensity) -> Workout {
    Workout(
        name: name,
        type: .mixed,
        mode: .strengthTraining,
        exercises: exercises,
        rpe: nil,
        notes: notes,
        duration: nil,
        intensity: intensity
    )
}
```

(`WorkoutSuggestion` doesn't know muscle groups in v1, so leave that field empty — `inferredCategory` will fall back to text-based inference.)

Update the existing test in `FernletTests.swift`:
- `@Test func workoutSuggestionLibraryReturnsSuggestionForEachGoal()` — already exists. Add an assertion that the returned `Workout.mode == .strengthTraining`.

Add a new test:
- `@Test func quickExerciseSheetCreatesStrengthMode()` — construct the workout that `QuickExerciseSheet` would produce given a known `WorkoutExerciseEntry`, assert `mode == .strengthTraining` and `muscleGroups` non-empty.
```

---

# Phase M2 — HealthKit `HKWorkout` read/write

## Prompt M2.1 — Add `.workoutLogging` HealthCapability + onboarding hook

**Depends on:** M1 complete
**Files to modify:** `Fernlet/Fernlet/HealthKitService.swift`, `Fernlet/Fernlet/OnboardingPermissionsView.swift`, `Fernlet/Fernlet/Info.plist`
**Files to create:** none

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §6 of `move-refactor-and-trainer-integration-plan.md` and §C of `apple-fitness-and-healthkit-research.md`.

In `HealthKitService.swift`:

1. Add `.workoutLogging` to the `HealthCapability` enum.
2. Title: "Workout logging".
3. Summary: "Read and write workouts in Apple Health so Fernlet and Apple Fitness stay in sync."
4. Add to `HealthAuthorizationPresentation.writeTypeIdentifiers(for: .workoutLogging)`:
   - `HKObjectType.workoutType()` is implicitly in shareTypes (handle via the auth call, not this string list).
   - For the user-visible permission summary, list:
     - `HKQuantityTypeIdentifier.activeEnergyBurned.rawValue`
     - `HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue`
     - `HKQuantityTypeIdentifier.distanceCycling.rawValue`
     - `HKQuantityTypeIdentifier.distanceSwimming.rawValue`
5. In the actual authorization request method, request:
   - Share: `HKObjectType.workoutType()`, `HKQuantityType(.activeEnergyBurned)`, `HKQuantityType(.distanceWalkingRunning)`, `HKQuantityType(.distanceCycling)`, `HKQuantityType(.distanceSwimming)`
   - Read: same five types

In `OnboardingPermissionsView.swift`, add a row for `.workoutLogging` in the list of capabilities the user can opt into. Use the same chip/toggle pattern as existing rows. The row should appear after the `bodyContext` row (workouts are a passive context too).

In `Info.plist`, ensure these usage description keys exist (add if missing):
- `NSHealthShareUsageDescription`: keep existing if present; ensure it mentions workouts: "Fernlet reads your workouts, body metrics, and (optionally) cycle data from Apple Health to give you a complete picture of your activity."
- `NSHealthUpdateUsageDescription`: keep existing if present; ensure it mentions workouts: "Fernlet writes the workouts you log into Apple Health so they appear in Apple Fitness and across your devices."

Tests in `HealthKitDisableTests.swift` (existing file):
- `@Test func workoutLoggingCapabilityHasNonEmptySummaryAndTitle()`
- `@Test func workoutLoggingWriteTypeIdentifiersListIncludesActiveEnergy()`

Add to `MoveRefactorTests.swift`:
- `@Test func healthCapabilityIncludesWorkoutLogging()` — `HealthCapability.allCases.contains(.workoutLogging)`.

Note: This prompt only declares the capability. The actual save/read implementation is in M2.2 and M2.3.
```

---

## Prompt M2.2 — Implement `HealthKitService.saveWorkout(_:)` via `HKWorkoutBuilder`

**Depends on:** M2.1
**Files to modify:** `Fernlet/Fernlet/HealthKitService.swift`
**Files to create:** `Fernlet/FernletTests/HealthKitWorkoutTests.swift`

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §C and §F of `apple-fitness-and-healthkit-research.md`. CRITICAL: do not use `HKWorkout(activityType:start:end:…)` — it is deprecated in iOS 17. Use `HKWorkoutBuilder` exclusively.

Extend the `HealthKitServicing` protocol with:

```swift
func saveWorkout(_ workout: Workout) async throws -> UUID
```

In `HealthKitService`, implement:

```swift
func saveWorkout(_ workout: Workout) async throws -> UUID {
    guard isHealthDataAvailable() else { throw HealthKitServiceError.healthDataUnavailable }

    // 1. Build configuration
    let config = HKWorkoutConfiguration()
    let hkActivityType: HKWorkoutActivityType
    switch workout.mode {
    case .strengthTraining:
        hkActivityType = .traditionalStrengthTraining
    case .activity:
        hkActivityType = workout.activityType.map(ActivityTypeCatalog.hkActivityType(for:)) ?? .other
    }
    config.activityType = hkActivityType
    config.locationType = .unknown  // unknown is safe; .indoor/.outdoor refined later from activityType

    // 2. Resolve start/end
    let durationSeconds: TimeInterval = TimeInterval((workout.duration ?? defaultDuration(for: workout)) * 60)
    let endDate = workout.completedAt
    let startDate = endDate.addingTimeInterval(-durationSeconds)

    // 3. Begin builder
    let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: config, device: .local())
    try await builder.beginCollection(at: startDate)

    // 4. Add active energy sample if known
    var samples: [HKSample] = []
    if let kcal = workout.activeEnergyKcal, kcal > 0 {
        let q = HKQuantity(unit: .kilocalorie(), doubleValue: kcal)
        let s = HKQuantitySample(
            type: HKQuantityType(.activeEnergyBurned),
            quantity: q,
            start: startDate,
            end: endDate
        )
        samples.append(s)
    }
    // 5. Add distance sample if known
    if let miles = workout.distanceMiles, miles > 0 {
        let q = HKQuantity(unit: .mile(), doubleValue: miles)
        let typeID: HKQuantityTypeIdentifier = switch workout.activityType {
        case .cycling, .indoorCycling: .distanceCycling
        case .swimmingPool, .swimmingOpenWater: .distanceSwimming
        default: .distanceWalkingRunning
        }
        let s = HKQuantitySample(
            type: HKQuantityType(typeID),
            quantity: q,
            start: startDate,
            end: endDate
        )
        samples.append(s)
    }
    if !samples.isEmpty {
        try await builder.addSamples(samples)
    }

    // 6. Add metadata
    var metadata: [String: Any] = [
        "fernlet.workoutID": workout.id.uuidString,
        "fernlet.mode": workout.mode.rawValue,
        "fernlet.intensity": workout.intensity.rawValue,
        HKMetadataKeySyncIdentifier: workout.id.uuidString,
        HKMetadataKeySyncVersion: NSNumber(value: 1)
    ]
    if !workout.muscleGroups.isEmpty {
        metadata["fernlet.muscleGroups"] = workout.muscleGroups.map(\.rawValue).sorted().joined(separator: ",")
    }
    if !workout.exercises.isEmpty {
        metadata["fernlet.exercises"] = workout.exercises
    }
    if !workout.notes.isEmpty {
        metadata["fernlet.notes"] = workout.notes
    }
    if let effort = workout.effort {
        metadata["fernlet.effort"] = NSNumber(value: effort)
    }
    if let plannedID = workout.plannedWorkoutID {
        metadata["fernlet.plannedWorkoutID"] = plannedID.uuidString
    }
    try await builder.addMetadata(metadata)

    // 7. End collection and finish
    try await builder.endCollection(at: endDate)
    let saved = try await builder.finishWorkout()
    guard let saved else { throw HealthKitServiceError.healthDataUnavailable }
    return saved.uuid
}

private func defaultDuration(for workout: Workout) -> Int {
    switch workout.mode {
    case .strengthTraining: return 30
    case .activity: return workout.activityType?.defaultDurationMinutes ?? 45
    }
}
```

Also add (we will need it in M2.3 reconciliation):

```swift
private static func workoutWriteTypes() -> Set<HKSampleType> {
    [
        HKObjectType.workoutType(),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.distanceCycling),
        HKQuantityType(.distanceSwimming)
    ]
}
```

Create `FernletTests/HealthKitWorkoutTests.swift`. Use the existing test harness pattern (look at `HealthKitDisableTests.swift` for the mock pattern). Mock `HKHealthStore` is not feasible; the tests should focus on the prep logic before the HK call:

- `@Test func saveWorkoutBuildsTraditionalStrengthConfigForStrengthMode()` — extract the configuration-building logic into an internal helper `static func makeConfiguration(for: Workout) -> HKWorkoutConfiguration` and test it directly.
- `@Test func saveWorkoutBuildsCorrectActivityTypeForActivityMode()` — for each `WorkoutActivityType`, the produced config has the matching HK activity type.
- `@Test func saveWorkoutDefaultsDurationWhenMissing()` — `defaultDuration(for:)` returns 30 for strength, 45 for activity without explicit override.
- `@Test func saveWorkoutMetadataIncludesFernletID()` — extract metadata-building into `static func makeMetadata(for: Workout) -> [String: Any]`; assert it contains `fernlet.workoutID` matching the workout's UUID.
- `@Test func saveWorkoutMetadataIncludesMuscleGroupsWhenPresent()` — given a workout with non-empty `muscleGroups`, assert metadata contains `fernlet.muscleGroups` with comma-separated raw values in sorted order.
- `@Test func saveWorkoutMetadataOmitsMuscleGroupsWhenEmpty()` — given empty muscleGroups, the key is absent.
- `@Test func saveWorkoutMetadataIncludesPlannedIDWhenPresent()` — given `plannedWorkoutID` set, metadata contains `fernlet.plannedWorkoutID`.

Refactor the internal helpers (`makeConfiguration`, `makeMetadata`, `defaultDuration`) to be `internal static` so they can be tested without invoking HKHealthStore.

Update `FileIndex.md` for the new test file.

Do NOT modify `FernletStore.addWorkout` yet — that's prompt M2.4.
```

---

## Prompt M2.3 — Implement anchored-query observer for Apple Fitness → Fernlet sync

**Depends on:** M2.2
**Files to modify:** `Fernlet/Fernlet/HealthKitService.swift`, `Fernlet/Fernlet/FernletStore.swift`
**Files to create:** none

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §6.4 of `move-refactor-and-trainer-integration-plan.md`.

Extend `HealthKitServicing` with:

```swift
func startObservingWorkouts(handler: @escaping ([HKWorkout]) -> Void) async throws
func stopObservingWorkouts()
func recentWorkouts(since anchorDate: Date) async throws -> [HKWorkout]
```

Implement in `HealthKitService`:

1. **Anchored object query**: use `HKAnchoredObjectQuery` over `HKObjectType.workoutType()`. Persist the anchor in the keychain (not UserDefaults) using a new keychain key constant `"fernlet.healthkit.workoutAnchor"`. Mirror the existing keychain handling in `SystemHealthKitStoreController`.

2. **`startObservingWorkouts`**: load the persisted anchor (if any), execute the anchored query with `updateHandler` set so it emits incrementally, and persist the new anchor after each delivery. Call `handler` on the main actor.

3. **`recentWorkouts(since:)`**: an `HKSampleQuery` with `predicateForSamples(withStart: since, end: nil, options: [])` sorted by end date descending. Used for the 30-day backfill.

Add to `FernletStore.swift`:

```swift
@MainActor
func refreshWorkoutsFromHealth() async {
    let service = healthKitService ?? HealthKitService()  // existing pattern; check how store gets the service
    let snapshot = service.currentAuthorizationSnapshot()
    guard snapshot.status(for: "workoutLogging") == .sharingAuthorized else { return }

    do {
        try await service.startObservingWorkouts { [weak self] workouts in
            Task { @MainActor in
                self?.reconcileWorkouts(workouts)
            }
        }
    } catch {
        // Audit log; do not surface to UI
    }
}

private func reconcileWorkouts(_ hkWorkouts: [HKWorkout]) {
    for hk in hkWorkouts {
        // 1. Check if we already have this workout by externalUUID
        let externalID = hk.metadata?["fernlet.workoutID"] as? String
        let syncID = hk.metadata?[HKMetadataKeySyncIdentifier] as? String
        let knownID = externalID ?? syncID
        if let knownID, let uuid = UUID(uuidString: knownID), workoutExists(id: uuid) {
            // Update healthKitUUID if missing
            continue
        }

        // 2. Construct a new Workout from the HKWorkout
        let workout = makeWorkout(from: hk)
        let dayKey = FernletDate.dayKey(for: hk.endDate)
        addWorkout(workout, date: dayKey)
    }
}

private func workoutExists(id: UUID) -> Bool {
    // Check today's day plus any cached past days
    if day.workouts.contains(where: { $0.id == id }) { return true }
    // ... extend to past days via repository if needed
    return false
}

private func makeWorkout(from hk: HKWorkout) -> Workout {
    let activityType = ActivityTypeCatalog.fernletType(for: hk.workoutActivityType)
    let durationMin = Int(hk.duration / 60)
    let kcal = hk.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
    let distanceMiles: Double? = {
        let types: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .distanceSwimming]
        for typeID in types {
            if let q = hk.statistics(for: HKQuantityType(typeID))?.sumQuantity()?.doubleValue(for: .mile()) {
                return q > 0 ? q : nil
            }
        }
        return nil
    }()
    let name = (hk.metadata?["fernlet.activityName"] as? String) ?? activityType.displayName
    let mode: WorkoutMode = {
        if hk.workoutActivityType == .traditionalStrengthTraining || hk.workoutActivityType == .functionalStrengthTraining {
            return .strengthTraining
        }
        return .activity
    }()
    let muscleGroupsRaw = (hk.metadata?["fernlet.muscleGroups"] as? String) ?? ""
    let muscleGroups = Set(muscleGroupsRaw.split(separator: ",").compactMap { MuscleGroup(rawValue: String($0)) })
    let exercises = (hk.metadata?["fernlet.exercises"] as? String) ?? ""
    let notes = (hk.metadata?["fernlet.notes"] as? String) ?? ""
    let effort = (hk.metadata?["fernlet.effort"] as? NSNumber)?.intValue
    return Workout(
        name: name,
        type: activityType.fernletCategory,
        mode: mode,
        activityType: mode == .activity ? activityType : nil,
        exercises: exercises,
        distanceMiles: distanceMiles,
        activeEnergyKcal: kcal,
        rpe: nil,
        notes: notes,
        duration: durationMin,
        intensity: .moderate,
        completedAt: hk.endDate,
        effort: effort,
        muscleGroups: muscleGroups,
        healthKitUUID: hk.uuid
    )
}
```

Wire `refreshWorkoutsFromHealth()` into `MoveView`'s `task` modifier on appear.

Tests in `HealthKitWorkoutTests.swift`:
- `@Test func makeWorkoutFromHKWorkoutPreservesActivityType()` — extract `makeWorkout(from:)` into an internal static helper that can be unit-tested with a synthesized `HKWorkout`. (HKWorkout has no public initializer in iOS 17+, so this test will need to construct via HKWorkoutBuilder in a real HealthStore — skip if running in CI without entitlements; mark as `@Test(.disabled("Requires HealthKit entitlement"))`.)
- `@Test func makeWorkoutSetsStrengthModeForStrengthHKActivity()` — same constraint.
- `@Test func makeWorkoutParsesMuscleGroupsMetadata()` — given a known metadata dictionary, parse to Set<MuscleGroup>.
- `@Test func makeWorkoutDefaultsModeToActivityForCardio()` — for `.running`, `.cycling`, etc., mode is `.activity`.

For testability, extract the metadata-parsing logic into a pure function:
```swift
static func parseFernletMetadata(_ metadata: [String: Any]?) -> (muscleGroups: Set<MuscleGroup>, exercises: String, notes: String, effort: Int?, plannedWorkoutID: UUID?)
```
and test that directly without needing an HKWorkout.

Add to `MoveRefactorTests.swift`:
- `@Test func parseFernletMetadataHandlesMissingKeys()` — passing nil returns empty defaults.
- `@Test func parseFernletMetadataParsesAllKeysWhenPresent()` — full dictionary parses to expected values.
- `@Test func parseFernletMetadataSkipsUnknownMuscleGroups()` — "chest,unknownGroup,triceps" parses to {chest, triceps}.
```

---

## Prompt M2.4 — Wire `FernletStore.addWorkout` to HealthKit save + 30-day backfill on first auth

**Depends on:** M2.2, M2.3
**Files to modify:** `Fernlet/Fernlet/FernletStore.swift`, `Fernlet/Fernlet/HealthKitService.swift`
**Files to create:** none

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §6.3 and §8.3 of `move-refactor-and-trainer-integration-plan.md`.

1. In `FernletStore.swift`, after `addWorkout(_:date:)` mutates state and persists locally, dispatch an async HealthKit save if the user has authorized `.workoutLogging`:

```swift
func addWorkout(_ workout: Workout, date: String) {
    assert(!date.isEmpty, "workout date required")
    batchSnapshotPersistence {
        if date == todayKey {
            day.workouts.append(workout)
        } else {
            mutatePastDay(date) { $0.workouts.append(workout) }
        }
        invalidateDaySummary(for: date)
    }
    Task { [weak self] in
        await self?.saveWorkoutToHealthIfAuthorized(workout, date: date)
    }
}

private func saveWorkoutToHealthIfAuthorized(_ workout: Workout, date: String) async {
    let service = HealthKitService()  // adapt to existing access pattern
    let snapshot = service.currentAuthorizationSnapshot()
    guard snapshot.status(for: "workoutLogging") == .sharingAuthorized else { return }
    do {
        let hkUUID = try await service.saveWorkout(workout)
        await MainActor.run {
            updateWorkoutHealthKitUUID(workoutID: workout.id, hkUUID: hkUUID, date: date)
        }
    } catch {
        // Log to audit; do not surface
    }
}

private func updateWorkoutHealthKitUUID(workoutID: UUID, hkUUID: UUID, date: String) {
    batchSnapshotPersistence {
        if date == todayKey {
            if let idx = day.workouts.firstIndex(where: { $0.id == workoutID }) {
                day.workouts[idx].healthKitUUID = hkUUID
            }
        } else {
            mutatePastDay(date) { dayRef in
                if let idx = dayRef.workouts.firstIndex(where: { $0.id == workoutID }) {
                    dayRef.workouts[idx].healthKitUUID = hkUUID
                }
            }
        }
    }
}
```

2. Add a first-auth backfill in `HealthKitService`:

```swift
func backfillWorkoutsFromHealth(referenceDate: Date = .now) async throws -> [HKWorkout] {
    let thirtyDaysAgo = Calendar.current.date(byAdding: .day, value: -30, to: referenceDate) ?? referenceDate
    return try await recentWorkouts(since: thirtyDaysAgo)
}
```

3. In `LaunchPreparationService.swift` (or wherever startup tasks run), add a one-shot backfill that runs on the first launch after `.workoutLogging` is granted. Persist a flag `"fernlet.healthkit.workoutBackfillCompleted"` in UserDefaults so it does not re-run.

Tests in `HealthKitWorkoutTests.swift`:
- `@Test func backfillWindowIs30Days()` — extract the date arithmetic into a pure helper and test it returns `referenceDate - 30 days`.
- `@Test func backfillFlagIsPersistedAfterFirstRun()` — set the flag, assert subsequent calls return early.

Tests in `FernletTests.swift` (existing file):
- `@Test func addWorkoutDispatchesHealthKitSaveTask()` — using a mock `HealthKitServicing`, assert `saveWorkout` is invoked exactly once when adding a workout with the capability authorized, and zero times when not authorized.
- `@Test func addWorkoutPersistsHealthKitUUIDOnSuccess()` — given a mock service that returns a known UUID, assert the workout's `healthKitUUID` is populated after the async save.

Note: to make these tests deterministic, you may need to inject the service into FernletStore via init. If the store currently constructs `HealthKitService()` inline, extract it to an optional init parameter `healthKitService: HealthKitServicing? = nil` defaulting to `HealthKitService()`.
```

---

# Phase M3 — Deprecated-field cleanup

## Prompt M3.1 — Remove all focus-tag fields, types, and store methods

**Depends on:** M1 and M2 fully shipped and any old prototype-saved JSON has migrated through at least one app session.
**Files to modify:** `Fernlet/Fernlet/Models.swift`, `Fernlet/Fernlet/FernletStore.swift`, `Fernlet/Fernlet/MoveView.swift` (if any straggler references remain)
**Files to create:** none

```prompt
You are working in the Fernlet iOS SwiftUI project. This prompt removes the deprecated focus-tag surface entirely. Only run this after M2 has been in TestFlight for at least one release.

1. In `Models.swift`:
   - Delete `Workout.focusTag` and `Workout.focusColorName` properties.
   - Update `Workout.init(from:)` to NOT decode them, but to skip them silently if present in old JSON (Codable does this by default if the keys are absent from `CodingKeys`).
   - Update `Workout`'s designated initializer signature: drop the `focusTag` and `focusColorName` parameters.
   - Delete the `WorkoutFocusTag` struct entirely.
   - Delete the `WorkoutTagColor` enum if it has no other references (search; it may be used elsewhere — keep it if so).
   - In `FernletSettings`, delete the `workoutFocusTags` stored property AND remove its decode in `init(from:)`. New `FernletSettings` decoders silently drop any old `workoutFocusTags` key.

2. In `FernletStore.swift`:
   - Delete `setWorkoutFocusTags(_:)`.

3. Search the project for any remaining references to `focusTag`, `focusColorName`, `workoutFocusTags`, `WorkoutFocusTag`. Fix or delete each.

4. Update existing tests that reference these fields. Most test assertions that construct `Workout(...)` without focus-tag params will now compile unchanged. Any test that explicitly tests focus tags should be deleted.

Add a new test in `MoveRefactorTests.swift`:

- `@Test func legacyJSONWithFocusTagsStillDecodes()` — given a literal JSON string for a `Workout` containing `"focusTag":"push","focusColorName":"moss"` keys (plus the modern required keys), decoding succeeds and the modern fields populate correctly. The old keys are silently dropped.
- `@Test func legacySettingsJSONWithFocusTagsStillDecodes()` — given a literal JSON string for `FernletSettings` containing `"workoutFocusTags":[{"id":"push","name":"Push","color":"moss"}]`, decoding succeeds and produces a valid `FernletSettings` instance (the workoutFocusTags key is silently dropped).

Verify the existing `addWorkout` and related code in `MoveView.swift`'s save action no longer passes `focusTag:` or `focusColorName:` arguments.
```

---

# Phase M4 — Trainer plan data model

## Prompt M4.1 — Add `PlannedWorkout`, `PlannedExercise`, `TrainerProfile`, `TrainerPlan` types

**Depends on:** M1
**Files to modify:** none
**Files to create:** `Fernlet/Fernlet/TrainerPlan.swift`, `Fernlet/FernletTests/TrainerPlanTests.swift`

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §7.2 of `move-refactor-and-trainer-integration-plan.md` and §I of `apple-fitness-and-healthkit-research.md`.

Create `Fernlet/Fernlet/TrainerPlan.swift` containing:

```swift
import Foundation

struct PlannedSet: Identifiable, Codable, Equatable {
    var id = UUID()
    var orderIndex: Int
    var targetReps: Int?
    var targetRepRange: ClosedRange<Int>?    // e.g., 8...12 for "8-12 reps"
    var targetWeightLb: Double?              // store all weights as pounds internally
    var targetRPE: Int?
    var targetTempo: String?                 // "3-1-1-0" notation, free-form
    var targetRestSeconds: Int?
    var setType: PlannedSetType = .working
    var notes: String = ""

    init(orderIndex: Int, targetReps: Int? = nil, targetRepRange: ClosedRange<Int>? = nil,
         targetWeightLb: Double? = nil, targetRPE: Int? = nil, targetTempo: String? = nil,
         targetRestSeconds: Int? = nil, setType: PlannedSetType = .working, notes: String = "") {
        self.orderIndex = orderIndex
        self.targetReps = targetReps
        self.targetRepRange = targetRepRange
        self.targetWeightLb = targetWeightLb
        self.targetRPE = targetRPE
        self.targetTempo = targetTempo
        self.targetRestSeconds = targetRestSeconds
        self.setType = setType
        self.notes = notes
    }
}

enum PlannedSetType: String, Codable, CaseIterable {
    case warmup, working, dropSet, amrap, backoff
}

// ClosedRange<Int> Codable conformance helper since the stdlib doesn't synthesize it
extension ClosedRange where Bound == Int {
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let lo = try c.decode(Int.self)
        let hi = try c.decode(Int.self)
        self = lo...hi
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(lowerBound)
        try c.encode(upperBound)
    }
}

struct PlannedExercise: Identifiable, Codable, Equatable {
    var id = UUID()
    var orderIndex: Int
    var exerciseName: String                 // matches a WorkoutExerciseCatalog entry
    var primaryMuscles: Set<MuscleGroup>     // denormalized for offline lookup
    var sets: [PlannedSet]
    var notes: String = ""

    init(orderIndex: Int, exerciseName: String, primaryMuscles: Set<MuscleGroup> = [], sets: [PlannedSet], notes: String = "") {
        self.orderIndex = orderIndex
        self.exerciseName = exerciseName
        self.primaryMuscles = primaryMuscles
        self.sets = sets
        self.notes = notes
    }
}

enum PlannedWorkoutStatus: String, Codable {
    case scheduled
    case inProgress
    case completed
    case skipped
    case superseded   // user picked a different trainer's workout for this day
}

struct PlannedWorkout: Identifiable, Codable, Equatable {
    var id = UUID()
    var trainerProfileID: UUID
    var planID: UUID
    var scheduledDate: String                // FernletDate.dayKey
    var name: String
    var notes: String = ""
    var mode: WorkoutMode
    var activityType: WorkoutActivityType?
    var plannedExercises: [PlannedExercise] = []
    var targetDurationMinutes: Int?
    var targetEffort: Int?
    var createdAt = Date()
    var modifiedAt = Date()
    var status: PlannedWorkoutStatus = .scheduled
    var resultingWorkoutID: UUID?            // the Workout.id the user logged from this plan
}

struct TrainerProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var trainerPublicKey: Data               // Ed25519 raw key bytes
    var displayName: String
    var organization: String?
    var addedAt = Date()
    var lastSeenAt: Date?
    var isRevoked: Bool = false
}

struct TrainerPlan: Identifiable, Codable, Equatable {
    var id = UUID()
    var trainerProfileID: UUID
    var title: String
    var startDate: String                    // FernletDate.dayKey
    var endDate: String
    var workouts: [PlannedWorkout]
    var receivedAt = Date()
    var schemaVersion: Int = 1
}
```

Create `FernletTests/TrainerPlanTests.swift`:

- `@Test func plannedSetCodableRoundTrip()` — all set types, with and without optional fields.
- `@Test func plannedSetRepRangeRoundTrips()` — set with `targetRepRange = 8...12` survives encode/decode.
- `@Test func plannedExerciseCodableRoundTrip()` — encode/decode with nested sets.
- `@Test func plannedWorkoutCodableRoundTrip()` — full tree.
- `@Test func trainerProfileRoundTripsWithRevokedFlag()` — assert isRevoked default is false, can be flipped.
- `@Test func trainerPlanCodableRoundTrip()` — encode a plan with 3 PlannedWorkouts, each with 4 PlannedExercises, each with 3 PlannedSets; verify the tree round-trips identically.
- `@Test func plannedWorkoutStatusAllCasesAreEncodable()`.

Update `FileIndex.md` for both new files.
```

---

## Prompt M4.2 — Extend repository to persist `TrainerProfile` and `TrainerPlan`

**Depends on:** M4.1
**Files to modify:** `Fernlet/Fernlet/LocalFernletRepository.swift`, `Fernlet/Fernlet/CoreDataFernletRepository.swift`, `Fernlet/Fernlet/FernletStore.swift`
**Files to create:** none

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §7.3 of `move-refactor-and-trainer-integration-plan.md`.

Add to `LocalFernletRepository.swift`:

1. Add to `FernletSnapshot`:
   ```swift
   var trainerProfiles: [TrainerProfile] = []
   var trainerPlans: [TrainerPlan] = []
   ```
   Update the decoder to `decodeIfPresent` with `[]` defaults.

2. Add a derived database-records table `plannedWorkouts: [PlannedWorkoutRecord]` for efficient lookup by `scheduledDate`. Schema:
   ```swift
   struct PlannedWorkoutRecord: Codable, Equatable {
       var plannedWorkoutID: UUID
       var trainerProfileID: UUID
       var planID: UUID
       var scheduledDate: String
       var status: PlannedWorkoutStatus
   }
   ```
   Rebuild this table whenever any TrainerPlan or PlannedWorkout changes.

3. Add to `CoreDataFernletRepository.swift`: mirror the schema (new managed-object types `CDTrainerProfile`, `CDTrainerPlan`, `CDPlannedWorkoutRecord`). Provide migration via lightweight Core Data migration.

Extend `FernletStore` with:

```swift
@Published var trainerProfiles: [TrainerProfile] = []
@Published var trainerPlans: [TrainerPlan] = []

func addTrainerPlan(_ plan: TrainerPlan) {
    batchSnapshotPersistence {
        // Insert profile if new
        if !trainerProfiles.contains(where: { $0.id == plan.trainerProfileID }) {
            // Profile is added separately via acceptTrainer(_:); this is a no-op precondition check
            assertionFailure("Trainer profile must exist before adding a plan")
            return
        }
        if let idx = trainerPlans.firstIndex(where: { $0.id == plan.id }) {
            trainerPlans[idx] = plan
        } else {
            trainerPlans.append(plan)
        }
    }
}

func acceptTrainer(_ profile: TrainerProfile) {
    batchSnapshotPersistence {
        if let idx = trainerProfiles.firstIndex(where: { $0.id == profile.id }) {
            trainerProfiles[idx] = profile
        } else {
            trainerProfiles.append(profile)
        }
    }
}

func revokeTrainer(_ profileID: UUID) {
    batchSnapshotPersistence {
        if let idx = trainerProfiles.firstIndex(where: { $0.id == profileID }) {
            trainerProfiles[idx].isRevoked = true
        }
        // Remove all plans from this trainer
        trainerPlans.removeAll { $0.trainerProfileID == profileID }
    }
}

func plannedWorkouts(for dayKey: String) -> [(plan: TrainerPlan, workout: PlannedWorkout)] {
    var result: [(TrainerPlan, PlannedWorkout)] = []
    for plan in trainerPlans {
        for workout in plan.workouts where workout.scheduledDate == dayKey && workout.status != .superseded {
            // Skip if the trainer was revoked
            guard let profile = trainerProfiles.first(where: { $0.id == workout.trainerProfileID }), !profile.isRevoked else { continue }
            result.append((plan, workout))
        }
    }
    return result
}
```

Tests in `TrainerPlanTests.swift`:

- `@Test func snapshotRoundTripsTrainerData()` — encode a FernletSnapshot with trainer profiles and plans, decode, assert equality.
- `@Test func legacySnapshotWithoutTrainerKeysStillDecodes()` — old JSON without these keys decodes with empty arrays.
- `@Test func acceptTrainerAddsProfile()` — store starts empty, accept a profile, assert in store.
- `@Test func revokeTrainerRemovesAllTheirPlans()` — accept profile, add 2 plans from that trainer + 1 from another, revoke, assert only the other trainer's plan remains.
- `@Test func plannedWorkoutsForDayKeyExcludesRevokedTrainers()` — accept 2 trainers, add overlapping plans, revoke one, assert only the live trainer's plan returns.
- `@Test func plannedWorkoutsForDayKeyExcludesSuperseded()` — add a plan, mark its workout status to .superseded, assert it is not returned.
```

---

## Prompt M4.3 — Trainer plan card in MoveView "Today's movement" section

**Depends on:** M4.2
**Files to modify:** `Fernlet/Fernlet/MoveView.swift`
**Files to create:** none

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §7.6 of `move-refactor-and-trainer-integration-plan.md`.

In `MoveView.swift`, above the "Today's movement" `FernletScrollSection`, add a new conditional section that renders any planned workouts scheduled for today.

```swift
private var todaysPlannedWorkouts: [(plan: TrainerPlan, workout: PlannedWorkout)] {
    store.plannedWorkouts(for: store.todayKey)
}

// In body, before the "Today's movement" section:
if !todaysPlannedWorkouts.isEmpty {
    FernletScrollSection("Today's plans") {
        ForEach(Array(todaysPlannedWorkouts.enumerated()), id: \.offset) { _, item in
            PlannedWorkoutCard(
                plan: item.plan,
                workout: item.workout,
                trainerName: trainerName(for: item.plan),
                onStart: { startPlannedWorkout(item.workout) },
                onSkip: { skipPlannedWorkout(item.workout) }
            )
        }
    }
}
```

Create the `PlannedWorkoutCard` view inside `MoveView.swift` (or a new file `PlannedWorkoutCard.swift` if it grows large):

```swift
struct PlannedWorkoutCard: View {
    let plan: TrainerPlan
    let workout: PlannedWorkout
    let trainerName: String
    let onStart: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.circle.fill")
                    .foregroundStyle(Color.moss)
                Text("From \(trainerName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.slate)
                Spacer()
                if let duration = workout.targetDurationMinutes {
                    Text("\(duration) min").font(.caption).foregroundStyle(Color.slate)
                }
            }
            Text(workout.name).font(.headline)
            // Brief summary: count of exercises / activity name
            // Action row: "Start" primary, "Skip" secondary
            HStack {
                Button("Start", action: onStart).buttonStyle(...)
                Button("Skip", action: onSkip).buttonStyle(...)
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }
}
```

`startPlannedWorkout(_:)` opens the WorkoutSheet pre-populated with the planned data. Add a new init or `sheet(item:)` path for this case.

`skipPlannedWorkout(_:)` updates the workout's status to `.skipped` via a new store method:

```swift
// In FernletStore
func updatePlannedWorkoutStatus(_ plannedWorkoutID: UUID, to status: PlannedWorkoutStatus) {
    batchSnapshotPersistence {
        for planIdx in trainerPlans.indices {
            if let wIdx = trainerPlans[planIdx].workouts.firstIndex(where: { $0.id == plannedWorkoutID }) {
                trainerPlans[planIdx].workouts[wIdx].status = status
                trainerPlans[planIdx].workouts[wIdx].modifiedAt = Date()
                return
            }
        }
    }
}
```

Tests in `TrainerPlanTests.swift`:
- `@Test func updatePlannedWorkoutStatusFlipsStatus()` — add a plan, flip status to .skipped, assert it's reflected.

UI test in `FernletUITests`:
- `func testPlannedWorkoutCardAppearsForToday()` — preload the test fixture with a planned workout for today, open Move tab, assert the card renders with the trainer name.
```

---

## Prompt M4.4 — Pre-fill `WorkoutSheet` from a `PlannedWorkout`

**Depends on:** M4.3
**Files to modify:** `Fernlet/Fernlet/MoveView.swift`
**Files to create:** none

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §7.6 of `move-refactor-and-trainer-integration-plan.md`.

Add a new path into `WorkoutSheet` that pre-fills from a `PlannedWorkout`:

```swift
struct WorkoutSheet: View {
    // ... existing properties
    var plannedWorkout: PlannedWorkout?

    // In init or .onAppear, populate state from plannedWorkout:
    // - name = plannedWorkout.name
    // - notes = plannedWorkout.notes
    // - logMode = plannedWorkout.mode
    // - For .activity: selectedActivityType = plannedWorkout.activityType
    // - For .activity: duration = plannedWorkout.targetDurationMinutes?.description ?? ""
    // - For .strengthTraining: exerciseRows = plannedWorkout.plannedExercises.map { planned -> WorkoutExerciseEntry in
    //       let exercise = WorkoutExerciseCatalog.baseExercises.first(where: { $0.name == planned.exerciseName }) ?? <fallback construct>
    //       return WorkoutExerciseEntry(exercise: exercise, sets: ..., reps: ..., weight: ...)
    //   }
}
```

When the user saves, write the resulting `Workout` AND mark the plan's status:

```swift
// In the save closure:
var workout = Workout(...)
workout.plannedWorkoutID = plannedWorkout?.id
store.addWorkout(workout, date: targetDateKey)
if let plannedWorkout {
    store.linkLoggedWorkout(workoutID: workout.id, to: plannedWorkout.id)
}
```

In `FernletStore`:

```swift
func linkLoggedWorkout(workoutID: UUID, to plannedWorkoutID: UUID) {
    batchSnapshotPersistence {
        for planIdx in trainerPlans.indices {
            if let wIdx = trainerPlans[planIdx].workouts.firstIndex(where: { $0.id == plannedWorkoutID }) {
                trainerPlans[planIdx].workouts[wIdx].resultingWorkoutID = workoutID
                trainerPlans[planIdx].workouts[wIdx].status = .completed
                trainerPlans[planIdx].workouts[wIdx].modifiedAt = Date()
                return
            }
        }
    }
}
```

Tests in `TrainerPlanTests.swift`:
- `@Test func linkLoggedWorkoutSetsResultingIDAndCompletedStatus()`.
- `@Test func plannedWorkoutToExerciseRowsMapsKnownExercises()` — given a PlannedWorkout with a known exercise name from the catalog, the resulting WorkoutExerciseEntry has the correct ExerciseTarget.
- `@Test func plannedWorkoutToExerciseRowsHandlesUnknownExerciseNames()` — given an exercise name not in the catalog, the conversion falls back to a synthesized ExerciseTarget with the planned name and the planned primaryMuscles (this is why PlannedExercise has its own primaryMuscles field).

UI test:
- `func testStartPlannedWorkoutPrefillsSheet()` — tap "Start" on a planned workout card, assert the sheet opens with the planned exercise rows visible.
```

---

# Phase M5 — Diff engine + multi-trainer plan selection

## Prompt M5.1 — `SetDiff` and `WorkoutDiff` engine

**Depends on:** M4.1
**Files to modify:** none
**Files to create:** `Fernlet/Fernlet/WorkoutDiff.swift`, `Fernlet/FernletTests/WorkoutDiffTests.swift`

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §I of `apple-fitness-and-healthkit-research.md`.

Create `Fernlet/Fernlet/WorkoutDiff.swift`:

```swift
import Foundation

/// A logged set as captured during a workout. Mirror of PlannedSet's actuals.
struct LoggedSet: Identifiable, Codable, Equatable {
    var id = UUID()
    var plannedSetID: UUID?              // nil = bonus set
    var orderIndex: Int
    var actualReps: Int
    var actualWeightLb: Double?
    var actualRPE: Int?
    var completedAt = Date()
}

enum SetDiff: Equatable {
    case matchesPlan
    case shortReps(by: Int)
    case extraReps(by: Int)
    case lighterWeight(byLb: Double)
    case heavierWeight(byLb: Double)
    case bonus                            // plannedSetID == nil
    case missed                           // planned set never logged
}

struct WorkoutDiff {
    /// Row in a diff table: optionally references a planned set, optionally references a logged set, and carries the diff verdict.
    struct Row: Equatable {
        let planned: PlannedSet?
        let logged: LoggedSet?
        let diff: SetDiff
    }

    /// Per-exercise diff. The rows are sorted by orderIndex (plan first, then bonus sets).
    struct ExerciseDiff: Equatable {
        let plannedExercise: PlannedExercise?
        let exerciseName: String
        let rows: [Row]
        var completedSetCount: Int { rows.filter { $0.logged != nil }.count }
        var plannedSetCount: Int { plannedExercise?.sets.count ?? 0 }
    }

    static func diff(plannedSets: [PlannedSet], loggedSets: [LoggedSet]) -> [Row] {
        var rows: [Row] = []
        var loggedByPlannedID = [UUID: LoggedSet]()
        var bonusLogs: [LoggedSet] = []
        for log in loggedSets {
            if let pid = log.plannedSetID {
                loggedByPlannedID[pid] = log
            } else {
                bonusLogs.append(log)
            }
        }
        // For each planned set, find a matching logged set
        for planned in plannedSets.sorted(by: { $0.orderIndex < $1.orderIndex }) {
            if let log = loggedByPlannedID[planned.id] {
                rows.append(Row(planned: planned, logged: log, diff: diffSet(planned: planned, logged: log)))
            } else {
                rows.append(Row(planned: planned, logged: nil, diff: .missed))
            }
        }
        // Append bonus sets at the end
        for bonus in bonusLogs.sorted(by: { $0.orderIndex < $1.orderIndex }) {
            rows.append(Row(planned: nil, logged: bonus, diff: .bonus))
        }
        return rows
    }

    static func diffSet(planned: PlannedSet, logged: LoggedSet) -> SetDiff {
        // 1. Reps comparison
        let targetReps: Int? = planned.targetReps ?? planned.targetRepRange?.upperBound
        if let tr = targetReps {
            if logged.actualReps < tr {
                let lower = planned.targetRepRange?.lowerBound ?? tr
                // Inside range = match
                if logged.actualReps >= lower {
                    // fall through to weight check
                } else {
                    return .shortReps(by: tr - logged.actualReps)
                }
            } else if logged.actualReps > tr {
                return .extraReps(by: logged.actualReps - tr)
            }
        }
        // 2. Weight comparison
        if let tw = planned.targetWeightLb, let aw = logged.actualWeightLb {
            let delta = aw - tw
            if abs(delta) < 0.5 { return .matchesPlan }
            if delta < 0 { return .lighterWeight(byLb: -delta) }
            return .heavierWeight(byLb: delta)
        }
        return .matchesPlan
    }
}
```

Create `FernletTests/WorkoutDiffTests.swift`:

- `@Test func diffSetMatchesWhenIdenticalReps()` — planned 8 reps, logged 8 reps, same weight: `.matchesPlan`.
- `@Test func diffSetShortRepsWhenBelowRange()` — planned 8-12 reps, logged 6 reps: `.shortReps(by: 6)`.
- `@Test func diffSetMatchesWhenWithinRange()` — planned 8-12 reps, logged 10 reps: `.matchesPlan`.
- `@Test func diffSetExtraReps()` — planned 8 reps, logged 12 reps: `.extraReps(by: 4)`.
- `@Test func diffSetLighterWeight()` — planned 135 lb, logged 125 lb, same reps: `.lighterWeight(byLb: 10)`.
- `@Test func diffSetHeavierWeight()` — planned 135 lb, logged 145 lb, same reps: `.heavierWeight(byLb: 10)`.
- `@Test func diffSetIgnoresWeightWhenUnspecified()` — planned has no targetWeight, logged has weight: `.matchesPlan` if reps match.
- `@Test func diffRowsOrderPlannedFirstThenBonus()` — 3 planned (logged), 2 bonus → 5 rows, first 3 are .matchesPlan, last 2 are .bonus.
- `@Test func diffRowsIncludesMissedForUnloggedPlannedSet()` — 4 planned, 3 logged → 4 rows, the unmatched planned set has `.missed`.
- `@Test func diffRowsRespectOrderIndex()` — sets logged out of order are sorted by orderIndex in output.
- `@Test func diffRowsCompletedSetCountCountsOnlyLoggedRows()` — given 3 planned + 1 bonus = 4 rows, with 2 planned logged and 1 bonus, completedSetCount == 3.

Update `FileIndex.md` for both files.
```

---

## Prompt M5.2 — Diff visualization view

**Depends on:** M5.1
**Files to modify:** none
**Files to create:** `Fernlet/Fernlet/WorkoutDiffView.swift`

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §I of `apple-fitness-and-healthkit-research.md` for the visual conventions.

Create `Fernlet/Fernlet/WorkoutDiffView.swift`:

```swift
import SwiftUI

struct WorkoutDiffView: View {
    let plannedExercises: [PlannedExercise]
    let loggedExercises: [(exerciseName: String, sets: [LoggedSet])]

    private var exerciseDiffs: [WorkoutDiff.ExerciseDiff] { /* compute per-exercise */ }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(exerciseDiffs.enumerated()), id: \.offset) { _, exDiff in
                ExerciseDiffCard(diff: exDiff)
            }
        }
    }
}

struct ExerciseDiffCard: View {
    let diff: WorkoutDiff.ExerciseDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(diff.exerciseName).font(.headline)
                Spacer()
                if diff.plannedSetCount > 0 {
                    Text("\(diff.completedSetCount)/\(diff.plannedSetCount) sets")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.slate)
                }
            }
            ForEach(Array(diff.rows.enumerated()), id: \.offset) { idx, row in
                DiffRow(row: row, index: idx)
            }
        }
        .padding(12)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct DiffRow: View {
    let row: WorkoutDiff.Row
    let index: Int

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(setSummary).font(.callout)
                if let detail = diffDetail { Text(detail).font(.caption).foregroundStyle(diffColor) }
            }
            Spacer()
        }
    }

    private var statusIcon: some View {
        switch row.diff {
        case .matchesPlan: return Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.moss).eraseToAny()
        case .shortReps, .lighterWeight: return Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.goldenrod).eraseToAny()
        case .extraReps, .heavierWeight: return Image(systemName: "arrow.up.circle.fill").foregroundStyle(Color.terracotta).eraseToAny()
        case .bonus: return Image(systemName: "plus.circle.fill").foregroundStyle(Color.slate).eraseToAny()
        case .missed: return Image(systemName: "circle.dotted").foregroundStyle(Color.slate.opacity(0.5)).eraseToAny()
        }
    }

    private var setSummary: String {
        if let logged = row.logged {
            let weight = logged.actualWeightLb.map { "\(Int($0)) lb × " } ?? ""
            return "Set \(index + 1)   \(weight)\(logged.actualReps)"
        }
        if let planned = row.planned {
            let weight = planned.targetWeightLb.map { "\(Int($0)) lb × " } ?? ""
            let reps = planned.targetReps.map(String.init) ?? planned.targetRepRange.map { "\($0.lowerBound)-\($0.upperBound)" } ?? ""
            return "Set \(index + 1)   \(weight)\(reps) (planned)"
        }
        return "Set \(index + 1)"
    }

    private var diffDetail: String? {
        switch row.diff {
        case .matchesPlan: return nil
        case .shortReps(let by): return "↓\(by) reps vs plan"
        case .extraReps(let by): return "↑\(by) reps vs plan"
        case .lighterWeight(let byLb): return "↓\(Int(byLb)) lb vs plan"
        case .heavierWeight(let byLb): return "↑\(Int(byLb)) lb vs plan"
        case .bonus: return "bonus set"
        case .missed: return "not completed"
        }
    }

    private var diffColor: Color {
        switch row.diff {
        case .matchesPlan: return Color.moss
        case .shortReps, .lighterWeight: return Color.goldenrod
        case .extraReps, .heavierWeight: return Color.terracotta
        case .bonus: return Color.slate
        case .missed: return Color.slate.opacity(0.7)
        }
    }
}
```

Add a small view helper `extension View { func eraseToAny() -> AnyView { AnyView(self) } }` if not already present.

Tests in `WorkoutDiffTests.swift`:
- Snapshot or rendering tests are out of scope; instead, add data-driven tests that the supporting computed strings (`setSummary`, `diffDetail`) return expected values for representative diff rows. Extract those into static helpers if needed for testability.

Update `FileIndex.md`.
```

---

## Prompt M5.3 — Multi-trainer plan selection: "Pick the workout I'll do today"

**Depends on:** M4.3, M5.1
**Files to modify:** `Fernlet/Fernlet/MoveView.swift`, `Fernlet/Fernlet/FernletStore.swift`
**Files to create:** `Fernlet/Fernlet/TrainerPlanPickerSheet.swift`

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §7 (points 6–7) of the follow-up requirements: "the user should be able to elect which trainer's workout to do. Ties into the diff, the other trainers can see the diff and what was done instead."

When multiple trainers have scheduled a workout for the same day, render them as stacked cards (M4.3 already does this) but add a "Pick one" affordance that lets the user elect a primary workout for the day:

1. Add to `FernletStore`:
```swift
func elect(plannedWorkoutID: UUID, forDay dayKey: String) {
    batchSnapshotPersistence {
        // Mark all other planned workouts for this day as .superseded
        for planIdx in trainerPlans.indices {
            for wIdx in trainerPlans[planIdx].workouts.indices {
                let w = trainerPlans[planIdx].workouts[wIdx]
                guard w.scheduledDate == dayKey else { continue }
                if w.id == plannedWorkoutID {
                    trainerPlans[planIdx].workouts[wIdx].status = .scheduled
                    trainerPlans[planIdx].workouts[wIdx].modifiedAt = Date()
                } else if w.status == .scheduled {
                    trainerPlans[planIdx].workouts[wIdx].status = .superseded
                    trainerPlans[planIdx].workouts[wIdx].modifiedAt = Date()
                }
            }
        }
    }
}

func unelect(forDay dayKey: String) {
    // Restore all .superseded workouts for this day to .scheduled
    batchSnapshotPersistence {
        for planIdx in trainerPlans.indices {
            for wIdx in trainerPlans[planIdx].workouts.indices where trainerPlans[planIdx].workouts[wIdx].scheduledDate == dayKey {
                if trainerPlans[planIdx].workouts[wIdx].status == .superseded {
                    trainerPlans[planIdx].workouts[wIdx].status = .scheduled
                    trainerPlans[planIdx].workouts[wIdx].modifiedAt = Date()
                }
            }
        }
    }
}
```

Note: `plannedWorkouts(for:)` already excludes `.superseded` from the returned list (M4.2 contract). So once the user picks one, only the elected card shows. The other trainers' workouts remain in their plans (so they can be re-elected later) and the completion feedback to those other trainers will include a "superseded by X" note.

2. In `MoveView.swift`, when `todaysPlannedWorkouts.count > 1` (which is computed BEFORE filtering out .superseded — add a `store.allPlannedWorkouts(for:)` that returns including superseded for this UI), show a sheet trigger above the cards:

```swift
if store.allPlannedWorkouts(for: store.todayKey).count > 1 && store.electedPlannedWorkoutID(forDay: store.todayKey) == nil {
    Button("\(store.allPlannedWorkouts(for: store.todayKey).count) workouts scheduled — pick one") {
        showTrainerPicker = true
    }
}
```

3. Create `Fernlet/Fernlet/TrainerPlanPickerSheet.swift`:

```swift
import SwiftUI

struct TrainerPlanPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: FernletStore
    let dayKey: String

    private var allWorkouts: [(plan: TrainerPlan, workout: PlannedWorkout, trainer: TrainerProfile)] {
        // Compute all planned workouts including .superseded for this day, with their trainer profile
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Pick today's workout")
                        .font(.system(size: 26, weight: .bold, design: .serif))
                    Text("You have plans from \(uniqueTrainerCount) trainers. Pick one to do today. The others will be marked as superseded and the trainers will see what you did instead.")
                        .font(.callout)
                        .foregroundStyle(Color.slate)

                    ForEach(allWorkouts, id: \.workout.id) { item in
                        Button {
                            store.elect(plannedWorkoutID: item.workout.id, forDay: dayKey)
                            dismiss()
                        } label: {
                            TrainerPlanCardRow(workout: item.workout, trainer: item.trainer)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
        }
    }
}
```

4. Add `FernletStore.electedPlannedWorkoutID(forDay:)` — returns the ID of the .scheduled workout if exactly one .scheduled exists alongside one or more .superseded for the same day.

5. Add `FernletStore.allPlannedWorkouts(for:)` — like `plannedWorkouts(for:)` but includes .superseded.

6. Update `FernletSheet` enum (in `FernletUIComponents.swift`) to add `case trainerPlanPicker(dayKey: String)`. Wire it through `ContentView.sheetContent(for:)`.

Tests in `TrainerPlanTests.swift`:
- `@Test func electMarksOthersAsSuperseded()` — accept 2 trainer profiles, add 2 plans (one each) for today, elect the first; assert the second is .superseded and the first remains .scheduled.
- `@Test func unelectRestoresSuperseded()` — after elect, unelect; assert both are back to .scheduled.
- `@Test func plannedWorkoutsForExcludesSuperseded()` — covered in M4.2 but re-verify with elect/unelect.
- `@Test func allPlannedWorkoutsForIncludesSuperseded()` — new method must include superseded for the picker UI.
- `@Test func electedPlannedWorkoutIDReturnsIDWhenExactlyOneScheduled()` — given 1 scheduled + 1 superseded, returns the scheduled ID.
- `@Test func electedPlannedWorkoutIDReturnsNilWhenMultipleScheduled()` — given 2 scheduled with no supersedes, returns nil (no election yet).

Update `FileIndex.md` for the new sheet file.
```

---

# Phase M6 — Proximity transport

(Phase M6 is gated on Phase 7 of `ImplementationPlan.md` landing. The prompts below are written assuming the proximity primitives — Ed25519 identity, signed packets, MCSession, NISession — are in place.)

## Prompt M6.1 — Register `.fernlettrainerplan` UTType + AirDrop receive

**Depends on:** M4.1, Phase 7 envelope spec
**Files to modify:** `Fernlet/Fernlet/Info.plist`, `Fernlet/Fernlet/FernletApp.swift`
**Files to create:** `Fernlet/Fernlet/TrainerPlanEnvelope.swift`

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §7.4 and §7.5 of `move-refactor-and-trainer-integration-plan.md`. Assumes the signed envelope from `ImplementationPlan.md` Phase 7 is implemented.

1. In `Info.plist`, register the custom UTType. Add under `UTExportedTypeDeclarations`:

```xml
<dict>
    <key>UTTypeConformsTo</key>
    <array>
        <string>public.json</string>
        <string>public.data</string>
    </array>
    <key>UTTypeDescription</key>
    <string>Fernlet trainer plan</string>
    <key>UTTypeIdentifier</key>
    <string>app.fernlet.trainerplan</string>
    <key>UTTypeTagSpecification</key>
    <dict>
        <key>public.filename-extension</key>
        <array>
            <string>fernlettrainerplan</string>
        </array>
        <key>public.mime-type</key>
        <string>application/x-fernlet-trainerplan</string>
    </dict>
</dict>
```

Add under `CFBundleDocumentTypes`:

```xml
<dict>
    <key>CFBundleTypeName</key>
    <string>Fernlet trainer plan</string>
    <key>CFBundleTypeRole</key>
    <string>Viewer</string>
    <key>LSHandlerRank</key>
    <string>Owner</string>
    <key>LSItemContentTypes</key>
    <array>
        <string>app.fernlet.trainerplan</string>
    </array>
</dict>
```

2. Create `Fernlet/Fernlet/TrainerPlanEnvelope.swift`:

```swift
import Foundation
import CryptoKit

/// Wire-level envelope for trainer-to-client plan transfer.
/// Mirror of the file-sharing envelope spec from ImplementationPlan.md §Phase 7.
struct TrainerPlanEnvelope: Codable, Equatable {
    let schemaVersion: Int            // currently 1
    let senderPublicKey: Data         // Ed25519 raw bytes
    let payloadType: String           // "fernlet.trainer.plan.v1"
    let payloadSummary: PayloadSummary
    let createdAt: Date
    let expiresAt: Date?
    let signature: Data               // Ed25519 sig over (payload || createdAt || expiresAt)
    let payload: Data                 // JSON-encoded TrainerPlan; encrypted in M6.4 if recipient pubkey known

    struct PayloadSummary: Codable, Equatable {
        let title: String
        let workoutCount: Int
        let startDate: String
        let endDate: String
        let trainerName: String
    }

    enum DecodeError: Error {
        case invalidSignature
        case expired
        case unsupportedSchemaVersion
        case payloadParseFailed
    }

    func verify() throws -> TrainerPlan {
        guard schemaVersion == 1 else { throw DecodeError.unsupportedSchemaVersion }
        if let expiresAt, expiresAt < Date() { throw DecodeError.expired }

        // Verify Ed25519 signature
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: senderPublicKey) else {
            throw DecodeError.invalidSignature
        }
        let signedPayload = signedPayloadBytes()
        guard publicKey.isValidSignature(signature, for: signedPayload) else {
            throw DecodeError.invalidSignature
        }

        // Decode the TrainerPlan from payload
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let plan = try? decoder.decode(TrainerPlan.self, from: payload) else {
            throw DecodeError.payloadParseFailed
        }
        return plan
    }

    private func signedPayloadBytes() -> Data {
        var data = payload
        data.append(Data("\(createdAt.timeIntervalSince1970)".utf8))
        if let expiresAt {
            data.append(Data("\(expiresAt.timeIntervalSince1970)".utf8))
        }
        return data
    }
}
```

3. In `FernletApp.swift`, add an `.onOpenURL` handler at the root:

```swift
.onOpenURL { url in
    handleIncomingFile(url: url)
}
```

Where `handleIncomingFile(url:)` parses the file as a `TrainerPlanEnvelope`, calls `verify()`, and on success presents a confirmation sheet showing the trainer name + plan summary. On user confirm, calls `store.acceptTrainer(profile)` + `store.addTrainerPlan(plan)`.

Tests in `TrainerPlanTests.swift`:
- `@Test func envelopeRoundTripsCodable()`.
- `@Test func envelopeVerifyRejectsBadSignature()` — construct an envelope with a tampered signature, assert `verify()` throws `.invalidSignature`.
- `@Test func envelopeVerifyRejectsExpiredEnvelope()` — `expiresAt = .distantPast`, assert `verify()` throws `.expired`.
- `@Test func envelopeVerifyRejectsWrongSchemaVersion()`.
- `@Test func envelopeVerifySucceedsForValidSignature()` — generate a fresh key pair in the test, build and sign an envelope, verify, assert the returned plan matches.

Update `FileIndex.md`.
```

---

## Prompt M6.2 — NearbyInteraction + MultipeerConnectivity driver

**Depends on:** M6.1, Phase 7 NISession/MCSession primitives
**Files to modify:** none
**Files to create:** `Fernlet/Fernlet/TrainerProximityService.swift`, `Fernlet/FernletTests/TrainerProximityServiceTests.swift`

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §7.1 of `move-refactor-and-trainer-integration-plan.md` and §H of `apple-fitness-and-healthkit-research.md`.

This prompt depends on the proximity primitives from `ImplementationPlan.md` Phase 7. Assume the following are available (build stubs if not):
- `IdentityManager` — provides the device's Ed25519 keypair.
- `MCSessionManager` — wraps an MCSession with peer-id persistence.
- `NISessionManager` — wraps NearbyInteraction for ranging.

Create `Fernlet/Fernlet/TrainerProximityService.swift`:

```swift
import Foundation
import MultipeerConnectivity
import NearbyInteraction
import Combine

@MainActor
final class TrainerProximityService: ObservableObject {
    enum State: Equatable {
        case idle
        case advertising
        case discovering(rangingMeters: Double?)
        case awaitingConfirmation(peerName: String, planSummary: TrainerPlanEnvelope.PayloadSummary)
        case connected(peerName: String)
        case failed(reason: String)
    }

    @Published private(set) var state: State = .idle

    private let mcSessionManager: MCSessionManager
    private let niSessionManager: NISessionManager
    private let identity: IdentityManager
    private let store: FernletStore

    init(store: FernletStore, mcSessionManager: MCSessionManager, niSessionManager: NISessionManager, identity: IdentityManager) {
        self.store = store
        self.mcSessionManager = mcSessionManager
        self.niSessionManager = niSessionManager
        self.identity = identity
    }

    func beginPairingAsClient() async {
        state = .discovering(rangingMeters: nil)
        do {
            // 1. Start NISession ranging to confirm physical proximity (< 5 cm sustained for ≥ 1 second)
            try await niSessionManager.startRanging()
            // 2. When proximity is confirmed, start MCSession advertising/browsing
            try await mcSessionManager.startAdvertising(serviceType: "fernlet-coach")
            // 3. When a peer connects, receive their TrainerPlanEnvelope
        } catch {
            state = .failed(reason: error.localizedDescription)
        }
    }

    func cancelPairing() {
        Task {
            await mcSessionManager.disconnect()
            await niSessionManager.stopRanging()
            state = .idle
        }
    }

    /// Called by MCSession delegate when an envelope arrives.
    func didReceiveEnvelope(_ envelope: TrainerPlanEnvelope) {
        do {
            let plan = try envelope.verify()
            let trainer = TrainerProfile(
                trainerPublicKey: envelope.senderPublicKey,
                displayName: envelope.payloadSummary.trainerName
            )
            state = .awaitingConfirmation(peerName: trainer.displayName, planSummary: envelope.payloadSummary)
            pendingTrainer = trainer
            pendingPlan = plan
        } catch {
            state = .failed(reason: "Envelope verification failed: \(error)")
        }
    }

    private var pendingTrainer: TrainerProfile?
    private var pendingPlan: TrainerPlan?

    func confirmAcceptance() {
        guard let trainer = pendingTrainer, let plan = pendingPlan else { return }
        store.acceptTrainer(trainer)
        store.addTrainerPlan(plan)
        state = .connected(peerName: trainer.displayName)
        pendingTrainer = nil
        pendingPlan = nil
    }

    func rejectAcceptance() {
        pendingTrainer = nil
        pendingPlan = nil
        cancelPairing()
    }
}
```

Add the corresponding pairing UI in a new `TrainerPairingSheet.swift` (separate prompt M6.3).

Create `FernletTests/TrainerProximityServiceTests.swift`. Since MCSession and NISession can't run in unit tests, test the orchestration logic with mock managers:

- Define `MockMCSessionManager: MCSessionManaging` and `MockNISessionManager: NISessionManaging` protocols in the test file.
- `@Test func receiveValidEnvelopeTransitionsToAwaitingConfirmation()` — feed a valid envelope, assert state.
- `@Test func receiveInvalidEnvelopeTransitionsToFailed()` — feed a tampered envelope, assert .failed.
- `@Test func confirmAcceptanceAddsTrainerAndPlan()` — after .awaitingConfirmation, call confirm, assert store has the trainer profile and plan.
- `@Test func rejectAcceptanceClearsPending()`.
- `@Test func cancelPairingResetsState()`.

Update `FileIndex.md`.
```

---

## Prompt M6.3 — Pairing UI + live-session updates

**Depends on:** M6.2
**Files to modify:** `Fernlet/Fernlet/MoveView.swift`, `Fernlet/Fernlet/SettingsSheet.swift`
**Files to create:** `Fernlet/Fernlet/TrainerPairingSheet.swift`

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §7.1 of `move-refactor-and-trainer-integration-plan.md`.

Create `Fernlet/Fernlet/TrainerPairingSheet.swift`:

```swift
import SwiftUI

struct TrainerPairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject var service: TrainerProximityService

    var body: some View {
        VStack(spacing: 24) {
            switch service.state {
            case .idle, .advertising:
                pairingPrompt
            case .discovering(let meters):
                proximityPrompt(meters: meters)
            case .awaitingConfirmation(let peerName, let summary):
                confirmationCard(peerName: peerName, summary: summary)
            case .connected(let peerName):
                connectedView(peerName: peerName)
            case .failed(let reason):
                errorView(reason: reason)
            }
        }
        .padding(24)
        .background(Color.parchment)
        .task { await service.beginPairingAsClient() }
        .onDisappear { service.cancelPairing() }
    }

    private var pairingPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 56))
                .foregroundStyle(Color.moss)
            Text("Hold the tops of your phones together")
                .font(.title3.weight(.semibold))
            Text("Your trainer should be sending you a plan.")
                .font(.callout)
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
        }
    }

    private func proximityPrompt(meters: Double?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.system(size: 48))
                .foregroundStyle(Color.terracotta)
            if let meters {
                Text(meters < 0.05 ? "Hold steady…" : "Move closer (\(String(format: "%.1f", meters * 39.37)) in apart)")
            } else {
                Text("Searching…")
            }
        }
    }

    private func confirmationCard(peerName: String, summary: TrainerPlanEnvelope.PayloadSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Accept plan from \(peerName)?").font(.title3.weight(.bold))
            VStack(alignment: .leading, spacing: 6) {
                Label(summary.title, systemImage: "doc.text")
                Label("\(summary.workoutCount) workouts", systemImage: "list.bullet")
                Label("\(summary.startDate) – \(summary.endDate)", systemImage: "calendar")
            }
            .font(.callout)
            HStack {
                Button("Reject", role: .destructive) { service.rejectAcceptance(); dismiss() }
                Spacer()
                Button("Accept") { service.confirmAcceptance() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func connectedView(peerName: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(Color.moss)
            Text("Connected to \(peerName)").font(.title3.weight(.semibold))
            Text("The session will stay open while you work out so your trainer can see updates live.")
                .font(.callout)
                .foregroundStyle(Color.slate)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
        }
    }

    private func errorView(reason: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 48)).foregroundStyle(Color.terracotta)
            Text("Pairing failed").font(.headline)
            Text(reason).font(.caption).foregroundStyle(Color.slate)
            Button("Try again") { Task { await service.beginPairingAsClient() } }
        }
    }
}
```

Wire it through `FernletSheet`:
- Add `case trainerPairing` to `FernletSheet` enum in `FernletUIComponents.swift`.
- Add the routing in `ContentView.sheetContent(for:)`.

Add an entry point in `SettingsSheet.swift` `moveTab`: a row "Pair with trainer" that opens the sheet.

Tests in `TrainerProximityServiceTests.swift` (already created in M6.2): add UI tests in `FernletUITests`:
- `func testTrainerPairingSheetShowsInitialPrompt()` — open the pairing sheet, assert the "Hold the tops of your phones together" text is visible.
- `func testTrainerPairingSheetShowsConfirmationOnEnvelope()` — inject a fake envelope, assert the confirmation card renders.

Update `FileIndex.md`.
```

---

## Prompt M6.4 — Completion payload back to trainer (privacy filter)

**Depends on:** M6.3, M5.1
**Files to modify:** `Fernlet/Fernlet/TrainerProximityService.swift`
**Files to create:** `Fernlet/Fernlet/CompletionPayload.swift`

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §7.4 of `move-refactor-and-trainer-integration-plan.md`.

When the user logs a workout linked to a `PlannedWorkout`, Fernlet sends a completion summary back to the trainer (over the open MCSession or, if disconnected, queued for next pairing).

Create `Fernlet/Fernlet/CompletionPayload.swift`:

```swift
import Foundation

struct WorkoutCompletionPayload: Codable, Equatable {
    let schemaVersion: Int = 1
    let plannedWorkoutID: UUID
    let resultingWorkout: Workout
    let exerciseDiffs: [ExerciseDiffSummary]
    let userNote: String          // free text the user adds; stripped of any sensitive-tagged content
    let completedAt: Date
    let supersededByOtherTrainer: Bool   // true if the user picked a different trainer's workout

    struct ExerciseDiffSummary: Codable, Equatable {
        let exerciseName: String
        let plannedSetCount: Int
        let completedSetCount: Int
        let rows: [DiffRowSummary]
    }

    struct DiffRowSummary: Codable, Equatable {
        let plannedRepsOrRange: String?     // "8" or "8-12" or nil
        let plannedWeightLb: Double?
        let actualReps: Int?
        let actualWeightLb: Double?
        let diff: SetDiffCode
    }

    enum SetDiffCode: String, Codable {
        case match, short, extra, lighter, heavier, bonus, missed
    }
}

extension WorkoutCompletionPayload {
    /// Build a completion payload from a logged workout and its planned source.
    /// Strips any content the user has tagged as sensitive in their notes.
    static func build(loggedWorkout: Workout, plannedWorkout: PlannedWorkout, plannedExercises: [PlannedExercise], loggedSets: [(exerciseName: String, sets: [LoggedSet])], supersededByOther: Bool) -> WorkoutCompletionPayload {
        let exerciseDiffs = plannedExercises.map { planned -> ExerciseDiffSummary in
            let logged = loggedSets.first(where: { $0.exerciseName == planned.exerciseName })?.sets ?? []
            let rows = WorkoutDiff.diff(plannedSets: planned.sets, loggedSets: logged)
            let rowSummaries = rows.map { row -> DiffRowSummary in
                DiffRowSummary(
                    plannedRepsOrRange: row.planned.map { p in
                        p.targetRepRange.map { "\($0.lowerBound)-\($0.upperBound)" } ?? p.targetReps.map(String.init) ?? "—"
                    },
                    plannedWeightLb: row.planned?.targetWeightLb,
                    actualReps: row.logged?.actualReps,
                    actualWeightLb: row.logged?.actualWeightLb,
                    diff: SetDiffCode.from(row.diff)
                )
            }
            return ExerciseDiffSummary(
                exerciseName: planned.exerciseName,
                plannedSetCount: planned.sets.count,
                completedSetCount: rows.filter { $0.logged != nil }.count,
                rows: rowSummaries
            )
        }

        return WorkoutCompletionPayload(
            plannedWorkoutID: plannedWorkout.id,
            resultingWorkout: stripSensitive(loggedWorkout),
            exerciseDiffs: exerciseDiffs,
            userNote: stripSensitive(loggedWorkout.notes),
            completedAt: loggedWorkout.completedAt,
            supersededByOtherTrainer: supersededByOther
        )
    }

    private static func stripSensitive(_ workout: Workout) -> Workout {
        var copy = workout
        copy.notes = stripSensitive(copy.notes)
        return copy
    }

    private static func stripSensitive(_ note: String) -> String {
        // Strip lines that begin with [SENSITIVE], #private, or are inside <sensitive>...</sensitive> tags
        let lines = note.components(separatedBy: .newlines)
        return lines.filter { !$0.lowercased().contains("[sensitive]") && !$0.lowercased().contains("#private") }
                    .joined(separator: "\n")
    }
}

extension WorkoutCompletionPayload.SetDiffCode {
    static func from(_ diff: SetDiff) -> Self {
        switch diff {
        case .matchesPlan: return .match
        case .shortReps: return .short
        case .extraReps: return .extra
        case .lighterWeight: return .lighter
        case .heavierWeight: return .heavier
        case .bonus: return .bonus
        case .missed: return .missed
        }
    }
}
```

When `FernletStore.linkLoggedWorkout(...)` runs (M4.4), also dispatch:

```swift
func linkLoggedWorkout(workoutID: UUID, to plannedWorkoutID: UUID, loggedSets: [(exerciseName: String, sets: [LoggedSet])] = []) {
    // ... existing logic
    // After marking completed, build and send the completion payload
    Task { [weak self] in
        await self?.sendCompletionPayloadIfPossible(workoutID: workoutID, plannedWorkoutID: plannedWorkoutID, loggedSets: loggedSets)
    }
}

private func sendCompletionPayloadIfPossible(workoutID: UUID, plannedWorkoutID: UUID, loggedSets: [(exerciseName: String, sets: [LoggedSet])]) async {
    // Resolve the trainer for this planned workout
    // If MCSession is live, send immediately
    // Otherwise, queue for next pairing in a new `pendingCompletionPayloads: [WorkoutCompletionPayload]` in the snapshot
}
```

For trainers whose workouts were superseded by the user choosing another trainer's plan, also send a completion payload with `supersededByOtherTrainer: true` and a redacted view of what the user actually did (only summary, no detail). This satisfies follow-up requirement #7.

Tests in `TrainerPlanTests.swift`:
- `@Test func completionPayloadStripsSensitiveLinesFromNote()` — input "Did 8 reps\n[SENSITIVE] left ankle pain", output excludes the sensitive line.
- `@Test func completionPayloadDiffRowsMatchPlannedAndLogged()`.
- `@Test func completionPayloadSetSupersededByOtherTrainerFlag()` — given a superseded planned workout, the payload to that trainer carries supersededByOtherTrainer = true.
- `@Test func completionPayloadStripsHashPrivateLines()` — input "Did 8\n#private was nauseous", output excludes the private line.
- `@Test func completionPayloadIncludesBonusSetsInDiffs()`.

Update `FileIndex.md`.
```

---

# Phase M7 — Audit log + revoke + privacy

## Prompt M7.1 — Trainer event audit log

**Depends on:** M6
**Files to modify:** `Fernlet/Fernlet/FernletStore.swift`
**Files to create:** `Fernlet/Fernlet/TrainerAuditLog.swift`

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §7.7 of `move-refactor-and-trainer-integration-plan.md`.

Create `Fernlet/Fernlet/TrainerAuditLog.swift`:

```swift
import Foundation

struct TrainerAuditEvent: Identifiable, Codable, Equatable {
    var id = UUID()
    var timestamp = Date()
    var kind: Kind
    var trainerFingerprint: String   // first 8 hex chars of SHA-256(publicKey)
    var trainerName: String?
    var planID: UUID?
    var plannedWorkoutID: UUID?
    var details: String = ""

    enum Kind: String, Codable {
        case proximityHandshakeBegan
        case proximityHandshakeSucceeded
        case proximityHandshakeFailed
        case planReceived
        case planAccepted
        case planRejected
        case planSuperseded
        case workoutCompleted
        case completionPayloadSent
        case completionPayloadQueued
        case trainerRevoked
        case sessionStarted
        case sessionEnded
    }
}

extension Data {
    /// Returns the first 8 hex chars of SHA-256 — used for short fingerprinting of public keys.
    var sha256Fingerprint: String {
        // Use CryptoKit's SHA256
        // ...
    }
}
```

Add to `FernletStore`:

```swift
@Published private(set) var trainerAuditEvents: [TrainerAuditEvent] = []

func appendTrainerAudit(_ event: TrainerAuditEvent) {
    trainerAuditEvents.append(event)
    // Keep the last 1000 events
    if trainerAuditEvents.count > 1000 {
        trainerAuditEvents = Array(trainerAuditEvents.suffix(1000))
    }
    scheduleSnapshotSave()
}
```

Persist the log in `FernletSnapshot` and decode with empty default for legacy snapshots.

Call `appendTrainerAudit` from every point in `TrainerProximityService` and `FernletStore` where a trainer-related state change happens.

Tests in `TrainerPlanTests.swift`:
- `@Test func auditLogTrimsTo1000Events()` — append 1500 events, assert count == 1000 and the most recent 1000 are preserved.
- `@Test func auditEventRoundTripsCodable()` for every kind.
- `@Test func fingerprintIsStableAndShort()` — same key always produces the same 8-char fingerprint; different keys produce different fingerprints.

Update `FileIndex.md`.
```

---

## Prompt M7.2 — Trainers settings panel (list, revoke)

**Depends on:** M7.1
**Files to modify:** `Fernlet/Fernlet/SettingsSheet.swift`
**Files to create:** none

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §7.6 of `move-refactor-and-trainer-integration-plan.md`.

Add a new tab to `SettingsSheet` called "Trainers" alongside the existing tabs. Body:

- "Pair with new trainer" button → opens `TrainerPairingSheet`.
- List of `store.trainerProfiles` (excluding revoked, with a toggle to show revoked).
- Each row: trainer name + organization + first 8 chars of public key fingerprint + "Last seen" timestamp + "Revoke" action.
- Tapping a row opens a detail view showing the trainer's plans + recent audit events.

UI test in `FernletUITests`:
- `func testRevokeTrainerRemovesTheirPlans()` — preload fixture with a trainer and a plan; open settings → Trainers; revoke; assert their plans no longer appear in Move tab.

Tests in `TrainerPlanTests.swift`:
- `@Test func revokedTrainerExcludedFromActiveList()` — after revoke, the active list excludes them; the revoked-toggle list includes them.
```

---

# Phase M8 — Live workout sessions on iPhone

## Prompt M8.1 — `LiveWorkoutSession` wrapping `HKLiveWorkoutBuilder`

**Depends on:** M2
**Files to modify:** `Fernlet/Fernlet/HealthKitService.swift`
**Files to create:** `Fernlet/Fernlet/LiveWorkoutSession.swift`, `Fernlet/FernletTests/LiveWorkoutSessionTests.swift`

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §D of `apple-fitness-and-healthkit-research.md`. iOS 26 brought `HKWorkoutSession` to iPhone — use it.

Create `Fernlet/Fernlet/LiveWorkoutSession.swift`:

```swift
import Foundation
import HealthKit
import Combine

@MainActor
final class LiveWorkoutSession: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        case active(startedAt: Date)
        case paused(pausedAt: Date)
        case ending
        case ended(workoutID: UUID)
        case failed(reason: String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var heartRateBPM: Double?
    @Published private(set) var activeEnergyKcal: Double = 0
    @Published private(set) var distanceMiles: Double = 0

    private var hkSession: HKWorkoutSession?
    private var hkBuilder: HKLiveWorkoutBuilder?
    private var timerTask: Task<Void, Never>?

    func start(mode: WorkoutMode, activityType: WorkoutActivityType?) async {
        state = .preparing
        let config = HKWorkoutConfiguration()
        switch mode {
        case .strengthTraining:
            config.activityType = .traditionalStrengthTraining
        case .activity:
            config.activityType = activityType.map(ActivityTypeCatalog.hkActivityType(for:)) ?? .other
        }
        config.locationType = .unknown

        do {
            let store = HKHealthStore()
            let session = try HKWorkoutSession(healthStore: store, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            self.hkSession = session
            self.hkBuilder = builder

            session.prepare()
            let startDate = Date()
            session.startActivity(with: startDate)
            try await builder.beginCollection(at: startDate)

            state = .active(startedAt: startDate)
            startElapsedTimer(from: startDate)
            observeStatistics()
        } catch {
            state = .failed(reason: error.localizedDescription)
        }
    }

    func pause() async {
        guard case .active = state else { return }
        hkSession?.pause()
        state = .paused(pausedAt: Date())
    }

    func resume() async {
        guard case .paused = state else { return }
        hkSession?.resume()
        state = .active(startedAt: Date())  // Reset elapsed origin (timer keeps accumulating)
    }

    func end(metadata: [String: Any] = [:]) async throws -> UUID {
        state = .ending
        guard let session = hkSession, let builder = hkBuilder else {
            throw HealthKitServiceError.healthDataUnavailable
        }
        let endDate = Date()
        session.end()
        try await builder.endCollection(at: endDate)
        try await builder.addMetadata(metadata)
        guard let saved = try await builder.finishWorkout() else {
            throw HealthKitServiceError.healthDataUnavailable
        }
        state = .ended(workoutID: saved.uuid)
        timerTask?.cancel()
        return saved.uuid
    }

    private func startElapsedTimer(from startedAt: Date) {
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if case .active = self.state {
                    await MainActor.run {
                        self.elapsedSeconds = Date().timeIntervalSince(startedAt)
                    }
                }
            }
        }
    }

    private func observeStatistics() {
        // HKLiveWorkoutBuilderDelegate-style observation; collect HR, energy, distance as samples arrive
    }
}
```

Tests in `LiveWorkoutSessionTests.swift`:
Since HKWorkoutSession can't run in unit tests without entitlements:
- `@Test func liveWorkoutSessionInitialStateIsIdle()`.
- `@Test func liveWorkoutSessionConfigurationForStrengthMode()` — extract a static helper `static func makeConfiguration(mode: WorkoutMode, activityType: WorkoutActivityType?) -> HKWorkoutConfiguration` and test it (parallels M2.2 testing pattern).
- `@Test func liveWorkoutSessionConfigurationForActivityMode()`.

Real integration tests require a device with HealthKit access; mark those with `.disabled("Requires HealthKit entitlement and physical device")`.

Update `FileIndex.md`.
```

---

## Prompt M8.2 — Live workout UI + Live Activity

**Depends on:** M8.1
**Files to modify:** `Fernlet/Fernlet/MoveView.swift`
**Files to create:** `Fernlet/Fernlet/LiveWorkoutView.swift`, `Fernlet/Fernlet/FernletWorkoutActivityAttributes.swift`, a new Widget Extension target for the Live Activity (if not already present)

```prompt
You are working in the Fernlet iOS SwiftUI project. Read §D and §G (point 4) of `apple-fitness-and-healthkit-research.md`.

1. Create `Fernlet/Fernlet/FernletWorkoutActivityAttributes.swift`:

```swift
import ActivityKit
import Foundation

struct FernletWorkoutActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var elapsedSeconds: TimeInterval
        var heartRateBPM: Double?
        var activeEnergyKcal: Double
        var distanceMiles: Double
        var isPaused: Bool
    }

    var workoutName: String
    var activityTypeSymbol: String   // SF Symbol
    var startedAt: Date
}
```

2. Create `Fernlet/Fernlet/LiveWorkoutView.swift`:

```swift
import SwiftUI

struct LiveWorkoutView: View {
    @StateObject var session: LiveWorkoutSession
    @ObservedObject var store: FernletStore
    var plannedWorkout: PlannedWorkout?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            // Title + activity symbol
            // Elapsed time large display
            // Stats grid: HR, energy, distance
            // Pause/Resume button
            // End button
            // If plannedWorkout present: render the per-exercise checklist with planned sets
        }
        .task { await session.start(mode: mode, activityType: activityType) }
    }
}
```

3. Add a new Widget Extension target (if not present) for the Live Activity. The widget renders the same fields as the in-app view — elapsed time, HR, energy.

4. Wire the Live Activity from `LiveWorkoutSession`:

```swift
import ActivityKit

extension LiveWorkoutSession {
    private var currentActivity: Activity<FernletWorkoutActivityAttributes>?

    func startLiveActivity(name: String, symbol: String) async {
        let attributes = FernletWorkoutActivityAttributes(workoutName: name, activityTypeSymbol: symbol, startedAt: Date())
        let content = ActivityContent(state: .init(elapsedSeconds: 0, heartRateBPM: nil, activeEnergyKcal: 0, distanceMiles: 0, isPaused: false), staleDate: nil)
        do {
            currentActivity = try Activity<FernletWorkoutActivityAttributes>.request(attributes: attributes, content: content)
        } catch {
            // Live Activities unavailable — non-fatal
        }
    }

    func updateLiveActivity() async {
        guard let currentActivity else { return }
        let state = FernletWorkoutActivityAttributes.ContentState(
            elapsedSeconds: elapsedSeconds,
            heartRateBPM: heartRateBPM,
            activeEnergyKcal: activeEnergyKcal,
            distanceMiles: distanceMiles,
            isPaused: state == .paused(pausedAt: Date())  // adapt to actual state check
        )
        await currentActivity.update(ActivityContent(state: state, staleDate: nil))
    }

    func endLiveActivity() async {
        await currentActivity?.end(nil, dismissalPolicy: .immediate)
    }
}
```

5. In `MoveView`, add a "Start live workout" button alongside "Log" and "Suggest". Tapping it opens `LiveWorkoutView` in a full-screen cover.

Tests:
- UI test in `FernletUITests`: `func testStartLiveWorkoutButtonOpensLiveView()`.
- Unit test in `LiveWorkoutSessionTests`: `@Test func liveActivityAttributesAreCodable()` — `FernletWorkoutActivityAttributes` and its content state round-trip.

Update `FileIndex.md`.
```

---

# Phase M9 — WorkoutKit "Send to Apple Watch"

## Prompt M9.1 — Convert `PlannedWorkout` to WorkoutKit `CustomWorkout` and present

**Depends on:** M4.1
**Files to modify:** none
**Files to create:** `Fernlet/Fernlet/WorkoutKitBridge.swift`, `Fernlet/FernletTests/WorkoutKitBridgeTests.swift`

```prompt
You are working in the Fernlet iOS SwiftUI project. Read the WorkoutKit section in the GymKit/WorkoutKit assistant answer and §D of `apple-fitness-and-healthkit-research.md`.

Create `Fernlet/Fernlet/WorkoutKitBridge.swift`:

```swift
import Foundation
import HealthKit
import WorkoutKit

@MainActor
enum WorkoutKitBridge {
    /// Convert a Fernlet PlannedWorkout into a WorkoutKit composition suitable for the .workoutPreview SwiftUI modifier.
    /// Returns nil if the workout cannot be represented in WorkoutKit (e.g., strength training with no useful structure).
    static func composition(for plannedWorkout: PlannedWorkout) -> WorkoutPlan? {
        switch plannedWorkout.mode {
        case .strengthTraining:
            // WorkoutKit has no structured strength-training format. Use a SingleGoalWorkout with open goal.
            do {
                let workout = try SingleGoalWorkout(
                    activity: .traditionalStrengthTraining,
                    goal: .open,
                    displayName: plannedWorkout.name
                )
                return WorkoutPlan(.single(.singleGoal(workout)))
            } catch {
                return nil
            }
        case .activity:
            guard let activityType = plannedWorkout.activityType else { return nil }
            let hkType = ActivityTypeCatalog.hkActivityType(for: activityType)
            // For activities with a target duration, use SingleGoalWorkout with a time goal
            if let duration = plannedWorkout.targetDurationMinutes {
                do {
                    let workout = try SingleGoalWorkout(
                        activity: hkType,
                        goal: .time(Double(duration * 60), .seconds),
                        displayName: plannedWorkout.name
                    )
                    return WorkoutPlan(.single(.singleGoal(workout)))
                } catch {
                    return nil
                }
            }
            // Otherwise, open-ended
            do {
                let workout = try SingleGoalWorkout(
                    activity: hkType,
                    goal: .open,
                    displayName: plannedWorkout.name
                )
                return WorkoutPlan(.single(.singleGoal(workout)))
            } catch {
                return nil
            }
        }
    }

    /// Schedule a workout to land on the user's Apple Watch at a specific date.
    static func schedule(_ plannedWorkout: PlannedWorkout, at dateComponents: DateComponents) async throws {
        guard let plan = composition(for: plannedWorkout) else {
            throw BridgeError.unsupportedComposition
        }
        try await WorkoutScheduler.shared.schedule(plan, at: dateComponents)
    }

    static func scheduledWorkouts() async -> [PlannedWorkout.ID: ScheduledWorkoutPlan] {
        // Reverse-map by displayName or by querying our own snapshot of scheduled IDs
        // For v1, just expose the count
        let scheduled = await WorkoutScheduler.shared.scheduledWorkouts
        return [:]  // populate as part of M9.2
    }

    enum BridgeError: Error {
        case unsupportedComposition
        case schedulerUnavailable
    }
}
```

Create tests in `WorkoutKitBridgeTests.swift`:
- `@Test func compositionForStrengthReturnsSingleGoalOpen()` — given a strength PlannedWorkout, the result is a SingleGoalWorkout with .traditionalStrengthTraining and .open goal.
- `@Test func compositionForActivityWithDurationReturnsTimeGoal()` — given a planned 30-min cycling workout, the goal is .time(1800, .seconds).
- `@Test func compositionForActivityWithoutDurationReturnsOpenGoal()`.
- `@Test func compositionReturnsNilForActivityModeWithoutActivityType()` — invalid input, returns nil.

Add a "Send to Apple Watch" button to `PlannedWorkoutCard` (M4.3) — only render it if a paired Apple Watch is detected via `WCSession` (gracefully hide otherwise). Tapping the button presents the workout via `.workoutPreview(_:isPresented:)`.

Update `FileIndex.md`.
```

---

# Appendix — Cross-cutting checklist for every prompt

Before declaring a prompt complete, the assistant should verify:

- [ ] Build succeeds for the Fernlet target.
- [ ] Build succeeds for the FernletTests target.
- [ ] All new tests pass.
- [ ] No new warnings introduced (especially deprecation warnings — those indicate use of a deprecated API like `HKWorkout(activityType:start:end:…)`).
- [ ] `FileIndex.md` updated for every new file.
- [ ] No references to deprecated focus-tag types remain (except in legacy decode paths and the dedicated migration tests in M3).
- [ ] Codable model changes round-trip an old-format JSON literal in at least one test.
- [ ] HealthKit code uses `HKWorkoutBuilder` only; no occurrences of `HKWorkout(activityType:` in the codebase grep.
- [ ] No `print(...)` statements added; use the existing audit/logging facilities.
- [ ] No force-unwraps (`!`) added in production code beyond what already existed.
- [ ] Anything that requires Apple Intelligence is gated only by iOS 26.0 availability, not by `@available` checks.

---

## How to extend this document

When new feature work emerges:

1. Add a new phase section after M9.
2. Number the prompts as `M{phase}.{step}`.
3. Each prompt must include: **Depends on**, **Files to modify**, **Files to create**, the verbatim prompt block, and explicit test requirements.
4. Cross-reference the originating section in `move-refactor-and-trainer-integration-plan.md` or `apple-fitness-and-healthkit-research.md`.
5. Update the "Phase index" table near the top.
