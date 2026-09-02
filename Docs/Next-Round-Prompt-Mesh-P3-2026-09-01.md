# Loop Prompt — ProximityKit Network Migration: P3 (durable session context, roster, membership)

**Written:** 2026-09-01, at the P2 boundary (main = `801e34f`, pushed).
**Plan:** [Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md](Plan-ProximityKit-Network-Migration-2026-08-27.md) — the authority. **§8 is the P3 specification; §20 is the handoff.** This file is the launcher and the loop contract.
**Ledger:** [Docs/Mesh-Migration-Loop-Ledger-P3.md](Mesh-Migration-Loop-Ledger-P3.md) — the loop's memory, created on iteration 1 (§7). It lives on disk, not in context. The P2 ledger is a finished record; **do not reuse it.**
**Scope:** build **P3** — the derived roster, the sealed `MeshSessionContext` store, membership events + membership-driven rotation, the epoch model, and pointing `MeshIntroductionAuthority` at the derived roster. **Stop the loop at the P3 boundary.**

---

## How to start

```
/loop Read Docs/Next-Round-Prompt-Mesh-P3-2026-09-01.md and run one iteration of it.
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

1. **Read the ledger.** `Docs/Mesh-Migration-Loop-Ledger-P3.md`. On iteration 1, create it from §7's
   template, seeded with the ten items below. Thereafter it is already seeded — go straight to the
   next item.
2. **Check the tree is safe to build on** — first iteration, or after any owner activity:
   ```bash
   git -C . log --oneline -1; git -C . status --porcelain
   ```
   Another session has long held `App/Fernlet/Localizable.xcstrings` (a large foreign diff) and a
   personal `xcschememanagement.plist`. **Leave both alone**; never stage them. Commit with explicit
   pathspecs, never `git add -A`.
3. **Pick the next item** whose prerequisites are met, from §3's list, in ledger order. Prefer a
   **tier-1** item (no radio) over a tier-2 one — see §2.
4. **Dispatch one subagent** with the item's full context: the acceptance criterion, the walls it must
   not trip (§4), the D4 sealing constraint if it touches the store, and that it must run the gauntlet
   subset for what it touched (§6).
5. **Verify** — grep the marker line out of its build/test log yourself. Do not take "it passed" on
   trust; this repo has notified a failed build as exit 0, and a crossed log has shown ~20 phantom
   failures under concurrent-session contention.
6. **Commit** with explicit pathspecs (note `git mv` stages a rename immediately, so check
   `git diff --cached --name-status` first).
7. **Update the ledger**: item → done, with the SHA, one line on anything surprising, the next
   unblocked item, and any new sub-item the work exposed.
8. **Schedule the next wake**, or stop per §6.

---

## 2. Testing strategy — the phone drawer is gone (re-tiered 2026-09-01)

**P2 proved the simulator lane carries far more than the plan first assumed** (§7.8): two Simulators
on one Mac complete real Bonjour + QUIC/TLS + the signed introduction, QUIC **datagrams work** (the
old "usable frame size 0" was a misread accessor, not a negotiation failure), and six app flows run
over the real transport. P3 inherits that. **P3 does not need a drawer of phones.**

| Tier | What it proves | Cost |
|---|---|---|
| **1 — no radio** | The records algebra (`admitted − departed − removed`, union-merge, the §9 bounds), the §8.2 state machine on `FakeMeshTransportSession`, the epoch acceptance rule, rotation triggers, the sealed store's five-state load — all on `FakePeerNetwork` + `VirtualClock`. **If a check CAN live here, it MUST.** | Free, deterministic, CI. |
| **2 — sim↔sim MULTI-NODE** | 3–6 Simulators on one Mac through the Lane C harness (`FERNLET_MESH_TRANSPORT` / `_MATRIX` / `_FLOWS` / `_CONSOLE_LOG` + the chaos hooks): roster convergence, a departure gossiped by a *third* member (§10.5), admission across a live roster, rotation crossing two tunnels, a removal ejecting a peer at its next connect. **This is the default for anything wanting real nodes.** | One Mac, `simctl`, minutes per run. |
| **3 — physical devices** | Only §15's hardware gates: AWDL, the Local Network prompt, background/locked, battery, thermal. **P3 owes tier 3 nothing** — every membership check is tier 1 or 2. | Owner's time; not this phase. |

Flake protocol, hard-won across P2 — obey it:
- `The test runner hung before establishing connection` is a Simulator flake. If the destination sim
  is **already Booted**, a plain retry clears it; `simctl boot` is a no-op then. Boot + ~20 s settle
  **before** `xcodebuild` only when the sim is not yet booted. `simctl shutdown all` did NOT cure it.
- Use a **fresh log path per `xcodebuild` run**, and `pgrep xcodebuild` before believing any failure —
  a concurrent session shares this Mac's sim fleet, and a crossed log once showed ~20 phantom
  `FernletLock*`/`SecureEnclaveWrap*` failures that vanished uncontended.
- The full suite resets sim app state — any Lane C script must **re-harvest identities after an
  `xcodebuild test` run**.

### Item 0 — the multi-node bring-up, before you rely on it

Item 0 (P2) proved *two* Simulators connect and item 10 drove app flows across a pair, but **no
membership test has ever run ≥ 3 real nodes**, and P3's whole tier-2 story assumes it. **Bring up
three Simulators through the Lane C harness and confirm a three-node roster converges** (each sees the
other two; a departure by one is seen by both survivors) **before** writing any test that depends on
it. Timeboxed to one iteration.

- **If it converges:** record it as a first-class capability and the tier-2 items proceed.
- **If it does not:** record *exactly* where it broke (discovery, dial fan-out, the tie-breaker across
  three `sid`s, harness seeding) so the tier-2 items can be re-planned onto pairs or fixed. One
  iteration, then move on — do not let the bring-up become the phase.

---

## 3. The work list

Ledger order, respecting §20.4 ("records → store → rotation → authority"). Each is one iteration
unless noted; the store and the rotation/epoch work will each take 2–3.

| # | Item | Tier | Prereq |
|---|---|---|---|
| 0 | **Multi-node sim bring-up** (§2): 3 Simulators through Lane C, prove a 3-node roster converges. Timeboxed. | 2 | — |
| 1 | **Records + derived roster, pure, tier 1** (§8.1, §20.4.1): `admitted − departed − removed`, union-merge, the §9 bounds. **No storage, no transport, no clock.** Everything later consumes this. | 1 | — |
| 2 | **The sealed `MeshSessionStore`** (§8.1, §20.4.2): new keychain key role beside `friendWall`, `.completeUntilFirstUserAuthentication`, the **FIVE-state load** (loaded / absent / deferred / corrupt / **refused** — see §5, the D4 design call), a **per-instance disk root + grep-wall test** à la `PhotoDirectoryIsolationTests`, and the **§17.3 paperwork in the same commit**. 2–3 iterations. | 1 | 1 |
| 3 | **Membership event wire tokens** (§8.3): `member-departure.v1`, `terminated.v1`, `inventory-digest.v1`; legacy `sessionGoodbye` **parsed-not-emitted**; grow-only records, caps per §9. Moves signed bytes — golden vectors + registry + framing test together (§5). | 1 | 1 |
| 4 | **Epoch model** (§8.4): `MeshEpochRef` (Lamport counter, cap 4096), bounded keyring (current + ≤ 3 predecessors, ≤ 5 min grace), the acceptance rule, divergent-same-counter coexistence, replay protection moved **off** epochs. **Tighten the soft epoch gate to strict** at the source comparison (§20.1). | 1 | 3 |
| 5 | **Membership-driven rotation** (§8.3): triggers become **15-min timer ∪ any roster change ∪ any merge**; add the `cause` token (`timer`/`membership`/`merge`); exclude removed/departed from the new epoch's key distribution. Closes the confirmed voted-out-member-keeps-key-for-15-min gap. | 1 | 3, 4 |
| 6 | **State machine** (§8.2) on `FakeMeshTransportSession`: every edge; `hardDeadline` at both bounds (signed absolute + local monotonic guard); disconnect ≠ removal; idle-lapse resume IS the merge path; developed/terminated never rejoin. | 1 | 2 |
| 7 | **Point `MeshIntroductionAuthority` at the derived roster** (§20.4.4): the manager answers from `admitted − departed − removed`; `SignedRemovalRecord`s give `barred` real contents, making matrix row 3 (`barredMember`) the shipping authority's own answer instead of a chaos hook's. | 1 | 1, 2, 5 |
| 8 | **The P3 acceptance battery** (§8.4 acceptance list): every state edge; disconnect ≠ removal; idle-lapse resume; ceiling at both bounds; rotation on removal/departure/merge with old-key rejection after grace; the load/deferred/corrupt/**refused** matrix; legacy `sessionGoodbye` interop. | 1 | 2, 4, 5, 6, 7 |
| 9 | **Multi-node membership at tier 2** (Lane C, 3–6 sims): a departure gossiped by a third member (§10.5 propagation), admission across a live roster, rotation crossing two tunnels, a removal ejecting a peer at its next connection. | 2 | 0, 7 |

### The decisions, with defaults so nothing blocks

| Decision | Default | Why |
|---|---|---|
| Bind `sid` — and finalize `epochRef` — into the signed introduction transcript (a **transcript v2**) | **Yes, once, in item 3/4, golden vectors updated deliberately** | P3 is where `epochRef` stops being a placeholder, so the transcript is moving anyway (§20.5). Moving signed bytes once is far cheaper than twice; the P2 finding was that `sid` rides an *unsigned* hello field (§7.7 finding 1, §18 decision 7). **Owner-confirm before the move** — it is a wire-format change. |
| Tighten the epoch gate to **strict** once §8.4's merge rule exists | **Yes, at the source comparison (item 4)** | The soft rule (equal-or-one-empty) existed only because a joiner holds no key; §8.4 is precisely what lets it tighten. Flagged in source at the comparison. |
| Publish `fp` in the QUIC TXT record | **No — unless the transcript is already moving in item 3/4, then bundle it** | Still moves signed bytes with a golden vector attached (§19.4). If item 3/4 is opening the wire format anyway, bundling is the cheap moment; otherwise defer past P3. |

---

## 4. Walls that will bite

- **D4 sealing (§20.2) — the cross-cutting constraint of this phase.** `ColumnCrypto` is V3-only and
  **refuses to seal** without a `DeviceBindingID` (`SealedColumnStrictSealError.bindingUnavailable`).
  A sealed `MeshSessionContext` **cannot be written before first unlock** — not slower, not retried,
  *refused*. **"Seal refused" is not "absent"**: an `absent` that is really a refusal is the shape
  that overwrites live data, so the four-state load owes a fifth consideration. And **durable-before-
  acknowledged (§3.6): if you cannot seal, you must not acknowledge** — every custody receipt, every
  accepted membership record, every "joined" the UI shows sits behind a successful seal, because
  force-quit gives no callback to save you afterwards.
- **Wipe wall — now load-bearing.** P3 persists sealed data for the first time. `MeshSessionContext`,
  `MeshRoutedStore` (P5, but its key lands here if touched), the endpoint cache, and any new
  `UserDefaults` key each owe a disposition row in `Docs/PrivacyWipeCoverage.md` **and** delete-all
  writer wiring, in the same commit (§17.3). A new persisted surface with no wipe row fails CI.
- **Shared-disk-root flake family.** The store gets a **per-instance disk root** and a grep-wall test
  in the idiom of `PhotoDirectoryIsolationTests`. Suites share process-global disk; the flake family
  must not grow a new member.
- **Power of 10:** ≤ 60 code lines per function/`body`, bounded loops, no `!`/`try!`/`as!`/
  `fatalError`, no swallowed `try?`, no mutable globals, no nested `#if`, warnings-as-errors. A state
  machine and a five-state loader both want to sprawl past 60 lines — split before the scanner does.
