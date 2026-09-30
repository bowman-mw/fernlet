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
``JournalEntry/strippedIfSealed(in:)`` (a fail-closed memberwise allowlist), Core Memory — which
rides that same synced blob — never holds a journal entry's words: an entry mints an emotion-only
``MemoryNote`` (``MemoryNote/emotionOnly(for:)``, its ``FeelingTag`` token and no text), and only an
on-device AI summary that passes ``JournalMemorySummaryPolicy`` (bounded, no diagnostic language,
not verbatim, not a prefix, not an excerpt) may give it text (owner decision 2026-09-23), friends receive only
the 3-way ``FriendFuzzyState`` fold of ``CompanionState`` (never a number), and the heart
dead-drop seam (``HeartDropTransporting``) sees only pseudonymous tags and ciphertext. The
HealthKit day-context types are nameable here but never persisted to iCloud: since 2026-09-23 the
storage strip in `FernletPersistence` drops the whole ``HealthDailyContext``, HealthKit's sleep hours
(``HealthDailyContext/healthKitSleepLogHours`` is the provenance marker it reads) and Apple Health
workout imports before any synced write, and this device keeps its copy in a device-local cache.
When adding a type here, assume AI and iCloud code can read it.

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

- ``CompanionEmotion/displayName`` and ``CompanionEmotion/feelingPhrase`` (2026-09-24) — the
  companion's momentary feeling, a presentation layer over the state. Its lower-case raw values look
  even less like copy than the state's, and are exactly as frozen: the widget-publishable six cross
  into the widget process as each moment's `emotionRaw` in the snapshot's emotion timeline, where the
  hand-copied `WidgetCompanionEmotion` re-parses them. The enum is deliberately NOT `Codable`, so no
  persisted or synced model can carry it; see ``CompanionEmotion/isWidgetPublishable`` for which
  five feelings never leave the app and why.
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
- ``JournalMemorySummaryPolicy``
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

``NutritionTargetCalculator`` is Mifflin–St Jeor × activity, goal-adjusted. Weight Management is
the one goal with a real calorie cut, and it is fenced (2026-09-23): 10% below maintenance by
default (`defaultWeightManagementDeficitPercent`; owner sign-off 2026-09-24, "do 10% as a baseline,
users can change this as afterwards"), never under `deficitFloorKilocalories(for:)` (1,200 kcal
female / 1,500 kcal male, and never under estimated RMR), and never above maintenance. The user may
choose 0–20% in 5% steps: ``FernletSettings/weightManagementDeficitPercent`` (`nil` = the default,
synced like the macro overrides) read through `weightManagementDeficitPercent(for:)`, with
`normalizedWeightManagementDeficitPercent(_:)` enforcing the range at decode, at the setter, and in
the math. The floors bind at every choice; a pinned `calorieTargetOverride` outranks it; there is no
under-18 exception (owner, 2026-09-24). `GoalType.nutritionSummary(weightManagementDeficitPercent:)`
states the value in effect on the goal card. Evidence and options:
`Docs/Calorie-Deficit-Research-2026-09-23.md`.

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

``Macros`` is whole grams everywhere it is stored and summed: meals, day records, HealthKit, the widget,
exports and targets. Decimal grams (2026-09-29) exist only where a person types an ingredient's
macros ("3.4 g protein"), in ``PreciseMacros``. A ``FoodItem`` keeps them in the additive optional
blob key `preciseMacros`, at tenths of a gram (the precision they are typed and shown at), only
while they are valid, fractional, and round to exactly its `macros` (read them through
``FoodItem/exactMacros``). The invariant that keeps every existing number still:
``PreciseMacros/scaled(by:)`` and ``PreciseMacros/rounded`` reproduce ``Macros/scaled(by:)``
exactly, so a whole-gram food scales to the same integers as before and each consumer rounds ONCE
per ingredient from the exact value (``RecipeServingConversion/scaledMacros(for:)``). A decimal food
scales to tenths first (``FoodItem/scaledPreciseMacros(by:)``), so the whole gram a total counts is
the rounding of the tenth its row shows: "2.5 g" counts 3 g, never 2. Totals stay whole grams. On
the `fernlet.recipe` wire the fraction rides ``SharedRecipeIngredient/preciseMacros``, an optional
key on version 1 that must round, at tenths, to the whole-gram fields; the hash-covered exchange
packet never carries it.

