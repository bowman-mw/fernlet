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
`LocalPersistence`, the `Private*` stores, `AIProviders`, `CloudKitSync`, the modules over
ProximityKit (`FernletConnections`, `FernletSocial`, `FernletProximityUI`), `DiaryStore`, and
`FernletUI` all import it. ProximityKit itself does not: it is a package of its own (from its own
repository since ProximityKit plan step A1.3) that depends on nothing.

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
- ``ExerciseHowToCatalog/displayName(for:)`` — an exercise's ``ExerciseTarget/name`` is its identity,
  plan and log text, progression key, prompt vocabulary and coach-plan wire, so it never translates;
  screens draw it through this exact-match lookup (``ExerciseTarget/displayName``,
  ``PrescribedExercise/displayLine``), which also carries each exercise's localized how-to text.

Two more strings read exactly like UI copy and are not: ProximityKit's `PayloadSummary` `title`, `subtitle`,
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

Words that describe the user agree with the body profile's Sex answer (``BiologicalSex/termOfAddress``,
masculine when it was never answered), and ``AddressedCopy`` is where that happens: a translation
marks each such word `^[listo](inflect: true)`, and the helper resolves the key with inflection off
and inflects it for the term it is handed, never the system's Form of Address. It lives here
(since 2026-10-21; FernletUI keeps only the view half, `AddressedText` and the
`fernletTermOfAddress` environment value) because several of its callers are not views: the
planner's session notes are composed at plan time and stored on the logged row, so
``WorkoutLoadContext/address`` carries the user's term into the load pass ("welcome back" and the
max test's safety line agree with it), and the scoring lines and a notification's body are written
by modules with no SwiftUI. Display members here take the term from whoever draws them:
``FeelingTag/label(addressing:)`` (Quiet and Tired describe the person who logged them) and
``TrainingSplit/summary(addressing:)`` (Recovery Flow's says how the user should feel). A key built
in a package names its own bundle, `LocalizedStringResource("key", defaultValue: …, bundle: .module, …)`,
because a resource made here defaults to `Bundle.main`.

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

``MicronutrientGapAnalyzer`` rates a nutrient over a 7- or 14-day window only when that window holds
``MicronutrientGapAnalyzer/minimumDataDayFraction`` of its days with micronutrient data, and measures
intake against those days, never the nominal window (2026-10-16): an unlogged day is unknown, not
zero, and a first day of logging is no gap. The fraction is the owner's dial; at its value of `1.0`
the window must be full, so the gaps that feed the food score, the Home nudge and the AI prompt need
a full week (or fortnight) of data behind them. A tracked nutrient's ``NutrientReference/name`` is
frozen English, because the analyzer copies it into each ``NutrientGap/nutrientName`` and that rides
the persisted derived signals; screens draw ``NutrientReference/displayName`` and
``NutrientGap/displayedName``, which localize from the nutrient's key (2026-10-20).

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

A ``MealResolution`` carries the recipes the resolver built as offers (``MealResolution/suggestedRecipe``,
``MealResolution/offeredRecipes``) and the ones the person kept in the pre-log review as
``MealResolution/createdRecipes``, the only field a commit mints (2026-10-16), so a quick log that
commits without a review adds no recipe.

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
"N servings" is N of the food's declared serving, except where that serving is itself counted in
servings (2026-10-01): a custom editor row (``CustomIngredientUpsert``) and every imported
`fernlet.recipe` line mint a food holding the line's amount as its serving and the whole line's grams
as its macros, so "2 servings" of a food declaring "2 servings" is that food once. Every catalog row
served in servings declares exactly 1, so catalog servings are unchanged.

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
the search rows and, since 2026-10-18 (tracker §2.6), ``Meal/attributionLines(sourceOfFood:)`` does
for a meal logged from such a food (the meal rows, the day detail and the data export); and search
ranks it manual > openFoodFacts > usda > aiResolved, each source on a
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

A typed query that names a brand ranks that brand's rows first (2026-10-29, the targeted brand
fixes). The top key of the comparator is ``FoodBrandAgreement``, above history, so a bar the person
once logged cannot outrank the brand they typed.

What counts as a brand:
- **A restaurant chain from ``FoodBrandLexicon``.** It agrees with a row whose name or brand field
  says it.
- **A leading or trailing run of the query's words.** It agrees with a row whose BRAND FIELD states
  the run as whole words. The run is only a brand when at least two matched rows, and a fifth of
  them, carry it there, so a generic word that happens to sit in a few brand names ("olive") is not
  one.

The key is set only when a caller passes `brandAware` (``FoodItemSearch/results(for:in:limit:stripsStopwords:history:now:ranking:brandAware:)``,
the typed surface). Everywhere else it stays false and the order is unchanged.

``FoodSearchVocabulary`` turns the catalog index's words (``FoodSearchTerm``) into an OFFERED
spelling suggestion ("chobanni" → "chobani", "chickfila" → "chick fil a"), never a silent rewrite.

