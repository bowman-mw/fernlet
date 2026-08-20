//
//  TrainerExportBuilder.swift
//  Fernlet
//
//  Trainer / Nutritionist export (Phase 7). Assembles a CURATED workout + nutrition bundle the user can
//  review and — only on explicit confirmation — send sealed to a nearby trainer over the friend mesh.
//
//  Privacy (spec §10): built from LIVE, decrypted in-memory state, but the projection is a FAIL-CLOSED
//  ALLOWLIST — every field is selected by hand, so a future field is invisible to a trainer until someone
//  consciously adds it here. There is no copy-and-strip. A trainer/nutritionist gets exactly: the user's
//  workouts over time, per-day nutrition summaries (as-logged macro + micronutrient totals + meal names),
//  and training-safety context (injury notes, avoided muscles/movements). Optionally, and ONLY when the
//  user toggles them on: goal, hydration, sleep summary, sickness windows, and wellbeing (a derived
//  signal). NEVER: journal text, Sensitive/Tier-2 memory, period/cycle data, intimate-activity data,
//  photos, friends, location, or recipe ingredient lists.
//

import Foundation
import FernletDomainModel
import FernletFoundation
import FernletScoring

// MARK: - What the user chose to include

/// The optional, off-by-default categories. Workouts, per-day nutrition summaries, and training-safety
/// context are ALWAYS included (that is the point of a trainer/nutritionist export); everything here is
/// opt-in so nothing beyond the core is shared without a deliberate toggle.
struct TrainerExportOptions: Equatable {
    var includeGoal = false
    var includeHydration = false
    var includeSleep = false
    var includeSickness = false
    var includeWellbeing = false   // a derived signal (score + state), never the components/period phase

    static let coreOnly = TrainerExportOptions()
}

// MARK: - How much history to include

/// How far back each section of the export reaches.
///
/// The file/AirDrop path and the future coach-mesh transport use ``unlimited`` — the shipped
/// behaviour, where a trainer receives the user's whole logged history. The clipboard path uses
/// ``coachHandoff``, because that text has to fit in a chat box and, past a point, more history buys
/// worse programming rather than better: eight weeks of full session detail plus a six-month
/// per-exercise rollup carries the progression signal at a fraction of the size.
///
/// `nil` on a field means no limit. Windows are counted in `yyyy-MM-dd` day keys against the export
/// date, so a gap in logging doesn't stretch the window.
struct TrainerExportWindow: Equatable, Sendable {
    var workoutDays: Int?
    var nutritionDays: Int?
    var exerciseHistoryDays: Int?
    /// How far FORWARD to carry already-planned workouts, in days from today.
    ///
    /// The three windows above all reach backwards; this one is the only forward-looking field, and
    /// it exists because a coach cannot adjust a plan they cannot see. Defaults to 35 days — one
    /// more than the 30-day `CoachPlanLimits.maxDays`, so a full-length plan the user already
    /// accepted is visible end to end.
    var plannedDaysAhead: Int? = 35

    /// Everything ever logged — what the file export and the coach mesh send.
    nonisolated static let unlimited = TrainerExportWindow(workoutDays: nil, nutritionDays: nil,
                                                           exerciseHistoryDays: nil, plannedDaysAhead: nil)

    /// The clipboard window: 8 weeks of sessions, 2 weeks of day-by-day nutrition, 6 months of
    /// rollup, and 5 weeks of upcoming plans to adjust.
    nonisolated static let coachHandoff = TrainerExportWindow(workoutDays: 56, nutritionDays: 14,
                                                              exerciseHistoryDays: 183, plannedDaysAhead: 35)

    /// The earliest day key still inside `days`, or nil when unlimited.
    func earliestKey(_ days: Int?, from today: Date) -> String? {
        guard let days else { return nil }
        guard let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: today) else { return nil }
        return FernletDate.dayKey(for: start)
    }

    /// The latest day key still inside the forward planned window, or nil when unlimited.
    func latestPlannedKey(from today: Date) -> String? {
        guard let plannedDaysAhead else { return nil }
        guard let end = Calendar.current.date(byAdding: .day, value: plannedDaysAhead, to: today) else { return nil }
        return FernletDate.dayKey(for: end)
    }
}

// MARK: - Export DTO (curated, allowlisted projections)

