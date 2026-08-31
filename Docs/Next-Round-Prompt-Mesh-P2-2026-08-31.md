# Loop Prompt — ProximityKit Network Migration: P2 (NetworkMeshSession)

**Written:** 2026-08-31, at the P1 boundary (main = `16b9cb2`, pushed).
**Plan:** [Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md](Plan-ProximityKit-Network-Migration-2026-08-27.md) — the authority. This file is the launcher and the loop contract.
**Ledger:** [Docs/Mesh-Migration-Loop-Ledger.md](Mesh-Migration-Loop-Ledger.md) — the loop's memory. It lives on disk, not in context.
**Scope:** build **P2** — a second `PeerTransport` conformer over Network.framework QUIC, used only
by `MeshNetworkManager`. **Stop the loop at the P2 boundary.**

---

## How to start

```
/loop Read Docs/Next-Round-Prompt-Mesh-P2-2026-08-31.md and run one iteration of it.
```

Self-paced (no interval): the work is build-and-test-bound, not clock-bound, so the loop should wake
when work completes, not on a timer.

---

## 0. Orchestrator contract — read this first, it is the binding constraint

**The orchestrator is Fable, running on roughly 10% of a weekly budget.** That is the scarcest
resource in this project right now, scarcer than build minutes or device time. Every rule below
exists to protect it.

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
judgement. A subagent that returns 40 lines of summary has saved the orchestrator 4,000 lines of file
content — that ratio is the whole point.

### Hard token rules for the orchestrator

1. **Never `cat` a source file.** Use `sed -n '120,180p'` or a targeted `grep -n`. If you need more
   than ~60 lines of a file, that is a subagent's job, not yours.
2. **Never let build or test output reach context.** Always:
   ```bash
   xcodebuild … > "$LOG" 2>&1; echo "EXIT=$?" >> "$LOG"
   grep -E "EXIT=|BUILD (SUCCEEDED|FAILED)|TEST EXECUTE|Test run with" "$LOG"
   ```
   Three lines in, not three thousand. Only if it failed do you hand `$LOG` to a subagent to diagnose.
3. **One work item per iteration.** Finish it, record it, wake again. Do not batch — a batched
   iteration that fails halfway leaves the ledger lying.
4. **Write state to the ledger, not to your own memory.** `/loop` resumes the *same* context and never
   compacts between iterations, so anything you keep in your head is paid for again on every
   subsequent turn and is lost entirely if the session ends. The ledger is the only durable state.
5. **Stop early rather than run out.** See §6. A clean handoff is cheap; a loop that dies mid-item is
   expensive to reconstruct.

### If the Fable budget runs out mid-phase

Stop the loop, write the handoff (§6), and say plainly what is left. Do not silently degrade into
doing the work yourself — that is exactly how the budget disappears.

---

## 1. Each iteration, in order

1. **Read the ledger.** `Docs/Mesh-Migration-Loop-Ledger.md`. It is **already seeded** with all
   twelve items, their tiers, prerequisites and the four decisions — so iteration 1 spends nothing on
   setup and goes straight to item 0. (§7 has the template, for reference or if it is ever lost.)
2. **Check the tree is safe to build on** — only on the first iteration, or after any owner activity:
   ```bash
   git -C . log --oneline -1; git -C . status --porcelain
   ```
   Another session may hold `App/Fernlet/Localizable.xcstrings`. If so, leave it alone.
3. **Pick the next item** whose prerequisites are met, from §3's list, in ledger order. Prefer a
   **tier-1** item (no radio) over anything needing hardware — see §2.
4. **Dispatch one subagent** with the item's full context. Tell it: the acceptance criterion, the
   walls it must not trip (§4), and that it must run the gauntlet subset for what it touched.
5. **Verify** — grep the marker line out of its build/test log yourself. Do not take "it passed" on
   trust; this repo has had a failed build notified as exit 0.
6. **Commit** with explicit pathspecs (never `git add -A`; note `git mv` stages a rename immediately,
   so check `git diff --cached --name-status` first).
7. **Update the ledger**: item → done, with the SHA, one line on anything surprising, and the next
   unblocked item.
8. **Schedule the next wake**, or stop per §6.

