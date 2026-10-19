import Foundation
import FernletFoundation

// MARK: - Experience level

/// Training experience (beginner/intermediate/advanced).
///
/// Caps accessory slots per session (`maxSlotsPerDay`) and contributes points toward the
/// recommended split specificity; decodes tolerantly on ``WorkoutProfile``.
public nonisolated enum ExperienceLevel: String, Codable, CaseIterable, Identifiable {
    case beginner
    case intermediate
    case advanced

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .beginner: "Beginner"
        case .intermediate: "Intermediate"
        case .advanced: "Advanced"
        }
    }

    /// Beginners get fewer accessory slots so sessions stay sustainable.
    public var maxSlotsPerDay: Int {
        switch self {
        case .beginner: 5
        case .intermediate: 6
        case .advanced: 7
        }
    }

    public var points: Int {
        switch self {
        case .beginner: 0
        case .intermediate: 1
        case .advanced: 2
        }
    }
}

// MARK: - Workout profile (person-level limits; equipment lives on locations)

/// Durable workout context the suggestion engine reads: injuries (structured contraindications plus
/// free-text nuance), interests, sport, weekly frequency, level, and the chosen split (nil = auto).
public nonisolated struct WorkoutProfile: Codable, Equatable {
    // The enum sets + `experience` decode tolerantly with parked-token side channels
    // (EnumDecodeCompat): this struct lives in FernletSettings (top-level synced-blob field), so a
    // strict `Set<MuscleGroup>`/`Set<MovementPattern>`/`ExperienceLevel` decode of a raw value only
    // a newer build knows would brick the older device into read-only recovery — and a lossy
    // re-save here would strip a newer device's avoided-muscle selections (a safety field: dropping
    // one un-avoids it).
    public var avoidedMuscles: Set<MuscleGroup>
    public var unknownAvoidedMuscleTokens: [String] = []
    public var avoidedMovements: Set<MovementPattern>
    public var unknownAvoidedMovementTokens: [String] = []
    public var injuryNotes: String
    public var interests: [String]
    public var sport: String
    public var trainingDaysPerWeek: Int
    public var experience: ExperienceLevel {
        didSet { unknownExperienceToken = nil }
    }
    public var unknownExperienceToken: String? = nil
    /// nil → use the recommended split. Otherwise a `TrainingSplit.id`.
    public var selectedSplitID: String?

    public init(
        avoidedMuscles: Set<MuscleGroup> = [],
        avoidedMovements: Set<MovementPattern> = [],
        injuryNotes: String = "",
        interests: [String] = [],
        sport: String = "",
        trainingDaysPerWeek: Int = 3,
        experience: ExperienceLevel = .beginner,
        selectedSplitID: String? = nil
    ) {
        self.avoidedMuscles = avoidedMuscles
        self.avoidedMovements = avoidedMovements
        self.injuryNotes = injuryNotes
        self.interests = interests
        self.sport = sport
        self.trainingDaysPerWeek = trainingDaysPerWeek
        self.experience = experience
        self.selectedSplitID = selectedSplitID
    }

    public nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let muscleSplit = try c.decodeTolerantEnumSet(
            MuscleGroup.self, forKey: .avoidedMuscles, parkedTokensKey: .unknownAvoidedMuscleTokens)
        avoidedMuscles = muscleSplit.known
        unknownAvoidedMuscleTokens = muscleSplit.unknownTokens
        let movementSplit = try c.decodeTolerantEnumSet(
            MovementPattern.self, forKey: .avoidedMovements, parkedTokensKey: .unknownAvoidedMovementTokens)
        avoidedMovements = movementSplit.known
        unknownAvoidedMovementTokens = movementSplit.unknownTokens
        injuryNotes = try c.decodeIfPresent(String.self, forKey: .injuryNotes) ?? ""
        interests = try c.decodeIfPresent([String].self, forKey: .interests) ?? []
        sport = try c.decodeIfPresent(String.self, forKey: .sport) ?? ""
        trainingDaysPerWeek = try c.decodeIfPresent(Int.self, forKey: .trainingDaysPerWeek) ?? 3
        let experienceSplit = try c.decodeTolerantEnum(
            ExperienceLevel.self, forKey: .experience, parkedTokenKey: .unknownExperienceToken, default: .beginner)
        experience = experienceSplit.value
        unknownExperienceToken = experienceSplit.parkedToken
        selectedSplitID = try c.decodeIfPresent(String.self, forKey: .selectedSplitID)
    }

    /// Best-effort mapping of free-text constraint/injury phrases into structured contraindications,
    /// used to carry onboarding text (e.g. "shoulder issues") into the safety filter. Conservative:
    /// over-restricting is the safe direction. The raw text is kept in `injuryNotes`.
    public static func avoidedMuscles(fromConstraintText text: String) -> Set<MuscleGroup> {
        let lower = text.lowercased()
        var muscles: Set<MuscleGroup> = []
        if lower.contains("shoulder") || lower.contains("rotator") { muscles.formUnion([.frontDelts, .sideDelts, .rearDelts]) }
        if lower.contains("knee") { muscles.formUnion([.quads, .hamstrings]) }
        if lower.contains("back") || lower.contains("spine") || lower.contains("disc") { muscles.formUnion([.lowerBack]) }
        if lower.contains("elbow") { muscles.formUnion([.biceps, .triceps]) }
        if lower.contains("wrist") { muscles.formUnion([.forearms]) }
        if lower.contains("hip") { muscles.formUnion([.glutes, .adductors, .abductors]) }
        if lower.contains("hamstring") { muscles.formUnion([.hamstrings]) }
        if lower.contains("ankle") || lower.contains("calf") { muscles.formUnion([.calves]) }
        if lower.contains("chest") || lower.contains("pec") { muscles.formUnion([.chest]) }
        return muscles
    }

    public static func avoidedMovements(fromConstraintText text: String) -> Set<MovementPattern> {
        let lower = text.lowercased()
        var movements: Set<MovementPattern> = []
        if lower.contains("shoulder") || lower.contains("rotator") { movements.formUnion([.push]) }
        if lower.contains("back") || lower.contains("spine") || lower.contains("disc") { movements.formUnion([.hinge]) }
        if lower.contains("knee") { movements.formUnion([.squat, .lunge]) }
        return movements
    }

    /// Builds a profile from the free-text level / interests / constraints captured at onboarding,
    /// so that context isn't discarded. Constraints become structured contraindications (best-effort)
    /// plus the raw note; interests become tokens the engine biases toward.
    public static func fromOnboarding(level: String, interests: String, constraints: String) -> WorkoutProfile {
        let experience = ExperienceLevel(rawValue: level.lowercased()) ?? .beginner
        let interestList = interests
            .split { $0 == "," || $0 == "\n" }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false }
        let trimmedConstraints = constraints.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkoutProfile(
            avoidedMuscles: avoidedMuscles(fromConstraintText: trimmedConstraints),
            avoidedMovements: avoidedMovements(fromConstraintText: trimmedConstraints),
            injuryNotes: trimmedConstraints,
            interests: interestList,
            experience: experience
        )
    }
}

// MARK: - Equipment (granular, user-facing) → coarse engine capability

/// Equipment categories shown as sections in the selection grid.
public nonisolated enum EquipmentCategory: String, CaseIterable, Identifiable, Sendable {
    case cardio
    case freeWeights
    case machines
    case functional
    case recovery

    public var id: String { rawValue }

    /// The category's reader-facing name — the uppercase section caption in the location editor.
    ///
    /// Localized (`rawValue` stays the frozen token). Without this the `.textCase(.uppercase)` on
    /// that caption had nothing to transform *after*: the word never reached a catalog at all.
    public var label: String {
        switch self {
        case .cardio: String(localized: "equipmentCategory.cardio", defaultValue: "Cardio",
                             bundle: .module, comment: "Equipment category: treadmills, bikes, rowers")
        case .freeWeights: String(localized: "equipmentCategory.freeWeights", defaultValue: "Free weights",
                                  bundle: .module, comment: "Equipment category: dumbbells, barbells, kettlebells")
        case .machines: String(localized: "equipmentCategory.machines", defaultValue: "Machines",
                               bundle: .module, comment: "Equipment category: cable and plate-loaded machines")
        case .functional: String(localized: "equipmentCategory.functional", defaultValue: "Functional",
                                 bundle: .module, comment: "Equipment category: bands, mats, pull-up bars")
        case .recovery: String(localized: "equipmentCategory.recovery", defaultValue: "Recovery",
                               bundle: .module, comment: "Equipment category: foam rollers and mobility tools")
        }
    }
}

