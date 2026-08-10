# ``FernletDomainModel``

The portable, pure-value domain layer of Fernlet: every non-sensitive data type the app logs,
scores, syncs, and shares — meals, workouts, days, settings, coins, milestones, companion
cosmetics, and the proximity wire/audit DTOs.

## Overview

`FernletDomainModel` is the Layer-1 target of the FernletKit local package. It depends only on
`FernletFoundation` (for `FernletDate` day-key helpers) and holds no I/O, no services, no SwiftUI,
and no crypto — just `Codable`/`Sendable` value types plus deterministic pure functions
(economies, scoring inputs, search relevance, recipe math, program rendering). Nearly every other
module in the package sits above it: `FernletScoring`, `FoodCatalog`, `FernletPersistence`,
`LocalPersistence`, the `Private*` stores, `AIProviders`, `CloudKitSync`, `ProximityKit`,
`DiaryStore`, and `FernletUI` all import it.

That position dictates its two hard rules. First, the S3 privacy wall: because the walled
`AIProviders` and `CloudKitSync` targets import this module, **nothing sensitive may be nameable
here**. The raw cycle types (`CyclePhase`, cycle day entries) deliberately live in
`PrivateHealthStore`, sealed journal text is stripped before the synced blob by
``JournalEntry/strippedIfSealed(in:)`` (a fail-closed memberwise allowlist), friends receive only
the 3-way ``FriendFuzzyState`` fold of ``CompanionState`` (never a number), and the heart
dead-drop seam (``HeartDropTransporting``) sees only pseudonymous tags and ciphertext. When adding
a type here, assume AI and iCloud code can read it.

