# Increment D — On-device AI bypass diagnosis (2026-08-23)

Read-only diagnosis (Opus agent, food worktree @ 9aa090a + uncommitted item 9; nothing edited,
built, or run). Companion to [AI-Alternate-Track-Plan-2026-08-23.md](AI-Alternate-Track-Plan-2026-08-23.md) §1.
All paths below are worktree-relative; line numbers are as of this date.

## Headline

**One line explains everything the owner observes:**

```
FernletKit/Sources/FernletDomainModel/SettingsModel.swift:61
    public var aiStatus: AIStatus = .off
```

`.off` is the **app-target default**, not a test convenience. The only writer in shipping code is
the Settings toggle (SettingsSheet.swift:1181). Onboarding never mentions AI. On a fresh install
every AI path is closed, and the single enabling switch (Settings → AI & data sources →
"On-device AI helper", SettingsSheet.swift:1030) has no onboarding mention, no in-context prompt,
and no empty-state pointer from any feature that would use it.

**The features are not bypassed — they are invisible.** Meal logging is already AI-FIRST once
enabled; recipe creation has NO AI feature at all (nothing exists to bypass); workout adjust has
the app's only visible AI affordance.

## 1. Consultation map (8 sites, all through one choke point)

Exactly 8 shipping sites construct a `LanguageModelSession`; every one passes
`gate.dispatch`/`resolveRoute` first. Shared gate chain:

| Order | Gate | Location | Default |
|---|---|---|---|
| G1 | `settings.aiStatus != .off` pre-filter | e.g. MealResolutionService.swift:105 | **CLOSED** (.off) |
| G2 | `#if canImport(FoundationModels)` | per site | open |
| G3 | `#available(iOS 26.0, *)` | per site | open |
| G4a | effective status = intent ⊕ quota | AIContext/AICallQuota.swift:91-101 (.off wins :99) | — |
| G4b | `.off` → fallback | AIContext/FernletModelRouter.swift:101-102 | **CLOSED** |
| G4c | `.resting` ≥60 calls/day → fallback | :103-104; threshold AICallQuota.swift:35 | open |
| G4d | `.sleepy` ≥30 + !userInvoked → fallback | :105-111; threshold :33 | open |
| G4e | **device capability** — live `SystemLanguageModel.default.availability` | :117-119; AIProviders/SystemLanguageModelCapabilityProvider.swift:40-48 | **runtime**; PCC/BYOK pinned false (:31,:33); ALWAYS closed in simulator |
| G4f | sensitive-work pin (light never egresses) | :152-161 | n/a |
| G5 | quota charged once, on resolved destination | AIContext/FernletAIGate.swift:75-78 | — |

Sites: (1) meal dish decomposition M1 — **AI FIRST**, before all deterministic tiers
(MealResolutionService.swift:105-149 vs :156/:177/:184); (2) meal food selection M2; (3) workout
adjustment — the ONLY visible affordance ("Adjust with AI", MoveView.swift:1794); (4) recipe page
extraction — **deterministic first**: JSON-LD returns at RecipeWebImporter.swift:191 before any
gate; (5) ingredient substitution — fires on sheet APPEAR, no aiStatus pre-check, classed
userInvoked:true (quota concern); (6) food-product page extraction — 4 deterministic tiers first,
also requires `webNutritionLookupEnabled` (SettingsModel.swift:66, also default false;
DiaryStore.swift:106 requires BOTH); (7) day summary + (8) companion thought — ambient at launch
(LaunchPreparationService.swift:475/:538). Meal photo identify is Vision-only, not AI. No model
pre-warm exists anywhere.

## 2. Per-feature verdict

- **Recipe creation: AI never runs because no AI recipe feature EXISTS.** The creation chooser is
  pinned two-branch (Import|Manual, FoodView.swift:5686/:5695); manual entry has zero AI; URL
  import is deterministic-first by design (JSON-LD answers before the gate — correct, not a bug).
  Closest thing: decomposition's `suggestedRecipe` surfaced via "Save as a recipe"
  (FoodView.swift:4578, default ON at :4462).
- **NL meal logging: genuinely AI-first; the ONLY blocker is the default-off toggle** (the exact
  line: MealResolutionService.swift:105). With the toggle on and an eligible device, AI runs on
  every non-empty meal log up to the 60-call daily budget.
- **Workout: AI can only ADJUST an already-deterministic plan, and only with typed free text**
  (WorkoutPlanningService.swift:105 guards on non-empty text; cardio/mobility/rest filtered
  at :115). No from-scratch AI suggestions exist (that is plan increment E3).

## 3. Audit log + the owner's 10-minute on-device checklist

Schema `AIAuditEntry` (AIContext/AIAuditLog.swift:66-194): payloadKind (frozen tokens),
destination, modelIdentifier (`apple.ondevice.foundation-models`), outcome
(succeeded/fellBack/refused/schemaFailed), includedFields (names only). Ring 500, persisted
`<AppSupport>/FernletAIAudit/ai-audit-log.json`, excluded from backup, wiped by Delete-everything.
**Viewing surface ships**: Settings → Privacy & data → "AI activity log" (SettingsSheet.swift:383).
⚠️ It caches per push — back out and re-enter to refresh. ⚠️ **A closed gate writes NO row** —
"off", "ineligible device", and "quota" are indistinguishable silence; step 2 below is therefore
the load-bearing probe, not the log.

