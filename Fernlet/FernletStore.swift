import ProximityKit
import CryptoKit
import CloudKitSync
import FernletLock
import LocalPersistence
import AIProviders
import FernletFoundation
import HealthKit
import Observation
import SwiftUI
import FernletDomainModel
import PrivateMemoryStore
import FernletScoring
import FernletPersistence
import FoodCatalog
import PrivateHealthStore
import PrivateMediaStore
import PeriodContextBridge
import StoreCore
import DiaryStore
import HealthKitGateway
import AppServices

@MainActor
@Observable
final class FernletStore {
    /// The portable diary slice. Owns the pure diary state + pure diary methods; this facade owns
    /// the app-only collaborators (coordinators, proximity, snapshot machinery, retry/derived/
    /// saved-recipe services, the period bridge) and forwards every diary member to it. Accessing
    /// `diary.<prop>` still participates in observation (the @Observable tracking is on DiaryStore).
    @ObservationIgnored let diary: DiaryStore

    // MARK: - Diary forwarders (state moved to DiaryStore; settable forwarders write through)
    var day: FernletDay {
        get { diary.day }
        set { diary.day = newValue }
    }
    var settings: FernletSettings {
        get { diary.settings }
        set { diary.settings = newValue }
    }
    var recentMeals: [Meal] {
        get { diary.recentMeals }
        set { diary.recentMeals = newValue }
    }
    var previousJournals: [JournalEntry] {
        get { diary.previousJournals }
        set { diary.previousJournals = newValue }
    }
    var memories: [MemoryNote] {
        get { diary.memories }
        set { diary.memories = newValue }
    }
    var goals: [FitnessGoal] {
        get { diary.goals }
        set { diary.goals = newValue }
    }
    var workshop: WorkshopData {
        get { diary.workshop }
        set { diary.workshop = newValue }
    }
    var foodItems: [FoodItem] {
        get { diary.foodItems }
        set { diary.foodItems = newValue }
    }
    var webImportedFoodItems: [FoodItem] { diary.webImportedFoodItems }
    var allowsWebNutritionLookup: Bool { diary.allowsWebNutritionLookup }
    var recipes: [RecipeDefinition] {
        get { diary.recipes }
        set { diary.recipes = newValue }
    }
    var dailyScores: [DailyHealthScore] {
        get { diary.dailyScores }
        set { diary.dailyScores = newValue }
    }
    var companionThought: String? {
        get { diary.companionThought }
        set { diary.companionThought = newValue }
    }

