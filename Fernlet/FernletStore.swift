import SwiftUI
import Combine
import HealthKit

@MainActor
final class FernletStore: ObservableObject {
    @Published var day: FernletDay
    @Published var settings: FernletSettings
    @Published var recentMeals: [Meal]
    @Published var previousJournals: [JournalEntry]
    @Published var memories: [MemoryNote]
    @Published var goals: [FitnessGoal]
    @Published var workshop: WorkshopData
    @Published var retryQueue: [AIAnalysisRetryRecord]
    @Published var foodItems: [FoodItem]
    @Published var recipes: [RecipeDefinition]
    @Published var dailyScores: [DailyHealthScore]
    @Published var connectionSessionLogs: [ConnectionSessionLog]
    @Published var trustedProximityPeers: [ProximityTrustedPeerRecord]
    @Published var trainerAuditEvents: [TrainerAuditEvent]
    @Published var showConnectionInspector = false
    @Published var connectionInspector = ConnectionInspector()
    @Published var savedRecipes: [SavedRecipe]
    @Published var companionThought: String?
    @Published var photowallSeeds: [PhotowallSeed] = []
    @Published private(set) var derivedSignals: [DerivedSignalRecord] = []
    @Published private(set) var bundledFoodSeedingState: SeedingState = .notStarted
    @Published var lockState: FernletLockState = .notConfigured

    enum SeedingState {
        case notStarted
        case seeding
        case done
        case failed
    }

    private static let goodProteinThreshold = 25
    let todayKey: String
    private let repository: FernletRepository
    private let savedRecipeRepository: SavedRecipeRepository
    private let healthKitService: (any HealthKitServicing)?
    private var snapshotSaveTask: Task<Void, Never>?
    private var savedRecipeSaveScheduled = false
    private var deferredPostLaunchTasksStarted = false
    private var launchScreenDismissed = false
    private var bundledFoodSeedSavePending = false
    private var remoteReloadTask: Task<Void, Never>?
    private var isReloadingFromRepository = false
    private var cancellables = Set<AnyCancellable>()

    init(date: Date = .now, repository: FernletRepository? = nil, savedRecipeRepository: SavedRecipeRepository? = nil, healthKitService: (any HealthKitServicing)? = nil) {
        let initSignpostID = StartupTiming.begin("FernletStore.init")
        defer { StartupTiming.end("FernletStore.init", signpostID: initSignpostID) }

        let key = FernletDate.dayKey(for: date)
        assert(!key.isEmpty, "today key required")
        let activeRepository = StartupTiming.timed("CoreDataFernletRepository.init") {
            repository ?? CoreDataFernletRepository()
        }
        let savedRecipeRepository = StartupTiming.timed("SavedRecipeRepository.init") {
            savedRecipeRepository ?? SavedRecipeRepository()
        }
        let snapshot = StartupTiming.timed("FernletRepository.loadSnapshot") {
            activeRepository.loadSnapshot(todayKey: key)
        }
        self.todayKey = key
        self.repository = activeRepository
        self.savedRecipeRepository = savedRecipeRepository
        self.healthKitService = healthKitService
        self.day = snapshot.day
        self.settings = snapshot.settings
        self.recentMeals = snapshot.recentMeals
        self.previousJournals = snapshot.previousJournals
        self.memories = snapshot.memories
        self.goals = snapshot.goals
        self.workshop = snapshot.workshop
        self.retryQueue = snapshot.retryQueue
        self.foodItems = snapshot.foodItems
        self.recipes = snapshot.recipes
        self.dailyScores = snapshot.dailyScores
        self.connectionSessionLogs = snapshot.connectionSessionLogs
        self.trustedProximityPeers = snapshot.trustedProximityPeers
        self.trainerAuditEvents = snapshot.trainerAuditEvents
        self.savedRecipes = StartupTiming.timed("SavedRecipeRepository.load") {
            savedRecipeRepository.load()
        }
        self.connectionInspector.attachStore(self)
        rebuildDerivedSignals()
        subscribeToRemoteChangesIfNeeded()
    }

    private init(
        snapshot: FernletSnapshot,
        savedRecipes: [SavedRecipe],
        todayKey: String,
        repository: FernletRepository,
        savedRecipeRepository: SavedRecipeRepository,
        healthKitService: (any HealthKitServicing)? = nil
    ) {
        self.todayKey = todayKey
        self.repository = repository
        self.savedRecipeRepository = savedRecipeRepository
        self.healthKitService = healthKitService
        self.day = snapshot.day
        self.settings = snapshot.settings
        self.recentMeals = snapshot.recentMeals
        self.previousJournals = snapshot.previousJournals
        self.memories = snapshot.memories
        self.goals = snapshot.goals
        self.workshop = snapshot.workshop
        self.retryQueue = snapshot.retryQueue
        self.foodItems = snapshot.foodItems
        self.recipes = snapshot.recipes
        self.dailyScores = snapshot.dailyScores
        self.connectionSessionLogs = snapshot.connectionSessionLogs
        self.trustedProximityPeers = snapshot.trustedProximityPeers
        self.trainerAuditEvents = snapshot.trainerAuditEvents
        self.savedRecipes = savedRecipes
        self.connectionInspector.attachStore(self)
        subscribeToRemoteChangesIfNeeded()
    }

    private func subscribeToRemoteChangesIfNeeded() {
        guard let coreDataRepo = repository as? CoreDataFernletRepository else { return }
        coreDataRepo.remoteChangeSubject
            .sink { [weak self] in
                self?.scheduleRemoteRepositoryReload()
            }
            .store(in: &cancellables)
    }

    var score: Double {
        FernletScoring.compute(for: self)
    }

    var companionState: CompanionState {
        FernletScoring.state(for: score, isSick: settings.isSick)
    }

    var macroTotals: MacroTotals {
        day.meals.reduce(into: MacroTotals()) { partial, meal in
            partial.protein += meal.macros.protein
            partial.carbs += meal.macros.carbs
            partial.fat += meal.macros.fat
        }
    }

    var micronutrientTotals: Micronutrients {
        day.meals.reduce(into: Micronutrients()) { partial, meal in
            partial.add(meal.micronutrientSnapshot)
        }
    }

    var nutritionTargets: NutritionTargets {
        NutritionTargetCalculator.targets(for: settings)
    }

    var tierTwoMemories: [TierTwoMemoryRecord] {
        repository.loadTierTwoMemories()
    }

    var personalCareTasks: [PersonalCareTask] {
        PersonalCareTask.normalized(settings.personalCareTasks)
    }

    func personalCareProgress(for targetDay: FernletDay? = nil) -> (completed: Int, total: Int) {
        let activeDay = targetDay ?? day
        let tasks = personalCareTasks
        let completed = tasks.filter { isPersonalCareTaskCompleted($0, in: activeDay) }.count
        return (completed, tasks.count)
    }

    func isPersonalCareTaskCompleted(_ task: PersonalCareTask, in targetDay: FernletDay? = nil) -> Bool {
        let activeDay = targetDay ?? day
        if activeDay.completedPersonalCareTaskIDs.contains(task.id) { return true }
        if let item = task.defaultHygieneItem {
            return activeDay.hygiene.contains(item)
        }
        return false
    }

    // Returns a character-capped string of active Tier 2 inferences for FM prompt injection.
    // Keeps only medium/high-confidence active records and stops before exceeding maxChars,
    // so callers never need to worry about blowing the on-device model's context budget.
    func tierTwoContextSummary(maxChars: Int = 400) -> String {
        let active = tierTwoMemories
            .filter { $0.active && $0.confidence != "low" }
            .sorted { $0.extractedDate > $1.extractedDate }
        var parts: [String] = []
        var used = 0
        for record in active {
            let line = record.text
            let needed = line.count + (parts.isEmpty ? 0 : 2)
            if used + needed > maxChars { break }
            parts.append(line)
            used += needed
        }
        return parts.joined(separator: " ")
    }

