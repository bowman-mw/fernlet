# Loop Prompt — ProximityKit Network Migration: P4 (partition and merge)

**Written:** 2026-09-02, at the P3 boundary (main = `3722511`, pushed).
**Plan:** [Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md](Plan-ProximityKit-Network-Migration-2026-08-27.md) — the authority. **§10 is the P4 specification; §21 is the handoff; §16.2 is the acceptance.** This file is the launcher and the loop contract.
**Ledger:** [Docs/Mesh-Migration-Loop-Ledger-P4.md](Mesh-Migration-Loop-Ledger-P4.md) — the loop's memory, created on iteration 1 (§7). It lives on disk, not in context. The P3 ledger is a finished record; **do not reuse it.**
**Scope:** build **P4** — partition detection and the split states, branch-local operation, the single merge path, divergent-epoch reconciliation (`coexist` → one head), record re-gossip across a healed partition (§10.5), quorum under partition (§10.4), delivery-target semantics defined in partition terms (what P5 needs), and the tier-1 battery for all of it on `FakePeerNetwork` / `FakeMeshTransportSession` / an injected clock. **Stop the loop at the P4 boundary.**

---

## How to start

```
/loop Read Docs/Next-Round-Prompt-Mesh-P4-2026-09-02.md and run one iteration of it.
```

Self-paced (no interval): the work is build-and-test-bound, not clock-bound, so the loop wakes when
work completes, not on a timer.

---

## 0. Orchestrator contract — read this first, it is the binding constraint

**The orchestrator is Fable, running on a limited model budget.** That is the scarcest resource in
this project, scarcer than build minutes or sim time. Every rule below exists to protect it.

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

Delegate with `Agent(..., model: "opus")`. Opus does the reading and writing; Fable spends tokens on
judgement. A subagent that returns 40 lines of summary has saved the orchestrator thousands of lines
of file content — that ratio is the whole point.

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
   fix as its *own commit* is fine, as P2 did with items 3c/12/14.)
4. **Write state to the ledger, not to your own memory.** `/loop` resumes the *same* context and
   never compacts between iterations, so anything you keep in your head is paid for again on every
   subsequent turn and is lost if the session ends. The ledger is the only durable state.
5. **Stop early rather than run out.** See §6. A clean handoff is cheap; a loop that dies mid-item is
   expensive to reconstruct. When the ledger is the only thing a fresh session would need to resume,
   that is the moment to stop.

### If the Fable budget runs out mid-phase

Stop the loop, write the handoff (§6/§8), and say plainly what is left. Do not silently degrade into
doing the work yourself — that is exactly how the budget disappears.

---

## 1. Each iteration, in order

1. **Read the ledger.** `Docs/Mesh-Migration-Loop-Ledger-P4.md`. On iteration 1, create it from §7's
   template, seeded with the fourteen items below. Thereafter it is already seeded — go straight to
   the next item.
2. **Check the tree is safe to build on** — first iteration, or after any owner activity:
   ```bash
   git -C . log --oneline -1; git -C . status --porcelain
   ```
   Another session has long held `App/Fernlet/Localizable.xcstrings` (a large foreign diff) and a
   personal `xcschememanagement.plist`. **Leave both alone**; never stage them. Commit with explicit
   pathspecs, never `git add -A`.
3. **Pick the next item** whose prerequisites are met, from §3's list, in ledger order. Prefer a
   **tier-1** item over a tier-2 one — see §2. The tier-2 items (11–14) are corroboration, not the
   acceptance gate: do not start them before the tier-1 battery (item 10) is green.
4. **Dispatch one subagent** with the item's full context: the acceptance criterion, the walls it must
   not trip (§4), the merge laws it must not break (§4, first bullet), and that it must run the
   gauntlet subset for what it touched (§6).
5. **Verify** — grep the marker line out of its build/test log yourself. Do not take "it passed" on
   trust; this repo has notified a failed build as exit 0, and a crossed log has shown ~20 phantom
   failures under concurrent-session contention.
6. **Commit** with explicit pathspecs (note `git mv` stages a rename immediately, so check
   `git diff --cached --name-status` first).
7. **Update the ledger**: item → done, with the SHA, one line on anything surprising, the next
   unblocked item, and any new sub-item the work exposed.
8. **Schedule the next wake**, or stop per §6.

---

## 2. Testing strategy — re-tiered 2026-09-02, three real nodes now work

