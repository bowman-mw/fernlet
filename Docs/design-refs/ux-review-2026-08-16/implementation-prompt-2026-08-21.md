# Implementation prompt — UI/UX redesign 2026-08-21

Paste the block below into a fresh session.

---

Implement the approved 2026-08-21 UI/UX redesign. Use multi-agent workflows for both the
implementation fan-out and the review passes. When everything is green and committed, stop and
present the results in chat for my final review — do not push, do not merge to main.

## What this is

The 2026-08-16 UI/UX review (`Docs/UI-UX-Review-2026-08-16.md`) left 45 mockup-flagged findings.
A design canvas now resolves 36 of them across five batches (the 9 Friends/Private findings are
deliberately deferred). The spec:

- `Docs/design-refs/ux-review-2026-08-16/design-spec-2026-08-21.md` — text extraction of every
  artboard: labels, copy, annotation notes, AX3/AX5 behavior. **This is the working spec.**
- `Docs/design-refs/ux-review-2026-08-16/Fernlet-Redesign-2026-08-21.dc.html` — the canvas it
  came from (open in a browser if a layout is ambiguous; the rendered canvas is visual truth).
- `Docs/design-refs/ux-review-2026-08-16/shots/fresh-2026-08-21/` + its `INDEX.md` — current-build
  screenshots of every affected screen, keyed to finding ids.
- Finding ids (`HOME-02`, `FLOW-03`, …) resolve in `Docs/UI-UX-Review-2026-08-16.md`. The review
  text predates shipped fixes — where it disagrees with the current code, the code is right.

Artboards are named by the finding ids they resolve. Each has AX3/AX5 twins whose "what gives
way" notes are the Dynamic Type spec — implement those degradations, don't invent your own.

## Corrections that OVERRIDE the canvas where they conflict