/// The curated trainer/nutritionist export: a human-readable about block, the training-safety
/// profile, and per-day workout + nutrition projections.
///
/// This is the FAIL-CLOSED ALLOWLIST described in the file header — every field a trainer can see
/// is hand-selected here, so a new store field stays invisible until someone consciously adds a
/// projection for it. Built by `FernletStore.buildTrainerExport(options:)` from live decrypted
/// state (never a copy-and-strip), encoded to stable pretty JSON by
/// `encodeTrainerExport(_:)`, and reviewed in ``TrainerExportView`` before anything leaves the
/// device. Sealed/sensitive data (journal, cycle/intimacy, photos, friends, location, recipe
/// ingredients) has no representation in this type at all — that absence is the privacy guarantee.
struct TrainerExportBundle: Codable, Equatable {
    var about: About
    var profile: TrainingProfile
    /// The macro targets in effect, and whether each was set by the user or derived by Fernlet.
    ///
    /// Always included: the as-logged totals in `days` are meaningless to a coach without knowing
    /// what they were aimed at — "2100 kcal" is compliance or a deficit depending entirely on this.
    var targets: NutritionTargetsExport?
    /// Where the user trains and with what, plus the split they're following.
    ///
    /// Always included for the same reason as the avoid-lists: without it a plan can prescribe
    /// equipment the user doesn't have, which is the single most common way an outside plan is
    /// unusable on arrival.
    var trainingSetup: TrainingSetup?
    /// Per-exercise progression, rolled up from the logged free-text lines.
    var exerciseHistory: [ExerciseHistoryEntry]?
    /// How many logged exercise lines couldn't be parsed into sets/reps for `exerciseHistory`.
    ///
    /// Reported rather than swallowed: a rollup that silently covers half the log reads as a
    /// complete picture and would have a coach programming from a fiction.
    var unparsedExerciseLines: Int?
    var days: [DayExport]

    /// The self-describing preamble of the export: when it was prepared, and the human-readable
    /// "includes" / "never includes" lists.
    ///
    /// Rendered at the top of the JSON so the person receiving the file (and the user reviewing it)
    /// can see exactly what was and wasn't shared without reading the data itself.
    struct About: Codable, Equatable {
        var app = "Fernlet"
        var exportedOn: String
        var preparedFor = "Your trainer or nutritionist"
        var note = "A summary of your workouts and nutrition, prepared for you to review before you share "
            + "it in person. Fernlet keeps everything on your device."
        var includes: [String]
        var neverIncludes: [String]
    }

    /// The user's training context: safety information (always included) plus the opt-in goal.
    ///
    /// Projected from `FernletSettings.workoutProfile`; empty strings and empty sets become `nil`
    /// so the JSON only carries fields that say something.
    struct TrainingProfile: Codable, Equatable {
        // Training-safety context is always included — a trainer needs to know what to avoid.
        var injuryNotes: String?
        var avoidedMuscles: [String]?
        var avoidedMovements: [String]?
        var sport: String?
        var experience: String?
        var trainingDaysPerWeek: Int?
        // Opt-in only.
        var goal: String?
    }

    /// One day of the export: logged workouts, the nutrition summary, and the opt-in extras.
    ///
    /// Projected by `projectTrainerDay` — a day with nothing trainer-relevant (only journal or
    /// other excluded data) is dropped entirely rather than exported empty.
    struct DayExport: Codable, Equatable {
        var day: String
        var workouts: [WorkoutExport]?
        /// Workouts already PLANNED for this day and not yet done — what a coach adjusts.
        ///
        /// Distinct from `workouts`, which is what actually happened. Only these carry an `id`,
        /// because only these can be targeted by an imported plan's edits; a logged workout is a
        /// record of the past and is never rewritten by an import.
        var plannedWorkouts: [PlannedWorkoutExport]?
        var nutrition: NutritionSummary?
        // Opt-in only.
        var hydration: Hydration?
        var sleep: SleepExport?
        var wasSick: Bool?
        var wellbeing: Wellbeing?

        /// The day's water intake against the user's target, in bottles.
        ///
        /// Present only when `includeHydration` is on and the day logged at least one bottle.
        struct Hydration: Codable, Equatable {
            var bottles: Int
            var targetBottles: Int
        }
        /// The derived wellbeing signal: a rounded score plus its companion-state label.
        ///
        /// Only the derived value is ever exported — never the score components or period phase —
        /// and when sickness sharing is off the state is recomputed without the sick flag so this
        /// channel can't leak sick days (see `projectTrainerDay`).
        struct Wellbeing: Codable, Equatable {
            var score: Double
            var state: String
        }
    }

