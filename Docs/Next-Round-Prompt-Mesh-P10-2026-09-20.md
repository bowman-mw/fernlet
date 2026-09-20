# Loop Prompt — ProximityKit Network Migration: P10 (the companion `BGAppRefreshTask`), with P8's device gate and P9's MC cutover both still open

**Written:** 2026-09-20, at the P9 boundary (`main` = the P9 close-out; **P9 is BUILT at tier 1, 1b
and 2**, and two of its items ended blocked on the owner — the device gate and the MC→QUIC cutover).
**Plan:** [Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md](Plan-ProximityKit-Network-Migration-2026-08-27.md) — the authority.
**§17.2 is the P10 specification; §27 is the handoff; §17.1 is what P9 built; §15 is P8's unpaid gate.**
**Ledger:** `Docs/Mesh-Migration-Loop-Ledger-P10.md` — create it on iteration 1 (§7). The P9 ledger is
a finished record: read its "Blocked on owner" section and its surprises once, then do not reuse it.
**Design note carried in whole:** [Docs/Mesh-P9-Item4-Design-2026-09-20.md](Mesh-P9-Item4-Design-2026-09-20.md) —
the MC cutover's survey, decision and ready patches. Nothing in it is stale; it is waiting on a
person, not on code.
**Scope:** the companion background refresh — one identifier, one handler, one wall — plus the P9
residuals that are cheap on the same Mac. **Stop at the P10 boundary.** P10 is **not** gated by §15.

---

## How to start

```
/loop Read Docs/Next-Round-Prompt-Mesh-P10-2026-09-20.md and run one iteration of it.
```

Self-paced (no interval). A session that is not a `/loop` runs the same iterations back to back; the
ledger is the state either way. **This launcher assumes a Mac with Xcode 26 and at least one
Simulator.** Physical devices are needed only for item 0 and for the one row a Simulator cannot give
(§5a). **P9 built every commit and it cost nothing; keep doing that.**

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
reasoning, then a fix agent for what survives. **P8 ran seven adversarial verifies and P9 ran ten
(9.1, 9.2 ×2, 9.3 ×2, 9.4/9.5, 9.6/9.7, 9.8, 9.9, 9.10) — and every one of the seventeen found
something real.** P9's caught a QUIC session that refused *every* inbound dial behind 25 green
cells, a Bonjour wall that would have stayed green while friend-mesh discovery died, an anchor needle
that checked four hand-listed files, six baseline lines that could never fail, and a battery clause
that pinned source text while the shipping path could be flipped underneath it. If the owner declines
the dispatch, do the work in-session, keep the *shape*, and record the deviation in the ledger.

### Hard token rules for the orchestrator

1. **Never `cat` a source file.** `sed -n 'a,bp'` or a targeted `grep -n`; more than ~60 lines is a
   subagent's job.
2. **Never let build or test output reach context.**
   ```bash
   xcodebuild … > "$LOG" 2>&1; echo "EXIT=$?" >> "$LOG"
   grep -E "EXIT=|BUILD (SUCCEEDED|FAILED)|TEST EXECUTE|Test run with" "$LOG"
   ```
   A background build's notified exit code is the **last command's**, not the build's — grep the log.
   And `tail -f … | grep -m1` hangs to the timeout: foreground the short builds.
3. **One work item per iteration.** Each fix commit is its own.
4. **Write state to the ledger, not to your own memory.**
5. **Stop early rather than run out.** See §6.
6. **A close-out step that synthesises many facts runs as draft → adversarial verify → apply from
   scratch files.** (P9's close-out did, and the verify is what re-grepped every anchor.)
7. **A row that lands in two passes needs its gate to assert the later pass RAN.**
8. **One `xcodebuild` at a time on the shared DerivedData** — it is a CPU rule as much as a
   DerivedData rule; `pgrep -x xcodebuild` gates every start. A second implement agent may draft
   anchored patches in scratch but applies nothing until a marker exists and re-reads every patched
   file first, because `main` moves. **Run a scratch-drafting agent in the BACKGROUND** — two
   foreground agents cannot hand each other the build slot (P9 lost 100 minutes to that).
9. **Commit by explicit pathspec, never `git add -A`.** Never stage
   `App/Fernlet/Localizable.xcstrings`'s working copy, `xcuserdata/**`, or the stray PDF in `Docs/`.
   The primary holds the plan and several `Docs/*.md` uncommitted: **plan edits land as index-only
   blobs** (the P9 close-out's `CHECKLIST.md` recipe).

### If the budget runs out mid-phase

Stop the loop, write the handoff (§6/§8), and say plainly what is left.

---

## 1. Each iteration, in order

1. **Read the ledger.** `Docs/Mesh-Migration-Loop-Ledger-P10.md`. On iteration 1, create it from §7.
2. **Check the tree is safe to build on** (`git -C . log --oneline -1; git -C . status --porcelain`).
   Catalog keys are synced from `HEAD`'s blob (`Scripts/sync-string-catalogs.sh`), never from a held
   working copy, and **never in the worktree you are testing in** — the sync poisons its DerivedData.
3. **Pick the next item** whose prerequisites are met, from §3, in ledger order.
4. **Dispatch the three agents** with the item's full context: the acceptance criterion, the walls
   (§4), the ledger's decisions, and the gauntlet subset for what it touched (§6).
5. **Verify** — grep the marker line yourself. Check the exit code and `Test run with N tests in M
   suites`, count `◇ Suite` starts against `✔ Suite` passes, and grep for `Restarting after
   unexpected exit, crash, or test timeout` before believing any total. (`run-gated-suites.sh` now
   refuses a restarted run itself, and `--check-log <file>` checks a log you already have.)
6. **Commit** with explicit pathspecs.
7. **Update the ledger**: item → done with the SHA, one line on anything surprising, the next item.
8. **Schedule the next wake**, or stop per §6.

---

## 2. Testing strategy (re-tiered at the P9 boundary, §27.2)

| Tier | What it proves | Cost |
|---|---|---|
| **1 — no task, no radio** | **P10's design, and nearly all of its acceptance.** The handler as a pipeline over values: the day roll, the recompute, the snapshot **diff**, the publish, the exactly-once completion table (P8's oracle shape), the scheduling seam's submission/registration contract against a fake, and the import wall. **If a check CAN live here, it MUST.** | Free, deterministic, CI. |
| **1b — the app's UI/widget surface** | The snapshot reaching the app-group container and the timeline reload, serially, environment pinned (iPhone 17, portrait). | Minutes, same Mac. |
| **2 — Simulator** | **Thin, and possibly empty.** One question is worth an hour: can a Simulator launch a registered `BGAppRefreshTask` at all (the continued-processing path refuses with `BGTaskSchedulerErrorDomain` 1 — **do not assume the refresh path matches it**)? Record the answer in the runbook whichever way it falls. The mesh lanes are P9's and need no re-run. | One Mac, `simctl`. |
| **3 — physical devices** | **Two unpaid bills.** §15.1–§15.4 and the device plan's A–F (P8's acceptance, still NOT RUN), plus P10's own row: a refresh **granted and launched** by iOS on a phone, which nothing at tier 1 or 2 has ever seen. It blocks *shipping*, not P10. | Owner's devices and hours. |

