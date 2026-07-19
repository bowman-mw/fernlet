// NutritionModels.swift
// Split out of Models.swift (SPM carve-up §5c). Nutrition, food, meal, recipe, and macro/micronutrient models.

import Foundation

public nonisolated struct UserNutritionProfile: Codable, Equatable {

    public init(age: Int = 30, weightPounds: Double = 170, heightInches: Double = 68, sex: BiologicalSex = .male, activityLevel: ActivityLevel = .moderate) {
        self.age = age
        self.weightPounds = weightPounds
        self.heightInches = heightInches
        self.sex = sex
        self.activityLevel = activityLevel
    }
    public var age: Int = 30
    public var weightPounds: Double = 170
    public var heightInches: Double = 68
    // Tolerant enum decode + parked-token side channels (EnumDecodeCompat): this struct lives in
    // FernletSettings (a top-level synced-blob field), so a synthesized strict decode of a raw
    // value only a newer build knows would brick the older device into read-only recovery.
    // NOTE: the HealthKit body-profile auto-import assigns `sex` once per launch when Health has
    // it, which clears the park via `didSet` — deliberate, since Health is treated as the local
    // authority for this field on every device (known cases are overwritten the same way).
    public var sex: BiologicalSex = .male {
        didSet { unknownSexToken = nil }
    }
    public var unknownSexToken: String? = nil
    public var activityLevel: ActivityLevel = .moderate {
        didSet { unknownActivityLevelToken = nil }
    }
    public var unknownActivityLevelToken: String? = nil

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Required keys (synthesized-strict pre-compat): absence is corruption, not a newer build.
        // age/weight/height feed calorie targets — fabricating defaults would silently mis-guide.
        age = try c.decode(Int.self, forKey: .age)
        weightPounds = try c.decode(Double.self, forKey: .weightPounds)
        heightInches = try c.decode(Double.self, forKey: .heightInches)
        let sexSplit = try c.decodeTolerantRequiredEnum(
            BiologicalSex.self, forKey: .sex, parkedTokenKey: .unknownSexToken, default: .male)
        sex = sexSplit.value
        unknownSexToken = sexSplit.parkedToken
        let activitySplit = try c.decodeTolerantRequiredEnum(
            ActivityLevel.self, forKey: .activityLevel, parkedTokenKey: .unknownActivityLevelToken, default: .moderate)
        activityLevel = activitySplit.value
        unknownActivityLevelToken = activitySplit.parkedToken
    }

    public var weightKilograms: Double { weightPounds / 2.20462 }
    public var heightCentimeters: Double { heightInches * 2.54 }
}

public nonisolated struct UserNutritionPreferences: Codable, Equatable {

    public init(dietaryPattern: DietaryPattern = .balanced, guidanceIntensity: GuidanceIntensity = .steady) {
        self.dietaryPattern = dietaryPattern
        self.guidanceIntensity = guidanceIntensity
    }
    // Tolerant enum decode + parked-token side channels; same synced-settings contract as
    // `UserNutritionProfile` (EnumDecodeCompat).
    public var dietaryPattern: DietaryPattern = .balanced {
        didSet { unknownDietaryPatternToken = nil }
    }
    public var unknownDietaryPatternToken: String? = nil
    public var guidanceIntensity: GuidanceIntensity = .steady {
        didSet { unknownGuidanceIntensityToken = nil }
    }
    public var unknownGuidanceIntensityToken: String? = nil

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Required keys (synthesized-strict pre-compat): absence is corruption, not a newer build.
        let patternSplit = try c.decodeTolerantRequiredEnum(
            DietaryPattern.self, forKey: .dietaryPattern, parkedTokenKey: .unknownDietaryPatternToken, default: .balanced)
        dietaryPattern = patternSplit.value
        unknownDietaryPatternToken = patternSplit.parkedToken
        let intensitySplit = try c.decodeTolerantRequiredEnum(
            GuidanceIntensity.self, forKey: .guidanceIntensity, parkedTokenKey: .unknownGuidanceIntensityToken, default: .steady)
        guidanceIntensity = intensitySplit.value
        unknownGuidanceIntensityToken = intensitySplit.parkedToken
    }
}

public nonisolated enum BiologicalSex: String, Codable, CaseIterable, Identifiable {
    case female
    case male

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .female: "Female"
        case .male: "Male"
        }
    }
}

public nonisolated enum ActivityLevel: String, Codable, CaseIterable, Identifiable {
    case sedentary
    case light
    case moderate
    case active
    case veryActive

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sedentary: "Sedentary"
        case .light: "Light"
        case .moderate: "Moderate"
        case .active: "Active"
        case .veryActive: "Very active"
        }
    }

    public var multiplier: Double {
        switch self {
        case .sedentary: 1.2
        case .light: 1.375
        case .moderate: 1.55
        case .active: 1.725
        case .veryActive: 1.9
        }
    }
}

public nonisolated enum DietaryPattern: String, Codable, CaseIterable, Identifiable {
    case balanced
    case higherProtein
    case plantForward
    case lowerCarb

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .balanced: "Balanced"
        case .higherProtein: "Higher protein"
        case .plantForward: "Plant-forward"
        case .lowerCarb: "Lower carb"
        }
    }
}

public nonisolated enum GuidanceIntensity: String, Codable, CaseIterable, Identifiable {
    case gentle
    case steady
    case detailed

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .gentle: "Gentle"
        case .steady: "Steady"
        case .detailed: "Detailed"
        }
    }
}

public nonisolated struct MealComponentSnapshot: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var foodItemId: UUID?
    public var name: String
    public var quantity: Double
    public var unit: String
    public var macros: Macros
    public var micronutrients: Micronutrients

    public init(
        id: UUID = UUID(),
        foodItemId: UUID? = nil,
        name: String,
        quantity: Double,
        unit: String,
        macros: Macros,
        micronutrients: Micronutrients
    ) {
        self.id = id
        self.foodItemId = foodItemId
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.macros = macros
        self.micronutrients = micronutrients
    }
}