- ``FoodItemSearch``
- ``FoodBrandAgreement``
- ``FoodSearchVocabulary``
- ``FoodSearchTerm``
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

The recipe editor's unit menu is built per food (2026-09-30, F4b, the owner's call that the picker may
list USDA's named portions and a badged, editable typical-size table): ``RecipePortionPicker`` lists
the food's own USDA household portions first, each as what ONE is with its grams ("1 medium (118 g)",
"1 cup, sliced (150 g)" — ``FoodPortionReader/householdLabel(of:)``), then the person's own sizes,
then ``TypicalPortionTable``'s USDA typical sizes where the food's data states none of that kind
(a count where it has no count, a cup where it has no volume — "fruit (136 g)" for a Hass avocado,
every weight read from a cited SR Legacy row), then only the units that convert. A unit whose one IS a
listed portion ("each" of a banana is its medium) is folded into it, and the editor holds that choice
as the unit, so the line saves exactly as F4a saves "1 each". Any other named choice is held in
``ManualRecipeIngredientInput/portion`` and saved by ``ManualRecipeIngredientInput/recipeLine(for:)``
as its grams beside a ``RecipeHouseholdMeasure`` — the same encoding, no new token, the wire
unchanged — and re-opens as that choice (``RecipePortionPicker/reopened(_:foodItem:choices:)``). So a
banana's disagreeing cups are a choice between sliced and mashed, not a refusal. The converter never
reads the typical table: quick log, the meal composer and the resolver weigh amounts exactly as before;
only the recipe editor and the web importer's fallback read it. A caption's count agrees with its noun
where the label ends in one (``RecipeHouseholdMeasure/headTakesPlural``: "2 eggs", "2 cups, sliced",
but "2 medium").

F4b fix round 1 tightened four invariants. A row IS a typical-size entry's ingredient only where
USDA files it with that ingredient — a USDA row must sit in one of the entry's
``TypicalPortionEntry/categories`` (fail-closed: a chocolate egg, a sesame or hazelnut butter, an oat
milk, a pasta sauce, a canned potato get no estimate; a person's own food carries no USDA category and
is read by its words alone). A pick of a mass unit keeps the weight of a count, volume or serving —
the banana's "1 each" shown as "1 medium (118 g)" becomes 118 g, exactly as a named portion does
(``RecipePortionPicker/quantity(afterChoosing:standingIn:from:unit:portion:heldGramsPerOne:)``), while
a number typed in one mass unit still follows it to the next. Every path that stops reading a named
portion folds it into grams first (``ManualRecipeIngredientInput/droppingPortion()``), so a portion's
count is never read as grams. And where nothing on the menu counts, the editor asks "How many grams is
one?" (report §6.3 Rung E, ``RecipePortionPicker/Choices/asksGramsForOne``), saving the answer as the
person's own size under the frozen label ``RecipePortionPicker/gramsForOneLabel``. A saved line's
estimate status is worked out again where it is shown (``RecipeIngredient/isTypicalSizeEstimate(using:)``),
so the recipe page and cooking mode keep the editor's "USDA typical size, estimate" with no wire change.

