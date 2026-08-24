# Continuation prompt — 2026-08-22 parallel round, session 2

You are the **orchestrator** for the continuation of Fernlet's two-track round (accessibility +
food search). You are running as Fable. **You dispatch, verify, commit and account. You do not
implement.** Every code read, edit and test run happens inside a subagent; you keep only its
structured result. The previous session's full state is in
`Docs/Round-2026-08-22-Progress.md` — **read it first, it is the authoritative ledger.** Update it
after every commit. The two research reports are `Docs/Accessibility-Review-2026-08-22.md` and
`Docs/Food-Search-And-Community-Database-Research-2026-08-22.md` (untracked in the main tree,
copied into both worktrees).

## Usage monitoring (binding)

At every increment boundary, check your remaining session tokens (`<total_tokens>`). If the
remainder is below ~1.5M — enough for one increment + adversarial review + closure + commit +
handoff — **stop cleanly**: update the ledger, write a fresh continuation prompt like this one, and
report. Never start an increment you cannot finish. The owner also tracks plan usage externally;
keep agent prompts tight and never spawn agents whose result you won't use.

## Infrastructure (already exists — do not recreate)

- Worktrees: `/Users/michaelbowman/Desktop/Fernlet 5-18/fernlet-wt-a11y` (branch
  `claude/a11y-2026-08-22`) and `…/fernlet-wt-food` (branch `claude/food-search-2026-08-22`),
  both rooted at main `b259f3d`.
- DerivedData: `/tmp/dd-a11y` and `/tmp/dd-food` — never shared, always passed explicitly.
- Dedicated simulators: `Fernlet-A11y` = BBB73DF2-0E2E-4B2F-B437-58DBF12D563B,
  `Fernlet-Food` = B2A0DAC3-B9AC-4018-BC4B-C23D53AEA2D7 (iPhone 17, iOS 26.5). Other booted sims
  belong to other sessions — never touch them. `pgrep -fl "xcodebuild|XCBBuildService"` before
  full-suite runs.

## Completed (do not redo)

**Track A — `claude/a11y-2026-08-22`, 4 commits:**
- A1 `59fde3b` (Tier 0: T0-1..7 + dark launch + AssistiveAccess), A2 `886a352` (shared
  components/tokens), A3 `26e4b89` (FernletAnnouncer/widgets/companion), A4 `7a115ad` (§4.0
  catalogs + localization-wall accessibility half). Each went through implement → adversarial
  review → fix → closure-verify.
- **A5 is IMPLEMENTED and UNCOMMITTED** (53 files in the a11y worktree): §4.2 contrast capability,
  T2-7 threshold fix (0.46→0.1791), §4.5 wall both halves (119 audit issues ratcheted),
  `Docs/Accessibility-Nutrition-Labels.md`, Q2 hygiene fix, T2-9/10/11/12/17/18/20/22. See the
  ledger's 5a row for its self-reported findings and premise refutations.

**Track B — `claude/food-search-2026-08-22`, 5 commits:**
- Item 1 `c6cb9c2` (57-query corpus instrument), item 2 `8c55627` (bind floor + derived
  confidence), item 3 `5ee31f0` (template data + count parsing), item 4 `a3962e4` (brand tokens →
  review), items 5+6+7 `809e25e` (dual floor + guarded demotion + position stopwords — headline
  70% → 53% failure, zero regressions).
- **Item 5b is IMPLEMENTED + REVIEWED + FIX-PASSED and UNCOMMITTED** (plausibility gate; the fix
  pass addressed 14 findings incl. a §40.9 breach and a live regression; 243-test battery + 9/9
  mutation harness green). Needs closure verification then commit.

## Remaining work, in order

### First moves (dispatch these two concurrently)

1. **Item 5b closure verification** (Opus): targeted verify of the fix pass against the review's
   14 findings (the review report is summarized in the ledger's 5bb row; the reviewer verified
   authorities at primary sources — hold the fix to that standard). On closure: **you commit** with
   explicit pathspec, message naming item 5b/fix 1.14 and the §40.9 discipline.