public nonisolated struct Meal: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var name: String
    // Tolerant enum decode + parked-token side channels (EnumDecodeCompat): a Meal lives in the
    // blob's top-level `recentMeals` AND inside days, so a strict decode of a raw value only a
    // newer build knows would brick the older device (or drop the day's row).
    public var mealType: MealType {
        didSet { unknownMealTypeToken = nil }
    }
    public var unknownMealTypeToken: String? = nil
    public var macros: Macros
    public var macroSnapshot: Macros
    public var calorieSnapshot: Int
    public var micronutrientSnapshot: Micronutrients
    public var componentSnapshots: [MealComponentSnapshot]
    public var mealSource: MealSource = .manual {
        didSet { unknownMealSourceToken = nil }
    }
    public var unknownMealSourceToken: String? = nil
    public var isAIFallback: Bool = true
    public var quality: MealQuality {
        didSet { unknownQualityToken = nil }
    }
    public var unknownQualityToken: String? = nil
    public var confidence: String
    public var note: String
    public var source: String
    public var loggedAt = Date()
    public var photoID: UUID?

    public var calories: Int {
        macros.protein * 4 + macros.carbs * 4 + macros.fat * 9
    }

    public func copyForToday() -> Meal {
        var copy = self
        copy.id = UUID()
        copy.loggedAt = .now
        copy.photoID = nil
        return copy
    }

    public init(
        id: UUID = UUID(),
        name: String,
        mealType: MealType,
        macros: Macros,
        macroSnapshot: Macros? = nil,
        calorieSnapshot: Int? = nil,
        micronutrientSnapshot: Micronutrients = Micronutrients(),
        componentSnapshots: [MealComponentSnapshot] = [],
        mealSource: MealSource = .manual,
        isAIFallback: Bool = true,
        quality: MealQuality,
        confidence: String,
        note: String,
        source: String,
        loggedAt: Date = Date(),
        photoID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.mealType = mealType
        self.macros = macros
        self.macroSnapshot = macroSnapshot ?? macros
        self.calorieSnapshot = calorieSnapshot ?? Self.calories(for: macroSnapshot ?? macros)
        self.micronutrientSnapshot = micronutrientSnapshot
        self.componentSnapshots = componentSnapshots
        self.mealSource = mealSource
        self.isAIFallback = isAIFallback
        self.quality = quality
        self.confidence = confidence
        self.note = note
        self.source = source
        self.loggedAt = loggedAt
        self.photoID = photoID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        // Required key (was strict `decode` pre-compat): absence is corruption, not a newer build.
        let mealTypeSplit = try container.decodeTolerantRequiredEnum(
            MealType.self, forKey: .mealType, parkedTokenKey: .unknownMealTypeToken, default: .snack)
        mealType = mealTypeSplit.value
        unknownMealTypeToken = mealTypeSplit.parkedToken
        macros = try container.decode(Macros.self, forKey: .macros)
        macroSnapshot = try container.decodeIfPresent(Macros.self, forKey: .macroSnapshot) ?? macros
        calorieSnapshot = try container.decodeIfPresent(Int.self, forKey: .calorieSnapshot) ?? Self.calories(for: macroSnapshot)
        micronutrientSnapshot = try container.decodeIfPresent(Micronutrients.self, forKey: .micronutrientSnapshot) ?? Micronutrients()
        componentSnapshots = try container.decodeIfPresent([MealComponentSnapshot].self, forKey: .componentSnapshots) ?? []
        let mealSourceSplit = try container.decodeTolerantEnum(
            MealSource.self, forKey: .mealSource, parkedTokenKey: .unknownMealSourceToken, default: .manual)
        mealSource = mealSourceSplit.value
        unknownMealSourceToken = mealSourceSplit.parkedToken
        isAIFallback = try container.decodeIfPresent(Bool.self, forKey: .isAIFallback) ?? true
        // Required key (was strict `decode` pre-compat): absence is corruption, not a newer build.
        let qualitySplit = try container.decodeTolerantRequiredEnum(
            MealQuality.self, forKey: .quality, parkedTokenKey: .unknownQualityToken, default: .ok)
        quality = qualitySplit.value
        unknownQualityToken = qualitySplit.parkedToken
        confidence = try container.decode(String.self, forKey: .confidence)
        note = try container.decode(String.self, forKey: .note)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? MealLogSource.manual
        loggedAt = try container.decodeIfPresent(Date.self, forKey: .loggedAt) ?? Date()
        photoID = try container.decodeIfPresent(UUID.self, forKey: .photoID)
    }

    private static func calories(for macros: Macros) -> Int {
        macros.protein * 4 + macros.carbs * 4 + macros.fat * 9
    }
}

/// How much to trust a resolved meal. Drives the honest label on the meal row and whether the
/// quick-log flow pauses for a pre-log review before committing a fabricated / low-confidence result.
public nonisolated enum MealResolutionConfidence: String, Codable {
    case high
    case medium
    case low

    public var mealLabel: String {
        switch self {
        case .high: "Food match"
        case .medium: "Estimated"
        case .low: "Rough estimate"
        }
    }

    /// Low-confidence resolutions are routed through a pre-log review sheet instead of auto-committing.
    public var needsReview: Bool { self == .low }

    public var rank: Int {
        switch self {
        case .high: 2
        case .medium: 1
        case .low: 0
        }
    }

    public static func fromRank(_ rank: Int) -> MealResolutionConfidence {
        if rank >= 2 { return .high }
        if rank == 1 { return .medium }
        return .low
    }

    /// One step less confident (high -> medium -> low), floored at `.low`.
    public var lowered: MealResolutionConfidence { Self.fromRank(rank - 1) }

    /// The more pessimistic of two confidences.
    public static func combine(_ lhs: MealResolutionConfidence, _ rhs: MealResolutionConfidence) -> MealResolutionConfidence {
        fromRank(min(lhs.rank, rhs.rank))
    }

    /// Parses the model's free-text confidence word; defaults to `.medium` when absent/unrecognised.
    public static func fromModelWord(_ word: String) -> MealResolutionConfidence {
        let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("high") { return .high }
        if normalized.contains("low") { return .low }
        return .medium
    }
}

/// A meal produced by the resolver together with how much to trust it.
public nonisolated struct ResolvedMeal {

    public init(meal: Meal, confidence: MealResolutionConfidence) {
        self.meal = meal
        self.confidence = confidence
    }
    public var meal: Meal
    public var confidence: MealResolutionConfidence
}

/// The full outcome of resolving a quick-log description: the meals (not yet committed), any
/// recipes that were created as a side effect, overall confidence, and whether the keyword-heuristic
/// fallback was used. `needsReview` decides whether the UI pauses for a pre-log review.
public nonisolated struct MealResolution {

    public init(meals: [Meal], createdRecipes: [RecipeDefinition], confidence: MealResolutionConfidence, isFallback: Bool) {
        self.meals = meals
        self.createdRecipes = createdRecipes
        self.confidence = confidence
        self.isFallback = isFallback
    }
    public var meals: [Meal]
    public var createdRecipes: [RecipeDefinition]
    public var confidence: MealResolutionConfidence
    public var isFallback: Bool

    public var needsReview: Bool { confidence.needsReview || isFallback }
}

public nonisolated struct Macros: Codable, Equatable, Sendable {
    public var protein: Int
    public var carbs: Int
    public var fat: Int

    /// Per-serving protein (grams) at or above which a meal is rated `.good` rather than `.ok`. The
    /// single source of truth for this threshold — referenced by MealBuilder, the facade's meal
    /// correction/review paths, DiaryStore, and FoodView (WI-Q, Docs/Security-Hardening-Plan-2026-06-27.md).
    public static let goodProteinThreshold = 25

    public init(protein: Int, carbs: Int, fat: Int) {
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
    }

    public var calories: Int { protein * 4 + carbs * 4 + fat * 9 }
}

public nonisolated struct Micronutrients: Codable, Equatable, Sendable {
    public var fiber: Double?
    public var sugar: Double?
    public var saturatedFat: Double?
    public var cholesterol: Double?
    public var vitaminA: Double?
    public var vitaminC: Double?
    public var vitaminD: Double?
    public var vitaminE: Double?
    public var vitaminK: Double?
    public var vitaminB6: Double?
    public var vitaminB12: Double?
    public var thiamin: Double?
    public var riboflavin: Double?
    public var niacin: Double?
    public var folate: Double?
    public var calcium: Double?
    public var iron: Double?
    public var magnesium: Double?
    public var phosphorus: Double?
    public var potassium: Double?
    public var sodium: Double?
    public var zinc: Double?
    public var omega3: Double?

    nonisolated public init(
        fiber: Double? = nil,
        sugar: Double? = nil,
        saturatedFat: Double? = nil,
        cholesterol: Double? = nil,
        vitaminA: Double? = nil,
        vitaminC: Double? = nil,
        vitaminD: Double? = nil,
        vitaminE: Double? = nil,
        vitaminK: Double? = nil,
        vitaminB6: Double? = nil,
        vitaminB12: Double? = nil,
        thiamin: Double? = nil,
        riboflavin: Double? = nil,
        niacin: Double? = nil,
        folate: Double? = nil,
        calcium: Double? = nil,
        iron: Double? = nil,
        magnesium: Double? = nil,
        phosphorus: Double? = nil,
        potassium: Double? = nil,
        sodium: Double? = nil,
        zinc: Double? = nil,
        omega3: Double? = nil
    ) {
        self.fiber = fiber
        self.sugar = sugar
        self.saturatedFat = saturatedFat
        self.cholesterol = cholesterol
        self.vitaminA = vitaminA
        self.vitaminC = vitaminC
        self.vitaminD = vitaminD
        self.vitaminE = vitaminE
        self.vitaminK = vitaminK
        self.vitaminB6 = vitaminB6
        self.vitaminB12 = vitaminB12
        self.thiamin = thiamin
        self.riboflavin = riboflavin
        self.niacin = niacin
        self.folate = folate
        self.calcium = calcium
        self.iron = iron
        self.magnesium = magnesium
        self.phosphorus = phosphorus
        self.potassium = potassium
        self.sodium = sodium
        self.zinc = zinc
        self.omega3 = omega3
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiber = try container.decodeIfPresent(Double.self, forKey: .fiber)
        sugar = try container.decodeIfPresent(Double.self, forKey: .sugar)
        saturatedFat = try container.decodeIfPresent(Double.self, forKey: .saturatedFat)
        cholesterol = try container.decodeIfPresent(Double.self, forKey: .cholesterol)
        vitaminA = try container.decodeIfPresent(Double.self, forKey: .vitaminA)
        vitaminC = try container.decodeIfPresent(Double.self, forKey: .vitaminC)
        vitaminD = try container.decodeIfPresent(Double.self, forKey: .vitaminD)
        vitaminE = try container.decodeIfPresent(Double.self, forKey: .vitaminE)
        vitaminK = try container.decodeIfPresent(Double.self, forKey: .vitaminK)
        vitaminB6 = try container.decodeIfPresent(Double.self, forKey: .vitaminB6)
        vitaminB12 = try container.decodeIfPresent(Double.self, forKey: .vitaminB12)
        thiamin = try container.decodeIfPresent(Double.self, forKey: .thiamin)
        riboflavin = try container.decodeIfPresent(Double.self, forKey: .riboflavin)
        niacin = try container.decodeIfPresent(Double.self, forKey: .niacin)
        folate = try container.decodeIfPresent(Double.self, forKey: .folate)
        calcium = try container.decodeIfPresent(Double.self, forKey: .calcium)
        iron = try container.decodeIfPresent(Double.self, forKey: .iron)
        magnesium = try container.decodeIfPresent(Double.self, forKey: .magnesium)
        phosphorus = try container.decodeIfPresent(Double.self, forKey: .phosphorus)
        potassium = try container.decodeIfPresent(Double.self, forKey: .potassium)
        sodium = try container.decodeIfPresent(Double.self, forKey: .sodium)
        zinc = try container.decodeIfPresent(Double.self, forKey: .zinc)
        omega3 = try container.decodeIfPresent(Double.self, forKey: .omega3)
    }
}