A recipe pick teaches search (2026-09-30, F9b, the owner's call): when a person types an ingredient
out and chooses a food from below the top of the editor's list, the row carries the normalized words
in ``ManualRecipeIngredientInput/pickedForSearch`` until the recipe is saved, and the app's save
remembers them, so the next recipe search for the same words puts that food first. The field is
in-memory form state only — never on a ``RecipeIngredient``, the synced blob or the wire.

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
- ``RecipePortionPicker``
- ``RecipePortionOption``
- ``TypicalPortionTable``
- ``TypicalPortionEntry``
- ``TypicalPortion``
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
- ``MovementPlane``
- ``ExerciseModality``
- ``ExerciseDifficulty``
- ``ExerciseMeasure``
- ``WorkoutExerciseCatalog``
- ``ExerciseHowTo``
- ``ExerciseHowToCatalog``
- ``WorkoutSuggestion``

### Workout programming

``WorkoutProgram`` fills each ``WorkoutSlotSpec`` with the best *eligible* catalog exercise. Eligibility
is a requirement, not a score: rep-measured strength work (``ExerciseModality``, ``ExerciseMeasure``)
that shares the slot's movement pattern, its ``MovementPlane`` when both name one, and at least one
primary muscle — otherwise the slot is dropped and the session note names it. Among eligible
exercises the score adds target fit, a tool preference by slot role and ``ExperienceLevel`` (barbell
first for trained lifters' main lifts, dumbbells and machines for beginners, bands and bodyweight as
fallbacks), and an ``ExerciseDifficulty`` fit; only then does the name break a tie. A row marked
``ExerciseTarget/variation`` (an easier or harder step, or a staple's work with another tool — 37 of
the 59 rows the Gym Visual expansion added on 2026-10-21, and all 22 of the owner's additions on
2026-10-27) competes only where no staple is eligible, or as the supported variant for a mild injury, so
adding variations fills gaps without moving the plans people already follow. The picker's
`WorkoutExerciseCatalog.search` also matches `searchAliases`, the names people call a bundled exercise
by ("ab roller" for the Ab wheel); an alias only adds results after the direct matches, so a lookup
that takes the first result resolves as before.
``WorkoutSafetyFilter`` gates equipment on the exercise's tool or any alternative plus every piece of
required gear (a pull-up bar, a bench). The split advances by the last logged split day
(`WorkoutProgram.nextDayIndex(in:recentSessionNames:)`), not by weekday.

A lifting session runs in ``SessionBlock`` order — the owner's layout (2026-10-19): the warm-up
stretch flow (``WorkoutSessionBlocks/warmUpFlow``, 20–30 s holds), activation (the template's core
slot, prescribed light, plus a single-leg balance hold and, for a trained lifter's leg day, 2 × 4
squat jumps), the lifting, any cardio after it, and a cool-down of 45 s holds chosen to cover the
muscles the lifting worked. Every step is a catalog row through the same safety filter. A timed
movement carries `PrescribedExercise.holdSeconds` (its `reps` is the same duration as text, "40 s");
a one-sided step carries `side`. Only the lifting block progresses
(`SessionSuggestion.catalogExerciseNames`), an AI adjustment replaces only the lifting block, and
the plan text a log records summarizes the warm-up and cool-down in one line each
(``WorkoutSessionBlocks/planText(for:)``).

Injuries reach the filter as one ``InjuryLimits`` (`WorkoutProfile.injuryLimits`), combined from
three inputs: the body-area picker (`WorkoutProfile.injuryAreas`, each ``BodyArea`` at an
``InjurySeverity``; frozen tokens with parked decoding, carried at the top level of the settings
blob as `workoutInjuryAreas` so an older build's key parking keeps it through a re-save), the
free-text note read by whole words
(``InjuryNoteMatcher`` — "getting back into lifting" names no back), and the avoided sets older
builds wrote. The picker wins for an area it names; the rest is severe. Severe leaves the area's work
out (its muscles, its movement patterns, and for the spine a loaded bar); mild leaves out only the
heavy end (barbell, advanced, jumps), scores machine, cable and bench-supported variants higher, and
prescribes the area's main lift as accessory work. A Smith machine row is a machine row — the supported
end, by the owner's call of 2026-10-21 — but its bar still sits on the spine, so a spine area counts a
Smith squat as loading it, as it counts a back squat.

The 48-hour guard (``WorkoutRecoveryGuard``) reads yesterday's hard sets
(``WorkoutRecoveryGuard/RecentTraining``, gathered app-side): when today's split day would train
those primary muscles hard again it moves to the next split day that spares them — unless the
overlap is the split's own order, which moving would only push back every pass — and otherwise takes
a set off each overlapping lift, saying why in the note. Recovery and mobility days, and the warm-up,
activation and cool-down, are exempt.

A session's length follows ``WorkoutSessionOptions`` (synced settings with frozen tokens and parked
decoding): ``WorkoutWarmUpMode`` walks the owner's flow in full (exactly as written), short (about four
minutes of it, a subset in its order chosen for the day's worked areas,
``WorkoutSessionBlocks/shortWarmUpSeconds``) or not at all; ``WorkoutCoolDownMode`` keeps or drops the
cool-down; and ``WorkoutSessionLength`` sets a 20, 30, 45 or 60-minute budget. ``WorkoutSessionTime``
times a session by the guided runner's own rule — the plan card's estimate and the run's countdown start
equal, and both count about a minute of changeover before each exercise after the first
(``WorkoutSessionTime/changeoverSeconds``; the warm-up and cool-down flows take none) — and
``WorkoutSessionBudget`` fits each session into the budget in the owner's order: the short
warm-up, cool-down stretches down to two, accessory work (the jumps, the accessory lifts from the last,
the balance drill), accessory sets, the warm-up ramp cut to its one set nearest 60 % (never to none), then
main-lift sets down to two. Main lifts are never dropped and
nothing grows, so the injury limits and the guard's lighter sets hold; when even the shortest version is
over, the note says how long it runs. A cardio session's descriptor minutes are capped instead.

Exercise preferences (``WorkoutExercisePreferences``, synced at the top level of the settings blob as
`workoutHiddenExercises` and `workoutExerciseAlternates`, frozen names decoded tolerantly and bounded)
reach every block: an exercise the user hid ("Don't suggest this") leaves the feasible pool, so each
slot falls back to its next eligible pick, a slot only hidden exercises could fill is dropped with its
own note, and the AI adjuster never sees it. A saved alternate ("Always use this instead", one hop)
replaces the planner's pick only when it is in the feasible pool (equipment, injury limits, not hidden),
unused, eligible for the slot, and — under a time budget — no longer than the pick; otherwise the pick
stands silently. ``WorkoutExerciseSwapOptions`` ranks the plan editor's stand-ins. A hand-made custom
exercise (``CustomExerciseDraft``) carries every curation field a catalog row does, so the safety filter
and eligibility judge it the same way; ``CustomExerciseLibrary`` checks the name (not empty, no clash
with a bundled or another custom name) and the shared 500-exercise cap, and deleting one never touches
a logged workout.

