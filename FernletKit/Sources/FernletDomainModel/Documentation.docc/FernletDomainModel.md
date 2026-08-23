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

That position dictates its three hard rules. First, the S3 privacy wall: because the walled
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

Third — new with localization Phase 1, and the rule most likely to be broken by a well-meant edit —
**the TOKEN/DISPLAY fork**. This module now owns a `Localizable.xcstrings` (the package declares
`defaultLocalization: "en"`), which makes it the place where a bulk `String(localized:)` pass does
the most damage if it is applied by shape rather than by role. Every string here is exactly one of
two things and never both: a **token** — a persisted `rawValue`, a mesh wire byte, a word in an AI
prompt, a dictionary key, an export field — which is **English forever**, because it is compared,
decoded, and signed across builds, devices, and processes; or **display**, which is the only half
that localizes. Where one string was doing both jobs it has been forked, the raw value frozen
byte-identical to what already shipped and a separate reader-facing property added beside it:

- ``CompanionState/displayName`` — the raw value is re-parsed by `WidgetCompanionState` in the
  widget extension, a SEPARATE PROCESS reading the app-group snapshot, and is a field of the Coach
  export schema. A translated raw value makes every widget fail that parse and render its no-state
  fallback, with nothing in the app to show why.
- ``CareGroup/label`` — the raw value ("Morning"/"Anytime"/"Evening") is both persisted into
  `PersonalCareTask.group` on the synced settings blob *and* the predicate the checklist filters
  rows with, so translating it renders every existing checklist empty and writes a token the user's
  other devices cannot match. ``CareGroup/init(persistedToken:)`` is deliberately an exact match.
- ``MealConfidence/label`` — the persisted provenance stamp on `Meal.confidence`, forked from the
  English phrases five writers used to store; ``MealConfidence/init(persistedToken:)`` still
  resolves those legacy spellings, which is why that table is read-only and never edited.
- ``MealType/displayName`` and ``WorkoutType/displayName`` — persisted categories that are also the
  vocabulary the meal-parsing prompt hands the model, the input `WorkoutExerciseCatalog.inferType`
  matches against, and fields of the trainer export.

Two more strings read exactly like UI copy and are not: ``PayloadSummary``'s `title`, `subtitle`,
and every `extraDetails` key and value are folded into the Ed25519 canonical signing bytes by
`CanonicalSignatureSerializer` *and* render on the RECEIVER's phone (so localizing them would put
the sender's language in someone else's audit trail); and ``CoachPlanTokens``'s frozen muscle and
equipment aliases are an allowlist an unmatched token fails, which is what keeps an imported
exercise inside the user's avoid lists. Inside a package, both `String(localized:)` and SwiftUI's
`LocalizedStringKey` resolve against `Bundle.main` unless `bundle: .module` is passed — and getting
that wrong fails silently, returning the English literal forever — so every call here passes it.
``LocaleTolerantNumber`` is the input side of the same problem: a `.decimalPad` shows the locale's
separator, so "2,5" is what a Spanish, French, or German user types, and bare `Double(_:)` returns
nil and drops the value. `Tests/FernletTests/LocalizationBoundaryTests` is the wall that turns each
of these into a test failure, and `Scripts/sync-string-catalogs.sh` repopulates the catalogs without
opening Xcode (`--check` is the CI form).

> Warning: This page named only two rules, and none of the forked types, until 2026-08-20 — the
> whole fork landed without the landing-page update CLAUDE.md requires. The next planned work is a
> bulk conversion of roughly 1,700–2,200 literals to `String(localized:)`, and a contributor who
> read the old page first had no warning that translating a `rawValue` in *this* module is a
> data-loss bug rather than a cosmetic one. If you localized anything here on the strength of the
> old text, re-check it against the list above before shipping.

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
- ``CareGroup``
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
- ``MealConfidence``
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

### Food plausibility and completeness

Five internal-consistency checks plus a completeness check, run over ONE food record on the device
that holds it — custom foods and scanned labels alike. Pure functions, no persisted surface. The
input type keeps *absent* distinct from *zero*, which is the whole point: a nutrient the scanner
never read must not reach the diary as a claim that the food contains none of it. Every threshold
traces to a published source (Atwater / 21 CFR 101.9, FAO/INFOODS 2012, USDA ARS QC, Rand et al.
1991, Greenfield & Southgate 2003); the file header records which rule came from where, and states
the design boundary that these checks must never be combined with cross-device aggregation of
user-created food records.

- ``NutritionFacts``
- ``NutritionPlausibility``
- ``NutritionPlausibilityReport``
- ``NutritionPlausibilityFinding``
- ``NutrientField``
- ``NutrientSignificanceExemption``

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

### Coach plans

The `CoachPlan v1` wire schema (Fernlet Coach spec §3.5): a 1-30 day plan authored OUTSIDE Fernlet
and ingested through a review gate. Transport-agnostic — today it arrives via the manual clipboard
exchange, later over the signed `fernlet-coach` mesh — so nothing here knows which pipe it came
down.

Two invariants make this safe to hand untrusted bytes. **Everything is bounded**: `CoachPlanLimits`
caps are enforced during decode, before values are retained. **Enum-valued fields never park an
unknown token** the way persisted types do — freeze/park is the compatibility story for a newer
*Fernlet build*'s bytes, not for a plan author's typo, so ``CoachPlanTokens`` matches against an
allowlist and an unmatched token fails. That strictness is load-bearing for
``CoachExerciseDefinition``, whose muscles, equipment, and movement pattern are exactly the inputs
``WorkoutSafetyFilter`` needs: defaulting any of them would let an imported exercise slip past a
user's avoid list.

The `edits` half is what makes "a coach adjusts my month" possible rather than only "a coach
hands me a new block": `days` proposes new workouts, while ``CoachPlanEdit`` rewrites or removes
ones already on the calendar, targeted by the `PlannedWorkout.id` the trainer export echoes.
Targeting by id rather than day+name is what survives a rename and stays unambiguous when a day
holds two workouts with the same name. An edit can only ever reach a PLANNED row that is still
ahead of today — never a logged workout, which is the guarantee that an import cannot rewrite
what actually happened.

- ``CoachPlan``
- ``CoachPlanDay``
- ``CoachSession``
- ``CoachExercise``
- ``CoachExerciseDefinition``
- ``CoachPlanEdit``
- ``CoachPlanEditAction``
- ``CoachPlanStartPolicy``
- ``CoachPlanTokens``
- ``CoachPlanLimits``
- ``CoachPlanIssue``
- ``CoachPlanDecodeError``

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
- ``HeartDropWireLimits``
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

### Localization and typed input

The display halves of the forked enums are documented on their own types (see the third hard rule
above); this section holds the module-level helper that has no other home.

- ``LocaleTolerantNumber``
