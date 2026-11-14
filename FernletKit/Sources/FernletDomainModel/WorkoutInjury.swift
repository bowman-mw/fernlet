// WorkoutInjury.swift
// FernletDomainModel
//
// The planner's injury input, structured (2026-10-20). Three layers feed one answer, ``InjuryLimits``:
// - the body-area picker (`WorkoutProfile.injuryAreas`): each area at mild or severe;
// - the free-text note (`WorkoutProfile.injuryNotes`), read by ``InjuryNoteMatcher`` — whole words,
//   so "getting back into lifting" names no back and "championship" names no hip;
// - the avoided muscle and movement sets older builds wrote (the setup sheet's old chips, onboarding).
// The picker wins for an area it names. Anything the note or the old sets imply on top is severe — the
// safe direction, and what those inputs always meant. A fourth input ends a limit: the "No longer an
// issue" switch (WorkoutInjuryEasing.swift, where ``WorkoutProfile/injuryLimits`` combines all four)
// makes its area mild for two weeks from the next workout and then lifts the limit altogether.
//
// Severity, the owner's defaults for review:
// - Severe leaves the area's work out entirely: every exercise working one of its muscles (primary or
//   secondary), using one of its movement patterns, or — for the spine — loading a bar through it.
// - Mild keeps training around it: the heavy end of the area's work (a barbell, an advanced movement, a
//   jump or throw) is left out; machine, cable and bench-supported variants score higher; and a main
//   lift that loads the area — by these rules or, lightly, by its reviewed record — is prescribed as
//   accessory work: the higher rep range at a lighter weight, the accessory set count, and never a
//   calibration.
//
// Those rules read only muscle tags, patterns and a bar on the spine, so they are the FLOOR. On top
// of them every bundled exercise carries a reviewed record of the areas it loads
// (``ExerciseAreaLoads``, WorkoutAreaLoads.swift; the owner's fix e1, 2026-11-10): weight on the
// hands or a hard grip for the wrist, hanging and overhead work for the shoulder, bent-over and
// carried loads for the lower back, jumping for the ankle and knee. Severe leaves out every exercise
// the record says loads the area at all; mild leaves out the ones it loads hard and keeps the light,
// supported ones. The record never lifts a limit the floor sets, and an exercise without a record
// (a person's or a coach's own) gets the floor alone.
//
// Not medical advice: these are coarse, user-supplied limits, applied conservatively.

import Foundation

// MARK: - Body areas

