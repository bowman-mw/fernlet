# Fernlet — Meal Estimation Overhaul (Restaurant & Composite Dishes)

**Date:** 2026-06-02
**Scope:** Replace the lexical, candidate-constrained quick-log matcher with **on-device AI dish decomposition** as the primary route (model determines primary ingredients + per-component grams from its own knowledge, catalog supplies macros). Back it with deterministic fallbacks (dish lexicon JSON + dish-aware portions + preparation-aware scoring). Fix the USDA portion data by reverting to the original FoodData Central format (per-100 g nutrients + rich `foodPortions`). Fold in the already-built web product importer and extend it to chain restaurants behind a privacy gate.
**Method:** Source audit of the current meal pipeline against the uploaded files. Findings cite `file:line`. This is a planning document — it specifies *what to build and in what order*; it does not change code.

> **How to use this doc.** §1 is the diagnosis (why restaurant/composite estimates fail today, and what the recent web-importer work does and doesn't cover). §2 is the target architecture and the routing decision. §3–§7 are the build phases (M1–M5) in dependency order — each is self-contained enough to hand to a coding assistant. §8 is open decisions with recommended defaults. §9 holds the JSON and `@Generable` schemas. Build order is **M1a → M1 → M2 → M3 → M4 → M5**; rationale in §2.4.

---

## 1. Diagnosis

### 1.1 The quick-log path has a structural ceiling

`FernletStore.addResolvedMeals` (`FernletStore.swift:373-414`) is the only path for free-text logging. It:

1. builds candidates by **lexical search of the description** (`:376` → `FoodSelectionCandidateBuilder.candidates`, `Models.swift:1017-1035`; phrase generation `:1037`),
2. asks the on-device model to choose **only from those candidates** (`FoundationFoodSelection.swift` instructions: *"food selections from the numbered candidate list only"*, ~`:32-38`),
3. falls to a deterministic plan (`:398`) and finally a keyword estimator (`:412`).

The consequences, using nigiri as the worked example:

- **Rice can never appear.** Candidates come from the words typed. "Nigiri" produces no `rice` token, so rice is never a candidate, and the model is forbidden from adding it. The model *knows* nigiri is vinegared rice + raw fish; the architecture prevents it from saying so. Generalizes to every composite/ethnic dish whose parts aren't named (poke, pho, curry-and-rice, shawarma, bibimbap…).
- **Canned fish wins.** The scorer (`FoodDataCatalog.swift:327-372`) ranks on token match, name length, source, and a `foundation > srLegacy > branded > restaurant` tier. Nothing encodes preparation, so "tuna, canned in water" and "tuna, fresh, raw" score nearly identically and the shorter/alphabetically-earlier name wins.
- **Macros run high.** Default quantity is the catalog serving — for gram foods that's the full `servingSize`, typically 100 g (`Models.swift:1298` `defaultRecipeQuantity`). One fish ingredient at 100 g overstates protein/fat while rice (carbs) is absent.
- **Composite cap.** "Nigiri" isn't in `CompositeFoodLexicon` (`FoodDataCatalog.swift:215-234`), so the deterministic fallback keeps a **single** ingredient (`FoundationFoodSelection.swift:75`, `candidateLimit = isComposite ? 3 : 1`).
- **Item-count guard rejects correct grouping.** `plan.items.count >= MealItemSplitter.items(...).count` (`FernletStore.swift:380`) treats naive comma/"and"/"with" splitting as the minimum granularity. "Salmon and tuna nigiri" splits into 2 naive items, so a model that correctly returns one "nigiri" dish with fish+rice fails the floor and is dropped.

### 1.2 What the recent web-importer work covers — and doesn't

`FoodProductWebImporter` / `FoodProductWebSearch` (new) is a solid, confirmation-based lookup: DuckDuckGo HTML search for `"<query> nutrition facts"` (`FoodProductWebImporter.swift:39-50`), preferred-host ranking (`:106-120`), fetch (`:321`), then JSON-LD → `<meta>` → visible-text → nutrition-label-image OCR → on-device `@Generable` extraction (`:546-571`) into `ImportedFoodProduct`. Saved as an `.aiResolved` / `.branded` FoodItem (`FernletStore.swift:821`) and logged via `logWebImportedFoodProduct` (`:466`).

Boundaries of the current implementation:

- **Manual, retail-scoped lane.** `shouldSearch` (`FoodProductWebImporter.swift:21-37`) fires only on grocery retailer terms (`costco`, `kirkland`, `trader joe`, `whole foods`, `aldi`, `walmart`, `target`, `starbucks`, `sandwich bros`) or the literal " from ", and pre-empts the quick-log into a review sheet (`FoodView.swift:1084-1087`). It does **not** touch `addResolvedMeals`, so §1.1 is unaffected for generic dishes.
- **No chain-restaurant coverage.** The `FoodBrandLexicon` chain list (`FoodDataCatalog.swift:192-213`) is not consulted by `shouldSearch`. "Chipotle chicken bowl" does not trigger the web lane today.
- **Privacy gap [Medium].** The search query carries the meal text to DuckDuckGo and the destination host. It fires **before** and **independent of** `settings.aiStatus` (the quick-log AI gate at `FernletStore.swift:377`) and has no network-consent flag. This is the only path where meal contents leave the device, and it is currently ungated — inconsistent with the on-device-only posture and the `AIDestination` boundary comment (`AIContextPayload.swift:7-9`).

### 1.3 Portion data is the recurring frustration

The runtime conversion math is **correct**: `RecipeIngredient.scale(using:)` (`Models.swift:1127-1133`) divides logged grams by the food's per-serving basis, and `FoodPortion.grams(for:)` handles household units. The problem is **data**: the combined catalog left `servingSize`/`servingUnit` inconsistent and `portions` sparse, so most items collapse to a 100 g gram basis with no household measures, and the only loggable unit is "100 g." The fix is to stop flattening at build time and carry the original FDC shape (per-100 g nutrients + full `foodPortions`) so the existing `scale()` can do conversions consistently (§3).

---

## 2. Target architecture

### 2.1 The routing decision

Free-text Save resolves through three lanes, chosen by the description, not stacked blindly:

```
Save tapped
 ├─ Branded/retail product OR chain restaurant?  (shouldSearch, extended §6)
 │     └─ WEB LANE (opt-in): search → fetch → on-device extract → review → log
 ├─ Otherwise → QUICK-LOG (primary, §4):
 │     on-device AI DECOMPOSITION → resolve components to catalog → scale by grams
 │     ├─ model off / unavailable → DETERMINISTIC fallback (§5):
 │     │      dish lexicon JSON → dish-aware portions → keyword estimator
 │     └─ (single-entry dish match from FNDDS, if present, short-circuits — §3.4)
```

### 2.2 Primary route: on-device AI dish decomposition (route #5)

Invert the model contract. Instead of "pick from this lexical candidate list," the model **decomposes the dish using its own world knowledge** into primary components with estimated edible grams; the catalog then supplies the macros.

1. **Decompose.** Model returns `DecomposedDish { name, mealType, components: [{ ingredient, preparation, grams }] }` (schema §9.1). For "6 pieces salmon nigiri" → `[{salmon, raw, ~102}, {sushi rice, steamed, ~108}]`. No candidate list is sent; the model is free.
2. **Resolve each component to the catalog.** `FoodItemSearch.results(for: "\(preparation) \(ingredient)")` with the **preparation bias** from §5.1, take the top match, and scale its macros/micros by `grams` over the per-100 g basis (reuse `scale()` with a gram `RecipeIngredient`). This is where canned-vs-raw is finally disambiguated.
3. **Fallback per component.** No catalog hit → consult the dish lexicon (§5.2) for a typical component food; still nothing → synthesize a **bounded** `.aiResolved` FoodItem from a model macro estimate, flagged low-confidence (§8-D).
4. **Bound and sanity-check.** Clamp per-component grams (e.g. 1–1500 g) and total dish grams; reject implausible post-resolution macro density. Never trust raw model macros over a catalog match.

This removes every limb of §1.1: rice appears (model knowledge, not lexical presence), preparation is correct (bias at resolution), portions are realistic (model grams, not 100 g defaults), and there is no composite cap.

### 2.3 Privacy framing

Decomposition is on-device Foundation Models, so it stays within the existing posture. Add a typed `MealDecompositionPayload: AIContextPayload` whose `includedFieldNames` are `["mealDescription", "fallbackMealType"]` — strictly **less** than the current `FoodSelectionPayload` (no candidate list needed). Record it through `AIAuditLog` like the other on-device calls. The **web lane** is the only off-device path and gets its own opt-in destination (§6.2).

### 2.4 Build order and why

- **M1a (preparation bias)** first — tiny, removes the most jarring symptom (canned fish) on its own, and M1's resolution step depends on it.
- **M1 (AI decomposition)** — the headline lever; everything in §2.2.
- **M2 (lexicon + dish-aware portions)** — deterministic fallback for AI-off/old devices, and a source of typical portions to seed/bound M1.
- **M3 (per-100 g catalog data)** — makes the gram-based scaling in M1/M2 accurate and unlocks household units; larger data lift, sequence with the catalog-extraction refactor already on the roadmap.
- **M4 (web lane: chains + privacy gate)** — extends the built importer and closes the egress gap.
- **M5 (low-friction correction)** — optional inline edit; keeps quick-log one-tap.

---

## 3. Phase M3 — Per-100 g canonical catalog + original-format ingestion

> Listed here as the data foundation; build per §2.4 ordering. Owner-sequenced with the read-only-catalog extraction work.

### 3.1 Canonical stored form
Define the canonical FoodItem basis as **per-100 g** for foundation/SR/survey foods: `servingSize = 100`, `servingUnit = "g"`, macros/micros expressed per 100 g, and `portions` populated with every household measure FDC provides. Branded label foods stay per-labeled-serving (their numbers are per serving) but gain a `portions` entry for the label serving and a derived per-100 g portion where grams are known.

### 3.2 Ingest from the original FDC format
Stop flattening at combine time. Map directly from the FoodData Central download:
- `foodNutrients[]` → per-100 g macro/micro fields (by nutrient id),
- `foodPortions[]` → `FoodPortion { amount, unit (from `measureUnit.name`), gramWeight, description (`modifier`/`portionDescription`) }` (`Models.swift:958`).

The runtime `scale()` (`Models.swift:1127`) and `gramsEquivalent` (`:1309`) already consume this shape; no math change. Keep `USDAFoodItemRecord` (`FoodDataCatalog.swift:3-107`) as the wire type but stop deriving a single per-serving macro at build time.

### 3.3 Migration
Bump the binary-plist cache key (`food_catalog_v1` → `v2`, `FoodDataCatalog.swift:156-189`) so the reshaped catalog reseeds. Re-validate `preferredRecipeUnit` (`Models.swift:1275`): with a 100 g basis it should prefer a `.cup`/`.each` portion when present, else grams.

### 3.4 (Optional, sets up single-entry dish matches) FNDDS survey foods
Add `FoodDataType.survey` (alongside `foundation/srLegacy/branded/restaurant`, `Models.swift` enum). FNDDS contains composite/prepared dishes ("Nigiri, salmon"; "Sushi, …"). With a curated survey set seeded, the quick-log can short-circuit to a single accurate entry when the whole-dish name matches, before decomposition. Give `.survey` a sensible slot in `dataTypePriority` (below `foundation`, above `branded` for non-brand queries).

### 3.5 Acceptance
- A salmon/tuna/rice/avocado food each exposes ≥1 non-gram `FoodPortion` after reseed.
- Logging "100 g cooked white rice" and "1 cup cooked white rice" produce consistent, correct macros.
- Cache reseeds exactly once on version bump.

---

## 4. Phase M1 — On-device AI dish decomposition (primary)

### 4.1 New model contract
Add `FoundationDishDecomposition` (`@Generable`, schema §9.1) and a `MealDecompositionModel.decompose(_:) async throws -> DecomposedDish?` in `FoundationFoodSelection.swift` (or a sibling file). Instructions emphasize: split into **primary edible components**, include staples the dish implies (rice, oil, sauce, dressing, tortilla), give a **preparation** word, estimate **edible grams per component for the whole dish as described**, honor explicit counts ("6 pieces", "2 tacos"). No candidate list in the prompt.

### 4.2 Resolution + scaling
`MealDecompositionResolver` (new): for each `DishComponent`, query `FoodItemSearch.results(for: "\(preparation) \(ingredient)", in: index)` with the M1a bias, take the top, build a gram `RecipeIngredient(quantity: grams, unit: "g")`, and use `scaledMacros`/`scaledMicronutrients` (`Models.swift`). Assemble into a `Meal` (reuse `MealBuilder.mealFromIngredients`-style assembly; create a `RecipeDefinition` when >1 component, mirroring `MealBuilder.swift:40-48`). Per-component fallbacks per §2.2-3 and bounds per §2.2-4.

### 4.3 Wire into the store
In `addResolvedMeals` (`FernletStore.swift:373`), when `settings.aiStatus != .off`, call decomposition **first**. **Replace the item-count guard** (`:380`): gate on *"every component resolved or bounded-estimated"* and *"total macro density plausible"* rather than item count. Keep the deterministic plan (§5) and keyword estimator as the lower tiers.

### 4.4 Privacy/audit
Add `MealDecompositionPayload` (§2.3) and an `AIAuditLog.shared.record(payloadKind: "meal-decomposition", destination: .onDeviceFoundationModels, includedFields:)` call, matching `FoundationFoodSelection.swift:30-31`.

### 4.5 Acceptance (sushi is the canonical test)
- "6 pieces salmon nigiri" → two components (raw salmon ≈ 90–110 g, sushi/white rice ≈ 90–120 g); **rice present**; fish match is **not** canned; protein/fat within a sane band; carbs non-zero.
- "chicken burrito bowl" → rice + beans + chicken + (cheese/salsa); no single-ingredient collapse.
- "grilled cheese and tomato soup" → still two items, unchanged or better.
- AI off → falls cleanly to §5.

---

## 5. Phase M2 — Deterministic fallbacks (lexicon JSON + portions + prep scoring)

### 5.1 (M1a) Preparation-aware scoring — build first
Add a `preparationBias(queryTokens:candidate:)` modifier inside `FoodItemSearch.score` (`FoodDataCatalog.swift:327-346`). Maintain a small preparation token set (`raw`, `grilled`, `baked`, `fried`, `breaded`, `canned`, `in oil`, `in water`, `smoked`, `dried`). When the query implies a preparation (explicit word, or dish context e.g. sushi/sashimi/poke ⇒ raw), **reward** matching candidate tokens and **penalize** mismatched ones. Additive modifier, **not** a hard filter (a missing fresh entry should degrade to *something*).

### 5.2 Dish lexicon as JSON
Add `DishTemplates.json` (bundled, loaded like the food catalog) + `DishTemplateLexicon` (schema §9.2). Each entry: dish name/aliases, `isComposite`, component search terms, per-unit typical grams, and default unit/count. Two uses:
- **Fallback decomposition** when the model is unavailable: expand a known dish into component search terms (so rice becomes eligible) and apply typical portions.
- **Seed/bound M1**: pass typical portions for recognized dishes to clamp implausible model grams.
Mark these dishes composite (supersedes the hardcoded `CompositeFoodLexicon`, `FoodDataCatalog.swift:215-234`).

### 5.3 Dish-aware portions + count parsing
Replace the hardcoded sandwich branches in `FoundationFoodSelection.defaultUnit`/`defaultQuantity` (~`:89-109`) with a lookup against the lexicon. Add leading-count parsing ("6 pieces", "2 tacos") feeding per-unit grams. Defer fractional/range parsing.

### 5.4 Acceptance
- With AI off, "salmon nigiri" via the lexicon yields fish + rice with per-piece portions.
- "tuna sandwich" no longer returns canned-in-oil as the only ingredient at 100 g.
- Lexicon edits require no rebuild (JSON-driven), and a missing dish degrades gracefully to the keyword estimator.

---

## 6. Phase M4 — Web nutrition lane: chains + privacy gate

### 6.1 Extend the trigger to chain restaurants
In `FoodProductWebSearch.shouldSearch` (`FoodProductWebImporter.swift:21-37`), also fire when `FoodBrandLexicon.queryContainsBrandToken(description)` is true (`FoodDataCatalog.swift:209-212`). Add common chain official hosts to `sourcePriority` preferred hosts (`:106-120`). The existing `"<query> nutrition facts"` search and extraction pipeline already handle chain item pages.

### 6.2 Privacy opt-in (closes §1.2 gap) [Medium]
- Add a settings flag (e.g. `webNutritionLookupEnabled`, **default off**) and a new `AIDestination.webNutritionLookup` (`AIContextPayload.swift:7`). Gate `shouldSearch`/the product-search route on it (`FoodView.swift:1084`).
- Respect the AI master switch: do not run the web lane when `settings.aiStatus == .off`.
- Route through `AIAuditLog` with a `web-nutrition` payload kind, recording that the **meal description leaves the device**. Surface clear copy on first use ("Fernlet will search the web for this item; your description is sent to a search provider").
- Cache resolved products by normalized query (already partly implicit via the `.aiResolved` reuse in `saveWebImportedFoodProduct`, `FernletStore.swift:821-845`) to minimize repeat egress.

### 6.3 Acceptance
- With the flag off, no network request is made for any meal log; chains and retail both fall to the on-device lanes.
- With the flag on, "Chipotle chicken bowl" resolves via the web lane and logs with `MealLogSource.webImport`.

---

## 7. Phase M5 — Low-friction correction (optional, non-blocking)

Keep quick-log one-tap. **Do not** add a blocking confirm sheet to `addResolvedMeals` (the existing immediate-save + dismiss at `FoodView.swift:1088-1097` stays). Instead:
- Show the resolved component breakdown inline on the logged `MealRow` with a tap-to-edit affordance (swap a match, adjust grams/piece count).
- A subtle "looks off?" control opens the edit; correction is opt-in.
- The web lane already has an appropriate preview/review (`FoodView.swift:1112+`) because it's a heavier, rarer action — leave it.

Acceptance: logging stays a single tap; a wrong match is correctable in ≤2 taps without re-entering the description.

---

## 8. Open decisions (recommended defaults)

- **A — Model macros vs catalog-only when no match.** *Default:* resolve to catalog first; only when no catalog/lexicon match exists, accept a **bounded** model macro estimate, flagged low-confidence and surfaced for M5 correction. Rationale: catalog data carries micronutrients and is consistent; small on-device models drift on absolute macros.
- **B — FNDDS/survey now or later.** *Default:* add the `.survey` type and seed a **curated** dish set in M3; full FNDDS ingestion later with the catalog-extraction refactor. Rationale: a handful of survey dishes gives high-value single-entry matches without bloating the snapshot.
- **C — Decomposition payload type.** *Default:* a dedicated `MealDecompositionPayload` (fields: `mealDescription`, `fallbackMealType`) rather than reusing `FoodSelectionPayload`. Rationale: it sends strictly less; keeps the allowlist honest.
- **D — Web lane gating.** *Default:* opt-in, **default off**, gated additionally by `aiStatus`, audited, with explicit first-use copy. Rationale: it is the only off-device path for meal contents; make the egress a deliberate user choice.
- **E — Catalog reshape sequencing.** *Default:* land M3 with or just after the read-only-catalog store so the per-100 g reshape and the snapshot-extraction work share one migration.
- **F — Item-count guard.** *Default:* remove the `plan.items.count >= …` floor (`FernletStore.swift:380`) and gate on resolution completeness + plausibility instead.

---

## 9. Schemas

### 9.1 `@Generable` decomposition (M1)
```swift
@available(iOS 26.0, *)
@Generable
struct FoundationDishDecomposition {
    @Guide(description: "Short dish name, e.g. 'Salmon nigiri'")
    var name: String
    @Guide(description: "Meal type if clear, else 'Auto'")
    var mealType: String
    var components: [FoundationDishComponent]
}

@available(iOS 26.0, *)
@Generable
struct FoundationDishComponent {
    @Guide(description: "One primary edible ingredient, e.g. 'salmon', 'sushi rice', 'avocado'")
    var ingredient: String
    @Guide(description: "Preparation/state if relevant: raw, grilled, baked, fried, steamed, canned, none")
    var preparation: String
    @Guide(description: "Best estimate of edible grams of THIS component across the whole dish as described")
    var grams: Double
}
```
Resolution maps each component to a catalog `FoodItem` via `FoodItemSearch` (+ §5.1 bias), scales by `grams` over the per-100 g basis, applies §2.2 fallback/bounds.

### 9.2 `DishTemplates.json` (M2)
```json
{
  "version": 1,
  "dishes": [
    {
      "name": "nigiri",
      "aliases": ["sushi nigiri", "nigiri sushi"],
      "isComposite": true,
      "unit": "piece",
      "components": [
        { "search": "fish raw",   "gramsPerUnit": 17, "preparation": "raw" },
        { "search": "sushi rice", "gramsPerUnit": 18, "preparation": "steamed" }
      ]
    },
    {
      "name": "burrito bowl",
      "aliases": ["chipotle bowl"],
      "isComposite": true,
      "unit": "serving",
      "components": [
        { "search": "white rice cooked", "gramsPerUnit": 120 },
        { "search": "black beans cooked", "gramsPerUnit": 90 },
        { "search": "chicken grilled",    "gramsPerUnit": 110, "preparation": "grilled" },
        { "search": "cheese shredded",    "gramsPerUnit": 28 }
      ]
    }
  ]
}
```

### 9.3 `MealDecompositionPayload` (M1)
```swift
struct MealDecompositionPayload: AIContextPayload {
    let payloadKind = "meal-decomposition"
    let mealDescription: String
    let fallbackMealType: MealType?
    var includedFieldNames: [String] { ["mealDescription", "fallbackMealType"] }
}
```

---

## Appendix — Evidence index
- Quick-log path & ceiling: `FernletStore.swift:373-414` (`:376` candidates, `:377` aiStatus gate, `:380` item-count guard, `:398` deterministic, `:412` keyword).
- Candidate build / splitter / phrases: `Models.swift:1017-1035`, `:999-1015`, `:1037`.
- Model "candidates only" contract / composite cap: `FoundationFoodSelection.swift:~32-38`, `:75` (unchanged this pass).
- Scorer & data-type priority: `FoodDataCatalog.swift:327-372`; composite lexicon `:215-234`; brand lexicon `:192-213`.
- Portion model & scaling: `Models.swift:958` (`FoodPortion`), `:1127-1133` (`scale`), `:1298` (`defaultRecipeQuantity`), `:1309` (`gramsEquivalent`); cache `FoodDataCatalog.swift:156-189`.
- Web importer: `FoodProductWebImporter.swift` (`:21-37` shouldSearch, `:39-50` search, `:106-120` host priority, `:321` fetch, `:546-571` model extraction); wiring `FoodView.swift:1084-1087`, `:1112+`; store `FernletStore.swift:466` (log), `:821-845` (save).
- AI boundary: `AIContextPayload.swift:7-9`, `:25-32`; audit `FoundationFoodSelection.swift:30-31`.
