# Network mesh feasibility runbook

## Status

This is the required physical-device gate for background mesh continuation. The
`NetworkMeshFeasibilityProbe` is DEBUG-only and must not be treated as a
production mesh implementation.

**Plan:** [Plan-ProximityKit-Network-Migration-2026-08-27.md](Plan-ProximityKit-Network-Migration-2026-08-27.md)
is the authority for what this gate feeds. Two of its decisions govern this document:

- The spike's stated purpose was to **prove device↔simulator QUIC connection before touching
  ProximityKit**. That lane is the standing development loop, and it is the only lane P0 closes.
- The **background** questions — locked operation, Low Power Mode, soaks, battery and memory
  budgets, force quit — are **P8 entry criteria** (plan §15), not blockers on the transport work.
  P1 (transport neutrality) and P2 (the QUIC session) proceed without them: MC deprecation is iOS
  27, so the migration is unhurried, and the neutral transport has value whatever the background
  answer turns out to be.

So "do not begin the transport-abstraction phase until the gate has an approved result" — the
original framing — is superseded. What still holds: **do not ship background continuation** until
the §15 rows below carry real results.

## What the probe validates

- Bonjour discovery and listening on `_fernlet-mesh2._udp`.
- One Network.framework QUIC connection, with peer-to-peer networking enabled.
- A reliable control stream and QUIC datagram ping/pong.
- A signed channel-introduction transcript. Its signature covers the mesh ID,
  membership epoch, both ephemeral nonces, both Fernlet signing identities, and
  a SHA-256 binding derived from the active TLS connection exporter.
- A user-started `BGContinuedProcessingTaskRequest` submitted with `.fail` and
  its system-provided Live Activity title, subtitle, and progress.

The probe does not transfer user content, admit members, persist routing state,
or change a real mesh. Its TLS peer-authentication setting is intentionally
unauthenticated in DEBUG: a successful probe requires Fernlet's signed,
TLS-exporter-bound introduction to validate. Production transport must add its
own peer trust policy; this switch is not shippable.

QUIC still requires a server certificate before either endpoint can exchange
application bytes. The DEBUG listener therefore constructs a fixed, self-signed
test identity solely to complete the TLS handshake; neither side trusts that
certificate. The Fernlet-signed, TLS-exporter-bound introduction remains the
only authentication check, and the test identity must never move into a
production transport target.

The DEBUG datagram check is intentionally bounded: it allows three initial
ping/pong exchanges and three outbound-tunnel attempts, while recording only
recognized probe message kinds or an unknown payload's byte count. This makes
transient simulator infrastructure ordering observable without logging content.
Both endpoints explicitly advertise a 1,024-byte DATAGRAM-frame limit and a
1,280-byte QUIC UDP-payload limit; the copied diagnostic report records both
advertised values and the negotiated usable frame size.
If QUIC negotiates a zero usable datagram frame size, the probe reports that
negative result directly and does not retry the same unsupported path.

Use **Copy diagnostic report** in the probe's Local events section to put the
bounded DEBUG-only report on the pasteboard for review. It includes transport
state, negotiated datagram capacity, task state, candidate identifiers, and
local events; it never includes user content. Every terminal probe outcome
stops networking, cancels its request, and completes any delivered continued
task so the system activity can end. Launch also cancels a stale feasibility
request left by a prior process.

The permitted identifier remains the wildcard `MBO.Fernlet.mesh-continuation.*`,
but the DEBUG probe registers its concrete, stable request identifier before
submitting it. This avoids the BackgroundTasks wildcard-handler assertion seen
on current iOS 26 simulator/device builds. Production must validate the same
exact-registration rule for each generated mesh identifier.

## Simulator development lane

