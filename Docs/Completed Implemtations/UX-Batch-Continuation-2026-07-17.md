> **CLOSED 2026-07-19 — SHIPPED.** Every listed item verified on `main` by code audit (progress-photo timeline + PhotoCaptureControl, zoomable clothing canvas, recipe detail + own photo, App Intents, widget mood gate, jitter fix). Live tracker: [RemainingWork-2026-07-19.md](../RemainingWork-2026-07-19.md).

# Fernlet 21-item UX build-out — continuation prompt (2026-07-17)

Paste the block below into a fresh session to continue.

---

Continue the Fernlet 21-item tester-feedback build-out. Read these memories first:
`ux-batch-2026-07-16-state`, `delete-all-wiring-2026-07-17`, `tester-feedback-decisions-2026-07-16`,
`fernlet-domainmodel-clean-build-hazard`, `sensitive-feature-gating-decisions`,
`run-fernlet-tests-in-batches`.

## Branch + state
- Working branch: `claude/batch1-ux-fixes`. Nothing pushed. `main` is 5 ahead of `origin/main` from
  prior work. Branches STACK (batch1 contains the period-gate commit).
- Commits landed this session (newest first):
  - `37eefa9` #7 First Aid chips + Milestones keepsake shelf
  - `8cf3b4f` #8 gym locations delete + rename + persist + fixed built-in UUIDs
  - `48ef0bf` #18 delete-all UI wired + dialog made true
  - `8f1ce5d` #18 delete-all PLUMBING
  - (older: #19/#20, #9/#12/#13/#14, #4/#5 gate)
- DONE + verified on-device: #4, #5, #7, #8, #9, #12, #13, #14, #18, #19, #20.
- #21 (widget watchdog crash) CLOSED = simulator/host-contention artifact (0x8BADF00D scene-create
  watchdog; app CPU ~0.3s vs system 100%). Re-check only on a real device.

## FIRST: reconcile the three background tasks before writing new code
Three follow-up sessions were spawned as chips and may have landed changes. Check
`git log --all --oneline` and any new branches/worktrees, then reconcile:
- **task_4e449991** (mesh photos + PrivateMediaStore key) — edits `FernletStore.deleteAllData` and the
  hook pattern in `ContentView.attachDeleteAllHooks`, the SAME funnel as `48ef0bf`. Expect overlap.
- **task_701f94c2** (plaintext export JSON in tmp) — ALSO edits `deleteAllData`. Same file, same
  function. Two tasks + your funnel all touch one method — merge carefully, keep the `DeleteAllOutcome`
  failure-reporting pattern, and re-run `FernletTests/DeleteAllDataTests` + the delete-all UI test.
