# Loop Prompt — ProximityKit Network Migration: P9 (the remaining radios, MC retirement), with P8's device gate still open

**Written:** 2026-09-19, at the P8 boundary (`main` = the P8 close-out; **P8 is BUILT at tier 1 and
1b and its tier-3 acceptance has NOT been run** — plan §15's table is every row NOT RUN).
**Plan:** [Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md](Plan-ProximityKit-Network-Migration-2026-08-27.md) — the authority.
**§17.1 is the P9 specification; §17.2 is P10's; §26 is the handoff; §15 is P8's unpaid gate.**
**Ledger:** `Docs/Mesh-Migration-Loop-Ledger-P9.md` — created on iteration 1 (§7). The P8 ledger is a
finished record; read its "Blocked on owner" section once, then do not reuse it.
**Device plan:** [Docs/Mesh-P7-Physical-Device-Test-Plan-2026-09-18.md](Mesh-P7-Physical-Device-Test-Plan-2026-09-18.md) —
sections A–E are P7's behaviours on hardware, F is plan §15. Its results table is still blank.
**Scope:** **item 0 is the owner's device lanes** (P8's items 8 and 9, plus the two owed re-runs) —
with devices in hand, nothing else starts until §15's rows have dates. Then P9: presence and recipe
share over QUIC with the ephemeral posture reproduced, then MultipeerConnectivity **deleted**. Stop
at the P9 boundary. **P9 is NOT gated by §15** — with no devices, say so, record it, and do P9.

---

## How to start

```
/loop Read Docs/Next-Round-Prompt-Mesh-P9-2026-09-19.md and run one iteration of it.
```

Self-paced (no interval). A session that is not a `/loop` runs the same iterations back to back; the
ledger is the state either way. **This launcher assumes a Mac with Xcode 26 and at least one
Simulator**; two for tier 2, and two to four physical devices for item 0. A session with no toolchain
can do one thing here — nothing. **P7 wrote six items unbuilt and the debt was a whole item of P8:
build every commit.**

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
**Every one of P8's seven verifies found something real, and five found a defect that would have shipped** — a stranded claim,
a give-up clock running behind a hold, a door excuse admitting any slot, three unreachable card rows,
a raise fired while the app was lit, a reset that stranded a live handle. If the owner declines the
dispatch, do the work in-session, keep the *shape*, and record the deviation in the ledger.

### Hard token rules for the orchestrator

1. **Never `cat` a source file.** `sed -n 'a,bp'` or a targeted `grep -n`; more than ~60 lines is a
   subagent's job.
2. **Never let build or test output reach context.**
   ```bash
   xcodebuild … > "$LOG" 2>&1; echo "EXIT=$?" >> "$LOG"
   grep -E "EXIT=|BUILD (SUCCEEDED|FAILED)|TEST EXECUTE|Test run with" "$LOG"
   ```
   A background build's notified exit code is the **last command's**, not the build's — grep the log.
3. **One work item per iteration.** Item 0 may take several; each fix commit is its own.
4. **Write state to the ledger, not to your own memory.**
5. **Stop early rather than run out.** See §6.
6. **A close-out step that synthesises many facts runs as draft → adversarial verify → apply from
   scratch files.**
7. **A row that lands in two passes needs its gate to assert the later pass RAN.** P9's items 2 and 3
   are two-pass by shape (a transport, then the radio using it).
8. **One `xcodebuild` at a time on the shared DerivedData.** A second implement agent may draft
   anchored patches in scratch, but applies nothing until a marker file exists and re-reads every
   patched file first, because `main` moves. Commit by explicit pathspec, never `git add -A`, and
   never stage `App/Fernlet/Localizable.xcstrings`'s working copy, `xcuserdata/**`, or `Docs/`' PDF.

### If the budget runs out mid-phase

Stop the loop, write the handoff (§6/§8), and say plainly what is left.

---

## 1. Each iteration, in order

1. **Read the ledger.** `Docs/Mesh-Migration-Loop-Ledger-P9.md`. On iteration 1, create it from §7.
2. **Check the tree is safe to build on** (`git -C . log --oneline -1; git -C . status --porcelain`).
   Catalog keys are synced from `HEAD`'s blob (`Scripts/sync-string-catalogs.sh`), never from a held
   working copy.
3. **Pick the next item** whose prerequisites are met, from §3, in ledger order.
4. **Dispatch the three agents** with the item's full context: the acceptance criterion, the walls
   (§4), the ledger's decisions, and the gauntlet subset for what it touched (§6).
