# Fernlet Localization Plan — Spanish, French, German

**Date:** 2026-07-19 · **Status:** **Phase 0 SHIPPED 2026-08-19** (branch
`claude/localization-phase0`); Phases 1–5 still planned only. Grounded in a two-agent code audit of
`main` (2026-07-19); every claim below carries file:line evidence from that audit — see the
Phase 0 section for where the tree has since moved.
**Scope:** `es`, `fr`, `de` as the first localization wave, `en` stays the development language.
All three are inside Apple Intelligence's supported language set (on-device AI keeps working) and
all three are fully covered by the app's existing Latin fonts — the two facts that make this the
cheapest possible first wave.

**Explicitly out of scope:** CJK, Arabic/Hebrew (RTL), Thai, and other non-Latin scripts. They
additionally require new fonts (the serif identity faces — Fraunces / DM Serif Display /
Instrument Serif, `App/Fernlet/FernletDesignSystem.swift:37-64` — are Latin-only), FTS tokenizer work
(no CJK word segmentation in `unicode61`), and realistically regional food data. Separate project.

---

## 0. The two design rules everything hangs on

1. **Stable English tokens; localized display only.** Persisted enum `rawValue`s (the
   `EnumDecodeCompat` freeze/park machinery), mesh wire formats, AI prompt vocabulary, and the
   grep-wall all depend on stable English tokens. Localization must ONLY touch display-layer
   strings. The codebase already separates `rawValue` from `displayName` almost everywhere — the
   conversion is "swap display props to `String(localized:)`", never "translate a raw value."
   The audit found four places where a *display* string currently leaks into *logic or prompts*;
   those must be forked into token + display first (§3.4).
2. **Safety content keys on REGION, not language.** A German speaker in the US must see 988; an
   American in Spain must see 024. Crisis resources (§2.2) gate on `Locale.current.region`,
   translations gate on language.

---

## 1. Current state (audit summary)

Localization scaffolding is **zero**: no `.xcstrings`/`.strings`/`.lproj` anywhere; no
`NSLocalizedString`/`String(localized:)`/`LocalizedStringKey` usage; pbxproj
`knownRegions = (en, Base)` (`project.pbxproj:437-440`); `FernletKit/Package.swift` has no
`defaultLocalization`; `Bundle.module` appears only in a comment. The only localization-ready API
surface is `LocalizedStringResource` on the App Intents (`FernletAppIntents.swift:14,52,64`,
`App/FernletWidgets/WaterPlusOneIntent.swift:14`, `GuidedWorkoutLiveActivityIntents.swift:19,32`).

What is already safe (do not touch):

- **Day keys** — `FernletDate.swift:11-16` pins `en_US_POSIX` + Gregorian (mirrored in
  `ClosenessLedger.swift:102-115`, `WidgetSharedModels.swift:80-83`). No Buddhist/Japanese
  calendar corruption risk.
- **Matching logic case transforms** use locale-independent `.lowercased()` (not
  `.localizedLowercase`) — no Turkish-İ hazard (`ActivityTypeCatalog.swift:13-14`, etc.).
- **schema.org JSON-LD extraction** in the recipe/product importers is language-neutral
  (`RecipeWebImporter.swift:293-375`, `FoodProductWebImporter.swift:391-439`), as are numeric
  **barcodes**.

---

## 2. Phase 0 — Locale-correctness fixes (ship regardless of translation)

These are live bugs for non-US users **today, in English**.