The Simulator can accelerate protocol and infrastructure-network debugging but
cannot approve this gate. Its probe intentionally disables Apple peer-to-peer
Wi-Fi, waits for the QUIC listener and its Bonjour advertisement before
browsing, and records each bounded candidate plus its connection state. Its
Bonjour TXT record marks it as a Simulator, so it always dials a physical
device; the physical device never attempts to dial the Simulator's host-only
link-local address. A Simulator will also dial another Simulator when the
DEBUG-only `FERNLET_PROBE_ALLOW_SIM_DIAL=1` switch is set — see **Lane A2**,
which is the multi-node lane and needs no hardware.

Use one Simulator and one physical device on the same non-isolated Wi-Fi to
exercise Bonjour discovery, QUIC framing, the signed introduction, and
datagrams. Stop old runs before retrying: Bonjour may briefly retain a dynamic
listener port after a process exits. The Simulator lane does not validate
local-network permission, Apple peer-to-peer Wi-Fi, continued-processing
behavior, locked/background execution, battery use, or the release gate.

For Simulator interoperability debugging, the physical device can use the
DEBUG-only **Use infrastructure Wi-Fi** control in the probe. It removes the
peer-to-peer path preference so both endpoints have the same infrastructure
path policy. This is a diagnostic comparison only; restore **Use peer-to-peer**
before any two-device feasibility gate run.

## Procedure

### Simulator development check

1. Install the same DEBUG build on the Simulator and one physical device. Keep
   the Mac and device on the same non-isolated infrastructure Wi-Fi, with no
   VPN or client isolation.
2. Start the probe on the Simulator and wait for `QUIC listener is ready` and
   `Bonjour listener advertised` in its bounded event log before starting the
   device probe.
3. Inspect the candidate list and connection-state events. A refusal or timeout
   must identify the advertised service before another attempt is made. Stop
   both probes before retrying after a listener restart.

### Required physical-device gate

1. Install the same DEBUG build on two physical iOS 26.5-or-later devices with
   local-network permission granted. Open Settings → Advanced → Mesh network
   feasibility on both devices.
2. Start the probe on one device, then the other. Confirm that each device
   discovers the other, reports a valid introduction, and has a bounded event
   log with datagram replies.
3. Confirm the system Live Activity says `Fernlet mesh` and presents a dynamic
   friend count. The app must not create Fernlet's custom proximity activity.
4. Repeat over infrastructure Wi-Fi and then with infrastructure Wi-Fi
   unavailable, where Apple peer-to-peer networking is expected to carry the
   connection.
5. Lock both devices and background Fernlet. Run a 30-minute observation, then
   three-hour and six-hour soak tests. Repeat a representative run in Low Power
   Mode while recording battery loss, peak memory, discovery/reconnect events,
   and datagram/control-stream success.
6. Repeat with four devices. Exercise topology changes and simultaneous starts;
   verify the deterministic connection tie-breaker leaves at most one connection
   per peer pair. The probe's connection cap is 4, raised from 2 for exactly this
   step — at 2 the step was impossible to perform.
7. Test system cancellation, task expiration, network loss, app switching, and
   app-switcher force quit. Record whether the task receives an expiration
   handler; force quit is expected to be able to stop it without one.
8. Stop each probe and attach the device logs and measurements to the release
   evidence. The probe deliberately retains no user content to clean up.

## Gate criteria

Every row carries a **Result** and a **Date**. A blank cell reads as untested; a cell that says
`Deferred to P8` reads as scheduled. Neither is the same as a pass, and the difference is the whole
reason these two columns exist.

Fill a result in from the probe's **Copy diagnostic report** output, which now carries the counters
these rows are judged on: bytes sent/received, connect and reconnect counts with timestamps, and
thermal-state / Low Power Mode transitions.

### Lane A — device ↔ simulator (what the spike was built to prove; P0 closes this lane)

One physical iOS 26.5-or-later device plus one Simulator on the same non-isolated infrastructure
Wi-Fi. This is the standing development loop, not a release gate.

