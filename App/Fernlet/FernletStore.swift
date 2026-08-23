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

/// The central observable app state: the facade every screen reads and mutates, and the app
/// target's one legitimate integration point above the SPM "S3 wall".
///
/// Composition: the portable diary slice lives in `DiaryStore` (`diary`), with settable
/// forwarders here so call sites keep working; this facade owns everything app-only — the
/// per-row ledger services (saved recipes, custom items, coins, milestones), the proximity
/// subsystem (`meshNetworkManager`, `presenceManager`, `recipeShareManager`, trust vault, heart
/// ledger/`heartDropService`, moderation), the coordinators extracted from it
/// (`SnapshotSaveCoordinator`, `JournalSealingCoordinator`, `SealedBackupCoordinator`,
/// ``HealthSyncCoordinator``, workout planning / meal resolution), the sealed photo stores, the
/// AI gate/quota/audit plumbing, and the widget bridge.
///
/// Persistence: mutations schedule a debounced snapshot save through `SnapshotSaveCoordinator`
/// against the active `FernletRepository` (Core Data + CloudKit, or local JSON); remote-change
/// notifications reload state, and the after-save hook republishes the benign widget snapshot.
/// Sensitive data never enters the snapshot: journal/cycle/intimacy text lives in the sealed
/// narrative stores, and device-local sidecars (AI quota + audit log, hearts, closeness,
/// moderation, age assurance, sensitive-visibility resolution) deliberately never sync.
///
/// Invariants worth knowing before editing:
/// - Sensitive-surface gating is DERIVED (`isPeriodTrackingVisible` /
///   `isIntimacyTrackingVisible`) and fail-closed; hiding must also scrub resident plaintext
///   (`periodScrubHook`, `scrubHiddenHealthContext`), and the device-local resolution sidecar
///   protects the choice from mixed-version peers. The duress decoy (``duressSessionActive``)
///   rides that same derivation and must stay purely in-memory — it never writes a preference.
/// - "Delete everything" (`deleteAllData`) is a single ordered funnel: writers stopped first,
///   sealed rows dropped WITHOUT decrypting, then the sealed store FILE destroyed and re-created
///   (`sealedStoreRebuildHook`, keyless) so the row-delete's `-wal`/freelist residue goes too;
///   the synced store gets the same residue pass by checkpoint + vacuum instead
///   (`mainStoreRebuildHook`), because destroying ITS file would discard the CloudKit mirror's
///   pending export queue; every leg reported through ``DeleteAllOutcome`` — an unwired row hook
///   counts as failure, never success.
/// - AI call sites route through `aiGate` (rebuilt per read); the concrete provider type is
///   named only in ``FernletAIComposition`` so this file stays off the S3 grep-wall's AI list.
///
/// Concurrency: `@MainActor` + `@Observable`; collaborators call back via weak hooks onto the
/// main actor. Failure mode by design is best-effort-but-reported: saves, HealthKit calls, and
/// cloud legs may fail individually and surface through outcomes/audit logs rather than crashing.
@MainActor
@Observable
final class FernletStore {
    /// The portable diary slice. Owns the pure diary state + pure diary methods; this facade owns
    /// the app-only collaborators (coordinators, proximity, snapshot machinery, retry/derived/
    /// saved-recipe services, the period bridge) and forwards every diary member to it. Accessing
    /// `diary.<prop>` still participates in observation (the @Observable tracking is on DiaryStore).
    @ObservationIgnored let diary: DiaryStore