extension Micronutrients {
    nonisolated public static var totalFieldCount: Int { 23 }

    public static func totals(for meals: [Meal]) -> Micronutrients {
        meals.reduce(into: Micronutrients()) { partial, meal in
            partial.add(meal.micronutrientSnapshot)
        }
    }

    public var populatedFieldCount: Int {
        [
            fiber, sugar, saturatedFat, cholesterol,
            vitaminA, vitaminC, vitaminD, vitaminE, vitaminK, vitaminB6, vitaminB12,
            thiamin, riboflavin, niacin, folate,
            calcium, iron, magnesium, phosphorus, potassium, sodium, zinc, omega3
        ].compactMap { $0 }.count
    }

    public var totalFieldCount: Int { Self.totalFieldCount }

    public var completeness: Double {
        guard totalFieldCount > 0 else { return 0 }
        return Double(populatedFieldCount) / Double(totalFieldCount)
    }

    public var hasAnyValue: Bool {
        fiber != nil || sugar != nil || saturatedFat != nil || cholesterol != nil ||
        vitaminA != nil || vitaminC != nil || vitaminD != nil || vitaminE != nil ||
        vitaminK != nil || vitaminB6 != nil || vitaminB12 != nil || thiamin != nil ||
        riboflavin != nil || niacin != nil || folate != nil || calcium != nil ||
        iron != nil || magnesium != nil || phosphorus != nil || potassium != nil ||
        sodium != nil || zinc != nil || omega3 != nil
    }

    public func scaled(by scale: Double) -> Micronutrients {
        let safeScale = max(scale, 0)
        return Micronutrients(
            fiber: fiber.map { $0 * safeScale },
            sugar: sugar.map { $0 * safeScale },
            saturatedFat: saturatedFat.map { $0 * safeScale },
            cholesterol: cholesterol.map { $0 * safeScale },
            vitaminA: vitaminA.map { $0 * safeScale },
            vitaminC: vitaminC.map { $0 * safeScale },
            vitaminD: vitaminD.map { $0 * safeScale },
            vitaminE: vitaminE.map { $0 * safeScale },
            vitaminK: vitaminK.map { $0 * safeScale },
            vitaminB6: vitaminB6.map { $0 * safeScale },
            vitaminB12: vitaminB12.map { $0 * safeScale },
            thiamin: thiamin.map { $0 * safeScale },
            riboflavin: riboflavin.map { $0 * safeScale },
            niacin: niacin.map { $0 * safeScale },
            folate: folate.map { $0 * safeScale },
            calcium: calcium.map { $0 * safeScale },
            iron: iron.map { $0 * safeScale },
            magnesium: magnesium.map { $0 * safeScale },
            phosphorus: phosphorus.map { $0 * safeScale },
            potassium: potassium.map { $0 * safeScale },
            sodium: sodium.map { $0 * safeScale },
            zinc: zinc.map { $0 * safeScale },
            omega3: omega3.map { $0 * safeScale }
        )
    }

    public mutating func add(_ other: Micronutrients) {
        fiber = Self.sum(fiber, other.fiber)
        sugar = Self.sum(sugar, other.sugar)
        saturatedFat = Self.sum(saturatedFat, other.saturatedFat)
        cholesterol = Self.sum(cholesterol, other.cholesterol)
        vitaminA = Self.sum(vitaminA, other.vitaminA)
        vitaminC = Self.sum(vitaminC, other.vitaminC)
        vitaminD = Self.sum(vitaminD, other.vitaminD)
        vitaminE = Self.sum(vitaminE, other.vitaminE)
        vitaminK = Self.sum(vitaminK, other.vitaminK)
        vitaminB6 = Self.sum(vitaminB6, other.vitaminB6)
        vitaminB12 = Self.sum(vitaminB12, other.vitaminB12)
        thiamin = Self.sum(thiamin, other.thiamin)
        riboflavin = Self.sum(riboflavin, other.riboflavin)
        niacin = Self.sum(niacin, other.niacin)
        folate = Self.sum(folate, other.folate)
        calcium = Self.sum(calcium, other.calcium)
        iron = Self.sum(iron, other.iron)
        magnesium = Self.sum(magnesium, other.magnesium)
        phosphorus = Self.sum(phosphorus, other.phosphorus)
        potassium = Self.sum(potassium, other.potassium)
        sodium = Self.sum(sodium, other.sodium)
        zinc = Self.sum(zinc, other.zinc)
        omega3 = Self.sum(omega3, other.omega3)
    }

    private static func sum(_ first: Double?, _ second: Double?) -> Double? {
        switch (first, second) {
        case let (first?, second?):
            first + second
        case let (first?, nil):
            first
        case let (nil, second?):
            second
        case (nil, nil):
            nil
        }
    }
}

public nonisolated enum NutrientGapStatus: String, Codable, Equatable {
    case covered
    case gap
}

public nonisolated struct NutrientGap: Identifiable, Codable, Equatable {

    public init(nutrientKey: String, nutrientName: String, unit: String, windowDays: Int, coverageRatio: Double, dataCoverageRatio: Double, status: NutrientGapStatus) {
        self.nutrientKey = nutrientKey
        self.nutrientName = nutrientName
        self.unit = unit
        self.windowDays = windowDays
        self.coverageRatio = coverageRatio
        self.dataCoverageRatio = dataCoverageRatio
        self.status = status
    }
    public var nutrientKey: String
    public var nutrientName: String
    public var unit: String
    public var windowDays: Int
    public var coverageRatio: Double
    public var dataCoverageRatio: Double
    public var status: NutrientGapStatus

    public var id: String {
        "\(nutrientKey)-\(windowDays)-\(status.rawValue)"
    }
}

public nonisolated struct NutrientReference {

    public init(key: String, name: String, unit: String, recommendedDailyAmount: Double, value: @escaping (Micronutrients) -> Double?) {
        self.key = key
        self.name = name
        self.unit = unit
        self.recommendedDailyAmount = recommendedDailyAmount
        self.value = value
    }
    public var key: String
    public var name: String
    public var unit: String
    public var recommendedDailyAmount: Double
    public var value: (Micronutrients) -> Double?
}

