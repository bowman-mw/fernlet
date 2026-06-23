import SwiftUI

struct FernletDay: Codable {
    var date: String
    var meals: [Meal]
    var workouts: [Workout]
    var plannedWorkouts: [PlannedWorkout]
    var journals: [JournalEntry]
    var sleep: SleepLog?
    var bottleCount: Int
    var hygiene: Set<HygieneItem>
    var completedPersonalCareTaskIDs: Set<String>
    var healthContext: HealthDailyContext?

    init(
        date: String,
        meals: [Meal] = [],
        workouts: [Workout] = [],
        plannedWorkouts: [PlannedWorkout] = [],
        journals: [JournalEntry] = [],
        sleep: SleepLog? = nil,
        bottleCount: Int = 0,
        hygiene: Set<HygieneItem> = [],
        completedPersonalCareTaskIDs: Set<String>? = nil,
        healthContext: HealthDailyContext? = nil
    ) {
        self.date = date
        self.meals = meals
        self.workouts = workouts
        self.plannedWorkouts = plannedWorkouts
        self.journals = journals
        self.sleep = sleep
        self.bottleCount = bottleCount
        self.hygiene = hygiene
        self.completedPersonalCareTaskIDs = completedPersonalCareTaskIDs ?? Set(hygiene.map(\.rawValue))
        self.healthContext = healthContext
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        meals = try container.decodeIfPresent([Meal].self, forKey: .meals) ?? []
        workouts = try container.decodeIfPresent([Workout].self, forKey: .workouts) ?? []
        plannedWorkouts = try container.decodeIfPresent([PlannedWorkout].self, forKey: .plannedWorkouts) ?? []
        journals = try container.decodeIfPresent([JournalEntry].self, forKey: .journals) ?? []
        sleep = try container.decodeIfPresent(SleepLog.self, forKey: .sleep)
        bottleCount = try container.decodeIfPresent(Int.self, forKey: .bottleCount) ?? 0
        hygiene = try container.decodeIfPresent(Set<HygieneItem>.self, forKey: .hygiene) ?? []
        completedPersonalCareTaskIDs = try container.decodeIfPresent(Set<String>.self, forKey: .completedPersonalCareTaskIDs) ?? Set(hygiene.map(\.rawValue))
        healthContext = try container.decodeIfPresent(HealthDailyContext.self, forKey: .healthContext)
    }
}

struct HealthDailyContext: Codable, Equatable {
    var syncedAt = Date()
    var activity: HealthActivitySummary?
    var body: HealthBodyContext?
    var cycle: HealthCycleContext?
    var mindfulness: HealthMindfulnessContext?
    var intimate: HealthIntimateContext?

    mutating func merge(_ other: HealthDailyContext) {
        syncedAt = other.syncedAt
        activity = other.activity ?? activity
        body = other.body ?? body
        cycle = other.cycle ?? cycle
        mindfulness = other.mindfulness ?? mindfulness
        intimate = other.intimate ?? intimate
    }
}

struct HealthActivitySummary: Codable, Equatable {
    var steps: Int?
    var activeEnergyKilocalories: Double?
    var exerciseMinutes: Double?
}

struct HealthBodyContext: Codable, Equatable {
    var sleepHours: Double?
    var restingHeartRateBPM: Double?
    var heartRateVariabilityMS: Double?
}

struct HealthCycleContext: Codable, Equatable {
    var menstrualFlowEventCount: Int?
    var latestCycleEventAt: Date?
}

struct HealthMindfulnessContext: Codable, Equatable {
    var mindfulSessionMinutes: Double?
}

struct HealthIntimateContext: Codable, Equatable {
    var eventCount: Int?
}

struct FernletSettings: Codable {
    var bottleOz: Int = 24
    var hydrationTarget: Int = 4
    var showDeveloperNotes = false
    var connectionInspectorMode: ConnectionInspectorMode = .live
    var companionAppearance: CompanionAppearance = .standard
    var selectedGoal: GoalType = .wellness
    var isSick: Bool = false
    var aiStatus: AIStatus = .off
    var webNutritionLookupEnabled: Bool = false
    var showCalories: Bool = false
    var hasCompletedOnboarding: Bool = false
    var hidePredictions: Bool = false
    var hideFertileWindow: Bool = false
    var userProfile: UserNutritionProfile = UserNutritionProfile()
    var nutritionPreferences: UserNutritionPreferences = UserNutritionPreferences()
    var quickLogItems: [FernletShortcut] = FernletShortcut.defaultQuickLog
    var homeWidgets: [HomeWidget] = HomeWidget.defaultWidgets
    var personalCareTasks: [PersonalCareTask] = PersonalCareTask.defaultTasks
    var proximityDisplayName: String = ""
    var showProximityDebugTools: Bool = false
    var allowNearbyRecipeShares: Bool = true
    var companionName: String = ""

