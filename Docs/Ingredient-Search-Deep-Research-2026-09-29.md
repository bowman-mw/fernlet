# Ingredient search: deep research

Date: 2026-09-29, revised 2026-09-30 after three independent verification passes (Appendix B).
Tree: `main` at `cf46b8eb`. Read-only; nothing in the primary tree was changed.
Catalog: the committed `FernletKit/Sources/FoodCatalog/Resources/FoodCatalog.sqlite` (118,317 rows).
Paths are relative to the repository root unless absolute.
`$SP` below means the research session's local scratch directory. The Python replicas and probe outputs it
names were working files and are not in the repository; the shipped instruments that replaced them are
`IngredientSearchReplayProbeTests` (opt-in) and `IngredientSearchCorpusTests` (CI line `food-search`).

Evidence labels used throughout:

- **MEASURED**: shipping Swift run in the simulator, a `sqlite3` query, or a Python replica that
  reproduces the pinned test answers. Output is quoted or the command is given.
- **CODE**: read directly at the cited file:line.
- **INFERRED**: reasoning that was not executed.

Four research sweeps fed this report (`codemap`, `replay`, `units`, `history`; Appendix A), and three
verifiers then re-ran its numbers independently. This revision keeps what they reproduced, corrects what
they did not, and adds what they found that the first draft missed.

---

## 0. In plain words, for the owner

The search is not broken at its core. When you type an ingredient, the app finds a suitable row for 155
of 160 test ingredients. The trouble is in which six rows it shows first, in how it turns "1 banana" or
"1 cup" into grams, and in the data itself.

