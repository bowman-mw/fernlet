# ProximityKit Network Migration & Partition-Tolerant Mesh — Implementation Plan v2

**Date:** 2026-08-27
**Supersedes:** the first-pass "Background Mesh Continuation" plan (chat draft, 2026-08-27) and extends
[Docs/Proximity-Mesh-Redesign-2026-07-10.md](Proximity-Mesh-Redesign-2026-07-10.md)'s radio-consolidation direction.
**Primary migration reference:** [TN3213 — Moving from Multipeer Connectivity to Network framework](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework)
**Feasibility artifacts:** `App/Fernlet/Proximity/Feasibility/NetworkMeshFeasibilityProbe.swift`,
[Docs/Mesh-Network-Feasibility-Runbook.md](Mesh-Network-Feasibility-Runbook.md),
`Tests/FernletTests/MeshNetworkFeasibilityTests.swift`.

---

## 1. Purpose and scope

Migrate ProximityKit's transport layer from MultipeerConnectivity to Network.framework (QUIC, new
`NetworkConnection`/`NetworkListener`/`NetworkBrowser` API per TN3213), and in the same program make the
friend mesh **partition-tolerant**: logical membership survives socket loss, process death, and mesh
splits; content converges when split groups reunite; a user-started session can continue in the
background via `BGContinuedProcessingTask`.

In scope: all four MC radios (friend mesh, presence, recipe share, coach service constant), sequenced —
friend mesh first, MC retirement last. The companion `BGAppRefreshTask` (widget/companion refresh) rides
along as an independent phase. Out of scope: the iMessage extension, Lock Screen widget redesign,
HeartDrop (CloudKit away-hearts — unchanged), and the Coach app itself.

### Corrected platform facts this plan is built on (verified against live docs 2026-08-27)

| Fact | Consequence |
|---|---|
| MC is deprecated in **iOS 27 / Xcode 27**, not iOS 26 ("Xcode 27 deprecates the entire Multipeer Connectivity framework" — TN3213). No warning in the current SDK. | Migration is right and unhurried. Phases can land incrementally; the other radios can trail the mesh without deadline pressure. |
| `BGContinuedProcessingTask` **requires progress reporting**; "the system prioritizes the termination of tasks that reflect minimal or no progress." Every documented use is finite. Indeterminate progress is undocumented. | The background phase (P8) needs a monotonic progress strategy and a soak gate proving it survives hours. See §15.3. |
| Background availability of peer-to-peer Wi-Fi / Bonjour under a continued task is **undocumented in both directions** (TN3213 contains zero occurrences of "background"). Wi-Fi Aware is the only Apple-documented background p2p path. | P8 carries its own hardware gate; infra-Wi-Fi is the expected working case, AWDL-in-background the expected degraded case. Wi-Fi Aware gets a bounded evaluation (§15.4). |
| Force-quit cancels a continued task **with no expiration callback** (documented). | Durable-before-acknowledge is a hard rule in P5. No cleanup may depend on the callback. |
| The Info.plist identifier must be the **wildcard** (`MBO.Fernlet.mesh-continuation.*`, mandatory notation), but **runtime registration and submission use concrete per-mesh identifiers** — wildcard *registration* asserts on current builds (runbook finding). | Register `MBO.Fernlet.mesh-continuation.<meshID>` at mesh start, immediately before submit. Re-validate per SDK release. |
| `BGAppRefreshTask` gives ≤ 30 s, opportunistic. | Correct for P10 (companion refresh) and nothing else. |

### Owner-confirmed policy (previously mislabeled as existing behavior)

- The **30-minute idle timeout** and **6-hour session ceiling** are **new policy additions**, joining the
  existing 200-photo and 500-message caps. Today a live session is unbounded; after P3 it is not.
- **Membership events are wanted** — signed departure/termination/epoch-change records, and rotation
  driven by membership change (fixing the confirmed gap where a voted-out member keeps the group key
  for up to 15 minutes because `applyApprovedRemoval` never rotates).
- **Session-state persistence is an approved, documented policy reversal.** The "deliberately NOT
  Codable" invariant on session types is being deliberately replaced; §17.3 lists every doc guard,
  wipe-wall row, and boundary-test update owed in the same commits.
- **Moderation during partition requires a roster quorum** (owner decision, 2026-08-27): removal needs a
  strict majority of the *current roster*, so a minority partition can never moderate. §10.4.
- **The feasibility spike's purpose** was to prove device↔simulator connection before touching
  ProximityKit — that lane is the standing dev loop (P0 closes it out); the *background* hardware gates
  move into P8 where they belong.

---

## 2. Verified ground truth (what the code actually is)

From the 2026-08-27 three-agent audit (details in memory note `mesh-background-plan-review-2026-08-27`):

- **Transport leak:** `MultipeerTransport.send(_:to:mode: MCSessionSendDataMode)` is the only reason
  `ProximityCoordinator.swift` and `MultipeerTransport.swift` import MC. Five shipping files touch MC
  APIs at all; the real blast radius is `MultipeerPeer.underlying: MCPeerID` threaded through ~40
  signatures, and `PeerSlot.id == peer.id` couples QR-ceremony and admission bookkeeping to the
  per-discovery UUID minted in `MeshMultipeerSession.peer(for:)`.
- **Four radios**, each its own `MeshMultipeerSession`: `fernlet-friend` (mesh), `fernlet-near`
  (presence, deliberately **ephemeral** MCPeerID for unlinkability), `fernlet-recipe`, `fernlet-coach`.
  `PeerChannelTransport` is consumed by MeshNetworkManager, PresenceManager, and
  ProximityRecipeShareManager. The `pauseDiscovery`/`resumeDiscovery` contract (invite-while-paused is
  dropped loudly) is load-bearing for the recipe radio.
- **Membership = sockets:** `onPeerDisconnected → removeSlot` unconditionally; committed peers get no
  retry (reconnect is pre-commit only, 3 attempts); `stopSearching()` clears slots, group key, and
  messages; `sessionID` is minted per process; nothing about a session persists.
- **Epoch machinery exists**: lowest-fingerprint coordinator election, 20 s beacon, 45 s liveness,
  15-minute timer rotation, `meshKeyRotation`/`meshKeyAck`/`meshRotationSync` payloads, per-slot
  `joinedEpoch`, `epochLog` (cap 8), removal voting (`meshRemovalProposal`/`meshRemovalSecond`),
  signed admission (`meshAdmissionRequest`/`Grant`/`Token`). It is time-driven only.
- **Crypto/identity is transport-clean:** IdentityService, envelopes, verification, trust vault, and
  UWB ranging (`RangingProvider` exchanges opaque `Data` tokens inside the signed intro) have zero MC
  types. The QR ceremony keys on slot UUIDs, not MC identities.
- **Eleven payload handlers** ride the friend radio behind the `ProximityCapability` handshake,
  including the 13+ chat age gate enforced at advertise/send/receive.
- **`sessionGoodbye`** is one generic signed byte for both "I'm leaving" and "session over", with a
  frozen English display literal (`"Session ended"`) inside the signed bytes.
- **Persisted today:** trust vault (via snapshot), photo-wall cache + prefs, activity ledger, heart
  ledgers/outbox/dedup/prekeys, moderation ledgers, `FernletPeerID.archive`. **Not persisted:** every
  piece of live-session state, by documented design.
- **App-layer gating:** ProximityKit registers no lifecycle observers (except the heart
  ProtectedSidecar). `ContentView` starts/stops discovery and presence on scene/tab changes. A
  transport that survives backgrounding will not be stopped by anything ProximityKit owns.
- **Probe status:** discovery, deterministic dial tie-breaker, QUIC streams + datagrams, and a strong
  TLS-exporter channel binding (signed transcript over meshID ‖ epoch ‖ both signing keys ‖ both
  nonces ‖ exporter hash, using the real keychain identity under the domain-separated
  `fernlet.mesh.probe.channel-introduction.v1` purpose) all work. Gate table unfilled; locked/LPM/soak
  uninstrumented; `maxConnections = 2`; **`MeshNetworkFeasibilityTests.swift` does not compile** (two
  errors); three Info.plist keys ship unconditionally in Release; probe strings missing from the string
  catalog; the TLS-exporter label is a bare string.

---

## 3. Design invariants (new, stated once, enforced everywhere)

1. **Membership ≠ connectivity.** A socket is a delivery opportunity. Membership changes only via
   signed records (admission, departure, removal, termination) or ceiling expiry — never via link loss.
2. **Partition tolerance by construction.** All durable mesh state is a **union of signed immutable
   records** (grow-only sets keyed by unique IDs): admissions, departures, removals, termination,
   content manifests, chunks, receipts. Merging two views = set union + deterministic re-derivation.
   Connectivity affects *latency*, never *correctness*. Anything that cannot be union-merged (the live
   control key, slot rankings, transcript order) must be **derivable** from the merged record sets.
3. **Content encryption is independent of the group key.** Every routed item gets its own content key,
   wrapped per recipient X25519 identity, under a signed manifest with an immutable destination set.
   The group key protects live control traffic only. (This is what makes splits harmless — see §10.)
4. **Bounded everything** (Power of 10): roster, partitions, epochs, chunks, cache bytes, retries,
   inventory sizes, vote windows — every structure in this plan carries an explicit cap.
5. **Admission is foreground-only.** Background operation may reconnect and sync *existing authenticated
   members of the current unexpired mesh*; it never admits, never rediscovers old meshes, and relaunch
   never silently reconnects — the foreground UI offers resume.
6. **Durable before acknowledged.** No custody or receipt is emitted for state that would not survive a
   force-quit (no expiration callback exists to save you).
7. **Fail-closed sealed sidecars.** Loaded / absent / deferred(protected-data) / corrupt are distinct;
   deferred is never treated as empty and overwritten.
8. **Tokens never localize.** All new wire vocabulary is frozen English tokens; display text is forked
   from day one. `sessionGoodbye` is frozen/parked per the EnumDecodeCompat pattern, never reused.

---

## 4. Target architecture

```mermaid
flowchart TD
    subgraph App target
        LP["ProximityRunPolicy (P7)\nscene + tab + lock + age + continuation → per-radio run states"]
        CC["MeshContinuationCoordinator (P8)\nBGContinuedProcessingTask, progress, deadlines"]
        CR["CompanionBackgroundRefreshCoordinator (P10)"]
    end
    subgraph ProximityKit
        PC["ProximityCoordinator (neutral PeerTransport)"]
        MM["MeshNetworkManager"]
        CTX["MeshSessionContext (P3)\nroster, records, epochs — persisted sealed"]
        RT["MeshRoutedStore (P5)\nmanifests, chunks, receipts — sealed, 256 MiB cap"]
        NS["NetworkMeshSession (P2)\nQUIC listener+browser+connections"]
        MC2["MeshMultipeerSession (legacy, P9 retires)"]
    end
    LP --> MM
    CC --> MM
    PC --> NS
    PC --> MC2
    MM --> CTX
    MM --> RT
    NS -->|"_fernlet-mesh2._udp QUIC"| NS2["peer devices"]
```

---

## 5. Phase P0 — housekeeping and spike closure — **BUILT** (2026-08-29)

Small, unblocking, land first. Every item below is done except one, called out honestly in item 5:
the device↔simulator lane still has no hardware result, because no session that has touched this
plan has had a physical iOS 26.5 device. The runbook now has somewhere to record it.

1. ~~**Fix the compile blocker.**~~ **BUILT** — landed earlier, in `c29da7b`'s test-debt repair.
   `MeshNetworkFeasibilityTests.swift` calls `displayName(peerToPeerIncluded:)` and never references
   `includesPeerToPeer`; the test target builds clean.