    nonisolated init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bottleOz = try container.decodeIfPresent(Int.self, forKey: .bottleOz) ?? 24
        hydrationTarget = try container.decodeIfPresent(Int.self, forKey: .hydrationTarget) ?? 4
        showDeveloperNotes = try container.decodeIfPresent(Bool.self, forKey: .showDeveloperNotes) ?? false
        connectionInspectorMode = try container.decodeIfPresent(ConnectionInspectorMode.self, forKey: .connectionInspectorMode) ?? .live
        companionAppearance = try container.decodeIfPresent(CompanionAppearance.self, forKey: .companionAppearance) ?? .standard
        selectedGoal = try container.decodeIfPresent(GoalType.self, forKey: .selectedGoal) ?? .wellness
        isSick = try container.decodeIfPresent(Bool.self, forKey: .isSick) ?? false
        aiStatus = try container.decodeIfPresent(AIStatus.self, forKey: .aiStatus) ?? .off
        webNutritionLookupEnabled = try container.decodeIfPresent(Bool.self, forKey: .webNutritionLookupEnabled) ?? false
        showCalories = try container.decodeIfPresent(Bool.self, forKey: .showCalories) ?? false
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        hidePredictions = try container.decodeIfPresent(Bool.self, forKey: .hidePredictions) ?? false
        hideFertileWindow = try container.decodeIfPresent(Bool.self, forKey: .hideFertileWindow) ?? false
        userProfile = try container.decodeIfPresent(UserNutritionProfile.self, forKey: .userProfile) ?? UserNutritionProfile()
        nutritionPreferences = try container.decodeIfPresent(UserNutritionPreferences.self, forKey: .nutritionPreferences) ?? UserNutritionPreferences()
        let decodedQuickLogItems = try container.decodeIfPresent([FernletShortcut].self, forKey: .quickLogItems) ?? FernletShortcut.defaultQuickLog
        quickLogItems = FernletShortcut.normalizedQuickLog(decodedQuickLogItems)
        let decodedHomeWidgets = try container.decodeIfPresent([HomeWidget].self, forKey: .homeWidgets) ?? HomeWidget.defaultWidgets
        homeWidgets = HomeWidget.normalized(decodedHomeWidgets)
        let decodedCareTasks = try container.decodeIfPresent([PersonalCareTask].self, forKey: .personalCareTasks) ?? PersonalCareTask.defaultTasks
        personalCareTasks = PersonalCareTask.normalized(decodedCareTasks)
        proximityDisplayName = try container.decodeIfPresent(String.self, forKey: .proximityDisplayName) ?? ""
        showProximityDebugTools = try container.decodeIfPresent(Bool.self, forKey: .showProximityDebugTools) ?? false
        allowNearbyRecipeShares = try container.decodeIfPresent(Bool.self, forKey: .allowNearbyRecipeShares) ?? true
        companionName = try container.decodeIfPresent(String.self, forKey: .companionName) ?? ""
    }
}

enum ConnectionInspectorMode: String, Codable, CaseIterable, Identifiable {
    case disabled
    case passive
    case live

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled: return "Disabled"
        case .passive: return "Passive"
        case .live: return "Live"
        }
    }
}

enum FernletScreen: String, Codable, CaseIterable, Identifiable {
    case food
    case move
    case journal
    case periodTracking
    case intimacyTracking
    case friends
    case photos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .food: "Food"
        case .move: "Move"
        case .journal: "Journal"
        case .periodTracking: "Period"
        case .intimacyTracking: "Intimacy"
        case .friends: "Friends"
        case .photos: "Photos"
        }
    }

    var subtitle: String {
        switch self {
        case .food: "Meals, macros, and recipes."
        case .move: "Training, walks, and recovery."
        case .journal: "Mood and short daily notes."
        case .periodTracking: "Cycle notes and Health context."
        case .intimacyTracking: "Private intimacy notes."
        case .friends: "People to remember."
        case .photos: "A small photo wall."
        }
    }

    var systemImage: String {
        switch self {
        case .food: "fork.knife"
        case .move: "figure.walk"
        case .journal: "book.closed.fill"
        case .periodTracking: "calendar.badge.clock"
        case .intimacyTracking: "lock.shield.fill"
        case .friends: "person.2.fill"
        case .photos: "photo.on.rectangle.fill"
        }
    }
}

enum HomeWidget: String, Codable, CaseIterable, Identifiable {
    case companion
    case todaySummary
    case todayIntent
    case quickLog
    case logFood
    case recipeBook
    case newRecipe
    case workout
    case journal
    case sleep
    case water
    case hygiene
    case macros
    case trends

    static let defaultWidgets: [HomeWidget] = [.companion, .todaySummary, .todayIntent, .quickLog, .macros]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .companion: "Companion"
        case .todaySummary: "Today"
        case .todayIntent: "Today's intent"
        case .quickLog: "Quick log"
        case .logFood: "Log food"
        case .recipeBook: "Recipe book"
        case .newRecipe: "New recipe"
        case .workout: "Workout"
        case .journal: "Journal"
        case .sleep: "Sleep"
        case .water: "Water"
        case .hygiene: "Hygiene"
        case .macros: "Macros"
        case .trends: "Trends"
        }
    }

    var systemImage: String {
        switch self {
        case .companion: "leaf.fill"
        case .todaySummary: "calendar"
        case .todayIntent: "sun.max"
        case .quickLog: "square.grid.2x2"
        case .logFood: "fork.knife"
        case .recipeBook: "book.closed"
        case .newRecipe: "plus.square.on.square"
        case .workout: "figure.strengthtraining.traditional"
        case .journal: "book.closed"
        case .sleep: "moon"
        case .water: "drop"
        case .hygiene: "checklist"
        case .macros: "chart.pie"
        case .trends: "chart.line.uptrend.xyaxis"
        }
    }

    var isAction: Bool {
        switch self {
        case .logFood, .recipeBook, .newRecipe, .workout, .journal, .sleep, .water, .hygiene, .trends:
            true
        case .companion, .todaySummary, .todayIntent, .quickLog, .macros:
            false
        }
    }

    static func normalized(_ widgets: [HomeWidget]) -> [HomeWidget] {
        var result: [HomeWidget] = []
        for widget in widgets where !result.contains(widget) {
            result.append(widget)
        }
        if result.isEmpty { return defaultWidgets }
        return result
    }
}

