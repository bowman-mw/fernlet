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
link-local address.

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
| Discovery | Each endpoint lists the other as a bounded Bonjour candidate on `_fernlet-mesh2._udp`; the Simulator's TXT marking makes the device the dialer. | **Not yet run** — no physical device available to the sessions that built the spike | — |
| QUIC connect | Exactly one connection per pair reaches `.ready`; the deterministic tie-breaker suppresses the duplicate tunnel. | **Not yet run** | — |
| Control stream | Signed identity hello and signed channel introduction complete in both directions; `controlStreamVerified` becomes true on both endpoints. | **Not yet run** | — |
| Datagram | Ping/pong completes and the negotiated usable frame size is non-zero (a zero size is a reportable negative result, not a retry). | **Not yet run** | — |
| Channel binding (on-radio) | Both endpoints derive the same TLS-exporter hash from the live connection and each verifies the other's signature over it. | **Not yet run** | — |
| Channel binding (off-radio) | A changed mesh ID, epoch, nonce, identity, or binding hash fails verification. | **Pass** — `MeshNetworkFeasibilityTests.signedIntroductionRejectsAnyChangedChannelBinding`, run in the standard suite | 2026-08-29 |
| Dial policy | Self-candidates, already-failed candidates, and simulator→simulator dials are refused. | **Pass** — `MeshNetworkFeasibilityTests.discoveryPolicyRejectsSelfAndPreviouslyFailedCandidates` | 2026-08-29 |
| Plist configuration | The three keys the lane needs are present and the registration identifier is concrete, not the wildcard. | **Pass** — `MeshNetworkFeasibilityTests.probeInfoPlistConfigurationAllowsTheDeviceSpike` | 2026-08-29 |

The three `Pass` rows are what the radio-free unit suite can honestly prove. They are listed here
rather than omitted so the gap is legible: everything above them needs hardware, and nothing in the
automated suite substitutes for it.

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
| Security | No untrusted peer reaches the post-introduction state. | **Partly proven** — the introduction's rejection rules hold off-radio (Lane A); an on-radio hostile-peer walk is deferred to P8 | 2026-08-29 (off-radio only) |

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