Cardio and mobility lines stay text in the plan — the text is the source of truth, and a session-length
budget caps it — and become timed steps only when a guided run starts
(``WorkoutTimedSessions/expand(_:feasible:)``, roadmap step 4a, 2026-10-20). ``WorkoutTimedSessions``
reads a line strictly (``TimedDescriptor``): "Easy cardio - 20 min" is one steady countdown, "Intervals -
8 × 1 min hard / 1 min easy" is sixteen ``CardioSegment``s of a ``CardioPace`` each, every part after
the first following straight on with no lead-in; "Mobility flow - 15 min" is a stretch session in the
owner's warm-up order with 30–45 s holds (the ``SessionBlock/mobility`` block), and the rest day's
gentle stretching a short floor stretch that is never the day's session. A line it cannot read with
certainty (drills, a mixed "mobility + walk", "3 rounds") stays the untimed step it was. A finished
run's log folds segments back into their line, and a cardio or mobility session logs as the matching
``WorkoutActivityType`` (HIIT, walking, mixed cardio, flexibility). Where the location has a cardio
machine the person may use, ``WorkoutCardioMachines`` (2026-10-21) has the plan's generic cardio line name
it by its frozen catalog name — "Rowing machine - 20 min easy", rotating among the location's machines by
the split's rotation index — so the runner's step is that exercise (its how-to sheet and its name in the
user's language come with it) and the session logs as rowing, indoor cycling, elliptical, stair climbing or
walking; with no machine the generic line stays. The Log sheet logs the same machines in minutes
(``ExerciseInputKind/timed``). A guided sport session logs the sport
named in Workout setup when Fernlet models it (``WorkoutSportActivity``: pickleball, tennis, volleyball,
golf, hockey, boxing, skiing…, with bare "football" American football in the US and Canada and soccer
elsewhere), else the generic type — as it does for a distance sport, whose gym session is not a run. Each segment's pace aims for a heart-rate zone (roadmap step 4b): ``HeartRateZones`` builds five zones from the person's own maximum heart rate when they gave one (120–220 bpm), else from age by Tanaka (208 − 0.7 × age), and, when a trusted resting heart rate is given, by Karvonen's heart-rate reserve (percent of maximum otherwise), and maps easy and steady to zone 2 and hard to zone 4. Pure; the live reading is the app's.

A ``PlannedWorkout`` — planned ahead by the person or put on the calendar by a coach's plan — runs in the
guided runner as written (comparison report idea 17, 2026-10-20). The app reads each line with its own
line parser and ``WorkoutPlanRun/step(for:parsed:location:load:catalog:)`` decides the step: a line the
runner can time stays a descriptor for the expansion above (checked first, since "8 × 1 min" also reads
as eight sets of one), sets × reps and timed holds become counted steps under the catalog's name, and
anything else one step marked done that shows the line. Nothing is filtered or dropped. A weight the line
names is preselected as written (``WorkoutPlanRun/Step/weightAsWritten``); only a catalog lift whose line
names none gets the load engine's suggestion, for the sets and reps as written.

The planner's words are localized without touching what it stores (2026-10-20, idea 16). Every session-note sentence is a String Catalog key in ``WorkoutPlannerCopy``, composed in the device's language when the plan is built. The names the planner stores and matches stay frozen English — a session's name is what its guided log is saved under and what the rotation matches, a split's and a location's name are what the trainer export carries, the plan text is what the history parser reads — and screens draw them through ``WorkoutSessionNames``, ``WorkoutSplitDayNames``, `TrainingSplit.displayName`, ``WorkoutSlotNames``, ``WorkoutLocationNames`` (`WorkoutLocation.displayedName`, which a rename field saves back through `savedName(editing:)`) and ``WorkoutPlanLine``. FernletScoring's AI-free fallback workouts are saved under a frozen ``WorkoutFallbackName`` ("Suggested Light", "Mood Reset"), which `Workout.displayedName` draws localized (2026-10-20, Spanish round step 2).

- ``WorkoutPlannerCopy``
- ``WorkoutFallbackName``
- ``WorkoutSessionNames``
- ``WorkoutSplitDayNames``
- ``WorkoutSlotNames``
- ``WorkoutLocationNames``
- ``WorkoutPlanLine``
- ``WorkoutExercisePreferences``
- ``WorkoutExerciseSwapOptions``
- ``CustomExerciseDraft``
- ``CustomExerciseIssue``
- ``CustomExerciseLibrary``
- ``WorkoutProfile``
- ``BodyArea``
- ``InjurySeverity``
- ``InjuryLimits``
- ``InjuryNoteMatcher``
- ``WorkoutRecoveryGuard``
- ``WorkoutSessionOptions``
- ``WorkoutSessionLength``
- ``WorkoutWarmUpMode``
- ``WorkoutCoolDownMode``
- ``WorkoutSessionTime``
- ``WorkoutSessionBudget``
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
- ``SessionBlock``
- ``ExerciseSide``
- ``WorkoutSessionBlocks``
- ``WorkoutTimedSessions``
- ``WorkoutCardioMachines``
- ``WorkoutSportActivity``
- ``TimedDescriptor``
- ``CardioSegment``
- ``CardioPace``
- ``HeartRateZones``
- ``WorkoutPlanRun``
- ``WorkoutRestGuidance``

### Load-aware progression and plateaus

The owner's spec of 2026-10-19, with round 2's trend and ladder (2026-10-20). Given a
``WorkoutLoadContext`` (each lift's logged sessions as ``LiftExposure``s with their sleep and
readiness flags, recent protein and logged weigh-ins, the calibration state), `WorkoutProgram.dayPlan` runs
its lifting picks through a load pass. Everything is derived from the history each time — no stored
estimate — so the same history always builds the same plan.

- **Estimate and range.** ``WorkoutLoadEngine`` estimates a one-rep max by Epley with the reps left in
  the tank added back (sets of 12 or fewer, three sessions in eight weeks weighted 3:2:1) and sets a
  ``WeightPrescription`` whose width follows ``EstimateConfidence``: ±10 % low, ±5 % medium, one step
  at high, on the equipment's steps.
- **Next session.** Completed → one more rep, or at the top of the range a fixed step heavier and back
  to the bottom ("add weight now"; G4: one equipment step on an upper-body lift, one or two on a
  lower-body one, landing on the location's own weights) — as often as the lift's training age allows
  (G3, ``TrainingTier``: after every successful session in the first six months, after two in a row
  from six months to two years (`LoadChange.confirming`), once per four-week block past that
  (`LoadChange.blockHold`)). The training age is Workout setup's "How long have you lifted
  regularly?" — the existing ``ExperienceLevel``, nothing new stored — raised per lift by how long that
  lift has been logged (``WorkoutLoadContext/trainingAge(for:)``); "under 6 months" keeps the trend's
  age inferred. Tough or a miss → repeat; a second miss in a row on days with no sleep or
  readiness flag → lighter; a third → lighter and a set fewer. A flagged miss (``WorkoutSessionFlag``)
  always holds the load and never counts toward a cut (G10, 2026-10-20; `LoadChange.heldAfterFlag`,
  its note said as what happened alongside it). A travel day is the flag's third reason
  (World-Airports-Spec §13.4, 2026-10-31: `WorkoutSessionFlag.travelDay`, the light day's trims): the
  app passes only a per-day yes/no, never a flight, an airport, a time or a place. Two overrides the same way,
  or a "too heavy / too light" answer, re-center the estimate on the lifter's picks; a third override
  in five sessions asks why once (``OverrideReason``).
- **The trend (G1, 2026-10-20).** ``WorkoutTrend`` fits a robust weighted line through each lift's
  session scores in log units (``WorkoutTrend/sessionScore(of:in:)``: the top one or two sets with
  reps plus reps in reserve at 10 or fewer, 12 at most, averaged; a true single at its weight) and
  judges its slope against the person's expected linear-log curve, b about 10 % from an untrained
  start and 2.5 % from a trained one (``TrainingTier``, ``TrainingAge``, ``LifterTraits``; zero for a
  long-trained lifter over 60, so a steady line there is success). The noise starts at the tier's
  prior and becomes the person's own scatter after ten clean sessions. ``TrendState``: progressing,
  slowing (a soft note), stalled (the upper 80 % bound of the slope under 1 % per four weeks and
  clearly under the expected curve, on three readings in a row), dipping (two clean sessions more
  than two typical errors under the line) or too early. A session after a short night, on a light
  day or on a travel day (``WorkoutSessionFlags``: 6 h or less, or 90 minutes under the 14-night median) counts at half
  weight when it falls short and never toward a stall. The trend restarts when the rep scheme moves
  or after four weeks away. A seeded Monte Carlo (`WorkoutPlateauSimulationTests`) holds false
  plateaus to 5 % or fewer of histories over 12 weeks, against nearly all of them for the rule it
  replaced.
- **Plateau (G5).** ``WorkoutPlateau`` reads the trend into a ``PlateauStatus`` — not when overrides
  explain it or the lift is on a break — and a stall walks ``PlateauStage`` in order: a fair retest
  (the lift first, at least three minutes' rest), a loading change (a short heavier block, or a set
  more), a variant beside the lift (which stays, a set lighter), then holding steady with calm,
  goal-appropriate options. A dip gets a deload instead: half the sets at the kept load, once. The old
  helper-muscle support step is gone; the old ladder's tokens resolve to the nearest new step
  (``PlateauStage/resolve(token:parkedToken:)``). The session note gives at most two context lines and
  always a plain training option.
- **What each goal hears (G7, 2026-10-20).** ``PlateauTracking``: wellness, mental health, recovery
  and exploring get no plateau notes and no monthly strength test — they track minutes and sessions;
  weight management hears only a quiet "strength held" check
  (``WorkoutPlateau/strengthHeldStatus(of:unit:today:profile:)``, ``WorkoutTrend/hasEased(_:profile:)``:
  weeks of a line falling beyond noise, said as something a calorie deficit can bring, never a push to
  eat more); strength and sports prep follow their main lifts' full trend and keep the test.
- **Food, as context only (G11–G13, 2026-10-20).** Workout setup's "Use food logs in workout notes"
  (``WorkoutLoadContext/foodAware``, the synced `FernletSettings.workoutFoodAware`, on until switched
  off) lets the trend story mention food once the logs can be read; food never cuts a weight or speeds
  progress, and missing logs say nothing. Protein (``RecoverySummary``) is read against a fixed floor
  of about 1.2 g per kg a day, allowing for self-logged intake running about a fifth low, only with
  meals on five or more days in each of the last two weeks, beside a stall, a dip or a slowing, never
  to weight management, with a doctor caveat for older lifters and kidney concerns. Logged weigh-ins
  (``WorkoutBodyWeightTrend``: at least 0.5 % a week down over two to four weeks, 1.645 standard
  errors clear of flat, on three weigh-ins in a row — 3 % of steady weights called falling over eight
  weeks in its simulation) explain a Size lifter's stall, and beside weight management's strength-held
  check bring a gentle check-in. Before a long, high-volume session the runner may ask one optional
  "Eaten in the last few hours?" (``WorkoutFuelCheck``); a "no" holds a shortfall in the later sets
  rather than counting it (`LoadChange.heldUnfueled`, ``ExerciseResult/unfueled``) and the trend
  scores the top set alone.
- **Training focus (G6).** ``WorkoutStrengthFocus``, a synced Workout setup choice: Strength (main
  lifts 3–5 reps), Size (6–10 main, 10–15 the rest, a set more past six months on a lift and two past
  two years) or Both — the default, the goal's own mix. A Size focus never follows the blocks.
- **Age-adjusted copy (G9).** For a lifter of 60 or more the slowing and holding-steady notes say
  that holding strength is progress, and a long-trained lifter past 60 expects a steady line.
- **Blocks (G2, 2026-10-20).** A trained Strength lifter's main lifts follow ``WorkoutBlocks``: four
  weeks of volume (``BlockPhase/volume``, 4 × 6) then four heavier (``BlockPhase/heavier``, 5 × 3),
  counted from one fixed Monday so every device agrees (``BlockWeek``). The engine rebaselines each
  lift from its estimate at a switch, the session note names the block and its week, and the plateau
  trend reads both phases as one line — the backup to the plan.
- **Calibration.** ``WorkoutCalibration`` turns the main lift into a submaximal test about every four
  weeks for people without a coach plan, a one-set strength check when the estimate is already
  trusted, or — opt-in, trained lifters only (`WorkoutProfile.oneRepMaxTesting`) — a true max. On a
  day whose time budget can't hold it (under 30 minutes, or the block with the check's rests over the
  budget), the check waits for a roomier day and the note says so (N3).
- **At the heaviest weight (N7).** While a lift sits at the heaviest load its location has, the plan
  offers a harder variation — the same work one difficulty step up, a squat may step to a split
  squat (``LoadGuidance/harderVariation``) — as the plan editor's first swap; more reps, then a set,
  stays the plan. The guided runner's lighter and heavier buttons step through the loads the location
  owns (``LoadGuidance/loads``, ``LoadLadder/window(around:count:)``; R6).
- **Weights on hand (2026-10-20).** A location can list the dumbbell pairs, kettlebells, bar and
  plate pairs it has (``WorkoutWeightInventory``, presets in ``WorkoutWeightPresets``); every weight
  the load pass prescribes there — the range, the easier session, the calibration's sets — is then a
  load it can make (``LoadLadder``). The light-load guard holds with or without them: when the next
  load is more than `WorkoutLoadEngine.lightLoadGuardRatio` (10 %) heavier, or there is none, the
  lift adds reps up to three past the range, then a set, then takes the jump (``LoadCap``,
  ``LoadChange/repsFirst``, ``LoadChange/setFirst``). The weights sync at the settings blob's top
  level (`workoutLocationWeights`), where an older build's key parking keeps them; ``WorkoutLocation``
  itself now parks a newer build's equipment tokens and keys.
- **Warm-up sets.** ``WorkoutWarmUpSets`` puts two or three lighter sets in front of the session's
  FIRST heavy main lift — a compound main lift on a barbell or dumbbells — when it has a suggested
  weight; when that lift can't ramp, no later lift does. A barbell ramp is the empty bar × 8, then
  about 60 % × 5 and 80 % × 3; a dumbbell ramp is about 40 % × 8, 60 % × 5 and 80 % × 3 on the
  dumbbells the location owns (its ``LoadLadder``), else 5 lb or 2 kg steps. It runs when
  ``WorkoutLoadContext/warmUpSets`` is on (the synced `FernletSettings.workoutWarmUpSets`, defaulting
  on for intermediate and advanced lifters) and the day is not light. Each is a single-set step tagged
  `.ramp` like the calibration's, so the log writes "(ramp-up)" and no estimate, plateau check or
  weekly count reads it; `LoadGuidance.warmUp` tells it apart for a time budget to cut to one set.
  Barbell warm-ups land on loads the plates make: ``PlateCalculator`` over a ``BarbellPlateSet`` (the
  standard 45 lb / 20 kg bar and plates, or the location's own bar and plates) says which plates go on
  each side, or the closest load it can make.
- **After "Adjust with AI".** The on-device adjuster answers with names, sets and reps only, so
  ``WorkoutAdjustedLoad`` loads the adjusted lifting block again: a lift kept at the same reps keeps its
  guidance, any other catalog lift is prescribed from its history on the location's weights, the
  compound count ahead of each lift is redone, and the warm-up ramp goes back before the first heavy main
  lift when the setting is on and the committed day isn't light. The time budget is not applied again.

The guided runner prescribes from ``LoadGuidance`` and records an ``ExerciseResult`` per lift on
``Workout``'s additive `exerciseResults` (nil means "completed as prescribed" was never recorded; the
same facts are in the logged text, `ExerciseResult.loggedLine`).

The same record is written after the fact (idea 6): a correction re-records a lift's sets
(`ExerciseResult.record(_:unit:)`), and a lift entered set by set in the Log sheet is recorded the
way a run records it (`ExerciseResult.handLogged(name:sets:unit:equipment:effort:)`), each set a
``LoggedSet``. When the sets were not all lifted at one weight the result keeps `setWeights` and its
line spells them out ("(did 8 @ 100, 8 @ 100, 6 @ 95)"); the engine judges such a session at its
heaviest set's weight, and a lighter set keeps it from counting as completed
(`LiftExposure.workingSetReps`). `Workout.replaceExerciseLine(_:with:)` keeps the line in step
with the record. A result parks the keys a newer build adds and writes them back, so a re-save here
never drops them; an older build that drops `setWeights` still has them in the line.

- ``WorkoutLoadContext``
- ``WorkoutLoadEngine``
- ``LiftExposure``
- ``LiftPlan``
- ``LoadChange``
- ``LoadEstimate``
- ``RepScheme``
- ``WeightPrescription``
- ``LoadGuidance``
- ``ExerciseResult``
- ``LoggedSet``
- ``LoadUnit``
- ``ExerciseEffort``
- ``OverrideReason``
- ``OverrideDirection``
- ``EstimateConfidence``
- ``WorkoutTrend``
- ``TrendState``
- ``TrendReading``
- ``TrendPoint``
- ``TrendProfile``
- ``TrainingTier``
- ``TrainingAge``
- ``LifterTraits``
- ``WorkoutSessionFlag``
- ``SleepFlag``
- ``WorkoutSessionFlags``
- ``WorkoutPlateau``
- ``PlateauStatus``
- ``PlateauStage``
- ``RecoverySummary``
- ``WorkoutCalibration``
- ``CalibrationSettings``
- ``CalibrationKind``
- ``CalibrationSet``
- ``CalibrationStep``
- ``WorkoutWeightInventory``
- ``WorkoutWeightPresets``
- ``LoadLadder``
- ``LoadCap``
- ``WorkoutWarmUpSets``
- ``WarmUpSet``
- ``WorkoutAdjustedLoad``
- ``PlateCalculator``
- ``WorkoutBlocks``
- ``BlockPhase``
- ``BlockWeek``
- ``WorkoutStrengthFocus``
- ``PlateauTracking``
- ``WorkoutFuelCheck``
- ``WorkoutBodyWeightTrend``
- ``BodyWeightSample``
- ``BarbellPlateSet``
- ``PlateLoadout``

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

Localization (2026-10-20, Spanish round step 2). Every sentence the decode and validation can show
— `CoachPlanDecodeError.message` and `CoachPlanIssue.detail` — is a whole-sentence key in the
internal `CoachPlanIssueCopy`; `CoachPlanIssue.subject` is never drawn and stays English, and the
vocabularies after "Expected one of:" are wire tokens. The importer's provenance lines are stored
text: ``CoachPlanNoteStamp`` writes them in frozen English, matches them back by their exact shape
(a bare "Day " prefix used to drop the user's own "Day off, knees sore"), and draws them localized
through `PlannedWorkout.displayedNotes` and `Workout.displayedNotes`.

- ``CoachPlan``
- ``CoachPlanNoteStamp``
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

The companion is called Sprout. ``CompanionName`` is where that name comes from: the person's own choice, or
``CompanionName/standard`` ("Sprout", never translated) when they have none, read as
``FernletSettings/companionDisplayName``. "Fernlet" is the app's name and never the companion's.

- ``CompanionName``
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

Fernlet's proximity vocabulary and records. ``PayloadType`` and ``ProximityCapability`` are the
tokens FernletConnections reads into `ProximityNamespace.fernlet`'s vocabulary, which is where
ProximityKit's core takes every token from; ``ProximityMode`` is the session mode Fernlet persists on
its trust records and session logs, converted case for case by FernletConnections from the
coordinator's own `ProximitySessionMode`, whose frozen raw values it shares; ``ProximityTrustedPeerRecord`` and ``TrainerAuditEvent`` are the trust records and
audit rows Fernlet's `ProximityTrustVault` (FernletConnections) keeps and the snapshot persists: a
coordinator's audits arrive converted from ProximityKit's own `ProximitySessionAudit` by
FernletConnections' one conversion, while the vault builds its block, revoke and report rows itself
and the app builds the row for a pasted coach plan (`CoachPlanImporter`); and ``ConnectionSessionLog`` is
the session log the app's inspector builds from ProximityKit's own inspector values. ProximityKit
names none of these types and does not depend on this module, and `ProximityNamespaceBoundaryTests`
holds it there: ``PayloadType``, ``ProximityCapability``, ``ProximityMode``,
``ProximityTrustedPeerRecord``, ``ItemNameModeration``, `TrainerAuditEvent` and
`ConnectionSessionLog` are named nowhere in its code (Fernlet's typed view of the signed envelope's
token, which reads ``PayloadType``, is FernletConnections'). Fernlet's own modules name them freely: `FernletSocial`'s
presence, heart dead-drop and session hearts read ``ProximityTrustedPeerRecord``, its mesh features
register and send their payloads under ``PayloadType`` tokens and advertise and check
``ProximityCapability`` tokens, the dead-drop titles its envelope with a ``PayloadType`` token,
presence advertises the hearts ``ProximityCapability`` and the activity manager caps its names
under ``ItemNameModeration``; and `FernletConnections` reads the tokens into the vocabulary and
keeps the records. The generic types
an envelope carries (`PayloadEncryption`, `PayloadSummary` and its `DateRange`) and the session's
role and ranging mode are ProximityKit's own.

- ``PayloadType``
- ``ProximityCapability``
- ``ProximityMode``
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

### Languages (localization Phase 3)

``FernletLanguage`` names the languages the language-sensitive engines know by their frozen ISO
codes, and ``FernletLanguage/app`` is the one the app's interface resolved — app-supported by
construction, since a bundle resolves only a language it ships. The on-device model's prompts read
it (AIContext's `AIPromptLanguage`).

A ``LanguagePack`` is one language's MATCHING vocabulary — unit words, meal connectors, protected
dish names, plural rules — every key folded (``LanguagePack/folded(_:)``) and every value a frozen
English token, so a pack changes what Fernlet reads, never what it stores or shows ("2 tazas" stores
`cup`). The food engines read the packs of ``InputLanguages/current`` (English plus the app's
language): ``RecipeUnit/normalized(_:languages:)`` over ``RecipeUnit/englishSpellings`` (the one unit
table; the recipe line reader builds its unit words from ``RecipeUnit/spellings(languages:)``),
``MealItemSplitter``, and ``FoodItemSearch/matchVariants(for:)``. The two keyword screens read every
pack at once, whatever the interface language (``LanguagePack/all``): ``DiagnosticLanguage`` adds each
pack's clinical stems and whole words (and folds accents), and ``ItemNameModeration`` each pack's
blocked stems and whole words — the privacy policy's clinical-language claim holds in Spanish too. A
new language is a
`LanguagePack+<Language>.swift` and one line in ``LanguagePack/pack(for:)``; `LanguagePackTests`
checks every pack is filled and folded.

- ``FernletLanguage``
- ``InputLanguages``
- ``LanguagePack``
- ``PluralRule``

### Addressing the user

``AddressedCopy`` resolves catalog copy whose translation marks the words that describe the user,
inflected for ``BiologicalSex/termOfAddress`` of the effective profile. `LocalizationBoundaryTests`
part I fails any marked key read by `String(localized:)`, which keeps the markup verbatim, and part
I2 pins every user-gendered key to an addressed reader: the key's literal must sit inside
``AddressedCopy/string(_:addressing:)`` / ``AddressedCopy/attributed(_:addressing:)`` (or FernletUI's
`AddressedText`), never `String(localized:)`, `Text(LocalizedStringKey)` or ``AddressedCopy/plain(_:)``;
every literal `.masculine` in shipping code is pinned with its reason; and a
`LocalizedStringResource` built in a package must name `bundle: .module`.

- ``AddressedCopy``
