# SPM Module Carve-Up Plan

**Status:** Proposed. Serves two goals with one set of cuts: the **S3 compile-time privacy walls**
and the **cross-platform shared core** (see [RemainingWork-2026-06-23.md §2](./RemainingWork-2026-06-23.md)
for S3, and the canonical-signing prerequisite in
[Canonical-Signing-Encoding-Fix.md](./Canonical-Signing-Encoding-Fix.md)).
**Scope:** structure + sequencing of the package split. The Proximity *internal* refactor is
explicitly **out of scope** — Proximity is treated here as one black-box module boundary.

---

## 1. TL;DR

Carve the single-target app into **one local Swift package (`FernletKit`) with ~21 library
targets**. The package's `dependencies:` graph *is* the S3 wall: a target can `import` only the
targets it declares, so a forbidden import (AI code reaching a sealed type) becomes a **compile
error**, replacing the grep-based [`S3BoundaryTests.swift`](../FernletTests/S3BoundaryTests.swift).

The same cut delivers the Android shared core for free — the portable, Foundation/`swift-crypto`-only
**lower half of the graph is exactly the cross-platform core**; the Apple-bound upper half is the
set of platform shims that get native Android implementations behind shared seam protocols.

**The cost is detangling, not packaging.** Two god-files block everything and must be split first:
`Models.swift` (3,195 lines) and `FernletStore.swift` (2,200 lines, which violates *both* the
platform boundary and the privacy boundary). `Package.swift` itself is trivial by comparison.

---

## 2. Target module graph (layered DAG)

One package `FernletKit/` (sibling of `Fernlet/`, **not** inside the synced folder root). Layers are
numbered; **edges only point to strictly lower layers** — no peer or upward edges. Portability:
`[C]` shared-core (Foundation/`swift-crypto` only → compiles on Android), `[S]` platform-shim
(Apple-bound → needs a native Android impl behind a seam protocol), `[U]` ui-app (SwiftUI →
reimplemented natively). **S3** marks one of the spec's named privacy modules.

### Layer 0 — Foundation core
| Module | Responsibility | Depends on | Tag | S3 |
|---|---|---|---|---|
| `FernletFoundation` | Cross-cutting primitives + the platform **seam protocols** (`SecureKeyValueStore`, `BiometricGate`, `HealthSampleSource`, `CloudSyncTransport`) so nothing above names Security/HealthKit/CloudKit directly. `StoragePreferences`, `StartupTiming`, `FernletDate`. | — | [C] | |
| `FernletCrypto` | Pure sealing primitives: `ColumnCrypto` (per-repo HKDF-labelled AES-GCM), `SealedBackupService`. `import CryptoKit` → `import Crypto` on Android. | `FernletFoundation` | [C] | |

### Layer 1 — Domain core (the portable heart)
| Module | Responsibility | Depends on | Tag | S3 |
|---|---|---|---|---|
| `FernletDomainModel` | Day/nutrition/meal/recipe/workout/journal/companion value types (split out of `Models.swift`, **`Color` stripped**), `WorkoutProgram`, `MealBuilder`, `CustomIngredientUpsert`. | `FernletFoundation` | [C] | |
| `FernletScoring` | Scoring/goal-weight/workout-planning engine (`Scoring.swift`, primitive entry points only), `MealParser`, `WorkoutPlanner`. | `FernletDomainModel` | [C] | |
| `FoodCatalog` | USDA search/scoring (`FoodCatalog`, `FoodDataCatalog`, `BundledFoodStore` behind `BundledFoodSource`, `DishTemplateLexicon`). Owns `FoodCatalog.sqlite`. | `FernletDomainModel` | [C] | |

### Layer 2 — Persistence contract + portable engines
| Module | Responsibility | Depends on | Tag | S3 |
|---|---|---|---|---|
| `FernletPersistence` | `FernletRepository` protocol + `FernletSnapshot` aggregate + `strippedForStorage` (the cycle-strip travels here). | `FernletDomainModel` | [C] | |
| `StoreCore` | Portable sub-services: `DerivedSignalFactory`, `TierTwoMemoryEngine`, `AIRetryQueueService`, `SnapshotSaveCoordinator`, `SavedRecipeService`. | `FernletPersistence`, `FernletScoring` | [C] | |
| `LocalPersistence` | Foundation-only `LocalFernletRepository` + `LocalFernletDatabase` + `*LogRecord` DTOs. | `FernletPersistence` | [C] | |