enum FernletShortcut: String, Codable, CaseIterable, Identifiable {
    case meal
    case water
    case move
    case sleep
    case journal
    case care
    case logPeriod
    case periodTracking
    case intimacyTracking
    case friends

    static let defaultQuickLog: [FernletShortcut] = [.meal, .water, .move, .sleep, .journal, .care]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meal: "Meal"
        case .water: "Water"
        case .move: "Move"
        case .sleep: "Sleep"
        case .journal: "Journal"
        case .care: "Care"
        case .logPeriod: "Log period"
        case .periodTracking: "Period"
        case .intimacyTracking: "Intimacy"
        case .friends: "Friends"
        }
    }

    var systemImage: String {
        switch self {
        case .meal: "fork.knife"
        case .water: "drop"
        case .move: "figure.walk"
        case .sleep: "moon"
        case .journal: "book.closed"
        case .care: "checklist"
        case .logPeriod: "drop.fill"
        case .periodTracking: "calendar.badge.clock"
        case .intimacyTracking: "lock.shield"
        case .friends: "person.2"
        }
    }

    var screen: FernletScreen? {
        switch self {
        case .move: .move
        case .journal: .journal
        case .periodTracking: .periodTracking
        case .intimacyTracking: .intimacyTracking
        case .friends: .friends
        case .meal, .water, .sleep, .care, .logPeriod:
            nil
        }
    }

    static func normalizedQuickLog(_ items: [FernletShortcut]) -> [FernletShortcut] {
        var result: [FernletShortcut] = []
        for item in items where !result.contains(item) {
            result.append(item)
            if result.count == 6 { break }
        }
        for item in defaultQuickLog where result.count < 6 && !result.contains(item) {
            result.append(item)
        }
        for item in allCases where result.count < 6 && !result.contains(item) {
            result.append(item)
        }
        return Array(result.prefix(6))
    }

    static func visibleQuickLog(_ items: [FernletShortcut], allowsIntimacy: Bool) -> [FernletShortcut] {
        let availableItems = allowsIntimacy ? items : items.filter { $0 != .intimacyTracking }
        return normalizedQuickLog(availableItems)
    }

    static func selectableQuickLogItems(allowsIntimacy: Bool) -> [FernletShortcut] {
        allCases.filter { allowsIntimacy || $0 != .intimacyTracking }
    }
}

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

enum AIStatus: String, Codable, CaseIterable, Identifiable {
    case ready
    case sleepy
    case resting
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ready: "Ready"
        case .sleepy: "Sleepy"
        case .resting: "Resting"
        case .off: "Off"
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