    /// One logged workout, as the user recorded it.
    ///
    /// A direct projection of `Workout`'s trainer-relevant fields — including the free-text
    /// sets/reps/weights lines, RPE, and the user's own notes — with empty collections and strings
    /// collapsed to `nil`.
    struct WorkoutExport: Codable, Equatable {
        var name: String
        var type: String
        var mode: String
        var intensity: String
        var muscleGroups: [String]?
        var exercises: [String]?      // free-text sets/reps/weights lines, as the user logged them
        var durationMinutes: Int?
        var distanceMiles: Double?
        var activeEnergyKcal: Double?
        var perceivedEffortRPE: Double?
        var notes: String?
        var completedAt: Date
    }

    /// One workout the user has PLANNED but not yet done.
    ///
    /// `id` is the load-bearing field: it is the handle an imported plan uses to say "replace this
    /// one" / "adjust this one" / "remove this one" (`CoachPlanEdit.targetID`). It is the row's real
    /// `PlannedWorkout.id` — an opaque UUID that means nothing off this device, and echoing it is
    /// what makes targeting survive a rename or two workouts sharing a day.
    struct PlannedWorkoutExport: Codable, Equatable {
        var id: UUID
        var name: String
        var split: String
        /// Who planned it — `user` or `coach` — so a coach can tell their own prior work from the
        /// user's.
        var source: String
        var exercises: [String]?
        var notes: String?
        var durationMinutes: Int?
    }

    /// One day's nutrition, summed from the per-meal SNAPSHOTS the user logged.
    ///
    /// Meal names and calorie/macro totals plus optional micronutrient totals — never the recipe
    /// ingredient lists the snapshots were computed from (those are on the never-share list).
    struct NutritionSummary: Codable, Equatable {
        var mealNames: [String]
        var totalCalories: Int
        var proteinGrams: Int
        var carbsGrams: Int
        var fatGrams: Int
        var micronutrients: MicronutrientTotals?
    }

    /// Per-day micronutrient totals a nutritionist reviews — summed from the as-logged per-meal snapshots.
    ///
    /// Every field is optional: a nutrient nobody logged stays `nil`, and an all-nil value is
    /// dropped from the day entirely (`isEmpty`) rather than exported as an empty object.
    struct MicronutrientTotals: Codable, Equatable {
        var fiber: Double?
        var sugar: Double?
        var saturatedFat: Double?
        var cholesterol: Double?
        var sodium: Double?
        var potassium: Double?
        var calcium: Double?
        var iron: Double?
        var magnesium: Double?
        var vitaminC: Double?
        var vitaminD: Double?
        var omega3: Double?

        var isEmpty: Bool {
            fiber == nil && sugar == nil && saturatedFat == nil && cholesterol == nil && sodium == nil
                && potassium == nil && calcium == nil && iron == nil && magnesium == nil
                && vitaminC == nil && vitaminD == nil && omega3 == nil
        }
    }

    /// One night's sleep summary: hours, the quality label, and the user's note if any.
    ///
    /// Opt-in only (`includeSleep`); projected from the day record's sleep entry.
    struct SleepExport: Codable, Equatable {
        var hours: Double?
        var quality: String
        var note: String?
    }

    /// The daily macro targets in effect, with each one flagged user-set or Fernlet-derived.
    ///
    /// The `…IsUserSet` flags matter to whoever reads this: a derived target is Fernlet's arithmetic
    /// from goal + profile + activity and is fair game to change, whereas a user-set one is a
    /// deliberate choice that shouldn't be silently overridden.
    struct NutritionTargetsExport: Codable, Equatable {
        var calories: Int
        var proteinGrams: Int
        var carbsGrams: Int
        var fatGrams: Int
        var caloriesIsUserSet: Bool
        var proteinIsUserSet: Bool
        var fatIsUserSet: Bool
    }

    /// Where and how the user trains: their active location's equipment and the split they follow.
    ///
    /// `ownedEquipment` is the granular user-facing gear list; it maps down onto the coarse
    /// ``Equipment`` capabilities the planning engine and safety filter reason about.
    struct TrainingSetup: Codable, Equatable {
        var locationName: String
        var ownedEquipment: [String]
        var splitName: String?
        var splitIsUserChosen: Bool
        var trainingDaysPerWeek: Int?
    }

    /// One exercise's history, rolled up across the window: how often, how recently, how heavy.
    ///
    /// Parsed from the logged free-text lines, so every field past `name`/`sessions` is optional —
    /// a line that never stated a weight yields no weight, and saying so is more useful than
    /// inventing one. `estimatedOneRepMax` is Epley (`w × (1 + reps/30)`), rounded to one decimal,
    /// and is only present when a weight AND a numeric rep count were both parsed.
    struct ExerciseHistoryEntry: Codable, Equatable {
        var name: String
        /// Days on which this exercise appeared — the frequency signal, not the set count.
        var sessions: Int
        var totalSets: Int
        var firstLogged: String
        var lastLogged: String
        var lastSets: Int?
        var lastReps: String?
        var lastWeight: Double?
        var bestWeight: Double?
        var bestWeightReps: Int?
        var estimatedOneRepMax: Double?
        /// "lb" or "kg" as written in the logged lines, or nil when they never said.
        var weightUnit: String?
    }
}