public nonisolated enum MicronutrientGapAnalyzer {
    nonisolated(unsafe) public static let trackedNutrients: [NutrientReference] = [
        NutrientReference(key: "fiber", name: "Fiber", unit: "g", recommendedDailyAmount: 28) { $0.fiber },
        NutrientReference(key: "vitaminC", name: "Vitamin C", unit: "mg", recommendedDailyAmount: 90) { $0.vitaminC },
        NutrientReference(key: "vitaminD", name: "Vitamin D", unit: "mcg", recommendedDailyAmount: 20) { $0.vitaminD },
        NutrientReference(key: "vitaminB12", name: "Vitamin B12", unit: "mcg", recommendedDailyAmount: 2.4) { $0.vitaminB12 },
        NutrientReference(key: "folate", name: "Folate", unit: "mcg DFE", recommendedDailyAmount: 400) { $0.folate },
        NutrientReference(key: "calcium", name: "Calcium", unit: "mg", recommendedDailyAmount: 1_000) { $0.calcium },
        NutrientReference(key: "iron", name: "Iron", unit: "mg", recommendedDailyAmount: 18) { $0.iron },
        NutrientReference(key: "magnesium", name: "Magnesium", unit: "mg", recommendedDailyAmount: 420) { $0.magnesium },
        NutrientReference(key: "potassium", name: "Potassium", unit: "mg", recommendedDailyAmount: 3_400) { $0.potassium },
        NutrientReference(key: "zinc", name: "Zinc", unit: "mg", recommendedDailyAmount: 11) { $0.zinc },
        NutrientReference(key: "omega3", name: "Omega-3", unit: "g", recommendedDailyAmount: 1.6) { $0.omega3 }
    ]

    /// Fraction of meals that carry usable micronutrient data (>= 5 populated fields).
    /// Pure `Meal` arithmetic; lives in the domain layer so scoring depends on the
    /// domain (not the reverse). `FernletScoring.micronutrientDataCoverageRatio`
    /// forwards here for existing app-layer callers.
    public static func micronutrientDataCoverageRatio(for meals: [Meal]) -> Double {
        guard meals.isEmpty == false else { return 0 }
        let mealsWithData = meals.filter { $0.micronutrientSnapshot.populatedFieldCount >= 5 }.count
        return Double(mealsWithData) / Double(meals.count)
    }

    public static func gaps(from days: [(String, FernletDay)], windowDays: Int) -> [NutrientGap] {
        assert(windowDays > 0, "window must be positive")
        let window = Array(days.suffix(windowDays))
        let meals = window.flatMap { $0.1.meals.prefix(20) }
        guard meals.isEmpty == false else { return [] }
        guard micronutrientDataCoverageRatio(for: meals) >= 0.5 else { return [] }

        return trackedNutrients.compactMap { nutrient in
            let values = meals.compactMap { nutrient.value($0.micronutrientSnapshot) }
            let dataCoverageRatio = Double(values.count) / Double(meals.count)
            guard dataCoverageRatio >= 0.5 else { return nil }

            let coverageRatio = values.reduce(0, +) / (nutrient.recommendedDailyAmount * Double(windowDays))
            if coverageRatio < 0.25 {
                return NutrientGap(
                    nutrientKey: nutrient.key,
                    nutrientName: nutrient.name,
                    unit: nutrient.unit,
                    windowDays: windowDays,
                    coverageRatio: coverageRatio,
                    dataCoverageRatio: dataCoverageRatio,
                    status: .gap
                )
            }
            if coverageRatio >= 0.5 {
                return NutrientGap(
                    nutrientKey: nutrient.key,
                    nutrientName: nutrient.name,
                    unit: nutrient.unit,
                    windowDays: windowDays,
                    coverageRatio: coverageRatio,
                    dataCoverageRatio: dataCoverageRatio,
                    status: .covered
                )
            }
            return nil
        }
    }
}

public nonisolated enum FoodDataType: String, Codable, Sendable {
    case foundation   // USDA Foundation Foods
    case survey       // USDA/FNDDS survey foods
    case srLegacy     // USDA SR Legacy reference
    case branded      // Commercial/branded product
    case restaurant   // Restaurant chain item
}

public nonisolated enum FoodItemSource: String, Codable, Sendable {
    case usda
    case aiResolved
    case manual
}

public nonisolated enum MealLogSource {
    nonisolated public static let manual = "manual"
    nonisolated public static let labelScan = "label-scan"
    nonisolated public static let barcodeScan = "barcode-scan"
    nonisolated public static let usdaRecipe = "usda-recipe"
    nonisolated public static let webImport = "web-import"
    nonisolated public static let foundationModel = "foundation-model"
    nonisolated public static let foundationModelFoodSelection = "foundation-model-food-selection"
}

/// GTIN/UPC barcode normalization shared by the catalog read path, the database builder, and
/// user-item matching. Canonical form = digits only, left-padded to 14 (GTIN-14), so the UPC-A (12),
/// EAN-13 (13), EAN-8 (8), and GTIN-14 renderings of the same code all compare equal — a UPC-A
/// product scanned as EAN-13 (Vision reports UPC-A with a leading zero) still hits.
public nonisolated enum FoodBarcode {
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let digits = raw.filter(\.isNumber)
        guard [8, 12, 13, 14].contains(digits.count) else { return nil }
        return String(repeating: "0", count: 14 - digits.count) + digits
    }
}

public nonisolated struct FoodItem: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var brandSource: String?
    public var servingSize: Double
    public var servingUnit: String
    public var macros: Macros
    public var micronutrients: Micronutrients
    public var category: String
    // Tolerant enum decode + parked-token side channels (EnumDecodeCompat): foodItems is a
    // top-level synced-blob field, and `source`/`dataType` are exactly the taxonomy a future data
    // pipeline extends. Unknown `source` freezes to `.manual` (never falsely claims USDA or AI
    // provenance); unknown `dataType` freezes to the long-standing `.srLegacy` default.
    public var source: FoodItemSource {
        didSet { unknownSourceToken = nil }
    }
    public var unknownSourceToken: String? = nil
    public var dataType: FoodDataType = .srLegacy {
        didSet { unknownDataTypeToken = nil }
    }
    public var unknownDataTypeToken: String? = nil
    public var sourceURL: URL?
    public var servingDescription: String?
    public var verificationPolicyDays: Int = 180
    public var lastVerified: Date?
    public var isFlagged: Bool = false
    public var tags: [String]
    public var portions: [FoodPortion]
    /// Normalized GTIN (see `FoodBarcode.normalized`) when this food was created from / matched to a
    /// product barcode. Optional + `decodeIfPresent` so synced-blob snapshots stay backward compatible.
    public var barcode: String?

    public var calories: Int {
        macros.protein * 4 + macros.carbs * 4 + macros.fat * 9
    }

    /// Short, human-readable provenance shown on ingredient-search rows so the user can tell where a
    /// match came from (Item 3 ingredient-search UX). Branded/restaurant items prefer their brand
    /// name; reference USDA foods read "USDA"; user and AI-derived foods are labelled distinctly.
    public var dataSourceLabel: String {
        switch source {
        case .manual:
            return "Your foods"
        case .aiResolved:
            return "AI estimate"
        case .usda:
            switch dataType {
            case .branded:
                return brandSource?.isEmpty == false ? brandSource! : "Branded"
            case .restaurant:
                return brandSource?.isEmpty == false ? brandSource! : "Restaurant"
            case .foundation, .survey, .srLegacy:
                return "USDA"
            }
        }
    }

    nonisolated public init(
        id: UUID = UUID(),
        name: String,
        brandSource: String? = nil,
        servingSize: Double,
        servingUnit: String,
        macros: Macros,
        micronutrients: Micronutrients,
        category: String,
        source: FoodItemSource,
        dataType: FoodDataType = .srLegacy,
        sourceURL: URL? = nil,
        servingDescription: String? = nil,
        verificationPolicyDays: Int = 180,
        lastVerified: Date? = nil,
        isFlagged: Bool = false,
        tags: [String],
        portions: [FoodPortion] = [],
        barcode: String? = nil
    ) {
        self.id = id
        self.name = name
        self.brandSource = brandSource
        self.servingSize = servingSize
        self.servingUnit = servingUnit
        self.macros = macros
        self.micronutrients = micronutrients
        self.category = category
        self.source = source
        self.dataType = dataType
        self.sourceURL = sourceURL
        self.servingDescription = servingDescription
        self.verificationPolicyDays = verificationPolicyDays
        self.lastVerified = lastVerified
        self.isFlagged = isFlagged
        self.tags = tags
        self.portions = portions
        self.barcode = barcode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        brandSource = try container.decodeIfPresent(String.self, forKey: .brandSource)
        servingSize = try container.decode(Double.self, forKey: .servingSize)
        servingUnit = try container.decode(String.self, forKey: .servingUnit)
        macros = try container.decode(Macros.self, forKey: .macros)
        micronutrients = try container.decodeIfPresent(Micronutrients.self, forKey: .micronutrients) ?? Micronutrients()
        category = try container.decode(String.self, forKey: .category)
        // Required key (was strict `decode` pre-compat): absence is corruption, not a newer build.
        let sourceSplit = try container.decodeTolerantRequiredEnum(
            FoodItemSource.self, forKey: .source, parkedTokenKey: .unknownSourceToken, default: .manual)
        source = sourceSplit.value
        unknownSourceToken = sourceSplit.parkedToken
        let dataTypeSplit = try container.decodeTolerantEnum(
            FoodDataType.self, forKey: .dataType, parkedTokenKey: .unknownDataTypeToken, default: .srLegacy)
        dataType = dataTypeSplit.value
        unknownDataTypeToken = dataTypeSplit.parkedToken
        sourceURL = try container.decodeIfPresent(URL.self, forKey: .sourceURL)
        servingDescription = try container.decodeIfPresent(String.self, forKey: .servingDescription)
        verificationPolicyDays = try container.decodeIfPresent(Int.self, forKey: .verificationPolicyDays) ?? 180
        lastVerified = try container.decodeIfPresent(Date.self, forKey: .lastVerified)
        isFlagged = try container.decodeIfPresent(Bool.self, forKey: .isFlagged) ?? false
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        portions = try container.decodeIfPresent([FoodPortion].self, forKey: .portions) ?? []
        barcode = try container.decodeIfPresent(String.self, forKey: .barcode)
    }
}

