// WorkoutModels.swift
// Split out of Models.swift (SPM carve-up §5c). Workout, exercise, muscle, and equipment models.

import Foundation

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

    public var exerciseLines: [String] {
        exercises
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

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
        plannedWorkoutID: UUID? = nil,
        loggedFromGuidedSession: Bool? = nil,
        intensity: WorkoutIntensity,
        completedAt: Date = Date(),
        loggedAt: Date? = nil
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
        self.plannedWorkoutID = plannedWorkoutID
        self.loggedFromGuidedSession = loggedFromGuidedSession
        self.intensity = intensity
        self.completedAt = completedAt
        self.loggedAt = loggedAt ?? completedAt
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
        plannedWorkoutID = try container.decodeIfPresent(UUID.self, forKey: .plannedWorkoutID)
        loggedFromGuidedSession = try container.decodeIfPresent(Bool.self, forKey: .loggedFromGuidedSession)
        // Required key (was strict `decode` pre-compat): absence is corruption, not a newer build.
        let intensitySplit = try container.decodeTolerantRequiredEnum(
            WorkoutIntensity.self, forKey: .intensity, parkedTokenKey: .unknownIntensityToken, default: .moderate)
        intensity = intensitySplit.value
        unknownIntensityToken = intensitySplit.parkedToken
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt) ?? Date()
        loggedAt = try container.decodeIfPresent(Date.self, forKey: .loggedAt) ?? completedAt
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
        try container.encodeIfPresent(plannedWorkoutID, forKey: .plannedWorkoutID)
        // Encoded only when set (never written `false`), so untagged rows stay byte-identical.
        try container.encodeIfPresent(loggedFromGuidedSession, forKey: .loggedFromGuidedSession)
        try container.encode(intensity, forKey: .intensity)
        try container.encodeIfPresent(unknownIntensityToken, forKey: .unknownIntensityToken)
        try container.encode(completedAt, forKey: .completedAt)
        try container.encode(loggedAt, forKey: .loggedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, type, mode, activityType, exercises, rpe, notes, duration
        case distanceMiles, activeEnergyKcal, effort, muscleGroups, healthKitUUID, plannedWorkoutID
        case loggedFromGuidedSession
        case intensity, completedAt, loggedAt
        case unknownTypeToken, unknownModeToken, unknownActivityTypeToken
        case unknownMuscleGroupTokens, unknownIntensityToken
    }
}

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

    private enum CodingKeys: String, CodingKey {
        case id, name, split, source, mode, activityType, exercises, muscleGroups, notes, duration
        case targetDistanceMiles, targetEnergyKcal, targetEffort, createdAt
        case unknownSplitToken, unknownSourceToken, unknownModeToken
        case unknownActivityTypeToken, unknownMuscleGroupTokens
    }
}

public nonisolated enum WorkoutPlanSource: String, Codable, CaseIterable, Identifiable {
    case user
    case coach

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .user: "User"
        case .coach: "Coach"
        }
    }

    public var completionNote: String {
        switch self {
        case .user: "Completed from user plan."
        case .coach: "Completed from coach plan."
        }
    }
}

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

    public var title: String {
        switch self {
        case .workout: "Workout"
        case .upper: "Upper"
        case .lower: "Lower"
        case .fullBody: "Full Body"
        case .push: "Push"
        case .pull: "Pull"
        case .legs: "Legs"
        case .cardio: "Cardio"
        case .recovery: "Recovery"
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
}

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
}

public nonisolated enum WorkoutMode: String, Codable, CaseIterable, Identifiable {
    case strengthTraining
    case activity

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .strengthTraining: "Strength Training"
        case .activity: "Workouts"
        }
    }

    public var pickerTitle: String {
        switch self {
        case .strengthTraining: "Exercise"
        case .activity: "Class"
        }
    }

    public var searchPlaceholder: String {
        switch self {
        case .strengthTraining: "Search exercise or muscle"
        case .activity: "Search class, e.g. Pilates"
        }
    }

    public var addLabel: String {
        switch self {
        case .strengthTraining: "Add exercise"
        case .activity: "Add class"
        }
    }
}

public nonisolated enum BodyRegion: String, Codable, CaseIterable {
    case upper
    case lower
    case core
    case full
}