Lane gotchas carried from P2–P9 — all paid for: `STAGGER=1`; re-harvest identities after any
`xcodebuild test`; a fresh log directory per run; `pgrep -x xcodebuild` before believing a failure;
warm the first `test-without-building` after a build with a tiny suite; verify the `[mesh-matrix] run
label=` banner because `--console-pty` intermittently attaches no stdout; never chain a build and a
test run on one DerivedData; a Simulator that has run ~3 h stops rendering — erase and reboot before
believing a UI red; the audit stream is `xcrun simctl spawn <udid> log stream --level info
--predicate 'subsystem == "com.fernlet"'`. **New from P9:** **rebuild the app before any lane run**
(a "warm" binary was stamped a minute before the commit it was meant to contain), and **kill audit
streams by saved PID** — `pkill -f "log stream"` killed a concurrent session's stream.

---

## 3. The work list

Ledger order. *Every file:line anchor below was re-grepped at the P9 close-out, at `a5f8bcf`;
the 9.9 fix commit landed after that and touched the workflow, `CIGateSelectorBoundaryTests`,
`MeshP9AcceptanceTests` and two ProximityKit files — **re-check before editing**.*

| # | Item | Tier | Prereq |
|---|---|---|---|
| 0 | **The device gate, unchanged and now two phases old.** §15.1–§15.4 and the device plan's A–F on two to four phones; the two owed re-runs (P8 item 0's four founding fixes with the three eyeballs — Control Centre over the Friends tab and delete-all during a live session are still unobserved); the tier-3 rows P8 item 6 named (registration accepted, a `.fail` submission **granted**, the launch/expiration handlers on the real `SystemContinuationScheduler` conformer, the tunnel surviving the task, slow progress across the 3 h / 6 h soaks, no proximity Live Activity present, the Control-Centre peek re-submission F12). **§15.3 decides the degraded ladder.** Plus the two P9 device rows: the **boundary-wake drift** (P9-2-C: Simulators drifted +51 s on a 767 s arm) and **Lane D** (phone ↔ Simulator, cable out — device row F11, still the cheapest first run, still unrun). **If there are no devices, mark it `blocked (owner)` and go to item 1** — P10 is not gated by it. | 3 | — |
| 1 | **`FernletStoreAccess` out of `ExchangeIntentService.swift`, and the dead `install(store:)` deleted.** `FernletStoreAccess` is declared at `App/Fernlet/ExchangeIntentService.swift:18` (`shared` `:19`, `install(_:)` `:24`) and is already one process-global cache shared by UI and App Intents — the move into a small lifecycle service is **hygiene that lets the refresh handler share it**, not a bug fix (§17.2's one correction to v1). `ExchangeIntentService.install(store:)` (`:82`) is **callerless at HEAD** — verified: the only `install(store:` call sites in the tree are `RecipeShareLaneHarness`'s, from `App/Fernlet/FernletApp.swift:473`. `MemoryLifecycleBoundaryTests:105` carries its invariant text and must move with it. | 1 | — |
| 2 | **The background-refresh import wall (§16.4), in the first commit that adds any refresh code.** P10 may not import mesh / AI / HealthKit / CloudKit implementation modules. `Tests/FernletTests/MessagesExtensionBoundaryTests.swift` and `S3BoundaryTests` are the shape to copy; the wall must name the refresh handler's file(s) and be **red once** with a planted import. This is option C's rejection one layer out: a refresh handler that can reach the mesh is a second owner of the radios. | 1 | — |
| 3 | **The identifier, the plist and the scheduling seam.** `MBO.Fernlet.companion-refresh` joins `BGTaskSchedulerPermittedIdentifiers` (`App/Fernlet/Info.plist:28–31`, today **only** `MBO.Fernlet.mesh-continuation.*`) and the `fetch` background mode joins `UIBackgroundModes` (`:79–82`, today **only** `remote-notification` — there is no `fetch` mode in the tree). Copy `App/Fernlet/MeshContinuationScheduling.swift`'s protocol + production-conformer shape (`:185` onward; `register(forTaskWithIdentifier:)` at `:210`) — **do not widen the mesh's seam to carry a second task**. Schedule at handle + background, never on a timer. | 1 | 2 |
| 4 | **The handler as a pipeline over values, with the diff rule and exactly-once completion.** §17.2's chain: acquire the existing store safely → roll day → recompute the deterministic companion → **diff** the snapshot → publish via WidgetBridge → reload timelines **only on change** → complete once. Never: mesh, HealthKit, CloudKit force-sync, Foundation Models, or store creation while protected data is unavailable. **The diff is new behaviour and it has a trap** — `WidgetSnapshotMirror.publish` (`App/Fernlet/WidgetBridge.swift:382`) reloads on every successful write, and `WidgetSnapshot` is `Equatable` **including `computedAt: Date`** (`App/FernletWidgets/WidgetSharedModels.swift:77`, `:94`), so `old != new` is always true. Diff the meaningful fields. The publish path today is `FernletStore.publishWidgetSnapshot()` (`App/Fernlet/FernletStore.swift:6055`), wired at `activateWidgetBridge()` (`:5957`) and called from the save after-hook (`:5949`); `todayKey` is `diary.todayKey` (`:235`). Exactly-once completion is P8's table, not a flag. | 1 | 3 |
| 5 | **The P9 residuals that are cheap on this Mac.** (a) the **11 sibling suites, 83 cells**, in the files P9 item 6 gated — `MeshRoutedManifestGoldenTests` 16, `MeshRoutedTypeRegistryConsumerTests` 10, `MeshRoutedCustodyHandoffWallTests` 9, `MeshRoutedItemSealGoldenTests` 9 and seven smaller, named in `.github/workflows/s3-wall.yml`'s mesh-batteries comment — **plus whichever of the seven P9-touched suites the 9.9 fix left NAMED AS AN HONESTY ROW rather than gated**: `ProximityRecipeShareCapTests` (31 cells — the recipe radio's own two-device cap and pause/resume lifecycle, rewritten by `ba34491`, edited again by `b63aeaf`, and on no CI line at all when P9 ended), `NetworkMeshTransportTests` (119), `MeshTransportSelectionTests` (the only place `shippingDefault` and `resolvedKind` are asserted as VALUES), `PresenceHeartsTests`, `PresenceTagTests`, `PeerTransportNeutralityTests`, `ProximityRecipeShareDiagnosticsTests`. **Read `MeshP9HonestyAcceptanceTests` and the mesh step's comment first — they say which are still ungated.** Gating cost is **not** proportional to cell count (+92 % cells cost +10 % wall time), so price it, then gate and **measure** the floor. (b) the **five process-wide `>= 1` counts** left named by P9 item 7 — `routedQuiescent`, `blockedOrigin`, `originUnresolvable`, `originRemoved`, and `keyAgreement.rejected` at the restore path: either give the tokens the `held` key through the existing production door `MeshNetworkManager.heldMeshAuditContext(_:)` or state why each stays process-wide (`droppedUncommittedSlot` refuses **before** the mesh guard, by design — leave it) — and beside them the **~43 unscoped `.count(of:)` reads** across `Tests/FernletTests` (44 by `grep -rn '\.count(of:' Tests/FernletTests \| grep -v 'where:'` at the P9 close-out), several `== N` on a process-global capture: the same defect, one file at a time. (c) the **live restart branch** of `Scripts/run-gated-suites.sh` (`RESTART_MARKER` `:41`, `--check-log` `:45`) is proved only at its seam. (d) **item 8's residuals** — the accessibility ratchet runs on **no CI line** (no workflow names `FernletUITests` or `AuditRatchetBoundaryTests`); `UXScreenProbe.absentFromScreen(_:)`, the new enforcement that stops an under-reported category excusing a frozen line, is validated on **3 of 14 screens** (59 excusable entries remain on the other 11, and the first full `ScreenAppearanceUITests` run after `a5f8bcf` is where that claim is tested); the device guard's **locale leg has no red-once**; and `Home · Recent bites` is still viewport-unstable by construction (scrolling pins the edge, not the contents, and the demo seed is wall-clock-dated). | 1 | — |
| 6 | **9.4-LATER — the MC→QUIC cutover of the friend mesh. OWNER'S DECISION FIRST.** `MeshTransportFactory.shippingDefault` is `.multipeer` (`FernletKit/Sources/ProximityKit/Transport/MeshTransportSelection.swift:267`; the one construction site is `:297`), so the deletion is a cutover and **QUIC has no first-meeting stranger admission** (plan **§8.7 finding 3** — the P9 ledger's item 4 row and `df37afb`'s commit message mis-cite it as "§11 finding 3"; the ledger's row is corrected at the P9 close-out, the commit message cannot be). D-4.1 hold (recommended) / D-4.3 cut over. If the owner says cut over: the ready patches are the item-4 design note's appendices (`Info.plist`, `MeshNetworkManager.swift`, `MeshTransportSelection.swift`, `TransportNeutralityBoundaryTests.swift`, all marked `[SPLIT: LATER]`, anchored by text), plus D-4.4 (the `MCPeerIDStore` wipe row becomes a legacy `FileManager` sweep — `FernletPeerID.archive` survives on any pre-P9 install), `permittedFiles` emptied in the same commit (`Tests/FernletTests/TransportNeutralityBoundaryTests.swift:32`; the suite asserts each permitted path **exists** at `:105`), the **32 test files** that name MC, `_fernlet-friend._{tcp,udp}` moved from `liveBonjourServiceTypes` to `retiredBonjourServiceTypes` in `NoTrackingBoundaryTests` (`:979` / `:990` / `:1002`), and the rule-7 cell `MeshP9McRetirementAcceptanceTests`, which **pins the current truth on purpose** — after the 9.9 fix it asserts `shippingDefault` **and** `resolvedKind(environment:)` as VALUES, not as source text, so the cutover commit must edit it or it reddens. Also classify the two `_fernlet-friend` strings in the same commit: **every declared Bonjour type must be live, held or retired**, and an unclassified one is a red. | 1 | owner |
| 7 | **P9-3-A — a configured Fernlet Lock parks the recipe-share and presence radios permanently. OWNER'S PRODUCT CALL.** `ProximityRunPolicy.presenceState` (`App/Fernlet/ProximityRunPolicy.swift:475`) and `recipeShareState` (`:486`) both `guard … !input.appLockEngaged else { return .stop }`, and `.locked` is the **resting** state of a configured lock; every `.unlocked(scope:)` is a private surface where both stop anyway. Nothing tells the user why. **Default: leave the policy alone and surface the reason** — a policy-row change is a P7 bug fix that re-runs the 23 040-row product. | 1 / 1b | owner |
| 8 | **What a Simulator can show of a refresh (tier 2 / 1b), timeboxed to 90 minutes.** Does a registered `BGAppRefreshTask` submit and launch on a Simulator? Record the verdict and the exact error in the runbook under a new "Lane E — the companion refresh" section, whichever way it falls, and carry the unreachable rows into the ledger **by name** rather than as a gap (P8 item 2's shape). | 2 / 1b | 3, 4 |
| 9 | **The P10 acceptance battery + CI gate lines, one commit.** One serialized suite per clause (the scheduling seam; the handler pipeline; the diff rule; the import wall; an honesty suite naming what only a device can show). **Name them `MeshP10<Clause>AcceptanceTests`** — `CIGateSelectorBoundaryTests.isMeshBattery` (`:27`) matches only `MeshP<digit>…AcceptanceTests` (plus three named convergence suites), so any other name is demanded by nothing (its own cell pins `MeshP12FooAcceptanceTests` true and `MeshPhotoAcceptanceTests` false); the alternative is widening the predicate in the same commit, deliberately. The battery pin (`batteries.count >= N`, `:196` at the P9 close-out) and the floor are **measured** at the commit that moves them — never arithmetic. **Read `measuredSuiteNameCounts` (`:61`) the right way round:** it asserts `step.suites.count >= (measured ?? 1)`, so it catches a name **LEAVING** a step's line (96 against a pin of 97 reds in 0.14 s with no Simulator) and **adding one passes silently** — raise the entry in the same commit that adds names, or the pin quietly permits a later removal. The red that does fire for a new battery is `everyMeshAcceptanceBatteryIsGated`. Neither determinism digest may move. | 1 | 1–5 |
| 10 | **Close-out** (§8): §17.2 marked BUILT with its own What landed / Deviations / Findings / Acceptance evidence in §13/§14/§17.1's format, §15's table updated with whatever item 0 produced, the P11-or-TestFlight handoff, the next launcher, the memory note. | 1 | 0–9 |

### Not this phase

- **Relay increment 2** — still gated on the tier-2 measurement §11 names, still unearned.
- **Re-deciding the run policy.** Its 23 040-row table is P7's. A P10 that rewrites a policy row has
  found a P7/P8 bug — fix it as such, re-run the whole product, say so. (Item 7 is a *decision*, not
  a rewrite.)
- **A second owner for any radio.** Every radio verb's one home is
  `FernletStore.executeProximityRunActions` (`App/Fernlet/ProximityRunSeams.swift:276`).
- **Re-running P9's mesh lanes.** 9.2.2 and 9.3.2 are crossed and dated; the P9 residual lane rows
  (the `.remove` → republish branch, `openTransferCount` back to 0, a share in flight during a glare
  collapse) belong to **Lane D**, which is item 0's.
- **Option (b) for `handleEncryptedMetadata`, D-7.30, §18.2's copy, the legacy unsigned removal,
  transcript `sid`, the census/duress questions** — owner's, unchanged (§26.4 / §27.4).

### The decisions, with defaults so nothing blocks

| Decision | Default | Why |
|---|---|---|
| **The first iteration** | **Item 0 if devices are in hand; otherwise item 1, with item 0 `blocked (owner)`.** | Two phases of unpaid gate. It blocks shipping, not P10. |
| **Whether P10 may touch the mesh** | **No, and the wall lands in the first refresh commit.** | A refresh handler that can reach the mesh is a second owner of the radios. |
| **The scheduling seam** | **Its own protocol + production conformer**, copied from `MeshContinuationScheduling`, never a widened mesh seam. | Two tasks through one seam is how a fake stops modelling either. |
| **"Reload only on change"** | **Diff the meaningful fields**, never the whole `Equatable` value. | `computedAt` makes every snapshot unequal; the clause would silently become "always reload". |
| **P10's battery names** | **`MeshP10<Clause>AcceptanceTests`**, gated on the mesh step in the declaring commit. | Only that shape is demanded by the selector wall. |
| **9.4-LATER** | **Hold (D-4.1)** until the owner decides. | Stranger admission has no QUIC path; a cutover ships broken first-meeting founding. |
| **P9-3-A** | **Surface the reason; do not change a policy row.** | A row change re-runs P7's whole product. |
| **New persisted surface** | **None.** A "last refreshed at" key owes a `Docs/PrivacyWipeCoverage.md` row and delete-all writer wiring **in the same commit**. | P6–P9 added none between them. |
| **The degraded ladder** | **Still decided by §15.3 in item 0**; until then unchosen and P8's scope unchanged. | Only a soak picks a rung. |

---

## 4. Walls that will bite

- **The Bonjour partition** (`NoTrackingBoundaryTests`): every declared type in `App/Fernlet/Info.plist`
  must be classified **live** (`:990`), **held** (`:1002`) or **retired** (`:979`) — an unclassified
  type is a red, and a new one owes a `Docs/No-Tracking-Wall.md` §4c row in the same commit. Today:
  live = `_fernlet-friend._{tcp,udp}` (the shipping MC mesh) + the three QUIC types
  (`_fernlet-mesh2._udp`, `_fernlet-near2._udp`, `_fernlet-recipe2._udp`); held =
  `_fernlet-coach._{tcp,udp}`; retired = the four P9 removed.
- **The CI selector wall** (`CIGateSelectorBoundaryTests`): every `MeshP<n>*AcceptanceTests` declared
  must be named on the mesh step and every named suite declared; **every step now also pins its
  suite-NAME count** (`measuredSuiteNameCounts`, `:61`, parsed from the workflow — a step with no
  entry fails, and 96 names against a pin of 97 reds in 0.14 s with no Simulator). The pin is `>=`:
  **removing a name reds, adding one passes**, so raise the entry in the commit that adds names. The
  floor is **measured**, never inferred. Today **`118` suites at floor `1048`**,
  battery pin **`53`**. **Determinism**: `ca898bcc…6930` and `594b6f77…5765` do not move.
- **A grep wall sees only whole-line comments.** `MeshRoutedSourceScan.codeOnly`
  (`Tests/FernletTests/MeshRoutedStoreIsolationTests.swift:35`) drops lines whose first
  non-whitespace is `//` and nothing else — a **trailing** comment or a string literal satisfies
  every positive needle and false-reds a negative one. Needle against code that must exist.
- **The gate script refuses a restarted run** (`Scripts/run-gated-suites.sh:41`): a log carrying
  `Restarting after unexpected exit, crash, or test timeout` has no usable total. `--check-log` (`:45`)
  checks a log you already have.
- **Transport neutrality** (`TransportNeutralityBoundaryTests`): framework prefixes matched as whole
  identifiers; `permittedFiles` (`:32`) must **exist** (`:105`), so emptying it and deleting the files
  is one commit. Its scan roots are `FernletKit/Sources/ProximityKit` + `App/Fernlet` — **it has never
  seen `Tests/`**, where 32 files name MC.
- **The two continuation doors stay off the radio-verb retirement wall's needle list**, with the
  reason written into that wall: `beginBackgroundContinuation()` / `endBackgroundContinuation()` are
  session-state raises, not radio verbs. **The raise wall** (`MeshContinuationRaiseWallTests`):
  `.backgrounded` / `.foregrounded` exactly once each under `FernletKit/Sources`, inside those doors;
  the doors once each under `App/`; `applySessionEvent(` **zero** under `App/`.
- **The anchor retirement wall** (`MeshContinuationTaskHostWallTests`,
  `Tests/FernletTests/MeshContinuationTaskHostTests.swift:515`, cell at `:689`): no
  `ActivityKitProximityForegroundAnchor` and no `Activity.request` anywhere under
  `FernletKit/Sources/ProximityKit` (walk floor 120 files, 143 measured), and the surviving
  `Activity<ProximityConnectionActivityAttributes>.activities` read must stay **inside** the orphan
  reaper's brace-matched body. `App/Fernlet/LiveActivityStarter.swift` legitimately calls
  `Activity.request` — that is why the walk is module-scoped.
- **One gate writer** (W8, `MeshRoutedLockedDeviceTests`): `applyRoutedAccessGate(` once under `App/`,
  inside `FernletStore.runProximityPolicy`. **`storeEdges == 6`.**
- **One radio-speaking file**: `FernletStore.executeProximityRunActions`
  (`App/Fernlet/ProximityRunSeams.swift:276`); `MeshRejectionMatrixHarness` is exempted **by name**
  in `ProximityRunSeamsTests` (`:353`, `:428`). P9's `RecipeShareLaneHarness` is **not** on that list
  and must not be added to it — it needs no exemption, because it speaks no radio verb at all (it
  moves the store facts the run policy reads, and release compiles it out). **One timer**
  (`ProximitySessionPollerTests`). No second clock.
- **The zero-count token**: `proximityRunPolicy.unsupportedTransition` is emitted by nothing and held
  at zero under `App/`.
- **Three predicates, three jobs**: `isSessionLive`, `hasCommittedPeer`, `isInSession`. Never
  collapse. `hasSlot(for:)` means **any** slot.
- **The routed walls, unchanged**: the registry as the only per-type source; two admission doors;
  refusals through `refuseRoutedFrameBeforeStore` except the digest family; no epoch on the routed
  path; the three retirement zero-lists; schemas `MeshSessionContext` **3**, routed index **2**.
- **Memory lifecycle (ML4/ML5)**: a type holding a task and a manager holds the manager **weakly** and
  adds no detached unmarked `Task`. **`MemoryLifecycleBoundaryTests` is a tree-wide grep wall the
  compiler cannot see** — run it for every new manager-shaped test file, and remember item 1 moves its
  `FernletStoreAccess` invariant text (`:105`).
- **Wipe wall**: any new persisted surface or `UserDefaults` key owes a `Docs/PrivacyWipeCoverage.md`
  row and delete-all writer wiring in the same commit.
- **Localization**: display text is `LocalizedStringKey` (or `LocalizedStringResource` where an API
  needs a `String`); tokens frozen English; a `String` parameter silently opts the call site out.
  **P9 added zero display keys**; if P10 adds any, list them for the close-out's sync from `HEAD`'s
  blob, and run the sync in a **clean** worktree (it poisons the test DerivedData) that is **not**
  under `/tmp` (the scanners strip `RepoRoot.url.path` and every allowlist row misses).
- **Power of 10**: ≤ 60 code lines per body, bounded loops, no `!`/`try!`/`as!`/`fatalError`, no
  swallowed `try?`, no mutable globals, no nested `#if`, warnings-as-errors. Note the assertion-density
  floor (0.68) drifted to 0.770 when P9 removed 27 `assertionFailure`s — another sweep of that shape
  moves it further.
- **DocC**: `///` on every type, `Scripts/doc-coverage-scan.py` at zero, FileIndex /
  ProximityFunctionIndex / the landing pages in the same commit.
- **Do NOT touch** `App/Fernlet/Localizable.xcstrings`'s working copy, `xcuserdata/**`, or the stray
  PDF in `Docs/`.

---

## 5. Three items with a design call inside

### (a) The grant is the row no Mac can give

P8 never observed a `.fail` submission **granted** anywhere, because a Simulator refuses
continued-processing submissions with `BGTaskSchedulerErrorDomain` 1. P10 inherits the same shape one
API over: the handler is provable in one process, and *iOS deciding to run it* is not provable
without a phone. **Do not assume the refresh path behaves like the continued-processing path** —
measure it (item 8) and write the verdict down. Then build every tier-1 check as if the device row
will never come, because it may not come this phase either.

### (b) "Reload only on change" is a sentence with a trap inside it

The clause reads like a one-line `if`. It is not: the mirror reloads on every successful write, and
the value's `Equatable` conformance includes a `Date` stamped at construction. A literal reading ships
"always reload" with a test that passes. Decide the comparison explicitly — which fields *are* the
companion's visible state — pin it as a table, and make one cell assert that two snapshots differing
only in `computedAt` do **not** reload.

### (c) A wall is what makes "never touches the mesh" true

§17.2's prohibitions (mesh, HealthKit, CloudKit force-sync, Foundation Models, store creation under
unavailable protected data) are prose until something fails on them. The import wall is the half that
can be mechanical; the rest wants a zero-list of call spellings in the handler's file, shown red once
with each planted. Land the wall in the **first** commit that adds refresh code, not the last — P9's
item 4 is the standing proof that a wall arriving after the code is a wall arguing with a fait
accompli.

