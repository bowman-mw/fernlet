import Foundation

// MARK: - Experience level

enum ExperienceLevel: String, Codable, CaseIterable, Identifiable {
    case beginner
    case intermediate
    case advanced

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .beginner: "Beginner"
        case .intermediate: "Intermediate"
        case .advanced: "Advanced"
        }
    }

    /// Beginners get fewer accessory slots so sessions stay sustainable.
    var maxSlotsPerDay: Int {
        switch self {
        case .beginner: 5
        case .intermediate: 6
        case .advanced: 7
        }
    }

    var points: Int {
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
struct WorkoutProfile: Codable, Equatable {
    var avoidedMuscles: Set<MuscleGroup>
    var avoidedMovements: Set<MovementPattern>
    var injuryNotes: String
    var interests: [String]
    var sport: String
    var trainingDaysPerWeek: Int
    var experience: ExperienceLevel
    /// nil → use the recommended split. Otherwise a `TrainingSplit.id`.
    var selectedSplitID: String?

    init(
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

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        avoidedMuscles = try c.decodeIfPresent(Set<MuscleGroup>.self, forKey: .avoidedMuscles) ?? []
        avoidedMovements = try c.decodeIfPresent(Set<MovementPattern>.self, forKey: .avoidedMovements) ?? []
        injuryNotes = try c.decodeIfPresent(String.self, forKey: .injuryNotes) ?? ""
        interests = try c.decodeIfPresent([String].self, forKey: .interests) ?? []
        sport = try c.decodeIfPresent(String.self, forKey: .sport) ?? ""
        trainingDaysPerWeek = try c.decodeIfPresent(Int.self, forKey: .trainingDaysPerWeek) ?? 3
        experience = try c.decodeIfPresent(ExperienceLevel.self, forKey: .experience) ?? .beginner
        selectedSplitID = try c.decodeIfPresent(String.self, forKey: .selectedSplitID)
    }

    /// Best-effort mapping of free-text constraint/injury phrases into structured contraindications,
    /// used to carry onboarding text (e.g. "shoulder issues") into the safety filter. Conservative:
    /// over-restricting is the safe direction. The raw text is kept in `injuryNotes`.
    static func avoidedMuscles(fromConstraintText text: String) -> Set<MuscleGroup> {
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

    static func avoidedMovements(fromConstraintText text: String) -> Set<MovementPattern> {
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
    static func fromOnboarding(level: String, interests: String, constraints: String) -> WorkoutProfile {
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
enum EquipmentCategory: String, CaseIterable, Identifiable {
    case cardio
    case freeWeights
    case machines
    case functional
    case recovery

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cardio: "Cardio"
        case .freeWeights: "Free weights"
        case .machines: "Machines"
        case .functional: "Functional"
        case .recovery: "Recovery"
        }
    }
}

/// Specific pieces of equipment the user checks off per location. Each maps down to a coarse
/// `Equipment` capability that the planning engine / safety filter actually reasons about.
enum GymEquipment: String, Codable, CaseIterable, Identifiable {
    case treadmill, exerciseBike, rowingMachine, elliptical, stairClimber
    case dumbbells, barbell, kettlebells, weightPlates, weightBench
    case cableMachine, latPulldown, legPress, smithMachine, chestPress
    case pullUpBar, squatRack, resistanceBands, medicineBall, battleRopes
    case yogaMat, foamRoller

    var id: String { rawValue }

    var category: EquipmentCategory {
        switch self {
        case .treadmill, .exerciseBike, .rowingMachine, .elliptical, .stairClimber: .cardio
        case .dumbbells, .barbell, .kettlebells, .weightPlates, .weightBench: .freeWeights
        case .cableMachine, .latPulldown, .legPress, .smithMachine, .chestPress: .machines
        case .pullUpBar, .squatRack, .resistanceBands, .medicineBall, .battleRopes: .functional
        case .yogaMat, .foamRoller: .recovery
        }
    }

    var displayName: String {
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
    var systemImage: String {
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
    var capability: Equipment {
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
struct LocationTemplate: Identifiable {
    var id: String
    var name: String
    var subtitle: String
    var systemImage: String
    var equipment: Set<GymEquipment>

    func makeLocation() -> WorkoutLocation {
        WorkoutLocation(name: name, ownedEquipment: equipment)
    }

    static let all: [LocationTemplate] = [
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
struct WorkoutLocation: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var ownedEquipment: Set<GymEquipment>

    init(id: UUID = UUID(), name: String, ownedEquipment: Set<GymEquipment>) {
        self.id = id
        self.name = name
        self.ownedEquipment = ownedEquipment
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        // Defensive: drop any unknown raw values rather than throwing (handles older saves).
        let raws = (try? c.decodeIfPresent([String].self, forKey: .ownedEquipment)) ?? []
        ownedEquipment = Set(raws.compactMap(GymEquipment.init(rawValue:)))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(ownedEquipment.map(\.rawValue).sorted(), forKey: .ownedEquipment)
    }

    private enum CodingKeys: String, CodingKey { case id, name, ownedEquipment }

    /// Equipment available regardless of location (no gear required).
    static let alwaysAvailable: Set<Equipment> = [.bodyweight, .none]

    /// Coarse capabilities the planning engine checks against, derived from granular equipment.
    var capabilities: Set<Equipment> {
        var caps = Self.alwaysAvailable
        for item in ownedEquipment { caps.insert(item.capability) }
        return caps
    }

    func has(_ equipment: Equipment) -> Bool {
        capabilities.contains(equipment)
    }

    /// Count of equipment in a given category (for the "n of N" selection counters).
    func selectedCount(in category: EquipmentCategory) -> Int {
        ownedEquipment.filter { $0.category == category }.count
    }

    /// The default location: assume the user has every standard piece of gym equipment.
    static var fullGym: WorkoutLocation {
        WorkoutLocation(name: "Full gym", ownedEquipment: Set(GymEquipment.allCases))
    }

    static var home: WorkoutLocation {
        WorkoutLocation(name: "Home", ownedEquipment: [.dumbbells, .kettlebells, .resistanceBands, .yogaMat, .pullUpBar])
    }
}

// MARK: - Deterministic safety / equipment feasibility

/// The single authority on whether an exercise is allowed for a user. Deterministic by design — the
/// AI adjuster (added later) must run its output back through this, never around it.
/// Not medical advice: it filters on coarse, user-supplied contraindications.
enum WorkoutSafetyFilter {
    static func feasible(_ exercise: ExerciseTarget, location: WorkoutLocation, profile: WorkoutProfile) -> Bool {
        guard location.has(exercise.equipment) else { return false }
        if profile.avoidedMovements.contains(exercise.movementPattern) { return false }
        if profile.avoidedMuscles.isEmpty == false {
            let worked = exercise.primaryMuscles.union(exercise.secondaryMuscles)
            if worked.isDisjoint(with: profile.avoidedMuscles) == false { return false }
        }
        return true
    }

    static func feasibleExercises(in catalog: [ExerciseTarget], location: WorkoutLocation, profile: WorkoutProfile) -> [ExerciseTarget] {
        catalog.filter { feasible($0, location: location, profile: profile) }
    }
}

// MARK: - Slot / session / split structure

enum SlotRole {
    case main          // compound, heavier
    case accessory     // isolation / lighter
    case core          // trunk
}

/// A slot describes the INTENT of a movement (pattern + target region/muscles + role), not a fixed
/// exercise. The engine fills it from the equipment- and injury-filtered catalog, so the same split
/// adapts to the user's location and limits while keeping the structure consistent week to week.
struct WorkoutSlotSpec {
    var label: String
    var role: SlotRole
    var movement: MovementPattern?
    var muscles: Set<MuscleGroup> = []
    var region: BodyRegion?
}

enum SessionKind: String {
    case strength
    case fullBody
    case cardio
    case mobility
    case sport
}

/// When in the day a session happens — lets a split prescribe e.g. morning cardio + evening lifting.
enum SessionTime: String {
    case any
    case morning
    case midday
    case evening

    var label: String {
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
struct WorkoutSessionTemplate {
    var title: String
    var kind: SessionKind
    var time: SessionTime = .any
    var slots: [WorkoutSlotSpec] = []
    var conditioning: String? = nil
}

/// A day in the split. Most days have one session; some (cardio + strength, two-a-days) have several.
struct WorkoutSplitDay {
    var title: String
    var sessions: [WorkoutSessionTemplate]
}

/// How specific a split is, from "just move" to a body-part split.
enum SplitSpecificity: Int, CaseIterable {
    case minimal = 0      // very broad: daily movement / full body
    case balanced = 1     // upper/lower, full-body rotations
    case focused = 2      // push/pull/legs
    case specialized = 3  // body-part / two-a-day

    var label: String {
        switch self {
        case .minimal: "Very broad"
        case .balanced: "Balanced"
        case .focused: "Focused"
        case .specialized: "Very specific"
        }
    }
}

struct TrainingSplit: Identifiable {
    var id: String
    var name: String
    var summary: String
    var specificity: SplitSpecificity
    var goalFit: Set<GoalType>
    var days: [WorkoutSplitDay]

    var daysPerWeek: Int { days.count }
    var sessionsPerWeek: Int { days.reduce(0) { $0 + $1.sessions.count } }

    var frequencySummary: String {
        let sessions = sessionsPerWeek
        let dayWord = daysPerWeek == 1 ? "day" : "days"
        if sessions == daysPerWeek {
            return "\(daysPerWeek) \(dayWord)/week"
        }
        return "\(daysPerWeek) \(dayWord) · \(sessions) sessions/week"
    }
}

extension WorkoutSessionTemplate {
    func at(_ time: SessionTime) -> WorkoutSessionTemplate {
        var copy = self
        copy.time = time
        return copy
    }
}

// MARK: - Session library

enum WorkoutSessions {
    // Strength sessions. Vertical/horizontal pushes & pulls are distinguished by target muscles
    // (the catalog tags only movementPattern); "not used today" diversifies picks within a day.
    static let fullBodyA = WorkoutSessionTemplate(title: "Full Body A", kind: .fullBody, slots: [
        WorkoutSlotSpec(label: "Squat", role: .main, movement: .squat, muscles: [.quads, .glutes]),
        WorkoutSlotSpec(label: "Horizontal push", role: .main, movement: .push, muscles: [.chest]),
        WorkoutSlotSpec(label: "Horizontal pull", role: .main, movement: .pull, muscles: [.upperBack, .lats]),
        WorkoutSlotSpec(label: "Hinge", role: .accessory, movement: .hinge, muscles: [.hamstrings, .glutes]),
        WorkoutSlotSpec(label: "Core", role: .core, muscles: [.abs, .obliques], region: .core),
    ])
    static let fullBodyB = WorkoutSessionTemplate(title: "Full Body B", kind: .fullBody, slots: [
        WorkoutSlotSpec(label: "Hinge", role: .main, movement: .hinge, muscles: [.hamstrings, .glutes]),
        WorkoutSlotSpec(label: "Vertical push", role: .main, movement: .push, muscles: [.frontDelts, .sideDelts]),
        WorkoutSlotSpec(label: "Vertical pull", role: .main, movement: .pull, muscles: [.lats]),
        WorkoutSlotSpec(label: "Lunge", role: .accessory, movement: .lunge, muscles: [.quads, .glutes]),
        WorkoutSlotSpec(label: "Core", role: .core, muscles: [.abs, .obliques], region: .core),
    ])
    static let fullBodyC = WorkoutSessionTemplate(title: "Full Body C", kind: .fullBody, slots: [
        WorkoutSlotSpec(label: "Lunge", role: .main, movement: .lunge, muscles: [.quads, .glutes]),
        WorkoutSlotSpec(label: "Incline push", role: .main, movement: .push, muscles: [.chest, .frontDelts]),
        WorkoutSlotSpec(label: "Row", role: .main, movement: .pull, muscles: [.upperBack, .lats]),
        WorkoutSlotSpec(label: "Carry / loaded", role: .accessory, movement: .carry, muscles: [.forearms, .traps]),
        WorkoutSlotSpec(label: "Core", role: .core, muscles: [.abs, .obliques], region: .core),
    ])
    static let upper = WorkoutSessionTemplate(title: "Upper", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Horizontal push", role: .main, movement: .push, muscles: [.chest]),
        WorkoutSlotSpec(label: "Horizontal pull", role: .main, movement: .pull, muscles: [.upperBack, .lats]),
        WorkoutSlotSpec(label: "Vertical push", role: .main, movement: .push, muscles: [.frontDelts, .sideDelts]),
        WorkoutSlotSpec(label: "Vertical pull", role: .accessory, movement: .pull, muscles: [.lats]),
        WorkoutSlotSpec(label: "Biceps", role: .accessory, movement: .isolation, muscles: [.biceps]),
        WorkoutSlotSpec(label: "Triceps", role: .accessory, movement: .isolation, muscles: [.triceps]),
    ])
    static let lower = WorkoutSessionTemplate(title: "Lower", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Squat", role: .main, movement: .squat, muscles: [.quads, .glutes]),
        WorkoutSlotSpec(label: "Hinge", role: .main, movement: .hinge, muscles: [.hamstrings, .glutes]),
        WorkoutSlotSpec(label: "Lunge", role: .accessory, movement: .lunge, muscles: [.quads, .glutes]),
        WorkoutSlotSpec(label: "Calves", role: .accessory, movement: .isolation, muscles: [.calves]),
        WorkoutSlotSpec(label: "Core", role: .core, muscles: [.abs, .obliques], region: .core),
    ])
    static let push = WorkoutSessionTemplate(title: "Push", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Horizontal push", role: .main, movement: .push, muscles: [.chest]),
        WorkoutSlotSpec(label: "Vertical push", role: .main, movement: .push, muscles: [.frontDelts, .sideDelts]),
        WorkoutSlotSpec(label: "Incline push", role: .accessory, movement: .push, muscles: [.chest, .frontDelts]),
        WorkoutSlotSpec(label: "Side delts", role: .accessory, movement: .isolation, muscles: [.sideDelts]),
        WorkoutSlotSpec(label: "Triceps", role: .accessory, movement: .isolation, muscles: [.triceps]),
    ])
    static let pull = WorkoutSessionTemplate(title: "Pull", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Vertical pull", role: .main, movement: .pull, muscles: [.lats]),
        WorkoutSlotSpec(label: "Horizontal pull", role: .main, movement: .pull, muscles: [.upperBack, .lats]),
        WorkoutSlotSpec(label: "Rear delts", role: .accessory, movement: .isolation, muscles: [.rearDelts]),
        WorkoutSlotSpec(label: "Biceps", role: .accessory, movement: .isolation, muscles: [.biceps]),
        WorkoutSlotSpec(label: "Hinge", role: .accessory, movement: .hinge, muscles: [.hamstrings, .glutes]),
    ])
    static let legs = WorkoutSessionTemplate(title: "Legs", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Squat", role: .main, movement: .squat, muscles: [.quads, .glutes]),
        WorkoutSlotSpec(label: "Hinge", role: .main, movement: .hinge, muscles: [.hamstrings, .glutes]),
        WorkoutSlotSpec(label: "Lunge", role: .accessory, movement: .lunge, muscles: [.quads, .glutes]),
        WorkoutSlotSpec(label: "Calves", role: .accessory, movement: .isolation, muscles: [.calves]),
        WorkoutSlotSpec(label: "Core", role: .core, muscles: [.abs, .obliques], region: .core),
    ])
    // Body-part sessions (specialized splits)
    static let chest = WorkoutSessionTemplate(title: "Chest", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Flat press", role: .main, movement: .push, muscles: [.chest]),
        WorkoutSlotSpec(label: "Incline press", role: .main, movement: .push, muscles: [.chest, .frontDelts]),
        WorkoutSlotSpec(label: "Chest isolation", role: .accessory, movement: .isolation, muscles: [.chest]),
        WorkoutSlotSpec(label: "Dip / decline", role: .accessory, movement: .push, muscles: [.chest, .triceps]),
        WorkoutSlotSpec(label: "Triceps", role: .accessory, movement: .isolation, muscles: [.triceps]),
    ])
    static let back = WorkoutSessionTemplate(title: "Back", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Vertical pull", role: .main, movement: .pull, muscles: [.lats]),
        WorkoutSlotSpec(label: "Horizontal pull", role: .main, movement: .pull, muscles: [.upperBack, .lats]),
        WorkoutSlotSpec(label: "Row variation", role: .accessory, movement: .pull, muscles: [.upperBack]),
        WorkoutSlotSpec(label: "Rear delts", role: .accessory, movement: .isolation, muscles: [.rearDelts]),
        WorkoutSlotSpec(label: "Biceps", role: .accessory, movement: .isolation, muscles: [.biceps]),
    ])
    static let shoulders = WorkoutSessionTemplate(title: "Shoulders", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Overhead press", role: .main, movement: .push, muscles: [.frontDelts, .sideDelts]),
        WorkoutSlotSpec(label: "Side delts", role: .accessory, movement: .isolation, muscles: [.sideDelts]),
        WorkoutSlotSpec(label: "Rear delts", role: .accessory, movement: .isolation, muscles: [.rearDelts]),
        WorkoutSlotSpec(label: "Front delts", role: .accessory, movement: .isolation, muscles: [.frontDelts]),
        WorkoutSlotSpec(label: "Traps", role: .accessory, movement: .isolation, muscles: [.traps]),
    ])
    static let arms = WorkoutSessionTemplate(title: "Arms", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Biceps", role: .main, movement: .isolation, muscles: [.biceps]),
        WorkoutSlotSpec(label: "Triceps", role: .main, movement: .isolation, muscles: [.triceps]),
        WorkoutSlotSpec(label: "Biceps 2", role: .accessory, movement: .isolation, muscles: [.biceps]),
        WorkoutSlotSpec(label: "Triceps 2", role: .accessory, movement: .isolation, muscles: [.triceps]),
        WorkoutSlotSpec(label: "Forearms / grip", role: .accessory, movement: .isolation, muscles: [.forearms]),
    ])
    static let arnoldChestBack = WorkoutSessionTemplate(title: "Chest & Back", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Flat press", role: .main, movement: .push, muscles: [.chest]),
        WorkoutSlotSpec(label: "Vertical pull", role: .main, movement: .pull, muscles: [.lats]),
        WorkoutSlotSpec(label: "Incline press", role: .accessory, movement: .push, muscles: [.chest]),
        WorkoutSlotSpec(label: "Horizontal pull", role: .accessory, movement: .pull, muscles: [.upperBack]),
        WorkoutSlotSpec(label: "Chest isolation", role: .accessory, movement: .isolation, muscles: [.chest]),
    ])
    static let arnoldShouldersArms = WorkoutSessionTemplate(title: "Shoulders & Arms", kind: .strength, slots: [
        WorkoutSlotSpec(label: "Overhead press", role: .main, movement: .push, muscles: [.frontDelts, .sideDelts]),
        WorkoutSlotSpec(label: "Side delts", role: .accessory, movement: .isolation, muscles: [.sideDelts]),
        WorkoutSlotSpec(label: "Biceps", role: .accessory, movement: .isolation, muscles: [.biceps]),
        WorkoutSlotSpec(label: "Triceps", role: .accessory, movement: .isolation, muscles: [.triceps]),
        WorkoutSlotSpec(label: "Rear delts", role: .accessory, movement: .isolation, muscles: [.rearDelts]),
    ])

    // Cardio / mobility / sport sessions (rendered from their descriptor, not the catalog)
    static let easyCardio = WorkoutSessionTemplate(title: "Easy cardio", kind: .cardio, conditioning: "Easy cardio - 20 min")
    static let intervals = WorkoutSessionTemplate(title: "Intervals", kind: .cardio, conditioning: "Intervals - 8 × 1 min hard / 1 min easy")
    static let longCardio = WorkoutSessionTemplate(title: "Steady cardio", kind: .cardio, conditioning: "Steady cardio - 40 min")
    static let mobility = WorkoutSessionTemplate(title: "Mobility", kind: .mobility, conditioning: "Mobility flow - 15 min")
    static let sportConditioning = WorkoutSessionTemplate(title: "Sport conditioning", kind: .sport, slots: [
        WorkoutSlotSpec(label: "Lower power", role: .main, movement: .squat, muscles: [.quads, .glutes]),
        WorkoutSlotSpec(label: "Carry / loaded", role: .accessory, movement: .carry, muscles: [.forearms, .traps]),
        WorkoutSlotSpec(label: "Core", role: .core, muscles: [.abs, .obliques], region: .core),
    ])
}