public nonisolated struct FoodPortion: Codable, Equatable, Sendable {

    public init(amount: Double, unit: String, gramWeight: Double, description: String? = nil) {
        self.amount = amount
        self.unit = unit
        self.gramWeight = gramWeight
        self.description = description
    }
    public var amount: Double
    public var unit: String
    public var gramWeight: Double
    public var description: String?
}

public nonisolated struct FoodSelectionCandidate: Identifiable, Equatable, Sendable {

    public init(id: Int, foodItem: FoodItem) {
        self.id = id
        self.foodItem = foodItem
    }
    public var id: Int
    public var foodItem: FoodItem

    public var promptLine: String {
        let brand = foodItem.brandSource.map { " \($0)" } ?? ""
        return "\(id). \(foodItem.name)\(brand) - \(foodItem.category), serving \(String(format: "%g", foodItem.servingSize)) \(foodItem.servingUnit), P\(foodItem.macros.protein) C\(foodItem.macros.carbs) F\(foodItem.macros.fat)"
    }
}

public nonisolated struct FoodSelectionIngredient: Identifiable, Equatable {
    public var id = UUID()
    public var candidateId: Int
    public var foodName: String
    public var quantity: Double
    public var unit: String

    public init(id: UUID = UUID(), candidateId: Int, foodName: String, quantity: Double, unit: String) {
        self.id = id
        self.candidateId = candidateId
        self.foodName = foodName
        self.quantity = quantity
        self.unit = unit
    }
}

public nonisolated struct FoodSelectionMealItem: Identifiable, Equatable {

    public init(id: UUID = UUID(), name: String, ingredients: [FoodSelectionIngredient]) {
        self.id = id
        self.name = name
        self.ingredients = ingredients
    }
    public var id = UUID()
    public var name: String
    public var ingredients: [FoodSelectionIngredient]
}

public nonisolated struct FoodSelectionPlan: Equatable {

    public init(mealName: String, mealType: MealType, items: [FoodSelectionMealItem]) {
        self.mealName = mealName
        self.mealType = mealType
        self.items = items
    }
    public var mealName: String
    public var mealType: MealType
    public var items: [FoodSelectionMealItem]

    public var ingredients: [FoodSelectionIngredient] {
        items.flatMap(\.ingredients)
    }
}

public nonisolated enum MealItemSplitter {
    public static func items(from description: String) -> [String] {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }
        let normalized = trimmed
            .replacingOccurrences(of: " & ", with: " and ")
            .replacingOccurrences(of: ",", with: " and ")
            .replacingOccurrences(of: ";", with: " and ")
            .replacingOccurrences(of: " plus ", with: " and ", options: [.caseInsensitive])
            // "with" separates foods ("burger with fries") EXCEPT when it introduces a quantity modifier
            // of the preceding food ("burger with 2 patties", "coffee with extra shots"). Then the head
            // food is unchanged and the clause just describes it, so keep it attached as one item.
            .replacingOccurrences(
                of: #"\s+with\s+(?!(?:\d|two|three|four|five|six|seven|eight|nine|ten|extra|double|triple)\b)"#,
                with: " and ",
                options: [.regularExpression, .caseInsensitive]
            )
        let pieces = normalized
            .components(separatedBy: " and ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { $0.count >= 3 }
        return pieces.isEmpty ? [trimmed] : pieces
    }
}