---

## 6. Stop conditions — end the loop on any of these

1. **P10 is complete** — every unblocked item done, gauntlet green, §17.2 BUILT, the handoff written.
2. **Blocked on the owner** — items 0, 6 and 7 are the owner's; if only they remain, say what is
   needed and stop.
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
Scripts/sync-string-catalogs.sh --check
```

**`Scripts/spm-wall-check.sh` leaves no `FernletTests.xctest` in DerivedData** (it rebuilds under the
enforcement flag) — run it **last**, and expect a `build-for-testing` before the next test run.

**Repository gates at the P10 entry** (all measured at the P9 close-out): both scans at **0**;
mesh-batteries **`1048` over `118` suites**; `CIGateSelectorBoundaryTests`
battery pin **`53`**; the P9 gate subset was **1 275 / 119** at `85b7c4b`, then
**1 233 / 122** at `4dbd8d3`, then **`1 577 / 164`** at `4f52e0a` (three different lists — none is
a full suite, and none is comparable to another); determinism digests
unmoved. **The last MEASURED full-suite baseline is still P8's close-out: `5 055 tests in 513 suites`,
910 s, EXIT=0** (iPhone 17, 2026-09-19 00:07, bundle at `c86e3a0`) — **P9 ran no full suite at all**,
by the owner's standing instruction since P8 item 0, so every P9 number is a gated subset. Never take
a total from a log carrying `Restarting after unexpected exit, crash, or test timeout`.

Per-item subset: every suite the diff touches + the routed and phase suites (`MeshRouted*`, `MeshP5*`,
`MeshP6*`, `MeshP7*`, `MeshP8*`, `MeshP9*`, `MeshContinuation*`) + the wall suites
(`MeshRoutedLockedDeviceTests`, `MeshRoutedDrainTests`, `MeshRoutedDrainWallTests`,
`MeshRoutedRefusalBudgetTests`, `CryptographicPurposeBoundaryTests`, `CIGateSelectorBoundaryTests`,
`LocalizationBoundaryTests`, `PowerOfTenBoundaryTests`, `ProximityRunSeamsTests`,
`ProximitySessionPollerTests`, `SessionResumeCopyTests`, `MeshContinuationRaiseWallTests`,
`MeshContinuationTaskHostWallTests`, `TransportNeutralityBoundaryTests`) + the app-target walls
(`PersistedSurfaceWipeBoundaryTests`, `PrivacyWipeCoverageTests`, `DeleteAllDataTests`,
`NoTrackingBoundaryTests`, `MemoryLifecycleBoundaryTests`, `PrivacyPolicyParityTests`). Regenerate
from the `@Suite` declarations, then **add by hand the suites that carry none** — a grep for `@Suite`
under-counts both ways (`MeshRoutedItemSealTests` and `MeshRoutedStoreIsolationTests` are plain
structs). **Name the struct, never the file**: `-only-testing:FernletTests/<FileName>` matches nothing
and reports nothing, and **zsh does not word-split an unquoted `$ARGS`** — build argv as an array, and
always read `Test run with N tests in M suites`.

**Every new or amended wall is shown red once**: disable the guard, **REBUILD**, run, keep the log,
restore the exact text, re-grep, **REBUILD** again. A rename red-once can be satisfied by the rename
itself — a pass-2 cell's needles must be independently reddenable.

---

## 7. Ledger template

Create `Docs/Mesh-Migration-Loop-Ledger-P10.md` on iteration 1 if absent. Keep it short.

```markdown
# Mesh Migration Loop Ledger — P10

