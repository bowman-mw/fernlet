// NutritionModels.swift
// Split out of Models.swift (SPM carve-up §5c). Nutrition, food, meal, recipe, and macro/micronutrient models.

import Foundation

struct UserNutritionProfile: Codable, Equatable {
    var age: Int = 30
    var weightPounds: Double = 170
    var heightInches: Double = 68
    var sex: BiologicalSex = .male
    var activityLevel: ActivityLevel = .moderate

    var weightKilograms: Double { weightPounds / 2.20462 }
    var heightCentimeters: Double { heightInches * 2.54 }
}

struct UserNutritionPreferences: Codable, Equatable {
    var dietaryPattern: DietaryPattern = .balanced
    var guidanceIntensity: GuidanceIntensity = .steady
}

enum BiologicalSex: String, Codable, CaseIterable, Identifiable {
    case female
    case male

    var id: String { rawValue }

    var label: String {
        switch self {
        case .female: "Female"
        case .male: "Male"
        }
    }
}

enum ActivityLevel: String, Codable, CaseIterable, Identifiable {
    case sedentary
    case light
    case moderate
    case active
    case veryActive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sedentary: "Sedentary"
        case .light: "Light"
        case .moderate: "Moderate"
        case .active: "Active"
        case .veryActive: "Very active"
        }
    }

    var multiplier: Double {
        switch self {
        case .sedentary: 1.2
        case .light: 1.375
        case .moderate: 1.55
        case .active: 1.725
        case .veryActive: 1.9
        }
    }
}

enum DietaryPattern: String, Codable, CaseIterable, Identifiable {
    case balanced
    case higherProtein
    case plantForward
    case lowerCarb

    var id: String { rawValue }

    var label: String {
        switch self {
        case .balanced: "Balanced"
        case .higherProtein: "Higher protein"
        case .plantForward: "Plant-forward"
        case .lowerCarb: "Lower carb"
        }
    }
}

enum GuidanceIntensity: String, Codable, CaseIterable, Identifiable {
    case gentle
    case steady
    case detailed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gentle: "Gentle"
        case .steady: "Steady"
        case .detailed: "Detailed"
        }
    }
}

struct MealComponentSnapshot: Identifiable, Codable, Equatable {
    var id = UUID()
    var foodItemId: UUID?
    var name: String
    var quantity: Double
    var unit: String
    var macros: Macros
    var micronutrients: Micronutrients