public nonisolated enum MuscleGroup: String, Codable, CaseIterable, Identifiable {
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

    public var displayName: String {
        switch self {
        case .chest: "Chest"
        case .upperBack: "Upper Back"
        case .lats: "Lats"
        case .lowerBack: "Lower Back"
        case .traps: "Traps"
        case .frontDelts: "Front Delts"
        case .sideDelts: "Side Delts"
        case .rearDelts: "Rear Delts"
        case .biceps: "Biceps"
        case .triceps: "Triceps"
        case .forearms: "Forearms"
        case .abs: "Abs"
        case .obliques: "Obliques"
        case .quads: "Quads"
        case .hamstrings: "Hamstrings"
        case .glutes: "Glutes"
        case .calves: "Calves"
        case .adductors: "Adductors"
        case .abductors: "Abductors"
        case .fullBody: "Full Body"
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

public nonisolated enum MovementPattern: String, Codable, CaseIterable {
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

public nonisolated enum Equipment: String, Codable, CaseIterable, Identifiable {
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

    public var displayName: String {
        switch self {
        case .barbell: "Barbell"
        case .dumbbell: "Dumbbell"
        case .machine: "Machine"
        case .cable: "Cable"
        case .bodyweight: "Bodyweight"
        case .kettlebell: "Kettlebell"
        case .band: "Band"
        case .bench: "Bench"
        case .cardio: "Cardio"
        case .none: "None"
        }
    }
}

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

    public var displayName: String {
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

public nonisolated enum WorkoutIntensity: String, Codable, CaseIterable, Identifiable {
    case light, moderate, hard
    public var id: String { rawValue }
}

public nonisolated enum ExerciseInputKind: String, Codable {
    case strength
    case treadmill
    case none
}

public nonisolated struct ExerciseTarget: Identifiable, Codable, Equatable {
    public var id: String { name }
    public var name: String
    public var primaryMuscles: Set<MuscleGroup>
    public var secondaryMuscles: Set<MuscleGroup>
    public var equipment: Equipment
    public var movementPattern: MovementPattern
    public var inputKind: ExerciseInputKind

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

    public var muscles: [String] {
        (primaryMuscles.union(secondaryMuscles))
            .sorted { $0.displayName < $1.displayName }
            .map(\.displayName)
    }

    public init(
        name: String,
        primaryMuscles: Set<MuscleGroup>,
        secondaryMuscles: Set<MuscleGroup> = [],
        equipment: Equipment = .none,
        movementPattern: MovementPattern = .isolation,
        inputKind: ExerciseInputKind = .strength
    ) {
        self.name = name
        self.primaryMuscles = primaryMuscles
        self.secondaryMuscles = secondaryMuscles
        self.equipment = equipment
        self.movementPattern = movementPattern
        self.inputKind = inputKind
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
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(primaryMuscles, forKey: .primaryMuscles)
        try container.encode(secondaryMuscles, forKey: .secondaryMuscles)
        try container.encode(equipment, forKey: .equipment)
        try container.encode(movementPattern, forKey: .movementPattern)
        try container.encode(inputKind, forKey: .inputKind)
    }

    private enum CodingKeys: String, CodingKey {
        case name, primaryMuscles, secondaryMuscles, equipment, movementPattern, inputKind
        case legacyMuscles = "muscles"
    }
}

public nonisolated enum WorkoutExerciseCatalog {
    // Immutable, computed-once catalog. `nonisolated(unsafe)` avoids cascading Sendable
    // through ExerciseTarget; the array is built once and never mutated.
    nonisolated(unsafe) public static let baseExercises: [ExerciseTarget] = loadBaseExercises()

    public static func inferredCategory(for workout: Workout) -> WorkoutType {
        inferredCategory(for: "\(workout.name)\n\(workout.exercises)")
    }

    public static func inferredCategory(for text: String) -> WorkoutType {
        let lowercasedText = text.lowercased()
        var scores: [WorkoutType: Int] = [.upper: 0, .lower: 0, .fullBody: 0, .cardio: 0]
        for exercise in baseExercises {
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
        let muscles = baseExercises
            .filter { target in
                let name = target.name.lowercased()
                return text.contains(name) || name.split(separator: " ").allSatisfy { text.contains($0) }
            }
            .flatMap(\.muscles)
        let unique = muscles.reduce(into: [String]()) { result, muscle in
            if !result.contains(muscle) { result.append(muscle) }
        }
        return unique.prefix(4).joined(separator: ", ")
    }

    public static func search(_ query: String) -> [ExerciseTarget] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return baseExercises }
        let normalized = trimmed.lowercased()
        return baseExercises.filter { exercise in
            exercise.name.lowercased().contains(normalized)
                || exercise.category.rawValue.lowercased().contains(normalized)
                || exercise.muscles.contains { $0.lowercased().contains(normalized) }
        }
    }

    private static func loadBaseExercises() -> [ExerciseTarget] {
        guard let url = Bundle.main.url(forResource: "WorkoutExercises", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let exercises = try? JSONDecoder().decode([ExerciseTarget].self, from: data) else {
            return []
        }
        return exercises
    }
}
