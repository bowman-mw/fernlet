# AI Feature Expansion — 2026-07-23

Scoping for seven features that ride on the provider ladder in
[AI-Provider-Ladder-2026-07-23.md](AI-Provider-Ladder-2026-07-23.md).

**Status (2026-08-09):** **partially shipped** — see the SHIPPED STATUS block in §1 for the
authoritative per-step state. Landed: STEP 0b/0c/0, F1(a), F2, the provider-seam refactor, and
features F4 (scaling + substitution), F3 (grocery share-text + weekly planner), F5 (cooking mode +
Live Activity + Siri intents). Not landed: the cloud/BYOK/iOS-27 tracks (gated), and F6/F7
(deferred by decision D-C). Every file:line below was read and adversarially re-verified against
`main` @ `4916cd0` at authoring time. Where a survey claim was refuted, the corrected fact is what
appears here.

**Revised 2026-07-24** — post-audit revision (99-agent verification pass) plus owner decisions D-A
(recipe store), D-B (PCC consent), D-C (F6/F7 deferred), D-D (two-adapter BYOK). §1 below is now the
**single canonical build order** for both this doc and the ladder doc. Superseded claims are struck
through / marked in place.

---

## 0. What the survey changed

Five findings that invalidate the assumptions this work started from. Read these first — three of
the seven features are cheaper than expected and two are considerably more expensive.

1. **Photo → recipe already ships end to end.** [FoodView.swift:1583](../App/Fernlet/FoodView.swift)
   `identifyMealPhoto(_:)` → [MealPhotoRecognizer.swift:34](../App/Fernlet/MealPhotoRecognizer.swift) →
   prefill + `MealReviewContext(resolution:photo:)` → review sheet → `saveMealPhoto` /
   `attachMealPhoto`. There is no wall problem: the dish name is produced on-device and handed to
   the existing text-only `MealDecompositionPayload`. The work is recognition quality, servings
   estimation, and one missing wire — not architecture.

2. **The micronutrient gap engine already exists.** `MicronutrientGapAnalyzer.gaps` and its 11-entry
   RDA table are at [NutritionModels.swift:655](../FernletKit/Sources/FernletDomainModel/NutritionModels.swift),
   gaps are persisted as derived signals on 7- and 14-day windows, they already move the companion
   score via `FernletScoring.micronutrientModifier`
   ([Scoring.swift:365](../FernletKit/Sources/FernletScoring/Scoring.swift)), and an ambient card
   already ships at [AmbientCards.swift:408](../App/Fernlet/AmbientCards.swift). It just never names a
   food. **Do not build a gap detector.**

3. **The spec already specifies two of these features, with delivery mechanisms.**
   [FernletSpecificationV3 §12](FernletSpecificationV3.md) line 582: *"Ambient features should avoid
   dashboards, charts, percentiles, comparisons, and nags."* Line 591: *"Meal suggestions from user
   history and macro gaps."* Line 594: *"Shopping lists via share sheet and optionally Reminders."*
   Line 618 gives the exact copy shape for nutrient suggestions. Building either as a screen
   contradicts the spec; building both as ambient nudges makes them small.

4. **Cooking mode, scaling, and grocery list all block on one schema change, not three.**
   `SavedRecipeRecord` ([FernletKit/Sources/CloudKitSync/Persistence.swift:355](../FernletKit/Sources/CloudKitSync/Persistence.swift))
   is the only row entity built from typed columns instead of the `idString + payloadData` JSON-blob
   shape used by `CustomItemRecord`, `CoinLedgerRecord`, `MilestoneLedgerRecord`, and `DayRecord`. It
   hardcodes `ingredients: []`. Migrate it once and **all four unblock** — F3, F4, F5, and (per D-A,
   2026-07-24) synthesized recipe persistence.

5. **The AI retry queue silently destroys any non-meal retry.**
   `AIAnalysisRetryRecord.payloadType` is a free `String` and `AIRetryQueueService`'s own comment
   invites `workout`/`recipe`/`daily-summary` kinds — but the only consumer,
   `FernletStore.retryOldestMeal()` ([FernletStore.swift:2967](../App/Fernlet/FernletStore.swift)),
   takes `retryQueue.first` with **no** `payloadType` filter, looks up `record.sourceId` in that
   day's meals, and on the inevitable miss calls `clear(id:)`. The first non-meal AI feature that
   enqueues a retry loses it. Fix before shipping any second AI feature.

---

## 1. Build order

> **SHIPPED STATUS (2026-07-25, branch `claude/ai-ladder-features`).** Under `main`: STEP 0b/0c/0,
> F1(a), F2. On this branch: the **PROVIDER-SEAM REFACTOR** (commits `ee74c0b..5adcb96` — capability
> tiers, `FernletModelRouter`, `AIDestination` cases, audit-log fields + device-local persistence, the
> net-new quota counter, and every AI call site routed through the seam) and the **EXPANSION FEATURES**
> F4 (scaling + substitution), F3 (Phase A share-text + Phase B planner), and F5 (cooking mode + Live
> Activity + Siri intents). The CLOUD/BYOK/iOS-27 tracks remain gated as below; F6/F7 remain deferred
> (D-C). NOTE: the seam block's listed **"keychain-purge leg in `deleteAllData`" did NOT ship** — there
> is no BYOK key to purge yet (the delete-all comment defers it), so it belongs to the BYOK track, not
> the shipped seam.