    func storeDaySummary(_ text: String, for dateKey: String) {
        assert(!dateKey.isEmpty, "date key required")
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        guard !trimmed.isEmpty else { return }
        batchSnapshotPersistence {
            if let index = dailyScores.firstIndex(where: { $0.dateKey == dateKey }) {
                dailyScores[index].daySummaryText = trimmed
            } else {
                let targetDay = loadDay(for: dateKey)
                var healthScore = dailyHealthScore(for: dateKey, day: targetDay)
                healthScore.daySummaryText = trimmed
                dailyScores.append(healthScore)
            }
        }
    }

    func invalidateDaySummary(for dateKey: String) {
        assert(!dateKey.isEmpty, "date key required")
        guard let index = dailyScores.firstIndex(where: { $0.dateKey == dateKey }) else { return }
        dailyScores[index].daySummaryText = nil
        scheduleSnapshotSave()
    }

    func storeCompanionThought(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        companionThought = trimmed
    }

    var storageLocation: String {
        repository.storageDescription()
    }

    var pendingRetryCount: Int {
        retryQueue.count
    }

    var isIntimateLoggingAllowed: Bool {
        settings.userProfile.age >= 18
    }

    func setHidePredictions(_ hidePredictions: Bool) {
        settings.hidePredictions = hidePredictions
        scheduleSnapshotSave()
    }

    func setHideFertileWindow(_ hideFertileWindow: Bool) {
        settings.hideFertileWindow = hideFertileWindow
        scheduleSnapshotSave()
    }

    func setConnectionInspectorMode(_ mode: ConnectionInspectorMode) {
        settings.connectionInspectorMode = mode
        if mode != .live {
            showConnectionInspector = false
        }
        scheduleSnapshotSave()
    }

    func setProximityDisplayName(_ name: String) {
        settings.proximityDisplayName = name.trimmingCharacters(in: .whitespaces)
        scheduleSnapshotSave()
    }

    func replaceConnectionSessionLogs(_ logs: [ConnectionSessionLog]) {
        connectionSessionLogs = Array(logs.sorted { $0.startedAt > $1.startedAt }.prefix(50))
        scheduleSnapshotSave()
    }

    func trustedProximityPeer(fingerprint: String) -> ProximityTrustedPeerRecord? {
        trustedProximityPeers.first { $0.fingerprint == fingerprint }
    }

    func trustedProximityPeer(displayName: String) -> ProximityTrustedPeerRecord? {
        trustedProximityPeers
            .filter { $0.displayName == displayName }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
            .first
    }

    func trustProximityPeer(_ peer: ProximityCoordinator.PeerIdentity, mode: ProximityCoordinator.Mode) {
        batchSnapshotPersistence {
            if let index = trustedProximityPeers.firstIndex(where: { $0.fingerprint == peer.fingerprint }) {
                trustedProximityPeers[index].displayName = peer.displayName
                trustedProximityPeers[index].keyAgreementPublicKey = peer.keyAgreementPublicKey
                trustedProximityPeers[index].mode = mode
                trustedProximityPeers[index].lastSeenAt = Date()
                trustedProximityPeers[index].revokedAt = nil
            } else {
                trustedProximityPeers.append(ProximityTrustedPeerRecord(
                    displayName: peer.displayName,
                    fingerprint: peer.fingerprint,
                    signingPublicKey: peer.signingPublicKey,
                    keyAgreementPublicKey: peer.keyAgreementPublicKey,
                    mode: mode
                ))
            }
        }
    }

    func revokeTrustedProximityPeer(fingerprint: String) {
        batchSnapshotPersistence {
            if let index = trustedProximityPeers.firstIndex(where: { $0.fingerprint == fingerprint }) {
                trustedProximityPeers[index].revokedAt = Date()
                recordTrainerAuditWithoutSaving(TrainerAuditEvent(
                    kind: .trainerRevoked,
                    peerFingerprint: trustedProximityPeers[index].fingerprint,
                    peerDisplayName: trustedProximityPeers[index].displayName,
                    message: "Revoked \(trustedProximityPeers[index].displayName)"
                ))
            }
        }
    }

    func isRevokedProximitySigningKey(_ publicKey: Data) -> Bool {
        let fingerprint = IdentityService.fingerprint(of: publicKey)
        return trustedProximityPeers.contains { record in
            record.fingerprint == fingerprint && record.revokedAt != nil
        }
    }

    func isTrustedProximityPeer(fingerprint: String) -> Bool {
        trustedProximityPeers.contains { $0.fingerprint == fingerprint && $0.revokedAt == nil }
    }

    func recordTrainerAudit(_ event: TrainerAuditEvent) {
        batchSnapshotPersistence {
            recordTrainerAuditWithoutSaving(event)
        }
    }

    private func recordTrainerAuditWithoutSaving(_ event: TrainerAuditEvent) {
        trainerAuditEvents.insert(event, at: 0)
        trainerAuditEvents = Array(trainerAuditEvents.prefix(500))
    }

    func setHomeWidgets(_ widgets: [HomeWidget]) {
        settings.homeWidgets = HomeWidget.normalized(widgets)
        scheduleSnapshotSave()
    }

    func setQuickLogItems(_ items: [FernletShortcut]) {
        settings.quickLogItems = FernletShortcut.normalizedQuickLog(items)
        scheduleSnapshotSave()
    }

    func allowedHealthCapabilities(from capabilities: Set<HealthCapability>) -> Set<HealthCapability> {
        var allowed = isIntimateLoggingAllowed ? capabilities : capabilities.subtracting([.intimateLogging])
        if lockState != .unlocked {
            allowed.remove(.cycleTracking)
        }
        return allowed
    }

    var visibleHealthCapabilities: [HealthCapability] {
        HealthCapability.allCases.filter { capability in
            capability != .intimateLogging || isIntimateLoggingAllowed
        }
    }

    @discardableResult func addMeal(from description: String, type: MealType? = nil) -> Meal {
        addMeal(from: description, type: type, date: todayKey)
    }

    @discardableResult func addMeal(from description: String, type: MealType? = nil, date: String) -> Meal {
        assert(!date.isEmpty, "meal date required")
        let parsed = MealParser.parse(description, fallbackType: type)
        appendMeal(parsed, date: date)
        return parsed
    }

    @discardableResult func addResolvedMeal(from description: String, type: MealType? = nil, date: String? = nil) async -> Meal {
        let meals = await addResolvedMeals(from: description, type: type, date: date)
        guard let first = meals.first else {
            return addMeal(from: description, type: type, date: date ?? todayKey)
        }
        return first
    }

    @discardableResult func addResolvedMeals(from description: String, type: MealType? = nil, date: String? = nil) async -> [Meal] {
        let targetDate = date ?? todayKey
        assert(!targetDate.isEmpty, "meal date required")
        let candidates = FoodSelectionCandidateBuilder.candidates(for: description, foodItems: foodItems)
        if settings.aiStatus != .off {
            do {
                if let plan = try await FoundationFoodSelectionModel.resolve(description: description, candidates: candidates, fallbackType: type),
                   plan.items.count >= MealItemSplitter.items(from: description).count,
                   let meals = meals(from: plan, candidates: candidates, originalDescription: description), meals.isEmpty == false {
                    meals.forEach { appendMeal($0, date: targetDate) }
                    return meals
                }
            } catch {
                // The local parser below keeps logging available when model generation fails.
            }
        }
        if let plan = FoundationFoodSelectionModel.deterministicPlan(description: description, candidates: candidates, fallbackType: type),
           let meals = meals(from: plan, candidates: candidates, originalDescription: description), meals.isEmpty == false {
            meals.forEach { appendMeal($0, date: targetDate) }
            return meals
        }
        let fallback = addMeal(from: description, type: type, date: targetDate)
        queueMealRetry(fallback)
        return [fallback]
    }

