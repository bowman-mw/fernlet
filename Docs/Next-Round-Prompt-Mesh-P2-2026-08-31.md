# Next-Round Prompt — ProximityKit Network Migration: P2 (NetworkMeshSession)

**Written:** 2026-08-31, at the P1 boundary (main = `16b9cb2`, pushed).
**Plan:** [Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md](Plan-ProximityKit-Network-Migration-2026-08-27.md) — the authority. This file is only the launcher.
**Scope of the session this prompt starts:** build **P2** — a second `PeerTransport` conformer over
Network.framework QUIC, used only by `MeshNetworkManager`. **Stop at the P2 boundary.**

One phase per session, deliberately: a self-paced loop does not compact between phases, so a session
that runs P2→P4 arrives at the hard part with no room. Hand off at the boundary instead. §8 below is
the road from here to TestFlight, so the shape of the whole run is visible without doing it in one go.

---

## How to start

Open a fresh session in the repo and paste:

> Read `Docs/Next-Round-Prompt-Mesh-P2-2026-08-31.md` and execute it. Verify §1 before changing
> anything, run the Lane A gate in §2 first, then build §3. Stop at the P2 boundary and write the P3
> handoff.

---

## 1. Verify before you change anything

```bash
git -C . log --oneline -3
git -C . status --porcelain
python3 Scripts/power-of-10-scan.py
xcodebuild build-for-testing -project App/Fernlet.xcodeproj -scheme Fernlet \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

The build must succeed **before** your first edit. Check the real exit status — a piped or
backgrounded `xcodebuild` reports the wrapper's status, not the compiler's, and a failed build has
been notified as "exit 0" here twice.

### Two gates are ALREADY RED. Neither is yours; do not go hunting.

1. **`Scripts/sync-string-catalogs.sh --check`** fails on nine keys the source no longer produces
   (`- %@`, `--`, `…`, `· %lld servings`, `%@ - %@`, `%@ – %@`, and three sentence keys about photo
   deletion, "logged to today", and the System appearance setting). All nine are present in
   `App/Fernlet/Localizable.xcstrings` **as committed**, and the sync's output is a pure function of
   the source, so this fails on the committed tree independent of anything uncommitted. It is
   leftover from an earlier round that deleted UI without re-syncing.
   **Fix it early if the tree is quiet:** one write-mode `Scripts/sync-string-catalogs.sh` run, its
   own commit, before you touch anything else. It was left alone last round only because a concurrent
   session was holding that exact file. Check `git status` first — if `Localizable.xcstrings` is
   still modified by someone else, leave it alone again and say so.
2. **The runbook's Lane A** is unfilled. That is §2, and it is your first task.

**Concurrent sessions share this working tree and DerivedData.** Commit with explicit pathspecs,
never `git add -A`, and never run two `xcodebuild` invocations at once. Note that `git mv` *stages*
the rename immediately, so a later commit with explicit pathspecs still sweeps it in — check
`git diff --cached --name-status` before every commit.

---

## 2. FIRST: close Lane A. It is one sitting and it unblocks everything.

[Docs/Mesh-Network-Feasibility-Runbook.md](Mesh-Network-Feasibility-Runbook.md) — the Lane A table
still reads **"Not yet run"** for discovery, QUIC connect, control stream, datagram, and on-radio
channel binding. Nobody has ever run the spike on real hardware.

**Do this before writing QUIC code, not after.** A red Lane A discovered halfway through P2 is
indistinguishable from a P2 bug, and you will spend the session bisecting the wrong thing. The probe
already exists and is DEBUG-only; the procedure is the runbook's "Simulator development check".

Requires: one physical iOS 26.5-or-later device + one Simulator on the same non-isolated
infrastructure Wi-Fi, no VPN, no client isolation.

Fill the Result and Date columns from the probe's **Copy diagnostic report** — it now carries bytes
in/out, connect/reconnect counts with timestamps, and thermal / Low Power Mode transitions. Commit
the filled table as its own commit before starting §3.

**If no device is available:** say so plainly, commit nothing to Lane A, and proceed to §3 with the
risk stated in your final report. Do not mark rows passed on a simulator-only run — the probe refuses
a simulator peer by design, so two simulators cannot connect and a green result would be fictional.

---

## 3. P2 — the work

Plan §7. A second `PeerTransport` conformer, `NetworkMeshSession`, consumed **only** by
`MeshNetworkManager`. Presence, recipe share and coach stay on MultipeerConnectivity until P9 —
touching them is out of scope.

### 3.0 Four decisions, with defaults so you are never blocked

Proceed on the recommendation unless the owner has said otherwise; record what you chose and why.

| Decision | Recommendation | Why it matters |
|---|---|---|
| **Ephemeral per-mesh TLS identity** (§7.2) | **Yes.** Self-signed P-256, minted at session start, never persisted, never reused across meshes. TLS identity is not Fernlet identity. | Authentication comes solely from the signed channel introduction. A persisted TLS identity would become a second, weaker identity nobody audits. |
| **`prohibitedInterfaceTypes = [.cellular]`** | **Yes, always.** | Turns the serverless / no-internet claim from aspiration into something enforced. Cheap, and it is the kind of thing that is much harder to add later. |
| **Publish `fp` in the QUIC TXT record** | **No, not in P2.** | It would activate the fingerprint-mismatch gate and envelope recipient-binding that are vacuous today (§6.4 finding 4) — desirable, but it **moves signed bytes**, so it is a wire decision that deserves its own change with the golden vectors updated deliberately. |
| **Take the §6.5 root fix** (stable `id` per session) | **Yes, and do it as its own commit before the transport.** | It closes §6.4 findings 1–3 together. If you instead mint a fresh `id` per QUIC reconnect, those findings get **worse**, because reconnection stops being exceptional. Do not let the endpoint-cache design settle this by accident. |

### 3.1 Order of work

1. **The §6.5 root fix, first and alone.** Split the endpoint→UUID mapping out of the dictionary
   discovery prunes, so `peer(for:)` returns a stable `id` for the life of a session. Then fix the
   §6.4 asymmetries in the same commit — `handleChannelReady`'s `id`-only duplicate guard,
   `locallyKickedPeerIDs`, `peerRetryCount`, `canEvaluateOverflowCandidate`. This is a **behaviour
   change**, which is why P1 did not take it; own it explicitly with tests before the transport lands
   on top. **Privacy constraint:** the map stays session-scoped and cleared at teardown — the presence
   radio's posture is a per-start random, never-persisted identity, and a persisted map would weaken
   that *and* owe a wipe-wall disposition row.
2. **`NetworkMeshSession`**, beside `MeshMultipeerSession` in `Transport/`. Listener + browser +
   per-peer QUIC connection, owned by a session actor. §7.1 is the concept mapping; §7.3 is the duty
   list (connection cap 8, per-connection state machine, 3 dial retries at 2 s, duplicate-tunnel
   suppression, endpoint cache for direct re-dial, 30 s heartbeat datagrams).
3. **The no-tracking wall extension, in the same commit as the first QUIC file.** See §3.2 — there is
   a design call in it.
4. **The signed channel introduction, productionized** (§7.2). See §3.3.
5. **Wire `MeshNetworkManager` to select a transport.** Both conformers must be selectable so the
   suite can run either; QUIC does not become the default until it has passed on hardware.

### 3.2 The no-tracking wall extension — read this before extending the list

`NoTrackingBoundaryTests` bans `NWConnection` and `NWBrowser` via `httpClientMarkers`, permitted only
in `permittedHTTPClientFiles` (the two web importers plus `EphemeralWebSession.swift`). TN3213's API
is spelled `NetworkConnection` / `NetworkListener` / `NetworkBrowser`, so the new names pass straight
through a gap. §4c of [No-Tracking-Wall.md](No-Tracking-Wall.md) already names that gap as scheduled
to close here, so half the paperwork is written.

**Do not simply append the new names to `httpClientMarkers`.** That list exists to stop *outbound
HTTP egress*, and its permit set is three files that talk to the internet. A ProximityKit transport
file permitted there for `NetworkConnection` would thereby also be permitted to hold a `URLSession` —
silently widening the wall it is supposed to extend.

**Add a second, separate marker family** — local-link networking APIs, with its own permit set of
exactly the ProximityKit transport files plus the DEBUG probe. Two lists, two permit sets, neither
one weakening the other. Update No-Tracking-Wall §4c/§5 in the same commit and say which list is
which and why.

### 3.3 The channel introduction — the pairing that broke before

`FernletCryptoPurpose.Signature.meshChannelIntroductionV1` is **already registered** and declares
`.lengthPrefixed` framing. Nothing has signed under it yet, so you may still change the framing — but
**change the serializer and the registry together**, and add the case to
`CryptographicPurposeBoundaryTests.canonicalSerializerTranscriptsMatchTheirDeclaredFraming` in the
same commit.

This is not hypothetical bookkeeping. `91c3956` declared a raw prefix while `CanonicalByteWriter`
emitted a length-prefixed field; every canonical signature then threw at the signing boundary and
every verify returned false, and it reached the suite as ~200 unexplained failures rather than one
named cause. The declared framing says `.lengthPrefixed` because `CanonicalByteWriter` is the
reviewed serializer every other production signature uses. Use it, or change both halves.

Transcript per §7.2: purpose ‖ version ‖ meshID ‖ epochRef ‖ both signing public keys ‖ both nonces ‖
TLS-exporter hash, Ed25519-signed by both sides, verified against the trust vault / current roster.
Reject before any app frame: unknown identity, non-roster member, hard-departed or removed member,
ended or foreign meshID, introduction failure, replayed nonce (bounded per-session nonce cache).

The exporter label is registered too: `KeyDerivation.meshTLSExporterV1`. Keep it distinct from
`meshProbeTLSExporterV1` — `MeshNetworkFeasibilityTests.probeAndProductionMeshLabelsAreSeparateDomains`
fails if they converge, which is the point.

### 3.4 Testing — what to build it against

- **Use `FakePeerNetwork`, not timers.** `Tests/FernletTests/Mocks/FakePeerTransport.swift` gives you
  `VirtualClock` + scriptable connect/disconnect/latency/partition/heal with **no wall-clock sleeps**.
  Write the session actor's state machine, retry budget and duplicate-tunnel suppression against it.
  A test that sleeps will pass on your machine and flake in CI — this repo has a documented flake
  family from exactly that.
- **Give the dial policy its own symmetry test.** The MC inviter tie-break deadlocked the mesh once
  (the 25-line doc block at `MeshNetworkManager` :1986-2010 spells out the errno-61 failure) and is covered by two tests today. Five of the
  coordinator's discovery branches are unreachable in production and are driven by the mock alone
  (§6.4 finding 6), so the existing suite can go green on paths production never runs. Do not inherit
  confidence — prove the QUIC tie-breaker is symmetric and total.
- **Watch the golden vectors.** `PeerHandleWireGoldenTests` fails if a peer field starts or stops
  reaching the signed envelope bytes. If it fails, that is a wire-format decision to make
  deliberately, never a test to re-pin without thinking.
- **The MC containment wall.** `TransportNeutralityBoundaryTests` permits exactly
  `MeshMultipeerSession.swift` and `MCPeerIDStore.swift`. `NetworkMeshSession.swift` names no MC type,
  so it needs no permit entry — if you find yourself adding one, something has gone wrong.

**Acceptance (plan §7):** mesh flows — admission, QR ceremony, photos, chat, hearts, shop,
moderation, capabilities, age gates — pass on the QUIC transport on the device↔simulator lane **and
on 2 physical devices**; `Scripts/spm-wall-selftest.sh` and the extended no-tracking tests green.

**Explicit non-goals:** no session-state persistence (P3); no membership changes (P3 owns membership —
connection state feeds *presence* only); no partition logic (P4); no store-and-forward (P5); no
changes to the presence, recipe or coach radios (P9); no background continuation (P8); do not make
QUIC the default until hardware says so.

---

## 4. Constraints that will bite

- **Power of 10:** ≤ 60 code lines per function/`body`, every loop bounded, no `!`/`try!`/`as!`/
  `fatalError`, no swallowed `try?`, no mutable globals, warnings-as-errors. A QUIC session actor is
  exactly the kind of code that grows a 90-line state machine — split it before the scanner does.
- **DocC:** every new type carries a `///` comment; zero undocumented declarations is enforced. Update
  `FernletKit/Sources/ProximityKit/Documentation.docc/ProximityKit.md`'s Transport topic list.