**This is the single canonical, topologically-sorted build order for BOTH docs (revised
2026-07-24).** The [AI-Provider-Ladder §9](AI-Provider-Ladder-2026-07-23.md) build order is
superseded by this one and now points here; the ladder doc keeps only its ladder-specific track. The
two previous, contradictory orders (this doc's tree omitted the ladder's recipe-creation feature; the
ladder's §9 omitted STEP 0/0b/0c) are replaced.

```
STEP 0b  retryOldestMeal payloadType dispatch + meal-scoped badge   FIRST — tiny, unblocks everything
STEP 0c  CloudKit schema deploy process (none exists)               process prerequisite
STEP 0   SavedRecipeRecord -> payloadData migration                 additive-only (see §9.1); D-A prerequisite
   |                                                                 for recipe synthesis, F3/F4/F5
   |
   +== INCREMENT 1 — ships STANDALONE, all on-device, no cloud tier, no PCC/BYOK, no iOS 27 =========
   |     F1(a)  decomposition -> createRecipe wire  (highest-value cheap win; §2.5)
   |     F2     micronutrient suggestions           (independent, curated table; §3)
   |
   +== PROVIDER-SEAM REFACTOR (no behavior change) ==================================================
   |     AICapabilityTier, FernletModelRouter, AIDestination cases (clean build + EnumDecodeCompat),
   |     audit-log fields + DEVICE-LOCAL persistence, the net-new quota counter, and the
   |     keychain-purge leg in deleteAllData   (all detailed in the ladder doc)
   |
   +== CLOUD TRACK — gated on iOS 27 GA (~Sept 2026); cannot ship above the on-device floor before ==
   |     PCC entitlement (long pole) + first-use PCC consent sheet (D-B, same commit as the
   |       Privacy-Policy:119 / spec-guardrail:894 amendments)
   |     recipe synthesis (LADDER §4; persists via STEP 0-migrated SavedRecipeRecord, D-A)
   |     workout personalization                 (each per-feature opt-in)
   |
   +== BYOK TRACK — after PCC, per D-D (two adapters only) ==========================================
   |     Anthropic native LanguageModel package + one OpenAICompatible custom-endpoint adapter,
   |     settings UI, keychain storage, BYOK spend guard, custom-endpoint host/ATS requirements
   |
   +== iOS 27 ON-DEVICE UPLIFT (ladder track, once iOS 27 is available) =============================
   |     adopt the larger multimodal on-device model for the `standard` tier; revisit meal-photo
   |     analysis (currently Vision/Core ML)   — LADDER §9 ladder-track item 4
   |
   +== EXPANSION FEATURES (after STEP 0) ===========================================================
   |     F4 recipe scaling
   |       +-- F3 grocery list   (Phase A share-text: NO STEP 0 dependency;
   |       |                      Phase B planner rides DayRecord payload — no deploy;
   |       |                      web-import aggregation + "cook for 6" need STEP 0/F4)
   |       +-- F5 cooking mode   (after STEP 0; independent of F3 both ways)
   |
   +== DEFERRED (owner decision D-C, 2026-07-24) ===================================================
         F6 progressive overload / per-set record   — pending a spec-level product decision
         F7 deload detection                        — pending F6 and a defined artifact
```

`grep -rn initializeCloudKitSchema` returns **zero** hits and no doc describes pushing the Core Data
model to CloudKit's development or production environment. The container is
`NSPersistentCloudKitContainer` against `iCloud.MBO.Fernlet`
([FernletKit/Sources/CloudKitSync/Persistence.swift:183](../FernletKit/Sources/CloudKitSync/Persistence.swift))
with lightweight *local* migration configured at `:167-168` — that covers on-device SQLite, not
server-side record types. **Batch every Core Data change in this doc into a single deploy**, and note
STEP 0 modifies a **walled module** (`CloudKitSync`), so a wall check is required on that change.

> **Ordering notes (2026-07-24):** STEP 0b → STEP 0c → STEP 0 are strict prerequisites at the top.
> **Increment 1 (F1(a) + F2) is fully on-device** and ships before any cloud/provider work — it does
> not require PCC, BYOK, iOS 27, or a CloudKit deploy. The **cloud recipe-synthesis** feature (the
> ladder's text→recipe) is distinct from the on-device F1(a) wire and depends on STEP 0 (D-A). F6/F7
> are **deferred (D-C)** and intentionally absent from the active order.

---

## 2. F1 — Photo → recipe

### 2.1 What ships today

| Stage | Where | Behavior |
| --- | --- | --- |
| Capture | [PhotoCaptureControl.swift:25](../App/Fernlet/PhotoCaptureControl.swift) | Camera-first; `onCameraCapture(UIImage)`, `onLibraryPick(UIImage)`, `onLibraryPickData((Data, Date?))`. EXIF capture-date read at `:106`. |
| Entry point | [FoodView.swift:1583](../App/Fernlet/FoodView.swift) | `identifyMealPhoto(_:)` → `MealPhotoRecognizer().identify` at `:1588` |
| Recognition | [MealPhotoRecognizer.swift:34](../App/Fernlet/MealPhotoRecognizer.swift) | Gates on `aiStatus != .off`, classifies, composes text, calls `host.resolveMeals` |
| Classifier | [FoodImageClassifier.swift:28](../FernletKit/Sources/AppServices/FoodImageClassifier.swift) | `VisionFoodImageClassifier` — Vision `VNClassifyImageRequest`, Apple's general ~1300-class taxonomy on a detached Task |
| Filter | [FoodImageClassifier.swift:68](../FernletKit/Sources/AppServices/FoodImageClassifier.swift) | `FoodImageTaxonomy`: `confidenceFloor = 0.3`, `maxLabels = 3`, **226** unique single-word tokens (`:109-150`), top ≤3 joined by `" and "` |
| Resolution | [MealResolutionService.swift:78](../App/Fernlet/MealResolutionService.swift) | 5-tier cascade, `plausibilityGated` at `:220` |
| Review | [FoodView.swift:1595](../App/Fernlet/FoodView.swift) | Prefills the description field, sets `MealReviewContext(resolution:photo:)` |
| Attach | [FoodView.swift:1571](../App/Fernlet/FoodView.swift) | `attachPhoto` → `saveMealPhoto` → `attachMealPhoto`; sheet deliberately does **not** dismiss on seal failure (`:1342-1344`) |

The resolution cascade, in order: (1) AI dish decomposition, (2) AI candidate-constrained selection,
(3) `DishTemplateLexicon` deterministic, (4) deterministic candidate plan, (5) keyword heuristic
(fabricated macros, always `.low` + `needsReview`). Every high-confidence result passes
`plausibilityGated`: `MealPlausibility` caps at 4,000 kcal and 3,000 g, plus a 0.3–9 kcal/g density
check. **Any new tier must route through this or it bypasses the only guard that caught the
"2 burger patties → 81,688 kcal" class of bug.**

Tier 1 is [FoundationDishDecomposition.swift:14](../App/Fernlet/FoundationDishDecomposition.swift). Its
`@Generable` schema is `{name, mealType, components[{ingredient, preparation, grams, confidence,
explicitlyStated}], overallConfidence}` — **the model emits ingredient names and grams, never
macros.** `MealDecompositionResolver.resolve` (`:100`) binds each component with
`catalog.scoredResults(for:limit:1)` gated on `FoodItemSearch.minimumBindScore` (= 1,
[FoodItemSearch.swift:37](../FernletKit/Sources/FernletDomainModel/FoodItemSearch.swift)), clamps
grams to `DishTemplateLexicon.componentGramBounds` then to `1...1500`, dedupes by `foodItem.id`, and
sanity-checks density. This is already the ladder's invariant, shipped.

### 2.2 The four real gaps

**(a) The decomposition tier throws away the recipe it just built.**
[MealResolutionService.swift:93](../App/Fernlet/MealResolutionService.swift) returns
`createdRecipes: []`. But `MealDecompositionResolver` computes
`deduped: [(FoodSelectionIngredient, FoodItem)]` at
[FoundationDishDecomposition.swift:139](../App/Fernlet/FoundationDishDecomposition.swift) — with
quantities in grams and `unit = RecipeUnit.gram` — which is structurally identical to what
`MealBuilder.createRecipe` ([MealBuilder.swift:127](../App/Fernlet/MealBuilder.swift)) consumes. The
dish name is there too: `decomposition.name` already flows through at `:167-169`. **Wiring the
decomposition tier into `createRecipe` is a handful of lines, not a new binder.** This is the
single highest-value change in the whole document.

> **Audit delta (2026-07-24): cheap, but not free.** The wire crosses a cross-SPM-package edit.
> `ResolvedMeal` ([NutritionModels.swift:355](../FernletKit/Sources/FernletDomainModel/NutritionModels.swift))
> carries only `{meal, confidence}`, so threading the built recipe back out requires **either** a
> `FernletDomainModel` struct-field addition (the documented **clean-build hazard**) **or** two
> return-signature changes. And `MealBuilder.createRecipe` is **`private static`** (`:127`) — it must
> be reachable from the resolution path. Still the best warm-up, still increment 1, but budget the
> package edit.

**(b) Recognition is a general scene classifier plus a word list.** `VNClassifyImageRequest` returns
taxonomy labels ("banana", "pizza", "laptop"), not dishes. Anything outside the 226-token list is
invisible. Note the survey's own error, corrected: `pad thai` and `pho` *are* shipped — not in
`foodTokens`, but as two of the 29 entries in [DishTemplates.json](../App/Fernlet/DishTemplates.json)
(a dict `{version, dishes}`, each dish carrying aliases, `isComposite`, `unit`, `defaultCount`, and
components with `search` / `gramsPerUnit` / `preparation`). Those templates are also the *only*
thing bounding model-emitted grams before the loose `1...1500` clamp.

Options, cheapest first: (i) extend `foodTokens` and `DishTemplates.json` — mechanical, no ML;
(ii) route the classifier's raw labels *plus* the user's typed text to the deep tier for dish naming
— text-only, no wall change; (iii) send the image to a multimodal model — see §2.4.

**(c) No servings estimation from a plate.** `MealBuilder.createRecipe` hardcodes `servings: 1`
([MealBuilder.swift:141](../App/Fernlet/MealBuilder.swift)). `RecipeWebImporter.parseServings` (`:345`)
is JSON-LD-derived and `ExtractedRecipe.importedRecipe` hardcodes `servings: 1` at `:684`;
`NutritionLabelScanner` surfaces `servingsPerContainer`. So serving *parsing* exists in two places
and serving *estimation* exists nowhere. A plate photo is one serving of the plated dish but N
servings of the recipe that produced it — that distinction has no representation today.

**(d) No "save this as a recipe" affordance.** Recipes reach the book via the manual builder, web
import, or `MealBuilder`'s implicit multi-ingredient auto-mint. Grep finds no
`save as recipe` / `saveAsRecipe` UI anywhere.

### 2.3 Design

```
photo ──> Vision classifier ──┐
                              ├──> dish name (text) ──> MealDecompositionPayload ──> deep tier
user's typed text ────────────┘                              (NO payload change)
                                            │
                                            v
                          @Generable {name, components[{ingredient, grams, ...}]}
                                            │
                          ┌─────────────────┴─────────────────┐
                          v                                   v
              catalog.scoredResults bind              MealBuilder.createRecipe
              (on-device, always)                     (servings from F1(c))
                          │                                   │
                          v                                   v
                  plausibilityGated  ────────────>  MealReviewSheet ──> recipe book + meal
```

**The wall-cheapest design sends text, not pixels.** `MealDecompositionPayload`
([AIContextPayload.swift:37](../FernletKit/Sources/AIContext/AIContextPayload.swift)) carries
`mealDescription` + `fallbackMealType`. A photo-derived dish name drops straight in with **zero new
payload type and zero wall change**.

### 2.4 If pixels ever do cross

Not required for F1, but scope it honestly before anyone proposes it:

- **No payload can carry binary.** All eight conformers of `AIContextPayload` are
  String/Int/Double/enum. `includedFieldNames: [String]` — the audit contract — has no notion of
  describing an opaque blob.
- **No multimodal precedent.** All four `FoundationModels` call sites build a `String` prompt and
  call `respond(to:generating:)`. Zero image plumbing, zero availability checks.
- **The normalization helpers are inside the sealed module.** `MealPhotoStore.normalizedJPEG`
  ([MealPhotoStore.swift:148](../FernletKit/Sources/PrivateMediaStore/MealPhotoStore.swift), ImageIO
  thumbnail, ≤1600 px, q0.8) and `PrivateMediaStore.isWithinSafePixelBounds` (`:174`) are exactly
  what a model-bound image needs — and naming either from an AI-facing file is a grep-wall
  violation.
- **The mechanism to permit it already exists.** `S3BoundaryTests.swift:87-89` defines
  `sanctionedGateExemptions: [String: Set<String>]`, today
  `["MemoryAgent.swift": ["TierTwoMemoryRecord"]]` — one named file may name one named forbidden
  token, everything else still enforced. `MealPhotoPolaroid.swift:10` shows the closure-injection
  alternative (give a component sealed bytes without it naming the store).
- **A working precedent for the wall shape exists**: `FoodProductWebImporter.swift` (948 lines, app
  target) is a hard grep-wall floor file that performs network fetches *and* builds a
  `FoundationModels` prompt, staying wall-clean by never naming a sealed store. **But do not copy its
  SSRF posture (corrected 2026-07-24):** its `fetchHTML` / `fetchImage` (`:340`, `:522`) validate
  **scheme-only, with no per-redirect-hop validation**, which makes it **weaker SSRF-wise than
  `RecipeWebImporter`**. **`RecipeWebImporter` is the precedent to copy** (it does per-redirect-hop
  `isPrivateOrLoopbackIPLiteral` validation); `FoodProductWebImporter` is a **counter-example to
  fix**, not a template.

### 2.5 Bugs found in passing

- **Double JPEG encode.** `FernletStore.saveMealPhoto` does `image.jpegData(compressionQuality:
  0.82)` at [FernletStore.swift:1577](../App/Fernlet/FernletStore.swift), then `MealPhotoStore.save`
  runs `normalizedJPEG` which re-encodes at q0.8. A full-resolution encode plus generation loss, on
  the iPhone-11 memory floor.
- **The meal sheet decodes when it doesn't have to.** [FoodView.swift:1221](../App/Fernlet/FoodView.swift)
  holds `@State mealPhoto: UIImage?` full-resolution for the whole sheet session, because `MealSheet`
  uses `onLibraryPick` rather than `onLibraryPickData`. The recipe surface already uses the byte path
  (`:2805`, `:2820`). A 48 MP library pick decodes to ~190 MB. **Fix this as part of F1: switch the
  meal sheet to `onLibraryPickData`.** This double-JPEG + full-res `UIImage` landmine (~190 MB on the
  iPhone-11 floor) fires *more often* once F1 makes photo→recipe a first-class path, so the byte-path
  switch belongs in the same increment.
- **`MealPhotoRecognizer` is not grep-walled.** `S3BoundaryTests` discovers AI-facing files by the
  markers `LanguageModelSession` / `SystemLanguageModel` / `@Generable` / `import FoundationModels`.
  `MealPhotoRecognizer.swift` has none, and `FoodImageClassifier.swift` lives in `AppServices` which
  is not in `scanRoots` at all.

---

## 3. F2 — Micronutrient observations and gap-filling food suggestions

**Priority feature. Re-labelled from "blocked on a data problem" to SMALL** — provided it is built
as spec §591/§618 describe (an ambient nudge naming two or three foods) rather than as a ranked
screen, which §582 forbids.

### 3.1 What ships today

| Piece | Where | State |
| --- | --- | --- |
| Gap detection | `MicronutrientGapAnalyzer.gaps`, [NutritionModels.swift:655](../FernletKit/Sources/FernletDomainModel/NutritionModels.swift) | 11 tracked nutrients, flat adult RDA table |
| Persistence | `DerivedSignalRecord` via `DerivedSignalFactory` | 7- and 14-day windows, 7-day ordered first |
| Coverage gate | `micronutrientDataCoverageRatio`, `NutritionModels.swift:674` | counts a meal only if `populatedFieldCount >= 5` |
| Scoring | `FernletScoring.micronutrientModifier`, [Scoring.swift:365](../FernletKit/Sources/FernletScoring/Scoring.swift) | gaps ≥7 days: `max(count * -0.015, -0.05)`; covered: `min(count * 0.01, +0.03)` |
| Dedup | `dedupedNutrientGaps` `:341` + `preferNutrientGap` `:355` | dedupe by key, prefer `.gap`, then longer window |
| Ambient card | [AmbientCards.swift:408](../App/Fernlet/AmbientCards.swift) | gate at `:442`; copy at `:417`: *"⟨Name⟩ has been a little low lately."* |
| Second UI | [HomeView.swift:1640-1652](../App/Fernlet/HomeView.swift) | per-nutrient gap/covered rows, `prefix(4)` |
| Suppression | `nutrientBubbleDismissedUntil`, [DiaryStore.swift:847](../FernletKit/Sources/DiaryStore/DiaryStore.swift) | per-nutrient-key 14-day suppression, persisted, tolerant decode |
| Accept/dismiss precedent | [GentleOffers.swift](../App/Fernlet/GentleOffers.swift) + `AmbientCards.swift:125-180` | full offer engine; reuses the nutrient map under a reserved key (`DiaryStore.swift:859-880`) |

**Spec line 618 already mandates naming sources.** The shipped card is the spec's feature, minus its
payload.

### 3.2 The catalog problem, measured

Micronutrients are stored as **one opaque JSON TEXT column**. The only indexes are `idx_food_id`,
`idx_food_normalized_name`, `idx_food_gtin_upc`, plus FTS5 on names. There is no per-nutrient
column, no nutrient index, and no nutrient predicate. *"Top foods for iron" is not expressible
today.*

Bundled catalog: 118,317 rows = 109,163 branded / 8,888 srLegacy / 202 survey / 64 restaurant.

| Nutrient | Non-null rows | Usable? |
| --- | --- | --- |
| sodium | 109,075 | yes |
| sugar | 101,554 | yes |
| iron | 92,922 | yes |
| saturated fat | 91,683 | yes |
| calcium | 89,455 | yes |
| fiber | 85,802 | yes |
| cholesterol | 74,040 | yes |
| potassium, vitamins | sparse | **effectively zero on the branded corpus** |

**And naive ranking is unusable.** Measured, top srLegacy foods by raw iron per 100 g: dried thyme
124 mg, dried basil 89.8, dried spearmint 87.5, dried marjoram 82.7, *"Whale, beluga, meat, dried
(Alaska Native)"* 72.4, fortified bran flakes 67.7, dry infant oatmeal 67.2. By vitamin C: GERBER
baby food 2,730 mg. Density ranking without portion realism produces suggestions that damage trust
instantly.

Contributing factors: only 7,985 of 118,317 base rows (6.7%) carry any `portions`, and the branded
ODR catalog has **zero**; 8,839 of 8,888 srLegacy rows have `servingSize = 100.0` but 49 do not, and
those 49 are exactly the concentrated small-serving rows a density ranking mis-scales.

### 3.3 Design — curated table, not an index

Given §582 forbids the ranked screen anyway, the cheap and correct answer is a **hand-authored
good-sources table**: roughly five foods per tracked nutrient, chosen for portion realism and
everyday recognizability, each pinned to a catalog `FoodItem` id so the nudge can offer *"add it"*
and bind deterministically. ~55 rows of curated JSON. No new index, no catalog regeneration, no
57 MB rewrite.

The model's job is narrow and optional: phrase the nudge in Fernlet voice and pick which two of the
five fit this user's recent eating pattern (from `eatingPattern` and recent meal names — data that
already crosses in `DaySummaryPayload`). Selection is by **candidate number**, exactly as
[FoundationFoodSelection.swift:204](../FernletKit/Sources/AIProviders/FoundationFoodSelection.swift)
does. With AI off, the nudge names the top curated entry deterministically.

If a real nutrient query is ever wanted, the seams exist: `json_extract(micronutrients,'$.vitaminD')`
works directly against the shipped file (keys match Swift property names exactly), and
`FoodCatalog.attachBrandedSource` / `detachBrandedSource` (`:51`/`:56`) make scoping a query to the
base catalog trivial. `SQLiteBundledFoodSource` already has the per-source tuning precedent
(`hasBarcodeColumn` PRAGMA feature-detection, `skipPriorityOrder`, `candidateCap`).

### 3.4 Safety and correctness constraints

- **The RDA table is one flat adult set.** Iron is 18 mg — adult premenopausal female — applied to
  every user. No age, sex, pregnancy, or life-stage input exists, and there are no Tolerable Upper
  Intake Levels. A *suggestion* feature pushes intake up, so the absence of ULs matters more than it
  did for a passive observation. Partial precedent exists: `NutritionTargets` carries `sodiumLimit`
  (2,300) and `saturatedFatLimit`, and `JournalView.swift:828-838` already renders limit-style rows
  with an `isLimit` flag.
- **Two reference tables disagree.** `NutritionLabelScanner`'s `dvReference` differs from
  `trackedNutrients` on calcium (1,300 vs 1,000) and potassium (4,700 vs 3,400). Reconcile before
  building on either. (Vitamin D is *not* a disagreement — both are 20.)
- **`DiagnosticLanguage` will silently eat this feature's copy — but it is also blind to this
  feature's real risk vocabulary.** It is an **English-only substring gate**: 26 lowercase substrings
  ([DiagnosticLanguage.swift:15-23](../FernletKit/Sources/FernletDomainModel/DiagnosticLanguage.swift))
  including `period` and `cycle`, matched after normalizing to lowercase alphanumerics — which
  **fuses tokens across separators**. The gate returns an empty string with no diagnostic. Two
  consequences (revised 2026-07-24): (1) any nutrient copy must be **tested against it** so it isn't
  silently blanked; (2) it does **not contain deficiency/supplement vocabulary** (`deficient`,
  `deficiency`, `anemia`, `supplement` are not in the list) and it does not screen non-English model
  output — so it will **not** catch clinical-sounding nutrient copy on its own. Nutrient copy must be
  **reviewed separately**, not assumed safe because it passed this gate.
- **`MemoryAgent` has a payload-kind allowlist.** `allowedPayloadKinds: Set<String> =
  ["companion-thought"]` ([MemoryAgent.swift:15](../FernletKit/Sources/AIContext/MemoryAgent.swift)),
  guarded at `:29`. A new nutrient payload kind gets an empty memory string until explicitly added —
  which is also the natural review checkpoint.
- **Period interaction stays out.** Iron needs vary with menstruation, but period bridge signals are
  stripped from AI providers by the wall and are unnameable in `AIProviders`. The nudge must not
  imply cycle awareness.

### 3.5 Bug found in passing

The ambient card does **not** use the dedup helper. `FernletScoring.dedupedNutrientGaps` is used for
scoring ([FernletStore.swift:436](../App/Fernlet/FernletStore.swift)) but `AmbientCards.activeNutrientGap`
does a raw `.flatMap(\.nutrientGaps).filter{...}.first` at `:440-443`, so the 7-day and 14-day
signals for the same nutrient are not deduped at the card. Also, the shipped gate accepts
`windowDays >= 7` while spec line 618 says 14 — the card fires on the looser window.

### 3.6 Reference table — FDA Daily Values, verified 2026-07-23

Verified against 21 CFR 101.9 — the RDIs in (c)(8)(iv) and DRVs in (c)(9), adults and children
≥4 years — read via Cornell LII's copy of the eCFR (fda.gov and ecfr.gov both block automated
fetch; spot-check the live eCFR once before seeding the code table). Reconciliation against
`MicronutrientGapAnalyzer.trackedNutrients`
([NutritionModels.swift:655](../FernletKit/Sources/FernletDomainModel/NutritionModels.swift)):