    private func appendMeal(_ meal: Meal, date: String) {
        assert(!date.isEmpty, "meal date required")
        batchSnapshotPersistence {
            if date == todayKey {
                day.meals.append(meal)
            } else {
                mutatePastDay(date) { $0.meals.append(meal) }
            }
            invalidateDaySummary(for: date)
            recentMeals.insert(meal.copyForToday(), at: 0)
            recentMeals = Array(recentMeals.prefix(50))
        }
    }

    private func meals(from plan: FoodSelectionPlan, candidates: [FoodSelectionCandidate], originalDescription: String) -> [Meal]? {
        let meals = plan.items.compactMap { item -> Meal? in
            if let recipe = bestRecipeMatch(for: item.name, recipes: recipes) {
                return meal(from: recipe, mealType: plan.mealType)
            }

            let relevantIngredients = item.ingredients.filter { ingredient in
                guard let foodItem = candidates.first(where: { $0.id == ingredient.candidateId })?.foodItem else { return false }
                return isRelevant(foodItem: foodItem, to: item.name)
            }
            let sourceIngredients = relevantIngredients.isEmpty
                ? FoundationFoodSelectionModel.deterministicPlan(description: item.name, candidates: candidates, fallbackType: plan.mealType)?.ingredients ?? []
                : relevantIngredients
            let resolved = sourceIngredients.compactMap { ingredient -> (FoodSelectionIngredient, FoodItem)? in
                guard let foodItem = candidates.first(where: { $0.id == ingredient.candidateId })?.foodItem else { return nil }
                return (ingredient, foodItem)
            }
            guard resolved.isEmpty == false else { return nil }

            if resolved.count > 1 {
                let recipe = createRecipeIfNeeded(for: item.name, resolvedIngredients: resolved)
                return meal(from: recipe, mealType: plan.mealType)
            }

            return meal(from: item.name, resolvedIngredients: resolved, mealType: plan.mealType)
        }
        return meals.isEmpty ? nil : meals
    }

    private func makeMealFromRecipe(_ recipe: RecipeDefinition, mealType: MealType) -> Meal {
        let totals = macroTotals(for: recipe)
        let micronutrients = micronutrientTotals(for: recipe)
        let divisor = max(recipe.servings, 1)
        let perServing = Macros(
            protein: Int((Double(totals.protein) / Double(divisor)).rounded()),
            carbs: Int((Double(totals.carbs) / Double(divisor)).rounded()),
            fat: Int((Double(totals.fat) / Double(divisor)).rounded())
        )
        return Meal(
            name: recipe.name,
            mealType: mealType,
            macros: perServing,
            macroSnapshot: perServing,
            micronutrientSnapshot: micronutrients.scaled(by: 1 / Double(divisor)),
            mealSource: .recipe,
            isAIFallback: false,
            quality: perServing.protein >= Self.goodProteinThreshold ? .good : .ok,
            confidence: "Recipe",
            note: "Logged from saved recipe.",
            source: mealLogSource(for: recipe)
        )
    }

    private func meal(from recipe: RecipeDefinition, mealType: MealType) -> Meal {
        makeMealFromRecipe(recipe, mealType: mealType)
    }

    private func meal(from itemName: String, resolvedIngredients: [(FoodSelectionIngredient, FoodItem)], mealType: MealType) -> Meal {
        let totals = totals(for: resolvedIngredients)
        let ingredientText = resolvedIngredients
            .prefix(3)
            .map { "\($0.0.quantity.formatted(.number.precision(.fractionLength(0...1)))) \($0.0.unit) \($0.1.name)" }
            .joined(separator: ", ")

        return Meal(
            name: itemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? resolvedIngredients[0].1.name : itemName.capitalized,
            mealType: mealType,
            macros: Macros(protein: totals.macros.protein, carbs: totals.macros.carbs, fat: totals.macros.fat),
            macroSnapshot: Macros(protein: totals.macros.protein, carbs: totals.macros.carbs, fat: totals.macros.fat),
            micronutrientSnapshot: totals.micronutrients,
            mealSource: .manual,
            isAIFallback: false,
            quality: totals.macros.protein >= Self.goodProteinThreshold ? .good : .ok,
            confidence: "Food match",
            note: "Matched locally from food selection: \(ingredientText).",
            source: MealLogSource.foundationModelFoodSelection
        )
    }

    private func mealLogSource(for recipe: RecipeDefinition) -> String {
        if recipe.source == MealLogSource.webImport || recipe.source == "imported" {
            return MealLogSource.webImport
        }

        let recipeFoodItems = recipe.ingredients.compactMap { ingredient in
            foodItems.first(where: { $0.id == ingredient.foodItemId })
        }
        if recipeFoodItems.contains(where: { $0.source == .usda }) {
            return MealLogSource.usdaRecipe
        }
        if recipeFoodItems.contains(where: { $0.micronutrients.populatedFieldCount >= 5 }) {
            return MealLogSource.labelScan
        }
        return MealLogSource.manual
    }

    private func createRecipeIfNeeded(for itemName: String, resolvedIngredients: [(FoodSelectionIngredient, FoodItem)]) -> RecipeDefinition {
        if let existing = bestRecipeMatch(for: itemName, recipes: recipes) {
            return existing
        }
        let now = Date()
        let recipeIngredients = resolvedIngredients.map { resolvedIngredient in
            RecipeIngredient(
                foodItemId: resolvedIngredient.1.id,
                quantity: resolvedIngredient.0.quantity,
                unit: resolvedIngredient.0.unit
            )
        }
        let recipe = RecipeDefinition(
            name: itemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Meal item" : itemName.capitalized,
            servings: 1,
            ingredients: recipeIngredients,
            notes: "Created from meal logging.",
            source: "meal-log",
            createdAt: now,
            updatedAt: now
        )
        recipes.insert(recipe, at: 0)
        return recipe
    }

    private func totals(for resolvedIngredients: [(FoodSelectionIngredient, FoodItem)]) -> (macros: MacroTotals, micronutrients: Micronutrients) {
        resolvedIngredients.reduce(into: (macros: MacroTotals(), micronutrients: Micronutrients())) { totals, resolvedIngredient in
            let ingredient = RecipeIngredient(
                foodItemId: resolvedIngredient.1.id,
                quantity: resolvedIngredient.0.quantity,
                unit: resolvedIngredient.0.unit
            )
            let scaled = ingredient.scaledMacros(using: resolvedIngredient.1)
            totals.macros.protein += scaled.protein
            totals.macros.carbs += scaled.carbs
            totals.macros.fat += scaled.fat
            totals.micronutrients.add(ingredient.scaledMicronutrients(using: resolvedIngredient.1))
        }
    }

    private func bestRecipeMatch(for itemName: String, recipes: [RecipeDefinition]) -> RecipeDefinition? {
        let normalizedItem = FoodItemSearch.normalized(itemName)
        guard normalizedItem.count >= 3 else { return nil }
        let itemTokens = Set(normalizedItem.split(separator: " ").map(String.init))
        return recipes
            .map { recipe -> (recipe: RecipeDefinition, score: Int)? in
                let normalizedRecipe = FoodItemSearch.normalized(recipe.name)
                let recipeTokens = Set(normalizedRecipe.split(separator: " ").map(String.init))
                if normalizedRecipe == normalizedItem { return (recipe, 1_000) }
                if normalizedRecipe.contains(normalizedItem) || normalizedItem.contains(normalizedRecipe) { return (recipe, 700) }
                let overlap = itemTokens.intersection(recipeTokens).count
                guard overlap >= max(1, min(itemTokens.count, recipeTokens.count) - 1) else { return nil }
                return (recipe, overlap * 100)
            }
            .compactMap { $0 }
            .sorted { first, second in
                if first.score != second.score { return first.score > second.score }
                return first.recipe.updatedAt > second.recipe.updatedAt
            }
            .first?.recipe
    }