/// A body area the workout injury picker offers, with the work that loads it.
///
/// FROZEN tokens: the raw values persist in the synced settings blob (`workoutInjuryAreas`), so a
/// renamed case would drop a person's limit on the next decode — and dropping a limit un-avoids it.
/// Screens read ``displayName``.
public nonisolated enum BodyArea: String, Codable, CaseIterable, Identifiable, Sendable {
    case neck
    case shoulder
    case elbow
    case wristHand
    case upperBack
    case lowerBack
    case hip
    case knee
    case ankleFoot

    public var id: String { rawValue }

    /// The area's name on screen, localized. Never persisted or matched — `rawValue` is the token.
    public var displayName: String {
        switch self {
        case .neck: String(localized: "bodyArea.neck", defaultValue: "Neck",
                           bundle: .module, comment: "Body area in the workout injury picker")
        case .shoulder: String(localized: "bodyArea.shoulder", defaultValue: "Shoulder",
                               bundle: .module, comment: "Body area in the workout injury picker")
        case .elbow: String(localized: "bodyArea.elbow", defaultValue: "Elbow",
                            bundle: .module, comment: "Body area in the workout injury picker")
        case .wristHand: String(localized: "bodyArea.wristHand", defaultValue: "Wrist or hand",
                                bundle: .module, comment: "Body area in the workout injury picker")
        case .upperBack: String(localized: "bodyArea.upperBack", defaultValue: "Upper back",
                                bundle: .module, comment: "Body area in the workout injury picker")
        case .lowerBack: String(localized: "bodyArea.lowerBack", defaultValue: "Lower back",
                                bundle: .module, comment: "Body area in the workout injury picker")
        case .hip: String(localized: "bodyArea.hip", defaultValue: "Hip",
                          bundle: .module, comment: "Body area in the workout injury picker")
        case .knee: String(localized: "bodyArea.knee", defaultValue: "Knee",
                           bundle: .module, comment: "Body area in the workout injury picker")
        case .ankleFoot: String(localized: "bodyArea.ankleFoot", defaultValue: "Ankle or foot",
                                bundle: .module, comment: "Body area in the workout injury picker")
        }
    }

    /// The muscles whose work loads the area. The six areas the old setup chips covered keep the
    /// chips' exact maps (``hadSetupChip``), so a limit saved by an older build reads back as the
    /// same area.
    public var muscles: Set<MuscleGroup> {
        switch self {
        case .neck: [.traps]
        case .shoulder: [.frontDelts, .sideDelts, .rearDelts]
        case .elbow: [.biceps, .triceps]
        case .wristHand: [.forearms]
        case .upperBack: [.upperBack]
        case .lowerBack: [.lowerBack]
        case .hip: [.glutes, .adductors, .abductors]
        case .knee: [.quads, .hamstrings]
        case .ankleFoot: [.calves]
        }
    }

    /// The movement patterns that load the area whatever muscle they target: pressing for the
    /// shoulder, hinging for the lower back, squats and lunges for the knee, carries for the neck,
    /// running and jumping (locomotion) for the ankle and foot.
    public var movements: Set<MovementPattern> {
        switch self {
        case .neck: [.carry]
        case .shoulder: [.push]
        case .lowerBack: [.hinge]
        case .knee: [.squat, .lunge]
        case .ankleFoot: [.locomotion]
        case .elbow, .wristHand, .upperBack, .hip: []
        }
    }

    /// The spine areas: a loaded bar reaches them through a squat, hinge, lunge or carry whatever
    /// muscles the lift targets (a back squat rests on the neck and loads the lower back).
    public var bearsAxialLoad: Bool {
        switch self {
        case .neck, .upperBack, .lowerBack: true
        case .shoulder, .elbow, .wristHand, .hip, .knee, .ankleFoot: false
        }
    }

    /// The patterns a bar loads the spine through.
    static let axialPatterns: Set<MovementPattern> = [.squat, .hinge, .lunge, .carry]

    /// Whether `exercise` loads this area: it works one of the area's muscles (only its primary
    /// muscles count when `primaryOnly`), uses one of its patterns, or — for a spine area — is a
    /// squat, hinge, lunge or carry with a bar on the body (`carriesABar(_:)`).
    ///
    /// This is the floor, read from the exercise's tags alone. A bundled exercise's reviewed record
    /// (``ExerciseAreaLoads``) can name more areas; ``InjuryLimits`` combines the two.
    public func isLoaded(by exercise: ExerciseTarget, primaryOnly: Bool) -> Bool {
        let worked = primaryOnly ? exercise.primaryMuscles : exercise.primaryMuscles.union(exercise.secondaryMuscles)
        if !worked.isDisjoint(with: muscles) { return true }
        if movements.contains(exercise.movementPattern) { return true }
        return bearsAxialLoad && Self.carriesABar(exercise) && Self.axialPatterns.contains(exercise.movementPattern)
    }

    /// Whether a bar rests on the body: a barbell lift, or a Smith machine one. The owner counts the
    /// Smith machine as supported (2026-10-21): its rows are machine rows, so a mild area treats them
    /// as the guided variant, not the heavy end. Its bar still sits on the spine, so a spine area
    /// still counts a Smith squat as loading it, as it counts a back squat.
    static func carriesABar(_ exercise: ExerciseTarget) -> Bool {
        exercise.equipment == .barbell || exercise.requiredGear.contains(.smithMachine)
    }

    /// The areas the setup sheet had a chip for before the picker (Shoulders, Elbows, Wrists, Lower
    /// back, Hips, Knees). Each chip wrote exactly this area's ``muscles`` and ``movements`` into the
    /// profile's avoided sets, which is how an older build's limit is recognized.
    public var hadSetupChip: Bool {
        switch self {
        case .shoulder, .elbow, .wristHand, .lowerBack, .hip, .knee: true
        case .neck, .upperBack, .ankleFoot: false
        }
    }

    /// The areas whose whole map sits inside avoided sets an older build saved — the old chips, or
    /// onboarding's reading of a note. Only chip areas are recognized; the rest of the sets still
    /// apply as they are.
    public static func legacyAreas(avoidedMuscles: Set<MuscleGroup>, avoidedMovements: Set<MovementPattern>) -> Set<BodyArea> {
        Set(allCases.filter { area in
            area.hadSetupChip && area.muscles.isSubset(of: avoidedMuscles) && area.movements.isSubset(of: avoidedMovements)
        })
    }
}