| Key | Code today | FDA DV | Action |
| --- | --- | --- | --- |
| fiber | 28 g | 28 g (DRV) | keep |
| vitaminC | 90 mg | 90 mg | keep |
| vitaminD | 20 mcg | 20 mcg | keep |
| vitaminB12 | 2.4 mcg | 2.4 mcg | keep |
| folate | 400 mcg DFE | 400 mcg DFE | keep |
| calcium | 1,000 mg | **1,300 mg** | **update** |
| iron | 18 mg | 18 mg | keep |
| magnesium | 420 mg | 420 mg | keep |
| potassium | 3,400 mg | **4,700 mg** | **update** |
| zinc | 11 mg | 11 mg | keep |
| omega3 | 1.6 g | **none — FDA has no omega-3/ALA DV** | keep; annotate as NASEM AI (ALA) |

Related DRVs for the limit rows the app already renders: sodium 2,300 mg (matches
`NutritionTargets.sodiumLimit`), saturated fat 20 g, added sugars 50 g. Note the hardcoded 50 g
sugar row in `JournalView.swift:828-838` coincidentally equals the *added*-sugars DV but is applied
to total sugar — fold into the reconciliation pass.

The stale 1,000 / 3,400 are the NASEM adult-19–50 values — a different reference system, not typos.
Standardizing on FDA DVs matches `NutritionLabelScanner.dvReference` (already 1,300 / 4,700) and
what food packages print. **Behavior note (strengthened 2026-07-24): the change can only lower
scores on existing users.** Raising the calcium (1,000→1,300) and potassium (3,400→4,700)
denominators **lowers coverage ratios**, which pushes `micronutrientModifier`
(`Scoring.swift:364-373`) in one direction on both of its branches: **more gap penalty** (the
`.gap` branch, capped at **−0.05**) **and less covered bonus** (the covered branch,
`min(covered.count * 0.01, 0.03)`, capped at **+0.03**). Net effect is one-directional — down — never
up. It is small and hits only the narrow very-low-intake cohort, but it lands as an invisible rider
on a table cleanup. **Ship it with a pinned scoring test and a release note — not silently.** The shared table lands in
`FernletDomainModel` and both consumers point at it in the same commit.