- **Golden vectors + crypto purposes.** The membership tokens and any transcript change move signed
  bytes. New signature purposes (`member-departure`, `terminated`, `inventory-digest`, `removal`)
  each need a **registered domain** and a framing-transcript case in
  `CryptographicPurposeBoundaryTests` — change serializer, registry and framing test **together**
  (the `91c3956` lesson: a declared-vs-emitted framing mismatch reached the suite as ~200 unexplained
  failures). Do **not** re-pin `PeerHandleWireGoldenTests` to make it pass — a golden failure is a
  wire decision. **Do not reach for a crypto escape hatch**; the census is honest and P2 already spent
  the one (`x509-self-signature`) that had no domain to name.
- **MC containment:** `TransportNeutralityBoundaryTests` permits MC types only in
  `MeshMultipeerSession.swift` / `MCPeerIDStore.swift`. Nothing new names an MC type.
- **Localization:** the new wire tokens (`fernlet.mesh.member-departure.v1`, etc.), `rawValue`s and
  the `cause` strings stay **frozen English**; display text forks separately. `LocalizedStringKey`
  for UI, never `String`.
- **DocC + the §17.3 reversal.** Every new type carries `///`; `doc-coverage-scan.py` stays at zero.
  P3 is the commit that reverses "deliberately NOT Codable" / "memory-only, never persisted" — so the
  ProximityKit landing page and the `MeshSessionTypes` / `SessionMessageStore` / `MeshGroupKey` doc
  guards get **rewritten in the same commits** (§17.3), not after. The `MeshGroupKey` doc stays "never
  persisted" and becomes load-bearing by contrast.