// MARK: - Builder

extension FernletStore {
    /// Assembles the curated trainer bundle from live in-memory state. Excludes sealed/sensitive data by
    /// construction (see the file header). `options` gate the opt-in categories only.
    ///
    /// - Parameter window: how far back each section reaches. Defaults to ``TrainerExportWindow/unlimited``
    ///   so the shipped file/mesh export keeps sending the full history; the clipboard coach handoff
    ///   passes ``TrainerExportWindow/coachHandoff``.
    func buildTrainerExport(options: TrainerExportOptions,
                            window: TrainerExportWindow = .unlimited) -> TrainerExportBundle {
        let scoresByDay = Dictionary(dailyScores.map { ($0.dateKey, $0) }, uniquingKeysWith: { a, _ in a })

        let today = Date()
        let workoutFloor = window.earliestKey(window.workoutDays, from: today)
        let nutritionFloor = window.earliestKey(window.nutritionDays, from: today)
        let historyFloor = window.earliestKey(window.exerciseHistoryDays, from: today)

        let allDays = loadDays().values.sorted { $0.date > $1.date }   // newest first
        let todayDayKey = todayKey
        let plannedCeiling = window.latestPlannedKey(from: today)

        // Each section gets its own floor, so a day inside the workout window but outside the
        // nutrition window contributes its sessions and no meals — rather than the day being dropped
        // whole, which would silently shorten the workout history to the nutrition window.
        let dayExports: [TrainerExportBundle.DayExport] = allDays.compactMap { day in
            // Planned workouts reach FORWARD from today, unlike every other section. A past day's
            // leftover plan is not something a coach can adjust, so it is deliberately not sent.
            let includePlanned = day.date >= todayDayKey
                && (plannedCeiling.map { day.date <= $0 } ?? true)
            return Self.projectTrainerDay(
                day,
                score: scoresByDay[day.date],
                target: hydrationTargetBottles,
                options: options,
                includeWorkouts: workoutFloor.map { day.date >= $0 } ?? true,
                includeNutrition: nutritionFloor.map { day.date >= $0 } ?? true,
                includePlanned: includePlanned)
        }

        let rollup = Self.rollUpExerciseHistory(
            days: allDays.filter { day in historyFloor.map { day.date >= $0 } ?? true })

        let wp = settings.workoutProfile
        let profile = TrainerExportBundle.TrainingProfile(
            injuryNotes: wp.injuryNotes.isEmpty ? nil : wp.injuryNotes,
            avoidedMuscles: wp.avoidedMuscles.isEmpty ? nil : wp.avoidedMuscles.map(\.rawValue).sorted(),
            avoidedMovements: wp.avoidedMovements.isEmpty ? nil : wp.avoidedMovements.map(\.rawValue).sorted(),
            sport: wp.sport.isEmpty ? nil : wp.sport,
            experience: wp.experience.rawValue,
            trainingDaysPerWeek: wp.trainingDaysPerWeek > 0 ? wp.trainingDaysPerWeek : nil,
            goal: options.includeGoal ? settings.selectedGoal.rawValue : nil)

        var includes = ["Your workouts over time (names, sets/reps/weights as logged, duration, effort)",
                        "Per-day nutrition summaries (calorie + macro + micronutrient totals, meal names)",
                        "Your daily calorie and macro targets",
                        "Where you train, the equipment you have, and the split you follow",
                        "How each exercise has progressed (frequency, recent and best sets)",
                        "Workouts you've already planned for the coming weeks, so they can be adjusted",
                        "Training-safety context (injury notes, avoided muscles and movements)"]
        if options.includeGoal { includes.append("Your goal type") }
        if options.includeHydration { includes.append("Daily hydration") }
        if options.includeSleep { includes.append("Sleep summaries") }
        if options.includeSickness { includes.append("Days you were unwell") }
        if options.includeWellbeing { includes.append("Your wellbeing score for each day") }

        let about = TrainerExportBundle.About(
            exportedOn: todayKey,
            includes: includes,
            neverIncludes: [
                "Journal entries and private notes",
                "Period / cycle data and intimate-activity data",
                "Photos, friends, and location",
                "Recipe ingredient lists and your private cryptographic keys",
            ])

        return TrainerExportBundle(
            about: about,
            profile: profile,
            targets: projectedTargets(),
            trainingSetup: projectedTrainingSetup(),
            exerciseHistory: rollup.entries.isEmpty ? nil : rollup.entries,
            unparsedExerciseLines: rollup.unparsedLines > 0 ? rollup.unparsedLines : nil,
            days: dayExports)
    }