**P4's acceptance is tier 1 by design** (§10's acceptance line, §16.2's matrix): randomized bounded
schedules under a fixed seed belong on the fake fabric and nowhere else. What changed at the P3
boundary is corroboration: **§8.7 finding 1 is FIXED (`871b7ee`)** — `isSessionOpen`, the mesh-wide
"admits new **members**" rule, was gating whether a **link** could open, so a `.closed` mesh could
never form the tunnels it is made of. Three Simulators now form a **full mesh 3/3**, so tier 2 is
first-class for the first time.

| Tier | What it proves | Cost |
|---|---|---|
| **1 — no radio** | Everything in §10: partition detection and the split states, branch-local coordinator/rotation, the union merge, `coexist` → one head, §10.4's quorum arithmetic (rosters 2–8 × shapes), §10.5's two worked examples verbatim, §16.2's convergence property test over randomized bounded schedules with a fixed seed. All on `FakePeerNetwork` + `FakeMeshTransportSession` + an injected clock, **no wall-clock sleeps**. **If a check CAN live here, it MUST.** | Free, deterministic, CI. |
| **2 — sim↔sim MULTI-NODE, now first-class** | **3–6 Simulators on one Mac**, through the Lane C harness + P3's item-9 seams: `FERNLET_MESH_ROLE=founder\|joiner`, `FERNLET_MESH_LEAVE_AFTER`, `FERNLET_MESH_REMOVE_AFTER`, `armFounderLedgerForHarness()`, `requestAdmissionForHarness()`, `seedRemovalRecordForHarness`, `FERNLET_MESH_MATRIX_MEMBERS` (≤ 8 keys), `FERNLET_MESH_FLOWS=commit`, and the scratch `threerun.sh`. Proven at the boundary: 3/3 full mesh, `derived=3` on all three, one `epochRef` minted by a **non-founder** (so the key crossed two tunnels), a departure accepted by **both** survivors. | One Mac, `simctl`, minutes per run. |
| **3 — physical devices** | Only §15's hardware gates: AWDL, the Local Network prompt, background/locked, battery, thermal, §15.2's physical partition walks as the *last* confirmation. **P4 owes tier 3 nothing.** | Owner's time; not this phase. |

Lane gotchas — obey them, they are all paid for:
- **Launch the sims ~1 s apart (`STAGGER=1`), not 3 s.** `MeshFlowDriver.driveFounder` arms the
  founder's ledger on its *first* committed slot and collapses the seeded descriptor to the founder
  alone; a third node whose tunnel is not up by then is a stranger and is refused.
- **Always re-harvest identities** after any `xcodebuild test` run — the full suite resets sim app
  state, and a stale `FERNLET_MESH_MATRIX_MEMBERS` list silently makes a node a stranger.
- **A fresh log directory per run**, and `pgrep xcodebuild` before believing any failure — a
  concurrent session shares this Mac's sim fleet; a crossed log once showed ~20 phantom failures.
- `The test runner hung before establishing connection` is a Simulator flake. If the destination sim
  is **already Booted**, a plain retry clears it. Boot + ~20 s settle **before** `xcodebuild` only
  when the sim is not yet booted. `simctl shutdown all` did NOT cure it.
- **Instrument before the first run, not after the first mystery.** "The frame never arrived" and
  "the frame arrived and was refused" read identically without an echo. The existing ones:
  `[mesh-quic] membershipFrame sent` / `membershipRecord <accepted|refusal>`, `browsed peers=`,
  `dial refused`, `inbound tunnel refused`, `[mesh-flow] slots total=N committed=N`.
- A removal does **not** cut a live tunnel — it refuses the *next* introduction. And
  `seedRemovalRecordForHarness` re-seeds the ledger rather than travelling `insertMembershipRecord`,
  so it requests no rotation (rotation-on-removal is tier 1, `MeshRotationTriggerTests`).

---

## 3. The work list

Ledger order, respecting §10's own order (split → merge → epoch → quorum → convergence). Each is one
iteration unless noted; the merge path and the property test will each take 2–3.

