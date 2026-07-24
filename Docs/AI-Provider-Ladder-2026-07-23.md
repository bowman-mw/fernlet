# AI Provider Ladder & Deep AI Features — 2026-07-23

Plan for raising Fernlet's AI ceiling on two features (recipe creation, workout suggestions) by
adding a routed provider ladder underneath the existing on-device path.

**Status:** planned, not started. Supersedes the OHTTP design in
[FernletSpecificationV3 §17](FernletSpecificationV3.md) for the third-party tier (see §8).

**Revised 2026-07-24** — post-audit revision (99-agent verification pass against Fernlet @ `1ecc8a8`)
plus four owner decisions (D-A recipe store, D-B PCC consent, D-C F6/F7 deferral, D-D two-adapter
BYOK scope). Superseded claims are struck through / marked "superseded 2026-07-24" in place so the
history stays legible.

**Companion:** [AI-Feature-Expansion-2026-07-23.md](AI-Feature-Expansion-2026-07-23.md) scopes seven
further features that ride this ladder (photo→recipe, micronutrient gap suggestions, grocery list,
recipe scaling/substitution, cooking mode, progressive overload, deload detection), with a verified
build order and the cross-cutting prerequisites they share.

---

## 1. Decision

Four destinations, in escalation order. The letters match the option survey they came from.

| | Destination | User setup | Cost to user | Cost to Fernlet | Data leaves device |
| --- | --- | --- | --- | --- | --- |
| **A** | On-device Foundation Models (today) | none | none | none | no |
| **B** | On-device, iOS 27 model (larger, multimodal) | OS update | none | none | no |
| **C** | **Private Cloud Compute** — the default deep tier (first-use consent, D-B) | **one-time consent sheet** | **none** | none under 2M first-time downloads | Apple PCC only, after explicit consent |
| **F** | BYOK — Claude (native) **or** a custom OpenAI-compatible endpoint (D-D) | paste a key | per-token (theirs) | none | yes, to their chosen provider |

> ~~**F** | BYOK — Claude, GPT, Gemini, Kimi~~ — **superseded 2026-07-24 (D-D):** BYOK collapses to
> exactly two adapters — Claude via Anthropic's native `LanguageModel` package, plus one
> OpenAI-compatible custom-endpoint adapter that covers GPT, Kimi, and local servers for advanced
> users. The Google/Gemini native package and the per-vendor picker matrix are dropped.

**A and B are the floor. C is the new default for deep work, gated behind a one-time first-use
consent sheet that names Apple Private Cloud Compute (D-B) — PCC is not implied by the general AI
toggle. F is opt-in for users who want a frontier model and are willing to pay for it.** Nothing
here changes the rule that every AI feature has a deterministic fallback.

Not adopted: Fernlet-funded API key (recurring cost against a permanently-free app), remote MCP
connector (requires a server), copy/paste handoff (per-use friction).

---

## 2. Architecture: one protocol, four backends

iOS 27's Foundation Models framework exposes a `LanguageModel` protocol. Apple ships
`PrivateCloudComputeLanguageModel`; Anthropic publishes a conforming Swift package; everything
downstream of `LanguageModelSession` is unchanged. That gives us one call shape for all destinations:

```swift
let model = try FernletModelRouter.resolve(for: task, settings: settings)
let session = LanguageModelSession(model: model, instructions: instructions)
```

> **iOS-version caveat (revised 2026-07-24):** ~~iOS 26.4/27~~ these are **iOS 27 (WWDC26)** APIs —
> the `LanguageModel` protocol, `PrivateCloudComputeLanguageModel`, and the vendor packages ship in
> iOS 27, in **beta until ~Sept 2026 (GA), and the surface may still change**. "iOS 26.4" does not
> exist. **Every availability gate must be `#available(iOS 27, *)`** — an iOS-26 gate would resolve
> TRUE on devices that lack these symbols and crash on the unresolved reference. No cloud tier can
> ship to users above the on-device floor until iOS 27 GA; the on-device increment 1 stands alone
> before then (see the build order).

**Two adapters cover BYOK (D-D):**

| Provider | Adapter | Notes |
| --- | --- | --- |
| Claude | Anthropic's native `LanguageModel` Swift package | native, least work; the default BYOK provider |
| GPT / Kimi / local servers | `OpenAICompatibleLanguageModel` (ours) | one custom-endpoint adapter, `/v1/models`, `/v1/chat/completions`, user-supplied base URL |

> ~~Gemini | Google's `LanguageModel` Swift package~~ — **superseded 2026-07-24 (D-D):** the
> Google/Gemini native package is dropped. The OpenAI-compatible adapter is the same bet Xcode makes
> for third-party chat providers and covers GPT, Kimi (Moonshot base URL), and local servers
> (Ollama, LM Studio) — subject to the ATS/host requirements in §6.1. The adapter is **real
> conformance work via the `LanguageModelExecutor` path, not a thin shim** — it must map the
> `LanguageModel` request/response and streaming contract onto `/v1/chat/completions` itself.