**Phase:** P10 (the companion `BGAppRefreshTask`), with P8's device gate and P9's MC cutover open · **Prompt:** [Next-Round-Prompt-Mesh-P10-2026-09-20.md](Next-Round-Prompt-Mesh-P10-2026-09-20.md)
**Started:** 2026-__-__ · **Iteration:** 1 · **Tree at seed:** `main` = the P9 close-out; P9 BUILT at tier 1/1b/2, §15 NOT RUN, 9.4-LATER blocked

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`. Tier per §2.
| # | Item | Tier | Prereq | State | SHA | Note |
|---|---|---|---|---|---|---|
| 0 | The device gate (§15.1–§15.4, device plan A–F) + the two owed re-runs + P9's two device rows | 3 | — | todo | | blocked (owner) if no devices — P10 is NOT gated by it |
| 1 | `FernletStoreAccess` move + the dead `install(store:)` | 1 | — | todo | | hygiene; prereq for the handler |
| 2 | The background-refresh import wall (§16.4) | 1 | — | todo | | first refresh commit, red once |
| 3 | Identifier + plist (`fetch`) + the scheduling seam | 1 | 2 | todo | | copy MeshContinuationScheduling's shape |
| 4 | The handler pipeline + the diff rule + exactly-once | 1 | 3 | todo | | `computedAt` makes every snapshot unequal |
| 5 | P9 residuals: 83 ungated cells + the P9-touched suites left as honesty rows, five unscoped counts + ~43 unscoped `.count(of:)` reads, the restart branch, item 8's residuals | 1 | — | todo | | measure the floor at the commit; `ProximityRecipeShareCapTests` is the one to check first |
| 6 | 9.4-LATER — the MC→QUIC cutover | 1 | owner | todo | | blocked (owner): D-4.1 hold / D-4.3 cut over |
| 7 | P9-3-A — the lock parks the 1:1 radios | 1 / 1b | owner | todo | | product call; default = surface the reason |
| 8 | What a Simulator can show of a refresh | 2 / 1b | 3, 4 | todo | | timeboxed 90 min; record the verdict either way |
| 9 | P10 acceptance battery + CI lines | 1 | 1–5 | todo | | `MeshP10*AcceptanceTests`; pin, floor and name-count measured |
| 10 | Close-out: §17.2 BUILT, §15 updated, the handoff, the next launcher, memory | 1 | 0–9 | todo | | draft → verify → apply |

## Blocked on owner
- Devices for item 0 (two minimum, three for partitions, four for the topology row); Lane D is the cheapest first run.
- D-4.1 / D-4.3 (item 6) and D-4.4; P9-3-A (item 7).
- Carried from plan §26.4 / §27.4 (read them; do not re-list here).

## Decisions taken (defaults from §3 unless the owner overrides)
| Decision | Choice | Taken on |
|---|---|---|
| The first iteration | (default: item 0 if devices, else item 1) | — |
| Whether P10 may touch the mesh | (default: no, and the wall lands first) | — |
| The scheduling seam | (default: its own protocol + conformer) | — |
| "Reload only on change" | (default: diff the meaningful fields) | — |
| P10's battery names | (default: `MeshP10<Clause>AcceptanceTests`) | — |
| 9.4-LATER | (default: hold) | — |
| P9-3-A | (default: surface the reason, no policy-row change) | — |
| New persisted surface | (default: none) | — |

## Surprises worth not re-deriving
- (seed from the lesson list at the end of §7, below this template)

## Next item
0
```