---

## 2. Testing strategy — push work DOWN the tiers, never up

**Owner constraint, 2026-08-31:** device↔Simulator is the cheap, fast, well-logged loop and should
carry as much as it possibly can. **Two-device testing is limited and slow.** Keep the tier-3 list as
short as the work allows.

| Tier | What it proves | Cost |
|---|---|---|
| **1 — no radio** | Pure logic: dial tie-breaker's total order, retry budgets, connection state machine, framing bounds, the whole rejection matrix, partition scenarios. `Tests/FernletTests/Mocks/FakePeerTransport.swift` (`VirtualClock` + `FakePeerNetwork`) exists for this. | Free, deterministic, runs in CI. **If a check CAN live here, it MUST.** |
| **2 — device ↔ Simulator** | Real Bonjour, real QUIC, real TLS exporter, real crypto, every app-layer mesh flow over them, endpoint-cache reconnection, and the rejection matrix driven by making the Simulator misbehave on purpose. | One device, debugger attached, minutes per run. **This is the default.** |
| **3 — two physical devices** | Only genuine radio physics or OS policy: Apple peer-to-peer Wi-Fi (AWDL), the Local Network permission prompt, background/locked, battery, thermal, Low Power Mode. | Slow, hard to log, owner's time. **Justify every entry.** |

Known tier-2 limits — these are properties of the lane, not bugs:

- The Simulator disables Apple peer-to-peer Wi-Fi, so this lane is **infrastructure Wi-Fi only**.
- **The dial direction is one-way.** The Simulator's link-local address is host-only, so the device
  cannot reach it and the TXT marking makes the Simulator always the dialer. Consequence: the
  tie-breaker's *device↔device* branch (`localServiceName < candidateServiceName`) is **never
  exercised on this lane** — and that is the comparison that deadlocked the mesh before. Cover it
  exhaustively at tier 1 instead of hoping a hardware run reaches it.
- No Local Network permission flow; no meaningful background, battery or thermal behaviour.

### Item 0 — the experiment that could change everything downstream

`MeshProbeDiscoveryPolicy.allowsOutboundConnection` returns `!candidateRunsInSimulator` when the
local side is a Simulator, so **one Simulator will not dial another**. The documented reason — the
Simulator's host-only address — justifies the *device→Simulator* refusal, **not this one**. Two
Simulators on the same Mac share the host's network stack, and the probe already uses a random
per-instance service name, so instance-name collision is not the obstacle either.

**Run this first, timeboxed to one iteration.** Behind a DEBUG toggle, relax that one line and start
the probe on two Simulators.

- **If they connect:** multi-node testing (3, 4, 6 nodes) becomes possible entirely on one Mac. That
  changes the cost of P3 (membership), P4 (partition), P5 (routing) and P6 (features) — all of which
  want ≥3 nodes and are currently written as if they need a drawer full of phones. Record it in the
  ledger and the runbook as a first-class capability, and re-tier the later phases accordingly.
- **If they do not:** record *why* (the exact failure — no discovery, dial refused, TLS, timeout), so
  nobody re-runs this experiment in six weeks. One iteration, then move on.

Either way this is cheap and the upside is large. Do it before writing transport code.

---

## 3. The work list

Ledger order. Each is one iteration unless noted.

