// swift-tools-version: 6.2
import PackageDescription

// FernletKit — the local Swift package for the SPM module carve-up (plan §6).
// Phase 1 stands this up empty with a single Layer-0 `FernletFoundation` target;
// later phases add the rest of the layered DAG that forms the S3 privacy wall.
//
// `defaultIsolation(MainActor.self)` is set per target up front: MainActor
// isolation is NOT inherited from the app target's SWIFT_DEFAULT_ACTOR_ISOLATION
// build setting, so SPM targets must opt in explicitly (plan §7).
let package = Package(
    name: "FernletKit",
    platforms: [
        .iOS(.v26),
    ],
    products: [
        // Single umbrella product: the app and test targets link this ONE product
        // and can then `import` ANY target listed here. Each later module is added
        // to this `targets:` list (and gets its own `.target` below) with NO further
        // Xcode project surgery — the pbxproj references this product by name only.
        .library(name: "FernletKit", targets: ["FernletFoundation", "FernletCrypto", "FernletDomainModel", "FernletScoring", "FoodCatalog", "FernletPersistence", "LocalPersistence", "PrivateStoreCore", "PrivateHealthStore", "PrivateMemoryStore", "PrivateMediaStore", "PeriodContextBridge", "AIContext", "AIProviders", "CloudKitSync", "StoreCore", "DiaryStore", "HealthKitGateway", "FernletLock", "AppServices", "ProximityKit"]),
    ],
    dependencies: [
        // CryptoSwift supplies the memory-hard Scrypt KDF used by FernletLock's passphrase
        // derivation (the ONE external package the carve-up needs). Requirement mirrors the
        // app target's pbxproj reference exactly (upToNextMinor from 1.10.0) so SPM resolves
        // a single shared CryptoSwift across the .xcodeproj reference and this local package.
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift", .upToNextMinor(from: "1.10.0")),
    ],
    targets: [
        .target(
            name: "FernletFoundation",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        // Layer 0 — pure sealing primitives (CryptoKit only). References no
        // FernletFoundation symbols, so it declares no in-package dependency.
        .target(
            name: "FernletCrypto",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        // Layer 1 — the portable domain value types (nutrition/workout/wellbeing/
        // companion + settings aggregate, WorkoutProgram, FoodItemSearch). Color
        // stripped (lives in FernletUI). Uses FernletDate from FernletFoundation.
        //
        // NO defaultIsolation(MainActor.self): this target is pure value types with
        // zero @Observable/MainActor members, so per plan §7 it stays on the package
        // default (nonisolated). Uniform nonisolation is required because these
        // value types cross-reference each other's statics/inits (e.g. FernletSettings
        // defaults reference WorkoutProfile.fullGym / FernletShortcut.defaultQuickLog);
        // a mixed MainActor/nonisolated split produces cross-actor errors. It is also
        // the correct portability stance for the [C] shared core.
        .target(
            name: "FernletDomainModel",
            dependencies: ["FernletFoundation"]
        ),
        // Layer 1 — scoring/goal-weight/meal-parse/workout-plan engine + the
        // abstract period-scoring SIGNAL types that scoring consumes (the raw→
        // abstract conversion stays up in PeriodContextBridge). Pure logic, no
        // @Observable, so NO defaultIsolation (nonisolated, like DomainModel).
        .target(
            name: "FernletScoring",
            dependencies: ["FernletFoundation", "FernletDomainModel"]
        ),
        // Layer 2 — persistence contract: FernletRepository protocol + the
        // FernletSnapshot aggregate + the cycle-strip (forStorage factory). Pure
        // value types/protocol, nonisolated (no defaultIsolation).
        .target(
            name: "FernletPersistence",
            dependencies: ["FernletDomainModel"]
        ),
        // Layer 2 — Foundation-only LocalFernletRepository + LocalFernletDatabase
        // + *LogRecord DTOs + the derived-signal/Tier-2 engines (kept here since
        // they are tightly coupled to the DB derived-table rebuild). Nonisolated.
        .target(
            name: "LocalPersistence",
            dependencies: ["FernletFoundation", "FernletDomainModel", "FernletScoring", "FernletPersistence"]
        ),
        // Layer 1 — USDA food search/scoring + dish lexicon. Owns the bundled
        // read-only resources (loaded via Bundle.module, NOT Bundle.main). Pure
        // services (nonisolated), so no defaultIsolation.
        .target(
            name: "FoodCatalog",
            dependencies: ["FernletFoundation", "FernletDomainModel", "FernletScoring"],
            // DishTemplates.json + DishTemplateLexicon stay in the app target:
            // DishTemplateLexicon.resolve assembles meals via the @MainActor,
            // AI-coupled app service MealBuilder, so it can't live in this
            // nonisolated layer-1 module. Only FoodCatalog.sqlite is owned here.
            resources: [
                .copy("Resources/FoodCatalog.sqlite"),
            ]
        ),
        // Layer 2.5 — shared sealed-storage substrate on the PROTECTED side of the
        // S3 wall. The sealed (local-only, never-iCloud) CoreData stack
        // (PrivatePersistenceController + the 3 narrative entities + the history
        // pruner) plus the pending-narrative buffer. Shared by BOTH PrivateHealthStore
        // and PrivateMemoryStore (the plan implicitly placed the controller in
        // PrivateHealthStore, but the journal repo + the lock service need it too)
        // and drained by FernletLock. This MUST stay off any module that
        // AIProviders/CloudKitSync import, or AI/sync code could reach the sealed
        // store — so it is its own protected-side target, not part of FernletFoundation.
        // Nonisolated: the nonisolated repositories (e.g. JournalNarrativeRepository)
        // call the pruner/controller directly, so a MainActor default would force
        // cross-actor hops. The static singleton is nonisolated(unsafe) (non-Sendable
        // CoreData container), matching its prior app-target behaviour.
        .target(
            name: "PrivateStoreCore",
            dependencies: ["FernletFoundation", "FernletDomainModel"]
        ),
        // Layer 3 — sealed cycle/intimacy store (S3). PeriodTrackerStore (@Observable),
        // CyclePredictionEngine, MenstrualNarrativeRepository, IntimacyLogRepository +
        // the RAW cycle value types (CyclePhase, CycleDayEntry, UserLoggedCycleEvent, …).
        // Raw cycle types deliberately live HERE, not in FernletDomainModel: AIProviders
        // imports DomainModel, so exposing CyclePhase there would defeat the
        // PeriodContextBridge abstraction. Imports HealthKit ([S]) via a narrow injected
        // PeriodHealthKitServicing seam (the HealthKitService conformance stays app-side).
        // MainActor: PeriodTrackerStore is @Observable.
        .target(
            name: "PrivateHealthStore",
            dependencies: ["PrivateStoreCore", "FernletCrypto", "FernletFoundation", "FernletDomainModel"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        // Layer 3 — sealed journal store (S3). Just the raw at-rest journal repository
        // (JournalNarrativeRepository). NONisolated (plain final class; its CoreData
        // performAndWait closures run nonisolated under strict concurrency). Note: the
        // memory "gatekeeper" MemoryAgent + the AIAuditLog sink are NOT here — they are
        // pure, AI-facing control plane (every AI provider calls them) and live in
        // FernletDomainModel, so placing them in this sealed module would have been an
        // AIProviders -> Private* wall violation.
        .target(
            name: "PrivateMemoryStore",
            dependencies: ["PrivateStoreCore", "FernletCrypto", "FernletFoundation", "FernletDomainModel"]
        ),
        // Layer 3 — at-rest GCM-sealed photo index (S3). PrivateMediaStore +
        // PrivateMediaKeyStore (keychain key provider) + UIImage helpers + MealPhotoStore,
        // hoisted out of the otherwise-black-box Proximity/ subtree. NONisolated (plain
        // structs/classes). No FernletCrypto dep — these seal via CryptoKit directly with
        // their own keychain key, not ColumnCrypto. FriendPhotoPayload (their wire DTO) was
        // hoisted to FernletDomainModel in the C1 prep. The SwiftUI FriendPhotoReviewSheet
        // stays in the app.
        .target(
            name: "PrivateMediaStore",
            dependencies: ["FernletFoundation", "FernletDomainModel"]
        ),
        // Layer 4 — sanctioned egress. Converts RAW cycle data (CyclePhase, from
        // PrivateHealthStore) into the ABSTRACT period signals the scoring layer
        // consumes (PeriodPhaseSignal in FernletScoring); raw cycle types stay behind
        // this boundary. The app supplies non-sensitive wellbeing scores INTO the
        // bridge via its seam protocols (no upward edge). MainActor (@Observable bridge
        // + @MainActor seams); pure engines/value types marked nonisolated within.
        .target(
            name: "PeriodContextBridge",
            dependencies: ["PrivateHealthStore", "FernletScoring", "FernletFoundation", "FernletDomainModel"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        // Layer 4 — sanctioned egress: the typed AI context payloads (the
        // de-identification contract). Pure Sendable DTOs — AIProviders consume ONLY
        // these typed payloads, never raw sealed data. deps [FernletDomainModel] (uses
        // AIDestination). Nonisolated.
        .target(
            name: "AIContext",
            dependencies: ["FernletDomainModel"]
        ),
        // Layer 5 — AI providers (FoundationModels). THE WALLED CONSUMERS. The on-device
        // Foundation-model inference files whose deps are cleanly satisfiable below the
        // wall. Dependency list OMITS every Private* store BY CONSTRUCTION, so no sealed
        // type (CyclePhase, JournalNarrative, MenstrualNarrativeRepository, PrivateMediaStore,
        // …) is nameable here — `import PrivateHealthStore` is a compile error. The only
        // path to sealed data is the typed AIContext payloads. MainActor.
        //
        // NOTE: three further AI files (FoundationDishDecomposition, FoodProductWebImporter,
        // LaunchPreparationService) remain in the app for now — they reference app-target
        // helpers (MealBuilder/DishTemplateLexicon, NutritionLabelScanner, FernletStore) that
        // a package module cannot import. They are verified sealed-free and grep-covered by
        // FernletTests/S3BoundaryTests, which discovers every FoundationModels-using app file
        // dynamically and pins these three as a hard floor. Their move awaits helper extraction
        // (MealBuilder carve to FoodCatalog; a NutritionLabelScanning seam; a FernletStore launch seam).
        .target(
            name: "AIProviders",
            dependencies: ["AIContext", "FernletDomainModel", "FernletScoring", "FoodCatalog"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        // Layer 6 — iCloud-synced persistence. THE OTHER WALLED CONSUMER. The CoreData +
        // CloudKit repository, sync service, persistence controller, and the synced
        // SavedRecipe entity. Its dependency list OMITS every Private* store — the synced
        // blob must never name a sealed type (it references sealed entity names only as
        // string literals for iCloud EXCLUSION). Enforced as a hard error by the
        // DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR build flag. MainActor.
        .target(
            name: "CloudKitSync",
            dependencies: ["FernletPersistence", "LocalPersistence", "FernletFoundation", "FernletDomainModel"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        // Layer 7 — the central store-side services lifted out of the app target:
        // DerivedSignalsService/DerivedSignalsRebuilder (derived-signal rebuild),
        // SnapshotSaveCoordinator (debounced snapshot persistence), AIRetryQueueService
        // (meal-analysis retry queue), and SavedRecipeService (saved-recipe state). The
        // 4 service classes are individually @MainActor; DerivedSignalsRebuilder is a
        // plain nonisolated struct — so NO defaultIsolation(MainActor.self) here.
        // SavedRecipeService was inverted onto the SavedRecipeRepositoring protocol
        // (in FernletPersistence) so this module needs NO dependency on CloudKitSync.
        .target(
            name: "StoreCore",
            dependencies: ["FernletFoundation", "FernletDomainModel", "FernletScoring", "FernletPersistence", "LocalPersistence"]
        ),
        // Layer 8 — the portable diary slice carved out of the app's FernletStore. A pure
        // @Observable @MainActor store owning the diary state (day/settings/meals/journals/
        // memories/goals/workshop/foodItems/recipes/dailyScores/companionThought) + the pure
        // diary methods (scoring, meal/recipe/workout/journal-field/settings/care/load). It
        // depends ONLY on portable layers — NEVER any Private*/CloudKitSync/AIProviders/
        // HealthKit/Proximity/PeriodContextBridge module. The app-only collaborators (the 5
        // coordinators, proximity, snapshot machinery, retry/derived/saved-recipe services,
        // the period bridge) stay in the app-side FernletStore facade, which owns a DiaryStore
        // and forwards to it. Two injected closures decouple it from the facade:
        // `scheduleSnapshotSave` (→ the facade's SnapshotSaveCoordinator) and `periodAdjustment`
        // (→ the facade's PeriodContextBridge gate). MainActor: @Observable store.
        .target(
            name: "DiaryStore",
            dependencies: ["StoreCore", "FernletPersistence", "LocalPersistence", "FernletScoring", "FernletDomainModel", "FernletFoundation", "FoodCatalog"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        // Layer 6 — HealthKit platform shim ([S]). HealthKitService (@MainActor),
        // WorkoutHealthKitSync, ActivityTypeCatalog + the seam types the app/store consume
        // (HealthKitServicing, WorkoutSyncContext, HealthCapability, Authorization*/HealthBodyProfile,
        // HealthKitCacheClearing, HealthAuthorizationPresentation). Depends on PrivateHealthStore for
        // the `extension HealthKitService: PeriodHealthKitServicing` seam conformance — that is an
        // ALLOWED edge (the wall only forbids AIProviders/CloudKitSync from reaching the Private*
        // stores, not the platform gateways). The concrete CoreDataHealthKitCacheCleaner STAYS in the
        // app (it needs CloudKitSync's PersistenceController + LocalPersistence's LocalFernletDatabase)
        // and is injected through the HealthKitCacheClearing seam via an app-set static provider, so
        // this target needs NO CloudKitSync/LocalPersistence edge. MainActor (@MainActor service +
        // @Observable HealthKitAuthorizationViewModel).
        .target(
            name: "HealthKitGateway",
            dependencies: ["PrivateHealthStore", "FernletDomainModel", "FernletFoundation"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                // Swift 5 language mode (matching the app target's SWIFT_VERSION = 5.0 +
                // SWIFT_APPROACHABLE_CONCURRENCY) so HealthKit's `@Sendable` query completion
                // handlers that capture the non-Sendable observation `handler` closures keep
                // compiling exactly as they did in the app target. The handlers already hop to
                // `@MainActor` via `Task { @MainActor in … }` before touching any state, so this
                // is the source's original, behavior-identical concurrency contract — not a
                // relaxation introduced by the move.
                .swiftLanguageMode(.v5),
            ]
        ),
        // Layer 6 — app-lock platform shim ([S]). FernletLockService (@Observable @MainActor)
        // + its lock-state/credential/crypto-provider seam types. Drains the sealed
        // PendingNarrativeBuffer on unlock and defines FernletLockServicing: PeriodLockContext
        // (the PeriodLockContext seam is owned by PrivateHealthStore — a one-directional edge;
        // PrivateHealthStore never names FernletLock). Uses CryptoSwift's Scrypt directly. The
        // SwiftUI lock views (FernletLockGate/FernletLockView/OnboardingLockSetupView) stay in
        // the app (they use app Color/UI components). MainActor; crypto/date/uptime providers
        // are marked nonisolated within.
        .target(
            name: "FernletLock",
            dependencies: ["FernletFoundation", "FernletDomainModel", "PrivateStoreCore", "PrivateHealthStore", "CryptoSwift"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        // Layer 6 — assorted app platform services ([S]): NotificationService (UserNotifications),
        // WeatherKitService (@MainActor; WeatherKit + CoreLocation delegate), NutritionLabelScanner
        // (Vision/CoreImage OCR, nonisolated static helpers), and SharedRecipeImportQueue (App-Group
        // recipe-import queue + the RecipeDefinition(importedRecipe:) bridge, which needs AIProviders'
        // ImportedRecipe — a wall-legal downward edge). NO defaultIsolation: isolation is mixed
        // (WeatherKitService is explicitly @MainActor; the rest are nonisolated value types / off-main
        // Vision helpers), matching the FoodCatalog/StoreCore stance.
        .target(
            name: "AppServices",
            dependencies: ["FernletDomainModel", "AIProviders"]
        ),
        // Layer 6 — the Proximity peer-to-peer subsystem as ONE black-box shim ([S]): mesh
        // transport (MultipeerConnectivity), identity/replay (CryptoKit Ed25519/X25519), trust
        // vault, NI ranging, recipe-share + friend-photo managers, wire payloads, and the
        // ProximityHost seam protocol. "Outward edges only": the 6 files with backward edges to
        // the app (ConnectionInspector → FernletStore; the SwiftUI views on app Color/UI
        // components + FernletStore) STAY in the app, as does ProximityHostAdapter (the
        // FernletStore→ProximityHost conformance). Deps: PrivateMediaStore (MeshNetworkManager's
        // photo cache) + FernletDomainModel + FernletFoundation. defaultIsolation(MainActor.self)
        // (the managers are @Observable @MainActor).
        .target(
            name: "ProximityKit",
            dependencies: ["PrivateMediaStore", "FernletDomainModel", "FernletFoundation"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                // Swift 6 language mode (the package default — no `.swiftLanguageMode(.v5)`).
                //
                // WI-9 (2026-06-27) marked the wire `Codable` types, the canonical signing
                // serializer, and the pure `IdentityService` crypto statics `nonisolated`
                // (+ `Sendable`) so they are decode/verify-safe off the main actor. This
                // follow-up then dropped `.v5` by reworking the `nonisolated` delegate callbacks
                // that captured non-Sendable framework objects into their `Task { @MainActor … }`
                // hops — those captures are the Swift-6 `sending` data races `.v5` had hidden:
                //   • Ranging/NIRangingSession.swift — `session(_:didUpdate:)` and
                //     `session(_:didInvalidateWith:)` now extract the Sendable values
                //     (distance/direction; `ObjectIdentifier(session)`) BEFORE the hop.
                //   • Transport/MeshMultipeerSession.swift — the MCSession / advertiser / browser
                //     callbacks transfer the non-Sendable `MCPeerID` (and the single-shot
                //     `invitationHandler`) across the hop via a `nonisolated(unsafe)` local.
                //   • ForegroundAnchor/ProximityForegroundAnchor.swift — the non-Sendable
                //     ActivityKit `Activity` (a class) is passed to its `nonisolated async`
                //     `update`/`end` via a `nonisolated(unsafe)` local.
                // All rewrites are behavior-preserving — the UWB/MC/ActivityKit objects keep their
                // exact runtime semantics — so the target builds clean in Swift 6 mode. (An earlier
                // estimate of "exactly two errors, both in NIRangingSession" was incomplete: the
                // Mesh and ForegroundAnchor captures were equally blocking.)
                //
                // HealthKitGateway still uses `.v5` independently for its HealthKit `@Sendable`
                // query-completion handler captures; that is a separate target.
            ]
        ),
    ]
)