// MARK: - Split catalog (broad → specialized)

enum WorkoutSplitCatalog {
    static var fallback: TrainingSplit { fullBody3 }

    static let all: [TrainingSplit] = [
        dailyMove, fullBody2, recoveryFlow, fullBody3, upperLowerFull3, upperLower4,
        ppl3, cardioStrength4, sportPrep, pplUL5, ppl6, broSplit5, arnold6, twoADay,
    ]

    private static func day(_ title: String, _ sessions: [WorkoutSessionTemplate]) -> WorkoutSplitDay {
        WorkoutSplitDay(title: title, sessions: sessions)
    }

    // --- Minimal / very broad ---
    static let dailyMove = TrainingSplit(
        id: "daily-move", name: "Daily Movement",
        summary: "Easy full-body days and walks — just keep moving.",
        specificity: .minimal, goalFit: [.wellness, .mentalHealth, .recovery, .exploring],
        days: [day("Day 1", [WorkoutSessions.fullBodyA]), day("Day 2", [WorkoutSessions.easyCardio]), day("Day 3", [WorkoutSessions.fullBodyB])]
    )
    static let fullBody2 = TrainingSplit(
        id: "full-body-2", name: "Full Body ×2",
        summary: "Two full-body sessions a week. Simple and forgiving.",
        specificity: .minimal, goalFit: Set(GoalType.allCases),
        days: [day("Day 1", [WorkoutSessions.fullBodyA]), day("Day 2", [WorkoutSessions.fullBodyB])]
    )
    static let recoveryFlow = TrainingSplit(
        id: "recovery-flow", name: "Recovery Flow",
        summary: "Mobility and easy movement to feel better, not beat up.",
        specificity: .minimal, goalFit: [.recovery, .mentalHealth, .wellness],
        days: [day("Day 1", [WorkoutSessions.mobility]), day("Day 2", [WorkoutSessions.easyCardio]), day("Day 3", [WorkoutSessions.fullBodyA])]
    )