    // MARK: - App-only state
    var connectionSessionLogs: [ConnectionSessionLog]
    var showConnectionInspector = false
    var connectionInspector = ConnectionInspector()
    var isDisposableCameraLandscape = false
    var savedRecipes: [RecipeDefinition] {
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
    var photowallSeeds: [PhotowallSeed] = []
    var lockState: FernletLockState = .notConfigured

    var todayKey: String { diary.todayKey }
    private var repository: FernletRepository { diary.repository }
    @ObservationIgnored let savedRecipeService: SavedRecipeService
    @ObservationIgnored let customItemService: CustomItemService
    @ObservationIgnored let coinLedgerService: CoinLedgerService
    @ObservationIgnored let proximityTrustVault: ProximityTrustVault
    @ObservationIgnored let aiRetryQueueService: AIRetryQueueService
    @ObservationIgnored private(set) lazy var meshNetworkManager: MeshNetworkManager = MeshNetworkManager(store: self)
    @ObservationIgnored private(set) lazy var recipeShareManager: ProximityRecipeShareManager = ProximityRecipeShareManager(store: self)
    @ObservationIgnored private(set) lazy var clothingShareManager: ProximityClothingShareManager = {
        let manager = ProximityClothingShareManager(store: self)
        // Auto-broadcast this device's current shop to each peer on connect.
        manager.localCatalogProvider = { [weak self] in self?.buildShopCatalog() }
        return manager
    }()
    @ObservationIgnored let derivedSignalsService = DerivedSignalsService()
    @ObservationIgnored private let healthKitService: (any HealthKitServicing)?
    @ObservationIgnored private lazy var healthSyncCoordinator = HealthSyncCoordinator(host: self, healthKitService: healthKitService)
    @ObservationIgnored private lazy var workoutPlanningService = WorkoutPlanningService(host: self)
    @ObservationIgnored private lazy var mealResolutionService = MealResolutionService(host: self)
    @ObservationIgnored private lazy var sealedBackupCoordinator = SealedBackupCoordinator(host: self)
    @ObservationIgnored private lazy var snapshotSaveCoordinator = SnapshotSaveCoordinator(
        repository: diary.repository,
        buildSnapshot: { [unowned self] in self.currentSnapshot() },
        onAfterSave: { [weak self] in self?.rebuildDerivedSignals() }
    )
    /// Read-only SQLite-backed bundled food store + user-item snapshot. Replaces the old in-memory
    /// `bundledFoodItems` array; see FoodCatalog.swift. Forwarded to DiaryStore (it owns it).
    var foodCatalog: FoodCatalog { diary.foodCatalog }
    @ObservationIgnored private var isReloadingFromRepository = false
    @ObservationIgnored private let mealPhotoStore = MealPhotoStore(
        directory: (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("MealPhotos", isDirectory: true)
    )
    /// Injected (or nil → default) journal narrative repository, captured so the lazily-built
    /// `journalSealingCoordinator` can own it.
    @ObservationIgnored private let providedJournalNarrativeRepository: (any JournalNarrativeStoring)?
    @ObservationIgnored private lazy var journalSealingCoordinator = JournalSealingCoordinator(
        host: self,
        narrativeRepository: providedJournalNarrativeRepository ?? JournalNarrativeRepository()
    )
    @ObservationIgnored private var isProcessingSharedRecipeImportQueue = false
    /// Read-only abstract egress from the private cycle data into scoring. Nil until the app wires a
    /// `PeriodContextBridge`; when nil (or the opt-in is off) scoring is byte-identical to period-unaware.
    @ObservationIgnored private(set) var periodScoringContext: (any PeriodScoringContextProviding)?

    /// Preference key + current version for the one-time historical past-day journal scrub (WI-1).
    /// Bump `pastDayJournalScrubVersion` to force the full-repository scan to re-run on next activation.
    static let pastDayJournalScrubFlagKey = "pastDayJournalScrubVersion"
    static let pastDayJournalScrubVersion = 1
    /// Counts launches on which the scrub ran but at least one day's seal failed (WI1-1). The run-once
    /// version flag is only advanced on a clean (zero-failure) pass, so a *transiently* failed day is
    /// retried on a later launch; this counter caps that retry loop at `pastDayJournalScrubMaxAttempts`
    /// so a *permanently* failing entry (e.g. malformed content) can't make the bulk scan run on every
    /// launch forever. Cleared whenever the scrub reaches a terminal state (clean pass or give-up).
    static let pastDayJournalScrubAttemptsKey = "pastDayJournalScrubAttempts"
    static let pastDayJournalScrubMaxAttempts = 3
    /// Backing store for the run-once scrub flag. Injectable so tests can isolate the gate from the
    /// shared `.standard` suite (the scrub fires from journal activation, which many tests trigger).
    @ObservationIgnored var pastDayJournalScrubDefaults: UserDefaults = .standard
    /// In-memory, per-app-session guard so the scrub's retry budget counts LAUNCHES, not lock/unlock
    /// activations: `scrubLeakedPastDayJournalsIfNeeded` runs on every activation, so without this a few
    /// lock/unlock cycles in one session would exhaust the budget and give up prematurely (WI1-1 #2). Only
    /// a fresh process launch resets it.
    @ObservationIgnored private var pastDayScrubBudgetConsumedThisSession = false

    init(date: Date = .now, repository: FernletRepository? = nil, savedRecipeRepository: SavedRecipeRepository? = nil, customItemRepository: (any CustomItemRepositoring)? = nil, coinLedgerRepository: (any CoinLedgerRepositoring)? = nil, healthKitService: (any HealthKitServicing)? = nil, journalNarrativeRepository: (any JournalNarrativeStoring)? = nil, foodCatalog: FoodCatalog = .bundled()) {
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
        self.savedRecipeService = savedRecipeService
        let customItemService = StartupTiming.timed("CustomItemService.init") {
            CustomItemService(repository: customItemRepository ?? CustomItemRepository())
        }
        customItemService.loadSync()
        self.customItemService = customItemService
        let coinLedgerService = StartupTiming.timed("CoinLedgerService.init") {
            CoinLedgerService(repository: coinLedgerRepository ?? CoinLedgerRepository())
        }
        coinLedgerService.loadSync()
        self.coinLedgerService = coinLedgerService
        self.healthKitService = healthKitService
        self.connectionSessionLogs = snapshot.connectionSessionLogs
        self.proximityTrustVault = ProximityTrustVault(
            initialPeers: snapshot.trustedProximityPeers,
            initialAudit: snapshot.trainerAuditEvents
        )
        self.aiRetryQueueService = AIRetryQueueService(initial: snapshot.retryQueue)
        self.providedJournalNarrativeRepository = journalNarrativeRepository
        self.diary = DiaryStore(
            snapshot: snapshot,
            todayKey: key,
            repository: activeRepository,
            foodCatalog: foodCatalog,
            scheduleSnapshotSave: { },
            periodAdjustment: { _ in .none }
        )
        // Wire the two diary closures to the facade now that `self` exists. (Set after the diary is
        // built so the closures can capture `self` weakly without an initialization-order cycle.)
        self.diary.rewireHooks(
            scheduleSnapshotSave: { [weak self] in self?.snapshotSaveCoordinator.schedule() },
            periodAdjustment: { [weak self] key in self?.periodAdjustment(for: key) ?? .none },
            sealedJournalIDs: { [weak self] in self?.journalSealingCoordinator.sealedJournalIDs ?? [] }
        )
        // Mint the anonymous designer id now (not lazily from a view body) so the first Wardrobe/Studio
        // render is a pure read and never mutates @Observable state mid-update.
        self.diary.ensureLocalDesignerID()
        self.connectionInspector.attachStore(self)
        proximityTrustVault.onChange = { [weak self] in self?.snapshotSaveCoordinator.schedule() }
        aiRetryQueueService.onChange = { [weak self] in self?.snapshotSaveCoordinator.schedule() }
        rebuildDerivedSignals()
        // Credit any active day not yet in the coin ledger (reuses the warm `loadDays()` cache from the
        // derived-signals rebuild just above). Idempotent — re-running never double-grants.
        reconcileCoinLedger()
        snapshotSaveCoordinator.subscribeRemote { [weak self] in
            await self?.reloadFromRepository()
        }
    }

    private init(
        snapshot: FernletSnapshot,
        todayKey: String,
        repository: FernletRepository,
        savedRecipeService: SavedRecipeService,
        customItemService: CustomItemService,
        coinLedgerService: CoinLedgerService,
        healthKitService: (any HealthKitServicing)? = nil,
        foodCatalog: FoodCatalog = .bundled()
    ) {
        self.savedRecipeService = savedRecipeService
        self.customItemService = customItemService
        self.coinLedgerService = coinLedgerService
        self.healthKitService = healthKitService
        self.connectionSessionLogs = snapshot.connectionSessionLogs
        self.proximityTrustVault = ProximityTrustVault(
            initialPeers: snapshot.trustedProximityPeers,
            initialAudit: snapshot.trainerAuditEvents
        )
        self.aiRetryQueueService = AIRetryQueueService(initial: snapshot.retryQueue)
        self.providedJournalNarrativeRepository = nil
        self.diary = DiaryStore(
            snapshot: snapshot,
            todayKey: todayKey,
            repository: repository,
            foodCatalog: foodCatalog,
            scheduleSnapshotSave: { },
            periodAdjustment: { _ in .none }
        )
        self.diary.rewireHooks(
            scheduleSnapshotSave: { [weak self] in self?.snapshotSaveCoordinator.schedule() },
            periodAdjustment: { [weak self] key in self?.periodAdjustment(for: key) ?? .none },
            sealedJournalIDs: { [weak self] in self?.journalSealingCoordinator.sealedJournalIDs ?? [] }
        )
        self.diary.ensureLocalDesignerID()
        self.connectionInspector.attachStore(self)
        proximityTrustVault.onChange = { [weak self] in self?.snapshotSaveCoordinator.schedule() }
        aiRetryQueueService.onChange = { [weak self] in self?.snapshotSaveCoordinator.schedule() }
        reconcileCoinLedger()
        snapshotSaveCoordinator.subscribeRemote { [weak self] in
            await self?.reloadFromRepository()
        }
    }


    var score: Double {
        let body = day.healthContext?.body
        let activity = day.healthContext?.activity
        return FernletScoring.compute(
            journalTag: day.journals.last?.tag,
            mealCount: day.meals.count,
            workoutCount: day.workouts.count,
            sleepQuality: day.sleep?.quality,
            bottleCount: day.bottleCount,
            hydrationTarget: settings.hydrationTarget,
            hygiene: day.hygiene,
            hygieneTaskCount: personalCareTasks.count,
            completedPersonalCareTaskCount: personalCareProgress().completed,
            weights: GoalWeights.forGoal(settings.selectedGoal),
            isSick: isSick(on: todayKey),
            nutrientGaps: FernletScoring.dedupedNutrientGaps(from: derivedSignals.flatMap(\.nutrientGaps)),
            micronutrientDataCoverageRatio: FernletScoring.micronutrientDataCoverageRatio(for: day.meals),
            sleepHours: body?.sleepHours,
            sleepStages: body?.sleepStages,
            activitySteps: activity?.steps,
            activeEnergyKilocalories: activity?.activeEnergyKilocalories,
            exerciseMinutes: activity?.exerciseMinutes,
            periodAdjustment: periodAdjustment(for: todayKey)
        )
    }

    var companionState: CompanionState {
        FernletScoring.state(for: score, isSick: isSick(on: todayKey))
    }

    var macroTotals: MacroTotals { diary.macroTotals }

    var micronutrientTotals: Micronutrients { diary.micronutrientTotals }

    var nutritionTargets: NutritionTargets { diary.nutritionTargets }

    var tierTwoMemories: [TierTwoMemoryRecord] { diary.tierTwoMemories }

    var personalCareTasks: [PersonalCareTask] { diary.personalCareTasks }

    func personalCareProgress(for targetDay: FernletDay? = nil) -> (completed: Int, total: Int) {
        diary.personalCareProgress(for: targetDay)
    }

    func isPersonalCareTaskCompleted(_ task: PersonalCareTask, in targetDay: FernletDay? = nil) -> Bool {
        diary.isPersonalCareTaskCompleted(task, in: targetDay)
    }

    func storeDaySummary(_ text: String, for dateKey: String) {
        diary.storeDaySummary(text, for: dateKey)
    }

    func invalidateDaySummary(for dateKey: String) {
        diary.invalidateDaySummary(for: dateKey)
    }

    func storeCompanionThought(_ text: String) {
        diary.storeCompanionThought(text)
    }

    var storageLocation: String { diary.storageLocation }

    var pendingRetryCount: Int {
        aiRetryQueueService.pendingCount
    }

    var isIntimateLoggingAllowed: Bool { diary.isIntimateLoggingAllowed }

    func setHidePredictions(_ hidePredictions: Bool) {
        diary.setHidePredictions(hidePredictions)
    }

    func setHideFertileWindow(_ hideFertileWindow: Bool) {
        diary.setHideFertileWindow(hideFertileWindow)
    }

    func setPeriodAwareScoringEnabled(_ enabled: Bool) {
        diary.setPeriodAwareScoringEnabled(enabled)
    }

    func markPeriodContextPrimerSeen() {
        diary.markPeriodContextPrimerSeen()
    }

    /// Wires the read-only period→scoring bridge. Called once from `ContentView` after the period store
    /// exists. Held only as the abstract `PeriodScoringContextProviding` — the store never sees a raw
    /// cycle type.
    func attachPeriodScoringContext(_ context: any PeriodScoringContextProviding) {
        periodScoringContext = context
    }

    /// The pre-gated period adjustment for a day, or `.none` when period-aware scoring is opted out or no
    /// bridge is attached. This is the single gate point for the opt-in; the bridge applies the 3-cycle and
    /// confidence gates internally. Supplied to DiaryStore as the injected `periodAdjustment` closure so
    /// the pure scoring methods stay byte-identical without naming the (facade-only) bridge.
    func periodAdjustment(for dayKey: String) -> PeriodScoringAdjustment {
        guard settings.periodAwareScoringEnabled, let periodScoringContext else { return .none }
        return periodScoringContext.scoringAdjustment(forDayKey: dayKey)
    }

    /// Non-sensitive per-day wellbeing component scores (sleep/mood/exercise/nutrition) fed into the period
    /// bridge so its trend engine can correlate them against cycle phase. Sourced from already-computed
    /// `dailyScores`; nothing sensitive flows out.
    var periodWellbeingByDay: [String: PeriodWellbeingSample] {
        var result: [String: PeriodWellbeingSample] = [:]
        for score in dailyScores {
            guard let components = score.componentScores else { continue }
            result[score.dateKey] = PeriodWellbeingSample(
                sleep: components["sleep"],
                mood: components["journal"],
                exercise: components["workout"],
                nutrition: components["meal"]
            )
        }
        return result
    }

    func setConnectionInspectorMode(_ mode: ConnectionInspectorMode) {
        settings.connectionInspectorMode = mode
        if mode != .live {
            showConnectionInspector = false
        }
        snapshotSaveCoordinator.schedule()
    }

    func setCompanionAppearance(_ appearance: CompanionAppearance) {
        diary.setCompanionAppearance(appearance)
    }

    func setCompanionName(_ name: String) {
        diary.setCompanionName(name)
    }

    // MARK: - Custom items (Creation Studio / Wardrobe)
    // Items live in `customItemService` (own per-row store); the equip map + designer id live in settings.

    var customItems: [CustomizationItem] { customItemService.items }

    /// The items currently equipped, one per occupied slot, in slot order. Stale equip references
    /// (deleted item, slot mismatch) resolve to nothing.
    var equippedCustomItems: [CustomizationItem] {
        let map = settings.equippedItemIDsBySlot
        return ItemSlot.allCases.compactMap { slot in
            guard let id = map[slot.rawValue] else { return nil }
            return customItemService.items.first { $0.id == id && $0.slot == slot }
        }
    }

    func saveCustomItem(_ item: CustomizationItem) { customItemService.upsert(item) }

    func deleteCustomItem(id: UUID) {
        customItemService.delete(id: id)
        diary.clearEquipReferences(forItemID: id)
    }

    func equipCustomItem(id: UUID, slot: ItemSlot) { diary.equipCustomItem(id: id, slot: slot) }
    func unequipCustomSlot(_ slot: ItemSlot) { diary.unequipSlot(slot) }
    func setCustomItemShareable(id: UUID, _ shareable: Bool) { customItemService.setShareable(id: id, shareable) }
    func setCustomItemPrice(id: UUID, _ price: Int) { customItemService.setPrice(id: id, price) }

    /// This device's anonymous designer id, stamped onto items the user designs.
    var localDesignerID: UUID { diary.localDesignerID }

    /// Whether `item` was designed on this device.
    func isSelfDesigned(_ item: CustomizationItem) -> Bool { item.designer.id == localDesignerID }

    /// Resolves an item's provenance to a display name: "You" for own designs, the locally-learned name
    /// for a known friend-designer, or a generic fallback for a designer this device hasn't met yet.
    func designerDisplayName(for item: CustomizationItem) -> String {
        if isSelfDesigned(item) { return "You" }
        return settings.knownDesignerNames[item.designer.id.uuidString] ?? "a friend"
    }

    // MARK: - Coins (custom-clothing economy)
    // The ledger lives in `coinLedgerService` (its own per-row, union-merged store). Earning is
    // reconciled from the active-day history; spending appends a row. See `CoinEconomy`.

    /// Total coins ever earned (one credit per active day). Monotonic — unaffected by day-history
    /// pruning or HealthKit being disabled, because earned days are recorded as ledger rows, not
    /// re-derived from the (shrinkable) day history.
    var earnedCoins: Int { coinLedgerService.earnedCoins }

    /// Spendable coin balance (earned − spent, floored at zero).
    var coinBalance: Int { coinLedgerService.balance }

    /// Spends `amount` coins if affordable, appending a ledger row keyed by `ref` (idempotent per ref so
    /// a retried buy can't debit twice). Returns `false` when too few coins or the ref was already spent.
    /// Increment 3 calls this on a buy with the purchased item's id as `ref`.
    @discardableResult
    func spendCoins(_ amount: Int, ref: String = UUID().uuidString) -> Bool {
        coinLedgerService.spend(amount: amount, ref: ref)
    }

    /// Credits any active day not yet in the ledger. Idempotent; called at store launch and on app
    /// foreground so days logged on this or another device accrue exactly once.
    func reconcileCoinLedger() {
        coinLedgerService.reconcile(activeDayKeys: diary.activeDayKeys())
    }

    // MARK: - Clothing shop (in-person friend shop, Increment 3)
    // The catalog exchange runs over `clothingShareManager` (its own per-row mesh session). Buying is
    // local: spend coins + copy the already-received item into the closet, preserving its provenance.

    /// This device's broadcast shop catalog, built from the user's own shareable designs (capped,
    /// deterministically ordered). Supplied to `clothingShareManager` and sent to each peer on connect.
    func buildShopCatalog() -> ClothingCatalogPayload {
        ClothingShareCodec.catalog(
            forShareable: customItems,
            designerID: localDesignerID,
            displayName: shopDisplayName
        )
    }

    /// The seller name a buyer learns in person — the proximity display name, falling back to the
    /// companion name (may be empty, in which case the buyer just sees "a friend").
    private var shopDisplayName: String {
        let proximity = settings.proximityDisplayName.trimmingCharacters(in: .whitespaces)
        if !proximity.isEmpty { return proximity }
        return settings.companionName.trimmingCharacters(in: .whitespaces)
    }

    /// Records a designer id → display name learned by meeting a friend in person, so bought items resolve
    /// "designed by <friend>".
    func learnDesignerName(id: UUID, name: String) {
        diary.setKnownDesignerName(id: id, name: name)
    }

    enum ClothingPurchaseResult: Equatable {
        case bought
        case alreadyOwned
        case insufficientCoins
    }

    /// Buy an item from a friend's shop. Reloads the per-row stores first so another device's spends and
    /// purchases are seen before guarding, sanitizes the (untrusted, peer-sent) item, debits coins
    /// idempotently keyed by the item id, and lands the item in the closet with the SELLER's designer id
    /// preserved (provenance — it shows "designed by <friend>", never "You"). The bought copy is unlisted
    /// and not auto-equipped.
    @discardableResult
    func buyClothingItem(_ rawItem: CustomizationItem, fromDesignerID designerID: UUID, sellerName: String) -> ClothingPurchaseResult {
        // See another device's spends / synced-in purchases before guarding (multi-device reconciliation).
        coinLedgerService.reloadFromStore()
        customItemService.reloadFromStore()
        reconcileCoinLedger()

        let item = ClothingShopLimits.sanitizedForShop(rawItem)
        learnDesignerName(id: designerID, name: sellerName)

        if customItems.contains(where: { $0.id == item.id }) {
            return .alreadyOwned
        }
        let price = item.price
        guard coinBalance >= price else { return .insufficientCoins }

        // Idempotent spend keyed by the item id: a retried/duplicate buy can't debit twice. If the ref was
        // already spent on a prior buy, re-grant the item for free rather than charging again.
        let debited = spendCoins(price, ref: item.id.uuidString)
        var bought = item
        bought.isShareable = false
        // Provenance is the SELLER's declared designer id — NOT the raw per-item `designer` field, which a
        // hostile peer could set to the buyer's own id to forge "self-designed" and re-list someone else's
        // work. If the declared id still collides with this device's own designer id, treat it as unknown
        // provenance so a bought copy can never masquerade as self-made or be re-listed for sale.
        bought.designer = ItemDesigner(id: designerID == localDesignerID ? UUID() : designerID)
        saveCustomItem(bought)
        return debited ? .bought : .alreadyOwned
    }

    // MARK: - Shop listing management (Wardrobe)

    enum ShopListingResult: Equatable {
        case listed
        case nameFlagged
        case capReached
        /// The item isn't listable — not found, or not one of your own designs. Distinct from `capReached`
        /// so the UI never shows a misleading "shop is full" message for the wrong reason.
        case notAllowed
    }

    /// The user's own designs currently listed for sale.
    var listedShopItems: [CustomizationItem] {
        customItems.filter { $0.isShareable && isSelfDesigned($0) }
    }

    /// Whether another item can be listed (under the cap of `ClothingShopLimits.maxListedItems`).
    var canListMoreShopItems: Bool { listedShopItems.count < ClothingShopLimits.maxListedItems }

    /// Whether the shop's listed set was already changed today (drives the gentle once-per-day note).
    var shopUpdatedToday: Bool { settings.shopLastPublishedDayKey == todayKey }

    /// List one of the user's OWN items for sale at `price`. Enforces the cap (a flagged name keeps the
    /// item unlisted with a notice; an over-cap attempt is refused). Records today for the gentle throttle.
    @discardableResult
    func listCustomItemForSale(id: UUID, price: Int) -> ShopListingResult {
        guard let item = customItems.first(where: { $0.id == id }), isSelfDesigned(item) else { return .notAllowed }
        if !item.isShareable && !canListMoreShopItems { return .capReached }
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ItemNameModeration.isAllowedForListing(name) else { return .nameFlagged }
        customItemService.setPrice(id: id, ClothingShopLimits.clampedPrice(price))
        customItemService.setShareable(id: id, true)
        diary.setShopLastPublishedDay(todayKey)
        return .listed
    }

    /// Remove an item from the shop. Always allowed — taking something down is never throttled.
    func unlistCustomItem(id: UUID) {
        customItemService.setShareable(id: id, false)
    }

    func setProximityDisplayName(_ name: String) {
        diary.setProximityDisplayName(name)
    }

    func setShowProximityDebugTools(_ value: Bool) {
        diary.setShowProximityDebugTools(value)
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
        diary.setHomeWidgets(widgets)
    }

    func setQuickLogItems(_ items: [FernletShortcut]) {
        diary.setQuickLogItems(items)
    }

    func allowedHealthCapabilities(from capabilities: Set<HealthCapability>) -> Set<HealthCapability> {
        var allowed = isIntimateLoggingAllowed ? capabilities : capabilities.subtracting([.intimateLogging])
        if lockState != .unlocked {
            allowed.remove(.cycleTracking)
        }
        return allowed
    }

    // NOTE (deviation): `visibleHealthCapabilities` STAYS IN THE FACADE. `HealthCapability` is an
    // app-target type (defined in HealthKitService.swift), not a portable DomainModel type — the
    // classification's "HealthCapability type, not HealthKit" note was incorrect. Its body forwards
    // to `diary.isIntimateLoggingAllowed`, preserving identical behavior.
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
        let parsed = mealResolutionService.enrichingFallbackMicronutrients(MealParser.parse(description, fallbackType: type), description: description)
        diary.appendMeal(parsed, date: date)
        return parsed
    }

    /// Catalog-grounded micronutrient fallback for manually-parsed meals. Delegates to
    /// `MealResolutionService`; kept as a wrapper for the existing call sites + test.
    func fallbackMicronutrients(for description: String) -> Micronutrients {
        mealResolutionService.fallbackMicronutrients(for: description)
    }

    @discardableResult func addResolvedMeal(from description: String, type: MealType? = nil, date: String? = nil) async -> Meal {
        let meals = await addResolvedMeals(from: description, type: type, date: date)
        guard let first = meals.first else {
            return addMeal(from: description, type: type, date: date ?? todayKey)
        }
        return first
    }

    /// Convenience: resolve and immediately commit. Used by non-interactive callers (recipe retry
    /// queue, programmatic logging). The interactive quick-log flow calls `resolveMeals` then either
    /// `commitResolution` or routes low-confidence results through a pre-log review first.
    @discardableResult func addResolvedMeals(from description: String, type: MealType? = nil, date: String? = nil) async -> [Meal] {
        let targetDate = date ?? todayKey
        let resolution = await resolveMeals(from: description, type: type, date: targetDate)
        return commitResolution(resolution, date: targetDate)
    }

    /// Runs the quick-log resolution cascade WITHOUT writing anything to the diary, returning the
    /// resolved meals plus a confidence. Separating resolve from commit lets the UI review a
    /// low-confidence / fabricated result before it counts toward the day's totals.
    func resolveMeals(from description: String, type: MealType? = nil, date: String? = nil) async -> MealResolution {
        await mealResolutionService.resolveMeals(from: description, type: type, date: date)
    }

    /// Commits a resolved meal set to the diary: registers any created recipes, appends each meal,
    /// and queues a background AI retry for fabricated fallback meals.
    @discardableResult func commitResolution(_ resolution: MealResolution, date: String? = nil) -> [Meal] {
        let targetDate = date ?? todayKey
        assert(!targetDate.isEmpty, "meal date required")
        for newRecipe in resolution.createdRecipes { diary.recipes.insert(newRecipe, at: 0) }
        // `diary.recipes.insert` is a raw array mutation with NO save; `appendMeal` below schedules one,
        // so created recipes ride along whenever there are meals. A resolution with created recipes but
        // NO meals would otherwise lose them on the next reload — persist explicitly when recipes were added.
        if !resolution.createdRecipes.isEmpty { scheduleSnapshotSave() }
        resolution.meals.forEach { diary.appendMeal($0, date: targetDate) }
        if resolution.isFallback {
            resolution.meals.forEach { queueMealRetry($0, dayKey: targetDate) }
        }
        return resolution.meals
    }

    @discardableResult func copyMeal(_ meal: Meal) -> Meal {
        diary.copyMeal(meal)
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

    // NOTE (deviation): updateMealCorrection + its two static helpers STAY IN THE FACADE because they
    // use the app-target `MealBuilder`. (Classification had MealBuilder as portable/FoodCatalog; it is
    // not — its carve is future work.) The protein threshold itself is `Macros.goodProteinThreshold`.

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
            diary.mutateDay(date: todayKey) { targetDay in
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
            diary.invalidateDaySummary(for: todayKey)
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
        meal.quality = macros.protein >= Macros.goodProteinThreshold ? .good : .ok
    }

    func attachMealPhoto(mealID: UUID, photoID: UUID) {
        diary.attachMealPhoto(mealID: mealID, photoID: photoID)
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

    // NOTE (deviation): logRecipe STAYS IN THE FACADE — it builds the meal via app-target
    // `MealBuilder`, then writes it through the diary's pure `appendMeal`.
    @discardableResult func logRecipe(_ recipe: RecipeDefinition, mealType: MealType? = nil, date: String? = nil) -> Meal {
        let targetDate = date ?? todayKey
        assert(!targetDate.isEmpty, "recipe meal date required")
        let meal = MealBuilder.mealFromRecipe(
            recipe,
            mealType: mealType ?? MealParser.classifyMealType(recipe.name),
            foodItems: foodCatalog.items(forRecipe: recipe)
        )
        batchSnapshotPersistence {
            diary.mutateDay(date: targetDate) { $0.meals.append(meal) }
            diary.invalidateDaySummary(for: targetDate)
            recentMeals.insert(meal, at: 0)
            recentMeals = Array(recentMeals.prefix(50))
        }
        return meal
    }

    @discardableResult func logSavedRecipe(_ recipe: RecipeDefinition, mealType: MealType? = nil, date: String? = nil) -> Meal {
        diary.logSavedRecipe(recipe, mealType: mealType, date: date)
    }

    @discardableResult func logWebImportedFoodProduct(_ foodItem: FoodItem, mealType: MealType? = nil, date: String? = nil) -> Meal {
        diary.logWebImportedFoodProduct(foodItem, mealType: mealType, date: date)
    }

    func savedRecipeShareText(for recipe: RecipeDefinition) -> String {
        savedRecipeService.shareText(for: recipe)
    }

    func addSavedRecipe(_ recipe: RecipeDefinition) {
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
                let importedRecipe = try await RecipeWebImporter.importRecipe(from: url, catalog: foodCatalog, aiEnabled: settings.aiStatus != .off)
                addSavedRecipe(RecipeDefinition(importedRecipe: importedRecipe))
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

    func updateSavedRecipe(_ recipe: RecipeDefinition) {
        savedRecipeService.update(recipe)
    }

    func deleteSavedRecipe(_ recipe: RecipeDefinition) {
        savedRecipeService.delete(recipe)
    }

    func addWorkout(_ workout: Workout) {
        addWorkout(workout, date: todayKey)
    }

    func addWorkout(_ workout: Workout, date: String) {
        assert(!date.isEmpty, "workout date required")
        diary.appendWorkout(workout, date: date)
        guard workout.healthKitUUID == nil else { return }
        Task { [weak self] in
            await self?.healthSyncCoordinator.saveWorkoutToHealthIfAuthorized(workout, date: date)
        }
    }

    func planWorkout(_ plannedWorkout: PlannedWorkout, date: String) {
        diary.planWorkout(plannedWorkout, date: date)
    }

    func copiedForwardWorkoutSplit(before date: String) -> WorkoutSplit? {
        diary.copiedForwardWorkoutSplit(before: date)
    }

    func previousWeekPlannedWorkout(for date: String) -> PlannedWorkout? {
        diary.previousWeekPlannedWorkout(for: date)
    }

    func deletePlannedWorkout(_ plannedWorkout: PlannedWorkout, date: String) {
        diary.deletePlannedWorkout(plannedWorkout, date: date)
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
        diary.removePlannedWorkout(plannedWorkout, date: date)
    }

    func refreshWorkoutsFromHealth() async {
        await healthSyncCoordinator.refreshWorkoutsFromHealth()
    }

    func backfillWorkoutsFromHealthIfNeeded(defaults: UserDefaults = .standard) async {
        await healthSyncCoordinator.backfillWorkoutsFromHealthIfNeeded(defaults: defaults)
    }

    func stopHealthKitWorkoutObservation() {
        healthSyncCoordinator.stopWorkoutObservation()
    }

    func addJournal(text: String, tag: FeelingTag) {
        let entry = JournalEntry(text: text, tag: tag)
        journalSealingCoordinator.seal(entry, dayKey: todayKey)
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
        diary.setSleep(hours: hours, quality: quality, note: note)
    }

    /// Merges a HealthKit daily context (and any HealthKit-derived sleep) into today.
    /// Delegates to `HealthSyncCoordinator`.
    func updateHealthContext(_ context: HealthDailyContext) {
        healthSyncCoordinator.updateHealthContext(context)
    }

    func addBottle() {
        diary.addBottle()
    }

    func removeBottle() {
        diary.removeBottle()
    }

    func toggleHygiene(_ item: HygieneItem) {
        diary.toggleHygiene(item)
    }

    func togglePersonalCareTask(_ task: PersonalCareTask) {
        diary.togglePersonalCareTask(task)
    }

    func setPersonalCareTask(_ task: PersonalCareTask, completed: Bool) {
        diary.setPersonalCareTask(task, completed: completed)
    }

    func addPersonalCareTask(label: String, group: String) {
        diary.addPersonalCareTask(label: label, group: group)
    }

    func removePersonalCareTask(_ task: PersonalCareTask) {
        diary.removePersonalCareTask(task)
    }

    // MARK: - Past-date access

    func loadDays() -> [String: FernletDay] {
        diary.loadDays()
    }

    func loadDay(for dateKey: String) -> FernletDay {
        diary.loadDay(for: dateKey)
    }

    func loadDayWithDecryptedJournals(for dateKey: String) -> FernletDay {
        journalSealingCoordinator.hydratingDecryptedJournals(into: loadDay(for: dateKey), dateKey: dateKey)
    }

    /// Whether the given day (by `yyyy-MM-dd` key) is flagged sick.
    func isSick(on dateKey: String) -> Bool {
        diary.isSick(on: dateKey)
    }

    /// Sets or clears the sickness flag for a specific day and persists the change.
    func setSick(_ value: Bool, on dateKey: String) {
        diary.setSick(value, on: dateKey)
    }

    /// Whether the "Today's intent" home prompt has been dismissed for the current day.
    var isTodayIntentDismissed: Bool { diary.isTodayIntentDismissed }

    /// Dismisses the "Today's intent" prompt for today and persists the change.
    func dismissTodayIntent() {
        diary.dismissTodayIntent()
    }

    /// Whether the preventive-care micronutrient nudge for a nutrient is active (i.e. not within its
    /// 2-week post-dismissal cooldown).
    func isNutrientBubbleActive(for key: String) -> Bool {
        diary.isNutrientBubbleActive(for: key)
    }

    /// Dismisses the micronutrient nudge for a nutrient, suppressing it for two weeks.
    func dismissNutrientBubble(_ key: String) {
        diary.dismissNutrientBubble(key)
    }

    // MARK: - Sealed CloudKit backup (see SealedBackupCoordinator)

    /// Error surfaced when period-data sealing/restore is attempted while locked.
    /// Aliased here so existing `FernletStore.SealedBackupWiringError` references resolve.
    typealias SealedBackupWiringError = SealedBackupCoordinator.SealedBackupWiringError

    /// Per-payload status of the most recent sealed-backup restore attempt, surfaced (observably) in
    /// Privacy & Data so a deferred/failed restore is VISIBLE and retryable (WS-4) instead of silently
    /// swallowed. Written by `SealedBackupCoordinator` via the `SealedBackupContext` callback.
    private(set) var sealedBackupRestoreStatus: [SealedBackupPayloadType: SealedBackupRestoreOutcome] = [:]

    /// Whether a cross-device escrow-key conflict was detected and awaits the user's explicit choice
    /// (WS-3). Surfaced (observably) in Privacy & Data; never auto-resolved.
    private(set) var sealedBackupEscrowConflict = false

    /// Seals + uploads (or deletes) the encrypted CloudKit backup for a payload; returns whether it
    /// succeeded. Delegates to `SealedBackupCoordinator`.
    @discardableResult
    func setSealedBackupEnabled(_ enabled: Bool, payloadType: SealedBackupPayloadType) async -> Bool {
        await sealedBackupCoordinator.setSealedBackupEnabled(enabled, payloadType: payloadType)
    }

    /// Pulls any sealed iCloud backups into the local stores at launch (and on the user's Retry).
    /// Delegates to `SealedBackupCoordinator`.
    func restoreSealedBackupsIfNeeded() async {
        await sealedBackupCoordinator.restoreSealedBackupsIfNeeded()
    }

    /// WS-3 user-confirmed conflict resolution: adopt the synced (other-device) escrow key and re-upload
    /// enabled backups. Delegates to `SealedBackupCoordinator`.
    @discardableResult
    func resolveSealedBackupEscrowConflict() async -> Bool {
        await sealedBackupCoordinator.adoptSyncedEscrowAndReupload()
    }

    /// Fetches/decrypts/writes a single sealed-backup payload into the local stores; returns whether
    /// records were restored. Delegates to `SealedBackupCoordinator`; kept as a wrapper for the
    /// restore tests.
    @discardableResult
    func restoreSealedBackup(payloadType: SealedBackupPayloadType) async -> Bool {
        await sealedBackupCoordinator.restoreSealedBackup(payloadType: payloadType)
    }

    /// Fetches/decrypts/writes a single sealed-backup payload AND records the rich outcome on the
    /// observable status so the UI can surface a non-silent, retryable result (WS-4). Delegates to
    /// `SealedBackupCoordinator`.
    @discardableResult
    func restoreSealedBackupOutcome(payloadType: SealedBackupPayloadType) async -> SealedBackupRestoreOutcome {
        await sealedBackupCoordinator.restoreSealedBackupOutcome(payloadType: payloadType)
    }

    /// Decodes a decrypted sealed-backup payload into the local stores, returning records written.
    /// Delegates to `SealedBackupCoordinator`; kept as a wrapper for the restore tests.
    @discardableResult
    func applyRestoredPayload(
        _ plaintext: Data,
        payloadType: SealedBackupPayloadType,
        narrativeRepository: MenstrualNarrativeRepository? = nil
    ) throws -> Int {
        try sealedBackupCoordinator.applyRestoredPayload(plaintext, payloadType: payloadType, narrativeRepository: narrativeRepository)
    }

    /// Decodes the decrypted chunks of a sealed-backup payload into the local stores, returning records
    /// written. Delegates to `SealedBackupCoordinator`; kept as a wrapper for the restore tests.
    @discardableResult
    func applyRestoredChunks(
        _ chunks: [Data],
        payloadType: SealedBackupPayloadType,
        narrativeRepository: MenstrualNarrativeRepository? = nil
    ) throws -> Int {
        try sealedBackupCoordinator.applyRestoredChunks(chunks, payloadType: payloadType, narrativeRepository: narrativeRepository)
    }

    func scoreBreakdown(for targetDay: FernletDay) -> ScoreBreakdown {
        diary.scoreBreakdown(for: targetDay)
    }

    func score(for targetDay: FernletDay) -> Double {
        diary.score(for: targetDay)
    }

    func dailyHealthScore(for dateKey: String, day targetDay: FernletDay) -> DailyHealthScore {
        diary.dailyHealthScore(for: dateKey, day: targetDay)
    }

    func addJournal(text: String, tag: FeelingTag, date: String) {
        assert(!date.isEmpty, "journal date required")
        let entry = JournalEntry(text: text, tag: tag)
        journalSealingCoordinator.seal(entry, dayKey: date)
        diary.mutateDay(date: date) { $0.journals.append(entry) }
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

        journalSealingCoordinator.updateSealedNarrative(for: entry, text: trimmed, tag: tag, dayKey: date)

        batchSnapshotPersistence {
            diary.mutateDay(date: date) { targetDay in
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
        journalSealingCoordinator.deleteSealed(id: entry.id)
        batchSnapshotPersistence {
            diary.mutateDay(date: date) { $0.journals.removeAll { $0.id == entry.id } }
            previousJournals.removeAll { $0.id == entry.id }
        }
    }

    func setSleep(hours: Double?, quality: SleepQuality, note: String, date: String) {
        diary.setSleep(hours: hours, quality: quality, note: note, date: date)
    }

    func setBottleCount(_ count: Int, date: String) {
        diary.setBottleCount(count, date: date)
    }

    func setHygiene(_ hygiene: Set<HygieneItem>, date: String) {
        diary.setHygiene(hygiene, date: date)
    }

    func setPersonalCareTaskIDs(_ ids: Set<String>, date: String) {
        diary.setPersonalCareTaskIDs(ids, date: date)
    }

    func replaceGoals(_ newGoals: [FitnessGoal]) {
        diary.replaceGoals(newGoals)
    }

    // MARK: - Workout profile, locations & suggestions

    func setWorkoutProfile(_ profile: WorkoutProfile) {
        diary.setWorkoutProfile(profile)
    }

    func upsertWorkoutLocation(_ location: WorkoutLocation, makeActive: Bool = false) {
        diary.upsertWorkoutLocation(location, makeActive: makeActive)
    }

    func deleteWorkoutLocation(_ id: UUID) {
        diary.deleteWorkoutLocation(id)
    }

    func setActiveWorkoutLocation(_ id: UUID) {
        diary.setActiveWorkoutLocation(id)
    }

    func setWorkoutLocations(_ locations: [WorkoutLocation], activeID: UUID?) {
        diary.setWorkoutLocations(locations, activeID: activeID)
    }

    func setSelectedSplit(_ id: String?) {
        diary.setSelectedSplit(id)
    }

    /// How consistently the user has trained over the last 4 weeks — a recommendation input.
    func workoutConsistency() -> WorkoutConsistency {
        workoutPlanningService.workoutConsistency()
    }

    /// Splits ranked for this user (goal + activity level + consistency + preferred days).
    func recommendedSplits() -> [TrainingSplit] {
        workoutPlanningService.recommendedSplits()
    }

    /// The user's chosen split, or the top recommendation when on auto.
    func activeWorkoutSplit() -> TrainingSplit {
        workoutPlanningService.activeWorkoutSplit()
    }

    /// Builds today's session(s) from the active split, rotating by weekday so the program is
    /// consistent week to week. Equipment + injuries are applied deterministically by the engine,
    /// and reps/sets reflect logged progression.
    func workoutDayPlan(intensity: WorkoutIntensity, context: String) -> WorkoutProgram.DayPlan {
        workoutPlanningService.workoutDayPlan(intensity: intensity, context: context)
    }

    /// Records that catalog exercises were completed, advancing their week-to-week progression.
    func recordCompletedExercises(_ names: [String]) {
        diary.recordCompletedExercises(names)
    }

    /// Applies a natural-language adjustment to a generated day plan using on-device Foundation
    /// Models, constrained to the equipment/injury-filtered catalog. Returns the plan unchanged when
    /// AI is off/unavailable or the request is empty.
    func adjustWorkoutDayPlan(_ plan: WorkoutProgram.DayPlan, request: String) async -> WorkoutProgram.DayPlan {
        await workoutPlanningService.adjustWorkoutDayPlan(plan, request: request)
    }

    func completeOnboarding(profile: UserNutritionProfile, preferences: UserNutritionPreferences, goal: GoalType) {
        diary.completeOnboarding(profile: profile, preferences: preferences, goal: goal)
    }

    @discardableResult func addRecipe(name: String, servings: Int, notes: String = "", ingredients inputIngredients: [ManualRecipeIngredientInput]) -> RecipeDefinition {
        diary.addRecipe(name: name, servings: servings, notes: notes, ingredients: inputIngredients)
    }

    func updateRecipe(_ recipe: RecipeDefinition, name: String, servings: Int, notes: String = "", ingredients inputIngredients: [ManualRecipeIngredientInput]) {
        diary.updateRecipe(recipe, name: name, servings: servings, notes: notes, ingredients: inputIngredients)
    }

    @discardableResult func saveCustomIngredient(_ ingredient: ManualRecipeIngredientInput) -> FoodItem? {
        diary.saveCustomIngredient(ingredient)
    }

    func cachedWebImportedFoodProduct(for query: String) -> FoodItem? {
        diary.cachedWebImportedFoodProduct(for: query)
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
        diary.deleteRecipe(recipe)
    }

    // NOTE (deviation): macroTotals/micronutrientTotals(for:) STAY IN THE FACADE — app-target
    // `MealBuilder`.
    func macroTotals(for recipe: RecipeDefinition) -> MacroTotals {
        MealBuilder.macroTotals(for: recipe, foodItems: foodCatalog.items(forRecipe: recipe))
    }

    func micronutrientTotals(for recipe: RecipeDefinition) -> Micronutrients {
        MealBuilder.micronutrientTotals(for: recipe, foodItems: foodCatalog.items(forRecipe: recipe))
    }

    func recipeShareText(for recipe: RecipeDefinition) -> String {
        RecipeShareCodec.shareText(for: recipe, foodItems: foodCatalog.items(forRecipe: recipe))
    }

    func proximityRecipeSharePayload(for recipe: RecipeDefinition) -> ProximityRecipeSharePayload {
        RecipeShareCodec.proximityPayload(for: recipe, foodItems: foodCatalog.items(forRecipe: recipe))
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
                  URL(string: savedPayload.sourceURLString) != nil else {
                throw RecipeImportError.invalidPayload
            }
            let trimmedName = savedPayload.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { throw RecipeImportError.emptyRecipe }
            let now = Date()
            let recipe = RecipeDefinition(
                name: trimmedName,
                servings: max(savedPayload.servings, 1),
                ingredients: [],
                notes: savedPayload.summary.trimmingCharacters(in: .whitespacesAndNewlines),
                source: MealLogSource.webImport,
                createdAt: now,
                updatedAt: now,
                webImport: RecipeWebImport(
                    sourceURLString: savedPayload.sourceURLString,
                    ingredientLines: savedPayload.ingredients,
                    macros: Macros(
                        protein: max(savedPayload.protein, 0),
                        carbs: max(savedPayload.carbs, 0),
                        fat: max(savedPayload.fat, 0)
                    ),
                    micronutrients: savedPayload.micronutrients
                )
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
        diary.addTexture(body, tags: tags)
    }

    func deleteMemory(_ memory: MemoryNote) {
        diary.deleteMemory(memory)
    }

    func updateMemory(_ memory: MemoryNote, category: String, text: String) {
        diary.updateMemory(memory, category: category, text: text)
    }

    func queueMealRetry(_ meal: Meal, dayKey: String? = nil) {
        aiRetryQueueService.queueMealRetry(meal, dayKey: dayKey)
    }

    func clearRetryItem(_ id: UUID) {
        aiRetryQueueService.clear(id: id)
    }

    func retryOldestMeal() async {
        guard let record = aiRetryQueueService.retryQueue.first else { return }
        // Fallback meals can be queued for any date (back-filled logging), not just today, and
        // the record carries the day it belongs to. Resolve against that day and re-commit on the
        // same date instead of only ever looking in today's meals and silently discarding the rest.
        let dayKey = record.dayKey ?? todayKey
        if dayKey == todayKey {
            guard let meal = day.meals.first(where: { $0.id == record.sourceId }) else {
                aiRetryQueueService.clear(id: record.id)
                return
            }
            let description = meal.name
            deleteMeal(meal)
            await addResolvedMeals(from: description)
        } else {
            guard let meal = loadDay(for: dayKey).meals.first(where: { $0.id == record.sourceId }) else {
                aiRetryQueueService.clear(id: record.id)
                return
            }
            let description = meal.name
            aiRetryQueueService.clearForSourceID(meal.id)
            batchSnapshotPersistence {
                _ = diary.mutateDay(date: dayKey) { $0.meals.removeAll { $0.id == meal.id } }
                diary.invalidateDaySummary(for: dayKey)
            }
            await addResolvedMeals(from: description, date: dayKey)
        }
    }

    func resetAll() {
        batchSnapshotPersistence {
            diary.resetDiary()
            connectionSessionLogs = []
        }
        savedRecipeService.reset()
        customItemService.reset()
        // Clears all earn/spend rows. Note `resetDiary()` is a SOFT reset — it wipes in-memory state but
        // preserves the persisted day history — so the next `reconcileCoinLedger()` legitimately re-mints
        // `earn` rows for any day still on record. That is intentional: coins are a pure function of the
        // logged days that exist, so a soft reset keeps the spend history cleared while earned coins track
        // whatever history survives. (A hard wipe of coins would require also wiping the day records.)
        coinLedgerService.reset()
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
        // Catches the async-load path (whose private init reconciled against a possibly-cold cache) and
        // any day that became active since launch. Idempotent, so a second pass is cheap and safe.
        reconcileCoinLedger()
    }

    func flushPendingSnapshotSave() {
        snapshotSaveCoordinator.flushPending()
        // Custom items persist on a separate debounce (their own per-row store). Flush it in lockstep so
        // a newly-designed item can't be lost when its equip reference (in the snapshot) is force-saved
        // on background but the item row's yield-debounced write hasn't run yet.
        customItemService.flushPendingSave()
        // Saved recipes share the same per-row, yield-debounced write — flush them too so a just-saved
        // recipe survives backgrounding.
        savedRecipeService.flushPendingSave()
        // The coin ledger is likewise a separate per-row store with a yield-debounced write; flush any
        // pending earn/spend rows so a just-credited day or a buy can't be lost on background.
        coinLedgerService.flushPendingSave()
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
        diary.applyDiarySlice(snapshot)
        connectionSessionLogs = snapshot.connectionSessionLogs
        aiRetryQueueService.apply(snapshot.retryQueue)
        proximityTrustVault.apply(peers: snapshot.trustedProximityPeers, audit: snapshot.trainerAuditEvents)
        connectionInspector.attachStore(self)
        journalSealingCoordinator.refreshAfterSnapshotApply()
        rebuildDerivedSignals()
        // A remote CloudKit change may have brought in rows from another device for any of the per-row
        // stores (coin ledger, custom items, saved recipes) — none are part of the snapshot blob. Refresh
        // each in-memory collection so this device tracks the other's additions; because the stores are
        // append/upsert-only, the next local mutation can't then clobber what just synced in.
        coinLedgerService.reloadFromStore()
        customItemService.reloadFromStore()
        savedRecipeService.reloadFromStore()
        // Credit any newly active synced day. Idempotent — re-running never double-grants.
        reconcileCoinLedger()
    }

    private func currentSnapshot() -> SanitizedSnapshot {
        // forStorage always strips sealed journal text AND sensitive health fields
        // (cycle/intimacy/periodPhase) so they never reach the synced blob, and returns a
        // SanitizedSnapshot — the only type saveSnapshot accepts. The sealing state is passed in as
        // pure data (the sealed-id set); the strip lives in the nonisolated FernletPersistence module.
        FernletSnapshot.forStorage(
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
            retryQueue: aiRetryQueueService.retryQueue,
            connectionSessionLogs: connectionSessionLogs,
            trustedProximityPeers: proximityTrustVault.trustedPeers,
            trainerAuditEvents: proximityTrustVault.auditEvents,
            sealedJournalIDs: journalSealingCoordinator.sealedJournalIDs
        )
    }

    /// `dailyScores` with the cycle-phase label removed. `DailyHealthScore.periodPhase` is cycle-derived
    /// metadata keyed by date, so — exactly like `healthContext.cycle` — it must never reach the
    /// CloudKit-synced blob. The label stays only on the in-memory record (device-only audit); it is
    /// scrubbed here before every persist, so a period-data wipe leaves no synced residue.
    /// (Internal rather than private only so a regression test can assert the strip.)
    var storedDailyScores: [DailyHealthScore] {
        FernletSnapshot.storedDailyScores(dailyScores)
    }

    private func batchSnapshotPersistence<T>(_ updates: () throws -> T) rethrows -> T {
        let result = try updates()
        snapshotSaveCoordinator.schedule()
        return result
    }


    func markLaunchScreenDismissed() { diary.markLaunchScreenDismissed() }

    /// The bundled food catalog is now a read-only SQLite store opened lazily by `FoodCatalog`, so
    /// there is no heavyweight seed to await at launch. Kept as no-ops for the existing launch/UI
    /// call sites (the 24 MB JSON parse + 13k-struct hydration they used to drive is gone).
    func loadBundledFoodItemsForLaunch() async { await diary.loadBundledFoodItemsForLaunch() }

    func ensureBundledFoodItemsSeeded() { diary.ensureBundledFoodItemsSeeded() }
}

// MARK: - Sealed Journal Management (Phase S2) — see JournalSealingCoordinator

extension FernletStore: JournalSealingContext {
    func activateNoLockJournals() {
        journalSealingCoordinator.activateNoLockJournals()
        scrubLeakedPastDayJournalsIfNeeded()
    }
    func activateSealedJournals(contentKey: SymmetricKey) {
        journalSealingCoordinator.activateSealedJournals(contentKey: contentKey)
        scrubLeakedPastDayJournalsIfNeeded()
    }
    func deactivateSealedJournals() { journalSealingCoordinator.deactivateSealedJournals() }

    /// WI-1 one-time scrub: seal + blank historical past-day journal plaintext that leaked into the days
    /// blob before the past-day strip (`DiaryStore.mutatePastDay`) existed. The snapshot sanitizer and
    /// `migrateExistingJournalsToSealedStore` only cover today + `previousJournals`, so days that aged out
    /// of that window keep their plaintext forever. Runs the full-repository scan at most once per device
    /// (gated by a run-once preference); called right after journal activation, when a content/device key
    /// is live. Re-persists only the days the coordinator actually changed.
    ///
    /// WI1-1 robustness: the run-once version flag is advanced **only** on a clean pass (every leaked day
    /// sealed). If a day's seal fails, its plaintext is preserved (no data loss, matching `seal()`), the
    /// flag is left unset so a later launch retries exactly that day — and a bounded attempts counter caps
    /// the retries so a *permanently* failing entry can't make the scan run on every launch forever. Once
    /// the cap is hit the flag is set anyway (give up); going-forward edits to such a day are still covered
    /// by the per-write strip (`mutatePastDay`).
    func scrubLeakedPastDayJournalsIfNeeded() {
        let defaults = pastDayJournalScrubDefaults
        guard defaults.integer(forKey: Self.pastDayJournalScrubFlagKey) < Self.pastDayJournalScrubVersion
        else { return }
        let outcome = journalSealingCoordinator.scrubbedLeakedPastDayJournals(in: repository.loadAllDays())
        for (dayKey, day) in outcome.changedDays {
            _ = repository.updateDay(
                SanitizedDay.sanitizing(day, sealedJournalIDs: journalSealingCoordinator.sealedJournalIDs),
                for: dayKey, todayKey: todayKey
            )
        }

        // No journal key was active, so the scan could not actually run. Do NOT advance the run-once flag —
        // a no-op pass must not be mistaken for a genuine clean pass and permanently disable the scrub (#3).
        guard outcome.keyActive else { return }

        guard outcome.unsealedFailureCount > 0 else {
            // Clean pass: every leaked past-day journal is sealed. Mark complete; the bulk scan never re-runs.
            defaults.set(Self.pastDayJournalScrubVersion, forKey: Self.pastDayJournalScrubFlagKey)
            defaults.removeObject(forKey: Self.pastDayJournalScrubAttemptsKey)
            return
        }

        // At least one day's seal failed. Don't advance the run-once flag — a later LAUNCH re-runs the scan
        // and retries exactly those still-plaintext days (already-sealed days are skipped, their blob text
        // is now empty). The retry budget counts LAUNCHES, not activations: this method also fires on every
        // lock/unlock transition, so a per-session guard prevents a few activations in one session from
        // exhausting the budget and giving up prematurely (#2).
        guard !pastDayScrubBudgetConsumedThisSession else { return }
        pastDayScrubBudgetConsumedThisSession = true

        let attempts = defaults.integer(forKey: Self.pastDayJournalScrubAttemptsKey) + 1
        if attempts >= Self.pastDayJournalScrubMaxAttempts {
            defaults.set(Self.pastDayJournalScrubVersion, forKey: Self.pastDayJournalScrubFlagKey)
            defaults.removeObject(forKey: Self.pastDayJournalScrubAttemptsKey)
            // Security-relevant: plaintext is being deliberately left unsealed (after the bounded retry
            // cap), so record it on the audit trail the rest of the privacy subsystem is grep-able
            // through — not just stdout.
            FernletAuditLog.log("journal.pastDayScrub.gaveUp", context: [
                "attempts": String(attempts),
                "unsealed": String(outcome.unsealedFailureCount)
            ])
        } else {
            defaults.set(attempts, forKey: Self.pastDayJournalScrubAttemptsKey)
        }
    }

    /// Re-arms the one-time past-day scrub after a per-entry seal/re-seal failure (`JournalSealingContext`):
    /// clears the run-once flag and the persisted retry budget so the next activation/launch re-scans ALL
    /// days — including aged-out ones outside the in-memory `previousJournals` window that the per-activation
    /// migrate never visits — and re-seals + strips the leaked plaintext instead of leaving it in the synced
    /// blob forever (F1). The per-session in-memory guard is left as-is: the budget the re-armed scan
    /// consumes is still counted per launch.
    func requestPastDayJournalRescrub() {
        let defaults = pastDayJournalScrubDefaults
        defaults.removeObject(forKey: Self.pastDayJournalScrubFlagKey)
        // Clearing the persisted attempts counter grants a FRESH bounded-retry budget on each newly-detected
        // leak — deliberately prioritizing closing a plaintext leak over bounding rescans. Consequence: on a
        // chronically-failing narrative store (every seal throws), each live seal failure re-arms and resets
        // the budget, so the WI1-1 give-up cap may not be reached. Note the session guard
        // (`pastDayScrubBudgetConsumedThisSession`) only caps the give-up COUNTER at one increment per session;
        // the scan itself (loadAllDays + per-day seal/strip + updateDay) still re-runs on every activation
        // while the run-once flag is unset — cheap in practice (loadAllDays is served from the warm cache and
        // already-sealed days carry empty text). Accepted trade: a persistent plaintext leak should keep being
        // retried rather than be permanently abandoned (#2).
        defaults.removeObject(forKey: Self.pastDayJournalScrubAttemptsKey)
    }

    /// Test seam: clears the in-memory per-session scrub-budget guard so a test can simulate a FRESH app
    /// launch (the per-launch retry budget only advances once per session). Production never calls this.
    func resetPastDayScrubSessionBudgetForTesting() {
        pastDayScrubBudgetConsumedThisSession = false
    }
}

extension FernletStore {
    /// Mutates the day for the given date key (forwards to DiaryStore, which owns the day +
    /// repository round-trip). Kept as a facade member so existing call sites resolve.
    @discardableResult
    func mutateDay(date: String, _ change: (inout FernletDay) -> Void) -> Bool {
        diary.mutateDay(date: date, change)
    }
}

extension FernletStore: WorkoutSyncContext {
    func workoutExists(id: UUID) -> Bool {
        diary.workoutExists(id: id)
    }

    func workoutExists(healthKitUUID: UUID) -> Bool {
        diary.workoutExists(healthKitUUID: healthKitUUID)
    }

    func setWorkoutHealthKitUUID(workoutID: UUID, hkUUID: UUID, date: String) {
        diary.setWorkoutHealthKitUUID(workoutID: workoutID, hkUUID: hkUUID, date: date)
    }

    /// NOTE J: routes to the PURE diary append, NOT facade `addWorkout`, so a workout imported FROM
    /// HealthKit (already carrying a `healthKitUUID`) is recorded without re-triggering the HK save
    /// loop. The former `addWorkout` path only avoided the loop via its `healthKitUUID != nil` guard;
    /// calling the pure append directly preserves that semantics without depending on the guard.
    func upsertWorkout(_ workout: Workout, date: String) {
        diary.appendWorkout(workout, date: date)
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
            SavedRecipeService(repository: SavedRecipeRepository())
        }
        let customItemService = StartupTiming.timed("CustomItemService.init") {
            CustomItemService(repository: CustomItemRepository())
        }
        let coinLedgerService = StartupTiming.timed("CoinLedgerService.init") {
            CoinLedgerService(repository: CoinLedgerRepository())
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
        await customItemService.loadAsync()
        await coinLedgerService.loadAsync()

        return FernletStore(
            snapshot: snapshot,
            todayKey: key,
            repository: activeRepository,
            savedRecipeService: savedRecipeService,
            customItemService: customItemService,
            coinLedgerService: coinLedgerService,
            healthKitService: nil
        )
    }
}

extension FernletStore: ProximityTrustPolicy {}

extension FernletStore: WorkoutPlanningContext {}

extension FernletStore: MealResolutionContext {}

extension FernletStore: SealedBackupContext {
    /// Narrow read of the (private) journal content key for sealed period-data backup. This is the
    /// ONE SealedBackupContext member the facade does NOT forward to DiaryStore — the key lives in
    /// the facade-owned `journalSealingCoordinator` and never enters DiaryStore.
    var sealedBackupContentKey: SymmetricKey? { journalSealingCoordinator.contentKey }
    func replaceTierTwoMemories(_ records: [TierTwoMemoryRecord]) {
        diary.replaceTierTwoMemories(records)
    }
    func loadAllDaysFromRepository() -> [String: FernletDay] {
        diary.loadAllDaysFromRepository()
    }
    func recordSealedBackupRestoreOutcome(_ outcome: SealedBackupRestoreOutcome, payloadType: SealedBackupPayloadType) {
        sealedBackupRestoreStatus[payloadType] = outcome
    }
    func recordSealedBackupEscrowConflict(_ inConflict: Bool) {
        sealedBackupEscrowConflict = inConflict
    }
}

extension FernletStore: HealthSyncContext {
    func scheduleSnapshotSave() { snapshotSaveCoordinator.schedule() }
}

// MARK: - Models