2. **A5 adversarial review** (Opus, different agent from the implementer): full refutation pass on
   the 53-file diff. Priorities: recompute the §4.2 ratios independently; replay the T2-7
   512-background simulation claim; attack the §4.5 scanner rules with planted evasions (the A4
   review found 8/8 evasions on that batch's first wall attempt — expect the same); verify the
   audit ratchet discriminates and the 119-issue baseline is honest; check the ANL declaration's
   three declared rows against their claimed verification bases; verify the Q2 and wizard-PIN
   premise refutations (both have probe evidence); confirm the new findings (MilestonesView.headline
   live bug, DeleteEverythingSheet AX5 collapse, gate re-lock routes) are real and triaged. Then
   fix pass → closure → **you commit A5**.

### Then Track B items 8–13 (sequential, one increment = one commit each)

| Item | Work | Model | Cautions |
|---|---|---|---|
| 8 | 1.10 local correction memory | **Opus** | Persisted surface → `Docs/PrivacyWipeCoverage.md` disposition row + delete-everything path IN THE SAME COMMIT |
| 9 | 1.9 history-first ranking | **Opus** | Same persisted-surface rule; §26's prescription; corpus flips need per-query justification |
| 10 | 1.11 composer search field + empty states | **Opus** (FoodView UI + design refs) | Keys off artboards 4a–4g (`Docs/design-refs/`); THIS is where the reconciliation-adjacent FoodView items can ride: brand-chip copy fix (item 4's F3 residual), createdNotice toast adoption, bare ProgressView, the moss macro rows — check the ledger's reconciliation list and fold in what belongs to FoodView |
| 11 | 1.12 whole-description probe | **Opus** | Needs 1.5 landed (it is) + a genuinely high floor; corpus measured |
| 12 | 2.4 RecipeUnit slice/piece + 2.5 scale fallback | **Sonnet** | `FernletDomainModel` enum change → **CLEAN BUILD** (the stale-binary hazard is documented and has produced phantom failures twice this round); the ramen 46k-kcal serving-unit case from the ledger is this item's acceptance case |
| 13 | 2.1 FNDDS dishes + 2.2 ingredients + 2.3 brand_source FTS — ONE regeneration | **Opus** | **OWNER DECIDED (2026-08-23): the regenerated FoodCatalog.sqlite is NEVER COMMITTED — it stays local due to size.** Commit code + generator only. Tests must stay green against the COMMITTED catalog; verify the regenerated binary locally and document its expected vintage so the corpus vintage pins flip only when the owner deliberately places the new file (that placement is an owner release step; distribution mechanism, e.g. the ODR pattern, is a future decision). FNDDS is ADDITIVE (never delete CuratedSurveyFoodItems.json — Q2 revisit pending the provenance task below). The retrieval/scorer asymmetry fix (in 809e25e) recorded ODR-cap arithmetic that 2.3 grows — read it. |

### Newly authorized by the owner (2026-08-23) — after item 13, in this order

| Work | Model | Notes |
|---|---|---|
| **Option 1.7(b) — score-first ranking** (§30 row 17; sign-off now GRANTED) | **Opus** | The only path to the mozzarella/cheese-pizza/broccoli/chickpeas class (proven this round). Full corpus + resolver-bank + review-battery measurement protocol; every flip justified per-query; the DishTemplateBindAudit's confident set will move — re-pin with justification. Adversarial review non-negotiable — this re-ranks every search surface. |
| **Re-derive `confidentBindScore`** (currently 250) | **Opus** | AFTER 1.7(b) — it re-ranks and shifts scores; calibrate once. Measured against the corpus + the pinned calibration population (`confidentBindPopulationIsPinnedForCalibration`); two other tiers gate on the constant. |
| **Chip 44pt growth** (T1-9's second half; owner ACCEPTED the ~10pt row spread) | **Sonnet** | A-track increment after A5 commits, before merge. ChipButtonStyle minHeight 44 + compensations; re-run the UI label sweep. |
| **Q2 provenance recovery** (owner: revisit) | **Explore/Sonnet** | Search old session transcripts (~July 2026) that generated `CuratedSurveyFoodItems.json` and the food catalogs to recover the curation criteria — the `mcp__ccd_session_mgmt__search_session_transcripts` tool exists for exactly this. Report findings to the owner; no deletion without their call. |
| **Fix StoragePrivacyUITests restore-prompt false match** (was a task chip; owner moved it here) | **Sonnet** | `testOnboarding_noExistingCloudData_noRestorePrompt` fails deterministically on account-less sims: the predicate `label CONTAINS[c] 'Restore'` also matches the detection-failure copy at `OnboardingStorageChoiceView.swift:114`. Tighten to the actual restore-prompt element (prefer an accessibilityIdentifier — frozen token). Proven pre-existing at baseline twice this round. |

Items 14–16 remain **out of scope** (item 17 = 1.7b is now authorized above).

### Then the endgame (in this order)

1. **Full-suite gauntlet on each branch**: batch by suite, clean build first, `Scripts/power-of-10-scan.py`
   + `Scripts/doc-coverage-scan.py` at zero, `Scripts/spm-wall-check.sh` passing,
   `Scripts/sync-string-catalogs.sh --check`.
2. **Ask the owner before merging anything to main** (standing instruction). Merge order:
   **A → main first** (it owns the shared UI kit), then **B rebased on top**, then the
   **reconciliation batch** (contents listed in the ledger — T2-4 MealRow, T2-14 announcements,
   FoodView leftovers not absorbed by item 10, the FoodView `.combine`-allowlist re-verify).
3. **One catalog sync** (`Scripts/sync-string-catalogs.sh`) after both tracks merge — 21+ keys are
   deliberately unsynced to avoid cross-track conflicts; this is the single deferred sync.
4. Final report: what landed, what deferred and why, what the reviews caught, budget remaining.
   **Most owner questions are now DECIDED — see the ledger's "OWNER DECISIONS — 2026-08-23"
   section** (1.7b authorized; confidentBindScore re-derive; binary never committed; chip growth
   accepted; .medium/merged-stamp/CLAUDE.md closed). Still genuinely open: §37 Q7 (TBD — owner
   guidance: disambiguation may come from the surrounding natural language, not the lexicon),
   Q2 (pending the provenance-recovery task), Q6 (pending item 13's report), and the
   future-round items (web-lane consent, schema optionality, NL→portions design, ODR flag
   paragraph). Q9 is CLOSED: **owner ruling — no paid data, ever; publicly available data
   only.** This is a STANDING DATA-SOURCING PRINCIPLE: if any agent proposes a commercial data
   source or vendor contact, reject it and cite this ruling.

## Process rules (these earned their keep — do not relax them)

- **Per-increment loop**: dispatch implementation (background) → agent builds/tests → adversarial
  review by a DIFFERENT Opus agent told to REFUTE → fix pass (back to the implementer via
  SendMessage — it keeps context) → closure verification by the ORIGINAL reviewer → you run a
  quick independent suite check → **you commit** (explicit pathspec, never `git add -A`; message
  names item IDs) → ledger row. Every closure verify this round caught something; do not skip them.
- **Models**: implementation per the table above; ALL reviews and closure verifies = Opus. Pass
  `model:` explicitly on every Agent call. Never let an implementer review its own work.
- **No red from an incremental build is actionable** — clean build, re-run in isolation, then
  judge. Runner hangs ("hung before establishing connection") → `simctl shutdown`+boot+retry once.
  Kill-signal waves = another session's contention. `ProximityCoordinatorTests` heartbeat +
  `CaptureProtectionUITests` cover test + `StoragePrivacyUITests` restore-prompt (chipped) are
  known flakes — attribute, don't debug.
- Suite-level `-only-testing:` only (method-level runs zero tests with a green banner). Log to a
  file, `echo EXIT=$?`, Read the log — never trust a chained notification exit code. This repo's
  suites emit Swift Testing `✔ Test run with N tests` lines.
- **Walls**: frozen tokens never localize; display via LocalizedStringKey/Text/LocalizedStringResource
  (package announce() calls use `resolved:` — enforced); approved hexes only, recompute every ratio;
  no new deps/endpoints; Power of 10 ≤60 lines + scanners at zero + density ≥0.68 (currently
  0.681–0.685); corpus re-baselines only with per-query justification; the §29 coupling — 1.6/1.7/1.8
  changes are measured as one unit; `normalized()` is load-bearing for count math.
- Owner decisions in the ledger's §4-decided list are settled — do not re-litigate (no hosted UGC,
  1.7a-only, ODR catalog untouched, ANL ruling). Decisions in the open list are surfaced, never taken.

**Start with the two first-moves above, concurrently. Do not merge anything to main without asking
the owner first.**