    private static func searchPhrases(from description: String) -> [String] {
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

struct RecipeDefinition: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var servings: Int
    var ingredients: [RecipeIngredient]
    var notes: String
    var source: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        servings: Int,
        ingredients: [RecipeIngredient],
        notes: String = "",
        source: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.servings = servings
        self.ingredients = ingredients
        self.notes = notes
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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

struct DailyHealthScore: Identifiable, Codable, Equatable {
    var id = UUID()
    var dateKey: String
    var score: Double
    var companionState: CompanionState
    var daySummaryText: String?
    var computedAt: Date

    init(id: UUID = UUID(), dateKey: String, score: Double, companionState: CompanionState, daySummaryText: String? = nil, computedAt: Date) {
        self.id = id; self.dateKey = dateKey; self.score = score; self.companionState = companionState; self.daySummaryText = daySummaryText; self.computedAt = computedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        dateKey = try c.decode(String.self, forKey: .dateKey)
        score = try c.decode(Double.self, forKey: .score)
        companionState = try c.decode(CompanionState.self, forKey: .companionState)
        daySummaryText = try c.decodeIfPresent(String.self, forKey: .daySummaryText)
        computedAt = try c.decodeIfPresent(Date.self, forKey: .computedAt) ?? Date()
    }
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

    var color: Color {
        switch self {
        case .breakfast: .goldenrod
        case .lunch: .fern
        case .dinner: .slate
        case .snack: .softTaupe
        case .preWorkout: .goldenrod
        case .postWorkout: .dustyRose
        }
    }
}

enum MealQuality: String, Codable, CaseIterable {
    case great, good, ok, low
}

struct Workout: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var type: WorkoutType
    var mode: WorkoutMode = .strengthTraining
    var activityType: WorkoutActivityType?
    var exercises: String
    var rpe: Double?
    var notes: String
    var duration: Int?
    var distanceMiles: Double?
    var activeEnergyKcal: Double?
    var effort: Int?
    var muscleGroups: Set<MuscleGroup> = []
    var healthKitUUID: UUID?
    var plannedWorkoutID: UUID?
    var intensity: WorkoutIntensity
    var completedAt = Date()
    var loggedAt = Date()

    var exerciseLines: [String] {
        exercises
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var inferredCategory: WorkoutType {
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

    init(
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
        self.intensity = intensity
        self.completedAt = completedAt
        self.loggedAt = loggedAt ?? completedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(WorkoutType.self, forKey: .type)
        mode = try container.decodeIfPresent(WorkoutMode.self, forKey: .mode) ?? .strengthTraining
        activityType = try container.decodeIfPresent(WorkoutActivityType.self, forKey: .activityType)
        exercises = try container.decode(String.self, forKey: .exercises)
        rpe = try container.decodeIfPresent(Double.self, forKey: .rpe)
        notes = try container.decode(String.self, forKey: .notes)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        distanceMiles = try container.decodeIfPresent(Double.self, forKey: .distanceMiles)
        activeEnergyKcal = try container.decodeIfPresent(Double.self, forKey: .activeEnergyKcal)
        effort = try container.decodeIfPresent(Int.self, forKey: .effort)
        muscleGroups = try container.decodeIfPresent(Set<MuscleGroup>.self, forKey: .muscleGroups) ?? []
        healthKitUUID = try container.decodeIfPresent(UUID.self, forKey: .healthKitUUID)
        plannedWorkoutID = try container.decodeIfPresent(UUID.self, forKey: .plannedWorkoutID)
        intensity = try container.decode(WorkoutIntensity.self, forKey: .intensity)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt) ?? Date()
        loggedAt = try container.decodeIfPresent(Date.self, forKey: .loggedAt) ?? completedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(activityType, forKey: .activityType)
        try container.encode(exercises, forKey: .exercises)
        try container.encodeIfPresent(rpe, forKey: .rpe)
        try container.encode(notes, forKey: .notes)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(distanceMiles, forKey: .distanceMiles)
        try container.encodeIfPresent(activeEnergyKcal, forKey: .activeEnergyKcal)
        try container.encodeIfPresent(effort, forKey: .effort)
        try container.encode(muscleGroups, forKey: .muscleGroups)
        try container.encodeIfPresent(healthKitUUID, forKey: .healthKitUUID)
        try container.encodeIfPresent(plannedWorkoutID, forKey: .plannedWorkoutID)
        try container.encode(intensity, forKey: .intensity)
        try container.encode(completedAt, forKey: .completedAt)
        try container.encode(loggedAt, forKey: .loggedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, type, mode, activityType, exercises, rpe, notes, duration
        case distanceMiles, activeEnergyKcal, effort, muscleGroups, healthKitUUID, plannedWorkoutID
        case intensity, completedAt, loggedAt
    }
}

struct PlannedWorkout: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var split: WorkoutSplit
    var source: WorkoutPlanSource
    var mode: WorkoutMode
    var activityType: WorkoutActivityType?
    var exercises: String
    var muscleGroups: Set<MuscleGroup>
    var notes: String
    var duration: Int?
    var targetDistanceMiles: Double?
    var targetEnergyKcal: Double?
    var targetEffort: Int?
    var createdAt = Date()

    var workoutType: WorkoutType { split.workoutType }

    var completedWorkout: Workout {
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

    init(
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        split = try container.decode(WorkoutSplit.self, forKey: .split)
        source = try container.decodeIfPresent(WorkoutPlanSource.self, forKey: .source) ?? .user
        mode = try container.decodeIfPresent(WorkoutMode.self, forKey: .mode) ?? .strengthTraining
        activityType = try container.decodeIfPresent(WorkoutActivityType.self, forKey: .activityType)
        exercises = try container.decodeIfPresent(String.self, forKey: .exercises) ?? ""
        muscleGroups = try container.decodeIfPresent(Set<MuscleGroup>.self, forKey: .muscleGroups) ?? []
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
    }
}

enum WorkoutPlanSource: String, Codable, CaseIterable, Identifiable {
    case user
    case coach

    var id: String { rawValue }

    var title: String {
        switch self {
        case .user: "User"
        case .coach: "Coach"
        }
    }

    var completionNote: String {
        switch self {
        case .user: "Completed from user plan."
        case .coach: "Completed from coach plan."
        }
    }
}

enum WorkoutSplit: String, Codable, CaseIterable, Identifiable {
    case workout
    case upper
    case lower
    case fullBody
    case push
    case pull
    case legs
    case cardio
    case recovery

    var id: String { rawValue }

    var title: String {
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

    var workoutType: WorkoutType {
        switch self {
        case .workout: .cardio
        case .upper, .push, .pull: .upper
        case .lower, .legs: .lower
        case .fullBody, .recovery: .fullBody
        case .cardio: .cardio
        }
    }

    var color: Color {
        switch self {
        case .workout: .terracotta
        case .upper, .push, .pull: .moss
        case .lower, .legs: .goldenrod
        case .fullBody, .recovery: .dustyRose
        case .cardio: .terracotta
        }
    }
}

enum WorkoutType: String, Codable, CaseIterable, Identifiable {
    case upper = "Upper"
    case lower = "Lower"
    case armsBack = "Arms/Back"
    case mixed = "Upper/Mixed"
    case fullBody = "Full Body"
    case cardio = "Cardio"
    case run = "C210K Run"
    case hike = "Hike"

    static let allCases: [WorkoutType] = [.upper, .lower, .fullBody, .cardio]

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .upper, .armsBack, .mixed:
            .moss
        case .lower:
            .goldenrod
        case .fullBody:
            .dustyRose
        case .cardio, .run, .hike:
            .terracotta
        }
    }
}

public enum WorkoutMode: String, Codable, CaseIterable, Identifiable {
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

public enum BodyRegion: String, Codable, CaseIterable {
    case upper
    case lower
    case core
    case full
}

public enum MuscleGroup: String, Codable, CaseIterable, Identifiable {
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
    nonisolated static func fromLegacyString(_ s: String) -> MuscleGroup? {
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

public enum MovementPattern: String, Codable, CaseIterable {
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

public enum Equipment: String, Codable, CaseIterable, Identifiable {
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

enum WorkoutActivityType: String, Codable, CaseIterable, Identifiable {
    case running, walking, hiking, cycling, indoorCycling
    case yoga, pilates, barre, dance, socialDance
    case swimmingPool, swimmingOpenWater, rowing, elliptical, stairClimbing, stairs
    case hiit, kickboxing, martialArts, climbing, jumpRope
    case tennis, basketball, soccer, pickleball, badminton, tableTennis, racquetball, squash
    case coreTraining, flexibility, mindAndBody, taiChi
    case functionalStrengthTraining, traditionalStrengthTraining
    case crossTraining, mixedCardio, preparationAndRecovery, cooldown
    case other

    var id: String { rawValue }

    var displayName: String {
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

    var systemImage: String {
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

    var expectsDistance: Bool {
        switch self {
        case .running, .walking, .hiking, .cycling, .swimmingPool, .swimmingOpenWater, .rowing:
            true
        case .indoorCycling, .yoga, .pilates, .barre, .dance, .socialDance, .elliptical, .stairClimbing, .stairs, .hiit, .kickboxing, .martialArts, .climbing, .jumpRope, .tennis, .basketball, .soccer, .pickleball, .badminton, .tableTennis, .racquetball, .squash, .coreTraining, .flexibility, .mindAndBody, .taiChi, .functionalStrengthTraining, .traditionalStrengthTraining, .crossTraining, .mixedCardio, .preparationAndRecovery, .cooldown, .other:
            false
        }
    }

    var expectsPace: Bool {
        switch self {
        case .running, .walking, .hiking:
            true
        case .cycling, .indoorCycling, .yoga, .pilates, .barre, .dance, .socialDance, .swimmingPool, .swimmingOpenWater, .rowing, .elliptical, .stairClimbing, .stairs, .hiit, .kickboxing, .martialArts, .climbing, .jumpRope, .tennis, .basketball, .soccer, .pickleball, .badminton, .tableTennis, .racquetball, .squash, .coreTraining, .flexibility, .mindAndBody, .taiChi, .functionalStrengthTraining, .traditionalStrengthTraining, .crossTraining, .mixedCardio, .preparationAndRecovery, .cooldown, .other:
            false
        }
    }

    var defaultDurationMinutes: Int {
        switch self {
        case .functionalStrengthTraining, .traditionalStrengthTraining:
            30
        case .yoga, .pilates, .barre, .flexibility, .mindAndBody, .taiChi:
            60
        case .running, .walking, .hiking, .cycling, .indoorCycling, .dance, .socialDance, .swimmingPool, .swimmingOpenWater, .rowing, .elliptical, .stairClimbing, .stairs, .hiit, .kickboxing, .martialArts, .climbing, .jumpRope, .tennis, .basketball, .soccer, .pickleball, .badminton, .tableTennis, .racquetball, .squash, .coreTraining, .crossTraining, .mixedCardio, .preparationAndRecovery, .cooldown, .other:
            45
        }
    }

    var fernletCategory: WorkoutType {
        switch self {
        case .running, .walking, .hiking, .cycling, .indoorCycling, .swimmingPool, .swimmingOpenWater, .rowing, .elliptical, .stairClimbing, .stairs, .jumpRope, .hiit, .crossTraining, .mixedCardio, .tennis, .basketball, .soccer, .pickleball, .badminton, .tableTennis, .racquetball, .squash:
            .cardio
        case .yoga, .pilates, .barre, .dance, .socialDance, .flexibility, .mindAndBody, .taiChi, .coreTraining, .functionalStrengthTraining, .traditionalStrengthTraining, .other, .preparationAndRecovery, .cooldown, .kickboxing, .martialArts, .climbing:
            .fullBody
        }
    }
}

enum WorkoutIntensity: String, Codable, CaseIterable, Identifiable {
    case light, moderate, hard
    var id: String { rawValue }
}

enum ExerciseInputKind: String, Codable {
    case strength
    case treadmill
    case none
}

struct ExerciseTarget: Identifiable, Codable, Equatable {
    var id: String { name }
    var name: String
    var primaryMuscles: Set<MuscleGroup>
    var secondaryMuscles: Set<MuscleGroup>
    var equipment: Equipment
    var movementPattern: MovementPattern
    var inputKind: ExerciseInputKind

    var bodyRegion: BodyRegion {
        let regions = Set(primaryMuscles.map { $0.region })
        if regions == [.upper] { return .upper }
        if regions == [.lower] { return .lower }
        if regions == [.core] { return .core }
        return .full
    }

    var category: WorkoutType {
        switch bodyRegion {
        case .upper: .upper
        case .lower: .lower
        case .core: .fullBody
        case .full: .fullBody
        }
    }

    var muscles: [String] {
        (primaryMuscles.union(secondaryMuscles))
            .sorted { $0.displayName < $1.displayName }
            .map(\.displayName)
    }

    init(
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

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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

enum WorkoutExerciseCatalog {
    static let baseExercises: [ExerciseTarget] = loadBaseExercises()

    static func inferredCategory(for workout: Workout) -> WorkoutType {
        inferredCategory(for: "\(workout.name)\n\(workout.exercises)")
    }

    static func inferredCategory(for text: String) -> WorkoutType {
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

    static func targetSummary(for workout: Workout) -> String {
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

    static func search(_ query: String) -> [ExerciseTarget] {
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

struct JournalEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var tag: FeelingTag
    var date = Date()
    var emotions: [String] = []

    init(id: UUID = UUID(), text: String, tag: FeelingTag, date: Date = Date(), emotions: [String] = []) {
        self.id = id; self.text = text; self.tag = tag; self.date = date; self.emotions = emotions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        tag = try c.decode(FeelingTag.self, forKey: .tag)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        emotions = try c.decodeIfPresent([String].self, forKey: .emotions) ?? []
    }
}

enum FeelingTag: String, Codable, CaseIterable, Identifiable {
    case bright, good, neutral, quiet, tired, hard

    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .bright: .sun
        case .good: .fern
        case .neutral: .softTaupe
        case .quiet: .slate
        case .tired: .dustyRose
        case .hard: .terracotta
        }
    }
}

struct SleepLog: Codable, Equatable {
    var hours: Double?
    var quality: SleepQuality
    var note: String
    var loggedAt = Date()

    init(hours: Double? = nil, quality: SleepQuality, note: String, loggedAt: Date = Date()) {
        self.hours = hours; self.quality = quality; self.note = note; self.loggedAt = loggedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hours = try c.decodeIfPresent(Double.self, forKey: .hours)
        quality = try c.decode(SleepQuality.self, forKey: .quality)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        loggedAt = try c.decodeIfPresent(Date.self, forKey: .loggedAt) ?? Date()
    }
}

enum SleepQuality: String, Codable, CaseIterable, Identifiable {
    case poor, ok, good, great

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var description: String {
        switch self {
        case .poor: "rough, broken, unrested"
        case .ok: "enough, not great"
        case .good: "solid, mostly through"
        case .great: "restorative, woke easy"
        }
    }
}

enum HygieneItem: String, Codable, CaseIterable, Identifiable {
    case teethAM, teethPM, floss, shower, deodorant, skincareAM, skincarePM, sunscreen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .teethAM: "Brush teeth AM"
        case .teethPM: "Brush teeth PM"
        case .floss: "Floss"
        case .shower: "Shower"
        case .deodorant: "Deodorant"
        case .skincareAM: "Skincare AM"
        case .skincarePM: "Skincare PM"
        case .sunscreen: "Sunscreen"
        }
    }

    var systemImage: String {
        switch self {
        case .teethAM, .teethPM: "mouth"
        case .floss: "checkmark.seal"
        case .shower: "shower"
        case .deodorant: "sparkle"
        case .skincareAM: "sun.max"
        case .skincarePM: "moon"
        case .sunscreen: "drop"
        }
    }

    var group: String {
        switch self {
        case .teethAM, .skincareAM, .sunscreen: "Morning"
        case .teethPM, .floss, .skincarePM: "Evening"
        case .shower, .deodorant: "Anytime"
        }
    }
}

struct PersonalCareTask: Identifiable, Codable, Equatable {
    var id: String
    var label: String
    var systemImage: String
    var group: String
    var defaultHygieneRawValue: String?

    static let groups = ["Morning", "Anytime", "Evening"]

    static var defaultTasks: [PersonalCareTask] {
        HygieneItem.allCases.map { item in
            PersonalCareTask(
                id: item.rawValue,
                label: item.label,
                systemImage: item.systemImage,
                group: item.group,
                defaultHygieneRawValue: item.rawValue
            )
        }
    }

    var defaultHygieneItem: HygieneItem? {
        guard let defaultHygieneRawValue else { return nil }
        return HygieneItem(rawValue: defaultHygieneRawValue)
    }

    static func custom(label: String, group: String) -> PersonalCareTask {
        PersonalCareTask(
            id: "custom-\(UUID().uuidString)",
            label: label,
            systemImage: "checkmark.circle",
            group: groups.contains(group) ? group : "Anytime",
            defaultHygieneRawValue: nil
        )
    }

    static func normalized(_ tasks: [PersonalCareTask]) -> [PersonalCareTask] {
        var seen: Set<String> = []
        let cleaned = tasks.compactMap { task -> PersonalCareTask? in
            let trimmedLabel = task.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.id.isEmpty, !trimmedLabel.isEmpty, !seen.contains(task.id) else { return nil }
            seen.insert(task.id)
            var normalizedTask = task
            normalizedTask.label = trimmedLabel
            normalizedTask.systemImage = task.systemImage.isEmpty ? "checkmark.circle" : task.systemImage
            normalizedTask.group = groups.contains(task.group) ? task.group : "Anytime"
            return normalizedTask
        }
        return cleaned.isEmpty ? defaultTasks : cleaned
    }
}

struct MemoryNote: Identifiable, Codable, Equatable {
    var id = UUID()
    var category: String
    var text: String
    var sourceDate = Date()

    init(id: UUID = UUID(), category: String, text: String, sourceDate: Date = Date()) {
        self.id = id; self.category = category; self.text = text; self.sourceDate = sourceDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        category = try c.decode(String.self, forKey: .category)
        text = try c.decode(String.self, forKey: .text)
        sourceDate = try c.decodeIfPresent(Date.self, forKey: .sourceDate) ?? Date()
    }

    static func fromJournal(text: String, tag: FeelingTag) -> MemoryNote? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return nil }
        let prefix = String(trimmed.prefix(120))
        return MemoryNote(category: tag.rawValue, text: prefix)
    }
}

struct FitnessGoal: Identifiable, Codable, Equatable {
    var id = UUID()
    var type: GoalType
    var goal: String
    var timeframe: String
    var metric: String
    var milestones: [String] = []
    var weeklyStructure: String?

    init(id: UUID = UUID(), type: GoalType, goal: String, timeframe: String, metric: String, milestones: [String] = [], weeklyStructure: String? = nil) {
        self.id = id; self.type = type; self.goal = goal; self.timeframe = timeframe; self.metric = metric; self.milestones = milestones; self.weeklyStructure = weeklyStructure
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try c.decode(GoalType.self, forKey: .type)
        goal = try c.decode(String.self, forKey: .goal)
        timeframe = try c.decodeIfPresent(String.self, forKey: .timeframe) ?? ""
        metric = try c.decodeIfPresent(String.self, forKey: .metric) ?? ""
        milestones = try c.decodeIfPresent([String].self, forKey: .milestones) ?? []
        weeklyStructure = try c.decodeIfPresent(String.self, forKey: .weeklyStructure)
    }
}

enum GoalType: String, Codable, CaseIterable, Identifiable {
    case wellness
    case strength
    case weightManagement
    case mentalHealth
    case recovery
    case exploring

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wellness: "Wellness"
        case .strength: "Strength"
        case .weightManagement: "Weight Management"
        case .mentalHealth: "Mental Health"
        case .recovery: "Recovery"
        case .exploring: "Exploring"
        }
    }

    var tagline: String {
        switch self {
        case .wellness: "Balanced daily care."
        case .strength: "Fuel, train, and recover."
        case .weightManagement: "Steady habits without pressure."
        case .mentalHealth: "Mood and steadiness first."
        case .recovery: "Rest, hydration, and gentle care."
        case .exploring: "Learn what feels useful."
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case Self.wellness.rawValue, "Wellness", "Short-term":
            self = .wellness
        case Self.strength.rawValue, "Strength", "Long-term":
            self = .strength
        case Self.weightManagement.rawValue, "Weight Management":
            self = .weightManagement
        case Self.mentalHealth.rawValue, "Mental Health":
            self = .mentalHealth
        case Self.recovery.rawValue, "Recovery":
            self = .recovery
        case Self.exploring.rawValue, "Exploring":
            self = .exploring
        default:
            self = .wellness
        }
    }
}


struct WorkshopData: Codable, Equatable {
    var textureEntries: [TextureEntry] = []
    var handoffEntries: [TextureEntry] = [
        TextureEntry(title: "Native handoff", body: "Core logging flows are now modeled as SwiftUI screens with local persistence.", tags: [.delight])
    ]
    var claudeNotesEntries: [TextureEntry] = [
        TextureEntry(title: "AI behavior", body: "External web AI calls are represented with deterministic local suggestions until an iOS API layer is added.", tags: [.tension])
    ]

    nonisolated init() {}

    init(textureEntries: [TextureEntry], handoffEntries: [TextureEntry], claudeNotesEntries: [TextureEntry]) {
        self.textureEntries = textureEntries
        self.handoffEntries = handoffEntries
        self.claudeNotesEntries = claudeNotesEntries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        textureEntries = try c.decodeIfPresent([TextureEntry].self, forKey: .textureEntries) ?? []
        handoffEntries = try c.decodeIfPresent([TextureEntry].self, forKey: .handoffEntries) ?? [
            TextureEntry(title: "Native handoff", body: "Core logging flows are now modeled as SwiftUI screens with local persistence.", tags: [.delight])
        ]
        claudeNotesEntries = try c.decodeIfPresent([TextureEntry].self, forKey: .claudeNotesEntries) ?? [
            TextureEntry(title: "AI behavior", body: "External web AI calls are represented with deterministic local suggestions until an iOS API caller is added.", tags: [.tension])
        ]
    }
}

struct TextureEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String = FernletDate.shortDate(for: .now) + " observation"
    var body: String
    var tags: Set<TextureTag>
    var createdAt = Date()

    init(id: UUID = UUID(), title: String = FernletDate.shortDate(for: .now) + " observation", body: String, tags: Set<TextureTag> = [], createdAt: Date = Date()) {
        self.id = id; self.title = title; self.body = body; self.tags = tags; self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? (FernletDate.shortDate(for: .now) + " observation")
        body = try c.decode(String.self, forKey: .body)
        tags = try c.decodeIfPresent(Set<TextureTag>.self, forKey: .tags) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

enum TextureTag: String, Codable, CaseIterable, Identifiable {
    case tension, delight, friction
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .tension: .terracotta
        case .delight: .moss
        case .friction: .goldenrod
        }
    }
}

struct CompanionAppearance: Codable, Equatable {
    var bodyStyle: CompanionBodyStyle = .circle
    var palette: CompanionPalette = .state
    var bodyColor: CompanionAssetColor = .state
    var bodyCustomColorHex: String?
    var accessory: CompanionAccessory = .sprout
    var accessoryColor: CompanionAssetColor = .fern
    var accessoryCustomColorHex: String?
    var clothing: CompanionClothing = .none
    var clothingColor: CompanionAssetColor = .terracotta
    var clothingCustomColorHex: String?
    var sideItem: CompanionSideItem = .none
    var sideItemColor: CompanionAssetColor = .bark
    var sideItemCustomColorHex: String?

    static let standard = CompanionAppearance()

    init(
        bodyStyle: CompanionBodyStyle = .circle,
        palette: CompanionPalette = .state,
        bodyColor: CompanionAssetColor = .state,
        bodyCustomColorHex: String? = nil,
        accessory: CompanionAccessory = .sprout,
        accessoryColor: CompanionAssetColor = .fern,
        accessoryCustomColorHex: String? = nil,
        clothing: CompanionClothing = .none,
        clothingColor: CompanionAssetColor = .terracotta,
        clothingCustomColorHex: String? = nil,
        sideItem: CompanionSideItem = .none,
        sideItemColor: CompanionAssetColor = .bark,
        sideItemCustomColorHex: String? = nil
    ) {
        self.bodyStyle = bodyStyle
        self.palette = palette
        self.bodyColor = bodyColor
        self.bodyCustomColorHex = bodyCustomColorHex
        self.accessory = accessory
        self.accessoryColor = accessoryColor
        self.accessoryCustomColorHex = accessoryCustomColorHex
        self.clothing = clothing
        self.clothingColor = clothingColor
        self.clothingCustomColorHex = clothingCustomColorHex
        self.sideItem = sideItem
        self.sideItemColor = sideItemColor
        self.sideItemCustomColorHex = sideItemCustomColorHex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bodyStyle = try container.decodeIfPresent(CompanionBodyStyle.self, forKey: .bodyStyle) ?? .circle
        palette = try container.decodeIfPresent(CompanionPalette.self, forKey: .palette) ?? .state
        bodyColor = try container.decodeIfPresent(CompanionAssetColor.self, forKey: .bodyColor) ?? CompanionAssetColor(palette: palette)
        bodyCustomColorHex = try container.decodeIfPresent(String.self, forKey: .bodyCustomColorHex)
        accessory = try container.decodeIfPresent(CompanionAccessory.self, forKey: .accessory) ?? .sprout
        accessoryColor = try container.decodeIfPresent(CompanionAssetColor.self, forKey: .accessoryColor) ?? .fern
        accessoryCustomColorHex = try container.decodeIfPresent(String.self, forKey: .accessoryCustomColorHex)
        clothing = try container.decodeIfPresent(CompanionClothing.self, forKey: .clothing) ?? .none
        clothingColor = try container.decodeIfPresent(CompanionAssetColor.self, forKey: .clothingColor) ?? .terracotta
        clothingCustomColorHex = try container.decodeIfPresent(String.self, forKey: .clothingCustomColorHex)
        sideItem = try container.decodeIfPresent(CompanionSideItem.self, forKey: .sideItem) ?? .none
        sideItemColor = try container.decodeIfPresent(CompanionAssetColor.self, forKey: .sideItemColor) ?? .bark
        sideItemCustomColorHex = try container.decodeIfPresent(String.self, forKey: .sideItemCustomColorHex)
    }
}

enum CompanionBodyStyle: String, Codable, CaseIterable, Identifiable {
    case circle
    case softBlob
    case pear
    case puddle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .circle: "Circle"
        case .softBlob: "Soft"
        case .pear: "Pear"
        case .puddle: "Puddle"
        }
    }
}

enum CompanionPalette: String, Codable, CaseIterable, Identifiable {
    case state
    case fern
    case rose
    case sun
    case slate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .state: "Mood"
        case .fern: "Fern"
        case .rose: "Rose"
        case .sun: "Sun"
        case .slate: "Slate"
        }
    }

    func color(for state: CompanionState) -> Color {
        switch self {
        case .state: state.color
        case .fern: .fern
        case .rose: .dustyRose
        case .sun: .sun
        case .slate: .slate
        }
    }
}

enum CompanionAssetColor: String, Codable, CaseIterable, Identifiable {
    case state
    case moss
    case fern
    case rose
    case sun
    case slate
    case terracotta
    case cream
    case bark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .state: "Mood"
        case .moss: "Moss"
        case .fern: "Fern"
        case .rose: "Rose"
        case .sun: "Sun"
        case .slate: "Slate"
        case .terracotta: "Clay"
        case .cream: "Cream"
        case .bark: "Bark"
        }
    }

    init(palette: CompanionPalette) {
        switch palette {
        case .state: self = .state
        case .fern: self = .fern
        case .rose: self = .rose
        case .sun: self = .sun
        case .slate: self = .slate
        }
    }

    func color(for state: CompanionState) -> Color {
        switch self {
        case .state: state.color
        case .moss: .moss
        case .fern: .fern
        case .rose: .dustyRose
        case .sun: .sun
        case .slate: .slate
        case .terracotta: .terracotta
        case .cream: .cream
        case .bark: .bark
        }
    }
}