| # | Item | Tier | Prereq |
|---|---|---|---|
| 1 | **Partition detection + branch-local operation** (§10.2): what raises `linksLost` / `partitioned` / `linksRestored` on `MeshSessionStateMachine`; unreachable members marked `temporarilyDisconnected` as **presence, never a record**; branch coordinator = lowest fingerprint **present**; branch-local 15-min rotation and liveness; a partition of one hits `localIdleStop` at 30 min and resumes-as-merge. | 1 | — |
| 2 | **The single merge path** (§10.3, §21.1): the record + epoch-head union exchange on reconnect, built **on `MeshNetworkManager.mergeMembershipLedger(_:)`** — do not add a second merge path. Blip, partition, idle lapse and process restart all run it; `resumedAfterLapse` goes through ledger merge + epoch acceptance, never a fresh session. 2–3 iterations. | 1 | 1 |
| 3 | **Divergent-epoch reconciliation** (§10.3, §21.1): two `coexist` heads at the same counter → the merged view's deterministic coordinator mints `successor(coordinatorFingerprint:meshID:)` at counter = max+1, `cause = .merge`; both old keys die at grace expiry; **exactly one** post-merge epoch at every member. `mergedHeads(_:adding:limit:)`' cap 8 is an assertion, not a knob (§21.3). | 1 | 2 |
| 4 | **§10.5 re-gossip and departure recovery at merge** (§10.5 + §8.7 finding 2, default per §21.3): the owner's worked example encoded **verbatim** — {A,B}/{C,D}, B departs, A meets C, C gossips to D, all three converge on roster {A,C,D} with quorum 2, B never meeting C or D. Plus: a survivor that **missed** a departure (the write that never flushed) learns it at the next merge. | 1 | 2 |
| 5 | **Quorum under partition** (§10.4): ⌊\|roster\|/2⌋+1 distinct signed votes re-derived on the **receiver's** merged roster; proposal ID; the 5-minute expiry; the target cannot vote; an incomplete proposal leaves no trace; a completed one is a permanent `SignedRemovalRecord` that union-merges. Table-driven over rosters 2–8 × partition shapes. **Check first whether proposal/vote records exist** — P3 shipped only the quorum-signed `member-removal.v1`; if the vote is new signed bytes it is golden + registry + framing case **together** (§4). | 1 | 1 |
| 6 | **Termination and development under partition** (§10.6): development in a split with merged roster > 2 is a departure with the bounded 15 s handoff to the *reachable* members; "final pair" judged on the **merged derived roster**, not the connected pair; a wrongly-issued termination downgrades to the signer's departure at every receiver with a larger roster; genuine final pair with an unreachable partner. | 1 | 1, 5 |
| 7 | **Content merge: ordering, dedup, and gates re-run at ingestion** (§10.3): photos union by manifest ID + hash on reassembly; texts union by message ID with the transcript re-derived in total order `(claimedSentAt clamped to ±10 min of first-seen, senderFingerprint, messageID)`; hearts union by gift ID with the final receipt still only at foreground decrypt + ledger commit. **Age gate and moderation re-run at ingestion** (§21.3 default) — a branch's approval is not a free pass. | 1 | 2 |
| 8 | **Delivery-target semantics for P5** (§10.1): a named type answering "who is this for" as **the full derived roster at creation time**, not the connected set, with unreachable members as *pending deliveries* rather than non-recipients. This is the interface P5's routed store consumes; design it here, deliberately (§5c). | 1 | 1 |
| 9 | **§16.2's convergence property test**: roster {3,4,6,8} × shapes (2/2, 3/1, 3/3, 4/2/2, nested re-split mid-merge) × events during split (photos, texts, hearts, timer rotation ×2, removal vote with/without quorum, departure, idle lapse, final-pair attempt) → merged state identical on every member, over randomized bounded schedules under a **fixed seed**. Asserts n-way merge needs no special case. 2 iterations. | 1 | 2, 3, 5, 7 |
| 10 | **The P4 acceptance battery** (§10's acceptance line): the §16.2 matrix; the convergence property; §10.4's quorum table; §10.5's two worked examples verbatim; exactly one post-merge epoch; no content loss; no duplicate ledger commits. | 1 | 1–9 |
| 11 | **Tier 2 — a real 2/2 and 3/1 split on Simulators** (§21.2, "newly reachable but not yet run"): four sims, roster 4, split by killing the links (not the apps), traffic both sides, heal, assert one post-merge rotation and a converged derived roster on all four. | 2 | 10 |
| 12 | **Tier 2 — a real quorum removal on ≥ 3 nodes**, off the shipping verifier's arithmetic rather than `seedRemovalRecordForHarness`. **This retires `FERNLET_MESH_CHAOS_BARRED`** (§8.7 finding 6) and its test-hook-wall entry. | 2 | 5 |
| 13 | **Tier 2 — §10.5 re-gossip on the radio**: a leaver with **no tunnel to one survivor**, so the departure arrives by digest re-gossip rather than `recipients=all`. The 0b run delivered it directly over both tunnels, so this path is still uncorroborated on a radio. | 2 | 4 |
| 14 | **Tier 2 — `MeshLedgerAdoption`'s actual rebase**: a joiner admitted by a **NON-founder**, which needs a `MeshFlowDriver` change (the harness's founder admits everyone, so the rebase is a proven no-op today). | 2 | — |

