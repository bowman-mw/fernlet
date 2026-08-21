# SPM Module Carve-Up Plan

**Status: BUILT AND ENFORCED.** This stopped being a proposal on 2026-06-27 and is now the shipped
module architecture: `FernletKit/Package.swift` declares **24 library targets** under one umbrella
product, and the wall it describes is a CI-required check
(`Scripts/spm-wall-check.sh`, `.github/workflows/s3-wall.yml`). Sections 1–10 are the original plan
and are preserved as the design record; **sections 11–14 are the execution handoffs and win wherever
they disagree with 1–10.** Two disagreements are load-bearing enough to name up front, because
following the plan text instead of the handoffs would undo enforcement:

1. **The grep-wall was NOT deleted, and must not be.** §1 says the DAG "replaces" the grep-based
   `S3BoundaryTests.swift`, and step 10 of §6 (repeated in the §10 checklist) says to delete it. That
   was reversed once the wall was actually built: the compile half and the grep half cover different
   failure modes, so both are kept. §12's "THE WALL" section and CLAUDE.md both record the grep-wall
   as the **complementary** half, and every handoff since ends with "DO NOT do step 10." Corrections
   are inlined at each of those three places below.
2. **A forbidden import is not a "no such module" error by itself.** §3 assumes SPM search paths make
   the sealed modules unnameable. Under one umbrella product Xcode pools every local-package module
   into a single `…/PackageFrameworks` search path, so a forbidden `import` *resolves* and downgrades
   to a warning. The hard error comes from building with
   `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR` — proven empirically in §12, and the reason
   `Scripts/spm-wall-check.sh` exists at all. Believing §3 as written would mean shipping with the
   wall silently off.