---

## 4. F3 — Grocery list

**Decided (§11.3): weekly planner + share-to-Notes. MEDIUM.**

Spec §594 — *"Shopping lists via share sheet and optionally Reminders"* — remains the delivery
mechanism. (§582's anti-dashboard rule constrains ambient *nudges*; a user-initiated planning tool
is not an ambient surface.) The list itself stays a generated artifact: no persisted checklist, no
new entity, no CloudKit deploy — check-off happens in Notes or Reminders, which are better at it
anyway. What grew is the front end: a weekly planner for choosing the recipes (§4.4).

### 4.1 The unifier already exists

`DataExportBuilder.recipeIngredientLines(_:nameByFoodID:)`
([DataExportBuilder.swift:369](../App/Fernlet/DataExportBuilder.swift)) already takes *any*
`RecipeDefinition` and returns `[String]`, collapsing both recipe shapes — it returns
`webImport.ingredientLines` for web imports and resolves structured ingredients for manual ones.
That is the whole share-sheet feature's core, shipped.

`FoodCatalog.items(forRecipes:)` ([FoodCatalog.swift:158](../FernletKit/Sources/FoodCatalog/FoodCatalog.swift))
already resolves the deduplicated union of `foodItemId`s across multiple recipes in one call.

### 4.2 Why aggregation is the hard half