### Not this phase

- **`MeshFrameReplayWindow` wiring is P5, not P4.** §8.7 finding 5 and §21.5 both assign it to P5,
  where routed content is what an attacker would replay. It is built, unwired, epoch-independent.
  Leave it alone.
- **The remaining `keyEpoch ==` gates** in `MeshNetworkManager` (photo manifest, the
  `keyEpoch >= localJoinedEpoch` filter, the encrypted-metadata wrapper) each wrongly reject content
  created in the other branch of a split — but §21.5 says retire them **with the path P5 replaces**,
  not by loosening them in place. Record any P4 test that trips over one; do not fix it here.
- **First-meeting stranger admission on QUIC** (§8.7 finding 3) — a design decision, MC until P9.
- **§17.3's `PrivacyInfo` / privacy-copy paragraph** — P3's debt, owner-carried, deadline is the
  first TestFlight build. Do not absorb it silently.

### The decisions, with defaults so nothing blocks

| Decision | Default | Why |
|---|---|---|
| **Departure delivery: a transport ack now, or P5 store-and-forward?** | **Wait for P5; make P4's merge path the recovery** (item 4) | §21.3. §8.7 finding 2: the leave awaits the local write, then stops the transport. An ack or bounded re-send is a `NetworkMeshSession` change; P5's relay exists for exactly "a frame the peer did not get". P4 owes the recovery a test anyway (§10.5). If the owner wants it sooner, the cheap half is awaiting a flush before `leaveSession()` stops the transport. |
| **Transcript `sid` binding** (§18 decision 7, §7.7 finding 1) | **Still owner-gated; still not taken** | §21.3. P4 moves no wire bytes either, so it keeps travelling — but it gets more expensive with every phase that adds a frame. Touch list: `MeshChannelIntroductionTranscript`, `canonicalBytes`, `bind(channelBindingHash:)`, the purpose doc, the framing case, the distinctness table. |
| **Does a merge re-run ingestion gates, or trust the branch that accepted first?** | **Re-run at ingestion** (item 7) | §21.3, §10.3. Records union; *content* does not get a free pass. Assert it rather than leaving it implied. |
| **Epoch head cap 8 vs roster cap 8 under nested re-splits** | **Keep 8; `mergedHeads`' limit is an assertion P4 tests, not a knob** | §21.3. A nested re-split cannot exceed everyone-alone. Past 8 is a merge bug, not a small cap. |
| **What *detects* a partition** | **§10 is silent; default: no new timer.** The existing presence/liveness signal raises `linksLost`; `partitioned` when a member the derived roster still names becomes unreachable. On-demand like `enforceSessionCeiling`/`evaluateIdleLapse` — **P7 wires the poller** (§8.7 finding 4). | §10.2 describes what a partition *does*, never what notices one. Inventing a timer here would duplicate P7's seam. |
| **Which node mints when the merged view's deterministic coordinator is not present at the merge** | **§10 is silent; default: mint from the lowest fingerprint present among the merging parties** (§10.2's branch rule), counter = max+1. A later merge supersedes with a strictly greater counter. | Converges because counters only rise and `coexist` is legal in the interim. Do not block a two-member reconnect on an absent coordinator. |
| **Is `temporarilyDisconnected` persisted?** | **§10 is silent; default: no.** Presence only — never sealed, never a record, `MeshSessionContext` schema stays 2. | §10.2 says "presence state, not a record"; persisting it would make a reversible local judgement durable and reintroduce the shape records exist to avoid. |
| **Spelling of the removal proposal/vote wire tokens, if they are new** | **§10 is silent; default: `fernlet.mesh.removal-proposal.v1` / `fernlet.mesh.removal-vote.v1`**, matching the frozen family, additive, no golden moved — and only if item 5 finds they do not already exist. | The token, the `PayloadType` case and the crypto purpose must share **one** frozen spelling or the vocabulary wall fails (§8.6). |
| **Partition UX copy** (§18.2: "N friends out of range — will sync when you reunite" vs the subtitle count only) | **Owner's, not blocking. Default: build no new copy in P4**; leave the seam and note it. | §21.4 flags §18.2 as the open decision P4 is the first phase to actually want. Shipping copy without the answer means localizing a string twice. |

---

