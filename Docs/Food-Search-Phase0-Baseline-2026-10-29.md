# Food search Phase 0 baseline — brand and product search

Date: 2026-10-29. Branch `claude/food-search-phase0`, measured on `ad3e7701`. No shipping code changed.

This is the measured baseline that the targeted brand-search fixes are judged against. On 2026-10-29 the owner cut the
coordinated food/exercise plan's search track down to those fixes:

- search the brand field;
- rank typed-brand agreement first;
- stop history overriding a typed brand;
- offer a labelled typo suggestion.

The plan's full program (brand dictionary, multi-route retrieval, schema versioning) is not being built. Earlier
research documents describe history; only the numbers here are current.

## What was built

| Piece | What it does |
| --- | --- |
| `Tests/FoodSearchBaseline/brand-panel.json` | 64 labelled queries in 2 splits: 37 tuning, 27 held out. Covers brand + product, word order, prefixes, brand-only, punctuation and possessives, consumer brand vs owner, ambiguity, generic controls, qualifiers, typos, unknown/numeric/short brands, accents, Spanish, and cross-brand names. Labels are **equivalence groups** (predicates over brand, name and data type), not one row id. **Status: draft, owner review pending.** |
| `Tests/FernletTests/FoodSearchBrandBaselineProbeTests.swift` | **Opt-in** probe (`FERNLET_BRAND_BASELINE`). Replays the panel through quick-log's real call, `catalog.results(for:context: .userTyped)`. Runs on base and base + branded (the loader's production configuration: cap 600, no priority sort), each cold and warm. Records per-route pool size and truncation, the gate at a 50,000-row cap, stage timings, the six shown rows with match evidence, first acceptable rank, and the panel metrics. `FoodSearchBrandPanelTests` (always on) checks only the panel's shape and the shared text canonicalisation. |
| `Scripts/food-search-baseline/audit.py` | Read-only SQLite **oracle** (are acceptable rows in the data at all?) plus the nutrition/identity **audit**. It applies `BundledRowCorrection`'s load-time rebasing and unit aliasing, so it measures what the app sees, not raw rows. |
| `Tests/FoodSearchBaseline/baseline-2026-10-29.json` | The committed per-query outcome of this run, for every later fix to diff against. |

Run them:

```
python3 -I Scripts/food-search-baseline/audit.py --base FernletKit/Sources/FoodCatalog/Resources/FoodCatalog.sqlite \
  --branded ODRAssets/FoodCatalogBranded.sqlite --panel Tests/FoodSearchBaseline/brand-panel.json --out <dir>
TEST_RUNNER_FERNLET_BRAND_BASELINE=1 TEST_RUNNER_FERNLET_REPLAY_OUT=<dir> TEST_RUNNER_FERNLET_REPLAY_BRANDED=<abs ODR path> \
  xcodebuild test-without-building … -only-testing:FernletTests/FoodSearchBrandBaselineProbeTests
```

A missing branded file is reported (`brandedAvailable: false`), never counted as branded coverage.

## Environment

- iOS 26.5 Simulator (iPhone 17, a private device), Debug build.
- Apple-silicon Mac shared with several concurrent builds.
- **Quality numbers are deterministic. Timing numbers are not device numbers**, and they moved between runs: the
  generic p95 was ~850–980 ms on one run and ~230–250 ms on the next. Device timing in Release is still owed before
  any latency budget is set.

## Results

"Labelled" excludes the two queries whose honest answer is "no such product". Top-1 and top-6 are over labelled
queries. "Mismatch" is the share of the six shown rows that disagree with the requested brand (brand intents only).

| Configuration | Profile | Split | Queries | Top-1 | Top-6 | Zero results | Brand mismatch |
| --- | --- | --- | --- | --- | --- | --- | --- |
| base | cold | tuning | 37 | 0.750 | 0.917 | 0.108 | 0.093 |
| base | cold | held-out | 27 | 0.654 | 0.692 | 0.259 | 0.045 |
| base + branded | cold | tuning | 37 | 0.750 | 0.944 | 0.081 | 0.078 |
| base + branded | cold | held-out | 27 | 0.654 | 0.769 | 0.148 | 0.057 |
| base + branded | warm | all | 64 | 0.758 | 0.871 | 0.109 | 0.074 |
| base + branded | cold | brand intents | 40 | 0.718 | 0.872 | 0.100 | 0.118 |
| base + branded | cold | generic | 24 | 0.696 | 0.870 | 0.125 | 0 |