    /// The macro targets in effect, flagged user-set or derived.
    private func projectedTargets() -> TrainerExportBundle.NutritionTargetsExport {
        let applied = nutritionTargets
        return .init(
            calories: applied.calories,
            proteinGrams: applied.protein,
            carbsGrams: applied.carbs,
            fatGrams: applied.fat,
            caloriesIsUserSet: settings.calorieTargetOverride != nil,
            proteinIsUserSet: settings.proteinTargetOverride != nil,
            fatIsUserSet: settings.fatTargetOverride != nil)
    }

    /// The active location's equipment plus the split in effect.
    ///
    /// `splitIsUserChosen` distinguishes a split the user picked from the one Fernlet recommended —
    /// the same "deliberate choice vs. our arithmetic" distinction the target flags carry.
    private func projectedTrainingSetup() -> TrainerExportBundle.TrainingSetup {
        let location = settings.activeWorkoutLocation
        let chosenID = settings.workoutProfile.selectedSplitID
        let split = chosenID.flatMap { id in WorkoutSplitCatalog.all.first { $0.id == id } }
            ?? recommendedSplits().first
            ?? WorkoutSplitCatalog.fallback
        let days = settings.workoutProfile.trainingDaysPerWeek
        return .init(
            locationName: location.name,
            ownedEquipment: location.ownedEquipment.map(\.displayName).sorted(),
            splitName: split.name,
            splitIsUserChosen: chosenID != nil,
            trainingDaysPerWeek: days > 0 ? days : nil)
    }

    /// Encodes the bundle to pretty, stable JSON bytes (for the reviewable preview and the future sealed
    /// coach send). Encodes through the shared `makeExportJSONEncoder()`, so the bytes are the same
    /// stable dialect as the Phase-1 data export.
    func encodeTrainerExport(_ bundle: TrainerExportBundle) -> Data? {
        do {
            return try Self.makeExportJSONEncoder().encode(bundle)
        } catch {
            // Callers treat nil as "couldn't prepare the export" and say so; name the reason here so
            // a failure that never should happen leaves a trace.
            FernletAuditLog.log("trainerExport.encodeFailed",
                                context: ["error": String(describing: type(of: error))])
            return nil
        }
    }

    /// Writes the reviewed bundle to a protected temp JSON file and returns its URL — the interim way to
    /// hand the summary to a coach (share sheet) until the dedicated in-person `fernlet-coach` transport
    /// ships. Writes through `writeProtectedExport` into `dataExportsDirectory` (atomic +
    /// `.completeFileProtection`, like the Phase-1 data export), so the file — injury notes, sickness
    /// days, wellbeing scores in the clear — is covered by the launch sweep, the pre-export sweep, and
    /// "Delete everything" by construction instead of surviving in the tmp/ root.
    ///
    /// Those sweeps are the backstop, not the primary lifetime: `TrainerExportView` deletes this exact
    /// file through ``discardExportedFile(at:)`` the moment the share sheet finishes (and if the user
    /// changes the included options or leaves the screen without sharing).
    func writeTrainerExportFile(options: TrainerExportOptions) -> URL? {
        guard let data = encodeTrainerExport(buildTrainerExport(options: options)) else { return nil }
        do {
            return try writeProtectedExport(data, kind: "training")
        } catch {
            // The screen surfaces nil as "couldn't prepare the file"; a protected-write failure
            // (disk full, protection class unavailable) is now recorded rather than dropped.
            FernletAuditLog.log("trainerExport.writeFailed",
                                context: ["error": String(describing: type(of: error))])
            return nil
        }
    }

    /// The user's daily hydration goal in bottles (mirrors the Phase-1 export's `settings.hydrationTarget`).
    private var hydrationTargetBottles: Int { settings.hydrationTarget }

    // MARK: - Projection helpers (static, pure — the allowlist lives here)

