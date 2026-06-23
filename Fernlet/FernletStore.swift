import CryptoKit
import HealthKit
import Observation
import SwiftUI

@MainActor
@Observable
final class FernletStore {
    private enum JournalActivationMode {
        case inactive
        case noLock
        case sealedUnlocked
        case sealedLocked
    }

    var day: FernletDay
    var settings: FernletSettings
    var recentMeals: [Meal]
    var previousJournals: [JournalEntry]
    var memories: [MemoryNote]
    var goals: [FitnessGoal]
    var workshop: WorkshopData
    var foodItems: [FoodItem]
    var bundledFoodItems: [FoodItem] = []
    var allFoodItems: [FoodItem] { bundledFoodItems + foodItems }
    var webImportedFoodItems: [FoodItem] {
        foodItems.filter { $0.tags.contains("web-import") }
    }
    var allowsWebNutritionLookup: Bool {
        settings.webNutritionLookupEnabled && settings.aiStatus != .off
    }
    var recipes: [RecipeDefinition]
    var dailyScores: [DailyHealthScore]
    var connectionSessionLogs: [ConnectionSessionLog]
    var showConnectionInspector = false
    var connectionInspector = ConnectionInspector()
    var isDisposableCameraLandscape = false
    var savedRecipes: [SavedRecipe] {
        savedRecipeService.savedRecipes
    }
    var trustedProximityPeers: [ProximityTrustedPeerRecord] {
        proximityTrustVault.trustedPeers
    }
    var trainerAuditEvents: [TrainerAuditEvent] {
        proximityTrustVault.auditEvents
    }
    var retryQueue: [AIAnalysisRetryRecord] {
        aiRetryQueueService.retryQueue
    }
    var derivedSignals: [DerivedSignalRecord] {
        derivedSignalsService.derivedSignals
    }
    var companionThought: String?
    var photowallSeeds: [PhotowallSeed] = []
    var bundledFoodSeedingState: BundledFoodSeedingService.State {
        bundledFoodSeedingService.state
    }
    var lockState: FernletLockState = .notConfigured