**Lessons carried from P9 — seed the surprises list with these:**
- **Grep `shippingDefault` (or the equivalent) before believing any "retire X" row.** Three documents
  described P9's item 4 as a deletion; it is a cutover that removes a shipping capability.
- **A fake that does not model the real session's ORDERING hides a total outage.** 25 green cells sat
  over a radio that refused every inbound dial. A lane row is the only cell that cannot lie.
- **A retirement cell that pins what must be ABSENT is half a wall** — pin the live set as hard as
  the dead one.
- **Before deleting a type, list every reader, not every writer** — the doomed conformer and the
  orphan reaper shared one attributes type.
- **An audit line with no context key cannot be scoped by a test**; the fix is production, and it
  must **extend** the existing call (a `log(`-count wall may stand beside it).
- **Scoping two counts in a file that holds twenty is a map of the other eighteen.** Sweep the file
  for the token family, not the launcher's list.
- **Price a name pin before believing "gated"** — a floor protects a line's total, not its membership.
- **A floor written in a draft is stale the moment another item lands a cell in a gated suite.**
- **Check a new suite's name against the selector's predicate before writing it.**
- **A field that only TRANSITIONS write is born wrong whenever the level was already set** — seed it
  from the level, and mint the cell **under** that level.
- **`??` is a nil-coalesce, not an empty-coalesce.**
- **A long single `Task.sleep` to a wall-clock deadline wakes late in proportion to its length**
  (+0.8 s at 300 s, **+51 s** at 767 s) — await in bounded steps and re-read the clock.