    private func isRelevant(foodItem: FoodItem, to itemName: String) -> Bool {
        let itemTokens = Set(FoodItemSearch.normalized(itemName).split(separator: " ").map(String.init).filter { $0.count >= 3 })
        let foodText = FoodItemSearch.normalized("\(foodItem.name) \(foodItem.category) \(foodItem.tags.joined(separator: " "))")
        let foodTokens = Set(foodText.split(separator: " ").map(String.init).filter { $0.count >= 3 })
        guard itemTokens.isEmpty == false else { return true }
        if itemTokens.intersection(foodTokens).isEmpty == false { return true }
        if itemTokens.contains("sandwich") && (foodTokens.contains("bread") || foodTokens.contains("cheese")) { return true }
        if itemTokens.contains("grilled") && itemTokens.contains("cheese") && (foodTokens.contains("bread") || foodTokens.contains("sourdough")) { return true }
        return false
    }

    @discardableResult func copyMeal(_ meal: Meal) -> Meal {
        let copiedMeal = meal.copyForToday()
        batchSnapshotPersistence {
            day.meals.append(copiedMeal)
        }
        return copiedMeal
    }

    func deleteMeal(_ meal: Meal) {
        batchSnapshotPersistence {
            day.meals.removeAll { $0.id == meal.id }
        }
    }

    @discardableResult func logRecipe(_ recipe: RecipeDefinition, mealType: MealType? = nil, date: String? = nil) -> Meal {
        let targetDate = date ?? todayKey
        assert(!targetDate.isEmpty, "recipe meal date required")
        let meal = makeMealFromRecipe(recipe, mealType: mealType ?? MealParser.classifyMealType(recipe.name))
        batchSnapshotPersistence {
            if targetDate == todayKey {
                day.meals.append(meal)
            } else {
                mutatePastDay(targetDate) { $0.meals.append(meal) }
            }
            invalidateDaySummary(for: targetDate)
            recentMeals.insert(meal.copyForToday(), at: 0)
            recentMeals = Array(recentMeals.prefix(50))
        }
        return meal
    }

    @discardableResult func logSavedRecipe(_ recipe: SavedRecipe, mealType: MealType? = nil, date: String? = nil) -> Meal {
        let targetDate = date ?? todayKey
        assert(!targetDate.isEmpty, "saved recipe meal date required")
        let macros = Macros(protein: recipe.protein, carbs: recipe.carbs, fat: recipe.fat)
        let hasMacros = recipe.protein > 0 || recipe.carbs > 0 || recipe.fat > 0
        let meal = Meal(
            name: recipe.name,
            mealType: mealType ?? MealParser.classifyMealType(recipe.name),
            macros: macros,
            macroSnapshot: macros,
            micronutrientSnapshot: recipe.micronutrients,
            mealSource: .recipe,
            isAIFallback: false,
            quality: macros.protein >= Self.goodProteinThreshold ? .good : .ok,
            confidence: hasMacros ? "Recipe" : "Recipe (no macros)",
            note: hasMacros ? "Logged from URL recipe." : "Logged from URL recipe. Macros not available.",
            source: MealLogSource.webImport
        )
        batchSnapshotPersistence {
            if targetDate == todayKey {
                day.meals.append(meal)
            } else {
                mutatePastDay(targetDate) { $0.meals.append(meal) }
            }
            invalidateDaySummary(for: targetDate)
            recentMeals.insert(meal.copyForToday(), at: 0)
            recentMeals = Array(recentMeals.prefix(50))
        }
        return meal
    }

    func savedRecipeShareText(for recipe: SavedRecipe) -> String {
        var lines: [String] = [recipe.name, ""]
        if recipe.protein > 0 || recipe.carbs > 0 || recipe.fat > 0 {
            let servingNote = recipe.servings > 1 ? " (per serving, \(recipe.servings) servings)" : ""
            lines += ["Macros\(servingNote): P \(recipe.protein)g · C \(recipe.carbs)g · F \(recipe.fat)g", ""]
        }
        if !recipe.summary.isEmpty {
            lines += [recipe.summary, ""]
        }
        lines += ["Ingredients:"]
        lines += recipe.ingredients.map { "- \($0)" }
        lines += ["", "Source: \(recipe.sourceURL.absoluteString)"]
        return lines.joined(separator: "\n")
    }

    func addSavedRecipe(_ recipe: SavedRecipe) {
        batchSnapshotPersistence {
            savedRecipes.removeAll { $0.sourceURLString == recipe.sourceURLString }
            savedRecipes.insert(recipe, at: 0)
        }
        scheduleSavedRecipeSave()
    }

    func updateSavedRecipe(_ recipe: SavedRecipe) {
        guard let index = savedRecipes.firstIndex(where: { $0.id == recipe.id }) else { return }
        savedRecipes[index] = recipe
        scheduleSavedRecipeSave()
    }

    func deleteSavedRecipe(_ recipe: SavedRecipe) {
        savedRecipes.removeAll { $0.id == recipe.id }
        scheduleSavedRecipeSave()
    }

    func addWorkout(_ workout: Workout) {
        addWorkout(workout, date: todayKey)
    }

    func addWorkout(_ workout: Workout, date: String) {
        assert(!date.isEmpty, "workout date required")
        batchSnapshotPersistence {
            if date == todayKey {
                day.workouts.append(workout)
            } else {
                mutatePastDay(date) { $0.workouts.append(workout) }
            }
            invalidateDaySummary(for: date)
        }
        guard workout.healthKitUUID == nil else { return }
        Task { [weak self] in
            await self?.saveWorkoutToHealthIfAuthorized(workout, date: date)
        }
    }

    private func saveWorkoutToHealthIfAuthorized(_ workout: Workout, date: String) async {
        let service = healthKitService ?? HealthKitService()
        let snapshot = service.currentAuthorizationSnapshot()
        guard isWorkoutLoggingAuthorized(snapshot) else { return }
        do {
            let hkUUID = try await service.saveWorkout(workout)
            updateWorkoutHealthKitUUID(workoutID: workout.id, hkUUID: hkUUID, date: date)
        } catch {
            FernletAuditLog.log("healthkit.workout.save.failed", context: ["error": error.localizedDescription])
        }
    }

    private func updateWorkoutHealthKitUUID(workoutID: UUID, hkUUID: UUID, date: String) {
        batchSnapshotPersistence {
            if date == todayKey {
                if let index = day.workouts.firstIndex(where: { $0.id == workoutID }) {
                    day.workouts[index].healthKitUUID = hkUUID
                }
            } else {
                mutatePastDay(date) { targetDay in
                    if let index = targetDay.workouts.firstIndex(where: { $0.id == workoutID }) {
                        targetDay.workouts[index].healthKitUUID = hkUUID
                    }
                }
            }
        }
    }

    func refreshWorkoutsFromHealth() async {
        let service = healthKitService ?? HealthKitService()
        let snapshot = service.currentAuthorizationSnapshot()
        guard isWorkoutLoggingAuthorized(snapshot) else { return }

        do {
            try await service.startObservingWorkouts { [weak self] workouts in
                self?.reconcileWorkouts(workouts)
            }
        } catch {
            FernletAuditLog.log("healthkit.workouts.refresh.failed", context: ["error": error.localizedDescription])
        }
    }

