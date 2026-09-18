# Loop Prompt — ProximityKit Network Migration: P8 (background continuation), preceded by the P7 gauntlet

**Written:** 2026-09-18, at the P7 boundary (branch `claude/zen-goodall-wejlxg` = `e8ffb44` + the close-out commit; **P7 is pushed to that branch, unmerged, and UNBUILT** — no P7 file has compiled).
**Plan:** [Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md](Plan-ProximityKit-Network-Migration-2026-08-27.md) — the authority. **§14 is the P8 specification; §15 is the entry gate; §25 is the handoff; §13.3's findings 1–3 and 9–12 are the named obligations the gauntlet clears first.** This file is the launcher and the loop contract.
**Ledger:** `Docs/Mesh-Migration-Loop-Ledger-P8.md` — the loop's memory, created on iteration 1 (§7). The P7 ledger is a finished record; **read its "Owed to a Mac" section once, then do not reuse it.**
**Device plan:** [Docs/Mesh-P7-Physical-Device-Test-Plan-2026-09-18.md](Mesh-P7-Physical-Device-Test-Plan-2026-09-18.md) — the tier-3 lane's first document; its section F is §15 as a checklist.
**Scope:** first, **build and run P7** (item 0 — nothing else starts until it is green); then build **P8** — the app-target `MeshContinuationCoordinator` that registers, submits, drives and completes one `BGContinuedProcessingTask` per mesh and **feeds** the policy P7 built; the one ProximityKit verb P7 found missing (stop browsing, keep links); the two session-state raises nothing in shipping performs today; the progress strategy §14 fixes; and the §15 hardware gates on physical devices. **Stop the loop at the P8 boundary.** P8's evidence is physical: a Simulator can reach none of §15.

---

## How to start

```
/loop Read Docs/Next-Round-Prompt-Mesh-P8-2026-09-18.md and run one iteration of it.
```

Self-paced (no interval). A session that is not a `/loop` runs the same iterations back to back; the
ledger is the state either way. **This launcher assumes a Mac with Xcode, at least one Simulator and,
from item 8 on, two to four physical devices.** A session without a toolchain can do exactly one thing
here — nothing — and should say so and stop (P7 wrote six items unbuilt and that debt is item 0).

---

## 0. Orchestrator contract — read this first, it is the binding constraint

**The orchestrator is a limited model budget.** Every rule below exists to protect it.

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

Delegate with `Agent(..., model: "opus")`. **Each item is three dispatches, never one:** understand +
design + implement, then an **adversarial verify** by a second agent that has not seen the first's
reasoning, then a fix agent for what survives. A Workflow is the owner's opt-in, never the default.
**P7 precedent:** the owner declined the dispatch on iteration 1 and the orchestrator did every item
in-session; if that happens again, do the work, record it in the ledger's decisions table as a process
deviation, and keep the three-step *shape* (design → adversarial re-read → fix) even inside one
session — P7's in-session re-read caught a wrong pinned count before commit.

### Hard token rules for the orchestrator

1. **Never `cat` a source file.** `sed -n 'a,bp'` or a targeted `grep -n`; more than ~60 lines is a
   subagent's job.
2. **Never let build or test output reach context.**
   ```bash
   xcodebuild … > "$LOG" 2>&1; echo "EXIT=$?" >> "$LOG"
   grep -E "EXIT=|BUILD (SUCCEEDED|FAILED)|TEST EXECUTE|Test run with" "$LOG"
   ```
3. **One work item per iteration.** Item 0 may take several iterations; each fix commit is its own.
4. **Write state to the ledger, not to your own memory.**
5. **Stop early rather than run out.** See §6.
6. **A close-out step that synthesises many facts runs as draft → adversarial verify → apply from
   scratch files.**
7. **A row that lands in two passes needs its gate to assert the later pass RAN.** P8's items 3 and 5
   are two-pass by shape (a verb, then the executor using it; a raise, then the disagreement cell).
8. **P8 edits the app target AND ProximityKit's session state machine**, the one file every phase has
   walled hardest. `git status` before and after every dispatch; never stage a file the item did not
   name; never stage `App/Fernlet/Localizable.xcstrings`'s working copy, `xcuserdata/**`, or the
   stray PDF in `Docs/`.

### If the budget runs out mid-phase

Stop the loop, write the handoff (§6/§8), and say plainly what is left.

---

## 1. Each iteration, in order

1. **Read the ledger.** `Docs/Mesh-Migration-Loop-Ledger-P8.md`. On iteration 1, create it from §7's
   template.