### `AIDestination` grows

[AIDestination.swift](../FernletKit/Sources/FernletDomainModel/AIDestination.swift) currently has two
cases. New shape:

```swift
public enum AIDestination: String, Codable, Sendable {
    case onDeviceFoundationModels
    case webNutritionLookup
    case privateCloudCompute
    case externalAnthropic
    case externalOpenAICompatible   // GPT, Kimi, local servers — the single custom-endpoint adapter (D-D)
}
```

> Revised 2026-07-24 (D-D): the `externalOpenAI` / `externalGoogle` / `externalMoonshot` split is
> collapsed to one `externalOpenAICompatible` case (the endpoint host distinguishes GPT vs Kimi vs a
> local server); the Google case is dropped.

This is a `FernletDomainModel` enum that lands in the audit log, so it is a brick-vector site —
follow the `EnumDecodeCompat` freeze/park pattern established in the UI/UX branch review. **Adding
these cases needs a clean build**: incremental builds mask non-exhaustive-switch errors on
`FernletDomainModel` enums and can ship a layout-corrupted binary (the documented clean-build
hazard). Land the case additions *with* the audit-log persistence, not before.

---

## 3. Routing and handoff

### 3.1 Capability tiers

Every AI task declares the minimum tier it needs. The router picks the *cheapest available*
destination meeting that tier, never higher than the user's configured ceiling.

```swift
public enum AICapabilityTier { case light, standard, deep }
```

| Tier | Tasks | Preferred destination |
| --- | --- | --- |
| `light` | journal emotion tags, tone wrapper, thought bubbles, diagnostic-language classifier | on-device only |
| `standard` | meal decomposition, food selection, workout adjustment, day summary | on-device → PCC |
| `deep` | **recipe synthesis**, **workout program personalization** | PCC → BYOK (if configured) |

`light` never escalates. Sensitive-adjacent work (journal, memory) stays pinned on-device
regardless of settings — that is a hard rule, not a default.

### 3.2 Resolution order

For a task at tier `T`:

1. `settings.aiStatus == .off` → deterministic fallback. Stop.
2. `aiStatus == .resting` (rate-limited or ≥60 calls today) → deterministic fallback. Stop.
3. `aiStatus == .sleepy` (≥30 calls today) → non-essential tasks take the fallback; `deep` tasks
   the user explicitly invoked still run.
4. Resolve the preferred destination for `T`, capped by device capability (§10.1), the user's
   ceiling, and per-feature opt-in.
5. On unavailable / error / timeout / schema-validation failure → **step down one rung**, retry once.
   **But a content-refusal is not a step-down trigger** (see below).
6. All rungs exhausted → deterministic fallback with a Fernlet-voice notice.

Escalation is downward only. The router never silently promotes a task to a destination the user
did not enable, and never sends a `light` payload off-device.

> **The 30/60-call budget and `.sleepy`/`.resting` are NET-NEW work (revised 2026-07-24).** The
> `.sleepy`/`.resting` enum cases exist but are **never assigned** — the only writes are the decode
> (`SettingsModel.swift:237`) and the `.off`/`.ready` toggle (`SettingsSheet.swift:1191`), and they
> are read only by the label switch (`:594-595`). **No call counter exists anywhere in the
> codebase.** Steps 2–3 above therefore require building the whole quota mechanism first: a
> **local, non-synced day counter** (it must NOT ride the synced blob), a midnight reset, and the
> state derivation that assigns `.sleepy`/`.resting`. This is scheduled in the provider-seam step of
> the build order (§9), not assumed.
>
> **BYOK spend guard (net-new, required before BYOK ships).** BYOK spends real money on the user's
> own key, and there is **no per-day cap, no per-destination cap, no confirm-before-call, and no
> wifi-only gating today** (no `NWPathMonitor` / `isExpensive` / `allowsCellularAccess` exists in app
> networking). BYOK must add: a **per-day and per-destination call cap**, a **confirm-before-call
> affordance for the deep tier on BYOK**, and a **wifi-only option**. A retry storm or heavy use must
> not be able to silently bill the user.
>
> **Per-provider schema-failure detection (revised 2026-07-24).** Step 5's "step down on
> schema-validation failure" only fires on providers that hard-enforce the schema. Anthropic and
> hosted OpenAI hard-enforce; **plain OpenAI-compatible servers reachable through the custom endpoint
> (non-K3 Kimi, Ollama, LM Studio) do JSON-mode only** with no schema enforcement. On those, the
> model returns *parseable* JSON with omitted fields, which Fernlet's tolerant `decodeIfPresent` /
> `EnumDecodeCompat` accepts as success — so the step-down never fires and the user gets a silently
> half-populated recipe. The router needs an **explicit required-field completeness check after
> decode**, not a reliance on the decoder throwing. (Context: Gemini's `responseSchema` is likewise
> only soft/best-effort — one of the reasons the native Gemini adapter was dropped under D-D; it is
> out of scope, but a user pointing the custom endpoint at a Gemini-compatible gateway would hit the
> same soft-schema problem.)
>
> **Content-refusal must NOT step down to another vendor (revised 2026-07-24).** A provider safety
> refusal is a *privacy event*: re-sending the same health-adjacent data to a different company on
> refusal would leak it further. A refusal **terminates to the deterministic fallback** with the
> Fernlet-voice notice — it never escalates or side-steps to another destination. Note the shipped
> fallback-voice bank is **5 generic strings** (`Scoring.swift:5-26`) with **no "refused" copy** yet;
> a refused-notice string must be added (the spec forbids surfacing the raw provider refusal).