    func backfillWorkoutsFromHealthIfNeeded(defaults: UserDefaults = .standard) async {
        guard HealthKitService.shouldRunWorkoutBackfill(defaults: defaults) else { return }
        let service = healthKitService ?? HealthKitService()
        let snapshot = service.currentAuthorizationSnapshot()
        guard isWorkoutLoggingAuthorized(snapshot) else { return }

        do {
            let workouts = try await service.backfillWorkoutsFromHealth(referenceDate: .now)
            reconcileWorkouts(workouts)
            HealthKitService.markWorkoutBackfillCompleted(defaults: defaults)
        } catch {
            FernletAuditLog.log("healthkit.workouts.backfill.failed", context: ["error": error.localizedDescription])
        }
    }

    private func isWorkoutLoggingAuthorized(_ snapshot: AuthorizationSnapshot) -> Bool {
        snapshot.status(for: HKObjectType.workoutType().identifier) == .sharingAuthorized
            || snapshot.status(for: HealthCapability.workoutLogging.rawValue) == .sharingAuthorized
    }

    private func reconcileWorkouts(_ hkWorkouts: [HKWorkout]) {
        for hk in hkWorkouts {
            let externalID = hk.metadata?["fernlet.workoutID"] as? String
            let syncID = hk.metadata?[HKMetadataKeySyncIdentifier] as? String
            let knownID = externalID ?? syncID
            if let knownID, let uuid = UUID(uuidString: knownID), workoutExists(id: uuid) {
                updateWorkoutHealthKitUUIDIfNeeded(id: uuid, healthKitUUID: hk.uuid)
                continue
            }
            if workoutExists(healthKitUUID: hk.uuid) {
                continue
            }

            let workout = Self.makeWorkout(from: hk)
            let dayKey = FernletDate.dayKey(for: hk.endDate)
            addWorkout(workout, date: dayKey)
        }
    }

    private func workoutExists(id: UUID) -> Bool {
        loadDays().values.contains { day in
            day.workouts.contains { $0.id == id }
        }
    }

    private func workoutExists(healthKitUUID: UUID) -> Bool {
        loadDays().values.contains { day in
            day.workouts.contains { $0.healthKitUUID == healthKitUUID }
        }
    }

    private func updateWorkoutHealthKitUUIDIfNeeded(id: UUID, healthKitUUID: UUID) {
        if let index = day.workouts.firstIndex(where: { $0.id == id }) {
            guard day.workouts[index].healthKitUUID == nil else { return }
            day.workouts[index].healthKitUUID = healthKitUUID
            scheduleSnapshotSave()
            return
        }

        for (dateKey, pastDay) in repository.loadAllDays() where dateKey != todayKey {
            guard pastDay.workouts.contains(where: { $0.id == id && $0.healthKitUUID == nil }) else { continue }
            mutatePastDay(dateKey) { targetDay in
                if let index = targetDay.workouts.firstIndex(where: { $0.id == id && $0.healthKitUUID == nil }) {
                    targetDay.workouts[index].healthKitUUID = healthKitUUID
                }
            }
            return
        }
    }

