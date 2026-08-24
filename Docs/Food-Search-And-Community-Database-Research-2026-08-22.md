# Food search, and the question of a user-uploaded food database

**A research memo answering two owner questions — 2026-08-22**

**Status:** Research and decision memo. Nothing here changes code. It names a recommendation rather
than surveying options, and it is sequenced cheapest-first.
**Scope:** Two questions, one worked example. **Q1 (from a beta tester):** *"Should Fernlet add an
online database of food uploaded by users?"* **Q2 (the owner's):** *"Why is food search bad, how do
other trackers search, rank and source food, and what should Fernlet do?"*
**Method:** Source audit of the food-resolution and search path (every code claim carries a
`file:line`), a read-only replay of the shipped 118,317-row `FoodCatalog.sqlite` through a
re-implementation of the real scorer and FTS expression, plus primary-source review of competitor,
licensing, regulatory and peer-reviewed material (every external claim carries a URL).
**Baseline:** branch `claude/design-impl-2026-08-21`, working tree actively edited by a concurrent
session. Line numbers are as of 2026-08-22.

**Revised twice on 2026-08-22.** *First revision* — nine owner-supplied PDFs answering the §38
blocked-source list. They are cited inline as *(owner-supplied PDF: "Title", p. N)*, alongside the original URL wherever the PDF is
a print of a known page, so provenance stays traceable. **§38.0 records which gap each one closed —
and which it did not.** **Both conclusions held.** What changed is the *reasoning*: Q1's
data-quality plank is retired (crowd macro data measures well — §16), leaving compliance, comparator
inertness and an absent user base; §18's Nutritionix row is materially rewritten (caching is a priced
tier feature, not a prohibition, and the meter is monthly active users); §14's appeal to industry
consensus is withdrawn; and Q2 gains three independent external supports, one of them from a hostile
witness.

*Second revision* — **two owner follow-up questions, answered in the new Part VII.** **§39** surveys food data sources beyond USDA against one test — may it be copied into a shipped, free, Apache-2.0 binary? — and finds the German and French localizations unblocked *today* by two national tables under open licences, and the Spanish one genuinely blocked. **§40** answers whether MyFitnessPal's five validation rules may be implemented given US 11,508,472 B2, and **rewrites fix 1.14 in §26 with the outcome.** Two research findings were refuted at primary sources and are corrected in §32: Germany's BLS 4.0 is **CC BY 4.0**, not "unclear"; and the patent's continuation **does** claim three of the five rules, contrary to one research pass — the conclusion survives, but on claim *dependency*, not on their absence.

> **How to read this.** §1 is the answer to both questions in one page; §2 lists the four things this
> memo deliberately does *not* recommend, so the body is not read as an oversight. Part I traces the
> tester's own query end to end. Part II is why search is bad, measured. Part III is what everyone
> else does. Part IV prices the UGC question. Part V is the plan, in three explicit buckets —
> **needs no new data**, **needs new data**, **needs a server**. Part VI is governance: the
> corrections this memo applies to its own inputs, and a confidence ledger. The last two sections are
> the owner's: the decisions only they can make, and the sources that were blocked so they can be
> supplied as PDFs — **§38.0 now records what the nine documents supplied on 2026-08-22 closed, and
> what three of them failed to close.**
> **Part VII was added in the second revision** and answers two owner follow-up questions: §39, what
> other food data is worth adopting and what its licence permits; §40, the patent question behind fix 1.14.

---

## 1. The answer

**Q1 — should Fernlet host an online database of food uploaded by users? No.** Not for privacy
reasons alone. Because **Fernlet already ran the experiment that a bigger database is supposed to
win, and it was worth roughly 3%** — while the hosted-UGC version of it would convert a no-account,
no-server app into a hosting provider with DSA Article 16 notice-and-action duties, an EU legal
representative under Article 13, App Store Guideline 1.2's four requirements including *published
contact information*, an iCloud account requirement, an unpriced CloudKit liability, and a standing
moderation bill.

**Q2 — why is food search bad?** It is a **ranking, parsing and gating** problem, not a data problem.
On a 57-query realistic corpus replayed against the shipped catalog, **11 queries (19%) return zero
results and not one is a coverage failure**, and **15 of the 46 that do return rows (33%) have a
clearly wrong top-1** — a combined **~46% failure rate on realistic input, entirely against data
already shipping**.