/// Specific pieces of equipment the user checks off per location. Each maps down to a coarse
/// `Equipment` capability that the planning engine / safety filter actually reasons about.
public nonisolated enum GymEquipment: String, Codable, CaseIterable, Identifiable, Sendable {
    case treadmill, exerciseBike, rowingMachine, elliptical, stairClimber
    case dumbbells, barbell, kettlebells, weightPlates, weightBench
    case cableMachine, latPulldown, legPress, smithMachine, chestPress
    case pullUpBar, squatRack, resistanceBands, medicineBall, battleRopes
    case yogaMat, foamRoller

    public var id: String { rawValue }

    public var category: EquipmentCategory {
        switch self {
        case .treadmill, .exerciseBike, .rowingMachine, .elliptical, .stairClimber: .cardio
        case .dumbbells, .barbell, .kettlebells, .weightPlates, .weightBench: .freeWeights
        case .cableMachine, .latPulldown, .legPress, .smithMachine, .chestPress: .machines
        case .pullUpBar, .squatRack, .resistanceBands, .medicineBall, .battleRopes: .functional
        case .yogaMat, .foamRoller: .recovery
        }
    }

    public var displayName: String {
        switch self {
        case .treadmill: "Treadmill"
        case .exerciseBike: "Exercise bike"
        case .rowingMachine: "Rowing machine"
        case .elliptical: "Elliptical"
        case .stairClimber: "Stair climber"
        case .dumbbells: "Dumbbells"
        case .barbell: "Barbell"
        case .kettlebells: "Kettlebells"
        case .weightPlates: "Weight plates"
        case .weightBench: "Weight bench"
        case .cableMachine: "Cable machine"
        case .latPulldown: "Lat pulldown"
        case .legPress: "Leg press"
        case .smithMachine: "Smith machine"
        case .chestPress: "Chest press"
        case .pullUpBar: "Pull-up bar"
        case .squatRack: "Squat rack"
        case .resistanceBands: "Resistance bands"
        case .medicineBall: "Medicine ball"
        case .battleRopes: "Battle ropes"
        case .yogaMat: "Yoga mat"
        case .foamRoller: "Foam roller"
        }
    }

    /// SF Symbol approximation (first pass — the design ships custom glyphs we can port later).
    public var systemImage: String {
        switch self {
        case .treadmill: "figure.run"
        case .exerciseBike: "bicycle"
        case .rowingMachine: "figure.rower"
        case .elliptical: "figure.elliptical"
        case .stairClimber: "figure.stairs"
        case .dumbbells: "dumbbell.fill"
        case .barbell: "figure.strengthtraining.traditional"
        case .kettlebells: "figure.strengthtraining.functional"
        case .weightPlates: "circle.circle"
        case .weightBench: "bed.double"
        case .cableMachine: "figure.strengthtraining.functional"
        case .latPulldown: "arrow.down.to.line"
        case .legPress: "figure.strengthtraining.traditional"
        case .smithMachine: "square.split.1x2"
        case .chestPress: "figure.strengthtraining.traditional"
        case .pullUpBar: "arrow.up.to.line"
        case .squatRack: "square.split.1x2"
        case .resistanceBands: "figure.flexibility"
        case .medicineBall: "circle.fill"
        case .battleRopes: "waveform.path"
        case .yogaMat: "figure.yoga"
        case .foamRoller: "capsule.fill"
        }
    }

    /// The coarse capability this unlocks for the planning engine.
    public var capability: Equipment {
        switch self {
        case .treadmill, .exerciseBike, .rowingMachine, .elliptical, .stairClimber, .battleRopes: .cardio
        case .dumbbells: .dumbbell
        case .barbell, .weightPlates, .squatRack, .smithMachine: .barbell
        case .kettlebells: .kettlebell
        case .weightBench: .bench
        case .cableMachine, .latPulldown: .cable
        case .legPress, .chestPress: .machine
        case .resistanceBands: .band
        case .pullUpBar, .medicineBall, .yogaMat, .foamRoller: .bodyweight
        }
    }
}

/// A preset starting point for a new location, pre-filling typical equipment.
public nonisolated struct LocationTemplate: Identifiable, Sendable {

    public init(id: String, name: String, subtitle: String, systemImage: String, equipment: Set<GymEquipment>) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.equipment = equipment
    }
    public var id: String
    public var name: String
    public var subtitle: String
    public var systemImage: String
    public var equipment: Set<GymEquipment>

    /// Mints a saved location from this template.
    ///
    /// **Known localization debt — deliberately deferred (accessibility review A4, F4).** `name`
    /// and `subtitle` are English literals, and this function BAKES `name` into the persisted
    /// `WorkoutLocation`, which the user can then rename. Localizing them would therefore be worse
    /// than leaving them: a French user's saved location would read "Salle de sport complète" until
    /// they switched language, after which the stored English-era or French-era string would be
    /// frozen and wrong — the exact trap `PersonalCareTask.displayLabel` documents and works around
    /// for built-in care tasks.
    ///
    /// The fix has a known shape and is a schema change, not a copy change: give `WorkoutLocation`
    /// an optional `templateID` written at mint time, resolve a built-in's display name live from
    /// the template (falling back to the stored `name` for a renamed or user-created location), and
    /// migrate existing rows by matching `name` against `LocationTemplate.all` — which is already
    /// how `availableTemplates` decides what is saved. Until that lands, these five names stay
    /// English on purpose.
    public func makeLocation() -> WorkoutLocation {
        WorkoutLocation(name: name, ownedEquipment: equipment)
    }

    public static let all: [LocationTemplate] = [
        LocationTemplate(id: "full-gym", name: "Full gym", subtitle: "Commercial or studio",
                         systemImage: "dumbbell.fill", equipment: Set(GymEquipment.allCases)),
        LocationTemplate(id: "hotel-gym", name: "Hotel gym", subtitle: "Small, shared space",
                         systemImage: "bed.double.fill",
                         equipment: [.treadmill, .exerciseBike, .dumbbells, .weightBench, .cableMachine]),
        LocationTemplate(id: "apartment-gym", name: "Apartment gym", subtitle: "Building amenity",
                         systemImage: "building.2.fill",
                         equipment: [.treadmill, .elliptical, .dumbbells, .weightBench, .cableMachine, .legPress]),
        LocationTemplate(id: "home-setup", name: "Home setup", subtitle: "Your own space",
                         systemImage: "house.fill",
                         equipment: [.dumbbells, .kettlebells, .resistanceBands, .yogaMat, .pullUpBar]),
    ]
}

// MARK: - Locations (what equipment is available where)

/// A place the user trains and the equipment it has. Defaults assume a fully-stocked gym; the user
/// can add a home/travel location with a narrower set. Bodyweight is always available everywhere.
public nonisolated struct WorkoutLocation: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var ownedEquipment: Set<GymEquipment>

    public init(id: UUID = UUID(), name: String, ownedEquipment: Set<GymEquipment>) {
        self.id = id
        self.name = name
        self.ownedEquipment = ownedEquipment
    }

    public nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        // Defensive: drop any unknown raw values rather than throwing (handles older saves) — that
        // is `compactMap` below. The decode itself only throws when the key is PRESENT and is not
        // an array of strings, i.e. real corruption, which must not be silent (R7): the recovery is
        // an empty equipment set that the next save persists, so it is named in the log.
        var raws: [String] = []
        do {
            raws = try c.decodeIfPresent([String].self, forKey: .ownedEquipment) ?? []
        } catch {
            FernletAuditLog.log("workout.location.ownedEquipment.decodeFailed",
                                context: ["error": error.localizedDescription])
        }
        ownedEquipment = Set(raws.compactMap(GymEquipment.init(rawValue:)))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(ownedEquipment.map(\.rawValue).sorted(), forKey: .ownedEquipment)
    }

    /// Persisted JSON keys for a ``WorkoutLocation``'s wire format.
    ///
    /// `ownedEquipment` is written as sorted raw values (see `encode(to:)`) so output is deterministic.
    private enum CodingKeys: String, CodingKey { case id, name, ownedEquipment }

    /// Equipment available regardless of location (no gear required).
    public static let alwaysAvailable: Set<Equipment> = [.bodyweight, .none]

    /// Coarse capabilities the planning engine checks against, derived from granular equipment.
    public var capabilities: Set<Equipment> {
        var caps = Self.alwaysAvailable
        for item in ownedEquipment { caps.insert(item.capability) }
        return caps
    }

    public func has(_ equipment: Equipment) -> Bool {
        capabilities.contains(equipment)
    }

    /// Count of equipment in a given category (for the "n of N" selection counters).
    public func selectedCount(in category: EquipmentCategory) -> Int {
        ownedEquipment.filter { $0.category == category }.count
    }

    // Fixed IDs for the two built-in locations.
    //
    // These are computed properties, so every access builds a NEW value — and with a `UUID()` default
    // that meant a new identity each time. `settings.activeWorkoutLocation` falls back to `.fullGym`,
    // so two reads of the same property could disagree about which location was active, and an `activeID`
    // captured from one read matched nothing on the next. A hardcoded UUID makes the built-ins stable
    // across reads, launches and devices; `static let` would not (it is initialized once per PROCESS, so
    // the id would still change every launch).
    //
    // Spelled through the non-failable `UUID(uuid:)` byte initializer rather than
    // `UUID(uuidString:)!` — same 128-bit value, no force unwrap (R5).
    // `WorkoutProgramTests.builtInLocationIDsMatchTheirPersistedStringForm` pins the `uuidString`
    // form of `fullGym`/`home`, so a typo in the bytes cannot silently change a persisted id.
    private static let fullGymID = UUID(uuid: (0xF0, 0xE1, 0xD2, 0xC3, 0xB4, 0xA5, 0x49, 0x68,
                                               0x87, 0x78, 0x6A, 0x5B, 0x4C, 0x3D, 0x2E, 0x1F))
    private static let homeID = UUID(uuid: (0x0A, 0x1B, 0x2C, 0x3D, 0x4E, 0x5F, 0x40, 0x61,
                                            0x92, 0x73, 0x84, 0x95, 0xA6, 0xB7, 0xC8, 0xD9))

    /// The default location: assume the user has every standard piece of gym equipment.
    nonisolated public static var fullGym: WorkoutLocation {
        WorkoutLocation(id: fullGymID, name: "Full gym", ownedEquipment: Set(GymEquipment.allCases))
    }

    nonisolated public static var home: WorkoutLocation {
        WorkoutLocation(id: homeID, name: "Home", ownedEquipment: [.dumbbells, .kettlebells, .resistanceBands, .yogaMat, .pullUpBar])
    }
}

// MARK: - Deterministic safety / equipment feasibility

/// The single authority on whether an exercise is allowed for a user. Deterministic by design — the
/// AI adjuster (added later) must run its output back through this, never around it.
/// Not medical advice: it filters on coarse, user-supplied contraindications.
public nonisolated enum WorkoutSafetyFilter {
    public static func feasible(_ exercise: ExerciseTarget, location: WorkoutLocation, profile: WorkoutProfile) -> Bool {
        guard hasEquipment(for: exercise, at: location) else { return false }
        if profile.avoidedMovements.contains(exercise.movementPattern) { return false }
        if profile.avoidedMuscles.isEmpty == false {
            let worked = exercise.primaryMuscles.union(exercise.secondaryMuscles)
            if worked.isDisjoint(with: profile.avoidedMuscles) == false { return false }
        }
        return true
    }

    public static func feasibleExercises(in catalog: [ExerciseTarget], location: WorkoutLocation, profile: WorkoutProfile) -> [ExerciseTarget] {
        catalog.filter { feasible($0, location: location, profile: profile) }
    }

    /// Whether the location can run the exercise at all: one of its tools (`equipment` or an
    /// alternative) is available, and every specific piece it requires is owned there.
    public static func hasEquipment(for exercise: ExerciseTarget, at location: WorkoutLocation) -> Bool {
        missingEquipment(for: exercise, at: location).isEmpty
    }

    /// What the location lacks for the exercise, named for a reason line ("Home has no weight
    /// bench") — empty when it has everything. The tool comes first when none of its options is
    /// there; then each required piece that is not owned, in catalog order.
    public static func missingEquipment(for exercise: ExerciseTarget, at location: WorkoutLocation) -> [String] {
        var missing: [String] = []
        let tools = [exercise.equipment] + exercise.alternativeEquipment
        if !tools.contains(where: location.has) {
            missing.append(exercise.equipment.displayName)
        }
        for gear in exercise.requiredGear where !location.ownedEquipment.contains(gear) {
            missing.append(gear.displayName)
        }
        return missing
    }
}