    static func makeWorkout(from hk: HKWorkout) -> Workout {
        let activityType = ActivityTypeCatalog.fernletType(for: hk.workoutActivityType)
        let durationMin = Int(hk.duration / 60)
        let kcal = hk.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
        let distanceMiles: Double? = {
            let types: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .distanceSwimming]
            for typeID in types {
                if let quantity = hk.statistics(for: HKQuantityType(typeID))?.sumQuantity()?.doubleValue(for: .mile()), quantity > 0 {
                    return quantity
                }
            }
            return nil
        }()
        let name = (hk.metadata?["fernlet.activityName"] as? String) ?? activityType.displayName
        let mode: WorkoutMode = {
            if hk.workoutActivityType == .traditionalStrengthTraining || hk.workoutActivityType == .functionalStrengthTraining {
                return .strengthTraining
            }
            return .activity
        }()
        let metadata = parseFernletMetadata(hk.metadata)
        return Workout(
            name: name,
            type: activityType.fernletCategory,
            mode: mode,
            activityType: mode == .activity ? activityType : nil,
            exercises: metadata.exercises,
            rpe: nil,
            notes: metadata.notes,
            duration: durationMin,
            distanceMiles: distanceMiles,
            activeEnergyKcal: kcal,
            effort: metadata.effort,
            muscleGroups: metadata.muscleGroups,
            healthKitUUID: hk.uuid,
            plannedWorkoutID: metadata.plannedWorkoutID,
            intensity: .moderate,
            completedAt: hk.endDate
        )
    }

    static func parseFernletMetadata(_ metadata: [String: Any]?) -> (muscleGroups: Set<MuscleGroup>, exercises: String, notes: String, effort: Int?, plannedWorkoutID: UUID?) {
        let muscleGroupsRaw = (metadata?["fernlet.muscleGroups"] as? String) ?? ""
        let muscleGroups = Set(muscleGroupsRaw.split(separator: ",").compactMap { rawValue in
            MuscleGroup(rawValue: String(rawValue).trimmingCharacters(in: .whitespacesAndNewlines))
        })
        let exercises = (metadata?["fernlet.exercises"] as? String) ?? ""
        let notes = (metadata?["fernlet.notes"] as? String) ?? ""
        let effort = (metadata?["fernlet.effort"] as? NSNumber)?.intValue
        let plannedWorkoutID = (metadata?["fernlet.plannedWorkoutID"] as? String).flatMap(UUID.init(uuidString:))
        return (muscleGroups, exercises, notes, effort, plannedWorkoutID)
    }

    func addJournal(text: String, tag: FeelingTag) {
        batchSnapshotPersistence {
            let entry = JournalEntry(text: text, tag: tag)
            day.journals.append(entry)
            previousJournals.insert(entry, at: 0)
            previousJournals = Array(previousJournals.prefix(30))
            if let memory = MemoryNote.fromJournal(text: text, tag: tag) {
                memories.append(memory)
                memories = Array(memories.suffix(300))
            }
        }
    }

    func setSleep(hours: Double?, quality: SleepQuality, note: String) {
        day.sleep = SleepLog(hours: hours, quality: quality, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        scheduleSnapshotSave()
    }

    func setHealthSleepHours(_ hours: Double) {
        guard hours > 0 else { return }
        let roundedHours = (hours * 10).rounded() / 10
        let current = day.sleep
        day.sleep = SleepLog(
            hours: roundedHours,
            quality: current?.quality ?? .ok,
            note: current?.note ?? ""
        )
        scheduleSnapshotSave()
    }

    func updateHealthContext(_ context: HealthDailyContext) {
        if var existing = day.healthContext {
            existing.merge(context)
            day.healthContext = existing
        } else {
            day.healthContext = context
        }
        if let sleepHours = context.body?.sleepHours {
            setHealthSleepHours(sleepHours)
        }
        scheduleSnapshotSave()
    }

    func addBottle() {
        day.bottleCount = min(day.bottleCount + 1, 30)
        scheduleSnapshotSave()
    }

    func removeBottle() {
        day.bottleCount = max(day.bottleCount - 1, 0)
        scheduleSnapshotSave()
    }

    func toggleHygiene(_ item: HygieneItem) {
        guard let task = personalCareTasks.first(where: { $0.defaultHygieneItem == item }) else { return }
        togglePersonalCareTask(task)
    }

    func togglePersonalCareTask(_ task: PersonalCareTask) {
        setPersonalCareTask(task, completed: !isPersonalCareTaskCompleted(task))
    }

    func setPersonalCareTask(_ task: PersonalCareTask, completed: Bool) {
        batchSnapshotPersistence {
            if completed {
                day.completedPersonalCareTaskIDs.insert(task.id)
                if let item = task.defaultHygieneItem { day.hygiene.insert(item) }
            } else {
                day.completedPersonalCareTaskIDs.remove(task.id)
                if let item = task.defaultHygieneItem { day.hygiene.remove(item) }
            }
        }
    }

    func addPersonalCareTask(label: String, group: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        batchSnapshotPersistence {
            var tasks = personalCareTasks
            tasks.append(PersonalCareTask.custom(label: trimmed, group: group))
            settings.personalCareTasks = PersonalCareTask.normalized(tasks)
        }
    }

    func removePersonalCareTask(_ task: PersonalCareTask) {
        batchSnapshotPersistence {
            settings.personalCareTasks = PersonalCareTask.normalized(personalCareTasks.filter { $0.id != task.id })
            day.completedPersonalCareTaskIDs.remove(task.id)
            if let item = task.defaultHygieneItem { day.hygiene.remove(item) }
        }
    }

    @discardableResult
    private func mutatePastDay(_ dateKey: String, _ mutate: (inout FernletDay) -> Void) -> Bool {
        assert(!dateKey.isEmpty, "date key required")
        var targetDay = repository.loadDay(for: dateKey, todayKey: todayKey)
        mutate(&targetDay)
        let saved = repository.updateDay(targetDay, for: dateKey, todayKey: todayKey)
        assert(saved, "past-date save failed for \(dateKey)")
        return saved
    }

    // MARK: - Past-date access

    func loadDays() -> [String: FernletDay] {
        var days = repository.loadAllDays()
        days[todayKey] = day
        return days
    }

    func loadDay(for dateKey: String) -> FernletDay {
        if dateKey == todayKey { return day }
        return repository.loadDay(for: dateKey, todayKey: todayKey)
    }

    func score(for targetDay: FernletDay) -> Double {
        FernletScoring.compute(
            journalTag: targetDay.journals.last?.tag,
            mealCount: targetDay.meals.count,
            workoutCount: targetDay.workouts.count,
            sleepQuality: targetDay.sleep?.quality,
            bottleCount: targetDay.bottleCount,
            hydrationTarget: settings.hydrationTarget,
            hygiene: targetDay.hygiene,
            hygieneTaskCount: personalCareTasks.count,
            completedPersonalCareTaskCount: personalCareProgress(for: targetDay).completed,
            weights: GoalWeights.forGoal(settings.selectedGoal),
            isSick: settings.isSick,
            micronutrientDataCoverageRatio: FernletScoring.micronutrientDataCoverageRatio(for: targetDay.meals)
        )
    }

    func dailyHealthScore(for dateKey: String, day targetDay: FernletDay) -> DailyHealthScore {
        assert(!dateKey.isEmpty, "date key required")
        if let stored = dailyScores.first(where: { $0.dateKey == dateKey }) {
            return stored
        }
        let score = score(for: targetDay)
        return DailyHealthScore(
            dateKey: dateKey,
            score: score,
            companionState: FernletScoring.state(for: score, isSick: settings.isSick),
            daySummaryText: nil,
            computedAt: Date()
        )
    }

    func addJournal(text: String, tag: FeelingTag, date: String) {
        assert(!date.isEmpty, "journal date required")
        if date == todayKey { addJournal(text: text, tag: tag); return }
        let entry = JournalEntry(text: text, tag: tag)
        mutatePastDay(date) { $0.journals.append(entry) }
    }

    func updateJournal(_ entry: JournalEntry, text: String, tag: FeelingTag, date: String) {
        assert(!date.isEmpty, "journal date required")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        var updatedEntry = entry
        updatedEntry.text = trimmed
        updatedEntry.tag = tag

        batchSnapshotPersistence {
            if date == todayKey {
                guard let index = day.journals.firstIndex(where: { $0.id == entry.id }) else { return }
                day.journals[index] = updatedEntry
            } else {
                mutatePastDay(date) { targetDay in
                    guard let index = targetDay.journals.firstIndex(where: { $0.id == entry.id }) else { return }
                    targetDay.journals[index] = updatedEntry
                }
            }

            if let index = previousJournals.firstIndex(where: { $0.id == entry.id }) {
                previousJournals[index] = updatedEntry
            }
        }
    }

    func deleteJournal(_ entry: JournalEntry, date: String) {
        assert(!date.isEmpty, "journal date required")
        batchSnapshotPersistence {
            if date == todayKey {
                day.journals.removeAll { $0.id == entry.id }
            } else {
                mutatePastDay(date) { $0.journals.removeAll { $0.id == entry.id } }
            }
            previousJournals.removeAll { $0.id == entry.id }
        }
    }

    func setSleep(hours: Double?, quality: SleepQuality, note: String, date: String) {
        assert(!date.isEmpty, "sleep date required")
        if date == todayKey { setSleep(hours: hours, quality: quality, note: note); return }
        mutatePastDay(date) { $0.sleep = SleepLog(hours: hours, quality: quality, note: note.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func setBottleCount(_ count: Int, date: String) {
        assert(!date.isEmpty, "water date required")
        let clamped = min(max(count, 0), 30)
        if date == todayKey { day.bottleCount = clamped; scheduleSnapshotSave(); return }
        mutatePastDay(date) { $0.bottleCount = clamped }
    }

    func setHygiene(_ hygiene: Set<HygieneItem>, date: String) {
        let ids = Set(hygiene.map(\.rawValue))
        setPersonalCareTaskIDs(ids, date: date)
    }

    func setPersonalCareTaskIDs(_ ids: Set<String>, date: String) {
        assert(!date.isEmpty, "personal care date required")
        let defaultItems = Set(ids.compactMap(HygieneItem.init(rawValue:)))
        if date == todayKey {
            day.completedPersonalCareTaskIDs = ids
            day.hygiene = defaultItems
            scheduleSnapshotSave()
            return
        }
        mutatePastDay(date) {
            $0.completedPersonalCareTaskIDs = ids
            $0.hygiene = defaultItems
        }
    }

    func replaceGoals(_ newGoals: [FitnessGoal]) {
        goals = Array(newGoals.prefix(12))
        scheduleSnapshotSave()
    }

    func completeOnboarding(profile: UserNutritionProfile, preferences: UserNutritionPreferences, goal: GoalType) {
        batchSnapshotPersistence {
            settings.userProfile = profile
            settings.nutritionPreferences = preferences
            settings.selectedGoal = goal
            settings.showCalories = true
            settings.hasCompletedOnboarding = true
        }
    }

    func addRecipe(name: String, servings: Int, notes: String = "", ingredients inputIngredients: [ManualRecipeIngredientInput]) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        assert(!trimmedName.isEmpty, "recipe name required")
        let now = Date()
        batchSnapshotPersistence {
            let recipeIngredients = makeRecipeIngredients(from: inputIngredients, verifiedAt: now)
            recipes.insert(
                RecipeDefinition(
                    name: trimmedName,
                    servings: max(servings, 1),
                    ingredients: recipeIngredients,
                    notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                    source: "manual",
                    createdAt: now,
                    updatedAt: now
                ),
                at: 0
            )
        }
    }

    func updateRecipe(_ recipe: RecipeDefinition, name: String, servings: Int, notes: String = "", ingredients inputIngredients: [ManualRecipeIngredientInput]) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        assert(!trimmedName.isEmpty, "recipe name required")
        guard let index = recipes.firstIndex(where: { $0.id == recipe.id }) else { return }
        batchSnapshotPersistence {
            let recipeIngredients = makeRecipeIngredients(from: inputIngredients, verifiedAt: Date())
            assert(!recipeIngredients.isEmpty, "recipe ingredients required")
            recipes[index].name = trimmedName
            recipes[index].servings = max(servings, 1)
            recipes[index].ingredients = recipeIngredients
            recipes[index].notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            recipes[index].updatedAt = Date()
        }
    }

    @discardableResult func saveCustomIngredient(_ ingredient: ManualRecipeIngredientInput) -> FoodItem? {
        guard !ingredient.trimmedName.isEmpty else { return nil }
        return batchSnapshotPersistence {
            upsertCustomFoodItem(from: ingredient, verifiedAt: Date())
        }
    }

    func deleteRecipe(_ recipe: RecipeDefinition) {
        recipes.removeAll { $0.id == recipe.id }
        scheduleSnapshotSave()
    }

    func macroTotals(for recipe: RecipeDefinition) -> MacroTotals {
        recipe.ingredients.reduce(into: MacroTotals()) { totals, ingredient in
            guard let foodItem = foodItems.first(where: { $0.id == ingredient.foodItemId }) else { return }
            let macros = ingredient.scaledMacros(using: foodItem)
            totals.protein += macros.protein
            totals.carbs += macros.carbs
            totals.fat += macros.fat
        }
    }

    func micronutrientTotals(for recipe: RecipeDefinition) -> Micronutrients {
        recipe.ingredients.reduce(into: Micronutrients()) { totals, ingredient in
            guard let foodItem = foodItems.first(where: { $0.id == ingredient.foodItemId }) else { return }
            totals.add(ingredient.scaledMicronutrients(using: foodItem))
        }
    }

    func recipeShareText(for recipe: RecipeDefinition) -> String {
        let payload = sharedRecipePayload(for: recipe)
        var lines: [String] = [
            payload.name,
            "Servings: \(payload.servings)",
            "",
            "Ingredients:"
        ]
        lines += payload.ingredients.map { ingredient in
            "- \(String(format: "%g", ingredient.quantity)) \(ingredient.unit) \(ingredient.name) (P\(ingredient.protein) C\(ingredient.carbs) F\(ingredient.fat))"
        }
        if !payload.notes.isEmpty {
            lines += ["", "Notes:", payload.notes]
        }
        if let json = sharedRecipeJSON(for: payload) {
            lines += ["", "Fernlet recipe data:", json]
        }
        return lines.joined(separator: "\n")
    }

    @discardableResult func importRecipe(from text: String) throws -> RecipeDefinition {
        let payload = try sharedRecipePayload(from: text)
        let trimmedName = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, payload.servings > 0, !payload.ingredients.isEmpty else {
            throw RecipeImportError.emptyRecipe
        }

        let now = Date()
        return batchSnapshotPersistence {
            let recipeIngredients = payload.ingredients.map { ingredient in
                let trimmedIngredientName = ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let unit = ingredient.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? RecipeUnit.serving.rawValue : ingredient.unit
                let quantity = max(ingredient.quantity, 0.01)
                let foodItem = FoodItem(
                    name: trimmedIngredientName.isEmpty ? "Imported ingredient" : trimmedIngredientName,
                    brandSource: "Imported recipe",
                    servingSize: quantity,
                    servingUnit: unit,
                    macros: Macros(protein: ingredient.protein, carbs: ingredient.carbs, fat: ingredient.fat),
                    micronutrients: Micronutrients(),
                    category: "recipe ingredient",
                    source: .manual,
                    lastVerified: now,
                    tags: ["recipe", "imported"]
                )
                foodItems.append(foodItem)
                return RecipeIngredient(foodItemId: foodItem.id, quantity: quantity, unit: unit)
            }

            let recipe = RecipeDefinition(
                name: trimmedName,
                servings: payload.servings,
                ingredients: recipeIngredients,
                notes: payload.notes.trimmingCharacters(in: .whitespacesAndNewlines),
                source: "imported",
                createdAt: now,
                updatedAt: now
            )
            recipes.insert(recipe, at: 0)
            return recipe
        }
    }

    private func sharedRecipePayload(for recipe: RecipeDefinition) -> SharedRecipePayload {
        SharedRecipePayload(
            name: recipe.name,
            servings: recipe.servings,
            notes: recipe.notes,
            ingredients: recipe.ingredients.compactMap { ingredient in
                guard let foodItem = foodItems.first(where: { $0.id == ingredient.foodItemId }) else { return nil }
                let macros = ingredient.scaledMacros(using: foodItem)
                return SharedRecipeIngredient(
                    name: foodItem.name,
                    quantity: ingredient.quantity,
                    unit: ingredient.unit,
                    protein: macros.protein,
                    carbs: macros.carbs,
                    fat: macros.fat
                )
            }
        )
    }

    private func sharedRecipeJSON(for payload: SharedRecipePayload) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func sharedRecipePayload(from text: String) throws -> SharedRecipePayload {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if trimmedText.hasPrefix("{") {
            jsonText = trimmedText
        } else if let markerRange = text.range(of: "Fernlet recipe data:") {
            let payloadText = text[markerRange.upperBound...]
            guard let firstJSONLine = payloadText
                .split(whereSeparator: \.isNewline)
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { $0.hasPrefix("{") }) else {
                throw RecipeImportError.missingPayload
            }
            jsonText = firstJSONLine
        } else {
            throw RecipeImportError.missingPayload
        }

        guard let data = jsonText.data(using: .utf8),
              let payload = try? JSONDecoder().decode(SharedRecipePayload.self, from: data) else {
            throw RecipeImportError.invalidPayload
        }
        guard payload.format == "fernlet.recipe", payload.version == 1 else {
            throw RecipeImportError.unsupportedFormat
        }
        return payload
    }

    private func makeRecipeIngredients(from inputIngredients: [ManualRecipeIngredientInput], verifiedAt: Date) -> [RecipeIngredient] {
        let validIngredients = inputIngredients.filter { !$0.trimmedName.isEmpty }
        assert(!validIngredients.isEmpty, "recipe ingredients required")
        var recipeIngredients: [RecipeIngredient] = []
        for ingredient in validIngredients {
            let foodItem = ingredient.selectedFoodItem(in: foodItems) ?? upsertCustomFoodItem(from: ingredient, verifiedAt: verifiedAt)
            recipeIngredients.append(RecipeIngredient(
                foodItemId: foodItem.id,
                quantity: max(ingredient.quantity, 0.01),
                unit: ingredient.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "serving" : ingredient.unit
            ))
        }
        return recipeIngredients
    }

    private func upsertCustomFoodItem(from ingredient: ManualRecipeIngredientInput, verifiedAt: Date) -> FoodItem {
        let servingUnit = ingredient.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? RecipeUnit.serving.rawValue : ingredient.unit
        let foodItem = FoodItem(
            name: ingredient.trimmedName,
            brandSource: "Custom ingredient",
            servingSize: max(ingredient.quantity, 0.01),
            servingUnit: servingUnit,
            macros: ingredient.macros,
            micronutrients: ingredient.scannedMicronutrients ?? Micronutrients(),
            category: "custom ingredient",
            source: .manual,
            lastVerified: verifiedAt,
            tags: ["recipe", "custom"]
        )
        let normalizedName = FoodItemSearch.normalized(foodItem.name)
        if let existingIndex = foodItems.firstIndex(where: { existing in
            existing.source == .manual && FoodItemSearch.normalized(existing.name) == normalizedName
        }) {
            var updatedFoodItem = foodItem
            updatedFoodItem.id = foodItems[existingIndex].id
            foodItems[existingIndex] = updatedFoodItem
            return updatedFoodItem
        }
        foodItems.append(foodItem)
        return foodItem
    }

    func addTexture(_ body: String, tags: Set<TextureTag>) {
        batchSnapshotPersistence {
            workshop.textureEntries.insert(TextureEntry(body: body, tags: tags), at: 0)
        }
    }

    func deleteMemory(_ memory: MemoryNote) {
        batchSnapshotPersistence {
            memories.removeAll { $0.id == memory.id }
        }
    }

    func updateMemory(_ memory: MemoryNote, category: String, text: String) {
        guard let index = memories.firstIndex(where: { $0.id == memory.id }) else { return }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else { return }
        batchSnapshotPersistence {
            memories[index].category = trimmedCategory.isEmpty ? "note" : trimmedCategory
            memories[index].text = String(trimmedText.prefix(240))
        }
    }

    func queueMealRetry(_ meal: Meal) {
        retryQueue.append(AIAnalysisRetryRecord(payloadType: "meal", sourceId: meal.id, note: FernletVoice.message(for: .mealAnalysisFailed)))
        scheduleSnapshotSave()
    }

    func clearRetryItem(_ id: UUID) {
        retryQueue.removeAll { $0.id == id }
        scheduleSnapshotSave()
    }

    func resetAll() {
        batchSnapshotPersistence {
            day = FernletDay(date: todayKey)
            settings = FernletSettings()
            recentMeals = []
            previousJournals = []
            memories = []
            goals = []
            workshop = WorkshopData()
            retryQueue = []
            foodItems = []
            recipes = []
            dailyScores = []
            connectionSessionLogs = []
            trustedProximityPeers = []
            trainerAuditEvents = []
            savedRecipes = []
        }
        scheduleSavedRecipeSave()
    }

    private func rebuildDerivedSignals() {
        StartupTiming.timed("FernletStore.rebuildDerivedSignals") {
            let orderedDays = loadDays().sorted { first, second in first.key < second.key }
            let recent = Array(orderedDays.suffix(FernletLimits.signalWindowDays))
            derivedSignals = DerivedSignalFactory.makeSignals(from: recent, todayKey: todayKey)
        }
    }

    func deferredPostLaunchTasks() {
        guard !deferredPostLaunchTasksStarted else { return }
        deferredPostLaunchTasksStarted = true

        Task(priority: .utility) { @MainActor [weak self] in
            await Task.yield()
            self?.rebuildDerivedSignals()
        }
    }

    private func scheduleSnapshotSave() {
        snapshotSaveTask?.cancel()
        snapshotSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.snapshotSaveTask = nil
            self?.performSnapshotSave()
        }
    }

    func flushPendingSnapshotSave() {
        guard snapshotSaveTask != nil else { return }
        snapshotSaveTask?.cancel()
        snapshotSaveTask = nil
        performSnapshotSave()
    }

    private func scheduleRemoteRepositoryReload() {
        remoteReloadTask?.cancel()
        remoteReloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self else { return }
            self.remoteReloadTask = nil
            await self.reloadFromRepository()
        }
    }

    private func reloadFromRepository() async {
        guard !isReloadingFromRepository else { return }
        isReloadingFromRepository = true
        defer { isReloadingFromRepository = false }

        let snapshot: FernletSnapshot
        if let coreDataRepository = repository as? CoreDataFernletRepository {
            snapshot = await coreDataRepository.loadSnapshotAsync(todayKey: todayKey)
        } else {
            snapshot = repository.loadSnapshot(todayKey: todayKey)
        }
        apply(snapshot)
    }

    private func apply(_ snapshot: FernletSnapshot) {
        day = snapshot.day
        settings = snapshot.settings
        recentMeals = snapshot.recentMeals
        previousJournals = snapshot.previousJournals
        memories = snapshot.memories
        goals = snapshot.goals
        workshop = snapshot.workshop
        retryQueue = snapshot.retryQueue
        foodItems = snapshot.foodItems
        recipes = snapshot.recipes
        dailyScores = snapshot.dailyScores
        connectionSessionLogs = snapshot.connectionSessionLogs
        trustedProximityPeers = snapshot.trustedProximityPeers
        trainerAuditEvents = snapshot.trainerAuditEvents
        connectionInspector.attachStore(self)
        rebuildDerivedSignals()
    }

    private func performSnapshotSave() {
        let snapshot = FernletSnapshot(
            todayKey: todayKey,
            day: day,
            settings: settings,
            recentMeals: recentMeals,
            previousJournals: previousJournals,
            memories: memories,
            goals: goals,
            workshop: workshop,
            foodItems: foodItems,
            recipes: recipes,
            dailyScores: dailyScores,
            retryQueue: retryQueue,
            connectionSessionLogs: connectionSessionLogs,
            trustedProximityPeers: trustedProximityPeers,
            trainerAuditEvents: trainerAuditEvents
        )
        let saved = repository.saveSnapshot(snapshot)
        assert(saved, "snapshot should save")
        rebuildDerivedSignals()
    }

    private func batchSnapshotPersistence<T>(_ updates: () throws -> T) rethrows -> T {
        let result = try updates()
        scheduleSnapshotSave()
        return result
    }

    private func scheduleSavedRecipeSave() {
        guard !savedRecipeSaveScheduled else { return }
        savedRecipeSaveScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.savedRecipeSaveScheduled = false
            let saved = self.savedRecipeRepository.save(self.savedRecipes)
            assert(saved, "saved recipes should save")
        }
    }

    func markLaunchScreenDismissed() {
        guard !launchScreenDismissed else { return }
        launchScreenDismissed = true
        flushPendingBundledFoodSeedSaveIfNeeded()
    }

    func ensureBundledFoodItemsSeeded() {
        guard bundledFoodSeedingState == .notStarted else { return }
        bundledFoodSeedingState = .seeding

        Task { @MainActor [weak self] in
            let bundledItems = await Task.detached(priority: .utility) {
                FoodDataCatalog.bundledFoodItems()
            }.value

            guard let self else { return }
            guard !bundledItems.isEmpty else {
                self.bundledFoodSeedingState = .done
                return
            }

            let existingIds = Set(self.foodItems.map(\.id))
            let missingItems = bundledItems.filter { !existingIds.contains($0.id) }
            if !missingItems.isEmpty {
                self.foodItems.append(contentsOf: missingItems)
                self.queueBundledFoodSeedSaveAfterLaunch()
            }
            self.bundledFoodSeedingState = .done
        }
    }

    private func queueBundledFoodSeedSaveAfterLaunch() {
        if launchScreenDismissed {
            scheduleSnapshotSave()
        } else {
            bundledFoodSeedSavePending = true
        }
    }

    private func flushPendingBundledFoodSeedSaveIfNeeded() {
        guard bundledFoodSeedSavePending else { return }
        bundledFoodSeedSavePending = false
        scheduleSnapshotSave()
    }
}