- ``Meal``
- ``MealComponentSnapshot``
- ``MealType``
- ``MealQuality``
- ``MealConfidence``
- ``MealSource``
- ``MealLogSource``
- ``Macros``
- ``PreciseMacros``
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
- ``FoodPortionReader``
- ``FoodPortionMeasure``
- ``FoodDataType``
- ``FoodItemSource``
- ``FoodBarcode``

An amount becomes nutrition only through ``RecipeServingConversion``, which fails closed: an amount
it cannot ground in the food's serving or in one of its USDA household portions converts to nothing,
never to a guess. A VOLUME amount (2026-09-30, the ingredient-search round's F1(b)) takes the portion
stated in the requested unit when there is exactly one, and otherwise the food's volume portions'
agreed density: ``FoodPortion/densityAgreement(among:)`` answers with the median-density portion
only when every portion's g/ml lies within ``FoodPortion/densityAgreementTolerance`` (15%) of it, so
butter's cup and tablespoon convert a teaspoon while a banana's sliced and mashed cups refuse. A
COUNT stays strict — exactly one portion of that count unit. The amount a tap binds,
``FoodItem/preferredRecipeUnit`` × ``FoodItem/defaultRecipeQuantity(for:)``, carries an invariant
(F1(c)): it converts. The unit the data suggests is kept only when ``FoodItem/tapDefaultConverts(_:)``
holds, else grams, else "1 serving" — so no tap lands on an amount the recipe editor then refuses.

A portion is read TOLERANTLY (F4a, ``FoodPortionReader``): its leading measure word decides and the
qualifiers go, so "cup, sliced" is a cup and "medium (7" to 7-7/8" long)" a size. "Each" is the
food's one medium portion among several sizes, else its single named count ("clove", "egg", "fruit",
a closed list of frozen English nouns), else the named count its own NLEA/RACC serving names (a
lemon's 58 g fruit) — always a USDA weight, never an estimate. The reader only ADDS conversions: a
portion stated exactly (``FoodPortion/exactRecipeUnit``) answers first, and every exactly stated
answer an earlier build gave is kept. "Each" leads the tap default, so a banana taps to one medium
banana (118 g) and a bare "2 eggs" logs two eggs, not two cups. What a count word leads is set aside
when it is not one of anything (fix round 1): a count unit on a USDA yield ("piece, cooked, excluding
refuse (yield from 1 lb raw meat with refuse)" is a pound's cooked yield, 283 g of pork roast, so
"1 piece" refuses as it did before the round) and a named count holding a part or packaging word
("apricot half with liquid", "small box (1.5 oz)" of raisins) — frozen tokens beside the nouns.

``FoodItemSource`` gained its fourth frozen token, `openFoodFacts`, on 2026-09-24: a barcode product
the user looked up on Open Food Facts (behind the web-nutrition-lookup consent, one explicit tap per
lookup) and kept after reviewing it. It is a user food row — synced with the rest of `foodItems`,
never merged into the bundled catalog — whose values are Open Food Facts contributors', so it is
not `.manual`. Two invariants ride on it: every surface that names such a row's source shows
``FoodItemSource/attributionLine`` (the ODbL notice), which ``FoodItem/dataSourceLabel`` does for
the search rows; and search ranks it manual > openFoodFacts > usda > aiResolved, each source on a
distinct priority because the comparators stop at the first differing source. A build that predates
the token reads the row as `.manual` and parks the token (`EnumDecodeCompat`), so a round trip
through an older device loses nothing.

``FoodItemSearch``'s comparator has one per-user input, research §26 fix 1.9's
``FoodSearchHistory``: the foods this person has logged, weighted by frequency and recency, read as
its TOP ranking key. It defaults to ``FoodSearchHistory/empty`` on every entry point and
``FoodItemSearch/scoredResults(for:in:limit:stripsStopwords:)`` has no parameter for it at all — so
every confidence gate that reads a score is cold by construction, and the profile can only re-rank
rows the match gate and both floors already admitted. It is derived, never stored: `DiaryStore`
computes it from `recentMeals`.

A score is a RETRIEVAL judgement, and its prefix and substring bonuses reward a typed word found
inside a longer one ("apple" scores *APPLEBEE'S, chili* past ``FoodItemSearch/confidentBindScore``).
So a confidence stamp asks one more question the score cannot:
``FoodItemSearch/nameStatesQueryAsWords(_:query:stripsStopwords:)`` — does the name say every typed
word whole, or its regular plural? The quick-log plan tier (`MealResolutionService.bindConfidence`)
requires both before it auto-commits (2026-09-30, the ingredient-search round's fix round 1). It asks
one more about the AMOUNT when the text named a food and no unit ("honey", "pineapple"): the unit the
tier guessed — a recipe tap's default — must be one serving the data vouches for,
``FoodItem/guessedUnitIsOneServing(_:)``: a volume only on a food stating a single volume measure
(cooked rice's cup, not honey's cup beside its tablespoon), a named item within
``FoodItem/guessedItemMaxGrams`` and ``FoodItem/guessedItemMaxCalories`` (one banana, not a 905 g
pineapple or an 828 kcal stick of butter). Otherwise the plan pauses for review with the bind in place.

The recipe surfaces order their rows differently (2026-09-30, the ingredient-search round's F5, the
owner's call that "for the recipe it's more important to rank the plain ingredients first"). A caller
passing ``FoodSearchRanking/ingredientIdentity`` — the recipe editor's typeahead and the swap sheet,
nothing else — gets ``FoodIngredientIdentity``'s key above every other: a row whose name IS the typed
ingredient (its head noun, plural-aware, read the way USDA and branded names are written) ranks ahead
of a row that only contains the words, so "Sugars, brown" leads the cereals that mention brown sugar.
The standard keys order each side, so a person's own and logged foods still lead the identity group.
For a typed compound ("whole milk", "olive oil") a USDA reference row that writes the modifier as its
kind ("Milk, whole", "Oil, olive") leads the other USDA rows — a level read after history and source,
never above a personal row. A product name (branded, restaurant, scanned) is read as one phrase: a
preposition makes it a composite and a first segment followed by anything but an echo of its words or a
variant word ("Salsa, Mild", "Chocolate Chips, Semi-sweet") is a flavor list, so "Lemon, Ginger Drink"
is not a lemon; a person's own food is read by its first segment ("Chicken breast, grilled"). Every
entry point defaults to ``FoodSearchRanking/standard``, and
``FoodItemSearch/scoredResults(for:in:limit:stripsStopwords:)`` passes it explicitly, so quick-log, the
meal composer, Adjust meal, the resolver and every confidence gate rank exactly as before. The key is
off, and the order standard, while the head noun is still being typed.

- ``FoodItemSearch``
- ``FoodSearchRanking``
- ``FoodIngredientIdentity``
- ``FoodSearchHistory``
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

A recipe may be made in parts (2026-09-24): a dressing first, then the salad. ``RecipeComponent`` is
an id PARTITION over the recipe's flat `ingredients` and `steps`, never a copy of them. Nutrition,
scaling, grocery aggregation, logging and every older reader keep working on the flat arrays, and
each row counts exactly once. Read parts only through ``RecipeDefinition/resolvedComponents``, the one
resolution rule: a row no part claims joins the last part, empty parts drop, fewer than two collapse
to a one-part recipe, and at most ``RecipeComponentLimits/maxComponents`` parts are honoured. A one-part
recipe has no `components` key, so its blob and wire bytes are unchanged. On the `fernlet.recipe` wire
the version stays 1. A multipart payload carries the whole recipe in its flat arrays, in part order,
with steps labelled by part (``RecipeComponentWire``), plus an optional count partition
(``SharedRecipeComponent``). An older build reads a flat recipe with section-labelled steps, and a
newer one rebuilds the parts (``RecipeComponentImport``). The labelling separator and every JSON key
are tokens and never localize. Part names are user content (``RecipeComponentNaming`` normalizes
them).

A line chosen as a household amount that only this round's readers convert ("1 each" of a banana,
half a cup of butter beside its tablespoon) is SAVED as the grams it converts to, with the choice in
the line's additive optional ``RecipeHouseholdMeasure`` ("medium", 118 g per one) — 2026-09-30, F4a.
Grams are the only encoding every build and every peer resolves; "1 each" of a banana converts only
where the portion reader knows what one weighs, and an unconvertible line totals a recipe at zero. A
line an older build already reads to the same grams ("1 cup" of a food stating one cup, "2 slice") is
kept as typed (fix round 1), so the grocery list, share text and export still show it. Every path
that mints a recipe line applies the rule: the editor, a substitution fork
(``RecipeSubstitution/substitutedIngredient(replacing:originalFoodItem:with:)``) and a recipe a meal
log creates (``RecipeDefinition/savingHouseholdAsGrams(using:)``, applied where the store commits it).
A fork saved as grams keeps the ORIGINAL line's grams (118 g of banana swaps for 118 g of apple,
"0.65 medium"), and its count is rounded finer than one decimal where one decimal would move it more
than ``RecipeSubstitution/roundingTolerance`` — never to zero (fix round 2). Its measure is read
off ONE unit, not the count: 320 g of onion is 106.7 cloves of garlic, past
``RecipeConversionLimits/maxCount``, and is saved as `320 g` beside "clove" (N-2). A substitute
served by count with no grams form whose matched count does not convert takes its tap default.
The measure is display metadata: nutrition never reads it, the recipe page shows "1 medium (118 g)"
(``RecipeIngredient/amountText``), the editor re-opens the line as "1 each"
(``RecipeIngredient/restoringHouseholdAmount(using:)``), and the `fernlet.recipe` wire carries the
plain grams, so its bytes and keys are unchanged. No new ``RecipeUnit`` token exists or may be added
for it.

- ``RecipeDefinition``
- ``RecipeIngredient``
- ``RecipeStep``
- ``RecipeStepSanitizer``
- ``RecipeComponent``
- ``ResolvedRecipeComponent``
- ``RecipeComponentLimits``
- ``RecipeComponentNaming``
- ``RecipeComponentInput``
- ``RecipeComponentAssembly``
- ``RecipeCookingStep``
- ``RecipeUnit``
- ``RecipeHouseholdMeasure``
- ``RecipeWebImport``
- ``RecipeSourceURLMatcher``
- ``RecipeScaling``
- ``RecipeSubstitution``
- ``IngredientSubstitutionSuggestion``
- ``ManualRecipeIngredientInput``
- ``SharedRecipePayload``
- ``SharedRecipeIngredient``
- ``SharedRecipeComponent``
- ``SharedRecipeComponentContent``
- ``SharedRecipeComponentSlice``
- ``RecipeComponentWire``
- ``RecipeComponentImport``
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
- ``CompanionEmotion``
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
- ``BanEvidence``
- ``ModerationBanRecovery``

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
above); this section holds the module-level helpers that have no other home.
``MacroGramEntry`` is the typed-grams rule for macro fields: it parses through
``LocaleTolerantNumber`` (either separator), stores tenths of a gram, and displays in the locale's
separator with no grouping, so every prefill parses back to the value it came from.
``RecipeQuantityDisplay`` writes the quantity or serving size beside those grams in the same
separator (up to two decimal places), so an es/fr/de row never mixes "1.5" with "3,4".

- ``LocaleTolerantNumber``
- ``MacroGramEntry``
- ``RecipeQuantityDisplay``
