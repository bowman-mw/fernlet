# Continuation prompt — accessibility round (written 2026-08-22)

> **SUPERSEDED (2026-08-23).** A later session folded this into
> `Docs/Next-Round-Prompt-Parallel-2026-08-22.md`, which runs accessibility (all five batches of §7)
> and the food-search work as two parallel tracks and carries the owner's scope decisions. **Use that
> prompt.** This file is kept because it holds the accessibility-specific constraints and the
> what-not-to-do list, which the parallel prompt references rather than repeats.
>
> Known collision recorded there: `App/Fernlet/FoodView.swift` is owned by the food track, so this
> report's three items in that file (T1-4, T2-4, T2-14) defer to a reconciliation batch.

Paste the block below into a fresh session. Everything above the rule is context for you, the owner.

The audit is **complete and written up**; **no code was changed** by it. The report is
`Docs/Accessibility-Review-2026-08-22.md` (also published at
https://claude.ai/code/artifact/779c6811-c1ed-4051-8dc9-76ea30e13634). The only piece of the original
**State at handoff: the audit and its delta re-verification are both complete.** The peer's capstone has
landed and merged, all 65 in-flight findings were re-checked against it, and the report reflects the result.
Nothing is outstanding except deciding what to build.

---

## Prompt to paste

I'm continuing an accessibility round on Fernlet. The audit is already done — do **not** re-run it.

**Read first, in this order:**
1. `Docs/Accessibility-Review-2026-08-22.md` — the full report: 270 verified findings merged into 38 work
   items (Tier 0 blockers → Tier 3 deliberate no-gos), 5 systemic moves, an App Store Accessibility
   Nutrition Label table, and a 5-batch sequencing plan. Its "How much to trust this" section lists
   exactly which claims were re-verified by hand and which were not.
2. Your memory files `accessibility-review-2026-08-22` and `fernlet-design-token-contrast`.

**Task 1 — delta re-verification: DONE, do not redo.** Completed 2026-08-23 against the peer's capstone
`350ff4d` (merged as `b259f3d`). Result: no finding invalidated, exactly one fixed (T0-4's contrast line).
Every zero-usage API is still zero. Shared-UI-kit line numbers are exact; line numbers inside `FoodView`,
`MoveView`, `WorkoutLocationSetupView` and `SettingsSheet` drifted ~±15, so re-anchor by symbol name in
those four. Full detail is in the report's "Delta re-verification" section.

**Task 2 — settle the three unresolved grouping questions (~10 minutes, unblocks scope decisions).**
Three high-impact findings could not be resolved without running the app; two change scope by an order of
magnitude. Open the app and use Xcode's Accessibility Inspector on:
- `HomeView.swift:2381` — does `HealthBar`'s accessibility label attach to anything?
- `HomeView.swift:2700-2734` — does the outer `Button` swallow the nested hygiene toggles?
- `WorkoutLocationSetupView.swift:699-750` — buttons nested inside a button.
Also settle whether a parent `.accessibilityLabel` overrides a child's (this decides T1-10).

**Task 3 — implement, in the report's batch order.** Do **not** invent a new plan; the report already has
one. Start with **Batch 1 (Tier 0, T0-1..T0-7)**, which is deliberately clear of the peer's in-flight files
and can land independently. The single most important item is **T0-1**: `FernletLockGate.swift:165` is
`ZStack { content; if active && isLocked { lockOverlay.zIndex(100) } }` — `zIndex` reorders drawing, not
the accessibility tree, and the whole `FernletLockUI` module has zero `isModal`/`accessibilityHidden`, so
VoiceOver and Switch Control walk off the passcode field into the gated Private tab and can operate it.

**Constraints that will bite you if you skip them:**
- **Localization wall.** Accessibility labels/hints/values and custom-action names are *display* strings —
  pass `LocalizedStringKey`/`Text`, never a bare `String` (a `String` parameter silently opts the call site
  out). Inside an SPM module you must pass `bundle: .module` or it renders English forever with a clean
  build. `accessibilityIdentifier` is a **frozen English token** — never localize it.
  **Sharp edge:** `AccessibilityNotification.Announcement` takes a `String`, so any announcer API must be
  `LocalizedStringResource` at its surface or every announcement ships English.
- **`FernletUI` has no string catalog** (report §4.0). Any literal added *inside* that module resolves
  against `Bundle.main`. This silently blocks six proposed fixes — resolve it before Batch 4.
- **Power of 10:** ≤60 code lines per function *and* per `body`. Several targets are already near the
  ceiling (`ContentView.customTabBar` is 54/60; `CompanionVectorAssets.body` ~58) and need an extraction
  *first* — the report names which.
- **Never invent colors.** `Docs/design-refs/ux-review-2026-08-16/design-spec-2026-08-21.md` already
  specifies and the owner already approved: moss ink `#46683A` (measures 5.54:1), Increase Contrast
  `slate → #45535E` (6.90:1), `filled moss → #38562C` (7.22:1). None exist in code yet. Recompute any
  ratio you rely on — agent estimates in this area were wrong by up to 1.5x.
- **Shared working tree.** Other sessions use this tree and its DerivedData. Commit or stash before any
  fan-out, build with your own `-derivedDataPath`, and never blame another session's test failures on your
  diff.
- Run tests in batches by suite, not as one run; check the exit code, not a naïve grep.

**Calibration on the audit itself:** 0 of 270 findings were refuted outright, though 99 were downgraded to
PARTIAL and every impact-5 was cut to ≤4. A 0% refutation rate is the lenient-verifier signature. The
report's table lists what I re-verified by hand (T0-1, T1-1, T1-7, the hex values, the opacity math, every
source-comment contrast claim). **Anything not in that table should be re-checked at the code before you
build on it.**

**What NOT to do**, all with reasons recorded in the report's Tier 3 — do not reopen without new
information: per-cell VoiceOver for the pixel canvas (1,920 cells); Bold Text (Instrument Serif is
single-weight — it is a typeface problem, not a missing check); `accessibilityRotor` anywhere (headings
deliver ~90% of the value); `AXChartDescriptor` (no `import Charts` in the tree); CoreSpotlight indexing
(copies sealed content outside the lock gate and the wipe path — a privacy regression); a blanket
`.accessibilityHidden` sweep of all 294 SF Symbols (~10 sites actually matter).