- **Web-imported recipes have no structured ingredients at all**, confirmed at three seams:
  `RecipeDefinition(importedRecipe:)` sets `ingredients: []`
  ([SharedRecipeImportQueue.swift:170](../FernletKit/Sources/AppServices/SharedRecipeImportQueue.swift)),
  `SavedRecipeMapping.recipe(...)` sets `ingredients: []`, and the proximity path at
  `FernletStore.swift:2877-2895`.
- **Recipes live in two disjoint stores.** Manual/peer: `DiaryStore.recipes` → `FernletSnapshot.recipes`
  → the single blob record. Web: Core Data `SavedRecipeRecord`. The UI unions them; nothing else does.
- **Three independent unit converters exist**, not one: `FoodItem.gramsEquivalent`
  ([NutritionModels.swift:1459](../FernletKit/Sources/FernletDomainModel/NutritionModels.swift)),
  `FoodDataCatalog.gramWeight(quantity:unit:)` (`:254-264`), and a third. `gramsEquivalent` consults
  the food's own portions only for `.ounce`/`.cup`/`.tablespoon`/`.teaspoon`/`.each`; `.pound` is
  unconditional at `:1470`.
- **93.3% of catalog rows have no portions** (110,332 of 118,317). Only 260 rows (0.22%) carry an
  each-mappable portion; 1,780 (1.5%) a cup portion.
- **Raw USDA unit codes reach `FoodItem.servingUnit` unnormalized** and `RecipeUnit.normalized`
  returns nil for them: `GRM` 12,376 / `MLT` 2,193 / `MG` 420 / `IU` 193 / `GM` 31.
- **No aisle taxonomy.** 331 distinct category strings in the base catalog plus 129 in the branded
  ODR catalog = 460 strings to map, and the base taxonomy lumps eggs into *"Dairy and Egg Products"*.
- **The free-text ingredient parser is trapped behind the wall.** `parseIngredient` / `parseQuantity`
  / `parseFraction` / `resolveUnit` / `cleanFoodName`
  ([RecipeWebImporter.swift:427-512](../FernletKit/Sources/AIProviders/RecipeWebImporter.swift)) are
  `private static` inside `AIProviders`. A deterministic list engine below the wall cannot call them;
  they would need lifting into `FoodCatalog` or `FernletDomainModel`.

### 4.3 Lifecycle (answered by §11.3)

Check-off state lives in Notes/Reminders, not in Fernlet — the generated list is one-shot text, so
nothing expires, and recipe edits after generation simply don't propagate (regenerate). The only
persisted state is the *plan* (which recipes on which days), which rides the per-day row (§4.4) and
degrades gracefully: a deleted recipe leaves a dangling ID that render drops. Web-imported recipe
BODIES remain **absent from the data export** (`buildDataExport()` reads only the `recipes` array).

> **AS SHIPPED (2026-07-25).** The plan's day-row field IS covered by the export: `DayExport.plannedMeals`
> projects `FernletDay.plannedRecipeIDs` to recipe NAMES (unioning both recipe stores; dangling ids
> drop). F5 cooking steps are also exported now — `RecipeExport.steps` renders each authored step
> (timer appended as "(N min timer)"). Both are covered by `DataExportTests.testExportCarriesRecipeStepsAndPlannedMeals`.
> Web-import recipe bodies staying absent is unchanged/by design.

### 4.4 Design

**Phase A — select, generate, share. No persistence, no STEP 0 dependency.**
Multi-select from the recipe book → aggregate → formatted text → share sheet, Notes as the primary
target. Aggregation: resolve via `FoodCatalog.items(forRecipes:)`, merge by `foodItemId` (fallback
key: `FoodItemSearch.normalized` name), sum quantities only when `RecipeUnit.normalized` says the
units are compatible — otherwise keep both lines. Web-imported recipes contribute their free-text
`ingredientLines` under a per-recipe heading via `DataExportBuilder.recipeIngredientLines` (the
shipped both-shapes unifier) until STEP 0 backfills structure. Output: a consolidated section on
top, per-recipe sections below.

**Phase B — the weekly planner.**
A week strip where the user assigns recipes to days (or leaves them floating in the week). The plan
persists as a `plannedRecipeIDs`-style field on `FernletDay`, mirroring the `plannedWorkouts`
precedent: `DayRecord` stores an opaque `payloadData` JSON blob per day, so the field is a tolerant
`decodeIfPresent` addition — **no Core Data schema change, no CloudKit deploy, per-row sync for
free**. "Create shopping list" aggregates the week's assignments through the Phase A pipeline.
Once F4 ships, a per-recipe scaled yield ("cook this for 6") feeds the same aggregation.

**Delivery.** `ShareLink` with the list as plain text is the entire Notes integration — Notes
receives it as a new note; there is nothing else to build because there is nothing else Apple
exposes. Reminders can be added behind the same generate step via EventKit later — worth noting
that iOS 17+ Reminders grocery lists auto-categorize items by aisle, which would sidestep the
460-category-string taxonomy problem (§4.2) without Fernlet ever building an aisle map.

---

## 5. F4 — Recipe scaling and substitution

### 5.1 Scaling

`servings` is only ever a **divisor** at display and log time — `mealFromRecipe` sets
`divisor = max(recipe.servings, 1)` ([MealBuilder.swift:57](../App/Fernlet/MealBuilder.swift)) and the
same division repeats at `FoodView.swift:877`. The servings Stepper (`FoodView.swift:761`, range
1...24) changes the divisor **without touching ingredient quantities**. Nothing multiplies a
`RecipeDefinition`'s quantities.

A working proportional scaler does exist, just not on recipes: `MealComponentCorrectionInput`
([FoodView.swift:2213-2246](../App/Fernlet/FoodView.swift)) stores `baseQuantity`/`baseMacros`/
`baseMicronutrients` and rescales. That is the math to lift.

Two things make scaling safe: `Meal` has **no** `recipeId` back-reference
([NutritionModels.swift:191](../FernletKit/Sources/FernletDomainModel/NutritionModels.swift)), so
editing a recipe can never retroactively alter a logged meal; and `Micronutrients.scaled(by:)` /
`.add(_:)` are already nil-preserving.

Two things make it awkward: `DiaryStore.updateRecipe(_:name:servings:notes:ingredients:)` (`:927`)
takes `[ManualRecipeIngredientInput]`, not `[RecipeIngredient]` — there is **no store API that
writes scaled `RecipeIngredient` quantities**. And web-imported recipes cannot be scaled at all
(`ingredients: []`).

### 5.2 Substitution

**The app has no concept of "dairy."** No allergen field, no dietary tag, no exclusion list, no
ingredient-class taxonomy. `FoodItem` carries `category: String` and `tags: [String]`, the latter
mechanically derived from category. The USDA taxonomy is actively hostile in both directions:
*"Dairy and Egg Products"* lumps eggs with dairy (over-exclusion), while branded categories include
*"Cheese/Cheese Substitutes"* and *"Yogurt/Yogurt Substitutes"* (under-exclusion).

So substitution needs the model for world knowledge, then rebinds through
`FoodCatalog.candidates(for:limit:)` by number. `CustomIngredientUpsert.resolve` is the escape hatch
when the catalog can't supply the substitute, and `FoodItem.preferredRecipeUnit` /
`defaultRecipeQuantity` (`:1425`) already pick a sensible unit for the new food.

**No provenance field exists** — no `parentRecipeID`, no `scaleFactor`, no applied-substitutions
list. Decide whether scaling mutates in place or forks a new recipe before building.

> **AS SHIPPED (resolved).** Scaling is a pure VIEW-TIME transform (`RecipeScaling`) that never mutates
> or persists the recipe — "cook for N" on the detail page and mise en place, one serving still logged.
> Substitution FORKS a new recipe carrying a `RecipeDefinition.parentRecipeID` annotation (strip-tolerant,
> nothing depends on it). No in-place mutation of the base recipe.

`MealBuilder` is `@MainActor`, lives in the app target, and imports `AIProviders`, so a scaling
engine inside `AIProviders` or `FoodCatalog` can never call back into it.

---

## 6. F5 — Cooking mode

**Re-labelled: MEDIUM-LARGE.** The runtime half is genuinely cheap; the precondition is not.