2. **Register crypto labels: BUILT.** Seven entries added to `FernletCryptoPurpose`, taking the
   registry from 47 to 54, each carrying a `///` comment that says what it is for and that it is
   reserved rather than in use:
   - `Signature.meshChannelIntroductionV1` — `fernlet.mesh.channel-introduction.v1`, `.lengthPrefixed`
   - `Signature.meshRoutedManifestV1` — `fernlet.mesh.routed-manifest.v1`, `.lengthPrefixed`
   - `KeyDerivation.meshProbeTLSExporterV1` — `fernlet.mesh.probe.tls-exporter.v1`, moved out of the
     probe, which now reads the constant instead of a bare string literal
   - `KeyDerivation.meshTLSExporterV1` — `fernlet.mesh.tls-exporter.v1`
   - `KeyDerivation.meshRoutedContentKeyWrapV1` + `AEAD.meshRoutedContentKeyWrapV1` — the two halves
     of P5's per-recipient content-key wrap, mirroring the shipped `meshGroupKeyWrap` pair
   - `AEAD.meshRoutedItemV1` — the routed item's own content-key seal

   **Two judgement calls to know about.** The framing on the two signature purposes is a
   *reservation*: nothing has signed under either spelling, so P2/P5 may still change it — but they
   must change the serializer and the registry together, which is exactly the pairing that broke in
   `91c3956`. And `AEAD.meshRoutedItemV1` is one entry beyond what P0 literally asked for: a wrap
   purpose with no item purpose would leave P5 to invent the second spelling alone, which is how
   copy-paste collisions enter a registry.

   `CryptographicDomainSeparationTests.allDomains` grew the matching seven rows, so the all-pairs
   uniqueness and key-distinctness sweeps now cover them, and
   `MeshNetworkFeasibilityTests.probeAndProductionMeshLabelsAreSeparateDomains` pins the property the
   probe/production split exists for: the spike can never derive the shipping build's exporter secret.
3. **Info.plist decision: BUILT** — recommendation accepted, keys kept. §4c of
   [No-Tracking-Wall.md](No-Tracking-Wall.md) still described the proximity layer as
   MultipeerConnectivity + NearbyInteraction over `_fernlet-*`. It now tabulates all three local-only
   paths (MC, NearbyInteraction, the DEBUG QUIC probe) with their service types, gives each of the
   three plist keys a row saying why it ships in Release for a probe that does not, and names the
   `NWConnection` → `NetworkConnection` marker gap as deliberate-and-scheduled (§7.4) rather than
   leaving it to be discovered.
4. **String catalog: the probe's strings landed, but the gate is still RED — and it was already red
   before this round.** `Scripts/sync-string-catalogs.sh --check` reports every SPM module clean
   (ProximityKit included, 63 stringsdata) and `App/Fernlet/Localizable.xcstrings` **stale**, over
   nine keys the current source no longer produces:

   `- %@`, `--`, `…`, `· %lld servings`, `%@ - %@`, `%@ – %@`, and three sentence keys about photo
   deletion, "logged to today", and the System appearance setting.

   All nine are present in the file **as committed at `f4fa541`**, and the sync's output is a pure
   function of the source — so the check fails on the committed tree, independent of anything this
   round did and independent of the uncommitted churn another session has in that file. Nothing in
   P0 or P1 adds a user-facing string; the staleness is leftover from an earlier round that deleted
   UI without re-syncing.

   **Deliberately not fixed here.** The fix is one write-mode `Scripts/sync-string-catalogs.sh` run,
   which rewrites exactly the file a concurrent session was actively editing when this round started
   — the one file this round's launcher names as off-limits. It is a one-command fix on a quiet tree
   and belongs to whoever owns that file next.
5. **Runbook closure: STRUCTURE BUILT, one lane still owed to hardware.** The gate table had only
   *Check* and *Required result* columns — nowhere to record what happened. It is now two lanes with
   **Result** and **Date** columns:
   - **Lane A (device↔simulator).** Discovery, QUIC connect, control stream, datagram, and on-radio
     channel binding read **"Not yet run"**, because they have not been. No session that has touched
     this plan has had a physical iOS 26.5 device, and the probe's own discovery policy makes a
     simulator↔simulator run impossible by design (each side refuses a simulator peer). The three
     rows the radio-free suite genuinely proves — off-radio channel-binding rejection, dial policy,
     plist configuration — carry a real Pass and date, listed *beside* the empty ones so the gap is
     legible instead of papered over.
   - **Lane B.** The locked / background / Low Power Mode / soak / battery / force-quit / partition
     rows read **"Deferred to P8 — see plan §15.x"**. A blank cell reads as untested; a deferred cell
     reads as scheduled.

   The runbook's opening "do not begin the transport-abstraction phase until the gate has an approved
   result" is superseded, and now says so: MC deprecation is iOS 27, and P1/P2 have unconditional
   value. **Owner action: Lane A is one sitting with a phone.**
6. **Probe upkeep: BUILT.** `maxConnections` is 4 — the runbook's four-device step was impossible at
   2 — and the cap's own event string interpolates the constant instead of saying "two". The P8
   counters are `bytesSent` / `bytesReceived` (every control frame and datagram now routes through
   four counted wrappers, so the numbers are exact rather than estimated), `connectCount` with
   first/last timestamps, `reconnectCount` with its timestamp, and thermal-state / Low Power Mode
   readings.

   Two deliberate shapes. The **counters are fields, not ring entries**: the ring holds 80 events and
   a six-hour soak fires 720 heartbeats, so a counter kept in the ring would measure nothing. And
   **power state is recorded on CHANGE only**, sampled at the connect, re-dial and heartbeat paths
   P8 correlates against — a steady soak costs one line, a throttling one shows exactly when. All of
   it lands in the copied diagnostic report, which is the only way numbers leave a device the
   developer cannot attach a debugger to; `theDiagnosticReportCarriesTheP8GateCounters` pins that.
7. **Docs: BUILT.** The FileIndex / ProximityFunctionIndex entries for the Feasibility directory
   landed with the spike; the runbook now cross-links this plan from its Status section and states
   which of its rows gate what.

Acceptance: full gauntlet green (`power-of-10-scan.py`, `spm-wall-check.sh`, S3 + no-tracking +
localization boundary tests, doc coverage), runbook gate table has no empty cells.

---

## 6. Phase P1 — transport neutrality — **BUILT** (2026-08-29)

Goal: remove MC types from the shared protocol surface with **zero behavior change**, so P2 can slot in
beside MC and the other three radios keep working untouched.

**Result:** no `MultipeerConnectivity` symbol survives outside
`Transport/MeshMultipeerSession.swift` and `Transport/MCPeerIDStore.swift`. `ProximityCoordinator`,
`MeshNetworkManager`, `PresenceManager` and `ProximityRecipeShareManager` no longer import the
framework at all. The whole existing proximity suite — 25 suites — passes unchanged through the new
abstraction over the MC adapter, and two golden vectors pin the one field that could have moved a
signed byte.

### 6.1 The thing the sketch above got wrong: `id` is not an identity

The target surface as drafted has `PeerHandle` carrying `id` and `displayHint`, with the transport's
routing token kept private. That is right about the routing token and **wrong about `id`**, and
building it as drafted would have deleted a load-bearing check with no compile error and no test
failure.

Seven sites across the three radio managers were written as
`$0.peer.id == peer.id || $0.peer.underlying == peer.underlying`. The disjunct is not defensive
padding. `MeshMultipeerSession.peer(for:)` mints a **fresh UUID on every cache miss**, and the cache
is evicted when a peer is lost while holding no channel — and, more importantly, is simply absent
for an inbound invitation from a device the transport is not currently tracking, because
`advertiser(_:didReceiveInvitationFromPeer:)` calls `peer(for:)` *before* `prepareChannel`. So
`a.id == b.id` implies "same device", but "same device" does **not** imply `a.id == b.id`. `id` is a
false-negative-only test; `MCPeerID` equality was the total one.