**Q2 now carries three external supports, one of them hostile.** (a) MyFitnessPal's own account of
its database describes **no ranking function at all** — "Best match" is defined *circularly* as
*"When you manually search the food appearing at the top of your search results is considered the
best match"*, and the words rank, algorithm, popular and frequency occur **zero times** across
sixteen pages (owner-supplied PDF: "How MyFitnessPal's Food Database Works", p. 4;
[blog.myfitnesspal.com/how-food-database-works](https://blog.myfitnesspal.com/how-food-database-works/)).
The largest crowd database in the market has not articulated, let alone solved, ranking. (b) A vendor
whose entire commercial thesis is that crowd *data* ruins accuracy nonetheless blames the *ordering*:
*"Most casual users tap the first result they get, which is rarely the verified one. This is the
mechanism behind the validity problems documented above."* (owner-supplied PDF: "MyFitnessPal vs.
Lose It! vs. Fitia: Database Compared", p. 4 — vendor content marketing published by Fitia; see §17).
(c) Evenepoel's own remedy for a 6-million-entry crowd database was **selection engineering, not
corpus work** — pre-register authoritative entries for generic foods, steer users to them, then to
verified-flagged ones — and the same database measured **r = 0.21–0.42** uncoached versus
**0.79–0.96** coached (owner-supplied PDF: Evenepoel et al., JMIR 2020, p. 7). Identical corpus; the
entire swing is seeding, gating and ranking.

**The top three fixes, each needing no new data:**

1. **Stop hardcoding `.high` confidence on the dish-template tier** (`App/Fernlet/MealResolutionService.swift:148-149`).
   It is the only tier in the five-tier cascade with no quality gate at all, and that single literal
   is why the tester's meal was committed to her diary with no review sheet.
2. **Give that tier the bind floor every other tier already has** (`App/Fernlet/DishTemplateLexicon.swift:215`
   uses the *unscored* `results(for:limit:1)` API). The mozzarella component bound at score **58**
   against a `confidentBindScore` of **250** that the codebase already defines at
   `FernletKit/Sources/FernletDomainModel/FoodItemSearch.swift:53`.
3. **Stop sorting data type above relevance score** (`FoodItemSearch.swift:93-102`). Demoting data
   type to a tiebreak turns `mozzarella cheese` from a breaded fried stick at score 58 into
   `Mozzarella Cheese` at 1870, and addresses 15 of the 46 measured wrong top-1s.

The catalog already contains the answer to the tester's query. `SELECT … WHERE normalized_name LIKE
'%pizza%' AND LIKE '%cheese%'` returns roughly 35 rows, many carrying real per-slice gram weights:
`PIZZA HUT 14" Cheese Pizza, Pan Crust` slice = 112 g / pizza = 897 g; `DOMINO'S 14" Cheese Pizza,
Crunchy Thin Crust` slice = 70 g / 540 g; `DIGIORNO Pizza, cheese topping, rising crust` slice
(¼ of pie) = 183 g / pie = 729 g; `Pizza, cheese topping, thin crust, frozen, cooked` slice = 69 g.
**468 rows repo-wide mention a slice portion; 194 portion entries have unit exactly `slice`.** None
of it was consulted.

And the one rung that could have answered the query was designed for exactly this and is switched
off: `FoodProductWebSearch.shouldSearch` returns TRUE for "costco cheese pizza slice" because
`costco` is a hardcoded retailer term (`App/Fernlet/FoodProductWebImporter.swift:46-49`), but the
lane is gated on `webNutritionLookupEnabled`, which defaults to `false`
(`FernletKit/Sources/FernletDomainModel/SettingsModel.swift:66`).

| | **Q1 — user-uploaded online food DB** | **Q2 — food search** |
|---|---|---|
| **Answer** | No. Not now, not in this shape. | A ranking, parsing and gating problem, not a data problem. |
| **Measured benefit** | ~3% top-1 improvement (the ODR experiment, §10) | 9 local changes address a measured ~46% failure rate |
| **Measured cost** | Hosting-provider status (DSA Art. 16 / Art. 13), App Store 1.2's four requirements incl. **published contact information**, an iCloud account requirement, an unpriced CloudKit liability, moderation labour | Engineering only; no new destination, no new dependency, no wall amendment |
| **Walls broken** | No-tracking §1 (no developer-operated server), the no-account promise, Privacy Policy §1/§8/§12/§13 | None |
| **The cheap alternative** | Local correction memory + private custom foods + the sealed proximity mesh that already ships | — |

---

## 2. Four things this memo deliberately does not recommend

Each of these is a proposal a reader will otherwise generate. Each has one killing fact.

**1. A global user-upload pool.** Killed by the measurement in §10 (a 4× row increase moved top-1 for
one query in thirty) plus the compliance surface in §21. Adding rows to *this* comparator, which has
no score floor, is a net negative before a single moderation question is asked.

**2. A runtime nutrition API — Open Food Facts, FoodData Central, Nutritionix, FatSecret, Edamam,
Spoonacular.** Killed for an offline-first app by caching terms: FatSecret requires non-storable
content to be deleted or re-requested **within 24 hours**
([fatsecret.com/platform-api-terms-and-conditions](https://platform.fatsecret.com/api/Default.aspx?screen=rapiu));
Spoonacular permits a **1-hour** cache
([spoonacular.com/food-api/terms](https://spoonacular.com/food-api/terms)); Edamam permits caching of
**six fields only** ([developer.edamam.com/faq](https://developer.edamam.com/faq)). Each also costs a
new permitted destination under the no-tracking wall.

**Correction, 2026-08-22 — "killed by caching terms" is too strong for Nutritionix specifically.**
Its published pricing page carries an explicit **"Caching Allowed"** comparison row: ✗ on the free
Business Trial, ✗ on Starter ($499/mo), **✓ on MVP ($999/mo)**, ✓ on Unicorn (from $1,850/mo), all
billed annually (owner-supplied PDF: "Nutrition API by Nutritionix", p. 2;
[nutritionix.com/api](https://www.nutritionix.com/api)). Caching is **not prohibited — it is a paid
feature with a $999/month floor**, a categorically different regime from FatSecret's 24 hours,
Spoonacular's 1 hour and Edamam's six fields. Two things keep it out of the recommendation anyway.
First, **scope is undefined**: the page never says what "caching" covers, no retention period is
stated, and a durable copy shipped inside an offline binary is a different thing from response
caching — the row's definition lives in a hover tooltip that did not survive print-to-PDF, and the
binding terms are Syndigo's, at `syndigo.com/legal/terms-of-use`, which was not supplied. Second, the
meter is **monthly active users** (2 / 200 / 1,000 / customizable, with **no published call limits at
all**), and a free app is off the published price list entirely. See §18, §19 and the answerable
question in §37.

**3. `ORDER BY rank`, or a "let SQLite rank it" refactor.** `food_fts` is declared
`content='', columnsize=0` (`FernletKit/Sources/FoodCatalog/BundledFoodStore.swift:107`). SQLite
documents that with `columnsize=0` on a contentless table the `xColumnSize` API "always returns -1"
([sqlite.org/fts5.html](https://www.sqlite.org/fts5.html)), so BM25's document-length normalisation is
disabled. **Correction to the source research: the function is not unavailable.**
`SELECT rowid, rank FROM food_fts WHERE food_fts MATCH 'pizza*' ORDER BY rank` returns usable,
varying values against the shipped file — measured `-8.18197255136941`, `-8.15861098628329`,
`-8.15861098628329` — identical to `bm25(food_fts)`. What is lost is length normalisation, which is
precisely the short-name-beats-long-dish pathology that produced "Pizza Dough" over "Pizza, cheese,
regular crust." Restoring it means dropping `columnsize=0` and regenerating a **59,748,352-byte** file
into git history with no LFS and no `.gitattributes`.

**4. `INSERT INTO food_fts(food_fts) VALUES('optimize')` at build time.** **Already done** —
`App/Fernlet/FoodCatalogDatabaseBuilder.swift:74`, followed by `VACUUM;` at `:75`. This
recommendation appeared in the source research and is moot.

---

# PART I — THE WORKED EXAMPLE

## 3. "costco cheese pizza slice"

A beta tester typed that into the meal composer. Fernlet logged a **three-ingredient recipe**:

| Component | Grams | Catalog row bound |
|---|---|---|
| Pillsbury Pizza Dough Thin Crust | **120 g** | branded |
| Mozzarella sticks, breaded, baked, or fried | **80 g** | survey |
| Tomato sauce, canned, no salt added | **60 g** | srLegacy |

Roughly 600–700 kcal, committed to the diary **with no review sheet**. The user saw the components
only afterwards, on the Adjust-meal sheet, where all three carried the label "Probably not what you
meant."

**This is not an AI hallucination.** It is the deterministic dish-template tier, reproduced
byte-for-byte offline. The fingerprint is conclusive: the string `"pizza dough crust"` occurs in
**exactly one file in the entire repo**, `App/Fernlet/DishTemplates.json:291`. A repo-wide grep
returns one hit. That rules out the model path entirely. The gram values follow arithmetically from
the template: `2 × (60 / 40 / 30)` = 120 / 80 / 60, matching the report exactly.

---

## 4. Seven steps from a text box to a wrong meal

**Step 1 — the UI.** `MealSheet.saveTapped` (`App/Fernlet/FoodView.swift:2766`) is a four-branch
cascade. Branch 3 is the branded/retail web lane. `FoodProductWebSearch.shouldSearch`
(`App/Fernlet/FoodProductWebImporter.swift:44-53`) returns TRUE — `retailerTerms` at `:46-49`
contains `"costco"`, and the ≥ 2-meaningful-token guard passes. But the lane is gated on
`store.allowsWebNutritionLookup` (`FernletKit/Sources/DiaryStore/DiaryStore.swift:95-97` =
`webNutritionLookupEnabled && aiStatus != .off`), whose backing setting is
`webNutritionLookupEnabled: Bool = false` (`FernletKit/Sources/FernletDomainModel/SettingsModel.swift:66`).
Control falls to `resolveTypedMeal` (`FoodView.swift:2829`).

**Step 2 — canonicalisation.** `MealResolutionService.canonicalizedQuery`
(`App/Fernlet/MealResolutionService.swift:245-258`) rewrites only `burger patt(y|ies)`. The
description passes through unchanged.

**Step 3 — the five-tier cascade.** `resolveMeals` (`MealResolutionService.swift:91-164`): tier 1 AI
decomposition at `:113`, tier 2 AI candidate-constrained selection at `:132` (both gated on
`aiStatus != .off` at `:105`), tier 3 `DishTemplateLexicon` at `:148`, tier 4 deterministic plan at
`:155`, tier 5 `MealParser` keyword fallback at `:162`, with `plausibilityGated` at `:268`.
**Tiers 1 and 2 returned nil or were skipped.**

**Step 4 — template match.** `DishTemplateLexicon.resolve` (`:177-198`) calls
`MealItemSplitter.items` (`FernletKit/Sources/FernletDomainModel/NutritionModels.swift:1354-1376`),
which returns ONE item — there is no comma, no `" and "`, no `" with "`. `matchDetailsWithCount`
(`:124-140`) normalises, finds no exact key, then takes the **longest substring match**:

> `catalog.index.filter { norm.contains($0.key) }.max { $0.key.count < $1.key.count }` — `DishTemplateLexicon.swift:133-138`

Exactly two keys are contained in "costco cheese pizza slice": `pizza` (5 chars) and the alias
`cheese pizza` (12 chars). Longest wins.

**Step 5 — the count.** `extractLeadingCount` (`:248-253`) reads only
`normalized.split(separator: " ").first` — that is `"costco"`, which is not numeric → nil →
`defaultCount = 2`. **The word "slice" the user typed is never parsed**; the template's declared
`unit: "slice"` (`DishTemplates.json:288`) is documentation only. The brand token `"costco"` is
discarded entirely and never reported as unmatched.

**Step 6 — component binding.** `assemble` (`:202-238`) loops the three components calling
`catalog.results(for: query, limit: 1).first` at **`:215` — the unscored API, no floor**. Grams at
`:218` = `min(component.gramsPerUnit * count, MealPlausibility.maxSingleLogGrams)`.

**Step 7 — auto-commit.** `MealResolutionService.swift:149` wraps the result in
`MealResolution(meals: lexiconMeals, createdRecipes: [], confidence: .high, isFallback: false)`
**unconditionally**. `needsReview` (`NutritionModels.swift:625`) is
`confidence.needsReview || isFallback || !unmatchedItems.isEmpty` → all three false → **FALSE**.
`plausibilityGated` downgrades only above 4,000 kcal; this meal is ~600–700 kcal.

**The replay, with scores.** Re-implementing `FoodItemSearch` and the FTS expression and running the
three template search strings against the shipped catalog reproduces all three bindings and all three
gram values exactly:

| Template search string | Top-1 returned | Data type | Score | Runner-up | Verdict |
|---|---|---|---|---|---|
| `pizza dough crust` | Pillsbury Pizza Dough Thin Crust | branded | 179 | Gluten Free Dough, Thin Crust Pizza (178) | **Template-data defect** — survives every ranking variant |
| `mozzarella cheese` | Mozzarella sticks, breaded, baked, or fried | survey | **58** | DENNY'S mozzarella cheese sticks (srLegacy, 369); Cheese, mozzarella, whole milk (srLegacy, 119) | **Ranking defect** — data type sorted above score |
| `tomato sauce` | Tomato sauce, canned, no salt added | srLegacy | 868 | Tomato, sauce, canned, with salt added (868, loses on name order) | Correct |

---

## 5. Six causes, and how much each is to blame

The percentages are a **judgement call, not a measurement**. What is not a judgement call is the
plurality: **no single fix addresses all three bad bindings** — one is ranking, one is template data,
one was already correct. That is why the fix list in §26 is plural.

| # | Cause | Blame | Code | Fix bucket |
|---|---|---|---|---|
| 1 | **Decomposition decision.** Unanchored longest-substring template match; brand token silently discarded; no whole-description catalog probe before decomposition, even though `Docs/Meal-Estimation-Overhaul-Plan.md` §2.1/§3.4 specifies exactly such a single-entry short-circuit | ~40% | `DishTemplateLexicon.swift:133-138`; `MealResolutionService.swift:91-164` (no probe anywhere in the cascade) | No new data |
| 2 | **No bind floor + hardcoded `.high`.** The lexicon tier is the only tier in the cascade with no quality gate at all | ~20% | `DishTemplateLexicon.swift:215`; `MealResolutionService.swift:148-149`; contrast `FoundationDishDecomposition.swift:226-232` and `FoundationFoodSelection.swift:143-148/:187` | No new data |
| 3 | **Ranking — data type sorted above relevance score** | ~15% | `FoodItemSearch.swift:93-102` (comparator), `:305-322` (`dataTypePriority`); `demotingDishes` applied only at `NutritionModels.swift:1489` and `FoodCatalog.swift:126`, **not** in `results()` at `FoodCatalog.swift:87-89` | No new data |
| 4 | **Template data quality.** (a) `pizza dough crust` is not the name of any food; (b) `defaultCount: 2` silently doubles the meal | ~15% | `DishTemplates.json:284-295`; `DishTemplateLexicon.swift:248-253` | No new data |
| 5 | **Retrieval.** `brand_source` is indexed nowhere; strict prefix-AND gate | ~10% | `BundledFoodStore.swift:107`, `:227-232`; `FoodItemSearch.swift:67` | New data (regeneration) |
| 6 | **The web lane is off by default** | ~5% | `FoodProductWebImporter.swift:44-53`; `SettingsModel.swift:66`; `DiaryStore.swift:95-97` | Product decision |
| — | **The AI tier and its prompt/shortlist** | **0%** | That tier never ran | — |

**A correction to the source research.** The claim that "decomposition is the designed default at
every rung; there is no is-this-one-packaged-food test anywhere in the cascade" is **overstated**. The
AI decomposition prompt contains, two lines above the "Keep to 2–6 primary ingredients" instruction:
*"Treat a plainly named whole food as a SINGLE component — '2 eggs' is one 'egg' component (~100 g),
NOT separate yolk and white. Only split a food into parts when the person explicitly names the
part."* (`App/Fernlet/FoundationDishDecomposition.swift:39-52`). The claim holds for rung 3 — the tier
that actually fired — and not for the AI rung.

Worth stating plainly, because it inverts the intuitive blame: **the AI decompose tier is in several
ways safer than the deterministic tier that fired.** It has a bind floor
(`FoundationDishDecomposition.swift:226-232`), gram-bounds clamping (`componentGramBounds` 0.5×–1.75×,
then hard-clamped to 1…1500 g), a caloric-density check (0.3–9 kcal/g), and derives its confidence
from bind strength rather than asserting it.

---

## 6. The warning label carries no information

The most quotable line in the tester's report is that the app flagged all three items with "Probably
not what you meant" and logged them anyway. That reads as the code knowing and shipping regardless. It
is not. It is a false-positive machine — **and the signal it needed did exist and was discarded.**
That second half is the honest indictment.

`MealCorrectionSheet.lowConfidenceComponentIDs(for:)` at `App/Fernlet/FoodView.swift:3991-4004`:

> `let unexplained = componentTokens.subtracting(mealTokens).count`
> `if unexplained * 2 > componentTokens.count { flagged.insert(component.id) }`

It is computed once at sheet-open from token overlap between the meal name and each component name,
and rendered at `:4121`. Its own doc comment (`:3986-3990`) concedes it is "reconstructed from the
names" and that "there is no stored per-item match score."

Verified by hand against meal name `{costco, cheese, pizza, slice}`: Pillsbury has 4 of 5 tokens
unexplained; Mozzarella sticks 5 of 5; Tomato sauce 5 of 5. **All three flagged, by construction.**
It fires on **every** decomposition by construction — a correct rice + salmon split under "Salmon
nigiri" would flag identically — and it is blind to bad single-token binds, because
`guard componentTokens.count > 1 else { continue }` skips them.

The real signal was one API call away. `catalog.scoredResults` would have returned **58** for the
mozzarella bind, far below `confidentBindScore = 250`, which the codebase already defines at
`FoodItemSearch.swift:53` and which every other tier consults. `DishTemplateLexicon.swift:215` chose
the unscored API instead.

---

# PART II — WHY FOOD SEARCH IS BAD

## 7. The pipeline, precisely

No judgement can be formed about the fix list without knowing that FTS5 here is a **set filter, not a
ranker**, and that ranking is a hand-written integer scorer whose comparator puts provenance above
relevance.

**Retrieval.**
`CREATE VIRTUAL TABLE food_fts USING fts5(name, category, tags, content='', columnsize=0, tokenize='unicode61')`
(`BundledFoodStore.swift:107`). Contentless, three columns, stock `unicode61` — no porter stemmer, no
trigram index, no `prefix=` table, no `remove_diacritics` override. The read query at `:248-252`
orders by a hard-coded data-type CASE at `:246-247` (`foundation` 5 … `restaurant` 1) purely to
de-bias LIMIT truncation, **never by `rank`**. `candidateFetchLimit = 10000` at `:58`. The MATCH
expression is built at `:227-232` as a strict AND of prefix terms with singular/plural variants OR'd
inside each token: `(eggs* OR egg*) AND cheese*`.

**Scoring.** `FoodItemSearch.score` (`:188-212`). A hard gate first: every query token must
equal-or-prefix some searchable token, else `nil`. Then exact name **+1000**; prefix **+500**;
substring **+250**; **+60** per query token that *exactly equals* a name token;
`−(nameLen − queryLen)/8` integer-division length penalty; plus `preparationBias` (`:234-295`: +150 on
agreement, −100/−150/−200 on conflict) and `formSpecificityBias` (`:218-230`: **−130 per extraneous
form qualifier** drawn from a 20-token set — yolk, yolks, white, whites, powder, powdered, dried,
dehydrated, concentrate, paste, juice, extract, substitute, imitation, peel, skin, skins, flour,
flakes, puree).

**The searchable string.** `Index.init` at `:62-74`:
`let searchable = [name, category, tags].joined(…)`. **`brandSource`, `servingDescription` and
`portions` are not in it.** The FTS insert mirrors the omission
(`FoodCatalogDatabaseBuilder.swift:97`).

**Ranking.** `Index.scoredMatches` at `:93-102` sorts, in order: `sourcePriority` DESC (manual 3 >
usda 2 > aiResolved 1, `:297`) → `dataTypePriority` DESC (`:305-322`) → **then** score → then
`localizedStandardCompare` on name.

**Tokenisation.** `tokens()` at `:325-330` filters only on `count >= 2`. **There is no stopword list
on the search path.** The stopword set exists at `NutritionModels.swift:1499-1502` —
`["and","with","plus","then","for","the","a","an","of","my","meal","breakfast","lunch","dinner","snack","pre","post","workout"]`
— and is consumed only by `FoodSelectionCandidateBuilder.searchPhrases`, never by `results(for:)`.

**Stemming.** `singularStem` at `:362-371` fires only for tokens ≥ 4 chars: `ies → y` (len ≥ 5) and a
trailing non-`ss` `s`. There is no typo tolerance of any kind.

**Brand detection.** `FoodBrandLexicon` at `:15-24` is a **43-entry** Set (the source research said
44), matched by an unanchored substring test at `:31-34`: `chains.contains { n.contains($0) }`. It
contains the bare tokens `"chilis"`, `"sonic"`, `"subway"`, `"checkers"`, `"outback"`, `"rallys"`,
`"friendlys"`.

**Caps.** `FoodCatalog.results` / `scoredResults` default to `limit: 6` (`FoodCatalog.swift:87`,
`:93`) with **no score floor**. `candidates(for:)` defaults to 18 (`:114-128`), taking
`results(for: phrase, limit: 4)` per phrase and applying `PreparedDishHeuristic.demotingDishes` at
`:126` — which `results()` does not. `index(for:)` at `:130-134` unions base + branded + userItems per
keystroke. The typeahead debounces 220 ms off the main actor (`FoodView.swift:1882`, `:1888`).

| Sort key | Values | Consequence |
|---|---|---|
| `sourcePriority` | manual 3 > usda 2 > aiResolved 1 | Any matching user item — even one that squeaked through on a tag with a negative score — outranks every catalog row |
| `dataTypePriority` (non-brand query) | foundation 5 > survey 4 > srLegacy 3 > branded 2 > restaurant 1 | 109,163 branded rows sit permanently below 8,888 srLegacy rows for every non-brand query. `foundation` has **0 rows** in the shipped file — the top tier is unreachable |
| `dataTypePriority` (brand query) | restaurant 5 > branded 4 > foundation 3 > survey 2 > srLegacy 1 | Flipped by an unanchored substring test on the whole query |
| `score` | integer, unbounded, can be negative | **Third-order tiebreak.** No score bias can ever demote a higher tier |
| name | `localizedStandardCompare` | — |

---

## 8. What actually fails, measured

This section reframes the whole memo. It was produced by re-implementing
`normalized` / `tokens` / `matchVariants` / `score` / `preparationBias` / `formSpecificityBias` and
the full comparator, plus `BundledFoodStore.candidates`' prefix-AND FTS5 expression, the 10,000-row
cap and the ORDER-BY-CASE de-bias, then replaying 57 realistic logging queries against the shipped
read-only `FoodCatalog.sqlite`.

**11 of 57 (19%) return zero rows:** `bowl of oatmeal`, `two scrambled eggs`, `glass of milk`,
`handful of almonds`, `piece of chicken`, `bowl of cereal`, `plate of pasta`,
`costco cheese pizza slice`, `kirkland protein bar`, `whole foods rotisserie chicken`, `chiken breast`.

**Not one is a coverage failure.** The catalog holds `Oatmeal NFS`, `Nuts, almonds`, `Pasta, cooked`,
several `Milk` rows, and `Egg omelet or scrambled egg`. It holds **679** rows whose `brand_source`
contains Whole Foods, **31** Costco, **2** Kirkland — all invisible because `brand_source` is in
neither the FTS table nor `Index.searchable`. Seven of the eleven are natural-phrasing failures, three
are brand-index failures, one is a typo.

**15 of the 46 non-empty queries (33%) have a clearly wrong top-1:**

| Query | Top-1 returned |
|---|---|
| `apple` | *Apple salad with dressing* |
| `brown rice` | *Snacks, brown rice chips* |
| `cheddar cheese` | *Sausage, pork and beef, with cheddar cheese, smoked* |
| `cheese pizza` | *Calzone, with cheese, meatless* |
| `beef tacos` | *Burrito, beef, cheese* |
| `pho` | *Gelatin desserts, dry mix, reduced calorie, with aspartame* |
| `mac and cheese` | *Macaroni or pasta salad with cheese* |
| `chicken noodle soup` | *Ramen bowl with chicken* |
| `low fat greek yogurt` | *Low-Fat Greek Yogurt Guacamole* |
| `chick fil a sandwich` | *Banquet Breakfast Chicken Sandwich* |
| `chipotle chicken bowl` | *Lean Chipotle Chicken Bowl Spicy* |
| `slice of toast` | a five-cheese *Texas Toast* |
| `cup of coffee` | *Cape Cod Cranberry Coffee Cake* |
| `tomatoes` | *Pork with chili and tomatoes* |
| `potatoes` | *Beef stew with potatoes, Puerto Rican style* |

**Combined failure rate on realistic input: ~46%.** Every one is a ranking or normalisation defect:
data type sorted above score; the +60 coverage bonus requiring exact token equality, so a stemmed
match earns nothing; a length penalty divided by 8 that is effectively nil; and no phrase bonus at
all.

**FTS row counts against the shipped file.** All sixteen independently reproduced on 2026-08-22:

| MATCH expression | Rows | What it shows |
|---|---|---|
| `cheese* AND pizza*` | 533 | Baseline |
| `cheese* AND pizza* AND slice*` | **6** | One natural word costs 99% of the result set |
| `costco* AND cheese* AND pizza* AND slice*` | **0** | The tester's query is unsearchable |
| `costco*` | **0** | …against 31 rows whose `brand_source` contains Costco |
| `bowl* AND of* AND oatmeal*` | **0** | `of` is a real token; there is no stopword list |
| `oatmeal*` | 690 | |
| `of*` | 1,551 | |
| `(tomatoes* OR tomatoe*)` | 951 | None are the singular `Tomato, …` rows |
| `tomato*` | 2,143 | |
| `(potatoes* OR potatoe*)` | 1,211 | |
| `potato*` | 3,090 | |
| `chiken*` | **2** | No edit-distance fallback |
| `chicken*` | 5,270 | |
| `yoghurt*` | 17 | Locale spelling unhandled |
| `yogurt*` | 3,876 | |
| `che*` | 13,958 | ~1.59 MB of JSON hydrated per keystroke, truncated at 10,000 |
| `pizza*` | 2,686 | |
| `(chilis* OR chili*)` | 1,335 | |
| `subway*` | 11 | Chain tokens do not overflow the cap |
| `kfc*` | 22 | |
| `domino*` | 13 | **Correction:** `dominos*` returns 0; the 13 is `domino*` |

---

## 9. Three failures you can reproduce in one query each

**(a) Exact-name matches lose to generic rows.** `protein bar` → top hit
`Formulated Bar, SOUTH BEACH protein bar` (srLegacy, score **367**), while two `Protein Bar` branded
rows scoring **1870** on an exact-name match rank 3rd and 4th. `cheerios` →
`Cereals ready-to-eat, GENERAL MILLS, CHEERIOS` (srLegacy, **306**) above `Cheerios Cereal` (branded,
**810**).

**(b) A trailing `s` silently switches the app into restaurant mode.** `chili` → top hits
`Chili, NFS` (survey, 810) and `Chili with chicken` (survey, 809). `chilis` → the identical 1,335-row
gate-passing set, but the top hits become `5 Chilis Salsa` (branded, **309**) followed by three rows
scoring **0** (Beans & Franks, Beans & Wieners, Beef Chili), because `"chilis"` is a bare entry in the
43-item chain lexicon matched by unanchored `contains`. The converse also fails: `mcdonald's fries`
normalises to `mcdonald s fries`, which does not contain the lexicon entry `mcdonalds`, so brand
detection silently does not fire and the token `s` is dropped as < 2 chars.

**(c) There is no score floor on the search path.** `cheese pizza` top-6, in order:
`Calzone, with cheese, meatless` (survey, **58**), `Calzone, with meat and cheese` (58), then three
`White pizza` rows at **−12 / −12 / −13**, with `Annie's Three Cheese Pizza Poppers` (srLegacy, **368**)
ranked below them. `cheese pizza slice` returns six branded rows, two of which score **−82** (a
seven-cheese blend row and a Wisconsin whole-milk fresh mozzarella row), presented in the top-6 with
no visual distinction from a real hit. `minimumBindScore = 1` (`FoodItemSearch.swift:50`) is a no-op —
any single name-token hit scores +60 — and it guards only the AI and deterministic bind paths, never
the search path.

**The counterfactual, which quantifies fix leverage.** Re-run with data type demoted to a pure
tiebreak: `mozzarella cheese` → `Mozzarella Cheese` (score **1870**, exact-name); `cheese pizza` →
`Cheese Pizza` (**1870**). But `pizza dough crust` → **Pillsbury under every ranking variant**,
because the template literally asked for dough AND crust.

---

## 10. Fernlet already shipped the bigger database

This is the single most important empirical result in the memo, and every argument for OFF's 4.7 M
rows, Nutritionix's 1.27 M, or a user-upload pool must clear it first.

**Method.** 30 non-brand everyday queries against the base catalog alone, then against base + the
364,457-row `ODRAssets/FoodCatalogBranded.sqlite` (**177,901,568 bytes**) attached exactly as
`FoodCatalog.index(for:)` unions them, with the branded source's `candidateCap = 600` and
`skipPriorityOrder: true` (`App/Fernlet/BrandedCatalogResourceLoader.swift:34`, `:101-102`; `odrTag`
at `:27`).

**Result: the top-6 changed for 10 of 30. The top-1 changed for exactly one** — `black coffee`,
Califia Cold Brew → Black Coffee.

**Mechanism.** `dataTypePriority` puts branded at 2 and srLegacy at 3, so for any non-brand query the
364 k new rows sort **underneath** the 8,888 generic rows and are functionally inert.

**A second, independent inertness.** The branded source drops its `ORDER BY`
(`skipPriorityOrder: true`), so `LIMIT 600` retains an arbitrary low-rowid slice. `MATCH 'pizza*'`
matches **7,337** branded rows; the 600 returned span `food_id` 194…36196 out of 364,457 — **8.2%
retained**, decided by nothing more than catalog build order. Of the 5 DiGiorno pizza rows
(`food_id` 6,112…289,206), **only the 6,112 row falls inside the window**. (Correction: the source
research said 6 rows; a name match yields 5. The min/max ids and the conclusion are exact.)

**And the ODR file is not shipping at all.** It is gitignored at `.gitignore:11`;
`git ls-files --error-unmatch` errors on it; a case-insensitive grep of
`App/Fernlet.xcodeproj/project.pbxproj` for `odr|assetTags|OnDemand|ON_DEMAND|FoodCatalogBranded`
returns **zero** hits; and the integration test silently returns when the file is absent
(`Tests/FernletTests/BrandedODRCatalogTests.swift:26` — `guard let odrURL = Self.odrURL else { return }`).
`ODRAssets/README.md` documents the Xcode tag assignment as a manual one-time step that was never
performed.

| Intervention | Rows added | Bytes | Top-1 change measured |
|---|---|---|---|
| Attach branded ODR catalog | +364,457 (4×) | 177,901,568 | **1 of 30 (3%)** |
| Open Food Facts world corpus | +4,701,512 | ~1.28 GB CSV gz | Untested; same comparator, same inertness mechanism |
| A user-upload pool | unbounded | server | Untested; the new rows would enter the same comparator, which has no score floor and sorts data type above relevance. **Note this is an *ordering* objection, not a data-quality one** — see §20 |
| The stopword list already in the repo | 0 | 0 | **Recovers 7 of 11 zero-result queries** |
| Score above data type | 0 | 0 | Addresses 15 of 46 wrong top-1s |

---

## 11. The primary logging surface has no search field

Before deciding what to put in the database, make the database reachable. This is not a data question
at all, and it belongs in the memo's spine.

`MealSheet` (`FoodView.swift:2188`) presents exactly one text input — a `SheetGrowingTextField` bound
to `description` with the placeholder "scrambled eggs and toast" — plus Capture, Scan label, Recent,
Import, and Enter macros by hand (`:2628-2687`). **There is no `CatalogTypeahead`, no
`MealItemSearchField`, and no result list.**

The catalog typeahead exists in exactly three places: the recipe ingredient editor, the Replace/Add
controls in Adjust meal (`MealItemSearchField`, `FoodView.swift:4208`), and the ingredient swap sheet
(`IngredientSubstitutionSheet.swift:140`). A user who wants `Sliced Pizza, Cheese` — which is shipped
— has no path to it except typing free text and hoping the five-tier resolver lands there.

`suggestionList` (`FoodView.swift:2016`) renders **nothing** on zero results: no empty state, no
create-it escape, no result count. `MealItemSearchField` has **no create affordance**, so a catalog
miss in Adjust meal is a dead end. "Save custom ingredient" exists only in the recipe ingredient
editor (`FoodView.swift:2026`), and "Remember this food" only on the barcode not-found screen
(`BarcodeScanView.swift:581`, `:659`).

The industry contrast: MacroFactor lists creating custom foods and recipes as one of five
**first-class** logging methods, not a fallback
([macrofactorapp.com/logging-food](https://macrofactorapp.com/logging-food/)); Cronometer's
create-a-custom-food flow is reached from a Foods tab, not from a failed search. **MEDIUM
confidence, and unmoved by a targeted attempt** — the specific empty-state copy of MacroFactor,
Cronometer and Lose It still could not be verified because their help centres return 403 (§38A). None
of the nine owner-supplied documents describes any app's zero-result behaviour: Cronometer's two
supplied pages never mention custom foods, a missing food, or a food-request path at all, and
MyFitnessPal's own page says only *"you can always add a food that's missing"*, linking out to a
support article that was not supplied (owner-supplied PDF: "How MyFitnessPal's Food Database Works",
p. 11). Recorded here so a future round does not assume the gap was closed.

**One outcome study now supports the re-entry framing rather than the precision framing.** Harvey,
Krukowski, Priest & West, *"Log Often, Lose More: Electronic Dietary Self-Monitoring for Weight
Loss,"* Obesity 2019;27(3):380–384, [doi:10.1002/oby.22382](https://doi.org/10.1002/oby.22382)
(owner-supplied PDF, NIH author manuscript `nihms-1040559`): across 142 participants, successful
losers logged **2.4–2.7 sessions per day versus 1.6–1.7**, while **minutes per day did not differ by
success in any of six months** (p = 0.279, 0.566, 0.859, 0.422, 0.420, 0.786). What separates success
is short, frequent **re-entry**, not total time spent. That makes cheap mid-day resumption — a
reachable search field, a working empty state, history-first ranking (fix 1.9) — the outcome-relevant
lever, and it is exactly what this section and fix 1.9 propose. The same paper reports that **34.5% of
participants had stopped logging entirely by month 6**, and that among those losing under 5% of body
weight **52% had stopped**: abandonment dwarfs database quality as an effect size. **Two caveats that
must travel with it:** the outcome in that literature is weight loss, which Fernlet explicitly does
not optimise for, and the study evaluated a single curated USDA-derived web journal, so it is evidence
about *logging cadence*, not about databases in either direction.

---

## 12. Fernlet already has an online food lookup

Q1 is often framed as "Fernlet has no online food lookup, should it get one?" That framing is false.
Fernlet **has** one, it **correctly recognised this exact query**, and it was disabled behind two
gates.

`shouldSearch` returns TRUE for "costco cheese pizza slice"; `retailerTerms` at
`FoodProductWebImporter.swift:46-49` includes `"costco"`. The lane sits at `FoodView.swift:2779-2795`,
gated on `store.allowsWebNutritionLookup` = `webNutritionLookupEnabled && aiStatus != .off`
(`DiaryStore.swift:95-97`), and `webNutritionLookupEnabled: Bool = false` at `SettingsModel.swift:66`,
tolerant-decoded to false at `:330`.

The question that follows is a product question nobody has asked: **what fraction of users will ever
discover and enable a double-gated, off-by-default toggle buried in Settings — and is the right fix a
consent prompt at the moment of first miss rather than a new database?** A prompt offered at the point
of failure reuses the existing wall-compliant, audited egress path (`html.duckduckgo.com`, the only
host the app itself chooses to contact, `Docs/No-Tracking-Wall.md` §3) and costs nothing in hosting,
moderation or licensing. It is exactly the pattern §5 of the no-tracking wall already prescribes:
*"put the egress behind an explicit, off-by-default user setting whose copy names the destination."*

The audit discipline is already in place: `AIDestination.webNutritionLookup` has
`leavesDevice == true`, so the audit entry is recorded at **dispatch** with a provisional `.fellBack`
and settled at completion.

---

# PART III — HOW OTHER TRACKERS DO IT

## 13. Four sourcing models, and what each buys

Every tracker sits somewhere on a line from *curated core, crowd shell* (MyFitnessPal, Lose It) to
*curated only, gated submissions* (Cronometer). The measured accuracy literature in §16 tracks that
line. Fernlet is already at the curated end by construction.

| App / vendor | Claimed size | Core source | Crowd layer | Verification |
|---|---|---|---|---|
| **MyFitnessPal** | *"over 20 million"* foods in MFP's own account, stated twice and never as 20.5 M (owner-supplied PDF, pp. 3, 11); 68 K+ brands, 380+ restaurants ([Mar 2026 press release](https://www.myfitnesspal.com/press)). **The 20.5 M figure is the App Store listing, not a blog figure** (§17) | Licensed Nutritionix/Syndigo layer | Majority; "any user of the Services can contribute to or edit" ([terms](https://www.myfitnesspal.com/terms-of-service)) | Verbatim, first-party: green check = *"MyFitnessPal has reviewed **or added** a food to our database and **believes** that the nutrition information is accurate"*; unmarked = *"submitted by a MyFitnessPal member like you and **has not been reviewed** by MyFitnessPal"*. **Best Match is defined circularly** — *"the food appearing at the top of your search results"* — and is **not** documented as dietitian-curated anywhere (owner-supplied PDF, p. 4) |
| **Lose It!** | 56 M+ items against ~57 M users ([loseit.com](https://www.loseit.com/)) | — | Dominant (item count ≈ user count) | "verified" checkmark; scope unverified (help centre 403, §38A) — **still unverified after the owner-supplied round** |
| **Cronometer** | ~1.1 M curated foods ([cronometer.com](https://cronometer.com/)) — **not corroborated** by Cronometer's own data-sources page, which states no food count anywhere | Ten named sources, verbatim: NCCDB, **CFCD** (Cronometer Food Composition Database), **USDA SR28**, **CNF 2015**, IFCDB, NEVO, CoFID, NUTTAB, **Nutritionix**, **FDC UPC** — *"over 10 different trusted sources from around the globe"* (owner-supplied PDF: "Accurate Nutrition Database…", pp. 4–5) | Submissions **are** accepted, behind a gate: *"Every item submitted to our database undergoes a verification process"* — scoped to branded entries, with no mechanism stated | *"Our nutrition information is sourced from lab-analyzed data, not crowd-sourced guesses"*; *"By consistently removing duplicate foods and outdated entries, we make choosing the right foods easy"* |
| **MacroFactor** | ~1,360,000 verified items ([macrofactorapp.com](https://macrofactorapp.com/logging-food/)) | NCC Food and Nutrient Database | Opt-in submission | "machine validated by us, and reviewed by the Open Food Facts community, but they are not guaranteed to be manually verified by a human" |
| **Nutritionix / Syndigo** | 1,266,570 items — 1,053,256 grocery from 48,317 brands; **202,837 restaurant items from 860 restaurants**; 10,477 common-food tags → 38,828 phrases ([nutritionix.com](https://www.nutritionix.com/)) | RD-curated; 72-hour CPG capture; monitors 600+ chains | None | Registered Dietitians |
| **FatSecret** | 2.3 M foods, 58+ countries, 26 languages, 90%+ barcode, "100% verified", "zero duplicates" — **VENDOR MARKETING, no external audit**; its own consumer site simultaneously says 1.9 M foods / 56 countries ([platform.fatsecret.com](https://platform.fatsecret.com/)) | Mixed | Yes, gated | Self-asserted |
| **Open Food Facts** | 4,701,512 products (measured 2026-08-22, [world.openfoodfacts.org](https://world.openfoodfacts.org/)) | Community + bulk imports (the 170,754 US rows are the USDA branded import) | Total | Robotoff ML insights, ~50 logic rules, human moderators, Nutripatrol queue, per-app-user bans |
| **Fernlet (today)** | 118,317 bundled + 364,457 ODR (not shipping) | USDA FoodData Central, CC0 | None | None needed |

**Four corrections to this table, from the owner-supplied first-party pages.**

**(a) "CRDB" is not Cronometer's name for anything.** Its data-sources page names the in-house set as
the **Cronometer Food Composition Database (CFCD)**; the acronym CRDB appears nowhere on it. Its USDA
source is the frozen legacy release — *"United States Department of Agriculture National Nutrient
Database for Standard Reference (USDA SR28)"* — not FoodData Central, and the Canadian file is pinned
at *"The Canadian Nutrient File (CNF 2015)"*. Both are superseded vintages, which sits awkwardly
beside the same page's *"removing … outdated entries"* claim and its *"most reliable data available"*
promise. That is a direct warning for §27: **a curated-first strategy inherits its upstreams'
staleness, silently.** (owner-supplied PDF: "Accurate Nutrition Database | Trusted Food Data Sources |
Cronometer", pp. 4–5;
[cronometer.com/features/accurate-databases.html](https://cronometer.com/features/accurate-databases.html))

**(b) Cronometer does not refuse submissions — it gates them.** *"Every item submitted to our database
undergoes a verification process, ensuring that the branded food entries you select are accurate and
up to date"* presupposes an inbound submission pipeline. Curated-first, in the market's most
accuracy-obsessed vendor, means **verify-before-publish, not decline**. Two caveats. The claim is
scoped to *branded* entries and states no mechanism, no criteria, no SLA and no rejection rate. And
**the two supplied Cronometer files are marketing pages, not the blocked `support.cronometer.com`
articles §38A asked for** — the photo-of-package requirement and the "curation team" quote in §15
remain unverified. Note also the soft spot in Cronometer's strongest line: the page claims
*"lab-analyzed data, not crowd-sourced guesses"* while its own list includes **Nutritionix** and the
**FDC Global Branded Food Products Database**, both predominantly label- or manufacturer-derived. Cite
that quote with the caveat, not as a clean precedent — a reviewer holding the same PDF finds the
tension in a minute.

**(c) MyFitnessPal's badge is weaker than its marketing, and MFP warns users about its own crowd
tier.** The green check certifies a **belief**, and merges two different populations — entries MFP
*reviewed* and entries MFP *added* — behind one mark, with no disclosed split, no criteria and no
reference standard. The article then silently upgrades that hedge in its advice sections to
*"reviewed and verified by MyFitnessPal"* and *"a reliable source"*; the strong wording appears
exactly where it does marketing work. **Treat "verified" as MyFitnessPal's marketing word, not its
definitional one.** Meanwhile MFP tells its own users, in its own voice, that *"you may come across
incorrect entries sometimes"*, lists *"Variability in user-submitted data"* as a bullet cause of
logging inaccuracy, and describes a moderation model that is entirely **reactive** — *"report it using
the 'Report a Food' feature… This will help flag an entry for our experts to review"* — while
**'remove', 'moderate' and 'duplicate' appear zero times** in the whole document. The largest crowd
database in the market publishes no removal process, names no staffing, and does not even claim to
dedupe. That is a first-party concession worth more than any third-party critique, and a design floor
low enough to clear. (owner-supplied PDF: "How MyFitnessPal's Food Database Works", pp. 4, 5, 11, 12)

**(d) The counter-argument the crowd tier actually wins, and this memo must meet head-on: coverage.**
MyFitnessPal's own answer to *"what if I can't find my exact food?"* is *"With over 20 million entries,
the database is incredibly extensive and may include a close match"* plus *"you can always add a food
that's missing"* (p. 11). **The crowd tier exists to guarantee a non-empty result.** Fitia — whose
whole thesis is that crowd data ruins accuracy — concedes it twice, recommending MyFitnessPal for
*"obscure ingredients where any other database is likely to come up empty"* and naming its own
weakness as *"Users who need the deepest long-tail coverage of obscure US restaurant items, where
MyFitnessPal's or Lose It!'s user-generated scale has the advantage."* §20 and §24 answer this
directly rather than leaving it for a reader to raise.

**The decisive industry datapoint.** MyFitnessPal — the canonical UGC food database — **licensed
curation to escape its own moderation bill.** Syndigo's own case study states: *"Since some of
MyFitnessPal's food database is crowdsourced, they sought to verify the information for accuracy… the
sheer volume of food entries to review proved to be burdensome,"* and quotes MFP's Joshua Klenk:
*"Because we trust the quality of Nutritionix food datasets, we don't need to dedicate the same
internal resources in our reviews"*
([syndigo.com case study](https://syndigo.com/resources/myfitnesspal-case-study/)).

**And the endgame.** On 17 March 2026 MyFitnessPal launched an advertising media network targeting on
*"explicit, declared first-party data including stated nutrition goals, dietary preferences, and
aggregated health and activity signals,"* across 5.7 million US free monthly active users and a
20-million-food database ([myfitnesspal.com/press](https://www.myfitnesspal.com/press)). That is what
eventually pays for a free crowd food database, and it is precisely what Fernlet's no-tracking wall
forbids in its first sentence.

---

## 14. The one tracker that publishes its ranking hierarchy puts your history first

This is the highest-value ranking change per line of code in the entire memo, and Fernlet has the
data and does not use it.

MacroFactor states its hierarchy verbatim
([macrofactorapp.com/logging-food](https://macrofactorapp.com/logging-food/)):

1. **From History** — "foods you have previously logged, which will always show up at the top of your
   search results if you have previously logged foods matching your query," justified because "most
   people frequently eat a lot of the same foods."
2. **Custom** — your own foods and recipes.
3. **Common** — research-grade rows, placed above branded because "most users log most branded foods
   via barcode scanning."
4. **Branded** — last, "typically generating the most numerous search results."

MacroFactor also ships **hourly go-tos** (foods weighted by frequency *and* time-of-day of past
logging), a **Latest** recency list, typo tolerance it advertises as "2–4 times faster," and
**"To Custom"** — a copy-on-write that forks a database row into a private editable copy, so a user's
serving fix never mutates the shared entry. Barcodes can be bound to a custom food: fix a bad scan
once, cached forever. Foodnoms markets the same idea as "Smart Suggestions," recommending foods based
on logging habits ([foodnoms.com](https://foodnoms.com/)).

**A correction to this section's original framing, applied 2026-08-22.** The heading used to read
"Everyone else ranks your own history first." **That is not supported as an industry consensus**, and
the owner-supplied first-party pages are why. It is verified verbatim for exactly one vendor —
MacroFactor — and asserted from marketing copy for Foodnoms. MyFitnessPal's own sixteen-page account
of its database **describes no ranking function whatsoever** (zero occurrences of rank, algorithm,
popular or frequency) and shows personal history as a **separate tab** — "All | My Meals | My Recipes
| My Foods", with a "History" list and a "Most Recent" sort control — i.e. history is *segregated from*
ranking, not blended into it (owner-supplied PDF: "How MyFitnessPal's Food Database Works", pp. 2, 4).
Cronometer's two supplied pages never mention search, ranking, recents or favourites at all.

**Fix 1.9 is unchanged and remains the highest value per line of code in the memo** — but it now
stands on MacroFactor's published hierarchy, on Fernlet's own comparator having no history tier, and
on the outcome evidence in §11 (successful loggers re-enter 2.4–2.7 times a day), **not** on an appeal
to what everyone does. If anything the incumbents' silence *strengthens* Q2: **ranking is an unclaimed
axis in the entire competitive set.**

**Fernlet's comparator has no history tier at all.** `FernletStore.dedupedRecentMeals` exists
(`App/Fernlet/FoodPlanning.swift:58-79`), is newest-first and case-folded with `limit: 8`, and feeds a
separate Recent-meals sheet that search never consults. On day 200, a user who has logged the same
yogurt every morning gets the identical generic ranking she got on day 1.

**One caveat that must not be dropped.** MacroFactor gives a *reason* for demoting branded rows —
barcode scanning covers them. Fernlet demotes branded for the same structural reason, but its barcode
path covers only **50,000 of 118,317** rows (42.3%), so the justification does not transfer.

---

## 15. What a submission gate actually looks like

If the owner ever does want user contribution, these are the mechanisms that ship in production — and
**four of the five need no server.**

**MacroFactor's exact contract** (2.7.0 release notes,
[macrofactorapp.com/changelog](https://macrofactorapp.com/changelog/)): *"Food submission is an opt-in
feature, and all of your custom foods are private by default."* / *"User-submitted entries will be
machine validated by us, and reviewed by the Open Food Facts community, but they are not guaranteed to
be manually verified by a human."* / On toggling off: *"Past foods you submitted will still remain in
the database, but your new foods and edits will remain private."* Submission requires brand, food
name, barcode, serving weight/volume, calories and macros, with an automatic plausibility check —
their published example is that 100 kcal with 300 g protein is rejected.

**Cronometer's gate** ([support.cronometer.com](https://support.cronometer.com/)): only *"common,
packaged, store-bought or restaurant food with nutrition information readily available"*; clear photos
of **both** the package front and the nutrition panel are required; *"every user submitted food is
reviewed by our curation team before being added."* Cronometer also offers **scoped private sharing
instead of a global publish** — Gold friend-to-friend, Pro coach-to-client.

**MyFitnessPal's automated pipeline** (US Patent 11,508,472 B2, assignee MyFitnessPal Inc, priority
2016-03-31, published 2022-11-22,
[patents.google.com/patent/US11508472B2](https://patents.google.com/patent/US11508472B2/en)): entries
are normalised, clustered by description string, and scored on **times-logged + number of distinct
users + intra-cluster nutrition similarity + public/private status**; the top-scoring record per
cluster becomes "verified"; missing nutrients are **back-filled by copying or averaging the top-ten
records in the cluster** — the patent's own worked example averages 16 g and 14 g of fat to get 15 g.
Sanity rules demote failures: non-negative; not all-zero (with a water/tea exception); **calories ≈
weighted macro sum within ±10%**; total fat ≥ trans + sat + poly + mono; total carbs ≥ fibre + sugar.
Deduplication runs on normalised edit distance — **0.3 merges clusters, 0.1 demotes a duplicate
verified item** — and clusters of 1–2 records get no verified item at all. The job runs periodically,
e.g. weekly.

**Evenepoel's plausibility caps — usable, but only after they are re-characterised.** The full text is
now in hand (owner-supplied PDF: Evenepoel et al., *J Med Internet Res* 2020;22(10):e18237,
[doi:10.2196/18237](https://doi.org/10.2196/18237)), and every number §16 carries is confirmed
verbatim against it. The complete rule set, stated **per logged food portion**, is eight one-sided
**upper bounds** and nothing else: **1,500 kcal energy, 95 g carbohydrate, 92 g fat, 52 g protein,
22 g fibre, 70 g sugar, 600 mg cholesterol, 3,600 mg sodium** (p. 1, repeated at p. 3). Three things
must be said before they are reused as a gate:

1. **They are one-sided, and applied at analysis time.** There is **no macro-sum check, no Atwater
   energy reconciliation, no per-100 g cap, no lower bound and no internal-consistency rule** anywhere
   in the paper. Do not attribute one to it.
2. **They are not physiological or regulatory.** They were curve-fitted on a training set to maximise
   agreement with the Belgian reference table: *"iteratively increasing the putative limit value…
   The nutrient intake value for which this correlation was maximal was defined as the upper limit"*
   (p. 3). 1,500 kcal or 3,600 mg of sodium in a *single portion* is near-inert on real food — which
   is consistent with the observed removals: carbohydrate alone accounted for 46 of 79, while fibre
   and energy triggered **zero** removals across all 2,826 items.
3. **They overfit.** Applying the frozen caps to the held-out set made two nutrients *worse* — protein
   fell from r = 0.94 to r = 0.90 and cholesterol from ρ = 0.67 to ρ = 0.51 — a regression the paper
   never acknowledges.

**So the design to copy is MyFitnessPal's five rules, not Evenepoel's ceilings.** The dominant crowd
failure mode is a **missing** field, not an inflated one (§16), and a ceiling is structurally blind to
a zero: an upper-bound-only rule would happily pass an entry claiming 0 g protein for chicken breast.
MFP's rules are internal-consistency checks — calories ≈ weighted macro sum within ±10%, total fat ≥
its own fractions, total carbs ≥ fibre + sugar, not-all-zero with a water/tea exception, non-negative —
and they catch both omission and impossibility. **All five are pure functions, need no server, and fit
the Power-of-10 ≤ 60-line rule.** Fernlet can ship them today against user-entered custom foods and
OCR-scanned labels: that is **fix 1.14 in §26**, and it belongs squarely in the *needs no new data*
tier. **The rules are described in a granted patent, which the owner asked about; §40 answers it.**
Short version: two of the five are in no claim of either patent in the family, and the other three are claimed only
inside a crowd-sourced curation pipeline Fernlet does not operate — so build them, but build them from the
pre-2016 public sources §40.4 traces them to, and never combine them with cross-device aggregation of
user-created food records (§40.8). Evenepoel's ceilings are still worth keeping as a cheap outer absurdity guard on a per-portion
value — provided they are labelled as exactly that, and never as a validated accuracy standard.

**The conclusion to draw:** a "verified" MFP macro can be a consensus of strangers' guesses, never
traceable to a label. Any provenance UI Fernlet builds should rank by **provenance class, never
popularity.** That reading is now corroborated from MyFitnessPal's own mouth rather than only from the
patent: the badge certifies that MFP *"believes that the nutrition information is accurate"*, and it
covers entries MFP merely **added** as well as entries it **reviewed**, with no disclosed split
(owner-supplied PDF: "How MyFitnessPal's Food Database Works", p. 4).

| Mechanism | Who ships it | Needs a server? | Fernlet status |
|---|---|---|---|
| Private-by-default custom foods | MacroFactor, Cronometer | No | `FernletKit/Sources/FernletDomainModel/CustomIngredientUpsert.swift:12-50` exists; reachable from only 2 of ~11 logging surfaces |
| Opt-in publish behind a plausibility gate | MacroFactor | Yes | N/A under this recommendation |
| Copy-on-edit ("To Custom") | MacroFactor | No | Absent; Adjust-meal Replace re-seeds quantity instead |
| Scoped sharing instead of global publish | Cronometer Gold/Pro | No | **Already built** — the signed/sealed proximity mesh |
| Bind-barcode-then-cache | MacroFactor | No | Partial: `CustomIngredientUpsert` remembers a barcode |
| MFP's five validation rules | MyFitnessPal | No | Absent; all are pure functions and all fit the Power-of-10 ≤ 60-line rule. **The design to copy** — see fix 1.14 |
| Per-portion absurdity ceilings (1,500 kcal / 95 g carb / 92 g fat / 52 g protein / 22 g fibre / 70 g sugar / 600 mg cholesterol / 3,600 mg sodium) | Evenepoel 2020's cleaning algorithm (research, not a shipped product) | No | Absent. Keep as an **outer guard only** — one-sided, curve-fitted, and structurally blind to omission |
| A nutrient **completeness** gate, and a completeness display on a resolved food | Nobody, explicitly | No | Absent. The failure mode §16 actually measures is **absence**, not inaccuracy — so this is the gate that matches the evidence, and it costs no data |

---

## 16. Macros survive a mediocre database; micronutrients do not

The measured evidence favours curation on **validity**, not just tidiness — and it says something
specific about *which* nutrients fail. Fernlet's curated USDA catalogue is **very likely** more
accurate than MyFitnessPal for micronutrients — but read the close of this section before quoting
that: it is an inference from source provenance, not a measurement of Fernlet's own file.

| Study | Design | Finding |
|---|---|---|
| **Evenepoel et al., JMIR 2020**, [doi:10.2196/18237](https://doi.org/10.2196/18237) — **now verified against the full text** (owner-supplied PDF) | 50 participants, two 4-day records a month apart; MyFitnessPal (then *"over 6 million food items and brands"*) vs the **1,194-item** Belgian Nubel table. **Both arms scored the *same* food registrations**, so portion and food-choice error cancels and the comparison isolates database content | Per-portion plausibility caps (**1,500 kcal, 95 g carb, 92 g fat, 52 g protein, 22 g fibre, 70 g sugar, 600 mg cholesterol, 3,600 mg sodium**) stripped values from **79 of 2,826 logged items (2.8%)** — carbohydrate 46, protein 17, sugar 8, cholesterol 3, sodium 3, fat 2, **fibre 0, energy 0**. After cleaning: r = 0.96 energy, 0.90 carb/fat/protein, 0.80 fibre, 0.79 sugar, no fixed or proportional bias on any of them — but **ρ = 0.51 cholesterol (77% under reference, mean difference −187 mg/day, SD 124, with proportional bias) and ρ = 0.53 sodium (51% under, −1,345 mg/day)**, plus a fibre fixed bias of *"about 4 g/day, which is about 20% of average fiber intake."* The power simulation is the sharpest statement of the split: *"the simulation showed a complete loss of power if MyFitnessPal would be used to assess cholesterol and sodium intake, resulting in extremely high sample sizes."* **The Bland-Altman limits of agreement exist only as dashed lines in a raster figure — there are no numeric limits in the paper to quote** |
| **Ho et al., JMIR mHealth 2024**, [doi:10.2196/54509](https://doi.org/10.2196/54509) | 836 food codes from 42 items across COFIT, MFP-Chinese, MFP-English and LoseIt!, vs USDA-FNDDS and the Taiwan FCD | Saturated fat underestimated **13.8–40.3%**; cholesterol **26.3–60.3%**. COFIT omitted **47%** of saturated-fat data; MFP-Chinese missed **62%** of cholesterol data. Coefficients of variation: beef **78–145%**, chicken 74–112%, seafood 97–124%, dairy cholesterol 71–118%, prepackaged 84–118%. **Errors persisted against both references — the app's core database is the source, not locale mismatch** |
| **Morello et al., J Hum Nutr Diet 2025**, [doi:10.1111/jhn.70148](https://doi.org/10.1111/jhn.70148) | 43 three-day records, two raters, MFP and Cronometer vs ESHA Food Processor + the Canadian Nutrient File | Cronometer: good-to-excellent inter-rater reliability for all nutrients, **good validity for all except fibre and vitamins A and D**. MyFitnessPal: **poor validity for total energy, carbohydrates, protein, cholesterol, sugar and fibre** |
| **Maringer et al., Public Health Nutr 2019**, [doi:10.1017/S136898001800157X](https://doi.org/10.1017/S136898001800157X) | 100 Dutch products barcode-scanned in 7 apps | Energy available for 99%, of which **79% within ±5%**. Identification rate: MyFitnessPal **96%**, SparkPeople **5%**. Structural conclusion: *"The presence of user-generated database entries implies that the availability of food products might vary depending on the size and diversity of an app's user base"* |
| **Banal et al., BMJ Nutr Prev Health 2024**, [doi:10.1136/bmjnph-2023-000770](https://doi.org/10.1136/bmjnph-2023-000770) | 37 Filipino adults with obesity; three dietitians re-entered the same records | Good inter-coder reliability, **poor validity** vs the Philippine FCT — underestimating energy, carbohydrate and fat, overestimating protein. **Reliability is not accuracy** |

**The mechanism is now known, and it is omission, not error.** Evenepoel names it directly: *"A reason
for the underestimation by MyFitnessPal is most likely incomplete or missing information about nutrient
composition for some food items in the database. Indeed, some entries in MyFitnessPal only have a value
for total energy content without values for macronutrient composition or cholesterol and sodium
content. Selecting such items for inclusion in the dietary record results in inaccurate information."*
(p. 7). The arithmetic confirms it: sodium ran **51% under** and cholesterol **77% under**, while the
plausibility caps removed only **3 values for each across 2,826 items** — **the ceilings caught
essentially none of the actual damage, because an absent field is low, never high.** The defensive
design that follows is therefore a **completeness gate and a completeness display**, not an accuracy
claim (§15; fix 1.14). It also suggests a display change with zero data cost: surface nutrient
*completeness* on a resolved food, not only its values.

**And the 2.8% is a coached floor, not a wild-condition error rate.** The researchers pre-registered
their own Nubel-sourced entries for common generic foods under a "Targid" tag — *"for standardization
purposes, as generic items often have multiple entries in MyFitnessPal with highly variable nutritional
information"* — told participants to prefer them, then to prefer green-flagged entries, issued an
illustrated manual on item selection and portion size, and asked them to weigh food. The authors
concede it drove the result: *"We assume that the high correlations between MyFitnessPal and Nubel
found in this study are partly due to the extensive manual that was provided to the participants and
the fact that we predefined a number of generic items."* The paper then supplies the uncoached
contrast — Chen et al. 2019, cited at p. 7, found naturalistic MyFitnessPal use gave 4-day mean energy
and macronutrient correlations of *"0.21 to 0.42"* against AUSNUT. **Same 6-million-entry corpus. The
entire swing from 0.21–0.42 to 0.79–0.96 is seeding, steering and selection — i.e. ranking and gating,
not rows.** That is the Q2 thesis, measured, and it is the strongest external evidence in the memo.

**What this section does establish.** The failure mode of crowd databases is exactly the layer USDA
covers well, and adopting a crowd corpus would trade Fernlet's strongest asset for its weakest need.

**What it does *not* establish, stated plainly so it is not overread.** First, **nothing in this
evidence tests Fernlet's own catalog.** "Already more accurate than MyFitnessPal for micronutrients" is
an inference from source provenance — CC0 USDA rows carry the full nutrient panel by construction — not
a measurement. Label it as such until the §25 corpus test is extended to nutrient completeness. Second,
and more importantly: **crowd *macro* data measures well.** 2.8% gross error; **zero** implausible
energy or fibre values across 2,826 items; r = 0.96 energy and r = 0.90 for all three macronutrients
with no fixed or proportional bias. Any framing in which crowd food data is simply junk is **refuted by
this memo's own cited study.** The case against hosting UGC is compliance, comparator inertness and an
absent user base (§20, §21) — **never data quality.**

---

## 17. Numbers that do not exist

Blunt and short, because a future reader will otherwise re-import these.

**Do not cite any of the following. They are fabricated.**

- "37% of popular food entries had energy errors exceeding 20%"
- "23.1% error rate" across MyFitnessPal's 20.5 M entries
- "packaged foods 11.2% error, restaurant items 38.4%"
- "a 2023 UNC study of 1,200 entries"
- "a 2019 *Nutrition Journal* study found errors in 27% of entries"

None could be located in Europe PMC by title, journal or subject search. All trace to competitor-app
SEO pages (calorie-trackers.com, nutrition-research-review.com, nutrola.app, caleye.fit,
amyfoodjournal.com, fitia.app). **Only the five studies in §16 are traceable.**

Also flag: MyFitnessPal's "over 14 million verified foods" is sourced only to a MyFitnessPal Facebook
post — do not use it to compute a verified/unverified split. The 20 M+ total *is* corroborated by the
March 2026 press release.

**Added 2026-08-22 — one more figure to blacklist, because it is now in the owner's own document pile
and will otherwise be imported.** *"User-generated content accounts for around 70% of [MyFitnessPal's]
database."* It comes from the Fitia comparison article, attributed only to unnamed *"outside
analyses"*, with no author, no date and no link (owner-supplied PDF: "MyFitnessPal vs. Lose It! vs.
Fitia: Database Compared", p. 4). It is unverifiable as printed; it is published by a direct competitor
on `fitia.app`, a domain **already named above as a fabrication source**; and that same article cannot
keep its own numbers straight — Fitia's database is *"more than 2 million foods"* on p. 5 and *"1M+"*
on p. 8, and its error illustration is *"30% or more"* on p. 4 and *"40%"* on p. 8. Treat the whole
document as a **vendor position paper** — it closes with *"use code FITIANOW to save 10%"* — never as
an independent comparison, and never as a source for a curated-versus-crowd ratio. Its one genuinely
useful line, the ranking quote in §1 and §20, is valuable precisely because it is a concession against
the publisher's own interest.

**And re-attribute the 20.5 M figure.** MyFitnessPal's own account of its database says *"over 20
million"*, twice, and **never 20.5 million** (owner-supplied PDF: "How MyFitnessPal's Food Database
Works", pp. 3, 11). The 20.5 M figure traces to MyFitnessPal's App Store listing, per the Fitia
article. Cite the App Store listing for it, not `blog.myfitnesspal.com`.

**One further caution about what first-party marketing pages can ever settle.** MyFitnessPal's page
carries **no curated-vs-crowd ratio in any form** — no counts, no percentages, no relative-magnitude
wording for any of its three tiers ("percent" occurs zero times; "majority" zero times). It also never
mentions duplicate entries, and never states whether a user-created food is public or private by
default. §38A's ratio row is therefore **closed as unmet**, not still open: the source was obtained and
does not carry the number.

---

## 18. The clause that kills every API

An offline-first app applies an unusual and decisive filter: **may the data live on the device
indefinitely?** Almost nothing survives it.

| Source | Licence / terms | Rate limits | May you bundle offline? |
|---|---|---|---|
| **USDA FoodData Central** | **CC0 1.0 Universal**, public domain. "USDA FoodData Central data are in the public domain and they are not copyrighted." Attribution *requested*, not required ([fdc.nal.usda.gov](https://fdc.nal.usda.gov/)) | 1,000 req/hr/IP with a data.gov key; DEMO_KEY 30/hr and 50/day; HTTP 429 on exceed | **Yes, unconditionally.** The only large food dataset with no attribution or share-alike obligation |
| **Open Food Facts** | Database ODbL 1.0; contents DbCL; **product images CC-BY-SA** (a separate share-alike regime with per-image author attribution); "Derivative works must be shared under the same conditions"; OFF "does not guarantee the accuracy" ([openfoodfacts.org/terms-of-use](https://world.openfoodfacts.org/terms-of-use)) | No key for reads. **User-Agent `AppName/Version (ContactEmail)` mandatory.** 15 req/min/IP product reads, 10 req/min/IP search, enforced by IP ban. v3 current, v2 deprecated. Writes require authentication | Yes, **but** ODbL §4.4(b)+(c) and §4.6 attach to the shipped artifact. See below and §27 |
| **FatSecret** | §1.5: must remove or re-request any content not "storable indefinitely" **within 24 hours**; the storable list is 11 identifier fields only (auth_secret, auth_token, exercise_id, food_category_id, food_entry_id, food_id, recipe_id, recipe_types, saved_meal_id, saved_meal_item_id, serving_id). §1.3 requires attribution "in every place that Content is provided or displayed." §1.2: the app "must not operate only behind a firewall or only on an internal network." §1.7(iii) forbids using it "to provide diet, nutrition or health advice, guidance or diagnosis" **and** requires you to "make clear that any information generated using the fatsecret Platform API should not be interpreted as a substitute for medical physician consultation" ([platform.fatsecret.com](https://platform.fatsecret.com/)) | §1.4: 5,000 calls/day (Basic); Premier Free unlimited but US-only and attribution-required | **No.** Non-compliant by construction |
| **Edamam** | Caching permitted for **six fields only** — FoodId, Food Label, Protein, Net Carbs, Total Fat, Kcal — on Core/Plus only. "Saved data can be used only in the end user's account, behind a password." "The data caching described here does not constitute permission to copy or reuse the Edamam data." Attribution with a supplied image + link required on all plans ([developer.edamam.com/faq](https://developer.edamam.com/faq)) | 50 / 100 / 300 req/min for Basic / Core / Plus | **No** |
| **Spoonacular** | "You may cache user-requested data to improve performance (for a maximum of 1 hour). After 1 hour, you must delete your cache and refresh the data via the spoonacular API"; mandatory cache deletion on suspension ([spoonacular.com/food-api/terms](https://spoonacular.com/food-api/terms)) | Free 50 points/day @ 1 req/s; Cook $29/mo 1,500 @ 5 req/s; Culinarian $79/mo 4,500 @ 10; Chef $149/mo 10,000 @ 20; Enterprise from $300/mo | **No** |
| **Nutritionix / Syndigo** | **Now read at the primary source** (owner-supplied PDF: "Nutrition API by Nutritionix", pp. 1–3; [nutritionix.com/api](https://www.nutritionix.com/api), captured 2026-08-22). Four tiers, **all billed annually** — *"API plans are billed annually"*: Business Trial **FREE**, Starter **$499/mo**, MVP **$999/mo**, Unicorn **"starting at $1850 /Month"**. An explicit **"Caching Allowed"** feature row: ✗ / ✗ / **✓** / **✓**. Attribution: Required / Required / Required / *"Removable Option"*. **Natural Language Engine: ✓ / ✗ / ✓ / ✓ — the $499 tier does not include it.** Non-commercial and student free trials discontinued: *"we no longer offer non-commercial free trials."* Bulk licensing is still only *"Interested in bulk database licensing? Please contact us."* Provenance claims: *"Our registered dietitian team started with the USDA database and supercharged it"*; 1 M+ grocery barcodes and **203 K restaurant foods** (an item count, not a chain count; **no chain is named**) | **Metered by monthly active users, not calls** — *"Active Users (MAU) … up to 2 … up to 200 … up to 1000 … Customizable"* — with **no published call limits at all**. Free and freemium apps are off the published list: *"If you have a freemium app business model… please contact us to discuss a customized pricing plan"* | **Caching is affirmatively permitted at ≥ $999/mo — but its scope is undefined.** The page never says what "caching" covers: no retention period, no distinction between transient response caching and a durable local store, nothing about shipping an offline copy. The row's definition sits in a hover tooltip that did not survive print-to-PDF, and the binding terms are Syndigo's, at `syndigo.com/legal/terms-of-use`, **not supplied**. So: **not "killed by caching terms" — open, and settleable by one written question (§37).** Two harder constraints remain: 1,000 MAU is the ceiling on the top *published* tier, and Fernlet is always-free by a locked decision, so **there is no published price for Fernlet's shape at all**. Attribution is also mandatory on every tier below $1,850/mo — a privacy-first app would ship UI naming its data vendor |
| **MenuStat** | **CC0 1.0** on Harvard Dataverse, [doi:10.7910/DVN/K4NYTR](https://doi.org/10.7910/DVN/K4NYTR), "MenuStat Annual Data", Cleveland, Lauren, 2022. 8 TSV files: 2008 (2.7 MB), 2010 (2.4), 2012 (5.4), 2013 (9.6), 2014 (14.0), 2015 (16.8), 2017 (26.6), 2018 (27.3) — **104.8 MB total**. 2016 and 2019–2022 exist only in Wayback captures. 96 chains, 71,172 rows in the 2018 file | — | Yes — **but contains no warehouse clubs.** Verified: zero Costco matches in both the Dataverse and NYC Open Data (`qgc5-ecnb`) mirrors. `menustat.org` returns **DNS SERVFAIL** as of 2026-08-22 |
| **Australian AFCD / AUSNUT 2023** | **CC BY-SA 3.0 AU** — ShareAlike. Has a real Food Measures file (9,816 measures) ([foodstandards.gov.au](https://www.foodstandards.gov.au/)) | — | Legal but **contaminating**: "You may only distribute a Derivative Work if You apply this Licence Agreement to it" |
| **Canadian Nutrient File** | Open Government Licence – Canada; attribution required ([canada.ca CNF](https://food-nutrition.canada.ca/cnf-fce/)) | — | Yes, with a notice |
| **UK CoFID** | Open Government Licence v3.0; ~2,887–2,898 foods, ~185 nutrients. **No household-portion / gram-weight table** ([gov.uk CoFID](https://www.gov.uk/government/publications/composition-of-foods-integrated-dataset-cofid)) | — | Yes, with a notice |

**What the offline filter proved.** The filter this section opens with — *may the data live on the
device indefinitely?* — turned out to be **exactly the line item Nutritionix prices.** A vendor
comparison table carrying a row literally called "Caching Allowed", gated at $999/month, is the
strongest available confirmation that **offline-copy rights are the axis vendors actually price on**,
and it converts a total unknown into a bounded one. The consequence for §19 is that the licensed-vendor
corner stays at *Investigate only* for a **new and better reason** than before: not because caching is
forbidden, but because the meter is monthly active users, the top published tier tops out at 1,000 of
them, and a free app is excluded from the price list altogether. Any cost model built on "$499" — or
even "$999" — would be analysing a tier Fernlet cannot buy.

**The ODbL clauses that govern the one realistic import**
([opendatacommons.org/licenses/odbl/1-0](https://opendatacommons.org/licenses/odbl/1-0/)):

- **§4.4(b):** *"For the avoidance of doubt, Extraction or Re-utilisation of the whole or a Substantial
  part of the Contents into a new database is a Derivative Database and must comply with Section 4.4."*
  Note the load-bearing qualifier **"Substantial"** — ODbL defines it only as "substantial in terms of
  quantity or quality or a combination of both," with no numeric threshold. A bulk US-slice import is
  clearly caught; a few-hundred-row curated extract arguably is not.
- **§4.4(c):** *"A Derivative Database is Publicly Used and so must comply with Section 4.4. if a
  Produced Work created from the Derivative Database is Publicly Used."*
- **§4.5(b):** *"Using this Database, a Derivative Database, or this Database as part of a Collective
  Database to create a Produced Work does not create a Derivative Database for purposes of Section
  4.4."* — **share-alike does not reach the Swift source.**
- **§4.6:** you must offer *"a copy in a machine readable form of: a. The entire Derivative Database;
  or b. A file containing all of the alterations made to the Database or the method of making the
  alterations to the Database (such as an algorithm)… free of charge if distributed over the
  internet."* **Option (b) — publishing the generator script — is the low-cost route, and
  `Scripts/branded-catalog/` already establishes that pattern.**
- **§4.3(a) attribution safe harbour:** *"Contains information from DATABASE NAME, which is made
  available here under the Open Database License (ODbL),"* placed so as to make anyone "exposed to the
  Produced Work aware" of source and licence — i.e. **in-app, not only in the repo.**

---

# PART IV — THE UGC QUESTION

## 19. "An online database of food uploaded by users" is three decisions

The phrase silently fuses three independent choices. Only the most expensive corner has been examined;
the cheap corners were never priced against it.

| Online? | Crowd or curated? | Global or personal? | Example | Cost | Verdict |
|---|---|---|---|---|---|
| Offline | Curated | Personal | Local correction memory, private custom foods | ~0 | **Do this** |
| Offline | Curated | Global | Bundled FNDDS layer (CC0) | Bytes + a build-time script | **Do this** |
| Offline | Curated | Global | Bundled OFF snapshot | Bytes + ODbL share-alike on the artifact | Optional, later |
| Offline | Crowd | Personal | — | — | Degenerate |
| Online | Curated | Personal | The existing web lane, prompted at first miss | Already built | **Do this** |
| Online | Curated | Global | Licensed vendor (Nutritionix bulk) | API tiers now priced — $499 / $999 / $1,850+ per month, **billed annually**; caching allowed at **≥ $999/mo with undefined scope**; metered at **1,000 MAU** on the top published tier; **a free app is off the price list entirely**; bulk-database licensing still unpriced; attribution required below $1,850/mo; new destination; contract (§18) | Investigate only |
| Online | Crowd | Personal | Contribute upstream to OFF from within the app | New authenticated network seam; breaks the `EphemeralWebSession` invariant | Defer |
| **Online** | **Crowd** | **Global** | **The tester's suggestion** | **A server, accounts, DSA hosting status, App Store 1.2, moderation labour, a GDPR erasure conflict** | **No** |

---

## 20. More rows through this comparator makes results worse

The upside bound is measured: **~3%** (§10).

The downside is also measured. `cheese pizza slice` returns six branded rows today, **two of which
score −82**, with no score floor and no visual distinction from a real hit. Every additional row that
clears the boolean AND gate becomes eligible for the top-6 regardless of score. A crowd corpus
multiplies exactly this population.

**Expected value on the current ranking stack: roughly zero upside, measurable downside in junk
density.** The prerequisite for any corpus expansion — curated or crowd — is a score floor plus
score-above-data-type ordering. **Ship those, re-measure, then decide about data.**

There is also a structural argument from the literature, and it is the sharpest one against a Fernlet
UGC pool specifically. Maringer 2019, verbatim: *"The presence of user-generated database entries
implies that the availability of food products might vary depending on the size and diversity of an
app's user base."* A no-account app has no user base to harvest. A Fernlet UGC pool would therefore be
**sparse** — the worst quadrant of §19, carrying crowd-sourcing's ordering and compliance costs with
none of its scale.

**What this argument is not, corrected 2026-08-22.** It is **not** "crowd data is junk." This memo's
own strongest cited study refutes that: after a 2.8% gross-error clean, MyFitnessPal's crowd corpus
correlated with a national food composition table at **r = 0.96 for energy and r = 0.90 for all three
macronutrients, with no fixed or proportional bias**, and **zero** implausible energy or fibre values
across 2,826 items (§16). Crowd *macro* data is good. What fails is micronutrients, and it fails by
**omission** rather than error. So the objection above is precisely about **junk density in a
comparator that has no score floor and sorts data type above relevance** — an *ordering* problem — plus
the compliance surface in §21 and the absent user base. **Those are the three planks. Data quality is
not one of them, and any wording elsewhere in this memo that leans that way should be read as
retired.**

**The same point, from the other direction, is the strongest evidence for Q2 in the entire memo.**
Evenepoel's identical 6-million-entry corpus produced **r = 0.21–0.42** for uncoached users and
**r = 0.79–0.96** once the researchers seeded authoritative entries, steered users toward them and
toward verified-flagged rows, and taught portion estimation. The corpus is a *constant* across both
studies. **Corpus size is not the variable that moves accuracy in the literature either** — the same
finding as §10's measured 3%, arrived at independently and from outside.

**And the honest cost of saying no.** The crowd tier's real product is **coverage**, and both
incumbents say so plainly (§13): MyFitnessPal's answer to a missing food is *"you can always add a food
that's missing"*, and even Fitia concedes that user-generated scale wins on *"obscure US restaurant
items."* Harvard Health's dietitian guidance, meanwhile, instructs readers to record preparation
method, sauces, condiments, dressings, toppings, and branded drink type and size (owner-supplied PDF:
McManus, *"Why keep a food diary?"*, Harvard Health Publishing, 2019-01-31, pp. 3, 5;
[health.harvard.edu](https://www.health.harvard.edu/blog/why-keep-a-food-diary-201901165781)) —
**exactly the long tail a curated catalogue covers worst.** Declining a hosted UGC pool therefore means
**accepting that the long tail of obscure branded and restaurant items will sometimes return nothing.**
That is what makes the empty-state work in §11 and the local correction memory in fix 1.10
**load-bearing compensation rather than polish**: together they convert *"we returned nothing"* into
*"we returned nothing once, and never again for you."* It also sharpens §12 — the consent-prompted web
lane **is** the coverage answer, and the miss is exactly the moment to offer it.

---

## 21. The bill, itemised

This is where the "just let people upload" instinct dies. Every row is a real obligation with a
citation.

| Obligation | Source | The detail that bites |
|---|---|---|
| **Accounts** | Apple, CloudKit | The public database "is always readable, even when the user is not signed in… Saving records to the public database… requires that the user be signed in." **Anonymous writes are structurally impossible.** The site's "No account, no login" promise (`Site/index.html:335`) dies at line one |
| **Attribution linkage** | CloudKit | `creatorUserRecordID` is stable per container and cannot be disabled. Every submission a person ever makes is permanently linkable to every other, and correlatable with their existing heart-send timeline (`Docs/No-Tracking-Wall.md` §6) |
| **Unpriced liability** | Apple DTS | Ziqiao Chen, Worldwide Developer Relations, Jan 2025: *"Regarding CloudKit public database, we currently don't have the pricing information available to public, and so I'd suggest that you file a feedback report."* Apple's marketing page publishes only "up to 1PB of storage for your app's public data," and **Apple's own allowances page now returns 404**. The historical quota/overage figures circulating in the community are mutually inconsistent and must not be used for a cost forecast |
| **No server-side validation** | CloudKit | No triggers, no functions, no server-side rate-limit hooks. You cannot reject a 9,000-kcal apple, cannot dedupe on write, cannot rate-limit a contributor. Every control is client-side and bypassable, or manual via a server-to-server key — which means standing up a moderation backend anyway |
| **App Store Guideline 1.2** | [developer.apple.com/app-store/review/guidelines](https://developer.apple.com/app-store/review/guidelines/#user-generated-content) | Four requirements, verbatim: *"A method for filtering objectionable material from being posted to the app; A mechanism to report offensive content and timely responses to concerns; **The ability to block abusive users from the service**; **Published contact information so users can easily reach you.**"* Enforcement: *"your app may be removed from the App Store until you can demonstrate improvements… Egregious or repeated behavior is grounds for immediate removal of your app from the App Store, and from the Apple Developer Program."* **A no-account app cannot block a user — there is no identity to block.** And "published contact information" is a doxxing surface on an app that also ships period and intimacy tracking |
| **Guideline 1.4.1** | Same | Medical apps *"that could provide inaccurate data or information… may be reviewed with greater scrutiny,"* and *"if the level of accuracy or methodology cannot be validated, we will reject your app."* A curated USDA catalogue has a disclosable methodology; a crowd average does not |
| **Guideline 5.1.1(v)** | Same | In-app account deletion is mandatory once you support account creation; *"only offering to temporarily deactivate or disable an account is insufficient."* In force since June 30, 2022. This collides head-on with an append-only shared database |
| **DSA Article 16** | [EUR-Lex 2022/2065](https://eur-lex.europa.eu/eli/reg/2022/2065/oj) | All hosting providers must *"put mechanisms in place to allow any individual or entity to notify them of the presence… of illegal content,"* processed *"in a timely, diligent, non-arbitrary and objective manner."* **No micro/small exemption** — Article 19's carve-out covers Section 3 only |
| **DSA Article 16(3)** | Same — **corrected quote** | Notices *"shall be considered to give rise to actual knowledge or awareness for the purposes of Article 6 in respect of the specific item of information concerned **where they allow a diligent provider of hosting services to identify the illegality of the relevant activity or information without a detailed legal examination.**"* A notice does **not** automatically strip the shield — the source research truncated this and overstated it |
| **DSA Article 13** | Same | A non-EU provider must designate an EU legal representative; *"It shall be possible for the designated legal representative to be held liable for non-compliance with obligations under this Regulation."* Article 13(4) additionally requires notifying the Digital Services Coordinator with name, address, email and phone, kept publicly available. **No micro/small carve-out. This is a recurring paid engagement, not a one-off filing** |
| **GDPR Article 17(2)** | [EUR-Lex 2016/679](https://eur-lex.europa.eu/eli/reg/2016/679/oj) | Having made data public, you must take *"reasonable steps, including technical measures"* to inform other controllers of an erasure request — *"taking account of available technology and the cost of implementation."* Once mirrored, un-publishing is not meaningfully possible |
| **GDPR Article 9** | Same + CJEU C-184/20 | Food queries are special-category **by inference** — halal/kosher → religion; prenatal vitamins → pregnancy; glucose tablets → diabetes. CJEU C-184/20 (*OT v Vyriausioji tarnybinės etikos komisija*, 1 Aug 2022) held that data indirectly revealing a special category is itself special-category. **Present as a well-supported reading, not a per-se statutory rule** |
| **CDA 230 exposure** | [47 U.S.C. §230](https://www.law.cornell.edu/uscode/text/47/230) | §230(c)(1) protects hosting third-party data; but §230(f)(3) defines an "information content provider" as anyone *"responsible, **in whole or in part**, for the creation or development of information."* Merging or averaging submissions into one authoritative figure risks co-development. **Whether averaging nutrition values crosses that line has not been litigated** — a grounded caution, not settled law |
| **Product liability** | *Winter v. G.P. Putnam's Sons*, 938 F.2d 1033 (9th Cir. 1991) | The informational content of a book is not a "product"; publishers owe no duty to investigate accuracy. **But** the court noted Putnam neither wrote nor edited, and expressly distinguished charts: *"The chart itself is like a physical product while the How to Use book is pure thought and expression."* **An app-authored, app-curated nutrition figure sits closer to the chart line** |
| **EU PLD 2024/2853** | [EUR-Lex 2024/2853](https://eur-lex.europa.eu/eli/dir/2024/2853/oj) | Art. 2(1): applies to *"products placed on the market or put into service after 9 December 2026."* Art. 4(1) defines "product" to include *"software."* Art. 2(2): *"This Directive does not apply to free and open-source software that is developed or supplied outside the course of a commercial activity."* **The exclusion turns on "commercial activity," not price** — the always-free, DSA-non-trader posture is load-bearing. (Do **not** cite the "mobile health application" recital — it could not be located; Recital 13 covers software generically) |
| **FTC Health Breach Notification Rule** | [Federal Register, 2024](https://www.federalregister.gov/documents/2024/04/26/2024-08750/health-breach-notification-rule) | Amended rule effective 29 July 2024, expressly reaching health apps outside HIPAA. A server-side food DB keyed to identity brings identifiable health information onto the developer's infrastructure and into scope |
| **CCPA/CPRA** | California | Thresholds: $26,625,000 annual gross revenue (2026 adjusted), or personal information of 100,000+ California consumers/households, or 50%+ of revenue from selling/sharing PI. **A free solo app meets none** — not the binding constraint |
| **DSA trader status** | [developer.apple.com trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-trader-status) | *"Since February 17, 2025 — Apps without trader status will be removed from the App Store in the European Union (EU) until trader status is provided and verified."* And: *"if you're a hobbyist and you developed your app with no intention of commercializing it, you may not be considered a trader."* Individual traders must publish address or P.O. Box, phone number and email |
| **Infrastructure** | — | Hetzner CX22 ~€4/mo; DigitalOcean managed Postgres ~$27/mo composite. **UNVERIFIED** (Hetzner's price table renders client-side). Irrelevant either way — **infrastructure is not the binding constraint; the compliance surface is** |
| **Moderation labour** | [Open Food Facts](https://world.openfoodfacts.org/); MyFitnessPal's and Cronometer's own pages (owner-supplied PDFs) | The leanest serious operation in the space: ~7 permanent team members for 4.7 M products with volunteer topic teams, ~8 million monthly visitors, and an open ask for €120,000 to complete 2026 funding. **Two new datapoints bracket the range, and neither vendor publishes headcount.** At the top: MyFitnessPal — with an ad network and 5.7 M US monthly active users — ships **no removal process, no dedup claim, no SLA and no named team**; its entire disclosed model is a user-triggered *"Report a Food"* queue reviewed by an undefined *"our experts"*, and 'remove', 'moderate' and 'duplicate' appear **zero times** in its own account of the database. At the bottom: Cronometer frames curation as a **permanent operating obligation**, not a one-time seed — *"By consistently removing duplicate foods and outdated entries"* — where the recurring verbs are **dedup and retirement**, the expensive half of curation and the half easiest to under-budget. Note Cronometer sells both as a **user-experience** win ("we make choosing the right foods easy"), not as an accuracy one — a directly transferable argument for fixes 1.7 and 1.8 |

**One thing this memo will not claim.** The widely repeated "Apple requires objectionable UGC to be
removed within 24 hours and the offending user ejected" standard **appears nowhere in the published
text of Guideline 1.2** (confirmed by direct reading). Its only support is App Review rejection-letter
templates reproduced on third-party blogs. Treat it as an unverified norm; **never cite it as a rule.**

---

## 22. The walls, and where a UGC feature would hit each one

Honest in both directions — including the uncomfortable finding that the walls would **not** catch a
CloudKit-based implementation.

| Wall | Mechanism | Would a UGC food DB trip it? |
|---|---|---|
| **No-tracking — destinations** | `NoTrackingBoundaryTests.permittedDestinations` is exactly five hosts (`html.duckduckgo.com`, `duckduckgo.com`, `example.com`, `www.apple.com`, `fernlet-prototype.invalid`), and fails in **both** directions | An HTTP endpoint: yes. **A CloudKit endpoint: no** |
| **No-tracking — clients** | `hostsInClients == ["duckduckgo.com", "html.duckduckgo.com"]`, an **exact set equality** on the pinned importer files (`Tests/FernletTests/NoTrackingBoundaryTests.swift:517`) | A new HTTP client must be added to `pinnedWebImporterFiles` |
| **No-tracking — session** | `EphemeralWebSession` sets seven privacy knobs (cookie policy `.never`, nil cookie storage, `httpShouldSetCookies` false, nil `urlCache`, `reloadIgnoringLocalAndRemoteCacheData`, nil `urlCredentialStorage`, plus `timeoutIntervalForResource`); `URLSession.shared` / `.default` banned in shipping code | **`urlCredentialStorage = nil` and `httpCookieStorage = nil` make authenticated contribution structurally hostile** — an OFF write would need a bearer token on every request |
| **No-tracking — dependencies** | Exact-set match; CryptoSwift only | Any SPM package fails CI until allowlisted **and** documented in the same commit |
| **No-tracking — CloudKit** | Only `allowedICloudContainers == ["iCloud.MBO.Fernlet"]` (`NoTrackingBoundaryTests.swift:346`) — **`CKContainer` / `CKDatabase` / `CKRecord` are not HTTP-client markers, and Apple frameworks carry no host literal** | **THE BLIND SPOT.** Shipping a `CommunityFoodRecord` into `container.publicCloudDatabase` would pass **all eight** no-tracking tests unchanged. Nothing would go red |
| **S3 wall** | Sealed `Private*` stores | Food is not a sealed category; `CloudKitSync` may legitimately touch it. **No help here either** |
| **Privacy Policy §1/§8/§12/§13** | Three pinned copies + `PrivacyPolicyParityTests`; effective date August 20, 2026 (`App/Fernlet/PrivacyPolicyView.swift:39`) | §13's perpetual promise requires "fresh, affirmative consent" for any new egress of existing data; "Continued use, silence, or installing an update is never consent." **A UGC feature could only ever cover foods created after fresh consent — no backfill** |
| **Persisted-surface wipe wall** | Any new UserDefaults key needs a disposition row in `Docs/PrivacyWipeCoverage.md` in the same commit | An upload outbox, a consent latch, and a contribution ledger each need one |
| **Delete-everything** | Enumerates by CloudKit record type | Contributed rows inherit the heart-drop hole: **creator-only delete, no server-side TTL**, and other users already hold local copies. "Delete Everything" would stop meaning what it says |
| **CloudKit schema deploy** | Production promotion is an owner console action; **deployed record types are additive-only and permanent** | A `CommunityFoodRecord` could never be removed or retyped |
| **Localization wall** | Tokens frozen English; display via `LocalizedStringKey` | A brand/unit lexicon is a **matching input** → frozen English forever |
| **Power-of-10** | ≤ 60 code lines per function/`body`, bounded loops, no recursion, no `!`/`try!`/`as!`/`fatalError`, no swallowed `try?` | Applies to every fix in Part V; MFP's five validation rules are pure functions and fit comfortably |
| **FernletDomainModel clean-build hazard** | Enum/struct changes need a CLEAN build | A new `FoodItemSource` case or `FoodDataType` case triggers it, plus the `EnumDecodeCompat` freeze/park pattern |

**The recommendation that follows from the blind spot.** If any public-database feature is ever built,
**extend the wall in the same commit** — pin the set of permitted public-database record types the way
`permittedDestinations` pins hosts. Otherwise the app's central verifiability claim — *every byte that
leaves the device is enumerable, and enumerated* — silently degrades.

---

## 23. Three seams already built

The privacy-compatible version of "share food data" is not a new subsystem. It is three existing seams
plus one generalisation.

**1. The sealed proximity mesh.** Recipes, clothing and friend photos already move this way — signed,
sealed, peer-to-peer, between people who met in person. A shared custom food is the same envelope with
a different payload. Nothing is stored at the provider's request, so the DSA's hosting definition
("storage of information provided by, and at the request of, a recipient of the service") is a poor
fit. **Flag: this is reasoning from the text, not settled authority** — and the CloudKit-transited
E2EE dead-drop is the harder case.

**2. `DiaryStore.cachedWebImportedFoodProduct`** (`FernletKit/Sources/DiaryStore/DiaryStore.swift:1429-1437`)
already implements a normalised-query → `FoodItem` lookup via a `web-query:<normalized>` tag. **That is
a persisted, synced, wipe-covered query-alias table hiding in the tags array**, used today for one
narrow purpose. Generalising it is the local correction memory in §26 (fix 1.10).

**3. `CustomIngredientUpsert.resolve`**
(`FernletKit/Sources/FernletDomainModel/CustomIngredientUpsert.swift:12-50`) already de-dupes by
normalised name against existing `.manual` foods, preserving stable ids, previously scanned
micronutrients and a remembered barcode. It is reachable from only two of ~11 logging surfaces.

**4. `NutritionLabelScanner`** — a Vision-based parser already extracting serving size, servings per
container, calories, all three macros and ~20 micronutrients, wired into `FoodCaptureRouter`. This is
the honest answer to the Costco slice specifically: 21 CFR 101.11 entitles the member to the full
11-nutrient panel **in written form on the premises, on request**, and the menu board already carries
calories. Pointing the existing scanner at a menu board is fully offline — zero network, zero ToS
surface, zero licence — and **more accurate than any database**, because it reads today's posted
values at that location.

**Two external corroborations that portion handling, not corpus content, is the dominant end-to-end
error term.** Evenepoel cites a PDA-versus-dietitian study in which *"portion size [was] the greatest
source of error, accounting for 49% of the errors between recorded and actual meals,"* with
*"reporting incorrect food (25%) and omitting food (15%)"* behind it (owner-supplied PDF: Evenepoel
2020, p. 7). Independently, Steenhuis & Poelman, *"Portion Size: Latest Developments and
Interventions,"* Curr Obes Rep 2017;6:10–17,
[doi:10.1007/s13679-017-0239-x](https://doi.org/10.1007/s13679-017-0239-x) (owner-supplied PDF), report
that *"People have difficulties in estimating amounts of food and, moreover, are unaware of reference
portion sizes,"* and that distraction degrades the estimate further. **That raises the value of §1's
slice and gram-weight findings relative to any corpus-expansion work** — 468 rows mention a slice
portion, 194 portion entries have unit exactly `slice`, and the `RecipeUnit` slice/piece gap (fix 2.4)
blocks all of them today. **Scope note, so neither source is over-cited:** the Steenhuis review is
about the portion-size effect on energy intake and population-level interventions, and mentions no
apps, databases, search or logging anywhere; it is cited here for the human-estimation finding only.

---

## 24. Q1: no

**No** to the online / crowd / global corner of §19.

**Yes** to all of the following, which together serve the need the tester actually had:

- private-by-default custom foods, reachable from every logging surface;
- local correction memory, so a query she fixes once is self-healing thereafter;
- peer-scoped sharing over the sealed mesh that already ships;
- a CC0 FNDDS import, which is a bigger, better, free, obligation-free database;
- a consent prompt at the moment of first miss, turning on the web lane the app already ships.

**And the thing this answer costs, stated plainly.** No hosted UGC pool means **accepting that the
long tail of obscure branded and restaurant items will sometimes return nothing** — the one axis on
which both incumbents, *including the vendor selling curation*, concede that crowd scale genuinely wins
(§13, §20). That is a real cost, not a rounding error. It is precisely why the empty-state work in §11,
the local correction memory in fix 1.10, and the consent-prompted web lane in §12 are load-bearing
compensation rather than polish.

**The tester asked for more foods. What she actually experienced was a wrong answer delivered
confidently. Those are different problems, and only one of them is fixable by adding data.**

That diagnosis also survives the strongest counter-evidence in the owner-supplied pile, which a reader
will otherwise find and raise. MyFitnessPal's own stated philosophy de-prioritises precision — *"It's
often better to strike a balance between accuracy, consistency, and your sanity"* — and the behavioural
literature agrees: *"the accuracy and completeness of self-monitoring diaries are not as important as
the frequency with which they are completed"* (Harvey et al. 2019 relaying Helsel 2007; owner-supplied
PDF, p. 2). Both are arguments about **consistency**, and **a confidently-wrong committed diary entry
is exactly the thing that ends consistency** — so they reinforce the diagnosis above rather than
undercutting it. What they *do* win is a different point, and this memo concedes it: **database
accuracy should never be Fernlet's competitive axis**, and the §11 surface fixes plus history-first
ranking (1.9) outrank the accuracy fixes on outcome grounds. The order in §30 already reflects that.
Two caveats on the counter-evidence itself: the outcome in both sources is weight loss, which Fernlet
explicitly does not optimise for, and MFP's supporting *"seven times more likely to show progress"*
statistic is first-party, uncited, correlational and self-selected for motivation.

---

# PART V — WHAT TO DO

## 25. Tier 0 — instrument first

Everything measured in this memo came from a 57-query benchmark built in an afternoon. Landing it as a
Swift test is the missing instrument, and without it the coupled fixes in §26 cannot land safely.

`FoodCatalogTests.sqliteSearchMatchesInMemoryScorer`
(`Tests/FernletTests/FoodCatalogTests.swift:98-107`) only asserts that FTS and the Swift scorer agree
**with each other** — and both agree on the wrong order. The two shipped-catalog tests silently
`return` (pass) when the DB is absent, guarded on `source.count > 50_000`
(`Tests/FernletTests/FoodSearchLabelAndFallbackTests.swift:118`, `:124`). `FoodCatalogTests.swift` is
250 lines.

Nothing in CI exercises: the source/data-type-above-score comparator on a mixed-type result set; the
brand-query flip; a 3+ token query; a query with an unmatched token; the branded ODR 600-cap ordering;
`minimumQueryLength`; or any score-value assertion at all.

**What to land:** query → expected top-1, or expected non-empty, over the 57-query corpus in
Appendix A. **This is a prerequisite, not a nice-to-have** — §29 demonstrates concretely that the
fixes regress each other.

---

## 26. Tier 1 — fixes needing NO new data

Fourteen changes — 1.1–1.13 as originally listed, plus **1.14** added on 2026-08-22 from the
owner-supplied Evenepoel full text and MyFitnessPal patent rules. No new bytes, no new destination, no
new dependency, no wall amendment.

| # | Fix | Where | Effort | Expected effect | Risk |
|---|---|---|---|---|---|
| **1.1** | **Stop hardcoding `.high` on the lexicon tier.** Derive confidence from bind quality: `.high` only when every component clears `confidentBindScore`; `.medium`/`.low` otherwise. Any non-high flips `needsReview` and routes through the existing "Check this meal" sheet | `MealResolutionService.swift:148-149` | S | **THE HIGHEST-LEVERAGE FIX.** The user would have seen the 3-ingredient decomposition BEFORE it counted toward the day's macros. Converts a silent wrong answer into a reviewable one | Low, but UX-visible: more quick-logs pause at review. Requires threading a bind-quality summary out of `DishTemplateLexicon.resolve` (currently returns `[Meal]?`) — a small ripple into `MealResolutionService` only |
| **1.2** | **Give the lexicon tier the bind floor every other tier already has.** `catalog.results(for:limit:1).first` → `catalog.scoredResults(…)`; drop the component below `minimumBindScore`; count components below `confidentBindScore` as weak | `DishTemplateLexicon.swift:215` | S (~5 lines) | Mirrors `FoundationDishDecomposition.swift:226-232` verbatim. The mozzarella bind scored **58** against `confidentBindScore = 250` → marked weak. Closes the one tier in the cascade with no quality gate at all | Low. Some currently-succeeding resolutions will drop components or return nil and fall through. **Pair with 1.1** so a weak bind downgrades confidence rather than silently vanishing. Worth a test over all 29 templates |
| **1.3** | **Fix the pizza template's data.** Change `pizza dough crust` to a term that resolves to a baked crust; reconsider whether a pizza should be decomposed at all. Audit the other 28 templates for the same "search string is not a food name" defect | `DishTemplates.json:291` (audit `:1-320`) | S | Removes the Pillsbury bind, which **no ranking change fixes** — verified to survive score-first and blended ranking identically. **Likely the highest value per minute in this list** | Low, contained to data. Replay each edited search string against the shipped catalog to confirm the new top-1 before committing |
| **1.4** | **Parse the unit word before falling back to `defaultCount`.** When the description names the template's own `unit` with no leading number, treat as count = 1 | `DishTemplateLexicon.swift:248-253`, `:126`/`:130`/`:137` | S | Halves the silent overcount: this meal logged 2 slices when the user typed one. Fixes "pizza slice", "a slice of pizza", "burrito" across all 29 templates | Low. Must not regress the plural case. **Localization wall: the unit token set is a matching input → frozen English; any displayed unit localises** |
| **1.5** | **Surface discarded brand/retailer tokens as `unmatchedItems`**, which already forces `needsReview` | `DishTemplateLexicon.swift:124-140` → `MealResolutionService.swift:148-151`; `NutritionModels.swift:625` | S | "costco" becomes a visible unmatched item, flipping `needsReview` — a **second, independent safety net** that would have caught this bug. Reuses the tested FOOD-04 mechanism | Low. Needs a brand/retailer token list; `FoodBrandLexicon` (43 entries) + `retailerTerms` exist, though the unanchored `contains` matching has its own false-positive problem ("chilis") |
| **1.6** | **Stopword filter in `FoodItemSearch.searchTokens`**, reusing the 18-word list already at `NutritionModels.swift:1499-1502` plus household-measure words (bowl, glass, plate, cup, handful, piece, slice, serving, two, three) | `FoodItemSearch.swift:325-337` | S | **Recovers 7 of the 11 measured zero-result queries:** `bowl of oatmeal` → *Oatmeal NFS*; `handful of almonds` → *Nuts, almonds*; `plate of pasta` → *Pasta, cooked*; `two scrambled eggs` → *Egg omelet or scrambled egg*; plus `glass of milk`, `bowl of cereal`, `piece of chicken` | **MUST NOT SHIP ALONE — see §29.** Naive stripping makes the tester's own query worse. Note FTS5 has no built-in stopword support; strip before building the MATCH expression |
| **1.7** | **Constrain data-type-over-score.** (a) Apply `PreparedDishHeuristic.demotingDishes` inside `results(for:)`/`scoredResults(for:)` as `candidates(for:)` already does at `FoodCatalog.swift:126`. (b) Let data type outrank score only when the score gap is below a threshold | `FoodItemSearch.swift:93-102`; `FoodCatalog.swift:87-95` | M | Measured: `mozzarella cheese` 58 → `Mozzarella Cheese` **1870**; `cheese pizza` 58 → `Cheese Pizza` **1870**. Addresses **15 of 46 wrong top-1s**. The codebase already names this defect in `PreparedDishHeuristic`'s doc comment | **HIGHEST-RISK ITEM.** Option (b) re-ranks every search surface including the typeahead, and the ordering exists deliberately (a broad-prefix regression test pins survey-row visibility). Full score-first would promote branded exact-name rows over generic USDA rows everywhere — a real product decision, not a bug fix. **Prefer (a) first; get owner sign-off before (b)** |
| **1.8** | **Add a real score floor on the search path** (`minimumBindScore = 1` is a no-op — any single name-token hit scores +60) and stop presenting negative-scoring rows undifferentiated | `FoodItemSearch.swift:50`; `FoodCatalog.swift:87-95` | S | Removes the two −82 rows from `cheese pizza slice`'s top-6. **Prerequisite for any corpus expansion** | Low–medium; shrinks some result sets |
| **1.9** | **History-first ranking.** Add a history tier at the top of the comparator plus a `log(1 + count)` frequency term and an exponential recency decay (τ ≈ 14–30 days) | `FoodItemSearch.swift:93-102`; data from `FoodPlanning.swift:58-79` or a new per-`foodItemId` usage ledger in `DiaryStore` | M | **Highest value per line of code.** Matches MacroFactor's published hierarchy (§14 — note this is *one* vendor's stated design, not an industry consensus). Perfectly private — counters never leave the device. The one change that makes the app better the longer someone uses it. **Now supported on outcome grounds too:** successful loggers re-enter **2.4–2.7 times a day** while spending no more total minutes than unsuccessful ones (Harvey et al. 2019, §11), so cheap resumption — not precision — is the lever the literature measures | Medium. A new persisted surface → needs a `Docs/PrivacyWipeCoverage.md` disposition row in the same commit, and inclusion in the delete-everything path. Position-bias caution: do not train on raw click counts |
| **1.10** | **Local correction memory.** Generalise `cachedWebImportedFoodProduct`'s query-alias mechanism: write a `search-alias:<normalized Q>` tag onto the `FoodItem` the user picks when replacing a component in `MealCorrectionSheet`; have `FoodCatalog.results` check aliases before the FTS gate | `DiaryStore.swift:1429-1437`; `FoodView.swift:4145-4153` | M | Makes the tester's query **self-healing after one correction**, per user, on device. No new schema (tags exist), no new persisted surface (tags die with `foodItems`, so no disposition row), no network, no licence, no moderation, no Guideline 1.2 / DSA / CDA 230 exposure | Low. The only proposal here that improves the more the app is used |
| **1.11** | **Give `MealSheet` a search field**, reusing `CatalogSuggestionRow`; give `suggestionList` an empty state with a create-it escape; give `MealItemSearchField` a create affordance | `FoodView.swift:2188`, `:2016`, `:4208`, `:1900` | M | Makes 118,317 rows reachable from the app's front door for the first time. Turns a catalog miss in Adjust meal from a dead end into a custom food | Medium — a UX surface change. **Must key off the approved Batch 4 artboards 4a–4g** (`Docs/design-refs/ux-review-2026-08-16/design-spec-2026-08-21.md:340-705`), not re-propose settled chip order / Capture demotion / header-Done rules |
| **1.12** | **Add a whole-description single-row probe** BEFORE any decomposition tier, as `Docs/Meal-Estimation-Overhaul-Plan.md` §2.1/§3.4 specified and was never built: search the full description; if a single row clears a high floor AND carries a portion matching the typed unit, short-circuit. Strip unmatched brand/retailer tokens first | `MealResolutionService.swift:104` (new branch before `:105`) | M | `cheese pizza slice` → `Sliced Pizza, Cheese`; with "slice" routed to portion matching, reaches `Fast Food, Pizza Chain, 14" pizza, cheese topping, regular crust` (slice = 107 g) or `PIZZA HUT 14" Cheese Pizza, Pan Crust` (slice = 112 g). Fixes the whole class, and reuses the 468 slice-bearing rows already shipping | Medium. Needs a genuinely high floor or it short-circuits to a wrong single row and masks correct decompositions. Brand stripping must be conservative and must **surface** the dropped brand (1.5). Ranking must prefer rows carrying a matching portion unit, which `RecipeUnit` cannot express for "slice" (→ 2.4) |
| **1.13** | **Replace the token heuristic with the real per-component bind score.** Persist the score from 1.2 on the component snapshot; flag on `score < confidentBindScore` | `FoodView.swift:3991-4004` + a score field on the component snapshot in `NutritionModels.swift` | M | Turns a false-positive machine into a real signal | **Medium — the one fix here that touches persisted shape.** Adds a field to a synced snapshot type → clean build required per the `FernletDomainModel` hazard, plus decode-compat for snapshots written before the field existed |
| **1.14** | **A plausibility + completeness gate on user-entered and OCR-scanned foods — CONFIRMED, with two changes, after the patent review in §40.** Implement the five internal-consistency rules as pure functions — non-negative; not all-zero (with a water/tea exception); **calories ≈ weighted macro sum within ±10%**; total fat ≥ trans + sat + poly + mono; total carbs ≥ fibre + sugar (§15) — plus Evenepoel's eight per-portion ceilings as an **outer absurdity guard only**, plus a **completeness** check that names which nutrients are missing instead of silently storing zeros. **Change 1: build them from the source documents, not from the patent.** §40.4 traces every rule to public practice long pre-dating the patent's 2016-03-31 priority — Atwater 1896 and 21 CFR 101.9(c)(1)(i)(B) for the 4/4/9 identity, FAO/INFOODS 2012 and USDA ARS's Table 4 (Haytowitz 2009) for the fat and carbohydrate inequalities, Rand et al. 1991 for zero-versus-missing, 21 CFR 101.9(j)(4) for the water/tea exception, Greenfield & Southgate 2003 for the tolerance band. Cite those; do not paste MyFitnessPal's phrasing into code or docs. **Change 2: the rules now carry a hard design boundary** — see the Risk column | `CustomIngredientUpsert.swift:12-50` — the single de-dupe/upsert seam every custom food already passes through; `NutritionLabelScanner` / `FoodCaptureRouter` on the OCR path; surfaced in the recipe ingredient editor (`FoodView.swift:2026`) and the barcode not-found screen (`BarcodeScanView.swift:581`, `:659`) | S–M | **The one submission-gate mechanism in §15 that Fernlet can ship with no server, no account and no moderation queue** — and it belongs in this tier, not Tier 3. It catches the failure mode §16 actually measures: a field that is *absent*, so it reads as zero, which a ceiling structurally cannot catch. It also catches an OCR misread (a decimal point lost in a scanned panel) before it becomes a diary entry, and it is the prerequisite that makes any future contribution flow — mesh-scoped or otherwise — honest | Low **on the arithmetic**, and §40 does not change that: two of the five rules (fat ≥ Σ fatty acids; carb ≥ fibre + sugar) appear in **no claim** of either patent in the family, and the other three appear only in claims whose independents require a crowd-sourced curation server — ingestion from a plurality of devices, clustering, scoring, verified-record election, duplicate merging — that Fernlet has no part of. *Note the honest correction: three of the five **are** claimed, in `'215` dependent claims 8 and 15 and as a genus in `'472` claims 1 and 9. The protection is claim **dependency**, not their absence (§40.2).* **The real constraint this fix inherits is a design boundary, and it must be written into the code comment: these rules must never be combined with cross-device aggregation of user-created food records** — no shared or federated store that clusters, scores, elects a canonical "verified" record and serves it back. That is the line the claims actually draw, it is the same line §24 draws for DSA and Guideline 1.2 reasons, and **Fernlet's proximity mesh is literally a plurality of health-tracking devices** (§40.8). All five rules remain pure functions fitting the Power-of-10 ≤ 60-line rule; no persisted surface, so no `Docs/PrivacyWipeCoverage.md` row. **Do not present the ceilings as a validated accuracy standard** (§15). Warning copy is display text → `LocalizedStringKey`; nutrient field names are matching inputs → frozen English |

---

## 27. Tier 2 — fixes needing NEW DATA (but no server)

These cost bytes and a regeneration, not a server. Sequence them so the ~57 MB git-history cost is
paid once.

| # | Change | What it buys | Cost | Licence |
|---|---|---|---|---|
| **2.1** | **Import the USDA FNDDS 2021-2023 layer.** The shipped catalog has **202** survey rows against FNDDS's **5,431** dish food codes — **5,229 missing (96.3%)**. Zipped FNDDS JSON is 3.7 MB (64 MB unzipped) | The "as consumed" layer a food logger needs: burritos, stir-fries, omelets, mixed dishes, each with household portions. Includes `Pizza, cheese, from restaurant or fast food` food codes **58106210** and **58106220**, the latter carrying 12 portions: 1 piece NFS 86 g; small 59 g; medium 63 g; large 86 g; extra-large 98 g; personal 5–7″ 127 g; small 8–10″ 353 g; medium 11–12″ 500 g; large 13–15″ 691 g; extra-large 16–18″ 977 g; **1 surface inch 4.5 g**; quantity not specified 172 g | ~57 MB of new git history per regeneration (no LFS, no `.gitattributes`). Schema already supports it: `FoodPortion` has amount/unit/gramWeight/description; `FoodDataCatalog.swift:283-304` already parses FDC `foodPortions`; `FoodItemSearch.dataTypePriority` already has a `.survey` case | **CC0.** Zero obligation |
| **2.2** | **Import the FNDDS Ingredients workbook** (1,047,224 bytes): **18,584 ingredient rows across 5,431 dishes**, mean 3.42, max 20, 171 WWEIA categories (Meat mixed dishes 1,573; Pasta mixed dishes 958; Poultry 902; Rice 728; Seafood 664; Eggs and omelets 581). Columns: Food code, Main food description, WWEIA Category number/description, Seq num, Ingredient code, Ingredient description, Ingredient weight in grams, Retention code, Moisture change percent | The authoritative replacement for the 29 hand-written templates in `DishTemplates.json`. **And the do-not-decompose signal Fernlet lacks: 1,602 of 5,431 dishes (29.5%) have exactly ONE ingredient.** USDA's own decomposition of a restaurant cheese pizza is **one ingredient at 100 g** — `Fast Food Pizza Chain 14" pizza, cheese topping, regular crust`. `DishTemplates.json` says three, at 60/40/30 g, doubled. **The tester hit a hand-authored contradiction of free public-domain data** | ~1 MB + a build-time script | **CC0** |
| **2.3** | **Index `brand_source` as a fourth FTS column** and add it to `Index.init`'s searchable string | Recovers **3 of the 11** measured zero-result queries and unlocks **14,392 distinct branded brands** currently displayed via `dataSourceLabel` but unreachable (measured `MATCH 'costco*'` = 0 against 31 Costco rows). Fixes the broad "I can see the brand and cannot type it" defect | Catalog regeneration (~57 MB history) — **pair with 2.1/2.2 so it is paid once**. Both sides of the fold must change together or search silently breaks (the `locale: nil` normalisation invariant, `FoodItemSearch.swift:174`) | — |
| **2.4** | **Add `slice`/`piece` to `RecipeUnit`, or match portions by raw string** | Unlocks **468 slice-mentioning rows / 194 `slice` portion entries** with **zero regeneration**. Correction: `RecipeUnit` has 9 cases but `normalized` accepts ~26 spellings (incl. `unit`/`units`/`item`/`items` → `.each`), which is why the 5 `item` rows do resolve. The slice/piece gap is real either way | Small; but a `FernletDomainModel` enum change → **clean build required** | — |
| **2.5** | **Fix `RecipeIngredient.scale`'s silent identity fallback.** `NutritionModels.swift:1647-1660` falls through to an unconditional `return quantity` at `:1659` when the unit cannot be resolved. **15,277 rows (12.9%) carry an unparseable `serving_unit`** — GRM 12,376, MLT 2,193, MG 420, IU 193, GM 31, plus survey units (cup 109, serving 26, sandwich 20, piece 11, item 5, double 5, cheeseburger 5, hamburger 4, slice 3, stick 2, meal 2, MC 2). Logging 100 g against a 1-piece survey row multiplies macros by 100 | Removes an order-of-magnitude calorie overcount with no warning | Small | — |
| **2.6** | *(Optional, later)* **Bundle an Open Food Facts snapshot** as its own attached source file, never merged into `FoodCatalog.sqlite`, with per-row provenance | Net new US barcodes. OFF's US slice is 956,577, of which **170,754 are the same USDA branded import** already shipping. Realistic net new: several hundred thousand. **Gains nothing** on restaurant meals (`categories_tags:"en:meals-from-restaurants"` = **0 products**) or generic whole foods | Fernlet's schema costs ~490 bytes/product, so a filtered US slice lands in the **250–470 MB** range → a second ODR tag, not a bundle asset | **ODbL share-alike attaches to the shipped artifact.** Keep it in its own file (the `attachBrandedSource` seam already supports this) so the publishable Derivative Database is precisely identifiable and the CC0 artifacts stay clean. §4.5(b) means the Swift source is unaffected; §4.6(b) is satisfied by publishing the generator, as `Scripts/branded-catalog/` already does |

**A staleness warning for the whole of Tier 2, from the owner-supplied Cronometer page.** The market's
most accuracy-focused vendor is shipping **USDA SR28** — the frozen 2015–16 legacy release — and
**CNF 2015**, on the same page that promises *"removing … outdated entries"* and *"the most reliable
data available"* (§13a). A curated-first strategy **inherits its upstreams' vintages, silently**. Every
import in this tier — 2.1, 2.2, and especially 2.6 — therefore needs a **stated refresh policy and a
recorded source vintage per row**, not just a one-time import script. The catalog already carries a
`user_version`; the per-source release date should join it, and the §25 corpus test should assert it.

**Data hygiene for 2.6.** OFF's live bulk files, measured by HTTP HEAD on 2026-08-22:
`en.openfoodfacts.org.products.csv.gz` = **1,275,171,186 bytes (~1.28 GB)**;
`openfoodfacts-products.jsonl.gz` = **12,725,142,044 bytes (~12.7 GB)**; MongoDB dump
15,496,304,879 bytes. **Correction: OFF's own documentation still says ~0.9 GB for the CSV — roughly
40% under the measured file — and the "7 GB gzipped / 43 GB uncompressed" JSONL figure appears nowhere
on the current data page and contradicts the measurement. Use the measured HEAD values.** Daily deltas
run ~25,822,371 bytes/day over a 14-day window, and OFF notes that *"the delta files cannot tell you
about deleted products,"* so re-baseline from a full dump each release. OFF's own accuracy caveat:
26,303 products currently trip `en:nutrition-value-total-over-105` (nutrients summing above 105 g per
100 g), exposed per-product as `data_quality_errors_tags` and filterable. **OFF's derived completeness
percentages (0.38% `en:complete`, 75.7% nutrition-facts-completed, 27.7% ingredients-completed) are
agent-measured point-in-time and could not be reproduced — the API returned 503 on re-check. The world
total 4,701,512 is confirmed.**

---

## 28. Tier 3 — the tier we are not building

Completing the taxonomy, so the recommendation reads as a choice among all three buckets rather than
an avoidance of one.

**What would live here:** a global submission pool, cross-user verification counts, server-side dedup
and plausibility validation, a moderation queue, a report/block system, per-contributor rate limiting.

**The bill:** §21, in full.

**The one server-shaped thing that might be worth revisiting later** is **contributing upstream to
Open Food Facts**, so that OFF — not Fernlet — carries the DSA, GDPR and moderation obligations. It is
blocked today by the `EphemeralWebSession` invariant (`urlCredentialStorage = nil`,
`httpCookieStorage = nil`), because OFF writes require either a session cookie or credentials as POST
parameters. That would need a new authenticated network seam punching a hole in a deliberate wall.
**Defer, and treat it as a wall amendment with owner sign-off, not a feature.**

For the record, OFF's own contribution machinery: writes require an account, but a shared "global app
account" is sanctioned provided you send `app_name`, `app_version` and `app_uuid` — *"a salted random
uuid for the user so that Open Food Facts moderators can selectively ban any problematic user without
banning your whole app account"*
([openfoodfacts.github.io/openfoodfacts-server/api/](https://openfoodfacts.github.io/openfoodfacts-server/api/)).
**That is a persistent pseudonymous per-user identifier transmitted to a third party** — precisely
what the no-tracking wall exists to prevent.

---

## 29. The coupled-fix hazard

Nobody tested the proposed fixes together, and the naive combination makes the tester's own query
*worse*. This is the worked demonstration:

- **Today:** `cheese pizza slice` returns `Sliced Pizza, Cheese` (branded, score **120**) at rank 1 — a
  defensible answer already in the shipped catalog.
- **With naive stopword stripping (1.6) alone:** "slice" is stripped, the query becomes
  `cheese pizza`, the survey tier re-enters, and top-1 becomes `Calzone, with cheese, meatless` —
  score **58, 424 g, 1,655 kcal**.
- **Why:** with "slice" present, only branded rows survive the AND gate, so branded-vs-branded ranking
  works. Remove it and `dataTypePriority` hands the result to survey.

**The rule:** 1.6 (stopwords), 1.7 (score above data type) and 1.8 (score floor) **must land and be
measured as one unit** against the fixed corpus. The same coupling applies to 2.3 (indexing
`brand_source`), which will pull thousands of branded rows through the gate on queries that currently
return clean generic results.

---

## 30. The order to do this in

| Order | Work | Bucket | Effort | Leverage | Risk | Gate |
|---|---|---|---|---|---|---|
| 1 | Land the 57-query corpus test | **Tier 0** | S | Enabling | None | — |
| 2 | Lexicon confidence + bind floor (1.1, 1.2) | **No new data** | S | **Very high** | Low | Test over all 29 templates |
| 3 | Template data audit (1.3) + unit-word parsing (1.4) | **No new data** | S | **Very high per minute** | Low | Replay each edited search string |
| 4 | Unmatched brand tokens (1.5) | **No new data** | S | High | Low | — |
| 5 | Score floor (1.8) | **No new data** | S | High | Low–Med | Corpus test |
| 5b | Plausibility + completeness gate on custom and scanned foods (1.14) | **No new data** | S–M | High | Low | Pure functions; no server, no schema change, no persisted surface. Independent of 5/6/7, so it can land in parallel |
| 6 | Data-type demotion, option (a) (1.7a) | **No new data** | M | **Very high** | Med | Corpus test; existing broad-prefix regression test |
| 7 | Stopwords (1.6) — **land with 5 and 6** | **No new data** | S | High | Med | Corpus test, jointly |
| 8 | Local correction memory (1.10) | **No new data** | M | High, compounding | Low | — |
| 9 | History-first ranking (1.9) | **No new data** | M | **Very high** | Med | Wipe disposition row in the same commit |
| 10 | Composer search field + empty states (1.11) | **No new data** | M | High | Med | Artboards 4a–4g |
| 11 | Whole-description probe (1.12) | **No new data** | M | High, class-wide | Med | Needs 1.5 + a high floor |
| 12 | `RecipeUnit` slice/piece (2.4) + scale fallback (2.5) | **New data (small)** | S | Med | Low–Med | Clean build |
| 13 | FNDDS dishes + Ingredients + `brand_source` FTS (2.1, 2.2, 2.3) — **one regeneration** | **New data** | L | **Very high** | Med | Query side + generator change together |
| 14 | Per-component bind score persisted (1.13) | **New data (schema)** | M | Med | Med | Clean build + decode-compat |
| 15 | Consent prompt at first miss for the web lane | **Product decision** | S | Med | Low | Owner decision |
| 16 | Partial-match fallback when the AND gate returns zero | **No new data** | L | High | **High** | Breaks the documented "FTS gate == scorer gate" invariant; `matchVariants` + the parity test must change together. **Do last** |
| 17 | Data-type demotion, option (b) — score-first (1.7b) | **No new data** | M | Very high | **High** | **Owner sign-off required** — a product decision, not a bug fix |
| — | OFF snapshot (2.6) | **New data** | L | Low–Med | Med | ODbL decision |
| — | Hosted UGC pool | **Needs a server** | XL | **~3%** | **Very high** | **Not recommended** |

---

## 31. What each tier does to the query that started this

| After | What "costco cheese pizza slice" does |
|---|---|
| **Today** | 3-ingredient recipe, 120/80/60 g, `.high` confidence, auto-committed, no review sheet |
| **+ 1.1, 1.2** | Same decomposition, but `.medium`/`.low` → **the review sheet opens before it counts toward the day** |
| **+ 1.5** | "costco" appears as an unmatched item → `needsReview` flips a second, independent time |
| **+ 1.4** | Count becomes 1, not 2 → 60/40/30 g instead of 120/80/60 |
| **+ 1.3** | The Pillsbury bind disappears (no ranking change fixes it) |
| **+ 1.7a, 1.8** | `mozzarella cheese` binds to `Mozzarella Cheese`, not breaded fried sticks |
| **+ 1.12** | Brand-stripped whole-description probe → `Sliced Pizza, Cheese`; with unit routing → `Fast Food, Pizza Chain, 14" pizza, cheese topping, regular crust` (slice = 107 g) or `PIZZA HUT 14" Cheese Pizza, Pan Crust` (slice = 112 g) |
| **+ 1.10** | If she corrects it once, the query is **self-healing** thereafter |
| **+ 2.1, 2.2** | FNDDS 58106220 becomes available: a **single** row with 12 portions including "1 piece, extra-large pizza" 98 g and "1 surface inch" 4.5 g — and USDA's own one-ingredient decomposition tells the resolver **not to decompose it** |
| **+ 2.3** | "costco" becomes searchable — surfacing 31 Costco-branded rows, **none of which is a food-court slice** |
| **+ web-lane consent prompt** | The lane that already recognises "costco" actually runs |
| **+ a hosted UGC pool** | **Still nothing**, unless another user happens to have uploaded a Costco food-court slice — and if they did, it would be an unverified stranger's number with no label to check it against |

**The honest closing fact: no government dataset can ever contain a Costco food-court slice.**
21 CFR 101.11 covers chains of 20+ locations operating under the same name — Costco runs **633 US
warehouses as of January 2026** (including Puerto Rico) and up to 655 by August 2026, far above the
threshold; note the definition turns on the FOOD ("restaurant-type food"), not the store type, which
is what pulls warehouse-club food courts into scope. The rule requires calories on the menu board and
the full 11-nutrient panel **in written form on the premises upon request**. It creates **no submission
to FDA, no public registry, and no machine-readable feed.** USDA Branded requires a
manufacturer-submitted GTIN through GDSN/1WorldSync; a food-court slice has neither. Verified against
the repo's own 364,457-row branded file: 117 rows for "Costco Companies Inc.", the only Costco pizza
being a packaged cauliflower-crust supreme; **zero rows containing "FOOD COURT" anywhere.**

And the published third-party numbers disagree materially, which is why the honest UI is one canonical
row plus a visible provenance marker, not a fake-precise value:

| Source | Serving | kcal | Fat | Carb | Protein | Sodium | Fibre |
|---|---|---|---|---|---|---|---|
| [CalorieKing](https://www.calorieking.com/) | 1 slice, 9.8 oz | **699** | 28 g | 70 g | 44 g | **1,370 mg** | **3 g** |
| [MyFoodDiary](https://www.myfooddiary.com/) | 1 slice, 269 g | **710** | 27 g | 78 g | 41 g | **1,780 mg** | **9 g** |
| [FastFoodNutrition](https://fastfoodnutrition.org/) — stamped "source: Costco Food Court", last updated 6/27/2021; third aggregator, less independently verified | 1 slice | **760** | 30 g | 80 g | 40 g | 1,740 mg | 7 g |

**Sodium differs by 30%; fibre by 3×.** Costco publishes nothing — its Member Service FAQ once said
the only routes were to ask a team member in-warehouse or email Member Service; that page now returns
"This answer is no longer available."

**The answer Fernlet should give is the existing OCR path.** `NutritionLabelScanner` already extracts
serving size, calories, macros and ~20 micronutrients. A "scan a menu board / nutrition sheet" entry
point reads today's posted values at that location — fully offline, zero network, zero licence, zero
ToS surface, and **more accurate than any database**, because it defeats the regional, limited-time and
slice-geometry variance that makes chain data structurally unfixable by bundling.

---

# PART VI — GOVERNANCE

## 32. Corrections applied to the source research

A short honesty section. It buys credibility for everything else, and it stops a future reader
re-importing the errors. **The second block was added on 2026-08-22**, when nine owner-supplied
documents let several claims be checked against primary sources for the first time — including two that
this memo had got wrong in the vendor's favour, and one it had got wrong against.

| Claim as originally made | Corrected |
|---|---|
| The catalog lacks a plausible single-row answer to "cheese pizza slice" | **False.** ~35 cheese-pizza rows exist, many with real per-slice gram weights already shipping |
| The Pillsbury bind is a ranking defect | **False.** It survives score-first and blended ranking identically — it is a template-data defect |
| `FoodBrandLexicon` has 44 entries | **43** |
| `dominos*` returns 13 rows | **0.** The 13 is `domino*` (re-measured 2026-08-22) |
| 6 DiGiorno pizza rows in the ODR file | **5** by name match; min/max `food_id` 6,112 / 289,206 exact; conclusion unchanged |
| 1,861 distinct portion unit strings | **1,876** |
| bm25 is "DEAD" on a contentless `columnsize=0` table | **Overstated.** `xColumnSize` always returns −1 so length normalisation is lost, but `ORDER BY rank` runs and returns usable varying values (measured: −8.18197255136941, −8.15861098628329) |
| "Decomposition is the designed default at every rung; no is-this-one-packaged-food test anywhere" | **Overstated.** The AI decompose prompt contains an explicit single-item counterweight (`FoundationDishDecomposition.swift:39-52`). True for rung 3 only |
| Only ~9 unit spellings map to `RecipeUnit` | `RecipeUnit` has 9 **cases**; `normalized` accepts ~26 spellings. The slice/piece gap is real |
| `INSERT INTO food_fts(food_fts) VALUES('optimize')` would be a cheap win | **Already implemented** at `FoodCatalogDatabaseBuilder.swift:74`, with `VACUUM;` at `:75` |
| OFF bulk: ~0.9 GB CSV, 7 GB gzipped / 43 GB uncompressed JSONL | **Measured:** CSV 1,275,171,186 bytes; JSONL.gz 12,725,142,044 bytes. OFF's own docs are ~40% under on the CSV |
| Edamam: ~$299+/mo, 615k UPCs, ~10k generic foods | **~900,000 foods, 790,000 unique UPCs, 100,000 common foods on Basic. Plans start at $14/mo** (100k calls); Core $69/mo; Plus $299/mo |
| FatSecret §1.7(iv) forbids robots/spiders | **Misnumbered.** §1.7(iv) is the excessive-usage clause. Do not cite that subsection for that proposition |
| DSA Art. 16(3): a notice gives rise to actual knowledge | **Truncated.** Only *"where they allow a diligent provider… to identify the illegality… without a detailed legal examination"* |
| *hiQ v. LinkedIn*: stipulated judgment December 7, 2022 | **December 6, 2022** — and the breach rested substantially on fake accounts and Mechanical Turk workers, not scraping public pages alone |
| Costco: ~624–629 US warehouses | **633** (Jan 2026, incl. PR) to **655** (Aug 2026). Conclusion unaffected |
| FDC Branded current release: April 2026 | **Conflicting checks.** One verifier confirmed April 2026 from the download page; another found Branded and the full download at **12/2025** (JSON 195M/3.1G; CSV 427M/2.9G; full 458M/3.1G). Sizes agree within rounding. Foundation 04/2026, SR Legacy 04/2018, FNDDS 10/2024 are agreed. **Re-check at [fdc.nal.usda.gov/download-datasets](https://fdc.nal.usda.gov/download-datasets) before publishing** |
| Apple enforces a 24-hour takedown under Guideline 1.2 | **Not in the published text.** An unverified norm from third-party blogs. Never cite as a rule |
| PLD recitals name "a mobile health application" | **Not located.** Recital 13 covers software generically. Do not cite. The Art. 2(1) applicability date **is** verified |
| Uncommitted capstone diff "25 files, +990/−494" | Stale (27 files / 1,091 / 527 at re-check, and drifting). **Do not quote a diffstat** |
| iCloud Private Relay is not available to third-party apps at all | Slightly too absolute: for iCloud+ subscribers, insecure plain-HTTP app traffic **is** carried automatically. No app can opt in deliberately |
| RRF uses k = 60 | Cite as **convention**, not a quoted parameter (ACM DL returned 403) |
| GDPR Art. 9 covers diet data | Present as a **well-supported reading** via CJEU C-184/20, not a statutory enumeration |
| *Winter v. Putnam* covers a curated nutrition DB | **Weaker than implied** — the court noted Putnam neither wrote nor edited, and distinguished charts |

**Corrections from the owner-supplied documents (2026-08-22).**

| Claim as made in the 2026-08-22 draft | Corrected |
|---|---|
| "The ~$1,850/month figure traces only to competitor SEO blogs" (§18), and §33 filed it under *Unverifiable* | **False as stated.** $1,850/month is the **published** starting price of Nutritionix's top "Unicorn" tier, read at the primary source: *"starting at $1850 /Month*"*, the asterisk resolving to *"API plans are billed annually."* The full published list is Business Trial FREE / Starter $499 / MVP $999 / Unicorn from $1,850. Moved to *Verified at the primary source*. What remains genuinely unpriced is **bulk database licensing** specifically — *"Interested in bulk database licensing? Please contact us."* The memo had conflated the API tier price with the bulk-licence price; they are now split |
| "A runtime nutrition API … killed for an offline-first app by caching terms," Nutritionix included (§2) | **Too strong for Nutritionix.** Its pricing page carries an explicit **"Caching Allowed"** comparison row: ✗ Business Trial (free), ✗ Starter ($499/mo), ✓ MVP ($999/mo), ✓ Unicorn ($1,850+/mo). Caching is **a paid feature with a $999/mo floor, not a prohibition** — categorically different from FatSecret's 24 hours, Spoonacular's 1 hour and Edamam's six fields. **Critical caveat retained:** the page never *defines* "caching" — no retention period, no transient-versus-durable distinction, nothing about shipping an offline copy — and the binding Syndigo terms were not supplied. Reworded to "affirmatively permits caching at ≥ $999/mo, scope undefined" |
| Nutritionix rate limits: "—" (nothing stated) | **It does not meter API calls at all.** Metering is by **monthly active users** — *"up to 2 … up to 200 … up to 1000 … Customizable"* — with no published call limits. This is a harder constraint than any caching clause: a consumer app crosses 1,000 MAU trivially, and **a free app is off the published price list entirely** (*"What if my app is free or freemium?"* → a sales referral). Also: the $499 Starter tier does **not** include the Natural Language Engine, so the cheapest tier carrying both NL parsing and caching is MVP at $999/mo |
| MyFitnessPal's *Best Match* is "created/verified by in-house RDs" (§13) | **Not supported by MyFitnessPal.** Its own page defines Best Match **circularly** — *"When you manually search the food appearing at the top of your search results is considered the best match"* — and the word "dietitian" appears nowhere in a curation context across sixteen pages (only in author bylines and a bio). The RD characterisation traces to the **Fitia competitor article**, on a domain §17 already names as a fabrication source. Dropped |
| MyFitnessPal's green check = "MFP reviewed" (§13) | **Weaker than implied.** *"When MyFitnessPal has reviewed **or added** a food to our database and **believes** that the nutrition information is accurate"* — a belief, covering two merged populations (entries MFP inspected and entries MFP authored), with no disclosed split, no criteria and no reference standard. The article then upgrades the hedge to *"reviewed and verified"* in its advice sections |
| MFP database size given as 20.5 M alongside `blog.myfitnesspal.com` | MFP's own page says *"over 20 million"*, twice, and **never 20.5 M**. The 20.5 M figure is the **App Store listing**; attribute it there (§17) |
| "Everyone else ranks your own history first" (§14 title and framing) | **Overstated as an industry consensus.** Verified verbatim for **MacroFactor only**. MyFitnessPal publishes **no ranking function at all** (rank/algorithm/popular/frequency: zero occurrences in sixteen pages) and segregates personal history into a **separate tab** with a "Most Recent" sort; Cronometer's supplied pages never mention search. Section retitled; **fix 1.9 unchanged** — it stands on its own merits |
| Cronometer's in-house database is "CRDB"; sources listed as "USDA … CNF" (§13, §15) | **CFCD** — *"Cronometer Food Composition Database"*; CRDB appears nowhere on Cronometer's own page. The USDA source is **SR28**, the frozen 2015–16 legacy release, and the Canadian file is **CNF 2015**. Both superseded vintages — a warning for §27 |
| Cronometer's submission gate quote and photo-of-package requirement (§15) | **Still not first-party-sourced.** The two supplied Cronometer files are **marketing pages**, not the blocked `support.cronometer.com` articles §38A named. All the marketing says is *"Every item submitted to our database undergoes a verification process"* — scoped to branded entries, with no mechanism, criteria, SLA or rejection rate. §38A's four Cronometer rows stay open |
| Evenepoel's caps are a set of plausibility rules reusable as a submission gate (§16) | **Re-characterised, not withdrawn.** They are **one-sided upper bounds only**, applied per logged portion at **analysis** time; there is no macro-sum check, no Atwater reconciliation, no per-100 g cap, no lower bound and no internal-consistency rule in the paper. They were **curve-fitted** to maximise correlation with the Belgian table, not derived from physiology or regulation. And they **overfit**: protein fell r 0.94 → 0.90 and cholesterol ρ 0.67 → 0.51 after cleaning, a regression the paper never acknowledges. Use **MFP's five internal-consistency rules** as the design to copy (§15, fix 1.14) |
| §16 framed crowd micronutrient failure as inaccuracy | **The mechanism is omission.** Evenepoel: entries *"only have a value for total energy content without values for macronutrient composition or cholesterol and sodium content."* The caps removed 3 sodium and 3 cholesterol values across 2,826 items while sodium ran 51% under and cholesterol 77% under — **the ceilings caught essentially none of the damage.** The defensive design is a **completeness** gate, not an accuracy claim |
| "Fernlet's curated USDA catalogue is already more accurate than MyFitnessPal for micronutrients" | **An inference from source provenance, not a measurement.** Nothing in the new evidence tests Fernlet's own catalog. Now labelled as such in §16 |
| Framing that a crowd corpus "adds junk" (§10 table, §20) | **Retired.** After a 2.8% clean, crowd macro data matched a national food composition table at r = 0.96 energy and r = 0.90 carb/fat/protein with no bias, and **zero** energy or fibre values were implausible across 2,826 items. The objection is **ordering** (no score floor, data type above relevance), **compliance** (§21) and **no user base** — not data quality |
| The owner-supplied `nihms-1040559.pdf` is Fallaize et al. 2019 | **No.** It is Harvey, Krukowski, Priest & West, *"Log Often, Lose More: Electronic Dietary Self-Monitoring for Weight Loss,"* Obesity 2019;27(3):380–384 — a behavioural adherence study with **no database content whatsoever**. §38F's Fallaize row **stays open** |
| Evenepoel's Bland-Altman limits of agreement could be recovered from the full text (§38F) | **They do not exist as numbers anywhere in the paper.** They are drawn only as dashed lines in a raster figure, labelled "95% UL" / "95% LL". The only numeric agreement statistics published are the sodium mean difference (**−1,345 mg/day, SD 241**), the cholesterol mean difference (**−187 mg/day, SD 124**) and the fibre fixed bias (*"about 4 g/day… about 20% of average fiber intake"*). **The stated sodium SD is internally inconsistent with the plotted spread by roughly a factor of three** — flag it if it is ever cited |
| The Fitia article is usable as a third-party comparison | **It is vendor content marketing published by Fitia**, one of the three apps compared: unsigned, undisclosed in the body, running **no test of its own**, and closing with *"use code FITIANOW to save 10%."* Its *"around 70%"* UGC figure is added to §17's do-not-cite list. Its ranking quote is quotable **because** it concedes against the publisher's own interest |

**Corrections applied to the second-revision research bundle (2026-08-22).** Six research passes and two
adversarial fact-checkers produced the material behind Part VII. Where they disagreed, the source that read the
publisher's own file or the granted claim text wins. These are the refutations, recorded so the wrong version is
never re-imported.

| Claim as made in the second-revision research | Corrected |
|---|---|
| Germany's **BLS 4.0 licence is "unclear"** — *"lizenzfrei" means no licence fee, not licensed for redistribution; no open licence has been declared; do not bundle on the strength of the press release, write to MRI first* | **REFUTED, and this was the single most consequential error in the bundle.** The publisher's own download page states the licence plainly: *"Die Daten des Bundeslebensmittelschlüssels (BLS) stehen als Open Data zur freien Verfügung. Die Nutzung ist unter der Lizenz **CC BY 4.0** … gestattet"*, with attribution to Max Rubner-Institut as publisher and DOI 10.25826/Data20251217-134202-0. **Verified independently in this round at [blsdb.de/download](https://blsdb.de/download).** Two of four passes graded it unclear because they read `blsdb.de/license`, a stale page that still links only the 2018 BLS 3.0 fee terms. **No permission email is needed and the German localization is unblocked today** (§39.4) |
| **Ciqual 2025 was "also dual-deposited as CC BY 4.0 on Zenodo"**, making it explicitly CC BY-compatible | **False, and the wrong half was load-bearing.** Verified this round against the authors' own deposit: the Recherche Data Gouv record for [doi:10.57745/RDMHWY](https://doi.org/10.57745/RDMHWY) records exactly **one** licence, SPDX `etalab-2.0`. The Zenodo record cited as evidence is a **different, much smaller companion dataset** (191 "average foods" with contributor detail), not the 3,484-food composition table. Verdict unaffected — Etalab 2.0 independently permits commercial reuse, modification and redistribution — but **strike the CC BY reassurance** |
| **New Zealand FOODfiles is "yes-with-attribution"** redistributable, since its licence grants a royalty-free right to use the data *"in or as part of any good, product or service"* | **The grant is real; the grading understates two hard blockers.** Verified this round at [foodcomposition.co.nz/terms](https://www.foodcomposition.co.nz/terms/): the same licence says *"You must not modify any part of the FOODfiles™ Data"* and the grant is explicitly **non-transferable**. That is a **no-derivatives, non-transferable** licence in the same class as NEVO and BEDCA, and normalising rows into a merged SQLite is exactly the modification it forbids. A downstream reader keying off the structured field rather than the prose would have shipped an infringement (§39.3, Group 4) |
| **Japan's MEXT Standard Tables** are published under terms permitting free copying, translation and commercial use, *"explicitly stated to be compatible with CC BY 4.0 — the licence question is settled and favourable"* | **Not supported by the primary source, and the bundle contradicted itself.** The MEXT food-composition page carries **no terms of use at all**; `mext.go.jp/b_menu/9.htm` returns 404. Japanese government data often does fall under the Government of Japan Standard Terms of Use v2.0, which is CC BY-compatible, but that has **not been demonstrated for this dataset**. Downgraded to unverified |
| The **FAO/INFOODS Density Database** is *"All rights reserved … non-commercial uses will be authorized free of charge, upon request"*, quoted as read | **The counts are confirmed (638 entries, 20 groups, 11 sources); the rights sentence is NOT independently verified.** The PDF's copyright page uses a subset font with no character map. The practical verdict (permission-gated, do not bundle) is almost certainly right for a 2012 FAO publication, and the FAO/INFOODS index carries only a bare "© FAO" with no open licence — but **flag the quotation as unverified**. The same applies to the FAO/INFOODS WAFCT "CC BY-NC-SA 3.0 IGO" string |
| **BEDCA's Spanish conditions**, quoted verbatim (*"no podrán ser modificados"*, and the express-authorisation clause) | **Conclusion confirmed on independent evidence; the quotes are not machine-verifiable.** `bedca.net/bdpub/UsoBD.pdf` fetches, but its fonts carry no ToUnicode map, so the clauses could not be extracted in either round. What **is** confirmed, and independently sufficient: `bedca.net` carries *"Copyright © 2007 [Consorcio BEDCA y Agencia Española de Seguridad Alimentaria y Nutrición], **todos los derechos reservados**"* with no open licence anywhere. **The Spanish blocker is real; do not reproduce the Spanish clauses as verified text** |
| **NEVO is worth investigating** because Fernlet uniquely satisfies its no-charge-to-end-users clause by being free | **Half right, and the conservative pass wins.** The clauses are confirmed verbatim from RIVM's own conditions document — but that document opens *"By requesting a version of the NEVO online dataset, agreement will come into effect"*, i.e. a bilateral click-through, and **nowhere grants redistribution.** Being free clears the no-charge clause; it does not supply the missing grant. Graded **skip**, not investigate |
| The **'215 continuation** *"contains NO nutrition-validation limitation at all — not calories-vs-macros, not fat-vs-fatty-acids, nothing"* | **REFUTED, and this was the most important error on the patent side.** '215 **claim 8** recites a validation rule comprising *"one or more of (i) all nutrition values … being non-negative, (ii) at least one of the nutrition values … being positive, (iii) … meeting a predetermined relationship between calories and macro-nutrients, and (iv) a particular nutrition value being positive … based on the a food category"*; **claim 9** adds demotion; **claim 15** repeats the list. Verified this round at an independent full-text mirror. Two other passes had it right. **Any reasoning built on the false version is discarded** (§40.2) |
| Headline framing that **"four of the five rules appear in no claim in the entire patent family"** | **The number is two**, plus the water/tea half of a third. Rules (a) and the not-all-zero half of (b) are claimed in '215 claims 8 and 15; rule (c) is claimed **twice** — as a genus in '472 independent claims 1 and 9, and again in the '215 dependents. Only (d) fat ≥ Σ fatty acids and (e) carb ≥ fibre + sugar are unclaimed family-wide. **The non-infringement conclusion survives on claim *dependency*, not on absence** (§40.3) |
| The **'215 has the "same computed expiry 2037-07-27 — the matching date suggests a terminal disclaimer"** | **Inverted.** The '215 expires **2036-03-31**, sixteen months *before* the parent. Its face states **0 days** of PTA and *"This patent is subject to a terminal disclaimer"* — so the disclaimer is confirmed fact rather than inference, and it **shortens** rather than aligns the term (a terminal disclaimer bars PTA under 35 U.S.C. 154(b)(2)(B)). Practical consequence: **the only claims in the family that name the sanity rules are in the patent that expires first** |
| The **'472's patent term adjustment is ~476 days**, derived from the 2016-04-07 filing | **483 days**, printed on the face of the patent, and the base date is wrong: for a continuation, the twenty years runs from the **parent's** 2016-03-31 filing under 35 U.S.C. 154(a)(2). The right expiry (2037-07-27) was reached by back-solving from the wrong base |
| Disclosure-dedication under *Johnson & Johnston* means the unclaimed rules *"cannot infringe"* and *"can never be claimed"* | **Two overstatements.** The doctrine bars recapture **only under the doctrine of equivalents** — it is not a general licence to practise disclosed matter, and the reason a bare rule-(d) check is safe is simply that those words are in no claim. And *"can never be claimed"* needs the **broadening-reissue time bar** (35 U.S.C. 251, two years from grant — passed 2024-11-22 and 2026-08-06), not the co-pendency argument the passes gave (§40.5) |
| Provenance comments *"make the independent-derivation story self-evident"* | **Misleading if read as an infringement defence.** Independent creation is **no defence** to patent infringement — §271(a) is strict liability (*Commil*, 575 U.S. at 639). Provenance citations are valuable for two *different* reasons: §§102/103 invalidity evidence, and good-faith evidence bearing on willfulness under *Halo*. Restated precisely in §40.7 |
| *"Zero exposure"*, *"There is no realistic infringement exposure"*, *"Ship them"*, *"You are not exposed"* | **Struck.** That is freedom-to-operate language, and a closing disclaimer does not cure a body written in that register. Three symptoms were fixed: the passes gave **three incompatible counts** of claim 1's limitations (twelve, ten, eleven-odd) and quoted miss-ratios off them — so §40.3 quotes **no ratio**; none noted that **claim construction is for a court** (*Markman*) — §40.3 now does; and the one Fernlet-specific exposure, the proximity mesh, was buried in a design bullet — it now has its own section (§40.8) |
| The **'472 grant PDF is "an image-only scan with no text layer"**, so column citations are estimated | **False for the '472** — it carries a clean embedded text layer (~108 K characters); the failure was a PDF-library artifact, and the resulting hedges were unnecessary. **True for the '215**, whose USPTO copy genuinely is image-only. Recorded because it explains why one pass's claim text rested on secondary mirrors when the authoritative document was machine-readable |
| **Nutritionix's published tier prices** ($499 / $999 / $1,850+), stated as primary-sourced | **Unchanged in substance, but re-flagged.** `nutritionix.com/api` returned **HTTP 402** on re-check this round, so those figures now rest on the owner-supplied PDF alone (§18, §39.3). The recommendation is unaffected — the MAU meter and the free-app exclusion are the binding constraints, not the price |
| **Open Food Facts product counts** (4,701,654 world / 956,659 US / 862,056 nutrition-complete) and **CNF's 5,690 foods × 152 nutrients** | **Both unverified.** OFF's v2 search API returned 503; CNF's 2026 portal page states no counts and the Health Canada user guide 403s — the 5,690/152 figures are **2015-edition legacy numbers carried forward**. OFF's counts drive every size estimate in §27's 2.6, so **re-run them before any bundle-size decision** (§39.7) |
| The **ODbL §4.5(b) / §4.6 / §4.7 analysis** and the conclusion that keeping OFF in a separate file makes it a "collection" rather than a derivative | **Sound in direction, but it is legal argument, not verified fact.** The licence stack itself is confirmed verbatim on OFF's terms page; the section-level reasoning is a judgement call. §27's 2.6 already treats it as a decision requiring owner sign-off, which is the right posture |

---

## 33. Confidence ledger

| Class | Examples | Status |
|---|---|---|
| **Measured read-only against the repo** | All catalog row counts, all FTS match counts, all reproduced scores and rankings, file sizes, git state, the 57-query corpus results, the ODR experiment | **High.** Independently reproduced by an adversarial verifier; sixteen FTS counts and the `ORDER BY rank` values re-measured on 2026-08-22 |
| **Read directly in source** | Every `file:line` in this memo | **High.** All spot-checked on 2026-08-22 against the working tree |
| **Verified at the primary source** | ODbL clauses, App Store guidelines, DSA articles, GDPR articles, USDA licensing and rate limits, FatSecret/Edamam/Spoonacular terms, the MFP patent, MacroFactor statements, the five peer-reviewed studies, MenuStat CC0 metadata, CalorieKing and MyFoodDiary panels. **Added 2026-08-22 from owner-supplied documents:** Nutritionix's four published tier prices, the "Caching Allowed" matrix, the MAU meter and the attribution matrix; MyFitnessPal's own badge definitions, *Best Match* wording and disclosed moderation model; Cronometer's ten-source enumeration with codes and vintages; **Evenepoel 2020's full text** — all eight caps, the 2.8% rejection with per-nutrient counts, every correlation, and the two mean differences | **High** |
| **Point-in-time API observations** | FDC per-data-type counts (Branded 433,403; Survey 5,432; Foundation 394; Experimental 115), OFF completeness percentages, OFF per-country facets | **Medium.** Not published figures. SR Legacy 7,793 and FNDDS 5,432 are separately documented |
| **Agent's own file parse** | FNDDS 22,046 portions / 5,395 codes / mean 4.09 / max 16; 18,584 ingredient rows / 5,431 dishes / mean 3.42 / max 20 | **Medium.** Could not be confirmed from a readable primary source (ARS PDFs failed text extraction) |
| **Vendor marketing** | FatSecret's 2.3 M / 58 countries / "100% verified" / "zero duplicates"; MFP's 14 M verified | **Low.** No external audit; FatSecret's own consumer site gives conflicting figures |
| **Unverifiable** | Nutritionix **bulk-database licence** price and terms, and the **scope** of its "Caching Allowed" permission (Syndigo's Terms of Use were not supplied, and the row's tooltip definition did not survive print-to-PDF); CloudKit historical quotas and overages; Hetzner/DigitalOcean prices; Apple's 24-hour norm; the PLD transposition date. **Note the ~$1,850/mo figure has moved out of this class** — it is Nutritionix's published Unicorn starting price (§32) | **Do not build a plan on these.** Get Syndigo's terms in writing — §37 now carries one precise, answerable question; file Apple Feedback for CloudKit pricing |
| **Owner-supplied first-party vendor pages** | MyFitnessPal's database article; Cronometer's data-sources and features pages; Nutritionix's API pricing page | **High for what the vendor *says*; Medium for what is *true*.** These are marketing documents, expert-reviewed at best. Quote them as claims, and note where a claim is hedged in its definition and strengthened in its advice sections (§13c) |
| **Owner-supplied competitor content marketing** | The Fitia comparison article | **Low.** Published by one of the three apps it compares, unsigned, running no test of its own, closing with a discount code, and internally inconsistent on its own numbers. Cite as a vendor position paper — or, for the ~70% UGC figure, not at all (§17) |
| **Owner-supplied peer-reviewed full texts** | Evenepoel 2020 (JMIR); Harvey et al. 2019 (Obesity); Steenhuis & Poelman 2017 (Curr Obes Rep) | **High** for everything quoted from them. Note that two of the three answer questions this memo did not ask — Harvey is logging **adherence**, Steenhuis is **portion-size interventions** — and neither contains any database content |
| **Fabricated** | The MyFitnessPal accuracy statistics in §17, plus the Fitia "~70% user-generated" figure | **Never cite** |
| **Dataset licences read at the publisher's own file or terms page** *(added 2026-08-22, second revision)* | BLS 4.0 = CC BY 4.0 + the MRI attribution requirement + DOI ([blsdb.de/download](https://blsdb.de/download)); Ciqual 2025 = Etalab 2.0 as the sole recorded licence, with exact file sizes ([doi:10.57745/RDMHWY](https://doi.org/10.57745/RDMHWY)); CoFID = OGL v3.0 with file sizes and the 2021 date (GOV.UK); DSLD = CC0 1.0 in its own OpenAPI document, count **214,780** from the API's stats endpoint; NZ FOODfiles = the no-modification and non-transferable clauses ([foodcomposition.co.nz/terms](https://www.foodcomposition.co.nz/terms/)); BEDCA = *"todos los derechos reservados"* with no open licence | **High.** Each read at the rights-holder's own page in this round. **The general rule this round established: for food composition data the licence lives with the *file*, not on the page named "licence"** — four research passes disagreed on three datasets, and in every case the pass that read the download/terms page beat the pass that read a licence-titled page |
| **Patent claim text** *(added 2026-08-22)* | '472 claims 1, 9, 10; '215 claims 8, 9, 15 (the only claims in the family naming the sanity rules) | **High.** '472 claims verified against the granted USPTO PDF's embedded text layer; '215 claims 8/9/15 verified in this round at an independent full-text mirror, the USPTO copy being image-only. Three research passes quoted '472 claim 1 substantially identically |
| **Patent term, assignee and territory** *(added 2026-08-22)* | '472 expiry 2037-07-27 with 483 days PTA; '215 expiry 2036-03-31 with 0 days PTA and a terminal disclaimer; MyFitnessPal, Inc. as assignee with the JPMorgan security interest; US-only, no PCT/EP | **Medium–High.** Term and disclaimer read off the granted patents' faces; the territory finding rests on one commercial patent database, and an independent EPO/Espacenet check was blocked (403) |
| **Patent maintenance-fee status, litigation and post-grant proceedings** *(added 2026-08-22)* | Whether the '472's 3.5-year fee was paid before the 2026-11-22 grace deadline; whether the family has ever been asserted, or challenged at the PTAB | **Unverifiable this round — treat as OPEN.** Every USPTO endpoint (fees, Patent Center, assignment API, PTAB, bulk maintenance-fee data) was unreachable, and the web-search budget was exhausted. Absence of a payment event in a **lagging** feed does not establish non-payment. **Do not treat the patent as lapsed.** Check Patent Center after 2026-11-22 (§37 q. 14) |
| **Legal doctrine and case law in §40** *(added 2026-08-22)* | *Alice*/*Mayo*, *Johnson & Johnston*, *Warner-Jenkinson*, *Commil*, *Halo*, *Global-Tech*, *Markman*, 35 U.S.C. 112(d)/154/251/271/282/298 | **High as to what the cases hold; NOT an opinion.** Citations spot-checked as to reporter, court and year. **This is research, not legal advice, and §40 must not be read in the register of clearance** — claim construction is for a court. One citation, *Recentive Analytics v. Fox*, 134 F.4th 1205 (Fed. Cir. 2025), is **unconfirmed** |
| **Dataset row and nutrient counts not re-verified** *(added 2026-08-22)* | CNF "5,690 foods × 152 nutrients" (a 2015-edition legacy figure; the 2026 portal states none); Open Food Facts 4,701,654 / 956,659 US / 862,056 nutrition-complete (API 503); AUSNUT 16,152 measures and its CC BY 2.5 AU grading (403); Fineli's CC BY 4.0 (403); FNDDS 22,046 portions | **Low–Medium. Do not quote user-facing.** The OFF counts drive every size estimate in §27's 2.6 — re-run them with a proper User-Agent and backoff first. Count CNF's rows from the downloaded ZIP. Note AUSNUT and AFCD are **different datasets**, so AUSNUT's CC BY grading must never be applied to AFCD, which is confirmed CC BY-**SA** |

**What would still settle each row that is not High.** Added so a future round knows exactly what to
ask for, and does not re-request what has already been obtained.

| Still not High | What would settle it |
|---|---|
| §11's empty-state finding (**Medium, unmoved**) | The Lose It! Zendesk food-database section, or MacroFactor/Cronometer help-centre articles describing zero-result behaviour. **None of the nine supplied documents describes any app's empty state** — a targeted attempt was made and failed |
| Cronometer's submission gate, custom-food scoping and sharing model (**Medium**) | The four `support.cronometer.com` articles in §38A. The supplied Cronometer files are marketing pages and do not close them |
| The curated-vs-crowd ratio inside MyFitnessPal (**closed as unmet**) | Nothing first-party publishes it; MFP's own page carries no ratio in any form. Treat any circulating percentage as unsourced, and **do not re-request the blog page** |
| Nutritionix's "Caching Allowed" **scope** (**bounded, not closed**) | `syndigo.com/legal/terms-of-use`, or one written answer to the question now in §37. This is a single email that closes a corner two research rounds have had to leave open |
| Nutritionix **bulk-licence** price for a free app (**Unverifiable**) | A quote. Every published tier excludes Fernlet's shape by its own terms |
| Fernlet's own micronutrient accuracy versus any competitor (**Inference**) | Extending the §25 corpus test to nutrient completeness and comparing a sample against FDC. Nothing external can supply it |
| Per-nutrient mean differences and Bland-Altman limits across five apps (**Open**) | Fallaize et al. 2019 full text — requested, **not** supplied (the file sent under that name is Harvey et al. 2019) |
| A Costco Food Court row from a curated commercial database (**Open**) | The blocked `nutritionix.com/brand/costco-food-court/...` page. The supplied Nutritionix page names **no chain at all** |
| The '472's maintenance-fee status (**Unverifiable, added 2026-08-22**) | One lookup at `patentcenter.uspto.gov` for application 15/093,191, **after 2026-11-22**. Free, thirty seconds, and it is the cheapest possible answer to half of §40 |
| Whether extending the proximity mesh to share user-created **food** records would read on these claims (**Open, and the one that matters**) | A patent attorney. §40.10 carries the question already drafted. Nothing in the public record answers it, because it depends on a design that does not exist yet |
| BLS 4.0's exact archive size, and whether its ZIP carries household-portion weights (**Open**) | Downloading it. The link is token-gated per session so no size is published; the licence question — the one that blocked German localization — **is closed** (§32) |
| Fineli's CC BY 4.0 grading, and the AUSNUT measures file (**Open**) | Opening `fineli.fi/fineli/en/avoin-data` and the FSANZ data-user-licence page **in a browser**. Both 403 every automated fetch, in both rounds |
| Whether MenuStat's missing years (2016, 2019–2022) can be brought under the same CC0 grant (**Open**) | One email to the Harvard Dataverse depositor asking them to add those years to the existing CC0 deposit. Cheapest high-value action in either round |

---

## 34. Appendix A — the 57-query corpus

**Method.** Re-implement `FoodItemSearch.normalized` / `tokens` / `matchVariants` / `score` /
`preparationBias` / `formSpecificityBias` and the full comparator, plus `BundledFoodStore.candidates`'
prefix-AND FTS5 expression, the 10,000-row cap and the ORDER-BY-CASE de-bias; then replay against the
shipped read-only `FoodCatalog.sqlite`. Land it as a Swift test asserting query → expected top-1, or
query → expected non-empty.

**The 11 zero-result queries** (all should return a defensible row):

`bowl of oatmeal` · `two scrambled eggs` · `glass of milk` · `handful of almonds` ·
`piece of chicken` · `bowl of cereal` · `plate of pasta` · `costco cheese pizza slice` ·
`kirkland protein bar` · `whole foods rotisserie chicken` · `chiken breast`

**The 15 wrong-top-1 queries**, with the row currently returned, are enumerated in the table in §8.

The remaining **31 queries returned a defensible top-1** and serve as the regression floor — the
purpose of pinning them is that fixes 1.6/1.7/1.8 must not move them, which is precisely the coupling
hazard §29 demonstrates.

---

## 35. Appendix B — what is actually in the box

| Property | Value |
|---|---|
| File | `FernletKit/Sources/FoodCatalog/Resources/FoodCatalog.sqlite` |
| Size | 59,748,352 bytes (56.98 MiB); git blob identical; 2 commits; **no LFS, no `.gitattributes`** |
| Rows | **118,317** — branded 109,163, srLegacy 8,888, survey 202, restaurant 64, **foundation 0** |
| Source | `source = 'usda'` for 100% of rows |
| Composition | `USDAFoodItems.json` 68,114 + `CuratedSurveyFoodItems.json` 202 + `BrandedCuratedFoodItems.json` 50,000 + 1 synthetic canonical alias |
| Barcodes | 50,000 rows carry a GTIN (42.3%); 0 for srLegacy/survey/restaurant |
| `serving_description` | **Empty on all 118,317 rows** |
| Portions | 7,985 rows (6.7%) carry any; **branded 0 of 109,163**; 15,160 portion entries over **1,876** distinct unit strings; 194 entries with unit exactly `slice`; **468 rows mention slice** |
| Unparseable `serving_unit` | 15,277 rows (12.9%) — GRM 12,376, MLT 2,193, MG 420, IU 193, GM 31, cup 109, serving 26, sandwich 20, piece 11, item 5, double 5, cheeseburger 5, hamburger 4, slice 3, stick 2, meal 2, MC 2 |
| Serving basis | srLegacy 8,839 of 8,888 at 100; branded 1,882 of 109,163 |
| Macros | INTEGER, no calories column (derived 4/4/9 at `NutritionModels.swift:652`); 826 branded + 68 srLegacy rows have all three = 0 |
| Brands | **14,392** distinct branded `brand_source` values, **none searchable** |
| Categories | 331 distinct |
| Indexes | `idx_food_id`, `idx_food_normalized_name`, `idx_food_gtin_upc`, plus FTS5 |
| Survey pizza rows | Exactly 12, none a plain restaurant cheese slice: Pizza rolls, Dessert pizza, Mexican pizza, Breakfast pizza with egg, 3× frozen-pepperoni, 3× White pizza, 2× hot-pocket |
| `restaurant` rows | All 64 are packaged CPG: STARBUCKS 22, STARBUCKS INC 19, Starbucks Coffee Company 15, STARBUCKS VIA 1, Outback Pets 3, AUSSIE OUTBACK 1, POPEYES 1, PANERA AT HOME 1, IHOP AT HOME 1 |
| ODR file | `ODRAssets/FoodCatalogBranded.sqlite` — 364,457 rows, 177,901,568 bytes, all branded, all with GTIN, **zero portions**, `user_version 2`. Gitignored (`.gitignore:11`), untracked, **zero references in `project.pbxproj`** |

---

## 36. Appendix C — sources

**1. Fernlet repo files and tests.** `App/Fernlet/MealResolutionService.swift`,
`App/Fernlet/DishTemplateLexicon.swift`, `App/Fernlet/DishTemplates.json`,
`App/Fernlet/FoodView.swift`, `App/Fernlet/FoodProductWebImporter.swift`,
`App/Fernlet/FoundationDishDecomposition.swift`, `App/Fernlet/FoundationFoodSelection.swift`,
`App/Fernlet/FoodCatalogDatabaseBuilder.swift`, `App/Fernlet/BrandedCatalogResourceLoader.swift`,
`App/Fernlet/BarcodeScanView.swift`, `App/Fernlet/FoodPlanning.swift`,
`App/Fernlet/IngredientSubstitutionSheet.swift`, `App/Fernlet/PrivacyPolicyView.swift`,
`FernletKit/Sources/FernletDomainModel/FoodItemSearch.swift`,
`FernletKit/Sources/FernletDomainModel/NutritionModels.swift`,
`FernletKit/Sources/FernletDomainModel/SettingsModel.swift`,
`FernletKit/Sources/FernletDomainModel/CustomIngredientUpsert.swift`,
`FernletKit/Sources/FoodCatalog/BundledFoodStore.swift`,
`FernletKit/Sources/FoodCatalog/FoodCatalog.swift`,
`FernletKit/Sources/DiaryStore/DiaryStore.swift`,
`Tests/FernletTests/NoTrackingBoundaryTests.swift`, `Tests/FernletTests/FoodCatalogTests.swift`,
`Tests/FernletTests/FoodSearchLabelAndFallbackTests.swift`,
`Tests/FernletTests/BrandedODRCatalogTests.swift`, `Site/index.html`.

**2. Fernlet docs.** [`Docs/No-Tracking-Wall.md`](No-Tracking-Wall.md),
[`Docs/Meal-Estimation-Overhaul-Plan.md`](Meal-Estimation-Overhaul-Plan.md),
[`Docs/FernletSpecificationV3.md`](FernletSpecificationV3.md),
[`Docs/AI-Feature-Expansion-2026-07-23.md`](AI-Feature-Expansion-2026-07-23.md),
[`Docs/AI-Provider-Ladder-2026-07-23.md`](AI-Provider-Ladder-2026-07-23.md),
[`Docs/Localization-Plan-2026-07-19.md`](Localization-Plan-2026-07-19.md),
[`Docs/RemainingWork-2026-07-19.md`](RemainingWork-2026-07-19.md),
[`Docs/RemainingWork-2026-08-20.md`](RemainingWork-2026-08-20.md),
[`Docs/UI-UX-Review-2026-08-16.md`](UI-UX-Review-2026-08-16.md),
`Docs/design-refs/ux-review-2026-08-16/design-spec-2026-08-21.md`,
[`Docs/PrivacyWipeCoverage.md`](PrivacyWipeCoverage.md),
[`Docs/CloudKit-Schema-Deploy.md`](CloudKit-Schema-Deploy.md),
[`Docs/App-Privacy-Nutrition-Labels.md`](App-Privacy-Nutrition-Labels.md),
[`Docs/Privacy-Policy.md`](Privacy-Policy.md), [`Docs/Verifiability.md`](Verifiability.md).

**3. SQLite.** FTS5 reference including `columnsize=0` / `xColumnSize` and bm25 —
https://www.sqlite.org/fts5.html · spellfix1 — https://www.sqlite.org/spellfix1.html

**4. USDA / FDA.** FoodData Central — https://fdc.nal.usda.gov/ · downloads —
https://fdc.nal.usda.gov/download-datasets · API guide — https://fdc.nal.usda.gov/api-guide ·
ARS FNDDS — https://www.ars.usda.gov/northeast-area/beltsville-md-bhnrc/beltsville-human-nutrition-research-center/food-surveys-research-group/docs/fndds/ ·
21 CFR 101.11 menu labeling — https://www.ecfr.gov/current/title-21/part-101/section-101.11

**5. Open Food Facts.** https://world.openfoodfacts.org/ · terms —
https://world.openfoodfacts.org/terms-of-use · data —
https://world.openfoodfacts.org/data · API docs —
https://openfoodfacts.github.io/openfoodfacts-server/api/ · ODbL —
https://opendatacommons.org/licenses/odbl/1-0/

**6. Competitor first-party.** MacroFactor logging —
https://macrofactorapp.com/logging-food/ · MacroFactor changelog —
https://macrofactorapp.com/changelog/ · Cronometer — https://cronometer.com/ ·
MyFitnessPal press — https://www.myfitnesspal.com/press · MyFitnessPal terms —
https://www.myfitnesspal.com/terms-of-service · Lose It! — https://www.loseit.com/ ·
Foodnoms — https://foodnoms.com/ · Syndigo/MFP case study —
https://syndigo.com/resources/myfitnesspal-case-study/

**7. Commercial vendor terms.** FatSecret Platform — https://platform.fatsecret.com/ ·
Edamam FAQ — https://developer.edamam.com/faq · Spoonacular terms —
https://spoonacular.com/food-api/terms · Nutritionix — https://www.nutritionix.com/ ·
MenuStat on Harvard Dataverse — https://doi.org/10.7910/DVN/K4NYTR

**8. Peer-reviewed literature.** https://doi.org/10.2196/18237 · https://doi.org/10.2196/54509 ·
https://doi.org/10.1111/jhn.70148 · https://doi.org/10.1017/S136898001800157X ·
https://doi.org/10.1136/bmjnph-2023-000770

**9. Legal primary sources.** ODbL 1.0 — https://opendatacommons.org/licenses/odbl/1-0/ ·
App Store Review Guidelines — https://developer.apple.com/app-store/review/guidelines/ ·
DSA (Reg. 2022/2065) — https://eur-lex.europa.eu/eli/reg/2022/2065/oj ·
GDPR (Reg. 2016/679) — https://eur-lex.europa.eu/eli/reg/2016/679/oj ·
PLD (Dir. 2024/2853) — https://eur-lex.europa.eu/eli/dir/2024/2853/oj ·
47 U.S.C. §230 — https://www.law.cornell.edu/uscode/text/47/230 ·
*Winter v. G.P. Putnam's Sons*, 938 F.2d 1033 (9th Cir. 1991) ·
*hiQ Labs v. LinkedIn* (N.D. Cal., stipulated judgment 6 Dec 2022) ·
US Patent 11,508,472 B2 — https://patents.google.com/patent/US11508472B2/en ·
FTC Health Breach Notification Rule — https://www.federalregister.gov/documents/2024/04/26/2024-08750/health-breach-notification-rule ·
CJEU C-184/20 — https://curia.europa.eu/juris/liste.jsf?num=C-184/20

**10. Apple platform.** App Store trader requirements —
https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-trader-status ·
CloudKit — https://developer.apple.com/icloud/cloudkit/ · Apple Developer Forums DTS reply on
public-database pricing (Jan 2025) — https://developer.apple.com/forums/

**11. Owner-supplied documents (received 2026-08-22).** Nine PDFs supplied against the §38
blocked-source list. Cited inline as *(owner-supplied PDF: "Title", p. N)*, with the original URL kept
alongside wherever the PDF is a print of a known page. §38.0 records what each one closed.

- **"How MyFitnessPal's Food Database Works"** — print of
  https://blog.myfitnesspal.com/how-food-database-works/ (on-page title *"Understanding MyFitnessPal's
  Food Database and Logging Accuracy"*; published 2025-03-31; written by Samantha Cassetty, MS, RD,
  expert-reviewed by Denise Hernandez, MS, RD, LD; 16 pp.). **First-party marketing, not documentation.**
- **"Accurate Nutrition Database | Trusted Food Data Sources | Cronometer"** — print of
  https://cronometer.com/features/accurate-databases.html (8 pp., ~450 words of body copy). Marketing.
- **"Advanced Features for Accurate Nutrition & Calorie Tracking | Cronometer"** — print of
  https://cronometer.com/features/ (11 pp., ~300 words of substance). Marketing teaser; every section
  links to a deeper page that was **not** supplied.
- **"Nutrition API by Nutritionix"** — print of https://www.nutritionix.com/api (3 pp.; footer
  *"© 2026 Syndigo LLC"*). The binding terms at https://www.syndigo.com/legal/terms-of-use/ and the API
  reference at https://developer.nutritionix.com/docs/v2 were **not** supplied.
- **Evenepoel C, Clevers E, Deroover L, Van Loo W, Matthys C, Verbeke K.** *"Accuracy of Nutrient
  Calculations Using the Consumer-Focused Online App MyFitnessPal: Validation Study."* J Med Internet
  Res 2020;22(10):e18237 — https://doi.org/10.2196/18237 (CC-BY full text, 9 pp.). **Multimedia
  Appendix 1 (the cap-derivation flowchart) and Appendix 2 (the R script) are external files and were
  not included.**
- **Harvey J, Krukowski R, Priest J, West D.** *"Log Often, Lose More: Electronic Dietary
  Self-Monitoring for Weight Loss."* Obesity (Silver Spring) 2019;27(3):380–384 —
  https://doi.org/10.1002/oby.22382 (NIH author manuscript `nihms-1040559`). **Supplied against the
  Fallaize 2019 request; it is a different paper** (§38.0).
- **Steenhuis I, Poelman M.** *"Portion Size: Latest Developments and Interventions."* Curr Obes Rep
  2017;6:10–17 — https://doi.org/10.1007/s13679-017-0239-x. Off-topic for both questions; one finding
  used in §23.
- **"MyFitnessPal vs. Lose It! vs. Fitia (2026): A Calorie Counter Food Database Comparison"** —
  https://fitia.app/learn/article/myfitnesspal-vs-lose-it-vs-fitia-database-comparison/ (dated
  2026-05-21; unsigned; 11 pp.). **A vendor position paper published by Fitia**, one of the three apps
  compared — see §17 and §33.
- **McManus KD.** *"Why keep a food diary?"* Harvard Health Publishing, 2019-01-31 —
  https://www.health.harvard.edu/blog/why-keep-a-food-diary-201901165781. General-audience blog; used
  in §20 for the granularity dietitians ask people to record.

**Provenance and safety note.** All nine were read as **data**. None contained text addressed to an
automated reader, and no instruction inside any of them was acted on. Several carry ordinary
reader-directed marketing calls to action — a Fitia discount code, MyFitnessPal and Cronometer sign-up
prompts, and a Nutritionix sales lead-capture form. Those are recorded here as document character; in
particular, **submitting the Nutritionix contact form is a sales action requiring the owner's own
go-ahead** (§37), not a research step.

---

## 37. Open questions for the owner

Decisions this memo cannot make.

1. **Is data-type-above-relevance still the intended contract?** Option (a): demote via
   `PreparedDishHeuristic` inside `results()`. Option (b): score-first with a gap threshold.
   *Recommendation: ship (a) now; (b) only with explicit sign-off, because it re-ranks every search
   surface in the app and is a product decision, not a bug fix.*
2. **Should the 202-row survey curation be replaced wholesale by FNDDS (2.1/2.2)?** There is no
   curation script in the repo for `CuratedSurveyFoodItems.json`, so the original selection criteria
   are unrecoverable from source. *Recommendation: yes — the selection dropped every plain restaurant
   cheese-pizza row, which is exactly the class the tester hit.*
3. **Is the branded ODR catalog meant to ship at all?** If yes: un-gitignore or LFS-track a
   177,901,568-byte binary, add target membership, set the `branded-food-catalog` tag, and make
   `BrandedODRCatalogTests` fail rather than skip. If no: `BrandedCatalogResourceLoader`, its DocC
   page, `Docs/FileIndex.md:345` and the No-Tracking-Wall entry all describe a capability the shipped
   binary does not have.
4. **Is the 2026-07-19 OpenFoodFacts barcode decision still live?**
   (`Docs/RemainingWork-2026-07-19.md:105-114`, with a 2026-08-09 note that it adds two outbound
   destinations.) The offline ODR catalog it calls "the roadmap endgame" shipped three weeks *before*
   the decision was annotated.
5. **Turn on the web lane by prompt rather than by toggle?** A consent prompt at the moment of first
   miss, naming what leaves and where it goes — versus the current double-gated Settings switch that
   almost nobody will find.
6. **Does a new `FoodItemSource` / provenance case get minted, or do curated rows reuse
   `.aiResolved` / `.branded` as web imports do?** This is a frozen-token, synced-blob decision, not a
   UI change.
7. **Should `queryContainsBrandToken` match on token boundaries?** Fixing it breaks multi-word entries
   ("taco bell", "chick fil a") unless the lexicon is restructured into phrase-vs-token sets, and it
   needs the apostrophe case handled (`mcdonald's` → `mcdonald s`).
8. **Is the ~57 MB-per-regeneration git-history cost acceptable, and should the catalog move to LFS?**
   No `.gitattributes` exists; the path currently has 2 commits.
9. **Send Syndigo one written question about Nutritionix caching scope?** This is the single cheapest
   unblock in the memo, and the owner-supplied pricing page reduced it to one sentence. Suggested
   wording: *"Does the MVP-tier 'Caching Allowed' permission extend to a durable local copy of
   Nutritionix data bundled inside an offline iOS app binary, and for how long may it persist without
   re-request?"* Add a second: *"What is the pricing and licence shape for a free, non-monetised
   consumer app, given that freemium models are excluded from the published tiers?"* **One email
   settles a corner two research rounds have had to leave open** (§18, §33). Note the page's contact
   form asks for name, company, phone and business email — a sales-contact action, so it needs the
   owner's own go-ahead rather than an agent's.
10. **Should this memo's baseline be `main` or `claude/design-impl-2026-08-21`?** FOOD-22 is still
   listed open in `Docs/RemainingWork-2026-08-20.md:103-106` but is implemented on the branch
   (`ff176c7` / `eacaaa6`).

**Added in the second revision (2026-08-22), from Part VII.**

11. **Adopt BLS 4.0 and Ciqual 2025 for the German and French locales?** Both are licence-clean and
   verified at the publisher's own page (§39.4): BLS 4.0 under CC BY 4.0 (7,140 German foods × 138
   nutrients, DOI 10.25826/Data20251217-134202-0), Ciqual 2025 under Etalab Open Licence 2.0 (3,484
   French foods × 74 constituents, 1.5 MB XLSX). *Recommendation: yes — but **after** §30's steps 1–9,
   not before. §20's finding holds: more rows through a comparator with no score floor and data type
   above relevance makes search measurably worse, and these add only ~11% to the row count.*
12. **Does adopting any attribution-bearing source make a "Data sources" screen a shipping gate?**
   Five distinct notices land with Group 1 (OGL v3, OGL-Canada, CC BY 4.0 naming Max Rubner-Institut,
   Etalab 2.0 naming ANSES, later NLOD/CC BY). *Recommendation: yes — one screen rendering licence,
   publisher, version and source vintage per bundled table, with a missing row treated as a
   build-breaking omission, the way `Docs/PrivacyWipeCoverage.md` already works. It also gives §27's
   staleness warning somewhere to live.*
13. **What is the Spanish plan?** There is **no** legally clean Spanish national table — BEDCA carries
   an explicit all-rights-reserved notice (§39.5). Three options: (a) ship a Fernlet-authored Spanish
   display-name layer over the CC0 spine now, using no BEDCA data and needing no permission;
   (b) write to AESAN/BEDCA for the express authorisation their conditions contemplate; (c) treat
   FAO/LATINFOODS as a per-country research track. *Recommendation: (a) now and do not gate the `es`
   launch on anything; (b) in parallel; (c) only if `es` becomes a priority locale.*
14. **Will anyone check the '472's maintenance-fee status after 2026-11-22?** The 3.5-year fee was due
   2026-05-22 and the surcharge grace period closes 2026-11-22. No payment event appears in the public
   record, **but that feed lags and every USPTO fee endpoint was unreachable** — non-payment is not
   established (§33). One lookup at Patent Center for application 15/093,191 settles it, and if the
   fee went unpaid then half of §40 evaporates. *This is a calendar item, not a decision.*
15. **Is one narrow question worth putting to a patent attorney?** §40.10 has it drafted. The valuable
   half is not the arithmetic — it is: *at what point would extending the proximity mesh to share
   user-created **food** records begin to read on these claims?* **That is a design decision the owner
   will otherwise make by accident**, and it is the same boundary §24 draws for DSA and App Store
   reasons (§40.8). *Recommendation: yes, and ask both halves in one letter.*
16. **Adopt NIH's DSLD for supplements?** 214,780 CC0 label records with UPCs, verified live. A scanned
   multivitamin is a guaranteed dead end today, and supplements are where a real share of a user's
   micronutrient intake comes from — the exact axis §16 identifies as failing. *Recommendation: yes,
   as a trimmed projection (low tens of MB), with two UI caveats: values are label-declared, not
   analytically verified, and off-market products are retained deliberately and must be date-flagged.*
17. **Send two low-cost emails?** (a) The Harvard Dataverse MenuStat depositor, asking them to add 2016
   and 2019–2022 to the existing CC0 deposit — that would move the freshest chain data forward four
   years for the price of one message. (b) NIN/ICMR Hyderabad about IFCT 2017 (542 Indian foods × 151
   components — the richest per-food panel found anywhere, currently reachable only through GitHub
   mirrors that re-license what the rights-holder never granted). *Both are the owner's to send; an
   agent should not be initiating correspondence in Fernlet's name.*

---

## 38. Sources I could not reach

The owner offered to supply PDFs, and on **2026-08-22 supplied nine**. **§38.0 records what each one
closed — and, in three cases, what it did not.** **§38.0b, added in the second revision, records what was
resolved directly at primary sources while researching Part VII, and §38.H lists what the second round could
not reach.** Rows the supplied documents satisfied have been
**removed from the tables below** and folded into §38.0; rows that a supplied document *failed* to
satisfy are annotated in place. **A URL still listed below is still genuinely blocked**, and §38 no
longer claims a source is missing that the owner has now provided.

### 38.0 Now resolved by owner-supplied documents

| Document | Gap it was meant to close | Outcome | What it changed in this memo |
|---|---|---|---|
| **"How MyFitnessPal's Food Database Works"** (print of `blog.myfitnesspal.com/how-food-database-works/`) | §38A row 1: the **curated-vs-member-submitted ratio** — the number this memo called "the single number that would let anyone estimate the junk density a crowd tier actually adds" | **Read in full; that gap is UNMET and now CLOSED AS UNMET.** The page carries no ratio in any form — no counts, no percentages, no relative-magnitude wording for any of the three tiers. "percent" occurs zero times, "majority" zero times, and the only number in the document is *"over 20 million"*, stated twice. It also never mentions duplicate entries and never states whether a user-created food is public or private by default. **Do not re-request this page** | Closed a different and more useful set of questions: §13's MFP row rewritten with verbatim badge definitions; *Best Match* shown to be **circular** and **not** dietitian-attributed (§32); the green check shown to certify a *belief* over two merged populations; MFP's **reactive-only** moderation model added to §21; MFP's own coverage argument surfaced in §13 and answered in §20 and §24; §17 re-attributes the 20.5 M figure to the App Store listing; §1 gains the "no incumbent publishes a ranking function" support for Q2 |
| **"Nutrition API by Nutritionix"** (print of `nutritionix.com/api`) | §38B: whether Nutritionix data may be cached, redistributed or shipped offline; pricing tiers; per-tier call limits | **Substantially closed, one clause short.** Prices, tiers, attribution and an explicit **"Caching Allowed"** feature row are now primary-sourced. The page never *defines* caching — that definition lives in a hover tooltip that did not survive print-to-PDF — and the binding Syndigo terms were not supplied. **No chain is named anywhere on the page, so §38B's Costco row is unmet** | §2 item 2 reworded — caching is **priced, not prohibited**; §18's Nutritionix row rewritten with the full tier table and the **monthly-active-user** meter; §19's licensed-vendor corner repriced and kept at *Investigate only* for a better reason; §32 records two corrections against the memo's own prior claims; §33 moves the $1,850 figure from *Unverifiable* to *Verified* while splitting out the still-unpriced bulk licence; §37 gains one precise, answerable question for Syndigo |
| **Evenepoel et al., JMIR 2020 — full text** | §38F row 1: the complete plausibility caps and the per-nutrient Bland-Altman limits | **Caps fully closed; the limits of agreement do not exist as numbers.** All eight caps, the 2.8% rejection with per-nutrient counts, every correlation and the two mean differences are confirmed verbatim. The Bland-Altman limits are drawn only as dashed lines in a raster figure — quoting one would be a measurement off a plot, not a published value | §16's Evenepoel row upgraded to *verified at primary source*; the **mechanism** identified (omission, not error); the **coached-floor** caveat and the uncoached **r = 0.21–0.42** contrast added — **the strongest single external support for Q2 in the memo**; §15 gains the caps as a re-characterised outer guard; **fix 1.14 in §26** turns MFP's five rules plus a completeness check into a serverless submission gate; §23 gains the 49%-portion-error datapoint |
| **Cronometer, "Accurate Nutrition Database / Trusted Food Data Sources"** | §38A: Cronometer's canonical source enumeration with in-app label codes and per-source provenance | **Partly closed.** The ten named sources with their codes are primary-sourced, and *"lab-analyzed data, not crowd-sourced guesses"* is quotable. **Per-source provenance labelling, in-app source display and any food count are absent** from the page | §13's Cronometer row corrected — **CFCD, not CRDB**; **USDA SR28**; **CNF 2015** — with the source list quoted verbatim; the vintage-staleness warning added to §27; the "lab-analyzed" line now cited **with** its own soft spot (Nutritionix and FDC UPC sit in the same list); §13b concedes that the market's most accuracy-obsessed vendor **hosts submissions behind a gate rather than declining them** |
| **Cronometer, "Advanced Features"** | §38A: custom-food scoping, sharing, and search behaviour | **UNMET.** An 11-page marketing teaser carrying ~300 words of substance. No custom foods, no sharing, no search, no ranking, no empty state. Its one usable datum is a privacy posture — *"If you choose to trust us with your personal information, we take that responsibility seriously"* — which is the entirety of its data-security claim | Nothing in §15 or §11 could be upgraded. **The four `support.cronometer.com` rows in §38A stay open**, and §33 records that these files do not close them |
| **Fitia comparison article** | A curated-vs-crowd ratio, and a cross-app comparison | **Closed nothing; contributed one load-bearing quote and one figure to blacklist.** The article ran **no test of its own** — it outsources the head-to-head comparison to a free-trial CTA — and it is published by one of the three apps it compares | Its ranking concession — *"Most casual users tap the first result they get, which is rarely the verified one"* — is now a **hostile-witness** support for Q2 in §1 and §20. Its *"around 70%"* UGC figure is added to §17's **do-not-cite** list; the document is classed as a vendor position paper in §33 |
| **Harvey et al., Obesity 2019** (`nihms-1040559`) | Supplied against §38F's **Fallaize et al. 2019** row | **Wrong paper. The Fallaize row STAYS OPEN.** This is *"Log Often, Lose More"*, a behavioural adherence study with no database content, no reference database and no nutrient-level accuracy analysis | Added to §11 as outcome evidence for the **re-entry** framing (2.4–2.7 sessions/day vs 1.6–1.7; minutes/day non-significant in **all six** months; 34.5% stopped logging by month 6) and to fix 1.9's rationale in §26; the adherence-beats-precision literature is met head-on in §24 rather than ignored |
| **Steenhuis & Poelman, Curr Obes Rep 2017** | — (no §38 row requested it) | **Off-topic for both questions**, and recorded as such so it is never mis-cited: no apps, no databases, no search, no logging, no self-monitoring anywhere in it | One finding used in §23 — people cannot estimate food amounts and are unaware of reference portion sizes — corroborating that **portion handling outranks corpus content** in end-to-end error |
| **Harvard Health, "Why keep a food diary?"** | — (no §38 row requested it) | General-audience blog post; one citation, no database content | Used in §20 for the **granularity dietitians actually ask people to record** — preparation method, sauces, condiments, dressings, toppings, branded drink type and size — i.e. exactly the long tail a curated catalogue covers worst. Note it recommends MyFitnessPal and Lose It! by name, which is what users have been told to expect |

**What the nine did not touch at all.** **Neither leg of Q1 moved.** The §10 measurement is internal to
Fernlet — attaching 364,457 rows moved top-1 for one query in thirty — and no external document can
refute it. And **not one PDF addresses DSA, CloudKit, App Store Guideline 1.2, GDPR or CDA 230**, which
is the entire compliance half of the answer. No supplied document describes any app's zero-result
behaviour, so §11 stays **MEDIUM**. No supplied document names Costco Food Court or any individual
chain, so §38B's Costco hope is unmet.

### 38.0b Resolved at primary sources in the second revision (2026-08-22)

Unlike §38.0, none of these needed the owner. They were fetched directly while researching Part VII, and each
closed a question that a prior research pass had left open, graded wrongly, or could only report at second hand.

| Source | Question it closed | Outcome |
|---|---|---|
| [`blsdb.de/download`](https://blsdb.de/download) and [`blsdb.de`](https://www.blsdb.de/) | Whether Germany's BLS 4.0 may be redistributed inside a shipped app binary — the **blocker on the entire German localization** | **CLOSED, favourably.** CC BY 4.0, stated verbatim, with the MRI attribution requirement and DOI 10.25826/Data20251217-134202-0. 7,140 foods × 138 nutrients, *"kostenfrei verfügbar"*. **Two research passes had graded this "unclear" and advised a permission email — they had read the stale `blsdb.de/license` page carrying the 2018 BLS 3.0 fee terms** (§32) |
| [Recherche Data Gouv API, `doi:10.57745/RDMHWY`](https://doi.org/10.57745/RDMHWY) | Ciqual 2025's actual licence and file sizes | **CLOSED.** Exactly one licence, SPDX `etalab-2.0`. XLSX 1,541,998 B; XLS 4,489,728 B; `compo` XML 69,243,149 B (one pass reported 66.0 MB — wrong). **Refuted the "dual-deposited CC BY 4.0" claim**: the Zenodo record cited for it is a different, 191-food companion dataset |
| [`foodcomposition.co.nz/terms`](https://www.foodcomposition.co.nz/terms/) | Whether New Zealand FOODfiles is genuinely redistributable | **CLOSED, unfavourably.** The grant is *"worldwide, non-exclusive, **non-transferable**, royalty free"* and covers use *"in or as part of any good, product or service"* — **but** *"You must not modify any part of the FOODfiles™ Data."* No-derivatives and non-transferable. **Corrects a structured-field grading of "yes-with-attribution"** (§32) |
| [`bedca.net/bdpub`](https://www.bedca.net/bdpub/index.php) | Whether Spain's BEDCA carries any open licence | **CLOSED.** *"Copyright © 2007 [Consorcio BEDCA y Agencia Española de Seguridad Alimentaria y Nutrición], todos los derechos reservados"*, and no open licence anywhere on the site. The Spanish-localization blocker is real and rests on this notice alone — **not** on the conditions PDF, whose text remains unextractable (§38.H) |
| [DSLD API stats endpoint](https://api.ods.od.nih.gov/dsld/v9/search-filter?q=*&size=1) and its OpenAPI document | DSLD's true record count and licence | **CLOSED.** Exactly **214,780** records; CC0 1.0 declared in the API's own spec. API version is **9.4.0**, not the 9.5.0 one pass reported |
| [GOV.UK CoFID publication page](https://www.gov.uk/government/publications/composition-of-foods-integrated-dataset-cofid) | CoFID's licence and file manifest | **CLOSED.** *"All content is available under the Open Government Licence v3.0, except where otherwise stated"*; xlsx 4.42 MB, old-foods 634 KB, guide 759 KB; last updated 19 March 2021 |
| [`freepatentsonline.com/12057215.html`](https://www.freepatentsonline.com/12057215.html) | Whether the '215 continuation claims any of the five validation rules | **CLOSED, and it refuted the bundle's own headline.** Claims 8, 9 and 15 recite the rules as a *"one or more of (i)–(iv)"* list. **Three of the five rules are claimed, not one** — the non-infringement conclusion survives on claim dependency instead (§40.2, §32) |

**One row moves the other way.** [`nutritionix.com/api`](https://www.nutritionix.com/api) — the page the owner
supplied as a PDF in the first round, and §38.0 recorded as *substantially closed* — returned **HTTP 402 Payment
Required** on re-check. The published tier prices, the "Caching Allowed" matrix and the MAU meter now rest on
that PDF alone, with no live page to re-verify against. §18's figures are unchanged; their **provenance class**
is weaker (§33).

### A. Competitor moderation and database composition — the biggest gap

| URL | Failure | Why it mattered |
|---|---|---|
| `https://blog.myfitnesspal.com/winter-release/` | HTTP 403 | Search snippets indicate it describes "Dietitian-Curated Best Match Results" and an "updated algorithm [that] improves search relevancy for over 2,000 foods" — a dated first-party count of the curated layer |
| `https://support.myfitnesspal.com/hc/en-us/articles/360032622691-Some-food-information-in-the-database-is-inaccurate-Can-I-edit-it` | Cloudflare JS challenge | MFP's first-party statement on entry provenance, editing and correction |
| `https://support.myfitnesspal.com/hc/en-us/articles/360032273292-What-does-the-check-mark-mean` | Cloudflare 403 live | Recovered via Wayback (2021-06-01 and 2025-08-13 captures), so only "unchanged since Aug 2025" is unconfirmed |
| `https://support.cronometer.com/hc/en-us/articles/360020982652-Mobile-Publishing-a-Food-to-CRDB` | HTTP 403 (whole domain) | **STILL OPEN.** Cronometer is the strongest curated-first precedent and this is its verbatim submission gate — photo-of-package evidence and staff review. The §15 quotes still rest on it. **The two owner-supplied Cronometer files are marketing pages and do not close this**; all their marketing says is *"Every item submitted to our database undergoes a verification process"*, with no mechanism, criteria, SLA or rejection rate. Note the article slug is the only surviving evidence for the name "CRDB" — Cronometer's own data-sources page calls the in-house set **CFCD** |
| `https://support.cronometer.com/hc/en-us/articles/360018239472-Data-Sources` | HTTP 403 | **PARTLY CLOSED** by the owner-supplied `cronometer.com/features/accurate-databases.html`, which enumerates all ten sources with codes and vintages (§13). **Still open for:** per-source provenance labelling (lab-analysed vs manufacturer vs user-submitted), the in-app label codes, update cadence, and conflict resolution when two sources carry the same food |
| `https://support.cronometer.com/hc/en-us/articles/360018240312-Create-a-Custom-Food` | HTTP 403 | **STILL OPEN.** How custom foods are scoped (account-private) and what fields they carry. The supplied Cronometer marketing pages never use the term "custom food" at all |
| `https://support.cronometer.com/hc/en-us/articles/360018867471-Sharing` | HTTP 403 | **STILL OPEN.** Gold friend-sharing and Pro client-sharing — **the closest analogue to Fernlet's proximity mesh model**. The supplied pages describe no sharing feature of any kind |
| `https://loseit.zendesk.com/hc/en-us/sections/47271871020692-Food-Logging-Food-Database` | HTTP 403, no Wayback capture | Lose It! claims 56 M+ items against ~57 M users — **the purest UGC-scale case**. The only first-party description of what its verified checkmark certifies and what search shows on zero results. **Its absence is why the empty-state finding in §11 is medium confidence** — and none of the nine owner-supplied documents describes any app's zero-result behaviour, so §11 is unchanged |
| `https://loseit.zendesk.com/hc/en-us` | HTTP 403 | Same domain, root |
| `https://www.fatsecret.com/fatsecret-app-help/add-new-or-custom-foods` | Cloudflare 403, no archive | Whether user-added foods are auto-approved into the public database, who reviews them, how duplicates are blocked — **exactly the design decision Fernlet faces** |
| `https://www.fatsecret.com/fatsecret-app-help/getting-started/cant-find-food` | Cloudflare 403, no archive | The user-facing "food is missing" flow — the moment a UGC database either accepts an unvetted contribution or keeps it private |

### B. Commercial licensing — the one architecturally compatible option

| URL | Failure | Why it mattered |
|---|---|---|
| `https://www.nutritionix.com/database` | HTTP 402 Payment Required | **STILL OPEN, and re-scoped.** The owner-supplied pricing page settled the tiers, prices, the "Caching Allowed" matrix and the MAU meter (§18), and gives item counts of "over 1M grocery foods with barcodes and 203K restaurant foods". What this page would still add is the **bulk database licence** — the only thing on the pricing page left as *"Interested in bulk database licensing? Please contact us."* — plus authoritative per-chain coverage |
| `https://www.syndigo.com/legal/terms-of-use/` | **Not supplied; never fetched** | **Now the load-bearing document for the entire question.** The owner-supplied pricing page establishes that caching is *permitted* at ≥ $999/mo but never defines it; Syndigo's Terms of Use are the binding text that would say whether a durable offline copy inside an app binary is covered, and for how long. §37 carries the one-sentence question that would settle it by email instead |
| `https://developer.nutritionix.com/docs/v2` | Not supplied | The natural-language endpoint's actual contract: how a phrase like "1 slice of cheese pizza" is parsed into food plus quantity, and what serving/portion structure comes back. The supplied marketing page describes it in **one sentence** and gives no schema, no worked example and no accuracy figure |
| `https://www.nutritionix.com/brand/costco-food-court/products/57be0c972eb9319429e7689f` | HTTP 402 | **STILL OPEN — the owner-supplied pricing page names no chain at all.** The actual Nutritionix "Costco Food Court" cheese-pizza row would show how a dietitian-curated restaurant DB models a per-slice serving and states provenance for a venue that publishes nothing |

### C. Open Food Facts — licensing, quality and moderation primary text

| URL | Failure | Why it mattered |
|---|---|---|
| `https://wiki.openfoodfacts.org/ODBL_License` | HTTP 403 (Anubis anti-bot) | **OFF's own plain-language page on how ODbL applies to reusers** — their stated position on attribution placement and app bundling, rather than a reading of the raw licence |
| `https://wiki.openfoodfacts.org/List_of_data_quality_errors_(generated)` | HTTP 403 | Per-error-tag counts across all ~1,254 checks — **the single best quantitative accuracy picture OFF publishes.** Substituted with spot-checks of two tags |
| `https://wiki.openfoodfacts.org/Nutri-Patrol` | HTTP 403 | Canonical description of the moderation queue, moderator privileges, vandalism and duplicate resolution |
| `https://wiki.openfoodfacts.org/Moderation_Team` | HTTP 403 | The moderation team's own rules — the primary statement of how bad entries are handled |
| `https://wiki.openfoodfacts.org/Write_API` | HTTP 403 | Anonymous / global-account contribution rules in more detail than the docs site |
| `https://world.openfoodfacts.org/countries` | HTTP 503 | Authoritative full per-country product-count table (the search-a-licious facet demonstrably lags production: US 688,249 vs the authoritative 956,577) |
| `https://world.openfoodfacts.org/states` | HTTP 503 | Authoritative completeness-state table with exact counts — **the source of every completeness percentage this memo labels point-in-time** |
| `https://world.openfoodfacts.org/facets/data-quality-errors` | HTTP 503 | Live per-tag counts of provably-wrong products |
| `https://world.openfoodfacts.org/api/v2/search?states_tags=en:complete&...` | HTTP 503 on re-check | Prevented independent reproduction of the 18,050 `en:complete` figure |
| `https://datasets-server.huggingface.co/statistics?dataset=openfoodfacts%2Fproduct-database&config=default&split=food` | HTTP 500 | Exact per-column null counts across all 4.69 M rows — **the most rigorous possible answer to "what fraction have complete nutrition facts", independent of OFF's own bookkeeping** |
| `https://search.openfoodfacts.org/docs` | JS-rendered shell | Worked around via `openapi.json` |
| `https://openfoodfacts.github.io/openfoodfacts-server/api/ref-v2/` (and `ref-v3`) | JS-rendered | Definitive v2 search-parameter list and deprecation notice |

### D. USDA / FDA / government

| URL | Failure | Why it mattered |
|---|---|---|
| `https://fdc.nal.usda.gov/api-spec/fdc_api.html` | JS-rendered Swagger, title only | The exact `/foods/search` contract: the full `requireAllWords` description, enumerated `dataType` values, allowed `sortBy` keys, and whether the response carries a relevance `score`. **The `requireAllWords` and `dataType` claims rest on secondary sources because of this** |
| `https://api.nal.usda.gov/fdc/v1/json-spec` | HTTP 403 | Canonical live OpenAPI spec. The static YAML substitute was last modified 2020-04-30 — itself a finding: the published spec is stale relative to the running API |
| `https://api.nal.usda.gov/fdc/v1/foods/search` (further queries) | HTTP 429, DEMO_KEY limit (30/hr, 50/day, shared IP), Retry-After ~3.3 h | Blocked (a) counting SR Legacy via API to cross-check 7,793, (b) reading a live FNDDS pizza record's `foodPortions` array, (c) a direct negative search for a Costco food-court item across all 433 k Branded rows |
| `https://www.ecfr.gov/current/title-21/.../section-101.11` | 302 to a bot gate | Primary regulatory text of the menu-labeling rule — the exact wording of 101.11(b)(2)(ii)(A) and verbatim confirmation that no submission to FDA is required |
| `https://www.fda.gov/food/nutrition-food-labeling-and-critical-foods/menu-labeling-requirements` | HTTP 404 (FDA reorganised) | FDA's plain-language explanation of covered establishments. Sibling pages also 404 |
| `https://catalog.data.gov/dataset/dohmh-menustat` | HTTP 404 | Federal catalog metadata and terms of use for the MenuStat mirror (NYC Open Data's Socrata record shows `licenseId: null` — **a real ambiguity for redistribution from that mirror**) |
| `https://www.menustat.org/data.html` | **DNS SERVFAIL — domain no longer resolves** | The canonical index of every annual file plus the per-year Restaurant Data Availability spreadsheet. **Without it, whether the 2019–2022 years absent from Dataverse are recoverable in usable form is unresolved** |
| `https://www.menustat.org/methods-for-researchers` | DNS SERVFAIL | MenuStat methodology, per-year restaurant availability, Data Completeness Documentation PDF |
| `https://www.ars.usda.gov/ARSUserFiles/80400530/pdf/fndds/FNDDS_2021_2023_factsheet.pdf` | PDF text extraction failed | Would have confirmed the 22,046-portion figure from a primary source rather than an agent's XLSX parse |
| `https://www.canada.ca/.../copyright-guidelines-canadian-nutrient-file.html` | HTTP 403 / empty body | Health Canada's exact required attribution wording for the CNF, and any restriction on redistributing it inside a commercial app |
| `https://www.foodstandards.gov.au/science-data/food-composition-databases/ausnut-2023/data-files` | HTTP 404 (FSANZ moved it) | Definitive AUSNUT 2023 file list with exact food counts and formats |

### E. Apple platform — CloudKit costs and API contracts

| URL | Failure | Why it mattered |
|---|---|---|
| `https://developer.apple.com/support/allowances-cloudkit/` | **HTTP 404 — page removed** | **Apple's own CloudKit allowance/quota table — the single missing primary source for public-database free-tier numbers.** Its removal is consistent with the DTS statement that pricing is no longer public |
| `https://developer.apple.com/documentation/cloudkit/ckdatabase` | JS-rendered shell, title only | Canonical statement on public-database readability, write/sign-in requirements and quota attribution. Sourced from a forums thread quoting the docs instead |
| `https://developer.apple.com/documentation/cloudkit/ckdatabase/scope-swift.enum/public` | HTTP 404 | Exact per-scope semantics |
| `https://developer.apple.com/documentation/cloudkit/using_the_cloudkit_console_to_manage_databases` | HTTP 404 | **What moderation tooling the CloudKit Console actually provides** (query, bulk delete, audit, "Act as iCloud") — which determines whether manual moderation of a public food DB is even practical |
| `https://developer.apple.com/documentation/cloudkitjs/setting_up_cloudkit_js` | HTTP 404 | Current detail on CloudKit JS and server-to-server keys — the mechanism a moderation backend would use |
| `https://developer.apple.com/documentation/network/nwrelay` | HTTP 404 | Concrete Network-framework relay/OHTTP API surface for evaluating an oblivious lookup endpoint |
| `https://developer.apple.com/documentation/naturallanguage/nlembedding` (and `nlcontextualembedding`) | JS-rendered | Worked around via DocC JSON, which gave symbol lists but not prose — **so `NLContextualEmbedding`'s `dimension`, `maximumSequenceLength` and on-disk size remain unconfirmed** |
| `https://developer.apple.com/documentation/corespotlight/cssearchableitemattributeset/rankinghint` | JS-rendered | The "1 to 100" range for `rankingHint` comes from a secondary write-up, not Apple's text |

### F. Academic and legal full texts

| URL | Failure | Why it mattered |
|---|---|---|
| `https://mhealth.jmir.org/2019/2/e9838/` | Empty body | **STILL OPEN.** Full text of **Fallaize et al. 2019** with per-nutrient mean differences and Bland-Altman limits across five apps. **The owner-supplied `nihms-1040559.pdf` is not this paper** — it is Harvey et al. 2019, *"Log Often, Lose More"* (§38.0). Note also, from the now-read Evenepoel full text, that Bland-Altman **limits of agreement are frequently published only as figure annotations**; if Fallaize is obtained, check whether its limits exist as numbers before planning around them |
| Evenepoel 2020 **Multimedia Appendix 1 & 2** (linked from the JMIR article; external files) | Not supplied | The Evenepoel cap-derivation **flowchart** (PNG) and the **in-house R script** (DOCX) that implement the iterative threshold fit. Only the prose description at p. 3 is available. Would matter only if the caps were ever reused as more than an outer guard — which §15 advises against |
| `https://dl.acm.org/doi/10.1145/1571941.1572114` | HTTP 403 | Cormack/Clarke/Buettcher RRF paper — **the k = 60 constant could not be confirmed from primary text** |
| `https://law.justia.com/cases/federal/appellate-courts/F2/938/1033/294363/` | HTTP 403 | *Winter v. Putnam* full opinion; confirmed via indexed summaries instead |
| `https://www.ftc.gov/business-guidance/blog/2024/04/updated-ftc-health-breach-notification-rule...` | HTTP 403 | FTC's own prose on the amended HBNR; corroborated via the Federal Register listing |
| `https://eur-lex.europa.eu/eli/dir/2024/2853/oj/eng` (transposition article + recitals) | Partial fetch | **The transposition deadline and the claimed "mobile health application" recital could not be located.** Art. 2(1)'s applicability date is verified |

### G. Miscellaneous

| URL | Failure | Why it mattered |
|---|---|---|
| `https://customerservice.costco.com/app/answers/detail/a_id/1206/...` | Error/navigation shell; the answer now reads "This answer is no longer available" | Costco's own primary statement on where food-court nutrition can be obtained — direct proof it publishes no machine-readable dataset |
| `https://costcoguides.com/costco-food-court-nutrition-facts/` | HTTP 403 | A secondary transcription of current in-warehouse signage — a fourth independent data point on the 699/710/760 spread |
| `https://www.hetzner.com/cloud/` | Client-rendered price table | The €4/mo CX22 figure and 20 TB allowance are unverified. **Low stakes — infrastructure is not the binding constraint** |
| `https://github.com/phiresky/sql.js-httpvfs/issues/10` | Comment thread not returned | A firmer account of why FTS5 must score every matching row before `ORDER BY rank` can apply LIMIT |
| `https://www.postman.com/api-evangelist/.../food-data-central-api` | JS-rendered | Fallback mirror for the blocked FDC spec |

### H. Second-revision blocks (2026-08-22) — Part VII research

| URL | Failure | Why it mattered |
|---|---|---|
| `https://patents.google.com/patent/US12057215B2/en` | **HTTP 503**, repeatedly, across the whole session | The primary bibliographic record for the continuation: term, terminal disclaimer, PTA, legal events, family. **Worked around** — claims 8/9/15 read at `freepatentsonline.com`; term and disclaimer taken from the granted patent's face as reported by the verification pass. A second independent read would still be worth having |
| `https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/12057215` (and `downloadBasicPdf`) | Empty body to WebFetch; the document is an **image-only scan with no text layer** | The authoritative front page of the '215 — PTA days, the terminal-disclaimer notice, the assignee address. The verification pass read it by rendering the pages; it could not be re-read here |
| `https://fees.uspto.gov/MaintenanceFees/...` (patent 11,508,472) | **HTTP 403** (CloudFront "Request blocked"); the JSON sibling returns 406 | **The single most decision-relevant unresolved fact in §40.** Whether the 3.5-year fee was paid before 2026-11-22. If it was not, the '472 lapsed on that date |
| `https://patentcenter.uspto.gov/retrieval/public/v2/application/data?...15093191` | Angular single-page-app shell; the data API needs a browser session | Would have confirmed fee status **and** definitively closed the no-pending-continuation question. The conclusion instead rests on the reissue time bar (§40.5), which is a firmer basis anyway |
| `https://bulkdata.uspto.gov/data/patent/maintenancefee/` | Connection failed entirely (zero bytes) | The greppable authoritative record of every maintenance-fee payment event — the fallback for the row above |
| `https://assignment-api.uspto.gov/patent/lookup?query=11508472` | Empty response body | Would have revealed any assignment recorded after 2024-07-26 that a commercial database has not indexed — relevant because **a change of owner is the main way this patent's risk profile could shift** (§40.10) |
| `https://developer.uspto.gov/ptab-api/proceedings?patentNumber=11508472` | 301 to a credentialed Open Data Portal | Would have converted "no PTAB proceeding found" from **absence of evidence** into verified absence (§33) |
| `https://www.bedca.net/bdpub/UsoBD.pdf` | Fetches, but the embedded fonts carry **no ToUnicode map**, so no text can be extracted | BEDCA's verbatim Spanish conditions — the no-derivatives and express-authorisation clauses. **The blocker is nonetheless established** by the site's all-rights-reserved notice (§38.0b), but the quoted Spanish must not be reproduced as verified text (§32) |
| `https://fineli.fi/fineli/en/avoin-data` | **HTTP 403** to every automated fetch, in both rounds | THL's authoritative statement of Fineli's CC BY 4.0 licence and required attribution. Fineli stays **unverified** and must be browser-checked before a single Finnish row ships |
| `https://fcdb.fooddata.dk/` (formerly `frida.fooddata.dk`, now a 301) | JavaScript single-page app returning only `Loading...` | Denmark's Frida disclaimer and terms — the page that would say whether "free with credit" is a redistribution licence. It cannot be read programmatically at all, which is why Frida stays *unclear* |
| `https://www.foodstandards.gov.au/.../ausnut/.../foodmeasures` and `.../datauserlicenceagreement`; `https://data.gov.au` CKAN API | **HTTP 403** bot walls, including with a browser user agent | AUSNUT 2011-13's 16,152-measure count, real file size, and the separate FSANZ Data User Licence Agreement. Note **AUSNUT and AFCD are different datasets** — AFCD's CC BY-**SA** grading *is* confirmed from FSANZ's own licence page, and must not be softened by AUSNUT's reported CC BY 2.5 |
| `https://openknowledge.fao.org/...` (WAFCT 2019 record) | **HTTP 403**; the DSpace REST API returns 401 | FAO's machine-readable rights field for the West Africa table. The CC BY-NC-SA 3.0 IGO string stays **unconfirmed** — immaterial, since NC and SA each disqualify independently (§32) |
| `https://www.fao.org/fileadmin/templates/food_composition/documents/density_DB_v2_0_01.pdf` (copyright page) | Subset font with no character map on the rights page only | The FAO/INFOODS Density Database's *"All rights reserved … upon request"* sentence. The **counts** (638 entries / 20 groups / 11 sources) extracted cleanly; the rights language did not |
| `https://world.openfoodfacts.org/api/v2/search?countries_tags=en:united-states&...` | **HTTP 503** (aggressive rate limiting) | The US product and nutrition-completeness counts that drive **every size estimate in §27's 2.6**. Re-run with a proper User-Agent and backoff before any bundle-size decision (§39.7) |
| `https://www.nutritionix.com/api` | **HTTP 402 Payment Required** | Re-verification of the tier prices, the "Caching Allowed" row and the MAU meter that §18 now sources solely to the owner-supplied PDF |
| `https://www.mext.go.jp/b_menu/9.htm` | **HTTP 404** (site restructured) | Japan's ministry terms of use — the page that would establish whether the Standard Tables of Food Composition fall under the CC BY-compatible Government of Japan Standard Terms v2.0. Japan stays **unverified** (§32) |
| `https://health-products.canada.ca/...` CNF user guide | **HTTP 403** | CNF 2026's actual food and nutrient counts. The circulating 5,690 × 152 figures are **2015-edition legacy numbers** and must be counted from the downloaded ZIP before use (§39.7) |
| **WebSearch budget** | **Exhausted (200/200 calls)** partway through the second round | Litigation and PTAB searches for the '472, and the *Recentive Analytics* citation check, could not be run. All three are recorded as open in §33 |


---

# PART VII — TWO FOLLOW-UP QUESTIONS (second revision, 2026-08-22)

The owner read the memo and asked two things it had not answered. **(A)** *"What other sources of food
data would be good? Currently I have USDA data only. One or two of the websites mentioned other
datasets."* **(B)** *"For copying MyFitnessPal's consistency rules, are there things we need to
consider since it's patented?"*

§39 answers (A). §40 answers (B), and because (B) is a direct question about **fix 1.14 in §26**, that
fix is rewritten in place with the outcome rather than left standing as originally written.

Both sections are licence-first and claim-first respectively, for the same reason: **the binding
constraint on a free, no-server, open-source app is never quality — it is whether the thing may be
copied into a shipped binary at all.** Share-alike, NonCommercial and no-derivatives are decisive
facts in §39; the difference between a patent's claims and its specification is the decisive fact in
§40.

---

## 39. What else is worth adding to the catalog, and what the licence actually permits

### 39.1 What USDA already gives Fernlet

**FoodData Central is the best-licensed food dataset in the world, and it is not close.** Verbatim:
*"USDA FoodData Central data are in the public domain and they are not copyrighted"*, *"published
under CC0 1.0 Universal (CC0 1.0)"*, *"No permission is needed for their use"*, with citation merely
requested ([fdc.nal.usda.gov/api-guide](https://fdc.nal.usda.gov/api-guide)). It is the **only** source
in this entire survey with **zero downstream obligation** — no attribution requirement, no share-alike,
no permission gate, and no contamination of anything merged with it.

That single fact should govern the architecture of everything below: **keep the CC0 rows as the spine
and never merge a share-alike source into them.** §27's 2.6 already applies this rule to Open Food
Facts, and the `attachBrandedSource` seam already implements the mechanism.

USDA also still has slack Fernlet has not taken. From §35: the shipped file carries **foundation 0
rows** and **survey 202 of 5,431 FNDDS food codes**. `FoodItemSearch.dataTypePriority` ranks
`.foundation` highest, so **the top-priority tier is unreachable by construction** — and Foundation
Foods is USDA's deepest analytically-derived nutrient tier. Nothing in §39 is worth doing before
§27's 2.1 and 2.2, which are free in licence terms and are already in the plan.

### 39.2 What USDA structurally cannot give

Six things, and the first is the one that matters most given the localization work already merged to
`main` (§ *Localization Phase 1*):

1. **Non-English food names. Ever.** Every row in FDC is English. There is no Spanish, French or German
   name anywhere in the dataset, and there never will be — it is a US federal survey and labelling
   dataset. A German-locale Fernlet backed by a USDA-only catalog renders a German UI around
   `Cheese, mozzarella, whole milk`. The localization wall forks tokens from display strings; it cannot
   invent a display string that does not exist.
2. **Non-US market foods.** Vollkornbrot, Quark, Leberwurst, crème fraîche, boudin blanc, fromage
   blanc, chorizo ibérico, morcilla, turrón. FDC's branded layer is US GTINs submitted through
   GDSN/1WorldSync; its survey layer is what NHANES respondents in the United States ate.
3. **Household-measure vocabulary in any language but English.** This is not cosmetic: it is exactly
   what fix **1.4**'s unit parser and **2.4**'s `slice`/`piece` gap consume. A localized unit parser
   needs a localized measure vocabulary, and USDA has one language.
4. **Dietary supplements.** FDC has no supplement labels at all. A user who scans a multivitamin today
   gets a dead end, and multivitamins are where a meaningful share of any user's actual micronutrient
   intake comes from — which is the exact axis §16 identifies as the one that fails.
5. **Restaurant and food-court items.** Settled in §31: 21 CFR 101.11 requires disclosure *to the
   customer*, and creates no submission to FDA, no registry and no feed.
6. **Micronutrient depth beyond its own panel** for foods outside Foundation Foods — and Fernlet ships
   zero Foundation rows, so today it has none of that depth at all.

Items 1–3 are the localization answer. Item 4 is a genuinely cheap fix nobody has proposed. Items 5–6
are already covered by §31 and §27.

### 39.3 The ranked adoption table

Sizes are bytes where a `HEAD` or a publisher manifest gave one, and are marked *not published* where
no figure exists rather than estimated. Row and nutrient counts are marked **unverified** where this
round could not reach a primary source — several figures circulating in the research bundle are legacy
numbers carried forward, and §39.7 says which.

#### Group 1 — free and clearly redistributable: adopt

| Dataset | Publisher | What it adds | Licence | Redistributable in a bundled app? | Size | Verdict |
|---|---|---|---|---|---|---|
| **Bundeslebensmittelschlüssel 4.0** | Max Rubner-Institut (German federal nutrition research institute) | **7,140 German-named foods × 138 nutrients** — the deepest per-food nutrient panel of any freely-licensed table found. Adds plant drinks, pseudocereals, composite dishes; every value carries a documented source, and data gaps are explicitly marked | **CC BY 4.0**, verbatim on the publisher's own download page: *"Die Daten des Bundeslebensmittelschlüssels (BLS) stehen als Open Data zur freien Verfügung. Die Nutzung ist unter der Lizenz CC BY 4.0 … gestattet."* DOI 10.25826/Data20251217-134202-0 | **Yes.** One attribution line — *"Bei Verwendung ist das Max Rubner-Institut als Herausgeber zu nennen"* | ZIP `BLS_4_0_2025_DE.zip`; **size not published** (token-gated link). ~1 M cells → single-digit MB | **ADOPT — top pick.** See §39.4 |
| **Table Ciqual 2025** | ANSES (French food-safety agency) | **3,484 French-named foods × 74 constituents**, incl. full fatty-acid and individual-sugar breakdown; culturally correct food set (plats composés, charcuterie, fromages) | **Etalab Open Licence 2.0** (SPDX `etalab-2.0`), the single licence recorded on the authors' own deposit. Permits commercial reuse, modification and redistribution | **Yes, with attribution** to ANSES plus the version date | **XLSX 1,541,998 B (1.5 MB)**; XLS 4,489,728 B; `compo` XML 69,243,149 B — take the XLSX | **ADOPT — second pick.** See §39.4 |
| **Canadian Nutrient File 2026** | Health Canada | Bilingual **EN/FR** food names *and* a bilingual household-measure vocabulary (`measure_name.csv`: `Measure_Description_and_Unit_EN` / `_FR`) — a second, independently-licensed source of French display strings, and the only ready-made bilingual measure table found | **Open Government Licence – Canada**, verbatim: *"Copy, modify, publish, translate, adapt, distribute or otherwise use the Information in any medium, mode or format for any lawful purpose"* | **Yes, with attribution** — *"Contains information licensed under the Open Government Licence – Canada."* The explicit **translate/adapt** grant is what makes the FR names safely reusable | Full ZIP 26,656,195 B; `measure_weight_conversion.csv` 834,367 B; `measure_name.csv` 67,867 B. Published 2026-05-14 | **ADOPT — third pick.** See §39.4 |
| **NIH Dietary Supplement Label Database** | NIH Office of Dietary Supplements | **214,780 supplement label records** (verified live 2026-08-22 via the API's own stats endpoint), with UPC, brand, full Supplement Facts panel and %DV. Closes the multivitamin dead-end and attacks micronutrients from the *intake* side | **CC0 1.0**, declared in the API's own OpenAPI document. Trademark caveat survives CC0: no NIH logo, no implied endorsement | **Yes, unconditionally** | Full-DB CSV zip 92,613,625 B; XLSX 271,506,687 B; JSON 584,344,994 B — **do not bundle whole** (a full record is ~5.6 KB → ~1.2 GB). The projection Fernlet needs is low tens of MB; a curated top-N is < 10 MB | **ADOPT, trimmed.** Strongest non-localization pick |
| **CoFID 2021** | OHID / Public Health England | ~2,887 UK foods with **185 nutrients** — the deepest micronutrient breadth under a free open licence after BLS. British food vocabulary (aubergine, courgette, digestive biscuit) | **Open Government Licence v3.0**, verbatim on GOV.UK: *"All content is available under the Open Government Licence v3.0, except where otherwise stated."* OGL v3 grants the right to *"exploit the Information commercially and non-commercially"* | **Yes, with attribution** | xlsx **4.42 MB** + old-foods xlsx **634 KB** + user guide **759 KB**; last updated **19 March 2021** | **Optional adopt.** Buys nutrient depth, no localization; oldest of the four |
| **MenuStat Annual Data** | Harvard Dataverse (Cleveland, 2022), from NYC DOHMH | 8 annual waves 2008–2018 of US chain-restaurant menu items; 71,172 rows / 96 chains in the 2018 file alone | **CC0 1.0** (`rightsIdentifier` CC0-1.0, SPDX) | **Yes, unconditionally** | 8 `.tab` files, **104.8 MB** total | **Already in §18.** Ship as a *labelled historical layer* — newest year is 2018 |
| **Livsmedelsdatabasen** | Livsmedelsverket (Sweden) | ~2,500 Swedish foods, >50 nutrients, JSON API | **CC BY 4.0**, verbatim: *"The data is published under the Creative Commons Attribution 4.0 license"* / *"The Swedish Food Agency must be stated as the source"* | **Yes, with attribution** | Small; sizes not published | **Park.** Clean licence, no target locale |
| **Matvaretabellen** | Mattilsynet (Norway) | 2,121 Norwegian foods; XLSX/CSV/JSON/ODS **plus a documented REST API** and open source | **Norwegian Licence for Open Government Data (NLOD)** | **Yes, with attribution** | Small | **Park.** The model of a well-published national table |
| **Fineli** | THL (Finland) | 4,232 foods × 55 or 74 components, CSV + API | Reported **CC BY 4.0** — **but the publisher's own open-data page returned HTTP 403 to every fetch, so this rests on secondary reporting of a page nobody in either round could read** | **Probably yes** — re-verify in a browser before shipping a single Finnish row | Not published | **Park, and do not promote without a browser check** |
| **gtinsearch.org** (Datakick successor) | Community | **6,561** GTIN→product items | **CC0 1.0** | **Yes, unconditionally** | Trivial | **Watch, don't adopt.** Perfect licence, negligible scale — but the one destination a future *outbound* contribution flow could target with no share-alike or privacy conflict |

#### Group 2 — free but licence-encumbered: the obligation is the point

| Dataset | Publisher | What it adds | Licence | Redistributable in a bundled app? | Size | Verdict |
|---|---|---|---|---|---|---|
| **Open Food Facts** | Open Food Facts (FR non-profit) | The only real branded/barcode expansion available, and the **only** source here with meaningful FR/DE/ES market coverage | **ODbL 1.0** database + DbCL contents + **CC BY-SA images**. Verbatim: *"Derivative works must be shared under the same conditions"* | **Yes — but share-alike attaches to the shipped artifact.** ODbL §4.5(b) means the Swift source is untouched; §4.6(b) is satisfied by publishing the generator | CSV.gz **1,275,171,186 B** (measured §27); a filtered US slice lands at **250–470 MB** | **Already §27's 2.6.** Unchanged: separate file, never merged. **Do not bundle the images** — a second share-alike regime with per-image author attribution |
| **Australian Food Composition Database** | FSANZ | 1,588 foods, up to 268 nutrients | **CC BY-SA 3.0 AU.** Three confirmed obligations: ShareAlike (*"You may only distribute a Derivative Work if You apply this Licence Agreement to it"*), a **DRM prohibition** (*"You must not impose any technological measures … that restrict the ability of a recipient"*), and a mandatory **Limitation of Data Statement** on every distributed copy | **Legally yes, practically no.** ShareAlike would bind the merged catalog permanently; and unlike ODbL, CC BY-SA 3.0 has **no parallel-distribution escape hatch** for App Store DRM | Small | **SKIP.** The DRM clause is the reason, and it has no cure |
| **FAO/INFOODS regional tables** (e.g. Western Africa 2019) | FAO / WAHO / Bioversity | 1,028 West African foods, EN + FR names — genuinely the best open source for African indigenous foods | Reported **CC BY-NC-SA 3.0 IGO**. **The licence string could not be verified** — the FAO index page states no licence and the Open Knowledge repository returned 403 to every attempt in both rounds | **No.** NC and SA each disqualify independently, so the unverified string does not change the answer | Not published | **SKIP** — but record it as a real equity loss, not a shrug |
| **Phenol-Explorer** | INRA consortium | 35,000+ polyphenol content values across 400+ foods | **CC BY-NC** | **No** | Not published | **SKIP.** NC binds permanently, and no user has a polyphenol target |
| **OpenNutrition Foods** | OpenNutrition (independent) | ~300k generic/branded/restaurant items | **ODbL** + modified DbCL, with attribution *"in every interface displaying data"* | **Only under ODbL, plus a per-screen credit** | Not published | **SKIP.** Inherits OFF's obligations without OFF's scale, adds a per-interface credit, and its values are **LLM-imputed over public sources and validated by other models** — a provenance problem for an app that computes a wellbeing signal from logged food |
| **Nutrola Open Food Nutrition Dataset** | Nutrola (commercial vendor) | Claimed 500k+ "verified" entries | **CC BY-SA 4.0** — which explicitly covers *sui generis* database rights, so ShareAlike attaches to an adapted database | **Only under CC BY-SA 4.0** | CSV ~210 MB / 48 MB gz | **SKIP.** Unauditable vendor self-claims, and the vendor's own blog gloss on when ShareAlike triggers does not describe bundling a copy inside a shipped binary. Do not take a licensor's reading of its own licence |

#### Group 3 — paid or closed

| Dataset | Publisher | What it adds | Licence | Redistributable in a bundled app? | Size | Verdict |
|---|---|---|---|---|---|---|
| **NCC Food and Nutrient Database (NCCDB)** | Nutrition Coordinating Center, University of Minnesota | ~18–20k foods × 166–178 nutrients with **near-zero missing values** — the actual quality differentiator behind Cronometer, MacroFactor and Carbon | Proprietary. *"A license must be obtained"*; *"Price is based on scope of use."* Agreements generally run a **2-year term** with a mutually agreed defined scope | **No, at any price.** Two independent killers: a bundled offline catalog does not expire, so a 2-year term would force stripping the catalog at term end; and an Apache-2.0 app whose build is publicly reproducible *redistributes* its catalog to the world, which no scope-of-use clause permits | Excel, no API | **SKIP — structurally, not financially.** The only public price anchor is the NDSR research list ($6,600 initial + $4,400/yr) and that buys **one Windows seat**, not redistribution |
| **Nutritionix / Syndigo** | Syndigo | 1.27 M items incl. 202,837 restaurant items | Paid. Published tiers **$499 / $999 / $1,850+ per month, billed annually**, metered by **monthly active users** (2 / 200 / 1,000 / custom) — **as read from the owner-supplied PDF in §18. `nutritionix.com/api` returned HTTP 402 on re-check this round, so those prices could not be independently re-verified** | **Caching is a priced feature at ≥ $999/mo, scope undefined** (§18) | Bulk CSV/JSON on a separate quote-only licence | **SKIP, unchanged.** 1,000 MAU is the ceiling on the top *published* tier and a free app is off the price list entirely (§18, §32) |
| **Edamam** | Edamam | ~900k foods, 680k UPCs | Paid to $999/mo. Terms forbid building a copy: caching *"does not constitute permission to copy or reuse the Edamam data"* | **No** | API only | **SKIP.** API-only defeats offline-first before price is even reached |
| **Passio Nutrition-AI** | Passio | 2.5 M items + on-device recognition SDK | $99 / $599 / $2,999 per month, token-metered | **No** — the DB is not separable from a closed-source SDK | SDK | **SKIP on three independent grounds:** cost scales with users on a free app; a closed-source SDK with unauditable outbound behaviour is exactly what `NoTrackingBoundaryTests` exists to reject; and a vendor binary cannot be held to the Power-of-10 standard |
| **University of Sydney GI database / AJCN 2021 GI tables** | U. Sydney SUGiRS; Atkinson et al., AJCN | Glycemic index / glycemic load for 4,000+ items, split by ISO-methodology quality tier | Sydney: no published terms at all (`/terms-of-use` 404s) — default all-rights-reserved, with the machine-readable AUSNUT GI edition licensed by the GI Foundation for a fee. AJCN: **Elsevier open-access user licence — non-commercial** | **No** | Supplemental tables | **SKIP.** The "GI values are facts under *Feist*" argument is not wrong, but an Apache-2.0 project has **no plausible deniability** — the database is public and inspectable by construction. If GI matters, ask the GI Foundation; the research rate is nominal |
| **EuroFIR FoodEXplorer** | EuroFIR AISBL | Federated search over ~40 European tables | Membership, ~€800+/yr for the cheapest small-organisation tier | **No at any tier** — it is an *access* layer; the underlying tables keep their national licences | Web only | **SKIP.** Paying EuroFIR would not make BEDCA or NEVO redistributable. Its one honest use is free reconnaissance |
| **GS1 / GDSN, UPCitemdb, Barcode Lookup and peers** | GS1, various | GTIN→product lookup | GS1 US API add-on a **$6,500 flat fee** and returns mostly company data; Verified by GS1 caps free lookups at 20–30/day. UPCitemdb forbids redistribution | **No** | API only | **SKIP.** And note the wall problem: a per-scan lookup is a new outbound destination that tells a third party what the user just ate — `Docs/No-Tracking-Wall.md` allowlists **no** food-data host today |
| **Souci-Fachmann-Kraut; BDA Italy; Trustwell/ESHA; 1WorldSync; Label Insight/SPINS** | Various commercial | German reference tables; Italian epidemiological DB; label-compliance and retail-intelligence platforms | Commercial book; €50-minimum donation gate scoped to *non-commercial research*; enterprise contracts with no published price and no bulk redistribution product | **No** | — | **SKIP.** SFK is additionally **redundant** now that BLS 4.0 is CC BY 4.0 |

#### Group 4 — traps: things that look free and are not

These are the rows that would ship an infringement if a reader keyed off a summary line instead of the
licence text. Each is stated with the clause that bites.

| Dataset | The trap | The clause |
|---|---|---|
| **BEDCA** (Spain) | The obvious source for the Spanish locale, and the **most restrictive** source in the whole survey | Its site carries *"Copyright © 2007 [Consorcio BEDCA y Agencia Española de Seguridad Alimentaria y Nutrición], **todos los derechos reservados**"* (verified 2026-08-22) and **no open licence anywhere**. Its published conditions additionally require express AESAN/BEDCA authorisation for non-personal electronic reuse and forbid modification. **Honesty note:** the conditions PDF at `bedca.net/bdpub/UsoBD.pdf` fetches but its fonts carry no ToUnicode map, so the Spanish clauses **could not be machine-verified in either round** — do not reproduce them as quoted text. The operative finding stands on the all-rights-reserved notice alone |
| **NEVO** (Netherlands) | Free, downloadable, and it never grants redistribution | *"Using the information from NEVO online is only allowed **unchanged** and stating the source and version number"*; *"The user is entitled to make **additions** … The user is **not** entitled to make amendment"*; *"The user is not allowed to charge (end)users for the use of NEVO online … data."* Fernlet uniquely satisfies the no-charge clause **by being free** — but the document opens *"By requesting a version of the NEVO online dataset, agreement will come into effect"*, i.e. a bilateral click-through, and **nowhere grants redistribution.** Clearing one clause is not a licence |
| **New Zealand FOODfiles** | Reads as a permissive commercial grant; is a **no-derivatives, non-transferable** licence | Verified verbatim 2026-08-22: the grant is *"a worldwide, non-exclusive, **non-transferable**, royalty free, right to access and use"* including *"in or as part of any good, product or service"* — **but** *"You must not modify any part of the FOODfiles™ Data."* Normalising rows into a merged SQLite is precisely the modification forbidden. **This is the fact-check's clearest catch:** a research summary graded this "yes-with-attribution" in its structured field while its own prose said otherwise |
| **Frida** (Denmark) | "Free of charge, credit on each use" is not a redistribution licence | DTU asserts copyright and names no licence. `frida.fooddata.dk` now 301s to `fcdb.fooddata.dk`, a single-page app that returns only `Loading...` to any fetch, so the terms **cannot be read programmatically at all** |
| **Japan MEXT Standard Tables** | Asserted in one research pass as *"settled and favourable, CC BY 4.0-compatible"*; the primary page carries **no terms of use at all** | Japanese government data often falls under the Government of Japan Standard Terms of Use v2.0, which *is* CC BY-compatible — but that has not been demonstrated for this dataset. `mext.go.jp/b_menu/9.htm` 404s. **Downgraded to unverified** |
| **IFCT 2017** (India) | 542 directly-measured Indian foods × **151 components** — the richest per-food panel found anywhere — reachable only through GitHub mirrors tagged AGPL-3.0 or MIT | The official domain `ifct2017.com` lapsed and now redirects to an unrelated blog. **A re-publisher cannot grant rights the rights-holder never gave**, so the mirror licences convey nothing; AGPL-3.0 would additionally be hostile to a distributed Apache-2.0 app. Same defect class as the Kaggle recipe corpora |
| **RecipeNLG, Recipe1M, Food.com/Kaggle recipe scrapes** | Large, convenient, and none is licensed for this | RecipeNLG is non-commercial *and* requires the user to indemnify the university against claims arising from *"any use of copyrighted images or text derived from it"* — an admission that upstream provenance is unresolved. Recipe1M is non-commercial behind a click-through. The Kaggle scrapes have no valid grant at all. **State it as a rule: a Kaggle licence tag is a claim by an uploader, not a grant by a rights-holder.** None carries nutrition data anyway — §27's 2.2 (FNDDS Ingredients, CC0) is the legitimate answer |
| **FAO/INFOODS Density Database v2.0** | 638 density entries; permission-gated, not open | FAO's pre-CC notice reserves all rights with non-commercial reuse *authorised free of charge **upon request***. **Honesty note:** the copyright page uses a subset font with no character map and the rights sentence **could not be verified verbatim** in either round; the 638 entries / 20 groups / 11 sources counts *were* verified. A permission granted to Fernlet would not travel to a fork — which defeats the point. Most of its values are USDA-derived; take them from USDA |
| **CREA (Italy), FAO/LATINFOODS national tables, ISGEM (Iceland)** | Not hostile — simply **no licensing decision has ever been made** | Web-consultation interfaces and PDFs under default national copyright, with a *request* to cite the source rather than a grant. Scraping them would be both legally unfounded and against the no-tracking wall's posture of not fetching from unallowlisted destinations |

### 39.4 The three top picks, in order

**1. Bundeslebensmittelschlüssel 4.0 — because it fixes two defects with one ingest, and it only
became possible eight months ago.** Until **16 December 2025** BLS was sold under paid per-software
licence models; version 4.0 abolished the fee and shipped under **CC BY 4.0**. Verified this round at
the publisher's own download page ([blsdb.de/download](https://blsdb.de/download)), which states the
licence, the attribution requirement and the DOI in one place. It fixes:

- **the German locale**, with 7,140 native German food names from the federal nutrition research
  institute — foods a German user actually recognises, not translated USDA rows; and
- **the micronutrient-depth defect §16 measures**, with **138 nutrients per food** — deeper than
  anything USDA ships outside Foundation Foods, and Fernlet ships zero Foundation rows today.

Cost of adoption: single-digit MB, one credit line, and a parallel source with its own IDs rather than
a merge into USDA rows — which is exactly the shape `attachBrandedSource` already supports. Fernlet's
schema stores micronutrients as a JSON blob, so widening the nutrient set costs bytes, not a migration.

*This was the single most consequential correction the licence fact-check made.* Two of four research
passes graded BLS "unclear" and advised writing to MRI before adopting, because they read
`blsdb.de/license` — **a stale page that still links only the 2018 BLS 3.0 fee terms.** The download
page is authoritative and says CC BY 4.0 in plain words. **The German localization is unblocked today,
not pending correspondence.**

**2. Table Ciqual 2025 — the best value-per-byte in the survey.** 1.5 MB of XLSX buys 3,484
French-named foods × 74 constituents from the French food-safety agency, under Etalab Open Licence 2.0,
which independently permits commercial reuse, modification and redistribution. It fixes **the French
locale** with a culturally correct food set, and it deepens micronutrients at the same time.

*One correction to the record before it is quoted:* the claim circulating in the research bundle that
Ciqual 2025 was **also dual-deposited as CC BY 4.0 on Zenodo is wrong.** Verified this round against the
authors' own deposit ([doi:10.57745/RDMHWY](https://doi.org/10.57745/RDMHWY)): exactly **one** licence
is recorded, SPDX `etalab-2.0`. The Zenodo record cited as CC BY evidence is a **different and much
smaller companion dataset** (191 "average foods" with contributor detail), not the 3,484-food
composition table. The verdict is unaffected — Etalab 2.0 is sufficient on its own — but the CC BY
reassurance should be struck.

**3. Canadian Nutrient File 2026 — because it is the only source that also fixes the *unit* problem.**
OGL-Canada grants *"copy, modify, publish, **translate**, adapt, distribute"* for any lawful purpose,
and CNF ships **bilingual EN/FR** throughout. Two distinct wins:

- a **second, independently-licensed source of French food names**, useful precisely where it disagrees
  with Ciqual — Ciqual should win for a France-region user, CNF gives Canadian French; and
- `measure_name.csv` (67,867 bytes), a government-maintained **bilingual household-measure vocabulary**
  — `1 fish (500 g)` / `1 poisson (500 g)`. That is the localized measure table fix **1.4**'s unit
  parser and fix **2.4**'s `slice`/`piece` gap will otherwise have to be hand-written, and it arrives
  pre-paired. Treat `Measure_Code` as a frozen token and the EN/FR strings as display, per the
  localization wall.

**Runner-up worth naming: NIH's DSLD.** 214,780 supplement labels, **CC0**, with UPCs — the strongest
non-localization adopt on the list. It attacks micronutrients from the intake side while BLS, Ciqual
and Foundation Foods attack them from the food side, and it turns a scanned multivitamin from a dead
end into a logged entry. Bundle a projection, not the file: on-market rows only, `{UPC, brand, name,
serving, servings/container, [nutrient, amount, unit, %DV]}`. Two caveats belong in the UI — values are
**label-declared, not analytically verified**, and the database deliberately retains **off-market**
products, which must be date-flagged or filtered.

### 39.5 The localization angle, answered directly

Fernlet is localizing to **es / fr / de** and ships a USDA-only, English-only catalog. That is a real
product defect, not a nicety: a localized UI wrapped around English food names is the most visible
possible tell that the localization is a veneer. The honest per-locale answer differs sharply.

| Locale | Answer | Confidence |
|---|---|---|
| **de** | **Solved, as of December 2025.** BLS 4.0, CC BY 4.0, 7,140 native German foods × 138 nutrients, published by the federal research institute. Verified at the publisher's own page this round. German went from *"no clean option at any price"* to *"best-covered locale in the set"* in eight months | **High** — licence read at the primary source |
| **fr** | **Solved.** Ciqual 2025 (Etalab 2.0) as the primary, 3,484 native French foods; CNF 2026 (OGL-Canada) as a second source of FR names *and* the bilingual measure vocabulary | **High** — both licences read at the primary source |
| **es** | **NOT solved, and this is the finding to act on.** There is no legally clean Spanish national food composition table. BEDCA — the only one that exists — carries an explicit *"todos los derechos reservados"* notice with no open licence anywhere on the site, and its published conditions add a no-derivatives clause. Being free and open-source cures neither | **High** on the blocker; **Medium** on the exact Spanish clause wording (font extraction failed both rounds) |

**The Spanish plan, in order.**

1. **Ship a Fernlet-authored Spanish display-name layer over the CC0 spine, and do it now.** Nutrient
   values stay USDA; Fernlet writes its own Spanish names. No BEDCA data is used, so no BEDCA
   permission is needed, and nothing blocks the `es` launch. This should be the default plan.
2. **Take FNDDS Survey Foods (§27's 2.1) seriously as a Spanish-coverage source, not only a dish
   source.** It carries 800+ Latino/Hispanic items — USDA collected them because NHANES samples
   Hispanic Americans — it is CC0, and it is *already in the plan*. It will not give Spanish *names*,
   but it gives the *foods*, which is the harder half.
3. **Write to AESAN/BEDCA** (`bedca.adm@gmail.com`) asking for the express authorisation their own
   conditions contemplate, describing Fernlet precisely: free, no ads, no accounts, no server, open
   source, bundled read-only redistribution, normalised into SQLite. A yes is plausible. **Do not gate
   the `es` launch on it.**
4. **FAO/LATINFOODS is a research track, not a source.** >6,000 Spanish-named foods across 14 countries
   — arguably serving more Spanish speakers than Spain's table would — but it is an aggregation of
   separately-owned national tables with **no common licence and no licensing decision at all**, mostly
   distributed as PDFs. Per-country diligence and per-country permission letters. If it is ever worth
   the effort, start with ARGENFOODS (already in Excel, one university contact) and Brazil's TBCA.

**One shipping consequence that must not be missed.** Every source in Group 1 except USDA, DSLD and
MenuStat carries an **attribution obligation**. Five distinct notices become a shipping requirement the
moment any of them lands: OGL v3 (UK), OGL-Canada, CC BY 4.0 naming Max Rubner-Institut, Etalab 2.0
naming ANSES, and later NLOD / CC BY for the Nordics. **Build one "Data sources" screen that renders
licence, publisher, version and source date per bundled table, and treat adding a source without its
row there as a build-breaking omission** — the same discipline `Docs/PrivacyWipeCoverage.md` already
enforces for persisted surfaces. That screen also gives §27's staleness warning somewhere to live: each
national table is a *national* dataset with an accuracy caveat, and a short "values are averages and
vary by region and preparation" line belongs there regardless of which sources are adopted.

### 39.6 What this does *not* change

**None of it touches Q2.** §8 measured a ~46% failure rate on realistic input **entirely against data
already shipping**, and §10 measured that quadrupling the catalog moved top-1 for one query in thirty.
Adding BLS, Ciqual and CNF adds roughly **13,500 rows to 118,317** — an 11% increase, against a 4×
increase that bought ~3%. **These sources are worth adopting for localization and micronutrient depth,
and for nothing else.** If they land before the Tier 1 ranking fixes, they will make search measurably
worse, because §20's finding holds: more rows through a comparator with no score floor and data type
above relevance is a net negative. Sequence them **after** §30's steps 1–9.

**And none of it changes Q1.** Every source above is a *published dataset* with a licence to read.
None is user-uploaded content, none creates a hosting-provider relationship, and none brings DSA
Article 16, App Store Guideline 1.2 or a moderation queue with it. That is the whole difference
between §39 and §28.

### 39.7 Where this section is honest about not knowing

| Claim | Status |
|---|---|
| BLS 4.0 is CC BY 4.0; 7,140 foods × 138 nutrients; DOI 10.25826/Data20251217-134202-0 | **Verified 2026-08-22** at `blsdb.de/download` and `blsdb.de` |
| Ciqual 2025 is Etalab 2.0 only; XLSX 1,541,998 B; compo XML 69,243,149 B | **Verified 2026-08-22** at the Recherche Data Gouv API. Note one research pass reported the compo XML as 66.0 MB — the correct figure is 69.2 MB |
| CoFID is OGL v3.0; 4.42 MB / 634 KB / 759 KB; updated 19 March 2021 | **Verified 2026-08-22** at GOV.UK |
| DSLD holds 214,780 records and is CC0 | **Verified 2026-08-22** at the DSLD API stats endpoint and its OpenAPI document. The API reports version **9.4.0**, not the 9.5.0 stated in the research bundle |
| NZ FOODfiles forbids modification and is non-transferable | **Verified 2026-08-22** at `foodcomposition.co.nz/terms` |
| BEDCA carries an all-rights-reserved notice and no open licence | **Verified 2026-08-22** at `bedca.net/bdpub` |
| CNF holds "5,690 foods × 152 nutrients" | **UNVERIFIED — a 2015-edition legacy figure carried forward.** The 2026 portal page states no counts and the Health Canada user guide returned 403. **Count the actual rows from the downloaded ZIP before quoting this anywhere user-facing** |
| Open Food Facts holds 4,701,654 products / 956,659 US / 862,056 nutrition-complete | **UNVERIFIED this round** — the v2 search API returned 503. These counts drive every size estimate for §27's 2.6; re-run them with a proper User-Agent and backoff before any bundle-size decision |
| AUSNUT 2011-13 holds 16,152 measures and is CC BY 2.5 AU | **UNVERIFIED** — `foodstandards.gov.au` and `data.gov.au`'s CKAN API both returned 403. Note AUSNUT and AFCD are *different datasets*, so the CC BY 2.5 grading must not be applied to AFCD, which is confirmed CC BY-SA |
| Fineli is CC BY 4.0 | **UNVERIFIED** — the publisher's open-data page returned 403 in both rounds |
| FNDDS supplies 22,046 portion weights across 5,432 codes in an 881 KB xlsx | **Partially verified.** The file exists under that exact name on the ARS page and the page carries no licence statement (consistent with federal public domain), but ARS publishes neither the size nor the counts. Unchanged from §33's *agent's own file parse* row |
| Nutritionix's published prices | **Could not be re-verified this round** — `nutritionix.com/api` returned HTTP 402. §18's figures stand on the owner-supplied PDF alone |
| FAO/INFOODS WAFCT is CC BY-NC-SA 3.0 IGO; the FAO density DB is all-rights-reserved | **UNVERIFIED strings** in both rounds (403s and unmappable PDF fonts). Both verdicts are SKIP on independent grounds, so nothing turns on it — but do not quote either licence as established |

**A methodological note worth keeping.** Four independent research passes disagreed with each other on
three of these datasets — BLS (unclear vs CC BY), NEVO (skip vs investigate) and Japan MEXT (settled vs
unverified) — and in every case **the pass that read the publisher's download or terms page beat the
pass that read a licence-titled page.** The lesson generalises: for food composition data, the licence
lives with the file, not on the page named "licence".

---
## 40. The patent question: are MyFitnessPal's five validation rules ours to use?

**This section is research, not legal advice.** No attorney-client relationship exists, nothing here
is a freedom-to-operate opinion, and §40.10 names the one narrow question a lawyer should be asked if
the owner wants certainty rather than a working position. Read §40.9 before §40.8 — the design
boundary matters more than the doctrine.

### 40.1 The distinction that decides everything: claims, not specification

**Only the claims of a patent are enforceable.** 35 U.S.C. 154(a)(1) grants the right to exclude from
*"the invention as claimed"*. Everything else in a patent document — the background, the figures, the
worked examples, the described embodiments — is a **teaching disclosure**, published in exchange for
the monopoly, and it confers no exclusionary right at all.

The corollary is the doctrine of **disclosure-dedication**: subject matter described in a
specification but not claimed is **dedicated to the public**, and the patentee cannot recapture it
under the doctrine of equivalents (*Johnson & Johnston Associates Inc. v. R.E. Service Co.*, 285 F.3d
1046 (Fed. Cir. 2002) (en banc); refined in *PSC Computer Products v. Foxconn*, 355 F.3d 1353 (Fed.
Cir. 2004), which requires the disclosure be specific enough that a skilled artisan would identify the
unclaimed matter as an alternative). **One honesty caveat that a research summary got wrong and must
not be repeated:** disclosure-dedication bars recapture *only under the doctrine of equivalents*. It
is not a general licence to practise disclosed matter. The reason a bare rule-(d) or rule-(e) check is
safe is the simpler one — **those words appear in no claim, so there is nothing to infringe
literally.**

So the question §15 and fix 1.14 actually raise is narrow and answerable: **for each of the five rules,
is it in a claim, or only in the specification?**

### 40.2 Where each of the five rules actually lives

The family is two granted patents: **US 11,508,472 B2** (the '472, granted 2022-11-22, 16 claims, two
independent — 1 method and 9 system) and its continuation **US 12,057,215 B2** (the '215, granted
2024-08-06, 15 claims, three independent — 1 method, 10 CRM, 13 system). A third family member,
application 15/087,646, was abandoned.

All five rules appear **verbatim in the '472's specification**, in the terms §15 quotes — including
the ±10% margin: *"the total calories may be required to almost equal a weighted sum of carbohydrates,
protein and fat, within a 10 % error margin"*, and *"the total fat for a food item must be greater than
or equal to the sum of trans fat, saturated fat, poly-saturated fat, and monounsaturated fat"*, and
*"the total carbohydrates must be greater than or equal to the sum of fiber and sugar in one example."*
Note the drafter's hedges — *"may be"*, *"in one example"* — which is how described embodiments are
signalled.

**But three of the five are also in claims, and the memo must say so plainly.**

| Rule (as §15 states it) | In a claim? | Where exactly |
|---|---|---|
| **(a)** All nutrient values non-negative | **YES — claimed** | Not in any '472 claim. **Claimed verbatim** as limitation **(i)** of the '215's **dependent claims 8 and 15**: *"all nutrition values for the verified data record being non-negative"* |
| **(b)** Not all values zero, with a water/unsweetened-tea exception | **Half claimed** | The not-all-zero half is limitation **(ii)** of '215 claims 8 and 15: *"at least one of the nutrition values … being positive"*. **The water/unsweetened-tea exception appears in no claim anywhere in the family** |
| **(c)** Calories ≈ weighted macro sum within ±10% | **YES — claimed twice, as a genus** | In the '472's **independent** claims 1 and 9, but only as *"a predetermined relationship between calories and macronutrients"* — **no Atwater 4/4/9 weighting, no 10% margin**. Elaborated in dependent claim 10 as an *"aggregate macronutrient caloric value"* against *"a predetermined threshold"* — still no numbers. Also limitation **(iii)** of '215 claims 8 and 15. **The ±10% species is specification-only** |
| **(d)** Total fat ≥ trans + saturated + poly + mono | **NO — specification only** | In **no claim** of the '472 (16 claims) and **no claim** of the '215 (15 claims). Unclaimed family-wide |
| **(e)** Total carbohydrate ≥ fibre + sugar | **NO — specification only** | In **no claim** of the '472 and **no claim** of the '215. Unclaimed family-wide |
| *(a sixth rule §15 does not list)* Category-conditional positive value | *Claimed* | Limitation **(iv)** of '215 claims 8 and 15: *"a particular nutrition value being positive, wherein the particular nutrition value is based on the a food category"* [sic — the typo is in the granted patent]. Worth knowing so it is not implemented from the patent's phrasing |

**'215 claim 8, verbatim** (verified 2026-08-22 against an independent full-text mirror at
[freepatentsonline.com/12057215.html](https://www.freepatentsonline.com/12057215.html); the USPTO's own
copy of the '215 is an image-only scan): *"The method of claim 1 further comprising performing a
validation check on each of the verified data records, the validation check determining whether the
verified data record follows at least one validation rule associated with at least one nutrition value
of the verified data record, wherein the at least one validation rule includes **one or more of** (i)
all nutrition values for the verified data record being non-negative, (ii) at least one of the
nutrition values for the verified data record being positive, (iii) the nutrition values for the
verified data record meeting a predetermined relationship between calories and macro-nutrients, and
(iv) a particular nutrition value being positive, wherein the particular nutrition value is based on
the a food category of the verified data record."* **Claim 9** adds *"demoting the verified data record
to a non-verified data record if the verified data record does not follow the at least one validation
rule."* **Claim 15** repeats the identical (i)–(iv) list against the system claim.

Two things follow that a casual reading would miss. First, **"one or more of"** means practising a
**single** one of those four checks satisfies that limitation — a bare non-negativity check is enough.
Second, **only rules (d) and (e), plus the water/tea exception of (b), are genuinely unclaimed across
the whole family.** Any statement that "four of the five appear in no claim" is wrong; the number is
two-and-a-half.

**Correction recorded, because this is where the research disagreed with itself.** One research pass
asserted that the '215 *"contains NO nutrition-validation limitation at all — not calories-vs-macros,
not fat-vs-fatty-acids, nothing."* **That is flatly false**, as claim 8 above shows. Two other passes
had it right. Any reasoning built on the false version is discarded (§32).

### 40.3 So why is the answer still "implement them"?

**Because those claims are dependent, and Fernlet does not practise the independents they hang off.**

Infringement of a claim requires that **every** limitation be met — the all-limitations rule
(*Warner-Jenkinson Co. v. Hilton Davis Chemical Co.*, 520 U.S. 17, 29 (1997)). And 35 U.S.C. 112(d)
makes a dependent claim incorporate every limitation of the claim it depends from: **you cannot
infringe claim 8 without first infringing claim 1.**

What claim 1 of the '215 requires, cumulatively: **receiving** data relating to consumables **from a
plurality of health tracking devices**; **storing** it as records in a **crowd-sourced database**;
**grouping** the records by description string; **scoring** individual records within each group;
**determining a single verified data record** per group by relative score; **hashing** each group;
**placing** at least two groups **in a common bin**; performing a **pair-wise comparison** of groups in
the bin; **identifying duplicate groups** by thresholding the comparison value; **merging** them;
**demoting** the losing verified record; **receiving a search request** from one of those devices; and
**returning and transmitting** the record set with a **verified-record identifier for display**.

The '472's independent claims are the same shape with a different added step, and claim 9 goes further
still: the record returned to a querying device must have been *"received from a **different** health
tracking device"* — an explicit cross-device provenance limitation.

**What Fernlet does:** ships a bundled, read-only, single-source, USDA-derived SQLite file on a device
with no account and no server, and — under fix 1.14 — runs arithmetic checks over a food the *user
themselves* typed or scanned, in that user's own store. There is no ingestion from a plurality of
devices, no crowd-sourced database, no clustering or grouping of others' records, no scoring, no
election of a verified representative, no duplicate-group merging, no demotion, and no search query
answered out of a crowd-sourced database.

**A caution about how confidently that gap should be stated.** Three research passes counted claim 1's
limitations as twelve, ten and "eleven-odd" respectively, and each quoted a miss-ratio off its own
count. **How a claim divides into limitations is a construction-dependent judgement, not arithmetic**,
and claim construction is a question for a court (*Markman v. Westview Instruments*, 517 U.S. 370
(1996)) — terms like *"crowd-sourced database"* and *"a plurality of health tracking devices"* would be
construed in litigation, not read plainly off the page. So: **do not quote a ratio.** The defensible
statement is qualitative and still decisive — *Fernlet performs no crowd-sourced aggregation,
clustering, scoring, verified-record election or duplicate merging, and answers no search query out of
a crowd-sourced database.* That is a statement about what the code does, which can be demonstrated from
the source tree; it is not a legal conclusion.

### 40.4 The prior-art record: these are decades-old standard checks

Independent of claims, it is worth knowing that every one of the five is documented public practice
long before the '472's **2016-03-31** priority date. This does not make practising them lawful on its
own (see §40.7) — its value is as §§102/103 invalidity evidence if anyone ever asserted a claim broad
enough to cover the bare rules, and as documentation that Fernlet built from public standards.

| Rule | Prior-art source | Date | Verbatim |
|---|---|---|---|
| **(c)** the 4/4/9 identity | **W. O. Atwater** and colleagues, USDA Storrs Experiment Station, as recounted in FAO Food and Nutrition Paper 77, ch. 3 | **1896** — 120 years pre-priority | *"The Atwater general factor system was developed by W.O. Atwater and his colleagues at the United States Department of Agriculture … at the end of the nineteenth century (Atwater and Woods, 1896)"* ([fao.org/4/y5022e/y5022e04.htm](https://www.fao.org/4/y5022e/y5022e04.htm)) |
| **(c)** the identity, codified in US law | **21 CFR 101.9(c)(1)(i)(B)**, incorporating Merrill & Watt, USDA Agriculture Handbook 74 (1955, rev. 1973) | Regulation **1993**; handbook **1955/1973** | *"Using the general factors of 4, 4, and 9 calories per gram for protein, total carbohydrate, and total fat, respectively, as described in USDA Handbook No. 74"* ([law.cornell.edu/cfr/text/21/101.9](https://www.law.cornell.edu/cfr/text/21/101.9)) |
| **(c)** the *tolerance band* concept | **Greenfield & Southgate**, *Food Composition Data*, 2nd ed., FAO, ch. 8 | **2003** (1st ed. 1992) | *"summations falling within the range of 97 to 103 percent of analytical sample weight are generally acceptable"* ([fao.org/4/y4705e/y4705e13.htm](https://www.fao.org/4/y4705e/y4705e13.htm)) |
| **(d)** fat ≥ Σ fatty acids | **FAO/INFOODS**, *Guidelines for Checking Food Composition Data prior to the Publication of a User Table/Database* v1.0 | **2012** — 4 years pre-priority | *"Total fat (FAT) > total saturated fatty acids (FASAT) + total monounsaturated fatty acids (cis) (FAMS) + total polyunsaturated fatty acids (cis) (FAPU) + trans-fatty acids (FATRN)"* — a component-for-component match |
| **(d)** the same, as a shipped release gate | **Haytowitz, Lemar & Pehrsson**, USDA ARS, *J. Food Composition and Analysis* 22 (2009) 433–441, **Table 4** | **2009** | *"Sum of values for total saturated fatty acids, total monounsaturated fatty acids, and total polyunsaturated fatty acids should not exceed values for total fat"* |
| **(e)** carb ≥ fibre + sugar | **Rand, Pennington, Murphy & Klensin**, *Compiling Data for Food Composition Data Bases*, UNU/INFOODS | **1991** — 25 years pre-priority | *"the sum of carbohydrate components [starch, sugars, fibre] must not exceed total carbohydrate"* — given as the worked example of a between-nutrient check |
| **(e)** the same, by definition in US law | **21 CFR 101.9(c)(6)** and (c)(6)(i)–(ii) | **1993** | Total carbohydrate is the by-difference residue, with dietary fiber and sugars declared as **indented sub-components** of it. The inequality follows from the definitions |
| **(a)** non-negativity | **FAO/INFOODS** 2012, proximates section | **2012** | *"If the calculated carbohydrate value for these foods is > 5 g/100 g or < −5 g/100 g EP the entire food entry should be removed from the DB"* — an impossible value causes removal, which is the patent's own demote-on-failure behaviour |
| **(b)** zero vs missing | **Rand et al.**, UNU/INFOODS | **1991** | *"MISSING and ZERO, however, must always be kept distinct, with the numeral '0' never used to represent MISSING"* |
| **(b)** the water/tea exception | **21 CFR 101.9(j)(4)** | **1993** — 23 years pre-priority | Exempts foods containing insignificant amounts of all nutrients, naming *"tea leaves, plain unsweetened instant coffee and tea"* by example |
| **All five, as a discipline** | **Rand et al.** 1991, and USDA ARS's published QC suite (Haytowitz 2009) | **1991 / 2009** | Rand: *"Although the basic procedures are relatively simple and easily performed by computers, there is no consensus on approaches."* A 1991 admission that automating them is routine |

Note also that the '472's own examiner had **Hochuli, *Data Cleansing for Food Composition Data*, ETH
Zurich, 2014-04-07** on the reference list — a paper on exactly this problem, two years pre-priority,
cited on the face of the patent and allowed over.

### 40.5 Status, assignee, term and territory

| | US 11,508,472 B2 | US 12,057,215 B2 |
|---|---|---|
| **Title** | Health tracking system with verification of nutrition information | (same family, continuation) |
| **Inventors** | Chul Lee, Hesamoddin Salehian | Chul Lee, Hesamoddin Salehian |
| **Application / filed** | 15/093,191, filed 2016-04-07 | 17/992,424, filed 2022-11-22 |
| **Earliest priority** | **2016-03-31** (parent 15/087,646, abandoned) | 2016-03-31 |
| **Granted** | **2022-11-22** | **2024-08-06** |
| **Claims** | 16 (independents 1, 9) | 15 (independents 1, 10, 13) |
| **Current assignee** | **MyFitnessPal, Inc.** — chain of title: inventors → Under Armour, Inc. (recorded 2019-07-29) → UA Connected Fitness, Inc. (2020-11-13, the Francisco Partners divestiture) → change of name to MyFitnessPal, Inc. (2021-01-20). **Encumbered:** MidCap security interest released and a JPMorgan Chase patent security agreement recorded **2024-07-26** | Same |
| **Term** | **Expires 2037-07-27** — 20 years from the parent's 2016-03-31 filing (2036-03-31) plus **483 days** of patent term adjustment, printed on the face of the patent. *One correction: a research pass derived this from the 2016-04-07 filing plus "~476 days" — the wrong base date for a continuation under 35 U.S.C. 154(a)(2), back-solved to the right answer* | **Expires 2036-03-31** — *sixteen months **before** the parent.* Its face states **0 days** PTA and *"This patent is subject to a terminal disclaimer"*, which bars PTA under 35 U.S.C. 154(b)(2)(B). **So the only claims in the family that name the sanity rules expire first** |
| **Territory** | **US only.** No PCT, no EP, no national-phase filings; "Also Published As" lists only US documents. The Paris Convention year off the 2016-03-31 priority expired 2017-03-31, so nothing can be filed abroad now | Same |
| **Litigation / post-grant** | **None found — but this is absence of evidence, not verified absence.** Both the USPTO PTAB API and every litigation search route were unreachable this round (§38). MyFitnessPal is an operating company with no history of asserting this patent | Same |
| **Maintenance fee** | **UNRESOLVED, and materially so.** The 3.5-year fee was due **2026-05-22**; the surcharge grace period closes **2026-11-22**. No payment event appears in the public legal-event record, which ends at a 2024-10-11 small-entity election — **but that feed lags, every USPTO fee endpoint was unreachable, and non-payment is NOT established.** Do not treat the patent as lapsed. **Check Patent Center for application 15/093,191 in December 2026** | 3.5-year fee due 2028-02-06 |

**Two consequences for Fernlet specifically.** The family is **US-only**, so 35 U.S.C. 271(a)'s
territorial limit — acts *"within the United States"* — means the **Spanish, French and German
localizations carry no exposure from this patent whatsoever.** And the window to claim the unclaimed
matter is shut: there is no co-pending continuation, and — the argument that actually forecloses it — a
**broadening reissue** under 35 U.S.C. 251 is time-barred more than two years after grant, i.e. since
**2024-11-22** for the '472 and **2026-08-06** for the '215. Both are past. *This is a different and
firmer basis than the co-pendency argument two research passes gave; note that "dedicated to the
public" does not by itself mean "can never be claimed" — the reissue bar is what does that work.*

### 40.6 Patent eligibility, as a backstop and not a shield

Would a claim to the bare arithmetic survive 35 U.S.C. 101? Almost certainly not — but this matters
much less than it first appears, because **nobody claimed the bare arithmetic.**

Under *Alice Corp. v. CLS Bank Int'l*, 573 U.S. 208 (2014), applying *Mayo v. Prometheus*, 566 U.S. 66
(2012): step one asks whether a claim is directed to a judicial exception; step two whether the
additional elements supply an *"inventive concept"* amounting to significantly more. *"Calories ≈
4C + 4P + 9F, else flag"* is a mathematical formula plus a tolerance test — the *Parker v. Flook*, 437
U.S. 584 (1978) alarm-limit fact pattern with different variable names, and *Gottschalk v. Benson*, 409
U.S. 63 (1972) is the root. Rules (d) and (e) are part-whole identities that follow from the
definitions at 21 CFR 101.9. Rules (a) and (b) are checks a human performs by reading a label, i.e. a
mental process (*CyberSource v. Retail Decisions*, 654 F.3d 1366 (Fed. Cir. 2011)). Wrapping them in
collect-analyse-flag-display does not help (*Electric Power Group v. Alstom*, 830 F.3d 1350 (Fed. Cir.
2016); *Content Extraction v. Wells Fargo*, 776 F.3d 1343 (Fed. Cir. 2014)).

**Three reasons not to lean on this.** (1) An issued patent is presumed valid and invalidity must be
shown by **clear and convincing evidence** (35 U.S.C. 282(a); *Microsoft v. i4i*, 564 U.S. 91 (2011)).
(2) *Berkheimer v. HP*, 881 F.3d 1360 (Fed. Cir. 2018) made step two's "well-understood, routine and
conventional" inquiry a **question of fact**, so an Alice motion is no longer a reliable early exit.
(3) §101 **cannot be raised in an inter partes review or ex parte reexamination** (35 U.S.C. 311(b),
301–302), and the post-grant-review window — the only USPTO route for §101 — closed nine months after
each grant. It is a litigation defence you would pay for, not a shield you hold.

There is one genuinely useful side effect worth recording: the '472's specification **published on
2017-10-05** as US 2017/0286062 A1. From that date it is itself printed prior art under 35 U.S.C.
102(a)(1) against any later application by anyone claiming these five rules. **The publication that
prompted this question also permanently blocks third parties from patenting the same rules.**

### 40.7 What independent creation does, and does not, do

**This is the most commonly misunderstood point in the whole area, and it must not be fudged.**

**Copyright and patent work differently.** Independent creation is a complete answer to a copyright
claim. It is **not a defence to patent infringement.** Direct infringement under 35 U.S.C. 271(a) is a
**strict-liability** offence (*Commil USA v. Cisco Systems*, 575 U.S. 632, 639 (2015)): if a product
falls within the claims it infringes, whether or not the maker had heard of the patent, whether or not
every line was derived from the CFR, and whether or not they got there first. (35 U.S.C. 273 provides
a narrow prior-commercial-use defence, but it requires US commercial use at least one year before the
patent's effective filing date — unavailable here.)

**So what does the provenance work in §40.4 actually buy?** Two real things, and they are worth having:

1. **Invalidity evidence.** FAO/INFOODS 2012, Rand et al. 1991, Greenfield & Southgate 2003, USDA ARS
   2009 and 21 CFR 101.9 are printed prior art under §§102/103 against any claim broad enough to reach
   the bare rules.
2. **Good-faith evidence bearing on willfulness.** After *Halo Electronics v. Pulse Electronics*, 579
   U.S. 93 (2016), enhanced damages under §284 are reserved for conduct that is *"willful, wanton,
   malicious, bad-faith, deliberate, consciously wrongful, flagrant, or—indeed—characteristic of a
   pirate"*, and culpability is *"generally measured against the knowledge of the actor at the time of
   the challenged conduct."* Building from public standards, documented at the time, is exactly the
   kind of fact that keeps conduct out of that category.

**What it does not buy: it does nothing to defeat literal infringement.** Any phrasing along the lines
of *"this makes the independent-derivation story self-evident"* — which two research passes used — is
misleading if a non-lawyer reads it as an infringement defence. Keep the distinction crisp: *"I built
it myself"* is worth nothing. *"This was public in 1991 and 2012, and in any event we do not do what
the claim says"* is worth everything.

**And reading the patent did not create a problem.** The folklore is wrong post-*Halo*. Knowledge alone
has never been sufficient for willfulness; 35 U.S.C. 298 provides that failure to obtain counsel's
advice *"may not be used to prove that the accused infringer willfully infringed"* (see also
*Knorr-Bremse v. Dana*, 383 F.3d 1337 (Fed. Cir. 2004) (en banc)); and deliberately **not** reading is
worse, not better — *Global-Tech Appliances v. SEB*, 563 U.S. 754 (2011) treats willful blindness as
the equivalent of knowledge. A policy of refusing to read patents in one's own field is the exact fact
pattern that doctrine was written for.

### 40.8 The one Fernlet-specific exposure, and it is not the arithmetic

**Fernlet's proximity mesh is, literally, a plurality of health-tracking devices exchanging
user-created food records.** That is the vocabulary of these claims, and it deserves top billing rather
than a bullet at the end of a design list.

It does not infringe today, and the reason is precise: the claims are not about *transferring* records
between devices. They are about **aggregating** records from many devices into a **crowd-sourced
database**, **grouping** them, **scoring** them, **electing** a canonical *verified* record per group,
**merging** duplicates, and **serving** that elected record in response to a search. A direct
peer-to-peer transfer into the receiving user's own local store does none of that.

**The design boundary to hold, stated as a rule rather than a hope.** Do not build, in Fernlet or in
anything downstream of it:

1. A shared store that **ingests user-created food records from many users' devices** and merges them
   into a single canonical catalog — central *or federated*, and the mesh is federated by construction.
2. **Clustering** user-entered food names into groups by string similarity, then **scoring** the
   records in each group — especially scoring by *popularity* (how many peers logged it) plus
   *similarity to groupmates*, which is verbatim '215 claim 10.
3. **Electing** a "verified" or "trusted" representative record per cluster and serving it in results.
4. **Merging** the nutrition values of duplicate records into an averaged canonical record.
5. A crowd-earned **"verified" marker transmitted to a device for display**.
6. **Hash-then-bin-then-pairwise-compare** near-duplicate detection over those groups.

**Per-user local records versus a crowd-aggregated canonical catalog is the whole distinction** — and
it is the same line §24 draws for entirely independent reasons (DSA, App Store Guideline 1.2, the
no-account promise). **The patent boundary and the compliance boundary are the same boundary.** That is
a fortunate coincidence and it should be written down, because a future feature request that crosses it
would cross both walls at once. If peer-to-peer food sharing is ever built, keep it a **direct transfer
between two people's devices into the receiving user's own store**, exactly as the sealed recipe-share
flow already works.

### 40.9 What this means for fix 1.14 — implement, with two changes

**Implement all five rules.** The patent does not stop it. What changes is *how*, and it costs an
afternoon:

1. **Build them from the source documents, not from the patent.** Write the validator against
   FAO/INFOODS 2012, Rand et al. 1991, Greenfield & Southgate 2003, USDA ARS's Table 4 (Haytowitz
   2009), and 21 CFR 101.9 — all of which are cited in §40.4 and most of which are US federal works in
   the public domain. Do not paste MyFitnessPal's phrasing into code comments or docs. Write *"total
   lipid must be ≥ the sum of its reported fatty-acid fractions (USDA NDL QC, Haytowitz 2009 Tbl. 4)"*,
   not the patent's sentence.
2. **Record provenance as facts, in a comment block or a short `Docs/` note** — where each rule came
   from and what the code does, limitation by limitation. **Record facts, not legal conclusions.** Two
   research passes gave the owner directly opposite advice here — one said do not write an internal
   memo, the other said write it down now — and the reconciliation both of them actually contain is
   this: a factual engineering record is cheap, useful and the artifact you hand a lawyer on day one;
   a **non-lawyer's written legal opinion** is unprivileged and discoverable, and there is no upside to
   creating one. (Note also that §298 already bars using the *absence* of counsel's advice against you,
   so the common fear behind that advice is misplaced.)
3. **Keep the ceilings labelled as an outer guard**, exactly as §15 already requires — Evenepoel's caps
   are curve-fitted, one-sided and demonstrably overfit, and none of that changes.

**One thing not to do:** do not redesign the validator to "avoid" rule (c) by using an odd tolerance or
omitting the check. A worse catalog is a real cost to real users, and the check is not what would create
exposure.

### 40.10 The bottom line, and the question for a lawyer

**The practical read, stated as a working position rather than clearance:** Fernlet ships a static,
read-only, single-source USDA-derived nutrition table inside its app binary and, under fix 1.14, would
run arithmetic sanity checks over foods the user themselves typed or scanned, in that user's own store.
It performs no crowd-sourced record aggregation, no clustering, no scoring, no reliable-record
election and no duplicate merging, and it answers no search query out of a crowd-sourced database. Two
of the five rules — fat ≥ Σ fatty acids and carb ≥ fibre + sugar — appear in no claim of either patent.
The other three appear only in claims whose independents describe a crowd-sourced curation server that
Fernlet has no part of. The family is US-only, so the localizations are outside it entirely. All five
rules are documented public practice from 1991, 1993, 2003, 2009 and 2012.

**That is a research conclusion, not an opinion of counsel, and it should not be repeated in the
register of clearance.** It rests on claim construction that a court, not this memo, would perform.

**If the owner wants certainty, the question to ask a patent attorney is narrow enough to be cheap:**

> *"US 11,508,472 B2 and its continuation US 12,057,215 B2 (MyFitnessPal, Inc.) claim a crowd-sourced
> food-database curation pipeline. We ship a free, open-source, offline iOS app with a bundled
> read-only USDA-derived nutrition table, no server and no account. We want to run five arithmetic
> validation checks — non-negativity; not-all-zero; calories within ±10% of the Atwater weighted macro
> sum; total fat ≥ the sum of its fatty-acid fractions; total carbohydrate ≥ fibre + sugar — over foods
> the user has typed or scanned into their own device-local store, and over rows in our bundled
> catalog. Do the claims of either patent read on that? And separately: our app has a peer-to-peer
> proximity mesh over which users can share recipes device-to-device. At what point would extending
> that to share user-created **food** records begin to read on these claims?"*

The second half of that question is the one worth paying for. The first half is very likely a short
answer; the second is a design decision the owner will otherwise make by accident.

**Two dates for the calendar.** **December 2026** — check USPTO Patent Center for application
15/093,191; if the 3.5-year maintenance fee went unpaid by 2026-11-22 the '472 expired on that date
(the '215 runs on regardless, to 2036-03-31). And **before any change of ownership matters**: a sale of
MyFitnessPal to a different owner, or to an assertion entity, is the main way this patent's risk
profile could shift. It is currently pledged as collateral under a JPMorgan patent security agreement —
which is a lien, not ownership, and JPMorgan cannot sue on it absent foreclosure.

---