### Layer 3 — Sealed stores (protected side of the wall)
| Module | Responsibility | Depends on | Tag | S3 |
|---|---|---|---|---|
| `PrivateHealthStore` | Sealed cycle/intimacy: `PeriodTrackerStore`, `CyclePredictionEngine`, `MenstrualNarrativeRepository`, `IntimacyLogRepository`, `PrivatePersistenceController`. | `FernletCrypto`, `FernletDomainModel` | [S] | **yes** |
| `PrivateMemoryStore` | Sealed journal + memory gatekeeper: `JournalNarrativeRepository`, `PendingNarrativeBuffer`, `MemoryAgent`, `AIAuditLog`. | `FernletCrypto`, `FernletDomainModel` | [C] | **yes** |
| `PrivateMediaStore` | At-rest GCM-sealed photo index: `PrivateMediaStore`, `PrivateMediaKeyStore`, `FriendPhotoImageHelpers`, `MealPhotoStore` (hoisted out of `Proximity/Photos/`). | `FernletCrypto`, `FernletFoundation` | [S] | **yes** |

### Layer 4 — Sanctioned egress (the ONLY legal path to AI)
| Module | Responsibility | Depends on | Tag | S3 |
|---|---|---|---|---|
| `PeriodContextBridge` | Exports ONLY abstract `PeriodPhaseSignal`/`PeriodScoringAdjustment`; raw cycle types stay behind. `PeriodPhaseTrendEngine`. | `PrivateHealthStore`, `FernletScoring` | [C]\* | **yes** |
| `AIContext` (ContextBuilder) | `AIContextPayload`, `AIDestination`, the sanctioned payload structs. The de-identification chokepoint: imports sealed stores, emits only typed payloads. | `PeriodContextBridge`, `PrivateMemoryStore`, `FernletDomainModel` | [C] | **yes** |

\* `PeriodContextBridge`'s *exported surface* is shared-core; its HealthKit ingestion edge is an
injected dependency (`HealthSampleSource`), so the export contract stays portable.

### Layer 5 — AI providers (structurally walled consumers)
| Module | Responsibility | Depends on | Tag | S3 |
|---|---|---|---|---|
| `AIProviders` | The 6 `import FoundationModels` files (`FoundationFoodSelection`, `FoundationDishDecomposition`, `FoundationWorkoutAdjustment`, `RecipeWebImporter`, `FoodProductWebImporter`, `LaunchPreparationService`) + deterministic fallbacks. | `AIContext` **only** — **never** a `Private*` store | [S] | **yes** |

### Layer 6 — Platform shims
| Module | Responsibility | Depends on | Tag | S3 |
|---|---|---|---|---|
| `HealthKitGateway` | HealthKit seam: `HealthKitService`, `WorkoutHealthKitSync`, `ActivityTypeCatalog`. Conforms to `HealthSampleSource`. | `FernletDomainModel`, `FernletScoring` | [S] | |
| `FernletLock` | App lock: `FernletLockService`, `FernletLockGate`, `FernletLockView`. Conforms to `SecureKeyValueStore`/`BiometricGate`. Re-declares `CryptoSwift`. | `FernletFoundation`, `FernletCrypto` | [S] | |
| `CloudKitSync` | `CoreDataFernletRepository`, `CloudKitDataService`, `Persistence`, CoreData `SavedRecipe`. Alternate `FernletRepository`. **Must omit all `Private*` stores** (verify exact upper deps at extraction). | `FernletPersistence` | [S] | |
| `AppServices` | `NotificationService`, `WeatherKitService`, `NutritionLabelScanner`, `SharedRecipeImportQueue`. | `FernletDomainModel` | [S] | |
| `ProximityKit` | **One black-box module** — whole `Proximity/` tree. Depends only on a narrow `ProximityHost` protocol + `PrivateMediaStore`. | `FernletDomainModel`, `PrivateMediaStore` | [S] | |