| Check | Required result | Result | Date |
| --- | --- | --- | --- |
| Discovery | Each endpoint lists the other as a bounded Bonjour candidate on `_fernlet-mesh2._udp`; the Simulator's TXT marking makes the device the dialer. | **Observed working** (owner report) — no diagnostic report captured yet | 2026-08-31 |
| QUIC connect | Exactly one connection per pair reaches `.ready`; the deterministic tie-breaker suppresses the duplicate tunnel. | **Observed working** (owner report) — no diagnostic report captured yet | 2026-08-31 |
| Control stream | Signed identity hello and signed channel introduction complete in both directions; `controlStreamVerified` becomes true on both endpoints. | Not yet recorded | — |
| Datagram | Ping/pong completes and the negotiated usable frame size is non-zero (a zero size is a reportable negative result, not a retry). | Not yet recorded | — |
| Channel binding (on-radio) | Both endpoints derive the same TLS-exporter hash from the live connection and each verifies the other's signature over it. | Not yet recorded | — |
| Channel binding (off-radio) | A changed mesh ID, epoch, nonce, identity, or binding hash fails verification. | **Pass** — `MeshNetworkFeasibilityTests.signedIntroductionRejectsAnyChangedChannelBinding`, run in the standard suite | 2026-08-29 |
| Dial policy | Self-candidates, already-failed candidates, and simulator→simulator dials are refused by default. | **Pass** — `MeshNetworkFeasibilityTests.discoveryPolicyRejectsSelfAndPreviouslyFailedCandidates`; the sim→sim refusal is opt-out only via `FERNLET_PROBE_ALLOW_SIM_DIAL` (Lane A2) | 2026-08-29 |
| Plist configuration | The three keys the lane needs are present and the registration identifier is concrete, not the wildcard. | **Pass** — `MeshNetworkFeasibilityTests.probeInfoPlistConfigurationAllowsTheDeviceSpike` | 2026-08-29 |

The three `Pass` rows are what the radio-free unit suite can honestly prove. They are listed here
rather than omitted so the gap is legible.

**"Observed working" is not a Pass, deliberately.** The owner reports that a device and a Simulator do
discover and connect (2026-08-31). That is real information and worth recording, but it is not the
same as a captured **Copy diagnostic report** with byte counts, connect timestamps and the negotiated
datagram frame size in it. Promote those rows to Pass when a report is attached; until then the lane
is known-good, not evidenced.

### What this lane can and cannot prove

This matters more than it looks: the device↔Simulator lane is the **cheap, high-frequency** loop —
Xcode is attached, logs are right there, and a run costs minutes. Two-device runs are slow and
awkward by comparison. So the standing rule for every phase is: **push work down this list, never
up.**