    /// Projects one day, or nil if it has no trainer-relevant content (a day with only journal/other
    /// excluded data produces nothing).
    private static func projectTrainerDay(_ day: FernletDay, score: DailyHealthScore?, target: Int,
                                          options: TrainerExportOptions,
                                          includeWorkouts: Bool = true,
                                          includeNutrition: Bool = true,
                                          includePlanned: Bool = true) -> TrainerExportBundle.DayExport? {
        // A day outside EVERY window is dropped whole. Without this the opt-in extras (hydration,
        // sleep, sickness, wellbeing) would keep emitting rows for days whose workouts and meals
        // were both windowed out — leaving the clipboard blob effectively unbounded whenever any
        // optional toggle is on, which is exactly what the window exists to prevent.
        guard includeWorkouts || includeNutrition || includePlanned else { return nil }

        let workouts = includeWorkouts ? day.workouts.map { w in
            TrainerExportBundle.WorkoutExport(
                name: w.name, type: w.type.rawValue, mode: w.mode.rawValue, intensity: w.intensity.rawValue,
                muscleGroups: w.muscleGroups.isEmpty ? nil : w.muscleGroups.map(\.rawValue).sorted(),
                exercises: w.exerciseLines.isEmpty ? nil : w.exerciseLines,
                durationMinutes: w.duration, distanceMiles: w.distanceMiles, activeEnergyKcal: w.activeEnergyKcal,
                perceivedEffortRPE: w.rpe, notes: w.notes.isEmpty ? nil : w.notes, completedAt: w.completedAt)
        } : []
        let planned: [TrainerExportBundle.PlannedWorkoutExport] = includePlanned ? day.plannedWorkouts.map { p in
            TrainerExportBundle.PlannedWorkoutExport(
                id: p.id,
                name: p.name,
                split: p.split.title,
                source: p.source.rawValue,
                exercises: p.exerciseLines.isEmpty ? nil : p.exerciseLines,
                notes: p.notes.isEmpty ? nil : p.notes,
                durationMinutes: p.duration)
        } : []
        let nutrition = includeNutrition ? projectNutrition(day.meals) : nil

        let hydration: TrainerExportBundle.DayExport.Hydration? =
            (options.includeHydration && day.bottleCount > 0) ? .init(bottles: day.bottleCount, targetBottles: target) : nil
        let sleep: TrainerExportBundle.SleepExport? = (options.includeSleep) ? day.sleep.map {
            .init(hours: $0.hours, quality: $0.quality.rawValue, note: $0.note.isEmpty ? nil : $0.note)
        } : nil
        let wasSick: Bool? = (options.includeSickness && score?.sicknessOverride == true) ? true : nil
        let wellbeing: TrainerExportBundle.DayExport.Wellbeing? = (options.includeWellbeing) ? score.map { s in
            // Don't leak sickness through the wellbeing channel: `companionState` is `.sick` on any sick
            // day regardless of score, so emitting it verbatim would disclose sick days even when the
            // dedicated `includeSickness` toggle is OFF. When sickness isn't shared, report the score-based
            // state (recomputed with isSick:false, so never `.sick`). NO periodPhase / components either.
            let state = options.includeSickness ? s.companionState : FernletScoring.state(for: s.score, isSick: false)
            return .init(score: (s.score * 100).rounded() / 100, state: state.rawValue)
        } : nil

        // Drop days with nothing a trainer would see.
        if workouts.isEmpty, planned.isEmpty, nutrition == nil, hydration == nil, sleep == nil,
           wasSick == nil, wellbeing == nil {
            return nil
        }
        return TrainerExportBundle.DayExport(
            day: day.date,
            workouts: workouts.isEmpty ? nil : workouts,
            plannedWorkouts: planned.isEmpty ? nil : planned,
            nutrition: nutrition,
            hydration: hydration, sleep: sleep, wasSick: wasSick, wellbeing: wellbeing)
    }

    /// As-logged nutrition totals for a day. Uses the per-meal SNAPSHOTS (the computed per-serving values
    /// that were logged), never recipe ingredient lists.
    private static func projectNutrition(_ meals: [Meal]) -> TrainerExportBundle.NutritionSummary? {
        guard !meals.isEmpty else { return nil }
        let names = meals.map(\.name).filter { !$0.isEmpty }
        let protein = meals.reduce(0) { $0 + $1.macroSnapshot.protein }
        let carbs = meals.reduce(0) { $0 + $1.macroSnapshot.carbs }
        let fat = meals.reduce(0) { $0 + $1.macroSnapshot.fat }
        let calories = meals.reduce(0) { $0 + $1.calorieSnapshot }
        let micro = TrainerExportBundle.MicronutrientTotals(
            fiber: sumMicro(meals, \.fiber), sugar: sumMicro(meals, \.sugar),
            saturatedFat: sumMicro(meals, \.saturatedFat), cholesterol: sumMicro(meals, \.cholesterol),
            sodium: sumMicro(meals, \.sodium), potassium: sumMicro(meals, \.potassium),
            calcium: sumMicro(meals, \.calcium), iron: sumMicro(meals, \.iron),
            magnesium: sumMicro(meals, \.magnesium), vitaminC: sumMicro(meals, \.vitaminC),
            vitaminD: sumMicro(meals, \.vitaminD), omega3: sumMicro(meals, \.omega3))
        return TrainerExportBundle.NutritionSummary(
            mealNames: names, totalCalories: calories, proteinGrams: protein, carbsGrams: carbs, fatGrams: fat,
            micronutrients: micro.isEmpty ? nil : micro)
    }