### Layer 7 — UI / App
| Module | Responsibility | Depends on | Tag | S3 |
|---|---|---|---|---|
| `FernletUI` | All SwiftUI screens + `FernletTheme`, `AmbientCards`, `EquipmentIcons`, and **`ModelColors.swift`** (the stripped `Color` extensions). | domain, scoring, stores, gateways | [U] | |
| `Onboarding` | First-run state machine + `PrivacyDataSettingsView`. | `FernletUI`, persistence, `FernletLock` | [U] | |
| `FernletApp` (app target) | Composition root: `FernletApp`, `ContentView`, the **slimmed** `FernletStore` + coordinators. The only layer that knows every module; assembles walls without crossing them. | everything | [U] | |

---

## 3. The S3 wall — forbidden edges that ARE the guarantee

The privacy guarantee is realized by **edges deliberately absent** from `Package.swift`. SPM hands
each target only the `.swiftmodule` search paths for its declared dependencies, so a module not in
the list is literally not importable — `import PrivateHealthStore` from a target that doesn't depend
on it fails with **"no such module"** at compile time.

**Edges that must NEVER appear:**
- `AIProviders` → `PrivateHealthStore` / `PrivateMemoryStore` / `PrivateMediaStore` ❌
- `CloudKitSync` → any `Private*` store ❌ (the synced blob must never name a sealed type)
- `AIContext` → `PrivateHealthStore` **directly** ❌ — it reaches cycle data **only** through
  `PeriodContextBridge`'s abstract surface.

**The only legal path AI → sealed data:**
```
PrivateHealthStore ┐
                   ├─► PeriodContextBridge ─► AIContext ─► AIProviders
PrivateMemoryStore ┘                          (typed payloads only)
```

Because `AIProviders` lists only `AIContext`, **no symbol in any `Private*` store is even nameable**
from an AI file — sealed types are unreachable by construction, not by convention. This replaces the
grep test (which only scans a hardcoded 5-file allowlist for 7 literal tokens): the DAG covers every
file, survives renames, and turns a violation into a red build instead of a `cmd-U`-only failure.

---

## 4. Dual payoff — the same graph serves S3 and cross-platform

Both questions reduce to one: *"is this pure value-logic, or does it bind an Apple framework?"*

- **Shared-core `[C]` (compiles on Android, zero rewrite):** `FernletFoundation`, `FernletCrypto`,
  `FernletDomainModel`, `FernletScoring`, `FoodCatalog`, `FernletPersistence`, `StoreCore`,
  `LocalPersistence`, `PrivateMemoryStore`, `AIContext`, and the exported surface of
  `PeriodContextBridge`. This is the **entire protected side of the S3 wall**.
- **Platform-shim `[S]` (Android supplies a 2nd impl behind the seam protocol):** `HealthKitGateway`
  (`HealthSampleSource`), `FernletLock` (`SecureKeyValueStore`/`BiometricGate`), `CloudKitSync`
  (alternate `FernletRepository`), `PrivateHealthStore`/`PrivateMediaStore` (CoreData/Keychain/UIImage),
  `AIProviders` (FoundationModels → Android LLM), `AppServices`, `ProximityKit`.
- **UI-app `[U]` (native reimplementation):** `FernletUI`, `Onboarding`, `FernletApp`.

The seam protocols live in `FernletFoundation`/`FernletDomainModel`, so the portable core never names
an Apple framework. **The privacy wall and the portability seam are the same set of cuts.**

---

## 5. The detangle (do this FIRST — nothing extracts until it's done)

### 5a. Sever the SwiftUI → domain edge *(highest leverage)*
- `Scoring.swift:1` — `import SwiftUI` → `import Foundation` (it uses zero SwiftUI symbols).
- `Models.swift:1` — strip every `var color: Color` off the ~10 domain enums (`MealType`,
  `FeelingTag`, `WorkoutType`, `WorkoutSplit`, `CompanionState`, `TextureTag`, …; ~95 `Color` refs)
  into a new `ModelColors.swift` in `FernletUI`, re-added via extensions.