- **Localization:** display text as `LocalizedStringKey` (a `String` parameter silently opts a call
  site out); wire tokens, `rawValue`s, ALPN strings and Bonjour service types stay frozen English.
- **Persisted-surface wipe wall:** the endpoint cache (§7.3) is new persisted-ish state. If it reaches
  disk or `UserDefaults` it needs a disposition row in `Docs/PrivacyWipeCoverage.md` in the same
  commit. Keeping it in memory avoids that — prefer memory.
- **Cross-round crypto constraint (reaches P3/P5, not P2, but do not re-derive it):** `ColumnCrypto`
  is V3-only and **refuses to seal** without a `DeviceBindingID`
  (`SealedColumnStrictSealError.bindingUnavailable`, owner decision D4). So a sealed
  `MeshSessionContext` cannot be written before first unlock. "Seal refused" is a distinct state from
  "deferred because protected data is unavailable", and durable-before-acknowledged means: **if you
  cannot seal, you must not acknowledge.**

---

## 5. State of the tree

- `main = 16b9cb2`, **pushed**. `origin/main` matches.
- P0 and P1 are **BUILT** (plan §5, §6). §19 is the P2 handoff written at the P1 boundary — read it;
  it is shorter than this file and says what P2 inherits.
- The transport surface is framework-free: `PeerTransport`, `PeerHandle`, `PeerEndpointKey`,
  `PeerDeliveryMode`, `PeerTransportState`, `PeerPendingInvite`, `InboundPeerFrame`,
  `PeerTransportError`. A second conformer needs no change to any of them.