## 4. Walls that will bite

- **The union-merge laws are already tested — do not break them.** `MeshMembershipLedger.merging(_:)`
  (P3 item 1, `cd8ea71`) is commutative, associative and idempotent **including at the caps**
  (keep-earliest-k under the records' own total order). Every P4 addition to the merge must preserve
  all three, at the cap as well as below it. Termination is **derived at read, not applied at merge**,
  for exactly this reason — do not "simplify" it into a mutation.
- **The `.merge` rotation cause fires once per merge.** P3 item 5 (`ddcc717`) gives one entry,
  `requestRotation(cause:)`, a 2-second coalescing window ranked `merge > membership > timer`. A merge
  that moves the roster mints **one** epoch, not one per record. Corollary trap: a test that seeds a
  roster *via* the merge trigger cannot then observe a membership rotation —
  `seedMembershipLedgerForTesting` exists to seed without spending it.
- **`MeshSessionContext` schema is 2.** If a merge adds persisted state, bump to **3** and treat older
  as **corrupt**, exactly as P3 item 4 (`374b1cc`) did going 1 → 2. And the five-state load holds:
  the `LoadToken` a writer needs is an associated value of `loaded`/`absent` **only**, so
  `refused`/`deferred`/`corrupt` structurally cannot `save`.
- **Durable-before-acknowledged (§3.6).** If you cannot seal, you must not acknowledge — a merged
  record, an accepted vote, a "reunited" the UI shows all sit behind a successful seal. `ColumnCrypto`
  is V3-only and **refuses** to seal without a `DeviceBindingID`; "seal refused" is not "absent".
- **`MeshGroupKey` and the keyring are never persisted.** Resume reconnects and rotates. The doc guard
  saying so is load-bearing by contrast with everything P3 made persistent.
- **No wire-format change without golden + registry + framing case together.** Any new record or frame
  needs a registered crypto domain and a framing-transcript case in
  `CryptographicPurposeBoundaryTests.canonicalSerializerTranscriptsMatchTheirDeclaredFraming`, in the
  **same commit** (the `91c3956` lesson: a declared-vs-emitted framing mismatch reached the suite as
  ~200 unexplained failures). Do **not** re-pin `PeerHandleWireGoldenTests` to make it pass — a golden
  failure is a wire decision. No crypto escape hatches; the census is honest.
- **Wipe wall.** Any new persisted surface or `UserDefaults` key owes a disposition row in
  `Docs/PrivacyWipeCoverage.md` **and** delete-all writer wiring, in the same commit. A new surface
  with no wipe row fails CI.
- **Shared-disk-root flake family.** Anything that touches disk gets a per-instance root, in the idiom
  of `MeshSessionStoreIsolationTests` / `PhotoDirectoryIsolationTests`. Suites share process-global
  disk; the family must not grow a new member.
- **Power of 10:** ≤ 60 code lines per function/`body`, bounded loops, no `!`/`try!`/`as!`/
  `fatalError`, no swallowed `try?`, no mutable globals, no nested `#if`, warnings-as-errors. A merge
  routine and a scenario-matrix generator both want to sprawl past 60 lines — split before the
  scanner does.
- **MC containment:** `TransportNeutralityBoundaryTests` permits MC types only in
  `MeshMultipeerSession.swift` / `MCPeerIDStore.swift`. Nothing new names an MC type. And remember
  0b's review lesson: relaxing a **link** gate is only safe where the transport is members-only. QUIC
  is; **MC — the shipping default — is not**, which is why `maySeatVerifiedPeer` exists.
- **Localization:** new wire tokens, `rawValue`s, `cause` strings and presence-state spellings stay
  **frozen English**; display text forks separately. `LocalizedStringKey` for UI, never `String`.
- **DocC:** every new type carries `///`; `doc-coverage-scan.py` stays at zero. Update the ProximityKit
  landing page when the partition/merge surface changes, in the same commit.

---

## 5. Three items with a design call inside

### (a) How the reconciled head is chosen from two `coexist` heads (item 3)

§10.3's rule is that **neither coexisting head wins**: the deterministic coordinator of the *merged*
view mints a strictly greater successor (counter = max+1, `cause = merge`) and both old keys die at
grace expiry. The trap is reaching for a tie-break between the two heads — lowest `epochID`, earliest
timestamp, "whichever branch was bigger". All three are wrong: an `epochID` tie-break is arbitrary,
and **anything involving a wall clock is disqualified outright** (a forged far-future stamp would pick
the winner). The choice must be a pure function of the merged derived roster and the two counters.
The one thing §10 does not say is who mints when that coordinator is not at the merge point — §3's
decisions table gives the default (lowest fingerprint present, superseded by a later merge).

### (b) What "partitioned" means for the derived roster (item 1)

**Nobody departs on a split.** `admitted − departed − removed` is unchanged by unreachability, and
§10.2 is explicit that liveness eviction while split is **local presence only — reversible, never a
membership record**. So `temporarilyDisconnected` must live somewhere the derived roster cannot see:
if a partition can shrink the roster, a 2/2 split becomes two meshes of two, quorum arithmetic
changes under everyone's feet, and `final pair` fires on a branch (§10.6 says it must not — a final
pair is judged on the **merged** roster). The P3 invariant to preserve verbatim: **disconnect ≠
removal, and it holds across a partition of any duration, including one that outlives a process.**

