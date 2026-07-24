# AI Provider Ladder & Deep AI Features — 2026-07-23

Plan for raising Fernlet's AI ceiling on two features (recipe creation, workout suggestions) by
adding a routed provider ladder underneath the existing on-device path.

**Status:** planned, not started. Supersedes the OHTTP design in
[FernletSpecificationV3 §17](FernletSpecificationV3.md) for the third-party tier (see §8).

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
| **C** | **Private Cloud Compute** — the default deep tier | **none** | **none** | none under 2M first-time downloads | Apple PCC only |
| **F** | BYOK — Claude, GPT, Gemini, Kimi | paste a key | per-token (theirs) | none | yes, to their chosen vendor |

**A and B are the floor. C is the new default for deep work. F is opt-in for users who want a
frontier model and are willing to pay for it.** Nothing here changes the rule that every AI feature
has a deterministic fallback.

Not adopted: Fernlet-funded API key (recurring cost against a permanently-free app), remote MCP
connector (requires a server), copy/paste handoff (per-use friction).

---

## 2. Architecture: one protocol, four backends

iOS 26.4/27's Foundation Models framework exposes a `LanguageModel` protocol. Apple ships
`PrivateCloudComputeLanguageModel`; Anthropic and Google publish conforming Swift packages;
everything downstream of `LanguageModelSession` is unchanged. That gives us one call shape for all
four destinations:

```swift
let model = try FernletModelRouter.resolve(for: task, settings: settings)
let session = LanguageModelSession(model: model, instructions: instructions)
```

**Two adapters cover all four BYOK providers:**

| Provider | Adapter | Notes |
| --- | --- | --- |
| Claude | Anthropic's `LanguageModel` Swift package | native, least work |
| Gemini | Google's `LanguageModel` Swift package | native |
| GPT | `OpenAICompatibleLanguageModel` (ours) | `/v1/models`, `/v1/chat/completions` |
| Kimi | same adapter, different base URL | Moonshot is OpenAI-compatible |

The OpenAI-compatible adapter is the same bet Xcode makes for third-party chat providers, and it
incidentally covers local servers (Ollama, LM Studio) for free.

### `AIDestination` grows

[AIDestination.swift](../FernletKit/Sources/FernletDomainModel/AIDestination.swift) currently has two
cases. New shape:

```swift
public enum AIDestination: String, Codable, Sendable {
    case onDeviceFoundationModels
    case webNutritionLookup
    case privateCloudCompute
    case externalAnthropic
    case externalOpenAI
    case externalGoogle
    case externalMoonshot
}
```

This is a `FernletDomainModel` enum that lands in the audit log, so it is a brick-vector site —
follow the `EnumDecodeCompat` freeze/park pattern established in the UI/UX branch review.

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
6. All rungs exhausted → deterministic fallback with a Fernlet-voice notice.

Escalation is downward only. The router never silently promotes a task to a destination the user
did not enable, and never sends a `light` payload off-device.

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

`RecipeDefinition` already carries everything needed — no schema change. Set:

- `source` — `"Generated from \"meatloaf and mashed potatoes\""`, or the host for a web lookup
- `webImport` — populated only on the web-lookup path (existing `RecipeWebImport` semantics)
- `ingredients` — structured `[RecipeIngredient]`, catalog-bound, so the recipe stays fully
  editable and re-costable later

Save through [SavedRecipeService](../FernletKit/Sources/StoreCore/SavedRecipeService.swift)
(`add(_:)`), then log the meal with the existing `SavedRecipeService.makeMeal(from:mealType:)`.
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

Stage 4 runs *after* the model in every path, including the fallback path. A model suggestion that
violates a contraindication is filtered, not surfaced and dismissed — the existing
`WorkoutProfile.avoidedMuscles(fromConstraintText:)` mapping is deliberately conservative and stays
that way.

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

- **Deep AI** — `off` / `Apple Private Cloud Compute` (default) / `My own provider`
- **Per-feature opt-in** — separate toggles for recipe creation and workout suggestions, both
  default off for the BYOK tier, on for PCC. Spec §17 requires per-feature opt-in for third-party
  AI; PCC is Apple infrastructure and inherits the on-device consent posture, but the toggles exist
  either way so the audit trail is honest.
- **Provider** (BYOK only) — Claude / GPT / Gemini / Kimi, plus model picker and a "custom
  OpenAI-compatible endpoint" row. Per-provider default models come from the single
  `ProviderDefaults` table (§10.4) so shipping a new default is a one-line change
- **Usage** — this month's token count per provider, from the framework's `usage` property

### 6.2 Key storage