| Tier | Prove it here | Why |
|---|---|---|
| **1. Unit tests, no radio at all** | Anything that is pure logic: the dial tie-breaker's total order, retry budgets, state machines, framing bounds, rejection rules, partition scenarios. | Free, deterministic, runs in CI. `Tests/FernletTests/Mocks/FakePeerTransport.swift` exists for exactly this. If a check *can* live here, it must. |
| **1b. Simulator ↔ Simulator, N nodes** | Real Bonjour, real QUIC, real TLS exporter, real crypto, real signed introductions — across 2, 3, 4 or 6 nodes, scripted, on one Mac with no hardware at all. **Not** QUIC datagrams (see the lane's result below). | Proven 2026-08-31. No device, no cable, no human tapping Start; `simctl` drives the whole run. Anything provable here must not be pushed up to tier 2. |
| **2. Device ↔ Simulator** | Real Bonjour, real QUIC, real TLS exporter, real crypto, and every app-layer mesh flow over them. Reconnection via endpoint cache. The full rejection matrix, by making the Simulator misbehave on purpose. **QUIC datagrams**, which tier 1b could not negotiate. | One device, attached debugger, fast turnaround. |
| **3. Two or more physical devices** | Only what is genuinely radio physics or OS policy: Apple peer-to-peer Wi-Fi (AWDL), the Local Network permission prompt, background and locked operation, battery, thermal, Low Power Mode. | Slow and hard to log. Keep this list as short as the work allows. |

**Known limitations of tier 2, stated so nobody mistakes them for bugs:**

- **The Simulator disables Apple peer-to-peer Wi-Fi.** This lane is infrastructure Wi-Fi only, so it
  cannot say anything about AWDL. That is a tier-3 question, permanently.
- **The dial direction is one-way.** The Simulator's link-local address is host-only, so a physical
  device cannot reach it; the TXT marking makes the Simulator always the dialer. Consequence worth
  naming: the tie-breaker's *device↔device* branch (`localServiceName < candidateServiceName`) is
  **never exercised on this lane** — and that comparison is the one that deadlocked the mesh before.
  Cover it at tier 1, exhaustively, rather than hoping a hardware run reaches it.
- **No Local Network permission flow.** The Simulator does not present it.
- **Background, locked, battery and thermal behaviour do not transfer** from a Simulator.

**Simulator ↔ Simulator was refused by policy, and that policy was wider than it needed to be.**
`MeshProbeDiscoveryPolicy.allowsOutboundConnection` returned `!candidateRunsInSimulator` when the
local side was a Simulator, so one Simulator would not dial another. The documented reason — the
Simulator's host-only address — justified the *device→Simulator* refusal, not that one. The
experiment was run on 2026-08-31 and **two Simulators do connect**; the lane below is the result.

### Lane A2 — simulator ↔ simulator (answered 2026-08-31)

**Two Simulators on one Mac connect: Bonjour discovery, QUIC/TLS, and the signed,
TLS-exporter-bound introduction all complete in both directions. QUIC datagrams do not
negotiate.** This is a real multi-node lane for everything up to and including the signed control
stream, and it needs no hardware and no human at all.

Two Simulators on the same Mac share the host's network stack, so the peer resolves to a routable
host address (`172.20.6.146` in the run below) rather than the host-only link-local address that
justifies the device→Simulator refusal. Instance-name collision was never an obstacle either: the
probe's service name is a fresh UUID per process.

How to run it — no UI navigation, no Start button:

```
xcrun simctl install <udid> <path>/Fernlet.app
SIMCTL_CHILD_FERNLET_PROBE_ALLOW_SIM_DIAL=1 \
SIMCTL_CHILD_FERNLET_PROBE_AUTOSTART=1 \
SIMCTL_CHILD_FERNLET_PROBE_CONSOLE_LOG=1 \
xcrun simctl launch --console-pty <udid> MBO.Fernlet
```

The three `FERNLET_PROBE_*` variables are DEBUG-only, read once per process by
`MeshProbeDebugOptions`, and **each is off when absent**. Off is not a near-equivalent of today's
behaviour, it is today's behaviour: `ALLOW_SIM_DIAL` widens the simulator→simulator case *only* (a
physical device still refuses a Simulator candidate), `AUTOSTART` replaces a tap on the probe
screen's Start button, and `CONSOLE_LOG` mirrors the existing 80-entry event ring to stdout so a
headless run has the same evidence the **Copy diagnostic report** button produces. When
`ALLOW_SIM_DIAL` is on, the sim→sim dial uses the same `localServiceName < candidateServiceName`
total order as the device↔device branch, so exactly one Simulator of a pair dials.