// MARK: - Slot / session / split structure

/// The role a slot plays in a session: main compound, accessory, or core work.
///
/// Drives set counts (``WorkoutGoalStyle``), exercise slot scoring, and rest demand
/// (``WorkoutRestGuidance``).
public nonisolated enum SlotRole: Sendable {
    case main          // compound, heavier
    case accessory     // isolation / lighter
    case core          // trunk
}

/// The part of a session a prescribed movement belongs to, in the order a session runs them.
///
/// Stretch first, then wake up the trunk and balance (and jump, when it fits), then lift while
/// fresh, then any cardio — after lifting, so it does not tire the legs for the heavy work — then
/// cool down with long holds. The owner's layout (2026-10-19), and NASM's session template with
/// cardio moved after resistance. FROZEN tokens: they cross into the app-group run state as raw
/// strings, so a renamed case would strand a run in progress.
public nonisolated enum SessionBlock: String, Codable, CaseIterable, Sendable {
    case warmUp
    case activation
    case lifting
    case cardio
    case coolDown
}

/// The side a one-sided stretch or drill is done on. FROZEN tokens (app-group run state).
public nonisolated enum ExerciseSide: String, Codable, CaseIterable, Sendable {
    case left
    case right
}

/// A slot describes the INTENT of a movement (pattern + plane + target region/muscles + role), not
/// a fixed exercise. The engine fills it from the equipment- and injury-filtered catalog, so the
/// same split adapts to the user's location and limits while keeping the structure consistent week
/// to week.
///
/// The pattern, plane and muscles are requirements, not hints: an exercise must share the slot's
/// movement pattern, its plane (when both name one), and at least one primary muscle, or the slot
/// is dropped and the session note says so — never filled with an unrelated movement.
public nonisolated struct WorkoutSlotSpec: Sendable {

    public init(
        label: String, role: SlotRole, movement: MovementPattern? = nil, plane: MovementPlane? = nil,
        muscles: Set<MuscleGroup> = [], region: BodyRegion? = nil
    ) {
        self.label = label
        self.role = role
        self.movement = movement
        self.plane = plane
        self.muscles = muscles
        self.region = region
    }
    public var label: String
    public var role: SlotRole
    public var movement: MovementPattern?
    public var plane: MovementPlane?
    public var muscles: Set<MuscleGroup> = []
    public var region: BodyRegion?
}

/// The kind of training session (strength, full-body, cardio, mobility, sport).
///
/// Cardio/mobility sessions render their conditioning descriptor directly; the others are filled
/// from the catalog via slots.
public nonisolated enum SessionKind: String, CaseIterable, Sendable {
    case strength
    case fullBody
    case cardio
    case mobility
    case sport
}

/// When in the day a session happens — lets a split prescribe e.g. morning cardio + evening lifting.
public nonisolated enum SessionTime: String, Sendable {
    case any
    case morning
    case midday
    case evening

    public var label: String {
        switch self {
        case .any: ""
        case .morning: "Morning"
        case .midday: "Midday"
        case .evening: "Evening"
        }
    }
}

/// One training session. Strength/full-body/sport sessions are filled from the catalog via `slots`;
/// cardio/mobility sessions render their `conditioning` descriptor directly.
public nonisolated struct WorkoutSessionTemplate: Sendable {

    public init(title: String, kind: SessionKind, time: SessionTime = .any, slots: [WorkoutSlotSpec] = [], conditioning: String? = nil) {
        self.title = title
        self.kind = kind
        self.time = time
        self.slots = slots
        self.conditioning = conditioning
    }
    public var title: String
    public var kind: SessionKind
    public var time: SessionTime = .any
    public var slots: [WorkoutSlotSpec] = []
    public var conditioning: String? = nil
}

/// A day in the split. Most days have one session; some (cardio + strength, two-a-days) have several.
public nonisolated struct WorkoutSplitDay: Sendable {

    public init(title: String, sessions: [WorkoutSessionTemplate]) {
        self.title = title
        self.sessions = sessions
    }
    public var title: String
    public var sessions: [WorkoutSessionTemplate]
}

/// How specific a split is, from "just move" to a body-part split.
public nonisolated enum SplitSpecificity: Int, CaseIterable, Sendable {
    case minimal = 0      // very broad: daily movement / full body
    case balanced = 1     // upper/lower, full-body rotations
    case focused = 2      // push/pull/legs
    case specialized = 3  // body-part / two-a-day

    public var label: String {
        switch self {
        case .minimal: "Very broad"
        case .balanced: "Balanced"
        case .focused: "Focused"
        case .specialized: "Very specific"
        }
    }
}

/// A named weekly training structure: specificity, goal fit, and its ordered days.
///
/// The unit ``WorkoutSplitRecommender`` ranks and the program engine rotates through; `id` is the
/// stable token stored in `WorkoutProfile.selectedSplitID`.
public nonisolated struct TrainingSplit: Identifiable, Sendable {

    public init(id: String, name: String, summary: String, specificity: SplitSpecificity, goalFit: Set<GoalType>, days: [WorkoutSplitDay]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.specificity = specificity
        self.goalFit = goalFit
        self.days = days
    }
    public var id: String
    public var name: String
    public var summary: String
    public var specificity: SplitSpecificity
    public var goalFit: Set<GoalType>
    public var days: [WorkoutSplitDay]

    public var daysPerWeek: Int { days.count }
    public var sessionsPerWeek: Int { days.reduce(0) { $0 + $1.sessions.count } }

    public var frequencySummary: String {
        let sessions = sessionsPerWeek
        let dayWord = daysPerWeek == 1 ? "day" : "days"
        if sessions == daysPerWeek {
            return "\(daysPerWeek) \(dayWord)/week"
        }
        return "\(daysPerWeek) \(dayWord) · \(sessions) sessions/week"
    }
}

extension WorkoutSessionTemplate {
    public func at(_ time: SessionTime) -> WorkoutSessionTemplate {
        var copy = self
        copy.time = time
        return copy
    }
}

// MARK: - Session library