5. **Verify** — grep the marker line yourself. Check the exit code and `Test run with N tests`, count
   `◇ Suite` starts against `✔ Suite` passes, and grep for `Restarting after unexpected exit, crash,
   or test timeout` before believing any total.
6. **Commit** with explicit pathspecs.
7. **Update the ledger**: item → done with the SHA, one line on anything surprising, the next item.
8. **Schedule the next wake**, or stop per §6.

---

## 2. Testing strategy (re-tiered at the P8 boundary, §26.5)

| Tier | What it proves | Cost |
|---|---|---|
| **1 — no radio** | The transport swap's pure halves: golden wire frames for each radio's payloads, the rejection matrix, the ephemeral-identity rotation as a value, the pause/resume contract, the neutrality wall's permit list shrinking to empty. **If a check CAN live here, it MUST.** | Free, deterministic, CI. |
| **1b — the app's UI suite** | The recipe share sheet's pause/resume affordances and the presence row, serially, environment pinned (iPhone 17, portrait). | Minutes, same Mac. |
| **2 — sim↔sim, real QUIC** | **P9's acceptance.** Two radios two Simulators can both run: a presence epoch rotating with a fresh identity and a new instance name; a recipe request/response with a pause and a resume across it; and P8's item 2 carry-over rows. This is the inversion §26.5 names — P8's acceptance was tier 3 and P9's is tier 2. **Check the lane before trusting it:** at the P8 boundary it discovered nothing on this Mac (finding L-4, item 0). | One Mac, `simctl`. |
| **3 — physical devices** | **P8's unpaid gate, not P9's.** §15.1–§15.4, the device plan's A–F. Run it if devices are in hand (item 0); it blocks *shipping*, not P9. | Owner's devices and hours. |

Lane gotchas carried from P2–P8 — all paid for: `STAGGER=1`; re-harvest identities after any
`xcodebuild test`; a fresh log directory per run; `pgrep -x xcodebuild` before believing a failure;
warm the first `test-without-building` after a build with a tiny suite (it otherwise hangs ~350 s);
`--console-pty` intermittently attaches no stdout, so verify the `[mesh-matrix] run label=` banner;
every Lane C launch carries `FERNLET_MESH_MATRIX=1` and bypasses the launch restore; never chain a
build and a test run on one DerivedData. **New from P8:** a Simulator that has run ~3 h stops
rendering — erase and reboot before believing a UI red; and the audit stream is readable with
`xcrun simctl spawn <udid> log stream --level info --predicate 'subsystem == "com.fernlet"'`
(`info` level required; the `.private` context IS shown on a Simulator).

---

## 3. The work list

Ledger order. *File:line anchors were re-grepped at the P8 close-out (`main`); re-check before editing.*