| Check | Required result | Result | Date |
| --- | --- | --- | --- |
| Discovery | Each Simulator lists the other as a bounded Bonjour candidate on `_fernlet-mesh2._udp`. | **Pass** — both sides logged `Bonjour discovery has 2 candidate(s)` | 2026-08-31 |
| Dial | Exactly one Simulator of the pair dials, by the service-name tie-breaker. | **Pass** — `fernlet-probe-70215e98…` dialed `fernlet-probe-d8d9ebf9…`, and `70215e98 < d8d9ebf9` | 2026-08-31 |
| QUIC connect / TLS | The connection reaches `.ready` on both endpoints. | **Pass** — initiator ready at `172.20.6.146%en0:57837`, responder ready at `172.20.6.146:64794` | 2026-08-31 |
| Control stream | Signed identity hello and signed channel introduction complete in both directions; `controlStreamVerified` becomes true on both endpoints. | **Pass** — both sides logged `Verified both Fernlet signatures against the same TLS exporter hash` | 2026-08-31 |
| Channel binding (on-radio) | Both endpoints derive the same TLS-exporter hash from the live connection and each verifies the other's signature over it. | **Pass** — implied by the line above; the introduction does not verify unless both hashes match | 2026-08-31 |
| Datagram | Ping/pong completes and the negotiated usable frame size is non-zero. | **Fail** — `usable frame size=0, required=23`, with `datagram-flow=false`; the probe reported the negative result and stopped, as designed. **Not attributed to this lane** — see below | 2026-08-31 |
| Dial policy, default off | With `FERNLET_PROBE_ALLOW_SIM_DIAL` absent, two Simulators discover each other and neither dials. | **Pass** — control run held ~90 s: two candidates on each side, zero `Opening QUIC tunnel` lines, zero connections | 2026-08-31 |

Evidence — the two console transcripts, trimmed to the load-bearing lines:

```
# initiator (iPhone 17 Pro)
6:53:48 PM: Opening QUIC tunnel attempt 1 to fernlet-probe-d8d9ebf9-….local. [Simulator].
6:53:49 PM: QUIC ready with …[Simulator] at 172.20.6.146%en0:57837; DATAGRAM=1024, UDP=1280,
            datagram-flow=false, usable datagram frame size=0 bytes.
6:53:49 PM: Control initiator accepted remote signed channel introduction.
6:53:49 PM: Verified both Fernlet signatures against the same TLS exporter hash.
6:53:49 PM: QUIC datagram capability check: usable frame size=0, required=23.
6:53:49 PM: Ending mesh feasibility probe: QUIC datagrams were not negotiated; usable frame size is 0 bytes.

# responder (iPhone 17)
6:53:49 PM: Accepted inbound QUIC tunnel id=1.
6:53:49 PM: QUIC ready with an inbound peer at 172.20.6.146:64794; …usable datagram frame size=0 bytes.
6:53:49 PM: Control responder accepted signed channel introduction.
6:53:49 PM: Verified both Fernlet signatures against the same TLS exporter hash.
```

**The datagram failure is not yet attributed to this lane, and must not be recorded as a sim↔sim
limitation.** Lane A's own Datagram row is still `Not yet recorded`, so nobody has seen a non-zero
usable frame size on *any* lane. Both endpoints advertised `maxDatagramFrameSize = 1024` and both
observed `datagram-flow=false` with a usable size of 0, which is equally consistent with a probe
QUIC-parameter defect that would fail the same way against a physical device. Settle it by reading
the usable frame size on one device↔Simulator run — one line of evidence decides it — before
concluding anything about Simulators.

**What this re-tiers.** Any P3–P6 work whose correctness lives above the control stream — routing,
membership, partition walks, departure transactions, N-node topology and simultaneous-start
races — can now be exercised on 3, 4 or 6 Simulators from a script, with no hardware and no
tester. That is a step change in the cost of those phases and the reason this experiment was worth
running. What it does **not** move: Apple peer-to-peer Wi-Fi, the Local Network permission prompt,
background/locked operation, battery and thermal, and (until the paragraph above is settled)
anything that rides on QUIC datagrams. Those stay at tier 3 / Lane B.

**One surprise worth carrying forward: an absent Bonjour TXT record reads as `device`.**
`MeshProbeDiscoveryPolicy.candidateRunsInSimulator` returns false when the TXT key is missing, and
in the first run one Simulator saw the other's freshly-published record before its TXT arrived,
logging `…[device]` and dialing it — a dial the *pre-existing* policy would also have allowed. It
did not recur in the control run. Two consequences: a Simulator-origin check that must be reliable
cannot be built on TXT presence alone, and the old sim→sim refusal was never quite airtight.