    private static let goodProteinThreshold = 25
    @ObservationIgnored let todayKey: String
    @ObservationIgnored private let repository: FernletRepository
    @ObservationIgnored let savedRecipeService: SavedRecipeService
    @ObservationIgnored let proximityTrustVault: ProximityTrustVault
    @ObservationIgnored let aiRetryQueueService: AIRetryQueueService
    @ObservationIgnored private(set) lazy var meshNetworkManager: MeshNetworkManager = MeshNetworkManager(store: self)
    @ObservationIgnored private(set) lazy var recipeShareManager: ProximityRecipeShareManager = ProximityRecipeShareManager(store: self)
    @ObservationIgnored let derivedSignalsService = DerivedSignalsService()
    @ObservationIgnored private let healthKitService: (any HealthKitServicing)?
    @ObservationIgnored private lazy var workoutHealthKitSync = WorkoutHealthKitSync(
        context: self,
        service: healthKitService ?? HealthKitService()
    )
    @ObservationIgnored private lazy var snapshotSaveCoordinator = SnapshotSaveCoordinator(
        repository: repository,
        buildSnapshot: { [unowned self] in self.currentSnapshot() },
        onAfterSave: { [weak self] in self?.rebuildDerivedSignals() }
    )
    @ObservationIgnored private let bundledFoodSeedingService = BundledFoodSeedingService()
    @ObservationIgnored private var isReloadingFromRepository = false
    @ObservationIgnored private let mealPhotoStore = MealPhotoStore(
        directory: (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("MealPhotos", isDirectory: true)
    )
    @ObservationIgnored private let journalNarrativeRepository: JournalNarrativeRepository
    @ObservationIgnored private var isProcessingSharedRecipeImportQueue = false
    /// Content key available while the lock is open; nil when locked.
    @ObservationIgnored private var journalContentKey: SymmetricKey?
    @ObservationIgnored private var journalActivationMode: JournalActivationMode = .inactive
    /// IDs of journal entries whose text is sealed in JournalNarrativeRepository.
    /// Used by currentSnapshot() to strip text before persisting to the cloud blob.
    @ObservationIgnored private var sealedJournalIDs: Set<UUID> = []

    init(date: Date = .now, repository: FernletRepository? = nil, savedRecipeRepository: SavedRecipeRepository? = nil, healthKitService: (any HealthKitServicing)? = nil, journalNarrativeRepository: JournalNarrativeRepository? = nil) {
        let initSignpostID = StartupTiming.begin("FernletStore.init")
        defer { StartupTiming.end("FernletStore.init", signpostID: initSignpostID) }

        let key = FernletDate.dayKey(for: date)
        assert(!key.isEmpty, "today key required")
        let activeRepository = StartupTiming.timed("CoreDataFernletRepository.init") {
            repository ?? CoreDataFernletRepository()
        }
        let savedRecipeService = StartupTiming.timed("SavedRecipeService.init") {
            SavedRecipeService(repository: savedRecipeRepository ?? SavedRecipeRepository())
        }
        let snapshot = StartupTiming.timed("FernletRepository.loadSnapshot") {
            activeRepository.loadSnapshot(todayKey: key)
        }
        savedRecipeService.loadSync()
        self.todayKey = key
        self.repository = activeRepository
        self.savedRecipeService = savedRecipeService
        self.healthKitService = healthKitService
        self.day = snapshot.day
        self.settings = snapshot.settings
        self.recentMeals = snapshot.recentMeals
        self.previousJournals = snapshot.previousJournals
        self.memories = snapshot.memories
        self.goals = snapshot.goals
        self.workshop = snapshot.workshop
        self.foodItems = snapshot.foodItems.filter { $0.source != .usda }
        self.recipes = snapshot.recipes
        self.dailyScores = snapshot.dailyScores
        self.connectionSessionLogs = snapshot.connectionSessionLogs
        self.proximityTrustVault = ProximityTrustVault(
            initialPeers: snapshot.trustedProximityPeers,
            initialAudit: snapshot.trainerAuditEvents
        )
        self.aiRetryQueueService = AIRetryQueueService(initial: snapshot.retryQueue)
        self.journalNarrativeRepository = journalNarrativeRepository ?? JournalNarrativeRepository()
        self.connectionInspector.attachStore(self)
        proximityTrustVault.onChange = { [weak self] in self?.snapshotSaveCoordinator.schedule() }
        aiRetryQueueService.onChange = { [weak self] in self?.snapshotSaveCoordinator.schedule() }
        rebuildDerivedSignals()
        snapshotSaveCoordinator.subscribeRemote { [weak self] in
            await self?.reloadFromRepository()
        }
    }

    private init(
        snapshot: FernletSnapshot,
        todayKey: String,
        repository: FernletRepository,
        savedRecipeService: SavedRecipeService,
        healthKitService: (any HealthKitServicing)? = nil
    ) {
        self.todayKey = todayKey
        self.repository = repository
        self.savedRecipeService = savedRecipeService
        self.healthKitService = healthKitService
        self.day = snapshot.day
        self.settings = snapshot.settings
        self.recentMeals = snapshot.recentMeals
        self.previousJournals = snapshot.previousJournals
        self.memories = snapshot.memories
        self.goals = snapshot.goals
        self.workshop = snapshot.workshop
        self.foodItems = snapshot.foodItems.filter { $0.source != .usda }
        self.recipes = snapshot.recipes
        self.dailyScores = snapshot.dailyScores
        self.connectionSessionLogs = snapshot.connectionSessionLogs
        self.proximityTrustVault = ProximityTrustVault(
            initialPeers: snapshot.trustedProximityPeers,
            initialAudit: snapshot.trainerAuditEvents
        )
        self.aiRetryQueueService = AIRetryQueueService(initial: snapshot.retryQueue)
        self.journalNarrativeRepository = JournalNarrativeRepository()
        self.connectionInspector.attachStore(self)
        proximityTrustVault.onChange = { [weak self] in self?.snapshotSaveCoordinator.schedule() }
        aiRetryQueueService.onChange = { [weak self] in self?.snapshotSaveCoordinator.schedule() }
        snapshotSaveCoordinator.subscribeRemote { [weak self] in
            await self?.reloadFromRepository()
        }
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
        snapshotSaveCoordinator.schedule()
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
        aiRetryQueueService.pendingCount
    }

    var isIntimateLoggingAllowed: Bool {
        settings.userProfile.age >= 18
    }

    func setHidePredictions(_ hidePredictions: Bool) {
        settings.hidePredictions = hidePredictions
        snapshotSaveCoordinator.schedule()
    }

    func setHideFertileWindow(_ hideFertileWindow: Bool) {
        settings.hideFertileWindow = hideFertileWindow
        snapshotSaveCoordinator.schedule()
    }

    func setConnectionInspectorMode(_ mode: ConnectionInspectorMode) {
        settings.connectionInspectorMode = mode
        if mode != .live {
            showConnectionInspector = false
        }
        snapshotSaveCoordinator.schedule()
    }

    func setCompanionAppearance(_ appearance: CompanionAppearance) {
        settings.companionAppearance = appearance
        snapshotSaveCoordinator.schedule()
    }

    func setCompanionName(_ name: String) {
        settings.companionName = name
        snapshotSaveCoordinator.schedule()
    }

    func setProximityDisplayName(_ name: String) {
        settings.proximityDisplayName = name.trimmingCharacters(in: .whitespaces)
        snapshotSaveCoordinator.schedule()
    }

    func setShowProximityDebugTools(_ value: Bool) {
        settings.showProximityDebugTools = value
        snapshotSaveCoordinator.schedule()
    }

    func setAllowNearbyRecipeShares(_ value: Bool) {
        settings.allowNearbyRecipeShares = value
        if !value {
            recipeShareManager.stop()
        }
        snapshotSaveCoordinator.schedule()
    }

    func replaceConnectionSessionLogs(_ logs: [ConnectionSessionLog]) {
        connectionSessionLogs = Array(logs.sorted { $0.startedAt > $1.startedAt }.prefix(50))
        snapshotSaveCoordinator.schedule()
    }

    func trustedProximityPeer(signingPublicKey: Data) -> ProximityTrustedPeerRecord? {
        proximityTrustVault.peer(signingPublicKey: signingPublicKey)
    }

    func trustedProximityPeer(displayName: String) -> ProximityTrustedPeerRecord? {
        proximityTrustVault.peer(displayName: displayName)
    }

    func trustProximityPeer(_ peer: ProximityCoordinator.PeerIdentity, mode: ProximityCoordinator.Mode) {
        proximityTrustVault.trust(peer, mode: mode)
    }

    func revokeTrustedProximityPeer(signingPublicKey: Data) {
        proximityTrustVault.revoke(signingPublicKey: signingPublicKey)
    }

    func isRevokedProximitySigningKey(_ publicKey: Data) -> Bool {
        proximityTrustVault.isRevokedProximitySigningKey(publicKey)
    }

    func isBlockedProximitySigningKey(_ publicKey: Data) -> Bool {
        proximityTrustVault.isBlockedProximitySigningKey(publicKey)
    }

    func isBlockedFingerprint(_ fingerprint: String) -> Bool {
        proximityTrustVault.isBlockedFingerprint(fingerprint)
    }

    func blockProximityPeer(signingPublicKey: Data) {
        proximityTrustVault.block(signingPublicKey: signingPublicKey)
        snapshotSaveCoordinator.schedule()
    }

    func unblockProximityPeer(signingPublicKey: Data) {
        proximityTrustVault.unblock(signingPublicKey: signingPublicKey)
        snapshotSaveCoordinator.schedule()
    }

    func isTrustedProximityPeer(signingPublicKey: Data) -> Bool {
        proximityTrustVault.isTrustedProximityPeer(signingPublicKey: signingPublicKey)
    }

    func recordTrainerAudit(_ event: TrainerAuditEvent) {
        proximityTrustVault.recordTrainerAudit(event)
    }

    func setHomeWidgets(_ widgets: [HomeWidget]) {
        settings.homeWidgets = HomeWidget.normalized(widgets)
        snapshotSaveCoordinator.schedule()
    }

    func setQuickLogItems(_ items: [FernletShortcut]) {
        settings.quickLogItems = FernletShortcut.normalizedQuickLog(items)
        snapshotSaveCoordinator.schedule()
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

        if settings.aiStatus != .off {
            // Primary (M1): model decomposes the dish from world knowledge, catalog supplies macros.
            do {
                let index = FoodItemSearch.Index(foodItems: allFoodItems)
                if let meal = try await FoundationDishDecompositionModel.decompose(
                    MealDecompositionPayload(mealDescription: description, fallbackMealType: type),
                    index: index
                ) {
                    appendMeal(meal, date: targetDate)
                    return [meal]
                }
            } catch {}

            // Secondary AI: candidate-constrained selection (item-count guard removed per M1).
            let candidates = FoodSelectionCandidateBuilder.candidates(for: description, foodItems: allFoodItems)
            do {
                if let plan = try await FoundationFoodSelectionModel.resolve(
                    FoodSelectionPayload(mealDescription: description, candidates: candidates, fallbackMealType: type)
                ), let result = MealBuilder.meals(
                    from: plan,
                    candidates: candidates,
                    recipes: recipes,
                    foodItems: allFoodItems,
                    originalDescription: description
                ), result.meals.isEmpty == false {
                    for newRecipe in result.createdRecipes { recipes.insert(newRecipe, at: 0) }
                    result.meals.forEach { appendMeal($0, date: targetDate) }
                    return result.meals
                }
            } catch {}
        }

        // Deterministic tier 1 (M2): dish template lexicon — handles composite dishes when AI is off.
        if let lexiconMeals = DishTemplateLexicon.resolve(description: description, mealType: type, foodItems: allFoodItems) {
            lexiconMeals.forEach { appendMeal($0, date: targetDate) }
            return lexiconMeals
        }

        // Deterministic tier 2: candidate-constrained plan.
        let candidates = FoodSelectionCandidateBuilder.candidates(for: description, foodItems: allFoodItems)
        if let plan = FoundationFoodSelectionModel.deterministicPlan(description: description, candidates: candidates, fallbackType: type),
           let result = MealBuilder.meals(
            from: plan,
            candidates: candidates,
            recipes: recipes,
            foodItems: allFoodItems,
            originalDescription: description
           ), result.meals.isEmpty == false {
            for newRecipe in result.createdRecipes { recipes.insert(newRecipe, at: 0) }
            result.meals.forEach { appendMeal($0, date: targetDate) }
            return result.meals
        }
        let fallback = addMeal(from: description, type: type, date: targetDate)
        queueMealRetry(fallback)
        return [fallback]
    }

    private func appendMeal(_ meal: Meal, date: String) {
        assert(!date.isEmpty, "meal date required")
        batchSnapshotPersistence {
            mutateDay(date: date) { $0.meals.append(meal) }
            invalidateDaySummary(for: date)
            recentMeals.insert(meal, at: 0)
            recentMeals = Array(recentMeals.prefix(50))
        }
    }

    @discardableResult func copyMeal(_ meal: Meal) -> Meal {
        let copiedMeal = meal.copyForToday()
        batchSnapshotPersistence {
            day.meals.append(copiedMeal)
        }
        return copiedMeal
    }

    func deleteMeal(_ meal: Meal) {
        aiRetryQueueService.clearForSourceID(meal.id)
        batchSnapshotPersistence {
            if let photoID = meal.photoID {
                let stillReferenced = day.meals.contains { $0.id != meal.id && $0.photoID == photoID }
                if !stillReferenced {
                    mealPhotoStore.delete(id: photoID)
                }
            }
            day.meals.removeAll { $0.id == meal.id }
        }
    }

    func updateMealCorrection(
        mealID: UUID,
        name: String,
        mealType: MealType,
        macros: Macros,
        componentSnapshots: [MealComponentSnapshot]? = nil
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let correction = Self.correctedNutrition(macros: macros, componentSnapshots: componentSnapshots)
        batchSnapshotPersistence {
            mutateDay(date: todayKey) { targetDay in
                guard let index = targetDay.meals.firstIndex(where: { $0.id == mealID }) else { return }
                Self.applyMealCorrection(
                    to: &targetDay.meals[index],
                    trimmedName: trimmedName,
                    mealType: mealType,
                    macros: correction.macros,
                    micronutrients: correction.micronutrients,
                    componentSnapshots: correction.componentSnapshots
                )
            }
            if let index = recentMeals.firstIndex(where: { $0.id == mealID }) {
                Self.applyMealCorrection(
                    to: &recentMeals[index],
                    trimmedName: trimmedName,
                    mealType: mealType,
                    macros: correction.macros,
                    micronutrients: correction.micronutrients,
                    componentSnapshots: correction.componentSnapshots
                )
            }
            invalidateDaySummary(for: todayKey)
        }
    }

    private static func correctedNutrition(
        macros: Macros,
        componentSnapshots: [MealComponentSnapshot]?
    ) -> (macros: Macros, micronutrients: Micronutrients, componentSnapshots: [MealComponentSnapshot]?) {
        guard let componentSnapshots, componentSnapshots.isEmpty == false else {
            return (macros, Micronutrients(), nil)
        }
        let totals = MealBuilder.totals(for: componentSnapshots)
        return (
            Macros(protein: totals.macros.protein, carbs: totals.macros.carbs, fat: totals.macros.fat),
            totals.micronutrients,
            componentSnapshots
        )
    }

    private static func applyMealCorrection(
        to meal: inout Meal,
        trimmedName: String,
        mealType: MealType,
        macros: Macros,
        micronutrients: Micronutrients,
        componentSnapshots: [MealComponentSnapshot]?
    ) {
        meal.name = trimmedName.isEmpty ? meal.name : trimmedName
        meal.mealType = mealType
        meal.macros = macros
        meal.macroSnapshot = macros
        meal.calorieSnapshot = macros.calories
        if let componentSnapshots {
            meal.componentSnapshots = componentSnapshots
            meal.micronutrientSnapshot = micronutrients
            let componentText = componentSnapshots
                .prefix(3)
                .map { "\($0.quantity.formatted(.number.precision(.fractionLength(0...1)))) \($0.unit) \($0.name)" }
                .joined(separator: ", ")
            meal.note = componentText.isEmpty
                ? "Corrected manually after quick logging."
                : "Corrected components: \(componentText)."
        } else {
            meal.micronutrientSnapshot = Micronutrients()
            meal.note = "Corrected manually after quick logging."
        }
        meal.confidence = "Corrected"
        meal.isAIFallback = false
        meal.quality = macros.protein >= Self.goodProteinThreshold ? .good : .ok
    }

    func attachMealPhoto(mealID: UUID, photoID: UUID) {
        batchSnapshotPersistence {
            if let index = day.meals.firstIndex(where: { $0.id == mealID }) {
                day.meals[index].photoID = photoID
            }
        }
    }

    func mealPhotoData(for id: UUID) -> Data? {
        mealPhotoStore.imageData(for: id)
    }

    #if canImport(UIKit)
    @discardableResult func saveMealPhoto(_ image: UIImage) -> UUID? {
        guard let data = image.jpegData(compressionQuality: 0.82) else { return nil }
        return mealPhotoStore.save(data)
    }
    #endif

    @discardableResult func logRecipe(_ recipe: RecipeDefinition, mealType: MealType? = nil, date: String? = nil) -> Meal {
        let targetDate = date ?? todayKey
        assert(!targetDate.isEmpty, "recipe meal date required")
        let meal = MealBuilder.mealFromRecipe(
            recipe,
            mealType: mealType ?? MealParser.classifyMealType(recipe.name),
            foodItems: allFoodItems
        )
        batchSnapshotPersistence {
            mutateDay(date: targetDate) { $0.meals.append(meal) }
            invalidateDaySummary(for: targetDate)
            recentMeals.insert(meal, at: 0)
            recentMeals = Array(recentMeals.prefix(50))
        }
        return meal
    }

    @discardableResult func logSavedRecipe(_ recipe: SavedRecipe, mealType: MealType? = nil, date: String? = nil) -> Meal {
        let targetDate = date ?? todayKey
        assert(!targetDate.isEmpty, "saved recipe meal date required")
        let meal = SavedRecipeService.makeMeal(from: recipe, mealType: mealType)
        appendMeal(meal, date: targetDate)
        return meal
    }

    @discardableResult func logWebImportedFoodProduct(_ foodItem: FoodItem, mealType: MealType? = nil, date: String? = nil) -> Meal {
        let targetDate = date ?? todayKey
        assert(!targetDate.isEmpty, "web imported product meal date required")
        let meal = Meal(
            name: foodItem.name,
            mealType: mealType ?? MealParser.classifyMealType(foodItem.name),
            macros: foodItem.macros,
            micronutrientSnapshot: foodItem.micronutrients,
            mealSource: .manual,
            quality: foodItem.macros.protein >= Self.goodProteinThreshold ? .good : .ok,
            confidence: "Saved product",
            note: "Logged from saved product.",
            source: MealLogSource.webImport
        )
        appendMeal(meal, date: targetDate)
        return meal
    }

    func savedRecipeShareText(for recipe: SavedRecipe) -> String {
        savedRecipeService.shareText(for: recipe)
    }

    func addSavedRecipe(_ recipe: SavedRecipe) {
        savedRecipeService.add(recipe)
    }

    func processSharedRecipeImportQueue() async {
        guard !isProcessingSharedRecipeImportQueue else { return }
        isProcessingSharedRecipeImportQueue = true
        defer { isProcessingSharedRecipeImportQueue = false }

        let queue = SharedRecipeImportQueue()
        let maxAge: TimeInterval = 7 * 24 * 3600
        for record in queue.records() {
            guard let url = record.url else {
                queue.remove(record)
                continue
            }
            if record.attemptCount >= 3 || Date().timeIntervalSince(record.queuedAt) > maxAge {
                queue.remove(record)
                continue
            }

            do {
                let importedRecipe = try await RecipeWebImporter.importRecipe(from: url, foodItems: allFoodItems, aiEnabled: settings.aiStatus != .off)
                addSavedRecipe(SavedRecipe(importedRecipe: importedRecipe))
                queue.remove(record)
            } catch {
                let description = (error as? LocalizedError)?.errorDescription ?? "Could not import that recipe."
                queue.markAttempt(record, errorDescription: description)
                FernletAuditLog.log("recipe.shareExtensionImport.failed", context: [
                    "host": url.host() ?? "unknown",
                    "errorType": "\(type(of: error))"
                ])
            }
        }
    }

    func updateSavedRecipe(_ recipe: SavedRecipe) {
        savedRecipeService.update(recipe)
    }

    func deleteSavedRecipe(_ recipe: SavedRecipe) {
        savedRecipeService.delete(recipe)
    }

    func addWorkout(_ workout: Workout) {
        addWorkout(workout, date: todayKey)
    }

    func addWorkout(_ workout: Workout, date: String) {
        assert(!date.isEmpty, "workout date required")
        batchSnapshotPersistence {
            mutateDay(date: date) { $0.workouts.append(workout) }
            invalidateDaySummary(for: date)
        }
        guard workout.healthKitUUID == nil else { return }
        Task { [weak self] in
            await self?.workoutHealthKitSync.saveIfAuthorized(workout, date: date)
        }
    }

    func planWorkout(_ plannedWorkout: PlannedWorkout, date: String) {
        assert(!date.isEmpty, "planned workout date required")
        mutateDay(date: date) { day in
            day.plannedWorkouts.removeAll { $0.id == plannedWorkout.id }
            day.plannedWorkouts.append(plannedWorkout)
            day.plannedWorkouts.sort { $0.createdAt < $1.createdAt }
        }
    }

    func copiedForwardWorkoutSplit(before date: String) -> WorkoutSplit? {
        assert(!date.isEmpty, "planned workout date required")
        let days = loadDays()
        if let sameDaySplit = days[date]?.plannedWorkouts.last?.split {
            return sameDaySplit
        }
        return days
            .filter { $0.key < date }
            .sorted { $0.key > $1.key }
            .compactMap { $0.value.plannedWorkouts.last?.split }
            .first
    }

    func previousWeekPlannedWorkout(for date: String) -> PlannedWorkout? {
        assert(!date.isEmpty, "planned workout date required")
        guard let targetDate = FernletDate.date(fromDayKey: date),
              let previousWeekDate = Calendar.current.date(byAdding: .day, value: -7, to: targetDate) else {
            return nil
        }
        let previousWeekKey = FernletDate.dayKey(for: previousWeekDate)
        return loadDay(for: previousWeekKey).plannedWorkouts.first
    }

    func deletePlannedWorkout(_ plannedWorkout: PlannedWorkout, date: String) {
        assert(!date.isEmpty, "planned workout date required")
        mutateDay(date: date) { day in
            day.plannedWorkouts.removeAll { $0.id == plannedWorkout.id }
        }
    }

    func completePlannedWorkout(_ plannedWorkout: PlannedWorkout, date: String) {
        assert(!date.isEmpty, "planned workout date required")
        var workout = plannedWorkout.completedWorkout
        if let targetDate = FernletDate.date(fromDayKey: date),
           let completedAt = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: targetDate) {
            workout.completedAt = completedAt
            workout.loggedAt = completedAt
        }
        addWorkout(workout, date: date)
        mutateDay(date: date) { day in
            day.plannedWorkouts.removeAll { $0.id == plannedWorkout.id }
        }
    }

