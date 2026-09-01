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
advertised values and the reported usable frame size.

**The reported usable frame size is evidence, not a verdict** (corrected 2026-09-01, P2 item 15).
The probe used to *throw* on a zero usable size and end the run before attempting a single
datagram, which is how this document came to record "QUIC datagrams do not negotiate". That was
wrong. `usableDatagramFrameSize` is only reachable on the **parent connection**, and the underlying
`nw_quic_get_stream_usable_datagram_frame_size` is documented as reading *a QUIC datagram flow's*
metadata — so a zero there means "this object is not a datagram flow", not "the peer refused
datagrams". `NWProtocolQUIC.Options.isDatagram`, logged beside it as `datagram-flow=false`, is the
same mistake: it is the per-stream flag asking whether *this stream should be* the datagram flow.
The probe now records both numbers and lets its bounded ping/pong decide; the "datagrams are not
usable" verdict is reached by trying and failing, never by reading.

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
| Datagram | Ping/pong completes. (The reported usable frame size is recorded but is **not** the criterion — see the correction above.) | Not yet recorded on this lane. Answered on Lane C instead: datagrams carry traffic between two Simulators with a reported usable size of 0 | 2026-09-01 |
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
| **1b. Simulator ↔ Simulator, N nodes** | Real Bonjour, real QUIC, real TLS exporter, real crypto, real signed introductions — across 2, 3, 4 or 6 nodes, scripted, on one Mac with no hardware at all. **And QUIC datagrams**: proven on Lane C, 2026-09-01 (P2 item 15), correcting the earlier "not datagrams" reading. | Proven 2026-08-31. No device, no cable, no human tapping Start; `simctl` drives the whole run. Anything provable here must not be pushed up to tier 2. |
| **2. Device ↔ Simulator** | Real Bonjour, real QUIC, real TLS exporter, real crypto, and every app-layer mesh flow over them. Reconnection via endpoint cache. The full rejection matrix, by making the Simulator misbehave on purpose. | One device, attached debugger, fast turnaround. ~~QUIC datagrams, which tier 1b could not negotiate~~ — struck 2026-09-01: tier 1b *can* carry datagrams, so this is no longer a reason to come up here. |
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
TLS-exporter-bound introduction all complete in both directions.** This is a real multi-node lane
for everything up to and including the signed control stream, and it needs no hardware and no human
at all.

~~QUIC datagrams do not negotiate.~~ **Struck 2026-09-01 (P2 item 15): they do.** See the Datagram
row below and Lane C's datagram finding — the probe was gating on a number that does not mean what
it was read to mean, and aborted before ever sending one.

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
| Datagram | Datagrams carry traffic in both directions. | ~~**Fail** — `usable frame size=0, required=23`~~ **Corrected to Pass, 2026-09-01 (P2 item 15).** The 2026-08-31 Fail was the probe refusing to try, not the transport refusing to carry: it threw on the reported usable size before sending a datagram. With the *shipping* transport on this same lane, mesh heartbeats were sent **and received** over QUIC datagrams in both directions for a full 170 s run — with the reported usable size still `0`. The number is read off the parent connection, which is not a datagram flow; see the correction under "How the probe is bounded" | 2026-09-01 |
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

~~**The datagram failure is not yet attributed to this lane.**~~ **Settled 2026-09-01 (P2 item 15),
and the answer was neither of the two candidates.** The suspicion recorded here was right that the
fault was on this side and not in the Simulator — but it was not a QUIC *parameter* defect. The
parameters were correct all along: both ends really did advertise `maxDatagramFrameSize = 1024`, and
the peer really did accept it. The defect was in the **reading**, in two places at once:

* `usableDatagramFrameSize` is only exposed on the **parent connection**, while
  `nw_quic_get_stream_usable_datagram_frame_size` is documented as reading *a QUIC datagram flow's*
  metadata. Asking a parent connection returns 0 because it is not a datagram flow — which says
  nothing whatever about the peer.
* `NWProtocolQUIC.Options.isDatagram`, logged as `datagram-flow=false`, is the per-**stream**
  configuration flag "should this stream be the datagram flow". Reading it off connection-level
  options is expected to be false and was never a report of peer support.