/// Distinguishes an assembled/prepared DISH (a hamburger on a bun, a chicken sandwich, a taco) from a
/// raw INGREDIENT, and demotes the former when a quick-log names an ingredient. This generalizes the
/// "burger patties bound to 'double hamburger on wheat bun'" problem: the USDA FNDDS `survey` dataset is
/// full of prepared/fast-food composite entries, and because data-type is sorted ABOVE relevance score
/// in `FoodItemSearch`, those dishes outrank the raw food no matter how much better it matches. The rule
/// is intent-based (not a food-name blocklist): a query "wants a dish" only when its HEAD noun (last
/// significant word) is itself a dish/carrier word — "cheeseburger", "chicken sandwich", "burger" — so
/// "burger patties" / "grilled chicken" (head = patties / chicken) prefer the raw food.
public nonisolated enum PreparedDishHeuristic {
    /// Carrier / assembly tokens that mark a food as a composed dish rather than a single ingredient.
    nonisolated static let carrierTokens: Set<String> = [
        "bun", "buns", "sandwich", "sandwiches", "roll", "rolls", "biscuit", "biscuits", "bagel",
        "croissant", "wrap", "wraps", "tortilla", "taco", "tacos", "burrito", "burritos", "sub",
        "hoagie", "pita", "melt", "toast", "panini", "quesadilla", "calzone", "nachos"
    ]
    /// Substrings that mark an FNDDS prepared / fast-food composite entry.
    nonisolated static let preparedMarkers: [String] = [
        "fast food", "on wheat", "on white", "with condiments", "double decker", "on bun", "on a bun"
    ]
    /// Head-noun words that mean the user WANTS the assembled dish — carriers plus the dish names whose
    /// head noun is the dish itself. When the query's head noun is one of these, dishes aren't demoted.
    nonisolated static let dishHeadNouns: Set<String> = carrierTokens.union([
        "burger", "hamburger", "cheeseburger", "pizza", "sushi", "ramen", "pho", "curry", "stew",
        "casserole", "lasagna", "enchilada", "gyro", "shawarma", "poutine"
    ])

    /// Whether a food is an assembled/prepared dish (carries an assembly token or a prepared marker).
    public nonisolated static func isPreparedDish(_ foodItem: FoodItem) -> Bool {
        let name = FoodItemSearch.normalized(foodItem.name)
        if preparedMarkers.contains(where: name.contains) { return true }
        let tokens = Set(name.split(separator: " ").map(String.init))
        return !tokens.isDisjoint(with: carrierTokens)
    }

    /// Cut / component / portion nouns. When the query's head noun is one of these it names a raw
    /// ingredient or cut, NOT the assembled dish — even under a dish modifier. This is what separates
    /// "a burger" (head = burger → the dish, with a bun) from "a burger patty" (head = patty → just the
    /// meat), and "chicken sandwich" (dish) from "chicken breast" (ingredient).
    nonisolated static let componentNouns: Set<String> = [
        "patty", "patties", "breast", "breasts", "thigh", "thighs", "drumstick", "drumsticks",
        "wing", "wings", "fillet", "fillets", "filet", "filets", "cutlet", "cutlets", "loin", "loins",
        "chop", "chops", "steak", "steaks", "strip", "strips", "tender", "tenders", "nugget", "nuggets",
        "meatball", "meatballs", "slice", "slices", "scoop", "scoops", "ground", "link", "links"
    ]

    /// Whether the query asks for an assembled dish — decided by its HEAD noun (the grammatical head of
    /// the main noun phrase), not by any token. A component head ("patty", "breast") is an ingredient;
    /// otherwise a dish/carrier head ("burger", "sandwich", "taco") is a dish. So "a burger" → dish,
    /// "a burger patty" → ingredient, "a burger with 2 patties" → dish (head = burger, before "with").
    public nonisolated static func queryWantsDish(_ query: String) -> Bool {
        guard let head = headNoun(of: query) else { return false }
        if componentNouns.contains(head) || componentNouns.contains(singular(head)) { return false }
        return dishHeadNouns.contains(head) || dishHeadNouns.contains(singular(head))
    }

    /// The head noun of the query's MAIN noun phrase: the last significant token BEFORE any trailing
    /// modifier/preposition. A post-"with"/"on" clause usually modifies the head ("burger with 2 patties",
    /// "toast on the side") rather than renaming it, so "burger with 2 patties" → "burger", not "patties".
    private nonisolated static func headNoun(of query: String) -> String? {
        var text = FoodItemSearch.normalized(query)
        for separator in [" with ", " on ", " topped ", " smothered ", " served ", " over ", " plus ", " and "] {
            if let range = text.range(of: separator) { text = String(text[..<range.lowerBound]) }
        }
        return text.split(separator: " ").map(String.init)
            .filter { $0.count >= 2 && Double($0) == nil }
            .last
    }

    /// Stable partition: raw ingredients first, prepared dishes last — but only for a bare-ingredient
    /// query, and only when it actually reorders anything (some, not all, are dishes). Order within each
    /// group is preserved, so the scorer's ranking is untouched apart from sinking the dishes.
    public nonisolated static func demotingDishes(_ foods: [FoodItem], forQuery query: String) -> [FoodItem] {
        guard !queryWantsDish(query) else { return foods }
        let ingredients = foods.filter { !isPreparedDish($0) }
        guard !ingredients.isEmpty, ingredients.count != foods.count else { return foods }
        return ingredients + foods.filter { isPreparedDish($0) }
    }

    private nonisolated static func singular(_ token: String) -> String {
        if token.hasSuffix("ies"), token.count >= 5 { return String(token.dropLast(3)) + "y" }
        if token.hasSuffix("s"), !token.hasSuffix("ss"), token.count >= 4 { return String(token.dropLast()) }
        return token
    }
}

public nonisolated enum FoodSelectionCandidateBuilder {
    public static func candidates(for description: String, foodItems: [FoodItem], limit: Int = 18) -> [FoodSelectionCandidate] {
        let index = FoodItemSearch.Index(foodItems: foodItems)
        let phrases = searchPhrases(from: description)
        var selected: [FoodItem] = []

        for phrase in phrases {
            let matches = FoodItemSearch.results(for: phrase, in: index, limit: 4)
            for match in matches where selected.contains(where: { $0.id == match.id }) == false {
                selected.append(match)
                if selected.count >= limit { break }
            }
            if selected.count >= limit { break }
        }

        // Prefer raw ingredients over assembled/prepared dishes when the query is a bare ingredient
        // (its head noun isn't a dish word). FNDDS `survey` entries like "Chicken sandwich" or "Double
        // hamburger, on wheat bun" outrank raw foods because data-type sorts ABOVE relevance score, so
        // a plain "chicken" log would bind the sandwich; this demotes those unless a dish was asked for.
        let ordered = PreparedDishHeuristic.demotingDishes(selected, forQuery: description)
        return ordered.enumerated().map { offset, foodItem in
            FoodSelectionCandidate(id: offset + 1, foodItem: foodItem)
        }
    }

    /// Splits a meal description into overlapping search phrases (3-, 2-, then 1-word), longest first.
    /// Shared with `FoodCatalog.candidates(for:)` so the SQLite-backed candidate set matches the
    /// in-memory array path.
    public static func searchPhrases(from description: String) -> [String] {
        let stopWords: Set<String> = [
            "and", "with", "plus", "then", "for", "the", "a", "an", "of", "my", "meal",
            "breakfast", "lunch", "dinner", "snack", "pre", "post", "workout"
        ]
        let tokens = FoodItemSearch.normalized(description)
            .split(separator: " ")
            .map(String.init)
            .filter { token in
                token.count >= 3 && Double(token) == nil && stopWords.contains(token) == false
            }
        var phrases: [String] = []

        for size in stride(from: min(3, tokens.count), through: 1, by: -1) {
            guard tokens.count >= size else { continue }
            for start in 0...(tokens.count - size) {
                phrases.append(tokens[start..<(start + size)].joined(separator: " "))
            }
        }

        return Array(Set(phrases)).sorted { first, second in
            if first.split(separator: " ").count != second.split(separator: " ").count {
                return first.split(separator: " ").count > second.split(separator: " ").count
            }
            return first < second
        }
    }
}

public nonisolated struct RecipeIngredient: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var foodItemId: UUID
    public var quantity: Double
    public var unit: String

    public init(id: UUID = UUID(), foodItemId: UUID, quantity: Double, unit: String) {
        self.id = id
        self.foodItemId = foodItemId
        self.quantity = quantity
        self.unit = unit
    }
}

public nonisolated enum RecipeUnit: String, CaseIterable, Identifiable {
    case gram = "g"
    case milliliter = "ml"
    case ounce = "oz"
    case pound = "lb"
    case cup = "cup"
    case tablespoon = "tbsp"
    case teaspoon = "tsp"
    case each = "each"
    case serving = "serving"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .gram: "Grams"
        case .milliliter: "Milliliters"
        case .ounce: "Ounces"
        case .pound: "Pounds"
        case .cup: "Cups"
        case .tablespoon: "Tablespoons"
        case .teaspoon: "Teaspoons"
        case .each: "Each"
        case .serving: "Servings"
        }
    }

    public static func normalized(_ unit: String) -> RecipeUnit? {
        switch unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "g", "gram", "grams":
            return .gram
        case "ml", "milliliter", "milliliters", "millilitre", "millilitres":
            return .milliliter
        case "oz", "ounce", "ounces":
            return .ounce
        case "lb", "lbs", "pound", "pounds":
            return .pound
        case "cup", "cups":
            return .cup
        case "tbsp", "tablespoon", "tablespoons":
            return .tablespoon
        case "tsp", "teaspoon", "teaspoons":
            return .teaspoon
        case "each", "unit", "units", "item", "items":
            return .each
        case "serving", "servings":
            return .serving
        default:
            return nil
        }
    }
}

extension RecipeIngredient {
    private func scale(using foodItem: FoodItem) -> Double {
        if unit.caseInsensitiveCompare(foodItem.servingUnit) == .orderedSame {
            return quantity / max(foodItem.servingSize, 0.01)
        }
        if let quantityGrams = foodItem.gramsEquivalent(quantity: quantity, unit: unit) {
            if foodItem.servingUnit.caseInsensitiveCompare(RecipeUnit.gram.rawValue) == .orderedSame {
                return quantityGrams / max(foodItem.servingSize, 0.01)
            }
            if let servingGrams = foodItem.gramsEquivalent(quantity: foodItem.servingSize, unit: foodItem.servingUnit) {
                return quantityGrams / max(servingGrams, 0.01)
            }
        }
        return quantity
    }