    // MARK: - Diary forwarders (state moved to DiaryStore; settable forwarders write through)
    /// Today's record (meals, workouts, journals, sleep, hygiene, health context) — the diary's
    /// canonical "current day", re-keyed on rollover by `refreshCurrentDayIfNeeded`.
    var day: FernletDay {
        get { diary.day }
        set { diary.day = newValue }
    }
    /// The synced user settings blob (goals, visibility toggles, proximity opt-ins, companion
    /// appearance, home-widget order). Prefer the dedicated setters when a side effect (scrub,
    /// radio stop) must accompany the change.
    ///
    /// The setter SCHEDULES A SNAPSHOT SAVE, so a plain SwiftUI binding — `$store.settings.showCalories`
    /// and the dozen other direct bindings in Settings — is durable the moment it is flipped. Without
    /// it those writes only reached memory: `flushPendingSnapshotSave()` on background flushes a
    /// PENDING save, and nothing had scheduled one, so a user who toggled a setting and force-quit
    /// without logging anything found it reverted. The write goes to `diary.settings` directly, which
    /// is what keeps this off the load path — `applyDiarySlice` assigns the diary's own property, so
    /// applying a remote snapshot still never schedules a save of what it just read.
    var settings: FernletSettings {
        get { diary.settings }
        set {
            diary.settings = newValue
            scheduleSnapshotSave()
        }
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
    /// Mirror of `FernletLockService.isDuressSessionActive`: true while the app is showing the
    /// DECOY because the duress PIN was entered (Phase 7).
    ///
    /// Wired in `ContentView` — from the launch `.task`, from the lock-state observer, and from its
    /// own `.onChange` on the service flag (the duress branches of `changeCredential` /
    /// `setBiometricEnabled` can flip it without any lock-state transition to observe).
    ///
    /// **In-memory ONLY, and that is the invariant.** Nothing writes it to `settings`, to the
    /// snapshot, or to a sidecar. `isPeriodTrackingVisible` / `isIntimacyTrackingVisible` AND-in
    /// `!duressSessionActive`, which rides the existing hide machinery — the
    /// `.onChange(of: sensitiveSurfaceVisibility)` scrub drops resident cycle state and the bridge
    /// trends, `PrivateHubSection` hides the sections, and `allowedHealthCapabilities` stops the
    /// HealthKit reads — so the decoy is complete and, when the real passcode clears the flag,
    /// completely reversible. Persisting the forced-hidden value instead (writing
    /// `settings.periodTrackingVisible = false`) would turn a reversible decoy into silent data
    /// hiding, and would reach the sealed-backup toggles that DELETE the iCloud backup. Gate on this
    /// flag; never on a setter.
    var duressSessionActive = false
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
        // The 13+ mesh-chat gate. Withholds the `messages` capability, refuses sends, and drops inbound
        // messages — see `MeshNetworkManager.chatAllowedProvider`. `?? false` keeps a deallocated facade
        // fail-closed, matching the nil-means-no contract the provider already documents.
        manager.chatAllowedProvider = { [weak self] in self?.ageAssurance.allows(.chat) ?? false }
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
        // Away hearts (Increment 3): prekey-bundle gossip over the mesh intros, mirroring the
        // presence path; the `heartsAway` capability advertises only under the user's consent.
        manager.heartDropBundleProvider = { [weak self] in self?.heartDropService.currentLocalBundle() }
        manager.onPeerPrekeyBundle = { [weak self] key, bundle in
            self?.heartDropService.storePeerBundle(bundle, friendSigningKey: key)
        }
        manager.heartsAwayEnabledProvider = { [weak self] in self?.settings.heartsAwayDelivery ?? false }
        return manager
    }()
    @ObservationIgnored private(set) lazy var recipeShareManager: ProximityRecipeShareManager = ProximityRecipeShareManager(store: self)
    /// Device-local hearts state (received hearts + per-friend-per-day rate limit). Deliberately
    /// outside the snapshot: heart activity never enters any synced store.
    ///
    /// On THIS store's proximity root rather than the process-wide one: `resetAll` calls
    /// `clearAll()`, which removes the sidecar file, so a shared path lets any wiping test delete
    /// the received hearts of every concurrently-live store.
    @ObservationIgnored private(set) lazy var heartLedger =
        ProximityHeartLedger(fileURL: ProximityHeartLedger.fileURL(in: proximitySupportRoot))
    /// Device-local moderation reports (never synced). Feeds item-hiding + the escalation/ban.
    ///
    /// On THIS store's proximity root: `resetAll` calls `clearAll()`, which removes the sidecar, so a
    /// process-wide path lets any wiping test delete who-reported-whom for every concurrently-live
    /// store. Unsealed, so the root is the whole fix — no keychain half, unlike the heart sidecars.
    @ObservationIgnored private(set) lazy var moderationLedger =
        ModerationLedger(fileURL: ModerationLedger.fileURL(in: proximitySupportRoot))
    /// Device-local, non-synced daily AI-call counter (Ladder §3.2). Drives the `.sleepy`/`.resting`
    /// overlay on `effectiveAIStatus`; deliberately outside the snapshot — usage never syncs.
    @ObservationIgnored private(set) lazy var aiCallQuotaStore: AICallQuotaStore =
        UserDefaultsAICallQuotaStore(defaults: aiQuotaDefaults)
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
    ///
    /// Per-instance root like the ledgers around it, and this one has the widest wipe reach of the
    /// three: besides `resetAll`, turning the fuzzy-state share OFF clears it (`setSharesFuzzyState`),
    /// so an ordinary settings toggle in one test — not just a wipe — used to empty every other live
    /// store's cache.
    @ObservationIgnored private(set) lazy var friendStateCache =
        FriendStateCache(fileURL: FriendStateCache.fileURL(in: proximitySupportRoot))
    /// Device-local closeness signal (in-person interaction counts) + close-slot assignment (Phase 5).
    /// Never synced — closeness is a private, per-device view.
    ///
    /// Per-instance root for the same reason as the two above: `resetAll` clears it.
    @ObservationIgnored private(set) lazy var closenessLedger =
        ClosenessLedger(fileURL: ClosenessLedger.fileURL(in: proximitySupportRoot))
    /// Offline "away" hearts via the CloudKit public-DB dead-drop (bitchat adoptions Increment 3).
    /// All crypto lives on the ProximityKit side; `HeartDropCloudTransport` (CloudKitSync) ferries
    /// only rotating day tags + sealed blobs — the S3 wall seam is `HeartDropTransporting` in
    /// FernletDomainModel. Consent-gated by `settings.heartsAwayDelivery` at queue AND fetch;
    /// shares the SAME heart ledger as the live paths so the 5-minute cooldown stays one gate.
    @ObservationIgnored private(set) lazy var heartDropService: HeartDropService = {
        let service = HeartDropService(
            ledger: heartLedger,
            isEnabled: { [weak self] in self?.settings.heartsAwayDelivery ?? false },
            activeFriends: { [weak self] in
                (self?.proximityTrustVault.trustedPeers ?? []).filter {
                    $0.blockedAt == nil && $0.revokedAt == nil && !$0.keyAgreementPublicKey.isEmpty
                }
            },
            localDayKey: { FernletDate.dayKey(for: $0) },
            displayName: { [weak self] in self?.proximityDisplayName ?? "" },
            // Files AND seal key on this store's own scope: `wipeForDeleteAll` destroys both, so
            // under the parallel test runner one store's "delete everything" would otherwise empty
            // every other live store's outbox and delete the key their sidecars are sealed with.
            // Production resolves to the unchanged Application Support paths + `com.fernlet.heartdrop`.
            storage: heartDropStorage
        )
        service.transport = HeartDropCloudTransport()
        return service
    }()
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
        // Away hearts (Increment 3): our prekey bundle rides the sealed presence intro; a friend's
        // verified intro hands theirs to the drop cache; a race-window live-send failure falls
        // back to queueing the drop instead of failing outright.
        manager.heartDropBundleProvider = { [weak self] in self?.heartDropService.currentLocalBundle() }
        manager.onPeerPrekeyBundle = { [weak self] key, bundle in
            self?.heartDropService.storePeerBundle(bundle, friendSigningKey: key)
        }
        manager.queueAwayHeart = { [weak self] friend in
            self?.heartDropService.queueHeart(to: friend) == .queued
        }
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
    /// The opt-in own-photo escrow backup (security-hardening Phase 5, step 5b) — the sanctioned
    /// cross-device route for meal / recipe / progress photos once their key is device-bound.
    /// Owns its own store instances over `photoDocumentsDirectory`; see `OwnPhotoBackupCoordinator`.
    @ObservationIgnored private lazy var ownPhotoBackupCoordinator = OwnPhotoBackupCoordinator(
        host: self,
        documentsDirectory: photoDocumentsDirectory
    )
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
    /// The app container's Documents directory — the production root of every own-photo corpus below
    /// and the input to the own-photo key migration. Falls back to the temporary directory only if the
    /// container is unreachable (the historical behavior of each store's inline expression).
    nonisolated static let defaultPhotoDocumentsDirectory: URL =
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory())

    /// THIS store's own-photo root — the directory the three own-photo corpora, the escrow backup
    /// coordinator and the key migrator all hang off. Production always resolves it to
    /// `defaultPhotoDocumentsDirectory`.
    ///
    /// Per-instance rather than static because it is shared *mutable on-disk state*: `resetAll` and
    /// `deleteAllData` call `deleteAll()` on all three corpora, so with one process-wide directory any
    /// store that wipes destroys the photos of every other live store. Under the test runner —
    /// XCTest and Swift Testing suites run in parallel in ONE process — that is a live cross-suite
    /// race, not a theoretical one. Injectable so each test store gets its own temp root, mirroring
    /// the `appGroupDirectory` and `webImageAttemptDefaults` seams.
    @ObservationIgnored nonisolated let photoDocumentsDirectory: URL
    /// THIS store's proximity-sidecar root — the friend photo-wall cache + its preferences, built by
    /// `MeshNetworkManager` off `ProximityHost.proximitySupportDirectory` (which the adapter forwards
    /// here). Per-instance for exactly the reason `photoDocumentsDirectory` is: the wall's index is a
    /// whole-file re-save, so a process-wide path lets one live manager overwrite another's album.
    ///
    /// Note this is the OTHER side of the Phase-5 media-key split — the wall stays on the
    /// backup-restorable `friendWall` key — so it deliberately gets its own root rather than hanging
    /// off the own-photo one. Production always resolves to `Application Support/Fernlet`, the path
    /// the cache has always used; nothing shipped is migrated.
    @ObservationIgnored nonisolated let proximitySupportRoot: URL
    /// Keychain service for THIS store's heart-drop material — the prekey private halves and the key
    /// that seals the three heart-drop sidecars, which live under one service by design so a
    /// delete-all takes them together (see `HeartDropSidecarSeal`).
    ///
    /// Injectable for the same reason `proximitySupportRoot` is, and it has to move WITH that root:
    /// `heartDropService.wipeForDeleteAll()` deletes the whole service, so a store whose files were
    /// isolated but whose key was not would still have its sealed sidecars rendered unopenable — and
    /// quarantined — by any other live store's wipe. Production always resolves to the unchanged
    /// `com.fernlet.heartdrop`.
    @ObservationIgnored nonisolated let heartDropKeychainService: String
    /// THIS store's app-group root — the shared `<group.MBO.Fernlet>/FernletWidgets/` directory
    /// holding the guided-run and cooking-run state files, the inbound widget-action queue and the
    /// widget snapshot. NIL means the real container, which is what production always passes.
    ///
    /// One seam for all four because they are genuine co-tenants of ONE directory: a test that wants
    /// a simulated relaunch to see its in-flight run should see its queued widget taps too, which is
    /// what a real relaunch does. `resetAll` clears the two run files and `deleteAllData` clears the
    /// queue, so on the process-wide container any wiping test destroyed all of it for every
    /// concurrently-live store — and `GuidedWorkoutRunStoreTests` reads that very file.
    @ObservationIgnored nonisolated let appGroupDirectory: URL?
    /// Defaults suite backing THIS store's device-local AI-call counter. `.standard` in production.
    ///
    /// The identity here is a UserDefaults SUITE, not a path — the same lesson the heart-drop seal
    /// key taught, one axis over. `deleteAllData` calls `aiCallQuotaStore.reset()`, so on `.standard`
    /// one store's wipe zeroes the counter of every other live store. Deliberately NOT folded into
    /// `sensitiveVisibilityDefaults`: that suite is shared with `AgeAssuranceStore` because both are
    /// sensitive-surface state, and a daily AI-call count is neither.
    @ObservationIgnored let aiQuotaDefaults: UserDefaults
    /// The two halves above as the one value ProximityKit takes, so the heart-drop stores this store
    /// builds can never end up half-isolated.
    @ObservationIgnored nonisolated var heartDropStorage: HeartDropStorageScope {
        HeartDropStorageScope(directory: proximitySupportRoot, keychainService: heartDropKeychainService)
    }
    /// The user's OWN at-rest media key (security-hardening Phase 5), used by all three own-photo
    /// stores below. Separate keychain row from the friend photo wall's, which stays on the
    /// original backup-restorable key inside `MeshNetworkManager`.
    ///
    /// Not `Sendable`: each store constructs its own instance of the same role (they read one
    /// keychain row, so they share the key material and differ only in their private cache), and
    /// every one of them stays on this main-actor store — see `PrivateMediaKeyProviding`.
    /// `ownPhotoLegacyKeyProvider` is the PRE-SPLIT key, injected as the read-path dual-open
    /// fallback for files `OwnPhotoKeyMigrator`'s eager pass has not re-sealed yet — and dropped
    /// (nil) the moment the own key is device-bound, which is what makes that binding mean
    /// anything (step 5c).
    nonisolated private static func ownPhotoKeyProvider() -> KeychainPrivateMediaKeyProvider {
        KeychainPrivateMediaKeyProvider(role: .ownPhotos)
    }
    /// The pre-split (now friend-wall) key, read-only: `mintsIfAbsent: false` so a fallback probe
    /// can never CREATE the wall's row — a fresh random key would open nothing and would install a
    /// row that later looks authoritative.
    ///
    /// Nil once the own-photos row is device-bound. The question is asked of the KEYCHAIN, not of a
    /// persisted flag, so a device restored from a backup taken before the flip (bound row absent,
    /// loose row restored) correctly keeps its fallback. Safe by construction: the row can only be
    /// bound after `OwnPhotoMigrationLatch` proved there is nothing left for the fallback to open.
    ///
    /// Internal rather than private purely so `OwnPhotoKeyBindingTests` can pin that biconditional
    /// — "fallback present exactly when the key is not bound" is the property, and asserting it on
    /// the real wiring beats re-deriving it in a test.
    ///
    /// Resolved once per store construction, so a binding that happens mid-session (the launch pass,
    /// or the user's consent tap) leaves the fallback in place until the next launch. Deliberately
    /// not re-resolved: the fallback can only ever open bytes sealed under a key this app owns, the
    /// latch already proved there are none left, and rebuilding live store instances to shed a
    /// no-op code path would be the riskier change.
    nonisolated static func ownPhotoLegacyKeyProvider() -> KeychainPrivateMediaKeyProvider? {
        guard !OwnPhotoKeyBinder.isOwnPhotoKeyDeviceBound() else { return nil }
        return KeychainPrivateMediaKeyProvider(role: .friendWall, mintsIfAbsent: false)
    }
    /// Lazy (rather than an inline initializer) so it can hang off the per-instance
    /// `photoDocumentsDirectory` — see that property for why the root is not static.
    @ObservationIgnored private lazy var mealPhotoStore = MealPhotoStore(
        directory: OwnPhotoCorpusLayout.mealPhotosDirectory(in: photoDocumentsDirectory),
        keyProvider: FernletStore.ownPhotoKeyProvider(),
        legacyKeyProvider: FernletStore.ownPhotoLegacyKeyProvider()
    )
    /// The user's gym progress-photo timeline (#11). Body photos, so it seals the bytes AND the dated
    /// index; reuses the same hardened media path as meal photos, in its own directory.
    @ObservationIgnored private lazy var progressPhotoStore = ProgressPhotoStore(
        directory: OwnPhotoCorpusLayout.progressPhotosDirectory(in: photoDocumentsDirectory),
        keyProvider: FernletStore.ownPhotoKeyProvider(),
        legacyKeyProvider: FernletStore.ownPhotoLegacyKeyProvider()
    )
    /// The recipe's picture (#1), sealed and keyed by the recipe id. Holds the user's own photo —
    /// which always wins — or, since the 2026-08-09 owner decision (reversing the 2026-07-16
    /// "no external image fetch" tester decision), a web-imported recipe's page picture, downloaded
    /// once by a user-present path and sealed through the same normalize-and-encrypt pipeline.
    @ObservationIgnored private lazy var recipePhotoStore = MealPhotoStore(
        directory: OwnPhotoCorpusLayout.recipePhotosDirectory(in: photoDocumentsDirectory),
        keyProvider: FernletStore.ownPhotoKeyProvider(),
        // Recipe photos never had a plaintext generation — fail closed on unsealed on-disk bytes.
        allowsLegacyPlaintextUpgrade: false,
        legacyKeyProvider: FernletStore.ownPhotoLegacyKeyProvider()
    )
    /// Backing store for ``RecipeWebImageAttemptMemory`` — the device-local "one automatic
    /// web-image attempt per device" bookkeeping (the synced half of that contract is
    /// `RecipeWebImport.webImageSuppressed`). Injectable so tests can isolate it from the shared
    /// `.standard` suite, mirroring `pastDayJournalScrubDefaults`.
    @ObservationIgnored var webImageAttemptDefaults: UserDefaults = .standard
    /// Backing store for ``FoodSearchCorrectionMemory`` — the device-local record of searches the
    /// user has corrected once (research §26 fix 1.10), republished into `foodCatalog` as a ranking
    /// input.
    ///
    /// An INIT PARAMETER and a `let`, not a settable `var` like `webImageAttemptDefaults`, and that
    /// difference is load-bearing: this suite is READ DURING INIT (`finishCommonWiring` publishes the
    /// alias map into the catalog), so a post-hoc assignment lands after the read and the store spends
    /// its first moments answering searches out of the process-global `.standard` suite. That is the
    /// repo's shared-disk-root hazard class — a correction planted by one test changes what an
    /// uninjected store returns, and persists in the simulator container across runs. Tests pass
    /// `uniqueFoodSearchCorrectionDefaults()`; the launch path passes `.standard`, which is the real
    /// device memory.
    @ObservationIgnored let foodSearchCorrectionDefaults: UserDefaults
    /// Recipe ids whose web-image download is currently in flight. Guards the entry to
    /// ``fetchRecipeWebImageIfNeeded(for:)`` so the paste-import fire-and-forget task and the
    /// detail's first-open task — both of which can hold the same not-yet-attempted recipe copy —
    /// never run the download twice concurrently. Memory-only: an in-flight fetch never outlives
    /// the session.
    @ObservationIgnored private var webImageFetchesInFlight: Set<UUID> = []
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
    @ObservationIgnored lazy var pendingWidgetActionQueue =
        PendingWidgetActionQueue(directory: appGroupDirectory)
    @ObservationIgnored private var isProcessingPendingWidgetActions = false
    /// Inbound queue of recipes shared in from the share extension. One instance shared by the drain
    /// and by "delete everything", so a wipe can't miss a queue the drain would still find.
    ///
    /// THIS store's queue file, pinned at init from `sharedRecipeImportQueueFileURL:`. Nil — what
    /// production always passes — means the real
    /// `<group.MBO.Fernlet>/SharedRecipeImports/PendingRecipeURLs.json`. That is a DIFFERENT app-group
    /// subdirectory from `appGroupDirectory`'s `FernletWidgets/`, and the seam is a file rather than a
    /// directory because the queue owns exactly one.
    ///
    /// Injectable for the reason the container roots are: `deleteAllData` calls `clear()` on it, so on
    /// the production path one store's wipe empties the inbox of every concurrently-live store. Unlike
    /// the widget files, nothing in the suite reads the production queue today — this one is latent,
    /// and the natural way to write the test that would trip it (read `store.sharedRecipeImportQueue`
    /// rather than hand-injecting one) is exactly what joins the race.
    ///
    /// Nil meaning production is load-bearing well beyond tests: the share extension is a separate
    /// process with NO seam and its own hand-copied path resolution, so an app that resolved anywhere
    /// else would strand every shared-in recipe in a file nothing drains — and there is no
    /// share-extension test target to catch it.
    @ObservationIgnored var sharedRecipeImportQueue: SharedRecipeImportQueue
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
    /// Intimacy has no equivalent hook: its caches are `@State` on `CycleTrackerView`, which this
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
    /// values fail-closed instead. See `reconcileSensitiveSurfaceVisibility`.
    ///
    /// Its identity is a UserDefaults SUITE, not a path — the axis `aiQuotaDefaults` is on. `.standard`
    /// means the real sidecar, which is what production always passes. It has to be injectable for the
    /// same reason the container roots do, only more so: every `init` WRITES the three keys through
    /// `reconcileSensitiveSurfaceVisibility`, and `resetAll` clears them (plus `ageAssurance.clear`) —
    /// and `resetAll` is far and away the commonest wipe in the suite. Left on `.standard`, one store's
    /// reset returns every concurrently-live store to "never resolved", so the next read re-derives from
    /// `sex` instead of re-asserting a hidden surface fail-closed.
    @ObservationIgnored private let sensitiveVisibilityDefaults: UserDefaults

    /// The age determination behind the intimacy (16+) and mesh-chat (13+) gates. Deliberately shares
    /// `sensitiveVisibilityDefaults` rather than taking its own injection point: it is the same kind of
    /// device-local, never-synced sidecar for the same set of sensitive surfaces, and tests that isolate
    /// one want the other isolated with it. That sharing is why the suite is the whole seam — the age
    /// record is never synced, so a store handed someone else's cleared suite has no blob to recover
    /// its verdict from and simply fails closed.
    ///
    /// NOT `@ObservationIgnored` on the inside — `AgeAssuranceStore.record` is observable, so a view that
    /// reads a gate during `body` re-renders when the verdict changes.
    @ObservationIgnored let ageAssurance: AgeAssuranceStore

    /// UserDefaults keys for the device-local sensitive-visibility resolution sidecar (see
    /// `sensitiveVisibilityDefaults`).
    ///
    /// Kept together so the load/store/clear trio can't drift.
    private enum SensitiveVisibilityKeys {
        static let resolved = "sensitiveVisibilityResolved"
        static let period = "sensitiveVisibilityResolvedPeriodVisible"
        static let intimacy = "sensitiveVisibilityResolvedIntimacyVisible"
    }

    /// The synchronous designated initializer (tests, previews, and the pre-async load path):
    /// loads the snapshot and every per-row service on the calling thread, builds the diary,
    /// rewires its closures onto the facade, reconciles sensitive-surface visibility BEFORE any
    /// UI read, reconciles the coin/milestone ledgers, and subscribes to remote-change reloads.
    /// Every repository/service/defaults parameter is an injection seam; nil means production
    /// default. Prefer `FernletStore.load` at app launch — it does the slow work off the first
    /// frame.
    init(date: Date = .now, repository: FernletRepository? = nil, savedRecipeRepository: SavedRecipeRepository? = nil, customItemRepository: (any CustomItemRepositoring)? = nil, coinLedgerRepository: (any CoinLedgerRepositoring)? = nil, milestoneLedgerRepository: (any MilestoneLedgerRepositoring)? = nil, healthKitService: (any HealthKitServicing)? = nil, journalNarrativeRepository: (any JournalNarrativeStoring)? = nil, foodCatalog: FoodCatalog = .bundled(), sensitiveVisibilityDefaults: UserDefaults = .standard, aiAuditLogStore: AIAuditLogPersisting? = nil, appGroupDirectory: URL? = nil, sharedRecipeImportQueueFileURL: URL? = nil, photoDocumentsDirectory: URL? = nil, proximitySupportDirectory: URL? = nil, heartDropKeychainService: String? = nil, aiQuotaDefaults: UserDefaults = .standard, foodSearchCorrectionDefaults: UserDefaults = .standard) {
        // Assigned FIRST: the own-photo corpora, the escrow coordinator and the launch key migration
        // all read it, and the migration kicks off at the end of this initializer.
        self.photoDocumentsDirectory = photoDocumentsDirectory ?? Self.defaultPhotoDocumentsDirectory
        self.proximitySupportRoot = proximitySupportDirectory ?? ProximitySupportLayout.defaultDirectory
        self.heartDropKeychainService = heartDropKeychainService ?? HeartDropStorageScope.production.keychainService
        self.appGroupDirectory = appGroupDirectory
        // A different app-group subdirectory from the one above, so it gets its own seam. Nil resolves
        // to the real `SharedRecipeImports/PendingRecipeURLs.json` — see `sharedRecipeImportQueue`.
        self.sharedRecipeImportQueue = SharedRecipeImportQueue(fileURL: sharedRecipeImportQueueFileURL)
        self.aiQuotaDefaults = aiQuotaDefaults
        self.foodSearchCorrectionDefaults = foodSearchCorrectionDefaults
        self.sensitiveVisibilityDefaults = sensitiveVisibilityDefaults
        self.ageAssurance = AgeAssuranceStore(defaults: sensitiveVisibilityDefaults)
        self.injectedAuditLogStore = aiAuditLogStore
        let initSignpostID = StartupTiming.begin("FernletStore.init")
        defer { StartupTiming.end("FernletStore.init", signpostID: initSignpostID) }

        let key = FernletDate.dayKey(for: date)
        assert(!key.isEmpty, "today key required")
        let activeRepository = StartupTiming.timed("CoreDataFernletRepository.init") {
            repository ?? CoreDataFernletRepository()
        }
        let snapshot = StartupTiming.timed("FernletRepository.loadSnapshot") {
            activeRepository.loadSnapshot(todayKey: key)
        }
        let services = Self.loadPerRowServicesSync(
            savedRecipeRepository: savedRecipeRepository,
            customItemRepository: customItemRepository,
            coinLedgerRepository: coinLedgerRepository,
            milestoneLedgerRepository: milestoneLedgerRepository
        )
        self.savedRecipeService = services.savedRecipe
        self.customItemService = services.customItem
        self.coinLedgerService = services.coinLedger
        self.milestoneLedgerService = services.milestoneLedger
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
        completeDiaryWiring()
        rebuildDerivedSignals()
        finishCommonWiring()
    }

    /// Builds and synchronously loads the four per-row services both initializers need (nil
    /// repository = the production default). Extracted so the two inits cannot drift.
    private static func loadPerRowServicesSync(
        savedRecipeRepository: SavedRecipeRepository?,
        customItemRepository: (any CustomItemRepositoring)?,
        coinLedgerRepository: (any CoinLedgerRepositoring)?,
        milestoneLedgerRepository: (any MilestoneLedgerRepositoring)?
    ) -> (savedRecipe: SavedRecipeService, customItem: CustomItemService,
          coinLedger: CoinLedgerService, milestoneLedger: MilestoneLedgerService) {
        let savedRecipeService = StartupTiming.timed("SavedRecipeService.init") {
            SavedRecipeService(repository: savedRecipeRepository ?? SavedRecipeRepository())
        }
        savedRecipeService.loadSync()
        let customItemService = StartupTiming.timed("CustomItemService.init") {
            CustomItemService(repository: customItemRepository ?? CustomItemRepository())
        }
        customItemService.loadSync()
        let coinLedgerService = StartupTiming.timed("CoinLedgerService.init") {
            CoinLedgerService(repository: coinLedgerRepository ?? CoinLedgerRepository())
        }
        coinLedgerService.loadSync()
        let milestoneLedgerService = StartupTiming.timed("MilestoneLedgerService.init") {
            MilestoneLedgerService(repository: milestoneLedgerRepository ?? MilestoneLedgerRepository())
        }
        milestoneLedgerService.loadSync()
        return (savedRecipeService, customItemService, coinLedgerService, milestoneLedgerService)
    }

    /// Post-construction wiring shared by BOTH initializers, part 1: hooks the freshly built diary
    /// onto the facade and reconciles the sensitive surfaces before any UI can read them.
    private func completeDiaryWiring() {
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
        // The 16+ intimacy gate. A closure rather than a cached `Bool` so it re-reads the observable
        // record on every call — that is what lets a view consulting `isIntimateLoggingAllowed` in its
        // body re-render when the verdict changes. `?? false` keeps a deallocated facade fail-closed.
        self.diary.attachAdultVerification { [weak self] in self?.ageAssurance.allows(.intimacy) ?? false }
        self.diary.ensureLocalDesignerID()
        // Apply the one-time period-visibility migration + the mixed-version fail-closed guard against the
        // just-loaded settings, BEFORE any UI reads `isPeriodTrackingVisible` or a save can persist.
        reconcileSensitiveSurfaceVisibility()
        syncCustomExerciseCatalog()
        self.connectionInspector.attachStore(self)
        proximityTrustVault.onChange = { [weak self] in self?.snapshotSaveCoordinator.schedule() }
        aiRetryQueueService.onChange = { [weak self] in self?.snapshotSaveCoordinator.schedule() }
    }

    /// Post-construction wiring shared by BOTH initializers, part 2: the ledger reconcile, the
    /// remote-change subscription and the AI audit sink. Runs last in either init.
    private func finishCommonWiring() {
        // Credit any active day not yet in the coin ledger (in the sync init this reuses the warm
        // `loadDays()` cache from the derived-signals rebuild). Idempotent — never double-grants.
        reconcileCoinLedger()
        snapshotSaveCoordinator.subscribeRemote { [weak self] in
            await self?.reloadFromRepository()
        }
        configureAIAuditLog()
        // Fix 1.10: hand the catalog this device's remembered corrections. Cheap (one small defaults
        // read) and done here rather than lazily, so the first typeahead keystroke of the session
        // already answers with the user's own choices.
        publishFoodSearchCorrectionAliases()
    }

    /// The async-load twin of the designated initializer: takes the snapshot and the
    /// already-loaded services from `FernletStore.load` and only does the cheap wiring here, so
    /// launch never repeats the store reads on the main thread. Keep the wiring in lockstep with
    /// the synchronous initializer.
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
        // Launch path: always the real container roots and the real keychain service (only tests
        // redirect them).
        self.photoDocumentsDirectory = Self.defaultPhotoDocumentsDirectory
        self.proximitySupportRoot = ProximitySupportLayout.defaultDirectory
        self.heartDropKeychainService = HeartDropStorageScope.production.keychainService
        // nil / `.standard` = the REAL app-group container and the real defaults. Never a unique
        // value here: the widget extension is a separate process with no seam, so an app that
        // resolved elsewhere would strand every widget tap in a file nothing drains — and the
        // sensitive-visibility sidecar is the launch's own memory of a hidden surface, so a fresh
        // suite per launch would read "never resolved" and re-derive from `sex` every single time.
        // The share extension is the same separate-process argument as the widget: it hand-copies its
        // own path resolution, so an app anywhere else strands every shared-in recipe.
        self.appGroupDirectory = nil
        self.sharedRecipeImportQueue = SharedRecipeImportQueue()
        self.aiQuotaDefaults = .standard
        // `.standard` on the launch path for the same reason as the sidecars above: this is the
        // device's own memory of the searches its owner corrected, and a fresh suite per launch would
        // forget every one of them.
        self.foodSearchCorrectionDefaults = .standard
        self.sensitiveVisibilityDefaults = .standard
        self.ageAssurance = AgeAssuranceStore(defaults: .standard)
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
        completeDiaryWiring()
        finishCommonWiring()
    }

    /// Wires the device-local AI audit-log sink into `AIAuditLog.shared` and adopts whatever survived
    /// the last relaunch. Runs before any AI call could record, so the in-memory session set adopts the
    /// persisted history rather than racing it. Device-local only — never synced/snapshot/exported.
    private func configureAIAuditLog() {
        let auditSink = aiAuditLogStore
        Task { await AIAuditLog.shared.configure(sink: auditSink) }
    }


    /// Today's 0–1 wellness score, recomputed on every read from the live day record, goal
    /// weights, derived nutrient gaps, and the (pre-gated) period/stress adjustments.
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

    /// The companion's mood band derived from `score` (sickness overrides), driving every
    /// companion render and the widget snapshot.
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
    ///
    /// A duress session (``duressSessionActive``) forces it shut regardless of the preference — the
    /// decoy's cycle half. Read-only and in-memory: the stored preference is untouched, so the
    /// surfaces come straight back when the real passcode clears the flag.
    var isPeriodTrackingVisible: Bool {
        guard !duressSessionActive else { return false }
        return settings.periodTrackingVisible ?? (settings.userProfile.sex == .female)
    }

    /// Whether intimate-activity surfaces are visible. Age is a separate, non-overridable floor —
    /// an adult who hides the feature and an under-18 user are both invisible, but for different
    /// reasons, and the UI must say the right one (see `intimacyHiddenReason`).
    ///
    /// A duress session forces it shut too, on the same terms as `isPeriodTrackingVisible`.
    var isIntimacyTrackingVisible: Bool {
        guard !duressSessionActive else { return false }
        return isIntimateLoggingAllowed && settings.intimacyTrackingVisible
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
                // R7: the re-upload is a success/failure signal. The coordinator's deferral flag keeps
                // the Settings banner honest on failure, so the audit line is the recovery here.
                if await !setSealedBackupEnabled(true, payloadType: .periodData) {
                    FernletAuditLog.log("sealedBackup.period.reuploadAfterUnhide.failed")
                }
            }
        }
    }

    func setIntimacyTrackingVisible(_ visible: Bool) {
        diary.setIntimacyTrackingVisible(visible)
        recordSensitiveVisibilityResolution()
        if !visible {
            diary.scrubHiddenHealthContext(periodVisible: isPeriodTrackingVisible, intimacyVisible: false)
        } else {
            settleIntimacyBackupAfterUnhide()
        }
    }

    /// The in-flight intimacy un-hide settle, held so the delete-all funnel can cancel it — the exact
    /// twin of `periodBackupSettleTask` and for the same reason (a settle suspended in the CloudKit
    /// fetch would otherwise resume after the wipe and re-insert logs into the just-emptied store).
    @ObservationIgnored var intimacyBackupSettleTask: Task<Void, Never>?

    /// Settles both halves of the sealed intimacy backup at the moment the gated log store becomes
    /// reachable again — the intimacy twin of `settlePeriodBackupAfterUnhide()`, and what makes the
    /// launch arm's "hidden only DEFERS; it restores when the user un-hides" claim true.
    ///
    /// Order is load-bearing and identical to period's:
    ///
    /// 1. **Restore first**, via the targeted `.payloadStoreOnly` path. The launch pass only restores
    ///    into a fresh install, and by the time someone un-hides, the day blob has synced down and the
    ///    device is permanently "not fresh" — so without this the sealed logs are unrestorable forever.
    ///    The targeted restore still refuses a non-empty store and still honors the one-way divergence
    ///    latch, so it can add data back but never overwrite or resurrect deleted logs.
    /// 2. **Re-upload second**, and only when the restore left nothing retryable AND a deferral is
    ///    actually outstanding. The retry re-checks `mayReuploadFromLocalStore(.intimacyLogs)`, so an
    ///    un-restored (empty) store can never replace the cloud copy with the single head record
    ///    `reconcileChunked` writes for a count of 0.
    private func settleIntimacyBackupAfterUnhide() {
        let preferences = StoragePreferencesStore.currentPreferences()
        guard preferences.sealedBackupIntimacyEnabled else { return }
        // A re-toggle while a settle is in flight replaces it — two concurrent settles could interleave
        // their restore/re-upload halves.
        intimacyBackupSettleTask?.cancel()
        intimacyBackupSettleTask = Task {
            if preferences.iCloudSyncEnabled {
                let outcome = await restoreIntimacyBackupTargeted()
                guard !outcome.isRetryable else { return }
            }
            guard !Task.isCancelled else { return }
            await retryDeferredSealedBackupIfNeeded(payloadType: .intimacyLogs)
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

    /// Publishes `settings.customExercises` into ``WorkoutExerciseCatalog``, the registry the planning
    /// engine, safety filter, rest guidance, and exercise picker all read.
    ///
    /// Called wherever settings become live — both inits and `apply(_:)` for a remote sync — because
    /// the registry is process-global while the settings blob is per-load. Missing the `apply(_:)`
    /// site would leave a device that synced a new exercise from another device unable to see it
    /// until relaunch; missing it after a wipe would leave a deleted exercise alive in the picker.
    /// Registration REPLACES rather than merges, so both directions hold.
    func syncCustomExerciseCatalog() {
        WorkoutExerciseCatalog.registerCustomExercises(settings.customExercises)
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
            // R7: an unwired context (nil) or a failed sidecar delete both leave HealthKit-derived
            // baselines on disk after the user opted out — named, since the toggle itself has no
            // failure surface to show.
            if stressScoringContext?.scrubStressLocalState() != true {
                FernletAuditLog.log("stress.scrubFailed", context: ["site": "optOutToggle"])
            }
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
    ///
    /// R7: the returned refusal is not discardable — a caller that grants goods must know whether the
    /// ledger actually debited (or had provably debited before).
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
            // The ledger's current rows, for the reset boundary inside: days BEFORE a wipe are never
            // re-derived. Day records keep no tombstones (the delete dialog discloses that another
            // device may re-add its most recent days), and a re-derived row carries a fresh
            // reconcile-time `createdAt` — post-boundary by construction — so without this the wiped
            // dated trail would come back through the day history. Not defaulted at the callee, so
            // this can't be forgotten.
            ledgerEntries: milestoneLedgerService.entries,
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

    /// The outcome of ``buyClothingItem(_:fromDesignerID:sellerName:sellerFingerprint:)``, which
    /// `FriendShopView` maps to user-facing messaging.
    ///
    /// `.bought` covers both a fresh purchase and the free re-grant of an already-paid item
    /// ("buy once, own forever, never charged twice"); the distinct refusals let the shop grid
    /// explain exactly why a buy didn't land.
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
        //
        // R7: the debit result is a decision, not a formality. The item is granted only when the ledger
        // actually debited OR the ref was provably paid before; any other refusal (a balance that moved
        // under the reload above) declines the purchase rather than handing out a free item.
        let debited = spendCoins(price, ref: item.id.uuidString)
        guard debited || alreadyPaid else { return .insufficientCoins }
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

    /// The outcome of ``listCustomItemForSale(id:price:)``, consumed by `WardrobeView` and the
    /// Creation Studio's listing confirmation to pick the right alert.
    ///
    /// The refusal cases are deliberately distinct so the UI never shows a misleading reason —
    /// a flagged name, a full shop, an unlistable item, and a banned store each get their own copy.
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

    /// Toggle away-delivery for hearts (bitchat adoptions Increment 3). Enforcement lives inside
    /// `HeartDropService` (queue and fetch both consult the setting), so flipping this off stops
    /// future syncs immediately.
    ///
    /// Turning it OFF also PURGES the dead-drop: the sealed records this device already uploaded are
    /// deleted from the CloudKit public database and the outbox is cleared. Leaving them was the old
    /// behavior and it was wrong — public-database records have no TTL, and once consent is gone
    /// nothing in the app is allowed to name them again, so the copies would sit there forever with
    /// nobody able to remove them. Consequence the Settings copy has to state: queued hearts that
    /// never made it out are dropped, not resumed on re-enable.
    ///
    /// The purge is best-effort over the network, so a failure is not swallowed: the outbox keeps the
    /// record names, `heartsAwayPurgePending` re-derives from them, Settings says so, and the
    /// foreground listener retries via `retryHeartsAwayPurgeIfNeeded()`.
    func setHeartsAwayDelivery(_ value: Bool) {
        settings.heartsAwayDelivery = value
        if value {
            // Re-enabling supersedes any pending purge: whatever survived is back under consent and
            // the service's own cleanup deletes it at the outbox expiry. Nothing to clear here —
            // `heartsAwayPurgePending` reads the consent flag, so it is already false.
            heartDropService.syncNow()
        } else {
            _ = startHeartDropPurgeIfNeeded()
        }
        snapshotSaveCoordinator.schedule()
    }

    /// True when consent is off but this device still has sealed hearts on the public database that a
    /// failed purge could not delete. Surfaced in Settings and retried on the next foreground.
    ///
    /// DERIVED from the outbox, never stored — the outbox already IS the durable record of what we
    /// uploaded, and a second on-disk flag would only add another trace of a feature the user has
    /// just opted out of. The in-memory flag this replaces was wrong on two paths:
    /// - it died with the process, so a purge that failed offline and was followed by an app kill was
    ///   forgotten entirely: nothing retried it, and this device's records stayed on the public
    ///   database indefinitely while the user read "off" as "removed" — there is no server-side
    ///   expiry, and `HeartDropOutbox.entryLifetime` prunes only the LOCAL outbox, so losing the
    ///   outbox loses the only handle that could delete them;
    /// - `heartsAwayDelivery` lives in the SYNCED snapshot, so withdrawing consent on another device
    ///   arrives here as a state change and never runs the setter a flag would have been set in.
    /// Reading it re-derives on both, because both are visible in (consent flag, outbox).
    var heartsAwayPurgePending: Bool {
        // Short-circuits on consent so the derived read can never be true while the feature is on,
        // which is what makes it safe to drive the retry directly off this value.
        guard !settings.heartsAwayDelivery else { return false }
        return heartDropService.hasStrandedDeadDropRecords()
    }

    /// True while a purge is between its capture and its remote delete. The retry seam fires from a
    /// listener chain that re-enters on every scene/tab/lock event, and each `purgeDeadDrop()` bumps
    /// the service's purge generation — so an unguarded second call would supersede the first
    /// mid-flight and multiply the delete round trips instead of finishing the one already running.
    @ObservationIgnored private var isPurgingHeartDropRecords = false

    /// The in-flight dead-drop purge, held so a retry can AWAIT it rather than spin on
    /// `isPurgingHeartDropRecords`. R2: the wait's bound is then that task's completion (a CloudKit
    /// round trip with its own timeouts), visible at the `await` — a yield-spin had no bound at all.
    /// Cleared by the task itself before it completes.
    @ObservationIgnored private var heartDropPurgeTask: Task<Void, Never>?

    /// Set when a WIPE-time purge failed: this device knowingly left sealed hearts on the CloudKit
    /// public database and, after `wipeForDeleteAll()`, can no longer name them. See the delete-all
    /// call site for why it is process-local and one-way.
    @ObservationIgnored private var strandedDeadDropRecordsFromWipe = false

    /// Retry seam for the foreground listener chain (ContentView), driven entirely by the derived
    /// state above: it costs nothing when nothing is outstanding, it picks up a purge owed from a
    /// previous launch, and it picks up consent withdrawn on another device — none of which the
    /// old setter-only wiring could see.
    func retryHeartsAwayPurgeIfNeeded() {
        Task { [weak self] in
            guard let self else { return }
            // Coalesce, don't stack: the listener chain re-enters on every scene/tab/lock
            // event, and a purge already in flight covers this one — waiting here would turn a
            // burst of foreground events into a queue of sequential delete round trips over the
            // same records. If the purge is still owed afterwards, the next event retries.
            guard !self.isPurgingHeartDropRecords else { return }
            // R7: `false` means nothing was owed (the common, benign case) — the fire-and-forget
            // seam has nothing to do with either answer, and the purge itself already reports its
            // own failure, so the value is consumed here and deliberately not acted on.
            _ = await self.retryHeartsAwayPurgeNow()
        }
    }

    /// Awaitable form of the retry seam, mirroring `HeartDropService.syncOnce()` vs `syncNow()`:
    /// production fires and forgets, tests await a settled state. Spinning on the fire-and-forget
    /// version instead made the purge tests flaky under full-suite load, where every `@MainActor`
    /// suite competes for the actor the detached Task needs.
    ///
    /// An in-flight purge is WAITED OUT, not declined (same pattern as `syncOnce()`'s
    /// `while isSyncing`): the toggle-off purge task can still be unwinding its failure when the
    /// retry arrives — under load that window stretches, and declining there meant a retry the
    /// caller was owed silently never ran (it also made the purge tests flaky in exactly that
    /// window). The reentrancy guard's job is preventing CONCURRENT purges, not refusing
    /// successors.
    func retryHeartsAwayPurgeNow() async -> Bool {
        // Wait out an in-flight purge by awaiting ITS task (R2) instead of spinning on the flag:
        // the bound is that task's completion, and the wait now also covers the window between a
        // purge being scheduled and the flag being set — which the spin could slip through.
        await heartDropPurgeTask?.value
        guard heartsAwayPurgePending else { return false }
        await startHeartDropPurgeIfNeeded().value
        return true
    }

    /// Starts the dead-drop purge (or returns the one already running) as a held task, so callers can
    /// await its completion. The task clears the handle before it finishes.
    private func startHeartDropPurgeIfNeeded() -> Task<Void, Never> {
        if let existing = heartDropPurgeTask { return existing }
        let task = Task { [weak self] in
            await self?.purgeHeartDropRecords()
            self?.heartDropPurgeTask = nil
        }
        heartDropPurgeTask = task
        return task
    }

    private func purgeHeartDropRecords() async {
        guard !isPurgingHeartDropRecords else { return }
        isPurgingHeartDropRecords = true
        defer { isPurgingHeartDropRecords = false }
        // Re-checked here, not only at the call site: the setter's task and a foreground retry can
        // both be in flight, and the user may have turned the feature back ON in between — purging
        // then would delete hearts they now expect to be delivered.
        guard !settings.heartsAwayDelivery else { return }
        // The retry is state-driven: a failed purge leaves the entries (and their record names) in
        // the outbox, which is exactly what `heartsAwayPurgePending` reads, so the recovery is
        // already wired. R7: name the failure anyway — a purge that never succeeds leaves sealed
        // hearts on the public database, and that must not be silent.
        if await !heartDropService.purgeDeadDrop() {
            FernletAuditLog.log("heartdrop.purge.deferred", context: ["site": "purgeHeartDropRecords"])
        }
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

    /// R3: most peer-supplied moderation rows accepted from ONE relay batch. Defense in depth at the
    /// store seam — a chatty verified peer must not be able to grow the device-local ledger without
    /// bound. Pinned to the WIRE cap rather than a second hand-picked number so the two can never
    /// drift: a batch larger than one payload's worth cannot legitimately exist, so this now never
    /// truncates in practice, which is the point. The bound that actually holds against a sustained
    /// flood is `ModerationLedger.maxRowsPerReporter` + its max-min-fair `bounded` eviction, which
    /// drains a loud reporter before a quiet one (or this device's own rows) loses anything.
    static let maxForeignModerationRowsPerBatch = ModerationReportPayload.maxReports

    /// Stores peers' verified moderation reports (from the one-hop relay) and re-evaluates bans.
    /// Oversized batches are truncated at this seam (R3).
    func ingestModerationRows(_ rows: [ModerationLedgerEntry]) {
        if rows.count > Self.maxForeignModerationRowsPerBatch {
            FernletAuditLog.log("moderation.foreignRows.batchTruncated", context: [
                "received": String(rows.count),
                "cap": String(Self.maxForeignModerationRowsPerBatch)
            ])
        }
        moderationLedger.ingestForeign(Array(rows.prefix(Self.maxForeignModerationRowsPerBatch)))
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
        // Scoped: cycle/intimacy are Private Hub data, so an unlock taken out on the progress-photo
        // strip or the App-lock settings page does NOT re-open these HealthKit reads.
        if !lockState.isUnlocked(for: .privateHub) {
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
    ///
    /// The `nil` is a failure signal, so the result is NOT discardable (R7): a caller that ignores
    /// it dismisses the nudge as if the food had been logged.
    func logNutrientSuggestionFood(_ source: CuratedFoodSource, date: String? = nil) -> Meal? {
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
    ///
    /// **KNOWN GAP, examined 2026-08-23 and deliberately not closed here — it is architectural.**
    /// This path commits WITHOUT consulting `MealResolution.needsReview`, so a background retry can
    /// replace a logged meal with a resolution the interactive flow would have paused for review.
    /// The only live caller is ``retryOldestMeal()``, which re-resolves a fabricated
    /// keyword-fallback meal, and neither available behaviour is right without a new surface:
    ///
    /// * committing anyway (today) changes a logged meal with nothing on screen saying so;
    /// * declining to commit is WORSE, not better — the thing it would preserve is
    ///   `MealParser.parse`'s invented macros, which have no catalog grounding at all, in favour of a
    ///   catalog-grounded resolution that is merely not confident.
    ///
    /// The real fix is a review surface for background re-estimation ("these logs were re-estimated,
    /// check them"), which is a product decision, not a refactor. Recorded rather than guessed at.
    /// Note also that `addResolvedMeal` (singular) above currently has no callers.
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

    /// Re-logs a past meal on today, dropping the source note and stamping it "Repeated".
    /// `mealType` files it in a specific slot (the log sheet's choice, or the by-time "Auto" rule a
    /// typed log follows); `nil` keeps the slot the passed-in meal already carries.
    @discardableResult func copyMeal(_ meal: Meal, mealType: MealType? = nil) -> Meal {
        diary.copyMeal(meal, mealType: mealType)
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

    /// Applies the Adjust-meal sheet's edits to the logged meal (today's diary row and its
    /// `recentMeals` twin), recomputing totals from the corrected snapshots.
    ///
    /// `componentSnapshots` distinguishes nil from empty: nil means the caller edited raw macros
    /// with no component information (existing snapshots are kept untouched); an EMPTY array is
    /// an explicit clear — the user removed every matched item (FOOD-05) — and must stick.
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
            // R7: today's write cannot fail (`mutateDay` mutates the live day), but the seam is
            // shared with past-day writes that can — so the verdict is named, not dropped.
            let written = diary.mutateDay(date: todayKey) { targetDay in
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
            if !written {
                FernletAuditLog.log("food.mealCorrection.saveFailed", context: ["date": todayKey])
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
        // nil = no component information (keep whatever the meal already has); an EMPTY array is
        // an explicit remove-all clear and flows through so `applyMealCorrection` empties the
        // meal's snapshots. Collapsing empty into nil here silently resurrected removed items.
        guard let componentSnapshots else { return (macros, Micronutrients(), nil) }
        guard componentSnapshots.isEmpty == false else {
            return (macros, Micronutrients(), componentSnapshots)
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
        meal.confidence = MealConfidence.corrected.token
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
    func saveMealPhoto(_ image: UIImage) -> UUID? {
        guard let data = image.jpegData(compressionQuality: 0.82) else { return nil }
        return mealPhotoStore.save(data)
    }

    /// Byte-path meal-photo save mirroring `saveRecipePhoto(data:)` / `addProgressPhoto(data:)`: seals
    /// the picked JPEG `Data` straight through the store's bounded ImageIO downscale (one normalize at
    /// q0.8) instead of the `UIImage` overload's redundant full-resolution `jpegData(0.82)` pre-encode.
    /// This is the double-JPEG-encode fix (§2.5) for the library-pick path — the ~190 MB / generation-
    /// loss landmine on the iPhone-11 floor that F1 makes photo→recipe fire far more often. Fail-closed
    /// (nil on non-image bytes or no key). Returns the new photo id.
    func saveMealPhoto(data: Data) -> UUID? {
        mealPhotoStore.save(data)
    }
    #endif

    // MARK: - Progress photos (#11 — the Move-tab timeline)

    /// The progress-photo timeline, newest first. Reads the sealed store on demand (the Move tab caches
    /// the result in view state and refreshes after a mutation, like `loadDays`), so there is no observed
    /// copy of these body-photo records held in app state.
    ///
    /// **The decoy's photo half.** Progress photos are sealed under `PrivateMediaKeyStore`'s OWN key,
    /// not the lock's content key, so the keyless decoy does not hide them by construction the way it
    /// hides journal and Worry Box rows — and a duress unlock entered on the photo strip's own gate
    /// satisfies `.progressPhotos`. Gating HERE, at the read seam that answers "what photos exist",
    /// is what makes the empty Fernlet actually empty of body photos; a check in the timeline view
    /// would be a display hint that the detail sheet, the widget, or the next surface could miss.
    /// Read-only and in-memory: not one byte is deleted or re-sealed, so the real passcode brings the
    /// whole strip straight back.
    func progressPhotoRecords() -> [ProgressPhotoRecord] {
        guard !duressSessionActive else { return [] }
        return progressPhotoStore.records()
    }

    /// The sealed bytes for one progress photo — the decrypt seam, so it carries the same duress gate
    /// as `progressPhotoRecords()` rather than trusting every caller to have filtered first.
    func progressPhotoData(for id: UUID) -> Data? {
        guard !duressSessionActive else { return nil }
        return progressPhotoStore.imageData(for: id)
    }

    func updateProgressPhotoCaption(id: UUID, caption: String?) {
        guard !duressSessionActive else { return }
        progressPhotoStore.updateCaption(id: id, caption: caption)
    }

    /// Edits a progress photo's capture date (the manual editor in the detail view). Backs onto the same
    /// fail-closed sealed-index rewrite as the caption edit.
    func updateProgressPhotoCapturedAt(id: UUID, date: Date) {
        guard !duressSessionActive else { return }
        progressPhotoStore.updateCapturedAt(id: id, date: date)
    }

    /// Library-pick entry point: seals the picked JPEG `Data` straight through the store's bounded ImageIO
    /// downscale (the ONLY decode), skipping the full-resolution-bitmap round trip that `UIImage.jpegData`
    /// forces. A 48 MP pick would otherwise materialise a ~190 MB bitmap and risk jetsam on the iPhone-11
    /// floor. `capturedAt` carries the photo's real (best-effort recovered) date so imports aren't pinned
    /// to "now". Returns the stored record, or nil when the bytes can't be sealed (fail-closed).
    func addProgressPhoto(data: Data, capturedAt: Date) -> ProgressPhotoRecord? {
        progressPhotoStore.add(data, capturedAt: capturedAt)
    }

    /// Deletes one progress photo. Inert during a duress session for the decoy's reversibility
    /// invariant: the strip renders empty there, so any delete reaching this far is somebody acting
    /// on photos they cannot see — and the decoy must destroy nothing.
    func deleteProgressPhoto(id: UUID) {
        guard !duressSessionActive else { return }
        progressPhotoStore.delete(id: id)
    }

    #if canImport(UIKit)
    /// Seals a new progress photo taken now. Returns the stored record (nil if the image couldn't be
    /// encoded/sealed). JPEG-encodes at source quality; the store downscales + re-encodes on the way in.
    func addProgressPhoto(_ image: UIImage, caption: String? = nil) -> ProgressPhotoRecord? {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        return progressPhotoStore.add(data, caption: caption, capturedAt: Date())
    }
    #endif

    #if DEBUG
    /// DEBUG-only seam for the demo/appearance seed: seals a progress photo with an EXPLICIT capture
    /// date so the seeded timeline shows a real spread rather than three photos stamped "now". Not on
    /// the shipping path — the app always captures at the current moment.
    func seedProgressPhoto(_ data: Data, caption: String?, capturedAt: Date) -> ProgressPhotoRecord? {
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
            // R7: today's branch always succeeds; a PAST-day repository write can fail, and a
            // dropped meal must not be invisible.
            if !diary.mutateDay(date: targetDate, { $0.meals.append(meal) }) {
                FernletAuditLog.log("diary.pastDayWriteFailed",
                                    context: ["op": "logRecipe", "dayKey": targetDate])
            }
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
        // A web re-import replaces any prior recipe from the same source URL under a NEW id (see
        // SavedRecipeService.add). The sealed photo is keyed by the recipe id and the photo store
        // lives HERE, not in StoreCore — so delete the superseded rows' photos before they become
        // unreachable, or every re-import strands one (auto-fetched default pictures would make
        // that routine, not rare). "Same source" must be the SAME normalized match the service's
        // supersede uses, or a row deleted there keeps its photo here.
        if let sourceURLString = recipe.webImport?.sourceURLString, !sourceURLString.isEmpty {
            for superseded in savedRecipeService.savedRecipes
            where superseded.id != recipe.id
                && RecipeSourceURLMatcher.urlsMatch(superseded.webImport?.sourceURLString ?? "", sourceURLString) {
                recipePhotoStore.delete(id: superseded.id)
            }
        }
        savedRecipeService.add(recipe)
    }

    /// The saved recipe already imported from `url`, matched under `RecipeSourceURLMatcher`
    /// normalization (case-insensitive scheme/host, fragment ignored, query significant), or `nil`.
    ///
    /// The zero-network duplicate check (owner decision 2026-08-09): both import paths — the
    /// foreground paste-a-URL sheet and the share-extension queue drain — consult this BEFORE
    /// fetching, and on a hit they surface/keep the existing recipe with no network at all.
    /// Refreshing an already-saved recipe is the explicit "Re-import from source" affordance
    /// (``reimportSavedRecipeFromSource(_:)``), never an implicit repeat import.
    func savedRecipe(matchingSourceURL url: URL) -> RecipeDefinition? {
        savedRecipeService.recipe(matchingSourceURL: url.absoluteString)
    }

    /// R2: the per-record retry cap for the share-extension import queue, named rather than a bare
    /// literal at the comparison — a record that fails this many times is dropped, not retried forever.
    private static let sharedRecipeImportMaxAttempts = 3

    /// R7: names a share-extension queue rewrite that did not land. Not recoverable inside the
    /// drain — the record simply survives, so the next foreground drain re-imports the recipe (a
    /// duplicate) or re-runs a page that should have self-destructed. The log line is what makes
    /// that duplicate diagnosable rather than mysterious.
    private func noteSharedRecipeQueueRewrite(_ didWrite: Bool, operation: String) {
        guard !didWrite else { return }
        FernletAuditLog.log("recipe.shareExtensionImport.queueRewriteFailed", context: ["operation": operation])
    }

    func processSharedRecipeImportQueue() async {
        guard !isProcessingSharedRecipeImportQueue else { return }
        isProcessingSharedRecipeImportQueue = true
        defer { isProcessingSharedRecipeImportQueue = false }

        let queue = sharedRecipeImportQueue
        let maxAge: TimeInterval = 7 * 24 * 3600
        for record in queue.records() {
            // R3 self-heal, checked BEFORE `URL(string:)` so a giant string is never parsed: the
            // extension rejects an oversize URL at enqueue, but a file poisoned by a pre-fix build —
            // or by an app/extension version skew during an update — still has to converge. Dropped
            // on the FIRST drain rather than retried.
            guard record.urlString.utf8.count <= SharedRecipeImportQueue.maxURLByteCount else {
                noteSharedRecipeQueueRewrite(queue.remove(record), operation: "removeOversizedURL")
                continue
            }
            guard let url = record.url else {
                noteSharedRecipeQueueRewrite(queue.remove(record), operation: "removeUnparseable")
                continue
            }
            if record.attemptCount >= Self.sharedRecipeImportMaxAttempts
                || Date().timeIntervalSince(record.queuedAt) > maxAge {
                noteSharedRecipeQueueRewrite(queue.remove(record), operation: "removeExpired")
                continue
            }
            // Zero-network duplicate skip (owner decision 2026-08-09): a queued URL that matches an
            // already-saved recipe is treated as SUCCESS — removed from the queue with no fetch and
            // no retry bookkeeping. Re-sharing a page you already imported should not re-download
            // it; refreshing is the detail page's explicit "Re-import from source" affordance.
            if savedRecipe(matchingSourceURL: url) != nil {
                noteSharedRecipeQueueRewrite(queue.remove(record), operation: "removeDuplicate")
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

            // Durability: the attempt is spent BEFORE the risky work, not in the `catch`. A record
            // whose page kills the app (a watchdog kill on a pathological page) or hangs the fetch
            // forever never reaches the catch, so it used to be retried on every launch — the same
            // failure, forever, with the queue never converging. The transient budget arm below
            // refunds it, keeping "a budget miss is not the page's fault" true.
            noteSharedRecipeQueueRewrite(
                queue.markAttemptStarted(record), operation: "markAttemptStarted"
            )
            do {
                // Ambient drain: userInvoked=false, so the `.sleepy` band falls back and the daily
                // budget is reserved for the user's own taps. A JSON-LD page still imports here without
                // AI (that path runs before any gate check), so a resting device only defers pages that
                // genuinely need the model.
                let importedRecipe = try await RecipeWebImporter.importRecipe(from: url, catalog: foodCatalog, aiEnabled: settings.aiStatus != .off, userInvoked: false, gate: aiGate)
                addSavedRecipe(RecipeDefinition(importedRecipe: importedRecipe))
                noteSharedRecipeQueueRewrite(queue.remove(record), operation: "removeImported")
            } catch RecipeWebImportError.aiBudgetExhausted {
                // Transient daily-budget fallback (clears at midnight) — NOT the page's fault. Don't burn
                // an attempt or remove the record; just stamp it deferred-for-today so the rest of today's
                // foreground drains skip re-fetching it. Tomorrow's key differs → it retries with a fresh
                // budget. `refundingStartedAttempt` gives back the attempt spent above — without it,
                // three resting days would silently delete a perfectly good queued recipe.
                noteSharedRecipeQueueRewrite(
                    queue.markBudgetDeferred(record, dayKey: todayKey, refundingStartedAttempt: true),
                    operation: "markBudgetDeferred"
                )
                FernletAuditLog.log("recipe.shareExtensionImport.deferred", context: [
                    "host": url.host() ?? "unknown",
                    "reason": "aiBudgetExhausted"
                ])
            } catch {
                let description = (error as? LocalizedError)?.errorDescription ?? "Could not import that recipe."
                noteSharedRecipeQueueRewrite(
                    queue.noteFailure(record, errorDescription: description), operation: "noteFailure"
                )
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

    /// Merges ONLY the notes field into the CURRENT saved row — the notes sheet's Done path.
    /// Writing the sheet's whole at-open snapshot back would revert any store update that landed
    /// while the sheet was up (a web-image suppression stamp, a CloudKit-refreshed row); merging
    /// the one edited field into the live row cannot. No-op when the recipe was deleted meanwhile.
    func updateSavedRecipeNotes(_ notes: String, forRecipeID recipeID: UUID) {
        guard var live = savedRecipeService.savedRecipes.first(where: { $0.id == recipeID }) else { return }
        live.notes = notes
        updateSavedRecipe(live)
    }

    func deleteSavedRecipe(_ recipe: RecipeDefinition) {
        savedRecipeService.delete(recipe)
        // The recipe's own photo is keyed by the recipe id, so it's cleaned up here rather than stranded.
        recipePhotoStore.delete(id: recipe.id)
        // Prune the device-local web-image attempt bookkeeping too — a deleted recipe's id must
        // not linger in the sidecar forever.
        RecipeWebImageAttemptMemory.clearAttempt(for: recipe.id, defaults: webImageAttemptDefaults)
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
    func removeWorkout(id: UUID, date: String) -> Bool {
        assert(!date.isEmpty, "workout date required")
        guard let workout = diary.loadDay(for: date).workouts.first(where: { $0.id == id }) else { return false }
        // A genuine Health import is read-only here; refuse so we never orphan / resurrect it.
        guard !workout.isHealthImported else { return false }

        // Reverse the guided completion while the committed plan + the row's name are still resolvable.
        if workout.loggedFromGuidedSession == true {
            reverseGuidedCompletion(for: workout, date: date)
        }

        // R7: the day write is the act this method reports on. A failed write (a past-day
        // repository failure) must not go on to tombstone the row and report a delete that never
        // happened — the caller's alert says so instead, and the row is still there to retry on.
        guard diary.removeWorkout(id: id, date: date) else {
            FernletAuditLog.log("workout.remove.failed", context: ["date": date])
            return false
        }

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

    /// Adds a journal entry to today. Sugar over ``addJournal(text:tag:date:)`` — see it for the
    /// bookkeeping, which is identical because today IS just the `date == todayKey` case.
    func addJournal(text: String, tag: FeelingTag) {
        addJournal(text: text, tag: tag, date: todayKey)
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
            // The same append + seal + previousJournals bookkeeping as `addJournal`, so it goes through
            // the same core. The only thing the core adds is the `MemoryNote.fromJournal` call, which
            // returns nil below 20 characters — a tag-only check-in has empty text, so it can never mint
            // a memory. Sealing is likewise a no-op for empty text, which is what lets a check-in work
            // while the private lock is closed.
            appendJournalEntry(JournalEntry(text: "", tag: tag, isQuickMood: true), date: todayKey)
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

    /// Commits the transactional Water sheet's drafted count for today in one write (2026-08-21
    /// redesign, artboard 2c). Clamped 0…30 at the diary boundary; rides the same
    /// `mutateDay`/save-coordinator path as `addBottle`, so the widget mirror and milestone
    /// catch-up follow from the flush exactly as per-tap writes did.
    func setTodayBottleCount(_ count: Int) {
        diary.setBottleCount(count, date: todayKey)
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

    /// Whether the sealed JOURNAL backup still owes an upload — turned on from Settings while the
    /// Private tab held no unlock, skipped by an escrow adopt, or waiting on a store this device has not
    /// restored into yet. Same persistence and surfacing contract as
    /// ``sealedBackupPeriodReuploadDeferred``; discharged by the launch pass or the next `.privateHub`
    /// unlock, both of which re-check the empty-store guard first.
    private(set) var sealedBackupJournalReuploadDeferred =
        StoragePreferencesStore.currentPreferences().sealedBackupJournalReuploadDeferred

    /// Whether the sealed INTIMACY backup still owes an upload. Same contract as the journal flag, plus
    /// the hidden-surface case: while intimacy is hidden the export cannot page the gated store, so the
    /// obligation is recorded and discharged by the un-hide settle.
    private(set) var sealedBackupIntimacyReuploadDeferred =
        StoragePreferencesStore.currentPreferences().sealedBackupIntimacyReuploadDeferred

    /// Seals + uploads (or deletes) the encrypted CloudKit backup for a payload; returns whether it
    /// succeeded. Delegates to `SealedBackupCoordinator`.
    func setSealedBackupEnabled(_ enabled: Bool, payloadType: SealedBackupPayloadType) async -> Bool {
        await sealedBackupCoordinator.setSealedBackupEnabled(enabled, payloadType: payloadType)
    }

    /// Discharges a period re-upload that was deferred because the sealed narratives weren't readable
    /// at the time (typically: the user turned the backup on from Settings while the Private tab held
    /// no unlock). Driven from the lock-state observer when `.privateHub` unlocks. Delegates to
    /// `SealedBackupCoordinator`, which owns the guards and is a no-op when nothing is outstanding.
    func retryDeferredSealedPeriodBackupIfNeeded() async {
        await sealedBackupCoordinator.retryDeferredPeriodReuploadIfNeeded()
    }

    /// Discharges a deferred re-upload of any paged payload. Same contract as
    /// `retryDeferredSealedPeriodBackupIfNeeded()`: the coordinator owns the guards (sync on, pref on,
    /// deferral outstanding, and the local store actually exportable) and it is a no-op otherwise.
    func retryDeferredSealedBackupIfNeeded(payloadType: SealedBackupPayloadType) async {
        await sealedBackupCoordinator.retryDeferredReuploadIfNeeded(payloadType: payloadType)
    }

    /// Pulls any sealed iCloud backups into the local stores at launch (and on the user's Retry, which
    /// passes `userInitiated: true` so the period half can use the targeted restore).
    /// Delegates to `SealedBackupCoordinator`, then to `OwnPhotoBackupCoordinator` for the own-photo
    /// escrow route — one launch/adopt seam for both, so the photo route is retried by the same
    /// banner button and the same launch pass as everything else. Both are no-ops unless their own
    /// preference is on.
    ///
    /// `userInitiated` also makes the photo pass a FULL one (every photo's bytes read and hashed);
    /// the ambient launch pass compares id sets only, so launching never decrypts a whole photo
    /// library on the main actor.
    func restoreSealedBackupsIfNeeded(userInitiated: Bool = false) async {
        await sealedBackupCoordinator.restoreSealedBackupsIfNeeded(userInitiated: userInitiated)
        // The photo route runs on its own opt-in and is deliberately NOT gated on `iCloudSyncEnabled`
        // — see `OwnPhotoBackupCoordinator.synchronize`. Gating only the ambient pass gave a
        // sync-off user exactly one upload attempt ever, with no retry from here and none from the
        // banner's Retry button, while the key was device-bound on the strength of it.
        // The pass records its own verdict on this store (`ownPhotoBackupStatus` +
        // `ownPhotoBackupUploadFailed`, which the Privacy & Data banner reads), so there is no
        // decision left for this seam — the value is consumed and deliberately not re-derived here.
        _ = await ownPhotoBackupCoordinator.synchronize(fullVerification: userInitiated)
    }

    /// Whether the own-photo escrow backup is on, and its last pass's outcome — observable so the
    /// Privacy & Data banner can surface a deferred/failed photo restore instead of swallowing it
    /// (WS-4). Nil until a pass has run in this session.
    private(set) var ownPhotoBackupStatus: SealedBackupRestoreOutcome?

    /// Whether the last own-photo pass's UPLOAD leg failed — observable for the same WS-4 reason,
    /// and separate from `ownPhotoBackupStatus` because that vocabulary is restore-phrased.
    ///
    /// A device that HAS photos never enters the restore branch, so without this an upload that
    /// reached nothing publishes `.nothingToRestore` (`needsAttention == false`) and the banner
    /// renders nothing at all — for the life of the install.
    private(set) var ownPhotoBackupUploadFailed = false

    /// Records an own-photo backup pass's outcome (``OwnPhotoBackupContext``).
    func recordOwnPhotoBackupOutcome(_ outcome: SealedBackupRestoreOutcome) {
        ownPhotoBackupStatus = outcome
    }

    /// Records whether the own-photo backup's upload leg failed (``OwnPhotoBackupContext``).
    func recordOwnPhotoBackupUploadFailed(_ failed: Bool) {
        ownPhotoBackupUploadFailed = failed
    }

    /// Turns the own-photo escrow backup on or off; returns whether it succeeded, so the caller only
    /// persists the preference on success. Delegates to `OwnPhotoBackupCoordinator`.
    ///
    /// Switching it ON can newly satisfy the step-5c binding gate (it is the sanctioned cross-device
    /// route), so the gate is re-evaluated here rather than left until the next launch — the photos
    /// are covered from the moment the first pass commits. Turning it OFF never un-binds: consent to
    /// device-binding is one-way, and a bound row whose backup was removed is still the custody the
    /// user asked for.
    ///
    /// The gate is asked with the pass's COMMIT PROOF, never with the preference. "The switch is on"
    /// is intent; "a manifest reached iCloud" is a route. Binding is irreversible, so it may only
    /// follow the second — see `OwnPhotoEscrowCommitLedger`.
    func setOwnPhotoBackupEnabled(_ enabled: Bool) async -> Bool {
        let succeeded = await ownPhotoBackupCoordinator.setEnabled(enabled)
        if succeeded && enabled {
            let outcome = OwnPhotoKeyBinder(
                escrowRouteCommitted: OwnPhotoEscrowCommitLedger().isCommitted
            ).bindIfEligible()
            recordOwnPhotoKeyBindingOutcome(outcome)
        }
        if succeeded && !enabled {
            // The route is gone, so a stale upload-failure banner would be reporting a problem the
            // user has just resolved by removing the thing that had it.
            recordOwnPhotoBackupUploadFailed(false)
        }
        return succeeded
    }

    /// Deletes every own-photo escrow record (all three corpora, bodies + manifests) and clears the
    /// photo generation namespace — the "delete everything" leg for the photo route
    /// (Docs/PrivacyWipeCoverage.md). Returns whether every corpus cleared.
    func deleteOwnPhotoEscrowBackups() async -> Bool {
        await ownPhotoBackupCoordinator.tearDownForDeleteAll()
    }

    /// WS-3 user-confirmed conflict resolution: adopt the synced (other-device) escrow key and re-upload
    /// enabled backups. Delegates to `SealedBackupCoordinator`.
    func resolveSealedBackupEscrowConflict() async -> Bool {
        await sealedBackupCoordinator.adoptSyncedEscrowAndReupload()
    }

    /// Fetches/decrypts/writes a single sealed-backup payload into the local stores; returns whether
    /// records were restored. Delegates to `SealedBackupCoordinator`; kept as a wrapper for the
    /// restore tests.
    func restoreSealedBackup(payloadType: SealedBackupPayloadType) async -> Bool {
        await sealedBackupCoordinator.restoreSealedBackup(payloadType: payloadType)
    }

    /// Fetches/decrypts/writes a single sealed-backup payload AND records the rich outcome on the
    /// observable status so the UI can surface a non-silent, retryable result (WS-4). Delegates to
    /// `SealedBackupCoordinator`.
    func restoreSealedBackupOutcome(payloadType: SealedBackupPayloadType) async -> SealedBackupRestoreOutcome {
        await sealedBackupCoordinator.restoreSealedBackupOutcome(payloadType: payloadType)
    }

    /// Targeted period-only restore (un-hide + explicit Retry) — the compensating restore path for the
    /// fresh-install-only launch pass. Delegates to `SealedBackupCoordinator`.
    func restorePeriodBackupTargeted(
        narrativeRepository: MenstrualNarrativeRepository? = nil
    ) async -> SealedBackupRestoreOutcome {
        await sealedBackupCoordinator.restorePeriodBackupTargeted(narrativeRepository: narrativeRepository)
    }

    /// Targeted journal-only restore (the `.privateHub` unlock + explicit Retry) — the compensating
    /// restore path for the fresh-install-only launch pass. Delegates to `SealedBackupCoordinator`.
    func restoreJournalBackupTargeted(
        journalRepository: JournalNarrativeRepository? = nil
    ) async -> SealedBackupRestoreOutcome {
        await sealedBackupCoordinator.restoreJournalBackupTargeted(journalRepository: journalRepository)
    }

    /// Targeted intimacy-only restore (un-hide, `.privateHub` unlock, explicit Retry) — the
    /// compensating restore path for the fresh-install-only launch pass. Delegates to
    /// `SealedBackupCoordinator`.
    func restoreIntimacyBackupTargeted(
        intimacyStore: IntimacyLogStore? = nil
    ) async -> SealedBackupRestoreOutcome {
        await sealedBackupCoordinator.restoreIntimacyBackupTargeted(intimacyStore: intimacyStore)
    }

    /// Decodes a decrypted sealed-backup payload into the local stores, returning records written.
    /// Delegates to `SealedBackupCoordinator`; kept as a wrapper for the restore tests.
    @discardableResult
    func applyRestoredPayload(
        _ plaintext: Data,
        payloadType: SealedBackupPayloadType,
        narrativeRepository: MenstrualNarrativeRepository? = nil,
        journalRepository: JournalNarrativeRepository? = nil,
        intimacyStore: IntimacyLogStore? = nil,
        scope: SealedBackupCoordinator.RestoreScope = .freshInstall
    ) throws -> Int {
        try sealedBackupCoordinator.applyRestoredPayload(
            plaintext,
            payloadType: payloadType,
            narrativeRepository: narrativeRepository,
            journalRepository: journalRepository,
            intimacyStore: intimacyStore,
            scope: scope
        )
    }

    /// Decodes the decrypted chunks of a sealed-backup payload into the local stores, returning records
    /// written. Delegates to `SealedBackupCoordinator`; kept as a wrapper for the restore tests.
    @discardableResult
    func applyRestoredChunks(
        _ chunks: [Data],
        payloadType: SealedBackupPayloadType,
        narrativeRepository: MenstrualNarrativeRepository? = nil,
        journalRepository: JournalNarrativeRepository? = nil,
        intimacyStore: IntimacyLogStore? = nil
    ) throws -> Int {
        try sealedBackupCoordinator.applyRestoredChunks(
            chunks,
            payloadType: payloadType,
            narrativeRepository: narrativeRepository,
            journalRepository: journalRepository,
            intimacyStore: intimacyStore
        )
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

    /// Adds a journal entry to `date` — the ONE journal-append path, for today and for past days
    /// alike. ``addJournal(text:tag:)`` and ``logQuickMood(_:)``'s new-entry branch both funnel
    /// through `appendJournalEntry(_:date:)` below.
    func addJournal(text: String, tag: FeelingTag, date: String) {
        appendJournalEntry(JournalEntry(text: text, tag: tag), date: date)
    }

    /// Seals `entry`, writes it into `date`'s journals, and runs the today-only side bookkeeping.
    ///
    /// The whole today-vs-past-date difference lives in `diary.mutateDay`, which is why this is one
    /// function and not two:
    /// - **today** — `mutateDay` mutates the live `day` in place and schedules ONE debounced snapshot
    ///   save, exactly what the old today-only overload's `batchSnapshotPersistence` did (that wrapper
    ///   is literally "run the closure, then `scheduleSnapshotSave()`"). Scheduling before rather than
    ///   after the `previousJournals`/`memories` updates is immaterial: the coordinator debounces and
    ///   calls `buildSnapshot()` at FIRE time, so the save serializes the final state either way.
    /// - **past date** — `mutateDay` routes to `mutatePastDay`, which loads that day's repository row,
    ///   applies the change, and writes it straight back through the `SanitizedDay` privacy barrier.
    ///   No snapshot save is scheduled because past days do not live in the aggregate snapshot at all,
    ///   and the write is synchronous rather than debounced. Collapsing the two paths onto
    ///   `batchSnapshotPersistence` would have written a past-day journal into TODAY's record.
    ///
    /// The `previousJournals` / `memories` bookkeeping is deliberately today-only. Both are
    /// today-scoped views (the "recent entries" strip and the memory pool feeding the companion), so
    /// back-dating an entry must not push it to the front of "recent" or mint a memory as if it had
    /// just been written. `MemoryNote.fromJournal` additionally rejects anything under 20 characters,
    /// so a tag-only mood check-in never mints a memory even though it flows through here.
    private func appendJournalEntry(_ entry: JournalEntry, date: String) {
        assert(!date.isEmpty, "journal date required")
        journalSealingCoordinator.seal(entry, dayKey: date)
        // R7: the narrative is already sealed above. If the past-day row write fails, the sealed
        // text exists with no journal skeleton pointing at it — log rather than lose it silently.
        if !diary.mutateDay(date: date, { $0.journals.append(entry) }) {
            FernletAuditLog.log("diary.pastDayWriteFailed",
                                context: ["op": "journalAppend", "dayKey": date])
        }
        guard date == todayKey else { return }
        previousJournals.insert(entry, at: 0)
        previousJournals = Array(previousJournals.prefix(30))
        if let memory = MemoryNote.fromJournal(text: entry.text, tag: entry.tag) {
            memories.append(memory)
            memories = Array(memories.suffix(300))
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
            let written = diary.mutateDay(date: date) { targetDay in
                guard let index = targetDay.journals.firstIndex(where: { $0.id == entry.id }) else { return }
                targetDay.journals[index] = updatedEntry
            }
            if !written {
                FernletAuditLog.log("diary.pastDayWriteFailed",
                                    context: ["op": "journalUpdate", "dayKey": date])
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
            if !diary.mutateDay(date: date, { $0.journals.removeAll { $0.id == entry.id } }) {
                FernletAuditLog.log("diary.pastDayWriteFailed",
                                    context: ["op": "journalDelete", "dayKey": date])
            }
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
    /// On THIS store's app-group root. `resetAll` clears this file and `GuidedWorkoutRunStoreTests`
    /// reads it, so the process-wide container was a live cross-suite race, not a latent one.
    @ObservationIgnored private lazy var guidedRunStateStore =
        GuidedWorkoutRunStateStore(directory: appGroupDirectory)
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
        mirrorGuidedRunState(state)
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

    /// Mirrors a guided-run transition to the app-group file, naming a failed write (R7).
    ///
    /// Recovery is the next event: the following transition rewrites the file and the foreground
    /// reconcile re-reads it. What must not happen is silence — while the file is stale the Live
    /// Activity's buttons drive a run it no longer describes.
    private func mirrorGuidedRunState(_ state: GuidedWorkoutRunState) {
        if !guidedRunStateStore.write(state) {
            FernletAuditLog.log("widget.runstate.write.failed", context: ["file": "guided"])
        }
    }

    /// Clears the guided run's app-group file, naming a failure (R7): a surviving file is re-adopted
    /// by the next `reconcileGuidedRunFromAppGroup`, which is how a finished run comes back.
    private func clearGuidedRunStateFile() {
        if !guidedRunStateStore.clear() {
            FernletAuditLog.log("widget.runstate.clear.failed", context: ["file": "guided"])
        }
    }

    /// Shared handling after an in-app transition: mirror to the group + reflect onto the activity;
    /// on a natural finish, log the workout (deduped) and end the activity; keep the done state in
    /// memory so the sheet can show its "nicely done" screen.
    private func applyGuidedTransition(_ state: GuidedWorkoutRunState) {
        guidedRunState = state
        if state.isDone {
            // Clear the group file first so a foreground reconcile racing this can't re-log the finish.
            clearGuidedRunStateFile()
            if state.completedNaturally { finishGuidedRunLogging(state) }
            syncActivity { await GuidedWorkoutActivityBridge.end() }
        } else {
            mirrorGuidedRunState(state)
            syncActivity { await GuidedWorkoutActivityBridge.sync(to: state) }
        }
    }

    /// Abandon the active run (the sheet's "End without logging"): nothing is logged. Clears the group
    /// file and ends the activity.
    func abandonGuidedRun() {
        guard guidedRunState != nil else { return }
        guidedRunState = nil
        clearGuidedRunStateFile()
        syncActivity { await GuidedWorkoutActivityBridge.end() }
    }

    /// Clear a finished run once the user closes the done screen (the activity was already ended on
    /// finish).
    func clearGuidedRun() {
        guidedRunState = nil
        clearGuidedRunStateFile()
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
            clearGuidedRunStateFile()
            guidedRunState = fileState.completedNaturally ? fileState : nil
            if fileState.completedNaturally { finishGuidedRunLogging(fileState) }
            syncActivity { await GuidedWorkoutActivityBridge.end() }
            return
        }
        // Active run. Retire only one untouched for hours (abandoned — the process outlived it); a
        // recently-touched run, even one resting across midnight, is adopted so it stays resumable.
        if Date().timeIntervalSince(fileState.updatedAt) > GuidedWorkoutRunState.abandonedAfter {
            guidedRunState = nil
            clearGuidedRunStateFile()
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
    // On the shared `appGroupDirectory` seam with its guided twin and the widget queue. Production
    // leaves it nil (the real app-group container); isolating it per test stops a parallel suite's
    // `deleteAllData`/cooking-wipe from racing the file this store is reading.
    @ObservationIgnored private lazy var cookingRunStateStore =
        CookingRunStateStore(directory: appGroupDirectory)
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
    ///
    /// Discardable by design (R7): `nil` means the recipe has no steps — a property of the recipe the
    /// caller already knows (the walker entry point is gated on it), not a failure to report.
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
        mirrorCookingRunState(state)
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

    /// Mirrors a cooking-run transition to the app-group file, naming a failed write (R7) — the
    /// cooking twin of ``mirrorGuidedRunState(_:)``, with the same next-event recovery.
    private func mirrorCookingRunState(_ state: CookingRunState) {
        if !cookingRunStateStore.write(state) {
            FernletAuditLog.log("widget.runstate.write.failed", context: ["file": "cooking"])
        }
    }

    /// Clears the cooking run's app-group file, naming a failure (R7): a surviving file is re-adopted
    /// by the next `reconcileCookingRunFromAppGroup`.
    private func clearCookingRunStateFile() {
        if !cookingRunStateStore.clear() {
            FernletAuditLog.log("widget.runstate.clear.failed", context: ["file": "cooking"])
        }
    }

    /// Shared handling after an in-app cooking transition: mirror to the group + reflect onto the
    /// activity. On a finish the group file is cleared FIRST (so a racing foreground reconcile can't
    /// resurrect a done run) and the activity ended; the in-memory state is kept so the walker can show
    /// its finish screen. There is no automatic meal log — logging is the cook's explicit choice.
    private func applyCookingTransition(_ state: CookingRunState) {
        cookingRunState = state
        if state.isFinished {
            clearCookingRunStateFile()
            syncActivity { await CookingActivityBridge.end() }
        } else {
            mirrorCookingRunState(state)
            syncActivity { await CookingActivityBridge.sync(to: state) }
        }
    }

    /// End the active cooking run (the walker's Close, a completed-and-logged session, or the resume
    /// card's Discard). Clears the group file and ends the cooking activity. Idempotent.
    func endCookingRun() {
        guard cookingRunState != nil else {
            // No in-memory run, but a group file (or orphan activity) may linger after a cold path.
            clearCookingRunStateFile()
            syncActivity { await CookingActivityBridge.end() }
            return
        }
        cookingRunState = nil
        clearCookingRunStateFile()
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
            clearCookingRunStateFile()
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
            clearCookingRunStateFile()
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

    func saveCustomIngredient(_ ingredient: ManualRecipeIngredientInput) -> FoodItem? {
        diary.saveCustomIngredient(ingredient)
    }

    func cachedWebImportedFoodProduct(for query: String) -> FoodItem? {
        diary.cachedWebImportedFoodProduct(for: query)
    }

    // MARK: - Local correction memory (research §26 fix 1.10)

    /// Remembers the corrections a SAVED "Adjust meal" made — one per component the user replaced,
    /// pairing the text they searched with the food they chose — and republishes the alias snapshot so
    /// the next search for that text answers with their own choice first.
    ///
    /// Called from the sheet's Save, never from the pick itself: a correction the user cancels out of
    /// must not teach the app anything. Device-local and never synced (see
    /// ``FoodSearchCorrectionMemory``).
    func rememberFoodSearchCorrections(_ corrections: [FoodSearchCorrection]) {
        guard !corrections.isEmpty else { return }
        FoodSearchCorrectionMemory.remember(corrections, defaults: foodSearchCorrectionDefaults)
        publishFoodSearchCorrectionAliases()
    }

    /// Pushes the persisted correction memory into `foodCatalog` — at launch, after every write, and
    /// after a wipe (where it publishes an EMPTY map, so corrections stop answering searches in the
    /// live process instead of surviving until relaunch).
    func publishFoodSearchCorrectionAliases() {
        foodCatalog.setSearchAliases(FoodSearchCorrectionMemory.aliases(defaults: foodSearchCorrectionDefaults))
    }

    /// Forgets every remembered search correction — and NOTHING else.
    ///
    /// The user-facing escape hatch for a surface that is otherwise invisible and permanent: a
    /// correction is learned from one tap, is never listed anywhere, and has no per-entry undo, so
    /// "delete everything" was the only way to unlearn a mistake. Settings routes here through
    /// `DestructiveConfirmation` like every other data-destroying control.
    ///
    /// - Returns: how many corrections were forgotten, so the caller can say so rather than claiming
    ///   an outcome it did not check.
    @discardableResult func forgetAllFoodSearchCorrections() -> Int {
        let forgotten = FoodSearchCorrectionMemory.aliases(defaults: foodSearchCorrectionDefaults).count
        FoodSearchCorrectionMemory.clearAll(defaults: foodSearchCorrectionDefaults)
        publishFoodSearchCorrectionAliases()
        FernletAuditLog.log("food.searchCorrections.forgotten", context: ["count": "\(forgotten)"])
        return forgotten
    }

    /// How many searches this device currently remembers a correction for — drives the Settings row's
    /// count and lets it hide itself when there is nothing to forget.
    var foodSearchCorrectionCount: Int {
        FoodSearchCorrectionMemory.aliases(defaults: foodSearchCorrectionDefaults).count
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

    /// Deletes the recipe's sealed photo AND suppresses the recipe's web image (synced): deleting
    /// the picture is the user's stated intent about this recipe's picture, so a web-derived
    /// default must never resurrect behind it — on this device or, via the synced row, any other
    /// (a no-op for recipes with no `webImport`).
    func deleteRecipePhoto(for recipeID: UUID) {
        recipePhotoStore.delete(id: recipeID)
        markRecipeWebImageSuppressed(recipeID)
    }

    #if canImport(UIKit)
    /// Seals the user's own photo for a recipe. Keyed by
    /// the recipe id so there's no separate id to thread through `RecipeDefinition`.
    func saveRecipePhoto(_ image: UIImage, for recipeID: UUID) -> Bool {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return false }
        return recipePhotoStore.save(data, forID: recipeID)
    }
    #endif

    /// Library-pick entry point mirroring `addProgressPhoto(data:)`: seals the picked JPEG `Data` straight
    /// through the store's bounded ImageIO downscale, so a full-resolution library pick isn't decoded into
    /// a giant bitmap just to be re-encoded. Fail-closed (false on non-image bytes or no key).
    func saveRecipePhoto(data: Data, for recipeID: UUID) -> Bool {
        recipePhotoStore.save(data, forID: recipeID)
    }

    /// Downloads a web-imported recipe's page picture and seals it as the recipe's default photo —
    /// one automatic attempt PER DEVICE (owner decision 2026-08-09, reversing the 2026-07-16 "no
    /// external image fetch" tester decision), with suppression synced: the photo bytes are
    /// device-local, so each device gets its own single attempt (``RecipeWebImageAttemptMemory``),
    /// while the user's intent that no web picture may ever be fetched
    /// (`RecipeWebImport.webImageSuppressed`) rides the synced row and wins everywhere.
    ///
    /// Called only from USER-PRESENT paths: the foreground paste-a-URL import, the first open of a
    /// recipe's detail page, and the post-"Re-import from source" refresh — never from the
    /// share-extension background queue drain. Entry gates: the recipe must carry an
    /// `imageURLString`, must not be suppressed (checked on the LIVE row, not just the caller's
    /// copy), must not have spent this device's one attempt, must not already be downloading (the
    /// paste-import task and the detail's first-open task can overlap), and must have no photo yet
    /// (the user's own picked photo always wins — finding one suppresses, synced). After the
    /// download the same conditions are RE-CHECKED before anything is written: the await suspends
    /// up to 15 s while the UI stays live, so the user may have picked a photo, deleted the recipe,
    /// or deleted its photo mid-download — their state always beats the late bytes. Cooperative
    /// cancellation (the detail's `.task` dies when the view pops) is the user navigating, not a
    /// failed fetch, so it does NOT consume the attempt; a genuine failure does. Downloaded bytes
    /// go through ``saveRecipePhoto(data:for:)`` — the sealed store's normalize pipeline (bounded
    /// downscale + JPEG re-encode, which strips EXIF). A failed image can never fail an import.
    /// - Returns: The sealed, stored photo bytes when the fetch landed, else `nil`. Discardable by
    ///   design (R7): every caller is fire-and-forget decoration — a missing image is a recipe
    ///   without a picture, and the attempt ledger (not the caller) owns the retry decision.
    @discardableResult
    func fetchRecipeWebImageIfNeeded(for recipe: RecipeDefinition) async -> Data? {
        guard let webImport = recipe.webImport,
              webImport.webImageSuppressed != true,
              let urlString = webImport.imageURLString,
              let url = URL(string: urlString) else { return nil }
        // Gate on CURRENT state, not just the caller's copy: the passed value can predate a
        // suppression stamped by another path, and two user-present paths can hold the same
        // not-yet-attempted copy (the in-flight set makes the overlap a single download).
        guard let live = savedRecipeService.savedRecipes.first(where: { $0.id == recipe.id }),
              live.webImport?.webImageSuppressed != true,
              !RecipeWebImageAttemptMemory.hasAttempted(recipe.id, defaults: webImageAttemptDefaults),
              !webImageFetchesInFlight.contains(recipe.id) else { return nil }
        guard recipePhotoData(for: recipe.id) == nil else {
            // The user already picked their own photo — never fetch behind it, and suppress
            // (synced) so the web image never resurrects if that photo is later deleted.
            markRecipeWebImageSuppressed(recipe.id)
            return nil
        }
        webImageFetchesInFlight.insert(recipe.id)
        defer { webImageFetchesInFlight.remove(recipe.id) }
        let downloaded = try? await RecipeWebImporter.downloadImage(from: url)
        if downloaded == nil, Task.isCancelled {
            // Cooperative cancellation — popping the detail mid-download — is navigation, not a
            // failed fetch: leave the attempt un-spent so the next open retries.
            return nil
        }
        RecipeWebImageAttemptMemory.recordAttempt(recipe.id, defaults: webImageAttemptDefaults)
        // Post-await re-validation: `FernletStore` is MainActor, so deletes, photo picks, and
        // suppressions interleave exactly at the download suspension. Re-check every condition the
        // entry checked — a recipe deleted mid-download must not get an orphaned sealed photo, and
        // a photo the user picked mid-download must never be overwritten.
        guard let downloaded,
              let current = savedRecipeService.savedRecipes.first(where: { $0.id == recipe.id }),
              current.webImport?.webImageSuppressed != true,
              recipePhotoData(for: recipe.id) == nil else { return nil }
        // R7: a failed seal means there is no photo to hand back — say so rather than re-reading the
        // store and returning whatever happens to be there.
        guard saveRecipePhoto(data: downloaded, for: recipe.id) else { return nil }
        return recipePhotoData(for: recipe.id)
    }

    /// Persists `webImageSuppressed = true` on the SAVED recipe with `recipeID`, via the
    /// saved-recipe update path (so the intent rides the per-row payload blob and syncs). Reads the
    /// service's CURRENT row rather than any caller-held copy, so a concurrent edit is never
    /// clobbered. No-op for unknown ids, recipes without a `webImport`, and already-suppressed rows.
    private func markRecipeWebImageSuppressed(_ recipeID: UUID) {
        guard var current = savedRecipeService.savedRecipes.first(where: { $0.id == recipeID }),
              var webImport = current.webImport,
              webImport.webImageSuppressed != true else { return }
        webImport.webImageSuppressed = true
        current.webImport = webImport
        updateSavedRecipe(current)
    }

    /// Re-runs the web importer for a saved recipe's source page and replaces the definition IN
    /// PLACE — the explicit, user-invoked refresh that the zero-network duplicate skip
    /// (``savedRecipe(matchingSourceURL:)``) points repeat imports at.
    ///
    /// The refreshed row **keeps the recipe's id**, which is the whole preservation story: the
    /// sealed photo is keyed by that id, so reusing it carries the photo across with no
    /// delete/migrate dance, and the same-id route through ``updateSavedRecipe(_:)`` never runs
    /// the supersede path (which deletes superseded rows' photos). The user's notes,
    /// `createdAt`, fork provenance, and `webImageSuppressed` state are carried too — see
    /// `RecipeDefinition.init(reimported:preserving:)` for the exact merge. A thrown import
    /// (bad URL, network failure, no recipe on the page) mutates NOTHING: the merge+update runs
    /// only after the fetch succeeds.
    /// - Returns: The refreshed definition now in the saved-recipe store, or `nil` when the
    ///   recipe was deleted while the fetch was in flight (nothing was persisted).
    func reimportSavedRecipeFromSource(_ recipe: RecipeDefinition) async throws -> RecipeDefinition? {
        guard let sourceURL = recipe.webImport?.sourceURL, sourceURL.isSafariPresentable else {
            throw RecipeWebImportError.invalidURL
        }
        let imported = try await RecipeWebImporter.importRecipe(
            from: sourceURL,
            catalog: foodCatalog,
            aiEnabled: settings.aiStatus != .off,
            userInvoked: true,
            gate: aiGate
        )
        return applyReimportedRecipe(imported, to: recipe)
    }

    /// The no-network half of ``reimportSavedRecipeFromSource(_:)``, split out so tests can
    /// exercise the replace-and-preserve contract without a live fetch: merges the fresh import
    /// over the CURRENT saved row — re-resolved by id at write time, the same live-row rule as
    /// ``markRecipeWebImageSuppressed(_:)``, so notes edited or suppression stamped during the
    /// multi-second fetch are preserved rather than reverted by the caller's stale snapshot — and
    /// persists it through the saved-recipe update path. The explicit re-import also re-arms THIS
    /// device's one automatic web-image attempt (the synced suppression, if any, still wins), so a
    /// transiently failed picture download is recoverable through the documented refresh
    /// affordance.
    /// - Returns: The refreshed definition, or `nil` when the recipe no longer exists (deleted
    ///   mid-flight) — nothing is persisted then, so the caller must not report success.
    func applyReimportedRecipe(_ imported: ImportedRecipe, to existing: RecipeDefinition) -> RecipeDefinition? {
        guard let live = savedRecipeService.savedRecipes.first(where: { $0.id == existing.id }) else {
            return nil
        }
        let refreshed = RecipeDefinition(reimported: imported, preserving: live)
        updateSavedRecipe(refreshed)
        RecipeWebImageAttemptMemory.clearAttempt(for: existing.id, defaults: webImageAttemptDefaults)
        return refreshed
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
        var payload = RecipeShareCodec.proximityPayload(for: recipe, foodItems: foodCatalog.items(forRecipe: recipe))
        #if canImport(UIKit)
        // Attach the recipe's picture (the user's own pick or the web-derived default) as a
        // downscaled, size-capped JPEG so the receiving device gets it over the mesh and never
        // fetches the web for it. Decrypt + downscale happen HERE in the app target — ProximityKit
        // must never see the sealed store (S3 wall). No picture, or one that won't fit the wire
        // cap, simply ships without an image.
        if let photoData = recipePhotoData(for: recipe.id) {
            payload.imageJPEGData = RecipeShareCodec.wireImageJPEG(fromPhotoData: photoData)
        }
        #endif
        return payload
    }

    /// R3/R5 bounds for recipe payloads that arrive from OUTSIDE the app — pasted clipboard text and
    /// mesh shares. Each imported ingredient becomes a `foodItems` row inside the synced snapshot, so
    /// the count is the growth cap; the servings/quantity bounds keep a hostile payload from turning
    /// every later macro computation into a nonsense (or non-finite) number.
    enum RecipeImportLimits {
        /// Most ingredients one imported recipe may carry (extras are refused / dropped).
        static let maxIngredients = 60
        /// Most servings one imported recipe may claim.
        static let maxServings = 100
        /// Largest per-ingredient quantity accepted from a share.
        static let maxQuantity: Double = 10_000
    }

    /// What accepting a proximity recipe share did — surfaced by the review sheet so the user
    /// learns whether a new recipe landed or their existing copy was kept.
    enum ProximityRecipeImportOutcome: Equatable {
        /// The share was imported as a new recipe with the given display name.
        case imported(name: String)
        /// The shared source page was already in the recipe book: the user's existing recipe —
        /// photo, notes, and all — was kept untouched (the owner's duplicate decision, matching
        /// the paste-import and queue-drain paths), and only the social signal was recorded.
        case alreadySaved(name: String)

        /// The display name of the recipe the outcome refers to, whichever case carries it.
        var name: String {
            switch self {
            case .imported(let name), .alreadySaved(let name): name
            }
        }
    }

    /// What the `.saved` arm of a proximity share produced: either the user's existing recipe was
    /// kept (the owner's duplicate decision) or a new one was added.
    private enum SavedProximityImport {
        /// The shared source page was already in the book; the local recipe was left untouched.
        case keptExisting(name: String)
        /// A new recipe was built from the payload and added to the book.
        case added(RecipeDefinition)
    }

    @discardableResult func importProximityRecipeShare(_ payload: ProximityRecipeSharePayload,
                                                       fromFingerprint fingerprint: String? = nil) throws -> ProximityRecipeImportOutcome {
        guard payload.format == "fernlet.proximity.recipe", payload.version == 1 else {
            throw RecipeImportError.unsupportedFormat
        }

        let importedName: String
        let importedRecipeID: UUID
        switch payload.recipe.kind {
        case .local:
            let imported = try importLocalProximityRecipe(payload.recipe.local)
            importedName = imported.name
            importedRecipeID = imported.id
        case .saved:
            switch try importSavedProximityRecipe(payload.recipe.saved) {
            case .keptExisting(let name):
                // The closeness signal still records: the friend did share, the user did accept.
                if let fingerprint { closenessLedger.recordShareAccepted(fingerprint: fingerprint) }
                return .alreadySaved(name: name)
            case .added(let recipe):
                importedName = recipe.name
                importedRecipeID = recipe.id
            }
        }
        // The picture rides the mesh so the receiver does NO web fetch: seal the sender's
        // downscaled JPEG into this device's own private recipe-photo store, keyed by the freshly
        // created recipe. Bytes above the wire cap are dropped before a single pixel is decoded
        // (a hostile peer doesn't get to pick our decode cost); the sealed store's normalize
        // pipeline bounds and re-encodes whatever is accepted. Best-effort — a bad image never
        // fails the recipe import, but a seal that fails is logged rather than vanishing.
        if let imageData = payload.imageJPEGData,
           imageData.count <= ProximityRecipeSharePayload.maxImageBytes,
           recipePhotoData(for: importedRecipeID) == nil,
           !saveRecipePhoto(data: imageData, for: importedRecipeID) {
            FernletAuditLog.log("recipe.proximityShare.imageSealFailed")
        }
        // Accepting a friend's shared recipe feeds the closeness "share accepted" signal (day-capped).
        if let fingerprint { closenessLedger.recordShareAccepted(fingerprint: fingerprint) }
        return .imported(name: importedName)
    }

    /// The `.local` arm of a proximity share: re-encodes the payload and routes it through the
    /// shared `importRecipe(from:)` validation (caps + numeric sanity live there).
    private func importLocalProximityRecipe(_ localPayload: SharedRecipePayload?) throws -> RecipeDefinition {
        guard let localPayload else { throw RecipeImportError.invalidPayload }
        let data = try JSONEncoder().encode(localPayload)
        guard let text = String(data: data, encoding: .utf8) else { throw RecipeImportError.invalidPayload }
        return try importRecipe(from: text)
    }

    /// The `.saved` (web-import) arm of a proximity share: validates the peer-supplied payload,
    /// keeps an existing recipe for the same source page, otherwise builds and adds the recipe.
    private func importSavedProximityRecipe(_ savedPayload: SharedSavedRecipePayload?) throws -> SavedProximityImport {
        guard let savedPayload else { throw RecipeImportError.invalidPayload }
        let trimmedName = savedPayload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw RecipeImportError.emptyRecipe }
        // R5: every number below is peer-controlled, and "clamp at or above zero" is NOT the whole
        // contract — an `Int.max` macro traps the moment `Macros.calories` adds it, and a 1e300
        // micronutrient traps in the day-detail row that renders it. So: servings and ingredient
        // COUNT capped, macros clamped into [0, maxMacroGrams], micronutrients sanitized. The
        // primary defence is `SharedSavedRecipePayload.init(from:)`, which rejects an out-of-range
        // payload at the wire; these clamps are belt-and-braces for a payload built in-process.
        let sanitizedSourceURLString = Self.sanitizedSharedSourceURLString(savedPayload.sourceURLString)
        // The owner's duplicate decision (2026-08-09) applies to the mesh path exactly as it
        // does to the paste-import and queue-drain paths: a share whose source page is already
        // in the book KEEPS the user's existing recipe. Without this, addSavedRecipe's
        // supersede would permanently delete the user's own sealed photo and replace their
        // edited notes with the sender's copy — an accept tap must never be destructive.
        if !sanitizedSourceURLString.isEmpty,
           let existing = savedRecipeService.recipe(matchingSourceURL: sanitizedSourceURLString) {
            return .keptExisting(name: existing.name)
        }
        let now = Date()
        let recipe = RecipeDefinition(
            name: trimmedName,
            servings: min(max(savedPayload.servings, 1), RecipeImportLimits.maxServings),
            ingredients: [],
            notes: savedPayload.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            source: MealLogSource.webImport,
            createdAt: now,
            updatedAt: now,
            webImport: RecipeWebImport(
                sourceURLString: sanitizedSourceURLString,
                // R3: a peer's ingredient list is unbounded input riding into the synced snapshot.
                ingredientLines: Array(savedPayload.ingredients.prefix(RecipeImportLimits.maxIngredients)),
                macros: Macros(
                    protein: min(max(savedPayload.protein, 0), SharedRecipeLimits.maxMacroGrams),
                    carbs: min(max(savedPayload.carbs, 0), SharedRecipeLimits.maxMacroGrams),
                    fat: min(max(savedPayload.fat, 0), SharedRecipeLimits.maxMacroGrams)
                ),
                micronutrients: savedPayload.micronutrients.sanitizedForImport(),
                // A mesh-received recipe must never web-fetch: the wire carries no image URL
                // (imageURLString stays nil) AND the fetch is pre-suppressed, so even a
                // future field addition can't quietly turn receivers into fetchers.
                imageURLString: nil,
                webImageSuppressed: true,
                // ...and the same rule for the SOURCE LINK: a peer-chosen host must not be
                // contacted on detail-appear by the connection pre-warm. An explicit tap on the
                // link is the consent point (Docs/No-Tracking-Wall.md §4b).
                sourceIsPeerSupplied: true
            ),
            // F5: preserve ordered cooking steps a peer sent (nil on older peers that carry none).
            steps: Self.sanitizedSharedSteps(savedPayload.steps)
        )
        addSavedRecipe(recipe)
        return .added(recipe)
    }

    /// Sanitizes a shared source link in place rather than rejecting the whole recipe (matching how
    /// the name/summary are trimmed). A peer can send any string here — a file:///, javascript:,
    /// tel:, or schemeless value would later crash the in-app Safari sheet
    /// (SFSafariViewController only accepts http/https). Anything that isn't a real web link is
    /// blanked to "no source"; an empty/absent string was always allowed and stays allowed.
    private static func sanitizedSharedSourceURLString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.isSafariPresentable else { return "" }
        return trimmed
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
        // R3/R5: the text is pasted clipboard content or a mesh `.local` payload — unbounded and
        // unvalidated. Refuse an oversized payload at the entry point (each ingredient becomes a
        // `foodItems` row riding the synced snapshot), and refuse a non-finite quantity, which
        // `max(_:0.01)` would otherwise pass straight through into every serving computation.
        guard payload.ingredients.count <= RecipeImportLimits.maxIngredients,
              payload.servings <= RecipeImportLimits.maxServings,
              payload.ingredients.allSatisfy({ $0.quantity.isFinite }) else {
            throw RecipeImportError.invalidPayload
        }

        let now = Date()
        return batchSnapshotPersistence {
            let recipeIngredients = payload.ingredients.map { ingredient in
                let trimmedIngredientName = ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let unit = ingredient.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? RecipeUnit.serving.rawValue : ingredient.unit
                let quantity = min(max(ingredient.quantity, 0.01), RecipeImportLimits.maxQuantity)
                let foodItem = FoodItem(
                    name: trimmedIngredientName.isEmpty ? "Imported ingredient" : trimmedIngredientName,
                    brandSource: "Imported recipe",
                    servingSize: quantity,
                    servingUnit: unit,
                    macros: Macros(protein: max(ingredient.protein, 0),
                                   carbs: max(ingredient.carbs, 0),
                                   fat: max(ingredient.fat, 0)),
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
            // R7: the past-day write can fail. If the fallback meal is not actually removed, adding
            // the resolved meal below would leave BOTH rows on that day — so a failed removal aborts
            // the retry (the record is re-queued) instead of duplicating the meal.
            var removed = false
            batchSnapshotPersistence {
                removed = diary.mutateDay(date: dayKey) { $0.meals.removeAll { $0.id == meal.id } }
                diary.invalidateDaySummary(for: dayKey)
            }
            guard removed else {
                FernletAuditLog.log("meal.retry.pastDayRemoveFailed", context: ["dayKey": dayKey])
                return
            }
            aiRetryQueueService.clearForSourceID(meal.id)
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
    /// Deletes the LEGACY direct-CloudKit records — the record types written by builds that talked to
    /// CloudKit themselves rather than through `NSPersistentCloudKitContainer`.
    ///
    /// Its own hook, and unconditional, because neither existing cloud leg reaches them.
    /// `cloudCopyDeleteHook` above is gated on "stop syncing, keep the copy", and a LIVE sync deletes
    /// the server copy only by PROPAGATING the local row deletes — which the mirror can do only for
    /// the `CD_`-prefixed types it wrote. A legacy record has no local row behind it, so on the
    /// commonest configuration of all (sync on) meal, journal, workout, hygiene, hydration and sleep
    /// records from an old install survived "delete everything" with nothing left able to name them.
    ///
    /// Reported with `== false` like `sealedStoreRebuildHook`, not the row hooks' `!= true`: a nil
    /// hook is an unwired TEST store, and every test that drives the real funnel would otherwise
    /// report an incomplete wipe. Production wiring is pinned by the `ContentView` seam scan in
    /// `PrivacyWipeCoverageTests`.
    @ObservationIgnored var legacyCloudRecordDeleteHook: (() async -> Bool)?
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
    /// Destroys and re-creates the sealed `FernletPrivate` store FILE after the row hooks above have
    /// emptied it — the physical half of the crypto-erasure baseline (Option B,
    /// Docs/Plan-Security-Hardening-OpusTrack-2026-08-10.md §6).
    ///
    /// Row-delete is not erasure: SQLite frees the pages, the history prune clears the shadow
    /// tables, and neither checkpoints the WAL or vacuums the freelist — so the just-deleted
    /// ciphertext can linger in `-wal` frames and freed pages until they are reused. This hook
    /// removes the file that residue lives in (and the `_SUPPORT` external-blob directory beside
    /// it). Like the row hooks it is KEYLESS — no decrypt, no re-wrap — so it runs while the app is
    /// locked, which is the primary delete path.
    ///
    /// Honest limits, because the confirm dialog's promises have to be true: in THIS funnel the
    /// app-lock content key survives by design, so the claim is "no live ciphertext, and any
    /// physical residue is class-key-protected and key-bound" — NOT "crypto-erased". The fully
    /// honest erase is `FernletLockService.reset()` (Settings → Reset app lock, and the duress WIPE
    /// built on the same seam), which destroys the key as well.
    ///
    /// Reported with `== false`, not the row hooks' `!= true`: a nil hook here means an unwired
    /// TEST store, and unlike the row hooks the wipe is not incomplete without it — the rows are
    /// already gone, this is the residue layer on top. Production wiring is enforced separately, by
    /// the `ContentView` seam scan in `PrivacyWipeCoverageTests`.
    @ObservationIgnored var sealedStoreRebuildHook: (() -> Bool)?
    /// The MAIN (synced) store's counterpart to `sealedStoreRebuildHook`: removes the deleted-row
    /// residue from the Core Data file after `repository.purgeAllPersistedData()` has emptied it.
    ///
    /// Deliberately NOT the same mechanism, and the difference is a correctness argument rather than
    /// a preference. The sealed store is local-only, so destroying its file loses nothing. This store
    /// is mirrored by `NSPersistentCloudKitContainer`, whose export queue is persistent history
    /// INSIDE that file — at the moment the wipe finishes, the deletes it just made may not have
    /// reached the server yet. Destroying the file would discard that queue, strand the server copy
    /// with nothing left able to address it, and let the fresh empty store import it all back. So the
    /// wired implementation checkpoints and vacuums instead (`PersistenceController
    /// .compactStoreAfterWipe()`), which preserves the queue and the mirror metadata.
    ///
    /// `== false` like the sealed hook, and for the same reason: a nil hook is an unwired test store,
    /// and the rows are already gone — this is the residue layer on top. Honest limits are the sealed
    /// hook's: logical residue only, never a claim about physical flash blocks.
    @ObservationIgnored var mainStoreRebuildHook: (() async -> Bool)?
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

    /// Fired immediately after `deleteAllData` rotates this device's proximity identity, so anything
    /// bound to the OLD identity key can be reconciled.
    ///
    /// Exists for one binding today, and it is a data-loss one: the duress recovery blob is sealed
    /// with this device's long-term key-agreement key mixed into the derivation, and the custodian
    /// opens it with the live one. "Delete everything" deliberately KEEPS the app lock (and with it
    /// the enrollment rows and the content key), so without this the phone would go on offering — and
    /// firing — `DuressMode.recoveryLock` over a blob that can never be opened again. Wired in
    /// `ContentView` to `DuressRecoveryCoordinator.reconcileEnrollmentWithLocalIdentity()`.
    ///
    /// Returns nothing and reports no incomplete store: a missed reconcile costs a stale enrollment
    /// the launch-time reconcile will catch, never a byte of the user's data.
    @ObservationIgnored var identityRotatedHook: (() -> Void)?

    /// Persists a per-payload re-upload deferral into `StoragePreferences` so the obligation survives
    /// relaunch. A hook (like `storagePreferencesResetHook`) because the preferences store is
    /// app-scoped: writing through a second `StoragePreferencesStore` instance would leave the app's
    /// observable copy stale, and its next `update` would clobber the flag. Unwired (tests) the deferral
    /// stays session-only, as before.
    @ObservationIgnored var sealedBackupDeferralPersistHook: ((Bool, SealedBackupPayloadType) -> Void)?

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
        case .journalNarratives: return preferences.sealedBackupJournalEnabled
        case .intimacyLogs: return preferences.sealedBackupIntimacyEnabled
        }
    }

    /// What a wipe actually managed to remove.
    ///
    /// Every layer of the delete is best-effort by design — a Core Data save can fail, a HealthKit
    /// type may be unauthorized, a coordinated file write can lose to another process — and the
    /// confirm dialog promises permanence. So a failure has to reach the user instead of being
    /// swallowed; "delete everything" quietly half-working is the failure mode this whole change
    /// exists to end.
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
    ///   my data" an abuse vector. Its co-located PEER bans are cleared (leg 11): a ban on someone
    ///   else is data about another person, addressed to the identity this funnel rotates away.
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
    func deleteAllData(includingHealthKitSamples deleteHealthSamples: Bool) async -> DeleteAllOutcome {
        var outcome = DeleteAllOutcome()

        // 1. Stop the writers first (see `stopWritersForWipe`).
        stopWritersForWipe()

        // 2. Sealed iCloud backups + the kept cloud copy, BEFORE the preference reset that would gate
        // them off (see `deleteSealedCloudBackups`).
        let preferences = StoragePreferencesStore.currentPreferences()
        let backupFailures = await deleteSealedCloudBackups(preferences: preferences, into: &outcome)
        let sealedBackupDeleteFailed = backupFailures.sealedFailed
        let cloudCopyDeleteFailed = backupFailures.cloudCopyFailed

        // 3. Sealed rows + the locked-note buffer (see `deleteSealedRows`).
        deleteSealedRows(into: &outcome)

        await deleteHealthSamplesIfRequested(deleteHealthSamples, into: &outcome)

        // 4. Photo bytes before the days that reference them (see `deletePhotoCorpora`).
        deletePhotoCorpora(into: &outcome)

        // 5-7b. The share-extension inbox, the plaintext export dump, and the session-scoped social
        // surfaces (see `clearInboxesAndExports`).
        clearInboxesAndExports(into: &outcome)

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

        // 10. The widget's app-group files and the device-local AI ledgers, LAST — after the cancel
        // (see `clearDeviceLocalLedgers`).
        await clearDeviceLocalLedgers(into: &outcome)

        // 11. Proximity identity, the away-hearts dead drop, and the orphaned at-rest keys
        // (see `rotateProximityIdentityAndPurgeDeadDrop`).
        await rotateProximityIdentityAndPurgeDeadDrop(into: &outcome)

        // 12. The MAIN store's file residue. Step 8 deleted the rows; SQLite only marks their pages
        // free, and in WAL mode the database file still holds the PRE-delete page images until a
        // checkpoint. The main-store counterpart of `sealedStoreRebuildHook` — see its doc for why
        // it checkpoints and vacuums rather than destroying the file the CloudKit mirror's export
        // queue lives in.
        //
        // BEFORE the preference reset, and that ordering is load-bearing: the reset returns
        // `localBackupExcludedFromiOSBackup` to its default, which the app observes and answers with
        // a container reload of its own. Reloading the same controller twice at once would swap the
        // container out from under itself, so the funnel does its reload while no preference has
        // changed yet and lets the app's reload follow. (The compaction also refuses outright if a
        // reload is somehow already in flight, rather than racing it.)
        if await mainStoreRebuildHook?() == false {
            outcome.incompleteStores.append("leftover traces in your local records")
        }
        // A third cancel: the leg above is the only step after the purge that SUSPENDS, and the
        // container swap it performs publishes a remote-change notification that reloads the store
        // — which can schedule a debounced save. Anything that slipped through writes the emptied
        // snapshot (an empty day row, no user content), and this stops the next one.
        snapshotSaveCoordinator.cancelPending()

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

    /// Wipe leg 1: stop every background writer that could rebuild what the wipe removes.
    ///
    /// A debounced save fires one second from now and a HealthKit workout notification can arrive at
    /// any moment; either one lands mid-wipe and re-creates day rows from samples that still exist.
    /// `stopHealthKitWorkoutObservation` matters most when the user chose to KEEP their Health
    /// samples — that is precisely when the observer still has data to re-import.
    private func stopWritersForWipe() {
        snapshotSaveCoordinator.cancelPending()
        stopHealthKitWorkoutObservation()
        // The un-hide settle is a third writer: suspended in its CloudKit fetch it would resume AFTER
        // the wipe and re-insert cycle narratives (and possibly re-upload a fresh backup) into the
        // just-emptied store. `applyRestoredChunks` honors the cancellation at its write point, and the
        // diverged-device latch backstops any restore this cancel arrives too late for.
        periodBackupSettleTask?.cancel()
        // The intimacy un-hide settle is the same class of writer, added with the intimacy payload.
        intimacyBackupSettleTask?.cancel()
    }

    /// Wipe leg 2: the sealed iCloud backups, the own-photo escrow backup, every re-upload deferral,
    /// the rollback generation mark, and the "stop syncing, keep cloud data" copy.
    ///
    /// - Returns: whether the sealed-backup deletes and the kept-cloud-copy delete failed — the two
    ///   flags `storagePreferencesResetHook` needs at the end of the funnel.
    private func deleteSealedCloudBackups(
        preferences: StoragePreferences,
        into outcome: inout DeleteAllOutcome
    ) async -> (sealedFailed: Bool, cloudCopyFailed: Bool) {
        // Sealed iCloud backups, BEFORE the preference reset that would gate them off. Turning the
        // pref off only stops the restore while it stays off; the CKRecords survive and re-appear the
        // moment the user re-enables the backup — a wipe the user's own journal outlives. Disabling
        // deletes the chunk set for real, and needs no escrow key, so it works while locked.
        //
        // Only backups the user actually ENABLED are touched. `setSealedBackupEnabled(false,…)` returns
        // false when there is no provisioned identity — the common case for someone who never used
        // proximity — so attempting it unconditionally would report a failure to delete a backup that
        // was never uploaded, on the one dialog whose whole value is that its promises are true.
        var sealedBackupDeleteFailed = false
        for payloadType in SealedBackupPayloadType.allCases where Self.hasSealedBackup(payloadType, preferences) {
            if await !setSealedBackupEnabled(false, payloadType: payloadType) {
                sealedBackupDeleteFailed = true
                if !outcome.incompleteStores.contains("your encrypted iCloud backup") {
                    outcome.incompleteStores.append("your encrypted iCloud backup")
                }
            }
        }
        // 2a. The own-photo escrow backup (Phase 5, step 5b) — a SEPARATE record namespace from the
        // chunked payloads above, deliberately: it is not a `SealedBackupPayloadType`, so the
        // `allCases` loop cannot reach it and it needs its own leg here. Like that loop this runs
        // BEFORE the preference reset that would gate it off, and before the local photo stores are
        // emptied further down — the records are addressed by corpus name, but the ENABLE flag is
        // what tells this funnel there is anything in iCloud to delete. Deletion is by record name,
        // so it needs no escrow key and works while the app is locked.
        if preferences.sealedBackupOwnPhotosEnabled {
            if await !deleteOwnPhotoEscrowBackups() {
                sealedBackupDeleteFailed = true
                if !outcome.incompleteStores.contains("your encrypted iCloud backup") {
                    outcome.incompleteStores.append("your encrypted iCloud backup")
                }
            }
        }

        // Every re-upload deferral points at a backup this wipe just deleted — and the local data
        // behind it is about to go too, so the promised re-upload can never happen again either way.
        // Clear them all (observable + persisted) with the backups. Driven off `allCases` so a payload
        // added later cannot leave a stale obligation pointing at a deleted backup.
        for payloadType in SealedBackupPayloadType.allCases {
            recordSealedBackupReuploadDeferred(false, payloadType: payloadType)
        }

        // The rollback high-water mark dies with the backups it describes. Keeping it would strand
        // the user: after a wipe the next backup mints generation 1, which is BELOW the pre-wipe
        // mark, so the restore guard would reject the user's own new backup as a rollback attack.
        // Safe to clear precisely because the records it protected are gone in the same breath.
        var generationStore = SealedBackupGenerationStore()
        generationStore.reset()

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
        // 2c. The LEGACY direct-CloudKit records, UNCONDITIONALLY — the one cloud leg that must not
        // be gated on a preference. The branch above covers "sync off, copy kept"; a LIVE sync
        // covers itself by propagating the local row deletes. Neither reaches a record type the
        // mirror never wrote: `NSPersistentCloudKitContainer` only knows its `CD_`-prefixed types,
        // so the bare-named meal / journal / workout / hygiene / hydration / sleep records left by
        // builds that talked to CloudKit directly have no local row to propagate a delete from, and
        // survived on the commonest configuration of all. Named under the same label as the branch
        // above so a double failure reads as one line after the dedupe. A missing iCloud account is
        // reported as a clean sweep by the service, not as a failure the user cannot act on.
        if await legacyCloudRecordDeleteHook?() == false {
            outcome.incompleteStores.append("your iCloud copy")
        }
        return (sealedBackupDeleteFailed, cloudCopyDeleteFailed)
    }

    /// Wipe leg 3: the sealed rows (cycle notes, intimate logs, journals) and the locked-note buffer.
    private func deleteSealedRows(into outcome: inout DeleteAllOutcome) {
        // Sealed rows: the most sensitive data and the only rows with no second chance. Each hook
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
    }

    /// Wipe leg 3b: the HealthKit samples Fernlet itself authored, when the user asked for them too.
    private func deleteHealthSamplesIfRequested(_ deleteHealthSamples: Bool,
                                                into outcome: inout DeleteAllOutcome) async {
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
    }

    /// Wipe leg 4: the three sealed own-photo corpora (meal, progress, recipe).
    private func deletePhotoCorpora(into outcome: inout DeleteAllOutcome) {
        // Photo bytes before the days that reference them: ownership lives in `Meal.photoID`, so once
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
    }

    /// Wipe legs 5-7b: the share-extension inbox, the plaintext export dump, and the session-scoped
    /// social surfaces (friends' clothing catalogs, temp messages, the presence radio).
    private func clearInboxesAndExports(into outcome: inout DeleteAllOutcome) {
        // The share-extension inbox, which is drained on the next foreground. A recipe shared into
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
    }

    /// Wipe leg 10: the widget's app-group files and the device-local AI ledgers (call quota + audit
    /// log). Runs after the funnel's second `cancelPending`, so no debounced save can rewrite them.
    private func clearDeviceLocalLedgers(into outcome: inout DeleteAllOutcome) async {
        // The widget's app-group files, LAST — after the cancel, so the debounced save's
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

        // The record of which Apple Health prompts have ever been shown — including `cycleTracking`
        // and `intimateLogging`. A plaintext `UserDefaults` array until 2026-08-20, cleared by
        // nothing, so a wiped phone still held a claim about the user's body; it is a device-only
        // keychain row now. Unlike the plain quota reset above this HAS a failure signal (a keychain
        // delete that did not take), and a surviving row is exactly the case the "everything
        // deleted" dialog must not paper over.
        if !HealthCapabilityRequestLedger.clear() {
            outcome.incompleteStores.append("your Apple Health permission history")
        }
        // Companion petting state (`fernlet.companionPets.*`): how many times the companion was
        // petted in the current window, when that window opened, when the settled period ends —
        // device-local timestamps of when the user was last here. `clearPersistentState` existed and
        // its only caller was a `#if DEBUG` UI-test seam, so in RELEASE nothing cleared it. Plain
        // `UserDefaults` removals, so no failure signal and no incomplete store.
        PetInteractionGovernor.clearPersistentState()

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
    }

    /// Wipe leg 11: rotate the proximity identity, purge the away-hearts dead drop (remote BEFORE
    /// local, since only this device can name those records), and drop the orphaned at-rest keys.
    private func rotateProximityIdentityAndPurgeDeadDrop(into outcome: inout DeleteAllOutcome) async {
        // Proximity identity + sealed-content device keys (bitchat adoptions Increment 1,
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
        // The identity this wipe just rotated is the SENDER key a duress recovery blob is sealed
        // under (`FernletLockService` keeps `com.fernlet.lock` through a delete-all by design, so the
        // enrollment outlives the key that makes it openable). Unreconciled, the lock would keep
        // `DuressMode.recoveryLock` armed over a blob no device on earth can open — firing it would
        // destroy every local unlock key for a ceremony that can only fail. Fired whether or not the
        // wipe above threw: a partial identity wipe rotates the key just as thoroughly.
        identityRotatedHook?()
        // Local moderation peer-ban records (keychain `com.fernlet.moderation`, `peerBan:`
        // accounts): 30-day bans keyed to OTHER designers' identity fingerprints. The rotation
        // above just promised a brand-new identity, and these rows are data about other people
        // addressed to the dead one — the ledger evidence that could re-mint them was already
        // cleared in `resetAll()`. The SELF-ban row in the same service deliberately survives
        // (2026-07-17: a wipe must not be a ban-evasion tool); the clear removes ONLY peer rows.
        if !moderationBanStore.clearPeerBansForDeleteAll() {
            outcome.incompleteStores.append("nearby designer bans")
        }
        // Away-hearts dead-drop (Increment 3). The REMOTE purge has to run BEFORE the local wipe:
        // the sealed records this device uploaded to the CloudKit public database are addressable
        // only by the record names held in the outbox, and recipients cannot delete a sender's
        // records — so wiping first would strand them there permanently, with nothing left in the
        // app able to name them. The local wipe below still runs on failure (privacy wins over a
        // retry we can no longer offer), which is precisely why a failure has to be REPORTED: after
        // this point the remote copies are unaddressable, and the dialog promises they are gone.
        // Flagged as in-flight so the foreground retry seam — whose listener chain can fire during a
        // multi-second wipe — does not start a second, competing purge over the same records.
        isPurgingHeartDropRecords = true
        let deadDropPurged = await heartDropService.purgeDeadDrop()
        isPurgingHeartDropRecords = false
        if !deadDropPurged {
            // Latched, because the local wipe below destroys the record names those copies are
            // addressed by and only a record's creator may delete it from the public database: after
            // this point nothing — not this process, not a reinstall — can ever retry. That is
            // precisely why it must not be forgotten. The failure alert invites the user to try
            // again, and a second wipe finds an empty outbox, so without this latch the retry would
            // come back reporting a CLEAN, complete deletion over records this device knowingly left
            // on a public database.
            //
            // Why latch rather than repair: repair needs the record names to survive the wipe, and
            // nothing at this layer can keep only those — the outbox entries that hold them also
            // hold each recipient's signing key and the sealed heart itself, so retaining the outbox
            // would leave a durable trace of who the user sends hearts to across the wipe they just
            // asked for. Privacy wins; the honesty debt is paid here instead. (A minimal
            // record-names-only retention seam in ProximityKit would let us have both.)
            //
            // Process-local on purpose: persisting it would re-create an on-disk trace of a feature
            // the user just erased, and since it can never legitimately become false again that
            // trace would be permanent.
            strandedDeadDropRecordsFromWipe = true
        }
        if strandedDeadDropRecordsFromWipe {
            outcome.incompleteStores.append("hearts parked in iCloud")
        }
        // Then the local state: prekeys (keychain), peer bundle cache, outbox, durable dedup, and
        // the service's own identity cache (the 4th live instance).
        heartDropService.wipeForDeleteAll()
        // No `heartsAwayPurgePending` reset needed: it derives from the outbox this just emptied, so
        // the Settings "it'll keep trying" notice cannot outlive the wipe that made retrying
        // impossible — which is the honest reading, since nothing addressable is left.
        // Orphaned at-rest keys: the journal/worry device keys, whose sealed rows died with the
        // repository purge. They regenerate lazily on next use; keychain not-found counts as done,
        // so they carry no incomplete-store signal.
        KeychainItem.delete(for: .deviceJournalKey, service: KeychainItem.journalService)
        KeychainItem.delete(for: .deviceWorryKey, service: KeychainItem.journalService)
        // NEITHER private-media content key (service `com.fernlet.private-media`) is deleted, and
        // neither must be re-added here.
        //   • `…contentKey` (friend wall) backs `MeshNetworkManager.photoCacheStore`, which holds
        //     the friend photo wall this funnel keeps by design (see the survivors list above).
        //     Deleting it would not orphan a key, it would shred the wall: the next `mediaKey()`
        //     finds no row, mints a fresh random one, and every retained photo decrypts to garbage —
        //     permanently, with no failure signal anywhere.
        //   • `…ownContentKey` (the Phase-5 own-photos key) backs the meal/recipe/progress stores,
        //     whose FILES this funnel does delete just above. The row is kept anyway (owner
        //     decision): the stores are empty, so the key protects nothing and discloses nothing,
        //     while deleting it would re-introduce the same stale-cache hazard for anything captured
        //     between the wipe and relaunch.
        // A key whose stores were just emptied protects nothing extra, so keeping it discloses
        // nothing. The cache invalidations below stay: they are still correct hygiene for the
        // emptied stores (next read re-fetches the surviving row).
        mealPhotoStore.invalidateEncryptionKeyCache()
        progressPhotoStore.invalidateEncryptionKeyCache()
        recipePhotoStore.invalidateEncryptionKeyCache()
    }

    /// Returns the human-readable names of any per-row store whose persisted delete failed, so the
    /// "delete everything" funnel can fold them into its failure alert. Empty on a clean reset.
    ///
    /// R7: the list is failure information, so it is NOT discardable — a standalone "Reset
    /// everything" caller must surface or audit-log whatever failed to delete.
    func resetAll() -> [String] {
        var incompleteStores: [String] = []
        batchSnapshotPersistence {
            diary.resetDiary()
            connectionSessionLogs = []
        }
        // `resetDiary()` cleared `settings.customExercises` in the blob, but ``WorkoutExerciseCatalog``
        // is a PROCESS-GLOBAL registry — without this re-publish, exercises imported from a coach plan
        // stay live in the picker, the safety filter, and the planning engine until the app is
        // relaunched, which is exactly the "deleted but still there" state this funnel exists to
        // prevent. Registration replaces, so this empties it.
        syncCustomExerciseCatalog()
        if !savedRecipeService.reset() { incompleteStores.append("your saved recipes") }
        // The pre-Core-Data `SavedRecipes.json` file (Application Support/Fernlet): plaintext recipe
        // names, ingredients, notes, macros and source URLs on any install predating the Core Data
        // migration. The migration latch deliberately survives the wipe (deliberate-exceptions
        // table), so nothing ever re-reads this file — but until now nothing deleted it either. A
        // missing file counts as success; a failed removal names the surviving copy under the same
        // label as the per-row reset above, and the funnel's dedupe collapses the pair to one line.
        if !LegacySavedRecipeJSONRepository().deleteFile() { incompleteStores.append("your saved recipes") }
        if !customItemService.reset() { incompleteStores.append("your custom items") }
        // Clears all earn/spend rows and appends a reset-boundary marker. The next `reconcileCoinLedger()`
        // re-mints `earn` rows ONLY for active days at or after the reset boundary day — days before the
        // reset stay voided and are never re-minted, so another device can't undo a reset by
        // deterministically re-minting pre-reset earns. Activity logged on or after the reset day still
        // earns normally (the reset zeroes the past, it doesn't disable earning going forward).
        if !coinLedgerService.reset() { incompleteStores.append("your coins") }
        // The milestone ledger is a DATED METADATA TRAIL of the content this funnel destroys: one
        // row per counted event — a journal entry happened on this day, a worry was let go on that
        // one — in Core Data and, mirrored, in the user's CloudKit private database. The rows carry
        // no content, but "we deleted your journal and kept the dates you journaled" is not a wipe,
        // so the trail goes with the data it describes (reversing the pre-2026-08-20 product call
        // that it outlives a reset). The row delete lives on the concrete CloudKit conformer
        // (`MilestoneLedgerRepositoring` carries none, and StoreCore has no CloudKitSync edge), so
        // the funnel narrows the service's store here — the same `as?` narrowing the async loader
        // uses for `CoreDataFernletRepository`. A narrowing that fails reports the store rather than
        // emptying memory and calling the wipe complete. Milestone COIN awards live in the coin
        // ledger and were voided just above; `MilestoneEconomy.missingAwards` honors that reset
        // boundary, so nothing re-mints them.
        let milestoneRows = milestoneLedgerService.persistedStore as? MilestoneLedgerRepository
        if !milestoneLedgerService.reset(deletingRowsWith: { milestoneRows?.deleteAll() ?? false }) {
            incompleteStores.append("your milestone history")
        }
        aiRetryQueueService.reset()
        proximityTrustVault.apply(peers: [], audit: [])
        // The stress sidecar caches HealthKit-derived baselines on-device; "reset everything"
        // must not leave clinical derivatives behind. `!= true` like the sealed hooks below: a nil
        // (unwired) context and a failed delete are both a baseline the wipe did not remove.
        if stressScoringContext?.scrubStressLocalState() != true {
            incompleteStores.append("your body-signals baseline")
        }
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
        // The Log-activity "Recent" chips (`fernlet.recentActivityTypes`): the last five workout
        // types picked, rendered to whoever holds the phone next. Same class of device-local
        // `UserDefaults` sidecar as the serving memory above; a plain removal has no failure signal.
        RecentActivityTypeMemory.clearAll()
        // Which recipes this device already spent its one automatic web-image download on — the
        // same class of device-local `UserDefaults` sidecar; clear it with the others so the
        // bookkeeping doesn't outlive the recipes it described.
        RecipeWebImageAttemptMemory.clearAll(defaults: webImageAttemptDefaults)
        // The local correction memory (research §26 fix 1.10): the searches this person typed and the
        // foods they chose for them — food-name/consumption data, and a legible record of what someone
        // holding the phone next would see promoted to rank 1. Same class of device-local `UserDefaults`
        // sidecar as the three above, and cleared with them. The second line is not housekeeping: the
        // live `FoodCatalog` holds its own in-memory copy of this map (`setSearchAliases`), so without
        // republishing the emptied snapshot the wipe would leave every corrected query still answering
        // with the user's remembered pick until the app is relaunched — the "deleted but still there"
        // state this funnel exists to prevent. No failure signal on a plain defaults removal.
        FoodSearchCorrectionMemory.clearAll(defaults: foodSearchCorrectionDefaults)
        foodCatalog.setSearchAliases([:])
        // The workout tombstone ring (`fernlet.workout.tombstones`): up to 200 ids of removed
        // workouts whose app-authored Health delete may never have confirmed. After this funnel
        // there are no local rows left for a tombstone to guard, and a survivor would make the
        // workout observer DELETE a still-existing app-authored Health sample on the next
        // re-enable — even against an explicit "keep my Health samples" answer. Correct for both
        // wipe choices: the delete path already removed the samples, the keep path wants re-import,
        // not deletion. No failure signal.
        workoutTombstones.clearAll()
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
        // R7: a file that survives the wipe is re-adopted by the next reconcile — the very
        // resurrection this leg exists to prevent — so name it with the other app-group files.
        if !guidedRunStateStore.clear() { incompleteStores.append("widget data") }
        syncActivity { await GuidedWorkoutActivityBridge.end() }
        // The cooking runner is the SAME class of live writer: an in-flight cook is mirrored to its own
        // app-group file that a foreground/launch `reconcileCookingRunFromAppGroup` re-reads and adopts
        // (resurrecting a "Cooking in progress" resume card on a supposedly-wiped device — and leaving the
        // recipe name + current step text on the Lock Screen). Cooking never auto-logs, so there is no
        // re-log hazard, but the file + Live Activity must still be stopped unconditionally at the wipe.
        cookingRunState = nil
        if !cookingRunStateStore.clear() { incompleteStores.append("widget data") }
        syncActivity { await CookingActivityBridge.end() }
        // Device-local sensitive-surface visibility resolution — reset to "unresolved" so a fresh start
        // re-derives from `sex` (resetDiary already restored the settings gate to its defaults).
        clearSensitiveVisibilityResolution()
        // The age determination is device-local and re-derivable from the Apple Account, so a wipe drops
        // it too rather than leaving a wiped device still holding a verdict about its user. Both gates
        // return to fail-closed until the user verifies again.
        ageAssurance.clear()
        // LAST, and after every sealed-row delete in BOTH wipe legs — the funnel's `periodData`/
        // `intimacyData`/`journalData` hooks upstream and `worryBoxResetHook` just above. Deleting
        // rows frees SQLite pages; it does not erase them, so the ciphertext can sit in `-wal`
        // frames and the freelist until reused. This destroys and re-creates the sealed store file
        // itself, taking that residue (and the `_SUPPORT` external-blob directory) with it.
        //
        // Row-delete first, rebuild second, deliberately: a rebuild that fails still leaves the
        // rows gone, whereas rebuilding first would hand a failing purge an intact store to leave
        // rows in. Keyless, like the row deletes — it must work while the app is locked.
        //
        // Placed in `resetAll()` rather than in `deleteAllData` so it runs ONCE per wipe and covers
        // the standalone "Reset everything" too (same reasoning as `worryBoxResetHook`).
        if sealedStoreRebuildHook?() == false { incompleteStores.append("your sealed store") }
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
            widgetSnapshotMirror = WidgetSnapshotMirror(directory: appGroupDirectory)
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
    ///
    /// Discardable by design (R7): the `Bool` reports whether the day ADVANCED, not whether the work
    /// succeeded — "still the same day" is the overwhelmingly common answer and nothing to act on.
    /// The failure that could occur inside (the diary declining the re-key) is audited there.
    @discardableResult
    func refreshCurrentDayIfNeeded(now: Date = Date()) -> Bool {
        let currentDayKey = FernletDate.dayKey(for: now)
        guard currentDayKey != todayKey else { return false }
        // Persist the outgoing in-memory state (day + recentMeals + …) under the OLD key BEFORE it
        // advances, so a log made just before this rollover isn't lost. `flushPending` is a no-op when no
        // save is pending (the outgoing day's row is then already durable). `currentSnapshot()` reads
        // `todayKey`, which is still the old key here, so the flush is correctly keyed to the old day.
        snapshotSaveCoordinator.flushPending()
        // R7: `false` means the diary was already on this key — impossible behind the guard above,
        // and if it ever happened the derived rebuilds below would be re-keying to a day the diary
        // never moved to. Named rather than assumed.
        if !diary.advanceCurrentDay(to: currentDayKey) {
            FernletAuditLog.log("day.rollover.diaryDeclined", context: ["day": currentDayKey])
        }
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
        migrateAndBindOwnPhotoKey()
    }

    /// Security-hardening Phase 5 (5a-3): re-seal every own photo from the pre-split shared media
    /// key onto the own-photos key, eagerly, once per launch until it is proven complete.
    ///
    /// Eager on purpose. A lazy, read-triggered migration would leave every photo the user never
    /// reopens sealed under the backup-restorable key indefinitely — and "own photos stop being
    /// readable off this device" is the whole point of the split, so the corpus has to be swept,
    /// not sampled. The read-path dual-open fallback covers only the window until this finishes.
    ///
    /// Off the main path in two senses: it runs from `deferredPostLaunchTasks` (after the UI is
    /// up), and on a detached utility task so the file I/O never touches the main actor. The
    /// migrator builds its OWN key providers inside that task — `PrivateMediaKeyProviding` is not
    /// `Sendable`, so the store's providers must not travel with it — and only `URL` values cross
    /// the boundary. Fully idempotent and cheap after completion: the latch short-circuits it, and
    /// even without the latch a migrated corpus costs one GCM open per file.
    ///
    /// Step 5c hangs the binding evaluation off the same task, in this order and no other: the
    /// re-seal pass must report completion BEFORE the gate is even consulted, because the latch it
    /// sets is the proof that no own file is still readable only under the pre-split key. The gate
    /// then refuses unless the user also has a cross-device route (escrow backup on, or recorded
    /// consent), so a launch never silently trades away their phone-swap recovery.
    private func migrateAndBindOwnPhotoKey() {
        let documentsDirectory = photoDocumentsDirectory
        // The COMMIT PROOF, not the preference. A launch that bound on the stored flag alone would
        // re-decide, on every boot, that a switch someone once flipped is a cross-device route —
        // including for a user whose every upload has failed since. Read on the main actor and
        // carried in as a Bool, because only `Sendable` values may cross into the detached task.
        let escrowRouteCommitted = OwnPhotoEscrowCommitLedger().isCommitted
        Task.detached(priority: .utility) { [weak self] in
            let complete = OwnPhotoKeyMigrator.standard(documentsDirectory: documentsDirectory).run()
            let outcome = complete
                ? OwnPhotoKeyBinder(escrowRouteCommitted: escrowRouteCommitted).bindIfEligible()
                : OwnPhotoKeyBindingOutcome.refusedMigrationIncomplete
            await self?.recordOwnPhotoKeyBindingOutcome(outcome)
        }
    }

    /// Whether the user's own-photo key is bound to this device — read from the keychain row itself,
    /// then held as observable state so Privacy & Data can reflect it without polling.
    ///
    /// Initialized at construction (one `SecItemCopyMatching`) rather than defaulted to false, so a
    /// device that is already bound never renders the "lock them to this device" offer for the
    /// instant before the launch pass runs.
    private(set) var ownPhotoKeyDeviceBound = OwnPhotoKeyBinder.isOwnPhotoKeyDeviceBound()

    /// Whether the eager own-photo re-seal pass has proven completion — the half of the binding gate
    /// the user cannot influence. Observable so the settings screen can say "still preparing"
    /// instead of offering a button that would refuse.
    private(set) var ownPhotoKeyMigrationComplete = OwnPhotoKeyMigrator.latch().isComplete

    /// Folds a binding evaluation back into the observable custody state.
    ///
    /// Both flags are re-read from their sources rather than inferred from `outcome`: the outcome
    /// says what this evaluation did, the keychain and the latch say what is true.
    private func recordOwnPhotoKeyBindingOutcome(_ outcome: OwnPhotoKeyBindingOutcome) {
        ownPhotoKeyMigrationComplete = OwnPhotoKeyMigrator.latch().isComplete
        ownPhotoKeyDeviceBound = OwnPhotoKeyBinder.isOwnPhotoKeyDeviceBound()
        switch outcome {
        case .bound:
            FernletAuditLog.log("privateMedia.ownKeyDeviceBound")
        case .rebindFailed(let status):
            FernletAuditLog.log("privateMedia.ownKeyBindFailed", context: ["status": String(status)])
        case .refusedMigrationIncomplete, .refusedNoRecoveryRoute, .deferredKeyUnavailable:
            break
        }
    }

    /// Re-evaluates the own-photo key binding gate — the seam for events that can newly satisfy it
    /// (the escrow photo backup being switched on, a completed migration).
    ///
    /// A no-op unless both halves hold, and it never *widens* custody: an already-bound row stays
    /// bound, and there is deliberately no un-bind path (see `OwnPhotoDeviceBindingConsent`).
    func bindOwnPhotoKeyIfEligible() -> OwnPhotoKeyBindingOutcome {
        let outcome = OwnPhotoKeyBinder(
            escrowRouteCommitted: OwnPhotoEscrowCommitLedger().isCommitted
        ).bindIfEligible()
        recordOwnPhotoKeyBindingOutcome(outcome)
        return outcome
    }

    /// The user-initiated "lock my photos to this device" ceremony: records explicit consent that
    /// own photos will not restore to a new phone without the escrow backup, then binds.
    ///
    /// Irreversible by design, which is why its only caller puts a WS-5 destructive confirmation in
    /// front of it. Consent is recorded even if the bind then defers on a transient keychain
    /// failure — the user's decision is durable; re-asking would be the wrong remedy.
    func lockOwnPhotosToThisDevice() -> OwnPhotoKeyBindingOutcome {
        FernletAuditLog.log("privateMedia.ownKeyBindingConsentRecorded")
        let outcome = OwnPhotoKeyBinder(
            escrowRouteCommitted: OwnPhotoEscrowCommitLedger().isCommitted
        ).recordConsentAndBind()
        recordOwnPhotoKeyBindingOutcome(outcome)
        return outcome
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
        syncCustomExerciseCatalog()
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
        // R7: a failed re-persist leaves that day's plaintext journal in the (synced) blob. Counting
        // the failures is what keeps the run-once flag from being advanced over a leak that is still
        // there — a discarded result would mark the scrub clean and it would NEVER re-run.
        var persistFailures = 0
        for (dayKey, day) in outcome.changedDays {
            let persisted = repository.updateDay(
                SanitizedDay.sanitizing(day, sealedJournalIDs: journalSealingCoordinator.sealedJournalIDs),
                for: dayKey, todayKey: todayKey
            )
            if !persisted { persistFailures += 1 }
        }
        if persistFailures > 0 {
            FernletAuditLog.log("journal.pastDayScrub.persistFailed", context: [
                "days": String(persistFailures)
            ])
        }

        // No journal key was active, so the scan could not actually run. Do NOT advance the run-once flag —
        // a no-op pass must not be mistaken for a genuine clean pass and permanently disable the scrub (#3).
        guard outcome.keyActive else { return }

        guard outcome.unsealedFailureCount + persistFailures > 0 else {
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
                "unsealed": String(outcome.unsealedFailureCount),
                "persistFailed": String(persistFailures)
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
                // R7: a failed day write leaves a row mirroring a Health sample the user deleted.
                // Nothing to retry from here (the observer event is spent), so name it.
                if !diary.removeWorkout(id: row.id, date: dateKey) {
                    FernletAuditLog.log("workout.removeByHealthKitUUID.failed", context: ["date": dateKey])
                }
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

/// The own-photo escrow route's callback seam. The single member
/// (`recordOwnPhotoBackupOutcome(_:)`) lives beside the sealed-backup status writers above, so both
/// routes publish their non-silent status through the same store.
extension FernletStore: OwnPhotoBackupContext {}

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
    func recordSealedBackupReuploadDeferred(_ deferred: Bool, payloadType: SealedBackupPayloadType) {
        switch payloadType {
        case .periodData: sealedBackupPeriodReuploadDeferred = deferred
        case .journalNarratives: sealedBackupJournalReuploadDeferred = deferred
        case .intimacyLogs: sealedBackupIntimacyReuploadDeferred = deferred
        // The whole-store overwrite payload needs neither a content key nor a visible surface, so its
        // reconcile can never be postponed and there is no obligation to record.
        case .sensitiveNotes: return
        }
        sealedBackupDeferralPersistHook?(deferred, payloadType)
    }

    /// Rebuilds day-blob journal skeletons for restored journal narratives (P3 journal
    /// self-sufficiency). See `SealedBackupContext.reinstateJournalEntries(from:)` for why this exists.
    ///
    /// The skeleton is written with **empty text and no emotions** on purpose. Both are sealed columns;
    /// writing the decrypted values into the day blob would put journal content back into the very
    /// (iCloud-mirrored) blob the sealing exists to keep it out of. What the blob is allowed to hold —
    /// and all the UI needs to render the entry — is the id, tag, and date; the text and emotion chips
    /// are then hydrated by id from the sealed store, exactly as they are after every lock/unlock cycle
    /// (`JournalSealingCoordinator.refreshSealedJournals` / `hydratingDecryptedJournals`).
    ///
    /// Existing ids are never touched, so a restore that races a partially-present day cannot duplicate
    /// or overwrite an entry. Entries are kept in date order to match how the diary renders them.
    func reinstateJournalEntries(from narratives: [JournalNarrative]) {
        guard !narratives.isEmpty else { return }
        for (dayKey, rows) in Dictionary(grouping: narratives, by: \.dayKey) {
            let written = diary.mutateDay(date: dayKey) { day in
                var known = Set(day.journals.map(\.id))
                for row in rows where !known.contains(row.id) {
                    day.journals.append(
                        JournalEntry(id: row.id, text: "", tag: row.tag, date: row.entryDate, emotions: [])
                    )
                    known.insert(row.id)
                }
                day.journals.sort { $0.date < $1.date }
            }
            // R7: a failed past-day write leaves restored narratives with no skeleton to render
            // through; the restore still proceeds for the other days, but the gap is recorded.
            if !written {
                FernletAuditLog.log("diary.pastDayWriteFailed",
                                    context: ["op": "reinstateJournals", "dayKey": dayKey])
            }
        }
        scheduleSnapshotSave()
        // Hydrate the text back in by id (today + the previousJournals window). Older days hydrate
        // lazily on read via `loadDayWithDecryptedJournals`, so nothing is lost for them either.
        journalSealingCoordinator.refreshAfterSnapshotApply()
    }
}

extension FernletStore: HealthSyncContext {
    func scheduleSnapshotSave() { snapshotSaveCoordinator.schedule() }
}

// MARK: - Models