The rationale lived in `Docs/CODE_REVIEW_2026-06-12.md` finding #19 ("Committed peer slots leak when
browser lostPeer fires before session .notConnected"), which was deleted from the tree in `cee2a31`.
No surviving comment explains it — the ones that exist ("the SAME peer re-inviting is always let
through") read as an `id` question — and **no test covered it**: every test peer is built with its
own fresh `MCPeerID`, and two separately constructed `MCPeerID`s are never equal, so the disjunct
could have been deleted outright and the suite would have stayed green.

What it costs when the match is missed, per site: a slot that is never removed on disconnect keeps
its seat against `maxTotalSlots` and its coordinator is never cancelled, so `end()` never runs —
ranging is not invalidated, the foreground Live Activity anchor is orphaned until the system's time
cap, and no `.sessionEnded` audit is written; a heart connection leaks one of four slots with an
in-flight send that never surfaces its failure; and a reconnecting recipe partner is refused by the
cap it already occupies, with the radio staying paused because reopening is keyed on record eviction.

So the built surface adds one type and one method:

```swift
public nonisolated struct PeerEndpointKey: Hashable, Sendable { /* opaque, process-local */ }

public func isSameEndpoint(as other: PeerHandle) -> Bool { id == other.id || endpoint == other.endpoint }
```

`isSameEndpoint(as:)` is now the single spelling of the "same device?" question; the seven sites call
it and the MC→QUIC swap touches one line instead of seven. `MeshMultipeerSession` keeps a private,
bounded (FIFO, cap 64) `MCPeerID ↔ PeerEndpointKey` mapping that is deliberately **not** pruned
alongside `peerMap`: `MCPeerID` equality is unaffected by our cache, so pruning would narrow the
identity test rather than preserve it. It is memory-only, per session instance, and links nothing the
presence radio's ephemeral-`MCPeerID` posture does not already link — so it owes no wipe-wall row.

### 6.2 Deviations from the sketch, and why

- **`PeerHandle` keeps `discoveryInfo` and `advertisedFingerprint`.** Dropping them would not have
  been neutral: five keys are read off a peer in shipping (`sid`, `v`, `t`, `name`, `fp`), including
  the deterministic single-inviter rule that once deadlocked the mesh, the presence friend-matching
  tag set, and the recipe-share recipient label. All five are Fernlet's own vocabulary, not
  MultipeerConnectivity's, so they survive a transport swap unchanged.
- **`displayHint` is renamed but is not yet purely a hint.** Two readers use it for more than
  display, and the doc comment names both rather than letting the new name assert something false:
  `ProximityCoordinator.shouldInviteDiscoveredPeer` uses `displayName < peer.displayName` as the
  last-resort inviter tie-break when neither side advertises a session id, and `PresenceManager`
  compares it against its own ephemeral names to filter its own ghost advertisements. Re-homing both
  is P2/P9 work (§7.2, §17.1); doing it here would have been a behaviour change.
- **`PeerTransportError` was renamed too**, though the sketch does not name it — it is the payload of
  `PeerTransportState.failed`, so leaving it would have left an MC-named type on the neutral surface.
- **`MultipeerServiceType`, `MCPeerIDStoring`, `FileMCPeerIDStore` and `MockMultipeerTransport` keep
  their names.** The first three are genuinely MC-shaped and retire with MC in P9 —
  `FileMCPeerIDStore` in particular is a named row in the privacy-wipe ledger, which is the worst
  place to take an unplanned rename. The mock is 78 references across 16 test files for no behavioural
  gain; renaming it would bury the real diff.
- **The sketch's naming collides with itself** — it calls both the protocol and the test fake
  `PeerTransport`. Resolved: the protocol is `PeerTransport`, the fake is `FakePeerTransport`.

### 6.3 What landed

| | |
|---|---|
| New | `Transport/PeerHandle.swift` (`PeerHandle`, `PeerEndpointKey`), `Transport/PeerTransport.swift` (`PeerTransport`, `PeerTransportState`, `PeerPendingInvite`, `InboundPeerFrame`, `PeerTransportError`, `PeerDeliveryMode`), `Transport/MCPeerIDStore.swift` (split out unchanged) |
| Changed | `MeshMultipeerSession` holds the only `MCSessionSendDataMode` mapping (`.bestEffort → .unreliable`) and the only `MCPeerID` lookup; the three radio managers and the coordinator dropped `import MultipeerConnectivity` |
| Tests | `PeerHandleIdentityTests` (the endpoint rule, previously untested), `FakePeerTransportTests`, `PeerHandleWireGoldenTests` |
| Fake | `Mocks/FakePeerTransport.swift` — `VirtualClock` + `FakePeerNetwork` + `FakePeerTransport`: scriptable connect/disconnect/latency/partition/heal, n-way splits, and **no wall-clock sleeps anywhere**. Time moves only when a test advances it, so a §16.2 scenario either settles deterministically or fails visibly. Mid-flight frames re-check reachability at arrival, so a partition opened after a send still drops the frame; healing never replays what was dropped, because convergence is the application's job (§10.3). |

### 6.4 Findings for the owner — real, and deliberately NOT fixed here

Each of these is a behaviour change, which P1's neutrality contract forbids. They are named so P2
does not inherit them silently.

1. **`shouldAdmitChannel` and `handleChannelReady` disagree about identity** in
   `ProximityRecipeShareManager`. The first uses the endpoint test, the second is `id`-only
   (`guard !connections.contains(where: { $0.peer.id == channel.peer.id })`). A re-minted reconnect
   is therefore *admitted* by the first and *appended as a second connection record* by the second —
   breaking the hard two-device cap from the inside. Same split exists in mesh
   (`MeshNetworkManager` :2051, :2548) and presence.
2. **`locallyKickedPeerIDs` and `peerRetryCount` are keyed by `peer.id`** beside a slot lookup that
   uses the endpoint test. Review finding #19 called this out explicitly and it was never closed:
   the slot lookup survives an identity churn, the kick/retry bookkeeping next to it does not.
3. **`PeerSlot.id == peer.id` propagates the unstable handle into trust bookkeeping** — the QR
   ceremony's `pendingQRVerifications`, `outstandingAdmissionRequestBySlot`, photo-send tracking,
   shop-catalog dedupe. A QUIC transport that mints a fresh id on reconnect changes that behaviour,
   and the verification tests drive slot ids directly so they would not catch it.
4. **`advertisedFingerprint` is always `nil` in shipping.** `"fp"` is published only by
   `ProximityCoordinator.discoveryInfo(for:mode:)`, which is handed to
   `PeerChannelTransport.startAdvertising` — an empty no-op. So the fingerprint-mismatch gate is
   vacuous today, and the intro/ack/heartbeat envelopes ship `recipientFingerprint: nil`, which the
   envelope format defines as *broadcast*, so the recipient-binding check never binds on them. **A P2
   transport that actually delivers a TXT `fp` would activate all of that at once** — a behaviour
   change disguised as a port, and one that moves signed bytes. `PeerHandleWireGoldenTests` pins both
   the bound and the broadcast vectors so the flip is loud when it happens.
5. **`meshID`, `meshName` and `memberCount` are advertised and never read** by any peer
   (`MeshNetworkManager` :1976-1978). A faithful port carries three dead keys into the new TXT
   record; dropping them passes every test while changing what a passive Bonjour scanner sees.
6. **Five coordinator branches are unreachable in production** — `PeerChannelTransport` only ever
   emits `.idle` / `.connected` / `.disconnected`, so `handleDiscoveredPeers`,
   `shouldInviteDiscoveredPeer`, `acceptPendingInvite` and the two awaiting-acceptance arms are
   driven by the mock alone. The live inviter decision is `MeshNetworkManager.shouldInitiateInvite`,
   covered by two tests. P2's dial policy needs its own symmetry test rather than inherited
   confidence — this comparison deadlocked the mesh once already.

### 6.5 Root fix considered and deferred

The churn exists only because the endpoint→UUID mapping shared a dictionary with the one discovery
prunes. Splitting them so `peer(for:)` returns a *stable* `id` for the life of a session would make
`id ==` a true identity test, fix findings 1–3 for free, and collapse `isSameEndpoint(as:)` to a
single comparison. It is a behaviour change, so it is not P1 — but it is the cheapest place to close
findings 1–3 together, and P2 is the natural home. **Privacy constraint if it is done:** the map must
stay session-scoped and cleared at teardown; the presence radio's whole posture is a per-start
random, never-persisted identity, and a persisted map would both weaken that and owe a wipe-wall row.

Work items:

```swift
public enum PeerDeliveryMode { case reliable, bestEffort }

public struct PeerHandle: Hashable, Sendable {
    public let id: UUID              // stable per discovery, == PeerSlot.id (preserves QR/admission keying)
    public let displayHint: String   // advertised instance name, display only — never identity
    // transport-opaque routing token lives inside the owning transport, keyed by id
}

public protocol PeerTransport: AnyObject {
    func send(_ frame: Data, to peer: PeerHandle, mode: PeerDeliveryMode) async throws
    func disconnect(_ peer: PeerHandle) async
    func pauseDiscovery()            // preserved contract: invite-while-paused fails loudly
    func resumeDiscovery()
}
```

Work items:
- Replace `MCSessionSendDataMode` in `MultipeerTransport` with `PeerDeliveryMode`; map inside
  `MeshMultipeerSession` (`.reliable → .reliable`, `.bestEffort → .unreliable`). This alone drops the
  MC import from `ProximityCoordinator.swift` and `MultipeerTransport.swift`.
- Introduce `PeerHandle` and migrate the ~40 `MultipeerPeer` signature sites. `MeshMultipeerSession`
  keeps its `MCPeerID ↔ id` map private. `FileMCPeerIDStore` stays (P9 retires it).
- Rename the protocol family to neutral names (`PeerTransportState`, `PeerPendingInvite`,
  `InboundPeerFrame`); keep the MC conformer as the only implementation.
- Deterministic fake transport for tests: in-memory `PeerTransport` with scriptable connect/disconnect/
  latency/partition schedules — this fake is the foundation of §16's partition tests, so build it well
  (injectable clock, no wall-clock sleeps, per the load-sensitive-flake lessons).
- Wire payloads, capability handshake, sealing, framing: untouched.

Acceptance: entire existing proximity test suite green through the neutral abstraction over the MC
adapter; no wire change (byte-identical frames verified by a golden test).

---

## 7. Phase P2 — NetworkMeshSession (the TN3213 mapping) — **BUILT** (2026-09-01)

A second `PeerTransport` conformer used only by `MeshNetworkManager`. The other radios stay on MC until P9.

**Result:** `NetworkMeshSession` ships beside `MeshMultipeerSession` — Bonjour listener and browser
over `_fernlet-mesh2._udp`, one authenticated QUIC tunnel per peer, an exporter-bound signed channel
introduction with twelve named rejections, and per-transfer streams beside the long-lived control
stream. `MeshNetworkManager` picks its radio through a `MeshTransportSession` seam; **a Release build
can only answer MC**. Two Simulators on one Mac now run the *shipping* mesh over real QUIC (runbook
Lane C): the rejection matrix was driven 6/6 against an accepted baseline, six app flows crossed in
both directions, and a verified pair holds one tunnel for a 170-second run with heartbeats flowing
over datagrams both ways. `NetworkMeshSession.swift` names no MultipeerConnectivity type, so P1's
containment permit list did not widen by one entry.

§§7.1–7.4 below are the sketch, kept as the specification. §7.5 records what landed, §7.6 where
reality moved the design and why, §7.7 what was deliberately left undone, and §7.8 what the phase
proved about the testing lanes — which is the largest thing P2 changed about the phases after it.

### 7.1 Concept mapping (TN3213)

| MC concept (current use) | Network.framework replacement |
|---|---|
| `MCNearbyServiceAdvertiser` | `NetworkListener` over `.bonjour(name:type:txtRecord:)`, type `_fernlet-mesh2._udp` |
| `MCNearbyServiceBrowser` | `NetworkBrowser(.bonjour(type, includeTxtRecord: true))` |
| Invitation handshake + pause contract | Dial policy: deterministic tie-breaker (probe's `localServiceName < candidate` rule), listener `newConnectionLimit`, explicit app-layer accept gate before any app frame; `pauseDiscovery` = stop browser + set limit 0 |
| `MCSession` (one object, N peers) | One authenticated QUIC `NetworkConnection` per directly reachable peer, owned by a session actor |
| `.reliable` sends | QUIC streams: one long-lived **control stream** per connection (identity, membership records, manifests, receipts, rotation) + independent per-transfer streams for photo chunks |
| `.unreliable` sends | QUIC datagrams (heartbeats; ranging chatter stays on the intro/control path as today) |
| `MCSessionState` | Connection state feeds *presence*, never membership (P3 owns membership) |
| MC "encryption required" | TLS 1.3 + the probe's exporter-bound signed introduction, productionized (§7.2) |

### 7.2 Productionizing the probe's security

- Replace the trust-all `certificateValidator` and the hardcoded DEBUG identity: each device mints an
  **ephemeral per-mesh self-signed P-256 TLS identity** at session start (never persisted, never reused
  across meshes — TLS identity is not Fernlet identity). Authentication comes solely from the signed
  channel introduction: transcript = purpose ‖ version ‖ meshID ‖ epochRef ‖ both signing pubkeys ‖
  both nonces ‖ TLS-exporter hash, Ed25519-signed by both sides under
  `fernlet.mesh.channel-introduction.v1`, verified against the trust vault / current roster. If the
  exporter secret is ever unavailable on a future SDK, the documented fallback is signing over both
  peers' TLS certificate fingerprints (decide only if forced; note in the runbook).
- Reject before any app frame: unknown identity, non-roster member, hard-departed/removed member,
  ended/foreign meshID, introduction failure, or replayed nonces (per-session nonce cache, bounded).
- ALPN `fernlet-mesh-v1`; explicit length framing stays `SealedPayloadFraming` (wire2), and the QUIC
  receive-window/frame caps move in lockstep with `maxInboundWireBytes` exactly as the MC comment
  demands today.
- Interface policy: `peerToPeerIncluded(true)` on device (per TN3213, with Apple's performance caveat
  acknowledged), **`prohibitedInterfaceTypes = [.cellular]` always** — the serverless/no-internet claim
  becomes enforced, not aspirational. Simulator lane: infra only (probe's TXT asymmetry pattern).
- Bonjour instance name: **random per session** (not derived from stable identity — an improvement over
  the archived MCPeerID: no cross-session tracking surface; identity is proven cryptographically).

### 7.3 Session actor duties

Connection set (cap = roster cap 8, §9), per-connection state machine, dial retry (3 attempts, 2 s,
matching today), duplicate-tunnel suppression via the tie-breaker, endpoint cache for direct re-dial
(so reconnection never depends on background Bonjour — feeds P8), heartbeat datagrams (30 s), and
surfacing `InboundPeerFrame`s upward unchanged.

### 7.4 No-tracking wall extension (same commit as the transport)

`NWConnection`/`NWBrowser` are banned markers today; the new API names pass through a gap. Extend
`NoTrackingBoundaryTests`' marker list with `NetworkConnection`, `NetworkListener`, `NetworkBrowser`,
`NWListener`, `NWParameters`, and permit exactly the ProximityKit transport files (and the DEBUG probe),
updating [No-Tracking-Wall.md](No-Tracking-Wall.md) §4c/§5 in the same commit. The wall stays meaningful
instead of accidentally porous.

Acceptance: mesh flows (admission, QR ceremony, photos, chat, hearts, shop, moderation, capabilities,
age gates) pass on the QUIC transport on the device↔simulator lane and on 2 physical devices;
`spm-wall-selftest.sh` and the extended no-tracking tests green.

**Acceptance as judged, 2026-09-01.** Met on a lane the sketch did not know existed and did not
predict: **simulator↔simulator**, two instances of the shipping app on one Mac (§7.8). Six flows —
slot commit, capabilities, chat, photos, shop, and both halves of the 13+ chat age gate — were
observed crossing in both directions, and the whole rejection matrix P2 can reach was driven against
an accepted baseline. Three named flows were **not** met and are recorded rather than papered over:
hearts and moderation (app-state preconditions, §7.7 finding 2) and stranger admission (P3's
question, finding 3). The two-physical-device half is item 11 and is still owed; the walls
(`spm-wall-selftest.sh`, the extended no-tracking family, Power of 10, doc coverage) were green at
every landing below, and so was the `FernletTests` suite.

### 7.5 What landed

| # | Work | SHA |
|---|---|---|
| 0 | **Sim↔sim experiment: CONNECTED.** Two Simulators complete Bonjour discovery, QUIC/TLS and the signed introduction on one Mac — multi-node testing needs no hardware | `926a791` |
| 3 | **§6.5 root fix taken.** `SessionPeerIdentity` minted once per peer, session-scoped, cleared at teardown; §6.4 findings 1–3 closed with it | `b8d7a5a` |
| 3b | RecipeShare + Presence ready paths recognize a peer the way their own gates do | `2a03800` |
| 3c | `sendHeart`'s outbound gate recognizes an existing connection by endpoint, not `id` | `8c258b5` |
| 3d | **The id-vs-endpoint family CLOSED** — 14 sites, with the exhaustive per-site audit table in the commit message. Do not re-audit it | `2f273a9` |
| 4 | Dial tie-breaker pinned exhaustively before any QUIC code — 18 tests, both sides of every pair; a late TXT only ever *withdraws* dial permission, so double-dial is possible pre-TXT and deadlock is not | `ce91f5d` |
| 5 + 6 | `NetworkMeshSession` skeleton — the whole §7.3 duty list in one slice, 47 tier-1 tests — and the no-tracking wall's **second** marker family (`localLinkMarkers` + `permittedLocalLinkFiles`, disjoint from the HTTP family by test) | `5835b52` |
| 7 | Signed channel introduction productionized: 12 named rejections, each a teardown; exporter label `KeyDerivation.meshTLSExporterV1`; `MeshIntroductionAuthority` seam minted | `48b0c5c` |
| 8 | Transport selection in the manager. `FERNLET_MESH_TRANSPORT=quic` is DEBUG-only and read once per launch; Release can only answer MC; the manager *is* the introduction authority; the manager's invite path finally reachable at tier 1 | `099727d` |
| 9 | Rejection matrix **6/6 plus an accepted baseline, observed on the real radio** (runbook Lane C) | `7357110` |
| 13 | A verified pair converges to one tunnel — tier-1 repro red before the fix, and item 9's "two tunnels" reading corrected to churn (Lane C cannot form the duplicate) | `96337a3` |
| 14 | The test-hook wall learns the `FERNLET_MESH*` / `FERNLET_PROBE*` families, per-family floors; a planted Release-reachable read trips it by name | `7ff49fc` |
| 15 | Churn root-caused: QUIC's `max_idle_timeout` ≈ the heartbeat interval. **And the datagram record inverted — datagrams work; the recorded zero was a wrong-object accessor** | `a9597d3` |
| 10 | Six app flows observed over QUIC; per-transfer photo streams; the **contiguous-write fix** for control-stream desync | `596bcf8` |
| — | Hygiene: the heartbeat flake test observes its condition instead of racing it | `3ca3ddb` |

| | |
|---|---|
| New (ProximityKit) | `Transport/NetworkMeshSession.swift`, `MeshChannelIntroduction.swift`, `MeshLinkTable.swift`, `MeshLinkAdvertisement.swift`, `MeshHeartbeatSchedule.swift`, `MeshTransferStreamTable.swift`, `EphemeralMeshTLSIdentity.swift`, `MeshTransportSelection.swift`, `MeshTransportDebugHooks.swift` |
| New (app target, DEBUG) | `Proximity/Feasibility/MeshRejectionMatrixHarness.swift`, `MeshFlowDriver.swift` — the Lane C drive mechanism |
| Changed | `MeshNetworkManager` owns a `MeshTransportSession` rather than a concrete `MeshMultipeerSession`, and conforms to `MeshIntroductionAuthority`; `MeshMultipeerSession` gained the two forwarding methods and one deliberately empty one |
| Tests | `NetworkMeshTransportTests` (the skeleton, the introduction, advertisement, heartbeat schedule and convergence suites), `MeshDialPolicyTests`, `MeshTransportSelectionTests`, `Mocks/FakeMeshTransportSession.swift` |

### 7.6 Deviations from the sketch, and why

- **The §6.5 root fix was taken first, before any QUIC code** (§19.4's first decision, answered yes).
  `SessionPeerIdentity` mints one identity per peer for the life of a session, so `id` is a true
  identity test and §6.4 findings 1–3 closed together. It **inverted a documented design intent**:
  the old `stop()` deliberately preserved the endpoint map ("an owner would stop recognizing a
  device"), but all three owners now drop every peer-keyed record in the same teardown, so
  preserving identity across `stop()` protected nothing.
- **`startRadios(discoveryInfo:)`, not `start`.** `MeshMultipeerSession` already owns
  `start(serviceType:discoveryInfo:)` with a defaulted service type, so a same-named protocol
  requirement would have read as direct recursion (Power of 10 rule 1) for no gain. The service type
  became each radio's own affair — which is also what a second radio on a *different* Bonjour type
  needs: the owner never picks one.
- **One `MeshTransportHandlers` value, not five settable protocol properties.** The two radios keep
  their hooks under their own names and types (MC's channel hook is typed to `PeerChannelTransport`,
  QUIC's to `NetworkPeerChannel`), so a settable protocol property would have needed a getter no
  conformer could honestly answer. `wire(_:)` takes the whole set and each conformer forwards it to
  whatever it actually keeps. The invitation gate defaults **closed**: a radio with no
  `shouldAcceptInvitation` refuses, exactly as MC's advertiser does today (`?? false`).
- **Inbound tunnels park as *pending* until a verified `sid` ranks them.** §7.3 said "connection set,
  cap 8"; an inbound QUIC connection arrives with no advertisement and therefore no key to file it
  under. It is booked against a separate `maxPendingInboundTunnels` bound, swept at a ten-second
  introduction deadline, holds **no roster slot**, and is promoted by
  `admitVerifiedInbound(_:pendingKey:)` onto the key its verified `sid` resolves to — or onto its own
  connection key when nothing resolves. A peer that connects and then says nothing costs a pending
  seat for ten seconds, never a seat against the roster cap.
- **The manager itself is the `MeshIntroductionAuthority`.** The sketch left the roster lookup
  unhomed. `MeshNetworkManager` conforms directly — it is already the holder of mesh id, epoch,
  roster and signing key — and the radio receives it through
  `MeshTransportSession.attachIntroductionAuthority(_:)`. **A nil authority refuses every tunnel**,
  the only fail-closed default available. MC's conformance is deliberately an *empty* method: that
  radio authenticates inside `ProximityCoordinator`'s signed identity introduction over an
  already-established link, and holding a reference it never reads would be the misleading half.
- **The QUIC idle timeout is declared, at 3× the heartbeat, on both parameter sets.** Left at the
  framework default it sat near 30 s — the same number as `MeshHeartbeatSchedule.intervalSeconds` —
  so QUIC reaped every tunnel a moment before its first beat was due, silently, with nothing refused
  and no budget spent (item 15). `idleTimeoutMilliseconds` is now
  `intervalSeconds × missedBeatsBeforeIdleReap`, and it is set on **the listener as well as the
  connection**, because QUIC negotiates the minimum of the two advertised values and a defaulted
  listener would pull it straight back under the interval. Dead-peer detection did not weaken, it
  moved to where it belonged: the app's heartbeat detects, QUIC's timer backstops three beats later.
  The same commit stopped a failed heartbeat *write* from ending a tunnel — a datagram that will not
  go now latches the beat onto the control stream, and only a beat the reliable stream also refuses
  ends anything.
- **Every frame is one contiguous write.** `sendFramed` originally wrote the length prefix and the
  payload as two awaited sends. Every frame on a tunnel shares one control stream and
  `MeshNetworkManager` fires its envelopes as independent tasks, so two of them suspending at the gap
  between the sends left the peer reading one frame's header followed by another frame's first four
  bytes — `invalidFrameLength`, tunnel dead, within a second of a slot committing. One buffer per
  frame closes it: concurrent sends may be ordered either way but never interleaved. Latent since
  item 5, and invisible until item 10, because item 15's stable tunnel never sent an app frame.
- **The TXT record carries `sid` and withholds `fp`** (§19.4's other two decisions). `sid` is what
  `shouldInitiateInvite` ranks, and the DEBUG probe's TXT carries none — it ranks Bonjour service
  names — so copying the probe's advertisement verbatim would have degraded the production tie-break
  to *both sides dial*: one duplicate tunnel per pair, every pair, with nothing failing. `fp` is
  neither published **nor believed inbound**, because accepting a fingerprint claim this build does
  not make itself would turn an unverified peer-supplied string into a fatal-mismatch lever;
  publishing it activates §6.4 finding 4's vacuous gates and moves signed bytes, so it stays a wire
  decision with a golden vector attached. `MeshLinkAdvertisement` is deliberately **one** bounded
  function serving both directions — asymmetry between publish and believe is exactly how a peer gets
  a field into a handle this build would never advertise.
- **The conformer never emits `.discovered`.** Discovery reaches the manager through
  `onPeerDiscovered` and the invite decision stays `MeshNetworkManager.shouldInitiateInvite`, exactly
  as on MC. So §6.4 finding 6 is *unchanged*, not closed: the coordinator's five discovery branches
  remain mock-driven, and §7.7 finding 4 is the live consequence of leaving them that way.
- **Two things the sketch did not ask for.** Photos got their own per-transfer QUIC streams beside
  the control stream (§7.1 named them; item 10 built them and observed both directions through both
  acceptors — an odd stream id is server-initiated, an even one client-initiated). And every tunnel
  end now names a cause: `MeshTunnelEndReason`, six frozen tokens, permanent `os.log` rather than a
  debug hook. A live tunnel that ended used to log **nothing**, and that silence is what let churn
  masquerade as duplication for an entire investigation — on a device, where there is no console to
  mirror, the disconnect path is exactly where silence costs most.

### 7.7 Findings for the owner — real, and deliberately NOT fixed here

1. **The `sid` that drives duplicate-tunnel suppression rides an unsigned hello field.** §7.2's
   transcript covers purpose ‖ version ‖ meshID ‖ epochRef ‖ both signing keys ‖ both nonces ‖
   exporter hash — it does not cover `MeshChannelHello.sessionID`. Binding it means a transcript v2,
   which moves signed bytes: an owner call, not a port detail. **Cost:** a peer that is *already a
   verified roster member* can misdirect the dedup of its own link by claiming a `sid` that ranks
   against a different browsed advertisement. It cannot reach another pair's links, and the fallback
   when a claim resolves to nothing is admit-both, which is safe. Documented on the field itself.
2. **Hearts and moderation were never exercised over QUIC.** Both gate on *mutual*
   `ProximityTrustVault` rows — app state written by completing `pendingFriendReview` on both devices
   in an **earlier** session — and the flow driver drives one session. This is an app-state
   precondition, not a transport limit; the `moderation` capability itself crossed in every
   capability list observed. They land in P6. **Cost:** two flow types ride an app path over QUIC
   that nothing has exercised until then.
3. **Stranger admission over QUIC is deferred to P3 membership (§8).** An empty roster makes every
   peer a stranger and the introduction refuses the tunnel before any app frame — matrix row 1,
   working as designed. MC remains the admission path meanwhile. **Cost:** the QUIC radio can only
   reconnect existing members; first meetings stay on MC until P3 gives the transport something to
   admit a stranger *into*.
4. **`ProximityCoordinator.shouldInviteDiscoveredPeer` still points the opposite way to the
   manager.** The coordinator returns `sessionID < remoteSID`; `MeshNetworkManager.shouldInitiateInvite`
   returns `localSessionID > peerSessionID`. It is dormant for one reason only: **no conformer emits
   `.discovered`**, so nothing drives the coordinator's discovery arm in production (§6.4 finding 6).
   **Cost:** nothing today — and a mutual deadlock the instant any conformer ever does emit it, which
   is precisely the failure that cost this mesh once already. Align the two **before** wiring any
   transport's discovery to the coordinator, not after.
5. **The epoch gate at introduction is deliberately soft.** Equal **or one side empty** — a joining
   peer holds no group key yet, so strict equality would make admission impossible; two different
   non-empty epochs are `.divergentEpoch`. **Cost:** an empty-epoch claim is evidence of nothing, so
   the gate contributes nothing on a first connection. P3 §8.4's merge rules are what make it
   strict-able; flagged in source at the comparison.
6. **The cross-key double-dial collapse is proven at tier 1 only.** Reaching the double-dial window
   needs a peer discovered **before** its TXT resolves; two Simulators browsing over infrastructure
   Wi-Fi receive the TXT with the browse result, so the `sid` ranks immediately and only one side
   dials. **Cost:** `MeshTunnelConvergence` is held by 14 tier-1 tests and an on-radio *control* run,
   but never exercised on a radio. Producing a late TXT is physical-radio behaviour, so this is a
   **Lane B (hardware) row** — the one P2 residual that genuinely needs physics.
7. **The `x509-self-signature` escape hatch is the first crypto hatch since the standardization
   round.** An X.509 self-signature has no Fernlet domain to name: the transcript is a DER
   TBSCertificate whose bytes the format fixes, so a Fernlet prefix would make the certificate
   unparseable. The census moved 3→4 files and 6→7 hatches, and `Crypto-Domain-Separation.md` was
   updated in the same commit. **Cost:** none technically — but the value of that census is that
   every entry was looked at by a person, so it wants the owner's eyes **as a policy act**.
8. **QUIC is not the default, and MC still ships.** `FERNLET_MESH_TRANSPORT=quic` is DEBUG-only and
   read once per launch; a Release build can only answer MC. **Cost:** none — this is the P2 boundary
   working exactly as designed (§18: "P9 after P2 is proven"). The cost arrives later, as the field
   evidence P9 needs and P2 could not produce.

### 7.8 What P2 proved about the testing lanes

The largest thing this phase changed is not in the transport. **Multi-node testing (3, 4, 6 nodes)
runs on one Mac, with no hardware and no human at all.**

- **Item 0 (`926a791`).** `MeshProbeDiscoveryPolicy` refused a Simulator→Simulator dial on a
  rationale that only ever justified the *device→Simulator* refusal. Relaxed behind a DEBUG toggle,
  two Simulators complete Bonjour discovery, QUIC/TLS and the signed, exporter-bound introduction in
  both directions — they share the host's network stack, so the peer resolves to a routable address
  rather than the host-only link-local one.
- **Lane C is the drive mechanism, and it exists.** `FERNLET_MESH_TRANSPORT`, `FERNLET_MESH_MATRIX`
  (+ `_LABEL` / `_MESH_ID` / `_MEMBERS`), `FERNLET_MESH_FLOWS`, `FERNLET_MESH_CONSOLE_LOG` and the
  `FERNLET_MESH_CHAOS*` hooks drive the **shipping** mesh across Simulators from `simctl` alone.
  Every variable is DEBUG-only, read once per process, **off when absent**, and compiled out of
  Release; the chaos hooks can only ever damage this side's own introduction or add to this side's
  own barred set, so neither can admit a peer that would otherwise be refused. Do not rebuild it.
- **Datagram-borne work is back on this lane (item 15, `a9597d3`).** The earlier "datagrams do not
  negotiate" reading was a wrong-object accessor — `usableDatagramFrameSize` read off the parent
  connection rather than the flow's metadata — and the probe threw on it *before ever sending one*.
  Heartbeats now demonstrably ride datagrams in both directions with that number still reporting
  zero. The assumption that datagram features need hardware is **struck**. The lesson generalizes:
  a negative read off an accessor is not a negative observed on the wire.
- **P8 is explicitly unaffected.** §14/§15 are background, lock, radio physics, battery, thermal and
  OS policy; a Simulator answers none of it (`BGTaskScheduler` returns error 1 there at all). This
  lane pulled work **down** out of P3–P6, not out of P8 — those gates stand exactly as written.

---

## 8. Phase P3 — durable session context, roster, and membership events

**Testing lane (re-tiered 2026-09-01, §7.8).** This phase does **not** need a drawer of phones.
Records, derived roster and the state machine are tier 1 on `FakePeerNetwork` with a virtual clock;
everything that wants ≥ 3 *real* nodes — a departure gossiped by a third member, admission across a
live roster, a rotation crossing two tunnels — runs 3–6 Simulators on one Mac through the Lane C
harness (`FERNLET_MESH_TRANSPORT` / `_MATRIX` / `_FLOWS` / `_CONSOLE_LOG` plus the chaos hooks).
Datagram-borne behaviour is on this lane too: item 15 struck the "datagrams need hardware"
assumption. Physical devices are owed only what §15 lists.

### 8.1 MeshSessionContext (persisted, sealed)

```swift
struct MeshSessionContext: Codable {           // sealed sidecar; see §17.3 for the policy-reversal paperwork
    let meshID: UUID
    let protocolVersion: Int
    let createdAt: Date                        // signed into the mesh descriptor at creation
    let hardDeadline: Date                     // createdAt + 6 h — absolute, identical on every member
    var admissions: [SignedAdmissionRecord]    // grow-only; cap 16
    var departures: [SignedDepartureRecord]    // grow-only; cap 16
    var removals:   [SignedRemovalRecord]      // grow-only (completed removals only); cap 16
    var termination: SignedTerminationRecord?
    var epochHeads: [MeshEpochRef]             // current branch head(s); cap 8
    var lastExternalHeartbeat: Date?
    var developedLocally: Bool                 // set at development; permanent rejoin bar
    var routingInventorySummary: InventoryDigest
}
```

- **Roster is derived, never stored**: `admitted − departed − removed` (termination ends everything).
  Everything else (connected set, coordinator, quorum, "final pair") derives from roster + live links.
- **The group control key is NOT persisted** — it stays memory-only exactly as today. After process
  death, resume performs a reconnect + fresh membership-driven rotation (§8.3); persistence of the
  control key is never needed because content doesn't depend on it (invariant 3).
- Storage: new `MeshSessionStore` sidecar in ProximityKit, sealed with a keychain-backed key (new role
  beside `friendWall`), file protection `.completeUntilFirstUserAuthentication`, four-state load
  (loaded/absent/deferred/corrupt), **per-instance disk root** with a grep-wall test à la
  `PhotoDirectoryIsolationTests` (the shared-disk-root flake family must not grow a new member).
- Only the current, unexpired, undeveloped context is recoverable; expiry or development deletes it.

### 8.2 State machine

```mermaid
stateDiagram-v2
    [*] --> idle
    idle --> joining: user starts/joins (foreground)
    joining --> activeForeground: first peer committed
    activeForeground --> continuingInBackground: scene backgrounds + CPT running
    continuingInBackground --> activeForeground: foreground
    activeForeground --> partitioned: links lost, roster peers remain
    continuingInBackground --> partitioned
    partitioned --> activeForeground: links restored (merge, §10)
    partitioned --> localIdleStop: 30 min no external heartbeat
    localIdleStop --> activeForeground: foreground resume within ceiling (rejoin-as-merge)
    activeForeground --> handingOff: user develops
    partitioned --> handingOff
    handingOff --> departed: memberDeparture sent (roster > 2)
    handingOff --> terminated: final pair (merged roster == 2)
    localIdleStop --> expired: hard deadline
    departed --> [*]
    terminated --> [*]
    expired --> [*]
```

Rules (unchanged from v1 where good, sharpened where partition-aware):
- Losing sockets never ends membership or clears content. An authenticated external heartbeat resets
  the 30-minute idle timer; heartbeat acks stay immediate.
- **`localIdleStop` ends local *participation* (radios, CPT), not membership.** Within the ceiling the
  foreground UI may offer resume; resume re-authenticates and enters the merge path (§10) — idle-lapse
  and partition are deliberately the same mechanism. The 30-minute timer is a resource policy; the
  6-hour ceiling is the membership death.
- The ceiling is enforced against `hardDeadline` (absolute, signed at creation, ±120 s skew tolerance)
  AND a local monotonic guard.
- A developed or terminated mesh can never be rejoined (`developedLocally` + termination record).
  Relaunch never auto-reconnects; force-quit → foreground resume offer only.

### 8.3 Membership events and membership-driven rotation

New frozen wire tokens (display text forked separately; `sessionGoodbye` frozen/parked, still parsed
from legacy builds as "departure, legacy" during the transition, never emitted by new builds):

- `fernlet.mesh.member-departure.v1` — signed by the leaver: {meshID, member fingerprint, at,
  custody-handoff summary}. Delivered to every reachable member at departure; **re-gossiped by every
  holder on every later connect** (grow-only record), so it propagates transitively (§10.5 example).
- `fernlet.mesh.terminated.v1` — signed by a final-pair member: {meshID, at, roster-at-signing}.
  Receivers validate against their *merged* roster: if their roster > 2 the record downgrades to a
  departure of the signer (safe: a partitioned member who believed the mesh was a pair only removes
  themself).
- `fernlet.mesh.inventory-digest.v1`, plus P5's manifest/chunk/receipt tokens.
- Rotation reuses the existing `meshKeyRotation`/`meshKeyAck`/`meshRotationSync` family, extended with
  a `cause` token (`timer` | `membership` | `merge`) and the new `MeshEpochRef`.

**Rotation triggers become: 15-minute timer ∪ any roster change ∪ any merge.** This closes the
voted-out-member-keeps-key gap: `applyApprovedRemoval` (and departure processing, and liveness
eviction) immediately triggers rotation by the current coordinator. Removed/departed members are
excluded from the new epoch's key distribution and rejected at the transport (§7.2).

### 8.4 Epochs that survive divergence

```swift
struct MeshEpochRef: Codable, Hashable {
    let counter: UInt32                // Lamport-style; mint = max(seen) + 1; cap 4096
    let epochID: UUID                  // unique per minted epoch
    let coordinatorFingerprint: String
}
```

- The group key is bound to `epochID`. Members hold a bounded keyring: current + ≤ 3 predecessors, each
  predecessor valid ≤ 5 minutes after supersession (covers in-flight control frames; the existing
  `pendingRotationClosingEpoch` grace generalizes to this).
- Acceptance of a rotation: signed by an authenticated roster member who is the deterministic
  coordinator (lowest fingerprint) of *the roster set they present*, and `counter >` local counter.
  Divergent same-counter epochs (two partitions each rotated) never need mutual acceptance — they
  coexist until a merge mints a strictly greater successor. Epoch continuity is **not** required;
  identity + roster validation is the authority (a member returning from a long partition at counter 5
  syncs forward to 9 without being "stale").
- **Replay protection moves off epochs**: routed content carries unique IDs + meshID + expiry and
  dedups by ID (P5); only live control-frame key selection uses epochs. (Today's epoch-gated photo
  manifests would wrongly reject cross-partition content; that gating is retired with the old path.)
- Bounds: ≤ 24 timer rotations per branch per ceiling × roster ≤ 8 branches → counter cap 4096 is
  generous; keyring 4; epoch log rolling 32 (diagnostic only, continuity never required).

Acceptance (P3): unit tests for every state edge; disconnect ≠ removal; idle-lapse resume; ceiling at
both bounds; rotation on removal/departure/merge with old-key rejection after grace; context
load/deferred/corrupt matrix; legacy `sessionGoodbye` interop.

---

## 9. Roster and capacity bounds

The mesh is small by design and every partition structure inherits it:

| Bound | Value | Source |
|---|---|---|
| Roster cap (admitted, lifetime of mesh) | **8** | new; comfortably above today's `maxTotalSlots = 5` + self |
| Concurrent QUIC connections | roster − 1 ≤ 7 | §7.3 |
| Partition branches trackable | ≤ roster (everyone alone) | §8.4 |
| Admission/departure/removal records | 16 each | §8.1 |
| Session photos / texts | 200 / 500 (existing) | unchanged |
| Routed logical items | 1024 | P5 |
| Relay cache | 256 MiB, 256 KiB chunks | P5 |

---

## 10. Phase P4 — partition and merge (the split-brain design)

The scenario driving this phase (owner, 2026-08-27): four devices split into two groups of two, both
groups keep sharing photos and messages, keys may rotate while split, then everyone reunites — and the
same must generalize to larger meshes with more (and nested) splits.

**Testing lane (re-tiered 2026-09-01, §7.8).** The §16.2 scenario matrix stays tier 1 on the fake
fabric — randomized bounded schedules under a fixed seed belong nowhere else. What changed is the
corroboration: the shapes worth watching over *real* QUIC (2/2, 3/1, and one nested re-split
mid-merge) now run **3–6 Simulators on one Mac** through the Lane C harness, driven from `simctl`,
rather than waiting on four phones. §15.2's physical partition walks stay on the list, but as the
last confirmation rather than the only evidence.

### 10.1 Why splits are safe by construction

Because of invariants 2 and 3, a partition is not an error state — it is normal operation with fewer
reachable custodians:

- **Content** created during a split is manifest-signed with the destination set = *full roster at
  creation time* (not the connected set). Members of the other partition are simply destinations whose
  delivery is pending. Content keys are wrapped per recipient identity, so nothing about content
  depends on which partition (or which group-key epoch) it was created in.
- **Control keys** diverging is harmless: each partition's key only protects that partition's live
  control traffic. There is no shared secret that must remain globally consistent.
- **Membership records** are signed and grow-only, so views can only differ by *missing* records, never
  by *conflicting* ones — and missing records are supplied by union on merge.

### 10.2 What each partition does while split

- Derives its own coordinator (lowest fingerprint **present**), runs its own 15-minute rotation, its
  own liveness — all scoped to the branch.
- Marks unreachable roster members `temporarilyDisconnected` (presence state, not a record). Liveness
  eviction while split is **local presence only** — reversible, never a membership record.
- Continues photos/text/hearts normally; new items enqueue for the absent destinations in the routed
  store (P5).
- The idle timer does *not* fire while any external member heartbeats — a live partition of ≥ 2 stays
  alive. A partition of one hits `localIdleStop` after 30 minutes (§8.2) and resumes-as-merge later.

### 10.3 Merge (any reconnect is a merge; there is only one path)

Reconnect between any two members — after a blip, a partition, an idle lapse, or a process restart —
runs the identical sequence. One mechanism, deliberately: **reconnect ≡ merge ≡ relay drain.**

```mermaid
sequenceDiagram
    participant A as member (branch A)
    participant B as member (branch B)
    A->>B: QUIC + signed channel introduction (§7.2)
    B->>A: verify identity ∈ merged roster, not departed/removed, mesh current
    A->>B: membership records + epoch heads (union exchange)
    B->>A: membership records + epoch heads
    Note over A,B: both derive merged roster; hard records win over soft presence
    Note over A,B: deterministic coordinator of merged view mints epoch counter = max+1, cause = merge
    A->>B: InventoryDigest (manifest IDs held, receipts held)
    B->>A: InventoryDigest
    A->>B: missing manifests/chunks/receipts (P5 drain, bounded)
    B->>A: missing manifests/chunks/receipts
    Note over A,B: transcripts/photo sets re-derived; gates re-applied on ingestion
```

Ordering and dedup on ingestion:
- **Photos**: union by manifest ID, hash-validated on reassembly, then the existing review flow.
- **Texts**: union by message ID into the routed inbox; the visible transcript is re-derived in total
  order `(claimedSentAt clamped to ±10 min of first-seen, senderFingerprint, messageID)`. Age gate and
  moderation run at ingestion exactly as the existing rebuild path does.
- **Hearts**: union by gift ID; final receipt still only at foreground decrypt + ledger commit; the
  ledger's existing dedup/cooldown arbitrates duplicates that crossed the split.
- N-way merges need no special case: merges are pairwise and union is associative/commutative/idempotent,
  so any partition tree (6 devices in three groups, nested re-splits mid-merge) converges as links form.
  Property test in §16 asserts exactly this.

**Direct answers to the driving questions:**
- *How do the messages and photos combine?* By ID-keyed union + deterministic re-derivation; nothing is
  overwritten because nothing conflicting can exist (only missing).
- *What if rotation happened while split?* Both branches rotated independently; both old keys die at
  merge when the merged coordinator mints a strictly-greater epoch. No content is affected because no
  content ever used those keys.
- *Larger meshes, more splits?* Same machinery, bounded by roster ≤ 8; convergence is a property of the
  union-merge, not of any particular topology.

### 10.4 Moderation under partition — roster quorum (owner decision)

- Removal requires **⌊|roster|/2⌋ + 1 distinct signed votes** (the proposal counts as the proposer's
  vote; the target cannot vote), where roster is the *current merged derived roster* at evaluation time.
- Votes are signed records referencing a proposal ID; a proposal expires **5 minutes** after issuance
  (bounded window — quorum is meant to be live, not archaeological). A **completed** removal (quorum
  reached) becomes a permanent `SignedRemovalRecord` and union-merges like any record; an incomplete
  proposal simply expires and leaves no trace in the roster.
- Consequences, per the owner's example: roster 4 → quorum 3 → a 2/2 split can moderate **nobody**; a
  3/1 split can remove the isolated member (votes are valid for absent targets — an abuser who walks
  away can still be removed, and the record ejects them at their next connection attempt). Roster 2 →
  quorum 2 with the target abstaining → removal is structurally impossible; the final pair ends the
  mesh instead. After a departure shrinks roster 4 → 3, quorum drops to 2 and a connected pair regains
  moderation power.
- Self-bans/blocks (persisted moderation ledgers) are unchanged and additive.

### 10.5 Departure propagation — worked example (owner's)

Roster {A, B, C, D}; split into {A, B} and {C, D}. B develops and leaves: B's signed
`memberDeparture` reaches A (the only reachable member). Everyone now behaves by their view — A knows
roster 3, C/D still assume 4. A later walks over and connects to C: the introduction's record exchange
(§10.3) hands C the departure record; C gossips it to D. All three converge on roster {A, C, D},
quorum 2, without B ever meeting C or D. If B had left while completely alone, the record could not
propagate — the residual is that C/D carry a phantom member until the ceiling; this is accepted and
bounded (no dead-drop side channel for mesh state).

### 10.6 Termination and development under partition

- Development in a split with merged roster > 2 is a departure (§8.3) with the bounded 15 s handoff to
  the *reachable* members — custody transfers to them preserve delivery to the other branch post-merge.
- A "final pair" is judged on the **merged derived roster**, not the connected pair (a 2/2 split of a
  4-roster is not two final pairs). A wrongly-issued termination downgrades to the signer's departure
  at every receiver whose roster is larger (§8.3) — the failure mode costs one member, never the mesh.
- Genuine final pair, partner unreachable at development: the terminator ends locally; the partner's
  idle-stop/ceiling closes their side; on foreground they are offered development of what they hold.

Acceptance (P4): deterministic fake-transport suites for §16.2's scenario matrix; the convergence
property test; quorum arithmetic table-driven tests (rosters 2–8 × partition shapes); the two worked
examples above encoded verbatim as tests.

---

## 11. Phase P5 — encrypted store-and-forward routing

**Testing lane (re-tiered 2026-09-01, §7.8).** Custody, receipts, dedup, backpressure and the drain
are tier 1. The questions that are genuinely about a real radio — chunk pacing at 256 KiB, whether a
large transfer starves the control stream, and therefore whether relay increment 2 is needed at all —
run over **real QUIC between 3–6 Simulators on one Mac** via the Lane C harness, including datagram
traffic (item 15 struck the assumption that datagrams need hardware). P2 already moved photo chunks
on per-transfer streams across that lane in both directions.

Carried from v1 with partition duties added. Structures (all bounded, all signed by the **origin**;
relays forward the origin's exact signed objects, never re-sign):

- `MeshRoutedManifest` — item ID, type token, content hash, size, immutable destination set (full
  roster at creation), expiry (= mesh `hardDeadline` + 20-minute development grace), per-recipient
  `MeshRecipientKeyWrap`s (X25519 wrap of the random content key; purposes registered in P0).
- `MeshChunk` (≤ 256 KiB, explicit index/count, per-chunk hash), `MeshCustodyReceipt` (relay has
  durable ciphertext), `MeshRecipientReceipt` (destination-final), `MeshInventoryDigest` (ID lists,
  bounded by the 1024-item cap — no probabilistic structures needed at this scale).
- Acknowledgement stages (unchanged from v1): photos/text final on durable recipient storage; **hearts
  final only after foreground decrypt + ledger commit**; control immediate. Custody ≠ delivery in every
  UI surface.
- Backpressure: at the 256 MiB / 1024-item caps, refuse new custody with a bounded, user-visible
  delivery failure. Nothing grows silently.
- Locked device: ciphertext-only custody; decryption and canonical-store mutation wait for unlock;
  four-state sidecar; identity-key keychain protection is never weakened for background decryption.
- Partition duty: the routed store is the *source* for §10.3's drain — delivery targets are
  "destinations lacking a `MeshRecipientReceipt`", which is partition-agnostic by construction.
- Unknown type tokens are rejected, not forwarded; every future routed type declares size cap,
  destination semantics, relay-retention, final-ack condition, and expiry at registration.

Relay scope note: v1's general A–B–C live chunk relaying is **staged**. Increment 1 ships
origin-retains + custody-transfer-on-departure (the load-bearing case — §10.6); live third-party relay
of in-flight chunks (hop count ≤ roster, TTL) is increment 2, gated on device measurements showing it
is actually needed at roster ≤ 8 on shared Wi-Fi.

---

## 12. Phase P6 — feature routing

**Testing lane (re-tiered 2026-09-01, §7.8).** Photos already crossed on per-transfer QUIC streams,
in both directions, between two Simulators on one Mac (P2 item 10) — so this phase's observation lane
is that one, at 3–6 nodes, through the Lane C harness. **Hearts and moderation did not cross**, for
an app-state reason rather than a transport one (§7.7 finding 2): both need mutual trust-vault rows,
which need a *second* session — commit, end, complete `pendingFriendReview` on both sides, reconnect.
Scripting two sequential sessions across two Simulators is this phase's first real job, and it is
still a sim-lane job; no hardware is implied by it.

- **Photos**: existing `resizedForFriendSharing()` (1400 px / q0.82) → content-key encrypt → chunk →
  manifest to full roster → reassemble + hash-check → existing review flow. Unfinished ciphertext
  survives process death; `maxIncomingPhotoBytes`/pixel bounds enforced at reassembly exactly as the
  store does today.
- **Temporary text**: `SessionMessageStore` stays the memory-only UI projection; the sealed routed
  inbox beneath it is the durable truth. Foreground/unlock: decrypt, validate, re-derive transcript
  (§10.3 ordering), re-apply age gate + moderation, clear everything per development/session rules.
- **Hearts**: sealed ciphertext custody in background; ledger commit, cooldown, dedup, closeness at the
  foreground final-receipt point. Mesh hearts remain a separate seam from `HeartDropService` (shared
  `ProximityHeartLedger` with per-path semantics is preserved; a routed gift whose recipient never
  foregrounds before mesh end **survives locally sealed until expiry** — v1's spec gap, closed).

---

## 13. Phase P7 — app-layer lifecycle gating seam

Today `ContentView` owns start/stop by scene/tab; ProximityKit deliberately observes nothing. Background
continuation breaks that ownership. Options reviewed:

| | Design | Verdict |
|---|---|---|
| **A — app-owned run policy (recommended)** | New app-target `ProximityRunPolicy`: the single translator from (scenePhase, tab, lock/duress state, protected data, age gates, delete-all, CPT state) → per-radio `RunState` (`run` / `foregroundOnly` / `stop`), pushed into each manager via one `apply(_:)` seam. `ContentView` stops calling managers directly and feeds the policy instead. `MeshContinuationCoordinator` *feeds* its state in (task running/refused/expired) rather than gating radios itself. | One decision point; ProximityKit stays UIKit-free and testable; matches the composition-root pattern. **Adopt.** |
| B — ProximityKit self-observes | Managers watch scenePhase/notifications internally. | Couples the SPM module to UIApplication, reverses the no-lifecycle-observers design, hurts every test. Reject. |
| C — coordinator intercepts | CPT coordinator keeps the mesh alive while ContentView keeps stopping it. | Two owners for one radio; stop-vs-keepalive ordering races are precisely the bug class to avoid. Reject. |

Policy matrix (the load-bearing rows): user-started mesh + CPT granted → mesh `run` in background,
discovery/admission `foregroundOnly` (invariant 5), presence + recipe `stop` on background (unchanged
behavior); CPT refused → mesh `foregroundOnly` with the UI explaining background continuation is
unavailable; delete-all / below-age / duress → `stop` + teardown. Table-driven tests over the full
input product.

---

## 14. Phase P8 — background continuation (`BGContinuedProcessingTask`)

App-target `MeshContinuationCoordinator`, owning: concrete-ID registration at mesh start
(`MBO.Fernlet.mesh-continuation.<meshID>`; plist wildcard already present), `.fail` submission on the
user's start/join action once the first peer commits, the 6-hour and 30-minute clocks, endpoint-cache
reconnection (never background Bonjour re-browse as the primary path), routed-store draining,
progress + title/subtitle updates, expiration/cancel handling, and exactly-once completion into one
idempotent shutdown (probe's `completeBackgroundTask` pattern, already right).

**Progress strategy (needs the §15.3 soak to confirm):** progress must advance monotonically or the
system kills the task — so the unit is **elapsed session time toward the ceiling** (monotonic by
construction), with title/subtitle carrying the human truth: `Fernlet mesh` / `N friends connected`
(count = roster members with fresh authenticated heartbeats, excluding self; hardcoded in the probe
today, dynamic here). This supersedes v1's "show no time-derived info" rule — the owner accepted the
timers as policy, and a monotonic bar is what the API's documented termination rule demands. The
30-minute idle stop also gives the task an honest finite shape: it is never "idle forever" — it is
either progressing, syncing, or ending.

The custom `ProximityForegroundAnchor` Live Activity is suppressed for continued meshes (no duplicate
UI); its once-per-launch orphan reaper stays.

Failure honesty: iOS can end the task under pressure regardless; the UI copy and privacy text say so.
Degraded ladder (pre-decided, per §15.3 results): full background mesh → background on infra-Wi-Fi only
→ foreground-only with opportunistic sync on reunite (which P4 makes automatic).

---

## 15. Hardware gates (P8 entry criteria — the honest successors to the spike)

The device↔simulator lane proved the transport (P0 closes it). These remain, on 2–4 physical devices:

**Unaffected by the 2026-09-01 re-tier (§7.8).** The simulator↔simulator lane pulled multi-node work
*down* out of P3–P6; it takes nothing out of here. Every gate below is background, lock, radio
physics, battery, thermal or OS policy, and a Simulator answers none of it — `BGTaskScheduler`
returns error 1 there at all, so the sim lane can never speak to P8's rows. These entry criteria
stand exactly as written. Two P2 residuals join them: **item 11** (AWDL path, Local Network
permission prompt) and the Lane B row "at most one connection per peer pair", which needs a late TXT
and therefore a physical radio (§7.7 finding 6).

**15.1 Radio matrix:** established QUIC connection surviving background+lock; re-dial via cached
endpoint while backgrounded; fresh Bonjour browse while backgrounded (expected to fail — record it);
each × infra-Wi-Fi and AWDL. Plus Low Power Mode on/off (undocumented — empirical answer required)
and memory-pressure kills.

**15.2 Partition walks:** the §10 scenarios physically — 2/2 split with traffic both sides, walk back
together, verify convergence + single post-merge rotation; 3/1 with a removal vote; departure-carried-
by-third-member (§10.5 verbatim).

**15.3 Progress soak:** 3 h and 6 h sessions with elapsed-based progress under normal use of the phone;
the gate is "the task survives while progress advances slowly." If it does not, the degraded ladder in
§14 activates and this plan's P8 scope shrinks to foreground + opportunistic — everything else stands.

**15.4 Wi-Fi Aware evaluation (bounded, 2 days):** the one Apple-documented background p2p path
("foreground and background states… BackgroundTasks API"), whose pairing requirement maps naturally
onto the existing QR ceremony. Establish: hardware floor vs the app's device floor, whether
`NetworkConnection` rides over it, battery profile. Outcome is a recommendation, not a dependency.

Results land in the runbook's gate table with dates; the probe's new counters (P0.6) supply the numbers.

---

## 16. Testing and release gates

**16.1 Unit/protocol (fake transport, injected clocks — no wall-clock waits):** neutral transport
behavior + golden wire frames; QUIC framing/bounds/malformed input; channel-binding transcripts
(byte-exact vectors); reject unknown/departed/removed/old-mesh peers; disconnect vs departure;
idle-lapse resume; ceiling at both clocks; rotation on removal/departure/merge + keyring grace expiry;
chunk dedup/TTL/caps/backpressure; custody vs final receipts; heart foreground-commit rule;
locked/deferred/corrupt sidecars; exactly-once task completion; run-policy matrix; legacy
`sessionGoodbye` interop; wipe-wall + delete-all resurrection checks for every new sidecar.

**16.2 Partition suite (the new investigation, automated):** scenario matrix = roster {3, 4, 6, 8} ×
partition shapes (2/2, 3/1, 3/3, 4/2/2, nested re-split mid-merge) × events during split (photos,
texts, hearts, timer rotation ×2, removal vote with/without quorum, departure, idle-lapse, final-pair
attempt) → assert: merged state identical on every member (**convergence property test** over
randomized bounded schedules with a fixed seed), exactly one post-merge epoch at every member, quorum
arithmetic per §10.4, no content loss, no duplicate ledger commits.

**16.3 Physical matrix:** §15 plus the v1 list (2/3/6 devices, screen off/locked, force-quit one peer,
restart + explicit resume, incomplete handoff, protected-data-unavailable launch, large photo with
concurrent heart/text traffic).

**16.4 Repository gates every phase:** existing suites; `Scripts/power-of-10-scan.py`;
`Scripts/spm-wall-check.sh`; S3 + extended no-tracking + localization + doc-coverage tests; the new
background-refresh import wall (P10 may not import mesh/AI/HealthKit/CloudKit implementation modules);
warnings-as-errors. Docs updated in the same commits: FileIndex, ProximityFunctionIndex,
No-Tracking-Wall, privacy copy, this plan's checkboxes.

---

## 17. Phase P9/P10 and paperwork

**17.1 P9 — remaining radios and MC retirement:** recipe share → QUIC request/response streams
(preserving pause/resume semantics); presence → QUIC with the **ephemeral posture reproduced** (fresh
TLS identity + randomized instance name per 900 s presence epoch — no stable name, matching today's
ephemeral MCPeerID intent); coach service constant per the Coach-app decision (§18). Then delete
`MeshMultipeerSession` and `FileMCPeerIDStore` (with delete-all/wipe rows retired), drop the eight
`_fernlet-*` MC Bonjour types from the plist, remove the MC import — done before the Xcode 27
toolchain move. Note that `MultipeerPeer.underlying` is **already gone** (P1 replaced it with
``PeerEndpointKey``), so P9's deletion list is two files plus the plist, not a signature sweep; and
`TransportNeutralityBoundaryTests`' permit list is the exact inventory of what is left to delete.

**17.2 P10 — companion `BGAppRefreshTask`:** as v1 §8 — `MBO.Fernlet.companion-refresh`, `fetch`
background mode, schedule at handle+background, handler limited to: acquire the existing store safely →
roll day → recompute deterministic companion → diff snapshot → publish via WidgetBridge → reload
timelines only on change → complete once. Never: mesh, HealthKit, CloudKit force-sync, Foundation
Models, store creation while protected data unavailable. One correction to v1: `FernletStoreAccess` is
already a single process-global cache shared by UI and App Intents — the move out of
`ExchangeIntentService.swift` into a small lifecycle service is hygiene that lets the refresh handler
share it, not a fix for a competing-stores bug. (Also delete the dead `install(store:)` path found in
the audit.)

**17.3 Documented policy reversal (owner-approved) — same-commit paperwork:**
- Rewrite the "deliberately NOT Codable" / "memory-only, never persisted" doc guards on
  `MeshSessionTypes`, `SessionMessageStore` (projection stays memory-only; state the sealed inbox
  beneath), and the `MeshGroupKey` doc (still never persisted — unchanged and now load-bearing).
- Wipe-wall disposition rows + delete-all writer wiring for: `MeshSessionContext`, `MeshRoutedStore`,
  endpoint cache, and any new UserDefaults key.
- `PrivacyInfo`/privacy copy: serverless + E2EE; nearby Fernlet devices may briefly hold ciphertext
  they cannot read; background continuation uses local network + battery and iOS may end it; content
  clears by development/session rules.
- Module DocC landing pages for ProximityKit (+ any new module) re-describe the invariants;
  `doc-coverage-scan.py` stays at zero.

---

## 18. Order, dependencies, and open decisions

```
P0 ──► P1 ──► P2 ──► P3 ──► P4 ──► P5 ──► P6 ──► P8 (gated by §15)
                       │                    ▲
                       └────────► P7 ───────┘        P9 after P2 is proven
P10 independent (after the small FernletStoreAccess move)
```

Critical path: **P2 transport → P3 membership → P4 partition → P5 routing**. P4 before P5 is
deliberate: routing's delivery targets are defined in partition terms, so the merge semantics must be
settled first. P7 can start once P3's states exist. P10 and P0 can interleave anywhere.

**Open decisions for the owner:**
1. Progress display: accept elapsed-toward-ceiling as the bar (recommended, §14)?
2. Partition UX: surface "N friends out of range — will sync when you reunite" or stay silent
   (recommended: the subtitle count only)?
3. Roster cap 8 and the 5-minute removal-vote window — confirm values.
4. Coach radio disposition in P9 (retire with the rest vs hold for the Coach-app decision).
5. Wi-Fi Aware evaluation (§15.4): run it during P2, or only if §15.1's AWDL rows fail?
6. Plist keys shipping in Release now (P0.3 recommendation: yes, documented).
7. Bind the introduction's `sid` into the signed transcript — a transcript v2, which moves signed
   bytes (§7.7 finding 1). P3 is where `epochRef` becomes real, so if the transcript moves it should
   move once.
8. The `x509-self-signature` escape hatch — the first crypto hatch since the standardization round,
   technically sound and wanting review **as a policy act** (§7.7 finding 7).

---

## 19. P2 handoff — written at the P1 boundary, 2026-08-29

**Spent at the P2 boundary, 2026-09-01.** Kept as the record of what P2 was handed and what it was
told to decide — every decision §19.4 poses was taken, and §7.6 says which way and why. **§20 is the
live handoff.** §19.5 is the exception: it was always a P3/P5 constraint, and it is carried forward
verbatim into §20.2 rather than left here to be found by accident.

P0 and P1 are **BUILT** (§5, §6). This section is what a fresh session needs to start P2 and nothing
more; the sections above are the authority for *what* to build.

### 19.1 What P2 inherits

- A framework-free transport surface: `PeerTransport`, `PeerHandle`, `PeerEndpointKey`,
  `PeerDeliveryMode`, `PeerTransportState`, `PeerPendingInvite`, `InboundPeerFrame`,
  `PeerTransportError`. A second conformer needs **no change** to any of them.
- `MeshMultipeerSession` and `MCPeerIDStore.swift` are the only two files that may name a
  MultipeerConnectivity type, and `TransportNeutralityBoundaryTests` fails the build if a third does.
  Add `NetworkMeshSession.swift` beside them; do not widen that permit list to reach it.
- A deterministic fabric — `VirtualClock` + `FakePeerNetwork` + `FakePeerTransport` — with
  connect/disconnect/latency/partition/heal and n-way splits, and **no wall-clock sleeps**. Write P2's
  session-actor tests against it, not against timers.
- Two golden vectors (`PeerHandleWireGoldenTests`) that fail if a peer field starts or stops reaching
  the signed envelope bytes. Treat a failure there as a wire-format decision, never as a test to
  re-pin without thinking.

### 19.2 Prerequisites this session did not have

1. **Two physical iOS 26.5+ devices.** P2's acceptance is mesh flows on the QUIC transport on the
   device↔simulator lane *and* on two physical devices. Lane A of the runbook is still empty
   (§5 item 5) — **fill it before writing QUIC code**, because a red Lane A during P2 is indis-
   tinguishable from a P2 bug, and the probe already exists to answer it in one sitting.
2. **TN3213 open alongside.** §7.1's mapping table was written against it and should be re-read
   rather than trusted from memory; the API is new enough that details move between revisions.
3. **The §7.2 decisions, which are still decisions, not facts.** Specifically: the ephemeral per-mesh
   self-signed P-256 TLS identity (minted at session start, never persisted, never reused across
   meshes — TLS identity is not Fernlet identity), and `prohibitedInterfaceTypes = [.cellular]`
   always, which turns the serverless claim from aspiration into enforcement. Both need the owner's
   explicit yes before they are load-bearing.

### 19.3 Do these first, in this order

1. **Close the marker gap in the same commit as the first QUIC file** (§7.4). `NWConnection` and
   `NWBrowser` are banned markers today; `NetworkConnection` / `NetworkListener` / `NetworkBrowser`
   are not, so the new API passes through a hole. Extend `NoTrackingBoundaryTests`' marker list,
   permit exactly the ProximityKit transport files plus the DEBUG probe, and update
   [No-Tracking-Wall.md](No-Tracking-Wall.md) §4c/§5 — §4c already names this gap as scheduled, so
   the paperwork is half written.
2. **Register the channel-introduction transcript against its declared framing.** The purpose exists
   (`Signature.meshChannelIntroductionV1`, `.lengthPrefixed`) but nothing signs under it yet. When
   P2's serializer lands, add its case to `CryptographicPurposeBoundaryTests`' framing test in the
   same commit. That pairing — declared framing vs. what the serializer emits — is exactly what broke
   in `91c3956` and surfaced as ~200 unexplained failures rather than one named cause.
3. **Give the dial policy its own symmetry test.** The MC inviter tie-break deadlocked the mesh once
   (documented at `MeshNetworkManager` :1993-2004) and is covered by two tests today. Do not inherit
   confidence from the existing suite: five of the coordinator's discovery branches are unreachable
   in production and are driven by the mock alone (§6.4 finding 6).

### 19.4 Decide before writing the session actor

- **Whether to take the §6.5 root fix.** Making `peer(for:)` return a stable `id` for the life of a
  session would fix §6.4 findings 1–3 together and collapse `isSameEndpoint(as:)` to one comparison.
  It is a behaviour change, which is why P1 did not take it, and P2 is the natural home — but if P2
  instead mints a *fresh* id per QUIC reconnect, findings 1–3 get **worse**, because reconnection
  becomes routine rather than exceptional. Decide deliberately; do not let the QUIC session's
  endpoint-cache design settle it by accident.
- **Whether the QUIC TXT record publishes `fp`.** It would activate the fingerprint-mismatch gate and
  the envelope recipient-binding that are vacuous today (§6.4 finding 4) — probably desirable, but it
  moves signed bytes, so it is a wire decision with a golden vector attached, not a port detail.
- **What the new TXT record carries.** `meshID`, `meshName` and `memberCount` are advertised today and
  read by nobody (§6.4 finding 5). Carrying them forward preserves a passive-scanner surface nobody
  asked for; dropping them passes every test. Either is defensible; silence is not.

### 19.5 Cross-round constraint that reaches P3/P5, not P2

`ColumnCrypto` is a single generation (V3) and **refuses to seal** without a `DeviceBindingID`
(`SealedColumnStrictSealError.bindingUnavailable`, owner decision D4); the V2 and unprefixed read
paths are deleted and survive only as classification cases so a refusal can name what it refused.

Consequence for §8.1's sealed `MeshSessionContext` and §11's routed store: **they cannot be written
before first unlock.** The four-state sidecar model in invariant 7 needs a fifth consideration —
"seal refused" is distinct from "deferred because protected data is unavailable" — and background
custody must never assume it can seal. This meets the durable-before-acknowledged rule (§3.6) head
on: **if you cannot seal, you must not acknowledge.**

---

## 20. P3 handoff — written at the P2 boundary, 2026-09-01

P0, P1 and P2 are **BUILT** (§5, §6, §7). This section is what a fresh session needs to start P3 and
nothing more; the sections above are the authority for *what* to build. §8 is the specification.

### 20.1 What P3 inherits

- **`MeshIntroductionAuthority` — the seam P3 is supposed to fill.** The QUIC radio asks its
  authority who this peer is, and `MeshNetworkManager` answers with mesh id, epoch reference, roster
  and signing key. **A nil authority refuses every tunnel**, so the fail-closed direction is already
  the default and P3 cannot accidentally open it by omission. Today the manager answers from live
  session state; P3's job is to answer from the *derived* roster of §8.1 — `admitted − departed −
  removed` — which is the same question with a durable answer.
- **A soft epoch rule waiting for §8.4 to make it strict.** The introduction accepts equal epochs
  **or one side empty**, because a joining peer holds no group key yet and strict equality would make
  admission impossible; two different non-empty epochs are already `.divergentEpoch`. §8.4's
  Lamport-style `MeshEpochRef` and its merge rule are what let this tighten. It is flagged in source
  at the comparison — tighten it there, deliberately, rather than discovering it later.
- **Membership events unlock two things P2 could not reach.**
  - **The hard-departed rejection row.** `MeshIntroductionRejection.barredMember` exists and was
    driven on the radio, but only under a chaos hook: `MeshNetworkManager.roster` keeps `barred`
    empty on purpose, because it records removals by *fingerprint* and holds no signing key for a
    member it has dropped — so a genuinely removed member falls out of `members` and refuses as
    `unknownIdentity`. P3's `SignedRemovalRecord`s are what give `barred` real contents and make the
    branch the shipping authority's own answer instead of a test's.
  - **The hearts and moderation ceremonies.** Both gate on *mutual* trust-vault rows written by
    completing `pendingFriendReview` on both devices in an earlier session (§7.7 finding 2). P3's
    durable context is the first thing in this plan that makes "an earlier session" a concept the
    code can hold across a process death.
- **A sim↔sim multi-node lane for roster and membership tests.** 3–6 Simulators on one Mac, driven
  from `simctl` through the Lane C harness (§7.8) — roster convergence, departure gossip via a third
  member, and rotation across two tunnels are all reachable without hardware.
- **A selectable transport.** `MeshTransportSession` + `FakeMeshTransportSession` mean the manager
  itself is now drivable at tier 1; the state machine of §8.2 should be pinned there, not on a radio.

### 20.2 The constraint that decides §8.1's shape — D4 sealing (carried from §19.5, verbatim in force)

`ColumnCrypto` is a single generation (V3) and **refuses to seal** without a `DeviceBindingID`
(`SealedColumnStrictSealError.bindingUnavailable`, owner decision D4); the V2 and unprefixed read
paths are deleted and survive only as classification cases so a refusal can name what it refused.

Consequences P3 must design *into* the store rather than discover in it:

- **A sealed `MeshSessionContext` cannot be written before first unlock.** Not "is slower", not
  "retries" — refused.
- **"Seal refused" is not "deferred because protected data is unavailable."** Invariant 7's four
  states (loaded / absent / deferred / corrupt) need the fifth consideration spelled out, and a
  refusal must name what it refused rather than collapsing into `absent` — an `absent` that is
  really a refusal is the shape that overwrites live data.
- **Durable before acknowledged (§3.6) meets it head on: if you cannot seal, you must not
  acknowledge.** Every custody receipt, every membership record accepted, every "joined" the UI
  shows must be behind a successful seal, because force-quit gives no expiration callback to save
  you afterwards.

### 20.3 The paperwork is part of this phase, not a follow-up

§17's bold line **"Documented policy reversal (owner-approved) — same-commit paperwork"** (item 17.3)
lists what P3 owes *in the commits that reverse the invariant*, not after them: the "deliberately NOT
Codable" / "memory-only, never persisted" doc guards on `MeshSessionTypes` and `SessionMessageStore`
(and the `MeshGroupKey` doc, which stays "never persisted" and becomes load-bearing by contrast);
wipe-wall disposition rows and delete-all writer wiring for `MeshSessionContext`, `MeshRoutedStore`,
the endpoint cache and any new `UserDefaults` key; the `PrivacyInfo` and privacy copy; and the
ProximityKit DocC landing page's invariants, with `doc-coverage-scan.py` still at zero. P3 is the
commit that reverses a documented design intent — the paperwork is the half that makes it a reversal
rather than a drift.

### 20.4 Do these first, in this order

1. **Records and derived roster, pure and tier 1.** `admitted − departed − removed`, union-merge,
   the bounds from §9. No storage, no transport, no clock. Everything later is a consumer of this.
2. **Then the sealed store**, with the five-state load of §20.2, a **per-instance disk root** and a
   grep-wall test à la `PhotoDirectoryIsolationTests` — the shared-disk-root flake family must not
   grow a new member — plus the §17.3 rows in the same commit.
3. **Then membership-driven rotation** (§8.3), which is what closes the confirmed gap where a
   voted-out member keeps the group key for up to 15 minutes.
4. **Then point the introduction authority at the derived roster**, which is what makes matrix row 3
   the shipping answer (§20.1) and what lets the sim lane prove a removal ejects a peer at its next
   connection attempt.

### 20.5 Decide before writing the store

- **Whether the transcript takes `sid`** (§7.7 finding 1, §18 open decision 7). P3 is where
  `epochRef` stops being a placeholder, so if the signed transcript is going to move, moving it once
  — with the golden vectors updated deliberately — is much cheaper than twice.
- **Whether the epoch gate goes strict** once §8.4's merge rule exists (§7.7 finding 5).
- **Whether the QUIC TXT publishes `fp`** — still open, still moves signed bytes, still a wire
  decision with a golden vector attached (§19.4, unchanged by P2).

### 20.6 Still owed, and not blocking P3

- **Hardware:** the Lane A diagnostic report (loop item 1), AWDL + the Local Network permission
  prompt (item 11), and the double-dial collapse's Lane B row (§7.7 finding 6). None of them gate
  membership work.
- **A known-red gate that is nobody's current fault:** `sync-string-catalogs.sh --check` fails on
  nine stale keys that are present in the file as committed (§5 item 4). It is one write-mode run on
  a quiet tree. **Do not bisect it.**
- **`MeshTunnelConvergence` and the id-vs-endpoint family are closed** (`96337a3`, `2f273a9`). The
  second has an exhaustive per-site audit table in its commit message — re-auditing it is wasted
  time.