### 3.3 The handoff invariant

This is the load-bearing rule for both features:

> **Models propose. Deterministic code binds, computes, and enforces safety.**

A model may never emit a nutrition number, a macro total, or an exercise the safety filter has not
seen. It selects from numbered candidates supplied by local data, exactly as
[FoundationFoodSelection.swift](../FernletKit/Sources/AIProviders/FoundationFoodSelection.swift) and
[FoundationWorkoutAdjustment.swift](../FernletKit/Sources/AIProviders/FoundationWorkoutAdjustment.swift)
already do via `FoodSelectionCandidate.promptLine` and `WorkoutAdjustmentCandidate.promptLine`.

That invariant is what makes it safe to send a stage to a frontier cloud model: the cloud model
contributes *world knowledge* (what goes in a meatloaf, how to periodize a push day), while
*numbers* come from `FoodCatalog` and the exercise library. A hallucinated ingredient name fails to
bind and drops out; it cannot become a calorie count.

### 3.4 Multi-model pipelines

Stages within one feature may run on different destinations. The router is per-stage, not
per-feature.

---

## 4. Feature 1 — Recipe creation from a plain meal description

**Trigger:** user logs "meatloaf and mashed potatoes" and taps *Build recipe* (or the food review
gate offers it when a description decomposes into a dish name rather than ingredients).

**Outcome:** a `RecipeDefinition` in the recipe book with catalog-bound ingredients, real macros
and micronutrients, an estimated serving size, and a logged meal — editable forever after.

### 4.1 Pipeline

| Stage | Work | Destination | Fallback |
| --- | --- | --- | --- |
| 1. Dish split | "meatloaf and mashed potatoes" → `["meatloaf", "mashed potatoes"]` | on-device (`standard`) | existing `MealDecompositionPayload` path |
| 2. Recipe source | For each dish: known-recipe synthesis **or** web lookup | **deep** (PCC → BYOK) | manual ingredient builder |
| 3. Catalog bind | Each ingredient line → numbered `FoodSelectionCandidate` → `FoodItem` | **on-device, always** | deterministic matcher already in `FoundationFoodSelectionModel.deterministicPlan` |
| 4. Nutrition | Sum macros + micronutrients across bound items | **pure code, no model** | — |
| 5. Servings | Estimate yield and per-serving split | on-device (`light`) | default 4, user edits |
| 6. Review | User confirms/edits before anything is saved | UI | — |

Stage 2 has two sub-paths, chosen by the router:

- **Synthesis** (PCC or BYOK): the model returns a structured recipe — title, servings, ingredient
  lines with quantity + unit, and a short method note. No nutrition fields are accepted from the
  model even if offered.
- **Web lookup**: reuse [RecipeWebImporter](../FernletKit/Sources/AIProviders/RecipeWebImporter.swift)
  wholesale. It already has the hard parts — `isSafePublicHTTPSURL`, per-redirect-hop SSRF
  validation via `isPrivateOrLoopbackIPLiteral`, JSON-LD `Recipe` extraction, a Foundation-model
  text-extraction fallback, and `estimateMacrosFromIngredients` against the catalog. Do not
  reimplement any of it. The only new part is *choosing* a URL, which stays user-confirmed —
  Fernlet must not fetch a URL a model invented without the user seeing it first.

### 4.2 New payload types

Added to [AIContextPayload.swift](../FernletKit/Sources/AIContext/AIContextPayload.swift), following
the existing `includedFieldNames` contract:

```swift
public struct RecipeSynthesisPayload: AIContextPayload {
    public let payloadKind = "recipe-synthesis"
    public let dishName: String            // "meatloaf" — the only user text that crosses
    public let servingsHint: Int?
    public let dietaryConstraints: [String] // from settings, not from journal or period data
    public var includedFieldNames: [String] { ["dishName", "servingsHint", "dietaryConstraints"] }
}

public struct ServingEstimatePayload: AIContextPayload {
    public let payloadKind = "serving-estimate"
    public let dishName: String
    public let ingredientSummaries: [String]  // names + quantities, no nutrition
    public var includedFieldNames: [String] { ["dishName", "ingredientSummaries"] }
}
```