| # | Item | Tier | Prereq |
|---|---|---|---|
| 0 | **Sim↔sim experiment** (§2). Timeboxed to one iteration, DEBUG toggle only. | 2 | — |
| 1 | **Capture a Lane A diagnostic report.** The owner reports device↔Simulator connects (recorded 2026-08-31), but no **Copy diagnostic report** has been attached. Get one, paste it into the runbook, promote those rows from *Observed working* to *Pass* with a date. | 2 | one device |
| 2 | **String-catalog repair.** `sync-string-catalogs.sh --check` is red on nine keys the source no longer produces — pre-existing, proven present in the file as committed. One write-mode run, its own commit. **Skip if `Localizable.xcstrings` is still modified by another session.** | 1 | quiet tree |
| 3 | **§6.5 root fix, alone.** Split the endpoint→UUID map out of the dictionary discovery prunes so `peer(for:)` returns a stable `id` per session; then close the §6.4 asymmetries in the same commit (`handleChannelReady`'s `id`-only guard, `locallyKickedPeerIDs`, `peerRetryCount`, `canEvaluateOverflowCandidate`). Behaviour change — own it with tests. Map stays session-scoped and cleared at teardown, or it owes a wipe-wall row. | 1 | — |
| 4 | **Dial-policy tie-breaker, tier-1 tests first.** Exhaustive symmetry/totality tests on the fake transport **before** any QUIC code. This is the deadlock comparison; the 25-line doc block at `MeshNetworkManager` :1986-2010 explains the errno-61 failure. | 1 | 3 |
| 5 | **`NetworkMeshSession` skeleton** beside `MeshMultipeerSession`: listener, browser, per-peer QUIC connection, session actor. §7.1 is the mapping, §7.3 the duty list (cap 8, per-connection state machine, 3 dial retries at 2 s, duplicate-tunnel suppression, endpoint cache, 30 s heartbeats). Written against `FakePeerNetwork`, not timers. May take 2–3 iterations. | 1 | 3, 4 |
| 6 | **No-tracking wall extension, same commit as the first QUIC file.** See §5 — there is a design call in it. | 1 | 5 |
| 7 | **Signed channel introduction, productionized** (§7.2). See §5. | 1 | 5 |
| 8 | **Transport selection** in `MeshNetworkManager` — both conformers selectable so the suite runs either. QUIC is **not** the default until hardware says so. | 1 | 5, 7 |
| 9 | **Rejection matrix at tier 2**: unknown identity, non-roster, hard-departed/removed, ended/foreign meshID, introduction failure, replayed nonce. Drive by making the Simulator misbehave. | 2 | 8 |
| 10 | **Mesh flows at tier 2**: admission, QR ceremony, photos, chat, hearts, shop, moderation, capabilities, age gates, on QUIC. | 2 | 8 |
| 11 | **Tier-3, and only this**: AWDL path, Local Network permission prompt. Everything else stays at tier 1 or 2. | 3 | 10 |

### The four decisions, with defaults so nothing blocks

| Decision | Default | Why |
|---|---|---|
| Ephemeral per-mesh TLS identity (§7.2) | **Yes** — self-signed P-256, minted at session start, never persisted, never reused across meshes | Authentication comes solely from the signed introduction. A persisted TLS identity becomes a second, weaker identity nobody audits. |
| `prohibitedInterfaceTypes = [.cellular]` | **Yes, always** | Makes the serverless claim enforced rather than aspirational. Much harder to add later. |
| Publish `fp` in the QUIC TXT record | **No, not in P2** | It would activate the vacuous fingerprint gate and envelope binding (§6.4 finding 4) — desirable, but it **moves signed bytes**, so it deserves its own change with the golden vectors updated deliberately. |
| Take the §6.5 root fix | **Yes, item 3, before the transport** | Closes §6.4 findings 1–3 together. Minting a fresh `id` per QUIC reconnect makes them *worse*, because reconnection stops being exceptional. |

---

## 4. Walls that will bite

- **Power of 10:** ≤ 60 code lines per function/`body`, bounded loops, no `!`/`try!`/`as!`/
  `fatalError`, no swallowed `try?`, no mutable globals, warnings-as-errors. A QUIC session actor
  grows a 90-line state machine if you let it — split it before the scanner does.
- **MC containment:** `TransportNeutralityBoundaryTests` permits exactly `MeshMultipeerSession.swift`
  and `MCPeerIDStore.swift`. `NetworkMeshSession.swift` names no MC type, so it needs **no** permit
  entry — if a subagent adds one, something has gone wrong.
- **Golden vectors:** `PeerHandleWireGoldenTests` fails if a peer field starts or stops reaching the
  signed envelope bytes. A failure is a wire-format decision, never a test to re-pin without thinking.
- **DocC:** every new type carries `///`; zero undocumented declarations is enforced. Update the
  Transport topic list in `FernletKit/Sources/ProximityKit/Documentation.docc/ProximityKit.md`.
- **Localization:** display text as `LocalizedStringKey`; wire tokens, `rawValue`s, ALPN strings and
  Bonjour service types stay frozen English.
- **Wipe wall:** the endpoint cache is new state. Keep it in memory; if it reaches disk or
  `UserDefaults` it owes a disposition row in `Docs/PrivacyWipeCoverage.md` in the same commit.
- **Cross-round crypto (reaches P3/P5, do not re-derive):** `ColumnCrypto` is V3-only and **refuses
  to seal** without a `DeviceBindingID` (D4). A sealed `MeshSessionContext` cannot be written before
  first unlock; "seal refused" ≠ "deferred, protected data unavailable"; and durable-before-
  acknowledged means **if you cannot seal, you must not acknowledge.**

---

## 5. Two items with a design call inside

### The no-tracking wall extension (item 6)

`NoTrackingBoundaryTests` bans `NWConnection`/`NWBrowser` via `httpClientMarkers`, permitted only in
`permittedHTTPClientFiles` (the two web importers plus `EphemeralWebSession.swift`). TN3213's API is
spelled `NetworkConnection` / `NetworkListener` / `NetworkBrowser`, so the new names pass through a
gap that No-Tracking-Wall §4c already names as scheduled to close here.

**Do not simply append the new names to `httpClientMarkers`.** That list stops *outbound HTTP egress*,
and its permit set is three files that talk to the internet. A ProximityKit file permitted there for
`NetworkConnection` would thereby also be permitted to hold a `URLSession` — silently widening the
wall it is meant to extend. **Add a second, separate marker family** for local-link APIs with its own
permit set (the ProximityKit transport files plus the DEBUG probe). Two lists, two permit sets,
neither weakening the other. Update No-Tracking-Wall §4c/§5 in the same commit.

### The channel introduction (item 7)

`FernletCryptoPurpose.Signature.meshChannelIntroductionV1` is **already registered** and declares
`.lengthPrefixed`. Nothing has signed under it yet, so the framing may still change — but **change the
serializer and the registry together**, and add the case to
`CryptographicPurposeBoundaryTests.canonicalSerializerTranscriptsMatchTheirDeclaredFraming` in the
same commit.

Not hypothetical bookkeeping: `91c3956` declared a raw prefix while `CanonicalByteWriter` emitted a
length-prefixed field, and it reached the suite as ~200 unexplained failures rather than one named
cause. `.lengthPrefixed` is declared because `CanonicalByteWriter` is the reviewed serializer every
other production signature uses.

Transcript per §7.2: purpose ‖ version ‖ meshID ‖ epochRef ‖ both signing public keys ‖ both nonces ‖
TLS-exporter hash, Ed25519 both sides, verified against the trust vault / current roster. The exporter
label `KeyDerivation.meshTLSExporterV1` is registered and must stay distinct from
`meshProbeTLSExporterV1` — `probeAndProductionMeshLabelsAreSeparateDomains` fails if they converge.

---

## 6. Stop conditions — end the loop on any of these

Call `ScheduleWakeup({stop: true})`, write the handoff, and report.

1. **P2 is complete** — every item done, gauntlet green, plan marked BUILT, P3 handoff written.
2. **Blocked on the owner** and no tier-1 work remains. Say exactly what is needed (a device run, a
   decision) and stop. Do not idle-wake waiting for a human.
3. **Fable budget is running low.** Stop with items to spare, not at zero.
4. **Context is filling.** `/loop` resumes the same context and never compacts, so a long P2 will run
   out. When the ledger is the only thing you would need to resume, that is the moment to stop and let
   a fresh session continue from it.
5. **A gate goes red for a reason you did not cause.** Record it, stop, report — do not spend
   iterations bisecting someone else's commit.

### Gauntlet — the subagent runs it; you check the marker line

```bash
python3 Scripts/power-of-10-scan.py
python3 Scripts/doc-coverage-scan.py
xcodebuild build-for-testing -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test-without-building -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FernletTests
Scripts/spm-wall-check.sh          # once anything wall-relevant moves
Scripts/spm-wall-selftest.sh       # after any change to the wall or its permit lists
```

Full suite ≈ 11 minutes (3304 tests / 298 suites) — run it in batches, check the **exit code**, never
a grep for "passed". `The test runner hung before establishing connection` is a simulator flake, not a
failure: `xcrun simctl shutdown all; sleep 5` and retry. It hit three times in one session last round,
burning a flat ~6 minutes each time.

---

## 7. Ledger template

Create `Docs/Mesh-Migration-Loop-Ledger.md` on iteration 1 if absent. Keep it **short** — it is read
on every wake, so every line costs orchestrator budget forever.

```markdown
# Mesh Migration Loop Ledger — P2

**Phase:** P2 · **Started:** <date> · **Iteration:** <n> · **Tree:** main = <sha>

## Items
| # | Item | State | SHA | Note |
|---|---|---|---|---|
| 0 | sim↔sim experiment | todo | | |
| 1 | Lane A diagnostic report | todo | | needs device |
| … | | | | |

## Blocked on owner
- (nothing yet)

## Surprises worth not re-deriving
- (nothing yet)

## Next item
0
```

States: `todo` / `in-flight` / `done` / `blocked` / `skipped (reason)`.

---

## 8. Close-out, when P2 is done

1. Mark P2 **BUILT** in the plan with landing SHAs, in the format §5/§6 use. Deviate from the sketch
   where reality requires it and say why — §6.2 is the model.
2. Record findings you deliberately did NOT fix, with what they cost, the way §6.4 does.
3. Memory note: what landed, what surprised you, what the next session must not re-derive.
4. Write the **P3 handoff block** (plan §20). P3 needs the D4 sealing constraint (§4) and the
   policy-reversal paperwork in plan §17 item 17.3 (a bold line, not a heading — search for
   "Documented policy reversal").
5. **Re-tier the later phases if item 0 succeeded.** If sim↔sim works, P3/P4/P5/P6 stop needing a
   drawer of phones, and their prompts should say so.

---

## 9. The road to TestFlight

The owner's goal is the whole migration before the first TestFlight build — roughly **seven more
sessions after this one**. Two things the ordering does not remove.

| Session | Phase | Prerequisite |
|---|---|---|
| this | **P2** | Lane A report; 1 device. Tier-3 items only at the end. |
| +1 | **P3** — durable session context, roster, membership events | D4 sealing constraint. §17.3 paperwork is part of the phase. |
| +2 | **P4** — partition tolerance and convergence | P3. Built on `FakePeerNetwork` — no hardware. |
| +3 | **P5** — encrypted store-and-forward routing | P4 first, deliberately: delivery targets are defined in partition terms. |
| +4 | **P6** — feature routing (photos, text, hearts) | P5. |
| +5 | **P7** — app-layer run policy | P3's states; can interleave earlier. |
| +6 | **P8** — background continuation | **§15 gates: 2–4 devices, 3 h and 6 h soaks, Low Power Mode, battery.** |
| +7 | **P9** — remaining radios, MC retirement | P2 proven in the field. |
| any | **P10** — companion `BGAppRefreshTask` | Independent. Could ship first. |

**The hardware dependency moves earlier, not away.** P8's §15 gates need devices and multi-hour soaks
that TestFlight does not supply. Finishing everything first means doing all of it with no external
build having ever existed. (If item 0 succeeds, tiers 1–2 absorb more of P3–P6, but P8 is unaffected —
background and battery are irreducibly physical.)

**P8's scope is not knowable in advance.** Plan §14 carries a pre-decided degraded ladder: full
background mesh → background on infra Wi-Fi only → foreground-only with opportunistic sync on reunite.
Which rung applies is decided by §15.1, a measurement nobody has taken. So "the entire migration"
resolves to a different amount of work depending on that result.

**An earlier shippable boundary exists.** After P2 the mesh runs on QUIC beside MC, MC still
available, other radios untouched. P9 (MC retirement) is the riskiest phase and the least hurried —
MC is deprecated in **iOS 27**, not 26 — so shipping after P9 means the first external build runs on a
transport that has never been in the field.

**Not a mesh question, but in the way:** a Release archive has never been built for this app, and
export compliance (5D992.c, self-classified) has its deadline at the *first overseas TestFlight*.
Worth one session of its own, whenever.