### (c) Delivery-target semantics for P5 (item 8)

P5's store-and-forward is defined in partition terms, so P4 owes it the vocabulary. §10.1's rule:
content is manifest-signed with the destination set = **full roster at creation time**, not the
connected set, and content keys are wrapped per recipient identity so nothing about content depends
on which partition or which epoch it was created in. The design call is the shape of the type that
says so — reachable vs unreachable is a *delivery* state, never a *destination* state, and the
distinction is what stops P5 dropping a recipient because they happened to be on the other side of a
split when the photo was taken. Get this wrong and P5 inherits it silently.

---

## 6. Stop conditions — end the loop on any of these

Call `ScheduleWakeup({stop: true})`, write the handoff (§8), and report.

1. **P4 is complete** — every item done, gauntlet green, §10 marked BUILT, P5 handoff written.
2. **Blocked on the owner** and no tier-1 work remains. Say exactly what is needed and stop; do not
   idle-wake waiting for a human. (Every §3 decision has a default, so this should not happen before
   the tier-2 items.)
3. **Fable budget is running low.** Stop with items to spare, not at zero.
4. **Context is filling.** `/loop` resumes the same context and never compacts, so a long P4 will run
   out. When the ledger is the only thing you would need to resume, stop and let a fresh session
   continue from it.
5. **A gate goes red for a reason you did not cause.** Record it, stop, report — do not spend
   iterations bisecting someone else's commit. (`sync-string-catalogs.sh --check` is **already
   known-red** on nine stale keys, §21.4 — **do not bisect it.**)

### Gauntlet — the subagent runs it; you check the marker line

```bash
python3 Scripts/power-of-10-scan.py
python3 Scripts/doc-coverage-scan.py
xcodebuild build-for-testing -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test-without-building -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FernletTests
Scripts/spm-wall-check.sh          # once anything wall-relevant moves
Scripts/spm-wall-selftest.sh       # after any change to the wall or its permit lists
```

Full `FernletTests` was **3687 green ≈ 11.4 min** at the P3 boundary and is growing — run it in
batches and check the **exit code**, never a grep for "passed". Plus, for P4 specifically: the
convergence property test must run its **fixed seed** in CI (a randomized seed is a flake generator,
not a property test), and any suite touching disk must be green in the same run as the isolation
grep-wall.

---

## 7. Ledger template

Create `Docs/Mesh-Migration-Loop-Ledger-P4.md` on iteration 1 if absent. Keep it **short** — it is
read on every wake, so every line costs orchestrator budget forever.

