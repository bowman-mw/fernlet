# Loop Prompt — ProximityKit Network Migration: P5 (encrypted store-and-forward routing)

**Written:** 2026-09-03, at the P4 boundary (main = `6bc98ee`, pushed).
**Plan:** [Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md](Plan-ProximityKit-Network-Migration-2026-08-27.md) — the authority. **§11 is the P5 specification; §22 is the handoff; §16.2/§11's own testing-lane paragraph is the acceptance.** This file is the launcher and the loop contract.
**Ledger:** [Docs/Mesh-Migration-Loop-Ledger-P5.md](Mesh-Migration-Loop-Ledger-P5.md) — the loop's memory, created on iteration 1 (§7). It lives on disk, not in context. The P4 ledger is a finished record; **do not reuse it.**
**Scope:** build **P5 increment 1** — `MeshRoutedManifest`/`MeshChunk`/`MeshCustodyReceipt`/`MeshRecipientReceipt`, the routed content digest, the drain wired onto the one merge path (reconnect ≡ merge ≡ relay drain), custody-transfer-on-departure (the load-bearing case §10.6 needs), backpressure, locked-device handling, the type-token registry, `MeshFrameReplayWindow` wired against content ids, retirement of the three `keyEpoch` gates with the path they replace, and the tier-1 battery for all of it. **Increment 2 (live third-party relay of in-flight chunks) is explicitly not this phase** — §11 gates it on device measurements. **Stop the loop at the P5 boundary.**

---

## How to start

```
/loop Read Docs/Next-Round-Prompt-Mesh-P5-2026-09-03.md and run one iteration of it.
```

Self-paced (no interval): the work is build-and-test-bound, not clock-bound, so the loop wakes when
work completes, not on a timer.

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
of lines of file content — that ratio is the whole point.

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
   fix as its *own commit* is fine, as P4's 2c/2d did beside a property-test iteration.)
4. **Write state to the ledger, not to your own memory.** `/loop` resumes the *same* context and
   never compacts between iterations, so anything you keep in your head is paid for again on every
   subsequent turn and is lost if the session ends. The ledger is the only durable state.
5. **Stop early rather than run out.** See §6. A clean handoff is cheap; a loop that dies mid-item is
   expensive to reconstruct. When the ledger is the only thing a fresh session would need to resume,
   that is the moment to stop.
6. **When a close-out step needs synthesis across many verified facts (marking a phase BUILT, writing
   a handoff), use a small Workflow** — draft → adversarial two-lens verify → apply — rather than one
   long inline agent call. P4's close-out did this in 9 agents and caught 51 real corrections; its
   single-shot apply step also 529-overloaded three times on a 40k-character inline prompt before
   succeeding with file-based inputs. Keep apply-step prompts short by writing drafts/corrections to
   scratch files first.

### If the budget runs out mid-phase

Stop the loop, write the handoff (§6/§8), and say plainly what is left. Do not silently degrade into
doing the work yourself — that is exactly how the budget disappears.

---

## 1. Each iteration, in order

1. **Read the ledger.** `Docs/Mesh-Migration-Loop-Ledger-P5.md`. On iteration 1, create it from §7's
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
   **tier-1** item over a tier-2 one — see §2.
4. **Dispatch one subagent** with the item's full context: the acceptance criterion, the walls it must
   not trip (§4), and that it must run the gauntlet subset for what it touched (§6).