Note how little crosses the wall: a dish name and a servings hint. Not the meal log, not the day,
not the user's goals, not any derived signal.

### 4.3 Data model

> ~~`RecipeDefinition` already carries everything needed — no schema change.~~ **Superseded
> 2026-07-24 (D-A): this is false, and a synthesized recipe silently destroys its own output
> without the STEP 0 migration.** `SavedRecipeService.add(_:)` persists to `SavedRecipeRecord`
> ([FernletKit/Sources/CloudKitSync/Persistence.swift:359-371](../FernletKit/Sources/CloudKitSync/Persistence.swift)),
> which has **no structured-ingredient column** (only `ingredientsText: String`), and
> `SavedRecipeMapping.recipe` **hardcodes `ingredients: []` + `source: .webImport`**
> ([CloudKitSync/SavedRecipe.swift:81-83](../FernletKit/Sources/CloudKitSync/SavedRecipe.swift)). So
> a synthesized recipe (Decision 5 mandates `webImport == nil`) round-trips on the next relaunch /
> iCloud sync to an **empty, zero-macro `webImport` shell** — the exact opposite of Decision 5's
> "editable, scalable, catalog-bound."

**Per D-A, synthesized recipes persist via the STEP 0-migrated `SavedRecipeRecord` (`payloadData`
shape).** STEP 0c (establish the CloudKit schema deploy process) then STEP 0 (`SavedRecipeRecord →
payloadData` migration) are **hard prerequisites BEFORE recipe creation ships** — recipe creation
must not merge until the migrated record can round-trip structured ingredients. Set, on the migrated
record:

- `source` — `"Generated from \"meatloaf and mashed potatoes\""`, or the host for a web lookup
- `webImport` — populated only on the web-lookup path (existing `RecipeWebImport` semantics); **nil
  on synthesis** (Decision 5)
- `ingredients` — structured `[RecipeIngredient]`, catalog-bound, so the recipe stays fully
  editable and re-costable later — persisted in `payloadData`, not the legacy typed columns

Save through [SavedRecipeService](../FernletKit/Sources/StoreCore/SavedRecipeService.swift)
(`add(_:)`), then log the meal with **`MealBuilder.mealFromRecipe`**
([MealBuilder.swift:52](../Fernlet/MealBuilder.swift)), which sums the structured ingredients.

> ~~log the meal with the existing `SavedRecipeService.makeMeal(from:mealType:)`~~ — **corrected
> 2026-07-24:** `SavedRecipeService.makeMeal` is **webImport-only** and logs a zero-macro
> "Macros not available" meal for a structured/synthesized recipe. Use
> `MealBuilder.mealFromRecipe`, which sums the bound structured ingredients.

One user action produces both the recipe book entry and the meal — that is the whole point of the
feature.

### 4.4 Review gate

Non-negotiable, and it reuses the existing food review-gate pattern. The sheet shows: dish name,
servings, every bound ingredient with its matched catalog item and quantity, unmatched lines
flagged for manual binding, and computed per-serving macros. Nothing is written to the recipe book
or the day log until the user confirms. Unmatched ingredients go to the existing retry queue rather
than silently zeroing.

---

## 5. Feature 2 — Personalized workout suggestions

**Today:** `WorkoutSuggestionLibrary.suggestions(for:intensity:)` in
[Scoring.swift](../FernletKit/Sources/FernletScoring/Scoring.swift) is a static goal × intensity
lookup table. `FoundationWorkoutAdjustmentModel.adjust` handles *edits* to an existing session but
does not author one.

**Target:** a suggestion that reflects the user's actual profile, split, recent history, and
readiness — and can explain itself in one sentence.

### 5.1 Pipeline

| Stage | Work | Destination | Fallback |
| --- | --- | --- | --- |
| 1. Context build | Assemble profile + history + readiness into a typed payload | code | — |
| 2. Session design | Choose focus, movement patterns, volume, intensity, and a rationale | **deep** (PCC → BYOK) | `WorkoutSuggestionLibrary` table |
| 3. Exercise bind | Model picks by **candidate number** from `WorkoutAdjustmentCandidateBuilder.candidates` | on-device or same-tier | deterministic split engine |
| 4. Safety filter | Apply `avoidedMuscles`, `avoidedMovements`, `injuryNotes` contraindications | **pure code, always last** | — |
| 5. Rest guidance | Per-exercise rest from `WorkoutRestGuidance` | code | — |