/// How much a body area limits training. FROZEN tokens (persisted beside ``BodyArea``).
public nonisolated enum InjurySeverity: String, Codable, CaseIterable, Sendable {
    /// Train around it: lighter, supported variants, no heavy loading of the area.
    case mild
    /// Leave the area's work out entirely.
    case severe
}

// MARK: - The combined limits

/// Everything the planner avoids or eases for one person, combined from the picker, the note and
/// the older avoided sets (see this file's header for the precedence and the severity rules).
///
/// ``WorkoutSafetyFilter`` asks ``allows(_:)``; the slot scorer and the prescription ask
/// ``eases(_:)``. Built once per plan from ``WorkoutProfile/injuryLimits``.
///
/// Two layers decide what an area leaves out: the muscle, pattern and spine rules on ``BodyArea``
/// (the floor, and all a custom exercise has), and the bundled exercise's reviewed record
/// (``ExerciseAreaLoads``). The `loads:` forms take the record as an argument and are pure; the
/// forms without it look the record up by the exercise's frozen name.
public nonisolated struct InjuryLimits: Equatable, Sendable {
    /// Areas whose work is left out entirely.
    public var severeAreas: Set<BodyArea>
    /// Areas trained around: heavy loading left out, the rest eased.
    public var mildAreas: Set<BodyArea>
    /// Single muscles avoided outright (older avoided sets, and muscle words in the note).
    public var avoidedMuscles: Set<MuscleGroup>
    /// Movement patterns avoided outright (older avoided sets).
    public var avoidedMovements: Set<MovementPattern>

    public init(
        severeAreas: Set<BodyArea> = [], mildAreas: Set<BodyArea> = [],
        avoidedMuscles: Set<MuscleGroup> = [], avoidedMovements: Set<MovementPattern> = []
    ) {
        self.severeAreas = severeAreas
        self.mildAreas = mildAreas
        self.avoidedMuscles = avoidedMuscles
        self.avoidedMovements = avoidedMovements
    }

    /// No limits at all.
    public static let empty = InjuryLimits()

    /// True when nothing is avoided or eased.
    public var isEmpty: Bool {
        severeAreas.isEmpty && mildAreas.isEmpty && avoidedMuscles.isEmpty && avoidedMovements.isEmpty
    }

    /// Whether the planner may prescribe `exercise` at all: it works no avoided muscle, uses no
    /// avoided pattern, loads no severe area, and is not the heavy end of a mild area's work — by
    /// the muscle and pattern rules and by the exercise's reviewed record, when it has one.
    public func allows(_ exercise: ExerciseTarget) -> Bool {
        allows(exercise, loads: record(for: exercise))
    }

    /// ``allows(_:)`` with the exercise's reviewed record passed in (nil for an exercise that has
    /// none, which then meets the muscle and pattern rules alone).
    public func allows(_ exercise: ExerciseTarget, loads: ExerciseAreaLoads?) -> Bool {
        let worked = exercise.primaryMuscles.union(exercise.secondaryMuscles)
        guard worked.isDisjoint(with: avoidedMuscles), !avoidedMovements.contains(exercise.movementPattern) else {
            return false
        }
        guard severeAreas(loadedBy: exercise, loads: loads).isEmpty else { return false }
        return mildAreas(loadedHardBy: exercise, loads: loads).isEmpty
    }

    /// The severe areas `exercise` loads, each of which leaves it out: an area loaded by the muscle
    /// and pattern rules (``BodyArea/isLoaded(by:primaryOnly:)``), or one its reviewed record names
    /// at any strength.
    public func severeAreas(loadedBy exercise: ExerciseTarget) -> Set<BodyArea> {
        severeAreas(loadedBy: exercise, loads: record(for: exercise))
    }

    /// ``severeAreas(loadedBy:)`` with the reviewed record passed in.
    public func severeAreas(loadedBy exercise: ExerciseTarget, loads: ExerciseAreaLoads?) -> Set<BodyArea> {
        severeAreas.filter { area in
            area.isLoaded(by: exercise, primaryOnly: false) || loads?.load(on: area) != nil
        }
    }

    /// The mild areas `exercise` loads too hard to keep. For an exercise with a reviewed record the
    /// record is the answer: an area it marks ``AreaLoad/hard`` leaves the exercise out, and an area
    /// it marks ``AreaLoad/light`` (or does not name) keeps it. For an exercise with no record (a
    /// custom one) it is the older rule: the heavy end of an area's own work (``isHeavyLoading(_:)``
    /// on a lift ``eases(_:)`` would ease).
    ///
    /// The record decides alone because the owner reviewed it (2026-11-10) and moved Hip thrust to
    /// light for the neck: the bar sits on the hips, and the older spine rule, which reads any
    /// barbell hinge as loading the neck, was wrong for it. `ExerciseAreaLoadTests` pins that the
    /// record still says hard everywhere else the older rule does.
    public func mildAreas(loadedHardBy exercise: ExerciseTarget) -> Set<BodyArea> {
        mildAreas(loadedHardBy: exercise, loads: record(for: exercise))
    }

    /// ``mildAreas(loadedHardBy:)`` with the reviewed record passed in.
    public func mildAreas(loadedHardBy exercise: ExerciseTarget, loads: ExerciseAreaLoads?) -> Set<BodyArea> {
        if let loads { return mildAreas.filter { loads.load(on: $0) == .hard } }
        let heavy = Self.isHeavyLoading(exercise)
        return mildAreas.filter { heavy && $0.isLoaded(by: exercise, primaryOnly: true) }
    }

    /// The reviewed record the area checks read for `exercise` — not looked up at all when no area
    /// is limited, so a person without limits pays nothing for it.
    private func record(for exercise: ExerciseTarget) -> ExerciseAreaLoads? {
        guard !severeAreas.isEmpty || !mildAreas.isEmpty else { return nil }
        return WorkoutExerciseCatalog.areaLoads(for: exercise)
    }

    /// Whether `exercise` loads an area being trained around (a mild area) and is therefore
    /// prescribed lighter: accessory treatment, and never a calibration or a max test. True when the
    /// muscle and pattern rules put its main load there (a primary muscle or a pattern), or when its
    /// reviewed record names the area at all — a mild area only ever keeps a lift it loads lightly
    /// (``mildAreas(loadedHardBy:)`` left the hard ones out), and that light load is eased too
    /// (2026-11-10: before, a kept lift the record marked ``AreaLoad/light`` was prescribed at full
    /// weight unless the muscle rules happened to catch it).
    public func eases(_ exercise: ExerciseTarget) -> Bool {
        eases(exercise, loads: record(for: exercise))
    }

    /// ``eases(_:)`` with the reviewed record passed in (nil for an exercise that has none, which
    /// is then eased by the muscle and pattern rules alone).
    public func eases(_ exercise: ExerciseTarget, loads: ExerciseAreaLoads?) -> Bool {
        mildAreas.contains { $0.isLoaded(by: exercise, primaryOnly: true) || loads?.load(on: $0) != nil }
    }

    /// Whether the muscle and pattern rules alone put `exercise`'s main load on a mild area. This
    /// is what the supported-variant bonus reads (``supportBonus(for:)``): a guided machine is
    /// preferred for the area's own work, not for every lift that merely grips or stands on it.
    func mainlyLoadsMildArea(_ exercise: ExerciseTarget) -> Bool {
        mildAreas.contains { $0.isLoaded(by: exercise, primaryOnly: true) }
    }

    /// The areas whose severe limit rules out walking: the ankle or foot, the knee and the hip.
    static let walkingAreas: Set<BodyArea> = [.ankleFoot, .knee, .hip]

    /// Whether a walk must not be offered: a severe ankle, knee or hip, or running and walking
    /// (locomotion) avoided outright. The planner then offers seated mobility in a walk's place
    /// (the fill's fallback offer, the Travel-day reset, a cardio day with no machine left).
    public var barsWalking: Bool {
        !severeAreas.isDisjoint(with: Self.walkingAreas) || avoidedMovements.contains(.locomotion)
    }

    /// The heavy end of a pattern, left out for a mild area: a barbell lift, an advanced movement
    /// (a dip, a pull-up, a front squat), or a jump or throw. A Smith machine row is a machine row,
    /// so it is the supported end, not this one (2026-10-21).
    public static func isHeavyLoading(_ exercise: ExerciseTarget) -> Bool {
        exercise.equipment == .barbell || exercise.difficulty == .advanced || exercise.modality == .power
    }

    /// Score bonus for a supported variant of a lift that loads a mild area: machines and cables
    /// guide the path, a bench takes the body's weight.
    static let machineSupportBonus = 15
    /// See ``machineSupportBonus``.
    static let benchSupportBonus = 8

    /// The slot-score bonus `exercise` earns as a supported variant — zero unless it loads a mild area.
    func supportBonus(for exercise: ExerciseTarget) -> Int {
        guard !mildAreas.isEmpty, mainlyLoadsMildArea(exercise) else { return 0 }
        if exercise.equipment == .machine || exercise.equipment == .cable { return Self.machineSupportBonus }
        return exercise.requiredGear.contains(.weightBench) ? Self.benchSupportBonus : 0
    }
}