- **A transport-error door that was start-failure-only under one framework becomes any-error under
  another** — classify every `report`: start failure, per-operation refusal, cancellation.
- **A rotation test can only see fields that CHANGE** — pin what must match as hard as what must differ.
- **A lane finding can be pre-existing and still a blocker** — record the class on every one.
- **A cell can pin SOURCE TEXT and still not pin the shipping path.** The P9 battery's MC clause read
  `shippingDefault`'s literal and stayed green against a one-line change to
  `resolvedKind(environment:)`. Assert the VALUE wherever `@testable` reaches it.
- **A needle that filters before it walks is its own blacklist** — the P9 audit-line cell filtered the
  records down to those already carrying the peer label, then proved none of them carried a peer name.
- **A grep wall's "comments stripped" means WHOLE-LINE comments only** — a trailing comment satisfies
  a positive needle (`MeshRoutedSourceScan.codeOnly`).
- **A frozen baseline line whose whole audit category goes "unreported" can never fail.** An excuse
  that subtracts unconditionally turns a ratchet into decoration; narrow it by what is on screen.
- **A suite that matches neither half of the CI selector's predicate is protected by nothing** —
  `ProximityRecipeShareCapTests` ran 31 cells on no CI line at all through the whole phase.
- **Every declared Bonjour type owes a live / held / retired classification** in the commit that adds
  it — an unclassified type is a red, and a live one deleted silently would have been green.