enum CompanionAccessory: String, Codable, CaseIterable, Identifiable {
    case none
    case sprout
    case flower
    case glasses

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .sprout: "Sprout"
        case .flower: "Flower"
        case .glasses: "Glasses"
        }
    }
}

enum CompanionClothing: String, Codable, CaseIterable, Identifiable {
    case none
    case scarf
    case sleepCap

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .scarf: "Scarf"
        case .sleepCap: "Sleep cap"
        }
    }
}

enum CompanionSideItem: String, Codable, CaseIterable, Identifiable {
    case none
    case mug
    case book
    case dumbbell
    case waterBottle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .mug: "Mug"
        case .book: "Book"
        case .dumbbell: "Weight"
        case .waterBottle: "Bottle"
        }
    }

    var systemImage: String {
        switch self {
        case .none: "circle.slash"
        case .mug: "mug"
        case .book: "book.closed"
        case .dumbbell: "dumbbell"
        case .waterBottle: "waterbottle"
        }
    }
}

enum CompanionState: String, Codable {
    case thriving = "Thriving"
    case okay = "Okay"
    case tired = "Tired"
    case resting = "Resting"
    case sick = "Sick"

    var color: Color {
        switch self {
        case .thriving: .moss
        case .okay: .goldenrod
        case .tired: .dustyRose
        case .resting: .slate
        case .sick: .terracotta
        }
    }
}

// MARK: - Core Logic