- **Chocolate chips** is a ranking problem plus a data problem. The app shows USDA rows in a fixed tier
  above store-brand rows, and USDA has no row called "chocolate chips" (its row is "Candies, semisweet
  chocolate"). So 24 USDA cookies, granola bars and trail mixes that mention chocolate chips come first,
  and the plain branded chips sit at #25. This can be fixed with targeted changes: a short list of
  synonyms ("chocolate chips" means the USDA semisweet row) and cleaner data. It does not need the search
  rebuilt.
- **Banana** is a units problem. The catalog already knows a medium banana weighs 118 g. The code that
  reads portions only understands exact unit words like "cup" or "slice", so it throws that away and
  refuses "1 banana". This part needs a real design: a portion reader and sensible default sizes. That is
  the "portions" item from your 2026-08-23 decisions, which was never started.
- **A bigger data bug turned up.** About 58,000 store-brand rows show nutrition per 100 g next to a
  smaller label serving, so a 15 g handful of chocolate chips shows about 7 times the real carbs and fat.
  Separately, the catalog build dropped every USDA food whose protein, carbs and fat are all zero, which
  is why salt, baking soda and water are missing. Both need fixing before any change that pushes
  store-brand rows higher, or the "fix" would surface wrong numbers.

---

## 1. The answer

**Verdict: the search engine needs refining, not replacing. The ranking has one structural weakness
that can be fixed step by step. The unit layer is missing a feature and needs a real design. The data
has serious, concrete defects.**

| Layer | What it decides | Verdict | Why |
|---|---|---|---|
| Retrieval: FTS5 prefix-AND gate plus the name floor (`BundledFoodStore.swift:275-303`, `FoodItemSearch.swift:523-530`) | Which rows are candidates | **Refine** | A suitable row was retrieved and scored for 155 of 160 queries (MEASURED). |
| Ranking: comparator key order and score features (`FoodItemSearch.swift:482-490`, `:565-600`) | Which 6 rows the user sees | **Structural weakness, refine first** | It sorts on data type, then on literal text overlap. Nothing says "this row is the ingredient itself". But the owner's chips case can be fixed by refinements (§8 F7, F3), and the one structural fix prototyped (F5) is promising but not proven. |
| Conversion: portion reader plus the one-portion-per-dimension rule (`NutritionModels.swift:1961-2035`, `:2579-2612`) | Whether "1 banana" or "1 cup" works | **Missing feature (needs a design)** | It throws away most of the USDA household measures the catalog already ships, and has no default-size rule. |
| Data: missing staples, mis-typed rows, branded macro basis, duplicates | What rows exist and what they claim | **Serious defects** | The branded per-100 g basis (§6.5) reaches about 58k rows and hits quick-log too. The build dropped all 32 zero-macro SR foods (§6.2). |
| Screen and import: typeahead, 6 rows, 220 ms debounce, web import parser | How results are shown and imported | **Refine, plus one parser bug** | Small UX gaps make failures hard to escape (§2.6). The web importer's regex mangles "large", "grams" and any food starting with g or l (§3.5). |

**Confidence.** High that the mechanisms below explain both owner cases: each was measured in the
shipping Swift code and reproduced by independent Python replicas. Medium on the "structural" label for
ranking: the only structural fix measured is a prototype over truncated 60-row windows. Medium on the
size of every proposed fix: those numbers come from simulations over measured data, not built code.

**The strongest evidence:**

1. **The plain chips row outscores the cookies 15 to 1 and still loses.**
   - "Chocolate Chips, Chocolate" scores 869. "Cookies, chocolate chip, dry mix" scores 59.
   - The cookie sits at #4 and the chips at #25, because the comparator checks data type before score (`FoodItemSearch.swift:486-488`).
   - The editor shows 6 rows (`FoodCatalog.swift:210`). MEASURED in Swift.
2. **Flipping the sort order alone is not the fix.**
   - Score-first does fix the owner's plural "chocolate chips" list (MEASURED, replica: 6 of 6 plain rows).
   - Across the 160 queries it trades gains for losses. Re-sorting the measured 60-row windows gives 112 at #1 (from 97) but 130 visible (from 132): 36 improved and 22 worsened by rank (`$SP/verify-reproduce/sfcheck.py`), 33 and 19 by bucket (`$SP/synthesis/sf.py`). Those windows cannot see rows beyond position 60. A full-candidate-set replica (`$SP/verify-codetrace/sf_all.py`, which matches the Swift top 10 on 153 of 160 queries) is worse: 109 at #1, 127 visible, 36 improved and 31 worsened by bucket, and 99 of the 109 #1 hits land on branded rows with no portions.
   - "carrot" becomes Carrot Cake and "ginger" becomes Ginger Ale. The score measures text overlap, not identity.
   - This matches the repo's own history: commit `ee3d3361` pinned generic-first after plural "eggs" and "ground beef" "exposed this regression" (`Tests/FernletTests/FoodCatalogTests.swift:224-226`).
3. **The banana data is in the catalog, and the code can't read it.**
   - "Bananas, raw" ships 8 USDA portions, including medium at 118 g. `FoodPortion.recipeUnit` (`NutritionModels.swift:2598-2612`) maps none of them.
   - So "1 each" and "1 cup" fail and Save is disabled.
   - Only 1 of 26 count-noun queries lands on a row that accepts "1 each". MEASURED in Swift.

**What hides the plain ingredient.** Of 160 queries, 63 do not put a plain row at #1, but 35 of those
still show it in the six. The ones that matter are the **28 queries whose plain row never appears in
the six** (20 FAIL, 4 GAP, 4 at #7-10). Among those 28 (MEASURED from the replay tags; script in
Appendix B.2):

- 23 carry a ranking cause observed in the base run (data-type tier, literal-text scoring, or both).
- 4 are catalog gaps: baking soda, "baking s", salt and water. The measured cause is the build dropping
  zero-macro SR foods (§6.2).
- 1 is vocabulary only: "red pepper flakes".
- 6 of the 28 are the chocolate-chip family (plural, singular in two categories, and the prefixes
  "chocolate c", "ch", "chi").

**Neither owner case is a search regression (INFERRED for chips, MEASURED for the device).** The
comparator's data-type-before-score order is the same in `128a2627` (2026-06-27; `git show 128a2627:FernletKit/Sources/FernletDomainModel/FoodItemSearch.swift`, lines 77-84), so chips most likely failed
the same way before the August round; no pre-round replay was run. The TestFlight archives of
2026-08-25, 2026-09-24 (two) and 2026-09-29 each carry exactly one catalog, with SHA-256 `822fb87a…`,
identical to the committed file, and nothing branded (MEASURED, `shasum -a 256` over
`~/Library/Developer/Xcode/Archives/*/*.xcarchive/Products/Applications/Fernlet.app/FernletKit_FoodCatalog.bundle/FoodCatalog.sqlite`).
`git log 53633f50..cf46b8eb` over the search and unit sources is empty. So the owner's build runs the
base catalog with today's search code. The banana failure is a deliberate side effect of the 2026-08-24
unit-safety change (`0ba40d90`), which replaced silently wrong conversions with refusals but never added
a default-size rule (§3.3).

---

## 2. Chocolate chips, traced

### 2.1 What the user saw

The recipe ingredient field calls `CatalogTypeahead.matches` (`App/Fernlet/FoodView.swift:1898-1917`).
That sleeps 220 ms and then calls `catalog.results(for:context: .userTyped)` (`:1911`), which returns
6 rows by default (`FoodCatalog.swift:210`). Nothing filters or re-ranks after that.

MEASURED (Swift, replay probe, base catalog):

| # | Row shown | Data type | Score |
|---|---|---|---|
| 1 | Cookies, marshmallow, with rice cereal and chocolate chips | srLegacy | 365 |
| 2 | Snacks, trail mix, regular, with chocolate chips, salted nuts and seeds | srLegacy | 364 |
| 3 | Snacks, trail mix, regular, with chocolate chips, unsalted nuts and seeds | srLegacy | 364 |
| 4 | Cookies, chocolate chip, dry mix | srLegacy | 59 |
| 5 | Snacks, crisped rice bar, chocolate chip | srLegacy | 58 |
| 6 | Cookies, chocolate chip, refrigerated dough | srLegacy | 57 |

- Ranks 7 to 24 are 18 more srLegacy cookies, granola bars, waffles and one ice cream, scoring 53 to 57.
- Rank 25 is the first plain row: "Chocolate Chips, Chocolate" (branded, 869).
- This matches the owner's report word for word.

The six rows are a plain `VStack`/`ForEach` inside the ingredient card (`FoodView.swift:2115-2124`).
How many of them sit above the keyboard was not measured; rows 4 to 6 may need a scroll while typing
(INFERRED).

### 2.2 Every keystroke

| Typed | Top-1 shown (score) | First plain chips row (MEASURED, Swift) |
|---|---|---|
| choc | Chocolate-flavored hazelnut spread (747) | "Candies, semisweet chocolate" at #28 (hidden); dark chocolate at #2 |
| chocolate | Chocolate-flavored hazelnut spread (807) | none in top 60 |
| chocolate c | Cadbury Chocolate Chomp 117.500 Gr (308) | none in top 60 |
| chocolate ch | Cadbury Chocolate Chomp 117.500 Gr (308) | "Candies, semisweet chocolate" at #45 |
| chocolate chi | Cookies, chocolate chip, dry mix (308) | none in top 60 (replica: #63) |
| chocolate chip | Cookies, chocolate chip, dry mix (368) | none in top 60 (replica: #253) |
| chocolate chips | Cookies, marshmallow, with rice cereal and chocolate chips (365) | #25 |

**At no keystroke does a plain chips row reach the six visible rows** (MEASURED in Swift; the replica
agrees).

For "chocolate c", the single letter is dropped from the match gate and the FTS query
(`FoodItemSearch.swift:723-728`), but it stays in the phrase used for the +500/+250 phrase bonus,
because the phrase is the whole normalized query whenever the raw and search token counts match
(`:300-306`). That is why "Cadbury Chocolate Chomp" earns 308.

The broad prefixes are also the slowest. On the simulator, "choc", "chocolate", "chocolate c" and
"chocolate ch" took 628 to 768 ms per settled keystroke, against a median of 37 ms across all 160 queries
(MEASURED, replay `milliseconds` field). Each hydrates about 9,000 rows, under the 10,000 cap
(`BundledFoodStore.swift:58`): `choc*` matches 9,208 FTS rows and `chocolate*` 8,980 (MEASURED,
`sqlite3 ... match 'choc*'`). The work runs in `Task.detached` (`FoodView.swift:1910`), which a newer
keystroke does not cancel; the stale result is dropped after it finishes (`:1913`). Device timing is
unmeasured.

### 2.3 The mechanism

Four causes stack. Any one of them alone would be survivable.

1. **Data type sorts before score.**
   - The keys are history, then source, then data type, then score, then name (`FoodItemSearch.swift:482-490`). srLegacy is priority 3 and branded is 2 (`:716-717`).
   - All 24 srLegacy rows that carry both words therefore outrank every branded row.
   - The doc comment records score-first as "NOT taken here" (`:457-459`). Commit `ee3d3361` (2026-08-24) pinned this order with `FoodCatalogTests.swift:198` and `:226`.
2. **No generic-tier row is named "chips".**
   - The USDA row is "Candies, semisweet chocolate" (food_id 818). The word "chips" appears only in its portion text.
   - FTS indexes name, category and tags only (`BundledFoodStore.swift:106-107`), and the name floor requires every typed word in the name (`FoodItemSearch.swift:523-530`). So "chips" can never reach row 818.
   - Typing "semisweet chocolate" finds it at #1 (MEASURED, replica).
3. **The +60 word bonus needs exact equality.**
   - Each query word must *equal* a name word (`FoodItemSearch.swift:569-571`). "chips" is not "chip", so the cookie rows get only 57 to 59.
   - Typing the singular "chocolate chip" hands a branded cookie literally named "Chocolate Chip" an exact-name score of 1870.
4. **The dish demotion does not know sweets.**
   - `carrierTokens` (`NutritionModels.swift:1506-1516`) holds bread and assembly words: bun, wrap, taco, salad and so on.
   - Cookies, bars, waffles and dough are not in it, so the one step that can move a row across data-type tiers (`:1623-1636`) leaves them alone.

The 6-row cap amplifies the problem but does not cause it. Showing 20 rows would still show no plain chips.

### 2.4 SQL: the plain rows exist

```
$ sqlite3 -readonly FoodCatalog.sqlite "select f.data_type, count(*) from food f where f.food_id in
  (select rowid from food_fts where food_fts match 'chocolate* AND (chips* OR chip*)') group by 1;"
branded|1149
srLegacy|28

$ sqlite3 -readonly FoodCatalog.sqlite "select food_id,name,serving_size,serving_unit,protein,carbs,fat
  from food where food_id in (64235,106868,107005,107279,12842);"
12842|Organic Semi-Sweet Chocolate Chips|15.0|g|7|60|33
64235|Chocolate Chips, Chocolate|15.0|g|0|67|27
106868|Chocolate Chips, Chocolate|15.0|g|0|10|4
107005|Chocolate Chips, Chocolate|15.0|GRM|0|10|4
107279|Chocolate Chips, Semi-sweet|15.0|g|1|10|4

$ sqlite3 -readonly FoodCatalog.sqlite "select food_id,name,tags,portions from food
  where name='Candies, semisweet chocolate';"
818|Candies, semisweet chocolate|["sweets"]|[{"unit":"cup mini chips","gramWeight":173}, {"unit":"cup chips
  (6 oz package)","gramWeight":168}, {"unit":"serving","gramWeight":14.5}, {"unit":"oz (approx 60 pcs)",
  "gramWeight":28.35}, {"unit":"cup large chips","gramWeight":182}]   (trimmed)
```

28 srLegacy rows pass the gate. Four of them are classed as dishes ("Biscuit", "Biscuits", "sandwich")
and sink, which leaves the 24 above.

### 2.5 Fixing the rank alone lands on broken rows

Under every ranking counterfactual that surfaces branded chips, the top three become three rows all
named "Chocolate Chips, Chocolate" (MEASURED, replica). They tie on score and name, so the stable sort
keeps SQL `food_id` order and **the broken row 64235 comes first** (INFERRED from the stable sort):

| food_id | What is wrong |
|---|---|
| 64235 | Shows C67 F27 for a 15 g serving, more macro grams than the serving weighs. This is the branded per-100 g basis bug (§6.5). |
| 107005 | Serving unit "GRM". It converts nothing in a recipe, not even grams, because the serving-unit guard fails first (`NutritionModels.swift:1962-1963`). |
| 106868 | Correct. |

On top of that, **no branded row has portions** (0 of 109,163, MEASURED), so "1 cup chocolate chips"
fails on every branded row. The USDA row 818 already carries cup measures (168 to 182 g, within 8% of
each other), so the cleanest answer is to make that row findable by the word "chips" (F7) and make its
cup portions readable (F1 0b plus the F4 reader).

### 2.6 What works today, and why it's hard to escape

- These queries find a plain row:
  - "semisweet chocolate" finds the USDA row at #1. It converts in grams, but "1 cup" still fails: its three cup portions carry words like "mini chips", so none of them parse.
  - "semisweet chocolate chips" puts "Akoma Extra Semisweet Chocolate Chips" (71285, 15 g, P1 C9 F4, 507 kcal/100 g, plausible) at #1.
  - **"semi sweet chocolate chips" and "white chocolate chips" also put plain branded chips at #1, but both rows carry the §6.5 bug.** "Organic Semi-Sweet Chocolate Chips" (12842) shows P7 C60 F33 for 15 g, which implies 3,767 kcal/100 g. "White Chocolate Chips" (64709) shows P0 C71 F32 for 14 g, 4,086 kcal/100 g (MEASURED, `sqlite3`). The owner should not use these as workarounds until F2 lands.
- A saved custom "Chocolate chips" ingredient ranks above catalog rows because manual source has priority 4 (`FoodItemSearch.swift:694-701`). But history weight is the first comparator key (`:482`), so a recently logged chip cookie still outranks it.
  - The only way to make one is to type macros into the manual rows (`FoodView.swift:2139-2155`).
  - The "Create custom ingredient" button appears only when the search returns nothing (`:2126`, `:2223-2227`).
- A pick in the recipe editor does not write a correction alias; only the meal-correction sheet does (`FoodView.swift:4278`). It does feed search history once the recipe is logged, because history counts each logged meal's `componentSnapshots` (`FoodSearchHistory.swift:170-175`).
- Other recipe surfaces fail the same way. The Swap-ingredient sheet (`IngredientSubstitutionSheet`, `candidates(limit: 12)`) shows no plain chips (codemap E4, `$SP/codemap/candidates.py`). Web import of "1 cup chocolate chips" parses cleanly (MEASURED, §3.5) and then binds the #1 row, "Cookies, marshmallow, with rice cereal and chocolate chips", whose only portion is "bar" 22 g (MEASURED, `sqlite3`). "cup" cannot convert, so the whole page's USDA estimate is voided (`RecipeWebImporter.swift:895`; composition of measured steps, not run end to end).

**30-second check on the owner's phone (the warm path is not modelled by any replica).** History is the
top sort key, manual foods rank above catalog rows, and correction aliases are prepended. If the owner
recently logged a chip cookie or granola bar, has a custom food named like one, or once corrected
"chocolate chips" to a cookie, the device list will differ from §2.1. Type "chocolate chips" in a
recipe ingredient and compare the six rows with §2.1; if they differ, one of those is the reason.

---

## 3. Banana, traced

### 3.1 What the user can and cannot do (MEASURED in Swift)

**Search works.** "Bananas, raw" is #1 for ban, bana, banan, banana and bananas (scores 749 to 810).
It is pinned at `FoodSearchCorpusTests.swift:393`.

**Units fail.** Tapping it sets 100 g (`FoodView.swift:2238-2248`).

| Amount | Result |
|---|---|
| 100 g (the tap default) | works |
| 1 oz | works |
| 1 serving | works, but it means 100 g, not one banana |
| 1 each, 1 piece | **fails** |
| 1 cup, 1 tbsp, 1 tsp | **fails** |

When it fails, the editor shows "This amount needs an exact serving basis or one source-backed
portion." (`FoodView.swift:2189-2191`) and **Save is disabled** (`canSave`, `:1683-1689`). The unit
picker still offers all 16 units, whether or not they can work (`:2168-2172`).

### 3.2 Why

The row's own USDA portions (MEASURED, `sqlite3 ... where name='Bananas, raw'`):

| Portion | Grams | Maps to a recipe unit? |
|---|---|---|
| NLEA serving | 126 | no |
| extra large (9" or longer) | 152 | no |
| large (8" to 8-7/8" long) | 136 | no |
| medium (7" to 7-7/8" long) | 118 | no |
| small (6" to 6-7/8" long) | 101 | no |
| extra small (less than 6" long) | 81 | no |
| cup, sliced | 150 | no |
| cup, mashed | 225 | no |

Three rules turn "USDA has the data" into "no conversion" (CODE):

1. **A portion counts only if its unit is spelled exactly like a unit.**
   - `FoodPortion.recipeUnit` (`NutritionModels.swift:2598-2612`) accepts a portion only if its whole unit string is one of the 16 spellings in `RecipeUnit.normalized` (`:1830-1867`).
   - The one exception is a unit that is empty or "undetermined" with a description shaped like "1 slice". The shipped catalog has no such portions (MEASURED by units).
   - "medium (7" to 7-7/8" long)" normalizes to "medium 7 to 7 7 8 long", which is not a unit. "cup, sliced" becomes "cup sliced", which is not "cup".
2. **Volume needs exactly one volume portion.**
   - `uniquePortion(in:)` (`:2584-2590`) refuses a food with two or more.
   - If both cup portions above were read, 150 g and 225 g would still count as "ambiguous".
3. **A count needs exactly one portion of that unit** (`uniquePortion(matching:)`, `:2579-2582`).

### 3.3 How it got here

Before `0ba40d90` (2026-08-24), size words mapped to "each" and the first match won. It was often wrong:

| Food | "1 each" before 2026-08-24 | Now |
|---|---|---|
| Bananas, raw | 152 g (extra large, first match) | refused |
| Egg, whole, raw, fresh | **243 g** (from "cup (4.86 large eggs)") | refused |
| Onions, raw | **14 g** (a slice) | refused |
| Carrots, raw | **7 g** (a strip) | refused |
| Apples, raw, with skin | 182 g (medium) | refused |

Across the 7,985 non-branded rows that carry portions, rows with a working "each" fell from **536 to
64** (MEASURED, `$SP/history/portion_units.py`).

The old rule was silently wrong and the new rule refuses. Neither has a default-size rule, and that
rule is the missing piece. The owner's decision 9 of 2026-08-23 ("Portions: future data-design item")
covers exactly this. It was never started (`Docs/Handoff/Round-2026-08-22-Progress.md:118-121`).

The prior memo's other units bug, `RecipeIngredient.scale` falling through to `return quantity` for
unparseable units, **was fixed** by `0ba40d90`: `resolve` now returns nil (`NutritionModels.swift:1961-1985`).
The `return quantity` still visible at `:2041` is the same-unit identity inside `convertedAmount`, which
is correct.

### 3.4 The same failure elsewhere

MEASURED (units replica and replay probe):

| Intent | Row | What happens | Data present but unread |
|---|---|---|---|
| 2 large eggs | Eggs, Grade A, Large, egg whole | "each" fails | `{unit: "egg", 50.3 g}` |
| 2 cloves garlic | #1 "Garlic, raw" (FDC 1104647, Foundation) | default 100 g works; "each" fails | RACC 85 g only |
| 2 cloves garlic | #2 "Garlic, raw" (FDC 169230, SR) | **default "1 cup" fails on tap** | clove 3 g, tsp 2.8 g, cup 136 g |
| 1 lemon | Lemons, raw, without peel | "each" fails | fruit 58 g / 84 g |
| 1 onion | Onions, raw | "each" fails | medium 110 g, large 150 g |
| 1 avocado | Avocado, Hass, peeled, raw | "each" fails | RACC 140 g only (USDA publishes nothing more) |
| 1 stick butter | Butter, salted | **default "1 cup" fails on tap** | stick 113 g, tbsp 14.2 g, cup 227 g |
| 2 tbsp peanut butter | Peanut butter, creamy | "tbsp" fails | no portions at all (USDA Foundation data has none) |

The two "Garlic, raw" rows tie at 810 and are ordered by SQL `food_id` (106 before 2072). The one the
user most likely taps has no clove data, so only borrowing from its SR sibling (Rung B) or a curated
size (Rung C) helps it. F6's identical-name collapse should keep the row that converts.

**Fail on tap.** Across the catalog, **16,310 rows (13.8%) fail the moment they are tapped** (MEASURED,
three independent replicas agree; breakdown from `$SP/revise/tapbreak.py`):

| Mechanism | Rows | Fix |
|---|---|---|
| Serving unit unreadable (U4): GRM 12,376, MLT 2,193, IU 193, GM 31, MC 2, survey units such as "sandwich" 48. The default is "1 serving", which the guard at `NutritionModels.swift:1962-1963` refuses before it reaches the `.serving` case | 14,843 | Rung 0a |
| The "oil" branch (`NutritionModels.swift:2550-2551`): a name containing "oil", no portions, a mass serving, so the default is "1 cup", which cannot convert. 879 of these names contain the word "oil" or "oils" (real oils); 151 contain it only inside another word ("boiled", "broiled") | 1,030 (995 branded, 35 srLegacy) | Rung 0c invariant |
| A single cup portion picks "cup" (`:2544-2545`), but the converter needs exactly one *volume* portion and the row has two or more (butter: cup and tbsp) (U5) | 437 srLegacy | Rung 0b |

So the "default disagrees with converter" mechanism (U5 plus the oil branch) reaches 1,467 rows. The
other 14,843 are the loader problem, which is why Rung 0a carries most of F1's impact.

Among the replay's distinct top-10 rows (deduplicated on name, type and portions), 131 of 1,231 fail on
tap (MEASURED, `$SP/replay/units.py`). They include Honey, Butter, Vanilla extract, Sugars granulated,
Oil canola and Lemon juice.

### 3.5 Knock-on effects (CODE unless marked)

- **One failing ingredient zeros a recipe.** `macroTotals` returns all zeros if any ingredient fails to convert (`App/Fernlet/MealBuilder.swift:283-286`). **Sharing drops such a line silently**: `sharedIngredients` uses `compactMap` (`FernletKit/Sources/FernletExchange/FernletExchange.swift:95-97`). The recipe editor itself cannot save such a recipe (`canSave`, `FoodView.swift:1683-1689`), so these paths are reached by imported, received or legacy recipes, or after a catalog change.
- **"Use manual nutrition" seeds the wrong basis.**
  - It copies the per-100 g macros onto whatever amount is typed (`FoodView.swift:2193-2198`). "2 tbsp" of creamy peanut butter comes out about 3.1 times too high (units replica).
  - It also creates a user food with the catalog's exact name, which then outranks the catalog row.
- **The web importer's line parser is broken** (MEASURED, the shipping regex run through `NSRegularExpression` in `$SP/revise/rx.swift`).
  - In the unit alternation at `FernletKit/Sources/AIProviders/RecipeWebImporter.swift:918`, "l" comes before "large", "liters?" and "ml" handling, and "g" comes before "grams?" and "glasses?". `\s*` lets the unit swallow the first letter of the food name.
  - Results: "2 large eggs" gives unit "l", name "arge eggs". "100 grams flour" gives "g", "rams flour". "1 lemon" gives "l", "emon". "2 garlic cloves" gives "g", "arlic cloves". "1 lime", "1 leek", "1 glass milk" and "1 gallon milk" break the same way.
  - The mangled names match 0 FTS rows (MEASURED, `sqlite3 ... match 'arge* AND (eggs* OR egg*)'` and the others all return 0), and the partial fallback runs only for `.userTyped` (`FoodCatalog.swift:224`). So these lines are silently skipped (`:889-892`), and the estimate undercounts.
  - Lines that do parse can void the whole page. "medium", "small", "whole" and "clove(s)" map to "each" (`:963-970`); "each" on a row without a count portion fails, and one failing line returns nil for the entire estimate (`:895`). Examples: "1 medium onion", "3 cloves garlic", "1 cup chocolate chips" (§2.6), and "2 cups all-purpose flour", whose #1 row is the RACC-only "Flour, wheat, all-purpose, enriched, bleached" (MEASURED in the replay: "1 cup" false). Composition of measured steps, not run end to end.
  - An empty or unknown unit maps to "serving", not "each" (`:969`). No test covers "large", "grams" or a g/l-initial food (`Tests/FernletTests/FoodSearchHistoryTests.swift:464-476` uses "1 flour" and "1 each ramen").

---

## 4. Measured: the replay

**Method.** Commit `5b654c2d` on branch `claude/r0929-search-replay` adds an opt-in probe. It runs the
editor's exact call, `catalog.results(for:context:.userTyped)` with the default limit of 6, for 160
queries (55 baking, 45 produce, 47 pantry, 13 typing prefixes) on a cold catalog. For each query it
also records the tap default and whether 1 each, 1 piece, 1 cup, 1 tbsp, 1 tsp, 100 g, 1 oz and
1 serving convert. The simulator was an iPhone 17 on iOS 26.5.

A query **passes** when a plain generic form of the ingredient is #1. The judgement patterns are
regexes in `$SP/replay/accept.py`, so they can be re-run and argued with. They judge names only, not
nutrition (see 4.1a).

### 4.1 Rates (base catalog, which is what the owner's phone runs)

| Category | n | #1 | #2-3 | #4-6 | #7-10 | FAIL (exists, not in top 10) | GAP (not in catalog) | Plain row visible in the 6 |
|---|---|---|---|---|---|---|---|---|
| Baking | 55 | 35 (64%) | 7 | 4 | 0 | 8 | 1 | 46 (84%) |
| Produce | 45 | 34 (76%) | 2 | 4 | 2 | 3 | 0 | 40 (89%) |
| Pantry | 47 | 24 (51%) | 12 | 4 | 1 | 4 | 2 | 40 (85%) |
| Prefix | 13 | 4 (31%) | 2 | 0 | 1 | 5 | 1 | 6 (46%) |
| **All** | **160** | **97 (61%)** | 23 | 12 | 4 | **20 (12%)** | 4 | **132 (82%)** |

With the optional branded catalog attached (not on the device; §1), the numbers barely move: 100 at #1,
21 FAIL, 0 GAP. It fills the three missing staples, and then two of them (salt, water) fail on the tier
rule instead.

### 4.1a The same rates with a nutrition check

15 queries land on a branded row as their first plain answer. Of those, 7 land on a row whose macros are
physically impossible for its serving (over 900 kcal per 100 g, or more macro grams than the serving
weighs), and 2 more land on a same-name duplicate set where the broken row has the lower `food_id` and so
sorts first (INFERRED from the stable sort). MEASURED, `$SP/revise/plaus.py`:

| Query | Verdict | Row | Implied kcal/100 g |
|---|---|---|---|
| semi sweet chocolate chips | PASS #1 | Organic Semi-Sweet Chocolate Chips, 15 g | 3,767 |
| white chocolate chips | PASS #1 | White Chocolate Chips, 14 g | 4,086 |
| apple cider vinegar | PASS #1 | Apple Cider Vinegar, 18 g | 1,111 |
| dijon mustard | PASS #1 | Dijon Mustard, 5 g | 2,160 |
| extra virgin olive oil | PASS #1 | Extra Virgin Olive Oil (broken 9446 sorts before the correct 108509) | 5,580 |
| cherry tomatoes | PASS #1 | Cherry Tomatoes (broken 23819 sorts before 76933) | 1,171 |
| sprinkles | OK #2 | Sprinkles, 4 g, C100 | 10,000 |
| olive oil | WEAK #5 | Olive Oil, 15 ml, all 20 same-name rows | 5,580 |
| mayonnaise | WEAK #7 | Mayonnaise, 13 g | 5,331 to 5,885 |

So **6 of the 97 PASS results land on broken nutrition**. Gated on plausibility, #1 is 91 of 160, not 97.
Every ranking change that promotes branded rows (F3, F5, score-first) makes this worse unless F2 lands
first.

### 4.2 Failure clusters (63 non-#1 queries; a query can carry several)

| Code | Cluster | Queries | Examples |
|---|---|---|---|
| P | A product whose name contains the typed phrase beats USDA's "Noun, qualifier" name | 22 | brown sugar (cereals 365 vs "Sugars, brown" 60), whole milk (ricotta), canola oil (hash browns "fried in canola oil") |
| A | Dozens of rows tie on score and the alphabet decides | 14 | flour ("Flour, 00 / almond / barley…"), milk ("Milk and cereal bar" before cow's milk at #28), egg |
| K | The plain row is branded and sits below every srLegacy row with the words | 14 | chocolate chips, olive oil, mayonnaise, spaghetti, sprinkles |
| D | A derived form ranks first | 13 | lemon (lemon grass, juice, peel), yeast (yeast extract spread), sugar (turbinado) |
| T | An FNDDS survey dish outranks the ingredient on data type | 12 | tomato ("Pork with chili and tomatoes" 248 over "Tomato, roma" 810), egg, rice, butter |
| S | Plural/singular mismatch loses the +60 bonus | 9 | potato ("Potatoes, …"), sugar ("Sugars, …"), lemon |
| X | The typed word is a prefix of another word | 6 | apple (10 APPLEBEE'S rows), bread ("breaded"), salmon (Salmonberries) |
| V | The plain row's name lacks the typed words | 6 | chocolate chips, garlic clove, red pepper flakes, vegetable oil |
| F | The −130 "form" penalty meant for egg white/yolk hits the wrong rows | 5 | "Rice, white" 676 vs "Rice, brown" 806; "Apples, … with skin" |
| G | Not in the catalog at all | 4 | baking soda, "baking s", salt, water. Cause MEASURED: the build dropped every SR food with zero protein, carbs and fat (§6.2) |
| 1 | A single-letter trailing word is dropped | 4 | "chocolate c", "brown s", "baking s", "chicken b" (`FoodItemSearch.swift:727`) |
| M | The "salad" carrier demotes a real ingredient | 2 | "Oil, olive, salad or cooking" sunk to #60; "Salad dressing, mayonnaise" to #40 |

Salt and water carry K as well as G. The K describes the branded run only; in the base run they are
catalog gaps.

### 4.3 Units in the same run

| Measure | Result |
|---|---|
| Count-noun queries whose plain row accepts "1 each" or "1 piece" | **1 of 26** (only "Chicken breast, roasted"). Queries, not rows: banana/bananas and carrot/carrots share rows |
| Volume ingredients whose plain row accepts 1 cup, tbsp or tsp | **17 of 84** |
| Rows with 2 or more volume portions that convert any volume | **0 of 121**. All 258 rows with exactly one volume portion convert (225 of them are gram-served) |
| Distinct top-10 rows (name, type, portions key) whose tap default fails immediately | **131 of 1,231** |

### 4.4 The existing 57-query corpus

- `FoodSearchCorpusTests.swift:309` pins `(zeroResults: 6, wrongTopOne: 24, defensible: 27)`.
- **12 of the 24 wrong answers are the chocolate-chips class**: a composite that contains X beats plain X. Examples are apple, brown rice, cheddar cheese, tomatoes, potatoes, white rice, whole milk and olive oil (history, from the pinned names).
- The corpus checks only the top result. The editor shows 6, and no test checks whether the plain ingredient appears in those 6, or whether its nutrition is plausible.

---

## 5. Root causes, ranked by how many failures each explains

Counts of distinct non-#1 queries from §4.2, out of 63 (MEASURED from the replay tags; Appendix B.2).

| Rank | Root cause | Queries | FAIL or GAP among them | Where | Owner case |
|---|---|---|---|---|---|
| 1 | **The score measures literal text, not identity** (P, S, A, F, D) | **47** | 17 | `phraseScore` `FoodItemSearch.swift:594-600`; exact-word +60 `:569-571`; form penalty `:606-618` | chips (singular) |
| 2 | **Data type sorts above score** (T, K) | **25** | 13 | `ranksAhead` `:486-488`; priorities `:703-721` | **chips** |
| 3 | Vocabulary and coverage (V, G) | 10 | 9 | FTS columns `BundledFoodStore.swift:106-107`; name floor `FoodItemSearch.swift:523-530`; zero-macro staples dropped by the build | **chips** |
| 4 | Token mechanics: prefix collisions, single-letter drop (X, 1) | 10 | 6 | `FoodItemSearch.swift:723-728` | typing "chocolate c" |
| 5 | Demotion vocabulary: "salad" too broad, sweets missing (M, plus the chips case) | 2 (+ chips) | 0 | `NutritionModels.swift:1506-1516` | **chips** |

- 58 of the 63 carry a ranking cause (1 or 2) observed in the base run. The other 5: four catalog gaps (baking soda, "baking s", salt, water) and one vocabulary-only query (red pepper flakes).
- Counting only queries whose tags fall entirely inside one cause: 28 are cause 1 only and 8 are cause 2 only. 12 carry both.
- For the 28 queries whose plain row never shows, see §1.

On a separate axis, **the conversion causes**, ranked by reach (MEASURED):

| Rank | Cause | Reach | Where | Owner case |
|---|---|---|---|---|
| U1 | Portion text is not parsed | 25 of 26 count-noun queries fail "1 each"; 55% of displayed portions map to nothing | `NutritionModels.swift:2598-2612` | **banana** |
| U2 | Exactly one volume portion required | 0 of 121 multi-volume rows convert any volume | `:2584-2590` | butter, sugar, olive oil |
| U3 | Branded rows carry no portions | 0 of 109,163 | catalog build | chips "1 cup" |
| U4 | Raw FDC unit codes are unreadable (GRM, MLT, GM, IU, MC, survey units) | **14,843 rows (12.5%)** convert nothing, not even grams | guard at `:1962-1963` | chips row 107005 |
| U5 | The tap default disagrees with the converter | **1,467 rows** (437 multi-volume cup defaults, 1,030 "oil" branch) | `:2539-2560` vs `:2031-2035` | butter, garlic 169230, olive oil |

U4 and U5 together are the 16,310 rows that fail on tap (§3.4).

And four data defects:

| Defect | Reach | Detail |
|---|---|---|
| D1: branded per-100 g macros stored against a label serving | 58,281 rows affected | §6.5 |
| D2: branded products typed srLegacy | 816 rows in the FDC 6xxxxx and 7xxxxx ranges, 747 of them with carbs = 0 (MEASURED); 763 by non-SR category (verifier) | "Barny Biscuit Vanilla Chocolate Chip" shows C0. They outrank real branded rows by tier. The FDC range also holds a few real generics (FDC 746761, beef round, carbs 0 naturally), so retype by category, not by range. |
| D3: Foundation Foods typed srLegacy | 0 rows are typed `foundation`; the 252 rows with FDC ids of 1,000,000 or more (for example 1104647 "Garlic, raw") are typed srLegacy | `dataTypePriority` 5 for foundation (`FoodItemSearch.swift:714`) never fires. "Generic-first" really means srLegacy plus 202 survey rows. |
| D4: zero-macro SR foods dropped | all 32 SR Legacy foods with protein, carbs and fat all 0 (salt, baking soda, tap and bottled waters, teas, spirits) | §6.2 |

---

## 6. Units and portions

### 6.1 The current model (CODE)

- **A recipe line** is `RecipeIngredient {foodItemId, quantity, unit}` (`NutritionModels.swift:1728-1739`). It stores no grams. The unit is a frozen `RecipeUnit` token, and there are 16 of them (`:1789-1805`).
- **Conversion** (`RecipeServingConversion.resolve`, `:1961-1985`) runs in this order:
  1. It checks that the food's own serving unit normalizes. This happens *before* the "serving" case, so a GRM food refuses even "1 serving".
  2. "serving" scales by quantity.
  3. The same unit as the serving is exact.
  4. The same dimension uses physical factors.
  5. Otherwise it asks for grams via a unique source portion.
- **It fails closed by design.** This is recorded at `Docs/Food-Catalog-Remaining-Plan-2026-08-24.md:145` and pinned at `Tests/FernletTests/MealBuilderTests.swift:380-393`.
- **The picker** lists all 16 units for every food (`FoodView.swift:2168-2172`), using the English `String` label (`NutritionModels.swift:1809-1828`).
- **The same functions drive meal logging, not just recipes.** `preferredRecipeUnit` and `defaultRecipeQuantity` set quick-log quantities (`FernletKit/Sources/AIProviders/FoundationFoodSelection.swift:246`, `:251-272`, `:327`), and `servingConversion` gates binds in `App/Fernlet/FoundationDishDecomposition.swift:261`, `App/Fernlet/WholeDescriptionFoodProbe.swift:169`, `App/Fernlet/MealBuilder.swift:244` and `:268`, `FoodView.swift:4171-4174` and `FernletKit/Sources/FernletDomainModel/RecipeSubstitution.swift:48-61` (CODE, `grep`). Every unit fix below therefore changes meal logging too.

### 6.2 The gap

MEASURED (units `stats.out`, `sqlite3`):

| Fact | Number |
|---|---|
| srLegacy rows with portions | 7,783 of 8,888 (87.6%) |
| Branded rows with portions | 0 of 109,163 |
| `serving_description` filled | 0 of 118,317 |
| srLegacy rows with count data in their portion text | 3,274 (36.8%) |
| srLegacy rows where a count unit actually converts (each, piece or slice) | 440 (5.0%) |
| srLegacy rows with volume data in their portion text | 3,225 (36.3%) |
| srLegacy rows where a volume unit actually converts | 1,730 (19.5%) |
| Distinct portion unit strings | 1,861 case-insensitive (1,876 raw) |

**What the build kept and dropped** (MEASURED, `$SP/revise/srzero.py` against
`~/Downloads/FoodData_Central_sr_legacy_food_json_2018-04.json`):

- USDA's SR Legacy file has 7,793 foods. 7,761 are in the catalog, with all of their 14,376 portions.
- The 32 missing foods are **exactly** the 32 whose raw protein, carbs and fat are all 0.0, carrying 73 portions: "Salt, table" (173468), "Leavening agents, baking soda" (175040), "Beverages, water, tap, drinking" (173647), bottled waters, teas, club soda and distilled spirits.
- The drop is already present in the committed intermediate `FoodDataSource/USDAFoodItems.json` (`grep -c '"Salt, table"'` returns 0). The script that produced that file is not in the tree at HEAD (not traced further).
- The 43 catalog srLegacy rows that show 0/0/0 are non-zero in the raw file; their values round to 0.

So cluster G has a measured cause, and F6 can restore these rows by rule instead of hand-adding staples.

### 6.3 Proposed default design

The design is a ladder. It stays fail-closed: an unknown count never silently becomes grams.
Sources are USDA only (SR Legacy, Foundation, FNDDS; public domain / CC0), which keeps to the standing
"public data only, never paid" principle.

**Rung 0: bug fixes, no new data.**
- 0a. Handle "serving" before the serving-unit guard. Map GRM and GM to g, and MLT to ml, when the catalog loads (`BundledFoodStore.swift` hydrate). This makes 12,407 rows usable in mass units (GRM 12,376 + GM 31) and 2,193 MLT rows usable in volume units (they have no portions, so no density, so not grams). The 195 IU and MC rows and the 48 survey-unit rows gain "1 serving" only, from the guard reorder.
- 0b. For volume, try the portion that matches the exact unit first. Then accept several volume portions if they imply the same density within 15%.
  - Olive oil shows this works. Tbsp 13.5 g, cup 216 g and tsp 4.5 g all give 0.913 g/ml (MEASURED, FDC 171413).
  - This fixes butter, sugar, olive oil, milk, honey and garlic 169230. It keeps the two-identical-slices test at `MealBuilderTests.swift:380` green, because that test is about counts.
- 0c. Add an invariant: the default unit must convert, otherwise use grams. This removes all 16,310 fail-on-tap rows once 0a lands. Matching "oil" as a word instead of a substring fixes only 151 of the 1,030 oil-branch rows; the other 879 are real oils served in grams with no portions, where "1 cup" can never convert. The invariant is the fix, and a word match must keep plural "oils".
- 0d. "Use manual nutrition" must seed macros that match the amount shown.
- 0e. Web import: fix the parser (longest unit first, and a word boundary after the unit), map a size word to "each" only when a count portion exists, and do not let one bad line void the page's estimate.

**Rung A: read the row's own portions.**
- A tolerant reader:
  - takes the leading measure word and drops qualifiers like ", sliced" and "(7" long)";
  - classifies cup, tbsp, tsp and fl oz as volume, and oz and lb as mass;
  - treats RACC, NLEA and "serving" as a reference serving;
  - treats everything else as a *named count* ("medium", "egg", "clove", "stick", "fruit").
- The picker is built per food:
  - named portions with grams first ("medium banana · 118 g", "clove · 3 g", "stick · 113 g");
  - then g and oz;
  - then cup, tbsp and tsp, only when Rung 0b yields a density;
  - then "1 serving (100 g)".
  - Units that can't convert are hidden.
- Projected coverage for non-branded rows (MEASURED, units projection replica): count options rise from 5.0% to 36.5%, and volume from 20.6% to 35.3%. This covers banana, egg, garlic 169230, lemon, onion, apple, butter stick and the SR semisweet chips row.

**Rung B: borrow from a same-name sibling.** Small reach (184 rows). It targets the thin Foundation
rows that win search, such as "Garlic, raw" FDC 1104647, which has RACC only.

**Rung C: a curated count table**, keyed by a frozen English head noun and badged "USDA typical size,
estimate". Every value is from a shipped SR row. Starred values were spot-checked against the shipped
catalog.

| Noun | Default | Other sizes | Source |
|---|---|---|---|
| banana* | medium 118 g | xs 81, s 101, l 136, xl 152 | SR 173944 |
| egg* | large 50 g | s 38, m 44, xl 56, jumbo 63 | SR 171287 |
| garlic* | clove 3 g | tsp 2.8 | SR 169230 |
| butter* | stick 113 g | tbsp 14.2, pat 5 | SR 173410 |
| lemon | fruit 58 g | 84 g; juice of 1 lemon 48 g | SR 167746, 167747 |
| onion | medium 110 g | s 70, l 150 | SR 170000 |
| apple | medium 182 g | s 149, l 223 | SR 171688 |
| avocado | fruit 136 g | Florida 304 | SR 171706, 171707 |
| carrot | medium 61 g | s 50, l 72 | SR 170393 |
| potato | medium 213 g | s 170, l 369 | SR 170026 |
| tomato | medium 123 g | s 91, l 182, cherry 17 | SR 170457 |
| bread | slice 29 g | thin 20 | SR 174924 |

The full starter set (about 30 nouns) is in the units write-up, §4.2.

**Rung D: grams per cup for baking staples** (again from shipped SR rows; starred values spot-checked):

| Ingredient | g per cup | Other | Source |
|---|---|---|---|
| All-purpose flour* | 125 | | SR 168894 |
| Granulated sugar* | 200 | tsp 4.2 | SR 169655 |
| Brown sugar, packed* | 220 | unpacked 145 | SR 168833 |
| Semisweet chocolate chips* | 168 | mini 173, large 182 | SR 167976 |
| Butter* | 227 | tbsp 14.2 | SR 173410 |
| Olive oil* | 216 | tbsp 13.5 | SR 171413 |
| Honey | 339 | tbsp 21 | SR 169640 |
| Peanut butter | 258 | tbsp 16 | SR 174265 |
| Rolled oats | 81 | | SR 173904 |
| Cocoa powder | 86 | tbsp 5.4 | SR 169593 |

FNDDS lists chocolate chips at 225 g per cup. That disagrees with SR's 168 g, and 168 g matches a
6 oz bag. Prefer SR and flag the FNDDS value.

**Rung E: an honest fallback.** When nothing is known, replace the current jargon with "How many
grams is one?" and remember the answer as a local per-food portion. That is a new persisted surface,
so it needs a `Docs/PrivacyWipeCoverage.md` disposition row in the same commit.

**Persistence (the constraint that shapes the design).**
- A recipe line is converted again at read time against the catalog row (`NutritionModels.swift:1961-1985`). So a household choice must be saved as **grams** (for example `236 g`), the only encoding every older build resolves. Use `2 each` only when today's reader already resolves "each" for that row; a "2 each" banana line that only the new reader understands totals zero on an older paired device (`MealBuilder.swift:283-286`). Keep "2 medium" as optional display metadata.
- Do not add new unit tokens. A receiver builds a food from the shared unit string (`App/Fernlet/FernletStore.swift:5278-5297`). On an older peer, a token its `RecipeUnit.normalized` doesn't know fails to convert, and the recipe totals zero. Practical risk is low while the owner is the only user.

### 6.4 Shipping FNDDS alone would not fix banana

The unshipped item-13 artifact (`../fernlet-wt-food/.food-catalog-build/FoodCatalog.sqlite`) has FNDDS
"Banana, raw" with portions "1 banana" 126 g, "1 cup" 150 g, "1 slice" 6 g, all with unit
"undetermined" (MEASURED). That artifact uses a different schema (`display_name`, a separate portion
table), which `BundledFoodStore` cannot load as is.

Under today's `recipeUnit`, "1 banana" fails because "banana" is not a count word. "1 cup" also fails,
because the description path admits only count words (`NutritionModels.swift:2606-2610`). Only
"1 slice" would map. The reader has to change first (Rung A).

### 6.5 A separate serious bug: branded per-100 g macros on a label serving

- **Where it comes from.** 59,163 branded rows came from `USDAFoodItems.json` (ids starting `00000000-0000-5000-`). USDA's branded `foodNutrients` are per 100 g or ml, and the file stores them next to the *label* serving size. The app treats the macros as belonging to that serving.
- **Measured:**

  ```
  $ sqlite3 -readonly FoodCatalog.sqlite "select case when id like '00000000-0000-5000-%' then 'fdc-json'
    else 'gtin' end o, serving_unit, count(*), sum((4*protein+4*carbs+9*fat)*100.0/serving_size > 900)
    from food where data_type='branded' and serving_unit in ('g','GRM') group by 1,2;"
  fdc-json|g|52852|26042
  gtin|GRM|12376|23
  gtin|g|29925|53
  ```

  Read per serving, **49% of those gram-served rows exceed 900 kcal per 100 g**, which is physically impossible. The other branded rows show 0.2%. This is the lower bound: it only catches servings under 100 g where the error is large.
- **Pairing test** (MEASURED, `$SP/revise/pair.py`): of 8,439 fdc-json rows that share a name and serving size with a GTIN row (non-zero macros, serving not 100), 7,476 (89%) equal the GTIN per-serving macros scaled to per 100 g, within 1 g. Only 430 (5%) match per serving. A verifier's looser pairing got 9,740 of 10,143 (96%). So the whole fdc-json set is on a per-100 g basis, not just the rows that look impossible.
- **Checked against USDA's raw label data** (units):
  - "Organic Semi-Sweet Chocolate Chips" shows P7 C60 F33 for 15 g. The label says P1 C9 F5, so the app is **6.7 times** over.
  - "String Cheese" shows P29 for a 28 g stick. The label says P8, so it is **3.6 times** over.
- **Scope.** 58,281 rows with a serving other than 100: about 44,517 over-count and about 13,764 under-count (for example "2% MILKFAT REDUCED FAT MILK" at 240 ml shows per-100 ml values).
- **Who sees it.** Quick-log, search suggestions and recipes alike. `NutritionPlausibility` runs only on user-entered foods (`CustomIngredientUpsert`, `NutritionLabelScanner`), never on catalog rows, so nothing masks it.
- **How the fix must model the label serving.** Quick-log turns a bare count ("2 string cheese") into `count × defaultRecipeQuantity(for: unit)` (`FoundationFoodSelection.swift:251-272`). If a shim only sets the serving to 100 g, "2 string cheese" becomes 2 × 100 g at correct per-100 g macros: still P58, 3.6 times the label. The label serving must become a *count* portion (unit "each", described "1 serving (28 g)") so that `preferredRecipeUnit` picks "each" (`NutritionModels.swift:2547-2548`) and "2" means two sticks.
- **30-second check on device:** search "string cheese". The suggestion reads "28 g · P29g".

### 6.6 Localization constraints

- **Frozen tokens.** `RecipeUnit` raw values are persisted, synced and shared, so they are frozen tokens. No canary test pins them yet: `grep RecipeUnit Tests/FernletTests/LocalizationBoundaryTests.swift` finds 0 lines. Add one next to the `frozen…Tokens` tests (`:440-500`).
- **Labels aren't localized.**
  - Unit labels reach the screen as a plain `String` through `Text(unit.label)` (`FoodView.swift:2170`), so they are never localized. "Tablespoons" is absent from `Localizable.xcstrings` (0 matches).
  - Because `RecipeUnit` lives in an SPM module, a localized label must pass `bundle: .module`, or be mapped in the app target.
- **Raw tokens show on screen.** "tbsp", "each" and "GRM" appear in the collapsed row and in suggestions (`FoodView.swift:1851-1853`, `:1987`).
- **New vocabulary.** Size words, curated nouns and alias phrases must be frozen English keys with a separate localized display. USDA portion descriptions are source data and are shown verbatim, like food names.

Side note for the separate decimal-point item: macros are `Int` end to end (`Macros`,
`NutritionModels.swift:695-698`; the catalog's columns are `INTEGER`; `Macros.scaled` rounds each
product, `:2517-2534`, so 3 g of garlic comes out as P0 C1 F0). Quantity already accepts decimals
(`.decimalPad`, `FoodView.swift:2159-2160`). That item is being handled on branch
`claude/r0929-decimals` (`916b9d7c`, an additive `preciseMacros` side channel); it does not change
anything in this report.

---

## 7. What the August rounds did and what they left

The sources are the history sweep, git and the ledger at `Docs/Handoff/Round-2026-08-22-Progress.md`.

| Item | Status | Commit | Bearing on these cases |
|---|---|---|---|
| 57-query corpus | Done | `c6cb9c22` | Checks top-1 only |
| 1.6 stopwords, 1.7(a) guarded demotion, 1.8 name and score floors | Done | `809e25e1` | Net positive; no effect on chips (all 28 rows carry both words in their names) |
| 1.9 history ranking | Done | `9d0e1d13` | Can put a logged cookie first (INFERRED) |
| 1.10 correction memory | Done, meal-correction sheet only | `9aa090a9` | Recipe picks never write a correction |
| 1.11 composer search and empty states | Done | `525b0c80` | "Create custom ingredient" only on zero results |
| Item 12: safe household conversion | Done | `0ba40d90` | **Banana regression by design**: rows with a working "each" fell from 536 to 64. Also fixed the old `return quantity` fall-through (§3.3). |
| **1.7(b) score-first** | **Not built.** Authorized 2026-08-23 "as a measured increment (after item 13)" (ledger decision 1, `:97-99`); item 13's catalog never shipped (decision 4). The Task 7 prompt asked for score-first (`Docs/Handoff/Next-Round-Prompt-Food-Catalog-2026-08-24.md:205-214`); the slot produced `ee3d3361` "Preserve generic-first", whose test says plural eggs and ground beef "exposed this regression" (`FoodCatalogTests.swift:224-226`) | `ee3d3361` | **Locks in the chips mechanism.** The evidence points to score-first having been tried and reverted on purpose, though no ledger row records the measurement. Measured here, it is not the right fix alone (§1). |
| `confidentBindScore` re-derivation | Done in the wrong order: 250 to 368 on today's comparator | `93df2064` | Must be re-derived after any ranking change (owner decision 2 already says so) |
| Item 13 catalog regeneration | Tooling only; catalog never shipped (owner decision 4) | `940332d2` | The artifact holds an FNDDS "Chocolate chips" row (food_id 4951; portions 1 piece 1 g, 1 cup 225 g, QNS 15 g; MEASURED). That it would rank #1 is INFERRED from survey priority plus an exact-name score; it was not run, and the artifact's schema cannot be loaded as is. |
| Portions design (owner decision 9) | Not started | none | **This is the banana case** |
| Remaining-plan P0 to P2 (portion provenance, serving presets, aliases) | Not started | none | Aliases fix chips; presets fix banana |
| Partial fallback | Done, then gated | `ab6e573d`, `ab466c7f` | Fires only on zero results, and only for `.userTyped` |

The shipped `FoodCatalog.sqlite` last changed in `7bb3e576` (2026-07-12). The recipe typeahead's call
shape has not changed since 08-01, apart from the `context:` argument.

**Regressions:** banana (units, deliberate, `0ba40d90`). None in search (INFERRED for chips; §1).

---

## 8. Recommended fixes, ranked

The order is value per unit of risk, with dependencies respected. Two ordering rules come from the
verification: **F2 must land before any change that promotes branded rows** (F3, F5, score-first),
and **every unit fix changes meal logging as well as recipes** (§6.1), so the meal-resolution suites
must be re-run with each.

### F10. Tests that would have caught this (first, as the measuring stick)

- **Changes:**
  - Pin the 160-query ingredient set as a "plain row in the top 6" corpus with a baseline tuple, like `FoodSearchCorpusTests`. Judge nutrition too: a row over 900 kcal/100 g, or with more macro grams than serving grams, never counts as a pass. Tighten the carrot pattern to reject ", salad".
  - Add a "default unit converts" sweep over the bundled catalog (bounded).
  - Pin "1 each" for about 20 count nouns.
  - Pin web-import lines: "2 large eggs", "100 grams flour", "1 lemon", "2 garlic cloves", "1 cup chocolate chips".
  - Add the `RecipeUnit` frozen-token canary.
- **Risk:** none (tests only). Keep catalog sweeps bounded for CI time.
- **Type:** Refinement. **Owner decision:** No.

### F2. Branded per-100 g basis (load-time shim)

- **Changes:** in `BundledFoodStore.swift` hydrate, for `dataType == .branded` rows whose id starts `00000000-0000-5000-` (the 59,163 fdc-json rows), set the serving to 100 g (or 100 ml for ml servings), keep the macros as they are, and add the label serving as a *count* portion: unit "each", description "1 serving (28 g)", gram weight = label serving. A regenerated catalog binary is not committed (decision on record), so the shim is the path.
- **Impact:** corrects nutrition on 58,281 rows (chips 6.7 times, string cheese 3.6 times) across search, quick-log and recipes, and gives about half the branded rows their first portion. Quick-log "2 string cheese" becomes two 28 g sticks.
- **Risk:** medium. Displayed servings change. It touches the meal path (`FoundationFoodSelection.swift:251-272`) and bind gates. Pin "2 string cheese" quick-log and a branded recipe line. Check whether `ODRAssets/FoodCatalogBranded.sqlite` (built by `Scripts/branded-catalog/`) has the same basis (not measured).
- **Type:** Structural (data). **Owner decision:** No (bug fix; the rebuild path is ruled out by the decision on record).

### F1. Unit Rung 0 bug fixes

- **Changes:**
  - `NutritionModels.swift`: `resolve` guard order (serving first), volume portion selection (exact unit first, then density agreement within 15%), and the `preferredRecipeUnit` invariant that the default must convert or fall back to grams.
  - Load-time unit aliases in `BundledFoodStore.swift` (GRM and GM to g, MLT to ml).
  - `FoodView.swift`: the "Use manual nutrition" seed.
- **Impact:** fail-on-tap drops from 16,310 rows to 0 (replica target). 12,407 rows usable in mass units, 2,193 in volume units, 243 in "serving" only. The 121 multi-volume rows convert when their portions agree: butter, sugar, olive oil, milk, honey, garlic 169230. Does not fix "each" for banana.
- **Risk:** low to medium. Persisted formats are unchanged and no new tokens are added, but quick-log quantities and bind acceptance change (§6.1). Re-run `MealBuilderTests`, `RecipeScalingTests`, `WholeDescriptionFoodProbeTests`, `DishTemplateBindAuditTests`, `MealDecompositionRecipeWireTests`, `IngredientSubstitutionTests`, `RecentIngredientSpecializationTests`. `MealBuilderTests.swift:380` stays green. Power-of-10: loops bounded by portion count; functions at 60 lines or fewer.
- **Type:** Refinement. **Owner decision:** No.

### F11. Web importer parser (new)

- **Changes:** `RecipeWebImporter.swift:918`: order the unit alternation longest first and require a word boundary after the unit (`(?=\s|$|\.)`); map size words to "each" only when the bound row has a count portion (`:963-970`); skip a line whose conversion fails instead of returning nil for the whole page (`:895`), and record it as skipped.
- **Impact:** "large", "grams", "glass" and every food starting with g or l parse again; one hard line no longer voids a page.
- **Risk:** low. `RecipeWebImporterTests`, `FoodSearchHistoryTests` (`:464-476`). The "void on failure" rule is documented at `:878-879` as deliberate ("rather than silently publishing a partial nutrition estimate"), so the replacement should publish the partial estimate with a visible "n ingredients not counted" note rather than silently.
- **Type:** Refinement. **Owner decision:** No, if the partial estimate is labelled.

### F6. Catalog hygiene (load-time, no binary rebuild)

- **Changes:**
  - Restore the 32 zero-macro SR foods by rule, from a small bundled supplement of public USDA SR rows read beside the SQLite (salt, baking soda, waters, teas, spirits).
  - Retype branded products typed srLegacy by category (not SR food groups), not by FDC range alone.
  - Retype Foundation rows (FDC 1,000,000 and up) as `foundation`, or leave them and drop the dead tier: measure both.
  - Collapse identical-name rows in the typeahead, keeping the one that converts and passes the plausibility check (fixes 64235 over 106868, and 1104647 over 169230 for garlic).
- **Impact:** closes the 4 GAP queries; removes the Barny and Belvita rows that crowd chips; stops ties from landing on the worst duplicate.
- **Risk:** low to medium. The dedupe must be bounded and must never hide a row the user saved. Retyping moves ranks; re-run the corpus.
- **Type:** Refinement (data). **Owner decision:** No.

### F7. A small alias layer (the targeted chips fix)

- **Changes:**
  - A curated table of frozen English phrase-to-row aliases, applied only for `.userTyped` inside the typeahead, prepending the target without removing anything: "chocolate chip(s)", "choc chips", "semi sweet chocolate chips" to "Candies, semisweet chocolate" (818); "garlic clove" to "Garlic, raw" 169230; "red pepper flakes" to "Spices, pepper, red or cayenne"; "vegetable oil" to "Oil, soybean…".
  - Match on the query as a prefix of an alias phrase once the first word is complete, so "chocolate chi" works.
  - Fold "semi sweet" into "semisweet".
- **Do not** build it on `FoodCatalog.promotingCorrection` (`FoodCatalog.swift:297-307`): that is exact-key only, and it runs for every context, including `candidates()` (`:326-342`) and the importer's limit-1 bind, so it would inject rows into meal-resolution pools. **Do not** index portion text in FTS instead: the name floor (`FoodItemSearch.swift:523-530`) and the scorer's own gate (`Index.init`, `:183-194`) would drop those rows anyway.
- **Impact:** fixes cluster V (6 queries), plural and singular chips, and the typing prefixes. With F1 0b and the F4 reader, row 818's cups (168 to 182 g) make "1 cup chocolate chips" work with correct USDA macros.
- **Risk:** low. Frozen English keys; es, fr and de are added alongside later. Bundled resource only (no network, no no-tracking review).
- **Type:** Refinement. **Owner decision:** No.

### F4a. Minimal banana fix (split out of F4)

- **Changes:** in `NutritionModels.swift`, a bounded portion reader that recognises a row's own named count portions (size words "medium", "large", "small", "extra large", "extra small", and single named counts such as "egg", "clove", "fruit", "stick", "pepper"). When a row has several size portions, "each" resolves to "medium" if present, otherwise to the single named count. The editor saves the line as grams (§6.3 persistence), with "1 medium" as display metadata only.
- **Impact:** banana (118 g), onion (110 g), carrot, cucumber, jalapeno, egg (50.3 g), garlic 169230 (3 g), lemon: "1" works and Save is enabled. Every value comes from the row's own USDA data, so item 12's "one source-backed portion" rule still holds.
- **Risk:** medium. Changes quick-log "each" quantities too (§6.1). Re-run the meal suites. Localization: size words are frozen English matching inputs.
- **Type:** Structural (units). **Owner decision:** No: the owner asked for good-enough defaults for items like banana, and this uses only source data.

### F3. Narrow sweets carriers (after F2 and F6)

- **Measured variants for "chocolate chips"** (`$SP/verify-codetrace/f3.py`, `$SP/verify-completeness/f3_chips.py`, `$SP/verify-reproduce/f3sim.py`; all agree):

  | Words added to `carrierTokens` | Plain rows in the top 6 | #1 |
  |---|---|---|
  | cookie(s), waffle(s), dough, bar(s) | 3 of 6 | trail mix |
  | the same plus "ice" | 4 of 6 | trail mix |
  | the same plus "mix" | 5 of 6 | Breyers mint chocolate chip ice cream |
  | the same plus "mix" and "ice" | 6 of 6 | "Chocolate Chips, Chocolate" (64235, broken) |

  The singular "chocolate chip" stays at 0 of 6 in every variant.
- **Collateral (MEASURED):** "cookie(s)" sinks USDA's own "Cookies, graham crackers / vanilla wafers / shortbread / ladyfingers / chocolate wafers" rows below branded rows that carry the per-100 g bug (`$SP/verify-completeness/f3_regress.out`). "mix" moves "instant pudding", "hot cocoa", "cornbread" and "gelatin" to branded rows (`f3_mix.py`). Exempting a carrier that is the row's own first comma segment protects graham crackers but brings "Cookies, marshmallow…" back to #1 for chips (`$SP/revise/f3_headexempt.py`), because USDA names the chip cookies the same way. Corpus cost: 1 of 57 top-1s changes ("glass of milk", still wrong); 160-set: 2 to 3 improve, 0 worsen.
- **Blast radius:** every added word also becomes a dish head noun (`NutritionModels.swift:1529`), and `carrierTokens` drives the resolver's *unguarded* demotion (`demotingDishes(_:forQuery:)`, `:1591-1596`, called from `FoodCatalog.swift:341` and `FoodSelectionCandidateBuilder`), which sinks every matching row regardless of score. Meal resolution, AI candidate pools and the swap sheet change too.
- **Recommendation:** F7 is the precise chips fix; do F3 only for words with no USDA-head collision ("waffles", "dough"), and measure each word against the regression set above plus the meal suites. Negating "salad or cooking" (like "no bun", `NutritionModels.swift:1547-1551`) is worth doing on its own: a verifier's replica moved "Oil, olive, salad or cooking" from #60 to #5 (visible, not #1). Mayonnaise needs a separate "salad dressing" rule.
- **Risk:** medium. **Type:** Refinement. **Owner decision:** No.

### F9. Small UX fixes

- **Changes:**
  - Show "Create custom ingredient" next to non-empty results.
  - Keep a single trailing letter as a prefix term only when the result set is small.
  - Cancel the detached typeahead search when a newer keystroke supersedes it (`FoodView.swift:1910`), or check cancellation inside the scoring loop.
- **Impact:** gives the user an escape and trims wasted work on broad prefixes. It does not move cold rankings.
- **Risk:** low. **Type:** Refinement. **Owner decision:** No.

### F9b. Let a recipe pick teach search

- **Changes:** a pick in the recipe editor writes a correction alias (`FoodSearchCorrectionMemory`), so the second search works.
- **Risk:** low technically (the correction store already has a wipe row), but it changes what a "correction" means: today it is an explicit fix made by someone looking at a wrong answer (`FoodCatalog.swift:199-204`).
- **Type:** Refinement. **Owner decision:** Yes (light).

### F4b. Full portions design: Rungs A, C, D and E

- **Changes:** the full tolerant reader and density agreement; a per-food picker in `FoodView.swift` (`quantityUnitRow`, `:2157-2176`) that hides units which can't convert; the curated count and cup tables (about 60 entries, frozen English keys, USDA-cited, badged "estimate"); a local per-food "grams in one" memory.
- **Impact:** generic count coverage 5.0% to 36.5%, volume 20.6% to 35.3% (projection); thin Foundation rows covered by Rungs C and D.
- **Risk:** medium. Persisted formats (grams only), localization (frozen keys, `bundle: .module`, canary), wipe wall (the per-food memory needs a disposition row), Power-of-10 (bounded parser), and the meal path (§6.1).
- **Type:** Structural. **Owner decision:** Yes: decision 9's design, the picker UX and the "estimate" badge.

### F5. Ranking: an ingredient-identity key (a hypothesis to test, not yet a proof)

- **Idea:** compute once per index entry whether the row's head noun matches the query's head noun, plural-aware; sort identity first, then today's generic-first data type, then score; precompute the flag the way history weight is precomputed (`FoodItemSearch.swift:228-233`); re-apply the dish demotion after the sort, as the real pipeline does (`:239-241`).
- **Measured** (prototype over the replay's measured 60-row windows, so rows beyond position 60 are invisible; `$SP/synthesis/identity.py` and `$SP/verify-codetrace/identity_demote.py`):

  | Variant | Plain row at #1 | Visible in the 6 | Improved / worsened (rank) |
  |---|---|---|---|
  | Today | 97 | 132 | n/a |
  | Score-first, window re-sort, demotion re-applied | 112 | 131 | 36 / 20 |
  | Score-first, full candidate set (`sf_all.py`) | 109 | 127 | 36 / 31 (bucket) |
  | Identity, tier, score; demotion re-applied | **121** | **141** | **45 / 5** |
  | The same without the tuned head list | 119 | 141 | 43 / 7 |

  - The tuned head list skips the first comma segment when it is "spices", "nuts", "candies", "leavening agents" or "fish". It was fitted on the same 160 queries it is scored on; the untuned row is the honest one.
  - Without re-applying the demotion (the first draft's method), the figures were 117/141 and 44/8, "chocolate chips" landed at #3 behind two mis-typed biscuit rows, and "carrot" landed on "Carrots, raw, salad" (an FNDDS coleslaw), which the judge wrongly accepted. With the demotion re-applied, chips is #1 (on the broken row 64235, so F2 and F6 still matter) and carrot is "Carrots, raw".
  - It rescues 3 of the 20 FAILs to #1 (brown sugar, chocolate chips, brown rice) and 5 into view (plus vegetable oil and apple).
  - Remaining regressions show the weak spot, USDA hypernym heads: zucchini #1 to #6 (branded "Baby Green Zucchini" beats "Squash, zucchini, baby, raw", whose head is "squash"), parmesan #2 to #6 ("Cheese, parmesan"), cilantro #1 to #3 ("Coriander (cilantro) leaves"), feta #1 to #2, garlic clove #2 to #3. Untuned, "Ginger root, raw" (head "root") falls behind "Ginger In Syrup". "eggs", "ground beef" and "peanut butter" keep generic rows at #1 once the demotion is re-applied.
  - A previously reported "processing penalty" variant (120/143) had no script behind it and is withdrawn.
- **Risk:** medium to high. Moves pins in `FoodSearchCorpusTests` (`:309`) and `DishTemplateBindAuditTests`; makes `confidentBindScore` 368 stale (re-derivation already authorized); changes every surface that shares the comparator.
- **Type:** Structural (ranking). **Owner decision:** Yes. It replaces the authorized-but-unbuilt 1.7(b) with a different design. Before asking, build it behind a flag and measure over the full candidate set, not windows.

### F8. Ship the FNDDS generic layer (item 13 runtime projection)

- **Changes:** a catalog projection with FNDDS "as-consumed" generics.
- **Impact:** brings a real "Chocolate chips" row and "1 banana", "1 egg" and "1 clove" portions, which F4 can then read.
- **Risk:** under today's comparator more survey rows make the T cluster worse (a survey dish already beats srLegacy ingredients 12 times). Land F5 or equivalent first. Size budget.
- **Type:** Structural (data). **Owner decision:** Yes (ODR options doc, still open).

**Suggested order:** F10, then F2 and F1 (in parallel, different files), then F11 and F6, then F7
and F4a (together they fix the owner's two cases end to end), then F3's narrow words and F9. F9b, F4b,
F5 and F8 wait for owner calls.

---

## 9. Open questions for the owner

1. **Ranking.** Keep generic-first and rely on aliases, data hygiene and narrow carriers (F7, F6, F3), or also pursue the identity key (F5), which replaces the authorized-but-unbuilt score-first change (1.7b)? Measured, score-first alone is not the fix.
2. **Portions (decision 9).** May the picker list USDA's named portions ("medium banana · 118 g")? Saving them as grams plus display metadata is recommended for peer compatibility.
3. **Estimates.** Is a curated "USDA typical size, estimate" table acceptable next to item 12's fail-closed stance, as long as it is badged and editable? (F4a needs no curated values; only F4b does.)
4. **"Use manual nutrition."** Should it seed macros for the amount shown, or switch the line to 100 g with per-100 g numbers?
5. **Learning.** Should a pick in the recipe editor be remembered for the next search, the way meal corrections are (F9b)?
6. **Catalog path for FNDDS.** The ODR options for item 13's projection are still open (F8).
7. **Sources.** The round brief and the standing principle list CNF as approved, but `Docs/Food-Catalog-Remaining-Plan-2026-08-24.md:11` says "CNF is rejected." Which stands? This report used USDA only.

Answered since the first draft: the owner's phone runs the base catalog only (MEASURED from the
archives, §1), and a branded-basis rebuild is ruled out by the decision not to commit a regenerated
catalog binary, so F2 is a load-time shim.

---

## Appendix A. Methodology

### A.1 Instruments

| Sweep | Instrument | Validation |
|---|---|---|
| codemap | `$SP/codemap/replica.py`: a line-by-line Python port of the typeahead (FTS MATCH string, floors, score terms, comparator, 60-row demotion) run against the shipped DB through real FTS5 | Reproduces all 41 top-1 pins in `FoodSearchCorpusTests.swift:360-434`, name and score |
| replay | `Tests/FernletTests/IngredientSearchReplayProbeTests.swift` (commit `5b654c2d`, branch `claude/r0929-search-replay`, not pushed): the shipping Swift in the simulator | The visible 6 are the prefix of the top 10 in all 320 runs |
| units | `$SP/units/replica.py` and friends: the conversion code in Python over the whole catalog, plus the raw FDC JSON and CSV in the owner's Downloads | Branded rows checked against USDA label data |
| history | `$SP/history/typeahead_replay.py`, `portion_units.py` (pre and post item 12) | Reproduces 7 of 7 corpus pins |
| synthesis | `$SP/synthesis/sf.py` (score-first by visibility bucket) and `identity.py` (identity-key prototype), both over the replay's measured 60-row lists | `sf.py` prints 112 #1, 130 visible, 33 better / 19 worse by bucket. The 36 / 22 rank-based count comes from `$SP/verify-reproduce/sfcheck.py` |
| verification | `$SP/verify-reproduce/`, `$SP/verify-codetrace/`, `$SP/verify-completeness/`, `$SP/revise/` | Independent replicas; `verify-codetrace/mine.py` reproduces the chips top 6 and the #25 row; `sf_all.py` matches the Swift top 10 on 153 of 160 queries |

**Two metrics.** "Improved / worsened" is counted two ways in this report. *Rank-based* compares the
plain row's exact position. *Bucket-based* compares #1 / #2-3 / #4-6 / hidden. Every figure says which.

**Limits.**
- Window re-sorts see only the measured 60-row window. The full-candidate replica (`sf_all.py`) is the check on that.
- The judgement patterns are one reviewer's regexes (`$SP/replay/accept.py`), and they judge names only. §4.1a adds a nutrition check.
- Latency was measured on the simulator, not a device.
- No replica models the warm path (history, corrections, user items). §2.6 gives a device check.

### A.2 How to re-run the replay probe

```
cd "<a worktree at 5b654c2d or later>"
UDID=88BA566A-0384-47F5-9455-5A22CEF17D91
SP=<your scratch directory>/replay
xcodebuild build-for-testing -project App/Fernlet.xcodeproj -scheme Fernlet \
  -destination "id=$UDID" -derivedDataPath "$SP/dd" -jobs 4
TEST_RUNNER_FERNLET_REPLAY=1 TEST_RUNNER_FERNLET_REPLAY_OUT="$SP/out" \
TEST_RUNNER_FERNLET_REPLAY_BRANDED="$PWD/ODRAssets/FoodCatalogBranded.sqlite" \
xcodebuild test-without-building -project App/Fernlet.xcodeproj -scheme Fernlet \
  -destination "id=$UDID" -derivedDataPath "$SP/dd" \
  -only-testing:FernletTests/IngredientSearchReplayProbeTests -parallel-testing-enabled NO
python3 "$SP/analyze.py" "$SP/out"                          # re-classify
python3 "$SP/units.py" "$SP/classified-base.json"           # unit table
python3 "$SP/../synthesis/sf.py" "$SP/classified-base.json"                  # bucket-based
python3 "$SP/../verify-reproduce/sfcheck.py" "$SP" "$SP/out/replay-base.json" # rank-based
(cd "$SP/../synthesis" && python3 identity.py ../replay/out/replay-base.json "")
(cd "$SP/../synthesis" && python3 ../verify-codetrace/identity_demote.py x "")
python3 "$SP/../revise/plaus.py"                            # nutrition check (run from $SP/..)
```

Without `TEST_RUNNER_FERNLET_REPLAY`, the probe returns in 0.001 s, so CI is unaffected. A full run
takes 2 to 3 minutes. To measure a fix, cherry-pick the probe commit onto the fix branch, re-run, and
compare the tables in §4.

### A.3 Spot checks and disagreements resolved

What I re-checked myself (all reproduced):
- The comparator, constants and score terms: `FoodItemSearch.swift:150-176`, `:213-242`, `:296-308`, `:477-490`, `:553-618`, `:694-728`, `:815-850`.
- The demotion: `NutritionModels.swift:1506-1545`, `:1585-1648`.
- The unit model: `:1728-1739`, `:1789-1867`, `:1961-2035`, `:2539-2612`.
- The editor: `FoodView.swift:1683-1689`, `:1898-1917`, `:2112-2128`, `:2157-2200`, `:2223-2248`.
- Retrieval: `FoodCatalog.swift:208-238`, `:297-341`; `BundledFoodStore.swift:106-107`, `:275-303`.
- Totals, sharing, quick-log and import: `MealBuilder.swift:283-286`; `FernletExchange.swift:91-102`; `FernletStore.swift:5276-5298`; `FoundationFoodSelection.swift:240-330`; `RecipeWebImporter.swift:874-1000`.
- The catalog counts and every SQL block above; the archives' catalog hashes; the SR zero-macro drop.

Where the sweeps disagreed:

| Topic | Claims | Resolution |
|---|---|---|
| Rank of the first plain chips row | codemap 29; replay and history 25 | Both are right at different steps. 29 is before the dish demotion; 4 srLegacy "biscuit" and "sandwich" rows then sink, giving 25. The Swift-measured 25 is what the user sees. |
| Can widening the carriers fix chips alone? | history: no, only same-tier; codemap: yes, 6 of 6 | `demotingDishes` returns `kept + sunk` (`NutritionModels.swift:1629-1636`), which crosses tiers, so carriers can move chips. But 6 of 6 needs "mix" and "ice"; the conservative set gives 3 of 6, with collateral (F3). |
| Rows with an unreadable serving unit | units 14,843; replay 15,213; codemap about 14.8k | **14,843.** "MG" lowercases to "mg", which is `.milligram` (`NutritionModels.swift:1832-1833`), so replay's figure over-counts by the 420 MG rows. |
| Count coverage | history 536 to 64; units 440 (5.0%) | Different definitions. history counts a working "each"; units counts each, piece or slice. Both reproduce. |
| Branded macro bug size | codemap 33,338; units 58,281 and 26,042 | Different thresholds for one bug. 33,338 rows have macro grams above the serving weight. 26,042 gram-served rows exceed 900 kcal per 100 g. 58,281 is every affected-origin row with a serving other than 100; the pairing test (§6.5) supports the full scope. |
| Score-first effect | replay "fixes 36, breaks 22" | Rank-based on the windows (`sfcheck.py`); `sf.py` gives 33 / 19 by bucket; the full candidate set gives 36 / 31 by bucket. |
| CNF | brief: approved; plan: rejected | Raised as Q7. |

### A.4 Source write-ups

All in `$SP/research/`: `codemap.md`, `replay.md` (the full 160-row table), `units.md` (the full count
and density tables, localization detail), `history.md` (the commit timeline and status tables). The
pre-revision draft of this report is at `$SP/revise/report-before-revision.md`.

---

## Appendix B. Verification notes

Three verifiers re-ran this report's numbers. Every refuted, unsupported or imprecise item was checked
again for this revision. Outcome per item:

### B.1 Corrected

| Item | Was | Now | Evidence |
|---|---|---|---|
| Headline framing | "Two rule sets are the wrong shape; tuning constants will not fix the owner's cases" | Search needs refining; ranking has a structural weakness fixable step by step; units need a design; data has serious defects | F7 and F3 are refinements that move plural chips; only units need new logic |
| `sf.py` "reproduces 36 / 22 exactly" | stated in A.1 | `sf.py` prints 33 / 19 (bucket); 36 / 22 is rank-based from `sfcheck.py` | ran both |
| F5 "processing penalty" row, 120 / 143, "rescues 7 of 20 FAILs" | table row | withdrawn; no script exists (`grep -rl penalty` over `$SP` finds only `replay/why.py`, unrelated) | ran `identity.py` both ways |
| F5 method | re-sorted windows after the demotion, without re-applying it | re-applied: 121 / 141, 45 / 5 (tuned), 119 / 141, 43 / 7 (untuned); chips #1; carrot on "Carrots, raw" | `identity_demote.py` |
| F5 tuned head list | undisclosed | disclosed, with untuned numbers | `identity.py` with `""` gives 115 / 141, 42 / 11 |
| Carrot judge pattern | `^carrots?, (raw|baby, raw)` accepted "Carrots, raw, salad" (FNDDS, food_id 68272) | flagged; F10 tightens it | `sqlite3` |
| F3 "0 to 6 of 6" | with a 22-word set the report itself warned against | full table: 3 / 4 / 5 / 6 of 6, plus collateral and head-exemption result | three scripts agree; `f3_headexempt.py` |
| F3 olive oil and mayonnaise "recover" | stated | olive oil to #5 (verifier replica, not re-run here); mayonnaise needs a "salad dressing" rule | verifier |
| "60 of 63 trace to ranking; only 3 pure data gaps" | stated | 58 of 63 carry an observed ranking cause; 4 catalog gaps (salt and water's K tag is the branded run); 1 vocabulary. Lead with the 28 hidden queries | `verify-reproduce/clusters.py ../research/replay.md` |
| "27 explained by one cause: 19 and 8" | stated | 28 cause-1-only and 8 cause-2-only | same script |
| U5 "16,310 rows fail because default and converter disagree" | stated | 14,843 are U4; U5 plus the oil branch is 1,467 | `$SP/revise/tapbreak.py` |
| Rung 0a "unlocks 14,795 rows" | stated | 12,407 mass, 2,193 volume, 243 serving-only | `sqlite3` unit counts |
| 0c "174 'boiled' rows" | stated | 1,030 oil-branch failures: 879 real oils, 151 substring only; the invariant is the fix | `tapbreak.py` |
| §6.2 "Nothing was lost in the build" | stated | 32 SR foods dropped, exactly the all-zero-macro ones; this is cluster G's cause | `$SP/revise/srzero.py` |
| §2.6 workaround queries "work" | stated | two of three land on 6.7x to 7x broken rows | `sqlite3`; `plaus.py` |
| §2.2 "choc": no plain row; "chocolate c": "c" dropped | stated | semisweet at #28 for "choc"; "c" dropped from the gate but kept in the phrase bonus | replay JSON; `FoodItemSearch.swift:300-306` |
| "About 9,000 rows (replay milliseconds field)" | source | FTS match counts 9,208 and 8,980 | `sqlite3` |
| "131 of 1,231 displayed rows" | label | distinct top-10 rows, name+type+portions key | `units.py` |
| "0 of 121 (all 225 with exactly one convert)" | stated | all 258 with exactly one convert; 225 are gram-served | verifier port |
| Web import "large" maps to "each"; failing line voids the page | stated | the regex mangles "large", "grams" and g/l-initial foods (skipped, undercount); "medium", "small", "whole", "cloves" do map to "each" and can void the page | `$SP/revise/rx.swift` (NSRegularExpression), `sqlite3` FTS counts |
| Garlic "fails on tap" | about the #1 row | #1 is FDC 1104647 (RACC only, 100 g works); 169230 is #2 and fails on tap | replay JSON `top10` |
| F2 "corrects nutrition" | shim sets serving to 100 g | the label serving must be a count portion, or quick-log bare counts still over-count 3.6x | `FoundationFoodSelection.swift:251-272` |
| F1 and F4 risk | recipes only | meal logging and bind gates change too | `grep` of callers (§6.1) |
| F3 risk | typeahead only | the resolver's unguarded demotion changes too | `FoodCatalog.swift:341`, `NutritionModels.swift:1591-1596` |
| F7 "or index portion text in FTS" | offered | refuted: the name floor and scorer gate drop such rows; and `promotingCorrection` must not carry the aliases | `FoodItemSearch.swift:183-194`, `:523-530`; `FoodCatalog.swift:297-342` |
| D2 scope | 616 rows (7xxxxx) | 816 in 6xxxxx and 7xxxxx (747 carbs = 0); retype by category; plus Foundation typed srLegacy (0 `foundation` rows) | `sqlite3` |
| §3.5 "one failing ingredient zeros the recipe", "sharing drops it" | unscoped | scoped to recipes not built in the editor (`canSave`) | `FoodView.swift:1683-1689` |
| §2.6 custom ingredient "ranks first on every later search"; "a pick is never remembered" | stated | history outranks source; picks feed history after logging, but not correction memory | `FoodItemSearch.swift:482-485`; `FoodSearchHistory.swift:170-175` |
| §6.3 persistence "or as an existing token such as 2 each" | stated | grams only, unless today's reader already resolves the token for that row | `NutritionModels.swift:1961-1985` |
| "Neither owner case is a search regression" | unlabelled | INFERRED for chips; device state now MEASURED | `history.md:146`; archives |
| Q10 device catalog | INFERRED from a pbxproj grep (weak: the project uses synced folders) | MEASURED from four archives; `ODRAssets/` is gitignored (`.gitignore:11`) and under no synced root | `shasum` |
| Item-13 FNDDS chips row "would rank #1 (MEASURED)" | stated | row existence MEASURED; rank INFERRED; schema differs | artifact |
| 1.7(b) "no ledger row explains the reversal" | stated | ledger sequenced it after item 13; `ee3d3361`'s test comment points to a deliberate revert | ledger `:97-99`; `FoodCatalogTests.swift:224-226` |
| "6 rows shown" | no caveat | keyboard overlap unmeasured; caveat restored | `FoodView.swift:2115-2124` |

### B.2 Scripts added in this revision

All in `$SP/revise/`: `srzero.py` (SR zero-macro drop), `tapbreak.py` (fail-on-tap by mechanism; run
from `$SP/verify-codetrace`), `plaus.py` (nutrition check on the replay's branded answers; run from
`$SP`), `pair.py` (fdc-json vs GTIN basis), `rx.swift` (the importer regex in `NSRegularExpression`;
`swift rx.swift`), `id_demote_detail.py` and `id_top.py` (identity prototype with the demotion
re-applied; run from `$SP/synthesis`), `f3_headexempt.py` (carrier head exemption). The 28-hidden
breakdown was computed inline from `$SP/research/replay.md` tags with the same parser as
`$SP/verify-reproduce/clusters.py`.

### B.3 Kept as written

- The chips trace (§2.1, §2.3, §2.4): confirmed by all three verifiers, including the #25 row, the 869 vs 57-365 scores and the comparator lines.
- The rates table (§4.1) and the branded-run figures: confirmed by an independent counter.
- The banana mechanism, the 536 to 64 history, the coverage figures and the Rung C and D source rows: confirmed.
- The branded per-100 g bug (§6.5): confirmed and strengthened by the pairing test.

---

## Update 2026-09-30: what landed

The fixes that needed no owner decision (F10, F2, F1, F4a, F6, F7, F3 narrowed, F11, F9 items 1 and 3) landed
on `main` with this report. Measured on the base catalog with the replay probe, 160 queries, before and after:

| Measure | Before | After |
|---|---|---|
| Plain row at #1 | 97 | 113 |
| Plain row in the visible six | 132 | 145 |
| FAIL / GAP | 20 / 4 | 10 / 0 |
| Catalog rows whose tap default fails | 16,310 | 1 |
| Count nouns taking "1 each" | 1 of 26 | 18 of 26 |

- "chocolate c" through "chocolate chips" now put "Candies, semisweet chocolate" at #1 (it was #25 and never
  appeared). "1 cup" of it is 173 g.
- "1 banana" is 118 g ("Counted as 1 medium (118 g)"). Its cup still refuses, because USDA's sliced (150 g)
  and mashed (225 g) cups disagree.
- F3 shipped only the "salad or cooking" oil exemption; the sweets carrier words were measured and dropped.
- Still open, and waiting on the owner: F5 (identity ranking, which owns all 10 remaining FAILs), F4b (the full
  portion picker and typical-size table), F8 (the FNDDS layer), F9b (learning from recipe picks).

## Update 2026-09-30 (later): the owner-approved fixes landed

The owner approved F5 for the recipe surfaces ("for the recipe it's more important to rank the plain
ingredients first"), F4b and F9b. All three landed on `main` with their own adversarial reviews.

| Measure (replay probe, base catalog, 160 queries) | After the first landing | Now |
|---|---|---|
| Plain row at #1 | 113 | 140 |
| Plain row in the visible six | 145 | 152 |
| FAIL | 10 | 3 (flour, milk, potato) |
| Count nouns offering a count option | 18 of 26 | 29 of 29 (7 only through a typical size) |
| Volume queries offering cup/tbsp/tsp | 57 of 91 | 89 of 94 (26 only through a typical size) |

- F5 ranks by ingredient identity only on the recipe editor and the swap sheet. Quick-log, the meal
  composer and the resolver keep the old order, and `QuickLogSweepProbeTests` shows them unchanged. A food
  the person made, scanned or logged still leads.
- F4b's unit menu lists the row's named USDA portions with their grams. A curated typical-size table
  (76 entries, each cited to a USDA row, shown as "USDA typical size, estimate") answers only rows in
  listed catalog aisles, so sweets, sauces, snacks, canned goods and drinks get no estimate. "How many
  grams is one?" stores a per-food answer locally, with its wipe row.
- F9b: a pick from below the top of a recipe list, for words the person typed out, is remembered in the
  correction memory, with an origin token beside it. It answers only the recipe searches and never
  overwrites a correction.
- Still open: F8 (the FNDDS layer) and a branded-category gate for flavor-last names such as lemon and lime.