**Checklist (real device only — the simulator can never open G4e):**
1. Settings → AI & data sources. If **"On-device AI helper" is OFF — that alone is the entire
   finding**; turn it on. ⚠️ The "Today" row says "Ready" even on ineligible devices
   (effectiveAIStatus ignores capability, FernletStore.swift:102-103) — do not trust it.
2. **Eligibility probe**: Move tab → today's plan. Look for the text field "e.g. swap the squat…"
   with **"Adjust with AI"** beneath it. Present → device eligible (G4e OPEN). Absent with toggle
   ON → **Apple Intelligence unavailable on this device/OS/language — complete diagnosis; no AI
   can ever run** (check iOS Settings → Apple Intelligence & Siri). This field is the app's only
   eligibility signal (MoveView.swift:1387-1394).
3. Log a multi-item free-text meal ("two eggs and toast").
4. Type "swap the squat" into the Adjust field → tap Adjust with AI.
5. (Optional) Import a recipe URL.
6. Settings → Privacy & data → AI activity log (re-enter fresh). Interpret:
   - "Meal breakdown" + Completed → all gates open, AI participating.
   - "Meal breakdown" + "No usable answer — Fernlet used its own logic" → gates open; QUALITY
     finding (model ran, nothing bound), not routing.
   - "Food match" row → M1 failed/nil, M2 ran — gates open.
   - No meal row at all with toggle ON → gate closed pre-dispatch; step 2 disambiguates
     ineligibility vs. quota ("Today: Sleepy/Resting").
   - No "Reading a recipe page" row after a SUCCESSFUL import → expected (JSON-LD answered) — not
     a bypass bug.
   - "Day summary"/"Companion thought" rows at launch → all gates open independently of taps.

## 4. Routing assessment (owner decides; this is the reasoning)

- **Option A (explicit affordance): minimal re-verification.** The corpus never constructs a
  store (structurally AI-independent); the 1.8 floors and retrievalGatedConfidence already sit on
  the AI tier; DishTemplateBindAudit pins stay valid. New surfaces need review-gate wiring, the
  1.14 plausibility gate on AI-drafted macros, strings, P10.
- **Option B decomposes**: B1 = flip the default (.off → .ready — one line, and it IS the
  observed symptom). B2 = reorder deterministic-first importers — **reject**: JSON-LD is exact
  publisher data; a model reading the same page is strictly worse and burns quota.
- **B1's real cost is testability**: FoundationModels can't run in the simulator, so flipping the
  default moves the entire shipped default path out of CI's reach; today CI measures exactly what
  users get. It also inverts the app's opt-in posture (ladder doc: PCC "is NOT implied by the
  general AI toggle").
- **Recommendation: A + discoverability, not B1.** Keep `.off` default; add a one-time factual
  first-use invitation from the surfaces that would use AI; fix the two honesty gaps (surface
  device eligibility; stop "Today: Ready" on ineligible devices); build E1 on the waiting `.deep`
  tier, E2 as disclosure over the already-AI-first cascade, E3 as extension of the working
  affordance.

## 5. Surprises / contradictions (feed these into increments E/F)

1. **`AICapabilityTier.deep` has ZERO production dispatch sites** — its doc names "Recipe
   synthesis, workout program personalization" (AICapabilityTier.swift:23). Built for E1/E3,
   waiting.
2. `effectiveAIStatus` ignores device capability → Settings shows "Ready" on ineligible devices.
   Misleading exactly during this diagnosis. FIX with E-work.
3. The workout Adjust field is the app's only eligibility signal — an accidental diagnostic;
   make deliberate.
4. `FernletModelRouter.stepDown` unreachable (PCC/BYOK pinned false) though ladder §3.2 presents
   step-down as shipped.
5. `AIDeviceCapability.isAvailable(.webNutritionLookup)` returns false unconditionally — a gate
   that can never open (harmless today).
6. Ladder §3.2 step 4's "user's ceiling + per-feature opt-in" do not exist in
   `FernletModelRouter.resolve` — doc ahead of code.
7. **Closed gates leave no trace anywhere** — for a privacy product built on legibility, the
   absence case is the one the log cannot explain. Consider an explicit "AI was not consulted
   because X" surface.
8. Ingredient substitution fires on sheet-appear with userInvoked:true and no aiStatus pre-check
   — quota-charging a surface the user merely opened.
9. **AI-authored recipes CAN auto-commit without a review sheet today**: M2's `createdRecipes`
   flow through `builtResolution` → `commitResolution` inserts at FernletStore.swift:2165
   whenever needsReview is false (confidence .high surviving retrievalGatedConfidence, no
   unmatched items). The E-standing-rule "every AI result flows through review gates" is NOT true
   of this path. **Pin before E2.**
10. `AIAuditLogView` ships but ladder §7.2 still calls the UI hypothetical — doc trails code.
11. Audit log excluded from backup → never a longitudinal record across device migration
    (correct for privacy; worth knowing).