2. **Check the tree is safe to build on:**
   ```bash
   git -C . log --oneline -1; git -C . status --porcelain
   ```
   Commit with explicit pathspecs, never `git add -A`. Catalog keys are synced from `HEAD`'s blob
   (`Scripts/sync-string-catalogs.sh`), never from a held working copy.
3. **Pick the next item** whose prerequisites are met, from §3, in ledger order. **Item 0 is not
   optional and nothing precedes it.**
4. **Dispatch the three agents** with the item's full context: the acceptance criterion, the walls
   (§4), the ledger's decisions, and the gauntlet subset for what it touched (§6).
5. **Verify** — grep the marker line yourself. Check the exit code and `Test run with N tests`, count
   `◇ Suite` starts against `✔ Suite` passes, and grep for `Restarting after unexpected exit, crash,
   or test timeout` before believing any total.
6. **Commit** with explicit pathspecs.
7. **Update the ledger**: item → done with the SHA, one line on anything surprising, the next item.
8. **Schedule the next wake**, or stop per §6.

---

## 2. Testing strategy (re-tiered at the P7 boundary, §25.5)

| Tier | What it proves | Cost |
|---|---|---|
| **1 — no radio** | The coordinator's state machine as a **pure value** (requested → running → refused / expired / completed, exactly-once completion), the progress arithmetic (elapsed toward `sessionCeiling`, monotonic by construction), the policy's continuation rows re-run whole (the 23 040-row product already exists — extend the expectation, never sample), the disagreement cell (pushed gate leg false, `sessionState == .continuingInBackground`, the heart predicate closed), the new verb's contract on the founding rig (browsing stopped, committed links kept, slots intact). **If a check CAN live here, it MUST.** | Free, deterministic, CI. |
| **1b — the app's UI suite** | The CPT-refused / expired card on the Friends tab; the resume card P7 added; the tab and scene edges. Serially, environment pinned (iPhone 17, portrait). | Minutes, same Mac. |
| **2 — sim↔sim, real QUIC** | P7's item 8 (carried, §3 item 2): the backgrounding half of the gate, the heart eligibility negative, the `FERNLET_MESH_ARM_AFTER` rows. **Nothing about the task itself** — `BGTaskScheduler` refuses on a Simulator with error 1. Budget ≈ 3.5 × the driver tick number. | One Mac, `simctl`. |
| **3 — physical devices** | **P8's acceptance.** §15.1 radio matrix, §15.2 partition walks, §15.3 progress soak, §15.4 Wi-Fi Aware; the device plan's sections A–E first (P7's behaviours on hardware, cheap), then F. Two devices minimum, three for partitions, four for the topology row. Results go in the runbook's Lane B table and the device plan's table, with dates. | Owner's devices and hours. |

Lane gotchas carried from P2–P7 — all paid for: `STAGGER=1`, re-harvest identities after any
`xcodebuild test`; a fresh log directory per run, `pgrep -x xcodebuild` before believing a failure;
the first `test-without-building` after a build hangs (~350 s) — warm with a tiny suite; `--console-pty`
intermittently attaches no stdout — verify the `[mesh-matrix] run label=` banner; every Lane C launch
carries `FERNLET_MESH_MATRIX=1` and **bypasses the launch restore**; never chain a build and a test run
on one DerivedData. **New for tier 3:** run over Wi-Fi with the cable OUT and check no ready line names
`en8`/`en9`/`anpi0`; Console.app filtered on `subsystem:com.fernlet` is the evidence stream; a phone
plugged into a Mac is a phone that never sleeps the way the row needs it to.

---

## 3. The work list

Ledger order. *File:line anchors are current at `e8ffb44`; re-check before editing — item 0's fixes
move them.*

| # | Item | Tier | Prereq |
|---|---|---|---|
| 0 | **Build and run P7 — the gauntlet the P7 session could not.** In the P7 ledger's order (§ "Owed to a Mac"): the two scans; `build-for-testing`; `ProximityRunPolicyTests` alone as the warm-up; per item, the named suites and the **red-once** step for every wall (W8's two halves; the retirement wall by verb and by name; the poller wall; the resume surface wall; `everyMeshAcceptanceBatteryIsGated` by deleting one selector); the mesh-batteries line exactly as the workflow spells it and **the floor raised to what it executed** (expected 313; write the measured number, and the same for `CIGateSelectorBoundaryTests`' pin, 42 by declaration); the **catalog sync** of P7's thirteen sentences from `HEAD`'s blob (count them against the ledger's list); the UI suite serially; the full suite against P6's baseline (4 866 / 486, one invocation, EXIT=0). Every red is a **P7 fix commit** with its own ledger line; the watch list is in the ledger (Release-config main-actor isolation vs `ProximityRunPolicy.Input`'s `Hashable`; the funnel's `duressSessionActive` parameter shadowing; a real `FernletStore` per funnel cell). Then the three simulator eyeballs the ledger names (Friends tab entry/exit; Control Centre over the Friends tab; delete-all during a live session). **Item 0 ends with plan §13's heading changed from IMPLEMENTED, UNBUILT to BUILT, with the measured numbers written into §13.4** — one commit, one ledger line. | 1 + 1b | — |
| 1 | **P7's item 6, carried: gate `MeshRoutedDrainTests` (43 `@Test`) and price P6's ~243 other ungated cells.** Measure the mesh-batteries step with and without; raise the floor by the measured count; record the price. File-disjoint from everything else. | 1 | 0 |
| 2 | **P7's item 8, carried: tier 2.** (a) The backgrounding half of the gate — a second `simctl launch` of one node, the pushed `appIsForeground` leg observed falling (`mesh.routedAccess.gateChanged`) and the routed re-entry staying down until the foreground push; (b) the heart eligibility negative (a third simulator that sat out session 1 — FINAL, audited refusal, custody kept); (c) only behind a `FERNLET_MESH_ARM_AFTER=<polls>` hook closing L-3: the removal vote, the `.chatAgeGated` three-leg negative, the app-path founding over MC. Timebox two iterations; what does not cross is recorded by name with a paste-ready owner sentence. | 2 | 0 |
| 3 | **The verb P7 found missing: stop browsing and admission, keep committed links.** Today `stopJoin()` (`MeshNetworkManager.swift:2040`) → `stopSearching()` (`:10764`) cancels every slot coordinator, stops the transport and clears group-key state, so the policy's row "mesh `run`, discovery `stop`" is **refused aloud** (`ProximityRunSeams.swift:72` `refuseBackgroundDiscoveryStop`, audit `proximityRunPolicy.unsupportedTransition` at `:224`). Add ONE public `MeshNetworkManager` verb that stops the browser and the admission door and keeps every committed slot, its coordinator and the group-key state; its inverse is the existing `resumeSearchingForPartitionedMesh()` (`:2081`). Pass 1: the verb, on the founding rig — committed links intact, nothing admitted afterwards, `hasCommittedPeer` unchanged, `isSearching` false. Pass 2: `ProximityRunTransition` emits the new action instead of the refusal, the executor calls the verb (still the one file), and **the refusal's audit token becomes a zero-count wall** in `ProximityRunSeamsTests` — the gate must assert pass 2 ran. Blast radius first: grep the readers of `isSearching` and of every slot-state predicate the verb leaves alone, and write the counts into the commit. | 1 | 0 |
| 4 | **`MeshContinuationCoordinator` as a pure value, with the state table as its test** (§14). App-target type, **no task submission in this commit**: (requested / running / refused / expired / completed) × (mesh started, first peer committed, session ended, task expired, task cancelled, app foregrounded) → next state + the `ProximityContinuationState` to feed + whether completion fires — **exactly once, on every path** (the probe's `completeBackgroundTask(success:)` idiom, `NetworkMeshFeasibilityProbe.swift:1400`). The progress arithmetic beside it: elapsed session time toward `sessionCeiling.hardDeadline` as a monotonic fraction, title `Fernlet mesh`, subtitle `N friends connected` (roster members with fresh authenticated heartbeats, excluding self). Table-driven over the full product. | 1 | 0 |
| 5 | **The two raises, and the disagreement cell.** The coordinator raises `applySessionEvent(.backgrounded)` at task start and `.foregrounded` at task end — **grepped at `e8ffb44`, nothing under `FernletKit/Sources` or `App` raises either** (`MeshSessionStateMachine.swift:101/:104`). Pass 1: the raises, from the coordinator only, and a wall that counts them at exactly two under `App/` and zero elsewhere. Pass 2: the cell §24.1 and §25.1 name — with a task running and the scene backgrounded, the pushed gate leg is **false** (`routedGateForeground(for:)`, `FernletApp.swift:221`), the routed re-entry does not run, `sessionState == .continuingInBackground`, and `mayCommitRoutedHeartLedgerJudgement` (`MeshNetworkManager.swift:8964`, the only reader) is **closed**; a custodied heart defers and one `.foregrounded` edge yields exactly one ack (P6's deferred-quarter shape, now reachable in shipping). **Do not make one leg read the other.** | 1 | 3, 4 |
| 6 | **Wiring the task: registration, submission, expiry, completion.** Concrete id `MBO.Fernlet.mesh-continuation.<meshID>` registered at mesh start (the plist wildcard is at `Info.plist:32`), the request submitted with `.fail` on the user's start/join action once the first peer commits, the expiration handler, cancellation, and exactly-once completion into one idempotent shutdown that **keeps the tunnel** (the probe tears its own down — the product must not). The coordinator **feeds** the store (`FernletStore.reapplyProximityRunPolicy(now:)`, `FernletStore.swift:1995`, through a setter like the two nearby-setting setters); it never calls a radio, and `ProximityRunSeamsTests`' retirement wall proves it. `ProximityForegroundAnchor` suppressed for a continued mesh; its orphan reaper stays. | 1 + 3 | 4, 5 |
| 7 | **What a refusal, an expiry and a system end present.** The Friends tab's card slot (`ConnectView.swift:493`, `sessionResumeBanner`'s home) gains the continuation states — refused ⇒ the session stays open only while Fernlet is on screen; expired / ended by iOS ⇒ it continues in the foreground, nothing lost that was sealed. Decision half as a pure table over the coordinator's state (tier 1), copy as `LocalizedStringKey` from the first line, keys listed for the close-out sync. §17.3's privacy sentence gains "background continuation uses local network + battery and iOS may end it". | 1 + 1b | 4 |
| 8 | **Tier 3, part one: P7 on hardware.** The device plan's sections A–E on two devices: tab/scene edges, the hard stops, the settings toggles, the poller's three verdicts (a partition, a 30-minute idle stop, and the 6-hour ceiling as the first soak), the resume card for every reachable outcome. Results and dates into the plan's table; every deviation from the expected column is a finding, by name. **This is the first time any P7 behaviour is observed anywhere.** | 3 | 0 |
| 9 | **Tier 3, part two: §15 on hardware — the entry gate.** §15.1 (the tunnel surviving background + lock; re-dial via cached endpoint while backgrounded; a fresh background browse, recorded either way; × infra-Wi-Fi and AWDL; Low Power Mode; memory pressure), §15.2 (2/2 and 3/1 walks, a removal vote, a departure carried by a third member), §15.3 (3 h and 6 h soaks with elapsed-based progress under normal phone use — the gate is "the task survives while progress advances slowly"), §15.4 (the bounded two-day Wi-Fi Aware evaluation, a recommendation). Every row into the runbook's Lane B table with a date. **If §15.3 fails, the degraded ladder in §14 activates and P8's scope shrinks to foreground + opportunistic** — everything else stands, and that is a recorded decision, not a failure. | 3 | 6, 8 |
| 10 | **The P8 acceptance battery + CI gate lines, one commit.** One serialized `MeshP8<Clause>AcceptanceTests` per clause (the coordinator's table whole; the verb; the raises and the disagreement cell; the presentation table) + an honesty suite naming what cannot run on CI (every §15 row). `CIGateSelectorBoundaryTests`' pin **measured** at the commit that moves it; the floor raised by the measured count. Neither determinism digest may move. | 1 | 3–7 |
| 11 | **Close-out** (§8): §14 BUILT with §14.1–§14.4, §15's table filled with dates, the §26 P9/P10 handoff, the next launcher, the memory note. | 1 | 0–10 |

### Not this phase

- **P9's radios** (recipe share and presence over QUIC, MC retirement) and **P10's `BGAppRefreshTask`**
  (§17) — a companion refresh handler that never touches the mesh.
- **Relay increment 2** — still gated on the tier-2 measurement §11 names, still unearned.
- **Re-deciding the policy.** `ProximityRunPolicy`'s table is P7's; P8 feeds one input and, with
  item 3, makes one refused row executable. A P8 that rewrites a policy row is a P8 that has found a
  P7 bug — fix it as a P7 fix commit with the full 23 040-row table re-run, and say so.
- **Making the policy or a scene handler raise `.backgrounded`.** Only the coordinator, only with a
  task in hand.
- **Option (b) for `handleEncryptedMetadata`, D-7.30, §18.2's copy, the legacy unsigned removal,
  transcript `sid`, the census/duress questions** — owner's, unchanged (§25.4).
- **`ConnectionInspectorTests.beginSessionCreatesLiveLog()`** — record a sighting, do not chase it.

### The decisions, with defaults so nothing blocks

| Decision | Default | Why |
|---|---|---|
| **The first iteration** | **Item 0, whole, before any P8 file.** | An unbuilt policy is a claim; P8's every row sits on it. |
| **How the coordinator reaches the radios** | **Feeds `ProximityContinuationState` into the store, which re-runs the policy.** Never a radio verb; the retirement wall stays at one file. | §13's whole argument. |
| **Who raises `.backgrounded` / `.foregrounded`** | **The coordinator, at task start and end — nobody else.** | Only the thing holding the task knows one is running. |
| **The stop-browsing verb** | **One new public `MeshNetworkManager` verb** that keeps committed slots, coordinators and group-key state; `stopJoin()` unchanged; inverse = `resumeSearchingForPartitionedMesh()`. | `stopSearching()` tears slots down; the policy's `hold` and the refused row are the same absence. |
| **The progress unit** | **Elapsed session time toward `sessionCeiling.hardDeadline`** (every member holds it since P7), monotonic; title/subtitle carry the human truth. | The API's termination rule demands monotonic progress. |
| **Whether the poller keeps running under a task** | **Yes, unchanged** — it enforces the two clocks §14 names and stops when the process is suspended. | No second clock for one deadline. |
| **When the task is submitted** | **On the user's start/join once the first peer commits**, `.fail` strategy, concrete id. | The probe's pattern; the plist is ready. |
| **What refusal / expiry presents** | **The Friends card slot, nothing modal, `LocalizedStringKey`.** | P7 built the slot; §13 required the explanation. |
| **The degraded ladder** | **Chosen by §15.3's result, recorded as a decision.** | §14 pre-decided the rungs. |
| **New persisted surface** | **None** beyond the task's own; any key owes a wipe row + delete-all wiring in the same commit. | P6 and P7 added none. |

---

## 4. Walls that will bite

- **One gate writer** (W8, `MeshRoutedLockedDeviceTests`): `applyRoutedAccessGate(` once under
  `App/`, inside `FernletStore.runProximityPolicy`. The coordinator does not push the gate.
- **One radio-speaking file** (`ProximityRunSeamsTests.everyRadioVerbLivesInTheSeamsFile`): every
  radio verb's home is `FernletStore.executeProximityRunActions`; `MeshRejectionMatrixHarness` is
  exempted **by name**. Item 3's new verb joins that list in the same commit or the wall reddens.
- **One timer** (`ProximitySessionPollerTests`): `pollSession(` from one app file, one `Task`,
  bounded, self-stopping. Do not add a task-side clock.
- **The refused row's token** (`proximityRunPolicy.unsupportedTransition`): a residual until item 3's
  pass 2, a **zero-count wall** after it.
- **The two raises**: exactly two call sites under `App/`, zero under `FernletKit/Sources`; the heart
  predicate keeps its own `sessionState` leg (`MeshNetworkManager.swift:8964`, the only reader — grep
  it before touching anything near it and write the count into the commit).
- **Three predicates, three jobs**: `isSessionLive` (projections, ceremonies, the poller),
  `hasCommittedPeer` (radio guards, the resume arm), `isInSession` (the layout swap). Never collapse.
- **`.inactive` is foreground; `ScenePhase` is not frozen**: `routedGateForeground(for:)` is the one
  place a phase is read.
- **Nothing may spin**: the coordinator's progress updates ride the poller's tick or a session event,
  never their own timer.
- **Wipe wall**: any new persisted surface or `UserDefaults` key owes a `Docs/PrivacyWipeCoverage.md`
  row and delete-all writer wiring in the same commit.
- **The routed walls, unchanged from P7's launcher §4**: the registry as the only per-type source; two
  admission doors; refusals through `refuseRoutedFrameBeforeStore` except the digest family; no epoch
  on the routed path; W2's pins move with the file; the three retirement zero-lists; schemas
  `MeshSessionContext` **3**, routed index **2**.
- **The CI selector wall**: every `MeshP<n>*AcceptanceTests` declared must be named in the mesh step
  and every named suite declared; the floor measured. Pin `>= 42` at the boundary (by declaration —
  item 0 re-measures it).
- **Determinism**: `ca898bcc…6930` (schedule) and `594b6f77…5765` (overlay) do not move; a move is a
  red, never a re-pin.
- **Localization**: display text is `LocalizedStringKey`, tokens frozen English; new keys listed for
  the close-out's sync from `HEAD`'s blob.
- **Power of 10**: ≤ 60 code lines per body, bounded loops, no `!`/`try!`/`as!`/`fatalError`, no
  swallowed `try?`, no mutable globals, no nested `#if`, warnings-as-errors.
- **Memory lifecycle** (ML4/ML5): a coordinator that holds a task and a manager is a host-holding
  type — do not add a detached unmarked `Task` in it; H-1a.3's old pattern is not the template.
- **DocC**: `///` on every type, `doc-coverage-scan.py` at zero, FileIndex / ProximityFunctionIndex /
  both landing pages in the same commit.
- **Do NOT touch** `App/Fernlet/Localizable.xcstrings`'s working copy, `xcuserdata/**`, or the stray
  PDF in `Docs/`.

---

## 5. Three items with a design call inside

### (a) Item 0 is a gauntlet, not a formality

P7 was written by reading code, not compiling it. Expect the first build to red on something
mechanical (the Release configuration's main-actor default isolation is the ledger's first suspect),
and expect one wall to be wrong in a way only a run shows. Each is a P7 fix commit with its own
ledger line; none is a reason to start P8 early. The item ends with §13's heading changed to BUILT
and the measured numbers in §13.4 — that edit is the acceptance criterion.

### (b) The verb is small and its blast radius is not

`stopSearching()` does five things; item 3's verb does two of them. The cell that proves it is on the
founding rig: two nodes committed, the verb on one, its committed slot still `admitted`, its
coordinator alive, `hasCommittedPeer` true, `isSearching` false, and a third node's introduction
refused at the door. Then the executor. Grep the readers of `isSearching` first — P6 found the heart
predicate's leg was not inert by counting readers, and this verb touches a predicate more things read.

### (c) The coordinator is a value; the task is its side effect

The temptation is a class that owns a `BGContinuedProcessingTask` and reacts. Build the state table
first as a pure value (item 4), so exactly-once completion is a row every path must satisfy, and let
item 6 be the thin object that calls `BGTaskScheduler` and feeds the store. The probe already has the
right completion idiom; what it lacks is the table that proves every path reaches it once.

---

## 6. Stop conditions — end the loop on any of these

1. **P8 is complete** — every item done, gauntlet green, §14 BUILT, §15's table filled, the next
   handoff written.
2. **Blocked on the owner** — after item 7, every remaining item needs devices in someone's hand. Say
   exactly what is needed and stop.
3. **Budget is running low.** Stop with items to spare.
4. **Context is filling.** When the ledger is the only thing a fresh session needs, stop.
5. **A gate goes red for a reason you did not cause.** Record it, stop, report.

### Gauntlet — the subagent runs it; you check the marker line

```bash
python3 Scripts/power-of-10-scan.py
python3 Scripts/doc-coverage-scan.py
xcodebuild build-for-testing -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test-without-building -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FernletTests
Scripts/spm-wall-check.sh
Scripts/spm-wall-selftest.sh
```

**The last MEASURED baseline is `4866 tests in 486 suites`, green, EXIT=0, one invocation
(P6 item 10, `64c47f2`).** P7 declared 65 new `@Test`s and amended five suites; item 0 measures the
new baseline and writes it here and in the ledger. Repository gates at P7's boundary:
`power-of-10-scan.py` → 509 files, 0 violations, density 0.778; `doc-coverage-scan.py` → 0.

Per-item subset: every suite the diff touches + the routed suites (`MeshRouted*`, `MeshP5*`, `MeshP6*`,
`MeshP7*`, `MeshP8*`) + the wall suites (`MeshRoutedLockedDeviceTests`, `MeshRoutedDrainTests`,
`MeshRoutedDrainWallTests`, `MeshRoutedRefusalBudgetTests`, `CryptographicPurposeBoundaryTests`,
`CIGateSelectorBoundaryTests`, `LocalizationBoundaryTests`, `PowerOfTenBoundaryTests`,
`ProximityRunSeamsTests`, `ProximitySessionPollerTests`, `SessionResumeCopyTests`) + the app-target
walls (`PersistedSurfaceWipeBoundaryTests`, `PrivacyWipeCoverageTests`, `DeleteAllDataTests`,
`NoTrackingBoundaryTests`, `MemoryLifecycleBoundaryTests`, `TransportNeutralityBoundaryTests`).
Regenerate the list from the `@Suite` declarations; add by hand the three suites with no `@Suite`
attribute; name the **struct**, never the file.

**Every new or amended wall is shown red once**: disable the guard, **REBUILD**, run, keep the log,
restore the exact text, re-grep, **REBUILD** again.

---

## 7. Ledger template

Create `Docs/Mesh-Migration-Loop-Ledger-P8.md` on iteration 1 if absent. Keep it short.

```markdown
# Mesh Migration Loop Ledger — P8

**Phase:** P8 (background continuation), preceded by the P7 gauntlet · **Prompt:** [Next-Round-Prompt-Mesh-P8-2026-09-18.md](Next-Round-Prompt-Mesh-P8-2026-09-18.md)
**Started:** 2026-__-__ · **Iteration:** 1 · **Tree at seed:** `claude/zen-goodall-wejlxg` = the P7 close-out commit, pushed, unmerged; P7 UNBUILT until item 0

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`. Tier per §2.
| # | Item | Tier | Prereq | State | SHA | Note |
|---|---|---|---|---|---|---|
| 0 | Build and run P7: the gauntlet, the red-onces, the floor and pin re-measured, the catalog sync, the UI suite, the full suite; §13 → BUILT | 1 + 1b | — | todo | | several iterations; every red = a P7 fix commit |
| 1 | P7 item 6 carried: gate the drain cells, measured | 1 | 0 | todo | | |
| 2 | P7 item 8 carried: tier 2 (backgrounding half; eligibility negative; ARM_AFTER rows) | 2 | 0 | todo | | timebox 2 |
| 3 | The stop-browsing-keep-links verb; the refused row executed; the token a zero-count wall | 1 | 0 | todo | | two passes |
| 4 | `MeshContinuationCoordinator` as a pure value + the state table; progress arithmetic | 1 | 0 | todo | | |
| 5 | The two raises (coordinator only) + the disagreement cell | 1 | 3, 4 | todo | | two passes |
| 6 | Task wiring: register, submit, expire, cancel, complete once; keeps the tunnel; feeds the store; anchor suppressed | 1 + 3 | 4, 5 | todo | | |
| 7 | Refusal / expiry presentation on the Friends card slot; privacy sentence | 1 + 1b | 4 | todo | | keys listed for sync |
| 8 | Tier 3 part one: the device plan A–E | 3 | 0 | todo | | first observation of any P7 behaviour |
| 9 | Tier 3 part two: §15.1–§15.4 → the runbook's Lane B table | 3 | 6, 8 | todo | | the degraded ladder is decided here |
| 10 | P8 acceptance battery + CI lines | 1 | 3–7 | todo | | pin and floor measured |
| 11 | Close-out: §14 BUILT, §15 filled, §26 handoff, next launcher, memory | 1 | 0–10 | todo | | draft → verify → apply |

## Blocked on owner
- Devices in hand from item 8 on; the runbook's Lane B rows are the evidence table.
- Carried from plan §25.4: the hardware lanes (A report, B double-dial, AWDL, D cable-out); option (b); D-7.30; §18.2 copy; the legacy unsigned removal; transcript `sid`; the census/duress questions; the final wording of P6's 19 and P7's 13 sentences; §17.3's privacy paragraph; `browsed peers=`; the `HeartDrop` CloudKit record type; `ConnectionInspectorTests`.
- P6 §12.3's open findings 4–13, 15–17, 19, 20; P7 §13.3's residuals 4–9, 13–14.

## Decisions taken (defaults from §3 unless the owner overrides)
| Decision | Choice | Taken on |
|---|---|---|
| The first iteration | (default: item 0 whole) | — |
| How the coordinator reaches the radios | (default: feeds the store; never a verb) | — |
| Who raises `.backgrounded` / `.foregrounded` | (default: the coordinator only) | — |
| The stop-browsing verb | (default: one new public verb; `stopJoin()` unchanged) | — |
| The progress unit | (default: elapsed toward the ceiling) | — |
| The poller under a task | (default: unchanged) | — |
| When the task is submitted | (default: first commit, `.fail`, concrete id) | — |
| What refusal / expiry presents | (default: the Friends card slot) | — |
| The degraded ladder | (decided by §15.3) | — |
| New persisted surface | (default: none) | — |

## Surprises worth not re-deriving
- (seed from §9 of this launcher's "Lessons carried from P7")

## Next item
0
```

**Lessons carried from P7 — seed the surprises list with these:**
- **A session without a toolchain can write but not prove.** P7's six items are UNBUILT; the first
  Mac session inherits a gauntlet. Do not spend iterations fetching a toolchain in a container that
  refuses it — say so and stop.
- **`stopJoin()` → `stopSearching()` tears the slots down.** There is no stop-browsing-keep-links
  verb; that absence is why the policy has `hold` and why one row is refused. Item 3 is that verb.
- **`.inactive` is foreground for the radios now**, not just the gate — a Control Centre pull over the
  Friends tab no longer stops the search. Device lock still traverses `.background`.
- **The three `FernletStore` stop sites were not all teardown** — two were the nearby-setting
  opt-outs, policy inputs now; only leg 7b was delete-all, and it is a hard stop now.
- **A helper whose body repeats a counted spelling makes a line-count wall read one too many** — the
  app helper is `pushProximityRunPolicy`, the store funnel `applyProximityRunPolicy`, on purpose.
- **Persisting effects on the founding rig need the pinned install binding**
  (`DeviceBindingID.$testOverride`) — the ceiling's termination mark is one; wrap the poll.
- **The mesh chat age gate is `AgeGate.chat` (13), reached only through `chatAllowedProvider`**; the
  policy's below-age fact is the final `.below` ruling or guardian limits, never "undetermined".
- **`FernletLockState` carries associated values**; the policy takes the projection `appLockEngaged`
  (true iff `.locked`).
- **Every lesson P6 carried still binds**: a log with `Restarting after unexpected exit` has no usable
  total; a red can be a starvation; never chain a build and a run on one DerivedData; `-only-testing:`
  names the suite; `@Test(arguments: [])` is green over nothing; a negative whose "before" text is
  empty cannot be reverted by a count-1 replace; "inert until P8" rots; measure a predicate's readers
  before changing it; a roster-wide invariant is not key-generic; a process-global audit signal cannot
  witness a per-cell claim; the first test invocation after a build hangs; zsh passes an unquoted
  `$ARGS` as one argument; `#expect(_, "literal")` only; bind `allSatisfy` first; never `==` on
  signed records; `MeshRoutedStorageScope.production` never as a test literal; a headless Simulator
  satisfies the foreground leg by accident; any harness bypass that skips a shipping door hides a
  product claim; long agent work can die at the usage-limit reset hour — resume.
- **Closed; do not re-audit:** `MeshTunnelConvergence`, the id-vs-endpoint family, the crypto-purpose
  / `PayloadType` / record-kind spellings, plan §10.7–§10.10, §11.1–§11.4, §12.1–§12.4 and — as a
  record, not as a build — §13.1–§13.4; `Docs/Proximity-Security-Followups-2026-08-18.md` §1.
- Concurrent sessions may share the tree; never stage the catalog working copy, `xcuserdata`, or the
  stray PDF.

---

## 8. Close-out, when P8 is done

1. Mark P8 **BUILT** in §14 with landing SHAs and §14.1–§14.4 in the §11–§13 format; fill §15's rows
   in the runbook's Lane B table with results and dates.
2. Record deviations and policy acts; every ledger "Blocked on owner" line ends resolved, taken, or
   written into §14.3 with its cost.
3. Memory note.
4. Write the **§26 P9/P10 handoff** and the next launcher from it, fact-checked against HEAD.
5. Draft → adversarial verify → apply from files.
6. Sync the string catalog from `HEAD`'s blob for every key P8 listed; check the count.
7. Note anything P8 learned that re-tiers P9/P10.

---

## 9. The road to TestFlight

| Session | Phase | Prerequisite |
|---|---|---|
| P2–P6 (done) | QUIC session, durable context, partition + merge, routed store, feature routing | built, proven sim↔sim; 4866 green at P6 |
| P7 (written) | app-layer run policy, the poller, the resume surface | **IMPLEMENTED, UNBUILT** — the gauntlet is this launcher's item 0 |
| **this** | **P8 — background continuation** | item 0 green; the verb; the coordinator; §15 on 2–4 devices; the degraded ladder decided by the soak |
| +1 | **P9/P10** — remaining radios, MC retirement (iOS 27), companion `BGAppRefreshTask` | P2 proven in the field |

**The tier-1 re-tier ended at P7.** P8's design is tier 1 (a state table, a verb, a policy row) and
its acceptance is tier 3. No amount of Simulator work moves a §15 row, and the first hardware sample
(a user-started task ended ≈ 46 s in) is the number the soak has to beat.