```markdown
# Mesh Migration Loop Ledger — P4

**Phase:** P4 (partition and merge) · **Prompt:** [Next-Round-Prompt-Mesh-P4-2026-09-02.md](Next-Round-Prompt-Mesh-P4-2026-09-02.md)
**Started:** <date> · **Iteration:** <n> · **Tree at seed:** main = `3722511` (pushed)

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`. Tier per §2.
| # | Item | Tier | Prereq | State | SHA | Note |
|---|---|---|---|---|---|---|
| 1 | Partition detection + branch-local operation (§10.2) | 1 | — | todo | | presence never a record; no new timer (P7 polls) |
| 2 | The single merge path (§10.3) on `mergeMembershipLedger` | 1 | 1 | todo | | 2–3 iters; do NOT add a second merge path |
| 3 | Divergent-epoch reconciliation, coexist → one head | 1 | 2 | todo | | successor = max+1, cause .merge, no wall clock |
| 4 | §10.5 re-gossip + departure recovery at merge | 1 | 2 | todo | | owner's worked example verbatim |
| 5 | Quorum under partition (§10.4), rosters 2–8 | 1 | 1 | todo | | check if proposal/vote records exist first |
| 6 | Termination + development under partition (§10.6) | 1 | 1, 5 | todo | | final pair = MERGED roster |
| 7 | Content merge: order, dedup, gates re-run at ingestion | 1 | 2 | todo | | |
| 8 | Delivery-target semantics for P5 (§10.1) | 1 | 1 | todo | | design call §5c |
| 9 | §16.2 convergence property test, fixed seed | 1 | 2,3,5,7 | todo | | 2 iters |
| 10 | P4 acceptance battery | 1 | 1–9 | todo | | |
| 11 | Tier 2: real 2/2 and 3/1 split, 4 sims | 2 | 10 | todo | | STAGGER=1, re-harvest identities |
| 12 | Tier 2: real quorum removal ≥ 3 nodes | 2 | 5 | todo | | retires FERNLET_MESH_CHAOS_BARRED |
| 13 | Tier 2: §10.5 re-gossip on the radio | 2 | 4 | todo | | leaver with no tunnel to one survivor |
| 14 | Tier 2: MeshLedgerAdoption rebase, non-founder admitter | 2 | — | todo | | needs a MeshFlowDriver change |

## Blocked on owner
- Departure-delivery ack vs P5 recovery (§21.3) — default: P5; P4 asserts the merge recovery.
- Transcript-`sid` move (§18 decision 7) — still owner-gated; P4 moves no wire bytes either.
- §18.2 partition UX copy — the first phase that actually wants it.
- §17.3 `PrivacyInfo` / privacy-copy paragraph — P3's debt, deadline = first TestFlight.

## Decisions taken (defaults from §3 unless the owner overrides)
| Decision | Choice | Taken on |
|---|---|---|
| Departure delivery | (default: wait for P5, assert merge recovery) | — |
| Merge re-runs ingestion gates | (default: yes) | — |
| Epoch head cap 8 | (default: assertion, not a knob) | — |
| Partition detection mechanism | (default: no new timer; P7 polls) | — |
| Minting coordinator absent at merge | (default: lowest fingerprint present) | — |

## Surprises worth not re-deriving
- (carry the P3 lessons below until they stop earning their place)