**Where the shipped graph differs from §2.** The plan sized this at "~21 library targets"; the tree
has 24, and `Package.swift` uses `swift-tools-version: 6.2` (not the 6.0 in §6 step 1). Added since:
`WebScrapingKit` (the no-tracking wall's single outbound-fetch seam), `PrivateStoreCore`, `DiaryStore`
(§5d's `FernletStore` decomposition landed as its own target), and `FernletLockUI`. Not built:
`Onboarding` — the onboarding state machine and its views stayed in the app target
(`App/Fernlet/Onboarding*.swift`). Narrower than planned: `FernletUI` is the **design system**
(theme, primitives, components, `ModelColors`, `CaptureProtection`), not "all SwiftUI screens" —
the screens are still app-resident, and five Proximity UI files stay there by necessity because they
hold `FernletStore` references (§14). Also still app-resident: three of the six AI provider files,
which need a downward inversion before they can move behind the wall (§12 "Deferred", recipe in §14).

**Scope:** structure + sequencing of the package split. Serves two goals with one set of cuts: the
**S3 compile-time privacy walls** and the **cross-platform shared core**. The Proximity *internal*
refactor is explicitly **out of scope** — Proximity is treated here as one black-box module boundary.
(The two companion documents cited in the original header, `RemainingWork-2026-06-23.md` and
`Canonical-Signing-Encoding-Fix.md`, are no longer in the tree; the live successors are
[`RemainingWork-2026-08-20.md`](RemainingWork-2026-08-20.md) and CLAUDE.md's wall sections.)

---

## 1. TL;DR

Carve the single-target app into **one local Swift package (`FernletKit`) with ~21 library
targets**. The package's `dependencies:` graph *is* the S3 wall: a target can `import` only the
targets it declares, so a forbidden import (AI code reaching a sealed type) becomes a **compile
error**, complementing the grep-based [`S3BoundaryTests.swift`](../Tests/FernletTests/S3BoundaryTests.swift).

> **Correction (2026-06-27, kept as standing policy).** This sentence originally said the DAG
> *replaces* the grep test. It does not, and the grep test is still in the tree deliberately. The two
> halves fail differently: the compile half covers every file and survives renames, but only fires on
> recompile and only under the enforcement flag (§12); the grep half runs in the ordinary unit suite,
> needs no special build or CI runner, and catches a sealed *symbol* travelling through an edge that
> is legal in the DAG — something a dependency graph cannot see. Deleting either leaves a hole.

The same cut delivers the Android shared core for free — the portable, Foundation/`swift-crypto`-only
**lower half of the graph is exactly the cross-platform core**; the Apple-bound upper half is the
set of platform shims that get native Android implementations behind shared seam protocols.

**The cost is detangling, not packaging.** Two god-files block everything and must be split first:
`Models.swift` (3,195 lines) and `FernletStore.swift` (2,200 lines, which violates *both* the
platform boundary and the privacy boundary). `Package.swift` itself is trivial by comparison.

---

## 2. Target module graph (layered DAG)

One package `FernletKit/` (sibling of `App/Fernlet/`, **not** inside the synced folder root). Layers are
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

> ⚠️ **Correction — that last sentence is not true as Xcode builds this package.** Under the single
> umbrella product, Xcode pools *every* local-package module into one `…/PackageFrameworks` search
> path, so the forbidden `import` resolves and the build emits only a build-system **warning**;
> splitting into separate SPM products does not change it (verified empirically). The hard error is
> obtained by building with **`DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR`**, which turns the
> missing declared dependency into `error: '<module>' is missing a dependency on '<sealed module>'`.
> The flag must be passed on the build command — the pbxproj value does not reach the synthesized
> package targets — which is exactly what `Scripts/spm-wall-check.sh` does, and why the wall is a CI
> job rather than a property of the checkout. §12 has the full write-up and the proof. **The
> forbidden-edge list below is still the guarantee; only the mechanism sentence was wrong.**

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
> **DONE (verified 2026-07-19).** Shipped with one deviation: `DerivedSignalFactory.swift` and the
> tier-two memory engine landed in `LocalPersistence` (alongside `LogRecords.swift`), not
> `StoreCore` — `StoreCore` instead holds the derived-signals *services*
> (`DerivedSignalsService`/`DerivedSignalsRebuilder`). `LocalFernletRepository.swift` is now 440
> lines in `LocalPersistence`; `FernletRepository.swift` + `FernletSnapshot.swift` live in
> `FernletPersistence` as planned.

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
10. ~~**Delete [`S3BoundaryTests.swift`](../Tests/FernletTests/S3BoundaryTests.swift).**~~ **DO NOT DO
    THIS — reversed 2026-06-27 and never performed.** The step assumed the DAG alone enforces the wall
    for all code; §12 showed the DAG needs an enforcement *flag* on the build command to bite at all,
    and that the grep-wall catches a class the DAG cannot (a sealed symbol crossing a legal edge). The
    negative-compile tripwire this step called "optional" is the one part that shipped, as
    `Scripts/spm-wall-selftest.sh`. `S3BoundaryTests.swift` stays, and was made move-tolerant
    (basename matching across scan roots) so file relocations do not silently blind it. The per-target
    `.testTarget` half is still open work — the tests remain in the host-app `FernletTests`, which
    means the pure-logic ones do not yet run on Linux as the cross-platform gate.

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
  dropping into `App/Fernlet/`, no pbxproj surgery). Hazard: Xcode does **not** auto-exclude a subfolder
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
- [ ] ~~Delete `S3BoundaryTests.swift`~~ **— cancelled; the grep-wall is kept as the complementary
      half of the wall (see the correction on step 10).** Add per-target test targets (pure-logic
      tests run on Linux) — still open.

---

## 11. Handoff notes (Phases 0–2 executed 2026-06-26)

**Status:** Phases 0–2 (the serial gate) are done and committed green, one commit per step, on top of
git tag **`spm-carveup-baseline`** (known-good rollback point). Commits `0fc138c` (detangle) →
`b034fad` (JournalSealing). FernletStore went 2,222 → ~1,560 lines.

### Done
- **§5a–5c detangle in place.** `Scoring.swift` → `import Foundation`; `compute(for store:)` deleted
  (field extraction inlined into `FernletStore.score`). `Models.swift` (3,195 lines) split into the §5c
  files; all SwiftUI `Color`/`color(for:)` members stripped into `ModelColors.swift`. **§5e
  (`LocalFernletRepository` split) was NOT done** — out of scope for this gate.
- **FernletKit package** stood up empty (`FernletFoundation` target only), linked to the app.
- **§5d decomposition: 6 of 7 units** extracted behind narrow context protocols — `ProximityHost`,
  `WorkoutPlanningService`, `MealResolutionService`, `SealedBackupCoordinator`, `HealthSyncCoordinator`,
  `JournalSealingCoordinator`. **`DiaryStore` deferred by decision** → do it AS PART OF the StoreCore
  module extraction (it's ~70% of the store and needs app-wide `@Observable` forwarding: `day`×74,
  `settings`×58, `snapshotSaveCoordinator`×36, `batchSnapshotPersistence`×34 refs — high-risk churn
  that gets re-touched at module time, so don't do it in-target).

### Deviations from this plan
- **`swift-tools-version: 6.2`, not the §6.1 literal `6.0`.** The `.defaultIsolation(MainActor.self)`
  swiftSetting that §7 mandates is a Swift 6.2 manifest API; 6.0 can't express it. Toolchain in use:
  Swift 6.3.2 / Xcode 26.5. Keep 6.2 (or higher) for every target.
- The seam protocols defined so far are the per-coordinator `*Context` protocols (mirroring the existing
  `WorkoutSyncContext`), **not** the layer-0 `SecureKeyValueStore`/`BiometricGate`/`HealthSampleSource`/
  `CloudSyncTransport` from §10 — those are still TODO for the real module cuts.

### Gotchas the next session would otherwise rediscover
- **There is a SECOND grep-wall beyond `S3BoundaryTests`.**
  `Tests/FernletTests/PeriodTrackerTests.menstrualFlowCountReferenceIsRestrictedToAllowedFiles` keeps its own
  hardcoded file allowlist (it scans for `menstrualFlowEventCount`). Splitting `Models.swift` broke it;
  it was updated `Models.swift` → `WellbeingModels.swift` (where `HealthCycleContext` now lives). Any
  further file split/rename touching that symbol must update this allowlist too.
- **The "retain cycle" in §5d is really a TYPE-coupling fix.** `MeshNetworkManager`/
  `ProximityRecipeShareManager` held `unowned let store: FernletStore` (non-retaining already), and
  `WorkoutHealthKitSync` holds its context `weak`. `ProximityHost` was about removing the concrete-type
  dependency so the subtree can become `ProximityKit`, not plugging a leak.
- **`ProximityHost` minimal-churn shape:** kept the param **label** `store:` and widened only the *type*
  to `any ProximityHost`, so all 17 call sites (incl. 15 in `MeshNetworkManagerTests`) compile
  unchanged. The protocol is `AnyObject`-bound (required for `unowned` on the existential).
- **Coordinator idiom:** each coordinator reads/mutates via a narrow `*Context` protocol that
  `FernletStore` conforms to. `scheduleSnapshotSave()` satisfies BOTH `HealthSyncContext` and
  `JournalSealingContext` — it's defined once; don't redefine it per conformance (duplicate-method error).
- **`journalContentKey` is still private on the store** and surfaced to `SealedBackupCoordinator` via a
  `sealedBackupContentKey` accessor whose conformance lives **in FernletStore.swift** (so it can read the
  private field). When `JournalSealingCoordinator`/`DiaryStore` fully own this, re-route the accessor.
- **`SealedBackupWiringError`** is referenced by tests as `FernletStore.SealedBackupWiringError` → kept a
  `typealias` to `SealedBackupCoordinator.SealedBackupWiringError`. Don't drop it.
- **Store wrappers that MUST stay** (external/test callers): `restoreSealedBackup`, `applyRestoredPayload`,
  `applyRestoredChunks`, `fallbackMicronutrients`, `resolveMeals`, `activate{NoLock,Sealed}Journals`,
  `deactivateSealedJournals`, `loadDayWithDecryptedJournals`, plus the workout/health wrappers. The
  `init(journalNarrativeRepository:)` param is used by `FernletTestHelpers` + `FernletPersistenceTests` —
  kept (captured as `providedJournalNarrativeRepository` for the lazy coordinator).
- **Period sealed-backup export is chunked** (2026-06-27 hardening of the security-review item: the old
  `MenstrualNarrativeRepository.allNarratives` materialized the entire cycle history before sealing). The
  export now pages the repo (`narrativeCount` + `narratives(offset:limit:)`, stable `dateKey`+`hkExternalUUID`
  order) and seals one `SealedBackupCoordinator.periodBackupChunkSize` (250) page per CloudKit record via
  `SealedBackupService.reconcileChunked`. Each chunk is an independent AES-GCM record named
  `sealed-backup.periodData[.chunk.<i>]`; the head (chunk 0) carries `chunkCount` and is written **last** as
  the commit marker, then stale higher chunks are pruned. `chunkIndex`/`chunkCount` are bound into the GCM
  AAD and re-checked in `CloudKitDataService.sealedBackupChunks`, so an incomplete or mixed-generation set
  fails closed on restore (`restoreChunks` → `applyRestoredChunks`). Sensitive-notes stays a single record.
  This is sealed end-to-end before egress — it was a memory/availability fix, not a confidentiality one.
- **Cycle-strip trap still pending.** `currentSnapshot`/`strippedForStorage`/`storedDailyScores` remain in
  the store; the journal-text strip now calls `journalSealingCoordinator.isSealed(_:)`. When
  `FernletPersistence` is extracted, this strip (journal text + `healthContext.cycle/intimate` +
  `DailyHealthScore.periodPhase`) must travel WITH `FernletSnapshot` (see §8).
- **pbxproj wiring for a LOCAL package** (objectVersion 77 / Xcode 16+): `FernletKit` is a sibling of the
  synced `App/Fernlet/` (NOT inside it); `relativePath = FernletKit`. Needs: `XCLocalSwiftPackageReference`,
  add to project `packageReferences`, an `XCSwiftPackageProductDependency` (**no `package =` line** for a
  local product), add to the app target's `packageProductDependencies`, and a `PBXBuildFile` in the app's
  `PBXFrameworksBuildPhase`. App target id `6869C2E12FB8D39D0098A0F3`, its Frameworks phase
  `6869C2DF2FB8D39D0098A0F3`. `.swiftpm/` and `.build/` are now in `.gitignore`.

### Build/test hygiene (cost me a red commit once)
- **Don't `tail` the build log to check success** — `xcodebuild … | tail -40` drops the actual `error:`
  lines, and a `grep` that matches the `FAILED` summary still exits 0. Capture FULL output to a file and
  gate on the **exit code** + `** TEST (BUILD|EXECUTE) SUCCEEDED **`. (A red SealedBackup build slipped
  through this way and was `--amend`ed green.)
- **Full `FernletTests` ≈ 7 min**; some suites dominate (e.g. `FernletLockTests` ~8s/test). Batch by
  suite (`-only-testing:Tests/FernletTests/<Suite>`) — build the test target once, then `test-without-building`
  per batch.
- Live UI verify needs the **computer-use MCP**; `idb` is not installed and Accessibility (osascript)
  is denied, so `simctl` screenshots are the only no-MCP option. App launches clean to onboarding and to
  the main UI via the `-completeOnboarding` launch arg.

---

## 12. Phases 3–5 handoff (steps 6–8 executed 2026-06-27, session 2)

**Branch:** `claude/laughing-goldstine-c8b9e9` (worktree). **Status:** steps 6, 7, 8 DONE and committed;
each module is its own commit, build-green (and FULL `FernletTests` green at every sealed-store / wall boundary).
Builds via the umbrella `FernletKit` product (one product, all targets) — no per-module pbxproj surgery.

### Modules extracted this session (commit → module)
- `510d8b5` step-6 prep hoist: `FernletLockError` + `FernletAuditLog` → **FernletFoundation**; `AIDestination` +
  `FriendPhotoPayloads` (6 Wire DTOs) → **FernletDomainModel**.
- `74d345d` **PrivateStoreCore** (NEW, layer 2.5, nonisolated): `PrivatePersistenceController` +
  `PrivatePersistentHistoryPruner` + `PendingNarrativeBuffer` + `PendingNarrativePayload`. *Deviation from the plan,*
  which put the controller in PrivateHealthStore — but the sealed CoreData stack is shared by BOTH sealed stores AND
  the lock service, and must sit on the protected side of the wall, so it is its own target.
- `2bbb096` **PrivateHealthStore** (MainActor): PeriodTrackerStore, CyclePredictionEngine, Menstrual/Intimacy repos +
  the raw cycle value types (CyclePhase stays here, never DomainModel, so AI can't see it). Split PeriodTrackerStore.swift:
  the `extension HealthKitService: PeriodHealthKitServicing` moved to app `HealthKitService.swift`; `PeriodHealthKitServicing`
  rewritten as a narrow standalone seam; `HealthKitService()` default removed (inject); fat `FernletLockServicing` now
  *refines* a narrow `PeriodLockContext` seam (zero call-site churn). `ColumnCrypto` (FernletCrypto) marked `nonisolated`.
- `f511f8e` **PrivateMemoryStore** (nonisolated): `JournalNarrativeRepository` ONLY. `MemoryAgent` + `AIAuditLog` are pure
  AI-facing control plane (every AI provider calls them) → they went to **AIContext** (`cdb7cde`), NOT the sealed module
  (would have been a latent AIProviders→Private* wall violation).
- `b5e1a8b` **PrivateMediaStore** (nonisolated): the 3 `Proximity/Photos/` non-UI files + `MealPhotoStore`.
- `abd06fa` **PeriodContextBridge** (MainActor; pure types nonisolated) · `2ce58f9` **AIContext** (payload DTOs; +explicit
  Sendable on 8 DomainModel value types; S3BoundaryTests made path-robust) · `cdb7cde` MemoryAgent+AIAuditLog → AIContext.
- `12996ef` **AIProviders** (MainActor; deps AIContext+DomainModel+Scoring+FoodCatalog, no Private*) = 3 cleanly-walled
  files. `05ee239` **CloudKitSync** (MainActor; deps FernletPersistence+LocalPersistence+FernletFoundation+DomainModel,
  no Private*) + the wall hardening.

### THE WALL — how it is actually enforced (load-bearing correction to §3/§10)
§3 assumed a forbidden import would be a hard "no such module" compile error. It is NOT, under the single umbrella
product: Xcode pools every local-package module into one `…/PackageFrameworks` search path, so a forbidden
`import PrivateHealthStore` from AIProviders RESOLVES and emits only a build-system *warning*. **Separate SPM products do
not fix this** (verified empirically — same pooling). The true hard error is obtained by building with
**`DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR`** (Xcode "Validate Dependencies = Yes (Error)"). PROVEN: the forbidden
import → `** TEST BUILD FAILED **` (exit 65) `error: 'AIProviders' is missing a dependency on 'PrivateHealthStore'`;
reverted → green; a clean build of the whole DAG under the flag is green (all declared deps complete). The pbxproj value
does NOT propagate to synthesized package targets, so it must be a **build-command override** (bake into CI). It only
re-fires on recompile, so CI clean builds are the reliable enforcement point. The honest package DAG + this flag IS the
wall; `S3BoundaryTests` is kept as a belt-and-suspenders grep (and was made robust to the file relocations).

### Deferred (not yet behind the wall) — 3 AI files still in the app target
`FoundationDishDecomposition` (uses `MealBuilder`/`DishTemplateLexicon`), `FoodProductWebImporter` (uses
`NutritionLabelScanner`/`NutritionLabelResult`), `LaunchPreparationService` (uses `FernletStore`, 7 methods). A package
module cannot import the app target, so each needs a downward inversion first: carve the pure `MealBuilder.mealFromIngredients`
+ `DishTemplateLexicon.componentGramBounds` into FoodCatalog; a `NutritionLabelScanning` seam (+ `NutritionLabelResult` →
DomainModel); a `FernletStore` launch seam. All 3 are verified to reference ZERO sealed types and (the aiFacing ones) stay
grep-covered by S3BoundaryTests.

### Remaining work (next session)
1. ~~Confirm the step-8 boundary FULL suite passed.~~ DONE (session 3) — `OVERALL: ALL-GREEN`.
2. ~~Add the committed wall-enforcement artifact.~~ DONE (session 3, `6274f1e`) — `Scripts/spm-wall-check.sh` + CLAUDE.md note.
3. ~~**Step 4c — StoreCore + DiaryStore** (the hardest).~~ DONE (session 3) — see §13.
4. **Step 9 — shims:** HealthKitGateway (will dep PrivateHealthStore for the period extension — OK, not a wall edge;
   note WorkoutSyncContext lives in WorkoutHealthKitSync.swift and the FernletStore facade conforms to it — keep the
   protocol reachable), FernletLock (redeclare CryptoSwift; deps PrivateStoreCore + PrivateHealthStore), AppServices,
   ProximityKit (27-file black box; deps PrivateMediaStore+DomainModel; ProximityHost seam already breaks app coupling).
5. (Optional) the 3 deferred AI-file inversions above, to put all 6 AI providers behind the wall.
- DO NOT do step 10 (delete S3BoundaryTests / per-target test targets) — post-review.

## 13. Step 4c + wall artifact handoff (executed 2026-06-27, session 3)

**Branch:** `claude/laughing-goldstine-c8b9e9`. **HEAD:** `176d61e`. Tree clean. Each module its own commit, build-green
under `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR`, with the gate (batch C per module; FULL A1–E at the step boundary).

- `6274f1e` **Wall artifact** — `Scripts/spm-wall-check.sh` runs `build-for-testing` with the enforcement flag (CI-runnable;
  derives repo root; `FERNLET_DESTINATION` override). Documented in CLAUDE.md. The honest DAG + this flag IS the wall.
- `e61d551` **StoreCore** (step 4c part 1; portable layer-2, deps FernletPersistence+LocalPersistence+FernletScoring+
  DomainModel+FernletFoundation; NO defaultIsolation — services are individually `@MainActor`, `DerivedSignalsRebuilder` is a
  pure struct). Moved the 5 sub-services. **Inversion to keep StoreCore portable:** new `SavedRecipeRepositoring` protocol in
  FernletPersistence (mirrors `FernletRepository`); concrete `SavedRecipeRepository` conforms in CloudKitSync — so StoreCore
  has NO backwards edge to layer-6 CloudKitSync.
- `176d61e` **DiaryStore** (step 4c part 2, the hardest; new layer-2.5 module, `defaultIsolation(MainActor)`, deps
  StoreCore+FernletPersistence+LocalPersistence+FernletScoring+DomainModel+FernletFoundation+FoodCatalog, NO app/sealed dep).
  Split the 1782-line `@Observable FernletStore` into `FernletKit/Sources/DiaryStore/DiaryStore.swift` (853 lines: pure synced
  state + pure methods + per-day scoring + snapshot round-trip) and the app `FernletStore` facade (1465 lines).

  **Design — the facade pattern (lowest-risk).** The facade owns `@ObservationIgnored let diary: DiaryStore` + ALL app-only
  collaborators and forwards every diary member (settable forwarders write through; observation rides on DiaryStore via
  `diary.<prop>` access). DiaryStore depends on no app/sealed module because TWO injected closures decouple it:
  `scheduleSnapshotSave` (replaces `snapshotSaveCoordinator.schedule()`) and `periodAdjustment` (replaces the facade-only
  `PeriodContextBridge` read; default `.none`). Init builds the diary with no-op hooks then `rewireHooks([weak self]…)`
  post-init — the diary is a `let`, so this avoids an init-order cycle. The facade keeps its 5 context-protocol conformances
  (Meal/Workout/Journal/Health/SealedBackup) by forwarding to the diary.

  **Five traps the carve resolves (these correct/extend §5d):** (1) the persistence snapshot mixes diary state AND app-only
  proximity/retry state, so `currentSnapshot`/`reloadFromRepository`/`apply`/`snapshotSaveCoordinator` STAY in the facade
  (the manifest wrongly placed them in DiaryStore). (2) `aiRetryQueueService`/`derivedSignalsService`/`savedRecipeService` are
  portable StoreCore *types* but stay facade-side because they're snapshot-wired — pulling the retry/derived/saved meal
  methods back to the facade. (3) `MealPhotoStore` lives in the sealed `PrivateMediaStore`, and `MealBuilder` +
  `HealthCapability` are still app-target types, so those methods (meal-correction, logRecipe, macro totals, photos,
  visibleHealthCapabilities) stay facade-side — a portable diary core must not import a sealed/app type. (4) `upsertWorkout`
  routes to the PURE `diary.appendWorkout` so a workout imported FROM HealthKit isn't re-saved to HealthKit. (5)
  `sealedBackupContentKey` is the one context member NOT forwarded (→ `journalSealingCoordinator.contentKey`); the key never
  enters DiaryStore. Behavior-identical: full `FernletTests` ALL-GREEN, zero test files changed.

## 14. Step 9 handoff — platform shims extracted (executed 2026-06-27, session 4)

**Branch:** `claude/laughing-goldstine-c8b9e9`. Base: HEAD `3da080c` (which already fully contained
`main`, incl. the sealed-backup chunking `fc42532` — the requested "merge main first" was a no-op).
**Status:** step 9 (the four platform shims) DONE, one commit per module, each build-green under
`DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR` with its targeted test batch; FULL suite at the
step-9 boundary. The umbrella `FernletKit` product now has **21 targets**.

### Modules extracted (commit → module)
- `2260ebc` **HealthKitGateway** (layer 6, MainActor): HealthKitService + WorkoutHealthKitSync +
  ActivityTypeCatalog. Deps PrivateHealthStore (the `extension HealthKitService:
  PeriodHealthKitServicing` seam — an ALLOWED edge) + DomainModel + FernletFoundation.
- `e8a065c` **FernletLock** (layer 6, MainActor): FernletLockService only. Deps FernletFoundation +
  DomainModel + PrivateStoreCore + PrivateHealthStore + the external **CryptoSwift** package.
- `6016f18` **AppServices** (layer 6, NO defaultIsolation): NotificationService, WeatherKitService
  (@MainActor), NutritionLabelScanner, SharedRecipeImportQueue. Deps DomainModel + AIProviders.
- `649858e` **ProximityKit** (layer 6, MainActor): 21 of the 27 Proximity/ files as one black-box
  target. Deps PrivateMediaStore + DomainModel + FernletFoundation.

### Deviations / decisions worth knowing
- **Two `swiftLanguageMode(.v5)` targets: HealthKitGateway and ProximityKit.** Both wrap callback-heavy
  Apple frameworks whose `nonisolated` delegate/completion handlers hop to `@MainActor` via `Task` while
  capturing non-Sendable framework objects — HealthKit anchored-object-query handlers; NISessionDelegate
  /MCSessionDelegate callbacks (NISession, [NINearbyObject], MCSession). This compiled under the app
  target's Swift 5 mode but is a hard data-race error under the package's Swift 6 default. v5 on these two
  targets preserves the exact original concurrency contract rather than rewriting working transport code.
  (The other 19 targets stay Swift 6.)
- **Cache-cleaner seam (HealthKitGateway):** the concrete `CoreDataHealthKitCacheCleaner` needs
  CloudKitSync's `PersistenceController` + LocalPersistence's `LocalFernletDatabase`, which the gateway
  must not depend on, so it STAYS in the app (`App/Fernlet/CoreDataHealthKitCacheCleaner.swift`) and is
  injected via `HealthKitService.defaultCacheClearer` (no-op default in the gateway), set in
  `FernletApp.init()` before any HealthKitService is built. The `HealthKitCacheClearing` protocol moved
  to the gateway (public).
- **CryptoSwift is FernletKit's first external package dependency** — `.upToNextMinor(from: "1.10.0")`,
  matching the app's pbxproj reference exactly so SPM resolves a single shared CryptoSwift. Only
  FernletLock uses it (Scrypt KDF).
- **Spurious-import trap caught at the gateway step:** the HealthKitGateway extraction added
  `import HealthKitGateway` to `Proximity/ProximityHost.swift` (WorkoutSyncContext is doc-comment-only
  there); the orchestrator removed it because ProximityHost.swift later moves to ProximityKit, which has
  no HealthKitGateway dep — under the wall flag that would have been a hard error in the ProximityKit step.

### ProximityKit split (the only module that left files behind)
6 of the 27 Proximity/ files STAY in the app (backward edges; FernletUI isn't carved out yet):
`Audit/ConnectionInspector.swift` (holds `weak var store: FernletStore?`), the 4 `UI/*` SwiftUI views
(app Color extensions + FernletCard/SectionLabel/ScreenHeader + FernletStore), and
`Photos/FriendPhotoReviewSheet.swift` (app Color + ChipButtonStyle). `ProximityHostAdapter.swift` (the
FernletStore→ProximityHost conformance) also stays. The 21 movers are self-contained (verified: no mover
references a staying type, and no lower module references a mover — the proximity persistence DTOs +
ProximityCoordinator's nested enums were already hoisted to DomainModel in step 4 prep, so cross
references are downward typealiases). `ConnectionSessionLog` is in DomainModel and crosses freely.

### Boundary FULL-suite result + pre-existing failures fixed/flagged
The step-9 boundary FULL suite (batches A–E) surfaced THREE failures, all PRE-EXISTING from earlier
sessions (the prior handoffs' "ALL-GREEN" was at a commit before these were broken; the full suite was
not re-run at `3da080c`). `git diff 3da080c..HEAD` proves step 9 touched none of the relevant code paths:
- `PeriodPredictionUITests.predictionPathDoesNotReferenceAICode` / `...DoesNotWritePredictionsToHealthKit`
  read source via `#filePath` with hardcoded paths to `App/Fernlet/CyclePredictionEngine.swift` +
  `App/Fernlet/PeriodTrackerStore.swift`, which moved to `FernletKit/Sources/PrivateHealthStore/` in **step 6**.
  **FIXED** in `9cc94b0` (paths updated; no assertion changed) — both pass.
- `FernletPersistenceTests.test_reload_updatesReloadingState` is a **load-sensitive FLAKY** observation
  race: `withObservationTracking`'s single-shot `onChange` schedules a `Task { @MainActor in … }` that
  reads `PersistenceController.isReloading` after the `@MainActor reload()` may have already flipped it
  back to false. It failed once under the full-suite's parallel sim-clone load but PASSES 3/3 in isolation.
  Pre-existing since `PersistenceController` became `nonisolated` in step 8 (CloudKitSync). NOT fixed — it
  is unrelated prior-session test debt; recommend hardening the test (deterministic observation) or a
  retry annotation in a follow-up. **All other suites green.**

### Hardcoded-source-path tests to track across future moves (now FOUR)
`S3BoundaryTests` (walks both App/Fernlet/ AND FernletKit/Sources, robust), `PeriodTrackerTests.menstrualFlow
CountReferenceIsRestrictedToAllowedFiles` (allowlist), the two FernletLock `#filePath` tests
(FernletLockServiceTests/FernletLockCryptoTests), and now `PeriodPredictionUITests.runGitGrep`. Any file
move/rename of the symbols they scan must update their hardcoded paths/allowlists.

### Remaining work (next session)
1. (Optional) the 3 deferred AI-file inversions (§12 item 5) to put all 6 AI providers behind the wall:
   FoundationDishDecomposition, FoodProductWebImporter, LaunchPreparationService.
   **Scoped 2026-07-19 (dependency map verified in code — use this as the recipe):**
   - **LaunchPreparationService** (342 lines): sole app coupling is `FernletStore`, param-injected,
     never stored — but the seam is **~16 members**, not the "7 methods" above: the 7 methods
     (`reconcileGuidedRunFromAppGroup`, `purgeDataExports`, `storeCompanionThought`,
     `backfillWorkoutsFromHealthIfNeeded`, `loadDays`, `loadDay(for:)`, `storeDaySummary`) PLUS
     9 property reaches incl. a write (`photowallSeeds`) and nested paths
     (`meshNetworkManager.meshPhotos`, `day.workouts/journals`, `settings.aiStatus`,
     `derivedSignals`, `memories`, `todayKey`, `dailyScores`, `tierTwoMemories`). Flatten the
     nested reaches into protocol members. Call sites: `ContentView.swift:22,178,1162`,
     `FernletStoreLoader.swift:15,28`.
   - **FoundationDishDecomposition** (243 lines): needs **four** downward moves, not two —
     (a) `MealBuilder.mealFromIngredients` + its `componentSnapshots`/`totals` helpers → FoodCatalog
     (verified data-pure; the struct's `@MainActor`+AIProviders import belongs to `meals(from:)`,
     not these); (b) `DishTemplateLexicon.componentGramBounds` + `matchDetailsWithCount` +
     `catalog` → FoodCatalog, WITH `DishTemplates.json` added to FoodCatalog `resources:` and the
     `Bundle.main` load at `DishTemplateLexicon.swift:46` switched to `Bundle.module`
     (`resolve`/`assemble` stay app-side until after (a)); (c) the plan-omitted
     `MealPlausibility.maxSingleLogCalories/-Grams` consts (`MealResolutionService.swift:25-30`);
     (d) the file itself.
   - **FoodProductWebImporter** (948 lines): the blocker is a **dependency cycle** — it
     `import AppServices` for `NutritionLabelScanner`/`NutritionLabelResult`, but AppServices
     depends on AIProviders. Fix: `NutritionLabelResult` → FernletDomainModel (retype touches
     `FoodCaptureRouter`, `BarcodeScanView`, `NutritionLabelCameraSheet`, `FoodView` ×6 sites +
     2 test files) and a `NutritionLabelScanning` protocol (in AIProviders or DomainModel) that the
     importer takes injected; the concrete scanner stays in AppServices. No other app refs.
   - **S3BoundaryTests is move-tolerant** (matches floor files by basename across scanRoots incl.
     AIProviders — `S3BoundaryTests.swift:21-29,48-50,235-244`); only the stale `// app-resident`
     comments need touching. Moved symbols must become `public`.
2. ~~Carving `FernletUI`~~ **DONE 2026-07-19.** `FernletUI` (theme palette + hex parsing, type
   roles/fonts/metrics/motion, color tokens, screen/sheet primitives incl. FernletCard/SectionLabel/
   EmptyState extracted from HomeView, ModelColors) and `FernletLockUI` (FernletLockSetupView /
   FernletLockView / FernletNumericPad / fernletLockGate) are package targets; ProximityKit gained
   `UI/` with the two app-free movers (KeepFriendsPromptSheet, FriendPhotoReviewSheet + saver).
   App-navigation enums (FernletTab/FernletSheet) stayed app-side in `App/Fernlet/FernletNavigation.swift`
   per §5c. **The remaining 5 Proximity UI files stay in the app by necessity, not by blocker:**
   ConnectionInspector + the two inspector views + both recipe-share sheets hold `FernletStore`
   references — they move only when a `ProximityHost`-style store inversion happens (§5d), which is
   NOT a FernletUI concern. Wall check + targeted suites green.
3. ~~(Optional) harden the flaky `test_reload_updatesReloadingState`~~ **Already hardened** (the
   synchronous `MainActor.assumeIsolated` observation recording, verified 3/3 green 2026-07-19).
4. DO NOT do step 10 (delete S3BoundaryTests / per-target test targets) — post-review.
