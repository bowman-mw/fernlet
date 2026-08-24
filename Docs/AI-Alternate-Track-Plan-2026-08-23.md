# AI Alternate Track & Third-Party Groundwork — plan, 2026-08-23

Owner-directed plan for (1) making the on-device AI a real, visible alternate track for recipe
creation, natural-language meal logging with portions, and workout suggestions, and (2) beginning
the third-party (BYOK) integration as pre-GA groundwork. Written at the wind-down of the
2026-08-22 two-track round; **executes AFTER that round's remaining work**
([Next-Round-Prompt-Continuation-2026-08-24.md](Next-Round-Prompt-Continuation-2026-08-24.md)),
except for the overlap items listed in §5, which ride the existing increments.

**This plan builds on, and does not reopen, the decided architecture** in
[AI-Provider-Ladder-2026-07-23.md](AI-Provider-Ladder-2026-07-23.md) (four destinations; A/B
on-device floor; C = PCC consent-gated default deep tier; F = BYOK, exactly two adapters —
Claude native + one OpenAI-compatible custom endpoint; all iOS-27 `LanguageModel` protocol;
`#available(iOS 27, *)` gates only) and the shipped provider seam (FernletModelRouter,
AIDestination, AI audit log with modelIdentifier/outcome, quota counter, all call sites routed).

## Owner decisions — 2026-08-23 (this doc's charter)

1. **Third-party AI: pre-GA groundwork NOW; adapters at iOS 27 GA.** No bespoke pre-27 HTTP
   path — the one-protocol design stands.
2. **On-device routing: DIAGNOSE FIRST, then decide.** The owner observes AI features being
   bypassed for deterministic paths; no routing change (AI-first vs. explicit affordance) is
   authorized until the diagnosis reports. Both options stay open.
3. **Alternate-track scope: recipe creation, NL meal logging + portions, workout suggestions.**
   The seven AI-Feature-Expansion features are NOT in this plan's scope (their build order in
   AI-Feature-Expansion §1 remains the reference if the owner later widens scope).
4. **Usage:** planning only in the 2026-08-23 session; the diagnosis increment may run if budget
   remains; everything else is deferred behind the two-track completion.

## 1. Increment D — the bypass diagnosis (FIRST AI move; may run early)

**Question:** why does the on-device AI rarely (never?) participate on the owner's device, and
what would each routing option cost?

Code-level half (an agent can do this in the food worktree, READ-ONLY — the item 9 diff is
uncommitted there; nothing may be edited):
- Map every consultation site of the AI tier: `MealResolutionService` (which tier order, what
  triggers escalation to `FoundationFoodSelectionModel.resolve`), recipe creation, workout
  suggestions. For each: the exact gate chain (aiStatus setting, `#available`, device
  eligibility/Apple Intelligence, quota counter, confidence thresholds that short-circuit to
  deterministic).
- Establish the app-target default of `aiStatus` (tests force `.off`; what does a fresh install
  get?) and every Settings surface that can change it.
- Read the AI audit log schema — it already records modelIdentifier + outcome per call. Write the
  exact on-device checklist for the owner: where to see whether AI was consulted, what outcome
  codes mean, which log absence proves which gate closed.
- Known inputs from the 2026-08-22 round (ledger rows 8b/9b): the AI tier stamps `.high` via
  `builtResolution` gated by the new `retrievalGatedConfidence` (wiring source-evidenced only —
  FoundationModels cannot run in the simulator); `aiStatus == .off` in ALL test stores;
  deterministic plans (`deterministicPlan` / `deterministicIngredients`) are the tested path.