> **AS SHIPPED (2026-07-25).** F5 is shipped: `RecipeStep {text, durationSeconds?}` schema, web-import
> step preservation, mesh wire-compat (old-decoder tested), mise-en-place → Next/Back walker → finish,
> keep-screen-awake, single per-step passive timer, Live Activity + `NextCookingStepIntent`/
> `RepeatCookingStepIntent`, and resume-after-kill. Section-by-section shipped notes below; the stale
> planning claims in §6.1–§6.4 are corrected inline.

### 6.1 The runner is directly copyable

Everything needed already exists and is battle-tested: `GuidedWorkoutRunState`
([App/FernletWidgets/GuidedWorkoutRunState.swift:24](../App/FernletWidgets/GuidedWorkoutRunState.swift)) as a
flat Codable value type in the app group; `GuidedWorkoutRunStateStore` with an **injectable
directory** (falls back to app-group container, then `NSTemporaryDirectory()`) making it unit-testable;
`reconcileGuidedRunFromAppGroup()` ([FernletStore.swift:2681](../App/Fernlet/FernletStore.swift)) as the
whole resume-after-kill story, clearing the file *before* logging so a lost log beats a duplicate;
`syncActivity(_:)` (`:2547`) serializing Live Activity ops; the root-level resume card pattern at
[MoveView.swift:92](../App/Fernlet/MoveView.swift); and `Text(timerInterval:countsDown:)`
([GuidedWorkout.swift:252](../App/Fernlet/GuidedWorkout.swift)) as a zero-tick countdown the system
renders both in-app and in the widget.

`NSSupportsLiveActivities` is already true ([Info.plist:26](../App/Fernlet/Info.plist)) and
`group.MBO.Fernlet` is in both entitlements files, so no plist work is needed for a second activity
type. Shared files need adding by name to the `PBXFileSystemSynchronizedBuildFileExceptionSet` at
`project.pbxproj:118-122`. Anything dropped in `App/FernletWidgets/` is automatically grep-walled
(`S3BoundaryTests.swift:27`).

Two closer analogues also ship: `GroundingView.swift:66` is a multi-step walker with per-step
crossfade and a progress-dot row; `BreathingExerciseView` drives phases with `Task.sleep` plus a
user-facing haptics toggle.

### 6.2 The precondition

`RecipeDefinition` has **no steps field** — the exact list is `id, name, servings, ingredients,
notes, source, createdAt, updatedAt, webImport`. `notes` is one free-text String.

Worse, **JSON-LD instructions were parsed and then destroyed** (the pre-F5 state described here).

> **AS SHIPPED (corrected 2026-07-25).** `RecipeDefinition.steps: [RecipeStep]?` now exists and JSON-LD
> ordered steps are preserved via `orderedSteps(from:)` (order kept, per-step). The old flatten-then-
> truncate path still exists but now feeds ONLY `briefSummary` — it no longer destroys the structured
> steps. The old "`:556` flattens N steps into one string / steps are being discarded" text below is
> STALE; it described the pre-F5 importer.

`instructionsText(from:)`
([RecipeWebImporter.swift:551](../FernletKit/Sources/AIProviders/RecipeWebImporter.swift)) plus the
two `instructionText` overloads at `:564`/`:574` already handle `HowToStep`/`HowToSection` shapes —
but the array branch at `:556` does `values.compactMap(instructionText).joined(separator: " ")`,
flattening N ordered steps into one string, which `briefSummary` then truncates to 280 characters.
The population most likely to have steps is exactly the one whose steps are being discarded. Neither
overload inspects `@type`; both are purely shape-based.

Persisting steps hits two paths with different costs: manual recipes go into the synced Codable blob
(cheap — `decodeIfPresent`, matching the existing `RecipeDefinition.init(from:)` pattern), while
saved/web recipes go into Core Data `SavedRecipeRecord`, which is the STEP 0 migration.

### 6.3 Other gaps

> **AS SHIPPED (2026-07-25).** All four gaps below are closed: idle timer via `KeepScreenAwakeModifier`
> (the app's sole `isIdleTimerDisabled` writer, restored on disappear/background); launch point via the
> recipe-detail "Cook" action + the Food-root resume card; wire format via an optional `steps` key,
> `SharedRecipePayload` still pinned `version 1`, with old-decoder tests (`RecipeStepsTests`); single
> per-step timer = the deliberate v1 scope. Concurrent named timers remain out of scope.

- **No idle-timer handling anywhere.** Exhaustive grep for `isIdleTimerDisabled` returns zero hits.
  A cooking screen that sleeps mid-recipe is a bad experience.
- **One timer at a time.** The run state expresses a single `restStartedAt`/`restEndsAt` pair.
  Cooking regularly needs several named concurrent timers.
- **No launch point.** `RecipeDetailView.actionsRow` ([FoodView.swift:2956](../App/Fernlet/FoodView.swift))
  has exactly Log / Edit / Share, and four call sites construct `RecipeDetailView`.
- **No wire format for steps.** `SharedRecipePayload` (`NutritionModels.swift:1310`) pins
  `version: Int = 1` and `RecipeShareCodec.proximityPayload` carries an explicit *"keeping wire
  compatibility with peers running older builds"* comment ([RecipeShareCodec.swift:49](../App/Fernlet/RecipeShareCodec.swift)).
  A recipe with steps shared to an older peer must degrade to a recipe without steps, not fail to
  decode.

The completion leg is free: `FernletStore.logRecipe(_:mealType:date:)` (`:1639`) already takes a
day-key parameter, which is the anchoring a long cooking session needs.

### 6.4 Interaction model (per decision §11.6)

> **AS SHIPPED (2026-07-25).** Built as specified: mise en place first (F4-scaled), explicit Next/Back
> walker (the timer never advances the step — on expiry it highlights Next + fires a haptic), Live
> Activity + `NextCookingStepIntent`/`RepeatCookingStepIntent`, resume-after-kill, and a finish/log leg
> whose meal log anchors to the run's `startedDayKey` (survives a midnight rollover). The in-app walker
> renders from the run's own frozen step snapshot while a run is active (a mid-run recipe edit can't
> desync the cursor from the text).

**Opens with mise en place.** Before step one, a screen lists every ingredient and amount — scaled
by the F4 transform when the cook chose a different yield. This reuses `RecipeDetailView`'s
per-serving math (`totals` / `perServing`, [FoodView.swift:2699/:2712](../App/Fernlet/FoodView.swift))
and gives the web-import population (no structured ingredients until STEP 0) graceful degradation:
their free-text lines render as-is.

**Navigation is explicit, never timer-driven.** A Next/Back pair advances the walker, plus a voice
path for messy-hands cooking: `NextCookingStepIntent` / `RepeatCookingStepIntent` App Intents
operating on the app-group `CookingRunState` — the exact pattern the interactive Live Activity
already uses for Done-set/Skip-rest (`LiveActivityIntents` on `GuidedWorkoutRunState`), and the
App Intents surface shipped in `a75e839` gives the Siri phrasing a home.

**The timer is demoted to a signal.** When a step carries `durationSeconds`, a passive
`Text(timerInterval:countsDown:)` countdown runs in-app and in the Live Activity; on expiry it
highlights the Next button and fires a haptic (the `BreathingExerciseView` haptics pattern) — it
never auto-advances the step. Steps without a duration just show the button. v1 scope is a single
per-step timer; concurrent named timers ("pasta" + "sauce") are explicitly out of scope until the
run-state schema needs a second `start/end` pair anyway.

---

## 7. F6 — Progressive overload coach

> **DEFERRED (owner decision D-C, 2026-07-24).** F6 is **not in the active build order** pending a
> spec-level product decision: the per-set weight/1RM/tonnage record is the single feature closest to
> the "optimization framing" the spec explicitly rejects
> ([FernletSpecificationV3.md:65](FernletSpecificationV3.md)), and it is the largest schema-invasive
> write. The survey content below is kept for when that go/no-go is made — do not schedule it before.

**Re-labelled: LARGE, and larger than first stated.**

### 7.1 The blocker

**There is no set-level model anywhere. Nothing records weight.** No `WorkoutSet`, `LoggedSet`, or
equivalent. `Workout` ([WorkoutModels.swift:6](../FernletKit/Sources/FernletDomainModel/WorkoutModels.swift))
has no weight/reps/sets fields. `PrescribedExercise` (`WorkoutProgram.swift:924`) has sets/reps but
is transient and non-Codable. There is no 1RM, e1RM, Epley/Brzycki, tonnage, or volume-load math
anywhere in the repo.