/// The static library of reusable session templates (full-body variants, PPL days, body-part days,
/// cardio).
///
/// Immutable `Sendable` constants, built once and never mutated, composed into every
/// ``TrainingSplit`` in ``WorkoutSplitCatalog``.
public nonisolated enum WorkoutSessions {
    // Strength sessions. Vertical/horizontal pushes & pulls are distinguished by target muscles
    // (the catalog tags only movementPattern); "not used today" diversifies picks within a day.
    public static let fullBodyA = WorkoutSessionTemplate(title: "Full Body A", kind: .fullBody, slots: [
        WorkoutSlotSpec(label: "Squat", role: .main, movement: .squat, muscles: [.quads, .glutes]),
        WorkoutSlotSpec(label: "Horizontal push", role: .main, movement: .push, plane: .horizontal, muscles: [.chest]),
        WorkoutSlotSpec(label: "Horizontal pull", role: .main, movement: .pull, plane: .horizontal, muscles: [.upperBack, .lats]),
        WorkoutSlotSpec(label: "Hinge", role: .accessory, movement: .hinge, muscles: [.hamstrings, .glutes]),
        WorkoutSlotSpec(label: "Core", role: .core, muscles: [.abs, .obliques], region: .core),
    ])
    public static let fullBodyB = WorkoutSessionTemplate(title: "Full Body B", kind: .fullBody, slots: [
        WorkoutSlotSpec(label: "Hinge", role: .main, movement: .hinge, muscles: [.hamstrings, .glutes]),
        WorkoutSlotSpec(label: "Vertical push", role: .main, movement: .push, plane: .vertical, muscles: [.frontDelts, .sideDelts]),
        WorkoutSlotSpec(label: "Vertical pull", role: .main, movement: .pull, plane: .vertical, muscles: [.lats, .upperBack]),
        WorkoutSlotSpec(label: "Lunge", role: .accessory, movement: .lunge, muscles: [.quads, .glutes]),
        WorkoutSlotSpec(label: "Core", role: .core, muscles: [.abs, .obliques], region: .core),
    ])
    public static let fullBodyC = WorkoutSessionTemplate(title: "Full Body C", kind: .fullBody, slots: [
        WorkoutSlotSpec(label: "Lunge", role: .main, movement: .lunge, muscles: [.quads, .glutes]),
        WorkoutSlotSpec(label: "Incline push", role: .main, movement: .push, plane: .horizontal, muscles: [.chest, .frontDelts]),
        WorkoutSlotSpec(label: "Row", role: .main, movement: .pull, plane: .horizontal, muscles: [.upperBack, .lats]),
        WorkoutSlotSpec(label: "Carry / loaded", role: .accessory, movement: .carry, muscles: [.forearms, .traps]),
        WorkoutSlotSpec(label: "Core", role: .core, muscles: [.abs, .obliques], region: .core),
    ])
    public static let upper = WorkoutSessionTemplate(title: "Upper", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Horizontal push", role: .main, movement: .push, plane: .horizontal, muscles: [.chest]),
        WorkoutSlotSpec(label: "Horizontal pull", role: .main, movement: .pull, plane: .horizontal, muscles: [.upperBack, .lats]),
        WorkoutSlotSpec(label: "Vertical push", role: .main, movement: .push, plane: .vertical, muscles: [.frontDelts, .sideDelts]),
        WorkoutSlotSpec(label: "Vertical pull", role: .accessory, movement: .pull, plane: .vertical, muscles: [.lats, .upperBack]),
        WorkoutSlotSpec(label: "Biceps", role: .accessory, movement: .isolation, muscles: [.biceps]),
        WorkoutSlotSpec(label: "Triceps", role: .accessory, movement: .isolation, muscles: [.triceps]),
    ])
    public static let lower = WorkoutSessionTemplate(title: "Lower", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Squat", role: .main, movement: .squat, muscles: [.quads, .glutes]),
        WorkoutSlotSpec(label: "Hinge", role: .main, movement: .hinge, muscles: [.hamstrings, .glutes]),
        WorkoutSlotSpec(label: "Lunge", role: .accessory, movement: .lunge, muscles: [.quads, .glutes]),
        WorkoutSlotSpec(label: "Calves", role: .accessory, movement: .isolation, muscles: [.calves]),
        WorkoutSlotSpec(label: "Core", role: .core, muscles: [.abs, .obliques], region: .core),
    ])
    public static let push = WorkoutSessionTemplate(title: "Push", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Horizontal push", role: .main, movement: .push, plane: .horizontal, muscles: [.chest]),
        WorkoutSlotSpec(label: "Vertical push", role: .main, movement: .push, plane: .vertical, muscles: [.frontDelts, .sideDelts]),
        WorkoutSlotSpec(label: "Incline push", role: .accessory, movement: .push, plane: .horizontal, muscles: [.chest, .frontDelts]),
        WorkoutSlotSpec(label: "Side delts", role: .accessory, movement: .isolation, muscles: [.sideDelts]),
        WorkoutSlotSpec(label: "Triceps", role: .accessory, movement: .isolation, muscles: [.triceps]),
    ])
    public static let pull = WorkoutSessionTemplate(title: "Pull", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Vertical pull", role: .main, movement: .pull, plane: .vertical, muscles: [.lats, .upperBack]),
        WorkoutSlotSpec(label: "Horizontal pull", role: .main, movement: .pull, plane: .horizontal, muscles: [.upperBack, .lats]),
        WorkoutSlotSpec(label: "Rear delts", role: .accessory, movement: .isolation, muscles: [.rearDelts]),
        WorkoutSlotSpec(label: "Biceps", role: .accessory, movement: .isolation, muscles: [.biceps]),
        WorkoutSlotSpec(label: "Hinge", role: .accessory, movement: .hinge, muscles: [.hamstrings, .glutes]),
    ])
    public static let legs = WorkoutSessionTemplate(title: "Legs", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Squat", role: .main, movement: .squat, muscles: [.quads, .glutes]),
        WorkoutSlotSpec(label: "Hinge", role: .main, movement: .hinge, muscles: [.hamstrings, .glutes]),
        WorkoutSlotSpec(label: "Lunge", role: .accessory, movement: .lunge, muscles: [.quads, .glutes]),
        WorkoutSlotSpec(label: "Calves", role: .accessory, movement: .isolation, muscles: [.calves]),
        WorkoutSlotSpec(label: "Core", role: .core, muscles: [.abs, .obliques], region: .core),
    ])
    // Body-part sessions (specialized splits)
    public static let chest = WorkoutSessionTemplate(title: "Chest", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Flat press", role: .main, movement: .push, plane: .horizontal, muscles: [.chest]),
        WorkoutSlotSpec(label: "Incline press", role: .main, movement: .push, plane: .horizontal, muscles: [.chest, .frontDelts]),
        WorkoutSlotSpec(label: "Chest isolation", role: .accessory, movement: .isolation, muscles: [.chest]),
        WorkoutSlotSpec(label: "Dip / decline", role: .accessory, movement: .push, muscles: [.chest, .triceps]),
        WorkoutSlotSpec(label: "Triceps", role: .accessory, movement: .isolation, muscles: [.triceps]),
    ])
    public static let back = WorkoutSessionTemplate(title: "Back", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Vertical pull", role: .main, movement: .pull, plane: .vertical, muscles: [.lats, .upperBack]),
        WorkoutSlotSpec(label: "Horizontal pull", role: .main, movement: .pull, plane: .horizontal, muscles: [.upperBack, .lats]),
        WorkoutSlotSpec(label: "Row variation", role: .accessory, movement: .pull, plane: .horizontal, muscles: [.upperBack]),
        WorkoutSlotSpec(label: "Rear delts", role: .accessory, movement: .isolation, muscles: [.rearDelts]),
        WorkoutSlotSpec(label: "Biceps", role: .accessory, movement: .isolation, muscles: [.biceps]),
    ])
    public static let shoulders = WorkoutSessionTemplate(title: "Shoulders", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Overhead press", role: .main, movement: .push, plane: .vertical, muscles: [.frontDelts, .sideDelts]),
        WorkoutSlotSpec(label: "Side delts", role: .accessory, movement: .isolation, muscles: [.sideDelts]),
        WorkoutSlotSpec(label: "Rear delts", role: .accessory, movement: .isolation, muscles: [.rearDelts]),
        WorkoutSlotSpec(label: "Front delts", role: .accessory, movement: .isolation, muscles: [.frontDelts]),
        WorkoutSlotSpec(label: "Traps", role: .accessory, movement: .isolation, muscles: [.traps]),
    ])
    public static let arms = WorkoutSessionTemplate(title: "Arms", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Biceps", role: .main, movement: .isolation, muscles: [.biceps]),
        WorkoutSlotSpec(label: "Triceps", role: .main, movement: .isolation, muscles: [.triceps]),
        WorkoutSlotSpec(label: "Biceps 2", role: .accessory, movement: .isolation, muscles: [.biceps]),
        WorkoutSlotSpec(label: "Triceps 2", role: .accessory, movement: .isolation, muscles: [.triceps]),
        WorkoutSlotSpec(label: "Forearms / grip", role: .accessory, movement: .isolation, muscles: [.forearms]),
    ])
    public static let arnoldChestBack = WorkoutSessionTemplate(title: "Chest & Back", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Flat press", role: .main, movement: .push, plane: .horizontal, muscles: [.chest]),
        WorkoutSlotSpec(label: "Vertical pull", role: .main, movement: .pull, plane: .vertical, muscles: [.lats, .upperBack]),
        WorkoutSlotSpec(label: "Incline press", role: .accessory, movement: .push, plane: .horizontal, muscles: [.chest, .frontDelts]),
        WorkoutSlotSpec(label: "Horizontal pull", role: .accessory, movement: .pull, plane: .horizontal, muscles: [.upperBack]),
        WorkoutSlotSpec(label: "Chest isolation", role: .accessory, movement: .isolation, muscles: [.chest]),
    ])
    public static let arnoldShouldersArms = WorkoutSessionTemplate(title: "Shoulders & Arms", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Overhead press", role: .main, movement: .push, plane: .vertical, muscles: [.frontDelts, .sideDelts]),
        WorkoutSlotSpec(label: "Side delts", role: .accessory, movement: .isolation, muscles: [.sideDelts]),
        WorkoutSlotSpec(label: "Biceps", role: .accessory, movement: .isolation, muscles: [.biceps]),
        WorkoutSlotSpec(label: "Triceps", role: .accessory, movement: .isolation, muscles: [.triceps]),
        WorkoutSlotSpec(label: "Rear delts", role: .accessory, movement: .isolation, muscles: [.rearDelts]),
    ])

    // Cardio / mobility / sport sessions (rendered from their descriptor, not the catalog)
    public static let easyCardio = WorkoutSessionTemplate(title: "Easy cardio", kind: .cardio, conditioning: "Easy cardio - 20 min")
    public static let intervals = WorkoutSessionTemplate(title: "Intervals", kind: .cardio, conditioning: "Intervals - 8 × 1 min hard / 1 min easy")
    public static let longCardio = WorkoutSessionTemplate(title: "Steady cardio", kind: .cardio, conditioning: "Steady cardio - 40 min")
    public static let mobility = WorkoutSessionTemplate(title: "Mobility", kind: .mobility, conditioning: "Mobility flow - 15 min")
    public static let sportConditioning = WorkoutSessionTemplate(title: "Sport conditioning", kind: .sport, slots: [
        WorkoutSlotSpec(label: "Lower power", role: .main, movement: .squat, muscles: [.quads, .glutes]),
        WorkoutSlotSpec(label: "Carry / loaded", role: .accessory, movement: .carry, muscles: [.forearms, .traps]),
        WorkoutSlotSpec(label: "Core", role: .core, muscles: [.abs, .obliques], region: .core),
    ])
}

// MARK: - Split catalog (broad → specialized)