### 5b. Delete the core → app scoring edge *(low effort, do immediately)*
- `Scoring.swift:352` — delete `FernletScoring.compute(for store: FernletStore)`. Move its field
  extraction up into `FernletStore.score`, calling the existing primitive
  `FernletScoring.compute(journalTag:mealCount:…)`. `FernletScoring` now depends only on value types.

### 5c. Split `Models.swift` (3,195 lines, ~95 types, 6 domains)
| New file | Holds | Target |
|---|---|---|
| `NutritionModels.swift` | `Macros`, `Micronutrients`, `FoodItem`, `FoodPortion`, `Recipe*`, `NutrientGap/Reference`, `MicronutrientGapAnalyzer`, `NutritionTargetCalculator`, `Meal/MealType/MealQuality`, FoodSelection DTOs, `MealItemSplitter` | `FernletDomainModel` |
| `WorkoutModels.swift` | `Workout`, `PlannedWorkout`, `WorkoutType/Split/Mode/Intensity`, `MuscleGroup`, `BodyRegion`, `Equipment`, `MovementPattern`, `WorkoutActivityType`, `ExerciseTarget`, `ExerciseInputKind`, `WorkoutExerciseCatalog` | `FernletDomainModel` |
| `WellbeingModels.swift` | `FernletDay`, `Health*Context`, `SleepStagesData`, `JournalEntry`, `FeelingTag`, `SleepLog/Quality`, `HygieneItem`, `PersonalCareTask`, `MemoryNote`, `FitnessGoal`, `GoalType`, `DailyHealthScore` | `FernletDomainModel` |
| `CompanionModels.swift` | `CompanionAppearance` + enums, `CompanionState`, `WorkshopData`, `TextureEntry/Tag` (Color stripped) | `FernletDomainModel` |
| `SettingsModel.swift` | `FernletSettings` (serialization aggregate) | core |
| `NavigationEnums.swift` | `FernletScreen`, `HomeWidget`, `FernletShortcut`, `ConnectionInspectorMode` | app target |
| `ModelColors.swift` | every `var color: Color` extension (imports SwiftUI) | `FernletUI` |

Invert the two domain→service back-references inside `Models.swift`: `MemoryNote.fromJournal` calls
`MemoryAgent.containsDiagnosticLanguage`, and nutrient-gap analysis calls `FernletScoring` — move
those calls out of the value types (or keep them same-module) so the model layer has no upward edge.

### 5d. Decompose `FernletStore.swift` (2,200 lines — violates BOTH boundaries)
It `import`s HealthKit **and** holds `journalContentKey` + `MenstrualNarrativeRepository` + AI food
resolution in one `@Observable` class. Split behind protocols (mirror the existing
`ProximityTrustPolicy`/`WorkoutSyncContext` extension pattern):

| New unit | Responsibility | Target |
|---|---|---|
| `DiaryStore` | day/settings/meals/recipes/scores/goals/memories vs. `FernletRepository` + snapshot round-trip (`import Foundation` only) | core (`StoreCore`) |
| `HealthSyncCoordinator` | `updateHealthContext`, workout HealthKit backfill/observe — owns `HealthKitServicing` | app |
| `JournalSealingCoordinator` | the Sealed-Journal extension: device/user content keys, migrate/refresh/seal — owns `JournalNarrativeRepository` + Keychain | app |
| `SealedBackupCoordinator` | `setSealedBackupEnabled`/`restoreSealedBackupsIfNeeded` — owns `SealedBackupService`, `CloudKitDataService`, `MenstrualNarrativeRepository` | app |
| `MealResolutionService` | `resolveMeals`/`commitResolution` — owns `Foundation*Model` + `MealBuilder` + `FoodCatalog` | app |
| `WorkoutPlanningService` | `recommendedSplits`/`workoutDayPlan`/`adjustWorkoutDayPlan` — owns `WorkoutProgram` | app |
| `ProximityHostAdapter` | conforms to a narrow `ProximityHost` protocol (displayName, trusted peers, `isBlocked`, payload builders) so `ProximityKit` depends only on the abstraction | app |