extension FernletStore {
    static func load(
        date: Date = .now,
        repository: FernletRepository? = nil,
        statusUpdate: @MainActor @escaping (String) -> Void = { _ in }
    ) async throws -> FernletStore {
        let loadSignpostID = StartupTiming.begin("FernletStore.load")
        defer { StartupTiming.end("FernletStore.load", signpostID: loadSignpostID) }

        let key = FernletDate.dayKey(for: date)
        assert(!key.isEmpty, "today key required")

        statusUpdate("Opening your records...")
        await Task.yield()

        let activeRepository = StartupTiming.timed("CoreDataFernletRepository.init") {
            repository ?? CoreDataFernletRepository()
        }
        let savedRecipeRepository = StartupTiming.timed("SavedRecipeRepository.init") {
            SavedRecipeRepository()
        }

        statusUpdate("Reading recent days...")
        let snapshot: FernletSnapshot
        if let coreDataRepository = activeRepository as? CoreDataFernletRepository {
            snapshot = await coreDataRepository.loadSnapshotAsync(todayKey: key)
        } else {
            snapshot = StartupTiming.timed("FernletRepository.loadSnapshot") {
                activeRepository.loadSnapshot(todayKey: key)
            }
        }

        statusUpdate("Loading saved recipes...")
        let savedRecipes = await savedRecipeRepository.loadAsync()

        return FernletStore(
            snapshot: snapshot,
            savedRecipes: savedRecipes,
            todayKey: key,
            repository: activeRepository,
            savedRecipeRepository: savedRecipeRepository,
            healthKitService: nil
        )
    }
}

extension FernletStore: ProximityTrustPolicy {}

// MARK: - Models