### Lane C — simulator ↔ simulator, the PRODUCTION mesh over QUIC (answered 2026-09-01)

Lane A2 proved the *spike* handshakes between two Simulators. Lane C is the same two Simulators
running the **shipping** transport — `NetworkMeshSession` selected by `FERNLET_MESH_TRANSPORT=quic`,
with `MeshNetworkManager` as its `MeshIntroductionAuthority` — and it answers a different question:
not "does a tunnel come up", but **"is the tunnel selective"**. Every named rejection in
`MeshIntroductionRejection` that P2 can reach was produced deliberately and read out of a console
transcript, alongside an accepted baseline. A matrix of refusals with no accept proves only that the
radio is broken; a baseline with no refusals proves only that it is open.

How to run it — no UI navigation, no Start button, nothing persisted:

```
xcrun simctl install <udid> <path>/Fernlet.app
SIMCTL_CHILD_FERNLET_MESH_TRANSPORT=quic \
SIMCTL_CHILD_FERNLET_MESH_MATRIX=1 \
SIMCTL_CHILD_FERNLET_MESH_CONSOLE_LOG=1 \
SIMCTL_CHILD_FERNLET_MESH_MATRIX_LABEL=<run-name> \
SIMCTL_CHILD_FERNLET_MESH_MATRIX_MESH_ID=<uuid> \
SIMCTL_CHILD_FERNLET_MESH_MATRIX_MEMBERS=<base64-key,base64-key> \
xcrun simctl launch --console-pty <udid> MBO.Fernlet -completeOnboarding
```

The harness variables are DEBUG-only, read once per process, and **each is off when absent** — off
being today's behaviour exactly, not a near-equivalent:

| Variable | Read by | Behaviour when absent |
| --- | --- | --- |
| `FERNLET_MESH_MATRIX` | `MeshMatrixDebugOptions` (app target) | Nothing is seeded and no radio is started. |
| `FERNLET_MESH_MATRIX_LABEL` | same | The run is named `unlabelled` in the transcript. |
| `FERNLET_MESH_MATRIX_MESH_ID` / `_MEMBERS` | same | No descriptor: the roster is empty, which is the state a device with no mesh is genuinely in. |
| `FERNLET_MESH_CONSOLE_LOG` | `MeshTransportConsoleLog` (ProximityKit) | The radio's `Logger` lines are not mirrored to stdout. Nothing else changes. |
| `FERNLET_MESH_CHAOS` | `MeshIntroductionChaos` (ProximityKit) | Fresh nonce every hello, signature goes out as signed. |
| `FERNLET_MESH_CHAOS_BARRED` | same | The roster's barred set is empty — the production answer. |

`FERNLET_MESH_CHAOS` is the only misbehaviour switch. It takes frozen tokens (`frozenNonce`,
`tamperSignature`) and **damages this side's own outbound introduction**, so it can only ever cause
the *peer* to refuse us. `FERNLET_MESH_CHAOS_BARRED` only ever adds keys to the roster's barred set,
and barred wins over member, so it too can only turn an accept into a refusal. Neither direction can
admit a peer that would otherwise be refused. In a Release build the whole environment-reading half
is compiled out — the members are constants a compiler can fold — so no launch environment a shipped
app could see can reach any of it.

#### The rejection matrix

Two Simulators on one Mac (iPhone 17 + iPhone 17 Pro), one 60-second run per row, both instances
launched with `FERNLET_MESH_TRANSPORT=quic`. The `sid` tie-break picks the dialer at random per
launch, so each run seeds **both** sides symmetrically; the refusal is logged by whichever side ends
up the responder (and, because hellos are exchanged before either is judged, usually by both).

