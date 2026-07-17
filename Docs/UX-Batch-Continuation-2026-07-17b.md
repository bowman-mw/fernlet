# Fernlet 21-item UX build-out — continuation prompt (2026-07-17, session 2)

Paste the block below into a fresh session to continue.

---

Continue the Fernlet 21-item tester-feedback build-out. Read these memories FIRST:
`ux-batch-2026-07-16-state` (live tracker — updated with everything below),
`goal-presets-workout-liveactivity-plan-2026-07-17`, `tester-feedback-decisions-2026-07-16`,
`delete-all-wiring-2026-07-17`, `fernlet-domainmodel-clean-build-hazard`,
`sensitive-feature-gating-decisions`, `run-fernlet-tests-in-batches`.

## Branch + state
- Working branch `claude/batch1-ux-fixes`. **Nothing pushed**; `main` is ahead of `origin/main` from
  prior work. Branches stack (batch1 contains the period-gate commit).
- Commits this session (newest first):
  - `85a95a8` Docs: plan goal presets + workout Live Activity (PLANNED, not built)
  - `725788e` #11 piece 2 — "Recent bites" Home widget (meal polaroids)
  - `b640326` #11 piece 1 — MealPhotoStore sealed + downscaled at rest
  - `c4c6395` #17 macro target overrides (feature)
  - `c7d971c` #17 MacroRing zero-goal NaN guard (blocker)
  - `e69feba` #18 delete-all dialog: whole shared-photo wall disclosed (reconciled bg task)
  - (`dec0656`/`ca15f5b` earlier bg tasks; `37eefa9`/`8cf3b4f`/`48ef0bf`/`8f1ce5d`/`d478635`/`6d17aa2`/
    `1281339` = #7/#8/#18/#19/#20/#9/#12-14/#4-5)
- **DONE + verified:** #4, #5, #7, #8, #9, #12, #13, #14, #17, #18, #19, #20, #11(pieces 1-2). #21 closed
  (sim artifact). All three background tasks reconciled + committed.

## Remaining, in order

### #11 polaroid — pieces 3 & 4 (NEXT)
- **Piece 3 — gym progress-pic timeline, UNDER THE MOVE TAB** (user's decision). Body photos. **Reuse the
  now-hardened `MealPhotoStore`** (FernletKit/Sources/PrivateMediaStore) **with a SEPARATE directory
  instance** (e.g. "ProgressPhotos/") — it already seals + downscales + fails-closed. Needs: a capture
  entry (reuse the food-capture flow, FoodView ~1300-1380: `PhotosPicker` + camera), a store/model for
  progress photos keyed by date, and a timeline UI in the Move tab. Reuse `MealPhotoPolaroid`
  (Fernlet/MealPhotoPolaroid.swift) or a dated variant for the timeline cards.
- **Piece 4 — reusable camera component.** Extract the food-capture camera/photos-picker into one
  reusable component used by meal photos AND gym progress pics.

### #15 + #16 — companion-aware zoomable editor canvas (ONE feature)
- The grid↔body coordinate map already exists and inverts: `CompanionVectorAssets.swift
  placement(for:size:texture:)`. A live companion preview already exists in `CreationStudioView`; it just
  isn't positioned under the grid. Real work = zoom/pan gesture arbitration (cells are ~6.7pt after the
  2× grid raise). See `uiux-redesign-brief-2026-07-08` / `custom-clothing-feature-2026-06-29`.

### Tail
- **#1 recipe book** — NO external image fetch (user's own photo only). Per-serving math already exists;
  what's missing is a recipe detail view.
- **#2 widget state** — NOT diagnosed; investigate, don't guess-fix.
- **#3 water views** — "+1 cup" is NOT representable; water is an `Int` bottle count.
- **#6 App Intents / Spotlight.**
- **#10 bottom-bar jitter** — NOT diagnosed; best surviving hypothesis is an over-counted overflow calc
  in `FernletUIComponents.swift` ~470.

### Two NEW planned features (plan already written — Docs/Plan-Goal-Presets-And-Workout-LiveActivity-2026-07-17.md)
- **Goal & nutrition preset cards** matching the workout options (goal already drives both; add
  `GoalType.nutritionSummary`/public `trainingSummary`, replace the bare picker with cards).
- **Workout Live Activity** (Dynamic Island + Lock Screen rest timer). `NSSupportsLiveActivities` already
  on; no ActivityKit yet; the guided-session runner is NEW. Build order + gotchas in the doc.

## How to work
- **Ultracode is on:** use `Workflow` fan-outs with adversarial verification — it earned its keep this
  session (caught the #17 fat-placeholder bug, a vacuous seal test, and a real migration regression).
- **VERIFY ON-DEVICE, and prove the test fails against the bug before keeping it.**
- Build: `xcodebuild build-for-testing -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17'`.
  Prefix long runs with `caffeinate -dimsu`. **One simulator at a time; keep workflows modest** (heavy
  concurrent builds + big workflows saturate the host and flake UI tests).
- Check the **exit code**, not a grep. zsh uses `$pipestatus`, not `$PIPESTATUS`.
- Run `Scripts/spm-wall-check.sh` before any push.
- **CLEAN build after ANY FernletDomainModel enum/struct change** (incremental masks non-exhaustive
  switches and ships layout-corrupted binaries).
- Known flake: `ProximityRecipeShareCapTests.connectTimeoutSurfacesBusyPeerFailure` (passes alone).
- The app forces its own light/dark via `@AppStorage fernletDarkModeEnabled` (NOT system appearance;
  `simctl ui … appearance dark` does nothing — write the default instead).

## Gotchas learned this session (don't relearn them)
- **Swift Testing `-only-testing:Suite/method` (per-method) matches 0 tests → vacuous "TEST EXECUTE
  SUCCEEDED".** Filter at the SUITE level and check per-test lines.
- **Nested `#require` inside another `#require` = "recursive expansion of macro" compile error.** Un-nest
  into a `let`.
- **A read that upgrades legacy plaintext can mask an unsealed-write test** — inspect on-disk bytes
  BEFORE calling any read in a sealing test.
- **`ImageRenderer` renders a SwiftUI view → PNG inside a plain XCTestCase** (attach + `xcresulttool
  export attachments`) — the clean way to mock visual candidates without driving the sim UI. Used for the
  #11 polaroid style pick.
- **Adding a `HomeWidget` case** = 3 HomeView switches (`homeWidget`/`handleHomeWidget`/`actionSubtitle`)
  + 3 in NavigationEnums (`title`/`systemImage`/`isAction`) + `defaultWidgets` + a migration marker. The
  migration append MUST be guarded on `!decodedHomeWidgets.isEmpty` (an empty list must fall back to
  `defaultWidgets`, or an all-unknown-token user is stranded on just the new widget). No HomeWidget
  switch in FernletWidgets.
- Settings edits persist across UI-test launches (the seed loads the persisted store) — reset any
  overrides at test start. numberPad has no return key — tap the nav bar to dismiss it.
- UI-test appearance harness: `UXTestApp.launch(openSheet:)` + `UXScreenProbe(...).capture()`; the demo
  seed (`FernletStore+DemoSeed.swift`) now photographs 2 meals for the Recent bites gallery; `simctl
  erase` between UI runs; the seed bails if TODAY's meals exist (don't seed on a post-wipe relaunch check).

Ask before starting only if a product decision is genuinely open (e.g. #15/#16 gesture model, or the two
planned features' open decisions); otherwise proceed. For visual redesigns, render candidates in real
SwiftUI + screenshot before implementing.