    private static func sumMicro(_ meals: [Meal], _ key: KeyPath<Micronutrients, Double?>) -> Double? {
        let values = meals.compactMap { $0.micronutrientSnapshot[keyPath: key] }
        guard !values.isEmpty else { return nil }
        return (values.reduce(0, +) * 100).rounded() / 100
    }

    // MARK: - Per-exercise progression rollup

    /// Rolls every logged exercise line in `days` up into one entry per exercise.
    ///
    /// This is the section a coach actually programs progression from: what you do, how often, and
    /// what you last moved. It reads the SAME free-text lines the workout rows already carry
    /// (`Workout.exerciseLines`) rather than any new storage, which is why it must be honest about
    /// what it couldn't read — `unparsedLines` counts every line that yielded no sets/reps, and the
    /// caller surfaces it in the export.
    static func rollUpExerciseHistory(days: [FernletDay]) -> (entries: [TrainerExportBundle.ExerciseHistoryEntry],
                                                              unparsedLines: Int) {
        var byExercise: [String: ExerciseAccumulator] = [:]
        var unparsed = 0

        // Oldest first, so "last" genuinely means the most recent day rather than whichever day the
        // dictionary happened to yield last.
        for day in days.sorted(by: { $0.date < $1.date }) {
            for workout in day.workouts {
                for line in workout.exerciseLines {
                    guard let parsed = ExerciseLineParser.parse(line) else {
                        unparsed += 1
                        continue
                    }
                    let key = WorkoutExerciseCatalog.normalizedName(parsed.name)
                    guard !key.isEmpty else {
                        unparsed += 1
                        continue
                    }
                    var entry = byExercise[key] ?? ExerciseAccumulator(
                        name: parsed.name, firstLogged: day.date, lastLogged: day.date)
                    entry.fold(parsed, dayKey: day.date)
                    byExercise[key] = entry
                }
            }
        }

        let entries = byExercise.values
            // Most-recently-trained first, then by frequency — the order a coach reads in.
            .sorted { ($0.lastLogged, $0.dayKeys.count) > ($1.lastLogged, $1.dayKeys.count) }
            .map { $0.entry() }
        return (entries, unparsed)
    }
}

/// Mutable per-exercise rollup state; converted to the immutable export entry once every logged day
/// has been folded in.
private struct ExerciseAccumulator {
    var name: String
    var dayKeys: Set<String> = []
    var totalSets = 0
    var firstLogged: String
    var lastLogged: String
    var lastSets: Int?
    var lastReps: String?
    var lastWeight: Double?
    var bestWeight: Double?
    var bestWeightReps: Int?
    var weightUnit: String?

    /// Folds one parsed line from `dayKey` in. Days arrive oldest-first, so "last" stays honest.
    mutating func fold(_ parsed: ExerciseLineParser.Parsed, dayKey: String) {
        dayKeys.insert(dayKey)
        totalSets += parsed.sets ?? 0
        lastLogged = dayKey
        lastSets = parsed.sets
        lastReps = parsed.reps
        lastWeight = parsed.weight ?? lastWeight
        if let weight = parsed.weight, weight > (bestWeight ?? 0) {
            bestWeight = weight
            bestWeightReps = parsed.repsCount
        }
        weightUnit = weightUnit ?? parsed.weightUnit
    }

    /// The export row, including the Epley one-rep-max estimate where it is meaningful.
    func entry() -> TrainerExportBundle.ExerciseHistoryEntry {
        var oneRepMax: Double?
        // Epley. Meaningless past ~12 reps, so don't publish an estimate there rather than
        // publishing a number a coach might load off.
        if let weight = bestWeight, let reps = bestWeightReps, reps > 0, reps <= 12 {
            oneRepMax = ((weight * (1 + Double(reps) / 30)) * 10).rounded() / 10
        }
        return .init(
            name: name,
            sessions: dayKeys.count,
            totalSets: totalSets,
            firstLogged: firstLogged,
            lastLogged: lastLogged,
            lastSets: lastSets,
            lastReps: lastReps,
            lastWeight: lastWeight,
            bestWeight: bestWeight,
            bestWeightReps: bestWeightReps,
            estimatedOneRepMax: oneRepMax,
            weightUnit: weightUnit)
    }
}