| # | Item | Tier | Prereq |
|---|---|---|---|
| 0 | **P8's device lanes and the two owed re-runs.** The device plan's sections A–E on two devices, then F (plan §15.1–§15.4), results and dates into the **runbook's Lane B table** and the device plan's results table. Plus: the owner's re-run of item 0's four founding fixes on the fixed build, with the three simulator eyeballs folded in (Friends tab entry/exit was observed incidentally; **Control Centre over the Friends tab and delete-all during a live session are unobserved**); and the tier-3 rows P8 item 6 named — registration accepted, a `.fail` submission **granted** (no grant has been observed anywhere: a Simulator returns `BGTaskSchedulerErrorDomain` error 1 for every submission), the launch and expiration handlers firing on the real `SystemContinuationScheduler` conformer (exercised by **no test**), the tunnel surviving the whole task, slow progress across the 3 h and 6 h soaks, no proximity activity present, and the Control-Centre peek re-submission (row F12). **§15.3 decides the degraded ladder** — record the rung as a decision in the ledger and in plan §14. **Before the drawer opens:** fix the `DayRecordRepository` `assertionFailure`-in-`catch` family, or every lock and background row crashes in DEBUG. **Also carried from P8 item 2** (`1017b62`, done inside its timebox with one row of four crossed): the heart eligibility negative (the documented recipe cannot reach the refusal it names — the runbook carries the corrected one), the `FERNLET_MESH_ARM_AFTER` rows (the switch does not exist; building it is the row's price) and item 3's QUIC hold on real radios, which did not cross because of **finding L-4 — the sim↔sim QUIC lane discovers nothing at HEAD on this Mac** (six runs, zero `[mesh-quic]`, zero `proximity.transport.quic` at debug; plan §14.3 finding 19, and the runbook's Lane C section is the full record). **Verdict:** attributed 2026-09-19 by a baseline-commit probe (four lane runs, same hour, same Simulators, same CGNAT network): NOT a P8 regression — the P6 close-out `82fc4d7` and P2's `596bcf8` discover, the pre-P8 tip `92f0b8e` and P8's tip fail identically; a P7 defect at `df0ce5b` (P7 item 3): the DEBUG matrix harness calls `startJoin()` on the Home tab and the store's first policy apply (previous nil, every radio an edge) resolves discovery `.stop` → `.stopJoin` → the QUIC listener is cancelled ~20 ms after creation, before Bonjour registers; the product path (entry via the Social tab) is unaffected; fix landed as the P7 fix commit `80934b7` — the harness selects the Social tab before `startJoin()`, with the pure-value cell `theMatrixHarnessSurvivesTheFirstRunPolicyVerdict` (no `.stopJoin` in the first verdict over the harness's facts) that would have reddened in `df0ce5b` itself, and a scan pinning every shipping `startJoin()` / `resumeSearchingForPartitionedMesh()` caller under `App/` to the seams file or the harness. **That lane is P9's acceptance lane (§2): confirm the P7 fix is on `main` and that a lane run discovers again before believing any tier-2 row.** **If there are no devices, mark item 0 `blocked (owner)` and go to item 1** — P9 is not gated by it. | 3 | — |
| 1 | **The `assertionFailure`-in-`catch` family.** `DayRecordRepository` and 18 sibling sites turn an environmental Core Data / file I/O failure into a DEBUG trap (`Task 437: Fatal error: day record delete failed`); the store loads with `FileProtectionType.complete` and nothing defers day writes while the device is locked. Owner chooses the scope (day repository only, or all 19). A cell per fixed site: a throwing store does not trap, and the failure is audited. | 1 | — |
| 2 | **Presence over QUIC — the posture before the framing.** `FernletKit/Sources/ProximityKit/Presence/PresenceManager.swift` (`serviceType` `"fernlet-near"` at `:113`, `session.start(serviceType:discoveryInfo:)` at `:272`). Pass 1: reproduce the **ephemeral posture** as a tier-1 value — a fresh TLS identity (`EphemeralMeshTLSIdentity`, `FernletKit/Sources/ProximityKit/Transport/EphemeralMeshTLSIdentity.swift:189`) and a randomized instance name per 900 s presence epoch (§17.1's figure — it is a spec number, not a constant in the code today), with a rotation table as its test: no name and no identity survives an epoch boundary, and nothing about the device is derivable across two epochs. Pass 2: the payload over `NetworkMeshSession`, the MC path gone from this file, and `isListening` (`PresenceManager.swift:239`, the same shape as `ProximityRecipeShareManager.swift:175`) still the radio's own account. **Do not re-introduce an edge-triggered listener seam** — P8 item 0's device finding (b) cost a device round. | 1 + 2 | — |
| 3 | **Recipe share over QUIC, pause/resume preserved.** `FernletKit/Sources/ProximityKit/RecipeSharing/ProximityRecipeShareManager.swift` (`serviceType` `"fernlet-recipe"` at `:119`, `start()` at `:181`, `isListening` at `:175`). Request/response streams over the same machinery; `MeshTransferStreamTable` (`FernletKit/Sources/ProximityKit/Transport/MeshTransferStreamTable.swift:90`) is the model for chunking. **Pause/resume is a shipped user-visible behaviour** — a swap that loses it is a regression nobody will attribute to the transport, so the pause/resume cell is pass 1's, not pass 2's. Tier 2: a share paused and resumed across a real QUIC stream between two Simulators. | 1 + 2 | 2 |
| 4 | **Retire MultipeerConnectivity.** Delete `FernletKit/Sources/ProximityKit/Transport/MeshMultipeerSession.swift` and `FernletKit/Sources/ProximityKit/Transport/MCPeerIDStore.swift` (`FileMCPeerIDStore` at `:32`); retire the `MCPeerIDStore` privacy-wipe row and its delete-all wiring; drop the MC Bonjour types from `App/Fernlet/Info.plist:18–25` — **six** if plan §18's open decision 4 (the coach radio's disposition) is still open, because `PeerTransport.trainer = "fernlet-coach"` (`FernletKit/Sources/ProximityKit/Transport/PeerTransport.swift:14`), `CoachSessionTrustPolicy` and `TrainerPayloads` still ship; all **eight** once the owner retires the coach radio. Record the choice in the ledger's decisions table and **keep `_fernlet-mesh2._udp` at `:26`** — that one is QUIC's; remove the MC import. `Tests/FernletTests/TransportNeutralityBoundaryTests.swift`'s `permittedFiles` (`:32`) empties in the same commit — a permit list naming files that no longer exist is a wall that has stopped meaning anything, and the suite already asserts each permitted file exists (`:105`). Done before the Xcode 27 toolchain move. | 1 | 2, 3 |
| 5 | **The 1:1 foreground anchors: ship a widget or retire them.** `ProximityCoordinator.swift:257` injects `ActivityKitProximityForegroundAnchor()` under `#if canImport(ActivityKit)`, but `ProximityConnectionActivityAttributes` (`FernletKit/Sources/ProximityKit/ForegroundAnchor/ProximityForegroundAnchor.swift:48`) is module-internal and `App/FernletWidgets/FernletWidgetsBundle.swift:30` declares no configuration for it — every `Activity.request` on the 1:1 path is doomed, exactly as the mesh's was before P8 injected `NoopProximityForegroundAnchor()` (`MeshNetworkManager.swift:11248`, `:14487`, `ProximityRecipeShareManager.swift:932`). **Default: retire.** The once-per-launch orphan reaper stays either way. | 1 | — |
| 6 | **The fourteen ungated P6-relevant suites.** Priced by P8 item 1 at **247 cells for 11 s** (`.github/workflows/s3-wall.yml`'s mesh-batteries comment lists them). The recommendation is to gate them; one line edit plus a re-measured floor (currently **469** over **71** suites). | 1 | — |
| 7 | **The six process-global audit counts on CI.** `Tests/FernletTests/MeshRoutedDrainTests.swift:673`, `:718`, `:752` (`== 1`) and `:792`, `:822`, `:853` (`== 0`) count the process-global `FernletAuditLog` capture of `mesh.routedInventory.staleSentAt` unscoped to the rig — the D-6a.10 shape. Green today only because no suite on the line emits the token beside them. Take them as deltas, or scope them by the rig's context key. `MeshKeyAdvertisementDeliveryTests`' `parkedReoffered` count is the same shape. | 1 | — |
| 8 | **The two accessibility-ratchet baselines.** `UXScreenProbe.auditBaselines`, last re-recorded 2026-08-27: Progress photos (`Aug 28` clipped, not in baseline) and Recent bites (three baseline findings that no longer reproduce). Both reproduce on the P6 close-out build `82fc4d7`, so they predate P7. Re-record on a **freshly erased** Simulator, pinned (iPhone 17, portrait, content size `large`, dark). | 1b | — |
| 9 | **The P9 acceptance battery + CI gate lines, one commit.** One serialized `MeshP9<Clause>AcceptanceTests` per clause (the ephemeral posture; the presence swap; the recipe swap with pause/resume; the MC retirement as a zero-list) plus an honesty suite naming what cannot run on CI. `CIGateSelectorBoundaryTests`' pin **measured** at the commit that moves it (48 today); the floor raised by the **measured** count (469 today). Neither determinism digest may move. | 1 | 2–4 |
| 10 | **Close-out** (§8): §17.1 marked BUILT with its own What landed / Deviations / Findings / Acceptance evidence, §15's table updated with whatever item 0 produced, the P10 handoff, the next launcher, the memory note. | 1 | 0–9 |

### Not this phase

- **P10's `BGAppRefreshTask`** (§17.2) — `MBO.Fernlet.companion-refresh`, the `fetch` mode, a handler
  limited to acquire-store → roll day → recompute companion → diff snapshot → publish via
  WidgetBridge → reload timelines only on change → complete once. Its identifier joins
  `BGTaskSchedulerPermittedIdentifiers` (`App/Fernlet/Info.plist:32`, today only
  `MBO.Fernlet.mesh-continuation.*`) and §16.4's import wall lands with it. `FernletStoreAccess`
  (`App/Fernlet/ExchangeIntentService.swift:18`) is already one process-global cache shared by UI and
  App Intents, so moving it out is hygiene; the dead `install(store:)` (`:82`) is still there.
- **Relay increment 2** — still gated on the tier-2 measurement §11 names, still unearned.
- **Re-deciding the run policy.** Its 23 040-row table is P7's and P8 fed it one input. A P9 that
  rewrites a policy row has found a P7/P8 bug — fix it as such, re-run the whole product, say so.
- **A second owner for any radio.** Every radio verb's one home is
  `FernletStore.executeProximityRunActions` (`App/Fernlet/ProximityRunSeams.swift:276`).
- **Option (b) for `handleEncryptedMetadata`, D-7.30, §18.2's copy, the legacy unsigned removal,
  transcript `sid`, the census/duress questions** — owner's, unchanged (§26.4).

### The decisions, with defaults so nothing blocks

| Decision | Default | Why |
|---|---|---|
| **The first iteration** | **Item 0 if devices are in hand; otherwise item 1, with item 0 `blocked (owner)`.** | P8's gate is the oldest unpaid bill and it blocks shipping, not P9. |
| **Presence posture** | **Reproduce it before the framing**: fresh TLS identity + randomized instance name per 900 s epoch, pinned by a rotation table. | The posture is the privacy claim; the framing is mechanics. |
| **Recipe share** | **Request/response streams preserving pause/resume**, the pause cell in pass 1. | A shipped behaviour, silently lost otherwise. |
| **When MC is deleted** | **Same phase, after both radios cross**, with the permit list emptied in the same commit. | A wall naming deleted files means nothing. |
| **The coach radio (plan §18 decision 4)** | **Hold the two `_fernlet-coach._{tcp,udp}` strings; drop the other six.** | `PeerTransport.trainer` still ships, with `CoachSessionTrustPolicy` and `TrainerPayloads`. Retiring the coach types is a product decision about the Coach app, not transport cleanup. |
| **The 1:1 anchors** | **Retire.** | They have never rendered. |
| **Gate the fourteen** | **Yes** — priced at 11 s. | The estimate that deferred them was wrong by an order of magnitude. |
| **New persisted surface** | **None.** Any `UserDefaults` key owes a `Docs/PrivacyWipeCoverage.md` row and delete-all wiring in the same commit. | P6, P7 and P8 added none. |
| **The degraded ladder** | **Decided by §15.3 in item 0**; until then unchosen and P8's scope unchanged. | §14 pre-decided the rungs; only a soak picks one. |

---

## 4. Walls that will bite

- **Transport neutrality** (`TransportNeutralityBoundaryTests`): framework type prefixes (`MCPeerID`,
  …) are matched as whole identifiers so Fernlet's own `MCPeerIDStoring` / `FileMCPeerIDStore` /
  `MeshMultipeerSession` names do not trip the scan. The permit list is `:32`; it must **exist**
  (`:105`) — so emptying it and deleting the files is one commit.
- **The two continuation doors are deliberately off the radio-verb retirement wall's needle list**,
  with the reason written into that wall: `beginBackgroundContinuation()`
  (`MeshNetworkManager.swift:9268`) and `endBackgroundContinuation()` (`:9283`) are session-state
  raises, not radio verbs. Do not "tidy" them onto the list. **The raise wall**
  (`MeshContinuationRaiseWallTests`): `.backgrounded` and `.foregrounded` exactly once each under
  `FernletKit/Sources`, inside those doors; the doors once each under `App/`; `applySessionEvent(`
  **zero** under `App/`.
- **One gate writer** (W8, `MeshRoutedLockedDeviceTests`): `applyRoutedAccessGate(` once under
  `App/`, inside `FernletStore.runProximityPolicy`. **`storeEdges == 6`** since P8 item 6.
- **One radio-speaking file**: `FernletStore.executeProximityRunActions`
  (`App/Fernlet/ProximityRunSeams.swift:276`); `MeshRejectionMatrixHarness` exempted **by name**. A
  new radio verb joins the list in the same commit or the wall reddens. **One timer**
  (`ProximitySessionPollerTests`): `pollSession(` from one app file, one bounded self-stopping
  `Task`. No second clock.
- **The zero-count token**: `proximityRunPolicy.unsupportedTransition` is emitted by nothing since
  P8 item 3 and `ProximityRunSeamsTests` holds it at zero under `App/`. `.holdLinks`
  (`ProximityRunSeams.swift:94`) is the executed row.
- **Three predicates, three jobs**: `isSessionLive` (projections, ceremonies, the poller),
  `hasCommittedPeer` (radio guards, the resume arm), `isInSession` (the layout swap). Never collapse.
  `hasSlot(for:)` means **any** slot; the committed predicate is `hasCommittedSlot(for:)`.
- **The routed walls, unchanged**: the registry as the only per-type source; two admission doors;
  refusals through `refuseRoutedFrameBeforeStore` except the digest family; no epoch on the routed
  path; the three retirement zero-lists; schemas `MeshSessionContext` **3**, routed index **2**.
- **The CI selector wall**: every `MeshP<n>*AcceptanceTests` declared must be named on the mesh step
  and every named suite declared; the floor **measured**. Today **71 suites at floor 469**, pin
  `>= 48`. **Determinism**: `ca898bcc…6930` and `594b6f77…5765` do not move; a move is a red.
- **Localization**: display text is `LocalizedStringKey` (or `LocalizedStringResource` where an API
  needs a `String`), tokens frozen English; a `String` parameter silently opts the call site out.
  New keys are listed for the close-out's sync from `HEAD`'s blob.
- **Power of 10**: ≤ 60 code lines per body, bounded loops, no `!`/`try!`/`as!`/`fatalError`, no
  swallowed `try?`, no mutable globals, no nested `#if`, warnings-as-errors. **Memory lifecycle**
  (ML4/ML5): a type holding a task and a manager holds the manager **weakly** and adds no detached
  unmarked `Task`.
- **Wipe wall**: any new persisted surface or `UserDefaults` key owes a `Docs/PrivacyWipeCoverage.md`
  row and delete-all writer wiring in the same commit. Item 4 **retires** a row — same rule, inverted.
- **DocC**: `///` on every type, `Scripts/doc-coverage-scan.py` at zero, FileIndex /
  ProximityFunctionIndex / both landing pages in the same commit.
- **Do NOT touch** `App/Fernlet/Localizable.xcstrings`'s working copy, `xcuserdata/**`, or the stray
  PDF in `Docs/`.

---

## 5. Three items with a design call inside

### (a) Item 0 is a gate, not a formality — and it is also optional

§15 is P8's acceptance and it has never been run. With phones in hand it is the highest-value hour in
the round: it decides the degraded ladder, it produces the first observed `.fail` **grant** anywhere,
and it exercises the one conformer no test touches. Without them, say so plainly, mark it blocked and
do P9 — **a phase that waits on devices it does not have spends its budget waiting.** Fix the
`assertionFailure`-in-`catch` family first either way: it decides whether a device row reports or crashes.

### (b) The posture is the product; the framing is the mechanics

Presence over QUIC is tempting to do payload-first, because the payload is the visible part. The part
that matters is the one nobody sees: a fresh TLS identity and a randomized instance name per epoch, so
two sightings 901 seconds apart are not linkable. Build it as a value with a rotation table, pin that
nothing survives an epoch boundary, then move the bytes. A radio stable-named for one release tracks.

### (c) A deletion is a wall change, not a file removal

Item 4 deletes two files; what keeps it honest is `TransportNeutralityBoundaryTests.permittedFiles`
going empty in the same commit — that suite asserts each permitted path **exists**, so the deletion and
the list move together or the tree is red. Retire the privacy-wipe row and its delete-all wiring in the
same commit: a wipe row for a store that no longer exists reads as coverage.

---

## 6. Stop conditions — end the loop on any of these

1. **P9 is complete** — every item done, gauntlet green, §17.1 BUILT, the P10 handoff written.
2. **Blocked on the owner** — item 0 needs devices; if only it remains, say what is needed and stop.
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

**The last MEASURED full-suite baseline is P8's close-out run: `5 055 tests in 513 suites`, 910 s,
EXIT=0**, no `Restarting after unexpected exit`, 0 suites failed (iPhone 17, 2026-09-19 00:07, bundle
at `c86e3a0`; item 0's was 4 939 / 499 and P6's 4 866 / 486). Never take a total from a log carrying
`Restarting after unexpected exit, crash, or test timeout`. Repository gates at the P8 boundary: both scans at 0; mesh-batteries
**469 / 71 at floor 469**; `CIGateSelectorBoundaryTests` pin **48**.

Per-item subset: every suite the diff touches + the routed and phase suites (`MeshRouted*`,
`MeshP5*`, `MeshP6*`, `MeshP7*`, `MeshP8*`, `MeshContinuation*`) + the wall suites
(`MeshRoutedLockedDeviceTests`, `MeshRoutedDrainTests`, `MeshRoutedDrainWallTests`,
`MeshRoutedRefusalBudgetTests`, `CryptographicPurposeBoundaryTests`, `CIGateSelectorBoundaryTests`,
`LocalizationBoundaryTests`, `PowerOfTenBoundaryTests`, `ProximityRunSeamsTests`,
`ProximitySessionPollerTests`, `SessionResumeCopyTests`, `MeshContinuationRaiseWallTests`,
`MeshContinuationTaskHostWallTests`, `TransportNeutralityBoundaryTests`) + the app-target walls
(`PersistedSurfaceWipeBoundaryTests`, `PrivacyWipeCoverageTests`, `DeleteAllDataTests`,
`NoTrackingBoundaryTests`, `MemoryLifecycleBoundaryTests`, `PrivacyPolicyParityTests`). Regenerate
from the `@Suite` declarations, then **add by hand the suites that carry none** — a grep for `@Suite`
under-counts. Verified at the P8 close-out: of the 71 suites on the mesh step, `MeshContinuationRaiseWallTests`
and `MeshContinuationTaskHostWallTests` have no attribute, and off the line so does
`MeshRoutedItemSealTests`. Name the **struct**, never the file.

**Every new or amended wall is shown red once**: disable the guard, **REBUILD**, run, keep the log,
restore the exact text, re-grep, **REBUILD** again. A rename red-once can be satisfied by the rename
itself — a pass-2 cell's needles must be independently reddenable.

---

## 7. Ledger template

Create `Docs/Mesh-Migration-Loop-Ledger-P9.md` on iteration 1 if absent. Keep it short.

```markdown
# Mesh Migration Loop Ledger — P9

**Phase:** P9 (the remaining radios, MC retirement), with P8's device gate still open · **Prompt:** [Next-Round-Prompt-Mesh-P9-2026-09-19.md](Next-Round-Prompt-Mesh-P9-2026-09-19.md)
**Started:** 2026-__-__ · **Iteration:** 1 · **Tree at seed:** `main` = the P8 close-out; P8 BUILT at tier 1/1b, §15 NOT RUN

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`. Tier per §2.
| # | Item | Tier | Prereq | State | SHA | Note |
|---|---|---|---|---|---|---|
| 0 | P8's device lanes (§15.1–§15.4, device plan A–F) + the two owed re-runs; the ladder decided | 3 | — | todo | | blocked (owner) if no devices — P9 is NOT gated by it |
| 1 | The `assertionFailure`-in-`catch` family (19 sites) | 1 | — | todo | | do before the phone drawer opens |
| 2 | Presence over QUIC — posture first | 1 + 2 | — | todo | | two passes |
| 3 | Recipe share over QUIC — pause/resume preserved | 1 + 2 | 2 | todo | | two passes |
| 4 | Retire MultipeerConnectivity (2 files, 6 or 8 plist strings, the wipe row, the permit list) | 1 | 2, 3 | todo | | one commit; the coach pair is §18 decision 4 |
| 5 | The 1:1 foreground anchors — widget or retire | 1 | — | todo | | default: retire |
| 6 | Gate the fourteen (247 cells / 11 s) | 1 | — | todo | | floor re-measured |
| 7 | The six process-global drain counts + `parkedReoffered` | 1 | — | todo | | D-6a.10 shape |
| 8 | The two accessibility-ratchet baselines | 1b | — | todo | | fresh Simulator |
| 9 | P9 acceptance battery + CI lines | 1 | 2–4 | todo | | pin and floor measured |
| 10 | Close-out: §17.1 BUILT, §15 updated, the P10 handoff, the next launcher, memory | 1 | 0–9 | todo | | draft → verify → apply |

## Blocked on owner
- Devices for item 0; the runbook's Lane B table is the evidence table.
- Carried from plan §26.4 (read it; do not re-list it here).

## Decisions taken (defaults from §3 unless the owner overrides)
| Decision | Choice | Taken on |
|---|---|---|
| The first iteration | (default: item 0 if devices, else item 1) | — |
| Presence posture | (default: reproduce before the framing) | — |
| Recipe share | (default: request/response, pause/resume in pass 1) | — |
| When MC is deleted | (default: same phase, after both radios cross) | — |
| The coach radio (plan §18 decision 4) | (default: hold the two `_fernlet-coach` strings; drop the other six) | — |
| The 1:1 anchors | (default: retire) | — |
| Gate the fourteen | (default: yes) | — |
| New persisted surface | (default: none) | — |
| The degraded ladder | (decided by §15.3 in item 0) | — |

## Surprises worth not re-deriving
- (seed from §9 of this launcher)

## Next item
0
```

**Lessons carried from P8 — seed the surprises list with these:**
- **A continued-processing task is delivered while the app is still in the foreground.** Any state
  meaning "we are continuing in the background" keys on (task in hand ∧ scene dark).
- **Gating cost is not proportional to cell count**: +92 % cells cost +10 % wall time on a tier-1
  step. Price a gate before deferring it.
- **A hold is not a stop**: every clock that assumes browsing must pause with the radios — grep every
  `arm…Clock` when adding a pause-shaped verb.
- **A terminal state erases its cause unless a projection rule keeps it**; and **a reset that clears
  state without walking the table strands every side effect the table owed**.
- **`hasSlot(for:)` means ANY slot** — read the body of every predicate a new door consults; and a
  **re-entry row keys on facts, not on `previous`**.
- **A protocol requirement declared in an app file is a second occurrence of a grep-wall's needle**,
  and **a grep for `@Suite` under-counts the suites** (some are plain structs found by their `@Test`s).
- **A background build's notified exit code is the last command's**, and **a Simulator that has run
  ~3 h stops rendering** — erase and reboot before believing a UI red.
- **Every P8 adversarial verify found something real.** Seven for seven; five of them would have shipped.
- **Every P6 and P7 lesson still binds**: a log with `Restarting after unexpected exit` has no usable
  total; never chain a build and a run on one DerivedData; `-only-testing:` names the SUITE;
  `@Test(arguments: [])` is green over nothing; a process-global audit signal cannot witness a
  per-cell claim; `.inactive` is foreground for the radios; `FernletLockState` carries associated
  values; the chat age gate is `AgeGate.chat`; zsh passes an unquoted `$ARGS` as one argument.
- **Closed; do not re-audit:** `MeshTunnelConvergence`, the id-vs-endpoint family, the crypto-purpose
  / `PayloadType` / record-kind spellings, plan §10.7–§10.10, §11.1–§11.4, §12.1–§12.4, §13.1–§13.4
  and §14.1–§14.4; `Docs/Proximity-Security-Followups-2026-08-18.md` §1. Concurrent sessions share
  the tree; never stage the catalog working copy, `xcuserdata`, or the stray PDF.

---

## 8. Close-out, when P9 is done

1. Mark §17.1 **BUILT** with landing SHAs and its own What landed / Deviations / Findings /
   Acceptance evidence, in §13's and §14's format; update §15's table with whatever item 0 produced,
   and the runbook's Lane B rows with results and dates.
2. Record deviations and policy acts; every ledger "Blocked on owner" line ends resolved, taken, or
   written into the findings list with its cost.
3. Memory note.
4. Write the **P10 handoff** (§27) and the next launcher from it, fact-checked against HEAD.
5. Draft → adversarial verify → apply from files.
6. Sync the string catalog from `HEAD`'s blob for every key P9 listed; check the count.
7. Note anything P9 learned that re-tiers P10.

---

## 9. The road to TestFlight

| Session | Phase | Prerequisite |
|---|---|---|
| P2–P6 (done) | QUIC session, durable context, partition + merge, routed store, feature routing | built, proven sim↔sim; 4 866 green at P6 |
| P7 (done) | app-layer run policy, the poller, the resume surface | built and measured at P8 item 0 |
| P8 (done at tier 1/1b) | background continuation | **§15 NOT RUN** — the device gate is this launcher's item 0, and it gates shipping, not P9 |
| **this** | **P9 — the remaining radios, MC retirement** | tier 2 is its acceptance; no devices needed |
| +1 | **P10 — companion `BGAppRefreshTask`** (§17.2) | P9 done; a refresh handler that never touches the mesh |

**The tier-1 re-tier ended at P7 and inverted at P8.** P8's design was tier 1 and its acceptance tier
3; **P9's acceptance is tier 2** — two radios two Simulators can both run — so a P9 that waits on
hardware has mis-tiered itself. The one hardware number still unbeaten is the first sample: a
user-started continued-processing task ended ≈ **46 s** in, no progress reported, 2026-09-02.