API keys are new long-lived secrets. Rules:

- Keychain, `ThisDeviceOnly`. **Never** in `FernletSettings` — that is the synced blob, and the
  day-split work established what happens when identity-ish values ride it.
- Never in the sealed backup, never in an export, never in the audit log.
- Cleared by the existing delete-all-data action.
- `AIProviders` must not gain a keychain dependency — its dependency list
  (`AIContext`, `FernletDomainModel`, `FernletScoring`, `FoodCatalog`) is the wall. Declare an
  `APIKeyProviding` protocol in `AIContext`, implement it in `AppServices`, inject at the call site.

---

## 7. Privacy, wall, and audit

**S3 wall:** unchanged and unweakened. All four destinations live behind `AIProviders`, which still
cannot name a `Private*` store. The typed payloads in §4.2 and §5.2 remain the only path to data.
Run `Scripts/spm-wall-check.sh` as usual.

**Audit log:** [AIAuditLog.swift](../FernletKit/Sources/AIContext/AIAuditLog.swift) is in-memory,
200-entry, and records `payloadKind` / `destination` / `includedFields` / `memorySummaryCharCount`.
For this work it needs:

- a `modelIdentifier` field (which model, not just which vendor)
- an outcome field (`succeeded` / `fellBack` / `refused` / `schemaFailed`)
- **persistence** — a user cannot meaningfully review "what left my device" from a log that dies
  with the process. This is already tracked as a gap in
  [RemainingWork-2026-07-19.md](RemainingWork-2026-07-19.md).

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
- **ImplementationPlan Phase 17** — retarget from "Third-Party AI via OHTTP" to this ladder.
- **Privacy-Policy.md:119** — currently says health data is "not sent to any external AI service."
  Must distinguish Apple PCC from user-authorized third-party providers, and state the per-feature
  opt-in and the field allowlist.
- **App-Privacy-Nutrition-Labels.md** — review before submission.

---

## 9. Build order

1. **Provider seam** — `AICapabilityTier`, `FernletModelRouter`, `AIDestination` cases, audit-log
   fields + persistence. No behavior change; existing on-device paths route through the new seam.
2. **PCC** — request the entitlement (long pole, start first), add
   `PrivateCloudComputeLanguageModel` as the `deep` default, availability-gate for iOS 26 floor.
3. **Recipe creation** — payloads, synthesis stage, catalog binding, review gate, recipe book save.
   Ship on PCC only.
4. **Workout personalization** — payload, design stage, candidate binding, safety filter ordering.
   Ship on PCC only.
5. **BYOK** — Anthropic + Google native packages, `OpenAICompatibleLanguageModel` for GPT + Kimi,
   settings UI, keychain storage.
6. **iOS 27 on-device** — adopt the larger multimodal model for `standard` tier; revisit meal photo
   analysis, which currently routes through Vision/Core ML.

---

## 10. Decisions (owner, resolved 2026-07-23)

1. **Deployment target → per-device capability ladder with graceful fallback.** No floor bump.
   The router resolves per device: no Apple Intelligence (iPhone 11 class) → deterministic path
   only; Apple-Intelligence devices → on-device Foundation Models; iOS 26.4+ devices → PCC as the
   deep tier. Rung unavailability is a per-device fact the §3.2 resolution order already expresses —
   no new mechanism, just per-device availability checks rather than per-app-version gates.
2. **2M download cliff → degrade to on-device + deterministic.** If the free PCC tier ends, the
   deep tier falls back to on-device (B) and the deterministic path; BYOK (F) remains for users who
   configured it. No Fernlet-funded key. The router treats "PCC ineligible" identically to "PCC
   unavailable on this device."
3. **Android → out of scope for now.** When the time comes: bundled on-device models, or default to
   the deterministic path only — plus the BYOK API-key connection as the cloud option. Keep the
   router provider-agnostic so this stays cheap; nothing else to do today.
4. **BYOK defaults approved** — Claude → `claude-opus-4-8`, GPT → latest reasoning-capable,
   Gemini → latest Pro, Kimi → latest; user-overridable in the picker. Added requirement: the
   defaults must be trivially updatable as new models ship — one `ProviderDefaults` table as the
   single source of truth, so a new model is a one-line change, never a scattered-constant hunt.
5. **A generated recipe is NOT a web import.** `webImport` stays nil on synthesis; synthesized
   recipes take the structured-ingredient path (editable, scalable, catalog-bound). The asymmetry
   with looked-up recipes is intended.

Feature-level decisions live in
[AI-Feature-Expansion-2026-07-23.md §11](AI-Feature-Expansion-2026-07-23.md) — seven remain open
there.
