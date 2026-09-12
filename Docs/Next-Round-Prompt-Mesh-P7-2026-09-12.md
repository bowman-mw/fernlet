# Loop Prompt — ProximityKit Network Migration: P7 (the app-layer run policy, the poller, and the resume surface)

**Written:** 2026-09-12, at the P6 boundary (branch `claude/youthful-zhukovsky-d27308` = `main` = the P6 close-out commit, whose SHA is in the P6 ledger's item 11 row; `origin/main` still `3a32be0` — **P6 is merged and NOT pushed**).
**Plan:** [Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md](Plan-ProximityKit-Network-Migration-2026-08-27.md) — the authority. **§13 is the P7 specification; §24 is the handoff; §12.3's findings 1, 3 and 14 are the named obligations.** This file is the launcher and the loop contract.
**Ledger:** [Docs/Mesh-Migration-Loop-Ledger-P7.md](Mesh-Migration-Loop-Ledger-P7.md) — the loop's memory, created on iteration 1 (§7). It lives on disk, not in context. The P6 ledger is a finished record; **do not reuse it.**
**Scope:** build **P7** — one app-target `ProximityRunPolicy` that becomes the **single** translator from (scenePhase, tab, lock/duress, protected data, age gates, delete-all, CPT state) to a per-radio `RunState`, the **single writer** of `applyRoutedAccessGate(_:now:)`, and the owner of the **poller** the three on-demand session consumers have been waiting for since P3; plus the **resume surface** P6 item 7 wired a door for and left invisible. **Stop the loop at the P7 boundary.** P7 is mostly wiring — every seam it needs already exists and is already tested. The half that is not wiring is the resume surface; scope it as product work.

---

## How to start

```
/loop Read Docs/Next-Round-Prompt-Mesh-P7-2026-09-12.md and run one iteration of it.
```

Self-paced (no interval): the work is build-and-test-bound, not clock-bound, so the loop wakes when
work completes, not on a timer. A session that is not a `/loop` runs the same iterations back to
back; the ledger is the state either way.

---

## 0. Orchestrator contract — read this first, it is the binding constraint

**The orchestrator is a limited model budget.** That is the scarcest resource in this project, scarcer
than build minutes or sim time. Every rule below exists to protect it.

### The orchestrator does not do the work. It decides what work happens next.

| Orchestrator DOES | Orchestrator DELEGATES |
|---|---|
| Read the ledger (one short file) | Reading any source file |
| Pick the next unblocked item | Writing or editing any file |
| Dispatch one subagent | Multi-file surveys, refactors, test authoring |
| Read the subagent's summary | Anything that would pull >100 lines into context |
| Grep one marker line out of a build log | Diagnosing a build failure |
| Update the ledger | — |
| Schedule the next wake | — |

Delegate with `Agent(..., model: "opus")`. Opus does the reading and writing; the orchestrator spends
tokens on judgement. A subagent that returns 40 lines of summary has saved the orchestrator thousands
of lines of file content — that ratio is the whole point. **Each item is three dispatches, never
one:** understand + design + implement (one agent, the ledger's decisions as input), then an
**adversarial verify** of the diff by a second agent that has not seen the first's reasoning (it reads
the item's acceptance criterion, the walls in §4 and the diff, and answers "what would make this
green for the wrong reason"), then a fix agent for what survives. When the owner has enabled
ultracode, the same three steps run as one small Workflow (P5 ran every item that way, 40–57 agents
each) — but a Workflow is the owner's opt-in, never the orchestrator's default. If Opus 529s at
spawn, ask the owner whether Opus is down rather than burning retries; if it is, omit `model:`.

### Hard token rules for the orchestrator

1. **Never `cat` a source file.** Use `sed -n '120,180p'` or a targeted `grep -n`. If you need more
   than ~60 lines of a file, that is a subagent's job.
2. **Never let build or test output reach context.** Always:
   ```bash
   xcodebuild … > "$LOG" 2>&1; echo "EXIT=$?" >> "$LOG"
   grep -E "EXIT=|BUILD (SUCCEEDED|FAILED)|TEST EXECUTE|Test run with" "$LOG"
   ```
   Three lines in, not three thousand. Only if it failed do you hand `$LOG` to a subagent to diagnose.
3. **One work item per iteration.** Finish it, record it, wake again. Do not batch — a batched
   iteration that fails halfway leaves the ledger lying. (Bundling a genuinely tiny, file-disjoint
   fix as its *own commit* is fine, as P5's 1a/1b/6a and P6's 1c were beside the items that exposed
   them.)
4. **Write state to the ledger, not to your own memory.** `/loop` resumes the *same* context and
   never compacts between iterations, so anything you keep in your head is paid for again on every
   subsequent turn and is lost if the session ends. The ledger is the only durable state.
5. **Stop early rather than run out.** See §6. A clean handoff is cheap; a loop that dies mid-item is
   expensive to reconstruct. When the ledger is the only thing a fresh session would need to resume,
   that is the moment to stop.
6. **When a close-out step needs synthesis across many verified facts (marking a phase BUILT, writing
   a handoff), use draft → adversarial two-lens verify → apply**, with drafts and corrections written
   to scratch files first — never one long inline agent call. P4's close-out caught 51 real
   corrections that way; P5's post-close review caught five more (one of them P1) that the close-out
   had not; P6's draft agent found the phase's owed catalog list was two keys wrong before anything
   was applied. Keep apply-step prompts short by pointing at files.
7. **A row that lands in two passes needs its gate to assert the later pass RAN** (§23.5). P5 item 13
   reported green with pass B untouched because the script's second pass never fired. P7's items 3
   and 5 below are two-pass by shape — a wiring pass and a **retirement** pass, and a decision value
   then its surface — so "all green" for item 3 means the **retirement wall is in the tree and
   green**, not that the run exited 0.
8. **This phase edits the APP TARGET more than it edits ProximityKit**, which inverts P3–P6's ratio.
   The app has no property battery, its walls are thinner, and `ContentView` / `FernletApp` are the
   two files every other session also touches. Check `git status` before and after every dispatch,
   and never stage a file your item did not name.

### If the budget runs out mid-phase

Stop the loop, write the handoff (§6/§8), and say plainly what is left. Do not silently degrade into
doing the work yourself — that is exactly how the budget disappears.

---

## 1. Each iteration, in order

1. **Read the ledger.** `Docs/Mesh-Migration-Loop-Ledger-P7.md`. On iteration 1, create it from §7's
   template, seeded with the seven items below. Thereafter it is already seeded — go straight to the
   next item.
2. **Check the tree is safe to build on** — first iteration, or after any owner activity:
   ```bash
   git -C . log --oneline -1; git -C . status --porcelain
   ```
   Another session has long held `App/Fernlet/Localizable.xcstrings` (a large foreign diff) and a
   personal `xcschememanagement.plist`; a stray untracked PDF sits in `Docs/`. **Leave all three
   alone**; never stage them. Commit with explicit pathspecs, never `git add -A`. If a new surface
   adds catalog keys, sync the catalog from `HEAD`'s blob and stage it as a blob (`f4a69f1`'s method,
   repeated at P6's close-out) — never from the held working copy.
3. **Pick the next item** whose prerequisites are met, from §3's list, in ledger order. Prefer a
   **tier-1** item over a tier-2 one — see §2.
4. **Dispatch the three agents** with the item's full context: the acceptance criterion, the walls it
   must not trip (§4), the decisions already taken in the ledger, and that the implementer must run
   the gauntlet subset for what it touched (§6).
5. **Verify** — grep the marker line out of its build/test log yourself. Do not take "it passed" on
   trust: this repo has notified a failed build as exit 0, a crossed log has shown ~20 phantom
   failures under concurrent-session contention, an interrupted-mid-run log has no markers at all
   (check the log's mtime is after the last source edit, and that a build succeeded after it), and a
   `-only-testing:` line naming a non-existent suite prints `TEST EXECUTE SUCCEEDED` over zero tests
   (check `Test run with N tests` is non-zero and count `◇ Suite` starts against `✔ Suite` passes).
6. **Commit** with explicit pathspecs (note `git mv` stages a rename immediately, so check
   `git diff --cached --name-status` first).
7. **Update the ledger**: item → done, with the SHA, one line on anything surprising, the next
   unblocked item, and any new sub-item the work exposed.
8. **Schedule the next wake**, or stop per §6.

---

## 2. Testing strategy (re-tiered at the P6 boundary, §24.5)

| Tier | What it proves | Cost |
|---|---|---|
| **1 — no radio** | **Everything in items 1–6.** §13's policy matrix is a **pure table over the full input product** — that is the phase's central test and it needs no simulator, no scene and no manager. The poller's three consumers are already pure-ish and already tested (`enforceSessionCeiling` / `evaluateIdleLapse` / `evaluatePartition`); what is new is *when* they run, which is again a decision value. The resume surface's decision half is a pure function over a `MeshSessionRestoreOutcome`. **If a check CAN live here, it MUST.** | Free, deterministic, CI. |
| **1b — UI tests, the app's own harness** | The resume surface and the tab/scene wiring are the first P-phase work with a **visible** surface, so the app's existing UI suite and its DEBUG launch hooks are in scope for the first time since P2. Run them **serially**, and **PIN the environment** (iPhone 17, portrait, its own invocation) before believing any appearance delta. | Minutes per run, same Mac. |
| **2 — sim↔sim, real QUIC** | **Two things, and both are cheap because P6 built the hooks.** (a) The **backgrounding half** of the gate: background one node with a second `simctl launch` and observe the pushed `appIsForeground` leg fall — P6 named this reachable and did not attempt it. (b) P6's un-run rows, if and only if L-3's arming race is closed first (`FERNLET_MESH_ARM_AFTER`): heart session 2, the removal vote, the `.chatAgeGated` three-leg negative. Budget wall clock at **≈ 3.5 ×** the driver tick number — a headless Simulator's 1 Hz poll runs at ≈ 0.3 Hz. | One Mac, `simctl`, minutes per run. |
| **3 — physical devices** | Only §15's hardware gates, and `.continuingInBackground` does not exist on a Simulator at all. **P7 owes tier 3 nothing.** | Owner's time; not this phase. |

Lane gotchas carried from P2–P6 — obey them, they are all paid for:
- **Launch the sims ~1 s apart (`STAGGER=1`)**; always re-harvest identities after any `xcodebuild
  test` run (the full suite resets simulator app state).
- **A fresh log directory per run**, and `pgrep -x xcodebuild` before believing any failure. Never
  `pgrep -f` your own command string — it matches itself and the loop never ends.
- **The FIRST `test-without-building` after a build or an idle gap hangs** (`The test runner hung
  before establishing connection`, ~350 s, counted as 1 failed test); the second invocation passes.
  Warm the runner with a tiny suite before a gated step; never read a hung first invocation as red.
- **`simctl launch --console-pty` intermittently attaches no stdout.** A node with no
  `[mesh-matrix] run label=` banner proves nothing about that node — verify the banner and relaunch.
- **Every Lane C launch carries `FERNLET_MESH_MATRIX=1`, which bypasses the launch restore.** A lane
  that wants to observe the restore must run **without** the harness — and a simulator holding a
  stale sealed context from an older schema can never join until a non-harness launch quarantines it
  (§12.3 finding 2, L-1).
- **Do not chain a build and a test run in one backgrounded command on a shared DerivedData.** Two
  `xcodebuild` processes on one DerivedData produce `unable to attach DB`; `xcodebuild` can outlive
  the shell step that started it.

---

## 3. The work list

Ledger order. Each is one iteration unless noted. *File:line anchors are current at `12ccc7d`;
re-check before editing — P7's own commits move them.*

| # | Item | Tier | Prereq |
|---|---|---|---|
| 1 | **`ProximityRunPolicy` as a pure value, with the matrix as its test** (§13 option A). New app-target type, **no wiring in this commit**: the inputs (`scenePhase`, `selectedTab`, app-lock / duress state, `isProtectedDataAvailable`, the age gate, a delete-all-in-progress flag, and a CPT state that is **inert until P8**) → a `ProximityRunState` per radio (`run` / `foregroundOnly` / `stop`) **plus** the `MeshRoutedAccessGate` value the app is already assembling. §13's load-bearing rows are the acceptance criterion: user-started mesh + CPT granted → mesh `run` in background, discovery/admission `foregroundOnly` (invariant 5), presence + recipe `stop` on background; CPT refused → mesh `foregroundOnly`; delete-all / below-age / duress → `stop` + teardown. **Table-driven over the full input product**, and the table is the artefact — an enumerated product with a named expectation per row, not a spot check. Two rules inherited and non-negotiable: the foreground leg is **always** `routedGateForeground(for:)`'s answer (`App/Fernlet/FernletApp.swift:220`, `phase != .background`), never a raw phase compare, because `ScenePhase` is not frozen; and **`.inactive` is NOT a background leg** (P5's post-close correction — an inactive scene is still foreground for data protection and for the heart ceremony). | 1 | — |
| 2 | **The policy becomes the single writer of the routed access gate.** `FernletApp.pushRoutedAccessGate(_:protectedData:foreground:)` (`App/Fernlet/FernletApp.swift:282`) is called from **six** sites (`:337`, `:383`, `:416`, `:435`, `:447`, `:491`); they collapse into one policy call. **`MeshNetworkManager.applyRoutedAccessGate(_:now:)` (`MeshNetworkManager.swift:1430`) does not move** — that seam is already the `apply(_:)` shape P7 was designed around, and its five-job re-entry is already bounded, idempotent and audited. The gate's contract stays ProximityKit's: it says what may be **decrypted**, never which radios run (D-10.3), and `mayCommitRoutedHeartLedgerJudgement` (`:8962`) keeps its own `sessionState` leg. The duress `.onChange` site must survive as its own edge — it moves at neither a scene nor a protected-data transition. **Wall to add:** exactly one call site for `applyRoutedAccessGate(` outside ProximityKit, counted, and shown red once. | 1 | 1 |
| 3 | **The radios stop being called from the view.** Today `ContentView` owns them directly: `startFriendsDiscovery()` / `stopFriendsDiscovery()` (`:1809` / `:1858`, which call `manager.startJoin()` / `manager.stopJoin()` through a **three-way** `FriendsDiscoveryEntry` resolve at `:1816`), `store.presenceManager.start()` / `.stop()` (`:1745` / `:1747`) and `store.recipeShareManager.start()` / `.stop()` (`:1710` / `:1712`). **`ContentView` is not the only caller** — `App/Fernlet/FernletStore.swift` stops presence and recipe at `:1701`, `:1868` and `:5327` (delete-all and the teardown paths), and those are *policy inputs*, not competing owners: the policy must produce `stop` for those conditions rather than have them reach around it. Give each manager one `apply(_:)` seam and make the policy the only writer. **Do not collapse `hasCommittedPeer`, `isSessionLive` and `isInSession`** — they answer three different questions and P6 item 2's pass-B P1 is what happens when they are confused (a link blip ran the session-end ceremony and presented a sheet whose two actions sign a termination on a live mesh). A fourth `startJoin()` caller, `App/Fernlet/Proximity/Feasibility/MeshRejectionMatrixHarness.swift:267`, is `#if DEBUG` behind `MeshMatrixDebugOptions.isEnabled` — the wall must exempt it **by name**, not by accident. *Two passes by shape: a wiring pass and a retirement pass whose wall counts the direct manager calls at zero outside the policy.* | 1 | 1, 2 |
| 4 | **The poller, and the three consumers that have been waiting for it since P3.** `enforceSessionCeiling(now:monotonicElapsed:)` (`MeshNetworkManager.swift:9559`), `evaluateIdleLapse(now:)` (`:9576`) and `evaluatePartition(reachable:now:)` (`:9637`) have **no shipping caller** — verified at `12ccc7d`, every caller is a test — and five doc sites say P7 owns the poller (`:1940`, `:9623`, `:13332`, `MeshRoutedCustody.swift:976`, `Documentation.docc/ProximityKit.md:1343`). Detection is **on demand by design so that nothing spins**, so the poller must be **one** timer the policy starts and stops with session liveness, not three. Order matters: ceiling, then idle lapse, then partition. **Item 2 of P6 created the first live consequence:** a yielding founder ends with a mesh and **no ceiling** until this exists (§12.3 finding 3) — that is this item's headline acceptance cell. Nothing here may spin while no session is live, and `isSessionLive` (`MeshNetworkManager.swift:1241`) is the predicate. | 1 | 1, 3 |
| 5 | **The resume surface — the half P6 wired a door for and left invisible.** `restoreSessionContextOncePerLaunch(now:)` (`MeshNetworkManager.swift:9723`) runs once per launch from `App/Fernlet/FernletApp.swift:317` and **no app surface reads its outcome**: `lastSessionRestoreOutcome`, `offersForegroundResume`, `restoredSessionContext` and `rejoinBar` have zero app readers, and the shipping doc says so at `FernletApp.swift:306–308`. Present it. Default shape in §3's decision table below; the decision half must be a **pure function** over `MeshSessionRestoreOutcome` so it is a tier-1 table and not a screenshot. Two facts to build against: a restore **arms no radio** (it makes the ledger, roster, restored key advertisements and routed store addressable — whether this device then looks for peers stays the Friends three-way's and now the policy's), and the rejoin bar is re-derived at launch, which had been claimed since P3 and never done. **New display copy is near-certain here — every sentence is a `LocalizedStringKey`, never a `String`, and the keys are listed in the handoff for the close-out's catalog sync.** *Two passes by shape: the decision value, then the surface.* | 1 + 1b | 1 |
| 6 | **Gate `MeshRoutedDrainTests` and price the rest of P6's ungated cells** (§12.3 finding 14, handed to P7 by P6's close-out). `MeshRoutedDrainTests` is **43 `@Test`** at HEAD (41 when P6 item 9 measured it; `0e182bb` added two) and holds P6 item 8's handed-over cell; ~243 more P6-relevant cells sit across fourteen suites — ~286 in all (itemised in P6 item 9's handoff). Gating all of them roughly doubles the `mesh-batteries` step. **Measure the step time with and without, raise `Scripts/run-gated-suites.sh mesh-batteries`'s floor by the measured count, and record the price** — the floor is 300 over 50 suites today (`.github/workflows/s3-wall.yml:246`), measured at P6 item 9, never inherited. File-disjoint from items 1–5; a good first iteration if 1 is still in design. | 1 | — |
| 7 | **The P7 acceptance battery + the CI gate lines, in ONE commit.** One serialized `MeshP7<Clause>AcceptanceTests` suite per §13 clause, mirroring P5's and P6's shape: the policy matrix whole (every row of the input product, `deferred` empty as a positive claim), the gate's single writer, the radios' seams, the poller's three consumers each driven to their verdict, and the resume decision over every `MeshSessionRestoreOutcome` case — plus an **honesty** suite naming what the battery does not claim (no scene, no CPT, no device lock; `.continuingInBackground` unreachable). **`CIGateSelectorBoundaryTests` fails any declared `MeshP7*AcceptanceTests` the workflow's mesh step does not name**, and its battery pin (`>= 36` at `CIGateSelectorBoundaryTests.swift:157`) is **measured** at the commit that moves it, never inherited. Neither pinned digest may move: nothing here touches `MeshRoutedScheduleOverlay`, `MeshConvergenceSchedule` or `MeshScheduleEvent`, so `594b6f77…5765` and `ca898bcc…6930` are both **unchanged**, and a move is a red, not a re-pin. | 1 | 1–6 |
| 8 | **Tier 2, P7's own lane work** (§2): (a) the **backgrounding half** of the gate — background one node with a second `simctl launch` and observe the pushed `appIsForeground` leg fall and the routed re-entry behave; P6 named this reachable and did not attempt it; (b) the **eligibility negative** — a heart to a member with **no** trust-vault row must be a FINAL, audited refusal with custody kept; it needs a third simulator that sat out session 1, and it is the one heart row P6's two passes did not reach; (c) **only if** a `FERNLET_MESH_ARM_AFTER=<polls>` hook closes L-3's founder-collapse arming race first, P6's remaining rows: the removal vote (three DEBUG seams for the signed quorum family; plan §4.2 is the spec), the `.chatAgeGated` three-leg negative, and the app-path founding over MC — which the QUIC lane cannot reach at all (runbook Amendment A), so its honest partial is shape (a) over MC. Timebox to two iterations; what does not cross is recorded by name with a paste-ready owner sentence, never left as "flaky". | 2 | 3, 4 |
| 9 | **Close-out** (§8): §13 BUILT with §13.1–§13.4, the §25 P8 handoff, the P8 launcher, the memory note. | 1 | 1–8 |

### Not this phase

- **P8's `MeshContinuationCoordinator` and every `BGContinuedProcessingTask` concern** (§14). P7's
  policy takes CPT state as an **input** and must compile and test with it inert; it does not
  register, submit, drive or complete a task. `BGTaskScheduler` errors on a Simulator, so there is
  nothing to observe here anyway.
- **Making `.continuingInBackground` real.** Nothing in shipping raises `.backgrounded` /
  `.foregrounded`. **P7 must not raise them either** — that would assert a CPT is running, which is
  P8's claim. Where the pushed `appIsForeground` leg and the heart predicate's `sessionState` leg
  will deliberately **disagree** is written down in §24.1 and in the shipping doc at
  `MeshNetworkManager.swift:8956–8958`; do not "fix" it by making one leg read the other.
- **Relay increment 2** — still gated on the tier-2 measurement §11 names (chunk pacing at 256 KiB,
  control-stream starvation), not run, so not earned.
- **Option (b) for `handleEncryptedMetadata`; D-7.30's per-session re-gossip budget once-per-window;
  §18.2's partition UX copy; the legacy unsigned two-party removal's retirement; transcript `sid`.**
  All owner's, all unchanged (§24.4).
- **Hardware:** Lane A's report, Lane B's double-dial, item 11's AWDL half, Lane D. Owner's.
- **The conflicted-member blast radius** (§12.3 finding 6) and **the charged forwarder** (finding 4) —
  both are one-line owner answers about policy, not P7 work.
- **`ConnectionInspectorTests.beginSessionCreatesLiveLog()`** — record a new sighting in the ledger,
  do not chase it; it is the owner's suite and it voided four P6 full runs.
- **Re-deciding what a two-device session carries.** P6 item 2's audit settled each behaviour; P7
  gates radios, not features.

### The decisions, with defaults so nothing blocks

| Decision | Default | Why |
|---|---|---|
| **Where the run policy lives** | **A new app-target `ProximityRunPolicy`** — §13 option A. | Options B and C are rejected in §13, and the reasons got stronger: ProximityKit imports no UIKit and cannot import `FernletLock`, and P6 added a second app-only fact (the duress session) to the gate's three. |
| **Whether the policy also writes the routed access gate** | **Yes, and it is the only writer.** Six call sites → one; `applyRoutedAccessGate(_:now:)` does not move. | One decision point (§13's whole argument). The gate keeps its own contract about plaintext. |
| **Whether the policy decides plaintext** | **No. Radios only.** | Two owners for "may we decrypt" is the bug class §13 rejects option C for, and the P8 disagreement needs the two legs independent. |
| **Who owns the poller and at what interval** | **The policy owns it**, one timer, started and stopped with `isSessionLive`, driving ceiling → idle lapse → partition. Start at **30 s** and measure against the 30-minute idle stop. | All three consumers are on-demand *so that nothing spins*; only something that already knows whether a session is live can start and stop one timer honestly. |
| **What the launch restore presents** | **A resume affordance on the Friends surface; nothing modal.** `offersForegroundResume` ⇒ offer; `corrupt` ⇒ say the previous session could not be reopened and that nothing sealed was lost; `deferred` ⇒ **silent** (it retries at the next protected-data rise); a `rejoinBar` hit ⇒ name the mesh as **ended**, never "failed". | A modal on launch fires on every cold start. `FriendsDiscoveryEntry`'s three-way already exists as the surface, and item 2 of P6 made it the session's real entry point. |
| **Which predicate gates a radio** | **`hasCommittedPeer`** for radio guards and the resume arm; **`isSessionLive`** for projections and ceremonies; **`isInSession`** for the layout swap. Never collapse them. | P6 item 2's pass-B P1 — reading the wrong one made a blip sign a termination on a live mesh. |
| **How delete-all / below-age / duress reach the radios** | **As policy INPUTS producing `stop`**, not as direct manager calls. `FernletStore`'s three existing stop sites (`:1701`, `:1868`, `:5327`) are re-aimed at the policy in item 3's retirement pass. | Otherwise the policy is not the single writer and the wall that says it is becomes a fiction — D-13.18's inadmissible-fix lesson, applied to the app target. |
| **Whether P7 adds a persisted surface** | **No.** The policy is derived state; the restore's outcome already lives in the manager. | Any new persisted surface or `UserDefaults` key owes a `Docs/PrivacyWipeCoverage.md` row and delete-all wiring **in the same commit** — P6 added none in its whole phase, and P7 should not be the one to break that. |
| **New display copy** | **`LocalizedStringKey` in the app, frozen English tokens in ProximityKit**, listed in the handoff and synced at close-out from `HEAD`'s catalog blob. | `RoutedShareRefusalCopy` and `SessionHeartStatusCopy` are the pattern; both are exhaustive over `CaseIterable`, so a new case fails a test until it is copied. |

---

## 4. Walls that will bite

P7's diff is mostly in the **app target**, where the walls are thinner and the two files it must edit
are the two every other session also touches. These are the ones that will actually fire.

- **The gate has exactly one writer, and the wall must say so.** After item 2, `applyRoutedAccessGate(`
  appears **once** outside ProximityKit. Count it, name the caller from a brace-matched body, and show
  the wall red once — this is the same shape as `theDrainFiresOnlyFromTheMergeDoor`, which is the
  reason P5's drain shape survived three phases.
- **The policy decides radios, never plaintext.** `MeshRoutedAccessGate` is pure vocabulary and D-10.3
  is its rule: iOS data protection gates plaintext (decrypt + canonical-store mutation) and store
  readability; Fernlet's app lock gates **nothing** in the mesh; a duress session closes the gate,
  observed on its own `.onChange` because it moves at neither a scene nor a protected-data transition.
  "May seal custody" is answered by the store's five states, never by the gate (D-10.2).
- **`.inactive` is not a leg, and `ScenePhase` is not frozen.** `routedGateForeground(for:)`
  (`App/Fernlet/FernletApp.swift:220`) answers `phase != .background` and exists precisely so no site
  writes a raw phase compare that would need an `@unknown default` under warnings-as-errors.
- **Three session predicates, three jobs.** `isSessionLive` (`MeshNetworkManager.swift:1241`) for
  projections and ceremonies, `hasCommittedPeer` for radio guards and the resume arm, `isInSession`
  for the layout swap. P6 item 2's pass-B P1 is what collapsing them costs.
- **Nothing may raise `.backgrounded` / `.foregrounded`.** That asserts a CPT is running (P8's claim).
  The heart predicate's `sessionState` leg is **not** inert — `.linksLost` reaches it on every blip —
  so a policy change that moves session state has a measurable blast radius: grep the readers of
  `.activeForeground` first (there is exactly **one** shipping reader,
  `mayCommitRoutedHeartLedgerJudgement` at `MeshNetworkManager.swift:8964`) and write the count into
  the commit.
- **Nothing may spin.** The three consumers are on-demand *by design*. One timer, owned by the policy,
  started and stopped with session liveness. A timer that survives a stopped session is a battery bug
  P8 will be blamed for.
- **Wipe wall.** Any new persisted surface or `UserDefaults` key owes a
  `Docs/PrivacyWipeCoverage.md` row **and** delete-all writer wiring in the same commit
  (`PersistedSurfaceWipeBoundaryTests`, `PrivacyWipeCoverageTests`, `DeleteAllDataTests`). P6 added
  **no row in its whole phase**; the default for P7 is the same.
- **The routed walls P6 leaves standing, none of which P7 should need to touch:** the registry is the
  only per-type source (`noShippingCodeBranchesOnARoutedTypeToken`); two admission doors and only two;
  every pre-store refusal exits through `refuseRoutedFrameBeforeStore` **except** the digest family;
  **no epoch on the routed path** (`theRoutedPathNamesNoEpochSymbol`); W2's pins move with the file
  that moves them (`everyRoutedPlaintextSeamNamesItsPredicate` sweeps all of
  `FernletKit/Sources/ProximityKit` asserting `sources.count >= 100`;
  `theRoutedStoreNamesNoDecryptionSeam` scans a **literal list** of routed-store files, so a new one
  joins the list or is never scanned); and the three retirement zero-lists
  (`theRetiredPhotoTransportIsGone`, `theRetiredTextTransportIsGone` at
  `Tests/FernletTests/MeshRoutedDrainTests.swift:2400`, `theRetiredMeshHeartTransportIsGone` at
  `:2443`).
- **Schemas.** `MeshSessionContext` is **3** (`MeshSessionContext.swift:60`,
  `MeshSessionContextSchema.current`), the routed index is **2**. Never conflate them, and neither
  should move in P7.
- **The CI selector wall.** Every `MeshP<n>*AcceptanceTests` declared in the tree must be named in
  `.github/workflows/s3-wall.yml`'s mesh step, every named suite must be declared, and every step runs
  through `Scripts/run-gated-suites.sh <label> <min-tests> <Suite>…` with a floor the step actually
  meets — 300 over 50 suites today (`:246–296`). A **cell-level** selector is not an option: the
  script rejects any selector containing a `/`, and `everyGatedSelectorNamesADeclaredSuite` requires
  each selector to name a declared top-level type.
- **Determinism.** `MeshP5DeterminismAcceptanceTests`' two pinned digests
  (`Tests/FernletTests/MeshP5AcceptanceTests.swift:1160`/`:1174`) —
  `ca898bcc9ec7eb099c20bf0b1557e8d450d2d6747d103d899883aef06d466930` (schedule) and
  `594b6f77d18703e3b3f3d180473869360999061b6d207206ba314b0896d55765` (overlay) — **must not move in
  P7**. A move means something touched the overlay, a schedule draw or `MeshScheduleEvent`, and it is
  a red, never a re-pin.
- **Localization.** Wire tokens, `rawValue`s, audit tokens and refusal spellings stay **frozen
  English**; display text is `LocalizedStringKey` in the app, never `String`.
  `RoutedShareRefusalCopy` and `SessionHeartStatusCopy` are the two patterns and both are exhaustive
  over `CaseIterable`. **New keys are listed in the handoff and synced at close-out from `HEAD`'s
  catalog blob** (`f4a69f1`'s method) — never from the held working copy.
- **Power of 10:** ≤ 60 code lines per function/`body`, bounded loops, no `!`/`try!`/`as!`/
  `fatalError`, no swallowed `try?`, no mutable globals, no nested `#if`, warnings-as-errors.
  `FernletApp.body` was already split once to stay under 60 lines (P5 item 10); a policy that folds
  six call sites into one will want to grow it again — split first.
- **MC containment:** `TransportNeutralityBoundaryTests` permits MC types only in
  `MeshMultipeerSession.swift` / `MCPeerIDStore.swift`.
- **Memory lifecycle:** `MemoryLifecycleBoundaryTests`' rules ML4/ML5 fail a new unmarked detached
  `Task` in a host-holding manager. Host-holding app types are still on the old pattern (H-1a.3);
  do not add a sixth.
- **DocC:** every new type carries `///`; `doc-coverage-scan.py` stays at zero; the ProximityKit
  landing page, `Docs/ProximityFunctionIndex.md` and `Docs/FileIndex.md` gain their rows in the same
  commit as the file. `ProximityFunctionIndex` indexes **ProximityKit shipping functions only** — an
  app-target type gets a `FileIndex` row and no function row, and saying so beats silently skipping it.
- **Do NOT touch** `App/Fernlet/Localizable.xcstrings`'s working copy or
  `App/Fernlet.xcodeproj/xcuserdata/**` (held by another session), or the stray PDF in `Docs/`.

---

## 5. Three items with a design call inside

### (a) The policy is a VALUE, and the matrix is the artefact (item 1)

The tempting shape is a coordinator that observes and acts. It is the wrong shape for the same reason
§13 rejects option B: everything that makes the decision hard — seven inputs, three radios, a CPT
state that does not exist yet — is *combinatorial*, and combinatorics belong in a table, not in a
control flow. Build `ProximityRunPolicy` as a pure function from an input struct to an output struct,
enumerate the **full** input product in the test, and give every row a named expectation. The wiring
(items 2–4) then has nothing to decide. This also buys the thing P3–P6 kept buying: a decision a test
can *state*, rather than a condition only a scene can reach.

### (b) The six call sites collapse and the seam does not move (item 2)

`applyRoutedAccessGate(_:now:)` was built in P5 item 10 as the `apply(_:)`-shaped door P7 would
become the single writer of, and P6 did not move it. Resist the urge to "improve" it on the way past:
its five-job re-entry is bounded, idempotent and audited, its rising-edge semantics are tested, and
the duress falling edge is the one clause that does not ride a scene transition. What changes is
**who calls it** and **how many times**. Add the wall that says so, in the same commit, shown red
once. If the owner later wants the policy inside ProximityKit, the cost is one file move and the
UIKit import that §13 rejects — say so in the commit so the alternative stays weighed.

### (c) The resume surface is product work wearing a wiring costume (item 5)

P6 item 7 wired `restoreSessionContextOncePerLaunch` and its review's honest verdict was "materially
real, not hollow" *for the drain* and completely hollow *for the user*: a restore leaves
`currentMesh == nil`, `isInSession` false, the Friends three-way resolving `.fresh`, and nothing
presented for any outcome. The decision half is small and testable (a pure function over
`MeshSessionRestoreOutcome`); the surface half is copy, placement and an affordance that must not
fire on every cold start. **Split them into two passes**, and write the copy as
`LocalizedStringKey` from the first line — the phase that forked `SessionHeartStatusCopy` out of a
`String`-composed failure message is one phase old, and that hole was invisible to both scanners.

---

## 6. Stop conditions — end the loop on any of these

Call `ScheduleWakeup({stop: true})` (or, outside a `/loop`, simply stop), write the handoff (§8), and
report.

1. **P7 is complete** — every item done, gauntlet green, §13 marked BUILT, P8 handoff written.
2. **Blocked on the owner** and no tier-1 work remains. Say exactly what is needed and stop; do not
   idle-wake waiting for a human. (Every §3 decision has a default, so this should not happen before
   item 8.)
3. **Budget is running low.** Stop with items to spare, not at zero.
4. **Context is filling.** `/loop` resumes the same context and never compacts, so a long P7 will run
   out. When the ledger is the only thing you would need to resume, stop and let a fresh session
   continue from it.
5. **A gate goes red for a reason you did not cause.** Record it, stop, report — do not spend
   iterations bisecting someone else's commit. (`ConnectionInspectorTests.beginSessionCreatesLiveLog()`
   is the known one: ~206 s under full-suite load against a 120 s limit. A log containing
   `Restarting after unexpected exit, crash, or test timeout` has **no usable total** — re-run, never
   bisect. `sync-string-catalogs.sh --check` may be known-red on stale keys from the held catalog.)

### Gauntlet — the subagent runs it; you check the marker line

```bash
python3 Scripts/power-of-10-scan.py
python3 Scripts/doc-coverage-scan.py
xcodebuild build-for-testing -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test-without-building -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FernletTests
Scripts/spm-wall-check.sh          # once anything wall-relevant moves
Scripts/spm-wall-selftest.sh       # after any change to the wall or its permit lists
```

**The CURRENT baseline is `4866 tests in 486 suites`, green, EXIT=0, ONE invocation, 1909.4 s**
(P6 item 10, `64c47f2`, `logs/item10/full-03.log`). P5's boundary was 4615 / 461. Check the **exit
code** and the `Test run with N tests` line, never a grep for "passed"; count `◇ Suite` starts against
`✔ Suite` passes; and grep for `Restarting after unexpected exit, crash, or test timeout` **before**
believing any total. Repository gates at the same bundle: `power-of-10-scan.py` → 503 files, **0
violations**, assertion density 0.781 (floor 0.68); `doc-coverage-scan.py` → **0** undocumented type
declarations.

Per-item, the subset is: every suite the diff touches + the routed suites (`MeshRouted*`, `MeshP5*`,
`MeshP6*`, `MeshP7*`) + the wall suites (`MeshRoutedLockedDeviceTests`, `MeshRoutedDrainTests`,
`MeshRoutedDrainWallTests`, `MeshRoutedRefusalBudgetTests`, `CryptographicPurposeBoundaryTests`,
`CIGateSelectorBoundaryTests`, `LocalizationBoundaryTests`, `PowerOfTenBoundaryTests`) — and, because
P7 edits the app target, also `PersistedSurfaceWipeBoundaryTests`, `PrivacyWipeCoverageTests`,
`DeleteAllDataTests`, `NoTrackingBoundaryTests`, `MemoryLifecycleBoundaryTests` and
`TransportNeutralityBoundaryTests`. **Regenerate the suite list from the `@Suite` declarations**,
never inherit one, and add by hand the three suites that carry no `@Suite` attribute
(`MeshRoutedStoreIsolationTests`, `PowerOfTenBoundaryTests`, `LocalizationBoundaryTests`). A
`-only-testing` line must name the **struct**, never the file:
`MeshRoutedDrainTests.swift` holds two suites, `MeshRoutedManifestTests.swift` holds two, and
`MeshIntroductionAuthorityTests.swift` holds three.

**Every new or amended wall is shown red once**: disable the guard (or revert the fix), **REBUILD**,
run the suite, keep the log, restore the exact text, re-grep the needles, **REBUILD** again.
`test-without-building` runs the LAST build. A negative whose "before" text is an empty string cannot
be reverted by a count-1 replace.

---

## 7. Ledger template

Create `Docs/Mesh-Migration-Loop-Ledger-P7.md` on iteration 1 if absent. Keep it **short** — it is
read on every wake, so every line costs orchestrator budget forever.

```markdown
# Mesh Migration Loop Ledger — P7

**Phase:** P7 (the app-layer run policy, the poller, the resume surface) · **Prompt:** [Next-Round-Prompt-Mesh-P7-2026-09-12.md](Next-Round-Prompt-Mesh-P7-2026-09-12.md)
**Started:** 2026-09-__ · **Iteration:** 1 · **Tree at seed:** `main` = the P6 close-out commit (SHA in the P6 ledger's item 11 row); `origin/main` = `3a32be0` — P6 is merged and **not pushed**

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`. Tier per §2.
| # | Item | Tier | Prereq | State | SHA | Note |
|---|---|---|---|---|---|---|
| 1 | `ProximityRunPolicy` as a pure value + the matrix over the full input product | 1 | — | todo | | |
| 2 | The policy is the single writer of `applyRoutedAccessGate` (6 sites → 1) | 1 | 1 | todo | | |
| 3 | The radios get `apply(_:)` seams; ContentView + FernletStore stop calling them | 1 | 1, 2 | todo | | two passes |
| 4 | The poller — one timer, three consumers (ceiling → idle lapse → partition) | 1 | 1, 3 | todo | | |
| 5 | The resume surface over `MeshSessionRestoreOutcome` | 1 + 1b | 1 | todo | | two passes |
| 6 | Gate `MeshRoutedDrainTests` (43) and price P6's ~286 ungated cells | 1 | — | todo | | P6 §12.3 finding 14 |
| 7 | The P7 acceptance battery + CI gate lines, one commit | 1 | 1–6 | todo | | |
| 8 | Tier 2: the backgrounding half; the heart eligibility negative; P6's remaining rows behind `FERNLET_MESH_ARM_AFTER` | 2 | 3, 4 | todo | | timebox 2 iterations |
| 9 | Close-out: §13 BUILT, §25 P8 handoff, P8 launcher, memory | 1 | 1–8 | todo | | draft → verify → apply from files |

## Blocked on owner
- P6 is merged to `main` (the close-out commit) and **not pushed**; `origin/main` = `3a32be0`. The first push is the first time CI builds any P6 code, against a `mesh-batteries` floor of 300 over 50 suites that has **never run on a hosted runner**.
- Carried unchanged from plan §24.4: option (b) for `handleEncryptedMetadata`; D-7.30 once-per-window; §18.2 copy; the legacy unsigned removal; transcript `sid`; the hardware lanes (A report, B double-dial, AWDL, D with the cable out); the two census/duress questions; the final wording of the routed hold / refusal / heart copy (P6 added 19 sentences, 17 of them new to the catalog); §17.3's privacy paragraph (drafted in §24.4); `browsed peers=` downgraded from `.notice`/`.public`; the `HeartDrop` CloudKit record type still not promoted to the Production schema.
- P6 §12.3's open findings, none of them P7 work: the charged forwarder (4), `ConnectionInspectorTests` (5), the conflicted-member blast radius (6), the un-linked third member (7), item 6's two residuals (8), D-4.5's expiring heart (9), I-13's vanished pair (10), the peer-holdings-shrink shape (11), tier 2's un-run rows (12), L-3's arming race (13), the unpinned audit tokens (15), 1c's sibling wall-clock leg (16), the battery's own named weaknesses (17), the un-taken `MeshRoutedAckStageTable.increment1` alias cleanup (19), and the grouped residuals of finding 20.

## Decisions taken (defaults from §3 unless the owner overrides)
| Decision | Choice | Taken on |
|---|---|---|
| Where the run policy lives | (default: app-target `ProximityRunPolicy`, §13 option A) | — |
| Single writer of the routed access gate | (default: yes, six sites → one, seam unmoved) | — |
| Policy decides plaintext | (default: no — radios only) | — |
| Poller ownership and interval | (default: policy-owned, one timer, 30 s, ceiling → idle lapse → partition) | — |
| What the launch restore presents | (default: Friends-surface affordance, nothing modal; deferred is silent) | — |
| Delete-all / age / duress reach the radios | (default: as policy inputs producing `stop`) | — |
| New persisted surface | (default: none) | — |

## Surprises worth not re-deriving
- (seed from §9 of this launcher's "Lessons carried from P6")

## Next item
1 (or 6, which is file-disjoint and has no prereq) — the orchestrator's call on iteration 1
```

**Lessons carried from P6 — seed the surprises list with these so P7 does not re-learn them:**
- **A full log containing `Restarting after unexpected exit, crash, or test timeout` has NO usable
  total.** Its `Test run with N tests` line covers the SECOND launch only. Grep for that line before
  believing a count. A voided run costs ~30 min — **re-run, do not bisect**.
- **A red can be a starvation, not a regression.** One P6 full run failed with a single issue where
  `MeshP4ConvergencePropertyAcceptanceTests.oneScheduleHealedTwoValidWaysConvergesOnIdenticalState()`
  took **1749 of 1938 seconds**, and it passed in **1.304 s** re-run alone. A fixed-seed comparison
  that takes 1749 s was starved, not regressed.
- **Do not chain a build and a test run in one backgrounded command on a shared DerivedData** — two
  `xcodebuild` processes on one DerivedData produce `unable to attach DB`, and `xcodebuild` outlives
  the shell step that started it. One command at a time, `pgrep -x xcodebuild` before each.
- **`-only-testing:` names the SUITE, and one file can hold four of them.** A P6 probe ran
  `MeshSessionStateMachineTests` for a cell living in `MeshSessionLifecycleManagerTests` — same file,
  690 lines apart — and proved nothing until it was re-run. `-only-testing:Suite/cell` runs **0** tests
  under a green banner even spelled correctly and even with `()`.
- **`@Test(arguments: [])` is green over nothing**, and a wall whose needle cannot match anything is
  the same failure wearing a different hat: P6 found a construction wall whose allowlist entry
  exempted nothing because the declaring file's own house form put the first label on the next line.
  **Collapse whitespace before `contains`, and assert that every allowlist entry matches something.**
- **A negative control whose "before" text is an empty string cannot be reverted by a count-1
  replace** (`text.count("")` is the file length) — revert deletions by re-inserting the exact block,
  and re-grep the needles before rebuilding.
- **"Inert until P8" is a claim that rots.** `sessionState == .activeForeground` was documented inert
  for a whole phase and was not — `.linksLost` reaches it on every link blip.
- **Measure a predicate's blast radius before changing it.** P6 item 6's P1 was bounded by grepping
  the readers of `.activeForeground` and finding exactly one. Write the count into the commit.
- **A roster-wide invariant is not key-generic.** `routedDeliveryState` answers `.reclaimed` for "no
  record", so a roster-wide claim about a single-recipient item passes at every non-recipient for the
  wrong reason.
- **A process-global audit signal cannot witness a per-cell claim** when suites run concurrently in
  one process; witness per run.
- **The first test invocation after a build or an idle gap hangs** (~350 s, 1 "failed" test); the
  retry is the acceptance. Warm the runner with a tiny suite first.
- **zsh passes an unquoted `$ARGS` string as ONE argument** — build `-only-testing:` flags into an
  array. A `while read` over a list with no trailing newline silently drops the LAST suite.
- **Under full-suite load, 1–4 `✔ Suite … passed` lines are corrupted by app `[startup]` stdout
  interleaving** — `starts − passes` of a few is a logging artefact; the banner, the exit code and
  zero `✘` are the signals.
- **`#expect(_, "literal")` only** — Swift Testing's `Comment?` rejects concatenation as well as
  interpolation. Bind `allSatisfy` Bools first. Never `==` on signed records (Ed25519 is hedged).
  `MeshRoutedStorageScope.production` may not appear as a test literal.
- **A headless Simulator satisfies the foreground leg by accident.** With its links up,
  `sessionState` stays `.activeForeground` because nothing in shipping raises `.backgrounded` /
  `.foregrounded` — so the lane cannot *prove* that leg, and `simctl` has no lock verb, so data
  protection is unobservable there. The leg is not inert: `.linksLost` closes it on every blip.
- **Any harness bypass that skips a shipping door is a place where a product claim can hide.** P6's
  L-1 (a device with an unsupported sealed schema can never join, and only the launch restore's
  quarantine clears it) went unseen for five phases because every Lane C launch bypassed the restore.
- **Long agent work can die of the session usage limit at a fixed local reset hour** — resume, don't
  retry; apply steps read their inputs from scratch files.
- **Closed; do not re-audit:** `MeshTunnelConvergence`, the id-vs-endpoint family, the crypto-purpose
  / `PayloadType` / record-kind spellings (walled), plan §10.7–§10.10, §11.1–§11.4 and **§12.1–§12.4**,
  `Docs/Proximity-Security-Followups-2026-08-18.md` §1.
- Concurrent sessions share this tree and sim fleet; `Localizable.xcstrings` +
  `xcschememanagement.plist` are held by another session — never stage them.

---

## 8. Close-out, when P7 is done

1. Mark P7 **BUILT** in §13 of the plan with landing SHAs, adding §13.1–§13.4 in the §11.1–§11.4 /
   §12.1–§12.4 format (what landed; deviations from the sketch and why; findings for the owner
   deliberately not fixed; acceptance evidence with the verified `-only-testing` lines).
2. Record deviations from the sketch and why — say where §13 was silent and which §3 default was
   taken, and which §5 calls the owner should read as **policy acts**.
3. Record findings you deliberately did NOT fix, with what they cost, the way §11.3 and §12.3 do.
   **Every "Blocked on owner" line in the ledger must end resolved, taken-as-default, or written into
   §13.3 with its cost** — P6's close-out made that the rule.
4. Memory note: what landed, what surprised you, what the next session must not re-derive.
5. Write the **P8 handoff block** (a new §25, in the §23/§24 format). P8 is background continuation
   (§14): hand it the exact place the pushed `appIsForeground` leg and the heart predicate's
   `sessionState` leg must **disagree**, the poller P7 built and what it costs while a CPT runs, the
   progress strategy §14 already fixes (elapsed session time toward the ceiling, monotonic by
   construction), and §15's hardware gates as entry criteria.
6. Write the **P8 launcher** from §25, as this file was written from §24. **Fact-check every claim
   against HEAD before writing it** — the P6 launcher had 10 wrong of 62, and each cost an iteration.
7. **Run the close-out as draft → adversarial verify → apply from files** (§0 rule 6); consider a
   post-close external review as P5 had — it found a P1.
8. **Sync the string catalog from `HEAD`'s blob** for every key the phase's handoffs listed
   (`f4a69f1`'s method, repeated at P6's close-out), and check the count against the list before
   committing — P6's owed list was 19 sentences of which **2 already existed**.
9. Note anything P7 learned that re-tiers P8 further.

---

## 9. The road to TestFlight

The owner's goal is the whole migration before the first TestFlight build. After P7, two phases remain.

| Session | Phase | Prerequisite |
|---|---|---|
| P2 (done) | NetworkMeshSession over QUIC | built + proven sim↔sim |
| P3 (done) | durable context, roster, membership | built; three sims form a full mesh |
| P4 (done) | partition + merge | built; property test found 3 merge defects, all closed by P5 |
| P5 (done) | encrypted store-and-forward routing | built (§11 BUILT `848f202`; review corrections `3a32be0`); photos ride it end to end; 4615 green |
| P6 (done) | feature routing (text, hearts) + key advertisement + pairwise identity | built (§12 BUILT; merged to `main`, **not pushed**); 4866 green; **text AND a routed heart both observed end to end on real QUIC** — the two-session ceremony P2 could not reach. The foreground gate of the heart ceremony is still untested on any radio — a headless Simulator satisfies its `sessionState` leg by accident rather than by proof, and `.continuingInBackground` is P8's. |
| **this** | **P7** — app-layer run policy, the poller, the resume surface | P3's states, P5's gate seam, P6's founding change. **Mostly wiring**; the resume surface is the product half. |
| +1 | **P8** — background continuation | **§15 gates: physical devices, multi-hour soaks, Low Power Mode, battery — irreducibly physical.** First hardware sample: iOS ended a user-started continued-processing task ≈ 46 s in. |
| +2 | **P9/P10** — remaining radios, MC retirement (iOS 27), companion `BGAppRefreshTask` | P2 proven in the field. |

**The tier-1 re-tier holds through P7 and not into P8.** P7's one genuinely-lane question is the
backgrounding half of the gate, and it is a sim-lane question. P8's background / battery / thermal
gates are the one thing that still needs the phone drawer and the multi-hour soaks TestFlight does
not supply — and a Simulator cannot produce `.continuingInBackground` at all.

**Still owed by the owner, not blocking P7** (carried from §24.4):
- **The push.** P6 is merged to `main` (the close-out commit) and `origin/main` is still `3a32be0`. The first
  push is also the first time CI builds any P6 code, against a `mesh-batteries` floor of 300 over 50
  suites that has never run on a hosted runner.
- **Hardware, unchanged:** the Lane A report, Lane B's double-dial row, the **AWDL half** of item 11,
  and **Lane D** with the cable OUT.
- **Option (b)**, **D-7.30**, **transcript `sid`**, **the legacy unsigned removal**, **§18.2 copy**,
  **the census/duress questions**, and **the final wording** of the routed hold, refusal and heart
  copy — P6 added **19** display sentences and they are already in the committed catalog (`6b77ec2`,
  17 added + 2 already present); only the English is outstanding.
- **§17.3's privacy paragraph** by the first TestFlight build — now plural and drafted in §24.4; and
  **downgrade `browsed peers=` from `.notice`/`.public`** before QUIC ships.
- **The `HeartDrop` CloudKit record type** is still not promoted to the CloudKit **Production**
  schema (`Docs/CloudKit-Schema-Deploy.md:95`; `Docs/ImplementationPlan.md:51` carries it as an
  App-Store-readiness owner action).