    public func scaledMacros(using foodItem: FoodItem) -> Macros {
        foodItem.macros.scaled(by: scale(using: foodItem))
    }

    public func scaledMicronutrients(using foodItem: FoodItem) -> Micronutrients {
        foodItem.micronutrients.scaled(by: scale(using: foodItem))
    }
}

/// Extra fields a recipe carries only when it was imported from a web URL (e.g. via the share
/// extension or pasteboard). User-built recipes leave this nil and derive nutrition from their
/// structured `ingredients`; web-imported recipes keep their free-text ingredient lines and the
/// precomputed nutrition extracted at import time, because those ingredients can't be resolved to
/// `foodItemId`s without ambiguity. Bundling them here keeps `RecipeDefinition` the single recipe
/// model while preserving the original imported data losslessly.
public nonisolated struct RecipeWebImport: Codable, Equatable {
    public var sourceURLString: String
    public var ingredientLines: [String]
    public var macros: Macros
    public var micronutrients: Micronutrients

    /// The parsed source link, or `nil` when there's no usable one. An absent or unparseable
    /// `sourceURLString` (e.g. the decode default of `""`) returns `nil` rather than fabricating a
    /// `file:///` URL — a "no source" recipe should render no link at all, and a fabricated file URL
    /// would crash `SFSafariViewController` if it ever reached an in-app Safari sheet. Scheme
    /// filtering (only http/https is safe to open) stays a presentation-layer concern.
    public var sourceURL: URL? {
        guard !sourceURLString.isEmpty else { return nil }
        return URL(string: sourceURLString)
    }

    public init(
        sourceURLString: String,
        ingredientLines: [String],
        macros: Macros = Macros(protein: 0, carbs: 0, fat: 0),
        micronutrients: Micronutrients = Micronutrients()
    ) {
        self.sourceURLString = sourceURLString
        self.ingredientLines = ingredientLines
        self.macros = macros
        self.micronutrients = micronutrients
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceURLString = try container.decodeIfPresent(String.self, forKey: .sourceURLString) ?? ""
        ingredientLines = try container.decodeIfPresent([String].self, forKey: .ingredientLines) ?? []
        macros = try container.decodeIfPresent(Macros.self, forKey: .macros) ?? Macros(protein: 0, carbs: 0, fat: 0)
        micronutrients = try container.decodeIfPresent(Micronutrients.self, forKey: .micronutrients) ?? Micronutrients()
    }
}

public nonisolated struct RecipeDefinition: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var name: String
    public var servings: Int
    public var ingredients: [RecipeIngredient]
    public var notes: String
    public var source: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Non-nil only for recipes imported from a web URL. See `RecipeWebImport`.
    public var webImport: RecipeWebImport?

    /// True when this recipe was imported from the web (and therefore stores free-text ingredient
    /// lines + precomputed nutrition rather than structured `ingredients`).
    public var isWebImport: Bool { webImport != nil }

    public init(
        id: UUID = UUID(),
        name: String,
        servings: Int,
        ingredients: [RecipeIngredient],
        notes: String = "",
        source: String,
        createdAt: Date,
        updatedAt: Date,
        webImport: RecipeWebImport? = nil
    ) {
        self.id = id
        self.name = name
        self.servings = servings
        self.ingredients = ingredients
        self.notes = notes
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.webImport = webImport
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        servings = try container.decode(Int.self, forKey: .servings)
        ingredients = try container.decode([RecipeIngredient].self, forKey: .ingredients)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        source = try container.decode(String.self, forKey: .source)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        webImport = try container.decodeIfPresent(RecipeWebImport.self, forKey: .webImport)
    }
}

public nonisolated struct SharedRecipePayload: Codable, Equatable, Sendable {
    public var format = "fernlet.recipe"
    public var version = 1
    public var name: String
    public var servings: Int
    public var notes: String
    public var ingredients: [SharedRecipeIngredient]

    public init(format: String = "fernlet.recipe", version: Int = 1, name: String, servings: Int, notes: String, ingredients: [SharedRecipeIngredient]) {
        self.format = format
        self.version = version
        self.name = name
        self.servings = servings
        self.notes = notes
        self.ingredients = ingredients
    }
}

public nonisolated struct SharedRecipeIngredient: Codable, Equatable, Sendable {
    public var name: String
    public var quantity: Double
    public var unit: String
    public var protein: Int
    public var carbs: Int
    public var fat: Int

    public init(name: String, quantity: Double, unit: String, protein: Int, carbs: Int, fat: Int) {
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
    }
}

public nonisolated enum RecipeImportError: Error, Equatable {
    case missingPayload
    case invalidPayload
    case unsupportedFormat
    case emptyRecipe

    public var message: String {
        switch self {
        case .missingPayload:
            "I could not find Fernlet recipe data in that text."
        case .invalidPayload:
            "That recipe data is a little tangled. Paste the full shared recipe and try again."
        case .unsupportedFormat:
            "That recipe came from a format this Fernlet does not know yet."
        case .emptyRecipe:
            "That recipe needs a name and at least one ingredient."
        }
    }
}

public nonisolated struct ManualRecipeIngredientInput: Identifiable, Equatable {

    public init(id: UUID = UUID(), name: String = "", selectedFoodItemId: UUID? = nil, quantity: Double = 1, unit: String = "serving", protein: Int = 0, carbs: Int = 0, fat: Int = 0, scannedMicronutrients: Micronutrients? = nil, barcode: String? = nil) {
        self.id = id
        self.name = name
        self.selectedFoodItemId = selectedFoodItemId
        self.quantity = quantity
        self.unit = unit
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.scannedMicronutrients = scannedMicronutrients
        self.barcode = barcode
    }
    public var id = UUID()
    public var name: String = ""
    public var selectedFoodItemId: UUID?
    public var quantity: Double = 1
    public var unit: String = "serving"
    public var protein: Int = 0
    public var carbs: Int = 0
    public var fat: Int = 0
    public var scannedMicronutrients: Micronutrients?
    /// Product barcode to remember on the created/updated user food item (barcode-scan flow), so
    /// the next scan of the same code resolves instantly. Normalized at upsert time.
    public var barcode: String?

    public var macros: Macros {
        Macros(protein: protein, carbs: carbs, fat: fat)
    }

    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func resolvedMacros(foodItems: [FoodItem]) -> Macros {
        guard let selectedFoodItem = selectedFoodItem(in: foodItems) else { return macros }
        return RecipeIngredient(foodItemId: selectedFoodItem.id, quantity: quantity, unit: unit)
            .scaledMacros(using: selectedFoodItem)
    }

    public func selectedFoodItem(in foodItems: [FoodItem]) -> FoodItem? {
        guard let selectedFoodItemId else { return nil }
        return foodItems.first { $0.id == selectedFoodItemId }
    }
}

extension Macros {
    public func scaled(by scale: Double) -> Macros {
        let safeScale = max(scale, 0)
        return Macros(
            protein: Int((Double(protein) * safeScale).rounded()),
            carbs: Int((Double(carbs) * safeScale).rounded()),
            fat: Int((Double(fat) * safeScale).rounded())
        )
    }
}

extension FoodItem {
    public var preferredRecipeUnit: RecipeUnit {
        let nameText = FoodItemSearch.normalized(name)
        if nameText.contains("flour") {
            return .gram
        }
        if portion(for: .cup) != nil {
            return .cup
        }
        if portion(for: .each) != nil {
            return .each
        }
        if nameText.contains("oil") && portions.isEmpty {
            return RecipeUnit.normalized(servingUnit) == .milliliter ? .tablespoon : .cup
        }
        if servingUnit.caseInsensitiveCompare(RecipeUnit.gram.rawValue) == .orderedSame {
            return .gram
        }
        if RecipeUnit.normalized(servingUnit) == .milliliter {
            return .milliliter
        }
        return RecipeUnit.normalized(servingUnit) ?? .serving
    }