5. **Verify** — grep the marker line out of its build/test log yourself. Do not take "it passed" on
   trust; this repo has notified a failed build as exit 0, a crossed log has shown ~20 phantom
   failures under concurrent-session contention, and an interrupted-mid-run log has no markers at all
   (check the log's mtime is after the last source edit, and that a build succeeded after it).
6. **Commit** with explicit pathspecs (note `git mv` stages a rename immediately, so check
   `git diff --cached --name-status` first).
7. **Update the ledger**: item → done, with the SHA, one line on anything surprising, the next
   unblocked item, and any new sub-item the work exposed.
8. **Schedule the next wake**, or stop per §6.

---

## 2. Testing strategy (§11's own testing-lane paragraph, re-tiered 2026-09-01, §7.8)

| Tier | What it proves | Cost |
|---|---|---|
| **1 — no radio** | **Custody, receipts, dedup, backpressure and the drain.** Manifest/chunk/receipt shapes, the type-token registry, custody-transfer-on-departure, the merge-window redesign, `MeshFrameReplayWindow` against content ids, locked-device state transitions, and a property-test extension (§3 item 14) asserting every outstanding delivery reaches `delivered` or a closed state under a bounded schedule, no content lost, no double-counted receipt. All on `FakePeerNetwork` + `FakeMeshTransportSession` + an injected clock, **no wall-clock sleeps**. **If a check CAN live here, it MUST.** P4's tier 1 already carries up to eight managers on the fake fabric — extend `MeshScheduleGenerator` with custody/receipt events rather than build a parallel rig. | Free, deterministic, CI. |
| **2 — sim↔sim, real QUIC, 3–6 Simulators** | **The questions that are genuinely about a real radio: chunk pacing at 256 KiB, whether a large transfer starves the control stream, and therefore whether increment 2 (live relay) is needed at all.** P2 already moved photo chunks on per-transfer streams across this lane in both directions — reuse `MeshTransferStreamTable`, not a new transport. Same Lane C harness, seams and env hooks P3/P4 corroborated on (`FERNLET_MESH_ROLE`, `armFounderLedgerForHarness()`, `MeshFlowDriver`, `threerun.sh`). | One Mac, `simctl`, minutes per run. |
| **3 — physical devices** | Only §15's hardware gates. **P5 owes tier 3 nothing.** | Owner's time; not this phase. |

Lane gotchas carried from P3/P4 — obey them, they are all paid for:
- **Launch the sims ~1 s apart (`STAGGER=1`)**; always re-harvest identities after any `xcodebuild
  test` run.
- **A fresh log directory per run**, and `pgrep xcodebuild` before believing any failure.
- `The test runner hung before establishing connection` hits the **first** invocation after every
  build; a plain retry clears it. Budget two invocations (~13 min each) per full gauntlet run.
- A two-node Lane C run with `FERNLET_MESH_LEAVE_AFTER` now emits `terminated.v1`, not
  `member-departure.v1` (three-node runs unaffected) — items 11–13 (tier-2, still owed from P4) must
  expect it.

---

## 3. The work list

Ledger order. Each is one iteration unless noted.

| # | Item | Tier | Prereq |
|---|---|---|---|
| 1 | **`MeshRoutedManifest` + `MeshRecipientKeyWrap`** (§11): item ID, type token, content hash, size, immutable destination set = `MeshDeliveryTarget`'s roster-at-creation (P4 item 8 — do not re-derive it from the connected set), expiry = `hardDeadline` (already signed on `MeshSessionContext`, `createdAt + 6h`) + 20-minute development grace, per-recipient X25519 key wrap of a random content key. Origin-signed; relays forward the origin's exact signed bytes, never re-sign. New wire family, full trio. | 1 | — |
| 2 | **`MeshChunk`** (≤ 256 KiB, explicit index/count, per-chunk hash) on P2's existing per-transfer stream lane (`MeshTransferStreamTable`) — do not build a second chunking transport. | 1 | 1 |
| 3 | **`MeshCustodyReceipt`** (a custodian has durable ciphertext) — durable-before-acknowledged: sealed before acknowledged, never the reverse. Sits on the four-state sidecar model (§3 invariant 7: loaded/absent/deferred/corrupt) plus §19.5's fifth wrinkle — **"seal refused" is distinct from "deferred because protected data is unavailable"**, and background custody must never assume it can seal. | 1 | 2 |
| 4 | **`MeshRecipientReceipt`** (destination-final) with the per-type ack-stage rules §11 names: photos/text final on durable recipient storage; **hearts final only after foreground decrypt + ledger commit** (P4 item 7's `MeshHeartCommitOutcome.judgements` is the idempotence assertion to reuse, not re-derive); control immediate. | 1 | 3 |
| 5 | **The routed content digest** (`MeshInventoryDigest` in §11's prose — ID lists, bounded by the 1024-item cap). **Naming hazard: P4 already owns the wire token `fernlet.mesh.inventory-digest.v1` for the *membership* digest.** This is a different structure over different content; it needs its own frozen token, and the type name must not collide either. Check first, then name it deliberately. | 1 | 1 |
| 6 | **The drain, wired onto the one merge path** (§22.1: reconnect ≡ merge ≡ relay drain). `MeshDeliveryTarget.outstandingReachable`/`outstandingUnreachable` (P4 item 8) drive what the drain asks for or offers on each `mergeReconnected(_:entry:)` door; a peer with outstanding custody is a reason to open or piggyback an exchange, in the idiom of `askOneReconnectedPeer`. Do NOT add a second reconnect path. | 1 | 1, 5 |
| 7 | **The merge-window redesign** (P4's 2d comes due, §22.3's decision: yes). `concludeMerge()` currently closes on the **first** matching digest; redesign it to close only when **every asked peer has matched**, and — because "answered" alone reopened the exact deadlock 2c fixed (`ab89d8c`) — the responder-side rule must be **"answered AND the peer's next digest matched"**, never "answered" alone. This item retires 2d's deferral; the P4 ledger's four deferred cells become the regression fixture. | 1 | 6 |
| 8 | **Custody-transfer-on-departure** (§10.6, §11: "the load-bearing case"). `MeshDevelopmentPlan.handoffTargets` (P4 item 6) names the custodians; `handoffSummary.handedOffItemCount` (currently hardcoded 0) gets filled for real — the departing device's outstanding custody transfers to the named reachable custodians before the 15 s window closes. Increment 1 has **no live relay hop otherwise**: origin retains custody until departure; only departure moves it (§3 decisions table, this file). | 1 | 3, 6 |
| 9 | **Backpressure**: at the 256 MiB / 1024-item caps, refuse new custody with a bounded, user-visible delivery failure. Nothing grows silently — this is Power of 10's bounded-growth rule applied directly to custody storage. | 1 | 3 |
| 10 | **Locked-device handling**: ciphertext-only custody; decryption and canonical-store mutation wait for unlock; the four-state sidecar (item 3) plus the fifth wrinkle; identity-key keychain protection is never weakened for background decryption. | 1 | 3 |
| 11 | **The type-token registry**: unknown type tokens are rejected, not forwarded; every future routed type declares size cap, destination semantics, relay-retention, final-ack condition and expiry **at registration** — a registry, not ad hoc per-type branching. | 1 | 1 |
| 12 | **`MeshFrameReplayWindow` wired** against manifest/chunk ids (P4 i8: it is built, unwired, deliberately epoch-independent — keep it that way; wire it here, where routed content is what an attacker would replay). | 1 | 2 |
| 13 | **Retire the three `keyEpoch` gates with the path they replace** (P4 i8, current at `81a4b3d`: `handlePhotoManifest` ~line 5864, `handleFriendPhotoEnvelope` ~line 4018, `handleEncryptedMetadata` ~line 6339 — re-check line numbers before editing, P5's own commits will move them). Each wrongly rejects other-branch content today; **retire them with the routed content-key-wrap path, never loosen them in place.** | 1 | 1–7 |
| 14 | **The P5 acceptance battery**: extend `MeshScheduleGenerator`/`MeshConvergenceRun`/`MeshConvergenceInvariants` (P4's reusable property harness — every event is one call into an existing seam, so a custody/receipt/backpressure event is a new case, not a new rig) with delivery-target events; assert every outstanding destination reaches `delivered` or a closed (departed) state under a bounded schedule across a partition tree, no content lost, no receipt double-counted, a locked-device `deferred` state never treated as `absent`. Mirror P4 item 10's named-suite shape (`MeshP5AcceptanceTests`) so CI can gate one line per clause. | 1 | 1–13 |

### Not this phase

- **Increment 2 — live third-party relay of in-flight chunks** (hop count ≤ roster, TTL). §11 itself
  gates it on device measurements showing it is actually needed at roster ≤ 8 on shared Wi-Fi — that
  measurement is tier 2's job (§2), not tier 1's, and the gate is a real "not yet", not a corner cut.
  Do not build speculative relay-hop plumbing "for later."
- **§18.2 partition UX copy.** Still the owner's. Default: the subtitle count only, no new localized
  string until the answer lands (§22.3).
- **The legacy unsigned two-party removal's retirement.** P4 left it frozen beside the signed family
  (§22.3, §22.4); P5 touches neither path.
- **Tier-2 items 11–14 from P4** (a real 2/2/3/1 split on Simulators; a real quorum removal on ≥ 3
  nodes retiring `FERNLET_MESH_CHAOS_BARRED`; §10.5 re-gossip on the radio; `MeshLedgerAdoption`'s
  non-founder rebase) remain owed on the owner's sim fleet — not P5's gate, but P5's own tier-2 lane
  (§2) is the natural place to fold them in if the owner runs the sim work during this phase.
- **The CI gate lines for P3's and P4's acceptance batteries.** Neither `MeshP3*AcceptanceTests` nor
  `MeshP4*AcceptanceTests` is wired into `.github/workflows/s3-wall.yml` today (§22.4). Not P5's job
  to add them, but flag it again at close-out if still unaddressed — three phases' batteries
  ungated is a real gap, not a rounding error.

### The decisions, with defaults so nothing blocks

| Decision | Default | Why |
|---|---|---|
| **Relay-retention for increment 1: does anyone but the origin ever hold custody before departure?** | **No.** Origin retains custody exclusively; custody moves only at departure (item 8), to the reachable custodians `MeshDevelopmentPlan` names. | §11: "Increment 1 ships origin-retains + custody-transfer-on-departure… live third-party relay… is increment 2." Building a relay hop for the "everyone present" case here would be increment 2 wearing increment 1's name. |
| **Does the merge window close on "answered" or on "every asked peer matched"?** | **Every asked peer matched**, with the responder-side rule "answered AND the peer's next digest matched" (item 7). | §22.3's decision, taken deliberately: "answered" alone is the exact deadlock 2c fixed reopened from the other side. |
| **Where is `MeshDeliveryTarget` persisted, and its wipe row?** | **Inside the routed store's own sealed surface**, encoded by P5 (the type stays non-`Codable` in ProximityKit — P5 owns persistence), with the `Docs/PrivacyWipeCoverage.md` disposition row and delete-all writer wiring in the **same commit**. | §22.3, §17.3's paperwork rule, the wipe wall. A delivery map is exactly "who this user was sending what to" — no new persisted surface ships without its row. |
| **The routed content digest's wire token** | **Not** `fernlet.mesh.inventory-digest.v1` (claimed by membership). Default: `fernlet.mesh.routed-inventory-digest.v1`, frozen, in the family. | Avoiding a silent name collision between two structurally different digests is cheaper than untangling it after the golden ships. |
| **The four-state sidecar model for custody/receipt storage** | **Mirror `MeshSessionContext`'s `LoadToken` exactly**: `loaded`/`absent`/`deferred`/`corrupt`, plus the fifth "seal refused" distinction from §19.5 — a `save` reachable only from `loaded`/`absent`, never from `refused`/`deferred`/`corrupt`. | Invariant 7 (§3) is stated once, enforced everywhere; §19.5 says explicitly this reaches P5's routed store, not just P3's session context. |
| **Departure delivery: still no transport ack?** | **Still no ack for membership frames** (P4's default stands, `ac3bddf`) — but the drain now carries real custody for *routed content* via item 8, which is the substantive half of what an ack would have bought. | §22.3: "the drain carries custody for routed content, not membership frames." The two questions were conflated in P4; P5 answers the one that was actually blocking. |
| **`MeshFrameReplayWindow` keyed on what** | **Manifest and chunk ids, never an epoch** (P4 i8's explicit instruction). | The window is deliberately epoch-independent so a divergent-branch replay is still caught; keying it to epoch would reopen exactly the gap P4's `.reconcile` verdict closed. |

---

## 4. Walls that will bite

- **Relays forward the origin's exact signed objects — never re-sign.** A custodian holding
  transferred custody is a courier, not a co-signer; mutating or re-deriving a manifest/chunk
  signature at a custodian breaks the origin-authenticity invariant §11 states as a given.
- **The four-state sidecar model, plus the fifth wrinkle (§19.5).** `loaded`/`absent`/`deferred`/
  `corrupt` are distinct and `deferred` is never treated as empty and overwritten (invariant 7); on
  top of that, **"seal refused" is distinct from "deferred because protected data is unavailable"**,
  and **background custody must never assume it can seal**. Identity-key keychain protection is never
  weakened for background decryption, full stop.
- **Durable-before-acknowledged (§3.6), doubly so here.** A custody receipt, a recipient receipt, a
  drain's "delivered" — none may be emitted for state that would not survive a restart. `ColumnCrypto`
  is V3-only and refuses to seal without a `DeviceBindingID`; "seal refused" is not "absent," and it
  is not "try again silently" either.
- **Backpressure is bounded and visible, never silent.** At the 256 MiB / 1024-item caps, refuse new
  custody with a user-visible failure. This is Power of 10's "bounded growth" rule with a UI
  consequence — a queue that grows past its cap without telling anyone is the violation, not just the
  growth itself.
- **Unknown type tokens are rejected, not forwarded.** A custodian that does not recognise a routed
  type must refuse it, never relay it blind — the type-token registry (item 11) exists precisely so
  "unknown" has one answer everywhere.
- **`MeshDeliveryTarget` stays non-`Codable` in ProximityKit.** P4 built it that way on purpose (§22.1)
  so P5 owns the persistence decision deliberately, with its own wipe row, rather than inheriting an
  encoding nobody chose.
- **No wire-format change without golden + registry + framing case together.** Any new record or
  frame needs a registered crypto domain and a framing-transcript case in
  `CryptographicPurposeBoundaryTests.canonicalSerializerTranscriptsMatchTheirDeclaredFraming`, in the
  **same commit** (the `91c3956` lesson: a declared-vs-emitted framing mismatch once reached the suite
  as ~200 unexplained failures). Do **not** re-pin an existing golden to make it pass — a golden
  failure is a wire decision. P4 shipped three new frames across two commits without moving a single
  existing golden; hold that line.
- **Retire the three `keyEpoch` gates WITH the path P5 replaces, never loosen them in place** (item
  13; P4 i8). Each currently, correctly, rejects other-branch content under the direct-decrypt path;
  loosening one before the routed content-key-wrap path exists would open exactly the hole P4 chose
  not to.
- **`MeshSessionContext` schema is 2 as of the P4 boundary.** If P5's routed store needs new state on
  the *session* context (not its own sidecar), bump to **3** and treat older as **corrupt**, exactly
  as P3's 1→2 and keep the five-state load discipline. The routed store's own sidecar is a separate
  schema from day one — do not conflate the two.
- **Wipe wall.** Any new persisted surface or `UserDefaults` key owes a disposition row in
  `Docs/PrivacyWipeCoverage.md` **and** delete-all writer wiring, in the same commit. A new surface
  with no wipe row fails CI.
- **Shared-disk-root flake family.** Anything that touches disk gets a per-instance root, in the idiom
  of `MeshSessionStoreIsolationTests` / `PhotoDirectoryIsolationTests`. The custody sidecar is a new
  disk surface — do not let it grow this family.
- **Power of 10:** ≤ 60 code lines per function/`body`, bounded loops, no `!`/`try!`/`as!`/
  `fatalError`, no swallowed `try?`, no mutable globals, no nested `#if`, warnings-as-errors. A
  chunking loop and a backpressure check both want to sprawl; split before the scanner does.
- **MC containment:** `TransportNeutralityBoundaryTests` permits MC types only in
  `MeshMultipeerSession.swift` / `MCPeerIDStore.swift`. Nothing new names an MC type.
- **Localization:** new wire tokens, `rawValue`s and state spellings stay **frozen English**; display
  text forks separately. `LocalizedStringKey` for UI, never `String`.
- **DocC:** every new type carries `///`; `doc-coverage-scan.py` stays at zero. Update the
  ProximityKit landing page when the routed-store surface changes, in the same commit.
- **Fixture discipline (carried from P4, all paid for once):** `ensureProvisioned()` + roster size as
  a hard precondition; a distinct `identity:` per manager (`IdentityService()` is keyed on one
  process-wide keychain service); one `ProximityCoordinator` per link in an N-manager rig; sample
  rotation-queue and drain state right after a synchronous pump, never after an `await`; heals must be
  **ordered** (re-gossip and, now, the drain answer once per peer per session); a healed partition
  must re-form as a full mesh with a second commit round; `MeshNetworkManager` holds its host store
  **`unowned`**, so an inline test store traps the process; `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
  on the test target means fixtures must be `@MainActor`.
- **Do NOT touch** `App/Fernlet/Localizable.xcstrings` or `App/Fernlet.xcodeproj/xcuserdata/**` (held
  by another session). Do not run `Scripts/sync-string-catalogs.sh` (known-red, do not bisect it).

---

## 5. Two items with a design call inside

### (a) The merge-window redesign (item 7)

2d's shape: `concludeMerge()` closes on the **first** peer digest that matches local inventory, so
across eight members another peer's later re-gossip lands outside the window and rotates
`.membership` instead of `.merge` — converging, but mislabeled. The naive fix, "close on *any*
answered exchange," reopens the 2c deadlock from the responder's side: a responder that considers
itself done the moment it answers stops asking, and if every member reaches that state with no
matching digest in flight, nothing moves again. The rule that survives both failure modes is
symmetric: a window closes only when **every peer it asked has sent a matching digest**, and a
responder additionally requires that **the peer whose mismatch it answered has, in turn, sent a
matching digest back** — "answered" is necessary but not sufficient on either side. Encode this as an
explicit state, not an implicit inference from a counter; the four cells 2d deferred are the
regression fixture, and they must now pass at full strictness, not merely converge.

### (b) Custody-transfer-on-departure is the only relay hop increment 1 has

§11 draws the line precisely: "Increment 1 ships origin-retains + custody-transfer-on-departure (the
load-bearing case — §10.6); live third-party relay of in-flight chunks… is increment 2." The trap is
reaching for a general "any custodian can relay to any other" primitive because it looks like the
natural generalisation of the departure case — it is not. Increment 1's invariant is narrower and
cheaper to verify: custody is either at the origin, or (after exactly one transfer, at exactly one
moment — a development) at the set of custodians `MeshDevelopmentPlan.handoffTargets` names. There is
no in-flight hand-off between two live, connected members. Build exactly that, and let increment 2's
device measurement (§2, tier 2) be the thing that earns the general case, not an assumption made here.

---

## 6. Stop conditions — end the loop on any of these

Call `ScheduleWakeup({stop: true})`, write the handoff (§8), and report.

1. **P5 is complete** — every item done, gauntlet green, §11 marked BUILT, P6 handoff written.
2. **Blocked on the owner** and no tier-1 work remains. Say exactly what is needed and stop; do not
   idle-wake waiting for a human. (Every §3 decision has a default, so this should not happen before
   the tier-2 items.)
3. **Budget is running low.** Stop with items to spare, not at zero.
4. **Context is filling.** `/loop` resumes the same context and never compacts, so a long P5 will run
   out. When the ledger is the only thing you would need to resume, stop and let a fresh session
   continue from it.
5. **A gate goes red for a reason you did not cause.** Record it, stop, report — do not spend
   iterations bisecting someone else's commit. (`sync-string-catalogs.sh --check` is **already
   known-red** on nine stale keys — **do not bisect it.**)

### Gauntlet — the subagent runs it; you check the marker line

```bash
python3 Scripts/power-of-10-scan.py
python3 Scripts/doc-coverage-scan.py
xcodebuild build-for-testing -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test-without-building -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FernletTests
Scripts/spm-wall-check.sh          # once anything wall-relevant moves
Scripts/spm-wall-selftest.sh       # after any change to the wall or its permit lists
```

Full `FernletTests` was **3859 green ≈ 11–13 min** at the P4 boundary and is growing — run it in
batches and check the **exit code**, never a grep for "passed". Plus, for P5 specifically: the
property-battery extension must run its **fixed seed family** in CI (root `0x00F32B1C00090002`, same
as P4's — a randomized seed is a flake generator, not a property test), and any suite touching disk
must be green in the same run as the isolation grep-wall.

---

## 7. Ledger template

Create `Docs/Mesh-Migration-Loop-Ledger-P5.md` on iteration 1 if absent. Keep it **short** — it is
read on every wake, so every line costs orchestrator budget forever.

```markdown
# Mesh Migration Loop Ledger — P5

**Phase:** P5 (encrypted store-and-forward routing) · **Prompt:** [Next-Round-Prompt-Mesh-P5-2026-09-03.md](Next-Round-Prompt-Mesh-P5-2026-09-03.md)
**Started:** <date> · **Iteration:** <n> · **Tree at seed:** main = `6bc98ee` (pushed)

## Items
States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`. Tier per §2.
| # | Item | Tier | Prereq | State | SHA | Note |
|---|---|---|---|---|---|---|
| 1 | MeshRoutedManifest + MeshRecipientKeyWrap (§11) | 1 | — | todo | | destination = MeshDeliveryTarget's roster-at-creation |
| 2 | MeshChunk on P2's existing stream lane | 1 | 1 | todo | | reuse MeshTransferStreamTable, no new transport |
| 3 | MeshCustodyReceipt, four-state sidecar + fifth wrinkle | 1 | 2 | todo | | seal refused ≠ deferred |
| 4 | MeshRecipientReceipt, per-type ack stages | 1 | 3 | todo | | hearts final only at foreground decrypt + commit |
| 5 | Routed content digest, own frozen token | 1 | 1 | todo | | do NOT collide with membership's inventory-digest.v1 |
| 6 | The drain on the one merge path | 1 | 1, 5 | todo | | reconnect ≡ merge ≡ relay drain |
| 7 | Merge-window redesign (2d comes due) | 1 | 6 | todo | | close only when every asked peer matched |
| 8 | Custody-transfer-on-departure | 1 | 3, 6 | todo | | the load-bearing case; increment 1's only relay hop |
| 9 | Backpressure at 256 MiB / 1024 items | 1 | 3 | todo | | bounded, visible refusal, never silent growth |
| 10 | Locked-device handling | 1 | 3 | todo | | ciphertext-only custody; keychain protection unweakened |
| 11 | Type-token registry | 1 | 1 | todo | | unknown types rejected, not forwarded |
| 12 | MeshFrameReplayWindow wired | 1 | 2 | todo | | against manifest/chunk ids, never epoch |
| 13 | Retire the three keyEpoch gates with the path | 1 | 1–7 | todo | | never loosen in place; re-check line numbers first |
| 14 | P5 acceptance battery | 1 | 1–13 | todo | | extend MeshScheduleGenerator, not a new rig |

## Blocked on owner
- §18.2 partition UX copy — default: subtitle count only, no new string (unchanged from P4).
- Legacy unsigned two-party removal's retirement — default: leave frozen (unchanged from P4).
- CI gate lines for MeshP3/P4 AcceptanceTests — still not wired into s3-wall.yml.

## Decisions taken (defaults from §3 unless the owner overrides)
| Decision | Choice | Taken on |
|---|---|---|
| Relay-retention, increment 1 | (default: origin-only until departure) | — |
| Merge window closing rule | (default: every asked peer matched) | — |
| MeshDeliveryTarget persistence | (default: inside routed store, own wipe row) | — |
| Routed digest wire token | (default: fernlet.mesh.routed-inventory-digest.v1) | — |
| Four-state sidecar model | (default: mirrors MeshSessionContext's LoadToken + fifth wrinkle) | — |
| Departure delivery ack | (default: still no ack; drain carries custody instead) | — |

## Surprises worth not re-deriving
- (carry the P4 lessons below until they stop earning their place)

## Next item
1
```

**Lessons carried from P4 — seed the surprises list with these so P5 does not re-learn them:**
- **The seeded property test paid for itself on its first iteration.** Three shipping merge defects
  (2c, the late-reconnect strand, 2d) surfaced from randomized bounded schedules under a fixed seed —
  none of the targeted tests for items 2–8 found them. Write the P5 battery extension (item 14)
  *beside* the first increment, not after it; every event is one call into an existing seam, so a
  custody/receipt/backpressure event is a new case in the existing generator, not a new rig.
- **One `ProximityCoordinator` per link** in any N-manager rig — the manager resolves an inbound
  frame's slot by coordinator identity.
- **`ensureProvisioned()` and roster size as a hard precondition** — an unprovisioned `IdentityService`
  shares one placeholder fingerprint with every other unprovisioned instance, so a roster silently
  dedupes and assertions go vacuous. A **distinct `identity:` per manager** for the same reason.
- **Sample rotation-queue (and now drain) state right after a synchronous pump, never after an
  `await`** — under a loaded suite a `Task.yield()` can take seconds, long enough for a 2 s debounce
  window to fire and consume what you meant to observe.
- **Heals must be ordered** — re-gossip (and P5's drain answer) fires once per peer per session; a
  test that fires two heals "together" instead of in sequence will silently answer only the first.
- **A healed partition must re-form as a full mesh with a second commit round** — branch scoping reads
  presence, so a member on a partial reachable set elects a different coordinator until the second
  round completes.
- **`MeshNetworkManager` holds its host store `unowned`.** An inline test store built without a
  guarding rig traps the whole test process; `MeshDepartureRig.node` guards it correctly.
- **`.merge` > `.membership` > `.timer`** in a 2 s coalescing window; a merge-seeded test cannot then
  observe a membership rotation (`seedMembershipLedgerForTesting` seeds without spending one).
- **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` on the test target** — fixture enums and suites must be
  `@MainActor` or pure suites cannot see them.
- **Widening an existing signed frame moves its golden.** New wire content needs a new additive frame
  with the full trio, never a widened existing one. The recipe that works: an independent
  re-implementation that first reproduces an *existing* golden byte-for-byte, then derives the new one.
- **The `test runner hung before establishing connection` flake hits the first invocation after every
  build**, consistently; the retry is the acceptance. Budget two invocations (~13 min each).
- **A single-file "apply" step in a close-out workflow should read its inputs from files, not a long
  inline prompt.** P4's apply agent 529-overloaded three times on a ~40k-character prompt built from
  three drafts' worth of corrections; it succeeded immediately once those were scratch files.
- **Closed; do not re-audit:** `MeshTunnelConvergence`, the id-vs-endpoint family (`96337a3`,
  `2f273a9`), the crypto-purpose / `PayloadType` / record-kind spellings (walled), and everything in
  P4's plan §10.7–§10.10.
- Concurrent sessions share this tree and sim fleet; `Localizable.xcstrings` +
  `xcschememanagement.plist` are held by another session — never stage them.

---

## 8. Close-out, when P5 is done

1. Mark P5 **BUILT** in §11 of the plan with landing SHAs, adding §11.1–§11.4 in the §10.7–§10.10
   format (what landed; deviations from the sketch and why; findings for the owner deliberately not
   fixed; acceptance evidence).
2. Record deviations from the sketch and why — say where §11 was silent and what default (§3) was
   taken.
3. Record findings you deliberately did NOT fix, with what they cost, the way §10.9 does.
4. Memory note: what landed, what surprised you, what the next session must not re-derive.
5. Write the **P6 handoff block** (a new §23, in the §21/§22 format). P6 is feature routing (photos,
   text, hearts onto the routed store). Hand it: the drain's actual shape and its window semantics,
   the type-token registry as the seam new routed types register through, `MeshFrameReplayWindow`'s
   final wiring, which `keyEpoch` gates actually retired and how, and the unlocks P6 gets from a
   working relay (the hearts/moderation ceremonies P2 could not reach, per §9's road-to-TestFlight
   table).
6. **Consider running the close-out as a Workflow** (draft → adversarial verify → apply), per §0 rule
   6 — it caught 51 real corrections on P4 and is worth its cost at a phase boundary.
7. Note anything P5 learned that re-tiers P6–P7 further.

---

## 9. The road to TestFlight

The owner's goal is the whole migration before the first TestFlight build. After P5, four phases remain.

| Session | Phase | Prerequisite |
|---|---|---|
| P2 (done) | NetworkMeshSession over QUIC | built + proven sim↔sim |
| P3 (done) | durable context, roster, membership | built (`ed3c193` battery, 3687 green); 0b FIXED — three sims form a full mesh |
| P4 (done) | partition + merge | built (§10 BUILT, `19af2d7`); property test found 3 merge defects, 2 fixed, 1 (2d) deferred to P5 |
| **this** | **P5** — encrypted store-and-forward routing | P4 (§10.3's sequence is the shape the drain plugs into; delivery targets are defined in partition terms). Retires the `keyEpoch ==` gates; closes 2d. |
| +1 | **P6** — feature routing (photos, text, hearts) | P5. Also unlocks the hearts/moderation ceremonies P2 could not reach. |
| +2 | **P7** — app-layer run policy | P3's states; **mostly wiring** — `.developed`/`.backgrounded`/`.foregrounded` plus a poller for `enforceSessionCeiling`/`evaluateIdleLapse`/`evaluatePartition` (P4 added a third consumer for the same poller). Can interleave earlier. |
| +3 | **P8** — background continuation | **§15 gates: physical devices, multi-hour soaks, Low Power Mode, battery — irreducibly physical.** Unchanged by P4 or P5; first hardware sample was iOS ending a user-started continued-processing task ≈ **46 s** in, after backgrounding. |
| +4 | **P9/P10** — remaining radios, MC retirement (iOS 27), companion `BGAppRefreshTask` | P2 proven in the field. |

**The tier-1 re-tier holds through P6 and not into P8.** P4 proved tier 1 carries up to eight
managers and a nested re-split; P5's drain across a real partition tree is the natural next tier-1
case, not a lane run. P8's background/battery/thermal gates are the one thing that still needs the
phone drawer and the multi-hour soaks TestFlight does not supply.

**Still owed by the owner, not blocking P5** (carried from §22.4, unchanged unless P5 resolves one):
- **Hardware, unchanged:** the Lane A report, Lane B's double-dial row, the **AWDL half** of tier-2
  item 11, and **Lane D — the production transport over Wi-Fi with the cable OUT**; check afterwards
  that no ready line names a USB-side interface (`anpi0`/`en8`).
- **The CI gate lines for both P3's and P4's acceptance batteries** — neither is wired into
  `.github/workflows/s3-wall.yml` today. Add P5's own battery's gate line at the same time if this is
  still open at P5's close-out.
- **Tier-2 items 11–14** on the sim fleet, carried unaddressed from P4.
- **The legacy unsigned removal's retirement decision.** **Transcript `sid`** (§18 decision 7) stays
  owner-gated; P5's routed frames make it dearer with every phase that adds one.
- **The one-line `sync-string-catalogs.sh` write** on a quiet tree (nine stale keys) — known-red, **do
  not bisect it**; and **the `HeartDrop` CloudKit record type is missing from the container**.
- **§17.3's `PrivacyInfo` / privacy-copy paragraph** by the first TestFlight build — P5 makes it
  concrete: nearby devices briefly holding ciphertext they cannot read *is* the drain. Also
  **downgrade `browsed peers=` from `.notice`/`.public`** before QUIC ships.
