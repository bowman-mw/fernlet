# ``FoodCatalog``

USDA food search, barcode and ingredient resolution, and the curated micronutrient-nudge table — the bundled nutrition knowledge base every food flow in Fernlet queries.

## Overview

FoodCatalog is the layer-1 FernletKit module that owns the app's bundled food data. Its
center is the ``FoodCatalog`` class: the single lookup surface that replaced the old
in-memory `allFoodItems` array. The ~13k bundled USDA/curated foods live in a read-only
SQLite file (`Resources/FoodCatalog.sqlite`, loaded via `Bundle.module`, never
`Bundle.main`) and are queried on demand through the ``BundledFoodSource`` abstraction;
the user's own foods are held as a small locked snapshot that the app keeps in sync from
`FernletStore.foodItems`. Search fans out to an FTS5 prefix-AND candidate fetch
(``SQLiteBundledFoodSource``) and then runs `FoodItemSearch` — the scorer in
`FernletDomainModel` — over the candidates plus user items, so the SQLite path preserves
the legacy preparation / form / data-type ranking exactly. Point lookups (by id, by
normalized GTIN barcode, by recipe ingredient set) resolve straight from SQLite, and
``FoodCatalog/candidates(for:limit:ranking:)`` builds the capped candidate pool the deterministic
and AI meal resolvers draw from.

Search carries three pieces of per-user state. The first, added for research §26 fix 1.10, is the
**local correction memory**. `FoodCatalog.setSearchAliases(_:)` publishes a normalized query →
food-id map — the searches this person corrected once in "Adjust meal" — and
``FoodCatalog/results(for:limit:stripsStopwords:context:ranking:)`` puts that food first, ahead of the FTS
gate rather than through it, so a query the gate answers wrongly (or not at all) can be
taught. The map holds no nutrition data, is empty on any catalog the app has not hydrated
(which is what keeps the measured cold pipeline deterministic), and deliberately does NOT
reach ``FoodCatalog/scoredResults(for:limit:stripsStopwords:)``: that surface's score is a
bind-CONFIDENCE gate, and a correction must not promote a future quick-log past its review
sheet. The durable copy lives in the app target (`FoodSearchCorrectionMemory`, a
device-local `UserDefaults` sidecar that never enters the synced snapshot or CloudKit, though
it does ride an encrypted device backup, and is cleared by "Delete everything"), so this
module stores only the snapshot it is handed.

The second, added for research §26 fix 1.9, is the **history profile** —
``FoodSearchHistory``, published by `FoodCatalog.setSearchHistory(_:)`. It weights the foods
this person has actually logged by `log(1 + count)` and an exponential recency decay, and
`FoodItemSearch` reads it as the TOP key of its comparator, above source and data-type
priority: your own food first, then everything else in the order it already had. Three
properties make it safe to sit that high. It **re-ranks and never injects** — every row it
moves already passed the FTS gate and both of fix 1.8's floors, which is the structural
difference from the correction alias above, and it means a stale profile can only reorder
right answers, never surface a wrong one. It applies to a **TYPED query only**, expressed by
``FoodSearchContext/userTyped`` rather than inferred from stopword policy, so
``FoodCatalog/candidates(for:limit:ranking:)`` and recipe-import estimation explicitly use
``FoodSearchContext/machineGenerated`` and keep cold ranking. The profile retains count/latest-use
statistics and calculates decay once per query, so it cannot go stale while the diary is idle. And it
has **no durable copy anywhere**: `DiaryStore` derives it from `recentMeals` (already in the
synced snapshot) on every write and at init, so a wipe of the diary is a wipe of the feature.
When a query has both a correction and a history weight, the **correction wins** — an explicit
statement outranks an inference.