/// The full split catalog, ordered from "just move" to specialized two-a-days.
///
/// `fallback` (Full Body ×3) is the safe default when nothing is selected or recommended; the
/// recommender ranks `all` rather than filtering, so the user can still pick any split.
public nonisolated enum WorkoutSplitCatalog {
    nonisolated public static var fallback: TrainingSplit { fullBody3 }

    public static let all: [TrainingSplit] = [
        dailyMove, fullBody2, recoveryFlow, fullBody3, upperLowerFull3, upperLower4,
        ppl3, cardioStrength4, sportPrep, pplUL5, ppl6, broSplit5, arnold6, twoADay,
    ]

    private static func day(_ title: String, _ sessions: [WorkoutSessionTemplate]) -> WorkoutSplitDay {
        WorkoutSplitDay(title: title, sessions: sessions)
    }

    // --- Minimal / very broad ---
    public static let dailyMove = TrainingSplit(
        id: "daily-move", name: "Daily Movement",
        summary: "Easy full-body days and walks — just keep moving.",
        specificity: .minimal, goalFit: [.wellness, .mentalHealth, .recovery, .exploring],
        days: [day("Day 1", [WorkoutSessions.fullBodyA]), day("Day 2", [WorkoutSessions.easyCardio]), day("Day 3", [WorkoutSessions.fullBodyB])]
    )
    public static let fullBody2 = TrainingSplit(
        id: "full-body-2", name: "Full Body ×2",
        summary: "Two full-body sessions a week. Simple and forgiving.",
        specificity: .minimal, goalFit: Set(GoalType.allCases),
        days: [day("Day 1", [WorkoutSessions.fullBodyA]), day("Day 2", [WorkoutSessions.fullBodyB])]
    )
    public static let recoveryFlow = TrainingSplit(
        id: "recovery-flow", name: "Recovery Flow",
        summary: "Mobility and easy movement to feel better, not beat up.",
        specificity: .minimal, goalFit: [.recovery, .mentalHealth, .wellness],
        days: [day("Day 1", [WorkoutSessions.mobility]), day("Day 2", [WorkoutSessions.easyCardio]), day("Day 3", [WorkoutSessions.fullBodyA])]
    )

    // --- Balanced ---
    public static let fullBody3 = TrainingSplit(
        id: "full-body-3", name: "Full Body ×3",
        summary: "Three full-body sessions — the most efficient way to cover everything.",
        specificity: .balanced, goalFit: Set(GoalType.allCases),
        days: [day("Day 1", [WorkoutSessions.fullBodyA]), day("Day 2", [WorkoutSessions.fullBodyB]), day("Day 3", [WorkoutSessions.fullBodyC])]
    )
    public static let upperLowerFull3 = TrainingSplit(
        id: "upper-lower-full-3", name: "Upper / Lower / Full",
        summary: "A bit more focus than full-body, still only three days.",
        specificity: .balanced, goalFit: [.strength, .weightManagement, .wellness, .sportsPrep, .exploring],
        days: [day("Day 1", [WorkoutSessions.upper]), day("Day 2", [WorkoutSessions.lower]), day("Day 3", [WorkoutSessions.fullBodyC])]
    )
    public static let upperLower4 = TrainingSplit(
        id: "upper-lower-4", name: "Upper / Lower",
        summary: "Four days alternating upper and lower body.",
        specificity: .balanced, goalFit: [.strength, .weightManagement, .wellness, .sportsPrep],
        days: [day("Day 1", [WorkoutSessions.upper]), day("Day 2", [WorkoutSessions.lower]), day("Day 3", [WorkoutSessions.upper]), day("Day 4", [WorkoutSessions.lower])]
    )

    // --- Focused ---
    public static let ppl3 = TrainingSplit(
        id: "ppl-3", name: "Push / Pull / Legs",
        summary: "Classic three-day split organised by movement.",
        specificity: .focused, goalFit: [.strength, .sportsPrep, .weightManagement],
        days: [day("Push", [WorkoutSessions.push]), day("Pull", [WorkoutSessions.pull]), day("Legs", [WorkoutSessions.legs])]
    )
    public static let cardioStrength4 = TrainingSplit(
        id: "cardio-strength-4", name: "Cardio + Strength",
        summary: "Morning cardio, evening lifting — for fat loss and conditioning.",
        specificity: .focused, goalFit: [.weightManagement, .wellness, .sportsPrep],
        days: [
            day("Day 1", [WorkoutSessions.easyCardio.at(.morning), WorkoutSessions.upper.at(.evening)]),
            day("Day 2", [WorkoutSessions.intervals.at(.morning), WorkoutSessions.lower.at(.evening)]),
            day("Day 3", [WorkoutSessions.easyCardio.at(.morning), WorkoutSessions.push.at(.evening)]),
            day("Day 4", [WorkoutSessions.longCardio.at(.morning), WorkoutSessions.pull.at(.evening)]),
        ]
    )
    public static let sportPrep = TrainingSplit(
        id: "sport-prep", name: "Sport Prep",
        summary: "Sport-specific conditioning paired with strength work.",
        specificity: .focused, goalFit: [.sportsPrep],
        days: [
            day("Day 1", [WorkoutSessions.sportConditioning.at(.morning), WorkoutSessions.lower.at(.evening)]),
            day("Day 2", [WorkoutSessions.upper]),
            day("Day 3", [WorkoutSessions.sportConditioning.at(.morning), WorkoutSessions.push.at(.evening)]),
            day("Day 4", [WorkoutSessions.pull]),
        ]
    )
    public static let pplUL5 = TrainingSplit(
        id: "ppl-ul-5", name: "PPL + Upper / Lower",
        summary: "Five days mixing push/pull/legs with upper/lower.",
        specificity: .focused, goalFit: [.strength, .sportsPrep],
        days: [day("Push", [WorkoutSessions.push]), day("Pull", [WorkoutSessions.pull]), day("Legs", [WorkoutSessions.legs]), day("Upper", [WorkoutSessions.upper]), day("Lower", [WorkoutSessions.lower])]
    )
    public static let ppl6 = TrainingSplit(
        id: "ppl-6", name: "Push / Pull / Legs ×2",
        summary: "Six high-frequency days for serious volume.",
        specificity: .focused, goalFit: [.strength, .sportsPrep],
        days: [day("Push A", [WorkoutSessions.push]), day("Pull A", [WorkoutSessions.pull]), day("Legs A", [WorkoutSessions.legs]), day("Push B", [WorkoutSessions.push]), day("Pull B", [WorkoutSessions.pull]), day("Legs B", [WorkoutSessions.legs])]
    )

    // --- Specialized / very specific ---
    public static let broSplit5 = TrainingSplit(
        id: "bro-5", name: "Bro Split",
        summary: "One body part per day for maximum focus.",
        specificity: .specialized, goalFit: [.strength],
        days: [day("Chest", [WorkoutSessions.chest]), day("Back", [WorkoutSessions.back]), day("Shoulders", [WorkoutSessions.shoulders]), day("Arms", [WorkoutSessions.arms]), day("Legs", [WorkoutSessions.legs])]
    )
    public static let arnold6 = TrainingSplit(
        id: "arnold-6", name: "Arnold Split",
        summary: "Chest+back, shoulders+arms, legs — twice over, six days.",
        specificity: .specialized, goalFit: [.strength],
        days: [day("Chest & Back", [WorkoutSessions.arnoldChestBack]), day("Shoulders & Arms", [WorkoutSessions.arnoldShouldersArms]), day("Legs", [WorkoutSessions.legs]), day("Chest & Back", [WorkoutSessions.arnoldChestBack]), day("Shoulders & Arms", [WorkoutSessions.arnoldShouldersArms]), day("Legs", [WorkoutSessions.legs])]
    )
    public static let twoADay = TrainingSplit(
        id: "two-a-day", name: "Two-a-Day Strength",
        summary: "Two strength sessions a day — advanced, high volume.",
        specificity: .specialized, goalFit: [.strength, .sportsPrep],
        days: [
            day("Day 1", [WorkoutSessions.push.at(.morning), WorkoutSessions.pull.at(.evening)]),
            day("Day 2", [WorkoutSessions.legs.at(.morning), WorkoutSessions.upper.at(.evening)]),
            day("Day 3", [WorkoutSessions.lower.at(.morning), WorkoutSessions.arms.at(.evening)]),
        ]
    )
}

// MARK: - Consistency + recommendation

/// How consistently the user has been training lately (low/medium/high).
///
/// Derived from recent history app-side; contributes points to the recommended split specificity.
public nonisolated enum WorkoutConsistency: Int {
    case low = 0
    case medium = 1
    case high = 2

    public var points: Int { rawValue }

    public var label: String {
        switch self {
        case .low: "Getting started"
        case .medium: "Fairly consistent"
        case .high: "Very consistent"
        }
    }
}

/// Recommends splits from goal + how specific the user is ready for (experience + consistency +
/// activity level) + their preferred training days. The user can still pick any split.
public nonisolated enum WorkoutSplitRecommender {
    public static func desiredSpecificity(experience: ExperienceLevel, consistency: WorkoutConsistency, activity: ActivityLevel) -> SplitSpecificity {
        let total = experience.points + consistency.points + activityPoints(activity) // 0…6
        switch total {
        case ...1: return .minimal
        case 2...3: return .balanced
        case 4...5: return .focused
        default: return .specialized
        }
    }

    public static func ranked(
        goal: GoalType,
        experience: ExperienceLevel,
        consistency: WorkoutConsistency,
        activity: ActivityLevel,
        preferredDays: Int
    ) -> [TrainingSplit] {
        let desired = desiredSpecificity(experience: experience, consistency: consistency, activity: activity)
        let tolerance = activityToleranceSessions(activity)
        return WorkoutSplitCatalog.all
            .map { split -> (split: TrainingSplit, score: Int) in
                var score = 0
                score += split.goalFit.contains(goal) ? 120 : -30
                score -= abs(split.specificity.rawValue - desired.rawValue) * 30
                score -= abs(split.daysPerWeek - preferredDays) * 12
                if split.sessionsPerWeek > tolerance {
                    score -= (split.sessionsPerWeek - tolerance) * 12
                }
                return (split, score)
            }
            // Deterministic secondary sort on split id: Array.sorted(by:) is not guaranteed
            // stable, and several splits tie at the top score, so without this the auto-selected
            // program could silently change identity between launches. Mirrors the id/name
            // tie-breaks used by bestExercise and the adjustment candidate builder.
            .sorted { lhs, rhs in
                lhs.score != rhs.score ? lhs.score > rhs.score : lhs.split.id < rhs.split.id
            }
            .map(\.split)
    }

    private static func activityPoints(_ activity: ActivityLevel) -> Int {
        switch activity {
        case .sedentary, .light: 0
        case .moderate: 1
        case .active, .veryActive: 2
        }
    }

    private static func activityToleranceSessions(_ activity: ActivityLevel) -> Int {
        switch activity {
        case .sedentary: 2
        case .light: 3
        case .moderate: 4
        case .active: 6
        case .veryActive: 8
        }
    }
}

// MARK: - Goal/energy → volume style