- **task_0b6fc855** (fix `testPrivateHubPeriodAppearance`) — touches the appearance test / period gate.
  This test is PRE-EXISTING broken on the branch (reproduced with the #7 change stashed).
If a task's work is unmerged, integrate it first; if merged, just confirm the delete-all tests are green
before proceeding.

## Remaining items, in order

### #17 macro target overrides (NEXT)
- **BLOCKER, fix FIRST:** `MacroRing.progress = min(current/goal, 1)` is fed to `.trim`; `goal == 0`
  gives NaN and crashes Home, Food AND Journal the moment a numeric override sheet makes "0" typeable.
- Put overrides on `FernletSettings` as `Int?` (nil = derived), NOT `UserNutritionProfile` (HealthKit
  overwrites that wholesale once per launch).
- Carbs is already the residual, so pinning protein/fat/calories rebalances carbs for free.
- **Needs a CLEAN build** (new `FernletDomainModel` fields) — incremental masks non-exhaustive-switch
  errors and ships layout-corrupted binaries (see `fernlet-domainmodel-clean-build-hazard`).

### #11 polaroid — all 4 pieces, ORDER IS LOAD-BEARING
- Harden `MealPhotoStore` (writes raw unencrypted full-res JPEG today) BEFORE gym progress pics, which
  are body photos. Coordinate with task_4e449991 — it also touches `PrivateMediaStore`.
- Pieces: polaroid food photos on Home, gym progress-pic timeline, reusable camera component.
- Food photo capture ALREADY works end-to-end; it just renders as a 54×54 thumb today.

### #15 + #16 companion-aware zoomable editor canvas (ONE feature)
- The grid↔body coordinate map already exists and is invertible:
  `CompanionVectorAssets.swift placement(for:size:texture:)`.
- A live companion preview already exists in `CreationStudioView`; it just isn't positioned under the
  grid. Real work = zoom/pan gesture arbitration (cells are ~6.7pt after the 2× grid raise).

### Tail
- **#1 recipe book** — NO external image fetch (user's own photo only). Per-serving math already exists;
  what's missing is a recipe detail view.
- **#2 widget state** — NOT diagnosed; 3 co-equal hypotheses. Investigate, don't guess-fix.
- **#3 water widget views** — "+1 cup" is NOT representable; water is an `Int` bottle count.
- **#6 App Intents / Spotlight.**
- **#10 bottom-bar jitter** — NOT diagnosed; best surviving hypothesis is an over-counted overflow calc
  in `FernletUIComponents.swift` ~470 (204pt computed vs 26pt real travel).

## How to work
- **Ultracode is on:** use `Workflow` fan-outs with adversarial verification. It earned its keep every
  time this session — it caught a `PendingNarrativeBuffer` regression I introduced in #18 (worse than
  the bug it fixed), 3 real bugs in #8, and 3 in #7.
- **VERIFY ON-DEVICE, and prove the test fails against the bug before keeping it.** The #8 delete test
  passed vacuously until it was made to swipe-dismiss (not tap "Done", which saves) — a green test that
  never exercised the bug is worthless.
- Build: `xcodebuild build-for-testing -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17'`.
  Prefix long runs with `caffeinate -dimsu` (the machine slept mid-run once).
- **Concurrency discipline:** run ONE simulator at a time and keep review workflows modest. Heavy
  concurrent builds + multiple sims + big workflows saturated the host and SIGKILL'd background sim apps
  (and flakes your own UI tests).
- Check the **exit code**, not a grep. zsh uses `$pipestatus`, not `$PIPESTATUS` — or capture `$?`
  directly after a non-piped command.
- Run `Scripts/spm-wall-check.sh` before any push.
- Adding `FernletDomainModel` fields/enum cases requires a CLEAN build.
- `ProximityRecipeShareCapTests.connectTimeoutSurfacesBusyPeerFailure` is a KNOWN FLAKE (passes alone).
- `testPrivateHubPeriodAppearance` is PRE-EXISTING broken (task_0b6fc855) — ignore unless that task
  hasn't fixed it.
- Sim gotchas: `xcrun simctl erase <dev>` between runs; `defaults write MBO.Fernlet
  hasCompletedOnboarding -bool YES` skips onboarding; the app forces its own light/dark via `@AppStorage
  fernletDarkModeEnabled` (NOT the system appearance — `simctl ui … appearance dark` does nothing; write
  the default instead). UI tests use `-completeOnboarding` + `FERNLET_UI_TEST_SEED_DEMO=1`; the demo seed
  only bails if TODAY's meals exist, so DON'T seed on a post-wipe relaunch check or it fakes a
  resurrection.
- Failure detail: `xcrun xcresulttool get test-results test-details --test-id "Suite/testName()" --path
  <xcresult>`; screenshots via `xcrun xcresulttool export attachments`.
- Don't assert `loadAllDays().isEmpty` — the repository synthesizes a blank entry for today; assert the
  specific written day is gone.

Ask before starting only if a product decision is genuinely open (e.g. #17's override UI, #15/#16 gesture
model); otherwise proceed. For visual redesigns (#7-style), render candidates in real SwiftUI + screenshot
before implementing.