- **Rebuild the app before any lane run**; **kill audit streams by saved PID**; **four Simulators are
  as cheap as two**.
- **Every P8 and P9 adversarial verify found something real** — **seventeen for seventeen** across
  the two rounds (P8's seven, P9's ten: 9.1, 9.2 ×2, 9.3 ×2, 9.4/9.5, 9.6/9.7, 9.8, 9.9, 9.10).
- **Closed; do not re-audit:** `MeshTunnelConvergence`, the id-vs-endpoint family, the crypto-purpose /
  `PayloadType` / record-kind spellings, plan §10.7–§10.10, §11.1–§11.4, §12.1–§12.4, §13.1–§13.4,
  §14.1–§14.4 and now §17.1; `Docs/Proximity-Security-Followups-2026-08-18.md` §1. Concurrent sessions
  share the tree; never stage the catalog working copy, `xcuserdata`, or the stray PDF.

---

## 8. Close-out, when P10 is done

1. Mark §17.2 **BUILT** with landing SHAs and its own What landed / Deviations / Findings /
   Acceptance evidence, in §13's, §14's and §17.1's format; update §15's table with whatever item 0
   produced, and the runbook's Lane B rows with results and dates.
2. Record deviations and policy acts; every ledger "Blocked on owner" line ends resolved, taken, or
   written into the findings list with its cost.
