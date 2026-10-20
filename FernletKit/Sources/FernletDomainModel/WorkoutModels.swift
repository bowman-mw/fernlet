// WorkoutModels.swift
// Split out of Models.swift (SPM carve-up §5c). Workout, exercise, muscle, and equipment models.

import Foundation
import FernletFoundation
import Synchronization

/// One completed workout row: what was done, how hard, and where the record came from.
///
/// Lives inside ``FernletDay``, so every enum field decodes tolerantly with parked tokens
/// (``EnumDecodeCompat``). Provenance is three-way and load-bearing for edit/delete rules:
/// `healthKitUUID` + `healthKitAuthored` distinguish a read-only Apple Health *import*
/// (``isHealthImported``) from a Fernlet-*authored* Health sample Fernlet owns
/// (``isHealthAuthored``), and `loggedFromGuidedSession` marks guided-flow rows so name-based
/// reconciliation only ever matches its own logs. Both markers are encoded only when set, so
/// untagged rows stay byte-identical.
public nonisolated struct Workout: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var name: String
    // The enum fields decode tolerantly (freeze-on-unknown + parked-token side channels): a raw
    // value only a NEWER build knows would otherwise throw the whole Workout → the whole FernletDay
    // → the blob decode (read-only recovery) or the day's row (silently dropped). Parked tokens are
    // re-encoded, re-adopted by a build that knows them, and cleared on an explicit local edit via
    // `didSet` (`EnumDecodeCompat`).
    public var type: WorkoutType {
        didSet { unknownTypeToken = nil }
    }
    public var unknownTypeToken: String? = nil
    public var mode: WorkoutMode = .strengthTraining {
        didSet { unknownModeToken = nil }
    }
    public var unknownModeToken: String? = nil
    public var activityType: WorkoutActivityType? {
        didSet { unknownActivityTypeToken = nil }
    }
    public var unknownActivityTypeToken: String? = nil
    public var exercises: String
    public var rpe: Double?
    public var notes: String
    public var duration: Int?
    public var distanceMiles: Double?
    public var activeEnergyKcal: Double?
    public var effort: Int?
    public var muscleGroups: Set<MuscleGroup> = []
    public var unknownMuscleGroupTokens: [String] = []
    public var healthKitUUID: UUID?
    /// Provenance marker: `true` iff Fernlet itself AUTHORED the Health sample this row points at (we
    /// wrote it via `saveWorkout` and stamped the returned UUID — or our own sample came back through the
    /// workout observer carrying our `fernlet.workoutID`). It disambiguates the two very different reasons
    /// a row can carry a `healthKitUUID`: a genuine Apple Health *import* (some other app / a manual Health
    /// entry owns the sample — remove/edit must be refused, deleting our mirror would orphan + resurrect
    /// it) versus a Fernlet-*authored* sample (we own it, so remove deletes the Health copy and edit
    /// re-syncs it). `nil` on imports and on plain local rows; encoded only when set, so untagged rows
    /// stay byte-identical; never written `false`.
    public var healthKitAuthored: Bool?
    public var plannedWorkoutID: UUID?
    /// Provenance marker: `true` iff this row was logged by the guided-workout flow (the Move-root
    /// card runner, the Suggest sheet's runner, or its "Mark done"). It is what lets name-based
    /// reconciliation match ONLY the guided flow's own rows — a manual Log-sheet entry or a planned
    /// completion sharing a guided session's name ("Legs", "Push") must not make the guided card claim
    /// itself done or refuse a rework. `nil` on every non-guided row (and encoded only when set, so
    /// untagged rows stay byte-identical); never written `false`.
    public var loggedFromGuidedSession: Bool?
    public var intensity: WorkoutIntensity {
        didSet { unknownIntensityToken = nil }
    }
    public var unknownIntensityToken: String? = nil
    public var completedAt = Date()
    public var loggedAt = Date()
    /// What happened to each prescribed lift in a guided session — prescribed sets, reps and weight
    /// range, the weight picked, and the actual reps when they differed (``ExerciseResult``).
    /// Additive optional: nil on every row written before it existed, on hand-logged rows, and on
    /// guided rows from a run with nothing to record. Encoded only when set, so other rows stay
    /// byte-identical. The same facts are in `exercises` as text, so a build that drops this field
    /// on a re-save loses only the structure, never the record.
    public var exerciseResults: [ExerciseResult]?

    /// Results a decoded row may carry at most (R3: the field arrives from synced storage).
    public static let maxExerciseResults = 64

    public var exerciseLines: [String] {
        exercises
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The name a screen DRAWS for this row: ``name``, unless it is still a frozen English default,
    /// which is drawn in the user's language instead.
    ///
    /// An activity logged with a blank name is stored as ``WorkoutActivityType/defaultName`` ("Pool
    /// Swim"), and a completed plan carries a blank-named plan's ``WorkoutSplit/defaultPlanName``.
    /// Display only: never persist, export, prompt with or match against this. Exports, prompts,
    /// HealthKit's `fernlet.activityName`, the category inference and the guided reconciliation all
    /// read ``name``, and a name field seeded from this saves back through ``savedName(editing:)``.
    public var displayedName: String {
        StoredWorkoutName.displayed(name, mode: mode, activityType: activityType,
                                    matchesSplitDefault: plannedWorkoutID != nil,
                                    matchesPlannerSession: loggedFromGuidedSession == true)
    }

    /// The notes a screen DRAWS for this row: ``notes``, unless they are still a plan completion's
    /// frozen note ("Completed from user plan."), which is drawn in the user's language. Display only;
    /// `reconstructPlannedWorkout` matches the stored note (2026-10-20, idea 16).
    public var displayedNotes: String {
        WorkoutPlanSource.allCases.first { $0.completionNote == notes }?.completionNoteDisplay ?? notes
    }

    /// The name to SAVE when a name field seeded with ``displayedName`` comes back as `typed` (already
    /// trimmed): the stored ``name`` while the user left the drawn text alone, else what they typed.
    /// Opening and saving a row in another language never rewrites its stored default.
    public func savedName(editing typed: String) -> String {
        typed == displayedName ? name : typed
    }

    /// Genuinely Apple Health-owned: carries a `healthKitUUID` we did NOT author (an import from another
    /// app or a manual Health entry). Remove/edit are refused for these — our copy is a read-only mirror.
    public var isHealthImported: Bool { healthKitUUID != nil && healthKitAuthored != true }

    /// Fernlet authored this Health sample; Fernlet owns it, so remove deletes the Health copy and edit
    /// re-syncs it.
    public var isHealthAuthored: Bool { healthKitAuthored == true }

    public var inferredCategory: WorkoutType {
        if mode == .activity, let activityType {
            return activityType.fernletCategory
        }

        if !muscleGroups.isEmpty {
            let regions = muscleGroups.map { $0.region }
            let upper = regions.filter { $0 == .upper }.count
            let lower = regions.filter { $0 == .lower }.count
            let core = regions.filter { $0 == .core }.count
            let total = max(upper + lower + core, 1)

            if Double(upper) / Double(total) >= 0.7 { return .upper }
            if Double(lower) / Double(total) >= 0.7 { return .lower }
            if Double(core) / Double(total) >= 0.7 { return .fullBody }
            return .fullBody
        }

        return WorkoutExerciseCatalog.inferredCategory(for: self)
    }

    public init(
        id: UUID = UUID(),
        name: String,
        type: WorkoutType,
        mode: WorkoutMode = .strengthTraining,
        activityType: WorkoutActivityType? = nil,
        exercises: String,
        rpe: Double?,
        notes: String,
        duration: Int?,
        distanceMiles: Double? = nil,
        activeEnergyKcal: Double? = nil,
        effort: Int? = nil,
        muscleGroups: Set<MuscleGroup> = [],
        healthKitUUID: UUID? = nil,
        healthKitAuthored: Bool? = nil,
        plannedWorkoutID: UUID? = nil,
        loggedFromGuidedSession: Bool? = nil,
        intensity: WorkoutIntensity,
        completedAt: Date = Date(),
        loggedAt: Date? = nil,
        exerciseResults: [ExerciseResult]? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.mode = mode
        self.activityType = activityType
        self.exercises = exercises
        self.rpe = rpe
        self.notes = notes
        self.duration = duration
        self.distanceMiles = distanceMiles
        self.activeEnergyKcal = activeEnergyKcal
        self.effort = effort
        self.muscleGroups = muscleGroups
        self.healthKitUUID = healthKitUUID
        self.healthKitAuthored = healthKitAuthored
        self.plannedWorkoutID = plannedWorkoutID
        self.loggedFromGuidedSession = loggedFromGuidedSession
        self.intensity = intensity
        self.completedAt = completedAt
        self.loggedAt = loggedAt ?? completedAt
        self.exerciseResults = exerciseResults
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        // Required key (was strict `decode` pre-compat): absence is corruption, not a newer build.
        let typeSplit = try container.decodeTolerantRequiredEnum(
            WorkoutType.self, forKey: .type, parkedTokenKey: .unknownTypeToken, default: .fullBody)
        type = typeSplit.value
        unknownTypeToken = typeSplit.parkedToken
        let modeSplit = try container.decodeTolerantEnum(
            WorkoutMode.self, forKey: .mode, parkedTokenKey: .unknownModeToken, default: .strengthTraining)
        mode = modeSplit.value
        unknownModeToken = modeSplit.parkedToken
        let activitySplit = try container.decodeTolerantOptionalEnum(
            WorkoutActivityType.self, forKey: .activityType, parkedTokenKey: .unknownActivityTypeToken)
        activityType = activitySplit.value
        unknownActivityTypeToken = activitySplit.parkedToken
        exercises = try container.decode(String.self, forKey: .exercises)
        rpe = try container.decodeIfPresent(Double.self, forKey: .rpe)
        notes = try container.decode(String.self, forKey: .notes)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        distanceMiles = try container.decodeIfPresent(Double.self, forKey: .distanceMiles)
        activeEnergyKcal = try container.decodeIfPresent(Double.self, forKey: .activeEnergyKcal)
        effort = try container.decodeIfPresent(Int.self, forKey: .effort)
        let muscleSplit = try container.decodeTolerantEnumSet(
            MuscleGroup.self, forKey: .muscleGroups, parkedTokensKey: .unknownMuscleGroupTokens)
        muscleGroups = muscleSplit.known
        unknownMuscleGroupTokens = muscleSplit.unknownTokens
        healthKitUUID = try container.decodeIfPresent(UUID.self, forKey: .healthKitUUID)
        healthKitAuthored = try container.decodeIfPresent(Bool.self, forKey: .healthKitAuthored)
        plannedWorkoutID = try container.decodeIfPresent(UUID.self, forKey: .plannedWorkoutID)
        loggedFromGuidedSession = try container.decodeIfPresent(Bool.self, forKey: .loggedFromGuidedSession)
        // Required key (was strict `decode` pre-compat): absence is corruption, not a newer build.
        let intensitySplit = try container.decodeTolerantRequiredEnum(
            WorkoutIntensity.self, forKey: .intensity, parkedTokenKey: .unknownIntensityToken, default: .moderate)
        intensity = intensitySplit.value
        unknownIntensityToken = intensitySplit.parkedToken
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt) ?? Date()
        loggedAt = try container.decodeIfPresent(Date.self, forKey: .loggedAt) ?? completedAt
        exerciseResults = try container.decodeIfPresent([ExerciseResult].self, forKey: .exerciseResults)
            .map { Array($0.filter { !$0.name.isEmpty }.prefix(Self.maxExerciseResults)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(unknownTypeToken, forKey: .unknownTypeToken)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(unknownModeToken, forKey: .unknownModeToken)
        try container.encodeIfPresent(activityType, forKey: .activityType)
        try container.encodeIfPresent(unknownActivityTypeToken, forKey: .unknownActivityTypeToken)
        try container.encode(exercises, forKey: .exercises)
        try container.encodeIfPresent(rpe, forKey: .rpe)
        try container.encode(notes, forKey: .notes)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(distanceMiles, forKey: .distanceMiles)
        try container.encodeIfPresent(activeEnergyKcal, forKey: .activeEnergyKcal)
        try container.encodeIfPresent(effort, forKey: .effort)
        try container.encode(muscleGroups, forKey: .muscleGroups)
        try container.encode(unknownMuscleGroupTokens, forKey: .unknownMuscleGroupTokens)
        try container.encodeIfPresent(healthKitUUID, forKey: .healthKitUUID)
        // Encoded only when set (never written `false`), so untagged rows stay byte-identical.
        try container.encodeIfPresent(healthKitAuthored, forKey: .healthKitAuthored)
        try container.encodeIfPresent(plannedWorkoutID, forKey: .plannedWorkoutID)
        // Encoded only when set (never written `false`), so untagged rows stay byte-identical.
        try container.encodeIfPresent(loggedFromGuidedSession, forKey: .loggedFromGuidedSession)
        try container.encode(intensity, forKey: .intensity)
        try container.encodeIfPresent(unknownIntensityToken, forKey: .unknownIntensityToken)
        try container.encode(completedAt, forKey: .completedAt)
        try container.encode(loggedAt, forKey: .loggedAt)
        // Encoded only when set, so rows without results stay byte-identical.
        try container.encodeIfPresent(exerciseResults, forKey: .exerciseResults)
    }

    /// Persisted JSON keys for a logged ``Workout``'s wire format.
    ///
    /// Renaming a case is a data-format break; the optional tag keys (`healthKitAuthored`,
    /// `loggedFromGuidedSession`, `exerciseResults`) are encoded only when set so untagged rows stay
    /// byte-identical.
    private enum CodingKeys: String, CodingKey {
        case id, name, type, mode, activityType, exercises, rpe, notes, duration
        case distanceMiles, activeEnergyKcal, effort, muscleGroups, healthKitUUID, healthKitAuthored, plannedWorkoutID
        case loggedFromGuidedSession, exerciseResults
        case intensity, completedAt, loggedAt
        case unknownTypeToken, unknownModeToken, unknownActivityTypeToken
        case unknownMuscleGroupTokens, unknownIntensityToken
    }
}

/// A workout planned for a day but not yet done.
///
/// Same tolerant enum-decode contract as ``Workout``; `completedWorkout` mints the completion row,
/// linking back to the plan via `plannedWorkoutID`.
public nonisolated struct PlannedWorkout: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var name: String
    // Tolerant enum decode + parked-token side channels, same contract as `Workout` (EnumDecodeCompat).
    public var split: WorkoutSplit {
        didSet { unknownSplitToken = nil }
    }
    public var unknownSplitToken: String? = nil
    public var source: WorkoutPlanSource {
        didSet { unknownSourceToken = nil }
    }
    public var unknownSourceToken: String? = nil
    public var mode: WorkoutMode {
        didSet { unknownModeToken = nil }
    }
    public var unknownModeToken: String? = nil
    public var activityType: WorkoutActivityType? {
        didSet { unknownActivityTypeToken = nil }
    }
    public var unknownActivityTypeToken: String? = nil
    public var exercises: String
    public var muscleGroups: Set<MuscleGroup>
    public var unknownMuscleGroupTokens: [String] = []
    public var notes: String
    public var duration: Int?
    public var targetDistanceMiles: Double?
    public var targetEnergyKcal: Double?
    public var targetEffort: Int?
    public var createdAt = Date()

    public var workoutType: WorkoutType { split.workoutType }

    /// The prescription as individual lines, mirroring ``Workout/exerciseLines``.
    ///
    /// The two types store the same free-text shape, so anything that reads one line-by-line (the
    /// trainer export's planned-workout projection, the coach-plan change diff) can read both the
    /// same way instead of re-splitting the string at each call site.
    public var exerciseLines: [String] {
        exercises
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The name a screen DRAWS for this plan: ``name``, unless it is still a frozen English default
    /// (``WorkoutActivityType/defaultName`` or ``WorkoutSplit/defaultPlanName``, what the plan sheet
    /// saves for a blank name), which is drawn in the user's language instead.
    ///
    /// Display only, on the same terms as ``Workout/displayedName``: the trainer export, the
    /// exchange file, the coach-plan rename check and ``completedWorkout`` all carry ``name``.
    public var displayedName: String {
        StoredWorkoutName.displayed(name, mode: mode, activityType: activityType, matchesSplitDefault: true)
    }

    /// The name to SAVE when a name field seeded with ``displayedName`` comes back as `typed` (already
    /// trimmed), as ``Workout/savedName(editing:)`` does for a logged row.
    public func savedName(editing typed: String) -> String {
        typed == displayedName ? name : typed
    }

    public var completedWorkout: Workout {
        Workout(
            name: name,
            type: workoutType,
            mode: mode,
            activityType: activityType,
            exercises: exercises.isEmpty ? notes : exercises,
            rpe: nil,
            notes: source.completionNote,
            duration: duration,
            distanceMiles: targetDistanceMiles,
            activeEnergyKcal: targetEnergyKcal,
            effort: targetEffort,
            muscleGroups: muscleGroups,
            plannedWorkoutID: id,
            intensity: .moderate
        )
    }

    public init(
        id: UUID = UUID(),
        name: String,
        split: WorkoutSplit,
        source: WorkoutPlanSource,
        mode: WorkoutMode = .strengthTraining,
        activityType: WorkoutActivityType? = nil,
        exercises: String = "",
        muscleGroups: Set<MuscleGroup> = [],
        notes: String,
        duration: Int?,
        targetDistanceMiles: Double? = nil,
        targetEnergyKcal: Double? = nil,
        targetEffort: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.split = split
        self.source = source
        self.mode = mode
        self.activityType = activityType
        self.exercises = exercises
        self.muscleGroups = muscleGroups
        self.notes = notes
        self.duration = duration
        self.targetDistanceMiles = targetDistanceMiles
        self.targetEnergyKcal = targetEnergyKcal
        self.targetEffort = targetEffort
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        // Required key (was strict `decode` pre-compat): absence is corruption, not a newer build.
        let splitSplit = try container.decodeTolerantRequiredEnum(
            WorkoutSplit.self, forKey: .split, parkedTokenKey: .unknownSplitToken, default: .workout)
        split = splitSplit.value
        unknownSplitToken = splitSplit.parkedToken
        let sourceSplit = try container.decodeTolerantEnum(
            WorkoutPlanSource.self, forKey: .source, parkedTokenKey: .unknownSourceToken, default: .user)
        source = sourceSplit.value
        unknownSourceToken = sourceSplit.parkedToken
        let modeSplit = try container.decodeTolerantEnum(
            WorkoutMode.self, forKey: .mode, parkedTokenKey: .unknownModeToken, default: .strengthTraining)
        mode = modeSplit.value
        unknownModeToken = modeSplit.parkedToken
        let activitySplit = try container.decodeTolerantOptionalEnum(
            WorkoutActivityType.self, forKey: .activityType, parkedTokenKey: .unknownActivityTypeToken)
        activityType = activitySplit.value
        unknownActivityTypeToken = activitySplit.parkedToken
        exercises = try container.decodeIfPresent(String.self, forKey: .exercises) ?? ""
        let muscleSplit = try container.decodeTolerantEnumSet(
            MuscleGroup.self, forKey: .muscleGroups, parkedTokensKey: .unknownMuscleGroupTokens)
        muscleGroups = muscleSplit.known
        unknownMuscleGroupTokens = muscleSplit.unknownTokens
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        targetDistanceMiles = try container.decodeIfPresent(Double.self, forKey: .targetDistanceMiles)
        targetEnergyKcal = try container.decodeIfPresent(Double.self, forKey: .targetEnergyKcal)
        targetEffort = try container.decodeIfPresent(Int.self, forKey: .targetEffort)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    /// Persisted JSON keys for a ``PlannedWorkout`` template's wire format.
    ///
    /// Renaming a case is a data-format break; the `unknown*Token` keys carry the freeze/park
    /// round-trip values for enum cases a newer build wrote that this build doesn't know.
    private enum CodingKeys: String, CodingKey {
        case id, name, split, source, mode, activityType, exercises, muscleGroups, notes, duration
        case targetDistanceMiles, targetEnergyKcal, targetEffort, createdAt
        case unknownSplitToken, unknownSourceToken, unknownModeToken
        case unknownActivityTypeToken, unknownMuscleGroupTokens
    }
}

/// Who authored a planned workout: the user or a coach.
///
/// Drives the completion note text; decodes tolerantly on ``PlannedWorkout``.
public nonisolated enum WorkoutPlanSource: String, Codable, CaseIterable, Identifiable {
    case user
    case coach

    public var id: String { rawValue }

    /// Who made the plan, on screen (the planned row's tag), localized (2026-10-20, idea 16). Display
    /// only: ``rawValue`` is the persisted token.
    public var title: String {
        switch self {
        case .user: String(localized: "workoutPlanSource.user", defaultValue: "User", bundle: .module,
                           comment: "Tag on a planned workout the person planned themselves")
        case .coach: String(localized: "workoutPlanSource.coach", defaultValue: "Coach", bundle: .module,
                            comment: "Tag on a planned workout that came from a coach's plan")
        }
    }

    /// The FROZEN note a completed plan's logged row is saved with. `reconstructPlannedWorkout`
    /// matches it to rebuild the plan when the completion is removed, so it stays English; screens
    /// draw ``Workout/displayedNotes``.
    public var completionNote: String {
        switch self {
        case .user: "Completed from user plan."
        case .coach: "Completed from coach plan."
        }
    }

    /// ``completionNote`` on screen, localized.
    public var completionNoteDisplay: String {
        switch self {
        case .user: String(localized: "workoutPlanSource.user.completionNote", defaultValue: "Completed from user plan.",
                           bundle: .module, comment: "Note on a logged workout that was completed from the person's own plan")
        case .coach: String(localized: "workoutPlanSource.coach.completionNote", defaultValue: "Completed from coach plan.",
                            bundle: .module, comment: "Note on a logged workout that was completed from a coach's plan")
        }
    }
}

/// The split label a planned workout belongs to (upper, push, legs, cardio, …).
///
/// Maps down to the coarser ``WorkoutType`` for scoring/history via `workoutType`; decodes
/// tolerantly on ``PlannedWorkout``.
public nonisolated enum WorkoutSplit: String, Codable, CaseIterable, Identifiable {
    case workout
    case upper
    case lower
    case fullBody
    case push
    case pull
    case legs
    case cardio
    case recovery

    public var id: String { rawValue }

    /// The localized split name, for screens only.
    ///
    /// `rawValue` is the token: it persists on ``PlannedWorkout`` (with a parked-token side
    /// channel) and it is the value the trainer export's `split` field must carry, because a coach
    /// re-importing that file has to get the same split back regardless of what language the
    /// exporting device was running. Prompts and exports read `rawValue`; only screens read this.
    public var title: String {
        switch self {
        case .workout: String(localized: "split.workout", defaultValue: "Workout",
                              bundle: .module, comment: "Workout split name: a generic session")
        case .upper: String(localized: "split.upper", defaultValue: "Upper",
                            bundle: .module, comment: "Workout split name: upper body")
        case .lower: String(localized: "split.lower", defaultValue: "Lower",
                            bundle: .module, comment: "Workout split name: lower body")
        case .fullBody: String(localized: "split.fullBody", defaultValue: "Full Body",
                               bundle: .module, comment: "Workout split name: whole body")
        case .push: String(localized: "split.push", defaultValue: "Push",
                           bundle: .module, comment: "Workout split name: pushing movements")
        case .pull: String(localized: "split.pull", defaultValue: "Pull",
                           bundle: .module, comment: "Workout split name: pulling movements")
        case .legs: String(localized: "split.legs", defaultValue: "Legs",
                           bundle: .module, comment: "Workout split name: legs")
        case .cardio: String(localized: "split.cardio", defaultValue: "Cardio",
                             bundle: .module, comment: "Workout split name: cardio")
        case .recovery: String(localized: "split.recovery", defaultValue: "Recovery",
                               bundle: .module, comment: "Workout split name: recovery / mobility")
        }
    }

    public var workoutType: WorkoutType {
        switch self {
        case .workout: .cardio
        case .upper, .push, .pull: .upper
        case .lower, .legs: .lower
        case .fullBody, .recovery: .fullBody
        case .cardio: .cardio
        }
    }

    /// The FROZEN name a plan of this split is SAVED under when the plan sheet's name field is left
    /// blank ("upper workout", "fullBody workout"). Never localize it.
    ///
    /// It is `PlannedWorkout.name` on every such plan, a completed plan carries it onto the logged
    /// `Workout.name`, and `WorkoutExerciseCatalog.inferredCategory(for:)` keyword-matches the name,
    /// so a localized spelling would have the same plan file under a different category on a device
    /// set to another language. The raw value is the token in it, not the title, which is why the
    /// English reads "fullBody workout". Screens read ``defaultPlanDisplayName``.
    public var defaultPlanName: String { "\(rawValue) workout" }

    /// The localized form of ``defaultPlanName``, for screens only: the plan sheet's name placeholder,
    /// and a row whose stored name is still the default (``PlannedWorkout/displayedName``,
    /// ``Workout/displayedName``). Never persist or match it.
    public var defaultPlanDisplayName: String {
        String(localized: "split.defaultPlanName", defaultValue: "\(title) workout", bundle: .module,
               comment: "The name a planned workout takes when its name is left blank. The argument is the split's name, e.g. 'Upper' or 'Full Body'.")
    }

    /// The split whose ``defaultPlanName`` is exactly `name`, or nil when `name` is anything else.
    public static func savingDefaultPlanName(_ name: String) -> WorkoutSplit? {
        allCases.first { $0.defaultPlanName == name }
    }
}

/// The one mapping from a STORED workout or plan name to the name a screen draws.
///
/// A blank name field saves a frozen English default (``WorkoutActivityType/defaultName``,
/// ``WorkoutSplit/defaultPlanName``) because the name is persisted, synced, written to Health and
/// keyword-matched. Drawn as stored, it reads English on every translated device. This swaps a
/// stored default for its localized form at draw time, and leaves every other name, including any
/// the user typed, exactly as it is. Display only: what it returns is never persisted, exported,
/// put in a prompt or matched against; those read `name`.
///
/// The planner's session names are the third kind of stored default (2026-10-20, idea 16): a guided
/// session is logged under its frozen English name ("Full Body A", "Morning · Easy cardio"), which the
/// rotation and the guided reconciliation match, and a row the guided flow logged draws it through
/// ``WorkoutSessionNames``.
nonisolated enum StoredWorkoutName {
    /// The name to draw for a row stored as `name`.
    ///
    /// `matchesSplitDefault` is whether the row can carry a split default at all: every plan can,
    /// and a logged workout only when a plan's completion minted it (`plannedWorkoutID` is set).
    /// `matchesPlannerSession` is whether it can carry a planner session's name: only a row the
    /// guided flow logged (`loggedFromGuidedSession`), so a hand-logged "Push" stays the user's own.
    static func displayed(_ name: String, mode: WorkoutMode, activityType: WorkoutActivityType?,
                          matchesSplitDefault: Bool, matchesPlannerSession: Bool = false) -> String {
        if mode == .activity, let activityType, name == activityType.defaultName {
            return activityType.displayName
        }
        if matchesSplitDefault, let split = WorkoutSplit.savingDefaultPlanName(name) {
            return split.defaultPlanDisplayName
        }
        if matchesPlannerSession, let session = WorkoutSessionNames.displayed(name) {
            return session
        }
        return name
    }
}

/// The coarse workout category used in history and scoring.
///
/// NOTE: `allCases` is deliberately overridden to only the four current categories — the legacy
/// cases (`armsBack`, `mixed`, `run`, `hike`) stay decodable for old rows but are excluded from
/// pickers and any `allCases` iteration.
public nonisolated enum WorkoutType: String, Codable, CaseIterable, Identifiable, Sendable {
    case upper = "Upper"
    case lower = "Lower"
    case armsBack = "Arms/Back"
    case mixed = "Upper/Mixed"
    case fullBody = "Full Body"
    case cardio = "Cardio"
    case run = "C210K Run"
    case hike = "Hike"

    public nonisolated static let allCases: [WorkoutType] = [.upper, .lower, .fullBody, .cardio]

    public var id: String { rawValue }

    /// The localized category name.
    ///
    /// This enum had no display property at all: `rawValue` WAS the on-screen text, so screens,
    /// storage, and the model prompt were all reading one string. `rawValue` is FROZEN — it is the
    /// persisted category on every workout row (including the four legacy spellings kept decodable
    /// above), the vocabulary `WorkoutExerciseCatalog.inferType` matches against, and part of the
    /// trainer export. `displayName` is the new, and only, reader-facing half.
    ///
    /// The legacy cases keep their literal spellings as the English default. They never appear in a
    /// picker (see the `allCases` override) and surface only on history rows old enough to still
    /// carry them, so they get a key each — a translator can render them, but nothing depends on
    /// what comes back.
    public var displayName: String {
        switch self {
        case .upper: String(localized: "workoutType.upper", defaultValue: "Upper",
                            bundle: .module, comment: "Workout category: upper body")
        case .lower: String(localized: "workoutType.lower", defaultValue: "Lower",
                            bundle: .module, comment: "Workout category: lower body")
        case .armsBack: String(localized: "workoutType.armsBack", defaultValue: "Arms/Back",
                               bundle: .module, comment: "Legacy workout category, history rows only")
        case .mixed: String(localized: "workoutType.mixed", defaultValue: "Upper/Mixed",
                            bundle: .module, comment: "Legacy workout category, history rows only")
        case .fullBody: String(localized: "workoutType.fullBody", defaultValue: "Full Body",
                               bundle: .module, comment: "Workout category: whole body")
        case .cardio: String(localized: "workoutType.cardio", defaultValue: "Cardio",
                             bundle: .module, comment: "Workout category: cardio")
        case .run: String(localized: "workoutType.run", defaultValue: "C210K Run",
                          bundle: .module, comment: "Legacy workout category (Couch to 10K), history rows only")
        case .hike: String(localized: "workoutType.hike", defaultValue: "Hike",
                           bundle: .module, comment: "Legacy workout category, history rows only")
        }
    }
}

/// Whether a workout is strength training or a named activity/class.
///
/// Switches which fields the logging UI expects (exercise lines vs ``WorkoutActivityType``);
/// decodes tolerantly where persisted.
public nonisolated enum WorkoutMode: String, Codable, CaseIterable, Identifiable {
    case strengthTraining
    case activity

    public var id: String { rawValue }

    /// The localized chip label in the log/plan sheets' "Kind" row. Display only: `rawValue` is the
    /// persisted token.
    ///
    /// `.activity` says "Cardio & activity" rather than the old "Workouts": inside a sheet titled
    /// "Log workout", a chip called Workouts read as "everything" instead of "the non-strength one".
    public var label: String {
        switch self {
        case .strengthTraining: String(localized: "workoutMode.strengthTraining", defaultValue: "Strength Training",
                                       bundle: .module, comment: "Workout kind chip: weights and exercise lines")
        case .activity: String(localized: "workoutMode.activity", defaultValue: "Cardio & activity",
                               bundle: .module, comment: "Workout kind chip: a named activity or class, e.g. running or yoga")
        }
    }
}

/// The coarse body region a muscle belongs to (upper/lower/core/full).
///
/// Derived from ``MuscleGroup``'s `region`; used to infer a workout's category from its muscle mix
/// and to match program slots by region.
public nonisolated enum BodyRegion: String, Codable, CaseIterable, Sendable {
    case upper
    case lower
    case core
    case full
}

/// The granular muscle taxonomy exercises target and injuries avoid.
///
/// Persisted in day rows AND in the safety-relevant ``WorkoutProfile`` avoided-muscles set, so
/// both decode tolerantly with parked tokens (dropping an avoided muscle would silently un-avoid
/// it). `fromLegacyString` maps the old coarse strings from early catalogs.
public nonisolated enum MuscleGroup: String, Codable, CaseIterable, Identifiable, Sendable {
    case chest
    case upperBack
    case lats
    case lowerBack
    case traps
    case frontDelts
    case sideDelts
    case rearDelts
    case biceps
    case triceps
    case forearms
    case abs
    case obliques
    case quads
    case hamstrings
    case glutes
    case calves
    case adductors
    case abductors
    case fullBody

    public var id: String { rawValue }

    /// The localized muscle name, for screens only.
    ///
    /// `rawValue` is the token: it is what persists on day rows and in the safety-relevant
    /// ``WorkoutProfile`` avoided-muscles set, what the AI prompt quotes as vocabulary, and what
    /// `CoachPlanTokens.muscleVocabulary` publishes to plan authors. A prompt, an export, or a
    /// matcher that reaches for this property instead of `rawValue` starts producing a different
    /// string per language — see `CoachPlanTokens.muscle(_:)`, which had to freeze an English alias
    /// table precisely because it used to match against this.
    public var displayName: String {
        switch self {
        case .chest: String(localized: "muscle.chest", defaultValue: "Chest",
                            bundle: .module, comment: "Muscle group name")
        case .upperBack: String(localized: "muscle.upperBack", defaultValue: "Upper Back",
                                bundle: .module, comment: "Muscle group name")
        case .lats: String(localized: "muscle.lats", defaultValue: "Lats",
                           bundle: .module, comment: "Muscle group name (latissimus dorsi)")
        case .lowerBack: String(localized: "muscle.lowerBack", defaultValue: "Lower Back",
                                bundle: .module, comment: "Muscle group name")
        case .traps: String(localized: "muscle.traps", defaultValue: "Traps",
                            bundle: .module, comment: "Muscle group name (trapezius)")
        case .frontDelts: String(localized: "muscle.frontDelts", defaultValue: "Front Delts",
                                 bundle: .module, comment: "Muscle group name (anterior deltoids)")
        case .sideDelts: String(localized: "muscle.sideDelts", defaultValue: "Side Delts",
                                bundle: .module, comment: "Muscle group name (lateral deltoids)")
        case .rearDelts: String(localized: "muscle.rearDelts", defaultValue: "Rear Delts",
                                bundle: .module, comment: "Muscle group name (posterior deltoids)")
        case .biceps: String(localized: "muscle.biceps", defaultValue: "Biceps",
                             bundle: .module, comment: "Muscle group name")
        case .triceps: String(localized: "muscle.triceps", defaultValue: "Triceps",
                              bundle: .module, comment: "Muscle group name")
        case .forearms: String(localized: "muscle.forearms", defaultValue: "Forearms",
                               bundle: .module, comment: "Muscle group name")
        case .abs: String(localized: "muscle.abs", defaultValue: "Abs",
                          bundle: .module, comment: "Muscle group name (abdominals)")
        case .obliques: String(localized: "muscle.obliques", defaultValue: "Obliques",
                               bundle: .module, comment: "Muscle group name")
        case .quads: String(localized: "muscle.quads", defaultValue: "Quads",
                            bundle: .module, comment: "Muscle group name (quadriceps)")
        case .hamstrings: String(localized: "muscle.hamstrings", defaultValue: "Hamstrings",
                                 bundle: .module, comment: "Muscle group name")
        case .glutes: String(localized: "muscle.glutes", defaultValue: "Glutes",
                             bundle: .module, comment: "Muscle group name")
        case .calves: String(localized: "muscle.calves", defaultValue: "Calves",
                             bundle: .module, comment: "Muscle group name")
        case .adductors: String(localized: "muscle.adductors", defaultValue: "Adductors",
                                bundle: .module, comment: "Muscle group name (inner thigh)")
        case .abductors: String(localized: "muscle.abductors", defaultValue: "Abductors",
                                bundle: .module, comment: "Muscle group name (outer hip)")
        case .fullBody: String(localized: "muscle.fullBody", defaultValue: "Full Body",
                               bundle: .module, comment: "Muscle group name covering the whole body")
        }
    }

    public var region: BodyRegion {
        switch self {
        case .chest, .upperBack, .lats, .lowerBack, .traps, .frontDelts, .sideDelts, .rearDelts, .biceps, .triceps, .forearms:
            .upper
        case .quads, .hamstrings, .glutes, .calves, .adductors, .abductors:
            .lower
        case .abs, .obliques:
            .core
        case .fullBody:
            .full
        }
    }
}

extension MuscleGroup {
    nonisolated public static func fromLegacyString(_ s: String) -> MuscleGroup? {
        switch s.lowercased() {
        case "chest": .chest
        case "triceps": .triceps
        case "biceps": .biceps
        case "shoulders": .frontDelts
        case "back": .upperBack
        case "lats": .lats
        case "core": .abs
        case "quads": .quads
        case "hamstrings": .hamstrings
        case "glutes": .glutes
        case "calves": .calves
        case "full body": .fullBody
        case "legs": .quads
        case "cardio", "mobility", "balance", "coordination", "sport", "class": nil
        default: nil
        }
    }
}

/// The biomechanical pattern of an exercise (push, pull, hinge, squat, …).
///
/// The unit of both slot matching in the program engine and movement-level contraindications in
/// ``WorkoutProfile``; also keys rest demand in ``WorkoutRestGuidance``.
public nonisolated enum MovementPattern: String, Codable, CaseIterable, Sendable {
    case push
    case pull
    case hinge
    case squat
    case lunge
    case carry
    case twist
    case isolation
    case locomotion
}

/// The coarse equipment capability the planning engine reasons about.
///
/// User-facing granular gear (``GymEquipment``) maps down onto these; the safety filter checks
/// that a ``WorkoutLocation`` has an exercise's capability before it can be prescribed.
public nonisolated enum Equipment: String, Codable, CaseIterable, Identifiable, Sendable {
    case barbell
    case dumbbell
    case machine
    case cable
    case bodyweight
    case kettlebell
    case band
    case bench
    case cardio
    case none

    public var id: String { rawValue }

    /// The localized equipment name, for screens only.
    ///
    /// `rawValue` is the token: it persists on ``WorkoutLocation``/catalog rows, it is what
    /// `CoachPlanTokens.equipmentVocabulary` publishes to plan authors, and it is what the trainer
    /// export must carry. Same warning as ``MuscleGroup/displayName`` — a prompt or export site
    /// reading this property produces a different string per language, and
    /// `CoachPlanTokens.equipment(_:)` had to freeze an English alias table because it used to
    /// match against it.
    public var displayName: String {
        switch self {
        case .barbell: String(localized: "equipment.barbell", defaultValue: "Barbell",
                              bundle: .module, comment: "Gym equipment category")
        case .dumbbell: String(localized: "equipment.dumbbell", defaultValue: "Dumbbell",
                               bundle: .module, comment: "Gym equipment category")
        case .machine: String(localized: "equipment.machine", defaultValue: "Machine",
                              bundle: .module, comment: "Gym equipment category: a weight machine")
        case .cable: String(localized: "equipment.cable", defaultValue: "Cable",
                            bundle: .module, comment: "Gym equipment category: a cable machine")
        case .bodyweight: String(localized: "equipment.bodyweight", defaultValue: "Bodyweight",
                                 bundle: .module, comment: "Gym equipment category: no equipment, own bodyweight")
        case .kettlebell: String(localized: "equipment.kettlebell", defaultValue: "Kettlebell",
                                 bundle: .module, comment: "Gym equipment category")
        case .band: String(localized: "equipment.band", defaultValue: "Band",
                           bundle: .module, comment: "Gym equipment category: a resistance band")
        case .bench: String(localized: "equipment.bench", defaultValue: "Bench",
                            bundle: .module, comment: "Gym equipment category: a weight bench")
        case .cardio: String(localized: "equipment.cardio", defaultValue: "Cardio",
                             bundle: .module, comment: "Gym equipment category: cardio machines")
        case .none: String(localized: "equipment.none", defaultValue: "None",
                           bundle: .module, comment: "Gym equipment category: none required")
        }
    }
}

/// The named activity/class taxonomy (running, yoga, pickleball, …) mirroring HealthKit's workout
/// types.
///
/// Carries the per-activity UI defaults (symbol, expected distance/pace, default duration) and
/// folds to a coarse ``WorkoutType`` via `fernletCategory`. Decodes tolerantly where persisted on
/// workout rows.
public nonisolated enum WorkoutActivityType: String, Codable, CaseIterable, Identifiable {
    case running, walking, hiking, cycling, indoorCycling
    case yoga, pilates, barre, dance, socialDance
    case swimmingPool, swimmingOpenWater, rowing, elliptical, stairClimbing, stairs
    case hiit, kickboxing, martialArts, climbing, jumpRope
    case tennis, basketball, soccer, pickleball, badminton, tableTennis, racquetball, squash
    case coreTraining, flexibility, mindAndBody, taiChi
    case functionalStrengthTraining, traditionalStrengthTraining
    case crossTraining, mixedCardio, preparationAndRecovery, cooldown
    case other

    public var id: String { rawValue }

    /// The FROZEN English name a workout of this type is SAVED under. Never localize it.
    ///
    /// It becomes `Workout.name` when the log sheet's name field is left blank,
    /// `PlannedWorkout.name` and `PlannedWorkout.exercises` when the plan sheet's is, and
    /// `Workout.name` on a Health import from another app (Fernlet's own samples carry their name in
    /// `fernlet.activityName`). Every one of those is persisted on a synced row, and the workout row
    /// and week calendar label a logged workout's category with
    /// `WorkoutExerciseCatalog.inferredCategory(for:)`, which keyword-matches ENGLISH words in the
    /// name and exercise text ("Mixed Cardio" files under Cardio by its name alone). A localized name
    /// would rebuild the same Health sample under a different name on two devices set to different
    /// languages, and file the same workout under a different category on each. Screens read
    /// ``displayName``.
    public var defaultName: String {
        switch self {
        case .running: "Running"
        case .walking: "Walking"
        case .hiking: "Hiking"
        case .cycling: "Cycling"
        case .indoorCycling: "Indoor Cycling"
        case .yoga: "Yoga"
        case .pilates: "Pilates"
        case .barre: "Barre"
        case .dance: "Dance"
        case .socialDance: "Social Dance"
        case .swimmingPool: "Pool Swim"
        case .swimmingOpenWater: "Open Water Swim"
        case .rowing: "Rowing"
        case .elliptical: "Elliptical"
        case .stairClimbing: "Stair Climbing"
        case .stairs: "Stairs"
        case .hiit: "HIIT"
        case .kickboxing: "Kickboxing"
        case .martialArts: "Martial Arts"
        case .climbing: "Climbing"
        case .jumpRope: "Jump Rope"
        case .tennis: "Tennis"
        case .basketball: "Basketball"
        case .soccer: "Soccer"
        case .pickleball: "Pickleball"
        case .badminton: "Badminton"
        case .tableTennis: "Table Tennis"
        case .racquetball: "Racquetball"
        case .squash: "Squash"
        case .coreTraining: "Core Training"
        case .flexibility: "Flexibility"
        case .mindAndBody: "Mind and Body"
        case .taiChi: "Tai Chi"
        case .functionalStrengthTraining: "Functional Strength Training"
        case .traditionalStrengthTraining: "Traditional Strength Training"
        case .crossTraining: "Cross Training"
        case .mixedCardio: "Mixed Cardio"
        case .preparationAndRecovery: "Preparation and Recovery"
        case .cooldown: "Cooldown"
        case .other: "Other"
        }
    }

    /// The localized activity name, for screens only: the activity picker, the chosen-activity row,
    /// the "Log it again" summary, the name field's placeholder, and any row whose stored name is
    /// still ``defaultName`` (``Workout/displayedName``). Never persist or match it — a workout saved
    /// with a blank name takes ``defaultName``.
    ///
    /// One case per line, unlike the two-line siblings: forty cases at two lines each exceed rule
    /// 4's 60-line body, which is met by formatting here because the extractor only harvests a
    /// literal written inside `String(localized:)` itself, so the calls cannot move into a helper.
    public var displayName: String {
        switch self {
        case .running: String(localized: "activityType.running", defaultValue: "Running", bundle: .module, comment: "Workout activity type: running, outdoors or on a treadmill")
        case .walking: String(localized: "activityType.walking", defaultValue: "Walking", bundle: .module, comment: "Workout activity type: walking")
        case .hiking: String(localized: "activityType.hiking", defaultValue: "Hiking", bundle: .module, comment: "Workout activity type: hiking on trails")
        case .cycling: String(localized: "activityType.cycling", defaultValue: "Cycling", bundle: .module, comment: "Workout activity type: cycling outdoors")
        case .indoorCycling: String(localized: "activityType.indoorCycling", defaultValue: "Indoor Cycling", bundle: .module, comment: "Workout activity type: cycling on a stationary bike or spin class")
        case .yoga: String(localized: "activityType.yoga", defaultValue: "Yoga", bundle: .module, comment: "Workout activity type: yoga")
        case .pilates: String(localized: "activityType.pilates", defaultValue: "Pilates", bundle: .module, comment: "Workout activity type: Pilates")
        case .barre: String(localized: "activityType.barre", defaultValue: "Barre", bundle: .module, comment: "Workout activity type: barre, a ballet-inspired fitness class")
        case .dance: String(localized: "activityType.dance", defaultValue: "Dance", bundle: .module, comment: "Workout activity type: dance as a cardio workout")
        case .socialDance: String(localized: "activityType.socialDance", defaultValue: "Social Dance", bundle: .module, comment: "Workout activity type: social or partner dancing, e.g. salsa or swing")
        case .swimmingPool: String(localized: "activityType.swimmingPool", defaultValue: "Pool Swim", bundle: .module, comment: "Workout activity type: swimming in a pool")
        case .swimmingOpenWater: String(localized: "activityType.swimmingOpenWater", defaultValue: "Open Water Swim", bundle: .module, comment: "Workout activity type: swimming in a lake or the sea")
        case .rowing: String(localized: "activityType.rowing", defaultValue: "Rowing", bundle: .module, comment: "Workout activity type: rowing, on water or a rowing machine")
        case .elliptical: String(localized: "activityType.elliptical", defaultValue: "Elliptical", bundle: .module, comment: "Workout activity type: the elliptical trainer machine")
        case .stairClimbing: String(localized: "activityType.stairClimbing", defaultValue: "Stair Climbing", bundle: .module, comment: "Workout activity type: a stair-climbing machine")
        case .stairs: String(localized: "activityType.stairs", defaultValue: "Stairs", bundle: .module, comment: "Workout activity type: climbing real flights of stairs")
        case .hiit: String(localized: "activityType.hiit", defaultValue: "HIIT", bundle: .module, comment: "Workout activity type: high-intensity interval training")
        case .kickboxing: String(localized: "activityType.kickboxing", defaultValue: "Kickboxing", bundle: .module, comment: "Workout activity type: kickboxing")
        case .martialArts: String(localized: "activityType.martialArts", defaultValue: "Martial Arts", bundle: .module, comment: "Workout activity type: martial arts")
        case .climbing: String(localized: "activityType.climbing", defaultValue: "Climbing", bundle: .module, comment: "Workout activity type: rock or wall climbing")
        case .jumpRope: String(localized: "activityType.jumpRope", defaultValue: "Jump Rope", bundle: .module, comment: "Workout activity type: skipping with a jump rope")
        case .tennis: String(localized: "activityType.tennis", defaultValue: "Tennis", bundle: .module, comment: "Workout activity type: tennis")
        case .basketball: String(localized: "activityType.basketball", defaultValue: "Basketball", bundle: .module, comment: "Workout activity type: basketball")
        case .soccer: String(localized: "activityType.soccer", defaultValue: "Soccer", bundle: .module, comment: "Workout activity type: soccer (association football)")
        case .pickleball: String(localized: "activityType.pickleball", defaultValue: "Pickleball", bundle: .module, comment: "Workout activity type: pickleball, the paddle sport")
        case .badminton: String(localized: "activityType.badminton", defaultValue: "Badminton", bundle: .module, comment: "Workout activity type: badminton")
        case .tableTennis: String(localized: "activityType.tableTennis", defaultValue: "Table Tennis", bundle: .module, comment: "Workout activity type: table tennis")
        case .racquetball: String(localized: "activityType.racquetball", defaultValue: "Racquetball", bundle: .module, comment: "Workout activity type: racquetball")
        case .squash: String(localized: "activityType.squash", defaultValue: "Squash", bundle: .module, comment: "Workout activity type: squash, the racket sport")
        case .coreTraining: String(localized: "activityType.coreTraining", defaultValue: "Core Training", bundle: .module, comment: "Workout activity type: core training, e.g. abs and planks")
        case .flexibility: String(localized: "activityType.flexibility", defaultValue: "Flexibility", bundle: .module, comment: "Workout activity type: flexibility and stretching")
        case .mindAndBody: String(localized: "activityType.mindAndBody", defaultValue: "Mind and Body", bundle: .module, comment: "Workout activity type: meditation, breathwork and similar practice")
        case .taiChi: String(localized: "activityType.taiChi", defaultValue: "Tai Chi", bundle: .module, comment: "Workout activity type: tai chi")
        case .functionalStrengthTraining: String(localized: "activityType.functionalStrengthTraining", defaultValue: "Functional Strength Training", bundle: .module, comment: "Workout activity type: functional strength training")
        case .traditionalStrengthTraining: String(localized: "activityType.traditionalStrengthTraining", defaultValue: "Traditional Strength Training", bundle: .module, comment: "Workout activity type: traditional strength training with weights")
        case .crossTraining: String(localized: "activityType.crossTraining", defaultValue: "Cross Training", bundle: .module, comment: "Workout activity type: cross training")
        case .mixedCardio: String(localized: "activityType.mixedCardio", defaultValue: "Mixed Cardio", bundle: .module, comment: "Workout activity type: mixed cardio")
        case .preparationAndRecovery: String(localized: "activityType.preparationAndRecovery", defaultValue: "Preparation and Recovery", bundle: .module, comment: "Workout activity type: warm-up, mobility and recovery work")
        case .cooldown: String(localized: "activityType.cooldown", defaultValue: "Cooldown", bundle: .module, comment: "Workout activity type: a cool-down after a workout")
        case .other: String(localized: "activityType.other", defaultValue: "Other", bundle: .module, comment: "Workout activity type: any activity not in the list")
        }
    }

    public var systemImage: String {
        switch self {
        case .running: "figure.run"
        case .walking: "figure.walk"
        case .hiking: "figure.hiking"
        case .cycling, .indoorCycling: "figure.outdoor.cycle"
        case .yoga, .mindAndBody: "figure.mind.and.body"
        case .pilates: "figure.pilates"
        case .barre: "figure.barre"
        case .dance, .socialDance: "figure.dance"
        case .swimmingPool, .swimmingOpenWater: "figure.pool.swim"
        case .rowing: "figure.rower"
        case .elliptical: "figure.elliptical"
        case .stairClimbing, .stairs: "figure.stairs"
        case .hiit, .crossTraining, .mixedCardio: "figure.highintensity.intervaltraining"
        case .kickboxing: "figure.kickboxing"
        case .martialArts: "figure.martial.arts"
        case .climbing: "figure.climbing"
        case .jumpRope: "figure.jumprope"
        case .tennis: "figure.tennis"
        case .basketball: "figure.basketball"
        case .soccer: "figure.soccer"
        case .pickleball: "figure.pickleball"
        case .badminton: "figure.badminton"
        case .tableTennis: "figure.table.tennis"
        case .racquetball: "figure.racquetball"
        case .squash: "figure.squash"
        case .coreTraining: "figure.core.training"
        case .flexibility, .cooldown, .preparationAndRecovery: "figure.flexibility"
        case .taiChi: "figure.taichi"
        case .functionalStrengthTraining, .traditionalStrengthTraining: "figure.strengthtraining.traditional"
        case .other: "figure.mixed.cardio"
        }
    }

    public var expectsDistance: Bool {
        switch self {
        case .running, .walking, .hiking, .cycling, .swimmingPool, .swimmingOpenWater, .rowing:
            true
        case .indoorCycling, .yoga, .pilates, .barre, .dance, .socialDance, .elliptical, .stairClimbing, .stairs, .hiit, .kickboxing, .martialArts, .climbing, .jumpRope, .tennis, .basketball, .soccer, .pickleball, .badminton, .tableTennis, .racquetball, .squash, .coreTraining, .flexibility, .mindAndBody, .taiChi, .functionalStrengthTraining, .traditionalStrengthTraining, .crossTraining, .mixedCardio, .preparationAndRecovery, .cooldown, .other:
            false
        }
    }

    public var expectsPace: Bool {
        switch self {
        case .running, .walking, .hiking:
            true
        case .cycling, .indoorCycling, .yoga, .pilates, .barre, .dance, .socialDance, .swimmingPool, .swimmingOpenWater, .rowing, .elliptical, .stairClimbing, .stairs, .hiit, .kickboxing, .martialArts, .climbing, .jumpRope, .tennis, .basketball, .soccer, .pickleball, .badminton, .tableTennis, .racquetball, .squash, .coreTraining, .flexibility, .mindAndBody, .taiChi, .functionalStrengthTraining, .traditionalStrengthTraining, .crossTraining, .mixedCardio, .preparationAndRecovery, .cooldown, .other:
            false
        }
    }

    public var defaultDurationMinutes: Int {
        switch self {
        case .functionalStrengthTraining, .traditionalStrengthTraining:
            30
        case .yoga, .pilates, .barre, .flexibility, .mindAndBody, .taiChi:
            60
        case .running, .walking, .hiking, .cycling, .indoorCycling, .dance, .socialDance, .swimmingPool, .swimmingOpenWater, .rowing, .elliptical, .stairClimbing, .stairs, .hiit, .kickboxing, .martialArts, .climbing, .jumpRope, .tennis, .basketball, .soccer, .pickleball, .badminton, .tableTennis, .racquetball, .squash, .coreTraining, .crossTraining, .mixedCardio, .preparationAndRecovery, .cooldown, .other:
            45
        }
    }

    public var fernletCategory: WorkoutType {
        switch self {
        case .running, .walking, .hiking, .cycling, .indoorCycling, .swimmingPool, .swimmingOpenWater, .rowing, .elliptical, .stairClimbing, .stairs, .jumpRope, .hiit, .crossTraining, .mixedCardio, .tennis, .basketball, .soccer, .pickleball, .badminton, .tableTennis, .racquetball, .squash:
            .cardio
        case .yoga, .pilates, .barre, .dance, .socialDance, .flexibility, .mindAndBody, .taiChi, .coreTraining, .functionalStrengthTraining, .traditionalStrengthTraining, .other, .preparationAndRecovery, .cooldown, .kickboxing, .martialArts, .climbing:
            .fullBody
        }
    }
}

/// The day's training energy (light/moderate/hard).
///
/// Adjusts prescribed set counts by ±1 in ``WorkoutGoalStyle``'s `adjustedSets`; decodes
/// tolerantly on ``Workout``.
public nonisolated enum WorkoutIntensity: String, Codable, CaseIterable, Identifiable {
    case light, moderate, hard
    public var id: String { rawValue }

    /// The localized intensity word for screens, lowercase so it sits mid-sentence
    /// ("built for a hard day", "Today's readiness suggests light.").
    ///
    /// `rawValue` is the token: it persists on ``Workout`` (Codable raw value) and is the
    /// vocabulary AI prompts and exports carry, so it stays English forever — only screens read
    /// this property. Resolved against `.module`, because inside an SPM module a bare
    /// `String(localized:)` looks up `Bundle.main` and renders English forever with a clean build.
    public var displayWord: String {
        switch self {
        case .light: String(localized: "workoutIntensity.light", defaultValue: "light",
                            bundle: .module, comment: "Workout intensity, mid-sentence: an easy day")
        case .moderate: String(localized: "workoutIntensity.moderate", defaultValue: "moderate",
                               bundle: .module, comment: "Workout intensity, mid-sentence: an average day")
        case .hard: String(localized: "workoutIntensity.hard", defaultValue: "hard",
                           bundle: .module, comment: "Workout intensity, mid-sentence: a demanding day")
        }
    }
}

/// What logging inputs an exercise expects (strength sets, treadmill fields, or none).
///
/// A catalog attribute on ``ExerciseTarget``; defaults to `.strength` for legacy rows.
public nonisolated enum ExerciseInputKind: String, Codable, Sendable {
    case strength
    case treadmill
    case none
}

/// Which way a push or pull travels relative to the torso.
///
/// The distinction the slot specs name ("Vertical pull", "Horizontal push") that muscles alone
/// cannot make: a row and a pulldown both list the lats as a primary mover. Only pushes and pulls
/// carry one; `nil` on a catalog row means "either", so an untagged custom exercise is never
/// excluded by it. FROZEN tokens: `rawValue` is the bundled catalog's JSON vocabulary.
public nonisolated enum MovementPlane: String, Codable, CaseIterable, Sendable {
    case horizontal
    case vertical
}

/// What kind of training an exercise is.
///
/// Slot-filled strength sessions draw only `.strength` rows. Explosive jumps and throws
/// (`.power`), conditioning moves (`.cardio`), stretches (`.mobility`) and balance drills belong
/// to a session's warm-up, activation and cardio blocks instead, so a box jump can no longer fill a
/// squat slot at 3 × 12. FROZEN tokens (catalog JSON vocabulary); a row without the key is
/// `.strength`.
public nonisolated enum ExerciseModality: String, Codable, CaseIterable, Sendable {
    case strength
    case power
    case cardio
    case mobility
    case balance
}

/// How much skill and control an exercise asks for.
///
/// The planner leans beginners toward `.foundational` rows and away from `.advanced` ones (a dip,
/// a pull-up, a Nordic curl), and breaks score ties toward the simpler movement for everyone. The
/// raw values are the catalog's JSON numbers (1–3) and are FROZEN; a row without the key is
/// `.standard`.
public nonisolated enum ExerciseDifficulty: Int, Codable, CaseIterable, Comparable, Sendable {
    case foundational = 1
    case standard = 2
    case advanced = 3

    public static func < (lhs: ExerciseDifficulty, rhs: ExerciseDifficulty) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Whether a set of an exercise is counted in repetitions or held for time.
///
/// A plank, a farmer's carry or a stretch is `.seconds`: prescribing it "12–15 reps" is
/// meaningless, so the planner prescribes it as a hold (`PrescribedExercise.holdSeconds`) and the
/// guided runner counts it down. FROZEN tokens; a row without the key is `.reps`.
public nonisolated enum ExerciseMeasure: String, Codable, Sendable {
    case reps
    case seconds
}

/// One catalog exercise: muscles, equipment, movement pattern and plane, modality, difficulty, and
/// how a set is measured.
///
/// The unit the program engine scores against slots and ``WorkoutSafetyFilter`` vets. Decode is
/// legacy-tolerant: rows written with the old `muscles` string array map through
/// `MuscleGroup.fromLegacyString` into `primaryMuscles`.
///
/// The curation fields (`plane`, `modality`, `difficulty`, `measure`, `alternativeEquipment`,
/// `requiredGear`, `unilateral`) are written by the bundled catalog. A custom row (coach-plan import) keeps
/// their defaults, and `encode(to:)` writes each one only when it differs from its default, so a
/// synced custom row's persisted shape is unchanged and an older build never meets the new keys.
/// They decode through raw strings/ints, so an unknown token from a newer catalog falls back to the
/// default instead of throwing the whole settings decode.
public nonisolated struct ExerciseTarget: Identifiable, Codable, Equatable, Sendable {
    public var id: String { name }

    /// FROZEN — never localize this, and never derive it from a localized string.
    ///
    /// `name` is doing four load-bearing jobs at once, and each of them breaks differently:
    /// - it IS the identity (`id == name`), so translating it re-identifies the exercise;
    /// - it is the exact-match lookup key every plan, slot, and log resolves an exercise by;
    /// - it is the vocabulary the model is given and the vocabulary a coach plan quotes back;
    /// - it is the KEY of `settings.workoutProgression: [String: Int]`, which syncs through
    ///   CloudKit — so a translated name silently orphans the user's accumulated progression on
    ///   every device, and a phone in a second language would grow a parallel set of keys.
    ///
    /// A localized exercise name lives in a lookup keyed BY this string, never as a replacement for
    /// it: ``ExerciseHowToCatalog/displayName(for:)``, which screens reach through ``displayName``.
    public var name: String
    public var primaryMuscles: Set<MuscleGroup>
    public var secondaryMuscles: Set<MuscleGroup>
    public var equipment: Equipment
    public var movementPattern: MovementPattern
    public var inputKind: ExerciseInputKind
    /// Vertical or horizontal, for pushes and pulls; `nil` matches any slot plane.
    public var plane: MovementPlane?
    /// Strength, power, cardio, mobility or balance — only `.strength` fills lifting slots.
    public var modality: ExerciseModality
    /// Skill demand, used to steer beginners and to break score ties toward the simpler move.
    public var difficulty: ExerciseDifficulty
    /// Reps or seconds — a `.seconds` row is prescribed as a timed hold.
    public var measure: ExerciseMeasure
    /// Other tools the same movement works with (a goblet squat takes a dumbbell or a
    /// kettlebell). Any one of `equipment` or these makes the exercise doable.
    public var alternativeEquipment: [Equipment]
    /// Specific pieces the movement cannot be done without (a pull-up needs a bar, a bench press a
    /// bench). Every one must be checked at the location — on top of the coarse capability, which
    /// alone cannot tell a pull-up bar from bare floor.
    public var requiredGear: [GymEquipment]
    /// Done one side at a time (a lunge stretch, a single-leg stance): the warm-up and cool-down
    /// prescribe it twice, left then right.
    public var unilateral: Bool

    public var bodyRegion: BodyRegion {
        let regions = Set(primaryMuscles.map { $0.region })
        if regions == [.upper] { return .upper }
        if regions == [.lower] { return .lower }
        if regions == [.core] { return .core }
        return .full
    }

    public var category: WorkoutType {
        switch bodyRegion {
        case .upper: .upper
        case .lower: .lower
        case .core: .fullBody
        case .full: .fullBody
        }
    }

    /// Every muscle this exercise works, primary and secondary, as FROZEN ``MuscleGroup``
    /// rawValue tokens in a stable order.
    ///
    /// This is the half that matching and ordering must use. `Set` has no order of its own, so the
    /// sort is what makes the list deterministic — and it sorts by rawValue rather than by
    /// `displayName` so the order is a property of the data, not of whatever language the device is
    /// in. (For English the two orders happen to be identical, since each display name is just its
    /// rawValue with the camel hump turned into a space.)
    public var muscleTokens: [String] {
        primaryMuscles.union(secondaryMuscles)
            .map(\.rawValue)
            .sorted()
    }

    /// The same muscles as ``muscleTokens``, in the same order, localized for display.
    ///
    /// Order is inherited from the token list on purpose: sorting the localized names instead would
    /// shuffle the row's text per language for no benefit, and it would make the "first three
    /// muscles" that several summaries show a different three in different languages.
    ///
    /// Display ONLY. `WorkoutExerciseCatalog.search` matches on ``muscleTokens`` (plus these, so an
    /// English or a translated search term both work); nothing else should read this to compare.
    public var muscles: [String] {
        primaryMuscles.union(secondaryMuscles)
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.displayName)
    }

    public init(
        name: String,
        primaryMuscles: Set<MuscleGroup>,
        secondaryMuscles: Set<MuscleGroup> = [],
        equipment: Equipment = .none,
        movementPattern: MovementPattern = .isolation,
        inputKind: ExerciseInputKind = .strength,
        plane: MovementPlane? = nil,
        modality: ExerciseModality = .strength,
        difficulty: ExerciseDifficulty = .standard,
        measure: ExerciseMeasure = .reps,
        alternativeEquipment: [Equipment] = [],
        requiredGear: [GymEquipment] = [],
        unilateral: Bool = false
    ) {
        self.name = name
        self.primaryMuscles = primaryMuscles
        self.secondaryMuscles = secondaryMuscles
        self.equipment = equipment
        self.movementPattern = movementPattern
        self.inputKind = inputKind
        self.plane = plane
        self.modality = modality
        self.difficulty = difficulty
        self.measure = measure
        self.alternativeEquipment = alternativeEquipment
        self.requiredGear = requiredGear
        self.unilateral = unilateral
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        inputKind = try container.decodeIfPresent(ExerciseInputKind.self, forKey: .inputKind) ?? .strength
        equipment = try container.decodeIfPresent(Equipment.self, forKey: .equipment) ?? .none
        movementPattern = try container.decodeIfPresent(MovementPattern.self, forKey: .movementPattern) ?? .isolation

        if let prim = try container.decodeIfPresent(Set<MuscleGroup>.self, forKey: .primaryMuscles) {
            primaryMuscles = prim
            secondaryMuscles = try container.decodeIfPresent(Set<MuscleGroup>.self, forKey: .secondaryMuscles) ?? []
        } else {
            let legacy = try container.decodeIfPresent([String].self, forKey: .legacyMuscles) ?? []
            primaryMuscles = Set(legacy.compactMap(MuscleGroup.fromLegacyString))
            secondaryMuscles = []
        }
        // Curation fields decode through raw values, so an unknown token falls back to the field's
        // default (or is skipped, in a list) rather than throwing — see the type's note.
        let planeToken = try container.decodeIfPresent(String.self, forKey: .plane)
        plane = planeToken.flatMap(MovementPlane.init(rawValue:))
        let modalityToken = try container.decodeIfPresent(String.self, forKey: .modality)
        modality = modalityToken.flatMap(ExerciseModality.init(rawValue:)) ?? .strength
        let difficultyValue = try container.decodeIfPresent(Int.self, forKey: .difficulty)
        difficulty = difficultyValue.flatMap(ExerciseDifficulty.init(rawValue:)) ?? .standard
        let measureToken = try container.decodeIfPresent(String.self, forKey: .measure)
        measure = measureToken.flatMap(ExerciseMeasure.init(rawValue:)) ?? .reps
        let alternatives = try container.decodeIfPresent([String].self, forKey: .alternativeEquipment) ?? []
        alternativeEquipment = alternatives.compactMap(Equipment.init(rawValue:))
        let gear = try container.decodeIfPresent([String].self, forKey: .requiredGear) ?? []
        requiredGear = gear.compactMap(GymEquipment.init(rawValue:))
        unilateral = try container.decodeIfPresent(Bool.self, forKey: .unilateral) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(primaryMuscles, forKey: .primaryMuscles)
        try container.encode(secondaryMuscles, forKey: .secondaryMuscles)
        try container.encode(equipment, forKey: .equipment)
        try container.encode(movementPattern, forKey: .movementPattern)
        try container.encode(inputKind, forKey: .inputKind)
        // Curation fields only when they differ from the default (see the type's note).
        try container.encodeIfPresent(plane, forKey: .plane)
        if modality != .strength { try container.encode(modality, forKey: .modality) }
        if difficulty != .standard { try container.encode(difficulty, forKey: .difficulty) }
        if measure != .reps { try container.encode(measure, forKey: .measure) }
        if !alternativeEquipment.isEmpty { try container.encode(alternativeEquipment, forKey: .alternativeEquipment) }
        if !requiredGear.isEmpty { try container.encode(requiredGear, forKey: .requiredGear) }
        if unilateral { try container.encode(unilateral, forKey: .unilateral) }
    }

    /// Persisted JSON keys for an ``ExerciseTarget`` catalog row (`id` is derived from `name`, so
    /// it is never encoded).
    ///
    /// `legacyMuscles` maps the old `muscles` string-array key so pre-split rows still decode.
    private enum CodingKeys: String, CodingKey {
        case name, primaryMuscles, secondaryMuscles, equipment, movementPattern, inputKind
        case plane, modality, difficulty, measure, alternativeEquipment, requiredGear, unilateral
        case legacyMuscles = "muscles"
    }
}

/// The bundled exercise catalog plus name-based category/target inference.
///
/// Loads `WorkoutExercises.json` from `Bundle.main` once (silently empty if the hosting bundle
/// lacks it — the resource lives in the APP target, not `Bundle.module`). `inferredCategory`
/// scores free text against catalog names for legacy rows without muscle data; `search` powers the
/// exercise picker.
public nonisolated enum WorkoutExerciseCatalog {
    /// The bundled catalog, computed once. `ExerciseTarget` is a `Sendable` value type, so this
    /// constant is concurrency-safe by construction.
    public static let baseExercises: [ExerciseTarget] = loadBaseExercises()

    // MARK: - Custom exercises

    /// Hard ceiling on the registered custom exercises (R3: the list grows across coach-plan
    /// imports and rides the synced settings blob, so it needs a total cap, not just a per-import
    /// one). Oldest-first truncation keeps the entries the user has had longest.
    public static let maxCustomExercises = 500

    /// The user's own exercises, registered from `FernletSettings.customExercises` (the coach-plan
    /// importer is the first writer). A `Mutex` rather than a bare mutable static: unlike
    /// `baseExercises` this one genuinely mutates at runtime — on settings load, and again every
    /// time a plan introduces an exercise — while the catalog is read from the planning engine, the
    /// picker, and rest guidance. The lock is the type, so no unsynchronized access can be written.
    private static let custom = Mutex<[ExerciseTarget]>([])

    /// Replaces the registered custom exercises. Call on settings load and after any change, so the
    /// catalog and `FernletSettings.customExercises` never disagree.
    ///
    /// Replace-not-append is deliberate: it makes "delete everything" (and a settings restore that
    /// drops a custom exercise) actually take effect here instead of leaving a stale entry alive in
    /// the picker until relaunch. More than ``maxCustomExercises`` entries are dropped (and logged)
    /// rather than retained.
    public static func registerCustomExercises(_ exercises: [ExerciseTarget]) {
        let capped: [ExerciseTarget]
        if exercises.count > maxCustomExercises {
            FernletAuditLog.log("workout.customExercises.truncated",
                                context: ["count": String(exercises.count),
                                          "max": String(maxCustomExercises)])
            capped = Array(exercises.prefix(maxCustomExercises))
        } else {
            capped = exercises
        }
        custom.withLock { $0 = capped }
    }

    /// The registered custom exercises.
    public static var customExercises: [ExerciseTarget] {
        custom.withLock { $0 }
    }

    /// Every exercise the app knows: the bundled catalog plus the user's own.
    ///
    /// This — not `baseExercises` — is what the planning engine, safety filter, rest guidance, and
    /// picker consume, so an imported exercise is a first-class citizen everywhere. A custom entry
    /// whose name collides with a bundled one is dropped: the bundled metadata is curated, and
    /// silently shadowing it would let a pasted plan redefine what "Bench press" targets.
    public static var allExercises: [ExerciseTarget] {
        let base = baseExercises
        let baseNames = Set(base.map { normalizedName($0.name) })
        return base + customExercises.filter { !baseNames.contains(normalizedName($0.name)) }
    }

    /// Case- and whitespace-insensitive comparison key for exercise names, so "Bench Press" and
    /// "bench  press" are one exercise rather than two.
    public static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Looks up an exercise by name across the bundled and custom catalogs.
    public static func exercise(named name: String) -> ExerciseTarget? {
        let key = normalizedName(name)
        return allExercises.first { normalizedName($0.name) == key }
    }

    /// The category to LABEL a logged row with.
    ///
    /// Keyword-scoring the name + exercise lines is the general rule, with one exception: a row
    /// logged by the guided flow already recorded the session's own kind, and scoring can talk it
    /// out of it — an "Easy cardio" session with one strength accessory added ties cardio against
    /// that accessory and the tie-break lands on Full Body, so a 20-minute cardio session was
    /// labelled "Full Body". A guided row that recorded `.cardio` keeps it. Every other row (manual
    /// logs, Health imports, planned completions) still goes through the text inference below.
    public static func inferredCategory(for workout: Workout) -> WorkoutType {
        if workout.loggedFromGuidedSession == true, workout.type == .cardio { return .cardio }
        return inferredCategory(for: "\(workout.name)\n\(workout.exercises)")
    }

    public static func inferredCategory(for text: String) -> WorkoutType {
        let lowercasedText = text.lowercased()
        var scores: [WorkoutType: Int] = [.upper: 0, .lower: 0, .fullBody: 0, .cardio: 0]
        for exercise in allExercises {
            let tokens = exercise.name.lowercased().split(separator: " ").map(String.init)
            if tokens.allSatisfy({ lowercasedText.contains($0) }) || lowercasedText.contains(exercise.name.lowercased()) {
                scores[exercise.category, default: 0] += 2
            }
        }
        if lowercasedText.contains("upper") { scores[.upper, default: 0] += 2 }
        if lowercasedText.contains("lower") || lowercasedText.contains("leg") { scores[.lower, default: 0] += 2 }
        if lowercasedText.contains("full body") || lowercasedText.contains("full-body") { scores[.fullBody, default: 0] += 2 }
        if lowercasedText.contains("cardio") { scores[.cardio, default: 0] += 2 }

        let sorted = scores.sorted { first, second in
            if first.value != second.value { return first.value > second.value }
            return WorkoutType.allCases.firstIndex(of: first.key) ?? 0 < WorkoutType.allCases.firstIndex(of: second.key) ?? 0
        }
        let best = sorted.first ?? (.fullBody, 0)
        let second = sorted.dropFirst().first?.value ?? 0
        if best.value == 0 { return .fullBody }
        if best.value == second && best.key != .cardio { return .fullBody }
        return best.key
    }

    public static func targetSummary(for workout: Workout) -> String {
        let text = "\(workout.name)\n\(workout.exercises)".lowercased()
        let muscles = allExercises
            .filter { target in
                let name = target.name.lowercased()
                return text.contains(name) || name.split(separator: " ").allSatisfy { text.contains($0) }
            }
            // Display names on purpose: this string is only ever shown ("Targets: chest, triceps")
            // and never parsed, persisted, or prompted with. De-duping localized names is safe for
            // the same reason — two muscles that share a display name in some language would merge
            // into one word on screen, which is what a reader would want anyway.
            .flatMap(\.muscles)
        let unique = muscles.reduce(into: [String]()) { result, muscle in
            if !result.contains(muscle) { result.append(muscle) }
        }
        return unique.prefix(4).joined(separator: ", ")
    }

    public static func search(_ query: String) -> [ExerciseTarget] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allExercises }
        let normalized = trimmed.lowercased()
        return allExercises.filter { exercise in
            exercise.name.lowercased().contains(normalized)
                // The drawn name too (D-L2): a translated name finds its exercise, and the frozen
                // English name above stays a searchable alias on every device.
                || exercise.displayName.lowercased().contains(normalized)
                || exercise.category.rawValue.lowercased().contains(normalized)
                // Match the FROZEN tokens as well as the localized names. Tokens alone would break
                // English search ("upper back" no longer finds `upperBack`); localized names alone
                // would break the moment the catalog and the device disagree on language. Matching
                // both is a strict superset of today's behavior in English, and keeps a user who
                // types an English muscle name on a translated device finding the same exercises.
                || exercise.muscleTokens.contains { $0.lowercased().contains(normalized) }
                || exercise.muscles.contains { $0.lowercased().contains(normalized) }
        }
    }

    private static func loadBaseExercises() -> [ExerciseTarget] {
        // An ABSENT resource is legitimate (test bundles and the extensions don't carry it), so it
        // stays silent. A PRESENT-but-unreadable one is not: without this line a corrupt
        // WorkoutExercises.json empties the whole catalog and every planning/safety consumer
        // degrades with no trace (R7). The recovery in both cases is an empty catalog.
        guard let url = Bundle.main.url(forResource: "WorkoutExercises", withExtension: "json") else {
            return []
        }
        do {
            return try JSONDecoder().decode([ExerciseTarget].self, from: Data(contentsOf: url))
        } catch {
            FernletAuditLog.log("workout.catalog.load.failed",
                                context: ["error": error.localizedDescription])
            return []
        }
    }
}