## Next item
1
```

**Lessons carried from P3 — seed the surprises list with these so P4 does not re-learn them:**
- **`LoadToken` is an associated value of `loaded`/`absent` only** — `refused`/`deferred`/`corrupt`
  structurally cannot `save`. Durable-before-acknowledged is enforced by the type system.
- **`isSessionOpen` gates *members*, not *links*** (0b, `871b7ee`). `mayLinkToDiscoveredPeers` is the
  link gate. Relaxing a link gate is only safe on a members-only transport: QUIC is, **MC is not** —
  hence `maySeatVerifiedPeer` in `checkCoordinatorStates` before any descriptor goes out.
- **A joiner's bootstrap root is its ADMITTER's key, not the founder's**; `MeshLedgerAdoption.adopt`
  rebases from the self-admitted root. On a pair the admitter *is* the founder, so the rebase is an
  unproven no-op — item 14 is the first thing that exercises it.
- **`.merge` outranks `.membership` outranks `.timer`** in a 2 s coalescing window; a merge-seeded
  test cannot then observe a membership rotation (`seedMembershipLedgerForTesting`).
- **The keyring stamps supersession INSIDE the rotation** whose drain waits ~10 s for acks a fake
  never sends — bracket grace assertions accordingly.
- **`PayloadType` is switched only with `default`** (manager + coordinator), so the clean-build
  non-exhaustive-switch hazard does not apply to adding a case.
- **Harness gotchas:** `STAGGER=1`; re-harvest identities after any `xcodebuild test`; fresh log dir
  per run; `pgrep xcodebuild` before believing a failure; a bare-integer link key is the reliable
  negative (browsed name only means "this side browsed that peer").
- **Instrument the wire before believing an inference** — a negative read off an *accessor* is not a
  negative observed on the wire; "never arrived" and "arrived and refused" read identically without
  an echo.
- **`/loop` never compacts between iterations** → fresh session per phase; the ledger is the only
  durable state; the §0 orchestrator contract is what made P3 twelve iterations with zero crossed logs.
- **Closed; do not re-audit:** `MeshTunnelConvergence`, the id-vs-endpoint family (`96337a3`,
  `2f273a9`), and the crypto-purpose / `PayloadType` / record-kind spellings (walled).
- Concurrent sessions share this tree and sim fleet; `Localizable.xcstrings` + `xcschememanagement.plist`
  are held by another session — never stage them.

---

## 8. Close-out, when P4 is done

1. Mark P4 **BUILT** in §10 of the plan with landing SHAs, in the §7/§8 format.
2. Record deviations from the sketch and why (§8.6 is the model) — say where §10 was silent and what
   default you took.
3. Record findings you deliberately did NOT fix, with what they cost, the way §8.7 does.
4. Memory note: what landed, what surprised you, what the next session must not re-derive.
5. Write the **P5 handoff block** (a new §22, in the §20/§21 format). P5 is encrypted store-and-forward
   routing. Hand it: item 8's delivery-target semantics, the merge path as the drain's model
   (reconnect ≡ merge ≡ relay drain), `MeshFrameReplayWindow` built-and-unwired, the three
   `keyEpoch ==` gates that must retire **with** the path P5 replaces rather than be loosened, and the
   three-node sim lane now that 0b is fixed.
6. Note anything P4 learned that re-tiers P5–P7 further.

---

## 9. The road to TestFlight

The owner's goal is the whole migration before the first TestFlight build. After P4, five phases remain.

| Session | Phase | Prerequisite |
|---|---|---|
| P2 (done) | NetworkMeshSession over QUIC | built + proven sim↔sim |
| P3 (done) | durable context, roster, membership | built (`ed3c193` battery, 3687 green); **0b FIXED (`871b7ee`) — three sims form a full mesh** |
| **this** | **P4** — partition + merge | P3. Tier 1 on `FakePeerNetwork`; tier 2 corroborates on 3–6 sims. |
| +1 | **P5** — encrypted store-and-forward routing | P4 (delivery targets are defined in partition terms). Wires `MeshFrameReplayWindow`; retires the `keyEpoch ==` gates. |
| +2 | **P6** — feature routing (photos, text, hearts) | P5. Also unlocks the hearts/moderation ceremonies P2 could not reach. |
| +3 | **P7** — app-layer run policy | P3's states; **mostly wiring** — `.developed`/`.backgrounded`/`.foregrounded` plus a poller for `enforceSessionCeiling`/`evaluateIdleLapse`. Can interleave earlier. |
| +4 | **P8** — background continuation | **§15 gates: physical devices, multi-hour soaks, Low Power Mode, battery — irreducibly physical.** First hardware sample: iOS ended a user-started continued-processing task ≈ **46 s** in, after backgrounding — that is P8's number, not P4's. |
| +5 | **P9/P10** — remaining radios, MC retirement (iOS 27), companion `BGAppRefreshTask` | P2 proven in the field. |

**The re-tier holds through P6 and not into P8.** With 0b fixed, the sim lane carries three-node
membership, partition and (for P5) a relay drain across a real split. P8's background/battery/thermal
gates are the one thing that still needs the phone drawer and the multi-hour soaks TestFlight does
not supply.

**Still owed by the owner, not blocking P4** (§21.4):
- **Lane D** — the production transport over Wi-Fi with the **cable OUT** (Xcode → Devices and
  Simulators → *Connect via network*). This is now an observed hazard, not a precaution: in the
  2026-09-02 runs the second tunnel came up over the **USB** path (`anpi0`/`en8`) while the first ran
  over Wi-Fi, and the phone refused the duplicate dials arriving on the other path. Check afterwards
  that no ready line names a USB-side interface.
- **AWDL** — item 11 has split: the **Local Network prompt half is observed granted** (the phone
  browsed and found the Simulator, which it cannot otherwise do), so Lane D's permission row is
  "confirm, not discover". The **AWDL half is still owed** — both ends of the 2026-09-02 runs sat on
  the same infrastructure Wi-Fi (`en0`), and peer-to-peer being *requested* in the parameters is not
  evidence a peer-to-peer radio carried anything.
- **The one-line `sync-string-catalogs.sh` write** on a quiet tree (nine stale keys). Known-red, and
  **do not bisect it.**
- **The `HeartDrop` CloudKit record type is missing from the container** — owner-side schema, not code.
- **§17.3's `PrivacyInfo` / privacy-copy paragraph** by the first TestFlight build: serverless +
  E2EE, nearby Fernlet devices may briefly hold ciphertext they cannot read, background continuation
  uses local network and battery and iOS may end it, content clears by development/session rules.
- Also outstanding: the double-dial collapse's Lane B row (§7.7 finding 6), and **downgrade
  `browsed peers=` from `.notice`/`.public`** before QUIC ships (it prints nearby Bonjour instance
  names).
