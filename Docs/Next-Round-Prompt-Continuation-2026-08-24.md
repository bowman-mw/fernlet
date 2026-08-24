# Continuation prompt — two-track round, session 3 (written 2026-08-23 at wind-down)

You are the **orchestrator** for the continuation of Fernlet's two-track round (accessibility +
food search). **You dispatch, verify, commit and account. You do not implement.** Every code
read, edit and test run happens inside a subagent; you keep only its structured result.
`Docs/Round-2026-08-22-Progress.md` is the authoritative ledger — **read it first**; every claim
below is expanded there with evidence. Update it after every commit. Research reports:
`Docs/Accessibility-Review-2026-08-22.md` and
`Docs/Food-Search-And-Community-Database-Research-2026-08-22.md` (untracked in the main tree,
copied into all three worktrees).

## USAGE (binding — this ended session 2)

Session 2 stopped because the owner reported **2% weekly / 5% Fable plan usage remaining**.
Before dispatching ANYTHING, confirm with the owner that usage has reset / how much budget this
session has, and size the plan to it. Typical costs observed: implementation agent 150–450k
tokens, adversarial review 200–370k, closure verify 200–360k, narrow fix 100–420k. A full
increment cycle ≈ 0.8–1.5M agent tokens. Keep prompts tight; never spawn agents whose result you
won't use. At every increment boundary check `<total_tokens>` too — stop cleanly below ~1.5M.

## Infrastructure (exists — do not recreate)

- Worktrees: `../fernlet-wt-a11y` (branch `claude/a11y-2026-08-22`, tip **ba6d561**),
  `../fernlet-wt-food` (branch `claude/food-search-2026-08-22`, tip **9aa090a**),
  `../fernlet-wt-home` (branch `claude/home-visuals-2026-08-23`, tip **4bd4d20**).
- DerivedData: `/tmp/dd-a11y`, `/tmp/dd-food`, `/tmp/dd-home` (never shared, always passed).
- Simulators: `Fernlet-A11y` = BBB73DF2-0E2E-4B2F-B437-58DBF12D563B, `Fernlet-Food` =
  B2A0DAC3-B9AC-4018-BC4B-C23D53AEA2D7, `Fernlet-Home` = B53294A4-75F7-43FA-8062-7476726B5870
  (all iPhone 17 / iOS 26.5). Other booted sims belong to other sessions — never touch.