> **DONE — 2026-08-19.** All four sub-sections below are implemented on
> `claude/localization-phase0`, with `LocaleTolerantNumberTests` (26 cases) and
> `LocaleCorrectnessTests` (month grid, crisis table, body units). Scanners clean
> (power-of-10 0 violations, doc coverage 0 undocumented), S3 wall check passed, owning suites
> green, and both the crisis row and the Monday-first grid verified on the simulator under
> `de_DE`. What the tree had already moved on from since the July audit:
>
> - **The three calendar grids are now one file.** `ContentView`/`JournalView`/`PeriodTrackerView`
>   were consolidated into `MonthCalendarCard.swift`'s `MonthGridModel`, so §2.1 was one fix, not
>   three. `MoveView`'s week strip and `GroceryPlannerView` use `dateInterval(of: .weekOfYear:)`,
>   which already honours `firstWeekday` — no bug there.
> - **Some decimal-comma sites had been fixed ad hoc**, each with its own
>   `replacingOccurrences(of: ",", with: ".")`. Those are now the shared parser too, so the rule
>   lives in one place.
> - **§2.4 was backwards, and worse than described.** The profile stores `weightPounds` /
>   `heightInches` (`weightKilograms` is a computed read-only view), and *both* editors —
>   onboarding and Settings' `ProfileEditor` — offered pounds and feet/inches only. A metric user
>   had no way to enter their own body at all, and those numbers feed the BMR behind every
>   nutrition target.
> - **One silent-corruption bug the audit did not predict.** `TrainerExportBuilder`'s load regex
>   matched `.` only, so a German user's `62,5 kg` did not fail visibly — the engine resumed at the
>   `5` and exported a **5 kg** lift to their coach.
> - **`EquipmentIcons.swift` was deliberately left alone.** The audit filed it under §2.3, but it
>   is an SVG path-data parser over app-authored strings, where `.` is mandated by the SVG spec;
>   making it locale-tolerant would be a bug, not a fix.
>
> Still open from Phase 0: **D-L5** — the hotline table below is safety copy and wants owner
> sign-off. The shipped table covers US, CA, GB, IE, ES, FR, DE, AU, NZ (each verified against the
> operator's own page in August 2026) and falls back to "local emergency services" with **no
> number** everywhere else.

### 2.1 Monday-first calendar grids
`ContentView.swift:1351-1361`, `JournalView.swift:663-675`, `PeriodTrackerView.swift:486-492` all
compute leading blanks as `firstWeekday - 1` and render headers from `veryShortWeekdaySymbols`
(always Sunday-indexed) — every Monday-first locale (all of es/fr/de) gets a misaligned month
grid. Fix: one shared helper — `blanks = (weekdayOfFirst - calendar.firstWeekday + 7) % 7`, and
rotate the symbol array by `calendar.firstWeekday - 1`. Three call sites, one unit test per
edge (Sunday-first, Monday-first, Saturday-first).

### 2.2 Region-keyed crisis resources
`FirstAidView.swift:181-189` hardcodes `tel:988` / `sms:988` (US/Canada only). Replace with a
small `CrisisResource` table keyed on `Locale.current.region`:

| Region | Resource | Actions |
| --- | --- | --- |
| US, CA | 988 Suicide & Crisis Lifeline | call 988 · text 988 |
| ES | Línea 024 de atención a la conducta suicida | call 024 |
| FR | 3114 — numéro national de prévention du suicide | call 3114 |
| DE | TelefonSeelsorge | call 0800 111 0 111 · 0800 111 0 222 (also 116 123) |
| GB | Samaritans | call 116 123 |
| fallback | "Contact your local emergency services" + no dead tel: link | — |

The fallback must never render a US number in a region where it doesn't work. **D-L5:** the final
hotline list is safety copy — user signs off before ship. The privacy-policy footer's "in the US,
call or text 988" line gets the same region treatment when the policy is localized (§6.3).

### 2.3 Decimal-comma input
Mostly handled (`JournalView.swift:1430`, `LogPeriodSheet.swift:215` already normalize `,`→`.`).
Two gaps: the deterministic quantity parser uses bare `Double(token)`
(`FoundationFoodSelection.swift:169-174`, `DishTemplateLexicon.swift:193-196`) — "2,5" fails for
every es/fr/de user; and `EquipmentIcons.swift:383-390` hand-rolls a dot-only parser (low risk,
app-generated input). Fix: one shared locale-tolerant number parser (accept both `.` and `,`,
prefer the locale's separator on ambiguity) used by all free-text quantity paths.

### 2.4 Units
- **Body weight** is stored and entered as `weightKilograms` (`NutritionModels.swift:1627`) with
  no imperial UI — irrelevant for es/fr/de (metric), but fix alongside: honor
  `Locale.current.measurementSystem` at the entry/display boundary (kg ↔ lb), storage stays kg.
  Precedent already in the codebase: `LogPeriodSheet.swift:31` does exactly this for °C/°F.
- **Energy stays kcal** — standard in Spain, France, and Germany; no kJ work in this wave.
- Hardcoded "g"/"kcal" *labels* (`ActivityPickerSection.swift:134`, `HomeView.swift:1978`,
  `JournalView.swift:832-835`) localize as ordinary strings in Phase 1 (the words barely change:
  g/kcal are universal; "cal" shorthand becomes "kcal" in de/fr copy).

---

## 3. Phase 1 — String-catalog scaffolding & token/display separation

### 3.1 Project plumbing
- `Localizable.xcstrings` in each of the three UI targets: **Fernlet** (app),
  **FernletWidgets** (≈33 strings: `WorkoutLiveActivity.swift:46-228`, intent titles),
  **FernletShareExtension** (2 error strings, `ShareViewController.swift:87`,
  `SharedRecipeImportQueueWriter.swift:90`). Synced folder groups make file adding trivial
  ([[fernlet-xcode16-synced-folder-groups]]); `InfoPlist.xcstrings` for bundle-visible plist strings.
- pbxproj `knownRegions` → `(en, es, fr, de, Base)`.
- `FernletKit/Package.swift`: add `defaultLocalization: "en"`, then one `Localizable.xcstrings`
  per string-bearing target, with `String(localized:bundle:.module)` lookups. String-bearing
  modules (audit counts): **FernletDomainModel** (~286 display strings — the dominant surface:
  `WorkoutProgram.swift` ~164 exercise names/cues, `WorkoutModels.swift` 34,
  `WellbeingModels.swift` 29, `NutritionModels.swift` 17, `NavigationEnums.swift` 16, plus
  Settings/Companion/Moderation), **FernletScoring** (`Scoring.swift:394-503` fallback names +
  provenance strings), **PrivateHealthStore** (cycle symptom labels,
  `MenstrualNarrativeRepository.swift:123`), **AppServices** (`NotificationService.swift:38-39`
  notification copy), **AIProviders** (recipe-import prose). CloudKitSync's literals are entity
  names/logs — excluded.
- **Clean-build hazard:** every FernletDomainModel pass ends with a *clean* build
  ([[fernlet-domainmodel-clean-build-hazard]]).

### 3.2 Extraction mechanics
SwiftUI `Text("…")` literals auto-extract into the catalog at build time once it exists. All
non-`Text` strings (the SPM display props, ambient-card copy `AmbientCards.swift:78-379`,
milestone copy `MilestonesView.swift:382-420`, App-Intent dialogs `FernletAppIntents.swift:40,47`)
convert to `String(localized:)` explicitly. Verify early that `xcodebuild` populates the catalog
the same way Xcode does; if not, extraction runs through Xcode once per pass.

### 3.3 Siri / App Shortcuts
`FernletShortcuts.swift:8-34` phrases must gain per-language variants (`AppShortcutsProvider`
phrases are matched literally per locale — untranslated phrases simply never trigger in es/fr/de).

### 3.4 The four token/display forks (do BEFORE any translation)
Display strings that currently feed logic or AI prompts — fork each into a stable English token
(model/logic-facing) + a localized display property:

1. `SleepQuality.label` / `description` (`WellbeingModels.swift:365-373`) — feeds FM prompts via
   derived signals.
2. `FeelingTag.label = rawValue.capitalized` (`WellbeingModels.swift:329-334`) — feeds prompts;
   `.capitalized` on a rawValue can't localize anyway.
3. `WorkoutExerciseCatalog` matching by lowercased English `name`
   (`WorkoutModels.swift:814-817`, `WorkoutRestGuidance.swift:137-144`) — switch matching to
   catalog IDs / canonical English names; localized names become display-only aliases (**D-L2**).
4. `DerivedSignal` values ("low"/"rising"/"needs gentleness", `DerivedSignalFactory.swift:40-156`)
   — consumed by both the English fallback text and FM prompts; keep tokens English, render
   localized at display.

Also: `MuscleGroup.fromLegacyString` (`WorkoutModels.swift:527-545`) and `DishTemplates.json` keys
stay English forever — they parse historical/persisted data, not UI.

---

## 4. Phase 2 — Translation pass (es / fr / de)

- **Volume:** ~1,000+ keys app-wide once extraction runs (286 domain + ~hundreds of view
  literals + widgets + intents + notifications).
- **Workflow:** machine-draft (the FM/LLM draft is fine) → **native-speaker review before ship**,
  prioritized: safety & crisis copy > period/intimacy flows > notifications (appear on the lock
  screen) > everything else.
- **Voice:** Fernlet's register is gentle, lower-case-hearted, non-clinical. A half-page tone
  guide per language prevents the classic "translated app" stiffness.
- **D-L1 — formality:** recommend informal address in all three (tú / tu / du) — consistent with
  the companion's voice and current wellness-app convention in all three markets. Decide once,
  apply everywhere; German especially cannot mix du/Sie.
- **German expansion QA:** German runs ~30% longer. Audit the narrow surfaces — Live Activity /
  Dynamic Island (`WorkoutLiveActivity.swift`), widget rows, goal-preset cards, stat chips — with
  pseudolocalization or de translations early, not last.
- **UI tests stay green:** the suite runs in `en` by default, so the ~181 English string
  assertions across 20 `FernletUITests` files keep passing. Localized-run testing is Phase 5.

---

## 5. Phase 3 — Language-sensitive engines

### 5.1 On-device AI (7 Foundation Models call sites)
`SystemLanguageModel` availability is checked, but `supportedLanguages` is checked **nowhere**
(0 hits repo-wide), and no prompt instructs an output language. Work:

- One central helper: *is the user's language both FM-supported and app-supported?* Gate AI
  features per-language; unsupported → the deterministic fallbacks (the architecture's whole
  point). es/fr/de are all FM-supported, so in this wave the gate exists mostly as correctness.
- Per call site (audit table): meal candidate-select (`FoundationFoodSelection.swift:36-49`),
  dish decomposition (`FoundationDishDecomposition.swift:31-51`), workout adjuster
  (`FoundationWorkoutAdjustment.swift:95-111`), recipe import (`RecipeWebImporter.swift:230-234`),
  product import (`FoodProductWebImporter.swift:583-588`), day summary
  (`LaunchPreparationService.swift:283-291`), companion thought (`:325-333`).
  - Prompts that produce **user-visible prose** (day summary, companion thought, journal
    reflection, adjuster notes): add "Respond in {language}" from the app locale.
  - Prompts that produce **catalog-matching output** (dish decomposition, candidate select):
    instruct "input may be in {language}; emit food component names in English" — this makes the
    AI path translate user food text onto the English catalog essentially for free, and is the
    main reason food search keeps working before Phase 4 data lands.
- **Fallback copy localizes as strings** (`deterministicThought` hardcoded sentences,
  `LaunchPreparationService.swift:226-243`; `Scoring.swift` fallback workout names).

### 5.2 Deterministic food parsing
- **Unit vocabulary** — extend `RecipeUnit.normalized` (`NutritionModels.swift:1164-1187`) and its
  duplicates (`FoundationFoodSelection.swift:237-261`, `RecipeWebImporter.swift:431,477-490`) with
  es (taza, vaso, cucharada/cda., cucharadita/cdta., gramos, pieza), fr (tasse, verre, cuillère à
  soupe/c. à s., cuillère à café/c. à c., grammes, tranche), de (Tasse, Becher, EL, TL, Prise,
  Gramm, Stück, Scheibe). Consolidate the three copies into one table while touching them.
- **Connectors** — `MealItemSplitter` (`NutritionModels.swift:956-978`): add y/e, et, und, mit,
  avec, con.
- **Plural/stem rules** (`FoodItemSearch.swift:312-331`): es (-s/-es), fr (-s/-x) are cheap; German
  plurals are irregular — skip stemming for de and rely on aliases (§5.3) instead.
- **Keyword macro estimator** (`Scoring.swift:424-456`) and `classifyMealType` (`:400-412`): add
  bounded starter word lists per language (~50 words each); accept that this last-resort tier
  stays weakest.

### 5.3 Food search bridge (pre-Phase-4): the alias layer
Until localized catalogs exist, a per-language alias table maps common food words → English
catalog tokens before the FTS query (`BundledFoodStore.swift:176-212`): "hähnchen"→chicken,
"fromage"→cheese, "arroz"→rice… (~150–250 entries per language, curated). Token-level
substitution at query time; no DB rebuild; the FTS `tags` column stays untouched. This +
§5.1's AI translation covers the search experience until real localized data ships.

### 5.4 Text filters — the honesty items
- `DiagnosticLanguage.patterns` is English-only (`DiagnosticLanguage.swift:15-23`; its own doc
  admits foreign terms evade it, `:32`) — and the privacy policy **claims** clinical-language
  filtering. Shipping es/fr/de without per-language term lists makes that claim false. Add
  es/fr/de clinical-term lists (bounded, ~30–50 patterns each) in the same normalized-substring
  style.
- `ItemNameModeration.blockedTerms` is explicitly "English-only for v1"
  (`ItemNameModeration.swift:15,26-31`) — add es/fr/de lists (the homoglyph/leetspeak folding
  `:72-87` is language-neutral and reusable).

---

## 6. Phase 4 — Regional food data packs (the "USDA equivalents" answer)

**Question asked:** do other-language equivalents of the USDA data exist, and can the app download
the right one per system language? **Answer: yes, for exactly these three languages, and the
download mechanism the app already uses (On-Demand Resources) is the right delivery channel.**
No true 1:1 USDA twin exists anywhere (nothing else is 68k foods with rich portions), but the
national tables are real, free, and good:

| Source | Lang | Foods | Components | License / cost | Notes |
| --- | --- | --- | --- | --- | --- |
| USDA FDC (current) | en | ~68k | rich + portions | public domain | ships today (`FoodCatalog.sqlite`) |
| **CIQUAL 2025** (ANSES, France) | fr **+ en names** | ~3,484 | 74 incl. micros | **open data, free** | English name per food = easy QA/cross-map |
| **BLS 4.0** (MRI, Germany) | de | ~14k | very rich | **free since 4.0** (was ~€100+/seat) | the best non-US table; **verify redistribution terms for in-app embedding (D-L3)** |
| **BEDCA** (AESAN, Spain) | es | ~1k | EuroFIR-standard | free, usage conditions PDF | thin — pair with alias layer + USDA fallback |
| CNF 2015/2026 (Health Canada) | en + fr | ~5.7k | USDA-like | Crown open license | bilingual French names on USDA-style entries — auxiliary fr-name source |
| OpenFoodFacts | multi | ~3M branded | variable | ODbL (share-alike) | later, for international **barcodes** (the USDA branded DB is US-only) |

### Architecture
1. **Per-source importers** in the existing `FoodCatalogDatabaseBuilder` pipeline compile each
   national table into the **same `FoodCatalog.sqlite` schema** (per-100 g + FTS5 `unicode61`).
   FTS then works natively in the pack's language — no aliases needed for pack-covered foods.
2. **Namespaced IDs** (`ciqual:12345`, `bls:B123400`) so pack items can never collide with FDC
   ids. Logged meals denormalize their macros at log time, so past history survives a language
   switch either way — verify this holds for every logging path before shipping packs.
3. **Delivery: On-Demand Resources, one tag per language pack** (`food-catalog-fr`, `-de`, `-es`)
   — Apple-hosted, so it honors "no servers anyone operates," and the mechanism already exists:
   `BrandedCatalogResourceLoader.swift:4-27` does exactly this for the 364k-product branded DB.
   Request the pack matching the system language on first use; sizes are small (CIQUAL/BEDCA a
   few MB; BLS maybe ~10–15 MB).
4. **Attach as an additional source** via the existing multi-source seam
   (`BundledFoodStore.swift:29-34, 235-240` attaches the branded DB as a secondary source today).
   Locale pack ranks first for generic foods in that locale; USDA stays as fallback (English
   queries, recipes, AI-translated component names).
5. **Portions:** the national tables are mostly per-100 g with thin household-portion data —
   fine in practice, because es/fr/de food culture logs in grams; default those locales to
   gram-first entry.

### Sequencing
- **v1 (this plan's ship line):** alias layer (§5.3) + AI translation bridge (§5.1) over the
  existing USDA catalog. Search works in all three languages with zero data dependencies.
- **v2:** CIQUAL (fr) and BLS (de) packs — both big enough to be the primary generic catalog for
  their locale; BEDCA (es) pack + retained alias layer (BEDCA alone is too thin).
- OpenFoodFacts for non-US barcodes is its own later effort (ODbL obligations + pipeline).

---

## 7. Phase 5 — QA & release

- **Pseudolocalization + de-expansion pass** over the narrow surfaces (Live Activity, widgets,
  preset cards) before translation review.
- **Localized UI runs:** rewrite the ~181 English `staticTexts[…]` assertions across 20
  `FernletUITests` files to accessibility identifiers (many views already carry ids, e.g.
  `FirstAidView.swift:166`), then run the appearance suite per locale via `-AppleLanguages`.
- **Per-locale screenshot gallery** — the existing UX appearance harness
  ([[ux-appearance-test-harness]]) already produces galleries; parameterize by locale.
- **App Store:** localized metadata, keywords, screenshots for es/fr/de storefronts.
- **Privacy policy (D-L4):** translate `Docs/Privacy-Policy.md` + `PrivacyPolicyView.swift` copy
  per language with review (legal text — machine draft is not enough); until then the English
  policy ships in all storefronts (common indie practice, GDPR-tolerable, not ideal).

---

## 8. Open decisions

| # | Decision | Status |
| --- | --- | --- |
| D-L1 | Formality of address | **DECIDED 2026-07-19:** informal (tú / tu / du) everywhere, consistent with the companion voice. |
| D-L2 | Localize exercise names? | **DECIDED 2026-07-19:** localize display names; matching/tokens stay canonical English via catalog IDs (§3.4-3). English terms kept as searchable aliases. |
| D-L3 | Regional data packs go/no-go | OPEN — do v1 aliases first; green-light CIQUAL/BLS packs after verifying BLS 4.0 redistribution terms for in-app embedding and confirming pack-vs-USDA ranking UX. |
| D-L4 | Privacy-policy translation timing | **DECIDED 2026-07-19:** ship English policy with wave 1; translated+reviewed policies as fast-follow. |
| D-L5 | Crisis-resource table | OPEN — implemented 2026-08-19 in `CrisisResources.swift` (US, CA, GB, IE, ES, FR, DE, AU, NZ + no-number fallback), each number verified against the operator's own page. Owner still signs off the list before ship. |

## 9. Suggested execution order & rough effort

1. ~~**Phase 0** (locale bugs) — small, self-contained, testable; ship first. *Days.*~~ **DONE
   2026-08-19** — see the note in §2.
2. **Phase 1** (scaffolding + token/display forks) — mechanical but wide; the §3.4 forks are the
   only genuinely delicate part. *Days, plus a clean-build + full-suite gate.*
3. **Phase 3** (engines) — the AI output-language + English-component instruction and the unit
   vocabulary are the highest-value items; alias layer after. *Days.*
4. **Phase 2** (translations) — pipelined with native review. *Calendar time dominated by review.*
5. **Phase 5** QA per locale; **Phase 4 v2** (data packs) as its own follow-on project.

**Testing spine:** unit tests for the calendar helper, number parser, unit tables, alias
substitution, and region-gated crisis table; snapshot/appearance runs per locale; the full
`FernletTests` suite in batches ([[run-fernlet-tests-in-batches]]) at each phase end; a clean
build after every FernletDomainModel pass.
