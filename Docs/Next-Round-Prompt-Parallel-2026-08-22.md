# Continuation prompt — parallel accessibility + food-search round (written 2026-08-22)

Everything above the rule is context for you, the owner. Paste the block below the rule into a fresh
**Fable 5** session started in this repo.

**Supersedes** `Docs/Next-Round-Prompt-Accessibility-2026-08-22.md`, whose premise ("wait for the peer
session to commit") is obsolete — that branch merged to `main` as `b259f3d` and is pushed. You can delete
the old file.

**Both source reports are untracked on disk.** `Docs/Accessibility-Review-2026-08-22.md` and
`Docs/Food-Search-And-Community-Database-Research-2026-08-22.md` exist in the working tree but are not in
git, so a fresh clone or a worktree checkout will **not** have them. The prompt handles this (the
orchestrator copies them into each worktree), but do not `git clean` this directory.

**Launch note on budget.** If you want a hard usage ceiling, launch the session with a token target
(e.g. append `+2M` to your first message). That makes `budget.total` / `budget.remaining()` real inside
Workflow scripts, and the prompt below tells the orchestrator to gate every dispatch on it. Without a
target, `budget.remaining()` is `Infinity` and only the checkpoint discipline protects you — which is
still enough to make any cutoff resumable, just not predictable.

---

## Prompt to paste

You are the **orchestrator** for a two-track implementation round on Fernlet. You are running as Fable 5.

**Your job is to dispatch, verify, commit and account. You do not implement.** Beyond the small reads
listed in Step 0, do not open source files yourself — every code read, edit and test run happens inside a
subagent, and you keep only its structured result. Context conservation is a first-class constraint of this
round: if you find yourself reading a 4,000-line view, you have already made a mistake.

### 0. Ground yourself (do this yourself, it is small)

```bash
cd "/Users/michaelbowman/Desktop/Fernlet 5-18/Fernlet"
git log --oneline -3 && git status --short && git rev-parse --short origin/main main
```

Expect `main` == `origin/main` == `b259f3d` and a clean tree apart from three untracked `Docs/*2026-08-22*`
files. If that is not what you see, stop and tell me before doing anything else.

Then read **only these**, and only the sections named:

- `Docs/Accessibility-Review-2026-08-22.md` — §3 (the 38-item roadmap tables), §4 (systemic moves), §7
  (sequencing). Skip the per-item prose; the implementing agents will read it.
- `Docs/Food-Search-And-Community-Database-Research-2026-08-22.md` — §1 (the answer), §29 (the coupled-fix
  hazard), §30 (the order to do this in). Skip Parts I–IV entirely; they are argument, not instruction.
- Your memory files `accessibility-review-2026-08-22`, `food-search-research-2026-08-22`,
  `fernlet-design-token-contrast`, `concurrent-sessions-shared-worktree`,
  `fernlet-domainmodel-clean-build-hazard`, `run-fernlet-tests-in-batches`.

That is your whole personal read. Everything else is delegated.

### 1. The two tracks

They are independent enough to run in parallel, and they will run in parallel, in **separate git
worktrees** so neither can revert the other or corrupt the other's DerivedData.

**Track A — Accessibility. All five batches** of the report's §7 sequencing, in order:

| Batch | Contents | Report est. |
|---|---|---|
| A1 | Tier 0: T0-1 … T0-7 — the lock gate, the unlock keypad, the calm tools, the destructive clock | 3–4 days |
| A2 | T1-1, T1-3, T1-4, T1-5, T1-6, T1-8, T1-9 — shared components and tokens | ~1 week |
| A3 | T1-2, T1-7, T1-10, T2-3, T2-5, T2-13, T2-15 — the announcer, focus convention, widget target | ~1 week |
| A4 | §4.0 first, then T2-1, T2-8, T2-16, T2-19 — the localization wall's accessibility half | ~1 week |
| A5 | T2-2, T2-4, T2-6, T2-7, T2-9, T2-10, T2-11, T2-12, T2-14, T2-17, T2-18, T2-20, T2-21, T2-22, plus §4.5's accessibility wall and the `Docs/Accessibility-Nutrition-Labels.md` declaration | 1–2 weeks |

**Track B — Food search. Items 1–13 of §30's order**, and no further:

| Item | Work | Note |
|---|---|---|
| 1 | The 57-query corpus test (Appendix A) | **Hard prerequisite. Nothing else in Track B dispatches until this is green and committed.** |
| 2 | 1.1 lexicon confidence + 1.2 bind floor | The highest-leverage pair in the report |
| 3 | 1.3 template data audit + 1.4 unit-word parsing | Replay every edited search string against the shipped catalog before committing |
| 4 | 1.5 unmatched brand/retailer tokens | |
| 5 | 1.8 score floor | |
| 5b | 1.14 plausibility + completeness gate | Independent — dispatch in parallel with 5/6/7 |
| 6 | 1.7**(a)** data-type demotion via `PreparedDishHeuristic` | **(a) only. See §4 below.** |
| 7 | 1.6 stopwords | **Must land with 5 and 6 as one unit** |
| 8 | 1.10 local correction memory | |
| 9 | 1.9 history-first ranking | New persisted surface → wipe-disposition row in the same commit |
| 10 | 1.11 composer search field + empty states | Keys off artboards 4a–4g |
| 11 | 1.12 whole-description probe | Needs 1.5 landed + a genuinely high floor |
| 12 | 2.4 `RecipeUnit` slice/piece + 2.5 scale fallback | `FernletDomainModel` enum change → **clean build required** |
| 13 | 2.1 FNDDS dishes + 2.2 FNDDS Ingredients + 2.3 `brand_source` FTS — **one regeneration** | **Stop before committing the regenerated binary. See §4.** |

Items 14–17 (persisted per-component bind score, web-lane consent prompt, partial-match fallback,
score-first ranking) are **out of scope**. Do not start them; note them in the ledger as deferred.

### 2. Isolation, and the one place the tracks collide

Create one worktree per track before dispatching anything:

```bash
git worktree add ../fernlet-wt-a11y   -b claude/a11y-2026-08-22 main
git worktree add ../fernlet-wt-food   -b claude/food-search-2026-08-22 main
```

Copy the two untracked reports into each worktree's `Docs/` — they are not in git and the agents need them.
Give each track its **own** `-derivedDataPath` (`/tmp/dd-a11y`, `/tmp/dd-food`) on every build and test
command. The shared-DerivedData hazard is documented in project memory and has cost this project real time.

**The collision is `App/Fernlet/FoodView.swift`, and it is not small.** Track A touches it at T1-4
(`:2266`), T2-4 (`MealRow`) and T2-14 (search-result announcements); Track B rewrites large parts of it at
1.10 (`:4145-4153`) and 1.11 (`:2188`, `:2016`, `:4208`, `:1900`). Both tracks may also touch
`FernletKit/Sources/FernletUI/` (Track A at T1-1/T1-3/T1-9/§4.0, Track B at 1.11's row reuse).

**The rule: Track B owns `FoodView.swift` outright.** Track A's three items in that file are **deferred to
a reconciliation batch** that runs after both tracks merge — do not dispatch them inside A2/A3/A5, and mark
them `DEFERRED-TO-RECONCILE` in the ledger when their batch would otherwise reach them. For
`FernletKit/Sources/FernletUI/`, Track A owns it; Track B must consume its components and must not edit
them — if Track B needs a change there, it files it in the ledger and Track A's next batch makes it.

Merge order at the end: Track A to `main` first (it owns the shared UI kit), then Track B rebased on top,
then the reconciliation batch.

### 3. Model assignment

| Work | Model | Why |
|---|---|---|
| Orchestration, ledger, dispatch, merge decisions | **Fable** (you) | Cheap coordination; you hold no file content |
| High-judgment implementation | **Opus** | T0-1 lock modality, T0-3/T1-2 the announcer seam, §4.0 the string-catalog decision, T2-6 the contrast capability; Track B items 1, 2, 6, 7, 9, 11, 13 — anything touching the comparator, a persisted surface, or the coupled ranking unit |
| Mechanical / high-volume implementation | **Sonnet** | T1-1 heading traits, T1-5 `.isSelected`, T1-8 glyph hiding, T1-7 widget labels, T2-10 invert-colors, T2-13 `ProgressView` labels, T1-9 tap targets; Track B items 3, 4, 5, 12 — data audits, replays, mechanical threading |
| Adversarial review after every batch | **Opus** | Must be a *different* agent than the implementer, told to refute, not to confirm |
| Capstone review before each track's merge | **Opus** | Whole-branch diff review |

Pass `model:` explicitly on every `Agent` call. Never let an implementation agent review its own work.

### 4. Owner decisions already made — do not re-litigate these

- **Q1 is settled: no hosted user-uploaded food database.** Not now, not in this shape. If any agent
  proposes a submission pool, a server, or an account, reject it and cite §21.
- **1.7(a) only.** Demote via `PreparedDishHeuristic` inside `results()`/`scoredResults()`. **Score-first
  (1.7b) is explicitly NOT authorized** — it re-ranks every search surface in the app and is a product
  decision. If an agent argues for it, record the argument in the ledger and move on.
- **Item 13's regeneration is authorized, but committing the regenerated binary is not.** The LFS question
  (~57 MB per regeneration, no `.gitattributes`, path currently has 2 commits) is deliberately deferred.
  So: build the generator changes, run the import, verify the query side, and then **stop, leave the new
  `FoodCatalog.sqlite` uncommitted, and ask me** whether it goes in as a plain blob or behind LFS. Commit
  the *code* and the *generator* in that increment; hold the binary.
- **The branded ODR catalog stays exactly as it is.** Do not un-gitignore the 178 MB binary, do not add
  target membership, do not change `BrandedODRCatalogTests` from skip to fail. Instead, record one
  paragraph in the ledger: that `BrandedCatalogResourceLoader`, its DocC page, `Docs/FileIndex.md:345` and
  the No-Tracking-Wall entry describe a capability the shipped binary does not have. That is a flag, not a
  work item.
- **Accessibility Nutrition Labels: declare Dark Interface at first submission**, plus Reduced Motion and
  Differentiate Without Color **only if** batch A2 lands and is verified. Leave Captions and Audio
  Descriptions blank as genuinely inapplicable — not "not supported". Everything else stays undeclared
  until its blocker clears; §5 of the report has the row-by-row gate.

### 5. Owner decisions still open — surface, do not decide

Collect these in the ledger with your recommendation and stop short of acting:

- §37 Q2 — replace the 202-row `CuratedSurveyFoodItems.json` wholesale with FNDDS? The report recommends
  yes. **But there is no curation script in the repo, so the original selection criteria are unrecoverable
  from source.** Proceed with FNDDS as an *additive* layer in item 13; do not delete the curated file
  without asking me.
- §37 Q5 — turn the web nutrition lane on by consent prompt instead of the buried Settings toggle.
- §37 Q6 — does a new `FoodItemSource` provenance case get minted for curated rows, or do they reuse
  `.aiResolved` / `.branded`? **Frozen-token, synced-blob decision.** Do not mint one unilaterally.
- §37 Q7 — should `queryContainsBrandToken` match on token boundaries? Fixing it breaks multi-word entries
  unless the lexicon is restructured into phrase-vs-token sets.
- §37 Q9 — the Syndigo/Nutritionix caching-scope email. **This is a sales-contact action and it is mine to
  send, not yours.** Do not contact any vendor.
- The three SwiftUI grouping questions the audit could not resolve without running the app (below).

### 6. Three things to settle early with the Accessibility Inspector

Two of them change Track A's scope by an order of magnitude, so dispatch this as the **first** A-track
agent, before A1's implementation, with the simulator:

- `HomeView.swift:2381` — does `HealthBar`'s accessibility label attach to anything at all?
- `HomeView.swift:2700-2734` — does the outer `Button` swallow the nested hygiene toggles?
- `WorkoutLocationSetupView.swift:699-750` — buttons nested inside a button.
- And the general rule it needs: does a parent `.accessibilityLabel` override a child's? This decides T1-10.

### 7. The per-increment loop

An **increment** is one unit of work that ends in one commit. Never dispatch an increment larger than that.

1. **Budget gate.** Before dispatching, check `budget.total`. If a target was set, and
   `budget.remaining()` is below your estimate for this increment plus its review pass, **stop cleanly**:
   write the ledger, print the resume line, and tell me how much is left. Do not start work you cannot
   finish. If `budget.total` is null, no ceiling was set — say so once, and rely on step 6's discipline.
   (I can check real account usage with `/usage` in an interactive terminal; you cannot, so do not claim to.)
2. **Dispatch implementation** to Opus or Sonnet per §3. The agent gets: the item IDs, the report path and
   the exact sections to read, its worktree path, its `-derivedDataPath`, the constraint list from §8, and
   an instruction to return a structured result — files touched, decisions made, anything it could not do.
3. **Build and test** inside the worktree. Batch tests by suite, never as one run, and **check the exit
   code, not a grep** — the success banner is `TEST EXECUTE SUCCEEDED`. Run
   `Scripts/power-of-10-scan.py` and `Scripts/doc-coverage-scan.py` before every commit; both must be zero.
   Run `Scripts/sync-string-catalogs.sh --check` on any increment that adds display strings.
4. **Adversarial review** by a *different* Opus agent, told to refute the implementation, not to confirm
   it. Feed it the diff, not the whole tree.
5. **Fix** what the review confirms, re-verify, then commit with a message that names the item IDs.
6. **Update the ledger** — `Docs/Round-2026-08-22-Progress.md`, one row per increment: item IDs, commit
   SHA, test suites run, deferred/blocked notes. Write it after *every* commit, not at the end. This file
   is what makes a mid-round cutoff survivable: any future session resumes from it with no other context.

### 8. Constraints that will bite an agent that skips them

Put these in **every** implementation agent's prompt — they are not optional background:

- **Localization wall.** Display text is `LocalizedStringKey`/`Text`, never a bare `String` — a `String`
  parameter silently opts the call site out. Inside an SPM module you must pass `bundle: .module` or it
  renders English forever with a clean build. `accessibilityIdentifier` is a **frozen English token** —
  never localize it. Same for persisted `rawValue`s, mesh wire bytes, AI prompt vocabulary, dictionary keys
  and matching inputs (including Track B's unit-word token set — the *token* is frozen, the *displayed*
  unit localizes).
  **Sharp edge:** `AccessibilityNotification.Announcement` takes a `String`, so any announcer API must be
  `LocalizedStringResource` at its surface or every announcement in the app ships English.
- **`FernletUI` has no string catalog** (§4.0). Any literal added *inside* that module resolves against
  `Bundle.main`. This silently blocks six proposed fixes — it must be resolved at the head of batch A4, and
  no earlier batch may add a literal there.
- **Power of 10.** ≤ 60 code lines per function *and* per `body`; no recursion; every loop bounded; no `!`,
  `try!`, `as!`, `fatalError`; no swallowed `try?`; no mutable globals. Several targets are already near the
  ceiling — `ContentView.customTabBar` is 54/60 and `CompanionVectorAssets.body` ~58 — and need an
  extraction *first*. `Scripts/power-of-10-scan.py` must stay at zero violations with assertion density
  above the 0.68 floor.
- **Never invent colors.** `Docs/design-refs/ux-review-2026-08-16/design-spec-2026-08-21.md` specifies and I
  have already approved: moss ink `#46683A` (5.54:1), Increase Contrast `slate → #45535E` (6.90:1),
  `filled moss → #38562C` (7.22:1). None exist in code yet. Recompute any ratio you rely on — agent
  estimates in this area were wrong by up to 1.5×.
- **`FernletDomainModel` clean-build hazard.** Any enum or struct change in that package (Track B item 12's
  `RecipeUnit`, and anything touching a synced snapshot) requires a **clean** build. Incremental builds mask
  non-exhaustive switches and ship corrupted binaries.
- **New persisted surfaces need a `Docs/PrivacyWipeCoverage.md` disposition row in the same commit**, plus
  inclusion in the delete-everything path. Track B item 9 (history-first ranking) is exactly this.
- **The coupled-fix hazard (§29).** Track B items 5, 6 and 7 make each other worse in isolation — naive
  stopword stripping alone turns the tester's query from a defensible answer into a 1,655 kcal calzone.
  They land and are measured as **one unit** against the corpus test from item 1.
- **No new outbound network destination, no new SPM dependency.** Neither track needs one. If an agent
  proposes either, it is wrong — the no-tracking wall fails CI until a destination is allowlisted in
  `Tests/FernletTests/NoTrackingBoundaryTests` *and* documented in `Docs/No-Tracking-Wall.md` in the same
  commit, and that is a wall amendment requiring my sign-off, not a feature.
- **Two paths both reports cite incorrectly:** `CaptureProtection.swift` is at
  `FernletKit/Sources/FernletUI/CaptureProtection.swift` (the T1-2 announcer source pattern is at `:144-152`),
  and `CustomIngredientUpsert.swift` is at `FernletKit/Sources/FernletDomainModel/CustomIngredientUpsert.swift`
  (Track B item 5b's seam — note it is inside an SPM module, so `bundle: .module` applies to its warning copy).

### 9. Do not do these — reasons already recorded, do not reopen without new information

Accessibility Tier 3: per-cell VoiceOver for the pixel canvas (1,920 cells); Bold Text (Instrument Serif is
single-weight — a typeface problem, not a missing check); `accessibilityRotor` anywhere (headings deliver
~90% of the value); `AXChartDescriptor` (no `import Charts` in the tree); CoreSpotlight indexing (copies
sealed content outside the lock gate and the wipe path — a privacy regression); a blanket
`.accessibilityHidden` sweep of all 294 SF Symbols (~10 sites actually matter).

Food Tier 3 and the four non-recommendations in §2: a global upload pool; a runtime nutrition API
(FatSecret 24h, Spoonacular 1h, Edamam six-fields, Nutritionix $999/mo with undefined scope); an
`ORDER BY rank` refactor (requires dropping `columnsize=0` and regenerating); `optimize` at build time
(already done at `FoodCatalogDatabaseBuilder.swift:74`).

Also do not redo the accessibility work that already landed — §2 of the report lists eight things that are
already correct, including the 44pt/label helper pair, `ChipButtonStyle`'s selection traits, and
`CaptureProtection`'s entire pattern. Commit `f053be2` already fixed the obvious layer six days ago.

### 10. Calibration on both reports

Neither report is gospel and both say so.

- **Accessibility:** 0 of 270 findings were refuted outright, but 99 were downgraded to PARTIAL and every
  impact-5 was cut to ≤4. **A 0% refutation rate is the lenient-verifier signature.** The report's "What I
  re-verified by hand" table lists exactly what was checked at the code — T0-1, T1-1, T1-7, the hex values,
  the opacity math, every source-comment contrast claim. **Anything not in that table gets re-checked at
  the code before an agent builds on it.**
- **Accessibility line numbers are stale.** 65 findings are marked † because they were taken against a tree
  that has since merged as `b259f3d`. Every † item's line numbers must be re-derived before editing —
  instruct agents to locate by symbol, not by line.
- **Food:** §33 is an explicit confidence ledger and §32 records corrections the memo applied to its own
  source research. Re-measure anything load-bearing. The measured claims that matter most — 11 of 57
  queries return zero results with no coverage failure, 15 of 46 have a wrong top-1, the mozzarella bind
  scores 58 against a `confidentBindScore` of 250 — are all reproducible against the shipped catalog, and
  item 1's corpus test is what makes them regression-proof.

### 11. Definition of done

- Track A: five batches committed on `claude/a11y-2026-08-22`, `Docs/Accessibility-Nutrition-Labels.md`
  written, §4.5's accessibility wall (the greppable-rules scanner + the `performAccessibilityAudit` half
  bolted onto `Tests/FernletUITests/UXScreenProbe.swift`) landed and green.
- Track B: items 1–13 committed on `claude/food-search-2026-08-22`, with item 13's regenerated binary held
  uncommitted pending my LFS call, and the 57-query corpus test green and asserting per-source vintage.
- Both: `Scripts/power-of-10-scan.py` and `Scripts/doc-coverage-scan.py` at zero, string catalogs in sync,
  `Scripts/spm-wall-check.sh` passing, full `FernletTests` green.
- `Docs/Round-2026-08-22-Progress.md` complete, including every deferred item, every open question from §5
  with your recommendation, and the reconciliation batch's contents.
- Report to me: what landed, what deferred and why, what the reviews caught, and what budget remains.

**Start with Step 0, then dispatch the §6 Accessibility Inspector agent and Track B item 1 concurrently.
Do not merge anything to `main` without telling me first.**