| Row | Result | Evidence |
| --- | --- | --- |
| **Accepted baseline** | **Observed** — both devices rostered in one mesh complete the introduction and activate a tunnel, in both directions | `[mesh-quic] accepted fb795f343c2954da sid=5894C3A5-…: tunnel activated` on A, and `accepted 0a676d9bbfcbbced sid=9ABA2D76-…` on B |
| 1. Unknown identity (no roster at all) | **Observed** — neither device holds a descriptor, so every peer verdicts stranger | `refused unknownIdentity as responder: mesh=00000000-…-000000000000 epoch="" rosterMembers=0 rosterBarred=0` → `A QUIC tunnel was refused: The peer is not a member of this mesh.` |
| 2. Non-roster member (valid identity, absent from THIS roster) | **Observed** — same mesh id on both sides, each roster holds two members and neither holds the peer | `refused unknownIdentity as responder: mesh=11111111-…-555555555555 epoch="" rosterMembers=2 rosterBarred=0`. Row 1 and row 2 are the same *rejection* and different *situations*; `rosterMembers` is what tells them apart, which is why the console line carries it. |
| 3. Hard-departed / removed member | **Observed as `barredMember`, with a caveat that matters** | `refused barredMember as responder: … rosterMembers=2 rosterBarred=1` → `The peer has departed, been removed, or been blocked.` **The shipping authority never produces this.** `MeshNetworkManager.roster` keeps `barred` empty on purpose: it records removals by *fingerprint* and holds no signing key for a member it dropped, so a genuinely removed member falls out of `members` and refuses as `unknownIdentity` — row 2's evidence is also the real removal path's evidence. The `barred` branch needed `FERNLET_MESH_CHAOS_BARRED` to be reachable on a radio at all. |
| 4. Ended / foreign meshID | **Observed, both sub-cases** | *Ended*: the device that left names the unbound all-zero mesh id and still refuses for the mesh reason, not the roster reason — `refused foreignMesh as responder: mesh=00000000-…-000000000000 … rosterMembers=0` — which is the mesh gate firing ahead of the roster gate, live. *Foreign*: two real, different mesh ids — `refused foreignMesh as responder: mesh=11111111-…` against a peer naming `99999999-…`. |
| 5. Introduction failure (tampered signature) | **Observed** | `refused signatureInvalid as responder at the signed introduction` → `The peer's channel-introduction signature did not verify.` The initiator saw only `A QUIC channel introduction did not complete: … MeshTransportError error 2` — **the responder never signed for a peer it had already refused**, so there was no second frame to read. The ordering property, observed rather than asserted. |
| 6. Replayed nonce | **Observed** | With `FERNLET_MESH_CHAOS=frozenNonce` and empty rosters, attempt 1 logs `refused unknownIdentity` (the nonce is admitted to the cache before the roster is consulted) and attempts 2–3 log `refused replayedNonce as responder: …` → `The peer replayed a channel-introduction nonce.` The three-attempt dial budget is what supplies the second introduction. |

Rows not in the matrix — `malformedHello`, `unsupportedProtocolVersion`, `divergentEpoch`,
`selfIntroduction`, `malformedIntroduction`, `channelBindingMismatch`, `missingPeerHello` — are
covered at tier 1 by the item-7 suite and were not driven over the radio here. Three of them
(`divergentEpoch`, `channelBindingMismatch`, `missingPeerHello`) are **unreachable at P2 by
construction rather than by omission**: there is no membership-epoch machinery to diverge yet (plan
§8.4), the channel binding is derived from the live tunnel at both ends and cannot be made to differ
without editing the transport, and `missingPeerHello` names a caller-order fault no peer can cause.

#### Two observations to carry forward