Two zeroes that both mean "wrong question" were read as one corroborated negative. The correction
came from the shipping transport, which stopped gating on the number and simply sent: heartbeats
crossed as QUIC datagrams in both directions, for 170 s, with the reported usable size still `0`.
The lesson worth keeping is the one the runbook's own "observed working is not a Pass" rule already
states in the other direction — **a negative result read off an accessor is not the same as a
negative result observed on the wire**, and this one cost the loop a fortnight and an unnecessary
re-tiering of every datagram-borne feature to hardware.

**What this re-tiers.** Any P3–P6 work whose correctness lives above the control stream — routing,
membership, partition walks, departure transactions, N-node topology and simultaneous-start
races — can now be exercised on 3, 4 or 6 Simulators from a script, with no hardware and no
tester. That is a step change in the cost of those phases and the reason this experiment was worth
running. What it does **not** move: Apple peer-to-peer Wi-Fi, the Local Network permission prompt,
background/locked operation, battery and thermal. Those stay at tier 3 / Lane B. ~~And anything
riding QUIC datagrams~~ — struck 2026-09-01: datagram-borne work comes back down to this lane.

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
| **Accepted baseline** | **Observed** — both devices rostered in one mesh complete the introduction and activate a tunnel, in both directions. *Amended 2026-09-01: the same line now carries `tunnels=`, and re-runs show `tunnels=1` throughout — see the convergence row below for what that corrects* | `[mesh-quic] accepted fb795f343c2954da sid=5894C3A5-…: tunnel activated` on A, and `accepted 0a676d9bbfcbbced sid=9ABA2D76-…` on B |
| **Convergence: at most one tunnel per verified pair** (2026-09-01, P2 item 13) | **Observed — and it corrects the reading below.** Four instrumented runs, ~100 s each, both Simulators rostered in one mesh over QUIC: every activation reports `tunnels=1`, so the pair holds exactly one connection at every instant. The repeated `accepted` lines are one tunnel that comes up, ends, and re-forms — **not** two coexisting ones | `[mesh-quic] accepted fb795f343c2954da sid=97D76DF2-…: tunnel activated, tunnels=1` ×3 on A, `accepted 3ed10f78c02b580a sid=A3456D0E-…: tunnel activated, tunnels=1` ×3 on B. **Control** (same binary, `MeshTunnelConvergence.resolve` stubbed to `.keepBoth`, i.e. the pre-item-13 behaviour): `tunnels=1` ×3 on both sides again, and no `redundantTunnelClosed` — so the single tunnel is **not** attributable to the collapse. The duplicate does not form on this lane at all |
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

**~~A verified pair activated two tunnels, not one.~~ Corrected 2026-09-01 (P2 item 13).** The
original reading was: each device logged `accepted` twice — inferred as "once as initiator, once as
responder" — so both sides dialed and duplicate-tunnel suppression did not collapse the pair. That
inference was **wrong about this lane**, and it was wrong because the console line said a tunnel came
up and nothing about whether the previous one was still there. It now carries `tunnels=`, and four
re-runs (two with the item-13 collapse, two with it stubbed out) report `tunnels=1` at *every*
activation on *both* sides. The repeated lines are churn: one tunnel forms, ends, and re-forms.

Two things follow, and they point in opposite directions:

* **The cross-key duplicate is real by construction, and is fixed** — an inbound tunnel whose
  verified `sid` resolves to no browsed advertisement keys off `connection.id`, so it can never
  collide with the browsed key and duplicate suppression is never asked. `MeshTunnelConvergence`
  closes it on the durable verified identity, and the tier-1 battery reproduces the double
  activation and pins the collapse (`MeshTunnelConvergenceTests`). What this lane cannot do is
  *exercise* it: reaching the double-dial window needs a peer discovered **before** its TXT record
  resolves, and two Simulators browsing over the infrastructure path get the TXT with the browse
  result, so the `sid` ranks immediately and only one side dials. Producing a late TXT is a physical
  radio's behaviour — the Lane B row "at most one connection per peer pair" (deferred to P8) is
  where the collapse gets exercised rather than merely held.