The `ProximityHost` protocol also **breaks the `App ↔ Proximity` retain cycle** — today
`MeshNetworkManager.swift:59` / `ProximityRecipeShareManager.swift:55` hold `unowned let store:
FernletStore` while the store lazily constructs them.

### 5e. Split `LocalFernletRepository.swift` (1,239 lines, 4 concerns)
→ `FernletRepository.swift` (protocol + default ext) + `FernletSnapshot.swift` → `FernletPersistence`;
`LocalFernletRepository.swift` + `LocalFernletDatabase` + `*LogRecord` → `LocalPersistence`;
`DerivedSignalFactory.swift` + `TierTwoMemory.swift` → `StoreCore`; `RetryQueueModels.swift` → core.

---

## 6. Incremental sequence (app builds green at every step)

1. **Empty package.** `mkdir FernletKit`; `Package.swift` (`swift-tools-version: 6.0`,
   `platforms: [.iOS(.v26)]`, one `.library`, an empty `FernletFoundation` target). Add Local Package
   in Xcode, link the product to the app, build green. *(Tag a known-good build first.)*
2. **Detangle in place (§5a–5c, 5e), still in the app target.** Import fix, delete `compute(for:)`,
   strip Colors, split `Models.swift`/`LocalFernletRepository.swift` into files. No module moves yet —
   behavior-identical. *This is the unblock.*
3. **Extract Core + Crypto + Domain (leaf-first).** `FernletDate`/`StoragePreferences` →
   `FernletFoundation`; `ColumnCrypto`/`SealedBackupService` → `FernletCrypto`; the split `*Models` +
   `WorkoutProgram`/`MealBuilder` → `FernletDomainModel`; `Scoring` → `FernletScoring`. Add the seam
   protocols to `FernletFoundation`. Set `defaultIsolation(MainActor.self)` per target with
   `@Observable`/MainActor types. Pay the access-control tax compiler-driven.
4. **Extract persistence + portable engines.** `FernletPersistence`, `LocalPersistence`, `StoreCore`,
   `FoodCatalog` (declare `FoodCatalog.sqlite` in `resources: [.copy(...)]`; flip
   `Bundle.main` → `Bundle.module`).
5. **Decompose `FernletStore` (§5d).** Land `DiaryStore` into `StoreCore`; create the app-side
   coordinators; introduce `ProximityHost`.
6. **Extract the sealed stores (layer 3)** — `PrivateHealthStore`, `PrivateMemoryStore`,
   `PrivateMediaStore` (the one cut that touches the otherwise-deferred Proximity subtree: hoist the
   three `Photos/` files + `MealPhotoStore`).
7. **Extract the egress (layer 4)** — `PeriodContextBridge` (already clean), `AIContext`.
8. **Extract `AIProviders` (layer 5) — THE WALL FLIP.** Move the 6 FoundationModels files into a
   target whose `dependencies:` is `["AIContext"]` and **omits every `Private*` store**. Any lingering
   sealed import now fails to compile. Same for `CloudKitSync`.
9. **Extract remaining shims** — `HealthKitGateway`, `FernletLock` (re-declare `CryptoSwift` first),
   `AppServices`, and `ProximityKit` as one target (outward edges only; internals untouched).
10. **Delete [`S3BoundaryTests.swift`](../FernletTests/S3BoundaryTests.swift).** The DAG enforces the
    wall for all code. Optionally keep one deliberately-failing negative-compile fixture in CI as a
    tripwire. Add per-target `.testTarget`s; move pure logic tests there (they also run on Linux as
    the cross-platform gate); keep CoreData/HealthKit integration in the host-app `FernletTests`.

---

## 7. Mechanics & gotchas

- **One package, many targets** (a "modular monolith"), not many packages — one `Package.swift` is a
  single source of truth for the `swift-crypto`/`CryptoSwift` versions and the whole dependency graph.