/// The volume prescription for a goal: sets/reps by role, plus the conditioning line.
///
/// `style(for:energy:sport:)` is the goal→volume table; `adjustedSets` applies the day's energy
/// (light trims a set, hard adds one, floored at 2).
public nonisolated struct WorkoutGoalStyle {

    public init(
        mainSets: Int, mainReps: String, accessorySets: Int, accessoryReps: String,
        includeConditioning: Bool, conditioningLabel: String, holdSeconds: Int = 30
    ) {
        self.mainSets = mainSets
        self.mainReps = mainReps
        self.accessorySets = accessorySets
        self.accessoryReps = accessoryReps
        self.includeConditioning = includeConditioning
        self.conditioningLabel = conditioningLabel
        self.holdSeconds = holdSeconds
    }
    public var mainSets: Int
    public var mainReps: String
    public var accessorySets: Int
    public var accessoryReps: String
    public var includeConditioning: Bool
    public var conditioningLabel: String
    /// Seconds per set for a timed lifting-block movement (a plank, a carry) under this goal.
    public var holdSeconds: Int

    /// Applies the day's energy: light trims a set; hard adds one.
    public func adjustedSets(for role: SlotRole, energy: WorkoutIntensity) -> Int {
        let base = (role == .main) ? mainSets : accessorySets
        let delta = energy == .light ? -1 : (energy == .hard ? 1 : 0)
        return max(2, base + delta)
    }

    public func reps(for role: SlotRole) -> String {
        switch role {
        case .main: mainReps
        case .accessory, .core: accessoryReps
        }
    }

    public static func style(for goal: GoalType, energy: WorkoutIntensity, sport: String) -> WorkoutGoalStyle {
        let conditioning: String
        switch goal {
        case .sportsPrep:
            conditioning = sport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Conditioning intervals - 12 min"
                : "\(sport.capitalized) drills / conditioning - 15 min"
        case .weightManagement:
            conditioning = "Steady cardio - 20 min"
        case .wellness, .mentalHealth:
            conditioning = "Easy walk - 15 min"
        case .recovery:
            conditioning = "Gentle mobility + walk - 12 min"
        default:
            conditioning = "Optional cardio - 10 min"
        }

        switch goal {
        case .strength:
            return WorkoutGoalStyle(mainSets: 4, mainReps: "5", accessorySets: 3, accessoryReps: "8-10", includeConditioning: false, conditioningLabel: conditioning, holdSeconds: 40)
        case .sportsPrep:
            return WorkoutGoalStyle(mainSets: 4, mainReps: "5", accessorySets: 3, accessoryReps: "8-12", includeConditioning: false, conditioningLabel: conditioning, holdSeconds: 40)
        case .weightManagement:
            return WorkoutGoalStyle(mainSets: 3, mainReps: "8-12", accessorySets: 3, accessoryReps: "12-15", includeConditioning: false, conditioningLabel: conditioning, holdSeconds: 40)
        case .wellness:
            return WorkoutGoalStyle(mainSets: 3, mainReps: "8-12", accessorySets: 2, accessoryReps: "10-12", includeConditioning: false, conditioningLabel: conditioning, holdSeconds: 30)
        case .mentalHealth:
            return WorkoutGoalStyle(mainSets: 2, mainReps: "10-12", accessorySets: 2, accessoryReps: "10-12", includeConditioning: false, conditioningLabel: conditioning, holdSeconds: 30)
        case .recovery:
            return WorkoutGoalStyle(mainSets: 2, mainReps: "12-15", accessorySets: 2, accessoryReps: "12-15", includeConditioning: false, conditioningLabel: conditioning, holdSeconds: 20)
        case .exploring:
            return WorkoutGoalStyle(mainSets: 3, mainReps: "8-12", accessorySets: 3, accessoryReps: "10-12", includeConditioning: false, conditioningLabel: conditioning, holdSeconds: 30)
        }
    }
}

// MARK: - The engine: split day + profile + location → concrete session(s)

/// A concrete prescribed movement: a catalog exercise with sets/reps (or a timed hold), or a
/// non-catalog line (e.g. a conditioning finisher) when `fromCatalog` is false.
///
/// `block` places it in the session's run order (``SessionBlock``). A timed movement — a stretch, a
/// plank, a carry — carries `holdSeconds`, and its `reps` is the same duration as display text
/// ("40 s"), so every surface that shows reps shows something true. `side` names the side of a
/// one-sided stretch or drill; `name` stays the frozen catalog name either way.
public nonisolated struct PrescribedExercise: Identifiable, Equatable {

    public init(
        id: UUID = UUID(), name: String, sets: Int, reps: String, role: SlotRole, fromCatalog: Bool,
        restSecondsOverride: Int? = nil, block: SessionBlock = .lifting, holdSeconds: Int? = nil,
        side: ExerciseSide? = nil
    ) {
        self.id = id
        self.name = name
        self.sets = sets
        self.reps = reps
        self.role = role
        self.fromCatalog = fromCatalog
        self.restSecondsOverride = restSecondsOverride
        self.block = block
        self.holdSeconds = holdSeconds
        self.side = side
    }
    public var id = UUID()
    public var name: String
    public var sets: Int
    public var reps: String
    public var role: SlotRole
    public var fromCatalog: Bool
    /// A per-exercise rest override (seconds) set by the in-app editor or the coach app; when nil the
    /// guided runner falls back to `WorkoutRestGuidance`'s goal-/movement-based default.
    public var restSecondsOverride: Int?
    /// Where in the session this runs. Everything the engine has always produced is `.lifting`.
    public var block: SessionBlock
    /// Seconds per set for a timed movement; nil for a rep-counted one.
    public var holdSeconds: Int?
    /// Left or right for a one-sided step; nil otherwise.
    public var side: ExerciseSide?

    /// The display text for a timed hold: "40 s".
    public static func holdText(seconds: Int) -> String { "\(seconds) s" }

    /// The plan-text line. A timed single step reads "Low lunge stretch (left) - 20 s"; a timed set
    /// "Plank - 2 x 30 s", which the history parser reads back as a hold, never as reps.
    public var line: String {
        guard fromCatalog else { return name }
        let label = side.map { "\(name) (\($0.rawValue))" } ?? name
        if let holdSeconds {
            let hold = Self.holdText(seconds: holdSeconds)
            return sets > 1 ? "\(label) - \(sets) x \(hold)" : "\(label) - \(hold)"
        }
        return "\(label) - \(sets) x \(reps)"
    }
}