* ~~**A live tunnel that ends logs NOTHING.**~~ **Closed 2026-09-01 (P2 item 15).** `endTunnel` now
  takes a `MeshTunnelEndReason` and every end — including a live one — emits a permanent `os.log`
  line plus the console echo, naming the cause, the peer's key fingerprint, whether the tunnel had
  gone live, and the surviving tunnel count. The six frozen tokens are `heartbeatSendFailed`,
  `controlStreamEnded`, `introductionFailed`, `frameBudgetSpent`, `localEviction` and
  `redundantDuplicate`; the first four log at `error`, the last two at `notice`, so an owner tidying
  a slot does not read as a radio fault. This is production logging, not a debug hook — on a device
  there is no console mirror, and the disconnect path is exactly where silence costs most.

#### Why the pair churned (answered 2026-09-01, P2 item 15)

~~**Why the pair churns at all is unexplained.**~~ **It was QUIC's own idle timeout, reaping every
tunnel a moment before its first heartbeat was due.**

The instrumented re-run named it on the first pass, on both sides:

```
[mesh-quic] accepted fb795f343c2954da sid=58C9DE24-…: tunnel activated, tunnels=1
[mesh-quic] datagramCapacity usable=0 requested=1024 required=22 …
[mesh-quic] tunnelEnded controlStreamEnded fb795f343c2954da live=true tunnels=0 for
            fernlet-mesh-446ba51a9384…: The inbound QUIC tunnel ended: The operation couldn't be
            completed. (Network.NWError error 60 - Operation timed out)
```

`NWError 60` is `ETIMEDOUT` — the QUIC connection's `max_idle_timeout`, left at the framework
default of roughly 30 s. `MeshHeartbeatSchedule.intervalSeconds` is also 30, so the first beat was
scheduled for the instant the reap was already due, and lost the race nearly every time: across a
150 s diagnostic run, four activations per side and **one** heartbeat line in total. A keepalive
that fires no sooner than the timeout it defends against is not a keepalive. Nothing was refused,
nothing failed to dial, and no budget was spent — which is exactly why the churn presented as
silent, and why it survived item 13's convergence work untouched.

The fix declares the timeout instead of inheriting it:
`MeshHeartbeatSchedule.idleTimeoutMilliseconds` is derived from the beat interval as
`intervalSeconds × missedBeatsBeforeIdleReap`, i.e. three intervals, and is set on **both** the
listener and the connection parameters — QUIC negotiates the minimum of the two advertised values,
so a listener left on the default would pull it straight back under the interval. Dead-peer
detection is not weakened, it is relocated: the app's heartbeat is the detector and QUIC's idle
timer is the backstop three beats behind it. Before, the backstop *was* the detector, firing so
early the detector never ran.

A second, independent fault was found in the same place and fixed with it: a failed heartbeat write
used to end the tunnel outright, so any transport that would not carry a beat was indistinguishable
from a peer that had left. A datagram write that fails now latches the tunnel onto the control
stream (`MeshHeartbeatChannel`) instead of killing it; only a beat the *reliable* stream also
refuses ends anything. On this lane the latch never fires — the datagrams work — but it removes the
fail-open that would have resurrected the churn on any lane where they do not.

| Check | Required result | Result | Date |
| --- | --- | --- | --- |
| Tunnel stability | A verified pair holds one tunnel for the whole run, with no unexplained ends. | **Pass** — 170 s, **one** `tunnel activated, tunnels=1` per side and **zero** `tunnelEnded` lines on either side. The same binary before the idle-timeout fix: four activations per side in 150 s | 2026-09-01 |
| Heartbeat flow | Beats are observably sent and received, not merely scheduled. | **Pass** — five `heartbeat sending over datagram` and five `heartbeat received over datagram` per side, at 30 s spacing, in both directions | 2026-09-01 |
| Datagram transport | QUIC datagrams carry traffic between two Simulators. | **Pass** — every heartbeat above rode a datagram, with `usableDatagramFrameSize` still reporting `0`. This is the evidence that corrects Lane A2's Datagram row | 2026-09-01 |
| End-reason diagnostic | A deliberate teardown names its cause in the transcript. | **Pass** — see the teardown lines below | 2026-09-01 |