> ~~Stage 4 runs *after* the model in every path.~~ **Corrected 2026-07-24:** `WorkoutSafetyFilter`
> today is a **PRE-filter** on the candidate pool ([WorkoutProgram.swift:1016](../FernletKit/Sources/FernletDomainModel/WorkoutProgram.swift)),
> and `applyAdjustment` (`:1131`) does **not** re-check the model's output. So the filter guards the
> *input* pool the model chooses from; it does not currently re-inspect what the model resolved. A
> cloud stage that selects (or an adapter that mis-maps) outside the pre-filtered pool would have
> **no last-line guard**.
>
> **Requirement (net-new): any cloud stage MUST re-run its resolved output back through
> `WorkoutSafetyFilter.feasibleExercises(in:location:profile:)` as a post-check before surfacing.**
> This is the "must run its output
> back through this, never around it" contract the filter's own doc already states — make it true on
> the cloud path, not just the candidate-pool path. A model suggestion that violates a
> contraindication is filtered, not surfaced and dismissed — the existing
> `WorkoutProfile.avoidedMuscles(fromConstraintText:)` mapping is deliberately conservative and stays
> that way.

### 5.2 Payload

```swift
public struct WorkoutProgramDesignPayload: AIContextPayload {
    public let payloadKind = "workout-program-design"
    public let experienceLabel: String        // ExperienceLevel
    public let goalLabel: String              // GoalType
    public let splitLabel: String?            // resolved TrainingSplit
    public let trainingDaysPerWeek: Int
    public let sport: String
    public let interests: [String]
    public let avoidedMuscleLabels: [String]
    public let avoidedMovementLabels: [String]
    public let recentSessionSummaries: [String]  // "Push - 4 exercises - RPE 7" × up to 10
    public let intensityReadinessLabel: String   // derived signal, already computed
    public let candidateCount: Int
    public var includedFieldNames: [String] { [...] }
}
```

Deliberately excluded: `injuryNotes` free text (the structured contraindications carry the
constraint without shipping the user's prose off-device), period bridge signals (spec §17 forbids
it, and the wall makes it unnameable in `AIProviders` anyway), body weight, and photos.

### 5.3 Enum safety

`WorkoutProfile` decodes its enum sets tolerantly via `EnumDecodeCompat` for multi-device reasons.
The model must therefore never emit an enum raw value — it selects candidate **numbers**, and code
maps numbers to `MuscleGroup` / `MovementPattern` / `ExerciseTarget`. An out-of-range number is
dropped, not parked.

---

## 6. Settings and key storage

### 6.1 Shape

Settings → Privacy → AI, extending the existing `aiStatus` / `webNutritionLookupEnabled` pattern in
[SettingsModel.swift](../FernletKit/Sources/FernletDomainModel/SettingsModel.swift):