- `App/Fernlet/Localizable.xcstrings` may still show as modified by another session. If so, leave it.

---

## 6. Verification gauntlet — before every commit

```bash
python3 Scripts/power-of-10-scan.py
python3 Scripts/doc-coverage-scan.py
xcodebuild build-for-testing -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test-without-building -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FernletTests
Scripts/spm-wall-check.sh
Scripts/spm-wall-selftest.sh      # after any change to the wall or its permit lists
```

The full suite is ~11 minutes (3304 tests / 298 suites); run it in batches and **check the exit code,
not a grep for "passed"**. If a run dies with `The test runner hung before establishing connection`,
that is a simulator flake, not a failure — `xcrun simctl shutdown all; sleep 5` and retry. It hit
three times in one session last round, always burning a flat ~6 minutes first.

---

## 7. Close-out

1. Mark P2 **BUILT** in the plan with landing SHAs, in the format §5/§6 use. If you deviate from the
   plan's sketch, say so and say why — §6.2 is the model.
2. Record any finding you deliberately did NOT fix, with what it costs, the way §6.4 does.
3. Write a memory note: what landed, what surprised you, what the next session must not re-derive.
4. Commit in logical units with explicit pathspecs. Push only if the owner asks.
5. Write the **P3 handoff block** at the bottom of the plan (§20). P3 needs the D4 sealing constraint
   in §4 above, and the policy-reversal paperwork in plan §17 item 17.3 (a bold line, not a heading — search
   for "Documented policy reversal") — every doc guard, wipe-wall row and boundary test owed when
   session state stops being memory-only.