Evidence — the stable pair, then one side killed on purpose at t≈45 s:

```
# survivor, before the teardown
[mesh-quic] accepted fb795f343c2954da sid=AE2FBAD2-…: tunnel activated, tunnels=1
[mesh-quic] datagramCapacity usable=0 requested=1024 required=22 idleTimeoutMs=90000 beatSeconds=30 …
[mesh-quic] heartbeat sending over datagram for fernlet-mesh-5b3ce2003939…
[mesh-quic] heartbeat received over datagram for fernlet-mesh-5b3ce2003939…

# survivor, the instant the peer was terminated
[mesh-quic] tunnelEnded controlStreamEnded fb795f343c2954da live=true tunnels=0 for
            fernlet-mesh-5b3ce2003939…: The outbound QUIC tunnel ended: The operation couldn't be
            completed. (Network.NWError error 61 - Connection refused)
```

Worth noting what the two runs now let a reader do that they could not before: the churn ended with
`NWError 60 - Operation timed out` and a real departure ends with `NWError 61 - Connection refused`,
under the same `controlStreamEnded` token. "The peer went away" and "we timed the peer out" are
different faults with different fixes, and until item 15 both were the same blank line.

A third path was exercised incidentally, by a run whose seeded roster had gone stale:
`tunnelEnded introductionFailed unverified live=false tunnels=0 … The outbound QUIC tunnel failed
its signed channel introduction.` — `live=false` marks a tunnel that never came up (so the close is
charged to the dial budget, and the `gave up after 3 attempts` line follows), and `unverified`
is the placeholder for a tunnel that died before anyone proved who they were.

**The refusal is charged to the dial budget, and the budget holds.** Every refused row ended with
`The QUIC tunnel gave up after 3 attempts` on the dialing side and silence thereafter. A peer that
refuses us is re-offered exactly three times, not forever.

#### The app flows (answered 2026-09-01, P2 item 10)

The rejection matrix proved the tunnel is *selective*. This asks the next question: **do the app
layers above it work over QUIC?** Same two Simulators, same seeded mesh, driven by
`FERNLET_MESH_FLOWS` — the flow driver commits each device's own slot and then calls the same public
entry points the UI calls (`sendTempMessage`, `addPhoto`), echoing what each side observed under
`[mesh-flow]`.

```
SIMCTL_CHILD_FERNLET_MESH_TRANSPORT=quic \
SIMCTL_CHILD_FERNLET_MESH_MATRIX=1 \
SIMCTL_CHILD_FERNLET_MESH_CONSOLE_LOG=1 \
SIMCTL_CHILD_FERNLET_MESH_MATRIX_MESH_ID=<uuid> \
SIMCTL_CHILD_FERNLET_MESH_MATRIX_MEMBERS=<base64-key,base64-key> \
SIMCTL_CHILD_FERNLET_MESH_FLOWS=commit,capabilities,chat,photo,shop \
xcrun simctl launch --console-pty <udid> MBO.Fernlet -completeOnboarding
```

| Variable | Read by | Behaviour when absent |
| --- | --- | --- |
| `FERNLET_MESH_FLOWS` | `MeshMatrixDebugOptions` → `MeshFlowDriver` (app target) | No flow is driven and no poll runs: the harness seeds and joins exactly as it did before flows existed. |

Its tokens are `commit`, `capabilities`, `chat`, `chatAgeGated`, `photo`, `shop`. Committing is
unconditional once *any* flow is asked for — every other flow needs a committed slot — so `commit`
names a run that wants only that. Two seams the driver sets, both **before** `startJoin()` because a
peer's capability list is snapshotted when its coordinator is built: `chatAllowedProvider` (a
Simulator can reach no age determination, and `AgeGate.chat` refuses self-attestation) and the
clothing shop's two providers (standing in for the `allowNearbyClothingShares` setting and a
designed catalogue). Nothing is persisted; both die with the process.