- CAUTION (disclosed by item 9's implementer): `Scripts/spm-wall-check.sh` ignores env
  DerivedData/destination overrides — running it verbatim touches the SHARED DerivedData and
  `name=iPhone 17`. Have agents re-run its exact flag set against a private DerivedData + the
  pinned sim UDID instead (both item 8's and 9's agents did this successfully). Fixing the script
  to accept overrides is a worthwhile micro-item.

## Committed state (do not redo)

**Track A** (`claude/a11y-2026-08-22`): A1 `59fde3b`, A2 `886a352`, A3 `26e4b89`, A4 `7a115ad`,
**A5 `ba6d561`** (61 files: §4.2 contrast capability + fitted() contrast axis, T2-7 crossover +
committed simulation artifact, §4.5 wall with 15/15 evasion recatch + identity-based audit
ratchet, ANL declaration, sync-script fix, T2-9..22). Every batch went implement → adversarial
review → fix → closure.

**Track B** (`claude/food-search-2026-08-22`): item 1 `c6cb9c2`, 2 `8c55627`, 3 `5ee31f0`,
4 `a3962e4`, 5+6+7 `809e25e` (corpus 70%→53% failure), **5b `f83d327`** (nutrition plausibility
gate, CFR-derived regimes), **8 `9aa090a`** (local correction memory — note: §26 row 1.10's
prescribed mechanism was PROVEN unimplementable; ledger 8b has the argument).

**Home** (owner interjection): `4bd4d20` on its own branch — photo frames restored to
pre-redesign 104×92, Customize tucked trailing. Screenshots delivered; owner visual sign-off
still pending. Merges LAST (after A and B) — it edits HomeView.swift, which A-track also edits.

## Implemented, UNCOMMITTED — the two first moves

1. **Item 9 (1.9 history-first ranking)** — food worktree diff over `9aa090a`. Ledger row 9b has
   the full report. FIRST MOVE: adversarial review (Opus, fresh agent — session 2's agents are
   gone). Attack targets named in the row: the `scoredMatches` tuple refactor, the
   `stripsStopwords` typed-only narrowing, the didSet/init publish seam pair, correction-wins
   precedence composition, the prose-not-table-row wipe decision (derived surface, no
   wipeManifest token), decay-at-publish staleness. Then fix → closure → **you commit**.
2. **Chip 44pt growth (T1-9 second half)** — a11y worktree diff over `ba6d561`, already
   adversarially reviewed. Verdict RETURN-FOR-FIX, short precise list (ledger row 6a): (a) update
   MoveView.swift:1873's now-false detent doc; (b) as a SEPARATE attributed change, delete the 2
   recipe-sheet baseline entries citing the sub-44pt `TextField("Qty")` at FoodView.swift:2046
   whose `.hitRegion` audit finding flaps non-deterministically (PROVEN pre-existing at ba6d561),
   and correct the falsified determinism claim at UXScreenProbe.swift:339-340; (c) optional F2/F3/F4
   wording items. The FoodView.swift:2527-2531 comment fix is FENCED → reconciliation list. Then
   **you commit** (reviewer's core-mechanism verdict already stands; a light closure check of the
   fix's own edits suffices).

## Then, in order (all deferred from session 2)

1. Track B items 10–13 (one increment = one commit each; models + cautions in the ledger's
   standing sections and the 2026-08-23 owner decisions):
   - 10: 1.11 composer search field + empty states (Opus; artboards 4a–4g in `Docs/design-refs/`;
     absorbs the FoodView reconciliation-adjacent items — brand-chip copy, createdNotice toast,
     bare ProgressView, moss macro rows, and now the FOOD-08 comment + Smart Invert sites if
     convenient). **AI overlap (owner 2026-08-23, see `Docs/AI-Alternate-Track-Plan-2026-08-23.md`
     §5): the composer layout must NOT preclude the future "draft from a description" AI
     affordance — reserve the empty-state seam; build no AI UI yet (diagnosis-first decision).**
   - 11: 1.12 whole-description probe (Opus; needs a genuinely high floor; corpus measured).
   - 12: 2.4 RecipeUnit slice/piece + 2.5 scale fallback (Sonnet; FernletDomainModel enum change
     → CLEAN BUILD; ramen 46k-kcal case is the acceptance case). **AI overlap: this unit model is
     the substrate for NL→portions (AI plan §2 E2) — the increment's report must state what E2's
     portion conversion can rely on.**
   - 13: 2.1 FNDDS + 2.2 ingredients + 2.3 brand_source FTS, ONE regeneration (Opus; **the
     regenerated FoodCatalog.sqlite is NEVER COMMITTED — owner decision 2026-08-23**; code +
     generator only; tests green against the COMMITTED catalog; FNDDS additive; read the
     ODR-cap arithmetic note in 809e25e).
2. Option 1.7(b) score-first ranking (Opus; owner-authorized; full corpus + resolver-bank +
   review-battery protocol; every flip justified; DishTemplateBindAudit re-pins).
3. Re-derive `confidentBindScore` (Opus; AFTER 1.7b; against the pinned calibration population).
4. Q2 provenance recovery (Explore/Sonnet; `mcp__ccd_session_mgmt__search_session_transcripts`
   over ~July 2026 sessions that generated CuratedSurveyFoodItems.json; report to owner, no
   deletion without their call).
5. StoragePrivacyUITests restore-prompt false-match fix (Sonnet; tighten the predicate to an
   accessibilityIdentifier — frozen token; OnboardingStorageChoiceView.swift:114 is the false
   match).
5b. **AI increment D (bypass diagnosis)** — may run any time budget allows (read-only, collides
   with nothing; brief in `Docs/AI-Alternate-Track-Plan-2026-08-23.md` §1). The rest of the AI
   plan (E/F/G) runs AFTER this round completes; fold the AI on-device validations (AI-tier gate
   wiring, item 9 history tier, D's device checklist) into ONE endgame device session.
6. Endgame: full-suite gauntlet per branch (batch by suite, clean build first; scanners at zero;
   spm-wall-check with the private-DD workaround; `sync-string-catalogs.sh --check` will exit 1
   on the food branch's deliberately-unsynced keys — attributed, known: **22 FernletDomainModel
   keys + 7 app-target keys**). **ASK THE OWNER before merging anything to main.** Merge order:
   A → main, then B rebased, then reconciliation batch (list in the ledger — includes T2-4,
   T2-14 food surfaces, T2-10 Smart Invert ×3 + allowlist-entry deletions, FoodView moss swaps,
   createdNotice toast, FOOD-08 comment, .combine-allowlist re-verify), then Home visuals last
   (HomeView conflict expected, trivial). ONE catalog sync post-merge. Final report per the
   ledger's owner-decisions section (open: §37 Q7 TBD, Q2 pending provenance task, Q6 pending
   item 13; Q9 CLOSED — no paid data EVER, standing principle).

## Owner-flag queue (surface in the final report; do not act unprompted)

- Home visuals `4bd4d20`: visual sign-off pending.
- Item 8's "Forget corrected searches" row: placement inside the export card = IA judgment call;
  the row itself was reviewer-prompted and is vetoable.
- A5: `LogWaterIntent` Siri-visible rename ("Log a bottle of water" → "Log water") — vetoable.
- CookingLiveActivityIntents has the identical Siri silent-no-op defect — out of scope, unfixed.
- A5 residuals ledgered: PeriodTemperatureUnit selection not persisted (needs disposition row if
  made durable); CyclePhase.title .capitalized render; audit Code=-56 timeout under load
  (XCTSkip recommendation); paged-TabView covered-tap + .accessibilityValue-on-.contain +
  AX5 custom-content announce + lock-gate TOUCH-BLOCKING = manual device checks.
- Item 8/9 residuals: AI-tier gate wiring on the real model path needs on-device validation;
  DEFEAT-A' reachability-blindness class documented-open.

## Process rules (unchanged from session 2 — they earned their keep)

Per-increment loop: implement (background) → adversarial review by a DIFFERENT Opus agent told to
REFUTE → fix pass (SendMessage back to the implementer — it keeps context) → closure verification
by the ORIGINAL reviewer → orchestrator's quick independent check (scanners at minimum) →
**orchestrator commits** (explicit pathspec, never `git add -A`; message names item IDs) → ledger
row. Every closure verify in sessions 1–2 caught something real — do not skip. Reviews/closures =
Opus always; pass `model:` explicitly. Suite-level `-only-testing:` only; log to file,
`echo EXIT=$?`, Read the log; `✔ Test run with N tests` lines. No red from an incremental build
is actionable. Known flakes (attribute, don't debug): ProximityCoordinator heartbeat,
CaptureProtection cover, StoragePrivacy restore-prompt (fix queued above), audit Code=-56 under
load. Walls: frozen tokens never localize; approved hexes only, recompute ratios; no new
deps/endpoints; P10 ≤60 lines + scanners 0 + density ≥0.68; corpus re-baselines only with
per-query justification; `normalized()` load-bearing; §29 coupling (1.6/1.7/1.8 one unit).
Owner decisions in the ledger are settled — do not re-litigate.

**Start with the two first moves (item 9 review; chip-growth narrow fix), concurrently, AFTER
confirming usage budget with the owner. Do not merge anything to main without asking.**