Second, forward-compatible serialization. Most of these types ride the CloudKit-synced snapshot
blob or per-day `DayRecord` rows across devices on *different app versions*, and a strict enum
decode of a raw value only a newer build knows would brick the older device into read-only
recovery. ``EnumDecodeCompat`` is the module-wide answer: unknown enum values freeze to a safe
default, the true token parks in a side-channel key and is re-encoded (so a re-save never strips a
newer device's choice), a build that knows a parked token re-adopts it, and explicit local edits
clear the park via `didSet`. ``FernletSettings`` extends the same idea to whole unknown top-level
keys via its ``JSONValue`` parking. The proximity *wire* types decode strictly — tolerance is for
persisted state, not untrusted peers, whose payloads instead pass boundary sanitizers
(`ItemGridTexture.sanitized()`, ``ItemNameModeration``, ``HeartPayload``'s day-key shape check).

Cross-device correctness without a server is handled by append-only ledgers with structurally
deterministic row ids: ``CoinEconomy`` and ``MilestoneEconomy`` collapse duplicate-id rows in code
(the storage layer does NOT de-duplicate) through the one shared `Array.deduplicatedByID()` in
`IdentityDedup.swift` — the same primitive `StoreCore`'s per-row services call on every load — so
two offline devices minting the same earn/award converge to a single grant, and reset boundaries
void pre-reset rows without deleting anything.

Concurrency: this target deliberately has **no** `defaultIsolation(MainActor.self)` — everything
is `nonisolated` pure value types, which is both required (the types cross-reference each other's
statics in initializers) and the right portability stance for the shared core. A handful of
immutable constants are `nonisolated(unsafe)` because they are built once and never mutated.
One operational hazard is documented in the repo memory: changing the stored layout of a type here
(enum cases, stored properties) requires a **clean build** — incremental builds can mask
non-exhaustive switches and ship corrupted binaries.

## Topics

### Diary and wellbeing

- ``FernletDay``
- ``JournalEntry``
- ``FeelingTag``
- ``SleepLog``
- ``SleepQuality``
- ``HygieneItem``
- ``PersonalCareTask``
- ``MemoryNote``
- ``TierTwoMemoryRecord``
- ``FitnessGoal``
- ``GoalType``
- ``DailyHealthScore``
- ``ScoringWeights``

### HealthKit day context

- ``HealthDailyContext``
- ``HealthActivitySummary``
- ``HealthBodyContext``
- ``SleepStagesData``
- ``HealthCycleContext``
- ``HealthMindfulnessContext``
- ``HealthIntimateContext``

### Nutrition profile and targets

- ``UserNutritionProfile``
- ``UserNutritionPreferences``
- ``BiologicalSex``
- ``ActivityLevel``
- ``DietaryPattern``
- ``GuidanceIntensity``
- ``NutritionTargets``
- ``NutritionTargetCalculator``
- ``FDADailyValues``
- ``MicronutrientGapAnalyzer``
- ``NutrientGap``
- ``NutrientGapStatus``
- ``NutrientReference``

### Meals and macros

- ``Meal``
- ``MealComponentSnapshot``
- ``MealType``
- ``MealQuality``
- ``MealSource``
- ``MealLogSource``
- ``Macros``
- ``MacroTotals``
- ``Micronutrients``

### Meal resolution and AI selection

- ``MealResolution``
- ``ResolvedMeal``
- ``MealResolutionConfidence``
- ``MealItemSplitter``
- ``FoodSelectionCandidateBuilder``
- ``FoodSelectionCandidate``
- ``FoodSelectionIngredient``
- ``FoodSelectionMealItem``
- ``FoodSelectionPlan``
- ``PreparedDishHeuristic``
- ``AIAnalysisRetryRecord``
- ``AIDestination``

### Food catalog and search

- ``FoodItem``
- ``FoodPortion``
- ``FoodDataType``
- ``FoodItemSource``
- ``FoodBarcode``
- ``FoodItemSearch``
- ``FoodBrandLexicon``
- ``CustomIngredientUpsert``

### Recipes

- ``RecipeDefinition``
- ``RecipeIngredient``
- ``RecipeStep``
- ``RecipeStepSanitizer``
- ``RecipeUnit``
- ``RecipeWebImport``
- ``RecipeSourceURLMatcher``
- ``RecipeScaling``
- ``RecipeSubstitution``
- ``IngredientSubstitutionSuggestion``
- ``ManualRecipeIngredientInput``
- ``SharedRecipePayload``
- ``SharedRecipeIngredient``
- ``RecipeImportError``
- ``GroceryAggregation``

### Workout logging

- ``Workout``
- ``PlannedWorkout``
- ``WorkoutType``
- ``WorkoutMode``
- ``WorkoutSplit``
- ``WorkoutPlanSource``
- ``WorkoutIntensity``
- ``WorkoutActivityType``
- ``MuscleGroup``
- ``BodyRegion``
- ``MovementPattern``
- ``Equipment``
- ``ExerciseTarget``
- ``ExerciseInputKind``
- ``WorkoutExerciseCatalog``
- ``WorkoutSuggestion``

### Workout programming

- ``WorkoutProfile``
- ``ExperienceLevel``
- ``WorkoutLocation``
- ``LocationTemplate``
- ``GymEquipment``
- ``EquipmentCategory``
- ``WorkoutSafetyFilter``
- ``TrainingSplit``
- ``WorkoutSplitDay``
- ``WorkoutSessionTemplate``
- ``WorkoutSlotSpec``
- ``SlotRole``
- ``SessionKind``
- ``SessionTime``
- ``SplitSpecificity``
- ``WorkoutSessions``
- ``WorkoutSplitCatalog``
- ``WorkoutSplitRecommender``
- ``WorkoutConsistency``
- ``WorkoutGoalStyle``
- ``WorkoutProgram``
- ``PrescribedExercise``
- ``WorkoutRestGuidance``

### Companion and appearance

- ``CompanionState``
- ``CompanionAppearance``
- ``CompanionBodyStyle``
- ``CompanionPalette``
- ``CompanionAssetColor``
- ``CompanionAccessory``
- ``CompanionClothing``
- ``CompanionSideItem``
- ``WorkshopData``
- ``TextureEntry``
- ``TextureTag``

### Custom items and the clothing shop

- ``CustomizationItem``
- ``ItemSlot``
- ``ItemGridTexture``
- ``ItemDesigner``
- ``ItemDesignPalette``
- ``ClothingShopLimits``
- ``ItemNameModeration``
- ``ReportReason``
- ``ModerationEntryKind``
- ``ModerationLedgerEntry``
- ``ClothingModerationLimits``
- ``ModerationEconomy``

### Coins and milestones

- ``CoinLedgerKind``
- ``CoinLedgerEntry``
- ``CoinEconomy``
- ``MilestoneEventKind``
- ``MilestoneLedgerEntry``
- ``MilestoneEconomy``

### Friends, hearts, and closeness

- ``FriendFuzzyState``
- ``FriendStatePayload``
- ``HeartPayload``
- ``HeartGlowMath``
- ``HeartDropRecord``
- ``HeartDropTransporting``
- ``FriendInteractionDayCounts``
- ``ClosenessMath``
- ``CloseSlotState``
- ``CloseSlotAssignment``
- ``FriendPhotoPayload``
- ``FriendPhotoSessionMetadata``
- ``FriendPhotoSessionParticipant``
- ``FriendPhotoManifestPayload``
- ``FriendPhotoManifestEntry``
- ``FriendPhotoRequestPayload``

### Group Activities

- ``ActivityLimits``
- ``ActivityDescriptor``
- ``ActivityParticipant``
- ``ActivityRosterSnapshot``
- ``ActivityJoinToken``

### Proximity wire and audit

- ``PayloadType``
- ``ProximityCapability``
- ``PayloadEncryption``
- ``PayloadSummary``
- ``DateRange``
- ``ProximityRole``
- ``ProximityMode``
- ``ProximityRangingMode``
- ``ConnectionSessionLog``
- ``ProximityTrustedPeerRecord``
- ``TrainerAuditEvent``

### Settings and navigation

- ``FernletSettings``
- ``SensitiveVisibilityResolution``
- ``SensitiveSurfaceVisibility``
- ``AIStatus``
- ``JSONValue``
- ``FernletScreen``
- ``FernletShortcut``
- ``HomeWidget``
- ``ConnectionInspectorMode``

### Age assurance

- ``AgeAssuranceRecord``
- ``AgeGate``
- ``AgeGateVerdict``
- ``AgeAssuranceProvenance``

### Serialization and privacy screens

- ``EnumDecodeCompat``
- ``DiagnosticLanguage``