3. Memory note.
4. Write the next handoff (§28) and the next launcher from it, fact-checked against HEAD — **every
   anchor re-grepped, every claim about HEAD read out of the code, never out of the ledger.**
5. Draft → adversarial verify → apply from files.
6. Sync the string catalog from `HEAD`'s blob for every key P10 listed; check the count.
7. Note anything P10 learned that re-tiers what follows.

---

## 9. The road to TestFlight

| Session | Phase | Prerequisite |
|---|---|---|
| P2–P6 (done) | QUIC session, durable context, partition + merge, routed store, feature routing | built, proven sim↔sim; 4 866 green at P6 |
| P7 (done) | app-layer run policy, the poller, the resume surface | built and measured at P8 item 0 |
| P8 (done at tier 1/1b) | background continuation | **§15 NOT RUN** — the device gate, now two phases old |
| P9 (done at tier 1/1b/2) | the remaining radios over QUIC | **MC not deleted** — the cutover is an owner decision (§8.7 finding 3) |
| **this** | **P10 — companion `BGAppRefreshTask`** (§17.2) | tier 1 is its design and most of its acceptance; the grant needs a phone |
| +1 | **The device round, or the cutover** | whichever the owner unblocks first; both are written and waiting |

**After P10 the plan's phases are spent and the remaining work is the owner's, not the loop's**: two
to four phones for §15, the stranger-admission design that unblocks the MC cutover, and the product
calls (P9-3-A, the degraded ladder, §26.4's list). A round that has nothing left but owner items
should say so in one page and stop, rather than inventing an eleventh phase.