    init(
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

struct Meal: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var mealType: MealType
    var macros: Macros
    var macroSnapshot: Macros
    var calorieSnapshot: Int
    var micronutrientSnapshot: Micronutrients
    var componentSnapshots: [MealComponentSnapshot]
    var mealSource: MealSource = .manual
    var isAIFallback: Bool = true
    var quality: MealQuality
    var confidence: String
    var note: String
    var source: String
    var loggedAt = Date()
    var photoID: UUID?

    var calories: Int {
        macros.protein * 4 + macros.carbs * 4 + macros.fat * 9
    }

    func copyForToday() -> Meal {
        var copy = self
        copy.id = UUID()
        copy.loggedAt = .now
        copy.photoID = nil
        return copy
    }

    init(
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        mealType = try container.decode(MealType.self, forKey: .mealType)
        macros = try container.decode(Macros.self, forKey: .macros)
        macroSnapshot = try container.decodeIfPresent(Macros.self, forKey: .macroSnapshot) ?? macros
        calorieSnapshot = try container.decodeIfPresent(Int.self, forKey: .calorieSnapshot) ?? Self.calories(for: macroSnapshot)
        micronutrientSnapshot = try container.decodeIfPresent(Micronutrients.self, forKey: .micronutrientSnapshot) ?? Micronutrients()
        componentSnapshots = try container.decodeIfPresent([MealComponentSnapshot].self, forKey: .componentSnapshots) ?? []
        mealSource = try container.decodeIfPresent(MealSource.self, forKey: .mealSource) ?? .manual
        isAIFallback = try container.decodeIfPresent(Bool.self, forKey: .isAIFallback) ?? true
        quality = try container.decode(MealQuality.self, forKey: .quality)
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
enum MealResolutionConfidence: String, Codable {
    case high
    case medium
    case low

    var mealLabel: String {
        switch self {
        case .high: "Food match"
        case .medium: "Estimated"
        case .low: "Rough estimate"
        }
    }

    /// Low-confidence resolutions are routed through a pre-log review sheet instead of auto-committing.
    var needsReview: Bool { self == .low }

    var rank: Int {
        switch self {
        case .high: 2
        case .medium: 1
        case .low: 0
        }
    }

    static func fromRank(_ rank: Int) -> MealResolutionConfidence {
        if rank >= 2 { return .high }
        if rank == 1 { return .medium }
        return .low
    }

    /// One step less confident (high -> medium -> low), floored at `.low`.
    var lowered: MealResolutionConfidence { Self.fromRank(rank - 1) }

    /// The more pessimistic of two confidences.
    static func combine(_ lhs: MealResolutionConfidence, _ rhs: MealResolutionConfidence) -> MealResolutionConfidence {
        fromRank(min(lhs.rank, rhs.rank))
    }

    /// Parses the model's free-text confidence word; defaults to `.medium` when absent/unrecognised.
    static func fromModelWord(_ word: String) -> MealResolutionConfidence {
        let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("high") { return .high }
        if normalized.contains("low") { return .low }
        return .medium
    }
}

/// A meal produced by the resolver together with how much to trust it.
struct ResolvedMeal {
    var meal: Meal
    var confidence: MealResolutionConfidence
}

/// The full outcome of resolving a quick-log description: the meals (not yet committed), any
/// recipes that were created as a side effect, overall confidence, and whether the keyword-heuristic
/// fallback was used. `needsReview` decides whether the UI pauses for a pre-log review.
struct MealResolution {
    var meals: [Meal]
    var createdRecipes: [RecipeDefinition]
    var confidence: MealResolutionConfidence
    var isFallback: Bool

    var needsReview: Bool { confidence.needsReview || isFallback }
}

struct Macros: Codable, Equatable {
    var protein: Int
    var carbs: Int
    var fat: Int

    var calories: Int { protein * 4 + carbs * 4 + fat * 9 }
}

struct Micronutrients: Codable, Equatable {
    var fiber: Double?
    var sugar: Double?
    var saturatedFat: Double?
    var cholesterol: Double?
    var vitaminA: Double?
    var vitaminC: Double?
    var vitaminD: Double?
    var vitaminE: Double?
    var vitaminK: Double?
    var vitaminB6: Double?
    var vitaminB12: Double?
    var thiamin: Double?
    var riboflavin: Double?
    var niacin: Double?
    var folate: Double?
    var calcium: Double?
    var iron: Double?
    var magnesium: Double?
    var phosphorus: Double?
    var potassium: Double?
    var sodium: Double?
    var zinc: Double?
    var omega3: Double?

    nonisolated init(
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

    init(from decoder: Decoder) throws {
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
    static var totalFieldCount: Int { 23 }

    static func totals(for meals: [Meal]) -> Micronutrients {
        meals.reduce(into: Micronutrients()) { partial, meal in
            partial.add(meal.micronutrientSnapshot)
        }
    }

    var populatedFieldCount: Int {
        [
            fiber, sugar, saturatedFat, cholesterol,
            vitaminA, vitaminC, vitaminD, vitaminE, vitaminK, vitaminB6, vitaminB12,
            thiamin, riboflavin, niacin, folate,
            calcium, iron, magnesium, phosphorus, potassium, sodium, zinc, omega3
        ].compactMap { $0 }.count
    }

    var totalFieldCount: Int { Self.totalFieldCount }

    var completeness: Double {
        guard totalFieldCount > 0 else { return 0 }
        return Double(populatedFieldCount) / Double(totalFieldCount)
    }

    var hasAnyValue: Bool {
        fiber != nil || sugar != nil || saturatedFat != nil || cholesterol != nil ||
        vitaminA != nil || vitaminC != nil || vitaminD != nil || vitaminE != nil ||
        vitaminK != nil || vitaminB6 != nil || vitaminB12 != nil || thiamin != nil ||
        riboflavin != nil || niacin != nil || folate != nil || calcium != nil ||
        iron != nil || magnesium != nil || phosphorus != nil || potassium != nil ||
        sodium != nil || zinc != nil || omega3 != nil
    }

    func scaled(by scale: Double) -> Micronutrients {
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

    mutating func add(_ other: Micronutrients) {
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

enum NutrientGapStatus: String, Codable, Equatable {
    case covered
    case gap
}

struct NutrientGap: Identifiable, Codable, Equatable {
    var nutrientKey: String
    var nutrientName: String
    var unit: String
    var windowDays: Int
    var coverageRatio: Double
    var dataCoverageRatio: Double
    var status: NutrientGapStatus

    var id: String {
        "\(nutrientKey)-\(windowDays)-\(status.rawValue)"
    }
}

struct NutrientReference {
    var key: String
    var name: String
    var unit: String
    var recommendedDailyAmount: Double
    var value: (Micronutrients) -> Double?
}

enum MicronutrientGapAnalyzer {
    static let trackedNutrients: [NutrientReference] = [
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

    static func gaps(from days: [(String, FernletDay)], windowDays: Int) -> [NutrientGap] {
        assert(windowDays > 0, "window must be positive")
        let window = Array(days.suffix(windowDays))
        let meals = window.flatMap { $0.1.meals.prefix(20) }
        guard meals.isEmpty == false else { return [] }
        guard FernletScoring.micronutrientDataCoverageRatio(for: meals) >= 0.5 else { return [] }

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

enum FoodDataType: String, Codable {
    case foundation   // USDA Foundation Foods
    case survey       // USDA/FNDDS survey foods
    case srLegacy     // USDA SR Legacy reference
    case branded      // Commercial/branded product
    case restaurant   // Restaurant chain item
}

enum FoodItemSource: String, Codable {
    case usda
    case aiResolved
    case manual
}

enum MealLogSource {
    static let manual = "manual"
    static let labelScan = "label-scan"
    static let usdaRecipe = "usda-recipe"
    static let webImport = "web-import"
    static let foundationModel = "foundation-model"
    static let foundationModelFoodSelection = "foundation-model-food-selection"
}

struct FoodItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var brandSource: String?
    var servingSize: Double
    var servingUnit: String
    var macros: Macros
    var micronutrients: Micronutrients
    var category: String
    var source: FoodItemSource
    var dataType: FoodDataType = .srLegacy
    var sourceURL: URL?
    var servingDescription: String?
    var verificationPolicyDays: Int = 180
    var lastVerified: Date?
    var isFlagged: Bool = false
    var tags: [String]
    var portions: [FoodPortion]

    var calories: Int {
        macros.protein * 4 + macros.carbs * 4 + macros.fat * 9
    }

    /// Short, human-readable provenance shown on ingredient-search rows so the user can tell where a
    /// match came from (Item 3 ingredient-search UX). Branded/restaurant items prefer their brand
    /// name; reference USDA foods read "USDA"; user and AI-derived foods are labelled distinctly.
    var dataSourceLabel: String {
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

    nonisolated init(
        id: UUID = UUID(),
        name: String,
        brandSource: String?,
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
        portions: [FoodPortion] = []
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        brandSource = try container.decodeIfPresent(String.self, forKey: .brandSource)
        servingSize = try container.decode(Double.self, forKey: .servingSize)
        servingUnit = try container.decode(String.self, forKey: .servingUnit)
        macros = try container.decode(Macros.self, forKey: .macros)
        micronutrients = try container.decodeIfPresent(Micronutrients.self, forKey: .micronutrients) ?? Micronutrients()
        category = try container.decode(String.self, forKey: .category)
        source = try container.decode(FoodItemSource.self, forKey: .source)
        dataType = try container.decodeIfPresent(FoodDataType.self, forKey: .dataType) ?? .srLegacy
        sourceURL = try container.decodeIfPresent(URL.self, forKey: .sourceURL)
        servingDescription = try container.decodeIfPresent(String.self, forKey: .servingDescription)
        verificationPolicyDays = try container.decodeIfPresent(Int.self, forKey: .verificationPolicyDays) ?? 180
        lastVerified = try container.decodeIfPresent(Date.self, forKey: .lastVerified)
        isFlagged = try container.decodeIfPresent(Bool.self, forKey: .isFlagged) ?? false
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        portions = try container.decodeIfPresent([FoodPortion].self, forKey: .portions) ?? []
    }
}

struct FoodPortion: Codable, Equatable {
    var amount: Double
    var unit: String
    var gramWeight: Double
    var description: String?
}

struct FoodSelectionCandidate: Identifiable, Equatable {
    var id: Int
    var foodItem: FoodItem

    var promptLine: String {
        let brand = foodItem.brandSource.map { " \($0)" } ?? ""
        return "\(id). \(foodItem.name)\(brand) - \(foodItem.category), serving \(String(format: "%g", foodItem.servingSize)) \(foodItem.servingUnit), P\(foodItem.macros.protein) C\(foodItem.macros.carbs) F\(foodItem.macros.fat)"
    }
}

struct FoodSelectionIngredient: Identifiable, Equatable {
    var id = UUID()
    var candidateId: Int
    var foodName: String
    var quantity: Double
    var unit: String
}

struct FoodSelectionMealItem: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var ingredients: [FoodSelectionIngredient]
}

struct FoodSelectionPlan: Equatable {
    var mealName: String
    var mealType: MealType
    var items: [FoodSelectionMealItem]

    var ingredients: [FoodSelectionIngredient] {
        items.flatMap(\.ingredients)
    }
}

enum MealItemSplitter {
    static func items(from description: String) -> [String] {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }
        let normalized = trimmed
            .replacingOccurrences(of: " & ", with: " and ")
            .replacingOccurrences(of: ",", with: " and ")
            .replacingOccurrences(of: ";", with: " and ")
            .replacingOccurrences(of: " plus ", with: " and ", options: [.caseInsensitive])
            .replacingOccurrences(of: " with ", with: " and ", options: [.caseInsensitive])
        let pieces = normalized
            .components(separatedBy: " and ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { $0.count >= 3 }
        return pieces.isEmpty ? [trimmed] : pieces
    }
}

enum FoodSelectionCandidateBuilder {
    static func candidates(for description: String, foodItems: [FoodItem], limit: Int = 18) -> [FoodSelectionCandidate] {
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

        return selected.enumerated().map { offset, foodItem in
            FoodSelectionCandidate(id: offset + 1, foodItem: foodItem)
        }
    }

    /// Splits a meal description into overlapping search phrases (3-, 2-, then 1-word), longest first.
    /// Shared with `FoodCatalog.candidates(for:)` so the SQLite-backed candidate set matches the
    /// in-memory array path.
    static func searchPhrases(from description: String) -> [String] {
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

struct RecipeIngredient: Identifiable, Codable, Equatable {
    var id = UUID()
    var foodItemId: UUID
    var quantity: Double
    var unit: String
}

enum RecipeUnit: String, CaseIterable, Identifiable {
    case gram = "g"
    case milliliter = "ml"
    case ounce = "oz"
    case pound = "lb"
    case cup = "cup"
    case tablespoon = "tbsp"
    case teaspoon = "tsp"
    case each = "each"
    case serving = "serving"

    var id: String { rawValue }

    var label: String {
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

    static func normalized(_ unit: String) -> RecipeUnit? {
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

    func scaledMacros(using foodItem: FoodItem) -> Macros {
        foodItem.macros.scaled(by: scale(using: foodItem))
    }

    func scaledMicronutrients(using foodItem: FoodItem) -> Micronutrients {
        foodItem.micronutrients.scaled(by: scale(using: foodItem))
    }
}

/// Extra fields a recipe carries only when it was imported from a web URL (e.g. via the share
/// extension or pasteboard). User-built recipes leave this nil and derive nutrition from their
/// structured `ingredients`; web-imported recipes keep their free-text ingredient lines and the
/// precomputed nutrition extracted at import time, because those ingredients can't be resolved to
/// `foodItemId`s without ambiguity. Bundling them here keeps `RecipeDefinition` the single recipe
/// model while preserving the original imported data losslessly.
struct RecipeWebImport: Codable, Equatable {
    var sourceURLString: String
    var ingredientLines: [String]
    var macros: Macros
    var micronutrients: Micronutrients

    var sourceURL: URL {
        URL(string: sourceURLString) ?? URL(fileURLWithPath: "/")
    }

    init(
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceURLString = try container.decodeIfPresent(String.self, forKey: .sourceURLString) ?? ""
        ingredientLines = try container.decodeIfPresent([String].self, forKey: .ingredientLines) ?? []
        macros = try container.decodeIfPresent(Macros.self, forKey: .macros) ?? Macros(protein: 0, carbs: 0, fat: 0)
        micronutrients = try container.decodeIfPresent(Micronutrients.self, forKey: .micronutrients) ?? Micronutrients()
    }
}

struct RecipeDefinition: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var servings: Int
    var ingredients: [RecipeIngredient]
    var notes: String
    var source: String
    var createdAt: Date
    var updatedAt: Date
    /// Non-nil only for recipes imported from a web URL. See `RecipeWebImport`.
    var webImport: RecipeWebImport?

    /// True when this recipe was imported from the web (and therefore stores free-text ingredient
    /// lines + precomputed nutrition rather than structured `ingredients`).
    var isWebImport: Bool { webImport != nil }

    init(
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

    init(from decoder: Decoder) throws {
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

struct SharedRecipePayload: Codable, Equatable {
    var format = "fernlet.recipe"
    var version = 1
    var name: String
    var servings: Int
    var notes: String
    var ingredients: [SharedRecipeIngredient]
}

struct SharedRecipeIngredient: Codable, Equatable {
    var name: String
    var quantity: Double
    var unit: String
    var protein: Int
    var carbs: Int
    var fat: Int
}

enum RecipeImportError: Error, Equatable {
    case missingPayload
    case invalidPayload
    case unsupportedFormat
    case emptyRecipe

    var message: String {
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

struct ManualRecipeIngredientInput: Identifiable, Equatable {
    var id = UUID()
    var name: String = ""
    var selectedFoodItemId: UUID?
    var quantity: Double = 1
    var unit: String = "serving"
    var protein: Int = 0
    var carbs: Int = 0
    var fat: Int = 0
    var scannedMicronutrients: Micronutrients?

    var macros: Macros {
        Macros(protein: protein, carbs: carbs, fat: fat)
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func resolvedMacros(foodItems: [FoodItem]) -> Macros {
        guard let selectedFoodItem = selectedFoodItem(in: foodItems) else { return macros }
        return RecipeIngredient(foodItemId: selectedFoodItem.id, quantity: quantity, unit: unit)
            .scaledMacros(using: selectedFoodItem)
    }

    func selectedFoodItem(in foodItems: [FoodItem]) -> FoodItem? {
        guard let selectedFoodItemId else { return nil }
        return foodItems.first { $0.id == selectedFoodItemId }
    }
}

extension Macros {
    func scaled(by scale: Double) -> Macros {
        let safeScale = max(scale, 0)
        return Macros(
            protein: Int((Double(protein) * safeScale).rounded()),
            carbs: Int((Double(carbs) * safeScale).rounded()),
            fat: Int((Double(fat) * safeScale).rounded())
        )
    }
}

extension FoodItem {
    var preferredRecipeUnit: RecipeUnit {
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

    func defaultRecipeQuantity(for unit: RecipeUnit) -> Double {
        switch unit {
        case .gram:
            servingUnit.caseInsensitiveCompare(RecipeUnit.gram.rawValue) == .orderedSame ? servingSize : 1
        case .milliliter:
            RecipeUnit.normalized(servingUnit) == .milliliter ? servingSize : 1
        case .ounce, .pound, .cup, .tablespoon, .teaspoon, .each, .serving:
            1
        }
    }

    func gramsEquivalent(quantity: Double, unit: String) -> Double? {
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
    var recipeUnit: RecipeUnit? {
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

    func grams(for quantity: Double) -> Double {
        quantity * gramWeight / max(amount, 0.01)
    }
}

enum MealSource: String, Codable {
    case mealDefinition
    case recipe
    case manual
}

struct MacroTotals: Equatable {
    var protein = 0
    var carbs = 0
    var fat = 0

    var calories: Int { protein * 4 + carbs * 4 + fat * 9 }
}

struct NutritionTargets: Equatable {
    var calories: Int
    var protein: Int
    var carbs: Int
    var fat: Int
    var fiber: Int
    var sodiumLimit: Int
    var saturatedFatLimit: Int

    var macroTotals: MacroTotals {
        MacroTotals(protein: protein, carbs: carbs, fat: fat)
    }
}

enum NutritionTargetCalculator {
    static func targets(for settings: FernletSettings) -> NutritionTargets {
        let profile = settings.userProfile
        let calories = adjustedCalories(for: settings)
        let protein = proteinTarget(for: settings)
        let fat = fatTarget(calories: calories, preferences: settings.nutritionPreferences)
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

enum MealType: String, Codable, CaseIterable, Identifiable {
    case breakfast = "Breakfast"
    case lunch = "Lunch"
    case dinner = "Dinner"
    case snack = "Snack"
    case preWorkout = "Pre-workout"
    case postWorkout = "Post-workout"

    var id: String { rawValue }
}

enum MealQuality: String, Codable, CaseIterable {
    case great, good, ok, low
}
