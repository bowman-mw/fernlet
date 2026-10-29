import Foundation
import FernletFoundation

// MARK: - Experience level

/// Training experience (beginner/intermediate/advanced).
///
/// Caps accessory slots per session (`maxSlotsPerDay`) and contributes points toward the
/// recommended split specificity; decodes tolerantly on ``WorkoutProfile``.
public nonisolated enum ExperienceLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case beginner
    case intermediate
    case advanced

    public var id: String { rawValue }

    /// The level's name on screen, localized (2026-10-20, idea 16). ``rawValue`` is the token the
    /// profile persists and onboarding parses.
    public var displayName: String {
        switch self {
        case .beginner: String(localized: "experienceLevel.beginner", defaultValue: "Beginner", bundle: .module,
                               comment: "Training experience level in Workout setup: new to lifting")
        case .intermediate: String(localized: "experienceLevel.intermediate", defaultValue: "Intermediate", bundle: .module,
                                   comment: "Training experience level in Workout setup: some lifting experience")
        case .advanced: String(localized: "experienceLevel.advanced", defaultValue: "Advanced", bundle: .module,
                               comment: "Training experience level in Workout setup: years of lifting")
        }
    }

    /// The level as the answer to Workout setup's "How long have you lifted regularly?" (G8,
    /// 2026-10-20): under six months, six months to two years, more than two years — the training-age
    /// tiers the load engine paces progression by (``TrainingTier``). The same stored field; nothing
    /// new is kept, and each lift's own log refines it (``WorkoutLoadContext/trainingAge(for:)``).
    public var trainingAgeLabel: String {
        switch self {
        case .beginner: String(localized: "experienceLevel.trainingAge.beginner", defaultValue: "Under 6 months",
                               bundle: .module, comment: "Workout setup: answer to 'How long have you lifted regularly?' — less than six months")
        case .intermediate: String(localized: "experienceLevel.trainingAge.intermediate", defaultValue: "6 months to 2 years",
                                   bundle: .module, comment: "Workout setup: answer to 'How long have you lifted regularly?' — between six months and two years")
        case .advanced: String(localized: "experienceLevel.trainingAge.advanced", defaultValue: "More than 2 years",
                               bundle: .module, comment: "Workout setup: answer to 'How long have you lifted regularly?' — two years or longer")
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
    /// Opt-in: the monthly calibration tests a true one-rep max instead of a submaximal set.
    /// Honored for intermediate and advanced lifters only (``WorkoutCalibration/kind(profile:confidence:)``).
    public var oneRepMaxTesting: Bool = false

    /// The injury picker's body areas, each at mild or severe (``InjuryLimits`` says what each
    /// does; ``injuryLimits`` combines them with the note and the avoided sets).
    ///
    /// Read and written typed; persisted as frozen tokens in ``injuryAreaTokens``. Changing an
    /// area's severity here clears that area's parked token (the last editor wins, as with
    /// ``EnumDecodeCompat``'s scalar fields); a newer build's unknown areas stay parked.
    ///
    /// Persisted at the TOP LEVEL of ``FernletSettings`` (`workoutInjuryAreas`), not inside this
    /// struct's own encoding: every build since generic key parking keeps an unknown top-level key
    /// through a re-save, while an older build re-saving this struct would drop a nested key — and
    /// with it a person's limits.
    public var injuryAreas: [BodyArea: InjurySeverity] {
        get { InjuryAreaTokens.typed(injuryAreaTokens) }
        set {
            let old = injuryAreas
            injuryAreaTokens = InjuryAreaTokens.tokens(newValue)
            for area in BodyArea.allCases where old[area] != newValue[area] {
                unknownInjuryAreaTokens[area.rawValue] = nil
            }
        }
    }
    /// The persisted shape of ``injuryAreas``: area token → severity token, pairs this build knows
    /// only. FROZEN shape (a JSON object of strings): every build since 2026-10-20 decodes it as one.
    /// Not one of this struct's `CodingKeys` — ``FernletSettings`` writes it (see ``injuryAreas``).
    public private(set) var injuryAreaTokens: [String: String] = [:]
    /// Area → severity pairs this build can't read — a newer build's area, or a newer severity for
    /// a known area — parked and re-encoded so a save here can't strip a newer device's limit.
    public var unknownInjuryAreaTokens: [String: String] = [:]

    /// This struct's own wire keys — every stored property except the injury-area tokens, which
    /// ``FernletSettings`` carries at its top level. The names are the property names the encoding
    /// was synthesized with before, so the nested shape is unchanged.
    private enum CodingKeys: String, CodingKey {
        case avoidedMuscles, unknownAvoidedMuscleTokens, avoidedMovements, unknownAvoidedMovementTokens
        case injuryNotes, interests, sport, trainingDaysPerWeek, experience, unknownExperienceToken
        case selectedSplitID, oneRepMaxTesting
    }

    /// Takes the injury-area tokens ``FernletSettings`` decoded from its top level, through the
    /// tolerant, parked split (an unknown area or severity parks; a known parked severity is adopted).
    mutating func adoptInjuryAreaTokens(main: [String: String], parked: [String: String]) {
        let split = InjuryAreaTokens.split(main: main, parked: parked)
        injuryAreaTokens = split.known
        unknownInjuryAreaTokens = split.parked
    }

    public init(
        avoidedMuscles: Set<MuscleGroup> = [],
        avoidedMovements: Set<MovementPattern> = [],
        injuryNotes: String = "",
        interests: [String] = [],
        sport: String = "",
        trainingDaysPerWeek: Int = 3,
        experience: ExperienceLevel = .beginner,
        selectedSplitID: String? = nil,
        oneRepMaxTesting: Bool = false,
        injuryAreas: [BodyArea: InjurySeverity] = [:]
    ) {
        self.avoidedMuscles = avoidedMuscles
        self.avoidedMovements = avoidedMovements
        self.injuryNotes = injuryNotes
        self.interests = interests
        self.sport = sport
        self.trainingDaysPerWeek = trainingDaysPerWeek
        self.experience = experience
        self.selectedSplitID = selectedSplitID
        self.oneRepMaxTesting = oneRepMaxTesting
        self.injuryAreaTokens = InjuryAreaTokens.tokens(injuryAreas)
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
        oneRepMaxTesting = try c.decodeIfPresent(Bool.self, forKey: .oneRepMaxTesting) ?? false
    }

    /// Best-effort mapping of free-text constraint/injury phrases into structured contraindications,
    /// used to carry onboarding text (e.g. "shoulder issues") into the avoided sets older builds
    /// read. Whole words through ``InjuryNoteMatcher`` — "getting back into lifting" avoids nothing —
    /// and conservative: every area named is avoided whole. The raw text is kept in `injuryNotes`,
    /// which the planner reads live (``injuryLimits``).
    public static func avoidedMuscles(fromConstraintText text: String) -> Set<MuscleGroup> {
        let match = InjuryNoteMatcher.match(text)
        return match.areas.reduce(into: match.muscles) { $0.formUnion($1.muscles) }
    }

    /// The movement half of ``avoidedMuscles(fromConstraintText:)``.
    public static func avoidedMovements(fromConstraintText text: String) -> Set<MovementPattern> {
        InjuryNoteMatcher.match(text).areas.reduce(into: Set<MovementPattern>()) { $0.formUnion($1.movements) }
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

    /// The piece's name on screen — the location editor's cards and the custom-exercise form's
    /// required-gear chips — localized (2026-10-20, idea 16). ``rawValue`` is the frozen token: it is
    /// what a location persists, the trainer export carries and the catalog's `requiredGear` names.
    public var displayName: String {
        switch self {
        case .treadmill: String(localized: "gymEquipment.treadmill", defaultValue: "Treadmill", bundle: .module, comment: "Gym equipment: a treadmill")
        case .exerciseBike: String(localized: "gymEquipment.exerciseBike", defaultValue: "Exercise bike", bundle: .module, comment: "Gym equipment: a stationary exercise bike")
        case .rowingMachine: String(localized: "gymEquipment.rowingMachine", defaultValue: "Rowing machine", bundle: .module, comment: "Gym equipment: a rowing machine")
        case .elliptical: String(localized: "gymEquipment.elliptical", defaultValue: "Elliptical", bundle: .module, comment: "Gym equipment: an elliptical trainer")
        case .stairClimber: String(localized: "gymEquipment.stairClimber", defaultValue: "Stair climber", bundle: .module, comment: "Gym equipment: a stair-climbing machine")
        case .dumbbells: String(localized: "gymEquipment.dumbbells", defaultValue: "Dumbbells", bundle: .module, comment: "Gym equipment: dumbbells")
        case .barbell: String(localized: "gymEquipment.barbell", defaultValue: "Barbell", bundle: .module, comment: "Gym equipment: a barbell")
        case .kettlebells: String(localized: "gymEquipment.kettlebells", defaultValue: "Kettlebells", bundle: .module, comment: "Gym equipment: kettlebells")
        case .weightPlates: String(localized: "gymEquipment.weightPlates", defaultValue: "Weight plates", bundle: .module, comment: "Gym equipment: weight plates for a barbell")
        case .weightBench: String(localized: "gymEquipment.weightBench", defaultValue: "Weight bench", bundle: .module, comment: "Gym equipment: a weight bench")
        case .cableMachine: String(localized: "gymEquipment.cableMachine", defaultValue: "Cable machine", bundle: .module, comment: "Gym equipment: a cable machine")
        case .latPulldown: String(localized: "gymEquipment.latPulldown", defaultValue: "Lat pulldown", bundle: .module, comment: "Gym equipment: a lat pulldown machine")
        case .legPress: String(localized: "gymEquipment.legPress", defaultValue: "Leg press", bundle: .module, comment: "Gym equipment: a leg press machine")
        case .smithMachine: String(localized: "gymEquipment.smithMachine", defaultValue: "Smith machine", bundle: .module, comment: "Gym equipment: a Smith machine, a barbell on guide rails")
        case .chestPress: String(localized: "gymEquipment.chestPress", defaultValue: "Chest press", bundle: .module, comment: "Gym equipment: a chest press machine")
        case .pullUpBar: String(localized: "gymEquipment.pullUpBar", defaultValue: "Pull-up bar", bundle: .module, comment: "Gym equipment: a pull-up bar")
        case .squatRack: String(localized: "gymEquipment.squatRack", defaultValue: "Squat rack", bundle: .module, comment: "Gym equipment: a squat rack")
        case .resistanceBands: String(localized: "gymEquipment.resistanceBands", defaultValue: "Resistance bands", bundle: .module, comment: "Gym equipment: elastic resistance bands")
        case .medicineBall: String(localized: "gymEquipment.medicineBall", defaultValue: "Medicine ball", bundle: .module, comment: "Gym equipment: a medicine ball")
        case .battleRopes: String(localized: "gymEquipment.battleRopes", defaultValue: "Battle ropes", bundle: .module, comment: "Gym equipment: heavy battle ropes")
        case .yogaMat: String(localized: "gymEquipment.yogaMat", defaultValue: "Yoga mat", bundle: .module, comment: "Gym equipment: a yoga mat")
        case .foamRoller: String(localized: "gymEquipment.foamRoller", defaultValue: "Foam roller", bundle: .module, comment: "Gym equipment: a foam roller")
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
    /// `name` and `subtitle` stay the English literals, and this function BAKES `name` into the
    /// persisted `WorkoutLocation`, which the user can then rename. Localizing the stored name would be
    /// worse than leaving it: a French user's saved location would read "Salle de sport complète"
    /// until they switched language, after which the stored string would be frozen and wrong — the
    /// trap `PersonalCareTask.displayLabel` documents for built-in care tasks — and
    /// `availableTemplates` tells saved presets apart by this name.
    ///
    /// Screens draw it localized instead (2026-10-20, idea 16), with no schema change: a location
    /// whose stored name is still exactly a built-in English name draws ``WorkoutLocation/displayedName``,
    /// and a template card draws ``displayName`` and ``displaySubtitle``. A renamed location draws its
    /// own name.
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
///
/// Forward compatible both ways (2026-10-20). Equipment tokens a newer build added decode into
/// ``unknownEquipmentTokens`` and are written back beside the known ones (``EnumDecodeCompat``), and
/// any other key a newer build writes inside a location is parked in ``parkedUnknownKeys`` and written
/// back — so a re-save here no longer drops a newer device's equipment or fields. The location's
/// ``weights`` are NOT part of this encoding: ``FernletSettings`` carries them at its top level
/// (`workoutLocationWeights`), because builds before this one drop unknown nested keys on a re-save.
public nonisolated struct WorkoutLocation: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var ownedEquipment: Set<GymEquipment>
    /// Equipment a newer build ticked that this one does not know, kept and written back under
    /// `unknownOwnedEquipmentTokens` (deduplicated, bounded). Never shown or toggled here.
    public var unknownEquipmentTokens: [String] = []
    /// "Weights I have": the dumbbells, kettlebells, bar and plates here. Empty when not set.
    /// Persisted at the settings blob's top level (see the type's note).
    public var weights = WorkoutWeightInventory()
    /// A weights entry this build could not read (a unit only a newer build knows), kept verbatim and
    /// written back until the user sets this location's weights here (the last editor wins).
    public var unreadableWeights: JSONValue?
    /// Keys a newer build wrote inside this location that this one does not know, written back
    /// verbatim at the location's own level. Never read for meaning.
    public var parkedUnknownKeys: [String: JSONValue] = [:]

    /// Most unknown keys parked from one location (R3).
    public static let maxParkedKeys = 16

    public init(id: UUID = UUID(), name: String, ownedEquipment: Set<GymEquipment>) {
        self.id = id
        self.name = name
        self.ownedEquipment = ownedEquipment
    }

    public nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        // Unknown raw values park rather than throw or vanish (`splitRawTokens`). The decode itself
        // only throws when a key is PRESENT and is not an array of strings, i.e. real corruption,
        // which must not be silent (R7): the recovery is an empty list that the next save persists,
        // so it is named in the log.
        let raws = Self.tokens(c, .ownedEquipment)
        let parked = Self.tokens(c, .unknownOwnedEquipmentTokens)
        let split = EnumDecodeCompat.splitRawTokens(raws + parked, as: GymEquipment.self)
        ownedEquipment = Set(split.known)
        unknownEquipmentTokens = split.unknown
        parkedUnknownKeys = try Self.parkedKeys(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(ownedEquipment.map(\.rawValue).sorted(), forKey: .ownedEquipment)
        // Written only when something is parked, so every location so far keeps its exact shape.
        if !unknownEquipmentTokens.isEmpty {
            try c.encode(unknownEquipmentTokens, forKey: .unknownOwnedEquipmentTokens)
        }
        guard !parkedUnknownKeys.isEmpty else { return }
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        var parked = encoder.container(keyedBy: LocationParkedKey.self)
        for (key, value) in parkedUnknownKeys.sorted(by: { $0.key < $1.key }) where !known.contains(key) {
            try parked.encode(value, forKey: LocationParkedKey(stringValue: key))
        }
    }

    /// Persisted JSON keys for a ``WorkoutLocation``'s wire format.
    ///
    /// `ownedEquipment` is written as sorted raw values (see `encode(to:)`) so output is deterministic.
    /// `CaseIterable` so the decoder can tell which keys to park; renaming a case is a wire break.
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, ownedEquipment, unknownOwnedEquipmentTokens
    }

    /// The strings of one token-array key; empty, with the failure logged, when the key holds
    /// something else.
    private static func tokens(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [String] {
        do {
            return try c.decodeIfPresent([String].self, forKey: key) ?? []
        } catch {
            FernletAuditLog.log("workout.location.\(key.stringValue).decodeFailed",
                                context: ["error": error.localizedDescription])
            return []
        }
    }

    /// Every key this build does not know, with its raw value — at most ``maxParkedKeys``, taken in
    /// key order so the same input always parks the same keys.
    private static func parkedKeys(from decoder: Decoder) throws -> [String: JSONValue] {
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: LocationParkedKey.self)
        let unknown = container.allKeys.filter { !known.contains($0.stringValue) }
            .sorted { $0.stringValue < $1.stringValue }
            .prefix(maxParkedKeys)
        var parked: [String: JSONValue] = [:]
        for key in unknown {
            parked[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        return parked
    }

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

/// A `CodingKey` that admits any string — how ``WorkoutLocation`` finds the keys a newer build added
/// and writes them back by name. Non-failable `init(stringValue:)` satisfies the failable
/// requirement, so the encode site needs no unwrap.
private nonisolated struct LocationParkedKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

// MARK: - Deterministic safety / equipment feasibility

/// The single authority on whether an exercise is allowed for a user. Deterministic by design — the
/// AI adjuster (added later) must run its output back through this, never around it.
/// Not medical advice: it filters on coarse, user-supplied contraindications — the profile's
/// combined ``InjuryLimits`` (the body-area picker, the injury note read by whole words, and the
/// avoided sets older builds wrote).
public nonisolated enum WorkoutSafetyFilter {
    public static func feasible(_ exercise: ExerciseTarget, location: WorkoutLocation, profile: WorkoutProfile) -> Bool {
        feasible(exercise, location: location, limits: profile.injuryLimits)
    }

    /// ``feasible(_:location:profile:)`` with the limits already combined, for a filter over many
    /// exercises (the note is read once, not once per exercise).
    public static func feasible(_ exercise: ExerciseTarget, location: WorkoutLocation, limits: InjuryLimits) -> Bool {
        guard hasEquipment(for: exercise, at: location) else { return false }
        return limits.allows(exercise)
    }

    public static func feasibleExercises(in catalog: [ExerciseTarget], location: WorkoutLocation, profile: WorkoutProfile) -> [ExerciseTarget] {
        let limits = profile.injuryLimits
        return catalog.filter { feasible($0, location: location, limits: limits) }
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
    /// A stretch session of its own — a Mobility day's flow or the rest day's gentle stretch — built
    /// when its run starts (``WorkoutTimedSessions``). Never part of a lifting session.
    case mobility
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

    /// The FROZEN English time label that is part of a two-session day's session NAME ("Morning ·
    /// Easy cardio"), which a guided log is saved under and the rotation matches. Never localize it;
    /// screens read ``displayLabel``.
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

    /// How specific the split is, on screen, localized (2026-10-20, idea 16). Display only.
    public var label: String {
        switch self {
        case .minimal: String(localized: "splitSpecificity.minimal", defaultValue: "Very broad", bundle: .module,
                              comment: "How specific a workout split is: very broad, like daily movement or full-body days")
        case .balanced: String(localized: "splitSpecificity.balanced", defaultValue: "Balanced", bundle: .module,
                               comment: "How specific a workout split is: balanced, like upper/lower days")
        case .focused: String(localized: "splitSpecificity.focused", defaultValue: "Focused", bundle: .module,
                              comment: "How specific a workout split is: focused, like push/pull/legs")
        case .specialized: String(localized: "splitSpecificity.specialized", defaultValue: "Very specific", bundle: .module,
                                  comment: "How specific a workout split is: very specific, like one body part a day")
        }
    }
}

/// A named weekly training structure: specificity, goal fit, and its ordered days.
///
/// The unit ``WorkoutSplitRecommender`` ranks and the program engine rotates through; `id` is the
/// stable token stored in `WorkoutProfile.selectedSplitID`.
public nonisolated struct TrainingSplit: Identifiable, Sendable {

    public init(id: String, name: String, specificity: SplitSpecificity, goalFit: Set<GoalType>, days: [WorkoutSplitDay]) {
        self.id = id
        self.name = name
        self.specificity = specificity
        self.goalFit = goalFit
        self.days = days
    }
    public var id: String
    /// The FROZEN English name: the trainer export's `splitName` and the day plan's `splitName`.
    /// Screens read ``displayName`` (2026-10-20, idea 16).
    public var name: String
    public var specificity: SplitSpecificity
    public var goalFit: Set<GoalType>
    public var days: [WorkoutSplitDay]

    public var daysPerWeek: Int { days.count }
    public var sessionsPerWeek: Int { days.reduce(0) { $0 + $1.sessions.count } }

    /// The one-line description on screen, by the split's stable id (``TrainingSplitSummaries``);
    /// empty for a split the catalog does not have. Display only.
    ///
    /// A method taking the user's term of address rather than a stored `String`: Recovery Flow's
    /// Spanish says how the user should feel afterwards (*no molido*), so it agrees with the profile's
    /// Sex, and a summary resolved once into a `static let` could never do that. `address` is the
    /// drawing view's `fernletTermOfAddress`.
    public func summary(addressing address: TermOfAddress) -> String {
        TrainingSplitSummaries.displayed(id: id, addressing: address) ?? ""
    }

    /// "3 days/week", or "4 days · 8 sessions/week" when some days hold two sessions. Localized, with a
    /// plural rule for each count (2026-10-20, idea 16).
    public var frequencySummary: String {
        let days = daysPerWeek
        let sessions = sessionsPerWeek
        if sessions == days {
            return String(localized: "trainingSplit.frequency.daysPerWeek", defaultValue: "\(days) days/week", bundle: .module,
                          comment: "How often a workout split trains, e.g. '3 days/week'")
        }
        let dayCount = String(localized: "trainingSplit.frequency.days", defaultValue: "\(days) days", bundle: .module,
                              comment: "How many days a week a workout split trains, e.g. '4 days', shown before the session count")
        let sessionCount = String(localized: "trainingSplit.frequency.sessionsPerWeek", defaultValue: "\(sessions) sessions/week",
                                  bundle: .module,
                                  comment: "How many sessions a week a workout split has, e.g. '8 sessions/week', shown after the day count")
        return "\(dayCount) · \(sessionCount)"
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
        specificity: .minimal, goalFit: [.wellness, .mentalHealth, .recovery, .exploring],
        days: [day("Day 1", [WorkoutSessions.fullBodyA]), day("Day 2", [WorkoutSessions.easyCardio]), day("Day 3", [WorkoutSessions.fullBodyB])]
    )
    public static let fullBody2 = TrainingSplit(
        id: "full-body-2", name: "Full Body ×2",
        specificity: .minimal, goalFit: Set(GoalType.allCases),
        days: [day("Day 1", [WorkoutSessions.fullBodyA]), day("Day 2", [WorkoutSessions.fullBodyB])]
    )
    public static let recoveryFlow = TrainingSplit(
        id: "recovery-flow", name: "Recovery Flow",
        specificity: .minimal, goalFit: [.recovery, .mentalHealth, .wellness],
        days: [day("Day 1", [WorkoutSessions.mobility]), day("Day 2", [WorkoutSessions.easyCardio]), day("Day 3", [WorkoutSessions.fullBodyA])]
    )

    // --- Balanced ---
    public static let fullBody3 = TrainingSplit(
        id: "full-body-3", name: "Full Body ×3",
        specificity: .balanced, goalFit: Set(GoalType.allCases),
        days: [day("Day 1", [WorkoutSessions.fullBodyA]), day("Day 2", [WorkoutSessions.fullBodyB]), day("Day 3", [WorkoutSessions.fullBodyC])]
    )
    public static let upperLowerFull3 = TrainingSplit(
        id: "upper-lower-full-3", name: "Upper / Lower / Full",
        specificity: .balanced, goalFit: [.strength, .weightManagement, .wellness, .sportsPrep, .exploring],
        days: [day("Day 1", [WorkoutSessions.upper]), day("Day 2", [WorkoutSessions.lower]), day("Day 3", [WorkoutSessions.fullBodyC])]
    )
    public static let upperLower4 = TrainingSplit(
        id: "upper-lower-4", name: "Upper / Lower",
        specificity: .balanced, goalFit: [.strength, .weightManagement, .wellness, .sportsPrep, .bodybuilding],
        days: [day("Day 1", [WorkoutSessions.upper]), day("Day 2", [WorkoutSessions.lower]), day("Day 3", [WorkoutSessions.upper]), day("Day 4", [WorkoutSessions.lower])]
    )

    // --- Focused ---
    public static let ppl3 = TrainingSplit(
        id: "ppl-3", name: "Push / Pull / Legs",
        specificity: .focused, goalFit: [.strength, .sportsPrep, .weightManagement, .bodybuilding],
        days: [day("Push", [WorkoutSessions.push]), day("Pull", [WorkoutSessions.pull]), day("Legs", [WorkoutSessions.legs])]
    )
    public static let cardioStrength4 = TrainingSplit(
        id: "cardio-strength-4", name: "Cardio + Strength",
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
        specificity: .focused, goalFit: [.strength, .sportsPrep, .bodybuilding],
        days: [day("Push", [WorkoutSessions.push]), day("Pull", [WorkoutSessions.pull]), day("Legs", [WorkoutSessions.legs]), day("Upper", [WorkoutSessions.upper]), day("Lower", [WorkoutSessions.lower])]
    )
    public static let ppl6 = TrainingSplit(
        id: "ppl-6", name: "Push / Pull / Legs ×2",
        specificity: .focused, goalFit: [.strength, .sportsPrep, .bodybuilding],
        days: [day("Push A", [WorkoutSessions.push]), day("Pull A", [WorkoutSessions.pull]), day("Legs A", [WorkoutSessions.legs]), day("Push B", [WorkoutSessions.push]), day("Pull B", [WorkoutSessions.pull]), day("Legs B", [WorkoutSessions.legs])]
    )

    // --- Specialized / very specific ---
    public static let broSplit5 = TrainingSplit(
        id: "bro-5", name: "Bro Split",
        specificity: .specialized, goalFit: [.strength, .bodybuilding],
        days: [day("Chest", [WorkoutSessions.chest]), day("Back", [WorkoutSessions.back]), day("Shoulders", [WorkoutSessions.shoulders]), day("Arms", [WorkoutSessions.arms]), day("Legs", [WorkoutSessions.legs])]
    )
    public static let arnold6 = TrainingSplit(
        id: "arnold-6", name: "Arnold Split",
        specificity: .specialized, goalFit: [.strength, .bodybuilding],
        days: [day("Chest & Back", [WorkoutSessions.arnoldChestBack]), day("Shoulders & Arms", [WorkoutSessions.arnoldShouldersArms]), day("Legs", [WorkoutSessions.legs]), day("Chest & Back", [WorkoutSessions.arnoldChestBack]), day("Shoulders & Arms", [WorkoutSessions.arnoldShouldersArms]), day("Legs", [WorkoutSessions.legs])]
    )
    public static let twoADay = TrainingSplit(
        id: "two-a-day", name: "Two-a-Day Strength",
        specificity: .specialized, goalFit: [.strength, .sportsPrep],
        days: [
            day("Day 1", [WorkoutSessions.push.at(.morning), WorkoutSessions.pull.at(.evening)]),
            day("Day 2", [WorkoutSessions.legs.at(.morning), WorkoutSessions.upper.at(.evening)]),
            day("Day 3", [WorkoutSessions.lower.at(.morning), WorkoutSessions.arms.at(.evening)]),
        ]
    )
}

/// The split summaries Workout setup draws, by the split's stable id (see
/// ``TrainingSplit/summary(addressing:)``).
///
/// A switch rather than a stored string on each catalog split, so one summary can agree with the
/// user: Recovery Flow's resolves through ``AddressedCopy`` for the term the drawing view passes.
/// The keys, English and comments are the ones the catalog splits used to carry.
nonisolated enum TrainingSplitSummaries {
    /// The summary for a catalog split id, or nil for an id the catalog does not have.
    static func displayed(id: String, addressing address: TermOfAddress) -> String? {
        switch id {
        case "daily-move": String(localized: "trainingSplit.dailyMove.summary", defaultValue: "Easy full-body days and walks — just keep moving.", bundle: .module,
                             comment: "One-line description of a workout split in Workout setup")
        case "full-body-2": String(localized: "trainingSplit.fullBody2.summary", defaultValue: "Two full-body sessions a week. Simple and forgiving.", bundle: .module,
                             comment: "One-line description of a workout split in Workout setup")
        // Recovery Flow says how the user should feel afterwards, which Spanish agrees with them.
        case "recovery-flow": AddressedCopy.string(LocalizedStringResource("trainingSplit.recoveryFlow.summary", defaultValue: "Mobility and easy movement to feel better, not beat up.", bundle: .module,
                                                                 comment: "One-line description of a workout split in Workout setup"),
                                         addressing: address)
        case "full-body-3": String(localized: "trainingSplit.fullBody3.summary", defaultValue: "Three full-body sessions — the most efficient way to cover everything.", bundle: .module,
                             comment: "One-line description of a workout split in Workout setup")
        case "upper-lower-full-3": String(localized: "trainingSplit.upperLowerFull3.summary", defaultValue: "A bit more focus than full-body, still only three days.", bundle: .module,
                             comment: "One-line description of a workout split in Workout setup")
        case "upper-lower-4": String(localized: "trainingSplit.upperLower4.summary", defaultValue: "Four days alternating upper and lower body.", bundle: .module,
                             comment: "One-line description of a workout split in Workout setup")
        case "ppl-3": String(localized: "trainingSplit.ppl3.summary", defaultValue: "Classic three-day split organised by movement.", bundle: .module,
                             comment: "One-line description of a workout split in Workout setup")
        case "cardio-strength-4": String(localized: "trainingSplit.cardioStrength4.summary", defaultValue: "Morning cardio, evening lifting — for fat loss and conditioning.", bundle: .module,
                             comment: "One-line description of a workout split in Workout setup")
        case "sport-prep": String(localized: "trainingSplit.sportPrep.summary", defaultValue: "Sport-specific conditioning paired with strength work.", bundle: .module,
                             comment: "One-line description of a workout split in Workout setup")
        case "ppl-ul-5": String(localized: "trainingSplit.pplUL5.summary", defaultValue: "Five days mixing push/pull/legs with upper/lower.", bundle: .module,
                             comment: "One-line description of a workout split in Workout setup")
        case "ppl-6": String(localized: "trainingSplit.ppl6.summary", defaultValue: "Six high-frequency days for serious volume.", bundle: .module,
                             comment: "One-line description of a workout split in Workout setup")
        case "bro-5": String(localized: "trainingSplit.bro5.summary", defaultValue: "One body part per day for maximum focus.", bundle: .module,
                             comment: "One-line description of a workout split in Workout setup")
        case "arnold-6": String(localized: "trainingSplit.arnold6.summary", defaultValue: "Chest+back, shoulders+arms, legs — twice over, six days.", bundle: .module,
                             comment: "One-line description of a workout split in Workout setup")
        case "two-a-day": String(localized: "trainingSplit.twoADay.summary", defaultValue: "Two strength sessions a day — advanced, high volume.", bundle: .module,
                             comment: "One-line description of a workout split in Workout setup")
        default: nil
        }
    }
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

    /// The consistency on screen, localized (2026-10-20, idea 16). Display only.
    public var label: String {
        switch self {
        case .low: String(localized: "workoutConsistency.low", defaultValue: "Getting started", bundle: .module,
                          comment: "How consistently the person has trained lately: just getting started")
        case .medium: String(localized: "workoutConsistency.medium", defaultValue: "Fairly consistent", bundle: .module,
                             comment: "How consistently the person has trained lately: fairly consistent")
        case .high: String(localized: "workoutConsistency.high", defaultValue: "Very consistent", bundle: .module,
                           comment: "How consistently the person has trained lately: very consistent")
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
                score += preferenceBonus(split, goal: goal)
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

    /// The ids of the push / pull / legs splits Bodybuilding prefers (`bb-goal`: "Push, pull and legs").
    public static let pushPullLegsSplitIDs: Set<String> = ["ppl-3", "ppl-ul-5", "ppl-6"]

    /// A goal's lean toward particular splits on top of `goalFit`: Bodybuilding's push / pull / legs
    /// days win a tie a step of specificity away (one step costs 30). Zero for every other goal, so
    /// their ranking is unchanged.
    public static func preferenceBonus(_ split: TrainingSplit, goal: GoalType) -> Int {
        guard goal == .bodybuilding, pushPullLegsSplitIDs.contains(split.id) else { return 0 }
        return 40
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
        case .bodybuilding:
            // Hypertrophy: moderate reps on the main lift, higher on accessories, plenty of sets.
            return WorkoutGoalStyle(mainSets: 4, mainReps: "6-10", accessorySets: 3, accessoryReps: "10-15", includeConditioning: false, conditioningLabel: conditioning, holdSeconds: 40)
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
        side: ExerciseSide? = nil, guidance: LoadGuidance? = nil, segment: CardioSegment? = nil
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
        self.guidance = guidance
        self.segment = segment
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
    /// The load plan for a rep-counted lift — its weight range, target reps, and calibration role —
    /// which the guided runner prescribes from and records against. Nil on everything else.
    public var guidance: LoadGuidance?
    /// The timed cardio segment this step is, when the runner expanded a cardio line into countdowns
    /// (``WorkoutTimedSessions/expand(_:feasible:)``); nil on every plan step.
    public var segment: CardioSegment?

    /// The display text for a timed hold: "40 s".
    public static func holdText(seconds: Int) -> String { "\(seconds) s" }

    /// The plan-text line. A timed single step reads "Low lunge stretch (left) - 20 s"; a timed set
    /// "Plank - 2 x 30 s", which the history parser reads back as a hold, never as reps.
    ///
    /// Carries the FROZEN ``name``: this is the text a logged row stores and the history parser
    /// reads back. Screens draw ``displayLine``.
    public var line: String { planLine(naming: name) }

    /// The line's layout around `exerciseName` — ``name`` for the stored ``line``, the display name
    /// for ``displayLine``. A non-catalog step is its name alone.
    func planLine(naming exerciseName: String) -> String {
        guard fromCatalog else { return exerciseName }
        let label = side.map { "\(exerciseName) (\($0.rawValue))" } ?? exerciseName
        if let holdSeconds {
            let hold = Self.holdText(seconds: holdSeconds)
            return sets > 1 ? "\(label) - \(sets) x \(hold)" : "\(label) - \(hold)"
        }
        let tag = guidance?.calibration.map { " (\(ExerciseResult.calibrationTag($0)))" } ?? ""
        return "\(label) - \(sets) x \(reps)\(tag)"
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
        /// the cool-down are not progressed and never counted, and nor are a lift's warm-up sets
        /// (``WorkoutWarmUpSets``), which would only repeat its name.
        public var catalogExerciseNames: [String] {
            exercises.filter { $0.fromCatalog && $0.block == .lifting && !WorkoutWarmUpSets.isWarmUpSet($0) }.map(\.name)
        }

        /// Builds the loggable `Workout` for this session. `loggedFromGuidedSession` tags the row as
        /// coming from the guided flow so name-based reconciliation only ever matches the guided
        /// flow's own logs; every guided logging site passes `true`, and no other caller does.
        public func workout(intensity: WorkoutIntensity, loggedFromGuidedSession: Bool = false) -> Workout {
            let mode: WorkoutMode = (kind == .strength || kind == .fullBody) ? .strengthTraining : .activity
            let type: WorkoutType = (kind == .cardio) ? .cardio : .fullBody
            return Workout(
                name: suggestion.name, type: type, mode: mode, activityType: activityType, exercises: suggestion.exercises,
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

        /// The activity a cardio or mobility session logs as, read from its descriptor
        /// (``WorkoutTimedSessions/activityType(forDescriptor:)``), so Apple Health files it as interval,
        /// steady or stretch work rather than "Other". Nil for any other session, and for the rest day's
        /// gentle line, which may as well have been a walk.
        var activityType: WorkoutActivityType? {
            guard kind == .cardio || kind == .mobility, let line = exercises.first,
                  !WorkoutTimedSessions.isOptionalStretch(line) else { return nil }
            return WorkoutTimedSessions.activityType(forDescriptor: line.name)
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
        /// What the 48-hour guard decided (``WorkoutRecoveryGuard``): the day it planned, the
        /// rotation's day when it moved off it, and the overlap it lightened. Nil when no recent
        /// training was passed in.
        public var recovery: WorkoutRecoveryGuard.Decision?

        public init(
            splitName: String, dayTitle: String, sessions: [SessionSuggestion], droppedSlots: [String],
            locationName: String, recovery: WorkoutRecoveryGuard.Decision? = nil
        ) {
            self.splitName = splitName
            self.dayTitle = dayTitle
            self.sessions = sessions
            self.droppedSlots = droppedSlots
            self.locationName = locationName
            self.recovery = recovery
        }
    }

    /// Renders the session(s) for one day of the split. `rotationIndex` picks the day (wrapped into
    /// range); the app passes ``nextDayIndex(in:recentSessionNames:)`` so the program walks the
    /// split in order, one completed day at a time.
    ///
    /// With `recent`, the 48-hour guard (``WorkoutRecoveryGuard``) may move to another split day or
    /// lighten the lifts whose primary muscles worked hard inside its window, and says so in the
    /// first session's note. Without it the rotation's day is planned as it is.
    ///
    /// `options` shape each session's length (``WorkoutSessionOptions``): the warm-up flow in full,
    /// short or off, the cool-down on or off, and a time budget each session is fitted into
    /// (``WorkoutSessionBudget``). The default plans exactly as before.
    ///
    /// `preferences` are the user's exercise preferences (``WorkoutExercisePreferences``): a hidden
    /// exercise is left out of every block, so each slot falls back to its next eligible pick, and a
    /// slot only hidden exercises could fill is dropped with its own note; a saved alternate replaces
    /// the planner's pick only when it passes everything the pick did
    /// (``preferredAlternate(for:slot:block:inputs:used:)``). The default changes nothing.
    public static func dayPlan(
        goal: GoalType,
        intensity: WorkoutIntensity,
        profile: WorkoutProfile,
        location: WorkoutLocation,
        context: String,
        split: TrainingSplit,
        rotationIndex: Int,
        progression: [String: Int] = [:],
        load: WorkoutLoadContext? = nil,
        recent: WorkoutRecoveryGuard.RecentTraining? = nil,
        options: WorkoutSessionOptions = WorkoutSessionOptions(),
        preferences: WorkoutExercisePreferences = WorkoutExercisePreferences(),
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
        let decision = recent.map { WorkoutRecoveryGuard.decide(split: split, dueIndex: rotationIndex, recent: $0) }
        let day = split.days[decision?.dayIndex ?? ((rotationIndex % dayCount) + dayCount) % dayCount]
        let style = WorkoutGoalStyle.style(for: goal, energy: intensity, sport: profile.sport)
        let limits = profile.injuryLimits
        let pool = splitHidden(catalog.filter { WorkoutSafetyFilter.feasible($0, location: location, limits: limits) },
                               preferences: preferences)
        let biasTokens = selectionTokens(profile: profile, context: context)

        var dayUsed: Set<String> = []
        var dropped: [String] = []
        var sessions: [SessionSuggestion] = []
        // One calibration a day at most: the first lifting session that can take it does — and none
        // on a day the guard lightens, when the muscles it would test are still tired.
        var calibrationOpen = decision?.overlap.isEmpty ?? true

        for session in day.sessions {
            let inputs = SlotInputs(
                goal: goal, intensity: intensity, style: style, feasible: pool.shown, biasTokens: biasTokens,
                profile: profile, location: location, progression: progression, load: load,
                limits: limits, recentHard: recent?.hardMuscles ?? [], options: options,
                hiddenFeasible: pool.hidden, alternates: preferences.alternateKeys, cardioSeed: rotationIndex
            )
            let rendered = render(
                session: session, inputs: inputs, context: context, used: &dayUsed,
                isMultiSession: day.sessions.count > 1, calibrationOpen: &calibrationOpen
            )
            dropped.append(contentsOf: rendered.dropped)
            sessions.append(rendered.session)
        }

        if sessions.isEmpty {
            sessions = [Self.fallbackSession]
        }
        if let decision, let from = decision.movedFrom {
            prependNote(WorkoutRecoveryGuard.movedNote(to: day, from: split.days[from]), to: &sessions)
        }

        return DayPlan(splitName: split.name, dayTitle: day.title, sessions: sessions, droppedSlots: dropped,
                       locationName: location.name, recovery: decision)
    }

    /// Puts `note` first in the first session's note.
    static func prependNote(_ note: String, to sessions: inout [SessionSuggestion]) {
        guard !sessions.isEmpty else { return }
        let existing = sessions[0].suggestion.notes
        sessions[0].suggestion.notes = existing.isEmpty ? note : "\(note) · \(existing)"
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
        for logged in recentSessionNames.prefix(rotationLookbackDays) {
            if let matched = matchedDayIndex(in: split, names: logged) { return (matched + 1) % split.days.count }
        }
        return 0
    }

    /// The split day that one past day's logged workout names belong to: the day sharing the most
    /// session display names with them, ties to the earlier day; nil when none shares a name.
    public static func matchedDayIndex(in split: TrainingSplit, names logged: [String]) -> Int? {
        let names = Set(logged.prefix(rotationNamesPerDay))
        guard !names.isEmpty else { return nil }
        var best: (index: Int, overlap: Int)?
        for (index, day) in split.days.enumerated() {
            let dayNames = Set(day.sessions.map { sessionDisplayName($0, timeLabel: $0.time.label) })
            let overlap = dayNames.intersection(names).count
            if overlap > 0, overlap > (best?.overlap ?? 0) { best = (index, overlap) }
        }
        return best?.index
    }

    /// The "there is always something to do" session used when a split renders nothing at all. Its
    /// name and plan line are frozen English (screens draw them through ``WorkoutSessionNames`` and
    /// ``WorkoutPlanLine``); its note is localized.
    private static var fallbackSession: SessionSuggestion {
        SessionSuggestion(
            title: "Move", timeLabel: "", kind: .fullBody,
            suggestion: WorkoutSuggestion(name: "Easy full body",
                                          exercises: "Full-body bodyweight circuit - 3 rounds",
                                          notes: WorkoutPlannerCopy.simpleOption)
        )
    }

    private static func render(
        session: WorkoutSessionTemplate,
        inputs: SlotInputs,
        context: String,
        used: inout Set<String>,
        isMultiSession: Bool,
        calibrationOpen: inout Bool
    ) -> (session: SessionSuggestion, dropped: [String]) {
        let timeLabel = session.time.label
        let name = sessionDisplayName(session, timeLabel: timeLabel)

        switch session.kind {
        case .cardio, .mobility:
            // The descriptor IS the session, so a time budget caps the minutes it names.
            let capped = WorkoutSessionBudget.capped(session.conditioning ?? inputs.style.conditioningLabel,
                                                     length: inputs.options.length)
            // The machine the location has, named after the cap so the cap never drops "easy".
            let detail = WorkoutCardioMachines.named(capped.text, feasible: inputs.feasible, seed: inputs.cardioSeed)
            let exercises = [PrescribedExercise(name: detail, sets: 0, reps: "", role: .accessory, fromCatalog: false)]
            let suggestion = WorkoutSuggestion(
                name: name, exercises: detail,
                notes: notes(inputs: inputs, context: context, dropped: [], includeContext: !isMultiSession,
                             progressNotes: capped.note.map { [$0] } ?? [])
            )
            return (SessionSuggestion(title: session.title, timeLabel: timeLabel, kind: session.kind, exercises: exercises, suggestion: suggestion), [])

        case .strength, .fullBody, .sport:
            let built = buildBlocks(session: session, inputs: inputs, used: &used, calibrationOpen: &calibrationOpen)
            let hiddenDrops = hiddenOnlyDrops(built.dropped, slots: session.slots, inputs: inputs)
            let suggestion = WorkoutSuggestion(
                name: name,
                exercises: WorkoutSessionBlocks.planText(for: built.exercises),
                notes: notes(inputs: inputs, context: context, dropped: built.dropped.filter { !hiddenDrops.contains($0) },
                             includeContext: !isMultiSession, progressNotes: built.progressNotes,
                             hiddenDropped: hiddenDrops)
            )
            return (SessionSuggestion(title: session.title, timeLabel: timeLabel, kind: session.kind, exercises: built.exercises, suggestion: suggestion), built.dropped)
        }
    }

    /// What every slot pick in one day's render shares.
    struct SlotInputs {
        let goal: GoalType
        let intensity: WorkoutIntensity
        let style: WorkoutGoalStyle
        let feasible: [ExerciseTarget]
        let biasTokens: Set<String>
        let profile: WorkoutProfile
        let location: WorkoutLocation
        let progression: [String: Int]
        /// The lifts' logged sessions and recovery; nil keeps the count-based ladder alone.
        let load: WorkoutLoadContext?
        /// The profile's combined injury limits: the feasible list already honours them; the slot
        /// score and the prescription read the mild areas (``InjuryLimits/eases(_:)``).
        var limits: InjuryLimits = .empty
        /// Primary muscles that got hard working sets inside the 48-hour window: a lifting pick
        /// working one of them gives up a set (``WorkoutRecoveryGuard``).
        var recentHard: Set<MuscleGroup> = []
        /// The session's length: the stretch blocks it walks and the time budget it is fitted into.
        var options = WorkoutSessionOptions()
        /// The exercises the safety filter allows but the user hid ("Don't suggest this"): never
        /// picked, only read to tell a slot they emptied from one nothing safe could fill.
        var hiddenFeasible: [ExerciseTarget] = []
        /// Saved alternates (``WorkoutExercisePreferences/alternateKeys``): the original's comparison
        /// key → the alternate's frozen name.
        var alternates: [String: String] = [:]
        /// The split's rotation index, which picks among the location's cardio machines
        /// (``WorkoutCardioMachines/named(_:feasible:seed:)``) so they alternate from day to day.
        var cardioSeed = 0
    }

    /// The safety-filtered pool split into what the planner may suggest and what the user hid.
    static func splitHidden(
        _ safe: [ExerciseTarget], preferences: WorkoutExercisePreferences
    ) -> (shown: [ExerciseTarget], hidden: [ExerciseTarget]) {
        let keys = preferences.hiddenKeys
        guard !keys.isEmpty else { return (safe, []) }
        var shown: [ExerciseTarget] = []
        var hidden: [ExerciseTarget] = []
        for exercise in safe {
            if keys.contains(WorkoutExerciseCatalog.normalizedName(exercise.name)) {
                hidden.append(exercise)
            } else {
                shown.append(exercise)
            }
        }
        return (shown, hidden)
    }

    /// One filled slot: the prescribed step, the catalog row behind it, the slot it fills, and the
    /// count-based ladder position it was prescribed from.
    struct SlotPick {
        var exercise: PrescribedExercise
        var target: ExerciseTarget
        var completions: Int
        var slot: WorkoutSlotSpec
    }

    /// The core slot a session without one of its own gets for its activation block.
    private static let activationCoreSlot = WorkoutSlotSpec(
        label: "Core", role: .core, muscles: [.abs, .obliques], region: .core
    )

    /// A lifting session's movements in run order — warm-up, activation, lifting, cardio,
    /// cool-down — plus the slots it dropped and what its note says about progression and time.
    ///
    /// The template's core slot moves into the activation block, ahead of the lifting, and is
    /// prescribed light; a session without one gets a light core pick there anyway. The lifting
    /// block is ``liftingBlock(_:inputs:used:dropped:calibrationOpen:)``; the stretch blocks and the
    /// time budget are ``sessionBlocks(activation:lifting:cardio:mainLabels:inputs:)``.
    private static func buildBlocks(
        session: WorkoutSessionTemplate, inputs: SlotInputs, used: inout Set<String>, calibrationOpen: inout Bool
    ) -> (exercises: [PrescribedExercise], dropped: [String], progressNotes: [String]) {
        let slots = Array(session.slots.prefix(inputs.profile.experience.maxSlotsPerDay))
        let liftSlots = slots.filter { $0.role != .core }
        let coreSlots = slots.filter { $0.role == .core }
        var dropped: [String] = []
        let core = fill(coreSlots.isEmpty ? [activationCoreSlot] : coreSlots, block: .activation,
                        inputs: inputs, used: &used, dropped: &dropped, reportDrops: !coreSlots.isEmpty)
        var lifting = liftingBlock(liftSlots, inputs: inputs, used: &used, dropped: &dropped, calibrationOpen: &calibrationOpen)
        let legPatterns: Set<MovementPattern> = [.squat, .hinge, .lunge]
        let trainsLegs = liftSlots.contains { $0.movement.map(legPatterns.contains) ?? false }
        let activation = core.map(\.exercise) + WorkoutSessionBlocks.balanceAndJumps(
            feasible: inputs.feasible, experience: inputs.profile.experience, goal: inputs.goal,
            intensity: inputs.intensity, trainsLegs: trainsLegs
        )
        var cardio: [PrescribedExercise] = []
        if session.kind == .sport { cardio.append(descriptorStep(inputs.style.conditioningLabel)) }
        if let extra = session.conditioning { cardio.append(descriptorStep(extra)) }
        if lifting.steps.isEmpty && cardio.isEmpty {
            lifting.steps = [descriptorStep("Full-body bodyweight circuit - 3 rounds", block: .lifting)]
        }
        let mainLabels = Set(liftSlots.filter { $0.role == .main }.map(\.label))
        let fitted = sessionBlocks(activation: activation, lifting: lifting, cardio: cardio,
                                   mainLabels: mainLabels, inputs: inputs)
        return (fitted.exercises, dropped, (fitted.note.map { [$0] } ?? []) + lifting.notes)
    }

    /// A session's lifting block on its way to the plan: its steps, with the catalog rows and the
    /// slots behind them (parallel, until the fallback circuit stands in for an empty block), and
    /// what the session note says about progression.
    struct LiftingBlock {
        var steps: [PrescribedExercise]
        var targets: [ExerciseTarget]
        var slots: [WorkoutSlotSpec]
        var notes: [String]
    }

    /// The lifting slots filled, through the load pass when there is one
    /// (``applyLoad(_:inputs:load:used:calibrationOpen:)``), then the 48-hour guard's lighter sets.
    static func liftingBlock(
        _ slots: [WorkoutSlotSpec], inputs: SlotInputs, used: inout Set<String>, dropped: inout [String],
        calibrationOpen: inout Bool
    ) -> LiftingBlock {
        let picks = fill(slots, block: .lifting, inputs: inputs, used: &used, dropped: &dropped, reportDrops: true)
        var block = LiftingBlock(steps: picks.map(\.exercise), targets: picks.map(\.target),
                                 slots: picks.map(\.slot), notes: ladderNote(picks, style: inputs.style))
        if let load = inputs.load {
            let pass = applyLoad(picks, inputs: inputs, load: load, used: &used, calibrationOpen: &calibrationOpen)
            block = LiftingBlock(steps: pass.steps, targets: pass.targets, slots: pass.slots, notes: pass.notes)
        }
        let recovery = lightened(block.steps, targets: block.targets, recentHard: inputs.recentHard)
        block.steps = recovery.steps
        if let note = recovery.note { block.notes.insert(note, at: 0) }
        return block
    }

    /// The session in run order with the stretch blocks the options ask for — the owner's warm-up
    /// flow in full, the short day-aware version (``WorkoutSessionBlocks/shortWarmUpSeconds``) or
    /// none; the cool-down for the worked muscles or none — fitted to the time budget when one is
    /// set (``WorkoutSessionBudget``), with the budget's note.
    ///
    /// A lifting step is a main lift when its slot is one of the template's main slots
    /// (`mainLabels`), so a main lift eased to accessory work for a mild injury is still never
    /// dropped. Only the lifting picks' muscles choose the stretches.
    static func sessionBlocks(
        activation: [PrescribedExercise], lifting: LiftingBlock, cardio: [PrescribedExercise],
        mainLabels: Set<String>, inputs: SlotInputs
    ) -> (exercises: [PrescribedExercise], note: String?) {
        let options = inputs.options
        let worked = lifting.targets.reduce(into: Set<MuscleGroup>()) { $0.formUnion($1.primaryMuscles) }
        let budget = options.length.minutes
        let wantsShort = options.warmUp == .short || (options.warmUp == .full && budget != nil)
        let short = wantsShort ? WorkoutSessionBlocks.shortWarmUp(feasible: inputs.feasible, worked: worked) : []
        let warmUp: [PrescribedExercise]
        switch options.warmUp {
        case .full: warmUp = WorkoutSessionBlocks.warmUp(feasible: inputs.feasible)
        case .short: warmUp = short
        case .off: warmUp = []
        }
        let coolDown = options.coolDown == .off
            ? [] : WorkoutSessionBlocks.coolDown(worked: worked, feasible: inputs.feasible)
        let mainLift = lifting.steps.indices.map { index in
            index < lifting.slots.count && mainLabels.contains(lifting.slots[index].label)
        }
        let blocks = WorkoutSessionBudget.Blocks(
            warmUp: warmUp, activation: activation, lifting: lifting.steps, mainLift: mainLift,
            cardio: cardio, coolDown: coolDown
        )
        guard let budget else { return (blocks.exercises, nil) }
        let outcome = WorkoutSessionBudget.fit(
            blocks, budgetMinutes: budget, goal: inputs.goal, shortWarmUp: options.warmUp == .full ? short : nil
        )
        return (outcome.blocks.exercises, outcome.note)
    }

    /// Fills slots in order with their best eligible pick, prescribing each for its block, and
    /// records the label of every slot nothing could fill (when `reportDrops`).
    private static func fill(
        _ slots: [WorkoutSlotSpec], block: SessionBlock, inputs: SlotInputs,
        used: inout Set<String>, dropped: inout [String], reportDrops: Bool
    ) -> [SlotPick] {
        var picks: [SlotPick] = []
        for slot in slots {
            let best = bestExercise(
                for: slot, in: inputs.feasible, excluding: used, biasTokens: inputs.biasTokens,
                experience: inputs.profile.experience, location: inputs.location, limits: inputs.limits
            )
            guard let best else {
                if reportDrops { dropped.append(slot.label) }
                continue
            }
            let pick = preferredAlternate(for: best, slot: slot, block: block, inputs: inputs, used: used) ?? best
            used.insert(pick.name)
            let completions = block == .lifting ? inputs.progression[pick.name] ?? 0 : 0
            let prescribed = easedSlot(slot, for: pick, limits: inputs.limits)
            picks.append(SlotPick(
                exercise: prescribe(pick, role: prescribed.role, block: block, completions: completions, inputs: inputs),
                target: pick, completions: completions, slot: prescribed
            ))
        }
        return picks
    }

    /// The slot a pick is prescribed from. A main lift that loads an area being trained around (a
    /// mild area) is prescribed as accessory work: the accessory rep range — so the load pass picks
    /// a lighter weight for the higher reps — the accessory set count, and no calibration (which
    /// only ever tests a main lift). Anything else keeps its slot.
    static func easedSlot(_ slot: WorkoutSlotSpec, for pick: ExerciseTarget, limits: InjuryLimits) -> WorkoutSlotSpec {
        guard slot.role == .main, limits.eases(pick) else { return slot }
        var eased = slot
        eased.role = .accessory
        return eased
    }

    /// The user's saved alternate for `pick` ("Always use this instead"), when it can take the slot:
    /// it is in the feasible pool (the location has its tools and gear, the injury limits allow it,
    /// and it is not hidden), no earlier slot today used it, it is eligible for the slot, and it fits
    /// the time budget (``alternateFitsBudget(_:insteadOf:slot:block:inputs:)``). Otherwise nil, and
    /// the planner's own pick stands — silently, since nothing went wrong.
    static func preferredAlternate(
        for pick: ExerciseTarget, slot: WorkoutSlotSpec, block: SessionBlock, inputs: SlotInputs, used: Set<String>
    ) -> ExerciseTarget? {
        guard !inputs.alternates.isEmpty,
              let name = inputs.alternates[WorkoutExerciseCatalog.normalizedName(pick.name)] else { return nil }
        let key = WorkoutExerciseCatalog.normalizedName(name)
        guard let alternate = inputs.feasible.first(where: { WorkoutExerciseCatalog.normalizedName($0.name) == key }),
              !used.contains(alternate.name), isEligible(alternate, for: slot) else { return nil }
        guard alternateFitsBudget(alternate, insteadOf: pick, slot: slot, block: block, inputs: inputs) else { return nil }
        return alternate
    }

    /// Under a time budget, an alternate may not make its step longer than the planner's pick would
    /// be — a longer hold, or longer rest for its movement — so swapping it in never pushes a fitted
    /// session over. Both are measured as first prescribed (no progression), with no budget always true.
    static func alternateFitsBudget(
        _ alternate: ExerciseTarget, insteadOf pick: ExerciseTarget, slot: WorkoutSlotSpec, block: SessionBlock,
        inputs: SlotInputs
    ) -> Bool {
        guard inputs.options.length.minutes != nil else { return true }
        let theirs = prescribe(pick, role: easedSlot(slot, for: pick, limits: inputs.limits).role, block: block,
                               completions: 0, inputs: inputs)
        let mine = prescribe(alternate, role: easedSlot(slot, for: alternate, limits: inputs.limits).role, block: block,
                             completions: 0, inputs: inputs)
        return WorkoutSessionTime.seconds(of: mine, goal: inputs.goal) <= WorkoutSessionTime.seconds(of: theirs, goal: inputs.goal)
    }

    /// The labels among `dropped` that a hidden exercise could have filled — what the session note
    /// names separately ("only options here are ones you've hidden"), so a person who hid every fit
    /// is not told the room had nothing safe.
    static func hiddenOnlyDrops(
        _ dropped: [String], slots: [WorkoutSlotSpec], inputs: SlotInputs
    ) -> [String] {
        guard !dropped.isEmpty, !inputs.hiddenFeasible.isEmpty else { return [] }
        return dropped.filter { label in
            guard let slot = slots.first(where: { $0.label == label }) else { return false }
            return inputs.hiddenFeasible.contains { isEligible($0, for: slot) }
        }
    }

    /// Takes a set off every lifting step whose primary muscles worked hard inside the 48-hour
    /// window, and names those lifts in the note (``WorkoutRecoveryGuard``). Steps and targets are
    /// parallel; a timed hold or a single-set step simply keeps its one set.
    static func lightened(
        _ steps: [PrescribedExercise], targets: [ExerciseTarget], recentHard: Set<MuscleGroup>
    ) -> (steps: [PrescribedExercise], note: String?) {
        guard !recentHard.isEmpty, steps.count == targets.count else { return (steps, nil) }
        var result = steps
        var names: [String] = []
        for index in result.indices where result[index].fromCatalog && result[index].block == .lifting {
            guard !targets[index].primaryMuscles.isDisjoint(with: recentHard) else { continue }
            let fewer = WorkoutRecoveryGuard.lightenedSets(result[index].sets)
            guard fewer < result[index].sets else { continue }
            result[index].sets = fewer
            if !names.contains(result[index].name) { names.append(result[index].name) }
        }
        return (result, names.isEmpty ? nil : WorkoutRecoveryGuard.lightenedNote(lifts: names))
    }

    /// Sets and reps (or a hold) for one pick. Lifting picks follow the goal and the day's energy,
    /// with double progression on rep-counted work; activation picks are deliberately light — two
    /// easy sets — so the trunk is awake, not tired, when the heavy lifting starts.
    static func prescribe(
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
        let adjustedTag = WorkoutPlannerCopy.adjustedToNote
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

    /// A session's NAME — the frozen English its guided log is saved under and the rotation and the
    /// guided reconciliation match ("Upper", "Morning · Easy cardio"). Screens draw it through
    /// ``WorkoutSessionNames/drawn(_:)``; never localize it here.
    private static func sessionDisplayName(_ session: WorkoutSessionTemplate, timeLabel: String) -> String {
        timeLabel.isEmpty ? session.title : "\(timeLabel) · \(session.title)"
    }

    /// The highest-scoring eligible exercise for a slot, or nil when nothing is eligible (the slot
    /// is then dropped and named in the session note). Ties fall to the name, so the pick is
    /// deterministic; the equipment and difficulty terms in ``slotScore`` keep real ties rare. With
    /// `limits` naming a mild area, a machine, cable or bench-supported variant of a lift that loads
    /// it scores higher (``InjuryLimits/supportBonus(for:)``). A ``ExerciseTarget/variation`` competes
    /// only where no staple is eligible, or as such a supported variant where no eligible staple is
    /// one already: a mild elbow keeps its Preacher curl (a machine, so already supported) rather
    /// than trading it for a Cable curl that wins only on the name tie-break (2026-10-27).
    static func bestExercise(
        for slot: WorkoutSlotSpec,
        in feasible: [ExerciseTarget],
        excluding used: Set<String>,
        biasTokens: Set<String>,
        experience: ExperienceLevel,
        location: WorkoutLocation,
        limits: InjuryLimits = .empty
    ) -> ExerciseTarget? {
        let eligible = feasible.filter { used.contains($0.name) == false && isEligible($0, for: slot) }
        let hasStaple = eligible.contains { !$0.variation }
        let hasSupportedStaple = eligible.contains { !$0.variation && limits.supportBonus(for: $0) > 0 }
        return eligible
            .filter { !hasStaple || !$0.variation || (!hasSupportedStaple && limits.supportBonus(for: $0) > 0) }
            .map { exercise -> (ExerciseTarget, Int) in
                let score = slotScore(
                    slot: slot, exercise: exercise, biasTokens: biasTokens,
                    experience: experience, location: location
                ) + limits.supportBonus(for: exercise)
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
        inputs: SlotInputs,
        context: String,
        dropped: [String],
        includeContext: Bool,
        progressNotes: [String],
        hiddenDropped: [String] = []
    ) -> String {
        // The note is display text composed now, in the device's language: the location reads by its
        // drawn name and the dropped slots by theirs. `dropped` itself stays the frozen labels.
        var parts: [String] = [inputs.location.displayedName]
        parts += progressNotes
        if includeContext, context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            parts.append(WorkoutPlannerCopy.noted(context.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if !inputs.limits.isEmpty {
            parts.append(WorkoutPlannerCopy.workedAroundLimits)
        }
        if dropped.isEmpty == false {
            parts.append(WorkoutPlannerCopy.skippedNoSafeOption(WorkoutSlotNames.drawnList(dropped)))
        }
        if hiddenDropped.isEmpty == false {
            parts.append(hiddenDropNote(hiddenDropped))
        }
        return parts.joined(separator: " · ")
    }

    /// The note for slots that only hidden exercises could fill. `labels` are the frozen slot labels;
    /// the note names them in the device's language (``WorkoutSlotNames``).
    public static func hiddenDropNote(_ labels: [String]) -> String {
        WorkoutPlannerCopy.skippedHidden(WorkoutSlotNames.drawnList(labels))
    }
}

