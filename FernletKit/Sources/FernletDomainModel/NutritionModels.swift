// NutritionModels.swift
// Split out of Models.swift (SPM carve-up §5c). Nutrition, food, meal, recipe, and macro/micronutrient models.

import Foundation

/// The user's body profile (age, weight, height, sex, activity) that drives calorie and macro
/// targets.
///
/// A top-level field of ``FernletSettings`` in the synced blob: the numeric fields decode STRICTLY
/// (fabricated defaults would silently mis-guide targets) while the enums decode tolerantly with
/// parked tokens (``EnumDecodeCompat``). `sex` may be auto-assigned from HealthKit once per launch,
/// which deliberately clears any parked token — Health is the local authority for that field.
public nonisolated struct UserNutritionProfile: Codable, Equatable {

    /// Sane bounds for the body-profile numbers (R5).
    ///
    /// `NutritionTargetCalculator` converts these through `Int(_: Double)`, which TRAPS on a
    /// non-finite or out-of-range value, so an absurd weight typed into the editor — or arriving in
    /// a corrupt/foreign synced blob — must be clamped at the boundary, not carried into the math.
    public static let ageRange: ClosedRange<Int> = 5...120
    public static let weightPoundsRange: ClosedRange<Double> = 40...1500
    public static let heightInchesRange: ClosedRange<Double> = 24...108

    public init(age: Int = 30, weightPounds: Double = 170, heightInches: Double = 68, sex: BiologicalSex = .male, activityLevel: ActivityLevel = .moderate) {
        self.age = min(max(age, Self.ageRange.lowerBound), Self.ageRange.upperBound)
        self.weightPounds = Self.clamped(weightPounds, to: Self.weightPoundsRange, default: 170)
        self.heightInches = Self.clamped(heightInches, to: Self.heightInchesRange, default: 68)
        self.sex = sex
        self.activityLevel = activityLevel
    }

    /// Clamps a body measurement into `range`, mapping a non-finite value to `fallback`.
    private static func clamped(_ value: Double, to range: ClosedRange<Double>, default fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
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
        // A PRESENT value is still clamped to its sane range (R5): the editor's "only positive,
        // plausible numbers" invariant is not a decode guarantee, and these feed trapping `Int()`
        // conversions in `NutritionTargetCalculator`.
        let decodedAge = try c.decode(Int.self, forKey: .age)
        age = min(max(decodedAge, Self.ageRange.lowerBound), Self.ageRange.upperBound)
        weightPounds = Self.clamped(try c.decode(Double.self, forKey: .weightPounds),
                                    to: Self.weightPoundsRange, default: 170)
        heightInches = Self.clamped(try c.decode(Double.self, forKey: .heightInches),
                                    to: Self.heightInchesRange, default: 68)
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

/// Eating-pattern and guidance-intensity preferences feeding the nutrition targets.
///
/// Same synced-settings tolerant-decode contract as ``UserNutritionProfile``
/// (``EnumDecodeCompat``): unknown pattern/intensity tokens freeze to the defaults and park.
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

/// Biological sex used for resting-metabolic-rate and fiber-target math.
///
/// Also the derivation input for default period-surface visibility when the user has made no
/// explicit choice (see ``FernletSettings``' `periodTrackingVisible`).
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

/// Self-reported activity level; `multiplier` scales resting metabolic rate into a calorie target.
///
/// Also feeds the workout split recommender's specificity and session-tolerance scoring.
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

/// The eating pattern that biases macro splits (balanced, higher-protein, plant-forward,
/// lower-carb).
///
/// Consumed by ``NutritionTargetCalculator`` for protein grams-per-kilogram and fat percentages.
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

/// How detailed the nutrition guidance copy should be (gentle, steady, detailed).
///
/// A tone preference only — it never changes any computed number.
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

/// One ingredient's contribution frozen into a logged meal (name, quantity, macros, micros).
///
/// Snapshotted at log time so later edits to the catalog food never rewrite a past meal's numbers;
/// `foodItemId` is kept so the correction flow can re-bind against the catalog.
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

/// One logged meal with its macro/micronutrient snapshots and provenance.
///
/// Lives both in the blob's top-level `recentMeals` AND inside each ``FernletDay``, so every enum
/// field (`mealType`, `mealSource`, `quality`) decodes tolerantly with parked tokens
/// (``EnumDecodeCompat``). The `*Snapshot` fields freeze the numbers as logged; `isAIFallback` and
/// `confidence` record how trustworthy the resolution was, and `source` carries the free-string
/// ``MealLogSource`` provenance token. `copyForToday(mealType:)` re-logs a past meal under a fresh
/// identity.
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

    /// The FROZEN provenance token — how this row got its numbers.
    ///
    /// Stays a free-form `String` rather than becoming a `MealConfidence` so the on-disk schema is
    /// unchanged and a stamp from a newer build survives a round trip through this one untouched
    /// (the same posture as the parked enum tokens above, achieved here for free by never narrowing
    /// the type). Write ``MealConfidence/token``; READ ``confidenceLabel`` — this string is storage,
    /// not text, and until the Phase 1 fork it was both.
    public var confidence: String
    public var note: String
    public var source: String
    public var loggedAt = Date()
    public var photoID: UUID?

    public var calories: Int {
        macros.calories
    }

    /// ``confidence`` resolved to a case, or nil when the stored string is one this build has no
    /// stamp for (a newer build's, or a hand-edited row).
    public var confidenceToken: MealConfidence? {
        MealConfidence(persistedToken: confidence)
    }

    /// The localized provenance text for the meal row — the ONLY thing that should be shown.
    ///
    /// Falls back to the raw stored string when the token is unrecognised. That is deliberate and
    /// matches the file's existing tolerant-decode posture: showing a stamp this build cannot name
    /// is honest, whereas blanking it or substituting a default would quietly misreport where the
    /// numbers came from.
    public var confidenceLabel: String {
        confidenceToken?.label ?? confidence
    }

    /// Re-logs this meal on today under a fresh identity.
    ///
    /// The copy is a NEW log, not a duplicate of the old row: the caller's `mealType` (the log
    /// sheet's explicit choice, or the same time-of-day classification a typed log's "Auto" rule
    /// produces) files it in the right slot instead of inheriting the source meal's — repeating a
    /// yogurt bowl at 7:35 PM filed it under Breakfast. The source `note` is dropped for the same
    /// reason: it described THAT logging ("Estimated locally from the description.", a seeded demo
    /// note) and attributing it to a meal the user never wrote is a small lie. `confidence` becomes
    /// ``MealConfidence/repeated`` — this row is as trustworthy as the one it copies, and says how
    /// it got here.
    ///
    /// - Parameter mealType: The slot to file the copy under; `nil` keeps the source meal's slot.
    public func copyForToday(mealType: MealType? = nil) -> Meal {
        var copy = self
        copy.id = UUID()
        copy.loggedAt = .now
        copy.photoID = nil
        if let mealType { copy.mealType = mealType }
        copy.note = ""
        copy.confidence = MealConfidence.repeated.token
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
        self.calorieSnapshot = calorieSnapshot ?? (macroSnapshot ?? macros).calories
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
        calorieSnapshot = try container.decodeIfPresent(Int.self, forKey: .calorieSnapshot) ?? macroSnapshot.calories
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
}

/// The provenance stamp on a logged meal — how this row got its numbers.
///
/// `Meal.confidence` is a free-form `String` on disk and has been since the first build, and what
/// five different writers put in it was the finished English sentence fragment the meal row shows
/// ("Estimated", "Food match", "Scanned label"). One string, two jobs: the persisted provenance
/// record and the on-screen text.
///
/// This type is the fork. ``token`` is what persists — a stable, English-forever identifier — and
/// ``label`` is the only thing a person reads. Because nothing in the codebase has ever COMPARED
/// `Meal.confidence` against anything, changing the stored characters is safe exactly now; once a
/// later phase adds an `==` it stops being safe, which is why the change is made here rather than
/// deferred.
///
/// Cross-version note: a row this build writes carries the new token, and an OLDER build reading
/// the shared blob renders `confidence` verbatim — so it shows "scannedLabel" where it used to show
/// "Scanned label". Cosmetic and confined to the mixed-version window; the alternative (freezing
/// the English phrases as the tokens) would have kept an English display string as the storage
/// format forever, which is the thing this whole phase exists to stop.
public nonisolated enum MealConfidence: String, Codable, CaseIterable, Sendable {
    case estimated
    case repeated
    case reviewed
    case corrected
    case foodMatch
    case roughEstimate
    case recipe
    /// A saved recipe with no macro data behind it — the numbers are structure, not nutrition.
    /// Distinct from ``recipe`` because the honest thing to show is that the recipe carried nothing
    /// to compute from, not that the row is recipe-backed and therefore trustworthy.
    case recipeNoMacros
    case logged
    case savedProduct
    case scannedProduct
    case scannedLabel
    case suggestedFood

    /// The FROZEN persisted value. Write this into `Meal.confidence`; never write ``label``.
    public var token: String { rawValue }

    /// FROZEN legacy spellings — the exact English phrases the pre-fork writers persisted, which
    /// are sitting in every existing user's blob today. Read-only compatibility: new writes always
    /// use ``token``. Never edit or remove a line; a row that stops resolving here loses its
    /// provenance stamp and falls back to showing the raw stored characters.
    private static let legacyTokens: [String: MealConfidence] = [
        "Estimated": .estimated,
        "Repeated": .repeated,
        "Reviewed": .reviewed,
        "Corrected": .corrected,
        "Food match": .foodMatch,
        "Rough estimate": .roughEstimate,
        "Recipe": .recipe,
        "Recipe (no macros)": .recipeNoMacros,
        "Logged": .logged,
        "Saved product": .savedProduct,
        "Scanned product": .scannedProduct,
        "Scanned label": .scannedLabel,
        "Suggested food": .suggestedFood,
    ]

    /// Resolves a persisted `Meal.confidence` string — new token or legacy English phrase — to a
    /// case, or nil for anything else.
    ///
    /// nil is a real answer, not a failure: the field is free-form and a future writer (or a newer
    /// build's stamp arriving over sync) may legitimately put something here this build has no case
    /// for. ``Meal/confidenceLabel`` shows the raw string in that event rather than inventing a
    /// stamp, on the same principle as the parked-token decodes elsewhere in this file.
    public init?(persistedToken: String) {
        if let exact = MealConfidence(rawValue: persistedToken) {
            self = exact
            return
        }
        guard let legacy = Self.legacyTokens[persistedToken] else { return nil }
        self = legacy
    }

    /// The localized provenance text on the meal row. Display only — never persist this.
    public var label: String {
        switch self {
        case .estimated: String(localized: "meal.confidence.estimated", defaultValue: "Estimated",
                                bundle: .module, comment: "Meal provenance: macros were estimated, not matched")
        case .repeated: String(localized: "meal.confidence.repeated", defaultValue: "Repeated",
                               bundle: .module, comment: "Meal provenance: re-logged from an earlier meal")
        case .reviewed: String(localized: "meal.confidence.reviewed", defaultValue: "Reviewed",
                               bundle: .module, comment: "Meal provenance: the user confirmed the numbers")
        case .corrected: String(localized: "meal.confidence.corrected", defaultValue: "Corrected",
                                bundle: .module, comment: "Meal provenance: the user edited the numbers")
        case .foodMatch: String(localized: "meal.confidence.foodMatch", defaultValue: "Food match",
                                bundle: .module, comment: "Meal provenance: matched a known food in the catalog")
        case .roughEstimate: String(localized: "meal.confidence.roughEstimate", defaultValue: "Rough estimate",
                                    bundle: .module, comment: "Meal provenance: a low-confidence guess")
        case .recipe: String(localized: "meal.confidence.recipe", defaultValue: "Recipe",
                             bundle: .module, comment: "Meal provenance: logged from a saved recipe")
        case .recipeNoMacros: String(localized: "meal.confidence.recipeNoMacros", defaultValue: "Recipe (no macros)",
                                     bundle: .module, comment: "Meal provenance: a saved recipe that carried no nutrition data")
        case .logged: String(localized: "meal.confidence.logged", defaultValue: "Logged",
                             bundle: .module, comment: "Meal provenance: entered directly by the user")
        case .savedProduct: String(localized: "meal.confidence.savedProduct", defaultValue: "Saved product",
                                   bundle: .module, comment: "Meal provenance: logged from a previously saved product")
        case .scannedProduct: String(localized: "meal.confidence.scannedProduct", defaultValue: "Scanned product",
                                     bundle: .module, comment: "Meal provenance: logged from a barcode scan")
        case .scannedLabel: String(localized: "meal.confidence.scannedLabel", defaultValue: "Scanned label",
                                   bundle: .module, comment: "Meal provenance: logged from a nutrition-label scan")
        case .suggestedFood: String(localized: "meal.confidence.suggestedFood", defaultValue: "Suggested food",
                                    bundle: .module, comment: "Meal provenance: added from a nutrient nudge")
        }
    }
}

/// How much to trust a resolved meal. Drives the honest label on the meal row and whether the
/// quick-log flow pauses for a pre-log review before committing a fabricated / low-confidence result.
public nonisolated enum MealResolutionConfidence: String, Codable {
    case high
    case medium
    case low

    /// The provenance stamp a resolution at this confidence writes onto the meal.
    public var mealConfidence: MealConfidence {
        switch self {
        case .high: .foodMatch
        case .medium: .estimated
        case .low: .roughEstimate
        }
    }

    /// MISNAMED — this is a persisted TOKEN, not a label.
    ///
    /// Every caller feeds it straight into `Meal.confidence`, so it was never display text; the
    /// name is a fossil from when `Meal.confidence` held the finished English phrase. Kept as a
    /// forwarder so the fork does not have to reach outside this module, but new code should call
    /// ``mealConfidence`` and take `.token` from it, and the remaining call site should be
    /// repointed. To SHOW a stamp, read `Meal.confidenceLabel`.
    public var mealLabel: String { mealConfidence.token }

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

/// A meal produced by the resolver together with how much to trust it, and — for the dish-
/// decomposition tier — the multi-ingredient recipe the resolver built along the way. The recipe is
/// carried (never auto-persisted): it is OFFERED in the pre-log review sheet and minted only if the
/// user confirms, so it never silently pollutes the recipe book (F1(a); AI-Feature-Expansion §2.5).
public nonisolated struct ResolvedMeal {

    public init(meal: Meal, confidence: MealResolutionConfidence, suggestedRecipe: RecipeDefinition? = nil) {
        self.meal = meal
        self.confidence = confidence
        self.suggestedRecipe = suggestedRecipe
    }
    public var meal: Meal
    public var confidence: MealResolutionConfidence
    /// The recipe the decomposition tier built from the same catalog-bound ingredients as `meal`,
    /// scaled to a default yield — offered for review, not committed. `nil` for tiers that build no
    /// recipe (single-ingredient decompositions, the keyword fallback).
    public var suggestedRecipe: RecipeDefinition?
}

/// The full outcome of resolving a quick-log description: the meals (not yet committed), any
/// recipes that were created as a side effect, overall confidence, and whether the keyword-heuristic
/// fallback was used. `needsReview` decides whether the UI pauses for a pre-log review.
public nonisolated struct MealResolution {

    public init(
        meals: [Meal],
        createdRecipes: [RecipeDefinition],
        confidence: MealResolutionConfidence,
        isFallback: Bool,
        suggestedRecipe: RecipeDefinition? = nil,
        unmatchedItems: [String] = []
    ) {
        self.meals = meals
        self.createdRecipes = createdRecipes
        self.confidence = confidence
        self.isFallback = isFallback
        self.suggestedRecipe = suggestedRecipe
        self.unmatchedItems = unmatchedItems
    }
    public var meals: [Meal]
    /// Recipes auto-minted as a side effect of resolution and persisted silently on commit (the legacy
    /// multi-ingredient auto-mint). Distinct from `suggestedRecipe`, which is review-gated.
    public var createdRecipes: [RecipeDefinition]
    public var confidence: MealResolutionConfidence
    public var isFallback: Bool
    /// The decomposition tier's built recipe, carried out to the review sheet where the user can edit
    /// its name + yield and confirm before it is minted. NOT auto-persisted by `commitResolution` — it
    /// reaches the recipe book only through a user confirm, so a decomposition that auto-commits (high
    /// confidence, no review) never mints a recipe. `nil` for every other tier.
    public var suggestedRecipe: RecipeDefinition?
    /// Typed items the resolver could not bind to any food, verbatim ("2 eggs" out of "2 eggs and
    /// toast"). Carried up from ``FoodSelectionPlan/unmatchedItems`` so the review sheet can name
    /// what was missed. Empty means every item the splitter produced ended up in the meal.
    public var unmatchedItems: [String] = []

    /// Whether the quick-log flow must pause on the "Check this meal" sheet instead of committing.
    ///
    /// Coverage counts as much as confidence: a plan that bound one of two typed items produces a
    /// meal that LOOKS certain (one real catalog match, `.high`) while silently dropping food, so
    /// any unmatched item forces the review — see ``unmatchedItems``.
    public var needsReview: Bool { confidence.needsReview || isFallback || !unmatchedItems.isEmpty }
}

/// Protein/carb/fat grams; `calories` derives via the 4/4/9 kcal-per-gram rule.
///
/// ``goodProteinThreshold`` is the single source of truth for the per-serving protein level that
/// rates a meal `.good` rather than `.ok` (WI-Q) — referenced by MealBuilder, the correction and
/// review paths, DiaryStore, and FoodView.
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

    /// Derived kilocalories via the 4/4/9 kcal-per-gram rule. The single source of the formula —
    /// `Meal.calories`, `FoodItem.calories`, `MacroTotals.calories`, and the app-target call sites
    /// all route through here.
    public var calories: Int { protein * 4 + carbs * 4 + fat * 9 }
}

/// The 23 tracked optional micronutrient amounts for a food or meal.
///
/// Every field is optional so "not measured" stays distinct from zero: `add`/`scaled(by:)`
/// preserve nil, and the coverage math (`populatedFieldCount`, `completeness`) counts only real
/// data. Consumed by the gap analyzer, the label scanner, and recipe/meal snapshotting.
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

    /// A copy with every implausible amount dropped to nil — the honest reading of garbage, and it
    /// preserves the nil-vs-zero invariant this type documents ("not measured" stays distinct from
    /// zero). Applied where UNTRUSTED micronutrients enter: the mesh `.saved` recipe decoder and
    /// the JSON-LD web importer's nutrition label.
    ///
    /// Drops rather than clamps deliberately: clamping a 1e300 sodium to the limit would PERSIST a
    /// fabricated number and show the user a plausible-looking wrong value, where nil renders as
    /// "not measured", which is true. R5: a non-finite or absurd `Double` here would otherwise
    /// reach a trapping `Int(_:)` in a day-detail or Home row.
    public func sanitizedForImport(limit: Double = SharedRecipeLimits.maxMicronutrientAmount) -> Micronutrients {
        Micronutrients(
            fiber: Self.plausible(fiber, limit),
            sugar: Self.plausible(sugar, limit),
            saturatedFat: Self.plausible(saturatedFat, limit),
            cholesterol: Self.plausible(cholesterol, limit),
            vitaminA: Self.plausible(vitaminA, limit),
            vitaminC: Self.plausible(vitaminC, limit),
            vitaminD: Self.plausible(vitaminD, limit),
            vitaminE: Self.plausible(vitaminE, limit),
            vitaminK: Self.plausible(vitaminK, limit),
            vitaminB6: Self.plausible(vitaminB6, limit),
            vitaminB12: Self.plausible(vitaminB12, limit),
            thiamin: Self.plausible(thiamin, limit),
            riboflavin: Self.plausible(riboflavin, limit),
            niacin: Self.plausible(niacin, limit),
            folate: Self.plausible(folate, limit),
            calcium: Self.plausible(calcium, limit),
            iron: Self.plausible(iron, limit),
            magnesium: Self.plausible(magnesium, limit),
            phosphorus: Self.plausible(phosphorus, limit),
            potassium: Self.plausible(potassium, limit),
            sodium: Self.plausible(sodium, limit),
            zinc: Self.plausible(zinc, limit),
            omega3: Self.plausible(omega3, limit)
        )
    }

    /// One field's plausibility test: finite, non-negative, and at or under `limit`.
    private static func plausible(_ value: Double?, _ limit: Double) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= limit else { return nil }
        return value
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

/// Whether a tracked nutrient is covered or in gap over the analysis window.
///
/// Intermediate coverage (25–50%) yields no row at all — see
/// ``MicronutrientGapAnalyzer/gaps(from:windowDays:)``.
public nonisolated enum NutrientGapStatus: String, Codable, Equatable {
    case covered
    case gap
}

/// One nutrient's coverage verdict over a rolling window, for the preventive-care nudge UI.
///
/// `coverageRatio` compares intake to the recommended window total; `dataCoverageRatio` records how
/// many meals actually carried data — the analyzer suppresses verdicts on thin data.
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

/// A tracked nutrient's identity, unit, recommended daily amount, and value accessor.
///
/// The row type of ``MicronutrientGapAnalyzer/trackedNutrients``; recommended amounts come from
/// the shared ``FDADailyValues`` table.
public nonisolated struct NutrientReference: Sendable {

    public init(key: String, name: String, unit: String, recommendedDailyAmount: Double,
                value: @escaping @Sendable (Micronutrients) -> Double?) {
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
    public var value: @Sendable (Micronutrients) -> Double?
}

/// Deterministic micronutrient gap analysis over recent days' meals.
///
/// Only speaks when the data supports it: it requires at least half the window's meals to carry
/// usable micronutrient data (and per-nutrient data coverage ≥ 50%) before rating a nutrient
/// covered (≥ 50% of the FDA-DV window total) or a gap (< 25%). Pure ``Meal`` arithmetic kept in
/// the domain layer so scoring can depend on it, never the reverse.
public nonisolated enum MicronutrientGapAnalyzer {
    // Recommended daily amounts come from the single shared `FDADailyValues` table
    // (21 CFR 101.9), which the `NutritionLabelScanner` reads too. Calcium and
    // potassium here previously carried the stale NASEM figures (1,000 / 3,400); they
    // now match the FDA DVs the label prints (1,300 / 4,700). Omega-3 keeps the NASEM
    // ALA Adequate Intake because FDA defines no omega-3 DV — see `FDADailyValues`.
    public static let trackedNutrients: [NutrientReference] = [
        NutrientReference(key: "fiber", name: "Fiber", unit: "g", recommendedDailyAmount: FDADailyValues.fiberGrams) { $0.fiber },
        NutrientReference(key: "vitaminC", name: "Vitamin C", unit: "mg", recommendedDailyAmount: FDADailyValues.vitaminCMilligrams) { $0.vitaminC },
        NutrientReference(key: "vitaminD", name: "Vitamin D", unit: "mcg", recommendedDailyAmount: FDADailyValues.vitaminDMicrograms) { $0.vitaminD },
        NutrientReference(key: "vitaminB12", name: "Vitamin B12", unit: "mcg", recommendedDailyAmount: FDADailyValues.vitaminB12Micrograms) { $0.vitaminB12 },
        NutrientReference(key: "folate", name: "Folate", unit: "mcg DFE", recommendedDailyAmount: FDADailyValues.folateMicrogramsDFE) { $0.folate },
        NutrientReference(key: "calcium", name: "Calcium", unit: "mg", recommendedDailyAmount: FDADailyValues.calciumMilligrams) { $0.calcium },
        NutrientReference(key: "iron", name: "Iron", unit: "mg", recommendedDailyAmount: FDADailyValues.ironMilligrams) { $0.iron },
        NutrientReference(key: "magnesium", name: "Magnesium", unit: "mg", recommendedDailyAmount: FDADailyValues.magnesiumMilligrams) { $0.magnesium },
        NutrientReference(key: "potassium", name: "Potassium", unit: "mg", recommendedDailyAmount: FDADailyValues.potassiumMilligrams) { $0.potassium },
        NutrientReference(key: "zinc", name: "Zinc", unit: "mg", recommendedDailyAmount: FDADailyValues.zincMilligrams) { $0.zinc },
        NutrientReference(key: "omega3", name: "Omega-3", unit: "g", recommendedDailyAmount: FDADailyValues.omega3ALAGrams) { $0.omega3 }
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
        // R5: a public entry point taking a plain Int. `suffix(_:)` TRAPS on a negative length and a
        // zero window divides by zero into NaN ratios, and `assert` is compiled out in Release — so
        // the guard, not the assert, is what makes the parameter safe.
        assert(windowDays > 0, "window must be positive")
        guard windowDays > 0 else { return [] }
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

/// The USDA/product dataset a food row came from (foundation, survey, SR legacy, branded,
/// restaurant).
///
/// Sorted ABOVE relevance score in search: reference data wins for plain queries, and
/// branded/restaurant data wins for brand queries — see
/// ``FoodItemSearch/dataTypePriority(_:brandQuery:)``.
public nonisolated enum FoodDataType: String, Codable, Sendable {
    case foundation   // USDA Foundation Foods
    case survey       // USDA/FNDDS survey foods
    case srLegacy     // USDA SR Legacy reference
    case branded      // Commercial/branded product
    case restaurant   // Restaurant chain item
}

/// Who authored a food row: USDA data, an AI resolution, or the user.
///
/// Ranked manual > usda > aiResolved in search so the user's own foods always outrank lookalikes;
/// decoded tolerantly on ``FoodItem`` (an unknown source freezes to `.manual`, never falsely
/// claiming USDA or AI provenance).
public nonisolated enum FoodItemSource: String, Codable, Sendable {
    case usda
    case aiResolved
    case manual
}

/// The free-string provenance tokens stamped into `Meal.source` (manual, label-scan, web-import, …).
///
/// Deliberately string constants rather than an enum so a token minted by a newer build round-trips
/// through older devices unharmed.
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

/// A catalog food: serving definition, macros, micronutrients, provenance, and portion table.
///
/// The unit every meal component and recipe ingredient binds to by `id`. Part of the synced blob's
/// top-level `foodItems` (USDA rows are filtered out of that store and served read-only by the
/// bundled catalog), so `source`/`dataType` decode tolerantly with parked tokens. `portions` powers
/// unit→gram conversion (`gramsEquivalent(quantity:unit:)`), and `barcode` holds the normalized
/// GTIN for instant re-scan matches.
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
        macros.calories
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
                return nonEmptyBrandSource ?? "Branded"
            case .restaurant:
                return nonEmptyBrandSource ?? "Restaurant"
            case .foundation, .survey, .srLegacy:
                return "USDA"
            }
        }
    }

    /// `brandSource` when it carries an actual brand name, `nil` when absent or blank — so the
    /// provenance label can fall back to the generic wording without a force unwrap.
    private var nonEmptyBrandSource: String? {
        brandSource.flatMap { $0.isEmpty ? nil : $0 }
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

/// One household-measure→gram mapping for a food (e.g. "1 cup = 240 g").
///
/// Powers `FoodItem.gramsEquivalent` and recipe-unit preference; `grams(for:)` scales the mapping
/// by an arbitrary amount.
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

/// A numbered catalog candidate offered to the AI food-selection prompt.
///
/// The model picks candidate NUMBERS only; `promptLine` is the compact one-line rendering it sees,
/// and code binds the number back to the ``FoodItem`` — the model never invents a food.
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

/// The model's pick for one ingredient: a candidate id plus the quantity/unit it assigned.
///
/// Bound back to the numbered ``FoodSelectionCandidate`` by `candidateId` after the response
/// parses.
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

/// One meal item in the AI selection plan, grouping its chosen ingredients under a name.
///
/// The intermediate grouping between the user's description and the bound ingredient list.
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

/// The parsed output of the AI food-selection tier: meal name/type plus per-item ingredient picks.
///
/// `ingredients` flattens the items for the binder that resolves candidate ids back to catalog
/// foods.
public nonisolated struct FoodSelectionPlan: Equatable {

    public init(
        mealName: String,
        mealType: MealType,
        items: [FoodSelectionMealItem],
        unmatchedItems: [String] = []
    ) {
        self.mealName = mealName
        self.mealType = mealType
        self.items = items
        self.unmatchedItems = unmatchedItems
    }
    public var mealName: String
    public var mealType: MealType
    public var items: [FoodSelectionMealItem]
    /// The split items the tier could NOT bind to a catalog food, verbatim as the user typed them
    /// ("2 eggs" out of "2 eggs and toast").
    ///
    /// A plan that binds one of two items is not a full answer: dropping the unbound half silently
    /// logs a confident-looking meal that is missing food. Resolvers carry the dropped words here so
    /// the confidence can be lowered and the review sheet can show what was missed instead of the
    /// user discovering it by re-reading the row. Empty means full coverage.
    public var unmatchedItems: [String]

    /// True when at least one split item was dropped — the "this plan is partial" signal callers
    /// use to demote confidence and open the review sheet.
    public var hasUnmatchedItems: Bool { !unmatchedItems.isEmpty }

    public var ingredients: [FoodSelectionIngredient] {
        items.flatMap(\.ingredients)
    }
}

/// Splits a free-text meal description into separately-resolvable food items.
///
/// Normalizes separators ("&", commas, semicolons, "plus", most "with" clauses) to " and " — but
/// keeps "with" attached when it introduces a quantity modifier of the preceding food ("burger
/// with 2 patties") — then splits and trims, falling back to the whole description.
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
///
/// **Two consumers, two entry points.** `FoodSelectionCandidateBuilder` / `FoodCatalog.candidates`
/// reorder a resolver POOL and call ``demotingDishes(_:forQuery:)``; `FoodItemSearch` reorders a
/// ranked SEARCH result and calls ``demotingDishes(scored:forQuery:)``, which adds a score guard so
/// the demotion can never promote a worse match (research §26 fix 1.7a). Keeping them as separate
/// entry points is deliberate: the resolver's pool has no scores to guard with, and changing its
/// ordering is not this fix's business.
public nonisolated enum PreparedDishHeuristic {
    /// Carrier / assembly tokens that mark a food as a composed dish rather than a single ingredient.
    /// The second block was added 2026-08-23 from a measured single-ingredient battery: `cheese`
    /// returned a *dip*, `beef` and `turkey` a *salad*, `onion` *rings*, `bacon` *bits*, and
    /// `piece of chicken` *nuggets* — every one an assembled/derived preparation standing in for the
    /// bare ingredient, and every one invisible to a carrier list built only from bread words.
    ///
    /// Adding a word here also adds it to ``dishHeadNouns``, which is the safety half: a query whose
    /// head noun IS the word ("caesar salad", "chicken noodle soup") stops demoting altogether, so
    /// widening the list cannot cost a query that asked for the dish by name.
    nonisolated static let carrierTokens: Set<String> = [
        "bun", "buns", "sandwich", "sandwiches", "roll", "rolls", "biscuit", "biscuits", "bagel",
        "croissant", "wrap", "wraps", "tortilla", "taco", "tacos", "burrito", "burritos", "sub",
        "hoagie", "pita", "melt", "toast", "panini", "quesadilla", "calzone", "nachos",
        "salad", "salads", "dip", "dips", "rings", "bits", "nuggets",
        // `tortillas` closes a plural gap every other carrier already had (bun/buns, roll/rolls,
        // taco/tacos …). Without it *Tortillas, ready-to-bake or -fry, corn* counted as an ingredient
        // while *Tortilla, blue corn …* counted as a dish, and the two were reordered against each
        // other for no reason a reader could defend.
        "tortillas"
    ]

    // NOT carriers, and each exclusion is measured. `soup`/`soups` were tried: USDA spells its
    // canonical broths *Soup, beef broth or bouillon canned, ready-to-serve* and *Soup, chicken
    // broth, ready-to-serve*, so making `soup` a carrier demoted the RIGHT answer for three shipped
    // dish-template components in favour of branded look-alikes. A soup is not an assembly around an
    // ingredient the way a bun or a wrap is.
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
    ///
    /// A carrier the name explicitly NEGATES does not count. FNDDS spells the un-assembled form of a
    /// dish by naming the carrier and denying it — *Chili hot dog, no bun*, *Hamburger, no bun* — so a
    /// plain substring test read the row that is LEAST assembled as the most. Measured: `hot dog`
    /// demoted every no-bun row and surfaced *Pickle relish, hot dog* as its top-1.
    public nonisolated static func isPreparedDish(_ foodItem: FoodItem) -> Bool {
        let name = FoodItemSearch.normalized(foodItem.name)
        if preparedMarkers.contains(where: name.contains) { return true }
        let tokens = Set(name.split(separator: " ").map(String.init))
        return tokens.intersection(carrierTokens).contains { !isNegated($0, in: name) }
    }

    /// Whether `carrier` appears in `normalizedName` only to be denied ("no bun", "without bun").
    /// `normalizedName` must already be `FoodItemSearch.normalized`, which collapses punctuation to
    /// single spaces, so the two spellings below are the only ones that can occur.
    private nonisolated static func isNegated(_ carrier: String, in normalizedName: String) -> Bool {
        normalizedName.contains("no \(carrier)") || normalizedName.contains("without \(carrier)")
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

    /// The score-aware demotion the SEARCH path uses — research §26 fix 1.7 **option (a)**, applied
    /// inside `FoodItemSearch`'s ranking rather than only inside the resolver's candidate builder.
    ///
    /// Same partition as ``demotingDishes(_:forQuery:)`` with ONE added guard, and the guard is the
    /// deliverable: **a dish is only sunk beneath ingredients that match at least as well.** Without
    /// it, applying the resolver's heuristic to free-text search measurably breaks correct answers,
    /// because the head-noun test cannot know an idiom from an ingredient:
    ///
    /// * `grilled cheese` — head noun "cheese", so the query reads as an ingredient, and the correct
    ///   top-1 *Grilled cheese sandwich, NFS* carries the carrier token "sandwich". It scores **1019**
    ///   against a best ingredient row in the low hundreds, so the guard leaves it exactly where it is.
    /// * `chicken burrito bowl` is NOT a rescue by this guard, and the difference matters for anyone
    ///   reading the mechanism: every row that passes the AND gate for that query carries "burrito",
    ///   so there are no ingredient rows at all and the function returns at its `bestIngredientScore`
    ///   guard, unreordered. Verified live rather than assumed.
    /// * `peanut butter` — head noun "butter", and *Peanut butter and jelly sandwich, NFS* really is
    ///   the wrong answer: plain peanut-butter rows score at least as well, so the sandwich sinks.
    /// * `avocado` — *Sushi roll, avocado* carries "roll" and is beaten on score by the raw avocado
    ///   rows, so it sinks.
    ///
    /// Score is used only to decide WHETHER to reorder; it never reorders rows itself, so the
    /// comparator's data-type-above-score ordering (option (b), not authorized) is untouched.
    public nonisolated static func demotingDishes(
        scored: [(foodItem: FoodItem, score: Int)],
        forQuery query: String
    ) -> [(foodItem: FoodItem, score: Int)] {
        guard !queryWantsDish(query), !scored.isEmpty else { return scored }
        let dishFlags = scored.map { isPreparedDish($0.foodItem) }
        guard let bestIngredientScore = zip(scored, dishFlags).filter({ !$0.1 }).map({ $0.0.score }).max() else {
            return scored
        }
        var kept: [(foodItem: FoodItem, score: Int)] = []
        var sunk: [(foodItem: FoodItem, score: Int)] = []
        // R2: one bounded pass over `scored`.
        for (row, isDish) in zip(scored, dishFlags) {
            if isDish, row.score <= bestIngredientScore { sunk.append(row) } else { kept.append(row) }
        }
        guard !sunk.isEmpty else { return scored }
        return kept + sunk
    }

    // A TOLERANCE MARGIN WAS TRIED HERE AND REVERTED, and the measurement is worth keeping.
    // Strict `<=` leaves two bare-ingredient queries unfixed by a hair: *Beef salad* outscores
    // *Beef, stew meat* by ONE point (810 vs 809) and *Onion rings…* outscores *Onions, raw* by 55,
    // so both dishes survive. Allowing a dish to sink when it leads by less than the scorer's own
    // +60 token bonus fixed both — and cost `grilled cheese`, where the best non-dish row is a
    // BRANDED product called *Grilled Cheese Style Tomato Soup* scoring 1016 against the canonical
    // survey *Grilled cheese sandwich, NFS* at 1019. Demotion is the one step that can lift a row
    // across data-type tiers, so a 3-point margin there put a tomato soup above the sandwich.
    // Tier-aware variants were considered and each cost a different measured case (a same-or-higher
    // tier rule loses `broccoli` and `avocado`, whose correct answers sit a tier BELOW the dish).
    // Strict it is: a demotion may never promote a worse-scoring row, full stop. `beef` and `onion`
    // stay unfixed and are pinned that way in `FoodSearchCorpusTests.reviewBattery`.

    private nonisolated static func singular(_ token: String) -> String {
        if token.hasSuffix("ies"), token.count >= 5 { return String(token.dropLast(3)) + "y" }
        if token.hasSuffix("s"), !token.hasSuffix("ss"), token.count >= 4 { return String(token.dropLast()) }
        return token
    }
}

/// Builds the numbered candidate list for the AI selection prompt from a meal description.
///
/// Searches overlapping 3/2/1-word phrases against the catalog index, de-dupes, then demotes
/// prepared dishes for bare-ingredient queries via ``PreparedDishHeuristic``. `searchPhrases` is
/// shared with `FoodCatalog` so the SQLite-backed path builds the same candidate set as the
/// in-memory array path.
public nonisolated enum FoodSelectionCandidateBuilder {
    public static func candidates(for description: String, foodItems: [FoodItem], limit: Int = 18) -> [FoodSelectionCandidate] {
        let index = FoodItemSearch.Index(foodItems: foodItems)
        let phrases = searchPhrases(from: description)
        var selected: [FoodItem] = []

        for phrase in phrases {
            // `stripsStopwords: false` — a sub-phrase, not a typed query. `searchPhrases` keeps
            // quantity words on purpose: in "slices pizza" the quantity word is the discriminator.
            let matches = FoodItemSearch.results(for: phrase, in: index, limit: 4, stripsStopwords: false)
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

/// One structured recipe line: a bound catalog food id, quantity, and unit.
///
/// Stores no nutrition of its own — macros/micros always derive from one validated
/// ``RecipeServingConversion`` against the bound ``FoodItem``.
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

/// One ordered cooking-mode instruction (F5, decision §11.6). `text` is the instruction; the optional
/// `durationSeconds` is a PASSIVE per-step timer — when present, cooking mode shows a countdown that on
/// expiry highlights the Next button and fires a haptic, but NEVER auto-advances the step. v1 supports
/// a single per-step timer only (no concurrent named timers).
///
/// Additive + tolerant everywhere it travels: absent on every recipe authored before F5, decoded with
/// `decodeIfPresent` on both the synced blob (`RecipeDefinition`) and the per-row `payloadData` path.
public nonisolated struct RecipeStep: Identifiable, Codable, Equatable, Sendable {
    public var id = UUID()
    public var text: String
    public var durationSeconds: Int?

    public init(id: UUID = UUID(), text: String, durationSeconds: Int? = nil) {
        self.id = id
        self.text = text
        self.durationSeconds = durationSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decode(String.self, forKey: .text)
        durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds)
    }
}

/// Shared normalizer for a recipe's cooking steps (F5). Trims each step's text, drops blank-text steps,
/// and clamps a non-positive `durationSeconds` to `nil` (a passive timer needs a positive window).
/// Returns `nil` when nothing survives so callers store "no steps" rather than an empty `[]`. Used by
/// the manual editor path (`DiaryStore.addRecipe/updateRecipe`) and the share/mesh decode path.
public nonisolated enum RecipeStepSanitizer {
    public static func sanitized(_ steps: [RecipeStep]?) -> [RecipeStep]? {
        guard let steps else { return nil }
        let cleaned: [RecipeStep] = steps.compactMap { step in
            let trimmed = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let duration = (step.durationSeconds ?? 0) > 0 ? step.durationSeconds : nil
            return RecipeStep(id: step.id, text: trimmed, durationSeconds: duration)
        }
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// The canonical recipe units, with `normalized(_:)` mapping user/USDA spellings onto them.
///
/// Un-normalizable unit strings return nil and are treated as incompatible — quantity math never
/// silently mixes units (see ``GroceryAggregation``'s merge rules).
public nonisolated enum RecipeUnit: String, CaseIterable, Identifiable {
    case milligram = "mg"
    case gram = "g"
    case kilogram = "kg"
    case milliliter = "ml"
    case ounce = "oz"
    case pound = "lb"
    case fluidOunce = "fl oz"
    case liter = "l"
    case cup = "cup"
    case tablespoon = "tbsp"
    case teaspoon = "tsp"
    case glass = "glass"
    case slice = "slice"
    case piece = "piece"
    case each = "each"
    case serving = "serving"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .milligram: "Milligrams"
        case .gram: "Grams"
        case .kilogram: "Kilograms"
        case .milliliter: "Milliliters"
        case .ounce: "Ounces"
        case .pound: "Pounds"
        case .fluidOunce: "US Fluid Ounces"
        case .liter: "Liters"
        case .cup: "Cups"
        case .tablespoon: "Tablespoons"
        case .teaspoon: "Teaspoons"
        case .glass: "Glass (12 US fl oz)"
        case .slice: "Slices"
        case .piece: "Pieces"
        case .each: "Each"
        case .serving: "Servings"
        }
    }

    public static func normalized(_ unit: String) -> RecipeUnit? {
        switch unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mg", "milligram", "milligrams":
            return .milligram
        case "g", "gram", "grams":
            return .gram
        case "kg", "kilogram", "kilograms":
            return .kilogram
        case "ml", "milliliter", "milliliters", "millilitre", "millilitres":
            return .milliliter
        case "oz", "ounce", "ounces":
            return .ounce
        case "lb", "lbs", "pound", "pounds":
            return .pound
        case "fl oz", "floz", "fluid ounce", "fluid ounces", "us fluid ounce", "us fluid ounces":
            return .fluidOunce
        case "l", "liter", "liters", "litre", "litres":
            return .liter
        case "cup", "cups":
            return .cup
        case "tbsp", "tablespoon", "tablespoons":
            return .tablespoon
        case "tsp", "teaspoon", "teaspoons":
            return .teaspoon
        case "glass", "glasses":
            return .glass
        case "slice", "slices":
            return .slice
        case "piece", "pieces":
            return .piece
        case "each", "unit", "units", "item", "items":
            return .each
        case "serving", "servings":
            return .serving
        default:
            return nil
        }
    }
}

/// The source-backed explanation for one recipe quantity's nutrition scale.
///
/// This is intentionally transient: logged components persist their already-scaled values, while this
/// result keeps every consumer of a new conversion on one validated quantity, unit, scale, and source
/// measure. A `.glassDefault` is Fernlet's editable 12-US-fluid-ounce assumption, never a mass ounce.
public nonisolated struct RecipeServingConversion: Equatable, Sendable {
    /// Which of the four conversion routes produced the scale, most trusted first.
    ///
    /// The rawValue is a frozen token: it rides in persisted and exported rows, so it never
    /// localizes. `.glassDefault` is the only route resting on an assumption rather than source
    /// data, which is why callers surface it for review.
    public enum Provenance: String, Equatable, Sendable {
        case exactServingBasis
        case physicalUnit
        case sourcePortion
        case glassDefault
    }

    public let foodItemID: UUID
    public let componentQuantity: Double
    public let componentUnit: String
    public let servingScale: Double
    public let grams: Double?
    public let sourceServingSize: Double
    public let sourceServingUnit: String
    public let sourcePortion: FoodPortion?
    public let provenance: Provenance

    public func scaledMacros(for foodItem: FoodItem) -> Macros {
        foodItem.macros.scaled(by: servingScale)
    }

    public func scaledMicronutrients(for foodItem: FoodItem) -> Micronutrients {
        foodItem.micronutrients.scaled(by: servingScale)
    }
}

/// Domain-level bounds shared by every recipe quantity conversion, independent of app-side meal UI.
public nonisolated enum RecipeConversionLimits {
    public static let maxGrams: Double = 3_000
    public static let maxCount: Double = 100
}

extension RecipeUnit {
    /// The measurement family a unit belongs to, used to reject incompatible conversions.
    ///
    /// `.serving` has no dimension — it is a source-relative multiplier, not a physical quantity —
    /// so `dimension` returns nil for it rather than inventing a family.
    public enum Dimension: Equatable, Sendable {
        case mass
        case volume
        case count
    }

    public var dimension: Dimension? {
        switch self {
        case .milligram, .gram, .kilogram, .ounce, .pound: .mass
        case .milliliter, .fluidOunce, .liter, .cup, .tablespoon, .teaspoon, .glass: .volume
        case .slice, .piece, .each: .count
        case .serving: nil
        }
    }

    public var isVolume: Bool { dimension == .volume }
    public var isCount: Bool { dimension == .count }

    public func baseAmount(for quantity: Double) -> Double? {
        guard quantity.isFinite, quantity > 0 else { return nil }
        let factor: Double
        switch self {
        case .milligram: factor = 0.001
        case .gram: factor = 1
        case .kilogram: factor = 1_000
        case .ounce: factor = 28.3495
        case .pound: factor = 453.592
        case .milliliter: factor = 1
        case .fluidOunce: factor = 29.5735
        case .liter: factor = 1_000
        case .cup: factor = 236.588
        case .tablespoon: factor = 14.7868
        case .teaspoon: factor = 4.92892
        case .glass: factor = 354.882
        case .slice, .piece, .each, .serving: return nil
        }
        let value = quantity * factor
        guard value.isFinite, value > 0, value <= RecipeConversionLimits.maxGrams else { return nil }
        return value
    }
}

extension RecipeServingConversion {
    fileprivate static func resolve(quantity: Double, unit: String, foodItem: FoodItem) -> RecipeServingConversion? {
        guard let requestedUnit = RecipeUnit.normalized(unit), validRequest(quantity, unit: requestedUnit),
              validServing(foodItem), let servingUnit = RecipeUnit.normalized(foodItem.servingUnit) else { return nil }
        if requestedUnit == .serving {
            return declaredServing(quantity: quantity, foodItem: foodItem)
        }
        if requestedUnit == servingUnit {
            return exactBasis(quantity: quantity, foodItem: foodItem, unit: requestedUnit)
        }
        if requestedUnit.dimension == servingUnit.dimension,
           let requestedBase = requestedUnit.baseAmount(for: quantity),
           let servingBase = servingUnit.baseAmount(for: foodItem.servingSize) {
            return physicalBasis(quantity: quantity, unit: unit, requestedBase: requestedBase,
                                 servingBase: servingBase, foodItem: foodItem, requestedUnit: requestedUnit)
        }
        guard let requestedGrams = grams(quantity: quantity, unit: unit, foodItem: foodItem),
              let servingGrams = grams(quantity: foodItem.servingSize, unit: foodItem.servingUnit, foodItem: foodItem),
              let scale = validScale(requestedGrams / servingGrams) else { return nil }
        return RecipeServingConversion(
            foodItemID: foodItem.id, componentQuantity: quantity, componentUnit: unit,
            servingScale: scale, grams: requestedGrams, sourceServingSize: foodItem.servingSize,
            sourceServingUnit: foodItem.servingUnit, sourcePortion: sourcePortion(for: requestedUnit, foodItem: foodItem),
            provenance: requestedUnit == .glass ? .glassDefault : .sourcePortion
        )
    }

    fileprivate static func grams(quantity: Double, unit: String, foodItem: FoodItem) -> Double? {
        guard let recipeUnit = RecipeUnit.normalized(unit), validRequest(quantity, unit: recipeUnit) else { return nil }
        if recipeUnit.dimension == .mass { return recipeUnit.baseAmount(for: quantity) }
        guard let dimension = recipeUnit.dimension,
              let portion = sourcePortion(for: recipeUnit, foodItem: foodItem),
              let amount = convertedAmount(quantity, from: recipeUnit, to: portion.recipeUnit, dimension: dimension)
        else { return nil }
        return portion.grams(for: amount)
    }

    private static func exactBasis(quantity: Double, foodItem: FoodItem, unit: RecipeUnit) -> RecipeServingConversion? {
        guard let scale = validScale(quantity / foodItem.servingSize) else { return nil }
        return RecipeServingConversion(
            foodItemID: foodItem.id, componentQuantity: quantity, componentUnit: foodItem.servingUnit,
            servingScale: scale, grams: grams(quantity: quantity, unit: unit.rawValue, foodItem: foodItem),
            sourceServingSize: foodItem.servingSize, sourceServingUnit: foodItem.servingUnit,
            sourcePortion: sourcePortion(for: unit, foodItem: foodItem), provenance: .exactServingBasis
        )
    }

    private static func declaredServing(quantity: Double, foodItem: FoodItem) -> RecipeServingConversion? {
        guard let scale = validScale(quantity) else { return nil }
        return RecipeServingConversion(
            foodItemID: foodItem.id, componentQuantity: quantity, componentUnit: RecipeUnit.serving.rawValue,
            servingScale: scale, grams: grams(quantity: foodItem.servingSize, unit: foodItem.servingUnit, foodItem: foodItem),
            sourceServingSize: foodItem.servingSize, sourceServingUnit: foodItem.servingUnit,
            sourcePortion: nil, provenance: .exactServingBasis
        )
    }

    private static func physicalBasis(
        quantity: Double, unit: String, requestedBase: Double, servingBase: Double,
        foodItem: FoodItem, requestedUnit: RecipeUnit
    ) -> RecipeServingConversion? {
        guard let scale = validScale(requestedBase / servingBase) else { return nil }
        let grams = requestedUnit.dimension == .mass ? requestedBase : nil
        return RecipeServingConversion(
            foodItemID: foodItem.id, componentQuantity: quantity, componentUnit: unit,
            servingScale: scale, grams: grams, sourceServingSize: foodItem.servingSize,
            sourceServingUnit: foodItem.servingUnit, sourcePortion: nil,
            provenance: requestedUnit == .glass ? .glassDefault : .physicalUnit
        )
    }

    private static func sourcePortion(for unit: RecipeUnit, foodItem: FoodItem) -> FoodPortion? {
        guard let dimension = unit.dimension else { return nil }
        if unit.isCount { return foodItem.uniquePortion(matching: unit) }
        return foodItem.uniquePortion(in: dimension)
    }

    private static func convertedAmount(
        _ quantity: Double, from source: RecipeUnit, to destination: RecipeUnit?, dimension: RecipeUnit.Dimension
    ) -> Double? {
        guard let destination, source.dimension == dimension, destination.dimension == dimension else { return nil }
        if source == destination { return quantity }
        guard let sourceBase = source.baseAmount(for: quantity),
              let destinationOne = destination.baseAmount(for: 1) else { return nil }
        let converted = sourceBase / destinationOne
        guard converted.isFinite, converted > 0, converted <= RecipeConversionLimits.maxGrams else { return nil }
        return converted
    }

    private static func validRequest(_ quantity: Double, unit: RecipeUnit) -> Bool {
        let limit = unit.isCount || unit == .serving
            ? RecipeConversionLimits.maxCount : RecipeConversionLimits.maxGrams
        return quantity.isFinite && quantity > 0 && quantity <= limit
    }

    private static func validServing(_ foodItem: FoodItem) -> Bool {
        foodItem.servingSize.isFinite && foodItem.servingSize > 0 &&
            foodItem.servingSize <= RecipeConversionLimits.maxGrams
    }

    private static func validScale(_ value: Double) -> Double? {
        guard value.isFinite, value > 0, value <= RecipeConversionLimits.maxGrams else { return nil }
        return value
    }
}

extension RecipeIngredient {
    /// Resolves one quantity once for its component display, provenance, macros, and micronutrients.
    /// Incompatible, ambiguous, non-finite, or implausibly large conversions return `nil`; callers must
    /// review or fall through rather than treating a raw quantity as a count of servings.
    public func servingConversion(using foodItem: FoodItem) -> RecipeServingConversion? {
        RecipeServingConversion.resolve(quantity: quantity, unit: unit, foodItem: foodItem)
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
    /// The page's main food-picture URL, extracted at import time (owner decision 2026-08-09,
    /// reversing the 2026-07-16 "no external image fetch" tester decision). Additive and
    /// tolerant-decoded: absent on every recipe imported before this field existed. The bytes are
    /// downloaded only by user-present paths (foreground import, first open of the detail) — never
    /// by the background queue drain — and a recipe received over the proximity mesh carries `nil`
    /// here so it can never web-fetch. `nil` or empty = no known page image.
    public var imageURLString: String?
    /// The user's synced intent that NO web-derived picture may ever be auto-fetched for this
    /// recipe, on any device. Set `true` when the user deletes the recipe's photo (the page image
    /// must never resurrect against that intent), when a fetch finds the user already picked their
    /// own photo (their photo always wins), and on every mesh-received recipe (a received recipe
    /// must never turn its receiver into a web fetcher). Deliberately SPLIT from the per-device
    /// attempt bookkeeping (`RecipeWebImageAttemptMemory`, app target): this intent field rides the
    /// synced row, while "this device already spent its one automatic attempt" stays device-local —
    /// one attempt per device, suppression syncs. Additive and tolerant-decoded; `nil` (legacy
    /// blobs) means "no suppression".
    public var webImageSuppressed: Bool?
    /// True when `sourceURLString` came from a PEER over the proximity mesh rather than from a URL
    /// this user pasted or shared in. The distinction is the consent boundary for automatic network
    /// contact: a URL the user chose justifies the source-link connection pre-warm
    /// (Docs/No-Tracking-Wall.md §4b), a stranger's does not — a unique per-recipient hostname would
    /// otherwise turn every open of that recipe into a DNS+TLS beacon to the sender. Additive and
    /// tolerant-decoded; `nil` (legacy blobs) means "not known to be peer-supplied".
    public var sourceIsPeerSupplied: Bool?

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
        micronutrients: Micronutrients = Micronutrients(),
        imageURLString: String? = nil,
        webImageSuppressed: Bool? = nil,
        sourceIsPeerSupplied: Bool? = nil
    ) {
        self.sourceURLString = sourceURLString
        self.ingredientLines = ingredientLines
        self.macros = macros
        self.micronutrients = micronutrients
        self.imageURLString = imageURLString
        self.webImageSuppressed = webImageSuppressed
        self.sourceIsPeerSupplied = sourceIsPeerSupplied
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceURLString = try container.decodeIfPresent(String.self, forKey: .sourceURLString) ?? ""
        ingredientLines = try container.decodeIfPresent([String].self, forKey: .ingredientLines) ?? []
        macros = try container.decodeIfPresent(Macros.self, forKey: .macros) ?? Macros(protein: 0, carbs: 0, fat: 0)
        micronutrients = try container.decodeIfPresent(Micronutrients.self, forKey: .micronutrients) ?? Micronutrients()
        // Additive + tolerant (2026-08-09): absent on every payload blob written before the web-image
        // fields existed. Missing key -> nil, never a decode failure.
        imageURLString = try container.decodeIfPresent(String.self, forKey: .imageURLString)
        webImageSuppressed = try container.decodeIfPresent(Bool.self, forKey: .webImageSuppressed)
        // Same additive + tolerant rule: absent on every blob written before the provenance flag
        // existed, and an absent flag must degrade to "pre-warm as before", never to a decode error.
        sourceIsPeerSupplied = try container.decodeIfPresent(Bool.self, forKey: .sourceIsPeerSupplied)
    }
}

/// A recipe: servings, structured ingredients (or a web import), notes, cooking steps, and fork
/// provenance.
///
/// The single recipe model for every path — manual, peer-shared, and web-imported (a non-nil
/// `webImport` switches it to free-text ingredient lines with precomputed nutrition).
/// `parentRecipeID` (F4 fork provenance) and `steps` (F5 cooking mode) are additive
/// tolerant-decoded fields with documented blob-strip landmines: an un-updated paired device
/// re-encoding the synced blob strips them, so correctness must never depend on either surviving a
/// round-trip (see the field docs below).
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
    /// Provenance for a recipe FORKED by ingredient substitution (F4, decision §11.4): the id of the
    /// recipe this one was derived from. `nil` for every originally-authored/imported recipe.
    ///
    /// BLOB-STRIP LANDMINE (deliberate, accepted): this field is additive and tolerant-decoded, but it
    /// is NON-LOAD-BEARING. An un-updated paired device that has no `parentRecipeID` in its
    /// `RecipeDefinition` will decode a synced recipe (ignoring this key), then re-encode the shared
    /// blob WITHOUT it — silently stripping the provenance link. That is acceptable: the fork is a
    /// fully-independent recipe (its own id, its own ingredients); losing `parentRecipeID` loses only
    /// the "derived from" annotation, never any recipe DATA. Likewise the proximity wire
    /// (`SharedRecipePayload`) does not carry it, so a fork shared to a peer arrives as a standalone
    /// recipe. Never make anything depend on this value being present.
    public var parentRecipeID: UUID?

    /// Ordered cooking-mode steps (F5, decision §11.6). `nil`/empty on every recipe authored before F5.
    ///
    /// BLOB-STRIP LANDMINE (deliberate, doc-accepted — §6.2 chose both persistence paths knowingly):
    /// this field is additive and tolerant-decoded, but on the SYNCED BLOB path (manual/peer recipes in
    /// `FernletSnapshot.recipes`) it is NON-LOAD-BEARING against an un-updated paired device. That older
    /// device has no `steps` in its `RecipeDefinition`, so it decodes a synced recipe (ignoring this
    /// key), then re-encodes the shared blob WITHOUT it — silently stripping the steps. Unlike
    /// `parentRecipeID` (a mere annotation), for a MANUAL recipe this is REAL data loss of user-authored
    /// steps. This is the documented tradeoff of the blob path; the per-row `SavedRecipeRecord.payloadData`
    /// path (web/saved recipes) is safe because it round-trips the whole `RecipeDefinition` per row and an
    /// un-updated device that lacks a `payloadData` writer never re-encodes another device's blob. Never
    /// make correctness depend on `steps` surviving a round-trip through an older peer's synced blob.
    public var steps: [RecipeStep]?

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
        webImport: RecipeWebImport? = nil,
        parentRecipeID: UUID? = nil,
        steps: [RecipeStep]? = nil
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
        self.parentRecipeID = parentRecipeID
        self.steps = steps
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
        // Tolerant + additive: absent on every recipe written before F4 and on rows re-encoded by an
        // un-updated peer. Missing key -> nil (no provenance), never a decode failure.
        parentRecipeID = try container.decodeIfPresent(UUID.self, forKey: .parentRecipeID)
        // Tolerant + additive (F5). Missing key -> nil, never a decode failure. See the blob-strip note.
        steps = try container.decodeIfPresent([RecipeStep].self, forKey: .steps)
    }
}

/// The wire form of a recipe share (`fernlet.recipe`, version 1).
///
/// Decoded from untrusted peer text/envelopes, hence `Sendable` and flat snapshot fields. `steps`
/// is an optional key ON version 1 by design: an older peer ignores it and decodes minus steps, so
/// bumping `version` for steps would wrongly make every steps-carrying share unreadable — see the
/// field note.
public nonisolated struct SharedRecipePayload: Codable, Equatable, Sendable {
    public var format = "fernlet.recipe"
    public var version = 1
    public var name: String
    public var servings: Int
    public var notes: String
    public var ingredients: [SharedRecipeIngredient]
    /// Ordered cooking steps (F5). WIRE-COMPAT (§6.3): `version` STAYS 1 and this is an OPTIONAL key.
    /// An older peer's `SharedRecipePayload` has no `steps` property, so its synthesized `Codable`
    /// silently ignores this extra key and still sees `version == 1` — decoding minus steps, exactly the
    /// required graceful degrade (proven by `RecipeShareStepsWireCompatTests`). A newer peer decodes it
    /// (synthesized `Codable` treats a missing optional as nil), so a peer that authored no steps sends
    /// none and one that did sends them. Do NOT bump `version` for this — `RecipeShareCodec.decodePayload`
    /// rejects any version != 1, so a bump would make every steps-carrying recipe unreadable by old peers.
    public var steps: [RecipeStep]?

    public init(format: String = "fernlet.recipe", version: Int = 1, name: String, servings: Int, notes: String, ingredients: [SharedRecipeIngredient], steps: [RecipeStep]? = nil) {
        self.format = format
        self.version = version
        self.name = name
        self.servings = servings
        self.notes = notes
        self.ingredients = ingredients
        self.steps = steps
    }

    /// Bounded decode (R3/R5). This type is built from UNTRUSTED bytes — pasted share text and mesh
    /// recipe envelopes — and import mints one catalog `FoodItem` per ingredient into the synced
    /// blob, so an unbounded payload is permanent bloat. Every collection and string is capped here,
    /// where the bytes enter, and a non-finite or absurd quantity is rejected rather than carried
    /// into the macro arithmetic.
    public init(from decoder: Decoder) throws {
        // Every key except `steps` stays REQUIRED, exactly as the synthesized decode had it — this
        // initializer adds bounds, it does not relax the wire contract.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        version = try c.decode(Int.self, forKey: .version)
        name = try Self.bounded(c.decode(String.self, forKey: .name),
                                limit: SharedRecipeLimits.maxNameCharacters)
        notes = try Self.bounded(c.decode(String.self, forKey: .notes),
                                 limit: SharedRecipeLimits.maxNotesCharacters)
        servings = min(max(try c.decode(Int.self, forKey: .servings), 1), SharedRecipeLimits.maxServings)
        let decodedIngredients = try c.decode([SharedRecipeIngredient].self, forKey: .ingredients)
        guard decodedIngredients.count <= SharedRecipeLimits.maxIngredients else {
            throw RecipeImportError.invalidPayload
        }
        // R5: a peer controls every number and string here. The macro ceilings keep a hostile Int
        // out of the trapping `+` that sums them (the review sheet renders this payload BEFORE the
        // store ever sees it), and the name/unit caps keep an unbounded string out of the synced
        // catalog row each ingredient mints. Reject rather than truncate — see `bounded(_:limit:)`.
        for ingredient in decodedIngredients {
            guard ingredient.quantity.isFinite,
                  ingredient.quantity >= 0,
                  ingredient.quantity <= SharedRecipeLimits.maxQuantity,
                  ingredient.protein >= 0, ingredient.protein <= SharedRecipeLimits.maxMacroGrams,
                  ingredient.carbs >= 0, ingredient.carbs <= SharedRecipeLimits.maxMacroGrams,
                  ingredient.fat >= 0, ingredient.fat <= SharedRecipeLimits.maxMacroGrams,
                  ingredient.name.count <= SharedRecipeLimits.maxIngredientNameCharacters,
                  ingredient.unit.count <= SharedRecipeLimits.maxUnitCharacters else {
                throw RecipeImportError.invalidPayload
            }
        }
        ingredients = decodedIngredients
        let decodedSteps = try c.decodeIfPresent([RecipeStep].self, forKey: .steps)
        if let decodedSteps, decodedSteps.count > SharedRecipeLimits.maxSteps {
            throw RecipeImportError.invalidPayload
        }
        steps = decodedSteps
    }

    /// Rejects an over-long free-text field rather than silently truncating it — a truncated recipe
    /// name or note is a quiet corruption of the sender's content.
    private static func bounded(_ value: String, limit: Int) throws -> String {
        guard value.count <= limit else { throw RecipeImportError.invalidPayload }
        return value
    }

    /// Wire JSON keys for a shared recipe payload.
    private enum CodingKeys: String, CodingKey {
        case format, version, name, servings, notes, ingredients, steps
    }
}

/// Hard bounds on a decoded ``SharedRecipePayload``.
///
/// The payload arrives as untrusted pasted text or a mesh envelope and every ingredient becomes a
/// synced catalog food on import, so these are the caps that keep an import bounded (R3).
public nonisolated enum SharedRecipeLimits {
    public static let maxIngredients = 100
    public static let maxSteps = 60
    public static let maxNameCharacters = 120
    public static let maxNotesCharacters = 2000
    public static let maxServings = 99
    public static let maxQuantity = 5000.0
    /// Largest per-ingredient macro, in grams. No real ingredient approaches this; the cap exists
    /// so peer-supplied `Int`s can never overflow a macro SUM in a view body (`Macros.calories`
    /// and the review sheet both add them with a trapping `+`).
    public static let maxMacroGrams = 10_000
    /// Longest per-ingredient name accepted from a wire payload.
    public static let maxIngredientNameCharacters = 200
    /// Longest per-ingredient unit string accepted from a wire payload.
    public static let maxUnitCharacters = 40
    /// Longest free-text ingredient LINE accepted on the saved (web-import) arm, which ships whole
    /// lines rather than structured ingredients.
    public static let maxIngredientLineCharacters = 300
    /// Longest saved-recipe summary accepted from a wire payload.
    public static let maxSummaryCharacters = 4_000
    /// Longest source URL accepted from a wire payload (the conventional practical URL ceiling).
    public static let maxSourceURLCharacters = 2_048
    /// Longest cooking-step text accepted from a wire payload; mirrors `RecipeLimits.maxStepTextLength`.
    public static let maxStepTextCharacters = 2_000
    /// Step cap for the SAVED (web-imported) arm. Deliberately 200, not ``maxSteps`` (60): the web
    /// importer keeps up to `RecipeWebImporter.maxImportedSteps` = 200 steps, so a 60-step cap here
    /// would REJECT a recipe this very app legitimately imported and then shared.
    public static let maxSavedSteps = 200
    /// Largest plausible micronutrient amount for one food or meal, in the field's own unit (mg for
    /// minerals, g for macronutrient-adjacent fields, mcg for vitamins). Generous by two orders of
    /// magnitude for every field; the cap exists so a peer- or page-supplied `Double` can never
    /// reach a trapping `Int(_:)` in a view body.
    public static let maxMicronutrientAmount = 100_000.0
}

/// One wire recipe ingredient: name, quantity/unit, and flat macro grams.
///
/// Carries snapshot macros (not a food id) because the receiver has no matching catalog row —
/// import re-binds or creates foods locally.
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

/// Why pasted/shared recipe text failed to import, with user-facing copy.
///
/// `message` is the friendly sentence surfaced directly in the import sheet.
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

/// The recipe editor's working form state for one ingredient row.
///
/// Either binds an existing catalog food (`selectedFoodItemId`) or describes a new custom one
/// (name + macros + optional scanned micros/barcode) that ``CustomIngredientUpsert`` resolves on
/// save. Never persisted — the saved artifacts are the ``FoodItem`` and ``RecipeIngredient``.
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

    /// Returns entered manual macros, or catalog macros only when the selected food has one
    /// source-backed conversion. `nil` is an explicit unavailable state, never zero nutrition.
    public func resolvedMacros(foodItems: [FoodItem]) -> Macros? {
        guard selectedFoodItemId != nil else { return macros }
        guard let selectedFoodItem = selectedFoodItem(in: foodItems) else { return nil }
        let ingredient = RecipeIngredient(foodItemId: selectedFoodItem.id, quantity: quantity, unit: unit)
        return ingredient.servingConversion(using: selectedFoodItem)?.scaledMacros(for: selectedFoodItem)
    }

    /// A hand-authored row is always valid; a catalog-bound row must retain a safe conversion.
    public func hasResolvedMacros(foodItems: [FoodItem]) -> Bool {
        resolvedMacros(foodItems: foodItems) != nil
    }

    public func selectedFoodItem(in foodItems: [FoodItem]) -> FoodItem? {
        guard let selectedFoodItemId else { return nil }
        return foodItems.first { $0.id == selectedFoodItemId }
    }
}

extension Macros {
    public func scaled(by scale: Double) -> Macros {
        // R5: `scale` is user-driven (a typed recipe/meal quantity divided by a serving size), and
        // `Int(_: Double)` TRAPS on a non-finite or out-of-range value — `max(NaN, 0)` is NaN, so
        // the old floor did not exclude it. Reject a nonsense scale and clamp every product.
        guard scale.isFinite else { return self }
        let safeScale = max(scale, 0)
        return Macros(
            protein: Macros.clampedInt(Double(protein) * safeScale),
            carbs: Macros.clampedInt(Double(carbs) * safeScale),
            fat: Macros.clampedInt(Double(fat) * safeScale)
        )
    }

    /// A total-conversion from `Double` to `Int`: non-finite becomes 0 and the magnitude is clamped
    /// well inside `Int`'s range, so no macro arithmetic can trap.
    public static func clampedInt(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value, 0), Double(Int32.max)).rounded())
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
        case .milligram, .gram, .kilogram:
            servingUnit.caseInsensitiveCompare(RecipeUnit.gram.rawValue) == .orderedSame ? servingSize : 1
        case .milliliter, .fluidOunce, .liter, .cup, .tablespoon, .teaspoon, .glass:
            RecipeUnit.normalized(servingUnit)?.isVolume == true ? servingSize : 1
        case .ounce, .pound, .slice, .piece, .each, .serving:
            1
        }
    }

    /// Returns grams only when a mass conversion is physical or a unique source portion supplies
    /// gram evidence. In particular, milliliters/cups/spoons never silently become grams.
    public func gramsEquivalent(quantity: Double, unit: String) -> Double? {
        RecipeServingConversion.grams(quantity: quantity, unit: unit, foodItem: self)
    }

    fileprivate func uniquePortion(matching unit: RecipeUnit) -> FoodPortion? {
        let matches = portions.filter { $0.recipeUnit == unit && $0.hasValidGramMeasure }
        return matches.count == 1 ? matches[0] : nil
    }

    fileprivate func uniquePortion(in dimension: RecipeUnit.Dimension) -> FoodPortion? {
        let matches = portions.filter {
            guard let unit = $0.recipeUnit else { return false }
            return unit.dimension == dimension && $0.hasValidGramMeasure
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func portion(for unit: RecipeUnit) -> FoodPortion? {
        uniquePortion(matching: unit)
    }
}

extension FoodPortion {
    public var recipeUnit: RecipeUnit? {
        let normalizedUnit = FoodItemSearch.normalized(unit)
        let normalizedDescription = FoodItemSearch.normalized(description ?? "")
        if let direct = RecipeUnit.normalized(normalizedUnit), direct != .serving {
            return direct
        }
        guard normalizedUnit.isEmpty || normalizedUnit == "undetermined" else { return nil }
        let words = normalizedDescription.split(separator: " ").map(String.init)
        guard words.count >= 2,
              let amount = LocaleTolerantNumber.double(from: words[0]), amount.isFinite, amount > 0,
              let derived = RecipeUnit.normalized(words[1]), derived.isCount else { return nil }
        return derived
    }

    public var hasValidGramMeasure: Bool {
        amount.isFinite && amount > 0 && amount <= RecipeConversionLimits.maxGrams &&
            gramWeight.isFinite && gramWeight > 0 && gramWeight <= RecipeConversionLimits.maxGrams
    }

    public func grams(for quantity: Double) -> Double? {
        guard hasValidGramMeasure,
              quantity.isFinite, quantity > 0,
              quantity <= RecipeConversionLimits.maxGrams else { return nil }
        let gramsPerUnit = gramWeight / amount
        let grams = gramsPerUnit * quantity
        guard gramsPerUnit.isFinite, gramsPerUnit > 0,
              grams.isFinite, grams > 0,
              grams <= RecipeConversionLimits.maxGrams else { return nil }
        return grams
    }
}

/// How a meal row was assembled: from a meal definition, a recipe, or manually.
///
/// Decoded tolerantly on ``Meal`` with a parked token; distinct from the free-string
/// ``MealLogSource`` provenance token.
public nonisolated enum MealSource: String, Codable {
    case mealDefinition
    case recipe
    case manual
}

/// A running protein/carb/fat accumulator with derived 4/4/9 calories.
///
/// The transient sum type for day and recipe totals — unlike ``Macros`` it is not `Codable` and is
/// never persisted.
public nonisolated struct MacroTotals: Equatable {
    public var protein = 0
    public var carbs = 0
    public var fat = 0

    public init(protein: Int = 0, carbs: Int = 0, fat: Int = 0) {
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
    }

    public var calories: Int { Macros(protein: protein, carbs: carbs, fat: fat).calories }
}

/// The day's computed nutrition plan: calorie/macro/fiber targets plus sodium and saturated-fat
/// ceilings.
///
/// Produced by ``NutritionTargetCalculator/targets(for:)``; the `*Limit` fields are ceilings, not
/// goals, and render as such.
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

/// Derives ``NutritionTargets`` from settings: Mifflin-St Jeor RMR × activity, goal-adjusted.
///
/// User overrides pin calories/protein/fat individually and the plan re-solves around them — carbs
/// is always the residual, floored so pinning protein+fat high pushes the totals slightly above
/// the stated calories rather than going negative (see the inline note in `targets(for:)`).
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
            sodiumLimit: Int(FDADailyValues.sodiumLimitMilligrams),
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

/// When a meal was eaten (breakfast … post-workout).
///
/// Raw values are display strings AND persisted tokens; unknown values from newer builds park via
/// ``Meal``'s tolerant decode.
public nonisolated enum MealType: String, Codable, CaseIterable, Identifiable, Sendable {
    case breakfast = "Breakfast"
    case lunch = "Lunch"
    case dinner = "Dinner"
    case snack = "Snack"
    case preWorkout = "Pre-workout"
    case postWorkout = "Post-workout"

    public var id: String { rawValue }

    /// The localized slot name.
    ///
    /// This enum had no display property: `rawValue` WAS the picker text, so one string was the
    /// screen label, the persisted `Meal.mealType` (with a parked-token side channel that assumes
    /// these exact spellings), the vocabulary the meal-parsing prompt hands the model, and part of
    /// the trainer export. `rawValue` is FROZEN; this is the reader-facing half.
    public var displayName: String {
        switch self {
        case .breakfast: String(localized: "mealType.breakfast", defaultValue: "Breakfast",
                                bundle: .module, comment: "Meal slot")
        case .lunch: String(localized: "mealType.lunch", defaultValue: "Lunch",
                            bundle: .module, comment: "Meal slot")
        case .dinner: String(localized: "mealType.dinner", defaultValue: "Dinner",
                             bundle: .module, comment: "Meal slot")
        case .snack: String(localized: "mealType.snack", defaultValue: "Snack",
                            bundle: .module, comment: "Meal slot")
        case .preWorkout: String(localized: "mealType.preWorkout", defaultValue: "Pre-workout",
                                 bundle: .module, comment: "Meal slot: eaten before training")
        case .postWorkout: String(localized: "mealType.postWorkout", defaultValue: "Post-workout",
                                  bundle: .module, comment: "Meal slot: eaten after training")
        }
    }
}

/// The four-step meal quality rating (great/good/ok/low) shown on the meal row.
///
/// Assigned by the resolver (protein-driven via ``Macros/goodProteinThreshold``) or edited by the
/// user; decodes tolerantly on ``Meal``.
public nonisolated enum MealQuality: String, Codable, CaseIterable {
    case great, good, ok, low
}