Truncation never dropped an acceptable row on this panel. The 600-row branded cap was hit only by six broad generic
queries, whose acceptable rows come from the base catalog. It **will** start to matter once the brand field becomes
searchable, because thousands more branded rows then pass the gate (the `SQLiteBundledFoodSource.candidates` doc
already says so). The fix must keep the cap in mind.

## Why the misses happen (base + branded, cold)

The oracle separates three causes: the product is not in the data, the gate never retrieves it, or ranking buries it.

| Cause | Queries | What the person sees | Fix it maps to |
| --- | --- | --- | --- |
| **Brand only in the brand field.** The gate and scorer read name, category and tags, never `brand_source`. 285 of 288 Quest rows and 362 of 366 Chobani rows in the branded file lack the brand in the name. | quest protein bar (129 Quest bars in the data, gate retrieves 0); protein bar quest | The leave-one-out fallback answers "protein bar"; a South Beach bar is #1 and a Quest bar only #5 by luck | Search the brand field |
| **A wrong brand ranks first.** Brand agreement is not a ranking signal. | chick-fil-a sandwich (Walmart's "…Chick'n" sandwich #1, Chick-fil-A #3); heinz ketchup (Herr's "Potato Chips, Heinz Ketchup" #1); doritos nacho cheese (Smartfood popcorn #1) | A different brand's product above the one typed | Rank typed-brand agreement first |
| **History overrides a typed brand.** | kind bar: correct cold, but warm (a conflicting bar logged three days earlier) puts the other bar #1 | The person's own history buries the brand they asked for | History must not override a typed brand |
| **Typos give nothing.** | chobanni yogurt, heinz ketchip (zero results); quest protien bar (a misspelt product happens to match) | Empty list, no suggestion | Labelled typo suggestion |
| **Run-together brand.** | chickfila nuggets (zero results) | Empty list | Typo / alias suggestion |
| **Spanish.** | yogur griego, leche descremada, pechuga de pollo: thousands of English matches in the data, gate 0 | Empty list | Out of the owner's scope; recorded |
| **Generic head-noun ranking** (not brand). | olive oil (mayonnaise with olive oil #1); milk ("Milk and cereal bar" #1); nonfat milk (chocolate nonfat yogurt #1); sugar free syrup (caramel popcorn #1) | A food that *contains* the word outranks the food itself | Out of scope; once the person has logged the right row, history puts it first (all four pass warm), so it mainly hurts a new user |
| **Not in the data.** | 5 hour energy (0 rows) | A generic energy drink via the fallback | None; a data gap |

Things that already work:
- Brand words that appear in names: Larabar, Oikos, Tillamook, 7UP, Starbucks.
- Possessive punctuation: "mcdonald's" and "mcdonalds", "wendy’s" and "wendys" all find the row.
- Word order: "yogurt chobani".
- Accents: "häagen-dazs" (with the branded file attached).

## Audit findings (after the app's load-time corrections)

| Finding | Base (118,317 rows) | Branded ODR (364,457 rows) | Note |
| --- | --- | --- | --- |
| Macro grams exceed the serving's grams | 437 | 1,295 | Raw SQL says 33,082 in base. `BundledRowCorrection` F2 rebases the compact branded set to per-100 g at load, and 437 remain. The rest are real source defects ("Canola Oil Cooking Spray" F3200 per 100 g). |
| All-zero macros | 894 | 18,202 | Many are water, diet soda or spices; not triaged. |
| Sugar > carbs / fiber > carbs / saturated > fat | 1,441 / 1,050 / 150 | 2,263 / 1,279 / 548 | Ratios, so unaffected by the rebase. |
| GTIN bad check digit | 206 of 50,000 | 1,823 of 364,457 | Every code is 14 digits. No duplicates; base and branded share no code, so they are disjoint as designed. |
| Collapse key `(data type, normalized name)` spanning several brands | 4,497 keys / 19,119 rows | 19,434 keys / 105,640 rows | What `TypeaheadDuplicateCollapse` can merge across brands. Widest: "extra virgin olive oil", 186 brands. |
| Same brand, same name, different nutrition | 9,268 | 13,981 | Real variants or package sizes; not resolved here. |
| Brand value carries a corporate suffix (owner, not consumer brand) | 86,768 of 109,163 branded | 307,585 of 364,457 | e.g. "Kraft Heinz Foods Company" also owns the Kraft products, so "heinz" in the brand field is an owner-level match. |
| `restaurant` data type | 64 rows | 0 | None is a restaurant meal: Starbucks grocery products, Panera/IHOP "at home", and "Outback Pets" chocolate bars. Real restaurant meals (Big Mac, Frosty, Chick-fil-A) are `srLegacy` rows named "BRAND, item". |

These are predicate and substring counts, not verified distinct products. None of them blocks the targeted fixes. The
two that matter to them:
- the corporate-suffix shape, which makes brand matching an owner-level match;
- the cross-brand collapse key, which can hide a second brand's same-named product in the six.

## Labels to review

The labels are drafts. Points the owner may want to change:

- **sonic** is labelled "no acceptable product", but the six include a "Sonic Chili Cheese Coney" row, so a Sonic
  restaurant item may exist.
- **chocolate** accepts "Chocolate-flavored hazelnut spread" as #1.
- **chipotle burrito** accepts any burrito.
- **doritos** excludes Smartfood's Doritos-flavoured popcorn.
- **Quest** and **Heinz** aliases also match unrelated owners ("Support Quest, Inc.") and the Kraft Heinz owner.
  These are noted in the panel.

## What the targeted fixes should move

Judged against `baseline-2026-10-29.json`:

- Quest protein bar and protein bar quest reach top-1.
- Chick-fil-A, Heinz ketchup and Doritos have a brand-agreeing #1.
- kind bar stays #1 warm.
- The typo queries offer a labelled suggestion and never a silent rewrite.
- Brand-intent mismatch falls.
- Every query that passes today still passes, especially the generic controls.

Retrieval must stay bounded under the 600-row cap once the brand field is searchable. Check this with the probe's
`brandedTruncated` and `acceptableInGate` against `acceptableInPool`.

## After the targeted fixes (2026-10-30, branch `claude/food-brand-fixes`)

All three fixes are typed-surface only. `scoredResults`, the resolver's `candidates`, and every confidence gate rank
exactly as before.

1. **Brand-field route.** A typed query with no presented rows reads itself as brand + product and fetches rows
   whose `brand_source` has a word starting with the brand word. The fetch is a `LIKE` over the product words' FTS
   gate, never a table scan, and is capped at 400 rows per source and reading. The scorer then checks the whole
   brand run against the brand field and the product words against the NAME. The leave-one-out fallback runs only
   after this route finds nothing. Because the route only fires on zero results, the 600-row cap question above
   never arises.
2. **Typed brand first, above history** (`FoodBrandAgreement`). A brand counts in two cases:
   - a lexicon chain named in the row's name or brand field;
   - a LEADING run of the query's words that at least two matched rows, and a fifth of them, state in their brand
     field.

   A USDA reference row ("USDA FDC …" in the brand field) agrees through its name. A row naming another brand in
   its brand field never does.
3. **Spelling suggestion** (`FoodCatalog.spellingSuggestion(for:)`). It reads the index's own word list through
   `fts5vocab` and returns, for example, "chobanni yogurt" → "chobani yogurt" and "chickfila" → "chick fil a". It
   is never applied by the catalog. **The visible "Did you mean" line is not built yet.** It needs `FoodView` and
   new strings, which the round 7 bodybuilding lane is changing, so it follows that lane's merge.

| Configuration | Profile | Split | Top-1 | Top-6 | Zero results | Brand mismatch |
| --- | --- | --- | --- | --- | --- | --- |
| base + branded | cold | tuning, brand intents | 0.762 → **0.952** | 0.952 → 0.952 | 0.091 → 0.091 | 0.143 → **0.051** |
| base + branded | warm | tuning, brand intents | 0.714 → **0.952** | 0.952 → 0.952 | 0.091 → 0.091 | 0.153 → **0.051** |
| base + branded | cold | all 64 | 0.710 → **0.790** | 0.871 → 0.871 | 0.109 → 0.109 | 0.070 → **0.039** |
| base (no branded file) | cold | all 64 | 0.710 → **0.790** | 0.823 → **0.855** | 0.172 → **0.141** | 0.075 → **0.037** |
| any | any | generic intents | unchanged | unchanged | unchanged | 0 |

What changed, by query:
- **Now right:** quest protein bar, protein bar quest, chick-fil-a sandwich (both spellings), heinz ketchup,
  kind bar (warm), and häagen-dazs on the base catalog.
- **Regressions:** none, in any configuration or profile.
- **Still wrong:**
  - doritos nacho cheese: an owner-only brand, the documented limit.
  - The typo queries: waiting on the suggestion UI.
  - Spanish, generic head-noun ranking, and 5 hour energy (not in the data): out of scope.

Existing corpus pins all hold, with one deliberate change. `FoodSearchCorpusTests`'s live typed-vs-resolver
divergence count went from 15 to 16, because typed "quest protein bar" now answers with Quest's own bars.

Timing: on the branded pass, per-query times stayed near baseline. The base pass ran at load average 20–28, where
even the untouched SQLite retrieval slowed by the same factor. Device timing is still owed.