**A verified pair activated two tunnels, not one.** In the accepted baseline each device logged
`accepted` twice — once as initiator, once as responder — meaning *both* sides dialed and
duplicate-tunnel suppression did not collapse the pair. The `sid` tie-break is symmetric, so the
likely cause is the documented `shouldInitiateInvite` fallback: a peer discovered before its Bonjour
TXT record resolves has no `sid`, and "deadlock is worse than a redundant invite" makes both sides
dial. The inbound tunnel then keys off `connection.id` rather than the browsed key when
`links.key(advertisingSessionID:)` cannot resolve it, so the two never collide. Nothing about
selectivity is affected — both tunnels are between two verified roster members — but "at most one
connection per peer pair" is a Lane B row that this lane can now test cheaply, and today it would
not pass.

**The refusal is charged to the dial budget, and the budget holds.** Every refused row ended with
`The QUIC tunnel gave up after 3 attempts` on the dialing side and silence thereafter. A peer that
refuses us is re-offered exactly three times, not forever.

### Lane B — physical multi-device and background (deferred to P8; see plan §15)

These rows do not gate P1 or P2. They gate **shipping background continuation**, and they are
carried out on 2–4 physical devices per plan §15.1–15.4.

| Check | Required result | Result | Date |
| --- | --- | --- | --- |
| Four-device topology | Simultaneous starts and topology changes leave at most one connection per peer pair, at `maxConnections = 4`. | Deferred to P8 — see plan §15.1 | — |
| Background operation | An established connection survives backgrounding and lock; re-dial via cached endpoint works while backgrounded; a fresh background Bonjour browse is recorded either way (failure is the expected, documentable result). | Deferred to P8 — see plan §15.1 | — |
| Low Power Mode | Behaviour on and off is recorded empirically. Apple documents neither direction. | Deferred to P8 — see plan §15.1 | — |
| Progress soak | Three-hour and six-hour sessions survive while elapsed-based progress advances. Failure activates the degraded ladder in plan §14, it does not sink the plan. | Deferred to P8 — see plan §15.3 | — |
| Resource budget | Battery, peak memory, throughput, and photo-size measurements meet an approved product budget. | Deferred to P8 — see plan §15.3 | — |
| Continued task | A user-started request either begins with system activity or reports the `.fail` refusal clearly. | Deferred to P8 — see plan §14 | — |
| Cancellation | Every path stops the probe and completes the task exactly once. | Deferred to P8 — see plan §14 | — |
| Force quit | Evidence confirms durable production acknowledgements cannot depend on an expiration callback. | Deferred to P8 — see plan §14 | — |
| Partition walks | The plan's §10 partition scenarios, physically. | Deferred to P8 — see plan §15.2 | — |
| Wi-Fi Aware evaluation | A bounded two-day answer on hardware floor, whether `NetworkConnection` rides over it, and battery profile. Outcome is a recommendation, not a dependency. | Deferred to P8 — see plan §15.4 | — |

### Security, both lanes

| Check | Required result | Result | Date |
| --- | --- | --- | --- |
| Security | No untrusted peer reaches the post-introduction state. | **Partly proven** — the introduction's rejection rules hold off-radio (Lane A), and six of them now hold **on-radio** between two Simulators running the production transport, against an accepted baseline (Lane C). What is still deferred to P8 is the hostile-peer walk on *physical* radios and anything riding QUIC datagrams | 2026-09-01 (Lane C; physical deferred) |

## Decision

Two separate decisions, previously conflated into one:

**Lane A gates the development loop.** Once its rows pass, the device↔simulator path is the standing
way to exercise QUIC work. It does not gate P1 or P2 — those land on the strength of the code and the
existing suites — but a red Lane A is the first thing to explain before trusting a P2 result.

**Lane B gates shipping background continuation.** Approve it only when the required paths demonstrate
a usable background transport and the security review accepts the channel-binding design. If the
transport is unreliable while continued processing is active, Fernlet must offer
foreground/opportunistic sharing rather than continuous background delivery — plan §14's degraded
ladder, which is pre-decided rather than improvised at that point.

The later production phases add neutral transport interfaces, authenticated
QUIC mesh sessions, persistent membership, encrypted store-and-forward routing,
departure transactions, and the separate companion refresh task. None of those
belong in this feasibility probe.