---

## 5. Two items with a design call inside

### The sealed store's fifth state (item 2)

Invariant 7's load is four states — loaded / absent / deferred / corrupt. D4 forces a fifth:
**refused** (the binding is unavailable, e.g. before first unlock). The trap is collapsing it into
`absent`, because a consumer that reads `absent` as "no prior context, start fresh" will **overwrite
live sealed data** the moment the device unlocks. Design the fifth state so a refusal names what it
refused and no writer treats it as a green field. This is the item where "seal refused ≠ deferred ≠
absent" earns its own type, its own tests, and a line in the ProximityKit landing page.

### The transcript move (items 3–4)

`epochRef` stops being a placeholder in P3, so the signed introduction transcript is going to change.
If it changes, change it **once**: decide up front (per §3's decision table, owner-confirmed) whether
`sid` is bound in the same move, update the golden vectors deliberately, and add the framing case to
`CryptographicPurposeBoundaryTests.canonicalSerializerTranscriptsMatchTheirDeclaredFraming` in the
same commit. Two separate wire-format churns — one for `epochRef`, one later for `sid` — is the
expensive path §20.5 warns against. `CanonicalByteWriter` is the reviewed serializer; the exporter
label `KeyDerivation.meshTLSExporterV1` stays distinct from the probe's.

---

## 6. Stop conditions — end the loop on any of these

Call `ScheduleWakeup({stop: true})`, write the handoff (§8), and report.

1. **P3 is complete** — every item done, gauntlet green, plan marked BUILT, P4 handoff written.
2. **Blocked on the owner** and no tier-1 work remains. Say exactly what is needed and stop; do not
   idle-wake waiting for a human. (The transcript-`sid` decision is the likely blocker — if the owner
   has not confirmed it, do every item that does not depend on the wire move first.)
3. **Fable budget is running low.** Stop with items to spare, not at zero.
4. **Context is filling.** `/loop` resumes the same context and never compacts, so a long P3 will run
   out. When the ledger is the only thing you would need to resume, stop and let a fresh session
   continue from it.
5. **A gate goes red for a reason you did not cause.** Record it, stop, report — do not spend
   iterations bisecting someone else's commit. (`sync-string-catalogs.sh --check` is already known-red
   on nine stale keys — §20.6 — do not bisect it.)