- **Deep AI** — `off` / `Apple Private Cloud Compute` / `My own provider`
- **First-use PCC consent sheet (D-B, required).** Turning on the PCC deep tier — or the first deep
  call after enabling it — must present a **one-time first-use consent sheet that names Apple Private
  Cloud Compute and shows the exact fields that will cross** (the payload's `includedFieldNames`),
  **before any payload leaves the device**. PCC is **NOT implied by the general AI toggle**. Reuse
  the sealed-backup confirmation sheet pattern (the established "you are about to let data leave in a
  new way" affordance). No cloud call happens until the user accepts. Related consent-design gap: the
  shipped Fernlet-voice fallback bank is **5 generic strings** (`Scoring.swift:5-26`) with **no
  "refused" copy** — a provider-refusal notice string must be authored (see §3.2), since the
  deterministic fallback is what a refused cloud call lands on.
- **Per-feature opt-in** — separate toggles for recipe creation and workout suggestions, default
  off. Spec §17 requires per-feature opt-in for third-party AI. ~~PCC is Apple infrastructure and
  inherits the on-device consent posture~~ — **superseded 2026-07-24 (D-B): PCC does NOT inherit the
  on-device consent posture; it requires its own first-use consent (above).** The per-feature toggles
  exist for both tiers so the audit trail is honest.
- **Provider** (BYOK only) — **Claude (native) or a custom OpenAI-compatible endpoint (D-D)**, plus a
  model picker. Per-provider defaults come from the single `ProviderDefaults` table (§10.4) so
  shipping a new default is a one-line change.
  - ~~Claude / GPT / Gemini / Kimi picker matrix~~ — **superseded 2026-07-24 (D-D):** two adapters
    only, no per-vendor picker matrix; GPT and Kimi are reached through the custom-endpoint row.
  - **Custom OpenAI-compatible endpoint — hard requirements (net-new):** **https-only**; an
    **explicit host-confirmation UI** before the first call to a new host; the **key is bound to its
    endpoint host** and is **never** sent to a different host than the one it was entered for (never
    send a key entered for host A to host B). **ATS note:** default App Transport Security **blocks
    `http://localhost`** (Ollama / LM Studio), so the "covers local servers for free" claim does not
    hold under default ATS — either scope a narrow `NSAllowsLocalNetworking` exception for the
    local-server case or drop the local-server claim. Do not advertise local servers as free without
    the ATS work.
- **Usage** — per-provider spend/usage. ~~this month's token count per provider, from the framework's
  `usage` property~~ — **corrected 2026-07-24:** there is **no uniform monthly `usage` property**;
  per-response usage shapes differ per vendor, so **the app must sum and persist per-response usage
  itself**. And **token count is not cost** — display it as tokens, or convert with a per-model price
  from `ProviderDefaults`; do not label a token count as spend.

### 6.2 Key storage

API keys are new long-lived secrets. Rules:

- Keychain, `ThisDeviceOnly`. **Never** in `FernletSettings` — that is the synced blob, and the
  day-split work established what happens when identity-ish values ride it.
- Never in the sealed backup, never in an export, never in the audit log.
- ~~Cleared by the existing delete-all-data action.~~ **Corrected 2026-07-24: a new keychain-purge
  leg must be ADDED to delete-all-data.** `FernletStore.deleteAllData` touches **zero** keychain
  items today and *deliberately* skips `FernletLockService.reset()`
  ([FernletStore.swift:3025-3027](../Fernlet/FernletStore.swift)), so a BYOK API key would **survive
  a full "delete everything."** Add an explicit keychain-purge leg (with a failure line, per the
  funnel's per-store contract) **plus a post-wipe test asserting the key is gone**. Scheduled in the
  build order (§9).
- `AIProviders` must not gain a keychain dependency — its dependency list
  (`AIContext`, `FernletDomainModel`, `FernletScoring`, `FoodCatalog`) is the wall. Declare an
  `APIKeyProviding` protocol in `AIContext`, implement it in `AppServices`, inject at the call site.
  Note the secret still enters the walled module **as data** at the call site — the wall keeps
  `AIProviders` from *naming* the keychain, it does not keep the key bytes out of the module.

---

## 7. Privacy, wall, and audit

**S3 wall — naming unchanged, but be precise about what it does NOT guarantee.** All destinations
live behind `AIProviders`, which still cannot name a `Private*` store, and the typed payloads in §4.2
and §5.2 remain the only path to data. Run `Scripts/spm-wall-check.sh` as usual.

### 7.1 The wall's real semantics (added 2026-07-24)

The S3 wall is a **naming wall, not an egress wall.** It was only *incidentally* an egress guarantee
while all inference ran on-device. The payload allowlist (`includedFieldNames`) is a **hand-declared
convention**, not a compile error — nothing inspects a field's *value*. Once a cloud tier exists,
"the wall is unchanged and unweakened" is true of *naming* and **misleading about egress.**
Consequences to design around:

- **Some allowlisted fields are health-derived or free-text and would egress verbatim.**
  `intensityReadinessLabel` in `WorkoutProgramDesignPayload` is **HealthKit-derived** — RHR/HRV via
  `DerivedSignalFactory` `sourceFields` include `body.restingHeartRate` — so a health-derived label
  crosses to a third party on the BYOK path. `dishName` / `mealDescription` are **arbitrary user
  free-text** that now egress verbatim. **Each field that crosses on a cloud tier needs a
  value-level justification in the payload's doc comment** (why this scalar is safe to send), not
  just a name on the allowlist.
- **The grep-wall needs new markers.** A BYOK HTTP adapter has **no `FoundationModels` marker**, so
  `S3BoundaryTests`'s discovery (`LanguageModelSession` / `SystemLanguageModel` / `@Generable` /
  `import FoundationModels`) will not see it — add markers for the network-egress adapters. Also
  **`AppServices` is not in `S3BoundaryTests` `scanRoots`**, and `MealPhotoRecognizer` /
  `FoodImageClassifier` are currently **grep-wall-blind** — add `AppServices` to `scanRoots` (or pin
  those files as floor files) before any AI/model plumbing lands there.

### 7.2 Audit log

[AIAuditLog.swift](../FernletKit/Sources/AIContext/AIAuditLog.swift) is in-memory, 200-entry, and
records `payloadKind` / `destination` / `includedFields` / `memorySummaryCharCount`. For this work it
needs:

- a `modelIdentifier` field (which model, not just which vendor)
- an outcome field (`succeeded` / `fellBack` / `refused` / `schemaFailed`)
- **persistence, and it MUST be DEVICE-LOCAL ONLY** — it lands in `LocalPersistence`, **never**
  `CloudKitSync`. A *synced* "what left my device" record is the wrong privacy semantics (it would
  itself leave the device) and is the actual trigger for the `AIDestination` brick-vector. `AIContext`
  depends only on `FernletDomainModel`, so the log has no wall-safe *synced* home anyway. A user
  cannot meaningfully review "what left my device" from a log that dies with the process — this is
  already tracked as a gap in [RemainingWork-2026-07-19.md](RemainingWork-2026-07-19.md). Any
  `AIDestination` case additions ride the `EnumDecodeCompat` freeze/park pattern **and** need a clean
  build (`FernletDomainModel` layout hazard).

**Payload tests:** every new payload gets a test asserting its field set, mirroring the existing
`FernletTests/S3BoundaryTests` grep-wall discipline. A forbidden field appearing in
`includedFieldNames` should fail the build's test phase.

---

## 8. Docs to update

- **Spec §7** — the two-tier list becomes four: on-device → PCC → third-party BYOK, with
  deterministic fallback underneath all of them.
- **Spec §17** — the OHTTP relay/gateway design is superseded. PCC provides the privacy property
  OHTTP was hand-rolling, and BYOK is a direct user-authorized connection where OHTTP's
  unlinkability does not apply (the user's own API key identifies them by construction). Rewrite
  rather than delete; record why.
- **Spec guardrail line 894** ("No Private Cloud Compute escalation assumption") — this guardrail
  currently promises no PCC escalation. Per D-B it must be amended **in the same commit as the
  consent code** (not after) to state that PCC escalation happens only behind the explicit first-use
  consent sheet.
- **ImplementationPlan Phase 17** — retarget from "Third-Party AI via OHTTP" to this ladder.
- **Privacy-Policy.md:119** — currently says health data is "not sent to any external AI service."
  Must distinguish Apple PCC from user-authorized third-party providers, and state the per-feature
  opt-in and the field allowlist. Per D-B, **land this edit in the same commit as the consent code,
  not after** — the policy must not be false in any shipped build.

**App Store / legal submission gates (added 2026-07-24 — none were in this list before):**

- **`PrivacyInfo.xcprivacy`** currently declares an **empty `NSPrivacyCollectedDataTypes`** — that
  becomes false the moment BYOK sends health-derived text to a third party. Update it before BYOK
  ships.
- **Third-party SDK signed privacy manifests** — adding Anthropic's SPM package inherits Apple's
  **signed third-party privacy-manifest** requirement; a missing manifest is an **automated upload
  rejection**.
- **App Review 5.1.2(i)** (added 2025-11) — explicit **disclosure at consent** before sharing
  personal data with a third-party AI. A default-off toggle alone is **not** the disclosure UI; the
  first-use consent sheet (D-B) is where this disclosure lives.
- **Age-rating questionnaire** — the mandatory re-answer now asks about **generative AI / AI
  chatbots**; re-answer it. The custom-endpoint row is exactly the "unrestricted AI generation" that
  draws Guideline 1.2 moderation scrutiny (model-authored free text reaches the user unmoderated).
- **EU AI Act Art. 50** (applies from **2026-08-02**) — AI-interaction disclosure + generated-content
  marking. In scope for any generated recipe/workout text.
- **App-Privacy-Nutrition-Labels.md** — ~~review before submission~~ **corrected 2026-07-24: this is
  a REQUIRED change, not a review.** Sending health-adjacent data to a third-party AI is a
  **Health & Fitness data type shared with a third party** — the label must declare it.
- **Mesh recipe-share provenance** — `SharedRecipePayload` has **no origin field**. AI-authored
  recipes crossing the mesh should carry a **provenance marker** so a peer can tell a model-authored
  recipe from a human-authored one (ties to
  [Docs/Data-Provenance-Coach-Trust-2026-07-12.md](Data-Provenance-Coach-Trust-2026-07-12.md)).

---

## 9. Build order

> **Superseded 2026-07-24.** The two docs previously carried two contradictory build orders (this
> §9 omitted STEP 0/0b/0c; the EXPANSION §1 omitted the recipe-creation feature). There is now **one
> canonical, topologically-sorted merged order, and it lives in
> [AI-Feature-Expansion-2026-07-23.md §1](AI-Feature-Expansion-2026-07-23.md).** Read that as the
> single source of truth for sequencing. This section keeps only the **ladder-specific track** and
> the work items the ladder owns.

**Ladder-specific track (slots into the canonical order at "Provider-seam refactor" and later):**

1. **Provider-seam refactor** — `AICapabilityTier`, `FernletModelRouter`, the `AIDestination` cases
   (`EnumDecodeCompat` freeze/park + clean build), and audit-log fields + **device-local**
   persistence (§7.2). **No behavior change** — existing on-device paths route through the new seam.
   This step also builds the **net-new quota mechanism** (the local, non-synced day counter + reset +
   `.sleepy`/`.resting` state derivation, §3.2) and the **keychain-purge leg in `deleteAllData`**
   (§6.2).
2. **Cloud track — gated on iOS 27 GA (~Sept 2026), cannot ship above the on-device floor before
   then.** PCC entitlement (long pole, start the request early) + the **first-use PCC consent sheet
   (D-B)** landed in the same commit as the Privacy-Policy:119 and spec-guardrail:894 amendments;
   then recipe synthesis and workout personalization, each **per-feature opt-in**. All availability
   gates are `#available(iOS 27, *)`.
3. **BYOK track (after PCC, per D-D)** — Anthropic's native `LanguageModel` package + the one
   `OpenAICompatibleLanguageModel` custom-endpoint adapter (real `LanguageModelExecutor` conformance,
   not a shim), settings UI, keychain storage, the **BYOK spend guard** (per-day/per-destination caps
   + confirm-before-call + wifi-only, §3.2), and the custom-endpoint host/ATS requirements (§6.1).
4. **iOS 27 on-device** — adopt the larger multimodal model for the `standard` tier; revisit meal
   photo analysis, which currently routes through Vision/Core ML.

The on-device recipe (F1(a)) + micronutrient (F2) increment ships **standalone, before any of the
above** — see the canonical order. F6/F7 are **deferred (D-C)** and are not in the active build order.

---

## 10. Decisions (owner, resolved 2026-07-23)

1. **Deployment target → per-device capability ladder with graceful fallback.** No floor bump.
   The router resolves per device: no Apple Intelligence (iPhone 11 class) → deterministic path
   only; Apple-Intelligence devices → on-device Foundation Models; **iOS 27** devices → PCC as the
   deep tier. Rung unavailability is a per-device fact the §3.2 resolution order already expresses —
   no new mechanism, just per-device availability checks rather than per-app-version gates.
   > Revised 2026-07-24: ~~iOS 26.4+~~ → **iOS 27** (the PCC/`LanguageModel` symbols are iOS 27,
   > WWDC26, beta until ~Sept 2026 GA). The per-device availability check **must gate on
   > `#available(iOS 27, *)`** — an iOS-26 gate resolves TRUE on iPhone-11-class devices that lack
   > the symbols and crashes on the unresolved reference. Make the deterministic-only floor genuinely
   > deterministic-only; do not let a version check alone stand in for symbol availability.
2. **2M download cliff → degrade to on-device + deterministic.** If the free PCC tier ends, the
   deep tier falls back to on-device (B) and the deterministic path; BYOK (F) remains for users who
   configured it. No Fernlet-funded key. The router treats "PCC ineligible" identically to "PCC
   unavailable on this device."
3. **Android → out of scope for now.** When the time comes: bundled on-device models, or default to
   the deterministic path only — plus the BYOK API-key connection as the cloud option. Keep the
   router provider-agnostic so this stays cheap; nothing else to do today.
4. **BYOK defaults approved** — ~~Claude → `claude-opus-4-8`, GPT → latest reasoning-capable,
   Gemini → latest Pro, Kimi → latest~~; user-overridable in the picker. Added requirement: the
   defaults must be trivially updatable as new models ship — one `ProviderDefaults` table as the
   single source of truth, so a new model is a one-line change, never a scattered-constant hunt.
   > **Superseded 2026-07-24 (D-D + cost correction).** BYOK is **two adapters** (§2, §6.1), so
   > `ProviderDefaults` shrinks accordingly — no Gemini row, no per-vendor matrix; the custom
   > endpoint carries its own user-typed base URL + model id. **Claude default →
   > `claude-haiku-4-5`** (not `claude-opus-4-8`), with **Sonnet as the step-up**. Keep
   > **extended/adaptive thinking OFF** for the bounded candidate-selection tasks the handoff
   > invariant defines. Precision: the **`effort` parameter is not supported on `claude-haiku-4-5`
   > (passing it errors)** — it applies only to the **Sonnet step-up**, where it should be set **low**.
   > (Opus is ~5× Haiku for this shape, and adaptive thinking makes it worse, on a permanently-free
   > app billing the user's own key.)
5. **A generated recipe is NOT a web import.** `webImport` stays nil on synthesis; synthesized
   recipes take the structured-ingredient path (editable, scalable, catalog-bound). The asymmetry
   with looked-up recipes is intended.
   > Revised 2026-07-24 (D-A): synthesized recipes persist via the **STEP 0-migrated
   > `SavedRecipeRecord` (`payloadData` shape)** — see §4.3. Without STEP 0c + STEP 0 (hard
   > prerequisites before recipe creation ships), a synthesized recipe round-trips to an empty,
   > zero-macro `webImport` shell — the opposite of this decision. The "keeps `webImport` nil /
   > structured path" intent is only achievable *after* the migration.

Feature-level decisions live in
[AI-Feature-Expansion-2026-07-23.md §11](AI-Feature-Expansion-2026-07-23.md) — all seven were
resolved 2026-07-23. ~~seven remain open there~~ (corrected 2026-07-24). Per the 2026-07-24 owner
decision **D-C, F6 (progressive overload / per-set record) and F7 (deload) are DEFERRED** pending a
spec-level product decision — the per-set record is the feature closest to the "optimization
framing" the spec rejects — and are **not part of the active build order**.