- **Access-control tax (pervasive, medium):** every cross-module symbol becomes `package` (preferred)
  or `public`; every cross-module value type needs an **explicit `public init`** (memberwise inits
  don't cross modules — easy to miss on structs). Lean on `package` to avoid a true public-API explosion.
- **MainActor isolation is NOT inherited.** The app sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`;
  SPM targets default to `nonisolated`, so `@Observable` state crossing modules sprays cross-actor
  errors (the same class as the recent "MainActor-isolated init in nonisolated default argument" fix).
  Set `defaultIsolation(MainActor.self)` in each affected target's `swiftSettings` **up front**.
- **Synced folder groups:** the project uses `PBXFileSystemSynchronizedRootGroup` (files added by
  dropping into `Fernlet/`, no pbxproj surgery). Hazard: Xcode does **not** auto-exclude a subfolder
  you move into the package — physically move files out of the synced root, don't leave duplicates.
- **Resources:** `FoodCatalog.sqlite` (and `DishTemplates.json`/`WorkoutExercises.json`) must move to
  the owning target's `resources:` and switch to `Bundle.module`. Keep `AppIcon`/`AccentColor` in the
  app-target asset catalog.
- **Build time:** first clean build is slower (more `.swiftmodule` emission + cross-module barriers);
  incremental builds get faster (touch one module, rebuild one module).

---

## 8. Effort, risk & traps

- **Detangle (steps 2, 5) — HIGH, and the gate.** `FernletStore` decomposition dominates: it is
  simultaneously the platform-boundary and privacy-boundary violator, and nothing modularizes until
  it is split behind protocols. The `Models.swift` split is mechanical but touches nearly everything.
- **Access control + MainActor — MEDIUM, pervasive.** Budget for it on every extraction.
- **Resource/Bundle — LOW effort, HIGH if missed.** A missed `Bundle.module` builds clean and crashes
  at runtime.
- **Sealed stores + egress (steps 6–8) — MEDIUM.** Mostly mechanical once the store is decomposed;
  `PeriodContextBridge` is the correct pattern to copy for journal/memory egress.
- **Proximity — LOW (deferred).** One black-box target; the only intrusion is hoisting the three
  `Photos/` files into `PrivateMediaStore`.

**Non-obvious trap to guard:** `DailyHealthScore.periodPhase` and `HealthDailyContext.cycle/intimate`
are cycle-derived fields on **core** value types that must be stripped before the synced blob. When
those types move down to the core, the strip logic must travel **with `FernletSnapshot`
serialization** (into `FernletPersistence`) — not stay in the app store — or a future caller silently
re-introduces a leak the (now-deleted) grep test can't catch.

---

## 9. Do-first checklist (this week, behavior-identical, no package yet)

- [ ] `Scoring.swift:1` — `import SwiftUI` → `import Foundation`.
- [ ] `Scoring.swift:352` — delete `FernletScoring.compute(for store:)`; move field extraction into `FernletStore.score`.
- [ ] Move `Models.swift` `Color` extensions → `ModelColors.swift`.
- [ ] Split `Models.swift` into the per-domain files (§5c) — still in the app target.

These three changes alone make the entire domain + scoring layer portable-extractable. Then stand up
the empty package (step 1) and move `Models`/`Scoring`/`Crypto` as the first real cut.

---

## 10. Full action checklist

- [ ] §5 detangle: `Models.swift`, `FernletStore.swift`, `LocalFernletRepository.swift`, `Scoring.swift`.
- [ ] Define seam protocols (`SecureKeyValueStore`, `BiometricGate`, `HealthSampleSource`, `CloudSyncTransport`) in `FernletFoundation`.
- [ ] Stand up `FernletKit` package; extract layers 0→2 leaf-first; set `defaultIsolation(MainActor.self)` per target.
- [ ] Decompose `FernletStore` behind protocols; introduce `ProximityHost` (breaks the App↔Proximity cycle).
- [ ] Extract sealed stores (layer 3), egress (layer 4).
- [ ] **Wall flip:** extract `AIProviders`/`CloudKitSync` with `Private*` stores omitted from `dependencies:`.
- [ ] Extract remaining shims; `ProximityKit` as one black-box target; re-declare `CryptoSwift`.
- [ ] Move resources to `Bundle.module`; verify `FoodCatalog.sqlite` loads.
- [ ] Ensure the cycle-strip moved with `FernletSnapshot` into `FernletPersistence`.
- [ ] Delete `S3BoundaryTests.swift`; add per-target test targets (pure-logic tests run on Linux).