    public func defaultRecipeQuantity(for unit: RecipeUnit) -> Double {
        switch unit {
        case .gram:
            servingUnit.caseInsensitiveCompare(RecipeUnit.gram.rawValue) == .orderedSame ? servingSize : 1
        case .milliliter:
            RecipeUnit.normalized(servingUnit) == .milliliter ? servingSize : 1
        case .ounce, .pound, .cup, .tablespoon, .teaspoon, .each, .serving:
            1
        }
    }

    public func gramsEquivalent(quantity: Double, unit: String) -> Double? {
        let unit = RecipeUnit.normalized(unit)
        switch unit {
        case .gram:
            return quantity
        case .milliliter:
            return quantity
        case .ounce:
            if let portion = portion(for: .ounce) { return portion.grams(for: quantity) }
            return quantity * 28.3495
        case .pound:
            return quantity * 453.592
        case .cup:
            if let portion = portion(for: .cup) { return portion.grams(for: quantity) }
            return quantity * 240
        case .tablespoon:
            if let portion = portion(for: .tablespoon) { return portion.grams(for: quantity) }
            return quantity * 15
        case .teaspoon:
            if let portion = portion(for: .teaspoon) { return portion.grams(for: quantity) }
            return quantity * 5
        case .each:
            if let portion = portion(for: .each) { return portion.grams(for: quantity) }
            return nil
        case .serving:
            return nil
        case nil:
            return nil
        }
    }

    private func portion(for unit: RecipeUnit) -> FoodPortion? {
        portions.first { $0.recipeUnit == unit }
    }
}

extension FoodPortion {
    public var recipeUnit: RecipeUnit? {
        let normalizedUnit = FoodItemSearch.normalized(unit)
        let normalizedDescription = FoodItemSearch.normalized(description ?? "")
        switch normalizedUnit {
        case "g", "gram", "grams":
            return .gram
        case "ml", "milliliter", "milliliters", "millilitre", "millilitres":
            return .milliliter
        case "oz", "ounce", "ounces":
            return .ounce
        case "lb", "lbs", "pound", "pounds":
            return .pound
        case "cup", "cups":
            return .cup
        case "tbsp", "tablespoon", "tablespoons":
            return .tablespoon
        case "tsp", "teaspoon", "teaspoons":
            return .teaspoon
        default:
            if normalizedUnit == "unit" || normalizedUnit == "serving" || normalizedDescription.contains("large") || normalizedDescription.contains("medium") || normalizedDescription.contains("small") {
                return .each
            }
            return nil
        }
    }

    public func grams(for quantity: Double) -> Double {
        quantity * gramWeight / max(amount, 0.01)
    }
}

public nonisolated enum MealSource: String, Codable {
    case mealDefinition
    case recipe
    case manual
}

public nonisolated struct MacroTotals: Equatable {
    public var protein = 0
    public var carbs = 0
    public var fat = 0

    public init(protein: Int = 0, carbs: Int = 0, fat: Int = 0) {
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
    }

    public var calories: Int { protein * 4 + carbs * 4 + fat * 9 }
}

public nonisolated struct NutritionTargets: Equatable {

    public init(calories: Int, protein: Int, carbs: Int, fat: Int, fiber: Int, sodiumLimit: Int, saturatedFatLimit: Int) {
        self.calories = calories
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.fiber = fiber
        self.sodiumLimit = sodiumLimit
        self.saturatedFatLimit = saturatedFatLimit
    }
    public var calories: Int
    public var protein: Int
    public var carbs: Int
    public var fat: Int
    public var fiber: Int
    public var sodiumLimit: Int
    public var saturatedFatLimit: Int

    public var macroTotals: MacroTotals {
        MacroTotals(protein: protein, carbs: carbs, fat: fat)
    }
}

public nonisolated enum NutritionTargetCalculator {
    public static func targets(for settings: FernletSettings) -> NutritionTargets {
        let profile = settings.userProfile
        // A non-nil override pins the target; nil falls through to the derived value. `fat` derives from
        // the (possibly overridden) `calories`, and `carbs` below is the residual of all three, so
        // pinning any of these re-solves the rest. The four macros agree with the calorie total in the
        // normal case; when a user pins protein and fat high enough that they alone exceed ~70% of the
        // calorie target, the carbs floor below holds instead of going negative, so the totals sum a
        // little ABOVE the stated calories. Overrides only ever reach here as a positive integer (the
        // editor maps 0/blank → nil).
        let calories = settings.calorieTargetOverride ?? adjustedCalories(for: settings)
        let protein = settings.proteinTargetOverride ?? proteinTarget(for: settings)
        let fat = settings.fatTargetOverride ?? fatTarget(calories: calories, preferences: settings.nutritionPreferences)
        let proteinCalories = protein * 4
        let fatCalories = fat * 9
        let remainingCalories = max(calories - proteinCalories - fatCalories, Int(Double(calories) * 0.30))
        let carbs = max(Int((Double(remainingCalories) / 4).rounded()), 50)
        let fiber = max(Int((Double(calories) / 1_000 * 14).rounded()), profile.sex == .female ? 25 : 30)
        let saturatedFatLimit = Int((Double(calories) * 0.10 / 9).rounded())

        return NutritionTargets(
            calories: calories,
            protein: protein,
            carbs: carbs,
            fat: fat,
            fiber: fiber,
            sodiumLimit: 2_300,
            saturatedFatLimit: saturatedFatLimit
        )
    }

    private static func adjustedCalories(for settings: FernletSettings) -> Int {
        let profile = settings.userProfile
        let base = restingMetabolicRate(for: profile) * profile.activityLevel.multiplier
        let adjusted: Double
        switch settings.selectedGoal {
        case .weightManagement:
            adjusted = base * 0.88
        case .strength:
            adjusted = base * 1.08
        case .sportsPrep:
            adjusted = base * 1.05
        case .recovery:
            adjusted = base * 0.98
        case .wellness, .mentalHealth, .exploring:
            adjusted = base
        }
        return Int((adjusted / 25).rounded() * 25)
    }

    private static func restingMetabolicRate(for profile: UserNutritionProfile) -> Double {
        let sexAdjustment = profile.sex == .male ? 5.0 : -161.0
        return (10 * profile.weightKilograms) + (6.25 * profile.heightCentimeters) - (5 * Double(profile.age)) + sexAdjustment
    }

    private static func proteinTarget(for settings: FernletSettings) -> Int {
        let kilograms = settings.userProfile.weightKilograms
        let gramsPerKilogram: Double
        switch (settings.selectedGoal, settings.nutritionPreferences.dietaryPattern) {
        case (.strength, _):
            gramsPerKilogram = 1.7
        case (.sportsPrep, _):
            gramsPerKilogram = 1.6
        case (.weightManagement, _):
            gramsPerKilogram = 1.5
        case (_, .higherProtein):
            gramsPerKilogram = 1.4
        case (_, .plantForward):
            gramsPerKilogram = 1.1
        default:
            gramsPerKilogram = settings.userProfile.activityLevel == .sedentary ? 0.9 : 1.2
        }
        return Int((kilograms * gramsPerKilogram).rounded())
    }

    private static func fatTarget(calories: Int, preferences: UserNutritionPreferences) -> Int {
        let percent: Double
        switch preferences.dietaryPattern {
        case .lowerCarb:
            percent = 0.35
        case .higherProtein:
            percent = 0.27
        case .balanced, .plantForward:
            percent = 0.30
        }
        return Int((Double(calories) * percent / 9).rounded())
    }
}

public nonisolated enum MealType: String, Codable, CaseIterable, Identifiable, Sendable {
    case breakfast = "Breakfast"
    case lunch = "Lunch"
    case dinner = "Dinner"
    case snack = "Snack"
    case preWorkout = "Pre-workout"
    case postWorkout = "Post-workout"

    public var id: String { rawValue }
}

public nonisolated enum MealQuality: String, Codable, CaseIterable {
    case great, good, ok, low
}