---

## 8. The road to TestFlight — what is left after P2

The owner's stated goal is to complete the whole migration before the first TestFlight build. That is
roughly **seven more sessions after this one**, and two things about it are worth knowing up front.

| Session | Phase | Prerequisite it cannot start without |
|---|---|---|
| next | **P2** | Lane A run (§2). 2 physical devices for acceptance. |
| +1 | **P3** — durable session context, roster, membership events | The D4 sealing constraint (§4). §17.3 paperwork is part of the phase, not after it. |
| +2 | **P4** — partition tolerance and convergence | P3's states. Built on `FakePeerNetwork` — no new hardware. |
| +3 | **P5** — encrypted store-and-forward routing | P4 first, deliberately: delivery targets are defined in partition terms. Purposes already reserved. |
| +4 | **P6** — feature routing (photos, text, hearts) | P5. |
| +5 | **P7** — app-layer run policy | P3's states. Can be interleaved earlier. |
| +6 | **P8** — background continuation | **§15 hardware gates: 2–4 physical devices, 3 h and 6 h soaks, Low Power Mode, battery and memory measurement.** |
| +7 | **P9** — remaining radios, MC retirement | P2 proven in the field. |
| any | **P10** — companion `BGAppRefreshTask` | Independent. Could ship first. |

**Two things this ordering does not remove.**

**The hardware dependency moves earlier, not away.** P2 needs 2 devices to accept, and P8 needs 2–4
plus multi-hour soaks. TestFlight does not supply those — they are runs the owner performs. Waiting
until everything is done means doing all of that hardware work with no external build ever having
existed.

**P8's scope is not knowable in advance.** Plan §14 carries a pre-decided degraded ladder: full
background mesh → background on infrastructure Wi-Fi only → foreground-only with opportunistic sync on
reunite. Which rung applies is decided by §15.1's results, because Apple documents background
peer-to-peer in neither direction. So "the entire migration" resolves to a different amount of work
depending on a measurement nobody has taken yet.

**A natural earlier boundary exists, if the owner wants one.** After P2 the mesh runs on QUIC beside
MC with the other three radios untouched and MC still available — a genuinely shippable increment,
and the one that would put the new transport in front of real devices soonest. P9 (MC retirement) is
the riskiest phase and the least hurried: MC is deprecated in **iOS 27**, not 26, so nothing forces it
before a first TestFlight. Shipping after P9 means the first external build runs on a transport that
has never been in the field.

**Separately, and not a mesh question:** a Release archive has never been built for this app, and
export compliance (5D992.c, self-classified) has its deadline at the *first overseas TestFlight*.
Neither is blocked by the migration, and both should be settled before a build goes out. Worth one
session of its own, whenever.