### Gauntlet — the subagent runs it; you check the marker line

```bash
python3 Scripts/power-of-10-scan.py
python3 Scripts/doc-coverage-scan.py
xcodebuild build-for-testing -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test-without-building -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FernletTests
Scripts/spm-wall-check.sh          # once anything wall-relevant moves
Scripts/spm-wall-selftest.sh       # after any change to the wall or its permit lists
```

Plus, for P3 specifically: the new sealed-store **isolation grep-wall test** and the **wipe-coverage**
test must be green in the same run that touches the store. Full suite is now ≈ 3400+ tests and growing
— run it in batches, check the **exit code**, never a grep for "passed".

---

## 7. Ledger template

Create `Docs/Mesh-Migration-Loop-Ledger-P3.md` on iteration 1 if absent. Keep it **short** — it is
read on every wake, so every line costs orchestrator budget forever.

```markdown
# Mesh Migration Loop Ledger — P3

**Phase:** P3 (durable session context, roster, membership) · **Prompt:** [Next-Round-Prompt-Mesh-P3-2026-09-01.md](Next-Round-Prompt-Mesh-P3-2026-09-01.md)
**Started:** <date> · **Iteration:** <n> · **Tree at seed:** main = `801e34f` (pushed)

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`. Tier per §2.
| # | Item | Tier | Prereq | State | SHA | Note |
|---|---|---|---|---|---|---|
| 0 | Multi-node sim bring-up (3 nodes) | 2 | — | todo | | de-risks every tier-2 item |
| 1 | Records + derived roster, pure | 1 | — | todo | | foundation; no storage/transport/clock |
| 2 | Sealed MeshSessionStore (5-state, per-instance root, §17.3) | 1 | 1 | todo | | 2–3 iters; D4 design call |
| 3 | Membership event wire tokens | 1 | 1 | todo | | moves signed bytes |
| 4 | Epoch model §8.4 + tighten the gate | 1 | 3 | todo | | |
| 5 | Membership-driven rotation | 1 | 3, 4 | todo | | closes voted-out-keeps-key gap |
| 6 | State machine §8.2 on the fake | 1 | 2 | todo | | |
| 7 | IntroductionAuthority → derived roster | 1 | 1, 2, 5 | todo | | makes matrix row 3 shipping |
| 8 | P3 acceptance battery | 1 | 2,4,5,6,7 | todo | | |
| 9 | Multi-node membership at tier 2 | 2 | 0, 7 | todo | | Lane C, 3–6 sims |