// MARK: - Persistence helpers

/// The token side of `WorkoutProfile.injuryAreas`: the typed ↔ token mapping and the tolerant,
/// parked decode (``EnumDecodeCompat``'s contract, per area).
///
/// The persisted shape (``FernletSettings``' top-level `workoutInjuryAreas`) is a JSON object of
/// area token → severity token. The main key carries only pairs this build knows; a pair it doesn't
/// — a newer build's area, or a newer severity for a known area — is parked under
/// `unknownWorkoutInjuryAreaTokens` and re-encoded, so a save here cannot strip it. An unknown
/// severity on a known area reads as severe meanwhile: the safe direction.
nonisolated enum InjuryAreaTokens {
    /// The typed view of persisted known pairs; an unreadable pair is skipped.
    static func typed(_ tokens: [String: String]) -> [BodyArea: InjurySeverity] {
        var typed: [BodyArea: InjurySeverity] = [:]
        for (key, value) in tokens {
            guard let area = BodyArea(rawValue: key), let severity = InjurySeverity(rawValue: value) else { continue }
            typed[area] = severity
        }
        return typed
    }

    /// The persisted pairs for a typed map.
    static func tokens(_ typed: [BodyArea: InjurySeverity]) -> [String: String] {
        var tokens: [String: String] = [:]
        for (area, severity) in typed { tokens[area.rawValue] = severity.rawValue }
        return tokens
    }

    /// Splits a decoded main map and parked map into the known pairs and the pairs to keep parked.
    ///
    /// Per known area, ``EnumDecodeCompat/resolveScalar(token:parkedToken:default:resolve:)``
    /// decides (a known parked severity is the latest true choice and is adopted). Unknown areas are
    /// parked whole, bounded by ``EnumDecodeCompat``'s limits.
    static func split(main: [String: String], parked: [String: String]) -> (known: [String: String], parked: [String: String]) {
        var known: [String: String] = [:]
        var stillParked: [String: String] = [:]
        for area in BodyArea.allCases {
            let key = area.rawValue
            guard main[key] != nil || parked[key] != nil else { continue }
            let resolved = EnumDecodeCompat.resolveScalar(token: main[key], parkedToken: parked[key], default: InjurySeverity.severe)
            known[key] = resolved.value.rawValue
            if let token = resolved.parkedToken { stillParked[key] = token }
        }
        let limit = EnumDecodeCompat.unknownTokenLengthLimit
        let unknownAreas = main.merging(parked) { first, _ in first }.filter { BodyArea(rawValue: $0.key) == nil }
        for key in unknownAreas.keys.sorted() where stillParked.count < EnumDecodeCompat.unknownTokenCountLimit {
            guard let value = unknownAreas[key], key.count <= limit, value.count <= limit else { continue }
            stillParked[key] = value
        }
        return (known, stillParked)
    }
}