// MARK: - Exercise line parsing

/// Reads one logged exercise line back into its parts.
///
/// The lines are free text — the guided runner writes `"Bench press - 3 x 8"`, but a hand-logged
/// line is whatever the user typed (`"Squat 5x5 @225lb"`, `"Incline DB press — 3x10"`). The parser
/// is therefore deliberately forgiving about separators and units, and deliberately strict about
/// what counts as a match: **no sets × reps pattern, no parse**. Returning a name-only "result"
/// would fold conditioning descriptions ("20 min row") into the strength rollup as zero-set
/// exercises, which is worse than honestly counting them as unparsed.
enum ExerciseLineParser {

    /// One parsed line: the exercise, its prescription, and the load if it stated one.
    struct Parsed: Equatable {
        var name: String
        var sets: Int?
        /// The rep text exactly as written, so "8-10" and "AMRAP" survive the round trip.
        var reps: String?
        /// The numeric rep count when `reps` is a plain number — the only form an Epley estimate
        /// can use.
        var repsCount: Int?
        var weight: Double?
        var weightUnit: String?
    }

    /// `3 x 8`, `3x8`, `3 × 8` — the sets × reps core every parseable line has.
    private static let setsReps = /(\d{1,2})\s*[xX×]\s*(\d{1,3}(?:\s*-\s*\d{1,3})?)/

    /// A trailing load, which must announce itself either with `@` (`@ 135`) or with a unit
    /// (`135 lb`, `60kg`).
    ///
    /// A bare trailing number is NOT accepted, and that restraint is the point: real logged lines
    /// end in things like `, 2 min rest`, and every line this app's own guided runner writes for a
    /// coach-planned exercise ends in a guidance suffix — `Bench press - 3 x 8 (RPE 7)`. Matching a
    /// bare number would read that 7 as a 7 lb bench press and quietly corrupt the progression
    /// rollup a coach programs from. Losing the load on `Squat 5x5 225` is the cheaper mistake.
    ///
    /// The fraction accepts `,` as well as `.` because the load is composed from what the person
    /// typed into the weight field, on a decimal pad whose separator follows their locale. While
    /// this matched `.` only, `62,5 kg` did not fail visibly — the engine simply resumed at the
    /// `5` and exported a **5 kg** bench press. Parsing is left to `LocaleTolerantNumber`.
    private static let load = /(?:@\s*(\d{1,4}(?:[.,]\d{1,2})?)\s*(lbs?|kgs?|kilos?)?|(\d{1,4}(?:[.,]\d{1,2})?)\s*(lbs?|kgs?|kilos?))\b/

    /// Removes parenthesised segments, which carry cues (`(RPE 7)`, `(2s pause)`) rather than load.
    private static func strippingParentheticals(_ text: String) -> String {
        text.replacing(/\([^)]*\)/, with: " ")
    }

    static func parse(_ rawLine: String) -> Parsed? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        guard let match = line.firstMatch(of: setsReps) else { return nil }

        // Everything before the sets × reps is the name, minus any trailing separator.
        let name = String(line[line.startIndex..<match.range.lowerBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—:,\t"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let sets = Int(match.output.1)
        let repsText = String(match.output.2).replacingOccurrences(of: " ", with: "")
        let repsCount = Int(repsText)

        // Look for the load only AFTER the sets × reps, so "3 x 8" can't have its own digits read
        // back as a weight, and with cue parentheticals removed first.
        var weight: Double?
        var unit: String?
        let tail = strippingParentheticals(String(line[match.range.upperBound...]))
        if let loadMatch = tail.firstMatch(of: load) {
            // The alternation gives two capture pairs — the `@`-prefixed form and the unit-suffixed
            // form — and exactly one of them is populated per match.
            let value = loadMatch.output.1 ?? loadMatch.output.3
            let rawUnit = loadMatch.output.2 ?? loadMatch.output.4
            weight = value.flatMap { LocaleTolerantNumber.double(from: String($0)) }
            if let rawUnit {
                unit = rawUnit.lowercased().hasPrefix("k") ? "kg" : "lb"
            }
        }

        return Parsed(name: name, sets: sets, reps: repsText.isEmpty ? nil : repsText,
                      repsCount: repsCount, weight: weight, weightUnit: unit)
    }
}