## Blocked on owner
- Transcript-`sid` / `epochRef` move (§3 decision, §18 decision 7) — confirm before the wire changes.

## Decisions taken (defaults from §3 unless the owner overrides)
| Decision | Choice | Taken on |
|---|---|---|
| Bind `sid`+`epochRef` in transcript v2 | (default: yes, once) | — |
| Epoch gate strict after §8.4 | (default: yes) | — |
| Publish `fp` in TXT | (default: no unless bundled) | — |

## Surprises worth not re-deriving
- (carry the P2 lessons below until they stop earning their place)

## Next item
0
```

**Lessons carried from P2 — seed the surprises list with these so P3 does not re-learn them:**
- Instrument the wire before believing an inference; a negative read off an *accessor* is not a
  negative observed on the wire (the datagram fortnight, the churn misread).
- The Lane C harness exists (`FERNLET_MESH_MATRIX`/`_FLOWS`/`_CONSOLE_LOG` + chaos) — reuse it, don't
  rebuild it. It commits **both** proximity gates (a sim `NIRangingSession` claims hardware).
- One contiguous write per QUIC frame is load-bearing (two awaited sends desync a shared stream).
- A hard-killed QUIC peer sends no `CONNECTION_CLOSE`, so a survivor refuses re-dials until its idle
  timer — bounded, self-healing, not a leak.
- `/loop` never compacts between iterations → fresh session per phase; the ledger is the only durable
  state.
- The id-vs-endpoint family and `MeshTunnelConvergence` are **closed** (`2f273a9`, `96337a3`) — the
  first has an exhaustive audit table in its commit message. Do not re-audit.
- Concurrent sessions share this tree and sim fleet; `Localizable.xcstrings` is held by one of them.

---

## 8. Close-out, when P3 is done

1. Mark P3 **BUILT** in §8 of the plan with landing SHAs, in the §5/§6/§7 format. Deviate from the
   sketch where reality required it and say why (§6.2 / §7.6 are the model).
2. Record findings you deliberately did NOT fix, with what they cost, the way §6.4 / §7.7 do.
3. Memory note: what landed, what surprised you, what the next session must not re-derive.
4. Write the **P4 handoff block** (a new §21, in the §19/§20 format). P4 is partition and merge
   (§10), built on `FakePeerNetwork` — no hardware. Hand it: the derived roster and union-merge P3
   built, the `MeshEpochRef` and its divergent-same-counter coexistence, the membership records that
   propagate by re-gossip (§10.5), and the sim↔sim multi-node lane for split/merge tests.
5. Note anything P3 learned that re-tiers P4–P6 further.

---

## 9. The road to TestFlight

The owner's goal is the whole migration before the first TestFlight build. After P3, six phases remain.

| Session | Phase | Prerequisite |
|---|---|---|
| P2 (done) | NetworkMeshSession over QUIC | built + proven sim↔sim; owner owes Lane D (Wi-Fi) + item 11 |
| **this** | **P3** — durable context, roster, membership | D4 sealing (§20.2); §17.3 paperwork is part of the phase |
| +1 | **P4** — partition + merge | P3. `FakePeerNetwork`, no hardware. |
| +2 | **P5** — encrypted store-and-forward routing | P4 first (delivery targets are defined in partition terms). |
| +3 | **P6** — feature routing (photos, text, hearts) | P5. Also unlocks the hearts/moderation ceremonies P2 could not reach. |
| +4 | **P7** — app-layer run policy | P3's states; can interleave earlier. |
| +5 | **P8** — background continuation | **§15 gates: physical devices, multi-hour soaks, Low Power Mode, battery — irreducibly physical.** |
| +6 | **P9/P10** — remaining radios, MC retirement (iOS 27), companion `BGAppRefreshTask` | P2 proven in the field. |

**The re-tier holds for P3–P6 but not P8.** Item 0's sim↔sim lane and P2's harness absorb membership,
partition, routing and feature testing onto one Mac. P8's background/battery/thermal gates (§15) are
the one thing that still needs the phone drawer and the multi-hour soaks TestFlight does not supply.

**Still owed by the owner, not blocking P3** (§20.6): Lane D (production transport over Wi-Fi, cable
unplugged — settles the reconnect-after-idle question and the run-3 device freeze at once), AWDL + the
Local Network prompt (item 11), the double-dial collapse's Lane B row, and the one-line
`sync-string-catalogs.sh` write on a quiet tree (do not bisect it).