A third, added for ingredient-search round F9b, is the **recipe picks** (`FoodCatalog.setRecipeSearchPicks(_:)`):
normalized query → the food a person chose for it from below the top of a recipe ingredient list
(the recipe editor's typeahead or the swap sheet). A pick is promoted exactly like a correction, but
only for a search that asks for `.ingredientIdentity` — the recipe surfaces — where it goes first,
above the identity order, history and a curated alias. In the swap sheet's pool
(``FoodCatalog/candidates(for:limit:ranking:)`` with that order) the remembered answer is looked up for
the WHOLE description, not only per sub-phrase, and is exempt from the dish demotion — the sub-phrases
drop stop words, numbers and every word past three, so "2% milk" or "low sodium chicken broth" is never
one of them; the resolver's `.standard` pool keeps the per-sub-phrase promotion only. A correction for
the same query still answers first, and quick-log, the meal composer, Adjust meal, the resolver's pool and
`recentIngredientPersonalization()` never see a pick: the owner scoped learning from recipe picks to
recipes. The app keeps picks and corrections in the same device-local memory under one cap, so the
same wipe and "Forget corrected searches" clear both.

A second, much larger branded catalog (~364k products) is delivered as a purgeable
On-Demand Resource and attached at runtime as an additional ``BundledFoodSource``
(`FoodCatalog.attachBrandedSource(_:)` / `detachBrandedSource()`, driven by the app's
`BrandedCatalogResourceLoader`). Every read unions base + branded + user items with
source priority user > base > branded, and the whole feature degrades gracefully: a
missing or purged database simply narrows results back to the bundled floor.

The SQLite file itself is generated at build/test time, not authored: the repo-only
source JSON under `FoodDataSource/` is decoded by ``FoodDataCatalog`` (whose
`USDAFoodItemRecord` workhorse accepts both the compact bundled schema and raw USDA FDC
envelopes, including branded-label per-serving rescaling and deterministic
FDC-id-derived UUIDs) and written out by the app-target `FoodCatalogDatabaseBuilder`.
``FoodCatalogSchema`` is the single source of truth both sides share; the shipped file is
schema v1, and the read path feature-detects the v2 `gtin_upc` barcode column at open so
one code path serves both. The private `FDC*` structs in FoodDataCatalog.swift are the
raw-envelope decoding helpers, and the free functions ``sqliteBindText(_:_:_:)`` /
``sqliteColumnText(_:_:)`` are the C-interop glue shared by generator and reader.

**Load-time corrections.** A defect in the committed `FoodCatalog.sqlite` is fixed where the
row is read, not by regenerating the file (a regenerated catalog binary is never committed):
``SQLiteBundledFoodSource`` passes every hydrated row through the internal `BundledRowCorrection`,
a pure per-row function that can change what a retrieved row says but never which rows a query
retrieves (Docs/Ingredient-Search-Deep-Research-2026-09-29.md §8). Today it rebases the 59,227
compact-source branded rows (ids `00000000-0000-5000-…`), whose USDA per-100 g nutrients had been
read against the product's label serving, onto a 100 g (100 ml) serving with the macros unchanged,
keeping a gram label serving as a count portion ("1 serving (28 g)", unit `each`) so a bare count
still means one label serving. The attachable On-Demand-Resource catalog is on the label basis
already and carries none of those ids, so it passes through untouched. It also reads USDA's raw
serving-unit codes — `GRM`/`GM` as `g`, `MLT` as `ml` — in both catalogs, so those rows convert in
grams or milliliters instead of refusing every amount, and it types the 773 packaged products the
source filed as SR Legacy as `branded`, so they no longer sit in the generic tier: 763 by category (a
category outside SR Legacy's 25 food groups) and ten filed under one of those groups by FDC id
(Chex Mix, two fruit snacks and seven Ritz rows, all "Snacks"). FDC's own `food.csv` types exactly
those 773 `branded_food`; `Scripts/food-catalog/misfiled_branded_audit.py` re-checks both rules
against the manifest-pinned archive.

Three more hygiene fixes ride the same no-regeneration rule. The catalog build dropped every SR
Legacy food with zero protein, carbohydrate and fat, which is why "salt" found nothing: the 26 of
them with zero energy (salt, baking soda, waters, teas — the six distilled spirits stay out, since
`Macros` has no alcohol term) ship beside the file in `Resources/FoodCatalogSupplement.json`,
regenerated by rule from USDA's CC0 SR Legacy file by `Scripts/food-catalog/sr_zero_energy_supplement.py`.
``BundledFoodSupplement`` reads it and ``FoodCatalog/bundled(bundle:)`` serves it through
``SupplementedBundledFoodSource``, which searches and resolves those rows exactly like file rows and
counts them in `bundledCount`. And a TYPED search (``FoodSearchContext/userTyped``) shows one row per
catalog name within a data type — the internal `TypeaheadDuplicateCollapse` keeps, at the group's
first position, the row whose nutrition is physically possible and whose tap default converts, then
the one with more household portions the domain's tolerant portion reader can read (since the
2026-09-30 units fixes every tap default converts, so for most twins that last rule decides: "Garlic,
raw" is now the SR row with a clove and a cup, not the RACC-only Foundation row) — never hiding a user
item or a row this person has logged; machine-generated queries see every row.

**Curated aliases.** A typed search also answers a short, frozen-English table of phrases whose
food's catalog NAME does not say them (the internal `CuratedSearchAlias`, ingredient-search round F7):
"chocolate chip(s)", "choc chips" and "semi sweet chocolate chips" name USDA's "Candies, semisweet
chocolate" (its "chips" live only in portion text, which neither FTS nor the name floor reads), "garlic
clove(s)" names the SR "Garlic, raw" that carries a clove, "red pepper flakes" names "Spices, pepper, red
or cayenne", and "vegetable oil" names the soybean salad or cooking oil. A phrase matches while its last
word is still being typed ("chocolate chi"), never on one word, and "semi sweet" folds to "semisweet".
The row is inserted, never substituted: it sits beneath this person's own and logged rows and beneath a
correction, above the cold list, and the list keeps its limit. It is typed-only by construction —
``FoodCatalog/candidates(for:limit:ranking:)``, the importer's bind and
``FoodCatalog/scoredResults(for:limit:stripsStopwords:)`` never see it — so no alias reaches a
meal-resolution pool or a bind-confidence gate. Targets are the rows' deterministic catalog ids.

**The recipe order.** ``FoodCatalog/results(for:limit:stripsStopwords:context:ranking:)`` and
``FoodCatalog/candidates(for:limit:ranking:)`` take a `FoodSearchRanking` (ingredient-search round F5),
independent of the context: the recipe editor's typeahead (typed) and the swap sheet's pool
(machine-generated sub-phrases) pass `.ingredientIdentity`, which puts the rows that ARE the typed
ingredient first (`FoodIngredientIdentity`, in `FernletDomainModel`), while every other caller keeps
the `.standard` default. It re-ranks rows the gate and floors admitted, before the one-row-per-name
collapse and the alias; ``FoodCatalog/scoredResults(for:limit:stripsStopwords:)`` has no ranking.

The module also owns the ambient nutrient-nudge data path: ``CuratedNutrientSources``
loads the hand-authored good-sources table (`Resources/CuratedNutrientSources.json`,
~55 ``CuratedFoodSource`` rows pinned to real catalog ids with a normalized-name
regeneration fallback), ``NutrientNudgePlanner`` applies the 7-vs-14-day window policy to
the derived-signal `NutrientGap`s, and ``NutrientNudgeCopy`` holds the card's exact
user-facing wording — all pure and unit-testable without SwiftUI, and deliberately
unaware of cycle data (iron needs vary with menstruation, but that signal is walled off
and must not surface here).

**Position in the graph and the S3 wall.** FoodCatalog depends only on
`FernletFoundation`, `FernletDomainModel`, and `FernletScoring`, and holds no sealed or
personal data — the bundled catalog is public USDA reference data. It therefore sits
*below* the S3 privacy wall: the walled `AIProviders` module imports it directly (a
wall-legal edge), as do `DiaryStore` and the app target's meal-resolution, barcode,
grocery, and export flows. Nothing in this module may ever grow an edge to a `Private*`
store. Note the deliberate exclusion: `DishTemplateLexicon`/`DishTemplates.json` stay in
the app target because dish resolution goes through the `@MainActor`, AI-coupled
`MealBuilder`.

**Concurrency.** The target has no `defaultIsolation(MainActor.self)` — everything is
nonisolated pure service code. ``FoodCatalog`` is `@unchecked Sendable` behind one
`NSLock` (user items + branded-source slot); ``SQLiteBundledFoodSource`` serializes its
single read-only connection on a private `DispatchQueue`. Both are safe to query from any
actor, which the off-main AI meal-resolution path relies on. Failure modes are uniformly
non-throwing: a missing resource falls back to an empty source, and any SQLite error
degrades to an empty result.

## Topics

### The catalog

- ``FoodCatalog``

### Bundled sources

- ``BundledFoodSource``
- ``SQLiteBundledFoodSource``
- ``InMemoryBundledFoodSource``
- ``SupplementedBundledFoodSource``
- ``BundledFoodSupplement``
- ``FoodCatalogSchema``

### SQLite interop helpers

- ``sqliteBindText(_:_:_:)``
- ``sqliteColumnText(_:_:)``

### Catalog generation

- ``FoodDataCatalog``

### Nutrient nudge

- ``CuratedFoodSource``
- ``CuratedNutrientSources``
- ``NutrientNudgePlanner``
- ``NutrientNudgeCopy``