    // --- Balanced ---
    static let fullBody3 = TrainingSplit(
        id: "full-body-3", name: "Full Body ×3",
        summary: "Three full-body sessions — the most efficient way to cover everything.",
        specificity: .balanced, goalFit: Set(GoalType.allCases),
        days: [day("Day 1", [WorkoutSessions.fullBodyA]), day("Day 2", [WorkoutSessions.fullBodyB]), day("Day 3", [WorkoutSessions.fullBodyC])]
    )
    static let upperLowerFull3 = TrainingSplit(
        id: "upper-lower-full-3", name: "Upper / Lower / Full",
        summary: "A bit more focus than full-body, still only three days.",
        specificity: .balanced, goalFit: [.strength, .weightManagement, .wellness, .sportsPrep, .exploring],
        days: [day("Day 1", [WorkoutSessions.upper]), day("Day 2", [WorkoutSessions.lower]), day("Day 3", [WorkoutSessions.fullBodyC])]
    )
    static let upperLower4 = TrainingSplit(
        id: "upper-lower-4", name: "Upper / Lower",
        summary: "Four days alternating upper and lower body.",
        specificity: .balanced, goalFit: [.strength, .weightManagement, .wellness, .sportsPrep],
        days: [day("Day 1", [WorkoutSessions.upper]), day("Day 2", [WorkoutSessions.lower]), day("Day 3", [WorkoutSessions.upper]), day("Day 4", [WorkoutSessions.lower])]
    )