The only persisted per-exercise history is a name→count map:
`FernletSettings.workoutProgression: [String: Int]`
([SettingsModel.swift:172](../FernletKit/Sources/FernletDomainModel/SettingsModel.swift)),
incremented once per completed guided session by `DiaryStore.recordCompletedExercises` (`:707`).

**`recentWorkouts` does not exist.** The spec's cap-30 array persisted at `recent-workouts` is not
in the codebase — the only match is `HealthKitService.recentWorkouts(since:)`, an unrelated
30-day HK backfill query.

**RPE is per-session, optional, and absent on every automated path.** `Workout.rpe: Double?` is one
value for a whole workout, written from exactly two manual sheets. Activity-mode workouts use a
different field entirely — `effort: Int?` (1–10) — with `rpe` forced nil
([MoveView.swift:623](../App/Fernlet/MoveView.swift)). And RPE **cannot be corrected after logging**:
the edit sheet exposes only name/intensity/duration/notes (`FernletStore.swift:1817`).

### 7.2 Why the write is expensive

A new performed-work record must be written from **both** guided-completion paths
(`FernletStore.swift:2734` cold-launch and `:2474` in-app), reversed by `reverseGuidedCompletion`
(`:1871`), tolerated by the HealthKit reconcile that can delete and rebuild rows, added to **both**
export schemas (`TrainerExportBuilder.swift:96`/`:215-223` and `DataExportBuilder`'s equivalent), and
wired into `deleteAllData`.

### 7.3 What can be reused

- `WorkoutAdjustmentCandidateBuilder.candidates`
  ([FoundationWorkoutAdjustment.swift:30](../FernletKit/Sources/AIProviders/FoundationWorkoutAdjustment.swift))
  — safety-filtered pool in, numbered candidates out. Note the type name: not
  `WorkoutAdjustmentCandidates`.
- `FoundationWorkoutPlan.resolved(candidates:)` (`:128`) — look up by emitted integer, silently drop
  unmatched and duplicates, clamp every scalar, cap the array.
- `WorkoutSafetyFilter.feasible` / `feasibleExercises` (`WorkoutProgram.swift:381`) — its own doc
  says the AI adjuster *"must run its output back through this, never around it."*
- `MoveView.exerciseEntries(from:)` (`:2731`) — a **working round-trip parser** of the free-text
  exercise grammar, resolving names through `WorkoutExerciseCatalog.search`. (A survey claimed no
  parser existed; that was its most damaging error.)
- `WorkoutRestGuidance` — the shape a load-progression table should mirror: research-backed,
  per-exercise, overridable, clamped.
- `WorkoutPlanningService` ([App/Fernlet/WorkoutPlanningService.swift:12](../App/Fernlet/WorkoutPlanningService.swift))
  — the established place to add an AI workout feature; app target, imports `AIProviders`,
  `AIContext`, `FernletFoundation`, `HealthKitGateway`, reads store state through a narrow protocol.
  Note `adjustWorkoutDayPlan` only handles `.strength`/`.fullBody`/`.sport` (`:96`).

### 7.4 What already exists that must be superseded, not duplicated

`WorkoutProgram.progressedPrescription` (`:1112`) is the current deterministic rule — and its set
growth is **capped at +1 forever**: `let sets = baseSets + min(cycles / 2, 1)` (`:1119`) and
`baseSets + min(completions / 3, 1)` (`:1124`).

A load nudge **already ships to the user**: `WorkoutProgram.notes(...)` (`:1198`) emits
*"Week N — nudge the weight or reps up a little from last time."* at `:1209`.

Existing tests pin the behavior a redesign would change — `WorkoutProgramTests.swift:172`
`progressionClimbsRepsThenBumpsSets`, `:186`, `:93`, `:116`.

---

## 8. F7 — Deload detection

> **DEFERRED (owner decision D-C, 2026-07-24).** F7 is **not in the active build order** — it depends
> on F6 (which is itself deferred) and still has no defined output artifact. The survey content below
> is retained for later scoping.

**Re-labelled: UNSIZEABLE, not small.** It is the only one of the seven with no defined output
artifact, and its own verifier declared the survey unreliable and recommended re-surveying
`PlannedWorkout` and `TierTwoMemoryEngine` before any scoping. **Do not schedule this until §8.3 is
answered.**

### 8.1 What exists

`dailyTrainingLoad` ([DerivedSignalFactory.swift:228](../FernletKit/Sources/LocalPersistence/DerivedSignalFactory.swift))
is the only load formula: per day, sum over the first 12 workouts of
`round(minutes × intensityMultiplier × rpeMultiplier)`, where `minutes = max(duration ?? 30, 0)`,
intensity is light 0.75 / moderate 1.0 / hard 1.35, and RPE is clamped to `1...10` then divided by 7
(defaulting to 1). It **ignores `effort` entirely**, so activity-mode logs contribute no perceived-
effort signal at all.

`progressionTrend` (`:121`) splits the window at `count/2` and compares summed load: `"building"` at
≥1.20×, `"deloading"` at ≤0.70×, else `"steady"`.

`intensityReadiness` (`:84`) uses only the last `min(3, count)` day rows.
`FernletScoring.recoveryReadinessScore` ([Scoring.swift:180](../FernletKit/Sources/FernletScoring/Scoring.swift))
maps HRV/RHR/sleep to 0…1 and returns nil unless RHR or HRV is present.

### 8.2 Bugs and divergences found

- **`progressionTrend`'s denominator is `Double(max(olderLoad, 1))`, not `olderLoad`.** With zero
  load in the older half — common for a sparse window or a new user — *any* newer load ≥ 2
  classifies as `"building"`, and `"deloading"` becomes unreachable.
- **The sickness flag does not feed `intensityReadiness`**, contrary to spec line 319 (*"Sickness
  always forces `needs rest`"*).
- **The implemented signal vocabulary diverges from the spec's** across all five signals
  (`building`/`steady`/`deloading` vs `progressing`/`plateau`/`regressing`, etc.).
- **Splits never schedule rest days.** `rotationIndex` is `Calendar.current.component(.weekday,
  from: Date())` ([WorkoutPlanningService.swift:72](../App/Fernlet/WorkoutPlanningService.swift)), so a
  3-day split maps weekdays 1…7 onto indices 1,2,0,1,2,0,1 — the user is offered a session every
  calendar day.
- **`intensityReadiness` is never sent to any model**, contrary to spec §6a.
- **`DiaryStore.loadDays()` always injects today** (`:1018-1022`), so the window's last row is always
  the current day even when empty.

### 8.3 The undefined artifact

Nobody has said what a "lighter week" *is*. Fewer sessions has no representation (no rest-day
concept, `grep restDay` returns nothing). The `recoveryFlow` split exists but nothing selects it,
and `selectedSplitID` is user-owned synced state with no revert. Lower intensity is partly covered —
`WorkoutGoalStyle.adjustedSets` (`WorkoutProgram.swift:871`) already trims one set at `.light`,
floored at 2. Or it could be a week of reduced `PlannedWorkout` rows.

That last option is the missed lead: **`PlannedWorkout` already is a persisted, synced, forward-dated
workout prescription** (`WorkoutModels.swift:222`), with `DiaryStore.previousWeekPlannedWorkout(for:)`
(`:637-646`) and `copiedForwardWorkoutSplit(before:)` (`:625`) providing an existing week concept, and
`WorkoutPlanSource` (`:347`) providing `.user`/`.coach` provenance. `TierTwoMemoryEngine`
([LocalPersistence/TierTwoMemoryEngine.swift:22](../FernletKit/Sources/LocalPersistence/TierTwoMemoryEngine.swift))
is a second derived-insight engine over the same 14-day window that *does* persist, append-only and
change-triggered.

### 8.4 Delivery has no infrastructure

`NotificationService` exposes exactly one identifier, `fernlet.dailyCheckIn`, one repeating
`UNCalendarNotificationTrigger`, and nothing else — no categories, no generic one-shot API. Rate
limiting is ad hoc inside `settings.nutrientBubbleDismissedUntil`, which the gentle-offer feature
already piggybacks on under a reserved key. There is no shared nudge registry.

---

## 9. Cross-cutting prerequisites

### 9.1 STEP 0 — `SavedRecipeRecord` migration

Columns today ([FernletKit/Sources/CloudKitSync/Persistence.swift:355-372](../FernletKit/Sources/CloudKitSync/Persistence.swift)):
`idString`, `sourceURLString`, `name`, `ingredientsText`, `summary`, `servings`, `protein`, `carbs`,
`fat`, `micronutrientsJSON`, `savedAt`. `SavedRecipeMapping.recipe` hardcodes `ingredients: []`.

Migrate to the `idString + payloadData` JSON-blob shape used by every other row entity, with a
read-both-shapes path. This unblocks structured ingredients on web imports (F3, F4), a steps array
(F5), and synthesized recipes (D-A) in one change. Note `Persistence.swift` lives in the **walled
`CloudKitSync` module**, so this change requires a **wall check**.

> **NSPersistentCloudKitContainer constraint — additive-only (added 2026-07-24).** CloudKit's
> mirrored schema **cannot remove or retype a deployed attribute**. The migration must therefore be
> **strictly additive**: **add** a `payloadData` attribute alongside the existing typed columns;
> **readers prefer `payloadData` and fall back to the legacy columns** when it is absent; **never
> remove** the deployed legacy attributes. And because an **un-updated paired device keeps writing
> legacy-shape rows** (it has no `payloadData` writer), the **read-both / write-both transition must
> tolerate both shapes indefinitely** — there is no safe "flip the switch" cutover on a synced store.
> STEP 0c (the CloudKit **production** schema deploy) **precedes** this — the new `payloadData`
> attribute has to be deployed to the CloudKit prod environment before any device writes it.

### 9.2 STEP 0b — retry queue dispatch

Make `retryOldestMeal` dispatch on `payloadType` and scope the Food-page badge count to meals.
Cheap; stops silent data loss the first time a non-meal retry is enqueued.

### 9.3 STEP 0c — CloudKit schema deployment

No process exists. Establish one, and batch every Core Data change above into a single deploy.

### 9.4 Catalog regeneration cost

`FoodCatalog.sqlite` is **57 MB, committed to git, and not under LFS** (`.gitattributes` absent).
Every regeneration — for a nutrient column, a generated column, or a new index — rewrites the whole
file and adds ~57 MB to history. `ODRAssets/FoodCatalogBranded.sqlite` (364,457 rows, 177 MB) is
**gitignored** and its source is a ~3 GB USDA download with hard-coded scratch paths, so only the
base catalog is regenerable from the repo. **This is the strongest argument for F2's curated-table
design over a nutrient index.**

---

## 10. Regressions to avoid

- **Silent recipe-book pollution.** `MealBuilder.createRecipe` auto-mints a `RecipeDefinition` with
  hardcoded `servings: 1` and `source: "meal-log"` whenever a plan resolves to more than one
  ingredient, and `FernletStore.swift:1446` inserts it at index 0 of `diary.recipes`. Recipes are
  **uncapped and unpruned**. Any feature routing through the meal-resolution cascade inherits this —
  F1 makes it fire far more often.
- **Synced-blob growth.** `recipes` and `foodItems` are uncapped in `FernletSnapshot`, which
  serializes to a single `FernletDatabaseRecord.payloadData`. Days were split into per-row
  `DayRecord` precisely to escape that record's size ceiling. Adding steps to every recipe plus
  grocery-list metadata pushes the one record these features all touch back in the direction the
  day-split work moved away from.
  > **AS SHIPPED — WATCH ITEM (2026-07-25).** F5 steps DID land on the blob's `recipes` array for
  > manual/peer recipes (~160 B/step; a 15-step recipe ≈ +2.4 KB; safe per-row on `SavedRecipeRecord.payloadData`).
  > Accepted per §6.2 (both paths chosen knowingly). Two residual watch items, NOT defects but tracked:
  > (1) an un-updated paired device re-encoding the blob STRIPS unknown fields — for manual-recipe steps
  > that is real data loss, and there is no user-facing version-skew warning; (2) each F4 substitution
  > FORK duplicates a full recipe (ingredients + notes + steps) into the still-uncapped, unpruned
  > `recipes` array. A per-row escape for manual recipes should precede anything that raises recipe minting.
  > Also (INFO): `deleteAllData` clears the AI audit sink+actor without an epoch guard, so a rare in-flight
  > ambient completion finishing after the wipe can re-persist ONE metadata-only entry (kind/destination/
  > outcome — no user values); ring-capped and cleared by the next wipe. Left as accepted.
- **Wire compatibility.** Three features want to add recipe fields; none mentioned the mesh. See §6.3.
- **The 14-day window's per-save cost — corrected 2026-07-24.** `rebuildDerivedSignals()`
  ([FernletStore.swift:3344](../App/Fernlet/FernletStore.swift)) is
  `derivedSignalsService.rebuild(allDays: loadDays(), todayKey:)`, called from
  `handleAfterSnapshotSave` (`:3353`). ~~It costs a full-history disk read on every save.~~ It does
  **not** re-read history from disk on every save: the default CoreData backend serves a **warm memo
  patched in place** (`CoreDataFernletRepository.swift:211,224,530-537`, `invalidatesDayCache:false`).
  The **real** cost is (1) an **uncapped in-memory sort per save** and (2) a **full re-decode after
  each iCloud merge**. F2 and F7 both widen what this window must carry — **fix those two costs (the
  per-save sort and the post-merge re-decode) before widening it**, not a disk read that is already
  engineered away.
- **The share extension is a fifth recipe write path** crossing a process boundary
  (`App/FernletShareExtension/SharedRecipeImportQueueWriter.swift` → app-group queue → drained on launch
  and foreground). Any recipe-shape change must cover it.

---

## 11. Decisions (owner, resolved 2026-07-23)

The provider-ladder doc's five decisions are recorded in
[AI-Provider-Ladder §10](AI-Provider-Ladder-2026-07-23.md). The seven feature-level decisions were
resolved the same day:

1. **F2 cadence — as recommended.** 7-day window keeps the passive observation; the food-naming
   suggestion requires the 14-day window. Suggestions are rarer than observations.
2. **Reference tables — one shared FDA-seeded table; values verified and pinned in §3.6.** The
   verification confirmed the scanner's side of both disagreements: calcium 1,300 mg and potassium
   4,700 mg are the current FDA DVs, so `trackedNutrients` is the stale table and gets updated.
   Omega-3 is the one carve-out — FDA has no omega-3/ALA DV; keep 1.6 g annotated as the NASEM AI.
   Missing ULs handled by curation of the good-sources table, not a UL engine.
3. **F3 — weekly planner + push to Notes. Re-labelled MEDIUM.** The user selects recipes for the
   week in a planner-like view, then generates one consolidated shopping list from the selection.
   Delivery is the share sheet with Notes as the primary target — there is **no public API that
   writes directly into Apple Notes**, so the share sheet *is* the push-to-Notes mechanism.
   Reminders via EventKit stays the optional secondary target. Design in §4.4.
4. **F4 provenance — as recommended.** Scaling is a non-persisted view/share-time transform;
   substitution forks a new recipe carrying a `parentRecipeID`.
5. **F1 servings — as recommended.** The review sheet carries an editable yield defaulting from the
   model's `servingsHint` (falling back to the dish template, then 4); the auto-mint's hardcoded
   `servings: 1` changes in the same commit.
6. **F5 — button + Siri navigation, timer demoted, mise-en-place opener.** Steps schema stays
   `RecipeStep {text, durationSeconds?}`, but navigation is an explicit Next button plus a
   Siri/App-Intents path — the timer never advances anything; it surfaces the Next button. Cooking
   mode opens with an ingredients-and-amounts screen. Interaction model in §6.4.
7. **F7 — as recommended.** Deferred until F6's per-set record exists; leading artifact is a week
   of reduced `PlannedWorkout` rows — the only persisted, synced, forward-dated prescription in
   the app.
   > **Superseded 2026-07-24 (D-C):** **both F6 and F7 are now DEFERRED** — not just F7-after-F6.
   > F6 awaits a spec-level go/no-go (the per-set record is the closest thing to the optimization
   > framing the spec rejects; see §7's banner), and F7 stays behind it. Neither is in the active
   > build order (§1).
