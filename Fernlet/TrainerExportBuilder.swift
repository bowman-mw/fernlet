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
}

// MARK: - Builder

extension FernletStore {
    /// Assembles the curated trainer bundle from live in-memory state. Excludes sealed/sensitive data by
    /// construction (see the file header). `options` gate the opt-in categories only.
    func buildTrainerExport(options: TrainerExportOptions) -> TrainerExportBundle {
        let scoresByDay = Dictionary(dailyScores.map { ($0.dateKey, $0) }, uniquingKeysWith: { a, _ in a })

        let dayExports: [TrainerExportBundle.DayExport] = loadDays().values
            .sorted { $0.date > $1.date }   // newest first
            .compactMap { Self.projectTrainerDay($0, score: scoresByDay[$0.date], target: hydrationTargetBottles, options: options) }

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

        return TrainerExportBundle(about: about, profile: profile, days: dayExports)
    }

    /// Encodes the bundle to pretty, stable JSON bytes (for the reviewable preview and the future sealed
    /// coach send). Encodes through the shared `makeExportJSONEncoder()`, so the bytes are the same
    /// stable dialect as the Phase-1 data export.
    func encodeTrainerExport(_ bundle: TrainerExportBundle) -> Data? {
        try? Self.makeExportJSONEncoder().encode(bundle)
    }

    /// Writes the reviewed bundle to a protected temp JSON file and returns its URL — the interim way to
    /// hand the summary to a coach (share sheet) until the dedicated in-person `fernlet-coach` transport
    /// ships. Writes through `writeProtectedExport` into `dataExportsDirectory` (atomic +
    /// `.completeFileProtection`, like the Phase-1 data export), so the file — injury notes, sickness
    /// days, wellbeing scores in the clear — is covered by the launch sweep, the share-completion purge,
    /// and "Delete everything" by construction instead of surviving in the tmp/ root.
    func writeTrainerExportFile(options: TrainerExportOptions) -> URL? {
        guard let data = encodeTrainerExport(buildTrainerExport(options: options)) else { return nil }
        return try? writeProtectedExport(data, kind: "training")
    }

    /// The user's daily hydration goal in bottles (mirrors the Phase-1 export's `settings.hydrationTarget`).
    private var hydrationTargetBottles: Int { settings.hydrationTarget }

    // MARK: - Projection helpers (static, pure — the allowlist lives here)

    /// Projects one day, or nil if it has no trainer-relevant content (a day with only journal/other
    /// excluded data produces nothing).
    private static func projectTrainerDay(_ day: FernletDay, score: DailyHealthScore?, target: Int,
                                          options: TrainerExportOptions) -> TrainerExportBundle.DayExport? {
        let workouts = day.workouts.map { w in
            TrainerExportBundle.WorkoutExport(
                name: w.name, type: w.type.rawValue, mode: w.mode.rawValue, intensity: w.intensity.rawValue,
                muscleGroups: w.muscleGroups.isEmpty ? nil : w.muscleGroups.map(\.rawValue).sorted(),
                exercises: w.exerciseLines.isEmpty ? nil : w.exerciseLines,
                durationMinutes: w.duration, distanceMiles: w.distanceMiles, activeEnergyKcal: w.activeEnergyKcal,
                perceivedEffortRPE: w.rpe, notes: w.notes.isEmpty ? nil : w.notes, completedAt: w.completedAt)
        }
        let nutrition = projectNutrition(day.meals)

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
        if workouts.isEmpty, nutrition == nil, hydration == nil, sleep == nil, wasSick == nil, wellbeing == nil {
            return nil
        }
        return TrainerExportBundle.DayExport(
            day: day.date,
            workouts: workouts.isEmpty ? nil : workouts,
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
}