    // --- Focused ---
    static let ppl3 = TrainingSplit(
        id: "ppl-3", name: "Push / Pull / Legs",
        summary: "Classic three-day split organised by movement.",
        specificity: .focused, goalFit: [.strength, .sportsPrep, .weightManagement],
        days: [day("Push", [WorkoutSessions.push]), day("Pull", [WorkoutSessions.pull]), day("Legs", [WorkoutSessions.legs])]
    )
    static let cardioStrength4 = TrainingSplit(
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
    static let sportPrep = TrainingSplit(
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
    static let pplUL5 = TrainingSplit(
        id: "ppl-ul-5", name: "PPL + Upper / Lower",
        summary: "Five days mixing push/pull/legs with upper/lower.",
        specificity: .focused, goalFit: [.strength, .sportsPrep],
        days: [day("Push", [WorkoutSessions.push]), day("Pull", [WorkoutSessions.pull]), day("Legs", [WorkoutSessions.legs]), day("Upper", [WorkoutSessions.upper]), day("Lower", [WorkoutSessions.lower])]
    )
    static let ppl6 = TrainingSplit(
        id: "ppl-6", name: "Push / Pull / Legs ×2",
        summary: "Six high-frequency days for serious volume.",
        specificity: .focused, goalFit: [.strength, .sportsPrep],
        days: [day("Push A", [WorkoutSessions.push]), day("Pull A", [WorkoutSessions.pull]), day("Legs A", [WorkoutSessions.legs]), day("Push B", [WorkoutSessions.push]), day("Pull B", [WorkoutSessions.pull]), day("Legs B", [WorkoutSessions.legs])]
    )

    // --- Specialized / very specific ---
    static let broSplit5 = TrainingSplit(
        id: "bro-5", name: "Bro Split",
        summary: "One body part per day for maximum focus.",
        specificity: .specialized, goalFit: [.strength],
        days: [day("Chest", [WorkoutSessions.chest]), day("Back", [WorkoutSessions.back]), day("Shoulders", [WorkoutSessions.shoulders]), day("Arms", [WorkoutSessions.arms]), day("Legs", [WorkoutSessions.legs])]
    )
    static let arnold6 = TrainingSplit(
        id: "arnold-6", name: "Arnold Split",
        summary: "Chest+back, shoulders+arms, legs — twice over, six days.",
        specificity: .specialized, goalFit: [.strength],
        days: [day("Chest & Back", [WorkoutSessions.arnoldChestBack]), day("Shoulders & Arms", [WorkoutSessions.arnoldShouldersArms]), day("Legs", [WorkoutSessions.legs]), day("Chest & Back", [WorkoutSessions.arnoldChestBack]), day("Shoulders & Arms", [WorkoutSessions.arnoldShouldersArms]), day("Legs", [WorkoutSessions.legs])]
    )
    static let twoADay = TrainingSplit(
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

enum WorkoutConsistency: Int {
    case low = 0
    case medium = 1
    case high = 2

    var points: Int { rawValue }

    var label: String {
        switch self {
        case .low: "Getting started"
        case .medium: "Fairly consistent"
        case .high: "Very consistent"
        }
    }
}

/// Recommends splits from goal + how specific the user is ready for (experience + consistency +
/// activity level) + their preferred training days. The user can still pick any split.
enum WorkoutSplitRecommender {
    static func desiredSpecificity(experience: ExperienceLevel, consistency: WorkoutConsistency, activity: ActivityLevel) -> SplitSpecificity {
        let total = experience.points + consistency.points + activityPoints(activity) // 0…6
        switch total {
        case ...1: return .minimal
        case 2...3: return .balanced
        case 4...5: return .focused
        default: return .specialized
        }
    }

    static func ranked(
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
            .sorted { $0.score > $1.score }
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

struct WorkoutGoalStyle {
    var mainSets: Int
    var mainReps: String
    var accessorySets: Int
    var accessoryReps: String
    var includeConditioning: Bool
    var conditioningLabel: String

    /// Applies the day's energy: light trims a set; hard adds one.
    func adjustedSets(for role: SlotRole, energy: WorkoutIntensity) -> Int {
        let base = (role == .main) ? mainSets : accessorySets
        let delta = energy == .light ? -1 : (energy == .hard ? 1 : 0)
        return max(2, base + delta)
    }

    func reps(for role: SlotRole) -> String {
        switch role {
        case .main: mainReps
        case .accessory, .core: accessoryReps
        }
    }

    static func style(for goal: GoalType, energy: WorkoutIntensity, sport: String) -> WorkoutGoalStyle {
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
            return WorkoutGoalStyle(mainSets: 4, mainReps: "5", accessorySets: 3, accessoryReps: "8-10", includeConditioning: false, conditioningLabel: conditioning)
        case .sportsPrep:
            return WorkoutGoalStyle(mainSets: 4, mainReps: "5", accessorySets: 3, accessoryReps: "8-12", includeConditioning: false, conditioningLabel: conditioning)
        case .weightManagement:
            return WorkoutGoalStyle(mainSets: 3, mainReps: "8-12", accessorySets: 3, accessoryReps: "12-15", includeConditioning: false, conditioningLabel: conditioning)
        case .wellness:
            return WorkoutGoalStyle(mainSets: 3, mainReps: "8-12", accessorySets: 2, accessoryReps: "10-12", includeConditioning: false, conditioningLabel: conditioning)
        case .mentalHealth:
            return WorkoutGoalStyle(mainSets: 2, mainReps: "10-12", accessorySets: 2, accessoryReps: "10-12", includeConditioning: false, conditioningLabel: conditioning)
        case .recovery:
            return WorkoutGoalStyle(mainSets: 2, mainReps: "12-15", accessorySets: 2, accessoryReps: "12-15", includeConditioning: false, conditioningLabel: conditioning)
        case .exploring:
            return WorkoutGoalStyle(mainSets: 3, mainReps: "8-12", accessorySets: 3, accessoryReps: "10-12", includeConditioning: false, conditioningLabel: conditioning)
        }
    }
}

// MARK: - The engine: split day + profile + location → concrete session(s)

/// A concrete prescribed movement: a catalog exercise with sets/reps, or a non-catalog line
/// (e.g. a conditioning finisher) when `fromCatalog` is false.
struct PrescribedExercise: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var sets: Int
    var reps: String
    var role: SlotRole
    var fromCatalog: Bool

    var line: String { fromCatalog ? "\(name) - \(sets) x \(reps)" : name }
}

enum WorkoutProgram {
    struct SessionSuggestion: Identifiable {
        var id = UUID()
        var title: String
        var timeLabel: String
        var kind: SessionKind
        var exercises: [PrescribedExercise] = []
        var suggestion: WorkoutSuggestion

        /// Names of catalog exercises in this session (for progression bookkeeping).
        var catalogExerciseNames: [String] { exercises.filter(\.fromCatalog).map(\.name) }

        func workout(intensity: WorkoutIntensity) -> Workout {
            let mode: WorkoutMode = (kind == .strength || kind == .fullBody) ? .strengthTraining : .activity
            let type: WorkoutType = (kind == .cardio) ? .cardio : .fullBody
            return Workout(
                name: suggestion.name, type: type, mode: mode, exercises: suggestion.exercises,
                rpe: nil, notes: suggestion.notes, duration: nil, intensity: intensity
            )
        }
    }

    struct DayPlan {
        var splitName: String
        var dayTitle: String
        var sessions: [SessionSuggestion]
        var droppedSlots: [String]
        var locationName: String
    }

    /// Renders the session(s) for the next day in the user's persistent rotation. `rotationIndex`
    /// (weekday) picks today's day so the program stays consistent week to week.
    static func dayPlan(
        goal: GoalType,
        intensity: WorkoutIntensity,
        profile: WorkoutProfile,
        location: WorkoutLocation,
        context: String,
        split: TrainingSplit,
        rotationIndex: Int,
        progression: [String: Int] = [:],
        catalog: [ExerciseTarget] = WorkoutExerciseCatalog.baseExercises
    ) -> DayPlan {
        let dayCount = max(split.days.count, 1)
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
            sessions = [SessionSuggestion(
                title: "Move", timeLabel: "", kind: .fullBody,
                suggestion: WorkoutSuggestion(name: "Easy full body", exercises: "Full-body bodyweight circuit - 3 rounds", notes: "A simple option for today.")
            )]
        }

        return DayPlan(splitName: split.name, dayTitle: day.title, sessions: sessions, droppedSlots: dropped, locationName: location.name)
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
            var exercises: [PrescribedExercise] = []
            var dropped: [String] = []
            var weeksDone = Int.max
            for slot in session.slots.prefix(profile.experience.maxSlotsPerDay) {
                if let pick = bestExercise(for: slot, in: feasible, excluding: used, biasTokens: biasTokens) {
                    used.insert(pick.name)
                    let completions = progression[pick.name] ?? 0
                    weeksDone = min(weeksDone, completions)
                    let progressed = progressedPrescription(
                        baseSets: style.adjustedSets(for: slot.role, energy: intensity),
                        baseReps: style.reps(for: slot.role),
                        completions: completions
                    )
                    exercises.append(PrescribedExercise(name: pick.name, sets: progressed.sets, reps: progressed.reps, role: slot.role, fromCatalog: true))
                } else {
                    dropped.append(slot.label)
                }
            }
            if session.kind == .sport {
                exercises.append(PrescribedExercise(name: style.conditioningLabel, sets: 0, reps: "", role: .accessory, fromCatalog: false))
            }
            if let extra = session.conditioning {
                exercises.append(PrescribedExercise(name: extra, sets: 0, reps: "", role: .accessory, fromCatalog: false))
            }
            if exercises.isEmpty {
                exercises = [PrescribedExercise(name: "Full-body bodyweight circuit - 3 rounds", sets: 0, reps: "", role: .accessory, fromCatalog: false)]
            }
            let weeks = (weeksDone == Int.max) ? 0 : weeksDone

            let suggestion = WorkoutSuggestion(
                name: sessionDisplayName(session, timeLabel: timeLabel),
                exercises: exercises.map(\.line).joined(separator: "\n"),
                notes: notes(goal: goal, location: location, context: context, dropped: dropped, profile: profile, includeContext: !isMultiSession, weeksDone: weeks)
            )
            return (SessionSuggestion(title: session.title, timeLabel: timeLabel, kind: session.kind, exercises: exercises, suggestion: suggestion), dropped)
        }
    }

    /// Double progression: reps climb within the goal's range week to week, then reset with a slight
    /// volume bump. Deterministic and weight-free (the app doesn't log loads) — the note nudges load.
    static func progressedPrescription(baseSets: Int, baseReps: String, completions: Int) -> (sets: Int, reps: String) {
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

    /// Replaces a session's exercises with an AI-adjusted set, rebuilding its display + note.
    static func applyAdjustment(to session: SessionSuggestion, exercises: [PrescribedExercise]) -> SessionSuggestion {
        guard exercises.isEmpty == false else { return session }
        var updated = session
        updated.exercises = exercises
        var note = session.suggestion.notes
        let adjustedTag = "Adjusted to your note."
        if note.contains(adjustedTag) == false {
            note = note.isEmpty ? adjustedTag : "\(note) · \(adjustedTag)"
        }
        updated.suggestion = WorkoutSuggestion(
            name: session.suggestion.name,
            exercises: exercises.map(\.line).joined(separator: "\n"),
            notes: note
        )
        return updated
    }

    private static func sessionDisplayName(_ session: WorkoutSessionTemplate, timeLabel: String) -> String {
        timeLabel.isEmpty ? session.title : "\(timeLabel) · \(session.title)"
    }

    private static func bestExercise(
        for slot: WorkoutSlotSpec,
        in feasible: [ExerciseTarget],
        excluding used: Set<String>,
        biasTokens: Set<String>
    ) -> ExerciseTarget? {
        feasible
            .filter { used.contains($0.name) == false }
            .compactMap { exercise -> (ExerciseTarget, Int)? in
                let score = slotScore(slot: slot, exercise: exercise, biasTokens: biasTokens)
                return score > 0 ? (exercise, score) : nil
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.name < rhs.0.name
            }
            .first?.0
    }

    private static func slotScore(slot: WorkoutSlotSpec, exercise: ExerciseTarget, biasTokens: Set<String>) -> Int {
        var score = 0
        if let movement = slot.movement, exercise.movementPattern == movement { score += 100 }
        if let region = slot.region, exercise.bodyRegion == region { score += 50 }
        if slot.muscles.isEmpty == false {
            score += exercise.primaryMuscles.intersection(slot.muscles).count * 40
            score += exercise.secondaryMuscles.intersection(slot.muscles).count * 12
        }
        switch slot.role {
        case .main:
            score += exercise.movementPattern == .isolation ? -25 : 20
        case .accessory, .core:
            score += exercise.movementPattern == .isolation ? 12 : 0
        }
        let nameTokens = Set(exercise.name.lowercased().split(separator: " ").map(String.init))
        if nameTokens.isDisjoint(with: biasTokens) == false { score += 15 }
        return score
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