**One thing the Simulator forces.** `NIRangingSession` reports hardware support there, so the friend
handshake lands at `awaitingProximityCommit` — the UWB gate — and the 15 cm dwell behind it can
never complete without a radio. The driver therefore commits at **both** gates through
`commitManualProximity`, which is exactly what the app's own debug "Force" control does with a stuck
UWB gate. It stands in for that control, not for a user's consent decision.

Run of 2026-09-01, ~130 s, iPhone 17 (A) + iPhone 17 Pro (B), both rostered in one mesh over QUIC.
The run is symmetric: each device drove every flow and observed the peer's.

| Flow | Result | Evidence |
| --- | --- | --- |
| **Slot commit** (the app handshake end to end) | **Observed**, both sides | `[mesh-flow] committing slot gate=awaitingProximityCommit` → `[mesh-flow] slots total=1 committed=1 states=[connected]` on A and on B |
| **Capabilities exchange** | **Observed**, both sides | `[mesh-flow] capabilities peer=[activities,messages,moderation,photos,shop,wire2]` on both — the peer's advertised list, read off `ProximityCoordinator.State.connected(peer:)` after the signed identity introduction |
| **Chat message delivered** | **Observed**, both directions | A: `[mesh-flow] sending chat isChatAllowed=true` then `[mesh-flow] chat received=1 sent=1`; B: the same pair. Each side sent one and received the other's |
| **Photo transferred (per-transfer streams)** | **Observed**, both directions, **on the new streams** | A: `[mesh-flow] sending photo jpegBytes=437040` → `[mesh-quic] transfer opened bytes=483282 stream=1` → `transfer sent bytes=483282 stream=1`, and B: `[mesh-quic] transfer received bytes=483282 stream=1` → `[mesh-flow] photos received=1`. The reverse crossed on B's `stream=4`. Two different stream ids because the two directions exercise the two acceptors: an odd id is server-initiated (served by the dialing side's acceptor), an even one client-initiated (routed past the control stream by the listening side's) |
| **Shop / clothing catalogue sync** | **Observed**, both sides | `[mesh-flow] shop peerCatalogs=1` on A and on B — the manager offers a catalogue once per slot at commit, so nothing is sent by hand |
| **Age gate — the 13+ mesh-chat gate** | **Observed**, both halves, both sides | Gate open: `messages` present in the capability list above and `chat received=1 sent=1`. Gate closed (`FERNLET_MESH_FLOWS=…,chatAgeGated`): `[mesh-flow] ageGate chatAllowed=false`, `[mesh-flow] capabilities peer=[activities,moderation,photos,shop,wire2]` — **`messages` is gone from the wire** — and `[mesh-flow] sending chat isChatAllowed=false` followed by `chat received=0 sent=0` for the rest of the run. Both enforcement points fire over QUIC exactly as they do over MC: the capability is withheld and the send is refused |
| **In-session hearts** | **Unreachable in this slice: mutual trust-vault records.** Not a transport limit | `sendSessionHeart(to:)` takes a `ProximityTrustedPeerRecord` and the receiver requires `ProximityTrustVault.isTrustedProximityPeer`; a fresh pair of Simulators has neither. Reaching it needs a *second* session — commit, end the session, complete the `pendingFriendReview` on both devices to write the vault rows, then reconnect — plus `allowNearbyHearts` on, which has no manager-level seam. The driver drives one session |
| **Moderation signal** | **Unreachable in this slice: same trust-vault precondition** | `sendModerationReports` gates on `isTrustedProximityPeer(signingPublicKey:)` for the recipient and on a non-empty `ownModerationReportsProvider`; the receiver re-checks vault trust before verifying a single row. Two devices that have never kept each other as friends exchange nothing, correctly. The `moderation` **capability** is advertised and was observed in every capability list above |
| **First-meeting stranger admission / the QR ceremony's stranger half** | **Unreachable at P2: membership (plan §8)** | An empty roster makes every peer a stranger and the QUIC introduction refuses the tunnel before any app frame — row 1 of the rejection matrix. Admitting a peer who is *not yet* a member is the membership question P3 owns; there is nothing at P2 to admit them into |

#### The defect this lane found: two writes per frame desynchronize the control stream

The first three attempts at this run never reached a single flow. The tunnel came up, the slot
committed, and within a second both sides died with:

```
[mesh-quic] tunnelEnded controlStreamEnded fb795f343c2954da live=true tunnels=0 …:
            The outbound QUIC tunnel ended: … (ProximityKit.MeshTransportError error 2.)
```

`MeshTransportError` error 2 is `invalidFrameLength` — the reader refused a length header. The cause
was in `sendFramed`, which wrote a frame as **two** awaited sends, the length prefix and then the
payload. Every frame on a tunnel shares one control stream, and `MeshNetworkManager` fires its
envelopes as independent tasks: a photo manifest, a vouch list, a shop catalogue and a shop request
all leave within the same instant of a slot committing. Two of those tasks suspend at the gap
between the two sends, and the peer reads one frame's header followed by another frame's first four
bytes as a length.

Reproduced in isolation on a loopback QUIC pair, six concurrent writers, twelve frames each:

```
split=true  writers=6 frames=72   READER: a frame's bytes were not uniform after 0 good frames — DESYNC   (×3)
split=false writers=6 frames=72   READER: 72 frames read intact — NO DESYNC                              (×3)
```

The fix is one contiguous write per frame — concurrent sends may be ordered either way, but neither
can land inside the other, and the bytes on the wire are identical. It is applied to `sendFramed`
and, for uniformity, to the handshake's `sendIntroductionFrame`. **The per-transfer streams
deliberately keep two writes**: such a stream is opened, written and closed by one task, so it has no
second writer to interleave with, and a bulk payload is exactly the one it would be wasteful to copy.

This was latent, not new. Item 15's runs held a tunnel for 170 s because they never sent an app
frame — the lane had no committed slot. The first frame-carrying run found it immediately.

#### What per-transfer streams are, and what they are not

A reliable frame at or above `MeshTransferStreamTable.bulkFloorBytes` (64 KiB) is written on a QUIC
stream opened for it alone, so a several-hundred-kilobyte photo cannot park a heartbeat, a chat
message or a moderation signal behind itself. Everything smaller stays in order on the control
stream, which is what keeps the reordering this buys away from the traffic whose order matters.

Nothing above the transport can tell. One transfer stream carries exactly one length-framed payload,
delivered as exactly one `InboundPeerFrame`, under the same 16 MiB ceiling both radios enforce —
`MeshNetworkManager` sends a friend photo the same way over MultipeerConnectivity and over QUIC. No
chunking, no resume, no new envelope, no signed byte moved.

Two properties worth recording because they were measured rather than assumed:

* **`inboundStreams` handlers run concurrently**, one task per stream. The listening side's handler
  for the control stream blocks for the tunnel's whole life; a loopback pair still delivered a
  second stream to a second handler while the first was parked in its receive loop. Without that,
  the listening side could not serve a transfer at all.
* **A QUIC stream's lifetime is its Swift object's.** A sender that returned the moment its last
  write returned tore the stream down under a peer that had not finished reading. The one-byte ack
  the receiver writes back is what holds the object until the payload has landed — and it turns "the
  peer vanished mid-transfer" into a thrown send the caller already handles rather than a silent
  truncation.

The budget cannot wedge. It lives **in** the tunnel record, so a torn-down link takes its open
transfers with it; an exhausted outbound budget falls back to the control stream (delivering a bulk
frame in order is always allowed); and a refused inbound transfer goes back un-acked, so the sender's
write fails loudly and recovery is the next manifest sync — which is the MC photo path's own failure
semantics reached by a different route.

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
| Security | No untrusted peer reaches the post-introduction state. | **Partly proven** — the introduction's rejection rules hold off-radio (Lane A), and six of them now hold **on-radio** between two Simulators running the production transport, against an accepted baseline (Lane C). What is still deferred to P8 is the hostile-peer walk on *physical* radios | 2026-09-01 (Lane C; physical deferred) |

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