1. **Moss fill**: the canvas header chip says "filled buttons are moss #5E844D". That is wrong —
   the shipped `Color.mossFill` (#4F7444 light) already deepens filled buttons so white ink clears
   5.4:1 (see the comment at its definition in FernletUIComponents.swift). Keep `mossFill` for
   filled buttons; `moss` #5E844D stays tint/accent-only. Do not lighten any filled button.
2. **5d "all four capabilities that exist today"**: verify the real HealthKit capability list in
   the code before merging cards. If cycle tracking and intimate logging are separate capabilities
   today, surface that and ask me before collapsing them into one card.
3. **Water sheet (2c) is a deliberate behavior change**: it becomes transactional — the stepper
   edits a draft, Done (top-right) commits, Cancel reverts. Today it writes live; that changes.
4. **Sheet template covering rule**: multi-field draft sheets commit via the bottom-right Save
   pill; single-control adjustment sheets (Water) commit via Done top-right. Read-only sheets get
   Done top-right as the whole exit. No bottom-right "Done" moss pill anywhere.
5. **5e typed-DELETE gate**: the confirm word is a matching input under the localization wall —
   compare against the localized display string, never a hardcoded English "DELETE".
6. **5e "Kept on purpose" list**: reconcile against the actual delete-everything wiring and the
   persisted-surface wipe-wall disposition table before shipping the copy as fact.
7. **5g quick-log picker**: when period surfaces are hidden, the two cycle chips are ABSENT from
   the picker (fail-closed at the gate), never shown disabled.
8. **5a "Advanced" section**: the disposition note routes Debug/Connection Inspector to a
   "Connection log" row in Advanced, but no Advanced section is drawn. Add a DEBUG-only Advanced
   section at the hub bottom unless you find a reason not to; note what you chose.
9. **4f Steps timer capsule**: only render per-step duration capsules if the recipe model has
   per-step durations. If it doesn't, ship Steps without capsules and report it as a residual.

## Order of work

**Batch 2 first, alone** (artboards 2a–2d): the three-slot sheet chrome (Cancel top-left / Done
top-right / Save bottom-right per the covering rule), the destructive token (terracotta ink
#A8452F on terracotta-tint fills; solid terracotta only inside confirmation alerts), and the
Water sheet. Everything else inherits this foundation — land it, build it, test it, commit it
before fanning out.

**Then batches 1, 3, 4, 5 in parallel** (artboards 1a–1g, 3a–3f, 4a–4g, 5a–5g) with strict
exclusive file ownership per agent — two agents must never touch the same file (see memory:
multi-agent fix workflow; that rule is what makes a large fan-out safe). Where two batches want
the same file (e.g. ContentView, SharedSheets), assign the file to one agent and have the other
express its need as a follow-up work item, or sequence those two batches.

**Then**: a build-doctor pass, adversarial capstone review (3+ independent reviewers over the
full diff, prompted to refute that each finding id is actually resolved), fix what survives,
close out.

## Process requirements (project walls — all enforced by CI/tests)

- Work on a new branch off main (e.g. `claude/design-impl-2026-08-21`). Commit the baseline state
  first if the tree is dirty — other sessions may share this working tree; commit only your hunks
  by explicit pathspec.
- Power-of-10 wall: ≤60 code lines per function/`body` (split named subviews early — the 2026-08-18
  round tripped this 7 times), no silent traps, warnings are errors. Run
  `Scripts/power-of-10-scan.py` before every commit; baseline is zero.
- Localization wall: all new display text as `LocalizedStringKey` (a `String` parameter silently
  opts the call site out); inside SPM modules pass `bundle: .module`. Tokens (rawValues, a11y
  identifiers, matching inputs) never localize. Run `Scripts/sync-string-catalogs.sh` after adding
  strings.
- New UserDefaults keys need a disposition row in the persisted-surface wipe wall in the same
  commit.
- Every new/changed type keeps `///` doc comments; run `Scripts/doc-coverage-scan.py` (zero
  undocumented is the baseline). Update module DocC landing pages if public surface changes.
- Read the relevant module's `Documentation.docc` landing page and `Docs/FileIndex.md` before
  touching a module; reuse existing components (ChipButtonStyle, DestructiveConfirmation,
  SheetCancelBar, FernletDesignSystem tokens) instead of duplicating.
- Build: `xcodebuild build -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS
  Simulator,name=iPhone 17'`. Test in batches by suite (full suite ~7 min; check exit codes, not
  grep). UI suites run serially (`-parallel-testing-enabled NO`).
- Known pre-existing UI failures (not yours): 5 share the `labeledElement(containing:)`/
  `privacy.controls` cause, 1 stray Restore prompt; `GoalPresetCardsUITests` self-poisons across
  runs (passes only after `simctl uninstall`). Verify a suspected pre-existing failure against a
  detached worktree at the pre-round commit before chasing it.
- The UX appearance harness (`FERNLET_UI_TEST_SEED_DEMO=1`, `FERNLET_UI_TEST_OPEN_SHEET=<id>`,
  `-completeOnboarding`, memory: ux-appearance-test-harness) is how you drive the app to any
  screen. Update `ScreenAppearanceUITests`/`SettingsAppearanceUITests` expectations that the
  redesign breaks (e.g. sheets that gained Cancel rows, the hub's new sections).

## Definition of done, then stop

1. Builds clean with warnings-as-errors; power-of-10 scan zero; doc scan zero.
2. Unit suite green; affected UI suites green; pre-existing failures unchanged.
3. Capstone review findings fixed or explicitly listed as accepted residuals.
4. Fresh simulator screenshots (seeded demo, light mode) of EVERY redesigned screen, saved to
   `Docs/design-refs/ux-review-2026-08-16/shots/impl-2026-08-21/` named by artboard id
   (`2c-water-sheet.png`, …), plus a handful of AX3 shots for the screens with AX twins.
5. All work committed on the branch by explicit pathspec. NOT pushed. NOT merged.

Then present in chat, for my final review: a per-batch summary of what was implemented, the
screenshot set side-by-side-able against the canvas, every deviation from the spec with its
reason, the accepted residuals, and the test tally. Wait for my sign-off before merging anything.
