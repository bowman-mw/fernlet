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
import AIContext

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
    /// The AI status actually in effect: the stored (synced) user intent in `settings.aiStatus`
    /// overlaid with this device's local daily call counter (`AICallQuotaStore`). The derived
    /// `.sleepy` / `.resting` states are a read-only overlay — they are NEVER written back into the
    /// synced settings, so one device's usage can't throttle another. Feed the AI status *label*
    /// from this, not from the raw stored value.
    var effectiveAIStatus: AIStatus {
        AIStatusOverlay.effectiveStatus(intent: settings.aiStatus, quota: aiCallQuotaStore.currentQuota())
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
        // A photo exchanged with a friend this session feeds the closeness photo signal.
        manager.onFriendPhotoSession = { [weak self] fingerprint in
            self?.closenessLedger.recordPhotoSession(fingerprint: fingerprint)
        }
        // TF b19 item 5: in-session hearts ride the live mesh session (reliable) instead of the fragile
        // on-demand presence connect. Share the SAME device-local ledger the presence path uses so the
        // 5-minute cooldown + received-heart dedup stay consistent across both transports, and route the
        // sent/received closeness signals to the SAME hooks (day-capped downstream).
        manager.heartLedger = heartLedger
        manager.onHeartSent = { [weak self] fingerprint in self?.closenessLedger.recordHeartSent(fingerprint: fingerprint) }
        manager.onHeartReceived = { [weak self] fingerprint in self?.closenessLedger.recordHeartReceived(fingerprint: fingerprint) }
        return manager
    }()
    @ObservationIgnored private(set) lazy var recipeShareManager: ProximityRecipeShareManager = ProximityRecipeShareManager(store: self)
    /// Device-local hearts state (received hearts + per-friend-per-day rate limit). Deliberately
    /// outside the snapshot: heart activity never enters any synced store.
    @ObservationIgnored private(set) lazy var heartLedger = ProximityHeartLedger()
    /// Device-local moderation reports (never synced). Feeds item-hiding + the escalation/ban.
    @ObservationIgnored private(set) lazy var moderationLedger = ModerationLedger()
    /// Device-local, non-synced daily AI-call counter (Ladder §3.2). Drives the `.sleepy`/`.resting`
    /// overlay on `effectiveAIStatus`; deliberately outside the snapshot — usage never syncs.
    @ObservationIgnored private(set) lazy var aiCallQuotaStore: AICallQuotaStore = UserDefaultsAICallQuotaStore()
    /// Reports which AI rungs this device can physically reach (the cloud rungs report `false` on this
    /// SDK). Built by `FernletAIComposition` — the concrete provider type is named ONLY in that helper
    /// file, never here, so this store (which references many sealed `Private*` stores) is not flagged
    /// AI-facing by the S3 grep-wall. Injectable so a test can simulate an incapable device.
    @ObservationIgnored private(set) lazy var aiCapabilityProvider: AIDeviceCapabilityProviding = FernletAIComposition.defaultCapabilityProvider()
    /// The routing gate every AI call site funnels through — the capability-capped `FernletModelRouter`
    /// plus the device-local quota store plus the *current* stored AI intent. Rebuilt on each read so a
    /// mid-session AI toggle is always reflected, and so the effective status is derived from the live
    /// counter at dispatch time (§3.2). Never stored — it carries no state of its own.
    var aiGate: FernletAIGate {
        FernletAIGate(
            router: FernletModelRouter(capabilityProvider: aiCapabilityProvider),
            quotaStore: aiCallQuotaStore,
            intent: settings.aiStatus
        )
    }
    /// Test-injected override for `aiAuditLogStore` (a temp-path sink), so a delete-all test can assert
    /// the wipe leg without touching the process-global Application Support file. `nil` in production.
    @ObservationIgnored private var injectedAuditLogStore: AIAuditLogPersisting?
    /// Device-local, non-synced AI audit-log sink (Ladder §7.2). Persists the ring buffer of AI-call
    /// metadata to Application Support and is wired into `AIAuditLog.shared` at init so the log survives
    /// relaunch. Deliberately outside the snapshot/CloudKit/export — a "what left my device" record
    /// must never itself leave the device.
    @ObservationIgnored private(set) lazy var aiAuditLogStore: AIAuditLogPersisting = injectedAuditLogStore ?? FileAIAuditLogStore()
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
    @ObservationIgnored private(set) lazy var presenceManager: PresenceManager = {
        let manager = PresenceManager(store: self, ledger: heartLedger)
        // Hearts sent/received in person feed the closeness signal (day-capped downstream).
        manager.onHeartSent = { [weak self] fingerprint in self?.closenessLedger.recordHeartSent(fingerprint: fingerprint) }
        manager.onHeartReceived = { [weak self] fingerprint in self?.closenessLedger.recordHeartReceived(fingerprint: fingerprint) }
        return manager
    }()
    @ObservationIgnored let derivedSignalsService = DerivedSignalsService()
    @ObservationIgnored private let healthKitService: (any HealthKitServicing)?
    @ObservationIgnored private lazy var healthSyncCoordinator = HealthSyncCoordinator(host: self, healthKitService: healthKitService)
    /// Persisted tombstones for locally-removed workouts, so the workout observer can delete-and-skip an
    /// app-authored Health sample that resurfaces after its row was already removed (see `removeWorkout`).
    @ObservationIgnored private let workoutTombstones = WorkoutTombstoneStore()
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
    /// Loads the full branded catalog (On-Demand Resource) and attaches it to `foodCatalog` at launch;
    /// held so its ODR access isn't reclaimed for the app session. See BrandedCatalogResourceLoader.
    @ObservationIgnored private let brandedCatalogLoader = BrandedCatalogResourceLoader()
    @ObservationIgnored private var isReloadingFromRepository = false
    @ObservationIgnored private let mealPhotoStore = MealPhotoStore(
        directory: (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("MealPhotos", isDirectory: true)
    )
    /// The user's gym progress-photo timeline (#11). Body photos, so it seals the bytes AND the dated
    /// index; reuses the same hardened media path as meal photos, in its own directory.
    @ObservationIgnored private let progressPhotoStore = ProgressPhotoStore(
        directory: (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("ProgressPhotos", isDirectory: true)
    )
    /// The user's OWN photo for a recipe (#1), sealed and keyed by the recipe id. No external image
    /// fetch (tester decision) — this only ever holds a photo the user chose.
    @ObservationIgnored private let recipePhotoStore = MealPhotoStore(
        directory: (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("RecipePhotos", isDirectory: true),
        // Recipe photos never had a plaintext generation — fail closed on unsealed on-disk bytes.
        allowsLegacyPlaintextUpgrade: false
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
    /// Inbound queue of recipes shared in from the share extension (injectable file URL for tests).
    /// One instance shared by the drain and by "delete everything", so a wipe can't miss a queue the
    /// drain would still find.
    @ObservationIgnored var sharedRecipeImportQueue = SharedRecipeImportQueue()
    /// Read-only abstract egress from the private cycle data into scoring. Nil until the app wires a
    /// `PeriodContextBridge`; when nil (or the opt-in is off) scoring is byte-identical to period-unaware.
    @ObservationIgnored private(set) var periodScoringContext: (any PeriodScoringContextProviding)?
    /// Read-only stress ("body signals") context for the gentle scoring nudge. Nil until the app wires a
    /// `StressService`; when nil (or the opt-in is off) scoring is byte-identical to stress-unaware.
    @ObservationIgnored private(set) var stressScoringContext: (any StressScoringContextProviding)?

    /// Device-local Worry Box seams (the `WorryBoxService` is a `ContentView` @State, not owned here).
    /// The lifetime "worries let go" count is read through `worriesLetGoProvider` — it stays device-local
    /// (never the synced milestone ledger) so worry metadata honors the box's "never sync" promise —
    /// and `worryBoxResetHook` lets `resetAll` purge the sealed worry rows + count. The hook returns
    /// whether the row delete landed — `Bool` like the sealed delete hooks, so a failed (or unwired)
    /// purge reaches the "delete everything" outcome instead of being swallowed while the dialog
    /// promises "Worry Box notes" are gone.
    @ObservationIgnored var worriesLetGoProvider: (() -> Int)?
    @ObservationIgnored var worryBoxResetHook: (() -> Bool)?

    /// Scrub seam for the cycle-visibility gate. Same shape as `worryBoxResetHook`: the
    /// `PeriodTrackerStore` is `ContentView` state, not owned here, but hiding must drop its resident
    /// plaintext synchronously — a gate that only refuses the NEXT load would leave up to 240 days of
    /// decrypted narratives in memory until process death.
    ///
    /// Intimacy has no equivalent hook: its caches are `@State` on `PersonalScreenView`, which this
    /// layer cannot reach. That view scrubs itself via `.onChange(of: isIntimacyTrackingVisible)`, and
    /// `loadIntimacyCalendar`'s own gate catches anything that slips past.
    @ObservationIgnored var periodScrubHook: (() -> Void)?

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

    /// Device-local sidecar for the sensitive-surface (period/intimacy) visibility RESOLUTION — the marker
    /// a mixed-version peer can never rewrite because it never rides the synced blob. A pre-gate build on a
    /// second device re-encodes the synced settings without the visibility keys; on re-decode the pin would
    /// re-fire (nil ⇒ visible-true) and intimacy would default back to visible, silently re-opening a
    /// deliberately hidden surface. This marker lets a device that has already resolved re-assert its own
    /// values fail-closed instead. Injectable so tests isolate it from `.standard`, mirroring
    /// `pastDayJournalScrubDefaults`. See `reconcileSensitiveSurfaceVisibility`.
    @ObservationIgnored private let sensitiveVisibilityDefaults: UserDefaults
    private enum SensitiveVisibilityKeys {
        static let resolved = "sensitiveVisibilityResolved"
        static let period = "sensitiveVisibilityResolvedPeriodVisible"
        static let intimacy = "sensitiveVisibilityResolvedIntimacyVisible"
    }

    init(date: Date = .now, repository: FernletRepository? = nil, savedRecipeRepository: SavedRecipeRepository? = nil, customItemRepository: (any CustomItemRepositoring)? = nil, coinLedgerRepository: (any CoinLedgerRepositoring)? = nil, milestoneLedgerRepository: (any MilestoneLedgerRepositoring)? = nil, healthKitService: (any HealthKitServicing)? = nil, journalNarrativeRepository: (any JournalNarrativeStoring)? = nil, foodCatalog: FoodCatalog = .bundled(), sensitiveVisibilityDefaults: UserDefaults = .standard, aiAuditLogStore: AIAuditLogPersisting? = nil, cookingRunDirectory: URL? = nil) {
        self.sensitiveVisibilityDefaults = sensitiveVisibilityDefaults
        self.injectedAuditLogStore = aiAuditLogStore
        // Test seam: redirect the shared cooking-run app-group file to a per-test temp dir so a parallel
        // suite's file wipe can't race a cooking test's read (mirrors GuidedWorkoutRunStateStore(directory:)).
        if let cookingRunDirectory {
            self.cookingRunStateStore = CookingRunStateStore(directory: cookingRunDirectory)
        }
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
        // Apply the one-time period-visibility migration + the mixed-version fail-closed guard against the
        // just-loaded settings, BEFORE any UI reads `isPeriodTrackingVisible` or a save can persist.
        reconcileSensitiveSurfaceVisibility()
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
        configureAIAuditLog()
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
        self.sensitiveVisibilityDefaults = .standard
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
        reconcileSensitiveSurfaceVisibility()
        self.connectionInspector.attachStore(self)
        proximityTrustVault.onChange = { [weak self] in self?.snapshotSaveCoordinator.schedule() }
        aiRetryQueueService.onChange = { [weak self] in self?.snapshotSaveCoordinator.schedule() }
        reconcileCoinLedger()
        snapshotSaveCoordinator.subscribeRemote { [weak self] in
            await self?.reloadFromRepository()
        }
        configureAIAuditLog()
    }

    /// Wires the device-local AI audit-log sink into `AIAuditLog.shared` and adopts whatever survived
    /// the last relaunch. Runs before any AI call could record, so the in-memory session set adopts the
    /// persisted history rather than racing it. Device-local only — never synced/snapshot/exported.
    private func configureAIAuditLog() {
        let auditSink = aiAuditLogStore
        Task { await AIAuditLog.shared.configure(sink: auditSink) }
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
        // Food-page badge: meal retries only. Non-meal records the Food "Retry oldest" button can't
        // process must not inflate this count.
        aiRetryQueueService.mealPendingCount
    }

    var isIntimateLoggingAllowed: Bool { diary.isIntimateLoggingAllowed }

    /// Whether cycle surfaces are visible. An explicit Settings choice outranks `sex`; absent one,
    /// derives from the onboarding answer. Distinct from `isIntimateLoggingAllowed`-style age gating:
    /// there is no age floor on cycle tracking, only a preference.
    ///
    /// This is a HARD gate — see `PeriodTrackerStore.isVisible`. Callers must not treat it as a
    /// display hint.
    var isPeriodTrackingVisible: Bool {
        settings.periodTrackingVisible ?? (settings.userProfile.sex == .female)
    }

    /// Whether intimate-activity surfaces are visible. Age is a separate, non-overridable floor —
    /// an adult who hides the feature and an under-18 user are both invisible, but for different
    /// reasons, and the UI must say the right one (see `intimacyHiddenReason`).
    var isIntimacyTrackingVisible: Bool {
        isIntimateLoggingAllowed && settings.intimacyTrackingVisible
    }

    /// The gate value for filtering navigation surfaces. Display-only — never persist a list filtered
    /// by this (see `FernletShortcut.visibleQuickLog`).
    var sensitiveSurfaceVisibility: SensitiveSurfaceVisibility {
        SensitiveSurfaceVisibility(
            intimacy: isIntimacyTrackingVisible,
            period: isPeriodTrackingVisible
        )
    }

    /// Flips the cycle-visibility gate and, when hiding, immediately drops every piece of cycle data
    /// already resident. Refusing future loads is not enough on its own: `PeriodTrackerStore.entries`
    /// can hold up to 240 days of decrypted narratives for the life of the process, and the day's
    /// health context would otherwise keep its last cycle value forever (see `scrubHiddenHealthContext`).
    /// Hiding never deletes — the sealed rows and HealthKit samples are untouched and come back if
    /// the user un-hides.
    func setPeriodTrackingVisible(_ visible: Bool) {
        diary.setPeriodTrackingVisible(visible)
        // Record the explicit choice device-locally so a later mixed-version key-drop re-asserts exactly
        // what the user last chose here (fail-closed) rather than re-running the pin-to-visible.
        recordSensitiveVisibilityResolution()
        if !visible {
            periodScrubHook?()
            diary.scrubHiddenHealthContext(periodVisible: false, intimacyVisible: isIntimacyTrackingVisible)
        } else {
            settlePeriodBackupAfterUnhide()
        }
    }

    /// The in-flight un-hide settle, held so the delete-all funnel can cancel it (see
    /// `settlePeriodBackupAfterUnhide`). Internal-settable ONLY so the delete-all tests can seed a live
    /// task; production writes it solely in `settlePeriodBackupAfterUnhide`.
    @ObservationIgnored var periodBackupSettleTask: Task<Void, Never>?

    /// Settles BOTH halves of the sealed period backup at the one moment the sealed narrative store
    /// becomes reachable again. Order is load-bearing:
    ///
    /// 1. **Restore first.** `restoreSealedBackupsIfNeeded` only ever restores into a fresh install, and by
    ///    the time a user un-hides, the day blob has synced down and the device is permanently "not
    ///    fresh" — so without this, someone who hides cycle tracking on one device and reinstalls on
    ///    another never gets their sealed history back, and every other period seam re-uploads instead.
    ///    The targeted restore drops only the whole-device freshness gate; a narrative store that already
    ///    holds history still refuses, so this can add data back but never overwrite.
    /// 2. **Re-upload second, and only if the restore left nothing retryable AND this device actually has
    ///    narratives to seal.** This is the deferral banner's promised remedy (G5) — the escrow adopt
    ///    couldn't re-seal while hidden. But re-sealing pages the LOCAL narrative store and rewrites the
    ///    whole chunk set, so running it over an empty store would overwrite the good cloud backup with a
    ///    single empty chunk. A retryable outcome leaves the deferral flag set; the coordinator clears the
    ///    deferral only on an ACTUAL re-seal success, so a failure keeps the banner honest.
    ///
    ///    Note the deferral does NOT fully self-heal at next launch: the ambient launch pass is
    ///    fresh-install-only and does not take the targeted-restore fallback (that is reserved for the
    ///    user's explicit Retry), so on an in-use device the restore half stays pending until the user
    ///    taps Retry. The launch follow-through re-upload is guarded on the same non-empty check, so a
    ///    pending restore can never be overwritten in the meantime.
    ///
    /// Both halves are gated on the pref so a backup the user has since turned off is never touched.
    ///
    /// The Task is HELD in `periodBackupSettleTask` (not fire-and-forget) so "delete everything" can
    /// cancel it: a settle suspended in the CloudKit fetch when the wipe runs would otherwise resume
    /// afterwards and re-insert cycle narratives into the just-emptied store — the same live-writer
    /// class as the debounced save and the guided run, which the funnel already stops.
    /// `applyRestoredChunks` checks for cancellation at the write point, and the `Task.isCancelled`
    /// guard here keeps a cancelled settle from re-uploading.
    private func settlePeriodBackupAfterUnhide() {
        let preferences = StoragePreferencesStore.currentPreferences()
        guard preferences.sealedBackupPeriodEnabled else { return }
        let reuploadDeferred = sealedBackupPeriodReuploadDeferred
        // A re-toggle while a settle is in flight replaces it — two concurrent settles could interleave
        // their restore/re-upload halves.
        periodBackupSettleTask?.cancel()
        periodBackupSettleTask = Task {
            if preferences.iCloudSyncEnabled {
                let outcome = await restorePeriodBackupTargeted()
                guard !outcome.isRetryable else { return }
            }
            guard !Task.isCancelled else { return }
            if reuploadDeferred, sealedBackupCoordinator.periodNarrativeCount() > 0 {
                await setSealedBackupEnabled(true, payloadType: .periodData)
            }
        }
    }

    func setIntimacyTrackingVisible(_ visible: Bool) {
        diary.setIntimacyTrackingVisible(visible)
        recordSensitiveVisibilityResolution()
        if !visible {
            diary.scrubHiddenHealthContext(periodVisible: isPeriodTrackingVisible, intimacyVisible: false)
        }
    }

    // MARK: - Sensitive-surface visibility resolution (device-local, never synced)

    /// Reads the device-local resolution marker from the sidecar. `resolved == false` means this device
    /// has never made a determination (a genuinely fresh device); the period value is a tri-state stored
    /// as an object so `nil` ("derive from `sex`") is distinct from an explicit `false`.
    private func loadSensitiveVisibilityResolution() -> SensitiveVisibilityResolution {
        let defaults = sensitiveVisibilityDefaults
        return SensitiveVisibilityResolution(
            resolved: defaults.bool(forKey: SensitiveVisibilityKeys.resolved),
            periodTrackingVisible: defaults.object(forKey: SensitiveVisibilityKeys.period) as? Bool,
            intimacyTrackingVisible: (defaults.object(forKey: SensitiveVisibilityKeys.intimacy) as? Bool) ?? true
        )
    }

    private func storeSensitiveVisibilityResolution(_ resolution: SensitiveVisibilityResolution) {
        let defaults = sensitiveVisibilityDefaults
        defaults.set(resolution.resolved, forKey: SensitiveVisibilityKeys.resolved)
        if let period = resolution.periodTrackingVisible {
            defaults.set(period, forKey: SensitiveVisibilityKeys.period)
        } else {
            defaults.removeObject(forKey: SensitiveVisibilityKeys.period)
        }
        defaults.set(resolution.intimacyTrackingVisible, forKey: SensitiveVisibilityKeys.intimacy)
    }

    /// Clears the device-local marker back to "unresolved" so a full reset returns to a genuinely fresh
    /// device that re-derives from `sex`. Called from `resetAll` alongside the other device-local sidecars.
    private func clearSensitiveVisibilityResolution() {
        let defaults = sensitiveVisibilityDefaults
        defaults.removeObject(forKey: SensitiveVisibilityKeys.resolved)
        defaults.removeObject(forKey: SensitiveVisibilityKeys.period)
        defaults.removeObject(forKey: SensitiveVisibilityKeys.intimacy)
    }

    /// Snapshots the CURRENT explicit visibility values into the device-local marker after the user changes
    /// a toggle. Resolving is implied by the act of choosing.
    private func recordSensitiveVisibilityResolution() {
        storeSensitiveVisibilityResolution(SensitiveVisibilityResolution(
            resolved: true,
            periodTrackingVisible: settings.periodTrackingVisible,
            intimacyTrackingVisible: settings.intimacyTrackingVisible
        ))
    }

    /// Applies the one-time period-visibility migration + the mixed-version fail-closed guard against the
    /// just-loaded settings, using the device-local marker (see `FernletSettings.reconcilingSensitiveVisibility`).
    /// Runs at every settings load/apply. Persists a re-asserted/migrated flip so it survives and syncs from
    /// an up-to-date device; refreshes the device-local record only when a real determination exists — a
    /// blank-slate first load (the synthesized missing-record default) stays genuinely UNRESOLVED, so the
    /// real account blob arriving via sync still gets the migration pin instead of a pristine re-assert.
    private func reconcileSensitiveSurfaceVisibility() {
        let deviceLocal = loadSensitiveVisibilityResolution()
        let result = settings.reconcilingSensitiveVisibility(deviceLocal: deviceLocal)
        if result.settings.periodTrackingVisible != settings.periodTrackingVisible
            || result.settings.intimacyTrackingVisible != settings.intimacyTrackingVisible
            || result.settings.didMigratePeriodVisibility != settings.didMigratePeriodVisibility {
            settings = result.settings
        }
        if result.resolution != deviceLocal {
            storeSensitiveVisibilityResolution(result.resolution)
        }
        if result.settingsChanged {
            snapshotSaveCoordinator.schedule()
        }
    }

    /// Drops any hidden dimension left resident in the day's health context. Called on load as well as
    /// on the toggle, so a day record written before the user hid the feature can't keep serving it.
    func scrubHiddenHealthContext() {
        diary.scrubHiddenHealthContext(
            periodVisible: isPeriodTrackingVisible,
            intimacyVisible: isIntimacyTrackingVisible
        )
    }

    func setSelectedGoal(_ goal: GoalType) {
        diary.setSelectedGoal(goal)
    }

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
            // Scope to meal records: a non-meal retry's sourceId is not a meal id and must not be
            // treated as an excluded meal.
            excludingMealIDs: Set(
                aiRetryQueueService.retryQueue
                    .filter { $0.payloadType == AIRetryQueueService.mealPayloadType }
                    .map(\.sourceId)
            ),
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
        /// The item was reported/hidden or the seller is peer-banned — refused at the store boundary even
        /// if the tap raced a mid-session report/ban that hadn't re-rendered the grid yet.
        case unavailable
    }

    /// Buy an item from a friend's shop. Reloads the per-row stores first so another device's spends and
    /// purchases are seen before guarding, sanitizes the (untrusted, peer-sent) item, debits coins
    /// idempotently keyed by the item id, and lands the item in the closet with the SELLER's designer id
    /// preserved (provenance — it shows "designed by <friend>", never "You"). The bought copy is unlisted
    /// and not auto-equipped.
    @discardableResult
    func buyClothingItem(_ rawItem: CustomizationItem, fromDesignerID designerID: UUID, sellerName: String,
                         sellerFingerprint: String? = nil) -> ClothingPurchaseResult {
        // See another device's spends / synced-in purchases before guarding (multi-device reconciliation).
        coinLedgerService.reloadFromStore()
        customItemService.reloadFromStore()
        reconcileCoinLedger()

        let item = ClothingShopLimits.sanitizedForShop(rawItem)

        // Moderation gate at the STORE boundary, not just the shop's render-time filter: a verified report
        // or peer-ban can arrive over the mesh mid-session, and an in-flight buy tap can fire against a row
        // the grid hasn't dropped yet. Any future buy surface is covered here too.
        if isProximitySellerBanned(fingerprint: sellerFingerprint)
            || isClothingItemHidden(item, sellerFingerprint: sellerFingerprint) {
            return .unavailable
        }

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
            // Blocked records were already skipped above, so a non-nil `existing` here is an active OR a
            // revoked ("Removed") record we're reviving — both must pass the cap. Only a genuinely NEW
            // fingerprint (`existing == nil`) is capped; testing active-only wrongly blocked reviving a
            // previously-removed friend once 12 active friends existed.
            let existing = proximityTrustVault.peer(signingPublicKey: entry.signingPublicKey)
            if existing == nil,
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

    /// Drops every device-local trace of a removed friend — their cached fuzzy vibe + appearance and
    /// their closeness interaction history — so a blocked/revoked/reported friend leaves nothing behind
    /// (the privacy invariant the cache `remove` methods were written for). Idempotent; no-op if absent.
    private func forgetProximityFriendCaches(signingPublicKey: Data) {
        let fingerprint = IdentityService.fingerprint(of: signingPublicKey)
        friendStateCache.remove(fingerprint: fingerprint)
        closenessLedger.remove(fingerprint: fingerprint)
    }

    func revokeTrustedProximityPeer(signingPublicKey: Data) {
        proximityTrustVault.revoke(signingPublicKey: signingPublicKey)
        forgetProximityFriendCaches(signingPublicKey: signingPublicKey)
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
        forgetProximityFriendCaches(signingPublicKey: signingPublicKey)
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
        forgetProximityFriendCaches(signingPublicKey: signingPublicKey)
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
    /// seller's transport-verified signing key, hides the item locally, and — when the seller resolves to
    /// a known key — blocks them. The key is taken from the catalog (captured at receipt, so it works for
    /// a committed-but-not-kept seller), falling back to the vault; without a real key the report can't
    /// escalate to a cross-device designer ban, so we prefer the catalog's verified key.
    func reportClothingItem(_ item: CustomizationItem, sellerFingerprint: String?,
                            sellerSigningPublicKey: Data?, reason: ReportReason) {
        let sellerKey = sellerSigningPublicKey.flatMap { $0.isEmpty ? nil : $0 }
            ?? sellerFingerprint.flatMap { proximityTrustVault.peer(fingerprint: $0)?.signingPublicKey }
            ?? Data()
        moderationLedger.recordLocalReport(
            reporterSigningPublicKey: meshNetworkManager.localSigningPublicKey,
            reporterFingerprint: meshNetworkManager.localFingerprint,
            subjectSigningPublicKey: sellerKey,
            itemID: item.id,
            contentHash: ModerationContentHash.of(item),
            reason: reason.rawValue)
        if !sellerKey.isEmpty {
            proximityTrustVault.report(signingPublicKey: sellerKey, reason: reason.rawValue, blockAlso: true)
            forgetProximityFriendCaches(signingPublicKey: sellerKey)
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

    /// G4 — the ambient-read gate. This is the load-bearing one for hiding: the Home tab requests
    /// EVERY capability on each appearance (see `refreshHealthContextForActiveTab`), so without this
    /// subtraction Fernlet would keep reading cycle/intimacy samples out of HealthKit on a path no
    /// view drives and the user cannot see.
    func allowedHealthCapabilities(from capabilities: Set<HealthCapability>) -> Set<HealthCapability> {
        var allowed = capabilities
        if !isIntimacyTrackingVisible { allowed.remove(.intimateLogging) }
        if !isPeriodTrackingVisible { allowed.remove(.cycleTracking) }
        if lockState != .unlocked {
            allowed.remove(.cycleTracking)
            // Previously only `.cycleTracking` was dropped on lock, so intimacy event counts were
            // read out of HealthKit and rendered while the app was locked — the lock is supposed to
            // cover intimate data at least as tightly as cycle data.
            allowed.remove(.intimateLogging)
        }
        return allowed
    }

    // NOTE (deviation): `visibleHealthCapabilities` STAYS IN THE FACADE. `HealthCapability` is an
    // app-target type (defined in HealthKitService.swift), not a portable DomainModel type — the
    // classification's "HealthCapability type, not HealthKit" note was incorrect. Its body forwards
    // to `diary.isIntimateLoggingAllowed`, preserving identical behavior.
    /// Which capabilities Settings > Health offers a row for. MUST honor the visibility gates as well
    /// as the age check: each row's "Update data" action passes its capability STRAIGHT to
    /// `loadDailyHealthContext`, bypassing `allowedHealthCapabilities` entirely — so a listed Cycle row
    /// doesn't merely ignore the gate, it undoes it, re-reading HealthKit and re-populating the exact
    /// `healthContext.cycle` that hiding just scrubbed (and prompting for cycle authorization on a
    /// feature the user just switched off).
    var visibleHealthCapabilities: [HealthCapability] {
        HealthCapability.allCases.filter { capability in
            switch capability {
            case .intimateLogging: isIntimacyTrackingVisible
            case .cycleTracking: isPeriodTrackingVisible
            default: true
            }
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

    /// Logs the curated food behind an F2 micronutrient nudge's "add it" affordance. Resolves the
    /// source's PINNED catalog `FoodItem` (id first, normalized-name fallback second) and logs one
    /// serving of it — so the logged meal carries the actual macros AND the nudged micronutrient.
    /// This is the whole point of pinning an id: free-text logging of the display name re-parses it
    /// with fabricated macros and binds an arbitrary branded row that often carries none of the
    /// nudged nutrient, which would then suppress the nudge without moving the gap. Returns the
    /// logged meal, or `nil` when the pinned food cannot be resolved against the bundled catalog
    /// (a regeneration/packaging fault — the curated table is unit-pinned so this should not happen).
    @discardableResult func logNutrientSuggestionFood(_ source: CuratedFoodSource, date: String? = nil) -> Meal? {
        guard let foodItem = CuratedNutrientSources.shared.resolve(source, in: foodCatalog) else { return nil }
        return diary.logNutrientSuggestionFoodItem(foodItem, date: date)
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
        // Day-rollover safety: if the app has stayed resident across local midnight, advance the store's
        // notion of "today" BEFORE resolving the default date, so a meal committed just after midnight
        // files on the new day rather than yesterday. Only when the caller relies on "today" (`date == nil`);
        // an explicit date is honored as-is. No-op unless the day actually rolled over.
        if date == nil { refreshCurrentDayIfNeeded() }
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

    /// Whether a sealed meal-photo file exists on this device for `id` (existence only — no decrypt).
    /// Lets a renderer tell "the bytes never synced here" (no file → on your other device) from "the
    /// file is here but couldn't be opened" (corrupt / undecryptable → a gentle unavailable state).
    func mealPhotoHasSealedFile(for id: UUID) -> Bool {
        mealPhotoStore.hasSealedData(forID: id)
    }

    #if canImport(UIKit)
    @discardableResult func saveMealPhoto(_ image: UIImage) -> UUID? {
        guard let data = image.jpegData(compressionQuality: 0.82) else { return nil }
        return mealPhotoStore.save(data)
    }

    /// Byte-path meal-photo save mirroring `saveRecipePhoto(data:)` / `addProgressPhoto(data:)`: seals
    /// the picked JPEG `Data` straight through the store's bounded ImageIO downscale (one normalize at
    /// q0.8) instead of the `UIImage` overload's redundant full-resolution `jpegData(0.82)` pre-encode.
    /// This is the double-JPEG-encode fix (§2.5) for the library-pick path — the ~190 MB / generation-
    /// loss landmine on the iPhone-11 floor that F1 makes photo→recipe fire far more often. Fail-closed
    /// (nil on non-image bytes or no key). Returns the new photo id.
    @discardableResult func saveMealPhoto(data: Data) -> UUID? {
        mealPhotoStore.save(data)
    }
    #endif

    // MARK: - Progress photos (#11 — the Move-tab timeline)

    /// The progress-photo timeline, newest first. Reads the sealed store on demand (the Move tab caches
    /// the result in view state and refreshes after a mutation, like `loadDays`), so there is no observed
    /// copy of these body-photo records held in app state.
    func progressPhotoRecords() -> [ProgressPhotoRecord] {
        progressPhotoStore.records()
    }

    func progressPhotoData(for id: UUID) -> Data? {
        progressPhotoStore.imageData(for: id)
    }

    func updateProgressPhotoCaption(id: UUID, caption: String?) {
        progressPhotoStore.updateCaption(id: id, caption: caption)
    }

    /// Edits a progress photo's capture date (the manual editor in the detail view). Backs onto the same
    /// fail-closed sealed-index rewrite as the caption edit.
    func updateProgressPhotoCapturedAt(id: UUID, date: Date) {
        progressPhotoStore.updateCapturedAt(id: id, date: date)
    }

    /// Library-pick entry point: seals the picked JPEG `Data` straight through the store's bounded ImageIO
    /// downscale (the ONLY decode), skipping the full-resolution-bitmap round trip that `UIImage.jpegData`
    /// forces. A 48 MP pick would otherwise materialise a ~190 MB bitmap and risk jetsam on the iPhone-11
    /// floor. `capturedAt` carries the photo's real (best-effort recovered) date so imports aren't pinned
    /// to "now". Returns the stored record, or nil when the bytes can't be sealed (fail-closed).
    @discardableResult func addProgressPhoto(data: Data, capturedAt: Date) -> ProgressPhotoRecord? {
        progressPhotoStore.add(data, capturedAt: capturedAt)
    }

    func deleteProgressPhoto(id: UUID) {
        progressPhotoStore.delete(id: id)
    }

    #if canImport(UIKit)
    /// Seals a new progress photo taken now. Returns the stored record (nil if the image couldn't be
    /// encoded/sealed). JPEG-encodes at source quality; the store downscales + re-encodes on the way in.
    @discardableResult func addProgressPhoto(_ image: UIImage, caption: String? = nil) -> ProgressPhotoRecord? {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        return progressPhotoStore.add(data, caption: caption, capturedAt: Date())
    }
    #endif

    #if DEBUG
    /// DEBUG-only seam for the demo/appearance seed: seals a progress photo with an EXPLICIT capture
    /// date so the seeded timeline shows a real spread rather than three photos stamped "now". Not on
    /// the shipping path — the app always captures at the current moment.
    @discardableResult func seedProgressPhoto(_ data: Data, caption: String?, capturedAt: Date) -> ProgressPhotoRecord? {
        progressPhotoStore.add(data, caption: caption, capturedAt: capturedAt)
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

    @discardableResult func logBarcodeScannedFoodItem(_ foodItem: FoodItem, mealType: MealType? = nil, date: String? = nil, servings: Double = 1) -> Meal {
        diary.logBarcodeScannedFoodItem(foodItem, mealType: mealType, date: date, servings: servings)
    }

    @discardableResult func logLabelScannedFoodItem(_ foodItem: FoodItem, mealType: MealType? = nil, date: String? = nil, servings: Double = 1) -> Meal {
        diary.logLabelScannedFoodItem(foodItem, mealType: mealType, date: date, servings: servings)
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

        let queue = sharedRecipeImportQueue
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
            // Already deferred for budget TODAY: the daily AI budget won't refresh until midnight, so
            // re-fetching this (non-JSON-LD) page's HTML on every foreground is pure waste — skip it until
            // the day-key changes. A JSON-LD page imports with no gate and is never stamped, so it still
            // retries and succeeds. (The first budget miss of the day still had to attempt the fetch, since
            // a JSON-LD-capable page can't be distinguished before fetching.)
            if record.budgetDeferredDayKey == todayKey {
                continue
            }

            do {
                // Ambient drain: userInvoked=false, so the `.sleepy` band falls back and the daily
                // budget is reserved for the user's own taps. A JSON-LD page still imports here without
                // AI (that path runs before any gate check), so a resting device only defers pages that
                // genuinely need the model.
                let importedRecipe = try await RecipeWebImporter.importRecipe(from: url, catalog: foodCatalog, aiEnabled: settings.aiStatus != .off, userInvoked: false, gate: aiGate)
                addSavedRecipe(RecipeDefinition(importedRecipe: importedRecipe))
                queue.remove(record)
            } catch RecipeWebImportError.aiBudgetExhausted {
                // Transient daily-budget fallback (clears at midnight) — NOT the page's fault. Don't burn
                // an attempt or remove the record; just stamp it deferred-for-today so the rest of today's
                // foreground drains skip re-fetching it. Tomorrow's key differs → it retries with a fresh
                // budget.
                queue.markBudgetDeferred(record, dayKey: todayKey)
                FernletAuditLog.log("recipe.shareExtensionImport.deferred", context: [
                    "host": url.host() ?? "unknown",
                    "reason": "aiBudgetExhausted"
                ])
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
        // The recipe's own photo is keyed by the recipe id, so it's cleaned up here rather than stranded.
        recipePhotoStore.delete(id: recipe.id)
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

    // MARK: - Planned recipes (F3 weekly shopping-list planner)

    func planRecipe(_ recipeID: UUID, date: String) {
        diary.planRecipe(recipeID, date: date)
    }

    func unplanRecipe(_ recipeID: UUID, date: String) {
        diary.unplanRecipe(recipeID, date: date)
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

    /// Removes a logged workout and reverses the bookkeeping its completion set up, so an accidental
    /// "Complete" is fully recoverable. Returns `false` (no change) when the id isn't on `date`, or the
    /// row is a genuine Apple Health *import* (`isHealthImported` — a sample owned by another app or a
    /// manual Health entry). Imports are refused: removing only our mirror would orphan the Health sample
    /// and the next refresh would resurrect it; the UI offers those rows a "manage in Health" affordance
    /// instead of Remove.
    ///
    /// A Fernlet-*authored* row IS removable — Fernlet owns that Health sample, so removal also deletes the
    /// Health copy (async, honestly reported; the local row is removed regardless — local intent wins). A
    /// not-yet-stamped row (its Health save may still be in flight) is removable too. For every removable
    /// row it also:
    /// - clears the guided completion (session id + progression) when the row was guided-logged and the
    ///   committed plan is still resolvable, so the Start card / "Mark done" honestly re-offer it;
    /// - restores the planned row a completion consumed (best-effort; the original planned id is
    ///   preserved so weekly copy-forward identity survives);
    /// - records a tombstone + fires a targeted Health delete by `fernlet.workoutID`, so an app-authored
    ///   sample that lands (or already landed) can't come back as a new untagged row (see the tombstone
    ///   note below).
    @discardableResult
    func removeWorkout(id: UUID, date: String) -> Bool {
        assert(!date.isEmpty, "workout date required")
        guard let workout = diary.loadDay(for: date).workouts.first(where: { $0.id == id }) else { return false }
        // A genuine Health import is read-only here; refuse so we never orphan / resurrect it.
        guard !workout.isHealthImported else { return false }

        // Reverse the guided completion while the committed plan + the row's name are still resolvable.
        if workout.loggedFromGuidedSession == true {
            reverseGuidedCompletion(for: workout, date: date)
        }

        diary.removeWorkout(id: id, date: date)

        // Put back the planned row this completion consumed. Idempotent: `planWorkout` replaces by id,
        // and a repeat remove finds no row (so no double-restore on double-remove).
        if let plannedID = workout.plannedWorkoutID {
            diary.planWorkout(Self.reconstructPlannedWorkout(from: workout, plannedID: plannedID), date: date)
        }

        // Tombstone synchronously (survives relaunch; the observer anchor persists immediately while the
        // snapshot save is debounced), then delete the app-authored Health sample by `fernlet.workoutID`.
        // Fired even for a not-yet-stamped row: if a save is still in flight the delete no-ops now and the
        // tombstone catches the sample when it lands (reconcile deletes + skips it).
        workoutTombstones.insert(id)
        Task { [weak self] in
            await self?.healthSyncCoordinator.removeWorkoutFromHealth(fernletWorkoutID: id)
        }
        return true
    }

    /// Replaces a logged workout in place (used by the edit sheet, which only exposes
    /// name/intensity/duration/notes). Provenance and timestamps the edit UI can't reach are re-asserted
    /// from the stored row so a partial edit can't drop them. Genuine Health *imports* are refused (not
    /// editable — another app owns them). A Fernlet-*authored* row IS editable — its immutable Health
    /// sample is re-synced (delete-old + save-new) so the Health copy never silently diverges from the
    /// edit. Returns `false` when the id isn't on `date` or the row is a Health import.
    @discardableResult
    func updateWorkout(_ workout: Workout, date: String) -> Bool {
        assert(!date.isEmpty, "workout date required")
        guard let existing = diary.loadDay(for: date).workouts.first(where: { $0.id == workout.id }) else { return false }
        guard !existing.isHealthImported else { return false }
        var updated = workout
        updated.plannedWorkoutID = existing.plannedWorkoutID
        updated.loggedFromGuidedSession = existing.loggedFromGuidedSession
        updated.completedAt = existing.completedAt
        updated.loggedAt = existing.loggedAt
        // A guided row's NAME is the relaunch reconciliation key (`loggedGuidedWorkoutNamesToday`) — pin it
        // so a rename can't un-key the guided card into a post-relaunch double-log, or stop a removal
        // reversal from matching. The edit sheet also disables the name field for guided rows; this is the
        // fail-closed backstop.
        if existing.loggedFromGuidedSession == true {
            updated.name = existing.name
        }

        if existing.isHealthAuthored {
            // Fernlet owns the Health sample. HKWorkouts are immutable, so reflect the edit by
            // delete-old + save-new. Clear the row's HK provenance for the re-sync window so the delete's
            // own deleted-object echo can't match — and therefore can't remove — the just-edited row; the
            // re-save re-stamps a fresh healthKitUUID + authored flag.
            updated.healthKitUUID = nil
            updated.healthKitAuthored = nil
            let replaced = diary.updateWorkout(updated, date: date)
            if replaced {
                let resyncWorkout = updated   // POST-edit values, stable id (== fernlet.workoutID)
                Task { [weak self] in
                    await self?.healthSyncCoordinator.resyncWorkoutInHealth(resyncWorkout, date: date)
                }
            }
            return replaced
        }

        // Not-yet-stamped / plain local row: carry the (nil) HK provenance straight through. If a save was
        // in flight the stamp still lands on this edited row; the Health sample then reflects the pre-edit
        // values until a later edit re-syncs it — a small, transient divergence limited to an edit within
        // the ~second-long save window right after logging.
        updated.healthKitUUID = existing.healthKitUUID
        updated.healthKitAuthored = existing.healthKitAuthored
        return diary.updateWorkout(updated, date: date)
    }

    /// Reverses `completeGuidedRunnerSession`'s bookkeeping for a removed guided-logged workout. Only
    /// meaningful for today's committed plan — the session ids and the exact progression names live
    /// there. A relaunch (fresh plan/ids) or an other-day removal has nothing to reverse against, so we
    /// leave progression untouched rather than guess (the row's removal alone un-sees its name).
    ///
    /// Two guided sessions can share a `suggestion.name` ("Push"). We clear every same-name session id
    /// (harmless: while any same-name row remains, name reconciliation still marks the session logged, so
    /// no double-log window opens until the last same-name row is gone) but decrement progression by
    /// exactly one session's worth per removal — one removed row undoes one completion.
    private func reverseGuidedCompletion(for workout: Workout, date: String) {
        guard date == todayKey, let plan = currentGuidedWorkoutPlan else { return }
        let matching = plan.sessions.filter { $0.suggestion.name == workout.name }
        guard let first = matching.first else { return }
        for session in matching { guidedCompletedSessionIDs.remove(session.id) }
        diary.decrementCompletedExercises(first.catalogExerciseNames)
    }

    /// Best-effort reverse of `PlannedWorkout.completedWorkout`, rebuilding the planned row a completion
    /// consumed. The `Workout` carries these exactly: plannedWorkoutID (→ preserved planned id),
    /// name, mode, activityType, exercises, muscleGroups, duration, distance/energy/effort targets.
    /// Lossy fields it can't carry are approximated: `split` collapses through `WorkoutType`
    /// (push/pull/upper all read back as `.upper`, legs/lower → `.lower`, etc.), `source` is recovered
    /// from the boilerplate completion note (else `.user`), `createdAt` is taken from the completion
    /// time, and the plan's own free-text notes are gone when the plan had exercises.
    ///
    /// Notes-vs-exercises origin is genuinely undetectable post-hoc: `PlannedWorkout.completedWorkout`
    /// folds a notes-only plan's text into `workout.exercises` (`exercises.isEmpty ? notes : exercises`),
    /// and the completed row carries no marker of which field it came from — so a restored notes-only plan
    /// reads its text back in `exercises`, not `notes`. Left as-is rather than guessed at.
    static func reconstructPlannedWorkout(from workout: Workout, plannedID: UUID) -> PlannedWorkout {
        let source: WorkoutPlanSource =
            workout.notes == WorkoutPlanSource.coach.completionNote ? .coach : .user
        return PlannedWorkout(
            id: plannedID,
            name: workout.name,
            split: Self.plannedSplit(for: workout.type),
            source: source,
            mode: workout.mode,
            activityType: workout.activityType,
            exercises: workout.exercises,
            muscleGroups: workout.muscleGroups,
            notes: "",
            duration: workout.duration,
            targetDistanceMiles: workout.distanceMiles,
            targetEnergyKcal: workout.activeEnergyKcal,
            targetEffort: workout.effort,
            createdAt: workout.completedAt
        )
    }

    /// Reverse of `WorkoutSplit.workoutType`, picking a representative split for each category. The
    /// forward map is many-to-one, so the finer split (push vs pull vs upper) can't be recovered.
    private static func plannedSplit(for type: WorkoutType) -> WorkoutSplit {
        switch type {
        case .upper, .armsBack, .mixed: return .upper
        case .lower: return .lower
        case .fullBody: return .fullBody
        case .cardio, .run, .hike: return .cardio
        }
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

    /// Whether a sealed PERIOD backup still needs re-uploading under the newly-adopted escrow key because
    /// period tracking was hidden when the key was adopted (G5). Surfaced (observably) in Privacy & Data so
    /// the stale cloud chunk is visible and can be re-uploaded after un-hiding, not silently left mismatched.
    /// PERSISTED in `StoragePreferences` (via `sealedBackupDeferralPersistHook`) so the obligation survives
    /// a relaunch; the initializer here re-publishes the persisted flag at launch.
    private(set) var sealedBackupPeriodReuploadDeferred =
        StoragePreferencesStore.currentPreferences().sealedBackupPeriodReuploadDeferred

    /// Seals + uploads (or deletes) the encrypted CloudKit backup for a payload; returns whether it
    /// succeeded. Delegates to `SealedBackupCoordinator`.
    @discardableResult
    func setSealedBackupEnabled(_ enabled: Bool, payloadType: SealedBackupPayloadType) async -> Bool {
        await sealedBackupCoordinator.setSealedBackupEnabled(enabled, payloadType: payloadType)
    }

    /// Pulls any sealed iCloud backups into the local stores at launch (and on the user's Retry, which
    /// passes `userInitiated: true` so the period half can use the targeted restore).
    /// Delegates to `SealedBackupCoordinator`.
    func restoreSealedBackupsIfNeeded(userInitiated: Bool = false) async {
        await sealedBackupCoordinator.restoreSealedBackupsIfNeeded(userInitiated: userInitiated)
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

    /// Targeted period-only restore (un-hide + explicit Retry) — the compensating restore path for the
    /// fresh-install-only launch pass. Delegates to `SealedBackupCoordinator`.
    @discardableResult
    func restorePeriodBackupTargeted(
        narrativeRepository: MenstrualNarrativeRepository? = nil
    ) async -> SealedBackupRestoreOutcome {
        await sealedBackupCoordinator.restorePeriodBackupTargeted(narrativeRepository: narrativeRepository)
    }

    /// Decodes a decrypted sealed-backup payload into the local stores, returning records written.
    /// Delegates to `SealedBackupCoordinator`; kept as a wrapper for the restore tests.
    @discardableResult
    func applyRestoredPayload(
        _ plaintext: Data,
        payloadType: SealedBackupPayloadType,
        narrativeRepository: MenstrualNarrativeRepository? = nil,
        scope: SealedBackupCoordinator.RestoreScope = .freshInstall
    ) throws -> Int {
        try sealedBackupCoordinator.applyRestoredPayload(
            plaintext,
            payloadType: payloadType,
            narrativeRepository: narrativeRepository,
            scope: scope
        )
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

    // MARK: Guided workout — shared session state (in-memory, session-scoped; NEVER persisted)

    /// Today's committed guided-workout plan, shared by the Move-root "Start today's workout" card and
    /// the Suggest sheet. The domain mints a *fresh* `SessionSuggestion.id` on every generation, so a
    /// completed-id set is only meaningful against one plan instance — sharing that instance (not just
    /// the id set) is what lets a session guided to completion from either entry point be excluded from
    /// re-running and "Mark done" in both. Not persisted: a fresh app run rebuilds it; a new day
    /// discards it. Kept observable so both surfaces re-render the moment it's committed or replaced.
    private var guidedPlanStorage: WorkoutProgram.DayPlan?
    /// The day `guidedPlanStorage` was generated for; a rollover makes the cached plan stale.
    @ObservationIgnored private var guidedPlanDayKey: String?
    /// The intensity `guidedPlanStorage` was committed with. Recorded so EVERY logging site for the
    /// committed plan (the Move-root card's guided runner, the Suggest sheet's "Mark done", and the
    /// Suggest sheet's own guided runner) logs the intensity the plan was actually *built* with, rather
    /// than re-deriving from readiness at tap time — which drifts across the day, so a plan committed at
    /// `.hard` could be logged as `.moderate`/`.light`. Session-scoped like the plan; reads through as
    /// nil after a rollover.
    @ObservationIgnored private var committedGuidedIntensityStorage: WorkoutIntensity?

    /// Sessions already logged today through the guided runner *or* the retroactive "Mark done" path —
    /// both mean "this session's workout is now logged; don't log it again." Cleared when a fresh plan
    /// is committed (a new day). Observable so a completion updates the card and the sheet at once.
    private(set) var guidedCompletedSessionIDs: Set<UUID> = []

    /// The committed plan iff it belongs to today; a day rollover reads through as nil.
    var currentGuidedWorkoutPlan: WorkoutProgram.DayPlan? {
        guidedPlanDayKey == todayKey ? guidedPlanStorage : nil
    }

    /// The intensity today's committed plan was built with, iff the plan belongs to today. Every site
    /// that logs a session of the committed plan reads this so the logged intensity matches the plan.
    var committedGuidedIntensity: WorkoutIntensity? {
        guidedPlanDayKey == todayKey ? committedGuidedIntensityStorage : nil
    }

    /// Names of GUIDED-logged workouts already in today's record. The reconciliation seam behind the
    /// guided card: a guided session's workout is logged with its `suggestion.name` AND tagged
    /// `loggedFromGuidedSession`, so a guided session whose name is present here counts as done — even
    /// after a routine relaunch minted the plan with fresh session ids and started
    /// `guidedCompletedSessionIDs` empty. Only tagged rows count: a manual Log-sheet entry or a planned
    /// completion that happens to share a guided session's name ("Legs", "Push") must NOT make the
    /// guided flow claim itself done or refuse a rework. The guided log itself carries the tag, so the
    /// relaunch double-log protection still holds. Observable via `day`.
    var loggedGuidedWorkoutNamesToday: Set<String> {
        Set(day.workouts.filter { $0.loggedFromGuidedSession == true }.map(\.name))
    }

    /// Maps the derived intensity-readiness signal to a recommended workout intensity, if present.
    /// Shared by the card (to pick a start intensity) and the Suggest sheet (its readiness note).
    func recommendedWorkoutIntensity() -> WorkoutIntensity? {
        guard let r = derivedSignals.first(where: { $0.signalName == "intensityReadiness" }) else { return nil }
        switch r.value {
        case "ready for hard": return .hard
        case "ready for light": return .light
        case "ready for moderate": return .moderate
        default: return nil
        }
    }

    /// Generates today's plan *without committing it* — for the Move-root card to read availability
    /// (guidable vs rest / cardio-only) before the user commits to anything. Plan *content* is
    /// deterministic, so this yields the same availability the committed plan will have; only the
    /// ephemeral session UUIDs differ, which is why the card must re-resolve against the committed
    /// plan on tap rather than trusting a preview's id.
    func previewTodaysGuidedWorkoutPlan(intensity: WorkoutIntensity) -> WorkoutProgram.DayPlan {
        currentGuidedWorkoutPlan ?? workoutDayPlan(intensity: intensity, context: "")
    }

    /// Commits today's plan (generating it once if today has none yet) and returns it — used when the
    /// user actually starts, from the card or from the Suggest sheet's "Suggest" button. A same-day
    /// call reuses the committed instance so its session IDs and any completions survive; only a new
    /// day (re)generates and clears the completed-session set.
    @discardableResult
    func commitTodaysGuidedWorkoutPlan(intensity: WorkoutIntensity, context: String = "") -> WorkoutProgram.DayPlan {
        if let plan = currentGuidedWorkoutPlan { return plan }
        let plan = workoutDayPlan(intensity: intensity, context: context)
        guidedPlanStorage = plan
        guidedPlanDayKey = todayKey
        committedGuidedIntensityStorage = intensity
        guidedCompletedSessionIDs = []
        // A freshly generated plan is not yet approved — the user reviews it in the Suggest sheet and
        // taps "Approve workout" (or starts it) to surface the Move-root card.
        guidedPlanApprovedDayKey = nil
        return plan
    }

    /// Whether today's committed plan can still be reworked back into the configurator. True only while
    /// NOTHING of it has been logged — neither through the in-memory completed set, nor (after a
    /// relaunch) as a matching workout already in today's day record. Once anything is logged the plan
    /// is pinned, because reworking it would orphan a logged session's place in the plan.
    var canReworkTodaysGuidedPlan: Bool {
        guard let plan = currentGuidedWorkoutPlan, guidedCompletedSessionIDs.isEmpty else { return false }
        let logged = loggedGuidedWorkoutNamesToday
        return !plan.sessions.contains { logged.contains($0.suggestion.name) }
    }

    /// Clears today's committed guided plan so the Suggest sheet falls back to its configurator
    /// (intensity chips, context, and the "Equipment & limits" entry). Refuses — returns false, changes
    /// nothing — once any session has been completed or logged, so a rework can never orphan an
    /// already-counted session. This restores pre-refactor reachability: a plan committed by an
    /// exploratory tap is no longer an irreversible same-day pin.
    @discardableResult
    func reworkTodaysGuidedPlan() -> Bool {
        guard canReworkTodaysGuidedPlan else { return false }
        guidedPlanStorage = nil
        guidedPlanDayKey = nil
        committedGuidedIntensityStorage = nil
        guidedCompletedSessionIDs = []
        guidedPlanApprovedDayKey = nil
        return true
    }

    /// Replaces today's committed plan in place with an AI-adjusted version (an adjustment keeps each
    /// `SessionSuggestion.id`, so completions stay valid — do NOT clear them here). Guarded twice:
    /// (1) the plan must still belong to today, so an adjustment resolving *after* a day rollover can't
    /// resurrect yesterday's plan as today's; and (2) the currently committed plan must still be the
    /// SAME plan the adjustment started from, identified by `baseSessionIDs` — the base plan's
    /// session-id set, which an adjustment preserves but a rework-and-recommit replaces with fresh ids.
    /// Without (2) an adjustment kicked off against P1 could clobber a P2 the user reworked-and-committed
    /// while it was in flight (wrong content, wrong ids, wrong intensity).
    func replaceGuidedWorkoutPlan(_ plan: WorkoutProgram.DayPlan, replacing baseSessionIDs: Set<UUID>) {
        guard guidedPlanDayKey == todayKey else { return }
        guard let current = guidedPlanStorage,
              Set(current.sessions.map(\.id)) == baseSessionIDs else { return }
        guidedPlanStorage = plan
    }

    /// Logs a session of the committed guided plan as done from the guided RUNNER — the Move-root card's
    /// runner or the Suggest sheet's in-flow runner. The completion belongs to the day (and the
    /// intensity) the plan was COMMITTED with, not "today": a rest between sets can cross local midnight
    /// while the runner sheet is open, and filing under the rolled-over day would (a) land the workout on
    /// the wrong day at a re-derived `.moderate`, and (b) leave the weekday-aliased next-day session
    /// reading `.allComplete` all day. So it anchors to `guidedPlanDayKey`/`committedGuidedIntensityStorage`
    /// (read directly, NOT through the today-gated `committedGuidedIntensity`), tags the row so name
    /// reconciliation only matches the guided flow's own logs, advances progression, and records the
    /// completion. The retroactive "Mark done" path stays today-anchored (it's only reachable while the
    /// plan is today's) and logs inline.
    func completeGuidedRunnerSession(_ session: WorkoutProgram.SessionSuggestion) {
        let dayKey = guidedPlanDayKey ?? todayKey
        let intensity = committedGuidedIntensityStorage ?? .moderate
        var workout = session.workout(intensity: intensity, loggedFromGuidedSession: true)
        // When the completion lands on an earlier day than today (a midnight-crossing rest), anchor its
        // timestamps to that day (noon) too, so they match the day bucket it's filed under — the same
        // back-dating `completePlannedWorkout` uses for a past-dated completion.
        if dayKey != todayKey,
           let targetDate = FernletDate.date(fromDayKey: dayKey),
           let completedAt = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: targetDate) {
            workout.completedAt = completedAt
            workout.loggedAt = completedAt
        }
        addWorkout(workout, date: dayKey)
        recordCompletedExercises(session.catalogExerciseNames)
        markGuidedSessionCompleted(session.id)
    }

    /// Records that a session's workout was logged today (guided runner or "Mark done"), excluding it
    /// from any further guided run or logging in either surface.
    func markGuidedSessionCompleted(_ id: UUID) {
        guidedCompletedSessionIDs.insert(id)
    }

    // MARK: Guided workout — approval gate (the Move-root "Today's workout" card)

    /// The day today's committed plan was APPROVED for. Distinct from "committed": tapping Suggest
    /// commits a plan so the sheet can show/edit/run it, but the Move-root "Today's workout" card only
    /// appears once the user explicitly approves it (or starts it) — so a plan the user generated to
    /// look at, then closed, doesn't silently become "today's workout". Observable so the card shows
    /// the moment approval lands; a rollover reads through as unapproved.
    private(set) var guidedPlanApprovedDayKey: String?

    /// Whether today's committed plan has been approved (or started) — the card's visibility gate.
    var isTodaysGuidedPlanApproved: Bool {
        guidedPlanApprovedDayKey == todayKey && currentGuidedWorkoutPlan != nil
    }

    /// Approve today's committed plan so the Move-root card surfaces it. Committing first (if needed)
    /// is the caller's job; this only flips the approval gate.
    func approveTodaysGuidedPlan() {
        guard currentGuidedWorkoutPlan != nil else { return }
        guidedPlanApprovedDayKey = todayKey
    }

    /// Replace one session of today's committed plan with an edited version from the in-app editor,
    /// preserving its `SessionSuggestion.id` so completions/dedup stay valid. Allowed only while nothing
    /// of the plan is logged (same guard as rework) — editing after a session started would orphan a
    /// logged place in the plan. Returns false (changing nothing) otherwise.
    @discardableResult
    func updateGuidedSession(_ updated: WorkoutProgram.SessionSuggestion) -> Bool {
        guard var plan = currentGuidedWorkoutPlan, canReworkTodaysGuidedPlan,
              let index = plan.sessions.firstIndex(where: { $0.id == updated.id }) else { return false }
        plan.sessions[index] = updated
        guidedPlanStorage = plan
        return true
    }

    // MARK: Guided workout — the active run (mirrored to the app group for the Live Activity buttons)

    /// The in-progress guided run, or nil when none is active. Mirrored into the app-group container
    /// (`guidedRunStateStore`) so the interactive Live Activity buttons ("Done set" / "Skip rest")
    /// can advance it from the Lock Screen — even after the app is suspended or terminated. Observable
    /// so the guided sheet and card reflect every transition, whether it came from the in-app buttons
    /// or the Lock Screen. Session-scoped; never part of the synced blob.
    private(set) var guidedRunState: GuidedWorkoutRunState?
    @ObservationIgnored private let guidedRunStateStore = GuidedWorkoutRunStateStore()
    /// Serializes Live Activity update/end calls so two rapid transitions can't land out of order.
    @ObservationIgnored private var activitySyncTask: Task<Void, Never>?

    private static func roleRaw(_ role: SlotRole) -> String {
        switch role {
        case .main: "main"
        case .accessory: "accessory"
        case .core: "core"
        }
    }

    private static func role(fromRaw raw: String) -> SlotRole {
        switch raw {
        case "main": .main
        case "core": .core
        default: .accessory
        }
    }

    /// Chain a Live Activity op after the previous one so update/end calls stay ordered on screen.
    private func syncActivity(_ op: @escaping @Sendable () async -> Void) {
        let previous = activitySyncTask
        activitySyncTask = Task { await previous?.value; await op() }
    }

    /// Reconstruct a `SessionSuggestion` from the active run so the guided sheet can RESUME it after a
    /// cold launch, when the committed plan (in-memory, session-scoped) is gone. Carries the run's own
    /// `sessionID` (so the sheet's `run` match holds) and its baked per-exercise rests (as overrides).
    func guidedSessionForResume() -> WorkoutProgram.SessionSuggestion? {
        guard let s = guidedRunState, !s.isDone else { return nil }
        let prescribed = s.exercises.map {
            PrescribedExercise(
                id: $0.id, name: $0.name, sets: $0.sets, reps: $0.reps,
                role: Self.role(fromRaw: $0.roleRaw), fromCatalog: $0.fromCatalog,
                restSecondsOverride: $0.restSeconds
            )
        }
        return WorkoutProgram.SessionSuggestion(
            id: s.sessionID, title: s.title, timeLabel: "",
            kind: SessionKind(rawValue: s.sessionKindRaw) ?? .fullBody,
            exercises: prescribed,
            suggestion: WorkoutSuggestion(name: s.title, exercises: s.suggestionExercisesText, notes: s.suggestionNotes)
        )
    }

    /// The unfinished run that starting `session` would displace — i.e. a live run belonging to a
    /// DIFFERENT session. Nil when there is no run, when the run IS this session (that's a resume, and
    /// the sheet renders it instead of the Ready screen), or when it has already finished. The Ready
    /// screen asks this before starting so it can confirm rather than discard someone's sets.
    func activeGuidedRunBlockingStart(of session: WorkoutProgram.SessionSuggestion) -> GuidedWorkoutRunState? {
        guard let state = guidedRunState, !state.isDone, state.sessionID != session.id else { return nil }
        return state
    }

    /// Begin guiding a session set-by-set. Builds the run from the plan's committed day/intensity,
    /// baking each exercise's rest (per-exercise override, else the research-based default), mirrors it
    /// to the app group, and requests the Live Activity. A pure cardio/mobility session (no set-based
    /// exercises) is a no-op — the guidable filter keeps those off this path.
    ///
    /// Fails closed on a live run for a different session: after a relaunch the committed plan is gone,
    /// so a user can walk past the Resume card into the configurator and mint a fresh session, and this
    /// would otherwise overwrite the in-progress run — state, app-group mirror and Live Activity — with
    /// no prompt. `replacingActiveRun` is the caller's word that the user was asked and said yes.
    /// Returns whether the run actually started.
    @discardableResult
    func startGuidedRun(_ session: WorkoutProgram.SessionSuggestion, replacingActiveRun: Bool = false) -> Bool {
        guard replacingActiveRun || activeGuidedRunBlockingStart(of: session) == nil else { return false }
        let dayKey = guidedPlanDayKey ?? todayKey
        let intensity = committedGuidedIntensityStorage ?? recommendedWorkoutIntensity() ?? .moderate
        let goal = settings.selectedGoal
        let exercises = session.exercises.map { pe in
            GuidedWorkoutRunState.Exercise(
                id: pe.id,
                name: pe.name,
                sets: pe.sets,
                reps: pe.reps,
                roleRaw: Self.roleRaw(pe.role),
                fromCatalog: pe.fromCatalog,
                restSeconds: pe.restSecondsOverride
                    ?? WorkoutRestGuidance.restSeconds(forExerciseNamed: pe.name, role: pe.role, goal: goal)
            )
        }
        guard !exercises.isEmpty else { return false }

        var state = GuidedWorkoutRunState(
            sessionID: session.id,
            committedDayKey: dayKey,
            intensityRaw: intensity.rawValue,
            title: session.suggestion.name,
            suggestionExercisesText: session.suggestion.exercises,
            suggestionNotes: session.suggestion.notes,
            sessionKindRaw: session.kind.rawValue,
            exercises: exercises
        )
        state.phase = .working
        guidedRunState = state
        guidedRunStateStore.write(state)
        WorkoutLiveActivityController.start(state)
        return true
    }

    /// Mark the current set done from the in-app sheet (mirrors the Live Activity "Done set" button):
    /// advance the runner, mirror it, and reflect it onto the activity — finishing (and logging) when
    /// the last set of the last exercise is done.
    func guidedMarkSetDone() {
        guard var state = guidedRunState, state.phase == .working else { return }
        state.markSetDone(now: Date())
        applyGuidedTransition(state)
    }

    /// End the current rest early from the in-app sheet (mirrors the Live Activity "Skip rest" button).
    func guidedSkipRest() {
        guard var state = guidedRunState, state.phase == .resting else { return }
        state.skipRest()
        applyGuidedTransition(state)
    }

    /// Shared handling after an in-app transition: mirror to the group + reflect onto the activity;
    /// on a natural finish, log the workout (deduped) and end the activity; keep the done state in
    /// memory so the sheet can show its "nicely done" screen.
    private func applyGuidedTransition(_ state: GuidedWorkoutRunState) {
        guidedRunState = state
        if state.isDone {
            // Clear the group file first so a foreground reconcile racing this can't re-log the finish.
            guidedRunStateStore.clear()
            if state.completedNaturally { finishGuidedRunLogging(state) }
            syncActivity { await GuidedWorkoutActivityBridge.end() }
        } else {
            guidedRunStateStore.write(state)
            syncActivity { await GuidedWorkoutActivityBridge.sync(to: state) }
        }
    }

    /// Abandon the active run (the sheet's "End without logging"): nothing is logged. Clears the group
    /// file and ends the activity.
    func abandonGuidedRun() {
        guard guidedRunState != nil else { return }
        guidedRunState = nil
        guidedRunStateStore.clear()
        syncActivity { await GuidedWorkoutActivityBridge.end() }
    }

    /// Clear a finished run once the user closes the done screen (the activity was already ended on
    /// finish).
    func clearGuidedRun() {
        guidedRunState = nil
        guidedRunStateStore.clear()
    }

    /// Reconcile the in-memory run with the app-group file — call on foreground and at launch so a
    /// finish or advance made entirely from the Live Activity is picked up. A natural finish is logged
    /// (deduped) and cleared; a live active run (including one whose rest crossed local midnight) is
    /// adopted so the sheet/card resume it; a run the process merely outlived (untouched for hours) is
    /// retired. When there is no run at all, any activity still on screen is retired.
    func reconcileGuidedRunFromAppGroup() {
        guard let fileState = guidedRunStateStore.read() else {
            // No backing run: retire any activity left on screen (an in-app finish whose immediate
            // end() didn't land, or an orphan from a prior build). No-op when nothing is live.
            syncActivity { await GuidedWorkoutActivityBridge.end() }
            return
        }
        if fileState.isDone {
            // Clear the file BEFORE logging so a crash mid-log can't re-log the finish on the next
            // launch (mirrors the in-app finish path; a lost log beats a duplicate).
            guidedRunStateStore.clear()
            guidedRunState = fileState.completedNaturally ? fileState : nil
            if fileState.completedNaturally { finishGuidedRunLogging(fileState) }
            syncActivity { await GuidedWorkoutActivityBridge.end() }
            return
        }
        // Active run. Retire only one untouched for hours (abandoned — the process outlived it); a
        // recently-touched run, even one resting across midnight, is adopted so it stays resumable.
        if Date().timeIntervalSince(fileState.updatedAt) > GuidedWorkoutRunState.abandonedAfter {
            guidedRunState = nil
            guidedRunStateStore.clear()
            syncActivity { await GuidedWorkoutActivityBridge.end() }
            return
        }
        guidedRunState = fileState
    }

    /// Log a finished guided run from its run state (works even after a cold launch, when the domain
    /// plan is gone). Anchors the logged workout to the day/intensity the plan was committed with — a
    /// rest can cross local midnight — tags it as a guided log, advances progression, and records the
    /// completion. Deduped by session id so a finish seen by both the sheet and a reconcile logs once.
    private func finishGuidedRunLogging(_ state: GuidedWorkoutRunState) {
        guard !guidedCompletedSessionIDs.contains(state.sessionID) else { return }
        let dayKey = state.committedDayKey
        // Durable same-day backstop: after a relaunch the in-memory completed set is empty, but a
        // guided log already in today's record (tagged with this name) means it's done — don't re-log.
        if dayKey == todayKey && loggedGuidedWorkoutNamesToday.contains(state.title) { return }
        let intensity = WorkoutIntensity(rawValue: state.intensityRaw) ?? .moderate
        let kind = SessionKind(rawValue: state.sessionKindRaw) ?? .fullBody
        let mode: WorkoutMode = (kind == .strength || kind == .fullBody) ? .strengthTraining : .activity
        let type: WorkoutType = (kind == .cardio) ? .cardio : .fullBody
        var workout = Workout(
            name: state.title, type: type, mode: mode, exercises: state.suggestionExercisesText,
            rpe: nil, notes: state.suggestionNotes, duration: nil,
            loggedFromGuidedSession: true, intensity: intensity
        )
        if dayKey != todayKey,
           let targetDate = FernletDate.date(fromDayKey: dayKey),
           let completedAt = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: targetDate) {
            workout.completedAt = completedAt
            workout.loggedAt = completedAt
        }
        addWorkout(workout, date: dayKey)
        recordCompletedExercises(state.exercises.filter { $0.fromCatalog }.map(\.name))
        markGuidedSessionCompleted(state.sessionID)
    }

    // MARK: Cooking mode — the active run (mirrored to the app group for the Live Activity + Siri)

    /// The in-progress cooking session, or nil when none is active. Mirrored into the app-group
    /// container (`cookingRunStateStore`) so the interactive Live Activity "Next" button — and the Siri
    /// "next step" / "repeat step" intents — can advance the recipe walker from the Lock Screen, even
    /// after the app is suspended or terminated. Observable so the cooking walker and the Food-root
    /// resume card reflect every transition, whether it came from the in-app buttons or the Live
    /// Activity. Session-scoped; never part of the synced blob. Directly mirrors `guidedRunState`.
    private(set) var cookingRunState: CookingRunState?
    // `var` (not `let`) so a test can point the app-group cooking file at a per-test temp directory via
    // the `cookingRunDirectory:` init override, mirroring the `GuidedWorkoutRunStateStore(directory:)`
    // seam. Production leaves this at the default (the real app-group container). Isolating the file per
    // test stops a parallel suite's `deleteAllData`/cooking-wipe from racing the shared real file.
    @ObservationIgnored private var cookingRunStateStore = CookingRunStateStore()
    /// Observer token for `.cookingRunAdvancedByIntent` — registered once in `activateWidgetBridge`. A
    /// cooking App Intent (Live Activity / Siri) runs in this process but mutates only the app-group file;
    /// this brings the in-memory walker into step the moment the file is written, so an in-app "Next"
    /// can't land on stale state and clobber the intent's advance while the app is foregrounded.
    @ObservationIgnored private var cookingIntentObserver: NSObjectProtocol?

    /// Begin cooking a recipe step-by-step. Builds the run from the recipe's ordered steps, anchors it
    /// to the day the cook began (a long session can cross local midnight), mirrors it to the app group,
    /// and requests the Live Activity. Replaces any cooking run already in progress (ending only the
    /// cooking activity — a live WORKOUT activity is a different type and is left untouched). A recipe
    /// with no steps is a no-op (the mise-only flow never enters the walker). Returns the run started.
    @discardableResult
    func startCookingRun(_ recipe: RecipeDefinition, startDayKey: String? = nil) -> CookingRunState? {
        let domainSteps = recipe.steps ?? []
        guard !domainSteps.isEmpty else { return nil }
        let steps = domainSteps.map { CookingRunState.Step(text: $0.text, durationSeconds: $0.durationSeconds) }
        let state = CookingRunState(
            recipeID: recipe.id,
            recipeName: recipe.name,
            startedDayKey: startDayKey ?? todayKey,
            steps: steps
        )
        cookingRunState = state
        cookingRunStateStore.write(state)
        CookingLiveActivityController.start(state)
        return state
    }

    /// Advance to the next step (or finish) from the in-app walker — mirrors the Live Activity "Next"
    /// button and the "next step" Siri intent.
    func cookingAdvanceStep() {
        guard var state = cookingRunState, !state.isFinished else { return }
        state.advance()
        applyCookingTransition(state)
    }

    /// Step back one step from the in-app walker (clamped at step 0).
    func cookingGoBack() {
        guard var state = cookingRunState, !state.isFinished else { return }
        state.goBack()
        applyCookingTransition(state)
    }

    /// Start (or restart, via the "repeat step" intent / in-app "Start timer") the current step's
    /// passive timer, mirroring the window into the app group so the Live Activity renders the countdown.
    func cookingStartTimer() {
        guard var state = cookingRunState, !state.isFinished else { return }
        state.startTimer(now: Date())
        applyCookingTransition(state)
    }

    /// Clear the current step's timer (in-app "Reset timer") — the Live Activity drops the countdown.
    func cookingClearTimer() {
        guard var state = cookingRunState, !state.isFinished else { return }
        state.clearTimer()
        applyCookingTransition(state)
    }

    /// Shared handling after an in-app cooking transition: mirror to the group + reflect onto the
    /// activity. On a finish the group file is cleared FIRST (so a racing foreground reconcile can't
    /// resurrect a done run) and the activity ended; the in-memory state is kept so the walker can show
    /// its finish screen. There is no automatic meal log — logging is the cook's explicit choice.
    private func applyCookingTransition(_ state: CookingRunState) {
        cookingRunState = state
        if state.isFinished {
            cookingRunStateStore.clear()
            syncActivity { await CookingActivityBridge.end() }
        } else {
            cookingRunStateStore.write(state)
            syncActivity { await CookingActivityBridge.sync(to: state) }
        }
    }

    /// End the active cooking run (the walker's Close, a completed-and-logged session, or the resume
    /// card's Discard). Clears the group file and ends the cooking activity. Idempotent.
    func endCookingRun() {
        guard cookingRunState != nil else {
            // No in-memory run, but a group file (or orphan activity) may linger after a cold path.
            cookingRunStateStore.clear()
            syncActivity { await CookingActivityBridge.end() }
            return
        }
        cookingRunState = nil
        cookingRunStateStore.clear()
        syncActivity { await CookingActivityBridge.end() }
    }

    /// Reconcile the in-memory cooking run with the app-group file — call on foreground and at launch so
    /// a step advance made entirely from the Live Activity / Siri is picked up, and so a resume card can
    /// appear after a cold launch. A finished run is retired (cleared + activity ended — cooking never
    /// auto-logs); a recently-touched active run is adopted so the walker/card resume it; a run the
    /// process merely outlived (untouched for hours) is retired. No file at all → retire any orphan
    /// activity. Mirrors `reconcileGuidedRunFromAppGroup`.
    func reconcileCookingRunFromAppGroup() {
        guard let fileState = cookingRunStateStore.read() else {
            syncActivity { await CookingActivityBridge.end() }
            return
        }
        if fileState.isFinished {
            // Clear the file BEFORE anything else so a crash can't re-surface a done run (mirrors the
            // guided finish path; a lost log beats a duplicate — though cooking's log is never automatic).
            cookingRunStateStore.clear()
            // ADOPT the finished state (don't nil it) — exactly as the guided path keeps a completed run
            // so the sheet can show its done screen. A Finish tapped from the Live Activity / Siri while
            // the walker is foregrounded must land the cook on the finish/log screen (via
            // `syncStageWithRun`), not `dismiss()` it: nil-ing here strands the meal-type/log step and,
            // with it, the run's authoritative `startedDayKey` (a wrong day after a midnight rollover).
            // The finished run is retired when the finish screen closes/logs (`endCookingRun`); the
            // Food-root resume card is gated on `!isFinished`, so this never resurrects a resume card.
            cookingRunState = fileState
            syncActivity { await CookingActivityBridge.end() }
            return
        }
        if Date().timeIntervalSince(fileState.updatedAt) > CookingRunState.abandonedAfter {
            cookingRunState = nil
            cookingRunStateStore.clear()
            syncActivity { await CookingActivityBridge.end() }
            return
        }
        cookingRunState = fileState
    }

    /// The RecipeDefinition an active cooking run refers to, resolved across the manual recipe book and
    /// the saved/web recipes so the Food-root resume card can re-open cooking mode. Nil when the recipe
    /// was deleted while the run outlived it — the card then only offers Discard.
    func recipeForActiveCookingRun() -> RecipeDefinition? {
        guard let id = cookingRunState?.recipeID else { return nil }
        return recipes.first { $0.id == id } ?? savedRecipes.first { $0.id == id }
    }

    /// Whether the active cooking run's recipe is a saved/web recipe (logs via `logSavedRecipe`) rather
    /// than a manual one (logs via `logRecipe`). Nil when there is no run or its recipe is gone.
    func activeCookingRunIsSavedRecipe() -> Bool? {
        guard let id = cookingRunState?.recipeID else { return nil }
        if recipes.contains(where: { $0.id == id }) { return false }
        if savedRecipes.contains(where: { $0.id == id }) { return true }
        return nil
    }

    func completeOnboarding(profile: UserNutritionProfile, preferences: UserNutritionPreferences, goal: GoalType) {
        diary.completeOnboarding(profile: profile, preferences: preferences, goal: goal)
        // Onboarding is the fresh-install visibility determination point (the migration marker is
        // stamped inside `DiaryStore.completeOnboarding`). Record it in the device-local sidecar too,
        // so a later mixed-version key-drop re-asserts this state instead of re-running the pin.
        recordSensitiveVisibilityResolution()
    }

    @discardableResult func addRecipe(name: String, servings: Int, notes: String = "", ingredients inputIngredients: [ManualRecipeIngredientInput], steps: [RecipeStep]? = nil) -> RecipeDefinition {
        diary.addRecipe(name: name, servings: servings, notes: notes, ingredients: inputIngredients, steps: steps)
    }

    // `steps` is REQUIRED (no default) — see the note on `DiaryStore.updateRecipe`: the stored steps are
    // overwritten unconditionally, so a defaulted-nil would silently erase them.
    func updateRecipe(_ recipe: RecipeDefinition, name: String, servings: Int, notes: String = "", ingredients inputIngredients: [ManualRecipeIngredientInput], steps: [RecipeStep]?) {
        diary.updateRecipe(recipe, name: name, servings: servings, notes: notes, ingredients: inputIngredients, steps: steps)
    }

    // MARK: - F4 ingredient substitution (fork on explicit save; decision §11.4)

    /// The numbered catalog candidate pool a substitution is chosen from — the same seam the meal
    /// resolver uses (`FoodCatalog.candidates`), seeded here with the name of the ingredient being
    /// replaced. Numbered so the model can pick BY NUMBER and code binds; never a source of quantities.
    func substitutionCandidates(forIngredientNamed name: String, limit: Int = 12) -> [FoodSelectionCandidate] {
        foodCatalog.candidates(for: name, limit: limit)
    }

    /// On-device AI substitution suggestions (standard tier, USER-INVOKED), routed through the shipped
    /// `aiGate`. The model proposes substitute food NAMES from world knowledge; each is rebound here
    /// through the local catalog (`foodCatalog.candidates(for:)`) — CODE supplies the real `FoodItem` +
    /// its macros, the model never does. Returns `nil` when AI didn't run (off / resting / incapable) or
    /// no proposed name resolved — the sheet then shows only its always-present manual catalog-search
    /// list (the deterministic path). `foodCatalog` is thread-safe (`@unchecked Sendable`), so the
    /// resolver is safe to invoke off the main actor from inside the model stage.
    func aiSubstitutionSuggestions(
        recipeName: String,
        ingredientName: String
    ) async -> [IngredientSubstitutionSuggestion]? {
        let payload = IngredientSubstitutionPayload(
            recipeName: recipeName,
            ingredientToReplace: ingredientName
        )
        let catalog = foodCatalog
        return (try? await FoundationIngredientSubstitutionModel.suggest(
            payload,
            gate: aiGate,
            resolve: { catalog.candidates(for: $0, limit: 3) }
        )) ?? nil
    }

    /// Persists an F4 substitution FORK for a BLOB (manual) recipe — the source lives in `diary.recipes`,
    /// so the fork does too. The source recipe is untouched; the fork carries `parentRecipeID`. Called
    /// only on explicit user save from the substitution preview.
    func addForkedRecipe(_ recipe: RecipeDefinition) {
        diary.insertRecipe(recipe)
    }

    /// Persists an F4 substitution FORK for a SAVED (Core Data / `SavedRecipeRecord`) recipe, so the fork
    /// lands in the same store as its source. Only reachable for a structured saved recipe (web imports
    /// have no structured ingredients to swap, so the swap affordance never appears for them).
    ///
    /// NOTE (forward plumbing, currently unexercised — review 2026-07-25 #5): every writer into
    /// `savedRecipeService` today produces a web-import (`webImport != nil`), and Swap is gated on
    /// `RecipeScaling.isScalable`, which requires `webImport == nil`. So no saved recipe is swappable yet
    /// and this path never runs in production. It stays as ready plumbing for the first structured
    /// (payloadData) saved-recipe feature; that feature is the one to add saved-fork persistence coverage.
    func addForkedSavedRecipe(_ recipe: RecipeDefinition) {
        savedRecipeService.add(recipe)
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
        // The recipe's own photo is keyed by the recipe id, so it's cleaned up here rather than stranded.
        recipePhotoStore.delete(id: recipe.id)
    }

    // MARK: - Recipe photos (#1 — the user's OWN photo of a recipe, keyed by the recipe id)

    func recipePhotoData(for recipeID: UUID) -> Data? {
        recipePhotoStore.imageData(for: recipeID)
    }

    func deleteRecipePhoto(for recipeID: UUID) {
        recipePhotoStore.delete(id: recipeID)
    }

    #if canImport(UIKit)
    /// Seals the user's own photo for a recipe (no external fetch — see the tester decision). Keyed by
    /// the recipe id so there's no separate id to thread through `RecipeDefinition`.
    @discardableResult func saveRecipePhoto(_ image: UIImage, for recipeID: UUID) -> Bool {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return false }
        return recipePhotoStore.save(data, forID: recipeID)
    }
    #endif

    /// Library-pick entry point mirroring `addProgressPhoto(data:)`: seals the picked JPEG `Data` straight
    /// through the store's bounded ImageIO downscale, so a full-resolution library pick isn't decoded into
    /// a giant bitmap just to be re-encoded. Fail-closed (false on non-image bytes or no key).
    @discardableResult func saveRecipePhoto(data: Data, for recipeID: UUID) -> Bool {
        recipePhotoStore.save(data, forID: recipeID)
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

    @discardableResult func importProximityRecipeShare(_ payload: ProximityRecipeSharePayload,
                                                       fromFingerprint fingerprint: String? = nil) throws -> String {
        guard payload.format == "fernlet.proximity.recipe", payload.version == 1 else {
            throw RecipeImportError.unsupportedFormat
        }

        let importedName: String
        switch payload.recipe.kind {
        case .local:
            guard let localPayload = payload.recipe.local else { throw RecipeImportError.invalidPayload }
            let data = try JSONEncoder().encode(localPayload)
            guard let text = String(data: data, encoding: .utf8) else { throw RecipeImportError.invalidPayload }
            importedName = try importRecipe(from: text).name
        case .saved:
            guard let savedPayload = payload.recipe.saved else {
                throw RecipeImportError.invalidPayload
            }
            let trimmedName = savedPayload.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { throw RecipeImportError.emptyRecipe }
            // Sanitize the shared source link in place rather than rejecting the whole recipe (matching how
            // the name/summary are trimmed above). A peer can send any string here — a file:///, javascript:,
            // tel:, or schemeless value would later crash the in-app Safari sheet (SFSafariViewController
            // only accepts http/https). Anything that isn't a real web link is blanked to "no source"; an
            // empty/absent string was always allowed and stays allowed.
            let sanitizedSourceURLString: String = {
                let trimmed = savedPayload.sourceURLString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let url = URL(string: trimmed),
                      url.isSafariPresentable else { return "" }
                return trimmed
            }()
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
                    sourceURLString: sanitizedSourceURLString,
                    ingredientLines: savedPayload.ingredients,
                    macros: Macros(
                        protein: max(savedPayload.protein, 0),
                        carbs: max(savedPayload.carbs, 0),
                        fat: max(savedPayload.fat, 0)
                    ),
                    micronutrients: savedPayload.micronutrients
                ),
                // F5: preserve ordered cooking steps a peer sent (nil on older peers that carry none).
                steps: Self.sanitizedSharedSteps(savedPayload.steps)
            )
            addSavedRecipe(recipe)
            importedName = recipe.name
        }
        // Accepting a friend's shared recipe feeds the closeness "share accepted" signal (day-capped).
        if let fingerprint { closenessLedger.recordShareAccepted(fingerprint: fingerprint) }
        return importedName
    }

    /// Normalizes cooking steps arriving over a share/mesh wire (F5) via the shared domain sanitizer:
    /// trims text, drops blank steps, clamps a non-positive duration to nil, and yields nil when nothing
    /// survives — so a peer that sent no (or only empty) steps produces a stepless recipe, not an empty `[]`.
    static func sanitizedSharedSteps(_ steps: [RecipeStep]?) -> [RecipeStep]? {
        RecipeStepSanitizer.sanitized(steps)
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
                updatedAt: now,
                // F5: preserve ordered cooking steps a peer sent (nil on older peers that carry none).
                steps: Self.sanitizedSharedSteps(payload.steps)
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
        // Consume only meal-payload records. Records of any other payloadType are left in the queue
        // untouched — the sourceId-miss clear below must never fire for a non-meal record, or the
        // first workout/recipe/daily-summary retry ever enqueued would be silently destroyed.
        guard let record = aiRetryQueueService.oldestMealRetry else { return }
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

    /// Seams for the stores `FernletStore` does not own but "delete everything" must still reach. Same
    /// shape as `worryBoxResetHook`. Wired in `ContentView`.
    ///
    /// `periodDataDeleteHook` / `intimacyDataDeleteHook` purge the sealed rows WITHOUT decrypting them,
    /// so they work while the app is locked. `healthKitSampleDeleteHook` deletes only the HealthKit
    /// samples Fernlet itself authored — no app can delete another app's samples.
    /// Each returns whether it actually cleared. `Bool` rather than `Void` because these are the most
    /// sensitive rows in the app and the confirm dialog promises they are gone — a hook that swallowed
    /// its own failure would let a wipe that left the journal behind report success.
    @ObservationIgnored var periodDataDeleteHook: (() -> Bool)?
    @ObservationIgnored var intimacyDataDeleteHook: (() -> Bool)?
    @ObservationIgnored var journalDataDeleteHook: (() -> Bool)?
    /// Returns whether the HealthKit delete cleared — and HOW it fell short when it didn't, for the same
    /// reason as the sealed hooks: `deleteAllAuthoredSamples` can hit an unexpected error that leaves
    /// authored samples behind, and a hook that swallowed that would let a wipe the dialog called
    /// complete keep them. `.accessRevoked` is distinct from `.failed` because it is not retryable —
    /// once share access is revoked only the Health app can remove Fernlet's samples, so the funnel
    /// names that path instead of inviting a retry that can only fail.
    @ObservationIgnored var healthKitSampleDeleteHook: (() async -> AuthoredSampleDeleteOutcome)?
    /// Deletes the day-blob copy sitting in the user's private CloudKit zone WITHOUT a live sync session
    /// — the "Stop syncing, keep cloud data" case, where sync is off so the per-row deletes below can't
    /// reach the server by propagating over a session. Returns whether it cleared. Wired in `ContentView`
    /// (the store does not own a CloudKit service). Invoked only when `cloudCopyKept` is set.
    @ObservationIgnored var cloudCopyDeleteHook: (() async -> Bool)?
    /// Purges the pending-narrative buffer — cycle notes written while the app was LOCKED, sealed under a
    /// device key and parked in a file until the next unlock can file them.
    ///
    /// This is its own hook rather than part of `periodDataDeleteHook` because it is a different store
    /// with a different key: the narrative repositories drop Core Data rows, and the buffer is a file
    /// that no amount of row-deleting reaches. `FernletLockService.reset()` used to purge it, and this
    /// funnel deliberately does not call `reset()` (the app lock survives a wipe by product decision) —
    /// so without this, replacing `reset()` with the row hooks SILENTLY DROPPED the buffer purge, and a
    /// note written while locked would be re-inserted into the emptied store on the next unlock.
    @ObservationIgnored var pendingNarrativeBufferPurgeHook: (() -> Bool)?
    /// Returns storage preferences to first-launch defaults. A hook because the preferences store is
    /// app-scoped, not owned by `FernletStore`.
    ///
    /// `keepSealedBackupFlags` is passed when a sealed-backup deletion FAILED. Those flags are what
    /// `hasSealedBackup` consults to decide there is a backup worth deleting, so clearing them after a
    /// failure would make the failure permanent: the retry the alert invites would find the flags false,
    /// skip the payload, and leave the backup in iCloud with nothing left to point at it.
    ///
    /// `keepCloudCopyFlag` plays the same role for `cloudCopyKept`: passed when the kept-cloud-copy delete
    /// failed, so a retry still knows there is a copy in iCloud to remove.
    ///
    /// Returns whether the reset ran — `Bool` like the other hooks, so an unwired funnel reports
    /// "your storage settings" instead of silently leaving the preferences (Health grants, backup
    /// flags) as they were.
    @ObservationIgnored var storagePreferencesResetHook: ((_ keepSealedBackupFlags: Bool, _ keepCloudCopyFlag: Bool) -> Bool)?

    /// Persists the period re-upload deferral into `StoragePreferences` so it survives relaunch. A hook
    /// (like `storagePreferencesResetHook`) because the preferences store is app-scoped: writing through
    /// a second `StoragePreferencesStore` instance would leave the app's observable copy stale, and its
    /// next `update` would clobber the flag. Unwired (tests) the deferral stays session-only, as before.
    @ObservationIgnored var sealedBackupDeferralPersistHook: ((Bool) -> Void)?

    /// Whether a sealed backup of this payload may be uploaded — i.e. whether "delete everything" has
    /// anything to remove. Lives here rather than on `StoragePreferences` because that type is Layer 0
    /// and cannot see `SealedBackupPayloadType`, which is defined above it in `CloudKitSync`.
    ///
    /// Deliberately does NOT require `iCloudSyncEnabled`. That seems like the obvious guard and it is
    /// wrong: `stopSyncingKeepCloudData()` is a first-class user flow that turns sync off while KEEPING
    /// the server copy, so "sync is off" says nothing about whether a backup is sitting in iCloud. Gating
    /// on it would skip the delete for exactly the user who most needs it, and the dialog would promise
    /// a deletion that never ran.
    private static func hasSealedBackup(_ payloadType: SealedBackupPayloadType, _ preferences: StoragePreferences) -> Bool {
        switch payloadType {
        case .sensitiveNotes: return preferences.sealedBackupSensitiveNotesEnabled
        case .periodData: return preferences.sealedBackupPeriodEnabled
        }
    }

    /// What a wipe actually managed to remove. Every layer of the delete is best-effort by design — a
    /// Core Data save can fail, a HealthKit type may be unauthorized, a coordinated file write can lose
    /// to another process — and the confirm dialog promises permanence. So a failure has to reach the
    /// user instead of being swallowed; "delete everything" quietly half-working is the failure mode
    /// this whole change exists to end.
    struct DeleteAllOutcome: Equatable {
        /// Human-readable names of the stores that did not confirm deletion, for the failure alert.
        var incompleteStores: [String] = []
        var isComplete: Bool { incompleteStores.isEmpty }
    }

    /// The single "delete everything" funnel. Both Settings entry points route here, so there is one
    /// definition of what deletion means rather than two partial ones that disagree.
    ///
    /// Deliberately NOT deleted (and disclosed in the confirm dialog, because a delete that quietly
    /// keeps things is worse than one that says so):
    /// - the moderation self-ban — a safety mechanism; letting a wipe undo a block would make "delete
    ///   my data" an abuse vector.
    /// - the milestone ledger — lifetime care counts, product call that they outlive a reset.
    /// - the mesh identity keypair — wiping it would force every friend to re-add you.
    /// - the shared-photo wall (`PrivateMediaStore` via `meshNetworkManager`) — BOTH the photos friends
    ///   sent you and the ones you shared with them (a photo you shared is cached under your own
    ///   fingerprint, so it is not "someone else's gift" — it is still kept). By product decision the wall
    ///   is curated one photo at a time (`MeshNetworkManager.deletePhoto`, which purges the sealed bytes);
    ///   there is deliberately NO "delete all photos", so this funnel must not add a bulk purge here.
    /// - the app lock itself — a wipe empties the protected data, it does not drop your protection.
    ///
    /// The ORDER is the correctness argument, not housekeeping. A wipe races three background writers
    /// that will happily rebuild what it deletes, so the writers are stopped BEFORE anything is removed
    /// and the pending-save cancel is repeated at the END — `resetAll()` schedules a fresh save of its
    /// own on the way past.
    @discardableResult
    func deleteAllData(includingHealthKitSamples deleteHealthSamples: Bool) async -> DeleteAllOutcome {
        var outcome = DeleteAllOutcome()

        // 1. Stop the writers first. A debounced save fires one second from now and a HealthKit workout
        // notification can arrive at any moment; either one lands mid-wipe and re-creates day rows from
        // samples that still exist. `stopHealthKitWorkoutObservation` matters most when the user chose
        // to KEEP their Health samples — that is precisely when the observer still has data to re-import.
        snapshotSaveCoordinator.cancelPending()
        stopHealthKitWorkoutObservation()
        // The un-hide settle is a third writer: suspended in its CloudKit fetch it would resume AFTER
        // the wipe and re-insert cycle narratives (and possibly re-upload a fresh backup) into the
        // just-emptied store. `applyRestoredChunks` honors the cancellation at its write point, and the
        // diverged-device latch backstops any restore this cancel arrives too late for.
        periodBackupSettleTask?.cancel()

        // 2. Sealed iCloud backups, BEFORE the preference reset that would gate them off. Turning the
        // pref off only stops the restore while it stays off; the CKRecords survive and re-appear the
        // moment the user re-enables the backup — a wipe the user's own journal outlives. Disabling
        // deletes the chunk set for real, and needs no escrow key, so it works while locked.
        //
        // Only backups the user actually ENABLED are touched. `setSealedBackupEnabled(false,…)` returns
        // false when there is no provisioned identity — the common case for someone who never used
        // proximity — so attempting it unconditionally would report a failure to delete a backup that
        // was never uploaded, on the one dialog whose whole value is that its promises are true.
        let preferences = StoragePreferencesStore.currentPreferences()
        var sealedBackupDeleteFailed = false
        for payloadType in SealedBackupPayloadType.allCases where Self.hasSealedBackup(payloadType, preferences) {
            if await !setSealedBackupEnabled(false, payloadType: payloadType) {
                sealedBackupDeleteFailed = true
                if !outcome.incompleteStores.contains("your encrypted iCloud backup") {
                    outcome.incompleteStores.append("your encrypted iCloud backup")
                }
            }
        }
        // The period re-upload deferral points at a backup this wipe just deleted — and the local
        // period data behind it is about to go too, so the promised re-upload can never happen again
        // either way. Clear it (observable + persisted) with the backup.
        recordSealedBackupPeriodReuploadDeferred(false)

        // 2b. The "Stop syncing, keep cloud data" copy. Sync is OFF, so the per-row deletes below can't
        // reach the server by propagating over a live session — but a full copy of the day blob is still
        // sitting in the user's private CloudKit zone, ready to sync straight back the moment they turn
        // iCloud on. Delete it directly (`deleteAllCloudKitData` opens its own connection and needs no
        // live session). Gated on `cloudCopyKept` so it never runs — and the dialog never claims it — for
        // a user who never kept a copy. A LIVE sync (`iCloudSyncEnabled`) needs nothing here: its server
        // copy goes when the local deletes below propagate over the still-open session.
        var cloudCopyDeleteFailed = false
        if !preferences.iCloudSyncEnabled && preferences.cloudCopyKept {
            if await cloudCopyDeleteHook?() != true {
                cloudCopyDeleteFailed = true
                outcome.incompleteStores.append("your iCloud copy")
            }
        }

        // 3. Sealed rows: the most sensitive data and the only rows with no second chance. Each hook
        // drops rows WITHOUT decrypting, so this works while the app is locked and while a surface is
        // hidden — deleting data must not require the ability to read it.
        //
        // `!= true` (not `== false`): a NIL hook — an unwired run — must count as a failure, not a skip.
        // `== false` treated nil as success, so an unwired funnel would silently miss the app's most
        // sensitive rows and still report a complete wipe. Only an explicit `true` clears the store.
        if periodDataDeleteHook?() != true { outcome.incompleteStores.append("your cycle notes") }
        if intimacyDataDeleteHook?() != true { outcome.incompleteStores.append("your intimate logs") }
        if journalDataDeleteHook?() != true { outcome.incompleteStores.append("your journal entries") }
        // Worry Box rows are purged (and reported) inside `resetAll()` below — its ONE invocation per
        // wipe, kept there so a standalone "Reset everything" purges them too.

        // The buffer of notes written while LOCKED. Not covered by the row hooks above — it is a file
        // under a separate device key — and its next drain re-inserts every payload into the store we
        // just emptied, so skipping it turns "delete everything" into "delete until the next unlock".
        if pendingNarrativeBufferPurgeHook?() != true { outcome.incompleteStores.append("your cycle notes") }

        if deleteHealthSamples {
            switch await healthKitSampleDeleteHook?() {
            case .complete:
                break
            case .accessRevoked:
                // Samples Fernlet wrote are still in Health and Fernlet can no longer reach them: the
                // user revoked its share access after writing. Reporting this as complete would be the
                // silent failure this funnel exists to end, and the bare label below would invite a
                // retry that can only fail — name the one path that works instead.
                outcome.incompleteStores.append("your Apple Health entries (Fernlet's Health access is turned off — remove them in the Health app)")
            case .failed, nil:
                // `nil` (an unwired hook) counts as failure, same as the sealed hooks above.
                outcome.incompleteStores.append("your Apple Health entries")
            }
        }

        // 4. Photo bytes before the days that reference them: ownership lives in `Meal.photoID`, so once
        // the days are gone nothing knows these files exist and they can never be reached again.
        if !mealPhotoStore.deleteAll() {
            outcome.incompleteStores.append("meal photos")
        }
        // 4b. The gym progress-photo timeline (#11) — the user's own body photos, a log like meals, so a
        // full wipe includes them. Its dated index is self-contained (not referenced from day records),
        // but the same reasoning applies: clear the store wholesale so nothing is stranded on disk.
        if !progressPhotoStore.deleteAll() {
            outcome.incompleteStores.append("progress photos")
        }
        // 4c. Recipe photos (#1), keyed by recipe id. The saved recipes themselves are cleared by the
        // repository purge below; their photos live in a separate sealed store that the purge can't reach.
        if !recipePhotoStore.deleteAll() {
            outcome.incompleteStores.append("recipe photos")
        }

        // 5. The share-extension inbox, which is drained on the next foreground. A recipe shared into
        // Fernlet before the wipe would otherwise import itself back into the emptied store — and the
        // extension can refill this file while the app is backgrounded, so the drain has to find it
        // empty rather than the app remembering not to drain.
        if !sharedRecipeImportQueue.clear() {
            outcome.incompleteStores.append("shared recipe inbox")
        }

        // 6. The plaintext "export my data" dump. `writeDataExportFile()` writes the user's whole
        // decrypted dataset — day logs, meals, journal, recipes, wardrobe, friends — UNENCRYPTED to a
        // tmp/ file for the share sheet, and nothing else in this funnel reaches it. iOS only reclaims
        // tmp/ under storage pressure, so a user who exported and then deleted everything could be left
        // with a full plaintext copy on disk after a dialog that said it was gone.
        if !purgeDataExports() {
            outcome.incompleteStores.append("your exported data file")
        }

        // 7. Friends' clothing catalogs browsable for an hour after a session. Memory-only, but it is
        // their social data visibly surviving a wipe in the running session.
        meshNetworkManager.clothingShop.clearAll()

        // 7b. More session-scoped social surfaces that would otherwise survive the wipe in a running
        // session (PrivacyWipeCoverage gap, 2026-07-25): temp messages are memory-only but a wipe is a
        // harder stop than the session end that normally clears them, and the presence radio keeps
        // advertising/matching until stopped.
        meshNetworkManager.sessionMessages.clear()
        presenceManager.stop()

        // `resetAll()` reports any per-row store whose CloudKit delete failed (designs / recipes / coins
        // left on disk to re-sync) plus the Worry Box purge. Those used to be discarded, so a failed
        // delete there looked complete.
        outcome.incompleteStores.append(contentsOf: resetAll())

        // 8. The authoritative per-row day store + the blob + the legacy JSON file. Without this, every
        // past day survives on disk, reloads on next launch, and re-uploads to iCloud — which is
        // exactly what "Reset everything" did before.
        //
        // Tier-two memories live inside the blob record, so the purge takes them; the old explicit
        // `replaceTierTwoMemories([])` here was worse than redundant — it is load-then-SAVE, so it
        // re-created the blob (and a fresh CloudKit record) microseconds after the purge deleted it.
        if !repository.purgeAllPersistedData() {
            outcome.incompleteStores.append("your day history")
        }

        // 9. Re-cancel: `resetAll` scheduled a debounced save on its way past (via
        // `batchSnapshotPersistence`), which would fire one second from now and re-create today's row
        // and the blob. Nothing between the purge and here suspends, so no save can slip in.
        snapshotSaveCoordinator.cancelPending()

        // 10. The widget's app-group files, LAST — after the cancel, so the debounced save's
        // `publishWidgetSnapshot` can't write the file back moments later. Until this runs the user's
        // score, water and macros keep rendering on the Home and Lock Screen.
        if let widgetSnapshotMirror, !widgetSnapshotMirror.clear() {
            outcome.incompleteStores.append("widget data")
        }
        // The pending widget-action queue (a "+1 cup" tapped from the widget/Siri before the wipe)
        // drains on the next foreground and re-creates a day record. `clear()` now reports a failed
        // empty-write, so a surviving row can't leave the dialog claiming a complete wipe. Names
        // "widget data" like the mirror above; the dedupe below collapses the pair to one line.
        if !pendingWidgetActionQueue.clear() {
            outcome.incompleteStores.append("widget data")
        }

        // The device-local AI daily-call counter (`AICallQuotaStore`) is a per-device ledger like the
        // widget mirror above — never synced, never in the snapshot. A wipe zeroes it so a post-wipe
        // fresh start isn't left in a stale `.sleepy`/`.resting` band from before the reset. `reset()`
        // has no failure signal (a plain UserDefaults removal), so it reports no incomplete store.
        aiCallQuotaStore.reset()

        // The device-local AI audit log (Ladder §7.2) — a per-device ledger of AI-call metadata, never
        // synced/snapshot/exported. Clear the persisted file directly (guaranteed even if the actor sink
        // was never wired) AND the in-memory session entries. Unlike the plain UserDefaults quota reset
        // above, a file removal HAS a real failure signal (like the widget-queue clear); a failed
        // removal would leave the log on disk behind a dialog claiming a complete wipe, so report it as
        // an incomplete store. NOT the BYOK keychain leg, which lands with BYOK later.
        if !aiAuditLogStore.clear() {
            outcome.incompleteStores.append("AI activity log")
        }
        await AIAuditLog.shared.clear()

        // 11. Proximity identity + sealed-content device keys (bitchat adoptions Increment 1,
        // Docs/PrivacyWipeCoverage.md). `IdentityService.wipe()` had ZERO call sites before this, so
        // the Ed25519/X25519 identity — which even survives an app reinstall via the keychain —
        // outlived "Delete everything", leaving a post-wipe "fresh start" recognizable to every
        // friend's trust vault. Wiping deliberately breaks every trust relationship (friends
        // re-friend in person; same semantics as bitchat's panic wipe) and takes the backup-escrow
        // rows under the same keychain service with it — their sealed backups were already deleted
        // in step 2, so the keys are orphans. All three live IdentityService caches are wiped so RAM
        // matches the keychain until relaunch.
        do {
            try meshNetworkManager.wipeIdentityForDeleteAll()
            try presenceManager.wipeIdentityForDeleteAll()
            try recipeShareManager.wipeIdentityForDeleteAll()
        } catch {
            outcome.incompleteStores.append("your nearby-friends identity")
        }
        // Orphaned at-rest keys: the journal/worry device keys (their sealed rows died with the
        // repository purge) and the shared private-media content key (every media store was emptied
        // above). All regenerate lazily on next use; keychain not-found counts as done, so these
        // carry no incomplete-store signal.
        KeychainItem.delete(for: .deviceJournalKey, service: KeychainItem.journalService)
        KeychainItem.delete(for: .deviceWorryKey, service: KeychainItem.journalService)
        KeychainPrivateMediaKeyProvider.deleteKeychainRowForWipe()
        mealPhotoStore.invalidateEncryptionKeyCache()
        progressPhotoStore.invalidateEncryptionKeyCache()
        recipePhotoStore.invalidateEncryptionKeyCache()

        if storagePreferencesResetHook?(sealedBackupDeleteFailed, cloudCopyDeleteFailed) != true {
            outcome.incompleteStores.append("your storage settings")
        }

        // A single store can be named by two independent legs — the sealed cycle-notes rows and the
        // locked-note buffer both purge "your cycle notes" — so collapse to first-seen (order preserved)
        // before the failure alert formats them, or it would read "…and your cycle notes and your cycle
        // notes". `isComplete` (empty vs not) is unaffected by the dedupe.
        var seenStores = Set<String>()
        outcome.incompleteStores = outcome.incompleteStores.filter { seenStores.insert($0).inserted }

        FernletAuditLog.log("settings.deleteAll.completed", context: [
            "healthSamples": deleteHealthSamples ? "deleted" : "kept",
            "complete": outcome.isComplete ? "true" : "false"
        ])
        return outcome
    }

    /// Returns the human-readable names of any per-row store whose persisted delete failed, so the
    /// "delete everything" funnel can fold them into its failure alert. Empty on a clean reset. Still
    /// safe to call in a Void context (`@discardableResult`) — the standalone "Reset everything" callers
    /// ignore the value.
    @discardableResult
    func resetAll() -> [String] {
        var incompleteStores: [String] = []
        batchSnapshotPersistence {
            diary.resetDiary()
            connectionSessionLogs = []
        }
        if !savedRecipeService.reset() { incompleteStores.append("your saved recipes") }
        if !customItemService.reset() { incompleteStores.append("your custom items") }
        // Clears all earn/spend rows and appends a reset-boundary marker. The next `reconcileCoinLedger()`
        // re-mints `earn` rows ONLY for active days at or after the reset boundary day — days before the
        // reset stay voided and are never re-minted, so another device can't undo a reset by
        // deterministically re-minting pre-reset earns. Activity logged on or after the reset day still
        // earns normally (the reset zeroes the past, it doesn't disable earning going forward).
        if !coinLedgerService.reset() { incompleteStores.append("your coins") }
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
        // other bulk-wipe path — purge the sealed rows + the device-local let-go count. `!= true`
        // like the funnel's sealed hooks: a nil (unwired) hook or a failed row delete must surface,
        // because the delete dialog promises "Worry Box notes" by name.
        if worryBoxResetHook?() != true { incompleteStores.append("your Worry Box notes") }
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
        // Per-GTIN last-used serving counts (feedback #13) are a device-local `UserDefaults` sidecar like
        // the ledgers above — clear them so a remembered "2 servings" for a scanned product doesn't
        // outlive a wipe. `deleteAllData` reaches this via its `resetAll()` call, so both wipe paths cover
        // it. A plain `UserDefaults` removal has no failure signal, so it reports no incomplete store.
        BarcodeServingMemory.clearAll()
        // Group activities (hosted/joined rosters + join tokens) — device-local social data, never synced;
        // clear the sidecar too (the manager owns it, mirroring the clothing-shop clearAll seam).
        meshNetworkManager.activities.clearAll()
        // The guided-workout runner mirrors an in-flight run to an app-group file that a
        // foreground/launch `reconcileGuidedRunFromAppGroup` re-reads — and a naturally-finished run
        // re-LOGS a workout back into the store (`finishGuidedRunLogging` → `addWorkout`; the dedup
        // guards are empty on a just-wiped store, and with sync on the resurrected day re-uploads to
        // iCloud). It is a live writer like the widget queue, so a wipe must stop it. Clear the file
        // UNCONDITIONALLY: a Live-Activity finish can leave the run only in the file with
        // `guidedRunState` already nil, so `abandonGuidedRun`'s non-nil guard is too weak here.
        guidedRunState = nil
        guidedRunStateStore.clear()
        syncActivity { await GuidedWorkoutActivityBridge.end() }
        // The cooking runner is the SAME class of live writer: an in-flight cook is mirrored to its own
        // app-group file that a foreground/launch `reconcileCookingRunFromAppGroup` re-reads and adopts
        // (resurrecting a "Cooking in progress" resume card on a supposedly-wiped device — and leaving the
        // recipe name + current step text on the Lock Screen). Cooking never auto-logs, so there is no
        // re-log hazard, but the file + Live Activity must still be stopped unconditionally at the wipe.
        cookingRunState = nil
        cookingRunStateStore.clear()
        syncActivity { await CookingActivityBridge.end() }
        // Device-local sensitive-surface visibility resolution — reset to "unresolved" so a fresh start
        // re-derives from `sex` (resetDiary already restored the settings gate to its defaults).
        clearSensitiveVisibilityResolution()
        return incompleteStores
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
        // Reconcile the cooking walker the instant an in-process App Intent (Live Activity "Next" / Siri)
        // writes the advanced run, instead of only on the next scenePhase `.active`. Registered once.
        if cookingIntentObserver == nil {
            cookingIntentObserver = NotificationCenter.default.addObserver(
                forName: .cookingRunAdvancedByIntent, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileCookingRunFromAppGroup() }
            }
        }
        processPendingWidgetActions()
    }

    /// Advances the store to the current wall-clock day when the app has crossed local midnight while
    /// resident. `FernletStore` is built once at launch and its `todayKey` is otherwise pinned forever
    /// (see `processPendingWidgetActions`), so a meal/edit made after midnight on a still-resident app
    /// would file under the launch day — showing during the session but vanishing from "Today" after the
    /// next cold launch re-keys. This re-keys the diary IN PLACE instead: it flushes the outgoing day
    /// under its OWN (old) key first (so nothing logged just before the rollover is lost), swaps the
    /// in-memory `day` to the new day's persisted content, then refreshes the derived signals, coin
    /// ledger, and widget mirror for the new day. No-op (returns false) when still on the same day.
    ///
    /// Called on foreground (`scenePhase == .active`) and defensively at the start of the interactive
    /// meal-commit path so a meal typed just after midnight is filed on the correct new day.
    @discardableResult
    func refreshCurrentDayIfNeeded(now: Date = Date()) -> Bool {
        let currentDayKey = FernletDate.dayKey(for: now)
        guard currentDayKey != todayKey else { return false }
        // Persist the outgoing in-memory state (day + recentMeals + …) under the OLD key BEFORE it
        // advances, so a log made just before this rollover isn't lost. `flushPending` is a no-op when no
        // save is pending (the outgoing day's row is then already durable). `currentSnapshot()` reads
        // `todayKey`, which is still the old key here, so the flush is correctly keyed to the old day.
        snapshotSaveCoordinator.flushPending()
        diary.advanceCurrentDay(to: currentDayKey)
        // Re-derive the new day's signals/score and refresh the coin ledger + widget mirror for it.
        rebuildDerivedSignals()
        reconcileCoinLedger()
        publishWidgetSnapshot()
        return true
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
        // Best-effort: bring up the full branded food catalog (On-Demand Resource) and attach it to the
        // live catalog for barcode + search. Non-blocking and failure-tolerant — the base catalog serves
        // until (and if) this attaches; a missing/purged asset just leaves us on base coverage.
        let catalog = foodCatalog
        Task { [brandedCatalogLoader] in await brandedCatalogLoader.loadBrandedCatalog(into: catalog) }
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
            // A transient Core Data / CloudKit fetch failure — or a nil/undecodable payload — makes
            // loadSnapshotAsync return the EMPTY read-only-recovery fallback. Applying that here would
            // overwrite the live in-memory diary with nothing: every tab would repaint bare parchment
            // and stay blank until the next successful remote-change reload restored it — the
            // intermittent "page blanks out, then loads" symptom. Keep the data we already hold; the
            // repository stays read-only (writes are skipped) until it recovers, and the next
            // successful reload applies real data. `isReloadingFromRepository` is reset by the defer.
            if coreDataRepository.isInReadOnlyRecovery { return }
        } else {
            snapshot = repository.loadSnapshot(todayKey: todayKey)
        }
        apply(snapshot)
    }

    private func apply(_ snapshot: FernletSnapshot) {
        diary.applyDiarySlice(snapshot)
        // A remote (CloudKit) blob may have been re-encoded by a pre-gate peer that dropped the visibility
        // keys — reconcile immediately, before any read or the derived-signals rebuild below, so a mixed-
        // version sync can't re-open a hidden period/intimacy surface.
        reconcileSensitiveSurfaceVisibility()
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

    func isWorkoutTombstoned(fernletWorkoutID id: UUID) -> Bool {
        workoutTombstones.contains(id)
    }

    func clearWorkoutTombstone(fernletWorkoutID id: UUID) {
        workoutTombstones.remove(id)
    }

    /// Removes the local row mirroring a Health sample the user deleted in the Health app (observer
    /// deleted-objects path). Matched across days by `healthKitUUID`. Deliberately does NOT restore a
    /// planned row or touch guided/progression bookkeeping — a Health-side deletion is an external event,
    /// not an undo of a completion, so we honour the deletion without re-offering the plan.
    func removeWorkoutByHealthKitUUID(_ hkUUID: UUID) {
        for (dateKey, dayValue) in diary.loadDays() {
            if let row = dayValue.workouts.first(where: { $0.healthKitUUID == hkUUID }) {
                diary.removeWorkout(id: row.id, date: dateKey)
                return
            }
        }
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
    func recordSealedBackupPeriodReuploadDeferred(_ deferred: Bool) {
        sealedBackupPeriodReuploadDeferred = deferred
        sealedBackupDeferralPersistHook?(deferred)
    }
}

extension FernletStore: HealthSyncContext {
    func scheduleSnapshotSave() { snapshotSaveCoordinator.schedule() }
}

// MARK: - Models
