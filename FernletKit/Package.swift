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
        .library(name: "FernletKit", targets: ["FernletFoundation", "FernletCrypto", "FernletDomainModel", "FernletScoring", "FoodCatalog", "FernletPersistence", "LocalPersistence", "PrivateStoreCore", "PrivateHealthStore", "PrivateMemoryStore"]),
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
    ]
)