/// The deterministic engine that turns a split day + profile + location into concrete sessions.
///
/// `dayPlan` picks the rotation day, filters the catalog through ``WorkoutSafetyFilter``, fills
/// each slot with the best-scoring feasible exercise (deterministic tie-breaks on name/id),
/// applies double progression from per-exercise completion counts, and honestly reports slots it
/// had to drop. The AI adjuster's output re-enters via `applyAdjustment` and must run back through
/// the safety filter, never around it.
public nonisolated enum WorkoutProgram {
    /// One rendered session: its prescribed exercises plus the displayable ``WorkoutSuggestion``.
    ///
    /// `workout(intensity:loggedFromGuidedSession:)` builds the loggable row; passing `true` tags
    /// it as guided so name-based reconciliation only matches the guided flow's own logs.
    public struct SessionSuggestion: Identifiable {
        public var id = UUID()
        public var title: String
        public var timeLabel: String
        public var kind: SessionKind
        public var exercises: [PrescribedExercise] = []
        public var suggestion: WorkoutSuggestion

        public init(id: UUID = UUID(), title: String, timeLabel: String, kind: SessionKind, exercises: [PrescribedExercise] = [], suggestion: WorkoutSuggestion) {
            self.id = id
            self.title = title
            self.timeLabel = timeLabel
            self.kind = kind
            self.exercises = exercises
            self.suggestion = suggestion
        }

        /// Names of the catalog exercises in this session's lifting block — the progression
        /// bookkeeping and the AI adjuster's subject. Warm-up stretches, the light activation work and
        /// the cool-down are not progressed and never counted.
        public var catalogExerciseNames: [String] {
            exercises.filter { $0.fromCatalog && $0.block == .lifting }.map(\.name)
        }

        /// Builds the loggable `Workout` for this session. `loggedFromGuidedSession` tags the row as
        /// coming from the guided flow so name-based reconciliation only ever matches the guided
        /// flow's own logs; every guided logging site passes `true`, and no other caller does.
        public func workout(intensity: WorkoutIntensity, loggedFromGuidedSession: Bool = false) -> Workout {
            let mode: WorkoutMode = (kind == .strength || kind == .fullBody) ? .strengthTraining : .activity
            let type: WorkoutType = (kind == .cardio) ? .cardio : .fullBody
            return Workout(
                name: suggestion.name, type: type, mode: mode, exercises: suggestion.exercises,
                rpe: nil, notes: suggestion.notes, duration: prescribedMinutes,
                loggedFromGuidedSession: loggedFromGuidedSession ? true : nil,
                intensity: intensity
            )
        }

        /// The minutes this session actually prescribes, when it says so itself.
        ///
        /// Cardio and mobility sessions ARE their leading descriptor ("Easy cardio - 20 min"), so
        /// the logged row can carry that duration instead of showing none at all while its own name
        /// promises 20 minutes. Slot-filled sessions (strength / full body / sport) prescribe sets
        /// and reps, not a clock, and an appended conditioning line describes only part of the
        /// session — those stay `nil` rather than reporting a made-up total.
        var prescribedMinutes: Int? {
            guard kind == .cardio || kind == .mobility else { return nil }
            return exercises.first.flatMap { WorkoutProgram.descriptorMinutes(in: $0.name) }
        }
    }

    /// Minutes named by a conditioning descriptor's trailing clause: "Easy cardio - 20 min" → 20.
    ///
    /// Deliberately strict — the clause must be a number followed by "min" and nothing else in
    /// front of it — so an interval descriptor ("Intervals - 8 × 1 min hard / 1 min easy") reports
    /// no duration rather than the wrong one (1). Accepts the hyphen and both dashes as separators.
    public static func descriptorMinutes(in descriptor: String) -> Int? {
        var tail: Substring?
        for separator in [" - ", " – ", " — "] {
            if let range = descriptor.range(of: separator) {
                tail = descriptor[range.upperBound...]
                break
            }
        }
        guard let clause = tail?.trimmingCharacters(in: .whitespaces) else { return nil }
        let digits = clause.prefix(while: \.isNumber)
        guard let minutes = Int(digits), minutes > 0, minutes <= 600 else { return nil }
        let unit = clause.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).lowercased()
        guard unit.hasPrefix("min") else { return nil }
        return minutes
    }

    /// The engine's full output for one day: sessions, dropped slots, and the location used.
    ///
    /// `droppedSlots` names the slots with no safe/feasible exercise so the session note can say
    /// why, honestly.
    public struct DayPlan {
        public var splitName: String
        public var dayTitle: String
        public var sessions: [SessionSuggestion]
        public var droppedSlots: [String]
        public var locationName: String

        public init(splitName: String, dayTitle: String, sessions: [SessionSuggestion], droppedSlots: [String], locationName: String) {
            self.splitName = splitName
            self.dayTitle = dayTitle
            self.sessions = sessions
            self.droppedSlots = droppedSlots
            self.locationName = locationName
        }
    }

    /// Renders the session(s) for one day of the split. `rotationIndex` picks the day (wrapped into
    /// range); the app passes ``nextDayIndex(in:recentSessionNames:)`` so the program walks the
    /// split in order, one completed day at a time.
    public static func dayPlan(
        goal: GoalType,
        intensity: WorkoutIntensity,
        profile: WorkoutProfile,
        location: WorkoutLocation,
        context: String,
        split: TrainingSplit,
        rotationIndex: Int,
        progression: [String: Int] = [:],
        catalog: [ExerciseTarget] = WorkoutExerciseCatalog.allExercises
    ) -> DayPlan {
        // R5: `TrainingSplit` is publicly constructible, so `days` can be empty — and the old
        // `max(count, 1)` made that trap on `days[0]` instead of degrading. Fall back to the same
        // "just move" session the empty-render path below produces.
        guard !split.days.isEmpty else {
            return DayPlan(splitName: split.name, dayTitle: "Move",
                           sessions: [Self.fallbackSession], droppedSlots: [],
                           locationName: location.name)
        }
        let dayCount = split.days.count
        let day = split.days[((rotationIndex % dayCount) + dayCount) % dayCount]
        let style = WorkoutGoalStyle.style(for: goal, energy: intensity, sport: profile.sport)
        let feasible = WorkoutSafetyFilter.feasibleExercises(in: catalog, location: location, profile: profile)
        let biasTokens = selectionTokens(profile: profile, context: context)

        var dayUsed: Set<String> = []
        var dropped: [String] = []
        var sessions: [SessionSuggestion] = []

        for session in day.sessions {
            let rendered = render(
                session: session, goal: goal, intensity: intensity, style: style,
                feasible: feasible, biasTokens: biasTokens, used: &dayUsed,
                profile: profile, location: location, context: context,
                isMultiSession: day.sessions.count > 1, progression: progression
            )
            dropped.append(contentsOf: rendered.dropped)
            sessions.append(rendered.session)
        }

        if sessions.isEmpty {
            sessions = [Self.fallbackSession]
        }

        return DayPlan(splitName: split.name, dayTitle: day.title, sessions: sessions, droppedSlots: dropped, locationName: location.name)
    }

    /// How many past training days ``nextDayIndex(in:recentSessionNames:)`` looks through.
    public static let rotationLookbackDays = 28
    /// Workout names read per past day — a day logs a handful at most; this bounds the scan.
    static let rotationNamesPerDay = 12

    /// The split day to plan next: the day after the most recent split day the user logged, or the
    /// first day when nothing recent belongs to this split.
    ///
    /// Sequence, not calendar: the old weekday rotation (`weekday % days`) handed someone who
    /// trains Monday and Wednesday on a two-day split the same session every time, and gave every
    /// calendar day a session. Now each finished day advances the program by one, whenever it
    /// happens, so every session comes round in turn.
    ///
    /// - Parameter recentSessionNames: one entry per past day that logged workouts, most recent
    ///   first, each the names logged that day. Pass days BEFORE today, so today's plan stays put
    ///   once its session is logged. A day matches the split day sharing the most session display
    ///   names with it ("Upper", "Morning · Easy cardio"); ties go to the earlier split day, which
    ///   keeps a repeated day (Upper twice in Upper/Lower) alternating correctly.
    public static func nextDayIndex(in split: TrainingSplit, recentSessionNames: [[String]]) -> Int {
        guard !split.days.isEmpty else { return 0 }
        let dayNames = split.days.map { day in
            Set(day.sessions.map { sessionDisplayName($0, timeLabel: $0.time.label) })
        }
        for logged in recentSessionNames.prefix(rotationLookbackDays) {
            let names = Set(logged.prefix(rotationNamesPerDay))
            var best: (index: Int, overlap: Int)?
            for (index, sessionNames) in dayNames.enumerated() {
                let overlap = sessionNames.intersection(names).count
                if overlap > 0, overlap > (best?.overlap ?? 0) { best = (index, overlap) }
            }
            if let best { return (best.index + 1) % split.days.count }
        }
        return 0
    }

    /// The "there is always something to do" session used when a split renders nothing at all.
    private static var fallbackSession: SessionSuggestion {
        SessionSuggestion(
            title: "Move", timeLabel: "", kind: .fullBody,
            suggestion: WorkoutSuggestion(name: "Easy full body",
                                          exercises: "Full-body bodyweight circuit - 3 rounds",
                                          notes: "A simple option for today.")
        )
    }

    private static func render(
        session: WorkoutSessionTemplate,
        goal: GoalType,
        intensity: WorkoutIntensity,
        style: WorkoutGoalStyle,
        feasible: [ExerciseTarget],
        biasTokens: Set<String>,
        used: inout Set<String>,
        profile: WorkoutProfile,
        location: WorkoutLocation,
        context: String,
        isMultiSession: Bool,
        progression: [String: Int]
    ) -> (session: SessionSuggestion, dropped: [String]) {
        let timeLabel = session.time.label

        switch session.kind {
        case .cardio, .mobility:
            let detail = session.conditioning ?? style.conditioningLabel
            let exercises = [PrescribedExercise(name: detail, sets: 0, reps: "", role: .accessory, fromCatalog: false)]
            let suggestion = WorkoutSuggestion(
                name: sessionDisplayName(session, timeLabel: timeLabel),
                exercises: detail,
                notes: notes(goal: goal, location: location, context: context, dropped: [], profile: profile, includeContext: !isMultiSession, weeksDone: 0)
            )
            return (SessionSuggestion(title: session.title, timeLabel: timeLabel, kind: session.kind, exercises: exercises, suggestion: suggestion), [])

        case .strength, .fullBody, .sport:
            let inputs = SlotInputs(
                goal: goal, intensity: intensity, style: style, feasible: feasible, biasTokens: biasTokens,
                profile: profile, location: location, progression: progression
            )
            let built = buildBlocks(session: session, inputs: inputs, used: &used)
            let suggestion = WorkoutSuggestion(
                name: sessionDisplayName(session, timeLabel: timeLabel),
                exercises: WorkoutSessionBlocks.planText(for: built.exercises),
                notes: notes(goal: goal, location: location, context: context, dropped: built.dropped, profile: profile, includeContext: !isMultiSession, weeksDone: built.weeksDone)
            )
            return (SessionSuggestion(title: session.title, timeLabel: timeLabel, kind: session.kind, exercises: built.exercises, suggestion: suggestion), built.dropped)
        }
    }

    /// What every slot pick in one day's render shares.
    private struct SlotInputs {
        let goal: GoalType
        let intensity: WorkoutIntensity
        let style: WorkoutGoalStyle
        let feasible: [ExerciseTarget]
        let biasTokens: Set<String>
        let profile: WorkoutProfile
        let location: WorkoutLocation
        let progression: [String: Int]
    }

    /// The core slot a session without one of its own gets for its activation block.
    private static let activationCoreSlot = WorkoutSlotSpec(
        label: "Core", role: .core, muscles: [.abs, .obliques], region: .core
    )

    /// A lifting session's movements in run order — warm-up, activation, lifting, cardio,
    /// cool-down — plus the slots it dropped and the progression week for its note.
    ///
    /// The template's core slot moves into the activation block, ahead of the lifting, and is
    /// prescribed light; a session without one gets a light core pick there anyway. The cool-down
    /// stretches the muscles the lifting picks actually worked.
    private static func buildBlocks(
        session: WorkoutSessionTemplate, inputs: SlotInputs, used: inout Set<String>
    ) -> (exercises: [PrescribedExercise], dropped: [String], weeksDone: Int) {
        let slots = Array(session.slots.prefix(inputs.profile.experience.maxSlotsPerDay))
        let liftSlots = slots.filter { $0.role != .core }
        let coreSlots = slots.filter { $0.role == .core }
        var dropped: [String] = []
        let core = fill(coreSlots.isEmpty ? [activationCoreSlot] : coreSlots, block: .activation,
                        inputs: inputs, used: &used, dropped: &dropped, reportDrops: !coreSlots.isEmpty)
        let lifting = fill(liftSlots, block: .lifting, inputs: inputs, used: &used, dropped: &dropped, reportDrops: true)
        let legPatterns: Set<MovementPattern> = [.squat, .hinge, .lunge]
        let trainsLegs = liftSlots.contains { $0.movement.map(legPatterns.contains) ?? false }
        let activation = core.map(\.exercise) + WorkoutSessionBlocks.balanceAndJumps(
            feasible: inputs.feasible, experience: inputs.profile.experience, goal: inputs.goal,
            intensity: inputs.intensity, trainsLegs: trainsLegs
        )
        var cardio: [PrescribedExercise] = []
        if session.kind == .sport { cardio.append(descriptorStep(inputs.style.conditioningLabel)) }
        if let extra = session.conditioning { cardio.append(descriptorStep(extra)) }
        var liftingSteps = lifting.map(\.exercise)
        if liftingSteps.isEmpty && cardio.isEmpty {
            liftingSteps = [descriptorStep("Full-body bodyweight circuit - 3 rounds", block: .lifting)]
        }
        let worked = lifting.reduce(into: Set<MuscleGroup>()) { $0.formUnion($1.target.primaryMuscles) }
        let exercises = WorkoutSessionBlocks.warmUp(feasible: inputs.feasible) + activation + liftingSteps
            + cardio + WorkoutSessionBlocks.coolDown(worked: worked, feasible: inputs.feasible)
        let weeksDone = lifting.map(\.completions).min() ?? 0
        return (exercises, dropped, weeksDone)
    }

    /// Fills slots in order with their best eligible pick, prescribing each for its block, and
    /// records the label of every slot nothing could fill (when `reportDrops`).
    private static func fill(
        _ slots: [WorkoutSlotSpec], block: SessionBlock, inputs: SlotInputs,
        used: inout Set<String>, dropped: inout [String], reportDrops: Bool
    ) -> [(exercise: PrescribedExercise, target: ExerciseTarget, completions: Int)] {
        var picks: [(exercise: PrescribedExercise, target: ExerciseTarget, completions: Int)] = []
        for slot in slots {
            let pick = bestExercise(
                for: slot, in: inputs.feasible, excluding: used, biasTokens: inputs.biasTokens,
                experience: inputs.profile.experience, location: inputs.location
            )
            guard let pick else {
                if reportDrops { dropped.append(slot.label) }
                continue
            }
            used.insert(pick.name)
            let completions = block == .lifting ? inputs.progression[pick.name] ?? 0 : 0
            picks.append((prescribe(pick, role: slot.role, block: block, completions: completions, inputs: inputs), pick, completions))
        }
        return picks
    }

    /// Sets and reps (or a hold) for one pick. Lifting picks follow the goal and the day's energy,
    /// with double progression on rep-counted work; activation picks are deliberately light — two
    /// easy sets — so the trunk is awake, not tired, when the heavy lifting starts.
    private static func prescribe(
        _ pick: ExerciseTarget, role: SlotRole, block: SessionBlock, completions: Int, inputs: SlotInputs
    ) -> PrescribedExercise {
        let timed = pick.measure == .seconds
        if block == .activation {
            let hold = WorkoutSessionBlocks.activationHoldSeconds
            return PrescribedExercise(
                name: pick.name, sets: 2, reps: timed ? PrescribedExercise.holdText(seconds: hold) : inputs.style.reps(for: .core),
                role: role, fromCatalog: true, restSecondsOverride: 20, block: .activation, holdSeconds: timed ? hold : nil
            )
        }
        let sets = inputs.style.adjustedSets(for: role, energy: inputs.intensity)
        if timed {
            let hold = inputs.style.holdSeconds
            return PrescribedExercise(name: pick.name, sets: sets, reps: PrescribedExercise.holdText(seconds: hold),
                                      role: role, fromCatalog: true, holdSeconds: hold)
        }
        let progressed = progressedPrescription(baseSets: sets, baseReps: inputs.style.reps(for: role), completions: completions)
        return PrescribedExercise(name: pick.name, sets: progressed.sets, reps: progressed.reps, role: role, fromCatalog: true)
    }

    /// A non-catalog descriptor line (a conditioning finisher, the fallback circuit).
    private static func descriptorStep(_ text: String, block: SessionBlock = .cardio) -> PrescribedExercise {
        PrescribedExercise(name: text, sets: 0, reps: "", role: .accessory, fromCatalog: false, block: block)
    }

    /// Double progression: reps climb within the goal's range week to week, then reset with a slight
    /// volume bump. Deterministic and weight-free (the app doesn't log loads) — the note nudges load.
    public static func progressedPrescription(baseSets: Int, baseReps: String, completions: Int) -> (sets: Int, reps: String) {
        guard completions > 0 else { return (baseSets, baseReps) }
        if let dash = baseReps.firstIndex(of: "-"),
           let low = Int(baseReps[..<dash]),
           let high = Int(baseReps[baseReps.index(after: dash)...]), high >= low {
            let cycleLength = (high - low) + 1
            let cycles = completions / cycleLength
            let reps = low + (completions % cycleLength)
            let sets = baseSets + min(cycles / 2, 1)
            return (sets, "\(reps)")
        }
        if let fixed = Int(baseReps) {
            let sets = baseSets + min(completions / 3, 1)
            return (sets, "\(fixed)")
        }
        return (baseSets, baseReps)
    }

    /// Replaces a session's lifting block with an AI-adjusted set, rebuilding its display + note.
    /// The warm-up, activation, cardio and cool-down blocks around it are kept as they were.
    public static func applyAdjustment(to session: SessionSuggestion, exercises: [PrescribedExercise]) -> SessionSuggestion {
        guard exercises.isEmpty == false else { return session }
        var updated = session
        let lifting = exercises.map { exercise -> PrescribedExercise in
            var copy = exercise
            copy.block = .lifting
            return copy
        }
        let before = session.exercises.filter { $0.block == .warmUp || $0.block == .activation }
        let after = session.exercises.filter { $0.block == .cardio || $0.block == .coolDown }
        updated.exercises = before + lifting + after
        var note = session.suggestion.notes
        let adjustedTag = "Adjusted to your note."
        if note.contains(adjustedTag) == false {
            note = note.isEmpty ? adjustedTag : "\(note) · \(adjustedTag)"
        }
        updated.suggestion = WorkoutSuggestion(
            name: session.suggestion.name,
            exercises: WorkoutSessionBlocks.planText(for: updated.exercises),
            notes: note
        )
        return updated
    }

    private static func sessionDisplayName(_ session: WorkoutSessionTemplate, timeLabel: String) -> String {
        timeLabel.isEmpty ? session.title : "\(timeLabel) · \(session.title)"
    }

    /// The highest-scoring eligible exercise for a slot, or nil when nothing is eligible (the slot
    /// is then dropped and named in the session note). Ties fall to the name, so the pick is
    /// deterministic; the equipment and difficulty terms in ``slotScore`` keep real ties rare.
    static func bestExercise(
        for slot: WorkoutSlotSpec,
        in feasible: [ExerciseTarget],
        excluding used: Set<String>,
        biasTokens: Set<String>,
        experience: ExperienceLevel,
        location: WorkoutLocation
    ) -> ExerciseTarget? {
        feasible
            .filter { used.contains($0.name) == false && isEligible($0, for: slot) }
            .map { exercise -> (ExerciseTarget, Int) in
                let score = slotScore(
                    slot: slot, exercise: exercise, biasTokens: biasTokens,
                    experience: experience, location: location
                )
                return (exercise, score)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.name < rhs.0.name
            }
            .first?.0
    }

    /// Whether an exercise can fill a slot at all: strength work that shares the slot's movement
    /// pattern, its plane (when both name one) and at least one primary muscle. A timed movement (a
    /// plank, a carry) qualifies too — it is prescribed as a hold, never as reps.
    ///
    /// These are the guards the old score-only picker lacked — any positive score used to win, so a
    /// biceps slot could take an ab wheel, a vertical pull a cable row, and a squat slot a box jump.
    public static func isEligible(_ exercise: ExerciseTarget, for slot: WorkoutSlotSpec) -> Bool {
        guard exercise.modality == .strength else { return false }
        if let movement = slot.movement, exercise.movementPattern != movement { return false }
        if let plane = slot.plane, let own = exercise.plane, own != plane { return false }
        if !slot.muscles.isEmpty, exercise.primaryMuscles.isDisjoint(with: slot.muscles) { return false }
        return true
    }

    /// How well an eligible exercise fits a slot for this lifter at this location.
    ///
    /// Target fit first (region, primary and secondary muscles, compound-vs-isolation for the
    /// role), then a small penalty per primary muscle the slot does not ask for (a flat press beats
    /// an incline press for a chest slot), then the preferred tool and the difficulty that suits
    /// the lifter's level, then the user's interest words.
    static func slotScore(
        slot: WorkoutSlotSpec,
        exercise: ExerciseTarget,
        biasTokens: Set<String>,
        experience: ExperienceLevel,
        location: WorkoutLocation
    ) -> Int {
        var score = 0
        if let movement = slot.movement, exercise.movementPattern == movement { score += 100 }
        if let region = slot.region, exercise.bodyRegion == region { score += 50 }
        if slot.muscles.isEmpty == false {
            score += exercise.primaryMuscles.intersection(slot.muscles).count * 40
            score += exercise.secondaryMuscles.intersection(slot.muscles).count * 12
            score -= exercise.primaryMuscles.subtracting(slot.muscles).count * 8
        }
        switch slot.role {
        case .main:
            score += exercise.movementPattern == .isolation ? -25 : 20
        case .accessory, .core:
            score += exercise.movementPattern == .isolation ? 12 : 0
        }
        let tools = ([exercise.equipment] + exercise.alternativeEquipment).filter(location.has)
        score += tools.map { equipmentPreference($0, role: slot.role, experience: experience) }.max() ?? 0
        score += difficultyFit(exercise.difficulty, experience: experience)
        let nameTokens = Set(exercise.name.lowercased().split(separator: " ").map(String.init))
        if nameTokens.isDisjoint(with: biasTokens) == false { score += 15 }
        return score
    }

    /// Preference for the tool an exercise is loaded with, by slot role and experience.
    ///
    /// Main lifts for trained lifters go to the barbell, then dumbbells; beginners start on the
    /// dumbbell, machine and cable options that NASM and ACSM favor for novices (easier to learn,
    /// easier to load in small steps). Accessory and core work prefers dumbbells, cables and
    /// machines. Bands and bare bodyweight are the fallbacks when nothing loadable is there — the
    /// gap that used to let "Band chest press" win a full gym's bench slot on alphabetical order.
    static func equipmentPreference(_ equipment: Equipment, role: SlotRole, experience: ExperienceLevel) -> Int {
        switch (role, experience) {
        case (.main, .beginner):
            switch equipment {
            case .dumbbell: 30
            case .machine: 28
            case .cable: 26
            case .kettlebell: 24
            case .barbell: 16
            case .bodyweight: 12
            case .bench: 10
            case .band: 8
            case .cardio, .none: 0
            }
        case (.main, _):
            switch equipment {
            case .barbell: 30
            case .dumbbell: 24
            case .kettlebell: 18
            case .machine, .cable: 16
            case .bench: 10
            case .bodyweight: 8
            case .band: 4
            case .cardio, .none: 0
            }
        case (.accessory, _), (.core, _):
            switch equipment {
            case .dumbbell, .cable: 20
            case .machine: 18
            case .kettlebell: 14
            case .barbell, .bodyweight: 10
            case .bench, .band: 8
            case .none: 6
            case .cardio: 0
            }
        }
    }

    /// How well an exercise's difficulty suits the lifter: beginners lean to foundational moves and
    /// steer well clear of advanced ones; trained lifters lean slightly away from the regressions
    /// (an incline push-up when a push-up is there).
    static func difficultyFit(_ difficulty: ExerciseDifficulty, experience: ExperienceLevel) -> Int {
        switch (experience, difficulty) {
        case (.beginner, .foundational): 6
        case (.beginner, .advanced): -60
        case (.intermediate, .foundational): -4
        case (.intermediate, .advanced): -10
        case (.advanced, .foundational): -6
        case (_, .standard), (.advanced, .advanced): 0
        }
    }

    private static func selectionTokens(profile: WorkoutProfile, context: String) -> Set<String> {
        var tokens: Set<String> = []
        for interest in profile.interests { tokens.formUnion(interest.lowercased().split(separator: " ").map(String.init)) }
        tokens.formUnion(profile.sport.lowercased().split(separator: " ").map(String.init))
        tokens.formUnion(context.lowercased().split(separator: " ").map(String.init))
        return tokens.filter { $0.count >= 3 }
    }

    private static func notes(
        goal: GoalType,
        location: WorkoutLocation,
        context: String,
        dropped: [String],
        profile: WorkoutProfile,
        includeContext: Bool,
        weeksDone: Int
    ) -> String {
        var parts: [String] = [location.name]
        if weeksDone > 0 {
            parts.append("Week \(weeksDone + 1) — nudge the weight or reps up a little from last time.")
        }
        if includeContext, context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            parts.append("Noted: \(context.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if profile.avoidedMuscles.isEmpty == false || profile.avoidedMovements.isEmpty == false {
            parts.append("Worked around your noted limits.")
        }
        if dropped.isEmpty == false {
            parts.append("Skipped \(dropped.joined(separator: ", ")) — no safe option here.")
        }
        return parts.joined(separator: " · ")
    }
}