- Output: a routing map + gate table + on-device checklist + a measured recommendation between
  "explicit AI affordance" and "AI-first when available", with what each breaks (review gates,
  this round's floors, §29-coupled corpus results — any AI-first re-route re-opens those).

Device half (owner, ~10 minutes, guided by the checklist): run one recipe creation and one meal
log on the real device, then read the audit log per the checklist. This settles empirically what
the simulator structurally cannot.

## 2. Increment E — the explicit alternate track (AFTER diagnosis + owner routing decision)

Whichever routing wins, these hold:
- **Every AI result flows through the existing review gates** — nothing AI-authored auto-commits
  past the surfaces this round hardened (bind floors, retrievalGatedConfidence, plausibility
  gate 1.14, correction memory precedence). The plausibility gate applies to AI-drafted recipes'
  macros exactly as to scanned labels.
- **Deterministic fallback always exists** (ladder doc's standing rule).
- Surfaces, per the scope decision:
  - **E1 Recipe creation:** an explicit entry point in the recipe composer ("draft from a
    description") → on-device model drafts name/ingredients/steps/servings → user reviews/edits →
    plausibility gate on the macros → save. The FoodView composer work (two-track item 10) must
    not preclude this affordance (§5).
  - **E2 NL meal logging + portions:** "4 pieces of salmon nigiri" → resolved meal with portion
    math. This is the owner's recorded portions driver (ledger owner-decision #9) — the
    portion-count field design and item 12's RecipeUnit work feed it. AI proposes; the resolver's
    gates dispose.
  - **E3 Workout suggestions:** the ladder doc's second feature; suggestion cards proposed from
    history, never auto-scheduled.
- Testing reality: FoundationModels is absent in the simulator, so E-increments are tested via
  the deterministic-shaped plan seams (item 8/9 pattern) + prompt/response-schema unit tests +
  an on-device validation checklist per increment. Budget on-device passes with the owner.

## 3. Increment F — BYOK pre-GA groundwork (can start after two-track merges; no iOS 27 needed)

Everything below compiles and ships on iOS 26 — only the adapter wiring waits for GA:
- **F1 Keychain storage for BYOK keys + the purge leg in `deleteAllData`.** The ladder doc
  already names the missing purge leg. Follow the item-8 wipe-wall pattern exactly: disposition
  row in PrivacyWipeCoverage.md + `PersistedSurfaceWipeBoundaryTests` entry + plant-wipe-prove-
  gone test + resurrection audit, same commit. Keychain, never UserDefaults.
- **F2 Settings surface:** provider picker (Claude / custom endpoint), key entry, endpoint URL
  entry with validation, per the D-D two-adapter scope. Display copy localized; no key material
  in any log or audit row (audit records modelIdentifier only).
- **F3 Consent sheets:** BYOK's own consent ("your data goes to the provider YOU chose, on your
  key") — distinct from the PCC first-use consent (D-B). Copy holds the §40.9-style discipline:
  factual, no reassurance language.
- **F4 No-Tracking wall rows:** `api.anthropic.com` + the user-supplied-endpoint class must be
  allowlisted in NoTrackingBoundaryTests AND documented in Docs/No-Tracking-Wall.md in the same
  commit (standing rule). The user-supplied endpoint needs its own wall treatment — a
  user-consented destination class, validated at entry, never a wildcard.
- **F5 Router integration stubs:** `AIDestination` cases for the two adapters behind
  `#available(iOS 27, *)`, quota interplay, and the audit-log outcome codes for cloud tiers —
  compiled but unreachable until GA. NOTE: verify the 26.5 SDK accepts the gates without the
  iOS 27 symbols (it does — the gated code references nothing that doesn't exist yet; the
  adapters themselves are NOT written in F).
- **S3 wall unchanged:** AIProviders still never reaches the sealed `Private*` stores; BYOK
  requests carry only what the feature's prompt builder already assembles on the walled side.
- **At iOS 27 GA (~Sept 2026):** increment G = the two adapters (Anthropic native package = one
  SPM dependency → No-Tracking wall + S3 DAG review in the same commit; the
  OpenAI-compatible adapter ours), PCC tier, per the ladder doc's build order.

## 4. Sequencing

1. Two-track round completes (items 10–13, 1.7b, confidentBindScore, endgame merges) — per the
   continuation prompt.
2. **D** (diagnosis) — may run earlier if budget allows; read-only, collides with nothing.
3. Owner routing decision on the diagnosis report.
4. **E1 → E2 → E3** (each a full implement→review→closure increment).
5. **F1–F5** (BYOK groundwork; F1 is independent and can interleave).
6. **G** at iOS 27 GA.

## 5. Overlaps folded into the two-track continuation (already amended there)

- **Item 10 (FoodView composer):** do not preclude the E1 "draft from a description" affordance —
  reserve the composer's empty-state layout seam; no AI UI yet (diagnosis first).
- **Item 12 (RecipeUnit slice/piece):** its unit model is E2's substrate — the increment's report
  must state what E2's portion conversion can rely on.
- **Endgame on-device validation pass:** fold in the two flagged AI validations (AI-tier
  retrievalGatedConfidence wiring; item 9's history tier on-device) + increment D's device
  checklist — one device session instead of three.
- **Wipe-wall discipline:** F1 reuses item 8's pattern verbatim (the pattern is now proven twice).

## 6. Standing constraints (unchanged, binding)

Provider ladder decisions D-A..D-D are settled. Every AI feature keeps a deterministic fallback.
No Fernlet-funded API key (free-forever). PCC and BYOK are separately consented; the general AI
toggle implies neither. Frozen tokens (AIDestination cases, audit outcome codes, prompt
vocabulary) never localize. Power-of-10, S3, No-Tracking, localization, and persisted-surface
walls all apply to every increment here.