    func refreshWorkoutsFromHealth() async {
        await workoutHealthKitSync.refreshFromHealth()
    }

    func backfillWorkoutsFromHealthIfNeeded(defaults: UserDefaults = .standard) async {
        await workoutHealthKitSync.backfillIfNeeded(defaults: defaults)
    }

    func stopHealthKitWorkoutObservation() {
        workoutHealthKitSync.stopObservation()
    }

    func addJournal(text: String, tag: FeelingTag) {
        let entry = JournalEntry(text: text, tag: tag)
        sealJournalEntry(entry, dayKey: todayKey)
        batchSnapshotPersistence {
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
        snapshotSaveCoordinator.schedule()
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
        snapshotSaveCoordinator.schedule()
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
        snapshotSaveCoordinator.schedule()
    }

    func addBottle() {
        day.bottleCount = min(day.bottleCount + 1, 30)
        snapshotSaveCoordinator.schedule()
    }

    func removeBottle() {
        day.bottleCount = max(day.bottleCount - 1, 0)
        snapshotSaveCoordinator.schedule()
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

    func loadDayWithDecryptedJournals(for dateKey: String) -> FernletDay {
        var loaded = loadDay(for: dateKey)
        let emptyEntries = loaded.journals.filter { $0.text.isEmpty }
        guard !emptyEntries.isEmpty, let key = activeJournalRefreshKey() else { return loaded }
        let narratives = (try? journalNarrativeRepository.narratives(forDayKey: dateKey, contentKey: key)) ?? []
        let byID = Dictionary(narratives.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        loaded.journals = loaded.journals.map { entry in
            guard entry.text.isEmpty, let n = byID[entry.id] else { return entry }
            return JournalEntry(id: entry.id, text: n.text, tag: entry.tag, date: entry.date, emotions: n.emotions)
        }
        return loaded
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
        let entry = JournalEntry(text: text, tag: tag)
        sealJournalEntry(entry, dayKey: date)
        mutateDay(date: date) { $0.journals.append(entry) }
        if date == todayKey {
            previousJournals.insert(entry, at: 0)
            previousJournals = Array(previousJournals.prefix(30))
            if let memory = MemoryNote.fromJournal(text: text, tag: tag) {
                memories.append(memory)
                memories = Array(memories.suffix(300))
            }
        }
    }

    func updateJournal(_ entry: JournalEntry, text: String, tag: FeelingTag, date: String) {
        assert(!date.isEmpty, "journal date required")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updatedEntry = entry
        updatedEntry.text = trimmed
        updatedEntry.tag = tag

        if sealedJournalIDs.contains(entry.id), let key = activeJournalRefreshKey() {
            let updated = JournalNarrative(
                id: entry.id, dayKey: date, tag: tag, entryDate: entry.date,
                text: trimmed, emotions: entry.emotions,
                createdAt: entry.date, updatedAt: Date()
            )
            try? journalNarrativeRepository.update(updated, contentKey: key)
        }

        batchSnapshotPersistence {
            mutateDay(date: date) { targetDay in
                guard let index = targetDay.journals.firstIndex(where: { $0.id == entry.id }) else { return }
                targetDay.journals[index] = updatedEntry
            }
            if let index = previousJournals.firstIndex(where: { $0.id == entry.id }) {
                previousJournals[index] = updatedEntry
            }
        }
    }

    func deleteJournal(_ entry: JournalEntry, date: String) {
        assert(!date.isEmpty, "journal date required")
        try? journalNarrativeRepository.delete(id: entry.id)
        sealedJournalIDs.remove(entry.id)
        batchSnapshotPersistence {
            mutateDay(date: date) { $0.journals.removeAll { $0.id == entry.id } }
            previousJournals.removeAll { $0.id == entry.id }
        }
    }

    func setSleep(hours: Double?, quality: SleepQuality, note: String, date: String) {
        assert(!date.isEmpty, "sleep date required")
        mutateDay(date: date) {
            $0.sleep = SleepLog(hours: hours, quality: quality, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func setBottleCount(_ count: Int, date: String) {
        assert(!date.isEmpty, "water date required")
        let clamped = min(max(count, 0), 30)
        mutateDay(date: date) { $0.bottleCount = clamped }
    }

    func setHygiene(_ hygiene: Set<HygieneItem>, date: String) {
        let ids = Set(hygiene.map(\.rawValue))
        setPersonalCareTaskIDs(ids, date: date)
    }

    func setPersonalCareTaskIDs(_ ids: Set<String>, date: String) {
        assert(!date.isEmpty, "personal care date required")
        let defaultItems = Set(ids.compactMap(HygieneItem.init(rawValue:)))
        mutateDay(date: date) {
            $0.completedPersonalCareTaskIDs = ids
            $0.hygiene = defaultItems
        }
    }

    func replaceGoals(_ newGoals: [FitnessGoal]) {
        goals = Array(newGoals.prefix(12))
        snapshotSaveCoordinator.schedule()
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

    @discardableResult func addRecipe(name: String, servings: Int, notes: String = "", ingredients inputIngredients: [ManualRecipeIngredientInput]) -> RecipeDefinition {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        assert(!trimmedName.isEmpty, "recipe name required")
        let now = Date()
        return batchSnapshotPersistence {
            let selectionCatalog = allFoodItems
            let recipeIngredients = CustomIngredientUpsert.recipeIngredients(
                from: inputIngredients,
                selectionCatalog: selectionCatalog,
                in: &foodItems,
                verifiedAt: now
            )
            let recipe = RecipeDefinition(
                name: trimmedName,
                servings: max(servings, 1),
                ingredients: recipeIngredients,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                source: "manual",
                createdAt: now,
                updatedAt: now
            )
            recipes.insert(recipe, at: 0)
            return recipe
        }
    }

    func updateRecipe(_ recipe: RecipeDefinition, name: String, servings: Int, notes: String = "", ingredients inputIngredients: [ManualRecipeIngredientInput]) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        assert(!trimmedName.isEmpty, "recipe name required")
        guard let index = recipes.firstIndex(where: { $0.id == recipe.id }) else { return }
        batchSnapshotPersistence {
            let selectionCatalog = allFoodItems
            let recipeIngredients = CustomIngredientUpsert.recipeIngredients(
                from: inputIngredients,
                selectionCatalog: selectionCatalog,
                in: &foodItems,
                verifiedAt: Date()
            )
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
            CustomIngredientUpsert.resolve(
                ingredient: ingredient,
                in: &foodItems,
                verifiedAt: Date()
            )
        }
    }

    func cachedWebImportedFoodProduct(for query: String) -> FoodItem? {
        let normalizedQuery = FoodItemSearch.normalized(query)
        guard !normalizedQuery.isEmpty else { return nil }
        let queryTag = "web-query:\(normalizedQuery)"
        return webImportedFoodItems.first { foodItem in
            foodItem.tags.contains(queryTag)
                || FoodItemSearch.normalized(foodItem.name) == normalizedQuery
        }
    }

    @discardableResult func saveWebImportedFoodProduct(_ product: ImportedFoodProduct) -> FoodItem {
        batchSnapshotPersistence {
            let normalizedQuery = product.lookupQuery.map(FoodItemSearch.normalized)
            let queryTags = normalizedQuery.map { ["web-query:\($0)"] } ?? []
            let foodItem = FoodItem(
                name: product.name.trimmingCharacters(in: .whitespacesAndNewlines),
                brandSource: product.brand ?? product.sourceURL.host(),
                servingSize: 1,
                servingUnit: RecipeUnit.serving.rawValue,
                macros: product.macros,
                micronutrients: product.micronutrients,
                category: "web product",
                source: .aiResolved,
                dataType: .branded,
                sourceURL: product.sourceURL,
                servingDescription: product.servingSize,
                lastVerified: Date(),
                tags: (["web-import", product.sourceURL.host()].compactMap { $0 } + queryTags).sorted()
            )
            let normalizedName = FoodItemSearch.normalized(foodItem.name)
            if let existingIndex = foodItems.firstIndex(where: {
                $0.source == .aiResolved && FoodItemSearch.normalized($0.name) == normalizedName
            }) {
                var updatedFoodItem = foodItem
                updatedFoodItem.id = foodItems[existingIndex].id
                foodItems[existingIndex] = updatedFoodItem
                return updatedFoodItem
            }
            foodItems.append(foodItem)
            return foodItem
        }
    }

    func deleteRecipe(_ recipe: RecipeDefinition) {
        recipes.removeAll { $0.id == recipe.id }
        snapshotSaveCoordinator.schedule()
    }

    func macroTotals(for recipe: RecipeDefinition) -> MacroTotals {
        MealBuilder.macroTotals(for: recipe, foodItems: allFoodItems)
    }

    func micronutrientTotals(for recipe: RecipeDefinition) -> Micronutrients {
        MealBuilder.micronutrientTotals(for: recipe, foodItems: allFoodItems)
    }

    func recipeShareText(for recipe: RecipeDefinition) -> String {
        RecipeShareCodec.shareText(for: recipe, foodItems: allFoodItems)
    }

    func proximityRecipeSharePayload(for recipe: RecipeDefinition) -> ProximityRecipeSharePayload {
        RecipeShareCodec.proximityPayload(for: recipe, foodItems: allFoodItems)
    }

    func proximityRecipeSharePayload(for recipe: SavedRecipe) -> ProximityRecipeSharePayload {
        RecipeShareCodec.proximityPayload(for: recipe)
    }

    @discardableResult func importProximityRecipeShare(_ payload: ProximityRecipeSharePayload) throws -> String {
        guard payload.format == "fernlet.proximity.recipe", payload.version == 1 else {
            throw RecipeImportError.unsupportedFormat
        }

        switch payload.recipe.kind {
        case .local:
            guard let localPayload = payload.recipe.local else { throw RecipeImportError.invalidPayload }
            let data = try JSONEncoder().encode(localPayload)
            guard let text = String(data: data, encoding: .utf8) else { throw RecipeImportError.invalidPayload }
            return try importRecipe(from: text).name
        case .saved:
            guard let savedPayload = payload.recipe.saved,
                  let sourceURL = URL(string: savedPayload.sourceURLString) else {
                throw RecipeImportError.invalidPayload
            }
            let trimmedName = savedPayload.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { throw RecipeImportError.emptyRecipe }
            let recipe = SavedRecipe(
                sourceURL: sourceURL,
                name: trimmedName,
                ingredients: savedPayload.ingredients,
                summary: savedPayload.summary.trimmingCharacters(in: .whitespacesAndNewlines),
                servings: savedPayload.servings,
                protein: savedPayload.protein,
                carbs: savedPayload.carbs,
                fat: savedPayload.fat,
                micronutrients: savedPayload.micronutrients
            )
            addSavedRecipe(recipe)
            return recipe.name
        }
    }

    @discardableResult func importRecipe(from text: String) throws -> RecipeDefinition {
        let payload = try RecipeShareCodec.decodePayload(from: text)
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
        aiRetryQueueService.queueMealRetry(meal)
    }

    func clearRetryItem(_ id: UUID) {
        aiRetryQueueService.clear(id: id)
    }

    func retryOldestMeal() async {
        guard let record = aiRetryQueueService.retryQueue.first else { return }
        if let meal = day.meals.first(where: { $0.id == record.sourceId }) {
            let description = meal.name
            deleteMeal(meal)
            await addResolvedMeals(from: description)
        } else {
            aiRetryQueueService.clear(id: record.id)
        }
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
            foodItems = []
            recipes = []
            dailyScores = []
            connectionSessionLogs = []
        }
        savedRecipeService.reset()
        aiRetryQueueService.reset()
        proximityTrustVault.apply(peers: [], audit: [])
    }

    private func rebuildDerivedSignals() {
        derivedSignalsService.rebuild(allDays: loadDays(), todayKey: todayKey)
    }

    func deferredPostLaunchTasks() {
        derivedSignalsService.scheduleDeferredRebuild(
            allDaysProvider: { [weak self] in self?.loadDays() ?? [:] },
            todayKey: todayKey
        )
    }

    func flushPendingSnapshotSave() {
        snapshotSaveCoordinator.flushPending()
    }

    private func reloadFromRepository() async {
        guard !isReloadingFromRepository else { return }
        isReloadingFromRepository = true
        defer { isReloadingFromRepository = false }

        snapshotSaveCoordinator.flushPending()

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
        foodItems = snapshot.foodItems.filter { $0.source != .usda }
        recipes = snapshot.recipes
        dailyScores = snapshot.dailyScores
        connectionSessionLogs = snapshot.connectionSessionLogs
        aiRetryQueueService.apply(snapshot.retryQueue)
        proximityTrustVault.apply(peers: snapshot.trustedProximityPeers, audit: snapshot.trainerAuditEvents)
        connectionInspector.attachStore(self)
        refreshSealedJournalsAfterSnapshotApply()
        rebuildDerivedSignals()
    }

    private func currentSnapshot() -> FernletSnapshot {
        // strippedForStorage always runs: it strips sealed journal text AND sensitive health fields.
        let (storedDay, storedPreviousJournals) = strippedForStorage(day: day, previousJournals: previousJournals)
        return FernletSnapshot(
            todayKey: todayKey,
            day: storedDay,
            settings: settings,
            recentMeals: recentMeals,
            previousJournals: storedPreviousJournals,
            memories: memories,
            goals: goals,
            workshop: workshop,
            foodItems: foodItems,
            recipes: recipes,
            dailyScores: dailyScores,
            retryQueue: aiRetryQueueService.retryQueue,
            connectionSessionLogs: connectionSessionLogs,
            trustedProximityPeers: proximityTrustVault.trustedPeers,
            trainerAuditEvents: proximityTrustVault.auditEvents
        )
    }

    /// Returns copies of day and previousJournals with sealed-entry text, emotions, and
    /// sensitive health fields (cycle, intimacy) removed before writing to the cloud blob.
    /// Cycle/intimacy data is always re-synced from HealthKit; it must not appear in CloudKit.
    private func strippedForStorage(
        day: FernletDay,
        previousJournals: [JournalEntry]
    ) -> (FernletDay, [JournalEntry]) {
        func strip(_ entry: JournalEntry) -> JournalEntry {
            guard sealedJournalIDs.contains(entry.id) else { return entry }
            return JournalEntry(id: entry.id, text: "", tag: entry.tag, date: entry.date, emotions: [])
        }
        var strippedDay = day
        strippedDay.journals = day.journals.map(strip)

        if var context = strippedDay.healthContext {
            context.cycle = nil
            context.intimate = nil
            strippedDay.healthContext = context
        }

        return (strippedDay, previousJournals.map(strip))
    }

    private func batchSnapshotPersistence<T>(_ updates: () throws -> T) rethrows -> T {
        let result = try updates()
        snapshotSaveCoordinator.schedule()
        return result
    }


    func markLaunchScreenDismissed() {}

    func loadBundledFoodItemsForLaunch() async {
        guard bundledFoodSeedingService.state == .notStarted else { return }

        let items = await bundledFoodSeedingService.load()
        if !items.isEmpty {
            bundledFoodItems = items
        }
    }

    func ensureBundledFoodItemsSeeded() {
        guard bundledFoodSeedingService.state == .notStarted else { return }

        Task { @MainActor [weak self] in
            await self?.loadBundledFoodItemsForLaunch()
        }
    }
}

// MARK: - Sealed Journal Management (Phase S2)

extension FernletStore {
    /// Call at startup when no lock is configured: seals any legacy plaintext blob entries
    /// with the device key and populates in-memory journal text from the device-key-sealed store.
    func activateNoLockJournals() {
        journalActivationMode = .noLock
        let key = deviceJournalKey
        migrateExistingJournalsToSealedStore(contentKey: key)
        refreshSealedJournals(contentKey: key)
    }

    /// Call on unlock: migrates any device-key-sealed entries, sets the content key,
    /// populates in-memory journal text from the sealed store, and migrates legacy plaintext entries.
    func activateSealedJournals(contentKey: SymmetricKey) {
        journalContentKey = contentKey
        journalActivationMode = .sealedUnlocked
        migrateDeviceKeyEntriesToUserKey(userKey: contentKey)
        refreshSealedJournals(contentKey: contentKey)
        migrateExistingJournalsToSealedStore(contentKey: contentKey)
    }

    /// Call on lock: scrubs in-memory journal text for sealed entries and clears the key.
    func deactivateSealedJournals() {
        let ids = sealedJournalIDs
        if !ids.isEmpty {
            day.journals = day.journals.map { entry in
                guard ids.contains(entry.id) else { return entry }
                return JournalEntry(id: entry.id, text: "", tag: entry.tag, date: entry.date, emotions: [])
            }
            previousJournals = previousJournals.map { entry in
                guard ids.contains(entry.id) else { return entry }
                return JournalEntry(id: entry.id, text: "", tag: entry.tag, date: entry.date, emotions: [])
            }
            sealedJournalIDs.removeAll()
        }
        journalContentKey = nil
        journalActivationMode = .sealedLocked
    }

    // MARK: Private helpers

    private func activeJournalRefreshKey() -> SymmetricKey? {
        switch journalActivationMode {
        case .inactive, .sealedLocked:
            return nil
        case .noLock:
            return deviceJournalKey
        case .sealedUnlocked:
            return journalContentKey
        }
    }

    private func refreshSealedJournalsAfterSnapshotApply() {
        guard let key = activeJournalRefreshKey() else { return }
        refreshSealedJournals(contentKey: key)
    }

    /// Device-bound key generated on first use and stored in Keychain (not iCloud-synced).
    /// Used to seal journal text when no user lock is configured, ensuring text never reaches the blob.
    private var deviceJournalKey: SymmetricKey {
        if let data = KeychainItem.load(for: .deviceJournalKey, service: KeychainItem.journalService) {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        KeychainItem.store(keyData, for: .deviceJournalKey, service: KeychainItem.journalService)
        return key
    }

    /// Seals a journal entry into JournalNarrativeRepository.
    /// Uses the user content key when a lock is configured; falls back to the device key so that
    /// journal text is never written to the iCloud-synced blob even without a lock.
    private func sealJournalEntry(_ entry: JournalEntry, dayKey: String) {
        let key = journalContentKey ?? deviceJournalKey
        let narrative = JournalNarrative(
            id: entry.id, dayKey: dayKey, tag: entry.tag, entryDate: entry.date,
            text: entry.text, emotions: entry.emotions,
            createdAt: entry.date, updatedAt: entry.date
        )
        do {
            try journalNarrativeRepository.insert(narrative, contentKey: key)
            sealedJournalIDs.insert(entry.id)
        } catch {
            print("[Fernlet] Journal sealing failed for \(entry.id): \(error)")
            // Do NOT add the entry to sealedJournalIDs on failure. Leaving it unsealed keeps
            // its plaintext in the local snapshot (so the user's text is never lost) and lets
            // migrateExistingJournalsToSealedStore (run from activateNoLockJournals /
            // activateSealedJournals on the next launch or unlock) retry sealing it, since it
            // targets exactly `!text.isEmpty && !sealedJournalIDs.contains(id)` entries.
            // We prioritise no-data-loss over the rare transient case where the text briefly
            // remains in the user's own (already-encrypted) private store instead of the
            // app-sealed narrative store.
        }
    }

    /// When the user sets up a lock for the first time, re-encrypts entries that were previously
    /// sealed with the device key so they become protected by the user's content key.
    private func migrateDeviceKeyEntriesToUserKey(userKey: SymmetricKey) {
        let dKey = deviceJournalKey
        let todayNarratives = (try? journalNarrativeRepository.narratives(
            forDayKey: todayKey, contentKey: dKey)) ?? []
        let prevDayKeys = Array(Set(
            previousJournals.filter { $0.text.isEmpty }.map { FernletDate.dayKey(for: $0.date) }
        ))
        let prevNarratives = prevDayKeys.isEmpty ? [] :
            ((try? journalNarrativeRepository.narratives(
                forDayKeys: prevDayKeys, contentKey: dKey)) ?? [])
        for narrative in todayNarratives + prevNarratives {
            try? journalNarrativeRepository.update(narrative, contentKey: userKey)
        }
    }

    /// Loads decrypted text from the sealed store into in-memory journal entries that have empty text.
    private func refreshSealedJournals(contentKey: SymmetricKey) {
        // Today's journals
        let emptyToday = day.journals.filter { $0.text.isEmpty }
        if !emptyToday.isEmpty {
            let narratives = (try? journalNarrativeRepository.narratives(forDayKey: todayKey, contentKey: contentKey)) ?? []
            let byID = Dictionary(narratives.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            day.journals = day.journals.map { entry in
                guard entry.text.isEmpty, let n = byID[entry.id] else { return entry }
                sealedJournalIDs.insert(entry.id)
                return JournalEntry(id: entry.id, text: n.text, tag: entry.tag, date: entry.date, emotions: n.emotions)
            }
        }

        // Cross-day previousJournals
        let emptyPrevious = previousJournals.filter { $0.text.isEmpty }
        if !emptyPrevious.isEmpty {
            let dayKeys = Array(Set(emptyPrevious.map { FernletDate.dayKey(for: $0.date) }))
            let narratives = (try? journalNarrativeRepository.narratives(forDayKeys: dayKeys, contentKey: contentKey)) ?? []
            let byID = Dictionary(narratives.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            previousJournals = previousJournals.map { entry in
                guard entry.text.isEmpty, let n = byID[entry.id] else { return entry }
                sealedJournalIDs.insert(entry.id)
                return JournalEntry(id: entry.id, text: n.text, tag: entry.tag, date: entry.date, emotions: n.emotions)
            }
        }
    }

    /// One-time migration: seals legacy journal entries that still have plaintext in the blob,
    /// then schedules a save so the stripped version is persisted.
    private func migrateExistingJournalsToSealedStore(contentKey: SymmetricKey) {
        var anyMigrated = false

        for entry in previousJournals where !entry.text.isEmpty && !sealedJournalIDs.contains(entry.id) {
            let dayKey = FernletDate.dayKey(for: entry.date)
            let narrative = JournalNarrative(
                id: entry.id, dayKey: dayKey, tag: entry.tag, entryDate: entry.date,
                text: entry.text, emotions: entry.emotions,
                createdAt: entry.date, updatedAt: entry.date
            )
            if (try? journalNarrativeRepository.insert(narrative, contentKey: contentKey)) != nil {
                sealedJournalIDs.insert(entry.id)
                anyMigrated = true
            }
        }

        for entry in day.journals where !entry.text.isEmpty && !sealedJournalIDs.contains(entry.id) {
            let narrative = JournalNarrative(
                id: entry.id, dayKey: todayKey, tag: entry.tag, entryDate: entry.date,
                text: entry.text, emotions: entry.emotions,
                createdAt: entry.date, updatedAt: entry.date
            )
            if (try? journalNarrativeRepository.insert(narrative, contentKey: contentKey)) != nil {
                sealedJournalIDs.insert(entry.id)
                anyMigrated = true
            }
        }

        if anyMigrated {
            // Trigger a save so the stripped (empty-text) version replaces the plaintext in the blob.
            snapshotSaveCoordinator.schedule()
        }
    }
}

extension FernletStore {
    /// Mutates the day for the given date key. Today mutates the in-memory day;
    /// past dates round-trip through the repository.
    @discardableResult
    func mutateDay(date: String, _ change: (inout FernletDay) -> Void) -> Bool {
        assert(!date.isEmpty, "date key required")
        if date == todayKey {
            change(&day)
            snapshotSaveCoordinator.schedule()
            return true
        }
        return mutatePastDay(date, change)
    }
}

extension FernletStore: WorkoutSyncContext {
    func workoutExists(id: UUID) -> Bool {
        loadDays().values.contains { day in
            day.workouts.contains { $0.id == id }
        }
    }

    func workoutExists(healthKitUUID: UUID) -> Bool {
        loadDays().values.contains { day in
            day.workouts.contains { $0.healthKitUUID == healthKitUUID }
        }
    }

    func setWorkoutHealthKitUUID(workoutID: UUID, hkUUID: UUID, date: String) {
        batchSnapshotPersistence {
            if date == todayKey {
                if let index = day.workouts.firstIndex(where: { $0.id == workoutID }) {
                    day.workouts[index].healthKitUUID = hkUUID
                    return
                }
            } else {
                let targetDay = repository.loadDay(for: date, todayKey: todayKey)
                if targetDay.workouts.contains(where: { $0.id == workoutID }) {
                    mutatePastDay(date) { day in
                        if let index = day.workouts.firstIndex(where: { $0.id == workoutID }) {
                            day.workouts[index].healthKitUUID = hkUUID
                        }
                    }
                    return
                }
            }

            if let index = day.workouts.firstIndex(where: { $0.id == workoutID }) {
                day.workouts[index].healthKitUUID = hkUUID
                return
            }

            for (dateKey, pastDay) in repository.loadAllDays() where dateKey != todayKey {
                guard pastDay.workouts.contains(where: { $0.id == workoutID && $0.healthKitUUID == nil }) else { continue }
                mutatePastDay(dateKey) { targetDay in
                    if let index = targetDay.workouts.firstIndex(where: { $0.id == workoutID && $0.healthKitUUID == nil }) {
                        targetDay.workouts[index].healthKitUUID = hkUUID
                    }
                }
                return
            }
        }
    }

    func upsertWorkout(_ workout: Workout, date: String) {
        addWorkout(workout, date: date)
    }
}

extension FernletStore {
    static func load(
        date: Date = .now,
        repository: FernletRepository? = nil,
        persistenceController: PersistenceController? = nil,
        statusUpdate: @MainActor @escaping (String) -> Void = { _ in }
    ) async throws -> FernletStore {
        let loadSignpostID = StartupTiming.begin("FernletStore.load")
        defer { StartupTiming.end("FernletStore.load", signpostID: loadSignpostID) }

        let key = FernletDate.dayKey(for: date)
        assert(!key.isEmpty, "today key required")

        statusUpdate("Opening your records...")
        await Task.yield()

        let sharedPersistenceController: PersistenceController?
        if repository == nil {
            let controller = persistenceController ?? PersistenceController.shared
            guard !controller.didFailToLoad else {
                throw PersistenceStoreLoadError.primaryStoreUnavailable
            }
            sharedPersistenceController = controller
        } else {
            sharedPersistenceController = nil
        }

        let activeRepository = StartupTiming.timed("CoreDataFernletRepository.init") {
            repository ?? CoreDataFernletRepository(controller: sharedPersistenceController)
        }
        let savedRecipeService = StartupTiming.timed("SavedRecipeService.init") {
            SavedRecipeService()
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
        await savedRecipeService.loadAsync()

        return FernletStore(
            snapshot: snapshot,
            todayKey: key,
            repository: activeRepository,
            savedRecipeService: savedRecipeService,
            healthKitService: nil
        )
    }
}

extension FernletStore: ProximityTrustPolicy {}

// MARK: - Models
