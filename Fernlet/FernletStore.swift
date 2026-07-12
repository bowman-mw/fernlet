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
    /// One-shot request to show the "Turn on Nearby Friends?" prompt (set when the user keeps
    /// their FIRST friend and presence was never offered before). Observable, memory-only —
    /// the persistent never-re-prompt marker is `settings.hasPromptedForPresence`.
    var presenceEnablePromptRequested = false

    var todayKey: String { diary.todayKey }
    private var repository: FernletRepository { diary.repository }
    @ObservationIgnored let savedRecipeService: SavedRecipeService
    @ObservationIgnored let customItemService: CustomItemService
    @ObservationIgnored let coinLedgerService: CoinLedgerService
    @ObservationIgnored let milestoneLedgerService: MilestoneLedgerService
    @ObservationIgnored let proximityTrustVault: ProximityTrustVault
    @ObservationIgnored let aiRetryQueueService: AIRetryQueueService
    @ObservationIgnored private(set) lazy var meshNetworkManager: MeshNetworkManager = {
        let manager = MeshNetworkManager(store: self)
        // Clothing shop (Phase 3a): catalogs ride the friend mesh; the opt-out is payload-layer, wired
        // here as app-side closures so `ProximityHost` stays settings-free. While the setting is off the
        // provider returns nil (nothing sent), inbound catalogs drop, and the `shop` capability is not
        // advertised; `setAllowNearbyClothingShares(false)` also clears held state immediately.
        manager.clothingShop.isSharingEnabledProvider = { [weak self] in
            self?.settings.allowNearbyClothingShares ?? false
        }
        manager.clothingShop.localCatalogProvider = { [weak self] in
            guard let self, self.settings.allowNearbyClothingShares else { return nil }
            return self.buildShopCatalog()
        }
        // Phase 3b: one-hop moderation relay — supply our own reports to sign + send; ingest peers' verified rows.
        manager.ownModerationReportsProvider = { [weak self] in self?.moderationLedger.rows ?? [] }
        manager.onModerationRowsReceived = { [weak self] rows in self?.ingestModerationRows(rows) }
        // Phase 4: fuzzy state exchange — advertise/send only when opted in; cache friends' received state.
        manager.friendStateEnabledProvider = { [weak self] in self?.settings.allowNearbyFriendState ?? false }
        manager.friendStatePayloadProvider = { [weak self] in
            guard let self, self.settings.allowNearbyFriendState else { return nil }
            return FriendStatePayload(state: self.companionState.fuzzy, appearance: self.settings.companionAppearance)
        }
        manager.onFriendStateReceived = { [weak self] fingerprint, payload in
            self?.receiveFriendState(fingerprint: fingerprint, payload: payload)
        }
        // Phase 5: an in-person friend session feeds the closeness signal.
        manager.onFriendSessionCommitted = { [weak self] fingerprint in
            self?.closenessLedger.recordSession(fingerprint: fingerprint)
        }
        return manager
    }()
    @ObservationIgnored private(set) lazy var recipeShareManager: ProximityRecipeShareManager = ProximityRecipeShareManager(store: self)
    /// Device-local hearts state (received hearts + per-friend-per-day rate limit). Deliberately
    /// outside the snapshot: heart activity never enters any synced store.
    @ObservationIgnored private(set) lazy var heartLedger = ProximityHeartLedger()
    /// Device-local moderation reports (never synced). Feeds item-hiding + the escalation/ban.
    @ObservationIgnored private(set) lazy var moderationLedger = ModerationLedger()
    /// Tamper-resistant store bans (Keychain-backed; survives app delete+reinstall and clock changes).
    @ObservationIgnored private(set) lazy var moderationBanStore = ModerationBanStore()
    /// Device-local cache of friends' shared fuzzy state + appearance (Phase 4). Never synced.
    @ObservationIgnored private(set) lazy var friendStateCache = FriendStateCache()
    /// Device-local closeness signal (in-person interaction counts) + close-slot assignment (Phase 5).
    /// Never synced — closeness is a private, per-device view.
    @ObservationIgnored private(set) lazy var closenessLedger = ClosenessLedger()
    /// The standing presence radio (mesh redesign Phase 4a/4b): broadcasts rotating pairwise-DH
    /// tags so KEPT friends recognize each other nearby, and — Phase 4b — carries in-person hearts
    /// over on-demand short-lived pairwise connections (the standalone heart radio is deleted).
    /// Lifecycle is owned by ContentView (opt-in `allowNearbyPresence` + scene + tab + lock),
    /// mirroring the other proximity listeners; the opt-out setter stops it immediately. Hearts are
    /// gated by the separate `allowNearbyHearts` setting (send + receive), consulted via the host.
    @ObservationIgnored private(set) lazy var presenceManager: PresenceManager =
        PresenceManager(store: self, ledger: heartLedger)
    @ObservationIgnored let derivedSignalsService = DerivedSignalsService()
    @ObservationIgnored private let healthKitService: (any HealthKitServicing)?
    @ObservationIgnored private lazy var healthSyncCoordinator = HealthSyncCoordinator(host: self, healthKitService: healthKitService)
    @ObservationIgnored private lazy var workoutPlanningService = WorkoutPlanningService(host: self)
    @ObservationIgnored private lazy var mealResolutionService = MealResolutionService(host: self)
    @ObservationIgnored private lazy var sealedBackupCoordinator = SealedBackupCoordinator(host: self)
    @ObservationIgnored private lazy var snapshotSaveCoordinator = SnapshotSaveCoordinator(
        repository: diary.repository,
        buildSnapshot: { [unowned self] in self.currentSnapshot() },
        onAfterSave: { [weak self] in self?.handleAfterSnapshotSave() }
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
    /// Widget bridge (nil until `activateWidgetBridge()` wires it from ContentView at store-ready,
    /// so unit tests stay hermetic — no app-group writes/WidgetCenter pokes unless a test injects
    /// its own mirror). Publishes the benign snapshot after every persisted save.
    @ObservationIgnored var widgetSnapshotMirror: WidgetSnapshotMirror?
    /// Inbound queue of widget App-Intent actions (injectable directory for tests).
    @ObservationIgnored var pendingWidgetActionQueue = PendingWidgetActionQueue()
    @ObservationIgnored private var isProcessingPendingWidgetActions = false
    /// Read-only abstract egress from the private cycle data into scoring. Nil until the app wires a
    /// `PeriodContextBridge`; when nil (or the opt-in is off) scoring is byte-identical to period-unaware.
    @ObservationIgnored private(set) var periodScoringContext: (any PeriodScoringContextProviding)?
    /// Read-only stress ("body signals") context for the gentle scoring nudge. Nil until the app wires a
    /// `StressService`; when nil (or the opt-in is off) scoring is byte-identical to stress-unaware.
    @ObservationIgnored private(set) var stressScoringContext: (any StressScoringContextProviding)?

    /// Device-local Worry Box seams (the `WorryBoxService` is a `ContentView` @State, not owned here).
    /// The lifetime "worries let go" count is read through `worriesLetGoProvider` — it stays device-local
    /// (never the synced milestone ledger) so worry metadata honors the box's "never sync" promise —
    /// and `worryBoxResetHook` lets `resetAll` purge the sealed worry rows + count.
    @ObservationIgnored var worriesLetGoProvider: (() -> Int)?
    @ObservationIgnored var worryBoxResetHook: (() -> Void)?

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

    init(date: Date = .now, repository: FernletRepository? = nil, savedRecipeRepository: SavedRecipeRepository? = nil, customItemRepository: (any CustomItemRepositoring)? = nil, coinLedgerRepository: (any CoinLedgerRepositoring)? = nil, milestoneLedgerRepository: (any MilestoneLedgerRepositoring)? = nil, healthKitService: (any HealthKitServicing)? = nil, journalNarrativeRepository: (any JournalNarrativeStoring)? = nil, foodCatalog: FoodCatalog = .bundled()) {
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
        let milestoneLedgerService = StartupTiming.timed("MilestoneLedgerService.init") {
            MilestoneLedgerService(repository: milestoneLedgerRepository ?? MilestoneLedgerRepository())
        }
        milestoneLedgerService.loadSync()
        self.milestoneLedgerService = milestoneLedgerService
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
            stressModifier: { [weak self] key in self?.stressModifier(for: key) ?? 0 },
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
        milestoneLedgerService: MilestoneLedgerService,
        healthKitService: (any HealthKitServicing)? = nil,
        foodCatalog: FoodCatalog = .bundled()
    ) {
        self.savedRecipeService = savedRecipeService
        self.customItemService = customItemService
        self.coinLedgerService = coinLedgerService
        self.milestoneLedgerService = milestoneLedgerService
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
            stressModifier: { [weak self] key in self?.stressModifier(for: key) ?? 0 },
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
            periodAdjustment: periodAdjustment(for: todayKey),
            stressModifier: stressModifier(for: todayKey)
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

    func setStressAwarenessEnabled(_ enabled: Bool) {
        diary.setStressAwarenessEnabled(enabled)
        // Opting out scrubs the device-local sidecar (HealthKit-derived baselines) promptly
        // rather than waiting for the next debounced refresh.
        if !enabled {
            stressScoringContext?.scrubStressLocalState()
        }
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

    /// Wires the stress ("body signals") context. Called once from `ContentView` after the
    /// `StressService` exists. Held only as the abstract protocol — the store never sees
    /// baselines or raw HealthKit series, just the current gentle assessment.
    func attachStressScoringContext(_ context: any StressScoringContextProviding) {
        stressScoringContext = context
    }

    /// The pre-gated stress scoring modifier for a day, or 0 when the opt-in is off or no
    /// stress context is attached. TODAY-ONLY by design: the assessment describes the current
    /// baseline deviation, so recomputed past days always get the identity 0 (a same-day
    /// stored `DailyHealthScore` may bake today's modifier in — accepted, mirroring the
    /// documented live-vs-stored nutrient-gap divergence). Supplied to DiaryStore as the
    /// injected `stressModifier` closure, twin of `periodAdjustment(for:)`.
    func stressModifier(for dayKey: String) -> Double {
        guard settings.stressAwarenessEnabled, dayKey == todayKey, let stressScoringContext else { return 0 }
        return StressEngine.scoringModifier(for: stressScoringContext.currentStressAssessment?.state)
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
    func isSelfDesigned(_ item: CustomizationItem) -> Bool { settings.ownedDesignerIDs.contains(item.designer.id) }

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
    ///
    /// `ref` is REQUIRED (no default): the idempotency guarantee is entirely on the caller-supplied ref, so
    /// a fresh-UUID default would silently make every call non-idempotent and let a retried buy debit twice.
    @discardableResult
    func spendCoins(_ amount: Int, ref: String) -> Bool {
        coinLedgerService.spend(amount: amount, ref: ref)
    }

    /// Credits any active day not yet in the ledger. Idempotent; called at store launch and on app
    /// foreground so days logged on this or another device accrue exactly once.
    ///
    /// Also folds in the (equally idempotent) milestone reconcile over the same day history, so
    /// every existing trigger point — launch, foreground, remote sync, pre-buy — doubles as a
    /// milestone catch-up and awards feel immediate without new plumbing.
    func reconcileCoinLedger() {
        let days = loadDays()
        coinLedgerService.reconcile(activeDayKeys: Set(days.compactMap { $0.value.hasLoggedContent ? $0.key : nil }))
        reconcileMilestones(days: days)
    }

    // MARK: - Milestones (lifetime care counts — cumulative only, never streaks)
    // Counted events live in `milestoneLedgerService` (its own append-only per-row store, mirroring
    // the coin ledger; see `MilestoneEconomy`). Journal/meal/workout/water events are DERIVED from
    // the day history by `reconcileMilestones` (backfill + steady state — an event that predates
    // pruned/reset history is simply never counted: undercount accepted). Breathing + worry events
    // are not in the diary and arrive only through `recordMilestoneEvent` live hooks.

    /// Lifetime care counts per kind (distinct milestone-event rows — monotonic, union-merged).
    /// NOTE: `.worry` is intentionally NOT sourced here — worry counts are device-local (see
    /// `lifetimeWorriesLetGo`) to honor the Worry Box's "never sync" promise.
    var milestoneCounts: [MilestoneEventKind: Int] { milestoneLedgerService.lifetimeCounts }

    /// Lifetime "worries let go", read from the device-local `WorryBoxService` (never synced).
    var lifetimeWorriesLetGo: Int { worriesLetGoProvider?() ?? 0 }

    /// Records one live milestone event that is NOT derivable from the day history (breathing
    /// session completed, worry released). `ref` is the counted thing's stable identity — the row
    /// id is deterministic from it, so a retried call can't double-count.
    func recordMilestoneEvent(_ kind: MilestoneEventKind, ref: String) {
        milestoneLedgerService.record([
            .event(kind: kind, ref: ref, dayKey: todayKey, at: Date())
        ])
        awardMilestoneCoins()
    }

    /// Mints any milestone-event rows the surviving day history implies but the ledger lacks, then
    /// awards any newly crossed milestone thresholds. Idempotent — deterministic row ids make
    /// re-running with overlapping inputs a no-op.
    func reconcileMilestones(days: [String: FernletDay]? = nil) {
        let allDays = days ?? loadDays()
        let derived = MilestoneEconomy.derivedEvents(
            from: allDays,
            hydrationTarget: settings.hydrationTarget,
            // Meals still pending AI resolution are placeholders that will be replaced by a
            // fresh-UUID resolved meal — exclude them so one logged meal isn't counted twice.
            excludingMealIDs: Set(aiRetryQueueService.retryQueue.map(\.sourceId)),
            at: Date()
        )
        milestoneLedgerService.record(derived)
        awardMilestoneCoins()
    }

    /// Appends the coin awards for any milestone threshold reached but not yet awarded.
    /// Exactly-once across devices (deterministic ids `milestone:<kind>:<threshold>`), and never
    /// resurrects awards a full reset voided (`MilestoneEconomy.missingAwards` applies the coin
    /// ledger's reset boundary).
    private func awardMilestoneCoins() {
        let awards = MilestoneEconomy.missingAwards(
            events: milestoneLedgerService.entries,
            coinEntries: coinLedgerService.entries,
            at: Date()
        )
        guard !awards.isEmpty else { return }
        coinLedgerService.grantEarns(awards)
    }

    // MARK: - Clothing shop (in-person friend shop)
    // The catalog exchange rides the friend mesh (`meshNetworkManager.clothingShop`, Phase 3a):
    // catalogs are sent pairwise-sealed to committed peers during the session, and the shop opens as a
    // 1-hour post-session window on the Friends tab. Buying is local: spend coins + copy the
    // already-received item into the closet, preserving its provenance.

    /// This device's broadcast shop catalog, built from the user's own shareable designs (capped,
    /// deterministically ordered). Supplied to the mesh's `clothingShop` provider (nil when the sharing
    /// opt-out is off) and sent to each committed peer that advertises the `shop` capability.
    func buildShopCatalog() -> ClothingCatalogPayload {
        // A banned store broadcasts nothing, even if local items are still flagged shareable.
        let shareable = moderationBanStore.isSelfBanned ? [] : customItems
        return ClothingShareCodec.catalog(
            forShareable: shareable,
            designerID: localDesignerID,
            displayName: shopDisplayName,
            // Filter by the whole owned designer-id set (matches `isSelfDesigned` / the listing predicate),
            // so an item designed under a superseded-but-owned id — one that shows "In your shop" and
            // consumes the cap — is actually broadcast rather than silently excluded from every peer.
            ownedDesignerIDs: settings.ownedDesignerIDs
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
            return .alreadyOwned                                  // still in the closet — nothing to add
        }
        let price = item.price

        // Was this item ALREADY PAID on a prior buy? The spend is idempotent per ref (`spend:<item id>`),
        // so a user who paid once, deleted the item, and re-buys must get it back for FREE — even if their
        // current balance is now below the price ("buy once, own forever, never charged twice"). The
        // balance guard must therefore run only for a genuinely NEW purchase; applying it before the
        // idempotency check would permanently lock a paid-for item behind a balance the user already spent.
        let alreadyPaid = coinLedgerService.entries.contains {
            $0.id == CoinLedgerEntry.spendID(ref: item.id.uuidString)
        }
        if !alreadyPaid {
            guard coinBalance >= price else { return .insufficientCoins }
        }

        // Idempotent spend keyed by the item id: a retried/duplicate buy can't debit twice. When already
        // paid, `spendCoins` is a no-op (returns false) and we re-grant for free. Either way the item lands
        // in the closet, so the outcome is `.bought` — `.alreadyOwned` is reserved for the early return
        // above (item still present), never for a fresh re-grant.
        spendCoins(price, ref: item.id.uuidString)
        var bought = item
        bought.isShareable = false
        // Provenance is the SELLER's declared designer id — NOT the raw per-item `designer` field, which a
        // hostile peer could set to one of the buyer's own ids to forge "self-designed" and re-list someone
        // else's work. If the declared id collides with ANY of this user's designer ids, treat it as unknown
        // provenance so a bought copy can never masquerade as self-made or be re-listed for sale.
        bought.designer = ItemDesigner(id: settings.ownedDesignerIDs.contains(designerID) ? UUID() : designerID)
        saveCustomItem(bought)
        return .bought
    }

    // MARK: - Shop listing management (Wardrobe)

    enum ShopListingResult: Equatable {
        case listed
        case nameFlagged
        case capReached
        /// The item isn't listable — not found, or not one of your own designs. Distinct from `capReached`
        /// so the UI never shows a misleading "shop is full" message for the wrong reason.
        case notAllowed
        /// This device's store is banned (repeatedly-reported content) — nothing can be listed.
        case storeBanned
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
        if moderationBanStore.isSelfBanned { return .storeBanned }
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

    /// Toggle the clothing-shop sharing opt-out. Payload-layer since Phase 3a (the shop rides the
    /// friend mesh — there is no clothing radio to stop): the providers wired in `meshNetworkManager`'s
    /// initializer gate outbound catalogs, inbound catalogs, and the `shop` capability on this setting,
    /// and turning it OFF additionally drops every held peer catalog and closes any open shop window
    /// immediately — WITHOUT touching the friend-mesh radio (photos keep working).
    func setAllowNearbyClothingShares(_ value: Bool) {
        settings.allowNearbyClothingShares = value
        if !value {
            meshNetworkManager.clothingShop.clearAll()
        }
        snapshotSaveCoordinator.schedule()
    }

    /// Toggle in-person hearts (mesh redesign Phase 4b). Hearts now ride the presence radio, so
    /// this setter no longer stops a dedicated radio — it only flips the setting. Enforcement is
    /// at the payload layer: `PresenceManager` blocks an outbound heart and drops an inbound one
    /// when this is off (the presence radio itself keeps running under `allowNearbyPresence`).
    func setAllowNearbyHearts(_ value: Bool) {
        settings.allowNearbyHearts = value
        snapshotSaveCoordinator.schedule()
    }

    /// Toggle the nearby-friends presence layer (mirrors `setAllowNearbyRecipeShares`). Turning
    /// it OFF stops the presence radio immediately; turning it ON is picked up by ContentView's
    /// listener chain (scene/tab/lock gated), which also observes this setting directly.
    func setAllowNearbyPresence(_ value: Bool) {
        settings.allowNearbyPresence = value
        if !value {
            presenceManager.stop()
        }
        snapshotSaveCoordinator.schedule()
    }

    /// Toggle sharing a fuzzy wellbeing vibe + avatar with kept friends in person (Phase 4). Turning it
    /// off drops the cached states received from others too — nothing kept about a signal we no longer share.
    func setAllowNearbyFriendState(_ value: Bool) {
        settings.allowNearbyFriendState = value
        if !value { friendStateCache.clearAll() }
        snapshotSaveCoordinator.schedule()
    }

    /// Caches a friend's shared fuzzy state (dropped when we've opted out), sanitizing the appearance.
    func receiveFriendState(fingerprint: String, payload: FriendStatePayload) {
        guard settings.allowNearbyFriendState, let fuzzy = payload.fuzzyState else { return }
        friendStateCache.record(fingerprint: fingerprint, fuzzyState: fuzzy, appearance: payload.sanitizedAppearance)
    }

    /// A friend's cached fuzzy state + appearance if still fresh (≤30 days), for the friend list.
    func cachedFriendState(fingerprint: String) -> CachedFriendState? {
        friendStateCache.state(for: fingerprint)
    }

    // MARK: - Closeness + close friends (Phase 5)

    /// Re-assigns the 4 close slots at most once per day (hysteresis lives in the slot assignment).
    func recomputeCloseFriendsIfNeeded() {
        guard closenessLedger.needsDailyEvaluation else { return }
        let active = proximityTrustVault.trustedPeers.filter { $0.blockedAt == nil && $0.revokedAt == nil }
        closenessLedger.evaluateSlots(
            eligibleFingerprints: active.map(\.fingerprint),
            firstAcceptedAt: Dictionary(active.map { ($0.fingerprint, $0.firstAcceptedAt) }, uniquingKeysWith: { a, _ in a }))
    }

    /// Whether a friend currently holds one of the 4 close-friend slots.
    func isCloseFriend(fingerprint: String) -> Bool { closenessLedger.isClose(fingerprint: fingerprint) }

    // MARK: - Received hearts (presentation-only surfacing)

    /// Golden warmth for the Home health bar from hearts received in the last 24h — a display
    /// overlay only, decaying linearly. Hearts NEVER feed `score`/`FernletScoring` (spec §10:
    /// friend activity must not enter persisted health scoring).
    var heartGlow: Double { heartLedger.activeGlow() }

    /// The received heart whose warm Home bubble should show (undismissed, still within 24h).
    var pendingHeartBubble: ReceivedHeartRecord? { heartLedger.pendingBubbleHeart }

    func dismissHeartBubble(id: UUID) {
        heartLedger.dismissBubble(id: id)
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

    /// Phase 2 friend minting (Docs/Proximity-Mesh-Redesign-2026-07-10.md): writes vault records
    /// for the session-roster entries the user chose to keep at session end. One-sided and
    /// local-only — no wire message is sent and the peer never learns whether they were kept.
    /// Display names are peer-supplied wire input; sanitize before they are persisted
    /// (control/zero-width/bidi scalars out, length-capped), per the heart-manager precedent.
    /// The vault's `onChange` (wired to `snapshotSaveCoordinator.schedule()`) persists the mint.
    func keepProximityFriends(from candidates: [MeshSessionRosterEntry], keptFingerprints: Set<String>) {
        // First-kept-friend presence prompt (Phase 4a): captured BEFORE minting — the prompt
        // fires only on the 0 → 1 transition of unrevoked-unblocked friends.
        let hadEligibleFriendBefore = proximityTrustVault.trustedPeers.contains {
            $0.revokedAt == nil && $0.blockedAt == nil
        }
        var mintedAny = false
        for entry in candidates where keptFingerprints.contains(entry.fingerprint) {
            guard !entry.signingPublicKey.isEmpty, !entry.keyAgreementPublicKey.isEmpty else { continue }
            // Re-check the vault at finalize time: eligibility was computed at presentation, and
            // trust() revives (clears blockedAt/revokedAt) — a peer blocked mid-prompt must stay
            // blocked. Blocked ONLY: block() sets both timestamps, so this covers blocked-mid-prompt,
            // while a revoked-only ("Removed") record passing through trust() and being revived IS
            // the desired in-person re-friend path (Phase-2 friend lifecycle semantics).
            guard !proximityTrustVault.isBlockedProximitySigningKey(entry.signingPublicKey) else { continue }
            // ≤12 friends (spec §10): re-friending / reviving an existing record is always allowed, but a
            // brand-new friend is declined once you're at the cap — existing friends are never auto-dropped.
            let existing = proximityTrustVault.peer(signingPublicKey: entry.signingPublicKey)
            let isExistingActive = existing.map { $0.revokedAt == nil && $0.blockedAt == nil } ?? false
            if !isExistingActive,
               proximityTrustVault.trustedPeers.filter({ $0.blockedAt == nil && $0.revokedAt == nil }).count >= CloseSlotAssignment.maxFriends {
                continue
            }
            var name = ItemNameModeration.sanitizedName(entry.displayName)
            if name.isEmpty { name = "A friend" }
            let peer = ProximityCoordinator.PeerIdentity(
                id: UUID(),
                displayName: name,
                signingPublicKey: entry.signingPublicKey,
                keyAgreementPublicKey: entry.keyAgreementPublicKey,
                fingerprint: entry.fingerprint,
                rangingMode: .none,
                firstSeenAt: Date()
            )
            trustProximityPeer(peer, mode: .friend)
            mintedAny = true
        }
        guard mintedAny else { return }
        // The presence roster derives from the vault — pick up the new friend immediately
        // (no-op while the presence radio isn't running).
        presenceManager.refreshRoster()
        // ONE-TIME enable prompt at the first kept friend (owner decision: presence defaults
        // off, prompted once). `hasPromptedForPresence` flips the moment the prompt is
        // requested, so it can never fire twice — even if the alert is dismissed by a
        // navigation swap before the user answers.
        if !hadEligibleFriendBefore,
           !settings.hasPromptedForPresence,
           !settings.allowNearbyPresence {
            settings.hasPromptedForPresence = true
            presenceEnablePromptRequested = true
            snapshotSaveCoordinator.schedule()
        }
    }

    func revokeTrustedProximityPeer(signingPublicKey: Data) {
        proximityTrustVault.revoke(signingPublicKey: signingPublicKey)
        presenceManager.refreshRoster()
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
        // Pairwise-DH tags mean a blocked friend's tag disappears from our broadcast (and their
        // ads stop matching) at the next roster rebuild — do that rebuild NOW.
        presenceManager.refreshRoster()
        snapshotSaveCoordinator.schedule()
    }

    func unblockProximityPeer(signingPublicKey: Data) {
        proximityTrustVault.unblock(signingPublicKey: signingPublicKey)
        presenceManager.refreshRoster()
        snapshotSaveCoordinator.schedule()
    }

    func isTrustedProximityPeer(signingPublicKey: Data) -> Bool {
        proximityTrustVault.isTrustedProximityPeer(signingPublicKey: signingPublicKey)
    }

    // MARK: - Content moderation (report + block + on-device log)

    /// Reports a peer (from the friend list or in-session roster) for objectionable content: blocks the
    /// peer and records the report locally.
    func reportProximityPeer(signingPublicKey: Data, reason: ReportReason) {
        proximityTrustVault.report(signingPublicKey: signingPublicKey, reason: reason.rawValue, blockAlso: true)
        presenceManager.refreshRoster()
        snapshotSaveCoordinator.schedule()
    }

    /// True when this device has locally reported this artwork — the shop hides it from the grid + buy path.
    func isClothingItemLocallyReported(_ item: CustomizationItem) -> Bool {
        moderationLedger.isLocallyReported(
            contentHash: ModerationContentHash.of(item),
            reporterFingerprint: meshNetworkManager.localFingerprint)
    }

    /// Reports a shared shop item: records a local report keyed to the artwork's content hash + the
    /// seller's verified signing key (resolved from the vault), hides the item locally, and — when the
    /// seller resolves to a known key — blocks them.
    func reportClothingItem(_ item: CustomizationItem, sellerFingerprint: String?, reason: ReportReason) {
        let sellerKey = sellerFingerprint
            .flatMap { proximityTrustVault.peer(fingerprint: $0)?.signingPublicKey } ?? Data()
        moderationLedger.recordLocalReport(
            reporterSigningPublicKey: meshNetworkManager.localSigningPublicKey,
            reporterFingerprint: meshNetworkManager.localFingerprint,
            subjectSigningPublicKey: sellerKey,
            itemID: item.id,
            contentHash: ModerationContentHash.of(item),
            reason: reason.rawValue)
        if !sellerKey.isEmpty {
            proximityTrustVault.report(signingPublicKey: sellerKey, reason: reason.rawValue, blockAlso: true)
            presenceManager.refreshRoster()
        }
        reconcileModerationBans()
        snapshotSaveCoordinator.schedule()
    }

    /// Whether this device's own shop is currently banned for repeatedly-reported content.
    var isStoreBanned: Bool { moderationBanStore.isSelfBanned }

    /// Re-evaluates escalation from the local report ledger and applies any warranted self/peer bans.
    /// Inert until peers' verified reports arrive (Phase 3b) — a device only holds its own reports today.
    func reconcileModerationBans() {
        moderationBanStore.reconcile(
            rows: moderationLedger.rows,
            localSigningKey: meshNetworkManager.localSigningPublicKey)
    }

    /// Stores peers' verified moderation reports (from the one-hop relay) and re-evaluates bans.
    func ingestModerationRows(_ rows: [ModerationLedgerEntry]) {
        moderationLedger.ingestForeign(rows)
        reconcileModerationBans()
    }

    /// True when a shop item should be hidden on this device: locally reported, or enough distinct
    /// verified reporters (across the one-hop ledger) have flagged the same artwork.
    func isClothingItemHidden(_ item: CustomizationItem, sellerFingerprint: String?) -> Bool {
        if isClothingItemLocallyReported(item) { return true }
        let hash = ModerationContentHash.of(item)
        return ModerationEconomy.distinctReporters(ofContentHash: hash, in: moderationLedger.rows, now: Date())
            >= ClothingModerationLimits.itemUnlistableReporters
    }

    /// True when a nearby seller's whole shop is locally peer-banned (repeatedly-reported designer).
    func isProximitySellerBanned(fingerprint: String?) -> Bool {
        guard let fingerprint else { return false }
        return moderationBanStore.isPeerBanned(fingerprint: fingerprint)
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

    @discardableResult func logBarcodeScannedFoodItem(_ foodItem: FoodItem, mealType: MealType? = nil, date: String? = nil) -> Meal {
        diary.logBarcodeScannedFoodItem(foodItem, mealType: mealType, date: date)
    }

    @discardableResult func logLabelScannedFoodItem(_ foodItem: FoodItem, mealType: MealType? = nil, date: String? = nil) -> Meal {
        diary.logLabelScannedFoodItem(foodItem, mealType: mealType, date: date)
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

    /// One-tap mood check-in: a tag-only journal entry (empty text, just a `FeelingTag`). It flows
    /// through every existing "last entry's tag" consumer — the daily score's journal component,
    /// the moodTrend derived signal, the Home ambient thought, and the calendar tint — with no
    /// special-casing, and a later real journal simply appends after it (last entry wins, exactly
    /// the existing same-day semantics).
    ///
    /// Changing your mind updates the check-in IN PLACE when today's latest entry is one we can
    /// POSITIVELY identify as a tag-only check-in via its synced `isQuickMood` marker. We never infer
    /// "tag-only" from empty text alone: a sealed journal entry synced from another device (or an
    /// unhydrated local seal) also has empty text, so inferring would (a) silently retag a real
    /// entry cross-device, and (b) while locked — where no such entry can be identified — append a
    /// fresh row on every tap, inflating milestone counts. The marker is available on every device and
    /// regardless of lock state, so re-tapping always updates in place instead of duplicating.
    /// Empty-text entries are never sealed (see `JournalSealingCoordinator.seal`), so a check-in
    /// works even while the private lock is closed.
    func logQuickMood(_ tag: FeelingTag) {
        if let last = day.journals.last, last.isQuickMood, last.text.isEmpty {
            guard last.tag != tag else { return }
            var updated = last
            updated.tag = tag
            batchSnapshotPersistence {
                if let index = day.journals.lastIndex(where: { $0.id == last.id }) {
                    day.journals[index] = updated
                }
                if let index = previousJournals.firstIndex(where: { $0.id == last.id }) {
                    previousJournals[index] = updated
                }
            }
        } else {
            let entry = JournalEntry(text: "", tag: tag, isQuickMood: true)
            journalSealingCoordinator.seal(entry, dayKey: todayKey)  // no-op for empty text
            batchSnapshotPersistence {
                day.journals.append(entry)
                previousJournals.insert(entry, at: 0)
                previousJournals = Array(previousJournals.prefix(30))
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

    /// Whether today's single ambient gentle offer (breathing / worry box / short walk) may still show.
    var isGentleOfferAvailableToday: Bool { diary.isGentleOfferAvailable() }

    /// Consumes today's gentle offer (dismissed or accepted) until the start of the next local day.
    func dismissGentleOffer() {
        diary.dismissGentleOfferForToday()
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
        // Gaining real text turns a tag-only check-in into a genuine journal entry — drop the
        // quick-mood marker so it seals + labels like any written entry (and can't be retagged
        // in place by `logQuickMood`).
        updatedEntry.isQuickMood = false

        if journalSealingCoordinator.isSealed(entry.id) {
            journalSealingCoordinator.updateSealedNarrative(for: entry, text: trimmed, tag: tag, dayKey: date)
        } else {
            // The entry has no sealed narrative — a tag-only mood check-in gaining its first text
            // (empty entries are deliberately never sealed), or an entry whose original seal failed.
            // Seal it fresh so the new text is stripped from the synced blob like any other journal;
            // without this the update would leave plaintext in the (iCloud-synced) days blob.
            journalSealingCoordinator.seal(updatedEntry, dayKey: date)
        }

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
        // Clears all earn/spend rows and appends a reset-boundary marker. The next `reconcileCoinLedger()`
        // re-mints `earn` rows ONLY for active days at or after the reset boundary day — days before the
        // reset stay voided and are never re-minted, so another device can't undo a reset by
        // deterministically re-minting pre-reset earns. Activity logged on or after the reset day still
        // earns normally (the reset zeroes the past, it doesn't disable earning going forward).
        coinLedgerService.reset()
        // The MILESTONE ledger is deliberately NOT reset: lifetime care counts ("you've written 40
        // journal moments") are memories of showing up, not spendable state, and the product call
        // is that they survive a data reset. The rows carry no content — only kind + day of a
        // counted event (accepted metadata retention; see `MilestoneLedgerRepositoring`, which has
        // no delete API at all). Milestone COIN awards, by contrast, live in the coin ledger and
        // were just voided with everything else; `MilestoneEconomy.missingAwards` honors the reset
        // boundary, so pre-reset awards are never re-minted from the surviving events.
        aiRetryQueueService.reset()
        proximityTrustVault.apply(peers: [], audit: [])
        // The stress sidecar caches HealthKit-derived baselines on-device; "reset everything"
        // must not leave clinical derivatives behind.
        stressScoringContext?.scrubStressLocalState()
        // Worry Box notes are the app's most sensitive free-text data and a no-lock user has no
        // other bulk-wipe path — purge the sealed rows + the device-local let-go count.
        worryBoxResetHook?()
        // Received-heart records (friend names, fingerprints, glow, rate-limit keys) outlive the
        // trust-vault wipe otherwise; clear the device-local sidecar too.
        heartLedger.clearAll()
        // Moderation reports (who reported whom, and the reported artwork hashes) are device-local
        // social data — clear them on "Reset everything" like the heart ledger.
        moderationLedger.clearAll()
        // Friends' cached fuzzy state + appearance is device-local social data — clear it too.
        friendStateCache.clearAll()
        // Closeness signal (in-person interaction counts + close-slot assignment) — device-local; clear it.
        closenessLedger.clearAll()
        // Group activities (hosted/joined rosters + join tokens) — device-local social data, never synced;
        // clear the sidecar too (the manager owns it, mirroring the clothing-shop clearAll seam).
        meshNetworkManager.activities.clearAll()
    }

    private func rebuildDerivedSignals() {
        derivedSignalsService.rebuild(allDays: loadDays(), todayKey: todayKey)
    }

    /// Post-save hook: rebuild derived signals (existing behavior) plus a TODAY-ONLY milestone
    /// catch-up so a milestone award lands the moment the triggering log persists (journal saved,
    /// meal logged, water target met…). Today-only keeps the per-save cost O(today's entries); the
    /// full-history reconcile runs at the coin-ledger trigger points (launch/foreground/sync/buy).
    private func handleAfterSnapshotSave() {
        rebuildDerivedSignals()
        reconcileMilestones(days: [todayKey: day])
        // Mirror the benign widget snapshot on the same flush path every mutation funnels through
        // (SnapshotSaveCoordinator.schedule()/flushPending() → performSnapshotSave → here).
        publishWidgetSnapshot()
    }

    // MARK: - Widget bridge (FernletWidgets extension)

    /// Called once from ContentView at store-ready: wires the mirror, drains any actions the
    /// widget queued while the app was closed, and publishes the initial snapshot.
    func activateWidgetBridge() {
        if widgetSnapshotMirror == nil {
            widgetSnapshotMirror = WidgetSnapshotMirror()
        }
        processPendingWidgetActions()
    }

    /// Drains the widget's pending-action queue (mirrors `processSharedRecipeImportQueue`'s two
    /// call sites: launch .task + scenePhase .active). Rows are claimed atomically (removed under
    /// one file coordination) so a row can never apply twice; each is applied via the canonical
    /// dated water mutation against the row's OWN dateKey, so a tap after midnight with the app
    /// closed still lands on the day it happened (day-rollover safety).
    func processPendingWidgetActions() {
        guard !isProcessingPendingWidgetActions else { return }
        isProcessingPendingWidgetActions = true
        defer { isProcessingPendingWidgetActions = false }

        // The CURRENT wall-clock day, not the launch-pinned `todayKey`: the store is built once at
        // launch and never rebuilt on foreground, so a `+1 water` tap made after midnight on a
        // still-resident app carries the real new-day key. Filtering against the stale launch day
        // would drop that row AFTER `claimAll()` already removed it — a silently lost tap.
        let currentDayKey = FernletDate.dayKey(for: Date())
        var increments: [String: Int] = [:]
        var seenIDs = Set<UUID>()
        for action in pendingWidgetActionQueue.claimAll() {
            guard seenIDs.insert(action.id).inserted,                     // idempotent by row id
                  action.action == PendingWidgetAction.waterPlusOne,      // only known actions
                  FernletDate.date(fromDayKey: action.dateKey) != nil,    // well-formed day key
                  action.dateKey <= currentDayKey                         // never create future days
            else { continue }
            increments[action.dateKey, default: 0] += 1
        }
        for (dateKey, count) in increments.sorted(by: { $0.key < $1.key }) {
            let current = diary.loadDay(for: dateKey).bottleCount
            diary.setBottleCount(current + count, date: dateKey)
        }
        // Always republish (even with zero actions): keeps the widget's dateKey/state fresh on
        // every foreground, catching day rollovers that happened while the app was backgrounded.
        publishWidgetSnapshot()
    }

    /// Writes the benign snapshot to the app-group container + reloads widget timelines. No-op
    /// until `activateWidgetBridge()` has wired the mirror. PRIVACY: score/water/macros only.
    func publishWidgetSnapshot() {
        guard let widgetSnapshotMirror else { return }
        let macros = macroTotals
        widgetSnapshotMirror.publish(WidgetSnapshot(
            companionStateRaw: companionState.rawValue,
            score: score,
            bottleCount: day.bottleCount,
            hydrationTarget: settings.hydrationTarget,
            macroSummary: WidgetSnapshot.MacroSummary(
                protein: Double(macros.protein),
                carbs: Double(macros.carbs),
                fat: Double(macros.fat)
            ),
            dateKey: todayKey,
            computedAt: Date()
        ))
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
        // Same for the milestone ledger — a just-counted care event (or a breathing/worry live hook)
        // must survive backgrounding.
        milestoneLedgerService.flushPendingSave()
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
        milestoneLedgerService.reloadFromStore()
        customItemService.reloadFromStore()
        savedRecipeService.reloadFromStore()
        // Credit any newly active synced day (and reconcile milestones over the synced-in history).
        // Idempotent — re-running never double-grants.
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
        savedRecipeRepository: SavedRecipeRepository? = nil,
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
            SavedRecipeService(repository: savedRecipeRepository ?? SavedRecipeRepository())
        }
        let customItemService = StartupTiming.timed("CustomItemService.init") {
            CustomItemService(repository: CustomItemRepository())
        }
        let coinLedgerService = StartupTiming.timed("CoinLedgerService.init") {
            CoinLedgerService(repository: CoinLedgerRepository())
        }
        let milestoneLedgerService = StartupTiming.timed("MilestoneLedgerService.init") {
            MilestoneLedgerService(repository: MilestoneLedgerRepository())
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
        await milestoneLedgerService.loadAsync()

        return FernletStore(
            snapshot: snapshot,
            todayKey: key,
            repository: activeRepository,
            savedRecipeService: savedRecipeService,
            customItemService: customItemService,
            coinLedgerService: coinLedgerService,
            milestoneLedgerService: milestoneLedgerService,
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
