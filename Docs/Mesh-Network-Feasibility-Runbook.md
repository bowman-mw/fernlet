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
**Lane D ran on 2026-09-21** — the production transport, phone ↔ Simulator, infrastructure Wi-Fi with the
cable out; every row of its table carries a result and a date (see *Lane D* below). §15 remains unrun.
**The device round ran on 2026-09-22** on the DELETION build — the UNSEEDED first meeting between the phone and a
Simulator founded a mesh through the provisional path and survived the double-mint re-dial (*Lane D* § *The device
round's item 1*); §15.5's overnight window was read back with no grant (*Lane E* § *The overnight window, read back*);
§15.1 and §15.2 remain unrun for want of a second phone, §15.3 for want of hours of the owner's normal use, §15.4 the owner's call — each row named as such in *Lane B*.

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
listener port after a process exits.

**Unplug the cable, or the run is not on Wi-Fi.** A device attached by USB brings up an
Ethernet-over-USB interface on the Mac (`en9` in the 2026-09-01 run), link-local addressed and with
a direct route to the phone — and Bonjour will use it in preference to Wi-Fi without saying so. The
run still exercises Bonjour, QUIC, TLS and the signed introduction perfectly well; what it cannot do
is say anything about the Wi-Fi path. Pair for wireless debugging first (Xcode → Window → Devices
and Simulators → **Connect via network**), then unplug. Check with `ifconfig | grep -c en9`, and read
the interface scope in the `QUIC ready with …` event: `%en0` or a routable address is Wi-Fi, `%en9`
is the cable. The Simulator lane does not validate
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

**Recorded 2026-09-01 (P2 item 1) from a captured diagnostic report.** The rows below are no longer
owner recollection: the Simulator's **Copy diagnostic report** output and the device's Xcode console
for the same run are reproduced in full under *Evidence* after the table.

**Read the link caveat before reading the table.** This run did **not** cross Wi-Fi. It crossed the
iPhone-USB Ethernet tether — see *The link was not Wi-Fi* below. Everything above the IP layer is
promoted on this evidence; nothing about a Wi-Fi path or AWDL is.

| Check | Required result | Result | Date |
| --- | --- | --- | --- |
| Discovery | Each endpoint lists the other as a bounded Bonjour candidate on `_fernlet-mesh2._udp`; the Simulator's TXT marking makes the device the dialer. | **Pass** — `Bonjour discovery has 1 candidate(s).` and `Opening QUIC tunnel attempt 1 to fernlet-probe-ab5ae6b8-…_udplocal. [device]`: the Simulator saw the device, marked it `[device]`, and dialed it | 2026-09-01 |
| QUIC connect | Exactly one connection per pair reaches `.ready`; the deterministic tie-breaker suppresses the duplicate tunnel. | **Pass** — `QUIC ready with …[device] at fe80::c6:e886:e3b5:bee8%en9.59535`, and the report's counters read `connects: 1` / `reconnects: 0`. One connection, one direction, as the lane's one-way dial rule requires | 2026-09-01 |
| Control stream | Signed identity hello and signed channel introduction complete in both directions; `controlStreamVerified` becomes true on both endpoints. | **Pass** — `Control initiator sent identity hello.` / `accepted remote identity hello.` / `sent signed channel introduction.` / `accepted remote signed channel introduction.`, and the report header `signed control stream: true` | 2026-09-01 |
| Datagram | Ping/pong completes. (The reported usable frame size is recorded but is **not** the criterion — see the correction above.) | **Pass, on this lane at last** — `Initial QUIC datagram attempt 1 received pong.` → `Verified a QUIC datagram round trip.`, with `QUIC datagram verified: true` in the header and the reported usable size still `0`. First hardware evidence for datagrams; it agrees with Lane C's | 2026-09-01 |
| Channel binding (on-radio) | Both endpoints derive the same TLS-exporter hash from the live connection and each verifies the other's signature over it. | **Pass** — `Verified both Fernlet signatures against the same TLS exporter hash.` The introduction does not verify unless both endpoints derived the same hash from the live connection | 2026-09-01 |
| Heartbeat flow | Authenticated heartbeats are observably sent and acknowledged over the live tunnel. | **Not observed on this lane — the window was too short, and the probe could not have held one anyway.** `authenticated heartbeats: 0` over a 13 s window (`6:35:19 PM` connect → `6:35:30 PM` copy) against a 30 s interval, so zero is the expected reading. The run then hit the idle-timeout defect below, which would have reaped the tunnel before the first beat regardless. Answered on Lane A2 the same day, post-fix: three beats at 30 s spacing | 2026-09-01 |
| Reconnect after idle timeout | A tunnel lost to an idle timeout is re-dialed and the peer's listener accepts it. | **Fail** — the device's inbound connection timed out and every re-dial was then refused at the device's listener with `NECP_CLIENT_ACTION_ADD_FLOW … [17: File exists]`. **Root-caused, fixed in the probe and verified on Lane A2 the same day**; whether the *shipping* transport shares the kernel half is Lane D's question. See *The reconnect failure* below | 2026-09-01 |
| Background continuation | A user-started `BGContinuedProcessingTaskRequest` begins with system activity. | **N/A on this lane** — the report was captured on the Simulator side, which refuses the request outright: `Background continuation is unavailable: … (BGTaskSchedulerErrorDomain error 1.)`. This is a Lane B row and stays deferred to P8 | 2026-09-01 |
| Channel binding (off-radio) | A changed mesh ID, epoch, nonce, identity, or binding hash fails verification. | **Pass** — `MeshNetworkFeasibilityTests.signedIntroductionRejectsAnyChangedChannelBinding`, run in the standard suite | 2026-08-29 |
| Dial policy | Self-candidates, already-failed candidates, and simulator→simulator dials are refused by default. | **Pass** — `MeshNetworkFeasibilityTests.discoveryPolicyRejectsSelfAndPreviouslyFailedCandidates`; the sim→sim refusal is opt-out only via `FERNLET_PROBE_ALLOW_SIM_DIAL` (Lane A2). Held live here too: the report's `simulator-to-simulator dial: refused (default)` | 2026-09-01 |
| Plist configuration | The three keys the lane needs are present and the registration identifier is concrete, not the wildcard. | **Pass** — `MeshNetworkFeasibilityTests.probeInfoPlistConfigurationAllowsTheDeviceSpike` | 2026-08-29 |

**What changed on 2026-09-01, and what did not.** Five rows moved to `Pass` on captured evidence
rather than recollection, and the Datagram row moved for the first time *on hardware* — it had been
answered only on Lane C. What did **not** move: this run crossed a USB tether, so no Wi-Fi-path row
and nothing about AWDL is promoted by it, and the Wi-Fi Aware / peer-to-peer questions stay exactly
where they were. And the run found a real defect, recorded as the lane's first `Fail`.

**"Observed working" is not a Pass, deliberately** — the rule that governed this table until today,
kept because it is the reason the promotion above means anything. The owner had reported (2026-08-31)
that a device and a Simulator discover and connect; that was real information and it was *not*
recorded as a Pass, because it was not a captured **Copy diagnostic report** with byte counts,
connect timestamps and the negotiated datagram size in it. It is one now, so the rows moved.

#### The link was not Wi-Fi

The runbook's own procedure says "the same non-isolated infrastructure Wi-Fi". This run did not use
it, and reading the addresses is what says so:

- The Simulator reached the device at `fe80::c6:e886:e3b5:bee8%en9.59535`; the device's own console
  names the same address scoped to its `en2`.
- On the Mac, `en9` carries `fe80::1c20:a841:6b8e:6c0` and `169.254.116.160` — an IPv4 **link-local**
  address, i.e. no DHCP lease — and reports `media: autoselect (100baseTX <full-duplex>)`.
- `en9` does not appear in `networksetup -listallhardwareports` at all (Wi-Fi there is `en0`). It is a
  dynamically created interface, and the routing table holds a direct link-layer entry for the
  device: `169.254.149.89  26:55:9a:92:80:73  UHLSW  en9`.

A 100baseTX full-duplex interface that no network service owns, addressed link-local only, with a
direct route to the attached phone, is the **iPhone-USB (Ethernet-over-USB) tether Xcode brings up
for a connected device** — not infrastructure Wi-Fi.

Consequences, stated so nobody reads more into the table than it holds:

- **Every row above the IP layer is unaffected.** Bonjour, QUIC, TLS, the exporter binding, the
  signed introduction and the datagram round trip do not care which link carried the packets, and
  this is real hardware running the real QUIC stack at both ends.
- **No Wi-Fi-path row is promoted, and no AWDL row is even touched.** Item 11 (the Wi-Fi path
  question) stays open. Note the device console's evaluator parameters *do* say `use awdl` — that is
  the parameters requesting peer-to-peer, not evidence that a peer-to-peer radio carried anything.
- **Re-run over Wi-Fi before treating this as the standing loop's baseline.** Unplug the cable, keep
  both ends on the same non-isolated Wi-Fi with no VPN, and confirm the ready line names a routable
  or `%en0`-scoped address rather than `%en9`.

#### The reconnect failure, and what it was

Two faults, one behind the other. Naming them separately matters because only one of them is the
probe's own and only one of them could reach the shipping transport.

**Fault 1 — the tunnel was reaped by QUIC's idle timer, at the probe's own heartbeat cadence.** The
device console:

```
nw_read_request_report [C4] Receive failed with error "Operation timed out"
quic_packet_builder_append_for_pn_space builder is null or 0
quic_conn_send_internal path is null or 0
nw_connection_group_handle_connection_state_changed [G1] connection [C1 connected
  fe80::1c20:a841:6b8e:6c0%en2.63016 quic, local: fe80::c6:e886:e3b5:bee8%en2.59535, definite,
  attribution: developer, server, path satisfied, viable, interface: en2, scoped]
  failed with error Operation timed out
```

This is **exactly the defect P2 item 15 measured and fixed in `NetworkMeshSession`, still live in the
probe** — item 15 changed the shipping transport and the probe only got that round's datagram-gate
change. The probe declared no `max_idle_timeout`, so it inherited Network.framework's default of
roughly 30 s, while `heartbeatInterval` was also 30 s. Worse than on Lane C, because of who beats:
`runInitiator` starts the heartbeat loop and sleeps a full interval before the first beat, while
`runResponder` only *answers* datagrams. So after the initial ping/pong at `6:35:19`, nothing at all
was due to cross the wire until `6:35:49` — and the reap was due at the same instant. A keepalive
that fires no sooner than the timeout it defends against is not a keepalive.

Fixed the same way item 15 fixed the transport: `idleTimeoutMilliseconds` is derived from the
probe's own beat interval as `heartbeatIntervalSeconds × missedBeatsBeforeIdleReap` (30 × 3 = 90 s)
and declared on **both** the listener and the connection parameters, because QUIC negotiates the
minimum of the two advertised values. The ready event and the diagnostic report now carry
`idleTimeoutMs=` and the peer's advertised value, so the next run's report proves the fix is on the
wire instead of leaving a reader to infer it.

**Fault 2 — every re-dial afterwards was refused at the device's listener.** The console again:

```
nw_path_evaluator_create_flow_inner failed NECP_CLIENT_ACTION_ADD_FLOW (null) evaluator parameters:
  quic, definite, server, attribution: developer, reuse local address, … use awdl,
  local address: fe80::c6:e886:e3b5:bee8%en2.59535
nw_path_evaluator_create_flow_inner NECP_CLIENT_ACTION_ADD_FLOW C565CBD6-… [17: File exists]
nw_endpoint_flow_setup_channel [C6 fe80::1c20:a841:6b8e:6c0%en2.52176 initial channel-flow …]
  failed to request add nexus flow
nw_connection_create_from_protocol_on_nw_queue [C6] Failed to create connection from listener
nw_ip_channel_inbox_handle_new_flow nw_connection_create_from_protocol_on_nw_queue failed
```

and the same three lines again for the IPv4 link-local attempt (`C8`, `local address:
169.254.149.89:59535`). `EEXIST` on `ADD_FLOW` means the kernel still holds a flow registration for
that local endpoint, so the listener cannot create a connection for the new one. Note that both
refusals name port **59535** — the listener's port — under two *different* local addresses (v6 then
v4) and two different remote ports, so the collision is on the listener's own registration, not on a
5-tuple.

**The trigger is probe-only, and it was found by reproducing it — not by reading the code.** The
first reading of this file said the probe ends its whole run on any tunnel error
(`inboundTunnelStopped` → `tunnelStopped` → `endProbe` → `stopNetworkOperations()`, which sets
`listener = nil`), so the re-dials must have hit a listener in teardown. **That reading was wrong,
and a sim↔sim run disproved it in three minutes.** It is recorded here because the true cause is
worse and quieter, and because "the code says it ends" was a completely plausible wrong answer.

**Reproduction, sim↔sim probe lane, 2026-09-01 18:54–18:58.** Two Simulators, `ALLOW_SIM_DIAL`,
`AUTOSTART`, `CONSOLE_LOG`; the initiator's app process suspended with `kill -STOP` for 110 s (past
the 90 s timeout) and resumed with `kill -CONT`:

```
# A — the responder, the survivor
6:54:59 PM: QUIC ready with an inbound peer at 169.254.116.160:57196; … idleTimeoutMs=90000,
            usable datagram frame size=0 bytes, peer idleTimeoutMs=90000, beatSeconds=30.
6:54:59 PM: Verified a QUIC datagram round trip.
6:56:29 PM: QUIC failed for an inbound peer: … (Network.NWError error 60 - Operation timed out)
            ← and then NOTHING. No "Ending mesh feasibility probe". No "Accepted inbound QUIC
              tunnel". Minutes of silence.

# B — the initiator, suspended and resumed
6:57:09 PM: QUIC failed for …[Simulator]: … (NWError 60 - Operation timed out)
6:57:09 PM: Outbound QUIC tunnel ended; retry 2 of 3: … (NWError 57 - Socket is not connected)
6:57:12 PM: Opening QUIC tunnel attempt 2 to fernlet-probe-dbb87903-….
            ← the re-dial, which never reached `.ready`, never reached `.failed`, and was never
              accepted
```

The run confirms three things at once, and one of them is the answer:

1. **The idle-timeout fix negotiates.** `idleTimeoutMs=90000` in the live options, `peer
   idleTimeoutMs=90000` read back off the connection, and the reap landed at `6:56:29` — exactly
   90 s after `6:54:59`, where the old default would have fired at 30.
2. **The survivor did not end its probe.** Zero `Ending mesh feasibility probe` lines. The
   "end-on-any-tunnel-error" theory is dead.
3. **The survivor's responder task never returned.** That is the defect.

**Why: the responder never writes unless written to, so it can never notice a dead peer.**
`runResponder` parks in `answerDatagrams`, a QUIC **datagram** receive, which did not throw when the
connection failed — the task was still parked minutes after `.failed`. Two consequences follow, and
they are the two symptoms:

- `inboundTunnelTask` never cleared, so `acceptIncoming`'s `guard … inboundTunnelTask == nil`
  **silently dropped every re-dial** — the userspace half, and the reason B's attempt 2 vanished.
- The parked task's frame kept the dead `NetworkConnection` alive. **That is what leaves the NECP
  flow registered**, and on a physical link-local `use awdl` path it is what answers the listener's
  next `ADD_FLOW` with `[17: File exists]` — the kernel half, and the device's symptom.

One leak, two symptoms, on two different layers. The initiator escapes it because it *does* write
unprompted: its heartbeat send threw `NWError 57` and `outboundTunnelStopped` ran normally.

**Fixed in the probe** (2026-09-01): `connectionStateChanged`'s `.failed` case now calls
`releaseFailedInboundTunnel`, which clears `inboundTunnelTask`, frees the connection slot and cancels
the task holding the connection — one tunnel ends, the listener keeps running, which is what
`NetworkMeshSession.endTunnel` does. `acceptIncoming`'s refusal also logs a line now instead of
returning silently; a wedge that leaves no trace is how this cost a device run.

**Verified on the radio, same lane, same `kill -STOP` procedure, with the fix in.** The whole cycle
now completes, and the run also fills in the Heartbeat row this lane could not:

```
# B — the responder, the survivor
7:01:40 PM: Accepted inbound QUIC tunnel id=1.
7:01:40 PM: QUIC ready with an inbound peer … idleTimeoutMs=90000, peer idleTimeoutMs=90000,
            beatSeconds=30.
7:03:10 PM: QUIC failed for an inbound peer: … (NWError 60 - Operation timed out)   ← 90 s exactly
7:03:10 PM: Released the failed inbound QUIC tunnel; the listener can accept a re-dial.
7:03:46 PM: Accepted inbound QUIC tunnel id=5.                                       ← the re-dial
7:03:46 PM: Control responder accepted signed channel introduction.
7:04:16 PM: Responder received heartbeat.
7:04:46 PM: Responder received heartbeat.
7:05:17 PM: Responder received heartbeat.                                            ← 30 s spacing

# A — the initiator, suspended 7:01:54–7:03:44
7:03:44 PM: Outbound QUIC tunnel ended; retry 2 of 3: … (NWError 57 - Socket is not connected)
7:03:46 PM: Opening QUIC tunnel attempt 2 to fernlet-probe-f710bb63-….
7:03:46 PM: Initial QUIC datagram attempt 1 received pong.
```

Four things this settles that the Lane A device run could not: the declared 90 s timeout is what the
connection actually uses (the reap is 90 s after ready, not 30); a reaped inbound tunnel is released
instead of wedging its listener; the re-dial is accepted and re-completes the signed introduction and
the datagram round trip; and **authenticated heartbeats flow at 30 s spacing**, which is the row the
13-second device window left blank. What it still cannot say anything about is the kernel `EEXIST` —
see the caveats below.

**Is the mechanism shared with production? Not on the evidence, but the question is not closed.**

| | Probe | Production (`NetworkMeshSession.swift`) |
| --- | --- | --- |
| What the responder parks in | `answerDatagrams` — a **datagram** receive, observed not to throw on connection failure | `receiveFrames(for:from:)` — a **control-stream** receive, observed to throw: Lane C's `tunnelEnded controlStreamEnded … NWError 60` lines are that throw |
| A tunnel error… | now: `releaseFailedInboundTunnel`, listener kept | `endTunnel(_:cause:reason:)` → `tunnels.removeValue(forKey:)` + `cancelTasks()`. **The listener is never touched**; `stop()` and `updateDiscoveryInfo` are its only other writers |
| A failed *pending* inbound | no pending state; one `inboundTunnelTask` | `dropPendingInbound(_:)`, plus `expirePendingInbound(now:)` on the shared poll |
| Concurrent inbound tunnels | one | `maxPendingInboundTunnels` pending + `MeshLinkTable.maxConcurrentLinks` live |

So the shipping transport's inbound teardown is driven off the **stream** receive, which does throw,
and Lane C recorded it re-dialing successfully after idle timeouts four times per side. Two caveats
keep this from being a clean acquittal:

- The `EEXIST` is a property of a *listener-derived nexus flow on a link-local, `use awdl` path*.
  Neither the sim↔sim lane nor Lane C can produce one — two Simulators share the host stack and meet
  over a routable host address with peer-to-peer disabled — so Lane C's successful re-dials are weak
  evidence about this specific kernel path.
- Production also runs a **datagram reader task** per tunnel (`datagramTask`). Nothing here proves it
  unblocks on connection failure; what it proves is that production does not *depend* on it to end a
  tunnel. If a device run shows the leak anyway, that task is the first place to look.
- **There is no fix of the "explicitly cancel the connection" shape available to either side.** In
  the iOS 26 Swift-native Network API, `NetworkConnection` exposes `start()`, `onStateUpdate`, the
  endpoints and `tryNextEndpoint` — and **no `cancel()`**; the legacy `NWConnection.cancel()` is on a
  different type. Dropping the last reference is the only release there is, which is why the probe's
  fix cancels the task that holds it. Do not plan a production fix around a `cancel()` call.

The residual question — *can a live `NetworkMeshSession` listener accept a re-dial on a link-local
peer-to-peer path after one of its inbound connections idled out?* — is unanswerable without putting
the **shipping transport** on hardware, which has never been done. That run is Lane D, below.

#### Evidence — the captured artifacts, in full

The Simulator's **Copy diagnostic report**, 2026-09-01 18:35:32:

```
Fernlet mesh feasibility diagnostic (DEBUG only)
generated: 9/1/2026, 6:35:32 PM
transport: Simulator infrastructure
simulator-to-simulator dial: refused (default)
status: Signed QUIC control stream verified
running: true
background task: not active
signed control stream: true
QUIC datagram verified: true
advertised QUIC DATAGRAM frame size: 1024
advertised QUIC UDP payload size: 1280
live QUIC options: DATAGRAM=1024, UDP=1280, datagram-flow=false
usable datagram frame size: 0
authenticated heartbeats: 0
bytes sent: 784
bytes received: 785
connects: 1 (first 6:35:19 PM, last 6:35:19 PM)
reconnects: 0 (last never)
thermal state: nominal
low power mode: false
shutdown reason: none
candidates:
fernlet-probe-ab5ae6b8-2d5a-4e3e-bb06-b4addba2bad5._fernlet-mesh2._udplocal. [device]
events:
6:35:18 PM: Start requested; host=Simulator infrastructure, peer-to-peer=false, DATAGRAM=1024, UDP=1280.
6:35:18 PM: Local Fernlet signing identity is provisioned.
6:35:19 PM: Cleared any prior continuation request before submitting a new one.
6:35:19 PM: Background continuation is unavailable: The operation couldn't be completed. (BGTaskSchedulerErrorDomain error 1.)
6:35:19 PM: Starting Simulator infrastructure probe on _fernlet-mesh2._udp.
6:35:19 PM: QUIC listener is ready.
6:35:19 PM: Bonjour listener advertised fernlet-probe-cd6b1fdf-47d2-4a70-a613-2680ad59d2c8._fernlet-mesh2._udp.local..
6:35:19 PM: Listening and browsing on _fernlet-mesh2._udp.
6:35:19 PM: Bonjour browser is ready.
6:35:19 PM: Bonjour discovery has 1 candidate(s).
6:35:19 PM: Opening QUIC tunnel attempt 1 to fernlet-probe-ab5ae6b8-2d5a-4e3e-bb06-b4addba2bad5._fernlet-mesh2._udplocal. [device].
6:35:19 PM: QUIC waiting for fernlet-probe-ab5ae6b8-…_udplocal. [device]: The operation couldn't be completed. (Network.NWError error 50 - Network is down)
6:35:19 PM: Control initiator opened stream id=0.
6:35:19 PM: QUIC ready with fernlet-probe-ab5ae6b8-…_udplocal. [device] at fe80::c6:e886:e3b5:bee8%en9.59535; DATAGRAM=1024, UDP=1280, datagram-flow=false, usable datagram frame size=0 bytes.
6:35:19 PM: Power state: thermal=nominal, lowPowerMode=false.
6:35:19 PM: Control initiator sent identity hello.
6:35:19 PM: Control initiator accepted remote identity hello.
6:35:19 PM: Control initiator sent signed channel introduction.
6:35:19 PM: Control initiator accepted remote signed channel introduction.
6:35:19 PM: Verified both Fernlet signatures against the same TLS exporter hash.
6:35:19 PM: QUIC datagram capability check: reported usable frame size=0, required=23. Reported on the parent connection, so it is evidence only — the ping/pong below is the test.
6:35:19 PM: Sending initial QUIC datagram ping attempt 1 of 3.
6:35:19 PM: Initial QUIC datagram attempt 1 received pong.
6:35:19 PM: Verified a QUIC datagram round trip.
6:35:30 PM: Copied mesh feasibility diagnostic report to the pasteboard.
```

Two lines in it are worth not misreading. `Network is down` (error 50) at `6:35:19` is a transient
`.waiting` on the way up, not a failure — `.ready` follows in the same second. And `usable datagram
frame size: 0` sits directly above `QUIC datagram verified: true`, which is the whole point of the
item-15 correction: the number is evidence, the ping/pong is the test.

The device's Xcode console for the same run, mesh lines only (startup, HealthKit, CloudKit and ODR
lines omitted as unrelated); the device probe's own event log was not captured:

```
boringssl_session_set_peer_verification_state_from_session(492) [C2:1] Unable to extract cached
  certificates from the SSL_SESSION object
nw_protocol_instance_set_output_handler Not calling remove_input_handler on 0x11fd61e00:udp
nw_read_request_report [C4] Receive failed with error "Operation timed out"
quic_packet_builder_append_for_pn_space builder is null or 0
quic_conn_send_internal path is null or 0
nw_connection_group_handle_connection_state_changed [G1] connection [C1 connected
  fe80::1c20:a841:6b8e:6c0%en2.63016 quic, local: fe80::c6:e886:e3b5:bee8%en2.59535, definite,
  attribution: developer, server, path satisfied (Path is satisfied), viable, interface: en2,
  scoped] failed with error Operation timed out
nw_path_evaluator_create_flow_inner failed NECP_CLIENT_ACTION_ADD_FLOW (null) evaluator parameters:
  quic, definite, server, attribution: developer, reuse local address, context: Default Network
  Context (private), proc: 729602E6-…, delegated upid: 0, use awdl,
  local address: fe80::c6:e886:e3b5:bee8%en2.59535
nw_path_evaluator_create_flow_inner NECP_CLIENT_ACTION_ADD_FLOW C565CBD6-… [17: File exists]
nw_endpoint_flow_setup_channel [C6 fe80::1c20:a841:6b8e:6c0%en2.52176 initial channel-flow …]
  failed to request add nexus flow
nw_endpoint_flow_failed_with_error [C6 …] already failing, returning
nw_endpoint_handler_create_from_protocol_listener [C6 … failed channel-flow …]
  nw_endpoint_flow_pre_attach_protocols
nw_connection_create_from_protocol_on_nw_queue [C6] Failed to create connection from listener
nw_ip_channel_inbox_handle_new_flow nw_connection_create_from_protocol_on_nw_queue failed
… the same five lines again for C8, local address: 169.254.149.89:59535, remote 169.254.116.160:54914
```

The `boringssl … Unable to extract cached certificates` line is expected and not a fault: the DEBUG
listener presents a fixed self-signed test identity that neither side trusts or caches, and the
Fernlet-signed, exporter-bound introduction is the only authentication check on this lane.

**Two gaps in the evidence, named rather than papered over.** The device probe's own **Copy
diagnostic report** was not captured, so the device's view of the introduction is inferred from the
Simulator's (`accepted remote signed channel introduction` cannot be logged unless the device signed
one). And the Simulator's report was copied at `6:35:30`, *before* the timeout at roughly `6:35:49`,
so the report shows a healthy connection and the console shows what happened next — the two artifacts
do not overlap in time. Capture both sides' reports at the end of the next run.

#### Run 2 and run 3 (2026-09-01, post-fix): the fix on the wire, a benign teardown EEXIST, and a device freeze

Three runs on the same physical device over the same USB tether, all within ~40 minutes of the
item-1 fix (`e5a4e80`). Run 1 is the one recorded above. Runs 2 and 3 are recorded here because run
2 verifies the fix on the wire, and run 3 raised — and this note answers — a sharper question than
run 1 did.

**Run 2 (19:13): the idle-timeout fix is deployed and negotiated.** Fresh install carrying
`e5a4e80`. The ready line now advertises the derived 90 s timeout on both sides, and QUIC took the
minimum of two equal values. Connect, signed introduction both ways, and the datagram round trip all
succeeded again:

```
QUIC ready with <device> at fe80::d0d4:faff:fee2:4f9e%en8.58565; DATAGRAM=1024, UDP=1280,
  datagram-flow=false, idleTimeoutMs=90000, usable datagram frame size=0 bytes,
  peer idleTimeoutMs=90000, beatSeconds=30.
Initial QUIC datagram attempt 1 received pong → Verified a QUIC datagram round trip
```

**What run 2 did NOT re-test: reconnect-after-idle-timeout.** The tester stopped the probe ~10 s
after connect — far inside the 90 s idle window — so the tunnel was never idle-reaped and no re-dial
was ever attempted. The reconnect-after-idle axis (run 1's `Fail`, fixed and verified on Lane A2 by
`kill -STOP`) was **not** re-exercised on hardware here. It stays owed by Lane D.

**The teardown EEXIST in run 2 is benign teardown/multipath noise — verdict, with a repro behind
it.** The device console showed the same `NECP_CLIENT_ACTION_ADD_FLOW … [17: File exists]` pattern as
run 1, but this time every occurrence is **bracketed by "already cancelled" lines**, during a
**tester-initiated stop**, across two interfaces (`anpi0` and `en2`) for the **same listener port
58565**:

```
nw_listener_cancel_block_invoke [L1] Listener is already cancelled, ignoring cancel   (x4)
nw_connection_group_cancel_block_invoke [G1] The group has already been cancelled     (x2)
NECP_CLIENT_ACTION_ADD_FLOW … local address: fe80::…%anpi0.58565 … [17: File exists]
NECP_CLIENT_ACTION_ADD_FLOW … local address: fe80::…%en2.58565   … [17: File exists]
```

This is the OS's own multipath, not the probe's. The probe dials with a single `NetworkConnection`
and listens with a single `NetworkListener`; it never creates an `NWConnectionGroup` or a
`.multipath` service (grep the source — there is no connection-group construction). The `[G1]/[G2]`
group and the anpi0+en2 fan-out are Network.framework's QUIC-listener *nexus* evaluating every viable
link-local `use awdl` path for the listener's one fixed port. During teardown, one path's flow is
cancelled while the OS is still setting up the sibling path's flow on the same port → `[17: File
exists]`. It blocks **nothing**: nobody is re-dialing (the tester stopped the run) and the whole
listener is being dropped anyway. This is categorically different from run 1, where a *wedged*
responder held a *dead* connection's flow and the peer's *live* re-dials were what got refused. Run 1
was a real wedge (closed by `releaseFailedInboundTunnel`); run 2 is teardown noise.

**Run 3 (same session): the physical device FROZE, and sim+device never connected.** The Simulator's
log shows the **listener failing to set up** — not a connect failure:

```
nw_listener_socket_inbox_create_socket setsockopt SO_NECP_LISTENUUID failed [2: No such file or directory]
nw_browser_cancel [B1] already cancelled (x3); nw_listener_cancel [L1] already cancelled (x4)
```

— then no `Bonjour discovery has N candidate(s)`, no `QUIC ready`, no dial. The three-run shape (run
1 connect → blocking EEXIST; run 2 connect → teardown EEXIST; run 3 device frozen + sim
listener-setup failure) sharpens the question from "is run 2's EEXIST benign" to **"does the probe
leak NECP flow/listener state that accumulates across repeated start/stop cycles until the stack
wedges?"**

**Answered on the sim↔sim probe lane, 2026-09-01 ~19:25–19:37: no accumulation, every restart
clean.** Two Simulators (iPhone 17 + iPhone 17 Pro), `ALLOW_SIM_DIAL` + `AUTOSTART` + `CONSOLE_LOG`,
the item-1 binary:

- **10 back-to-back fresh-process relaunches of one side.** Every one reached `QUIC listener is
  ready` in 2–3 s, with **0** `SO_NECP_LISTENUUID failed` and **0** `ADD_FLOW … [17: File exists]`.
  Run 3's sim-side listener-setup symptom did not reproduce across ten relaunches.
- **The survivor (one long-lived process) across a full accept → peer-vanishes → release → re-accept
  cycle.** It accepted an inbound tunnel, the peer was hard-killed, and about a minute later — its
  idle timer runs from the last packet, ~90 s earlier — it detected the dead peer and released it,
  the item-1 fix firing in-process on the survivor, then re-accepted the relaunched peer's re-dial:

```
7:37:03 QUIC failed for an inbound peer: … (NWError 60 - Operation timed out)
7:37:03 Released the failed inbound QUIC tunnel; the listener can accept a re-dial.
7:37:05 Accepted inbound QUIC tunnel id=6.        ← re-dial accepted, 2 s later
```

  Tally over the cycle: 2 accepts, 1 release, and **0** cap-`Ignored`, EEXIST, or NECP markers. The
  code matches the behaviour: `stopNetworkOperations()` cancels and nils all six tasks, drops
  `listener` and `browser` to `nil` (dropping the last reference is the only "cancel" the iOS 26
  `NetworkConnection` API has), and calls `activeConnectionIDs.removeAll()`; every tunnel-teardown
  path (`releaseFailedInboundTunnel`, `inboundTunnelStopped`, `outboundTunnelStopped`) removes its
  slot; the responder is hard-capped at one inbound tunnel and the listener at `maxConnections = 4`.
  A restart binds a **fresh ephemeral Bonjour port**, so it never asks for the just-freed port — the
  run-2 EEXIST is intra-listener and cannot carry into a restart.

  One expected behaviour worth stating: a hard-killed peer sends no QUIC `CONNECTION_CLOSE`, so the
  survivor cannot notice the loss until its 90 s idle timer fires — and it refuses re-dials
  (`Refused an inbound QUIC tunnel: one inbound tunnel is already held`) during that window. That is
  the single-inbound cap doing its job, not a leak; it self-heals at the timeout and holds at most
  one stale tunnel, never a growing set.

**Honest causation.** A full **device freeze** is more severe than a userspace flow leak alone
usually causes, and the sim-side `SO_NECP_LISTENUUID [2]` is plausibly a CoreSimulator networking
hiccup independent of the device. The sim lane shows the probe does **not** accumulate NECP/listener
state and that every restart is clean — so the freeze is **not demonstrably the probe**. But the sim
cannot settle it either way: sim↔sim meets over a routable host address with peer-to-peer disabled,
so it never exercises the link-local `use awdl` nexus-flow path that produced the kernel `EEXIST` on
the device. That specific path — and whether the *shipping* transport leaks on it — is
unreproducible without hardware. **Lane D remains owed**, and it is the run that can answer it.

**`anpi0`** is an Apple-internal peer interface that came up alongside the USB tether in run 2. Its
presence, plus `en2` and all-link-local addressing, is one more confirmation that run 2 — like run 1
— was **not** infrastructure Wi-Fi. Read it only as "an Apple-internal interface that appeared
alongside the USB path," never as infrastructure Wi-Fi or evidence of it.

Artifacts (retained with this round's working notes): `lane-a-run2-sim-2026-09-01.txt`,
`lane-a-run2-device-console-2026-09-01.txt`, `lane-a-run3-sim-2026-09-01.txt`, and the sim-lane
repro logs.

#### Lane A — owner runs 2026-09-02 (heartbeats on hardware; the continued-processing budget)

Two owner runs on the evening of 2026-09-02, phone (physical, `peer-to-peer=true`, a
`BGContinuedProcessingTaskRequest` submitted with the **fail-immediately** strategy) ↔ one Simulator
on the same Mac. The phone was on the same Wi-Fi as the Mac **and** attached by USB — both facts
matter below, because the two runs took two different links.

**Read what this lane is first.** These are runs of the **DEBUG feasibility probe** on
`_fernlet-mesh2._udp` — the instrument, not `NetworkMeshSession`. Nothing here is a production-mesh
result, and nothing here closes Lane D.

| Run / time | Path and interface | What was verified | How it ended |
| --- | --- | --- | --- |
| **Run 1** — 7:38 PM, ~4 s | Wi-Fi, phone-side `en0`, link-local IPv6 | Simulator dialled the phone; the phone accepted inbound. Both endpoints verified the other's signed channel introduction **against the same TLS exporter hash**. QUIC datagram ping/pong on attempt 1. 786 bytes each way. `authenticated heartbeats: 0` — a 4 s session against a 30 s beat, so zero is the expected reading | Stopped by the tester at ~4 s. The Simulator saw `NWError 57 - Socket is not connected` because the phone stopped first — the known hard-close signature |
| **Run 2, tunnel 1** — Simulator start 7:43:54, ready 7:43:55, dead 7:44:53 (~58 s) | Wi-Fi, phone-side `en0`, link-local | Signed introduction both directions and the datagram round trip, again | `NWError 57` at 7:44:53. **Why is not captured** — see below |
| **Run 2, retry gap** — attempt 2 opened 7:45:01, waited 28 s | — | The Simulator's bounded budget doing its job: `retry 2 of 3`, then a survivor patiently waiting for the peer to come back | Ended when the owner restarted the phone's probe at 7:45:27 |
| **Run 2, tunnel 2** — ready 7:45:29 | **USB**, phone `anpi0` ↔ Simulator `en8`, link-local — *not* Wi-Fi | Fresh signed introduction both directions and a fresh datagram round trip. **The phone received an authenticated heartbeat at 7:46:01**, 32 s after ready — the first heartbeat evidence on hardware. The Simulator counted 2 heartbeats across its two tunnels | The owner backgrounded the phone app; at 7:46:13 the phone logged `Ending mesh feasibility probe: iOS expired or cancelled the continued-processing task`, completed the task with `success=false`, and the tunnel died. Simulator `NWError 57` at 7:46:13, `retry 3 of 3` at 7:46:33, attempt 3 still pending when the report was copied |

**Final counters.** Phone: connects 1, heartbeats 1, 815 bytes sent / 813 received, thermal state
nominal, Low Power Mode off. Simulator: connects 2, reconnects 2, heartbeats 2, 1628 sent / 1631
received. The phone's counters cover only its second launch, which is why its connect count is 1
against the Simulator's 2.

**Background-continuation lines, both sides.** Phone: `The continued-processing task started; the
system activity is now task-owned.` Simulator: `Background continuation is unavailable:
BGTaskSchedulerErrorDomain error 1` — expected, and the same refusal the 2026-09-01 report carries.

**Noise seen and dismissed, so nobody re-opens it.** A transient `NWError 50 - Network is down` on
both sides immediately before `QUIC ready` in run 1 (harmless; the connection came up). The phone's
listener logged the documented benign `NECP_CLIENT_ACTION_ADD_FLOW … [17: File exists]` /
`Failed to create connection from listener` once per run and the tunnel came up anyway — the run-2
(2026-09-01) teardown/multipath signature, not run 1's wedge. On tunnel 2 the phone logged
`Refused an inbound QUIC tunnel: one inbound tunnel is already held` **twice** — the Simulator's dial
arrived on more than one path — and `quic_conn_process_inbound … unable to parse packet` once, a
stray packet addressed to the retired connection id.

**Interpretation — stated narrowly, because it is easy to overclaim from here.**

1. **Neither tunnel loss was a network failure, and the probe cannot tell us whether one would be.**
   The probe *tears itself down* when the continued-processing task ends: task ends → `endProbe` →
   `stopNetworkOperations()`. That is by design, and it means this instrument can say **nothing**
   about whether a QUIC tunnel survives backgrounding on its own. Answering that needs a
   probe/harness variant that **keeps the tunnel and keeps logging after task expiry** — which is a
   P8 experiment, not a re-run of this one.
2. **First measured continued-processing budget on hardware: iOS ended the task ≈ 46 s after it
   started**, shortly after the app was backgrounded, with the fail-immediately strategy. **One
   sample.** Candidate causes for P8 to separate, none of them asserted here: the probe reports no
   progress on the task (§14 makes monotonic progress the shipping requirement precisely because the
   system kills tasks that do not advance); the USB/debugger attachment; or simply the system's own
   policy for a task of this shape. Do not quote 46 s as a budget — quote it as the first sample.
3. **Multi-path, and why Lane D says "unplug the cable".** With the cable attached, tunnel 2 took the
   **USB** path (`anpi0`/`en8`) even though tunnel 1 had just run over Wi-Fi `en0`, and the phone
   refused the duplicate dials that arrived on the other path. This run is **not** Lane D and closes
   none of its rows.
4. **AWDL was not exercised.** Both ends were on the same infrastructure Wi-Fi and the Wi-Fi path was
   `en0`; peer-to-peer was requested in the parameters, which is not evidence a peer-to-peer radio
   carried anything.
5. **Proven on hardware for the first time, and this is the run's real yield:** signed channel
   introduction in **both** directions, a datagram round trip, **authenticated heartbeats**, and a
   bounded reconnect in which the survivor waits for the peer to return and then completes a fresh
   introduction on the new tunnel.
6. **Item 11's permission half was observably granted.** The phone browsed and found the Simulator,
   which it cannot do without Local Network access. The AWDL half of item 11 is untouched.

**Not captured, and stated rather than guessed:** the phone's report for the interval covering tunnel
1's death. The likeliest reading is the same mechanism as tunnel 2 — the *first* continued-processing
task expiring after an earlier backgrounding, tearing the probe down under it — and ~58 s is in the
same neighbourhood as the 46 s that *was* measured. It is a reading, not a record; the phone-side log
for 7:43–7:45 would settle it.

**What this changes for Lane D and Lane B (P8).**

- **Lane D — unchanged in what it owes, sharper in how to run it.** The cable steered a live tunnel
  onto USB mid-run here, so the runbook's "unplug the cable" step is now an observed requirement, not
  a precaution. Lane D's `Wi-Fi path`, `Reconnect after a real idle timeout` and `No NECP flow leak`
  rows are all still `—`.
- **Lane D can now expect the Local Network prompt to already be granted** on this phone; treat that
  row as "confirm, not discover".
- **Lane B (P8) gains its first datum and its first blocking design note.** The 46 s observation
  belongs to §15.1, and the "probe tears down with the task" property means the background-survival
  row **cannot** be answered by re-running this probe — P8 must build the variant that outlives its
  own task before that row can move off `Deferred to P8`.
- **Nothing about battery, thermal, Low Power Mode or lock is touched.** Thermal nominal / Low Power
  off over a 4-minute foreground run is not a measurement of any of them.

Artifacts (retained with this round's working notes): the phone's and Simulator's **Copy diagnostic
report** output for both runs, and the phone's Xcode console for the 7:45–7:47 window.

### What this lane can and cannot prove

This matters more than it looks: the device↔Simulator lane is the **cheap, high-frequency** loop —
Xcode is attached, logs are right there, and a run costs minutes. Two-device runs are slow and
awkward by comparison. So the standing rule for every phase is: **push work down this list, never
up.**

| Tier | Prove it here | Why |
|---|---|---|
| **1. Unit tests, no radio at all** | Anything that is pure logic: the dial tie-breaker's total order, retry budgets, state machines, framing bounds, rejection rules, partition scenarios. | Free, deterministic, runs in CI. `Tests/FernletTests/Mocks/FakePeerTransport.swift` exists for exactly this. If a check *can* live here, it must. |
| **1b. Simulator ↔ Simulator, N nodes** | Real Bonjour, real QUIC, real TLS exporter, real crypto, real signed introductions — across 2, 3, 4 or 6 nodes, scripted, on one Mac with no hardware at all. **Amended 2026-09-02 (P3 item 0): "N nodes" is proven for N=2 only.** Three Simulators run, discover and hold tunnels, but form a spanning STAR (N−1 edges), not a full mesh — see "Lane C — THREE nodes" below for what a 3-node run can and cannot be asked to prove. **And QUIC datagrams**: proven on Lane C, 2026-09-01 (P2 item 15), correcting the earlier "not datagrams" reading. | Proven 2026-08-31. No device, no cable, no human tapping Start; `simctl` drives the whole run. Anything provable here must not be pushed up to tier 2. |
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
| Heartbeat flow | Authenticated heartbeats are observably sent and acknowledged over the live tunnel. | **Pass** — `Responder received heartbeat.` at `7:04:16`, `7:04:46`, `7:05:17`, i.e. three beats at 30 s spacing, each acknowledged. Only reachable once the idle timeout stopped reaping the tunnel first (P2 item 1) | 2026-09-01 |
| Reconnect after idle timeout | A tunnel lost to an idle timeout is re-dialed and the peer's listener accepts it. | **Pass, after a fix** — the initiator suspended with `kill -STOP` for 110 s; the responder reaped at exactly 90 s, logged `Released the failed inbound QUIC tunnel`, and accepted the re-dial 36 s later (`Accepted inbound QUIC tunnel id=5`), re-completing the signed introduction and the datagram round trip. Before the fix, the same run wedged silently — see Lane A's *reconnect failure* | 2026-09-01 |
| Declared QUIC idle timeout | Both endpoints advertise the derived timeout, and the connection uses it. | **Pass** — `idleTimeoutMs=90000` in the live options and `peer idleTimeoutMs=90000` read off the connection on both sides, with the reap landing 90 s after ready rather than the framework default's ~30 | 2026-09-01 |

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
not "does a tunnel come up", but **"is the tunnel selective"**.

> **Dated correction, 2026-09-21 (the MC→QUIC cutover).** `NetworkMeshSession` is now the DEFAULT:
> `MeshTransportFactory.shippingDefault` is `.quic`, so every launch runs this radio whether or not
> anything selects it. `SIMCTL_CHILD_FERNLET_MESH_TRANSPORT=quic` in the recipes below (and at
> ~`:1027`, ~`:1189`, ~`:1194`, ~`:1499`) is therefore a **no-op**, and it is **kept on purpose,
> not left by accident**: the variable still exists and `=multipeer` still selects the retired
> radio, so the same copy-paste drives a pre-cutover build and a post-cutover one, which is what
> makes a bisect across this boundary work. Do not delete it from the recipes until the deletion
> round retires the seam with `MeshMultipeerSession.swift`.
>
> **The seam is retired (the deletion round, 2026-09-22).** `MeshTransportKind`, `MeshTransportFactory` and the
> `FERNLET_MESH_TRANSPORT` read went with `MeshMultipeerSession.swift`; `NetworkMeshSession` is the only mesh radio a
> build can construct. The variable in the recipes below is now **inert on every build from this commit on** — a Simulator
> ignores an unknown child variable — and it is left in the recipes so the same copy-paste still drives a pre-deletion
> build for a bisect. Nothing reads it; `TestHookBoundaryTests`' `FERNLET_MESH` family lost that one declaration.

Every named rejection in
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
| `FERNLET_MESH_CHAOS_BARRED` | same | The roster's barred set is whatever the derived roster says (P3 item 7) — no extra keys. |

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
| 1a. **Provisional stranger** — the same launch shape as row 1 with the join doors open (2026-09-22, the deletion round's item 0) | **Observed — ACCEPTED, both directions.** Since D-4.3 an empty roster no longer refuses: `admitsStrangersProvisionally` admits the stranger to a *tunnel*, and membership is decided at the three doors above the transport. Row 1's refusal is now the CLOSED-doors answer (`isAdmittingNewPeers && isSessionOpen` false), pinned at tier 1 in `MeshIntroductionAuthorityRosterTests` | audit `mesh.introductionAuthority.legacyRosterFallback members=0` on both, then `[mesh-quic] accepted fb795f343c2954da sid=B6453553-…: tunnel activated, tunnels=1` on A and `accepted 1b4fd5b9e6f123e5 sid=7B49DC16-…` on B — see "Lane C — the deletion round's item 0" below for the founding and the double-mint re-dial that followed |
| 2. Non-roster member (valid identity, absent from THIS roster) | **Observed** — same mesh id on both sides, each roster holds two members and neither holds the peer | `refused unknownIdentity as responder: mesh=11111111-…-555555555555 epoch="" rosterMembers=2 rosterBarred=0`. Row 1 and row 2 are the same *rejection* and different *situations*; `rosterMembers` is what tells them apart, which is why the console line carries it. |
| 3. Hard-departed / removed member | **Observed as `barredMember`** | `refused barredMember as responder: … rosterMembers=2 rosterBarred=1` → `The peer has departed, been removed, or been blocked.` **P3 item 7 made this the shipping authority's own answer.** `MeshNetworkManager.roster` is now the derived roster (`admitted − departed − removed`), and `SignedAdmissionRecord` keeps the admitted member's signing key inside the record — so a verified removal or departure names a *key* and fills `barred` for real (walled at tier 1 in `MeshIntroductionAuthorityTests`). What is still owed on a radio is a removal produced by a real quorum, which needs ≥ 3 nodes (⌊|roster|/2⌋ + 1 votes): until loop item 9's 3-node lane, a two-Simulator run still reaches the branch with `FERNLET_MESH_CHAOS_BARRED`. |
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
| `FERNLET_MESH_FLOWS_AFTER=<polls>` *(2026-09-12, P6 item 10)* | same | **0 — today's behaviour exactly.** Flows fire on the first poll that has a committed slot, which on a `founder` run is the poll the founder collapses its seeded descriptor to itself: the derived roster is 1, so every routed mint answers `.noDestinations`. Set it past the admission grant (≈ 5–10 polls) to observe a routed delivery instead of the founding window. |
| `FERNLET_MESH_ALLOW_HEARTS=1` *(2026-09-12, P6 item 10)* | same | Off, and off leaves the device's own `allowNearbyHearts` setting untouched. The setting ships **off** and `localCapabilities()` advertises `.hearts` only when it is on, so this is applied **before `startJoin()`** — a flip afterwards would never reach a peer's capability list. |
| `FERNLET_MESH_AUTO_KEEP_FRIENDS=1` *(2026-09-12, P6 item 10)* | same | Off: no friend-review batch is ever kept, which is what every Lane C run before this one did. On, it stands in for **one tap** — `ConnectView.finalizeFriendKeeps()`'s — by calling the shipping `FernletStore.keepProximityFriends(from:keptFingerprints:)` and `MeshNetworkManager.completeFriendReview(_:)` on a batch a real session end promoted. It is checked in the poll **and again after `leave()` returns**, because the departer's poll ends inside `leave` and the batch is promoted by that very departure. |

**The launch restore is bypassed on this lane, by construction** *(2026-09-12, P6 item 10; the
sentence P6 item 7's handoff left owed)*. P6 item 7 mounted `restoreSessionContextOncePerLaunch(now:)`
at `FernletApp.swift:496`, in the ready view's `.onAppear` one statement after the routed gate push
— and `shouldRestoreSessionAtLaunch(alreadyMounted:meshHarnessSeeding:)` refuses whenever
`MeshMatrixDebugOptions.isEnabled`, i.e. whenever `FERNLET_MESH_MATRIX=1`. Every Lane C launch in
this runbook carries that flag, **the identity-harvest launch included**, so no run can inherit the
sealed context the previous run left on the same Simulator, and no `simctl erase` or reinstall is
needed between runs. The cost is the other side of the same coin and belongs in "what this lane
cannot prove": **Lane C cannot observe the launch restore at all.** A device that has run the app
WITHOUT the harness does restore, so any future lane wanting a green field must wipe the container
rather than relying on the pre-item-7 behaviour, where the door had no shipping caller.

**`.chat` is a ROUTED flow since 2026-09-11 (P6 item 4), at a harness change of zero.** The driver
still calls `sendTempMessage`, but that call now mints a routed item instead of fanning a sealed
`.tempMessage` envelope per capability-advertising slot, and `reportPayloads` still reads
`sessionMessages.messages`, which the routed projection fills. Two consequences for reading a lane
log. The driver now echoes `chat outcome=…`, so a message that reached nobody is visible instead of
inferred — and `.noDestinations` in the founding window is the expected answer for a message sent in
the first second or two of a pair, not a failure. And a chat failure is now a **routed** failure: the
same three refusals a lane photo can hit apply to text (a destination with no verified X25519 key, a
capped destination raising `routedDeliveryHold`), plus the recipient's own 13+ gate at the
projection. **The rows are recorded in "Lane C — P6 text on the routed store" below** (2026-09-12),
together with the two lane facts item 10 measured and every later run depends on: a flow fires
**once**, on the first poll with a committed slot, which is before the admission grant — hence
`FERNLET_MESH_FLOWS_AFTER` — and **no routed line reaches `--console-pty` at all**.
`FernletAuditLog.log` goes to `Logger(subsystem: "com.fernlet", category: "audit")` and to capture
handlers, never to `print`, and `MeshTransportConsoleLog.echo`'s `[mesh-quic]` mirror is wired at
exactly two sites in `MeshNetworkManager`. A per-sim
`xcrun simctl spawn <udid> log stream --predicate 'subsystem == "com.fernlet"'` is therefore the
evidence for every routed observation; a run without one proves nothing about the routed path.

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
| **In-session hearts** | **Reachable since 2026-09-12 (P6 item 10)** — see "Lane C — two sessions: the hearts ceremony". `FERNLET_MESH_ALLOW_HEARTS=1` flips the opt-in before `startJoin()` so `hearts` reaches the capability list, and `FERNLET_MESH_AUTO_KEEP_FRIENDS=1` writes the trust-vault row through the shipping keep doors at a real session end. Both are observed; the second session's heart is not yet | `sendSessionHeart(to:)` takes a `ProximityTrustedPeerRecord` and the receiver requires `ProximityTrustVault.isTrustedProximityPeer`; a fresh pair of Simulators has neither. Reaching it needs a *second* session — commit, end the session, complete the `pendingFriendReview` on both devices to write the vault rows, then reconnect — plus `allowNearbyHearts` on, which has no manager-level seam. The driver drives one session |
| **Moderation signal** | **Unreachable in this slice: same trust-vault precondition — and do not conflate it with the moderation VOTE** (P6 item 10): `proposeSignedRemoval(of:now:)` gates on a mesh, a ledger roster and target ≠ self, and needs no vault at all; only the *report* needs one | `sendModerationReports` gates on `isTrustedProximityPeer(signingPublicKey:)` for the recipient and on a non-empty `ownModerationReportsProvider`; the receiver re-checks vault trust before verifying a single row. Two devices that have never kept each other as friends exchange nothing, correctly. The `moderation` **capability** is advertised and was observed in every capability list above |
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

### Lane C — THREE nodes (runs 2026-09-02, P3 items 0 and 0b): **a star, then a full mesh**

P3's whole tier-2 story assumes three Simulators can carry a mesh. **Item 0 found that they did
not, and item 0b fixed it.** This section keeps both halves: what the star looked like, because the
evidence is what named the defect, and the fix with its 3/3 proof in "Fixed (0b)" below. Read the
star as history; the lane's current answer is the last two subsections.

As found (item 0, `c619d1f`): three Simulators discovered, introduced and held QUIC tunnels exactly
as the pair did — but the graph they formed was a **spanning star with N−1 edges, never the
N(N−1)/2 full mesh**. One node ended holding two tunnels; the other two held one each, to the hub,
and never to each other. Reproduced three times with the hub landing on a *different* node each
time, so it was not a property of any one Simulator, of launch order, or of the `sid` ranking.

#### How to run it

No harness change was needed — `FERNLET_MESH_MATRIX_MEMBERS` already accepts up to
`MeshMatrixDebugOptions.maxSeededMembers` = 8 base64 keys, so N nodes is the two-node procedure with
a longer member list. Sims: `iPhone 17` (A), `iPhone 17 Pro` (B), `iPhone 17 Pro Max` (C), all booted
and settled ~20 s before installing.

```
# 1. harvest — one launch per sim with no mesh id, read the identity line
SIMCTL_CHILD_FERNLET_MESH_TRANSPORT=quic SIMCTL_CHILD_FERNLET_MESH_MATRIX=1 \
xcrun simctl launch --console-pty <udid> MBO.Fernlet -completeOnboarding
#    → [mesh-matrix] identity fingerprint=<fp> signingKey=<base64>

# 2. the run — identical environment on all three, ~3 s apart, a FRESH log path per node
SIMCTL_CHILD_FERNLET_MESH_TRANSPORT=quic \
SIMCTL_CHILD_FERNLET_MESH_MATRIX=1 \
SIMCTL_CHILD_FERNLET_MESH_CONSOLE_LOG=1 \
SIMCTL_CHILD_FERNLET_MESH_MATRIX_LABEL=threeNode-<A|B|C> \
SIMCTL_CHILD_FERNLET_MESH_MATRIX_MESH_ID=33333333-3333-3333-3333-333333333333 \
SIMCTL_CHILD_FERNLET_MESH_MATRIX_MEMBERS=<keyA>,<keyB>,<keyC> \
SIMCTL_CHILD_FERNLET_MESH_FLOWS=commit \
xcrun simctl launch --console-pty <udid> MBO.Fernlet -completeOnboarding
```

`FERNLET_MESH_FLOWS=commit` is what makes the topology readable: `[mesh-flow] slots total=N
committed=N` is this node's own count of peers that finished the introduction *and* the proximity
gate. A tunnel is `[mesh-quic] accepted <peer-fp> sid=…: tunnel activated, tunnels=N` — and the
`for <name>` suffix on the following lines says which side dialed: a `fernlet-mesh-<hex>._…local.`
name is a browsed advertisement (**this** side dialed, outbound), a bare integer is a
`connection.id` (**inbound**, the peer dialed us).

#### What was observed

| Run | Launch order | Hub | Edges formed | Missing edge |
| --- | --- | --- | --- | --- |
| 1 | A, B, C | **A** (`tunnels=2`, stable ~7 min, beats both ways) | A↔B, A↔C | B↔C: C dialed B, C activated `tunnels=2`, then `tunnelEnded controlStreamEnded fb795f343c2954da live=true tunnels=1 … NWError 57 - Socket is not connected`. **B logged nothing at all** |
| 3 | C, B, A | **B** | B↔C | A↔B churned: A activated and lost the tunnel **four times**, each `outbound … NWError 57`, `slots total=0` throughout, `gave up` never reached. A↔C never attempted |
| 5 | A, B, C (instrumented build) | **B** (`slots total=2 committed=2`) | A↔B, B↔C | A↔C: **no dial, no refusal, no error on either side** — the edge is simply never attempted |

Two different failure shapes, and the second is the worse one:

* **Run 1 / run 3 — the dial lands and the far side silently drops it.** The dialer completes the
  signed introduction, activates its tunnel, and then its control stream dies `ENOTCONN`; the
  listening side never logs an `accepted`, never logs a `refused`, and never logs a `tunnelEnded`.
  This is `NetworkMeshSession.admitVerifiedInbound` returning nil — the owner's `invitationGate`
  failing closed, or `MeshLinkAdmission.refusedDuplicateTunnel` / `refusedCapacity`. **Both exits
  logged at `debug` and neither reached the console mirror**, which is why an edge that was refused
  and an edge nobody attempted read identically in a transcript. Fixed in this iteration:
  `noteInboundRefusal(_:key:)` mirrors both at `notice`, naming who refused
  (`inbound tunnel refused <owner|admission-case> for <key>`).
* **Run 5 — the third pair never meets.** With the instrumentation in place, the missing A↔C edge
  produced *no* refusal line on either node. A and C each discovered and dialed B and stopped; they
  did not discover, dial, or refuse each other. So the star is **not** wholly an accept-side refusal:
  at least sometimes the dial fan-out or the browse never proposes the third pair at all.

Not a capacity cap: `MeshLinkTable.maxConcurrentLinks` is 8, and run 1's hub held two tunnels
stably with heartbeats flowing both ways for the whole run.

#### The departure half

Run 1, hub A, ~t+4 min: `xcrun simctl terminate <C> MBO.Fernlet` (a hard kill — the harness has no
clean-leave verb, so no `member-departure.v1` was emitted; see the finding below).

* **A, the hub, saw it immediately and named it**: `[mesh-quic] tunnelEnded controlStreamEnded
  87684c8a76bb86c7 live=true tunnels=1 for 5: The inbound QUIC tunnel ended: … NWError 61 -
  Connection refused`, and `[mesh-flow] slots total=1 committed=1`.
* **B saw nothing** — and correctly so: B never had an edge to C, so there was nothing to lose. B's
  transcript across the departure is heartbeats to A and nothing else.

So the item-0 criterion "a departure by one node is seen by **both** survivors" **is not met**, and
it is not met for a membership reason: with a star, the only node that can observe a departure
first-hand is the hub. Everything else has to arrive by gossip, which is exactly plan §10.5's
propagation — untested here because the third node never had the departing peer.

#### The roster question, and why it is not answered yet

A three-node run today converges the **descriptor** roster (all three are seeded members, so
`legacyIntroductionRoster()` answers 3 on every node) but says nothing about the **derived** roster:
`MeshNetworkManager.roster` falls back to the gossiped descriptor whenever `membershipVerifier?.roster`
is empty, and the harness sets `currentMesh` directly, which is precisely the "a test that sets
`currentMesh` directly" case that fallback documents. A ledger is bootstrapped only by
`startNewMesh(name:)` (founder) or a verified admission grant (joiner), and **neither is reachable
from the harness**: `startNewMesh` mints its own random mesh id, so seeded peers would not match it,
and a joiner needs an admitter — but a stranger cannot ask, because an empty derived roster refuses
its tunnel before any app frame (the P2 "first-meeting stranger admission" row). Giving Lane C a
founder/joiner shape is therefore a **prerequisite** for loop item 9, not a detail of it.

> **Amended 2026-09-11 (P6 item 2).** The shipping app now founds a mesh **with a ledger** at the
> FIRST proximity commit: `onSlotConnected` → `promoteToMesh()` → `foundMesh(_:now:)` runs the same
> `prepareMembershipLedger` + `seedFounderAdmission` + ceiling + state-machine steps
> `startNewMesh(name:)` does, and the founding pair's one admission is auto-granted. So the
> paragraph above is now specific to a **seeded** run: a flows-only Lane C run started with **no**
> `FERNLET_MESH_MATRIX_MEMBERS` seed and no seeded descriptor would form a real mesh on its own, with
> a derived (records) roster, and could answer the derived-roster question without
> `armFounderLedgerForHarness()` at all. Nothing about a seeded run changes — the harness arms its
> ledger *before* `startJoin`, so `currentMesh != nil` and the founding is never entered (A28) — and
> nothing here has been observed on a radio yet: P6 tier-2 item 10 is the run that would.
>
> **Corrected 2026-09-12 (P6 item 10).** The middle sentence is wrong **on the QUIC radio**, which is
> the radio every Lane C run in this runbook uses. A run with no seeded descriptor has
> `currentMesh == nil`, so `MeshNetworkManager.roster` (`:14288`) falls back to
> `legacyIntroductionRoster()` (`:14298`) → `currentMesh?.members ?? []` → **empty**, and
> `MeshIntroductionRoster.verdict(for:)` (`MeshChannelIntroduction.swift:303`) answers `.stranger`
> for an empty member list. `NetworkMeshSession`'s channel introduction refuses a stranger at
> `MeshChannelIntroduction.swift:486–488` (`.unknownIdentity`) **before any app frame**, so no tunnel
> comes up, no slot commits, and nothing is founded. `maySeatVerifiedPeer` returning `true` for
> `currentMesh == nil` (`:1171`) is a later gate that is never reached. The claim holds only on the
> **MC** radio, where `attachIntroductionAuthority(_:)` is a documented no-op
> (`MeshTransportSelection.swift:173`) and there is no transport-level admission decision at all — so
> an unseeded app-path founding is reachable there and nowhere else on this lane. That is why P6 item
> 10's TEXT-4 shape is specified over MC, and why the app-path founding over QUIC stays **unobserved**
> and is handed to the owner list rather than claimed.
>
> **Corrected 2026-09-21 (D-4.3).** The circularity the section above describes — "a stranger
> cannot ask, because an empty derived roster refuses its tunnel before any app frame" — **no longer
> holds at HEAD**. The owner took D-4.3 Option 1: `MeshChannelIntroductionExchange.receive` admits a
> peer the roster calls `stranger` *provisionally* while the owner's join doors are open
> (`MeshIntroductionRoster.admitsStrangersProvisionally`, answered by
> `MeshNetworkManager.mayAdmitStrangerProvisionally` = `isAdmittingNewPeers && isSessionOpen`), and
> the roster verdict is read **before** the meshID equality check so a mesh-less joiner's
> `unboundMeshID` no longer reads as `.foreignMesh`. So an unseeded QUIC run now has a path to a
> first meeting and to a records ledger without `armFounderLedgerForHarness()` at all.
>
> **Nothing below is therefore a statement about a run.** That path has **never been observed on any
> radio** — not on this lane, not on any other. The unseeded Lane C row is the stranger-admission
> design's owed test (vi); it is still owed and still unrun, and the capability stays **unobserved**
> and on the owner list exactly as the 2026-09-12 correction left the MC half. What is pinned today
> is tier 1 only: the transport arm in `MeshChannelIntroductionTests`, the join-door predicate in
> `MeshIntroductionAuthorityRosterTests`, and the manager half in `MeshPairwiseFoundingTests`.
>
> **Observed 2026-09-22 (the deletion round's item 0).** The unseeded pair run was made and passed on its first launch: two Simulators with no seed found a mesh through the provisional path (`derived=2` on both, 1.6 s from browse), and the double-mint re-dial converged after a tunnel killed between the two commits. The paragraph above is now history; the run is "Lane C — the deletion round's item 0" below.


#### Fixed (0b) — the root cause was the owner's link gate, not the transport

Both failure shapes were one flag. `MeshNetworkManager.isSessionOpen` carries the mesh-wide "this
mesh admits new **members**" rule, and it was being read as the gate on opening a **link at all**, at
three sites:

| Site | What a false answer did | How it read in a transcript |
| --- | --- | --- |
| `handlePeerDiscovered` (proximity-join branch) | returned before the `sid` tie-break, so no dial | **shape (b)**: no dial, no refusal, no error, on either node |
| `shouldAcceptInvitation` — the QUIC radio's `invitationGate` | `admitVerifiedInbound` returns nil after the peer is verified | **shape (a)**: the dialer's control stream dies `NWError 57`; the far side logs nothing (item 0 added `noteInboundRefusal` for exactly this) |
| `channelAdmission` — the seat decision | `.kick` → `disconnectPeer` after the introduction succeeded | a `localEviction` / re-dial loop; the far side reads a truncated frame and reports `MeshTransportError error 2` (`invalidFrameLength`), which looks like a transport defect and is not |

`handleMeshDescriptor` re-derives `isSessionOpen` from the **gossiped** descriptor's mode. The Lane C
harness seeds `mode: .closed` deliberately (a closed mesh publishes no `meshID`, so every run's TXT
is byte-identical) — so `startJoin()`'s `isSessionOpen = true` let the *first* edge form, and then
the first committed peer's descriptor latched the flag false on every node. From that instant a node
neither dialed, accepted, nor seated anybody, **its own co-members included**. Whichever node had
both of its edges in flight before that merge kept two tunnels and became the hub — a race, hence a
different hub every run, and hence not launch order, not `sid` rank and not the 8-link cap. A pair
was never affected because its only edge predates any descriptor crossing it.

This is a product defect and not a harness artefact: a `.closed` mesh could never form or heal the
tunnels it is made of. The fix is one property — `mayLinkToDiscoveredPeers` = `isSessionOpen ||
currentMesh != nil` — at those three gates plus the two re-invite guards in `handlePeerDisconnected`.
Once a device holds a mesh, the **roster** decides who may connect, where the peer's identity is
actually known: the QUIC introduction is members-only, MC's slot coordinator refuses at its identity
introduction, joining still needs an admission the user grants, and `setSessionOpen(false)` still
evicts uncommitted slots. Regression: `Tests/FernletTests/MeshClosedMeshStarTopologyTests.swift`
(five tests; three of them fail on the pre-fix tree).

> **Corrected 2026-09-21 (D-4.3).** "The QUIC introduction is members-only" is no longer true, here
> or anywhere below in this section. Since Option 1 landed, a peer the roster calls `stranger` holds
> a QUIC *tunnel* provisionally while the owner's join doors are open — so the sentence now reads:
> the roster decides who becomes a **member**, and it refuses `barred` keys at the transport
> unconditionally. The 0b argument itself is unaffected and the fix stands: what made the three-gate
> relaxation safe was never the transport alone but the seat check
> (`MeshNetworkManager.maySeatVerifiedPeer(signingPublicKey:)`) the finding below added for MC — and
> that check is now THE stage a provisional peer is judged at on **both** radios.

Two diagnostics landed with it, both `notice` + console mirror, for the same reason item 0's
`noteInboundRefusal` did — discovery and the dial decision were the two stages with no transcript at
all:

* `[mesh-quic] browsed peers=<n> [<names>]` on every change of the browse set size. **This is what
  retired the discovery hypothesis:** every node browses all its peers, and always did. It also
  corrects a reading convention item 0 recorded — a browsed-name link key means only that *this side
  had browsed that peer*, not that it dialed, because `admitVerifiedInbound` remaps a verified
  inbound connection onto the browsed key. The useful half is the contrapositive: a **bare integer**
  key means this side had **not** browsed that peer.
* `[mesh-quic] dial refused <admission> for <key>` (was `debug`).

A bounded re-propose sweep rides the existing 1 Hz poll
(`NetworkMeshSession.reproposeIdleBrowsedPeers`, every `reproposeIntervalSeconds` = 5 s): discovery
announces a peer **once**, so an announcement the owner declines is otherwise never repeated, and the
pair is stranded for the life of the session. It re-offers only `idle`, untunnelled, browsed peers
whose advertised `sid` is not already on a live tunnel — so it cannot double-dial, cannot spend a
retry budget, and cannot fight the duplicate collapse.

#### What the security review of the 0b change changed (2026-09-02)

The fix above relaxes three **link** gates, and that is only safe where the transport itself is
members-only. It was on QUIC. **It is not on MC — which is the shipping default**
(`MeshTransportFactory.shippingDefault`): an MC invitation carries no identity, and the identity
introduction one layer up is gated on revoked/blocked keys, not on the roster. Four findings, all
fixed in the same change:

> **Corrected 2026-09-21 (D-4.3).** "It is on QUIC" was true when this was written and is not true
> at HEAD: since Option 1, neither radio is members-only at the transport while the owner's join
> doors are open. The four findings below are unchanged and none of them weakens — finding 1 in
> particular gets *stronger*, because the seat check it added is no longer a second lock behind a
> transport that had already refused the peer; on either radio it is the first stage that knows who
> the peer is and may refuse them.
>
> **Corrected again the same day (the flip).** "MC — which is the shipping default" is now false in
> its own terms: `MeshTransportFactory.shippingDefault` is `.quic`. MC is a DEBUG-only bisect path
> until the deletion round. The paragraph's *argument* is untouched, and is the reason this
> correction is an addendum rather than a rewrite — it is the record of why the three link gates
> were relaxed and what had to be added beside them, and both radios are now reachable builds.

1. **HIGH — a closed mesh must still refuse a verified stranger.** Without a second gate, a stranger
   seated on a closed MC mesh would be sent this device's signed identity introduction and then, on
   any `broadcastMeshDescriptor()`, a **plaintext** descriptor naming the mesh, every member's
   fingerprint, display name and both public keys — and `setSessionOpen(false)`'s eviction of
   uncommitted slots would be undone by the next discovery. Closed had become "no new *member*"
   instead of "stops admitting". Fixed by taking the membership decision where MC *does* know the
   identity: `MeshNetworkManager.maySeatVerifiedPeer(signingPublicKey:)`, asked in
   `checkCoordinatorStates` the moment a slot's coordinator verifies and **before**
   `onSlotConnected` sends the descriptor, the photo manifest or the vouch list. It asks the same
   `roster` the QUIC introduction asks — derived records first, gossiped descriptor as the
   documented fallback, `barred` honoured — and only on a **closed** mesh; an open mesh and a device
   with no mesh are unchanged. Admit-by-prompt still works, because `allowAdmission(_:)` appends the
   member to `currentMesh` before it grants. Second lock: `broadcastMeshDescriptor` /
   `sendMeshDescriptor` now refuse an **uncommitted** slot outright.
2. **MEDIUM — the re-propose sweep could sustain a connect/refuse/re-dial loop.** The owner refuses
   seats for reasons this radio cannot see (a locally-kicked peer — and that record is consumed by
   the disconnect that follows it — a removed member, a capacity race), each refusal ends the tunnel,
   and `noteClosed` returns the link to `idle` **with a full dial budget**. Fixed with a second,
   separately-counted budget that is deliberately **never refilled**:
   `MeshLinkTable.maxReproposalsPerEndpoint` = 6, spent through `admitRepropose(_:)`, evicted with
   the endpoint cache.
3. **LOW — the sweep could dial a peer whose inbound was mid-introduction.** `pendingInbound` is
   keyed by *connection id*, never by a browsed key, so the radio cannot tell which peer it is. The
   sweep now defers entirely while any introduction is in flight — bounded, because
   `expirePendingInbound` runs first in the same tick.
4. **LOW — a comment claimed the first sweep waited an interval.** It sweeps on the first poll tick;
   the comment now says so.

Tests: `theReproposeBudgetIsSpentAndNeverRefilled`, `theReproposeBudgetIsPerEndpointAndDiesWithIt`
(`NetworkMeshTransportTests`); `aClosedMeshRefusesToSeatAVerifiedStranger`,
`anOpenMeshAndANoMeshDeviceSeatAnybodyAsBefore`, `admittingByPromptMakesTheRequesterSeatable`,
`anUncommittedSlotIsNeverSentTheMeshDescriptor` (`MeshClosedMeshStarTopologyTests`).

One posture worth stating: a `currentMesh` with an **empty** member list and no ledger refuses
everybody, this device included. That is fail-closed and deliberate.

**Logging note — TAKEN 2026-09-21, in the MC→QUIC cutover, and COMPLETED the same day.**
`browsed peers=` used to print nearby Bonjour instance names at `.notice` with `privacy: .public`,
and that was acceptable only while the QUIC radio was DEBUG-only. The cutover made it the shipping
radio, so the owed downgrade landed with it (plan §8.7 finding 1): **`noteBrowseSet` now
interpolates the COUNT at `privacy: .public` and the NAMES at `privacy: .private`.** Hygiene, not a
leak fix — a mesh instance name is `MeshLinkAdvertisement`'s random per-session token, not a device
name — but a system-log line naming who else was in the room does not belong in a sysdiagnose.

**The first version of this note named the wrong residual, and the real one was worse.** It said
`accepted`/`datagramCapacity` were "still `.public` and still owed". Both halves were wrong.
`accepted` is not a logged line at all — it, and `redundantTunnelClosed` beside it, go only to
`MeshTransportConsoleLog.echo`, which is an empty function outside DEBUG, so neither ever reached
the system log. `datagramCapacity` did, and so did **nine** other lines, and what they carried was
not a capacity: it was `MeshLinkKey.rawValue`, the browsed Bonjour endpoint id, which contains the
peer's advertised instance name verbatim — the exact value the `browsed peers=` downgrade had just
been made to keep out. Worse, `tunnelEnded` interpolated `tunnel.verified?.fingerprint` — the peer's
**stable** 16-character identity fingerprint, the value the ledger, the roster and the moderation
record are keyed on — at `privacy: .public` on every teardown.

**What was done.** `NetworkMeshSession` gained the two sibling radios' salted, session-scoped
`peerLabel(for:)`: 12 hexadecimal characters of SHA-256 over a 256-bit salt drawn once at
construction, never persisted, never advertised, gone with the session, so a reader who holds the
peer's public name still cannot re-link two excerpts. Every peer-scoped diagnostic now goes through
`peerLines(_:key:detail:)`, which returns the line twice — `logged`, naming the peer by its label,
for `os.Logger`; `echoed`, naming it by the raw endpoint id, for the DEBUG console mirror.
`tunnelEnded`'s fingerprint moved to `privacy: .private` and keeps its place on the line; the DEBUG
echo keeps it in clear. `NetworkMeshSessionTests.noPublicDiagnosticOnTheShippingRadioCarriesAPeerDerivedValue`
is the wall: it reads the file, extracts every `privacy: .public` interpolation, and fails on a
peer-derived token — and, because that scan alone would not see `let line = "… \(key.rawValue)"`
logged as `\(line, privacy: .public)`, it also refuses a raw endpoint id in any string literal
outside the two builders.

**What is still `.public`, and why none of it is peer-derived.** On the mesh radio: `keys.count`
(the browse-set size), `attempt` (the dial-retry number), `error.localizedDescription` twice (the
framework's listener/browser wait text), `reason` (a dial-failure reason), `message` (`report`'s
frozen diagnostic English), and `lines.logged` / `logged`, which carry the label. The two sibling
radios were already on this footing and were re-checked in the same pass: their only public
interpolations are `self.peerLabel(for:)`, `error.localizedDescription`, `message` and a teardown
`reason`.

**The lane transcripts are unaffected, byte for byte.** The DEBUG `MeshTransportConsoleLog.echo`
beside each of these lines still carries the raw endpoint id, and every echoed string is character
for character what it was before this change — `dial refused`, `datagramCapacity`, `tunnelEnded`,
`transfer`, `heartbeat`, `inbound tunnel refused` and `browsed peers=` all included. Every
`--console-pty` recipe in this runbook greps those, and none of them needs re-running. What did
change shape is the *system log*: a `xctrace`/Console reader now sees a 12-character label where it
saw `fernlet-mesh-…`, which is stable within a session and therefore still tells two peers apart.

#### The 3/3 proof (runs 2026-09-02, item 0b)

Procedure exactly as above, with one change: launch the three sims **~1 s apart, not 3 s**. The
harness's founder arms its ledger on its first committed slot, which collapses the seeded descriptor
to the founder alone — a third node whose tunnel is not already up by then is a stranger and is
refused. Scripted as `STAGGER=1` in the scratch `threerun.sh`.

*Topology, no roles* — `topo3`, `topo4`, `topo5`, every node in every run:

```
[mesh-quic] browsed peers=2 [fernlet-mesh-…,fernlet-mesh-…]
[mesh-flow] slots total=2 committed=2 states=[connected,connected]
```

No `tunnelEnded`, no `dial refused`, no `inbound tunnel refused`, no churn. **3/3 full mesh**, where
item 0 was 3/3 star.

*Membership, `FERNLET_MESH_ROLE=founder` on A and `joiner` on B and C* — `mem1`, `mem2`, both runs:

| Node | Evidence |
| --- | --- |
| A (founder, `d996bc564a17da2d`) | `founder armed=true … derived=1` → `admitting fb795f343c2954da` → `admitting 87684c8a76bb86c7` → `membershipFrame sent fernlet.mesh.member-admission.v1 slots=2 recipients=2` → `membership ledger=present derived=3 barred=0 status=active` |
| B (joiner, `fb795f343c2954da`) | `requesting admission asked=true` → two `membershipRecord fernlet.mesh.member-admission.v1 accepted` → `derived=3` |
| C (joiner, `87684c8a76bb86c7`) | same, `derived=3` |
| all three | `epochRef=1.f62a1fdb65021c9d93c2ed7e7d177e1d.87684c8a76bb86c7` — **one head, agreed by all three, coordinated by C**, the lowest fingerprint and *not* the founder. B cannot derive that head without the key it wraps, so the key crossed two tunnels |

*Departure*, C with `FERNLET_MESH_LEAVE_AFTER=55`:

```
C: leaving via leaveSessionAfterNotifyingPeers … derived=3
C: [mesh-quic] membershipFrame sent fernlet.mesh.member-departure.v1 slots=2 recipients=all
A: [mesh-quic] membershipRecord fernlet.mesh.member-departure.v1 accepted
A: membership … derived=2 barred=1 … epochRef=2.f79caa1f8ffb97cee9801c694da0cce9.d996bc564a17da2d
B: [mesh-quic] membershipRecord fernlet.mesh.member-departure.v1 accepted
B: membership … derived=2 barred=1 … epochRef=2.f79caa1f8ffb97cee9801c694da0cce9.d996bc564a17da2d
```

**Both survivors accepted it, and each got it DIRECTLY from C** (`recipients=all` over C's two live
tunnels), not by A's digest re-gossip — so item 0's criterion is met, and plan §10.5's re-gossip
path remains uncorroborated on a radio. Both survivors then rotated to epoch 2, coordinated by A,
which is now the lowest surviving fingerprint. The departure landed in **2 of 2** runs here; §8.7
finding 2's unacknowledged-write race is unfixed and can still eat it, and this lane does not claim
otherwise.

One line worth not misreading: A's transcript carries
`tunnelEnded controlStreamEnded 87684c8a76bb86c7 … MeshTransportError error 2` at C's departure. That
is `invalidFrameLength` from reading a connection C tore down mid-frame on its way out — the
teardown, not a framing defect.

#### What this lane can and cannot carry, for planning

| Ask | Verdict |
| --- | --- |
| Three nodes discover, introduce, and hold QUIC tunnels | **Yes** — every pairwise property of the two-node lane reproduces |
| Any *one* node observes two peers at once | **Yes** — the hub reaches `slots total=2 committed=2`, heartbeats both ways |
| A full three-node mesh (every node sees the other two) | **Yes, since 0b** — 3/3 runs, every node `slots total=2 committed=2`. It read **No** (a spanning star, N−1 edges, 3/3) before the fix |
| A departure reaching **both** survivors | **Yes, since 0b** — C left through `leaveSessionAfterNotifyingPeers()` and both A and B accepted `member-departure.v1`. Delivered **directly** over C's two tunnels (`recipients=all`), so plan §10.5's *re-gossip* path is still uncorroborated |
| The derived (records) roster converging over a radio | **Yes** — on a PAIR since 2026-09-02 (see "Lane C — pair membership" below) and on **three nodes** since 0b: `membership … ledger=present derived=3` on all three |

### Lane C — pair membership (run 2026-09-02, P3 item 9): **the derived roster, over a real tunnel**

Item 0 left the tier-2 story with a hole: three Simulators form a star, and the two-node lane could
only ever converge the **descriptor** roster, because the P3 records ledger was unreachable from the
harness. This section closes the second half. Four scenarios were driven over two Simulators, and
three of the four are proven; the fourth is proven intermittently and the intermittency is a
**product finding**, recorded below rather than tuned away.

Nodes: `iPhone 17` = **A**, `d996bc564a17da2d` (founder) · `iPhone 17 Pro` = **B**,
`fb795f343c2954da` (joiner). A is the lower fingerprint, so A is also the deterministic epoch
coordinator; the roles happened to coincide and the assertions below name whichever node minted.

#### Why the harness needed two new seams first

**The QUIC transport is members-only by construction.** `MeshChannelIntroductionExchange.receive`
refuses a foreign mesh id and refuses a signing key the roster does not name, so a founder holding a
one-member derived roster refuses a would-be joiner's tunnel *before any app frame* — and the joiner
has no other way to ask. `startNewMesh(name:)` mints a random mesh id, which seeded peers cannot
match. That circularity is why item 0 could not reach the derived roster, and it is a real property
of the shipping transport, not of the harness: **first-meeting stranger admission has no path on
this radio.**

> **Corrected 2026-09-21 (D-4.3).** The last sentence is the one the owner's decision retired.
> First-meeting stranger admission **has** a path on this radio as of Option 1: a `stranger` is
> admitted provisionally while the join doors are open, and the roster verdict is read before the
> meshID check so a mesh-less joiner's `unboundMeshID` is no longer `.foreignMesh`. The two seams
> below are therefore no longer *necessary* to open a first tunnel — they are a **convenience**,
> and they are why the run recorded in this section is reproducible: a seeded pair has
> byte-identical TXT records and a mesh id known before launch, which is what makes two runs
> comparable.
>
> **The unseeded row is owed, not done.** Nobody has run two Simulators with no
> `FERNLET_MESH_MATRIX_MEMBERS` seed over QUIC and watched them found a mesh through the
> provisional path. That is the stranger-admission design's owed test (vi); the capability has
> **never been observed on any radio**, and this section's results remain results about the
> **seeded** shape. Everything measured below stands exactly as recorded.
>
> **Done 2026-09-22.** The unseeded row was run and passed — "Lane C — the deletion round's item 0" below. The seams in the table stay what the sentence above says they are: a convenience that makes a seeded run reproducible, and on an unseeded run the founder role is inert (`armed=false`).

The seams below are the smallest thing that opens it, and each one stands in for exactly one step:

| Seam | Where | What it stands in for | What stays shipping code |
| --- | --- | --- | --- |
| `FERNLET_MESH_ROLE=founder\|joiner` | `MeshMatrixDebugOptions` / `MeshFlowDriver` | which membership shape the node plays | everything below |
| `MeshNetworkManager.armFounderLedgerForHarness()` | DEBUG extension, `MeshNetworkManager.swift` | `startNewMesh`'s **id mint** and its `startSearching()` restart (which would re-mint the Bonjour name and drop the tunnel) | `prepareMembershipLedger` + `seedFounderAdmission` + `persistSessionContext` — the shipping founding, on the id the seeded descriptor already names. It also collapses the seeded two-member descriptor to what `startNewMesh` would have produced: the founder alone |
| `MeshNetworkManager.requestAdmissionForHarness()` | same | the *trigger* only — a joiner whose seeded descriptor already lists it never gets the `handleMeshDescriptor` trigger | `sendAdmissionRequest(for:)`, the shipping emitter, and the whole grant path after it |
| `FERNLET_MESH_LEAVE_AFTER=<seconds>` | `MeshFlowDriver` | a user tapping Leave | `leaveSessionAfterNotifyingPeers()` verbatim |
| `FERNLET_MESH_FLOWS_AFTER=<polls>` *(P6 item 10)* | `MeshMatrixDebugOptions` / `MeshFlowDriver` | **nothing at all** — it only delays when the existing flows fire, so a run can observe a routed delivery instead of the founding window | every flow, unchanged |
| `FERNLET_MESH_ALLOW_HEARTS=1` *(P6 item 10)* | same | the user turning the nearby-hearts opt-in on, before the session | `FernletStore.setAllowNearbyHearts(_:)`, and `localCapabilities()`'s own decision to advertise `hearts` |
| `FERNLET_MESH_AUTO_KEEP_FRIENDS=1` + `MeshFlowVerb.heart` *(P6 item 10)* | same | **one tap each** — `ConnectView.finalizeFriendKeeps()`'s keep, and the camera sheet's heart button | `keepProximityFriends(from:keptFingerprints:)`, `completeFriendReview(_:)`, `canSendSessionHeart(toFingerprint:)` and `sendSessionHeart(to:)` — every gate, the mint, the ceremony and the receipt |
| `FERNLET_MESH_REMOVE_AFTER=<seconds>` + `seedRemovalRecordForHarness` | same | **plan §10.4's quorum arithmetic, and nothing else** | the record is really signed under `meshMemberRemovalV1`; `MeshDerivedRoster` really derives `barred` from it; the introduction really refuses on it |
| `[mesh-quic] membershipFrame sent …` / `membershipRecord … accepted\|<refusal>` | `MeshNetworkManager` (`MeshTransportConsoleLog`, DEBUG-only echo) | nothing — pure instrumentation | — |

The last row is the same lesson item 0 learned about inbound refusals: **without it, "the frame
never arrived" and "the frame arrived and was refused" read identically**, and run 1 below was
un-diagnosable until it existed.

Everything is `#if DEBUG` and env-gated in the family `TestHookBoundaryTests` walls; a Release build
compiles the environment reads, the seams and the echoes to nothing.

#### How to run it

```
# 1. harvest — one launch per sim with no mesh id (as in the three-node section)
# 2. the pair, launched ~3 s apart, a FRESH log path per node
SIMCTL_CHILD_FERNLET_MESH_TRANSPORT=quic \
SIMCTL_CHILD_FERNLET_MESH_MATRIX=1 \
SIMCTL_CHILD_FERNLET_MESH_CONSOLE_LOG=1 \
SIMCTL_CHILD_FERNLET_MESH_MATRIX_LABEL=<run>-<A|B> \
SIMCTL_CHILD_FERNLET_MESH_MATRIX_MESH_ID=44444444-4444-4444-4444-444444444444 \
SIMCTL_CHILD_FERNLET_MESH_MATRIX_MEMBERS=<keyA>,<keyB> \
SIMCTL_CHILD_FERNLET_MESH_FLOWS=commit \
SIMCTL_CHILD_FERNLET_MESH_ROLE=founder            # joiner on the other sim
# joiner only, for the departure row:  SIMCTL_CHILD_FERNLET_MESH_LEAVE_AFTER=55
# founder only, for the removal row:   SIMCTL_CHILD_FERNLET_MESH_REMOVE_AFTER=40
xcrun simctl launch --console-pty <udid> MBO.Fernlet -completeOnboarding
```

`FERNLET_MESH_MATRIX_MEMBERS` carries **both** keys on **both** nodes — that seeded descriptor is
the only thing that can open the first tunnel. `[mesh-flow] membership …` is the new audit line:
the **derived** roster's size, its barred count, its status and the epoch head, echoed whenever any
of them moves. `ledger=absent` is the honest answer for a node still answering introductions from
the gossiped descriptor, which is what every Lane C run before this one was doing.

#### What was observed

| # | Scenario | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | **Admission across a live roster** | **Proven** (runs 1, 2, 3) | A: `founder armed=true ledger=present derived=1 …` → `admitting fb795f343c2954da` → `membership ledger=present derived=2 barred=0 status=active`. B: `requesting admission asked=true` → `membershipRecord fernlet.mesh.member-admission.v1 accepted` → `membership ledger=present derived=2`. Both nodes' rosters are **derived**, not descriptor: `ledger=present` is the flag |
| 2 | **Rotation crossing a tunnel** | **Proven** (runs 1, 2, 3) | Both nodes converge on the *same* head within one poll of the admission — run 2: `epochRef=1.ba90f6b015431d40e21496274e6e348f.d996bc564a17da2d` on A **and** on B; run 3: `1.c7ab028f2fb754ee6b136d685ecf9971.d996bc564a17da2d` on both. A (the lower fingerprint) is the coordinator named inside the ref, so A minted and B adopted — the key crossed the real QUIC tunnel, since B's head cannot be derived without the key it wraps |
| 3 | **Clean departure → `member-departure.v1`** | **Proven, but INTERMITTENT — see the finding** | Run 2, B: `leaving via leaveSessionAfterNotifyingPeers …` → `[mesh-quic] membershipFrame sent fernlet.mesh.member-departure.v1 slots=1 recipients=all`. A: `[mesh-quic] membershipRecord fernlet.mesh.member-departure.v1 accepted` → `membership ledger=present derived=1 barred=1 status=active` → `epochRef=2.f60d0277d6c2fe0cb69287ccaf4b5233.d996bc564a17da2d` — the roster moved 2→1, B moved into `barred`, and the `.membership` rotation to epoch 2 happened with B necessarily excluded (it is barred and disconnected). **Run 1 lost it**: same steps, and A's roster never left `derived=2` |
| 4 | **Removal ejecting a peer at its next connect** | **Proven** (run 3) | A at t+40 s: `removal filed=true target=fb795f343c2954da ledger=present derived=1 barred=1`. B relaunched at t+73 s: A logs, three times, `[mesh-quic] refused barredMember as responder: mesh=55555555-… epoch="1.c7ab…" rosterMembers=1 rosterBarred=1` and `A QUIC tunnel was refused: The peer has departed, been removed, or been blocked.` B logs `tunnelEnded introductionFailed unverified live=false … The outbound QUIC tunnel failed its signed channel introduction.` The run's own banner reads `chaosBarred=none`: **this is the shipping derived roster's answer, with `FERNLET_MESH_CHAOS_BARRED` unset** — matrix row 3 no longer needs the chaos hook on a pair |

#### Finding — a clean departure can be lost in the teardown that follows it

`leaveSessionAfterNotifyingPeers()` awaits `sendMembershipEvent(.meshMemberDeparture)` and then
calls `leaveSession()`, which stops the transport immediately. The `await` returns when the frame
has been handed to the transport, **not** when the peer has it, so the survivor sees the departure
only if the QUIC write flushes before the connection is cancelled. On this lane it usually does and
sometimes does not:

* **Run 2 and run 4 — landed.** B logs `membershipFrame sent …member-departure.v1`, A logs
  `membershipRecord …member-departure.v1 accepted`, roster 2→1, rotation to epoch 2.
* **Run 1 — lost.** A's last membership line is `derived=2`; no roster move, no rotation. A's tunnel
  ended `controlStreamEnded … MeshTransportError error 2` at that moment, against run 2's
  `NWError 57 - Socket is not connected` — a *local* transport error rather than the peer's close,
  which is consistent with the write never leaving. (Run 1 predates the `membershipFrame` /
  `membershipRecord` echoes, so it can only be read off the roster; the echoes exist because of it.)

This is the same class of gap as the P2 heartbeat/idle-timeout race: the ordering is correct in the
code and the *durability* rule (plan §3.6) is honoured — the record is sealed before the frame goes
out — but nothing waits for, or retries, delivery. A departed member is not silently still a member
forever: it is barred by the *next* record any survivor accepts, and a rejoin attempt is refused
because it holds no admission. But the immediate consequences of a departure — the roster shrinking
and the `.membership` rotation that re-keys without the departed device — do not happen at all on
the run where the frame is lost. **Not fixed here** (a delivery ack or a bounded re-send is a
transport change, not a harness one); recorded for P4/P5, where the merge path is the natural place
for a survivor to learn a departure it missed.

#### Two smaller observations

* **A removal does not cut the live tunnel; it refuses the next one.** In run 3 the removal was
  filed at t+40 s and A's tunnel to B stayed up, with the slot committed, until B was terminated at
  t+63 s. That is the design (plan §8.3 excludes the removed member from the *next* epoch's key, and
  `MeshIntroductionAuthority` answers per introduction), and the transcript is now the evidence for
  it rather than an inference.
* **`seedRemovalRecordForHarness` does not request a rotation**, because it re-seeds the ledger
  rather than travelling `insertMembershipRecord` — so run 3 shows the roster moving 2→1 with the
  epoch head unchanged at 1. Rotation-on-removal is a tier-1 property (`MeshRotationTriggerTests`);
  what this lane owes is rotation-on-*departure*, which row 3 above does show.

#### What this lane deliberately does NOT prove

| Ask | Why not |
| --- | --- |
| A departure gossiped by a **third** member (plan §10.5) | Two nodes. **0b is fixed**, and the three-node run above shows a departure reaching both survivors — but *directly*, `recipients=all`. Re-gossip needs a run where the leaver has no tunnel to one survivor |
| A removal minted by a **real quorum** | ⌊2/2⌋ + 1 = 2 votes with the target excluded leaves 1 eligible voter, so `MeshMembershipRecordVerifier` refuses every honest two-node removal `quorumNotMet(required: 2, presented: 1)`. Needs ≥ 3 nodes — **now reachable** since 0b, not yet run |
| A rotation crossing **two** tunnels | One tunnel exists here. **Proven on three nodes** since 0b: one `epochRef` agreed by all three, minted by the non-founder lowest fingerprint |
| `MeshLedgerAdoption.adopt`'s **rebase** onto a founder that is not the admitter | On a pair the admitter *is* the founder, so the joiner's bootstrap root is already right and the rebase is a no-op. Needs a third node admitted by the second — the harness's founder admits everyone, so a driver change is owed |
| First-meeting **stranger** admission | Unreachable on this transport by construction (above). Not a P3 item; recorded here because the harness seams exist only to route around it |

### Lane C — P6 text on the routed store (runs 2026-09-12, P6 item 10a)

Three Simulators, QUIC, one seeded mesh, founder + two joiners. `iPhone 17 Pro` = **A**
(`fb795f343c2954da`, founder) · `iPhone 17 Pro Max` = **B** (`87684c8a76bb86c7`) · `iPhone 17e` = **C**
(`45975569e20dfb12`). Logs are per-run under a fresh directory, and **every routed observation below
comes from a per-sim `xcrun simctl spawn <udid> log stream --predicate 'subsystem == "com.fernlet"'`** —
no routed manifest, chunk, receipt or projection line reaches `--console-pty` at all.

| # | Scenario | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | A message sent in the **founding window** | **Refused, by name — and it is the only thing today's driver can produce** | `[mesh-flow] chat outcome=noDestinations` on every node, at the same poll as `[mesh-flow] founder armed=true ledger=present derived=1`, with `membership ledger=present derived=2 barred=0 status=active` later in the same transcript. The founder collapses the seeded descriptor to itself at its first committed slot, which is the first tick a flow can fire |
| 2 | Text **originated** as a routed item, after the grant | **PASS** | `FERNLET_MESH_FLOWS_AFTER=25`; `[mesh-flow] chat outcome=staged` + `mesh.routedShare.pushed` |
| 3 | Text **custodied and completed** at the receiver | **PASS** | `mesh.routedDrain.admitted type=fernlet.mesh.routed-manifest.v1 verdict=admitted` ×4 then `…routed-chunk.v1 verdict=admitted` ×6 |
| 4 | Text **projected** into the live transcript | **PASS** | `[mesh-flow] chat received=1 sent=1` at both converged members, with no `mesh.routedProjection.*` line for their own pair |
| 5 | The **recipient receipt** returned | **PASS** | `mesh.routedDrain.admitted type=fernlet.mesh.recipient-receipt.v1 verdict=admitted` ×4, plus `…custody-receipt.v1` ×4 |
| 6 | The legacy `.tempMessage` transport is **gone** | **PASS — the retirement, observed** | `grep -c 'fernlet.message.temp.v1'` over every audit and flow transcript of the run == **0**; no `mesh.tempMessage.refused` |
| 7 | No mint refusal on a converged mesh | **PASS** | no `mesh.routedShare.destinationNotAddressable`, no `mesh.routedShare.keyMismatch` |
| 8 | An **unresolvable origin** is refused at the projection | **PASS, unplanned** | a node that minted from the seeded descriptor but never joined had its frames admitted and then refused with `mesh.routedProjection.originUnresolvable` ×4 at both members — the author is not on the roster they derived. Fail-closed, and the reason "zero `mesh.routedProjection.*`" holds only for a fully converged roster |
| 9 | The 13+ gate, all three legs | **NOT RUN** | Out of the timebox: the three-node shape it needs converged in 2 of 4 attempts — see the founder-collapse race below |

**Three facts this lane measured that every later Lane C run depends on.**

1. **A flow fires ONCE, at the first poll with a committed slot, which is before the grant.** Hence
   `FERNLET_MESH_FLOWS_AFTER=<polls>`; absent, it is 0, which is exactly the old behaviour.
2. **The 1 Hz poll runs at roughly 0.3 Hz on a headless Simulator.** `FLOWS_AFTER=25` took ≈ 90 s and
   `LEAVE_AFTER=40` ≈ 140 s of wall clock. Budget ≈ 3.5 × the tick number or the run is terminated
   before its own schedule fires — two runs were voided by this before it was measured.
3. **Every node must seed the SAME descriptor `createdAt`.** The session hard deadline is
   `descriptor.createdAt + MeshSessionCeiling.ceilingSeconds`, every routed manifest and chunk carries
   `MeshRoutedManifest.expiry(afterHardDeadline:)`, and the receiver refuses anything that is not its
   own deadline plus grace. With a per-device `Date()` the deadlines differed by the launch stagger and
   **two thirds of every routed frame was refused `mesh.routedDrain.rejected reason=expiryMismatch`**
   (8 manifests, 12 chunks) — each node agreeing with exactly one peer. `MeshMatrixDebugOptions
   .seededCreatedAt` floors the instant to a shared 600 s grid and the banner echoes it; after the fix
   the same run has **zero** `expiryMismatch`. It is an artefact of seeding, not a product defect: on
   the app path the founder mints one descriptor and gossips it.

**Two things that did not cross, by name.**

* **`simctl launch --console-pty` intermittently attaches no stdout** — the launch returns its pid
  line and nothing else, while the app runs. A node with no `[mesh-matrix] run label=` banner proves
  nothing about that node; the launcher now checks for the banner after the stagger and relaunches
  once.
* **The founder-collapse race on the third node.** In 2 of 4 three-node attempts the third node
  logged `[mesh-quic] tunnelEnded introductionFailed unverified live=false … The outbound QUIC tunnel
  failed its signed channel introduction` three times, then `The QUIC tunnel gave up after 3 attempts`
  and `dial refused refusedRetryBudgetSpent`, and never joined. Hypothesis: the founder had already
  collapsed the seeded descriptor to itself, so its derived roster of one verdicts the late third node
  `.stranger`. **What would settle it:** a `FERNLET_MESH_ARM_AFTER=<polls>` hook holding
  `armFounderLedgerForHarness` until every tunnel is up, then a re-run. A tier-1 cell cannot: it is a
  race between a real dial and a real roster change.

### Lane C — two sessions: the hearts ceremony (runs 2026-09-12, P6 item 10b)

Two Simulators, A (founder) and B (joiner), `FERNLET_MESH_ALLOW_HEARTS=1` and
`FERNLET_MESH_AUTO_KEEP_FRIENDS=1` on both.

| # | Scenario | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | The hearts opt-in reaches the **handshake** | **PASS** | `[mesh-flow] hearts on=true` before `startJoin()`, then `[mesh-flow] capabilities peer=[activities,hearts,moderation,photos,shop,wire2]` — and `messages` correctly ABSENT, because this run asks for no chat flow and `chatAllowedProvider` is fail-closed |
| 2 | A two-member session ends with **`terminated.v1`**, not a departure | **PASS** | `[mesh-flow] leaving via leaveSessionAfterNotifyingPeers ledger=present derived=2` → `[mesh-quic] membershipFrame sent fernlet.mesh.terminated.v1 slots=1 recipients=all` → `[mesh-flow] left ledger=absent derived=0` |
| 3 | The mesh id is **barred** afterwards | **PASS** | `mesh.sessionState.rejoinBarred` on the departer; session 2 therefore uses a different id |
| 4 | The **keep** writes a trust-vault row through the shipping doors | **PASS on the departer** | `[mesh-flow] friends kept=1 vault=1`, then `[mesh-flow] vault friends=1 heartsReceived=0 ledgerLoaded=true heartState=idle`. The hook calls `keepProximityFriends(from:keptFingerprints:)` + `completeFriendReview(_:)` from the poll **and again after `leave()` returns**, because the departer's poll ends inside `leave` |
| 5 | Item 6's P1-1 re-assert, on the radio | **PASS, unplanned** | `mesh.sessionState.reassertedAdoptedCommit` in the joiner's audit — the raise a yielding/late-committing joiner needs, which no earlier lane run could show |
| 6 | The keep on **both** sides | **PASS (second pass, 2026-09-12)** | `[mesh-flow] friends kept=1 vault=1` on the founder **and** the joiner, each followed by `[mesh-flow] vault friends=1 heartsReceived=0 ledgerLoaded=true heartState=idle` |
| 7 | Session 2: one routed heart, the ceremony, the receipt | **PASS (second pass, 2026-09-12)** | the whole row set below |

#### Second pass (runs 2026-09-12, P6 item 10b): the mutual keep, then the heart

The first pass reached session 1 and stopped, because the survivor's friend-review batch promotes
only when *its own* session ends and its next poll — at the ≈ 0.3 Hz a headless Simulator really
runs — came after the run's teardown. Two sims only (`iPhone 17 Pro` = **A**, founder;
`iPhone 17 Pro Max` = **B**, joiner), the run length budgeted at `3.5 × leaveAfter + 60` s, and
**both sides ending locally** — the plan's own fallback — so neither keep depends on the departure
race.

Session 1 environment (both nodes, plus the two `LEAVE_AFTER`s):

```
SIMCTL_CHILD_FERNLET_MESH_TRANSPORT=quic  SIMCTL_CHILD_FERNLET_MESH_MATRIX=1
SIMCTL_CHILD_FERNLET_MESH_CONSOLE_LOG=1
SIMCTL_CHILD_FERNLET_MESH_MATRIX_MESH_ID=77777777-7777-7777-7777-777777777781
SIMCTL_CHILD_FERNLET_MESH_MATRIX_MEMBERS=<KA>,<KB>
SIMCTL_CHILD_FERNLET_MESH_ROLE=founder|joiner
SIMCTL_CHILD_FERNLET_MESH_FLOWS=commit,capabilities
SIMCTL_CHILD_FERNLET_MESH_ALLOW_HEARTS=1  SIMCTL_CHILD_FERNLET_MESH_AUTO_KEEP_FRIENDS=1
SIMCTL_CHILD_FERNLET_MESH_LEAVE_AFTER=70 (A) / 40 (B)          run length 340 s
```

Session 2 is the same with a **different mesh id** (`…782` — `terminated.v1` bars the first one
permanently), `FERNLET_MESH_FLOWS_AFTER=25`, **no** `AUTO_KEEP_FRIENDS`, and the `heart` verb on the
FOUNDER only, so exactly one heart is minted and the JOINER receives it; run length 320 s.

| # | Scenario | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | Both sides end locally and both keep | **PASS** | `leaving via leaveSessionAfterNotifyingPeers ledger=present derived=2` → `[mesh-quic] membershipFrame sent fernlet.mesh.terminated.v1 slots=… recipients=all` → `left ledger=absent derived=0` → **`friends kept=1 vault=1`**, on **both** nodes |
| 2 | The vault row **survives the relaunch** | **PASS** | session 2's first report on both nodes is `[mesh-flow] vault friends=1 heartsReceived=0 ledgerLoaded=true heartState=idle`, before any heart exists |
| 3 | The sender's five gates | **PASS** | `[mesh-flow] sending heart to=87684c8a76bb86c7 canSendSessionHeart=true` |
| 4 | The **mint** | **PASS** | `mesh.routedShare.pushed frames=2` on the sender — one manifest and one chunk to the single destination the `.singleRecipient` row names |
| 5 | **Consume-on-stage** | **PASS** | `[mesh-flow] … heartState=sent(recipientName: "iPhone 17 Pro Max")` on the sender, at the same poll |
| 6 | Custody, then completion at the recipient | **PASS** | `mesh.routedDrain.admitted type=fernlet.mesh.routed-manifest.v1 verdict=admitted` then `…routed-chunk.v1 verdict=admitted` |
| 7 | **The ceremony ran** | **PASS** | **`[mesh-flow] vault friends=1 heartsReceived=1 ledgerLoaded=true`** — `ProximityHeartLedger.recordReceivedHeart` landed and was read back off `receivedHearts` |
| 8 | The ceremony replaced the fail-closed no-op | **PASS** | **zero** `mesh.routedProjection.noDispatchArm` anywhere in the run |
| 9 | `mayCommitRoutedHeartLedgerJudgement` was true | **PASS** | **zero** `mesh.routedAccess.heartStageDeferred`. Note what this does and does not say: a `simctl launch`ed app satisfies the gate's two real legs trivially and the `sessionState` leg is inert until P8 — **the foreground gate was not tested** |
| 10 | The **recipient receipt on the wire** | **PASS** | `mesh.routedDrain.admitted type=fernlet.mesh.recipient-receipt.v1 verdict=admitted` on the sender (plus `…custody-receipt.v1`), and **no** `mesh.routedDrain.deliveryPending` — the delivery is not merely staged |
| 11 | The retired mesh `.friendHeart` path is silent | **PASS** | zero `fernlet.friend.heart.v1`, zero `mesh.friendHeart*`, zero `mesh.routedShare.recipientIsSelf`, zero `keyMismatch`, zero `destinationNotAddressable` |
| 12 | **Item 6's P1-1, as a product proof** | **PASS** | the recipient is the JOINER, and `mesh.sessionState.reassertedAdoptedCommit` is in **its** audit stream for this run. That is the device whose `.peerCommitted` was dropped by `noteCommitIntoMesh`'s `currentMesh != nil` guard; before item 6's fix it would have sat at `joining`, the heart stage would have judged nothing, and this heart would have expired custodied while its sender showed "Sent" and spent five minutes of cooldown |

One line worth not misreading: the recipient's stream also carries two
`mesh.routedProjection.originUnresolvable` lines. They are **not** the heart — `.heartLedger` is
deliberately absent from `projectableRoutedTypeTokens`, so a heart never reaches the projection arm
at all; it is judged inside `commitLocalDelivery`. They are leftover text items custodied by an
earlier run whose origins this run's roster does not name, which is the same fail-closed refusal row
8 of the text set records.

### Lane C — a removal by real quorum (P6 item 10b)

**NOT RUN.** The three DEBUG seams plan §4.2 specifies (`proposeSignedRemovalForHarness`,
`voteOnFirstOpenSignedRemovalForHarness`, `harnessRemovalSummary`) were not built inside the timebox,
and the run needs the three-node shape whose founder-collapse race is recorded above. Plan §4.2 is the
ready-made spec; note in passing that the moderation **vote** never needed the trust vault
(`proposeSignedRemoval` gates on a mesh, a ledger roster and target ≠ self) while the moderation
**report** still does — the two are routinely conflated.

### Lane C — P8 item 2: the backgrounding half of the gate, the hold, the heart negative (run 2026-09-19)

Two Simulators, **A** = `iPhone 17` (fp `3afcbe8b61420864`), **B** = `iPhone 17 Pro`
(fp `fb795f343c2954da`), app installed from the P8 DerivedData build of `main` at `526d0e1` — no
rebuild. Every launch carried `FERNLET_MESH_TRANSPORT=quic FERNLET_MESH_MATRIX=1
FERNLET_MESH_CONSOLE_LOG=1`, a seeded two-member descriptor, `FLOWS=commit,capabilities`, `STAGGER=1`
(3 s), a fresh log directory, and a per-sim audit stream started **before** the launch:

```
xcrun simctl spawn <udid> log stream --level info --predicate 'subsystem == "com.fernlet"'
```

No `xcodebuild` ran during the lane (`pgrep -x xcodebuild` empty throughout), and no ready or
activation line named `en8`/`en9`/`anpi0`. Backgrounding has no `simctl` verb of its own; the lane's
way is **`xcrun simctl launch <udid> com.apple.Preferences`**, which fronts Settings, and
`xcrun simctl launch <udid> MBO.Fernlet` to come back. Both work, and this is the first Lane C run to
use them.

| # | Row | Verdict | Evidence |
| --- | --- | --- | --- |
| a | **The backgrounding half of the routed-access gate** — the pushed `appIsForeground` leg falls on the background edge and the routed re-entry stays down until the foreground push | **PASS** | One audit stream, three `gateChanged` lines and nothing else between them. Launch: `mesh.routedAccess.gateChanged duress=false foreground=true protectedData=true` at `00:11:21.956`, immediately followed by `mesh.routedAccess.reentry … legs=protectedData+foreground`. **Fall**, 15 s after Settings was fronted: `mesh.routedAccess.gateChanged duress=false foreground=false protectedData=true` at `00:15:03.937` — exactly one line, and **no `mesh.routedAccess.reentry` anywhere in the next 93 s**. **Rise**, 7 s after the foreground relaunch: `mesh.routedAccess.gateChanged … foreground=true …` at `00:16:36.962`, then `mesh.routedAccess.reentry acksFiled=0 committed=0 heartsPending=0 legs=foreground projected=0 restored=false sweptPeers=0` at `00:16:36.970`. The `legs=` value naming **`foreground` alone** on the rise, against `protectedData+foreground` at launch, is the re-entry saying which leg moved — the gate's two legs are independent, live, on a real scene edge. **This is the first observation of the foreground gate on any lane**; every earlier run satisfied it by accident, a `simctl launch`ed app never having left `.activeForeground` |
| b | **The heart eligibility negative** — a heart to a member with no trust-vault row is a FINAL, audited refusal, custody kept | **NOT CROSSED** — blocked by finding **L-4** below (no committed pair, so no session, so no heart). **But the recipe changed**: see the correction under the table. No lane time was spent on the two sessions once L-4 was established | — |
| c | **The `FERNLET_MESH_ARM_AFTER` rows** (the removal vote, the `.chatAgeGated` three-leg negative, the app-path founding over MC) | **NOT CROSSED — hook absent** | `grep -rn FERNLET_MESH_ARM_AFTER App FernletKit Tests` → no match at `526d0e1`. The whole `FERNLET_MESH_*` family at HEAD is `ALLOW_HEARTS`, `AUTO_KEEP_FRIENDS`, `CHAOS`, `CHAOS_BARRED`, `CONSOLE_LOG`, `CONTINUATION`, `FLOWS`, `FLOWS_AFTER`, `LEAVE_AFTER`, `MATRIX`, `MATRIX_LABEL`, `MATRIX_MEMBERS`, `MATRIX_MESH_ID`, `REMOVE_AFTER`, `ROLE`, `TRANSPORT`. Building the hook was explicitly out of this item's scope, so the three rows stay where P6 §12.3 finding 12 left them, behind L-3 |
| d | **Item 3's QUIC hold row** — `holdCommittedLinks()` reached by the policy on a background edge, the committed tunnel beating ≥ 60 s, a third node neither browsed nor introduced, `resumeDiscovery()` on the return | **NOT CROSSED** — blocked by finding **L-4**. The hold is reached only with a committed peer, and no run produced one. The third Simulator was never booted, so nothing was spent on it | Neither `mesh.session.linksHeld` nor `mesh.session.linksResumed` appears in any stream — correctly, because `ProximityRunSeams` only emits the hold action for a session that has one |

**Item 6's Simulator refusal was NOT observed, and its absence is correct.** The expected
`mesh.continuation.refused` (`BGTaskSchedulerErrorDomain error 1`) never appeared, because the task
is submitted on the **first peer commit** and no peer ever committed. What *was* observed on both
nodes, on every run, is the half that precedes it: `mesh.continuation.registered event=meshStarted
state=idle` followed by `mesh.continuation.registered
id=MBO.Fernlet.mesh-continuation.88888888-8888-8888-8888-888888888881` — the concrete per-mesh id of
plan §14, registered at mesh start, on a radio, for the first time. The refusal itself stays owed to
a lane that reaches a commit.

#### The correction row (b) earns even without running: a third Simulator cannot produce the eligibility negative

P6 §12.3 finding 12(i) and the P7/P8 launchers all say this row "needs a third simulator that sat out
session 1". Read at `526d0e1`, that recipe cannot reach the refusal it names, and a **two**-Simulator
recipe can:

* The **sender** stops first and mints nothing. `MeshFlowDriver.fireHeart`
  (`App/Fernlet/Proximity/Feasibility/MeshFlowDriver.swift:431–445`) does
  `guard let friend = store.trustedProximityPeers.first(…) else { echo("heart NOT sent: no
  trust-vault row for …"); return }`. A third Simulator that sat out session 1 has no vault row on
  **either** side, so the run ends at a stdout echo: no mint, no custody, no audit token, nothing the
  row asks for.
* The refusal the row wants is the **recipient's**: `eligibleHeartAuthor` →
  `refusedHeart(key, reason: "notAFriend")` → `FernletAuditLog.log("mesh.routedHeart.refused",
  context: ["reason": …])` plus `routedHeartRefusedKeys.insert(key)`, which is what makes it FINAL
  (`MeshNetworkManager.swift:7880–7902`, short-circuited on later passes at `:7099`). Its own doc
  comment says the shipped sender cannot reach the case, "so a non-eligible heart implies a modified
  build".
* So the fixture the row needs is an **asymmetric vault**: the sender holds a row for the recipient
  and the recipient holds none for the sender. Two Simulators produce it by putting
  `FERNLET_MESH_AUTO_KEEP_FRIENDS=1` on **the sender only** in session 1 — the keep is a local act
  on each device, and nothing makes it mutual. Session 2 then mints normally and the recipient
  refuses.

**The ready-to-run recipe**, for whoever has a discovering lane: session 1 —
`FLOWS=commit,capabilities`, `ALLOW_HEARTS=1` both, `AUTO_KEEP_FRIENDS=1` **on A only**,
`LEAVE_AFTER=70` (A) / `40` (B), run length `3.5 × 70 + 60 ≈ 310 s`, both sides ending locally;
expect `friends kept=1 vault=1` on A and `vault friends=0` on B, and that asymmetry *is* the fixture.
Session 2 — a **different** mesh id (`terminated.v1` bars the first permanently),
`FLOWS=commit,capabilities,heart` with `heart` on A only, `FLOWS_AFTER=25`, no `AUTO_KEEP_FRIENDS`,
≈ 320 s; expect on B `mesh.routedDrain.admitted type=fernlet.mesh.routed-manifest.v1
verdict=admitted` (custody taken) then **`mesh.routedHeart.refused reason=notAFriend`**, the ledger
still at `heartsReceived=0`, and the refusal **not** repeated on later polls.

#### L-4 — the sim↔sim QUIC lane discovers nothing at `526d0e1` on this Mac (2026-09-19)

**Six runs, two of them after a full `simctl shutdown` + `boot` of both Simulators, produced not one
peer discovery.** Every run: both banners read
(`[mesh-matrix] run label=… transport=quic … role=founder|joiner`), both descriptors seeded
(`descriptor seeded: mesh=… members=2`), both radios up
(`[mesh-matrix] radios started; searching=true`) — and then
`[mesh-flow] slots total=0 committed=0 states=[]` and
`membership ledger=absent derived=0 barred=0` on both sides for the whole run, on every run.

What makes it a lane fact rather than a quiet run: **zero `[mesh-quic]` lines on stdout and zero
`proximity.transport.quic` lines in the audit stream**, at `--level debug`, on both nodes. No
`accepted`, no `refused`, no `browsed peers=`, no `tunnelEnded`, no `dial refused`. A refusal would
mean the door answered; there is no door. The empty browse set is consistent with
`NetworkMeshSession.noteBrowseSet` (`:978–985`), which guards on `keys.count != lastBrowseSetCount`
and so prints nothing at all for a browser that never finds anybody — silence here is exactly what
"no peer was ever browsed" looks like, and it is indistinguishable in a transcript from a browser
that never started.

Ruled out: a busy toolchain (`pgrep -x xcodebuild` empty for every run); the stale-Simulator hazard
(both were shut down and rebooted, and the two post-reboot runs behave identically); the
`--console-pty` no-stdout gotcha (both banners were read on every counted run); a VPN
(`scutil --nc list` empty, default route on `en0`); and mDNS being dead on the host
(`dns-sd -B _services._dns-sd._udp local` answers, and lists `_fernlet-friend._tcp` — the **MC**
service type, `MeshMultipeerSession.friendServiceType`, not the QUIC mesh's
`_fernlet-mesh2._udp`, `NetworkMeshSession.swift:270`).

**Not** ruled out, and the next two things to try: whether `_fernlet-mesh2._udp` is advertised at all
during a run (every `dns-sd` capture in this session came back empty through block-buffered
redirection — use a pty, or `dns-sd -B … | cat -u`), and whether the host's `en0` address being
inside the CGNAT range `100.64.0.0/10` (`100.110.200.196/26` tonight) changes what two Simulators can
route between, given the P2 note that they "meet over a routable host address with peer-to-peer
disabled". A Mac on an ordinary RFC1918 LAN is the cheapest control.

**Reproduction:** install the current `Debug-iphonesimulator/Fernlet.app` on `iPhone 17` and
`iPhone 17 Pro`; harvest both `signingKey=`s with a bare
`FERNLET_MESH_TRANSPORT=quic FERNLET_MESH_MATRIX=1` launch; relaunch both 3 s apart with a shared
`MATRIX_MESH_ID`, `MATRIX_MEMBERS=<KA>,<KB>` and `FLOWS=commit`; watch for `[mesh-quic]` on stdout
for 80 s. **Until L-4 is cleared, every tier-2 row that needs a committed pair is un-runnable** —
which tonight is rows (b) and (d), and it is also the gate on P6's four long-standing un-run rows.

**THE VERDICT, at the P8 close-out — and it is not this lane's own fault:** attributed
2026-09-19 by a baseline-commit probe (four lane runs, same hour, same Simulators, same CGNAT
network): NOT a P8 regression — the P6 close-out `82fc4d7` and P2's `596bcf8` discover, the pre-P8
tip `92f0b8e` and P8's tip fail identically; a P7 defect at `df0ce5b` (P7 item 3): the DEBUG matrix
harness calls `startJoin()` on the Home tab and the store's first policy apply (previous nil, every
radio an edge) resolves discovery `.stop` → `.stopJoin` → the QUIC listener is cancelled ~20 ms
after creation, before Bonjour registers; the product path (entry via the Social tab) is unaffected;
fix landed as the P7 fix commit `80934b7` — the harness selects the Social tab before `startJoin()`, with the
pure-value cell `theMatrixHarnessSurvivesTheFirstRunPolicyVerdict` (no `.stopJoin` in the first
verdict over the harness's facts) that would have reddened in `df0ce5b` itself, and a scan pinning
every shipping `startJoin()` / `resumeSearchingForPartitionedMesh()` caller under `App/` to the
seams file or the harness. The P7 fix commit's SHA is added to this section when it lands; until it
is on `main` and a lane run discovers again, the rows above stay un-runnable. **Confirmed on 2026-09-19** by the run below.

### Lane C — P9 item 0: the confirmation run at HEAD, then three and four nodes (2026-09-19)

**The P7 fix `80934b7` repairs the lane. The sim↔sim QUIC lane DISCOVERS at HEAD**, on the same Mac,
the same CGNAT `en0` and the same Simulators that produced L-4's six dark runs — and it does not stop
at a pair: three nodes and four nodes both form a **full** mesh on the first attempt.

Build: `f3d6175` (`claude/loving-bell-296321`, `80934b7` two commits below), rebuilt for this lane
(`xcodebuild build -scheme Fernlet`, `** BUILD SUCCEEDED **`, zero `error:`) and installed fresh on
every node. No `xcodebuild` ran during any run (`pgrep -x xcodebuild` empty throughout), no test run
touched the identities mid-lane, a fresh log directory per run, `STAGGER` 3 s, and a per-Simulator
audit stream started **before** each launch (`log stream --level info --predicate 'subsystem ==
"com.fernlet"'`). Every launch carried the same seven variables, differing only in label, mesh id and
member list:

```
SIMCTL_CHILD_FERNLET_MESH_TRANSPORT=quic  SIMCTL_CHILD_FERNLET_MESH_MATRIX=1 \
SIMCTL_CHILD_FERNLET_MESH_CONSOLE_LOG=1   SIMCTL_CHILD_FERNLET_MESH_MATRIX_LABEL=p9item0-<run>-<n> \
SIMCTL_CHILD_FERNLET_MESH_MATRIX_MESH_ID=<uuid> \
SIMCTL_CHILD_FERNLET_MESH_MATRIX_MEMBERS=<KA>[,<KB>…] \
SIMCTL_CHILD_FERNLET_MESH_FLOWS=commit,capabilities \
xcrun simctl launch --console-pty <udid> MBO.Fernlet -completeOnboarding
```

Nodes — **A** `iPhone 17` (`09F57BCA-…A88`, fp `8764ff61070db285`), **B** `iPhone 17 Pro`
(`454FCC9C-…661B`, fp `fb795f343c2954da`), **C** `iPhone 17 Pro Max` (`9BA301C9-…B7`, fp
`87684c8a76bb86c7`), **D** `iPhone 17e` (`9A1B8A32-…81D`, fp `45975569e20dfb12`, booted for run 3
only). A's fingerprint is not P8's — that install had been erased since; B's is unchanged, which is the
keychain-backed identity behaving as documented.

| Run | Node | `[mesh-matrix]` banner | `[mesh-quic]` lines | tunnels | `slots total=/committed=` | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| **1 — pair**, mesh `99991111-…` | A | yes | 13 | 1 | `1/1 [connected]` | **PASS** |
| | B | yes | 13 | 1 | `1/1 [connected]` | **PASS** |
| **2 — three**, mesh `33333333-…` | A | yes | 28 | **2** | `2/2 [connected,connected]` | **PASS** |
| | B | yes | 28 | **2** | `2/2` | **PASS** |
| | C | yes | 26 | **2** | `2/2` | **PASS** |
| **3 — four**, mesh `44444444-…` | A | yes | 45 | **3** | `3/3 [connected×3]` | **PASS** |
| | B | yes | 45 | **3** | `3/3` | **PASS** |
| | C | yes | 45 | **3** | `3/3` | **PASS** |
| | D | yes | 44 | **3** | `3/3` | **PASS** |
| **4 — pair repeat**, mesh `88882222-…` | A | yes | 9 | 1 | `1/1 [connected]` | **PASS** |
| | B | yes | 9 | 1 | `1/1 [connected]` | **PASS** |

The three decisive facts against L-4, on run 1: both banners read; `[mesh-quic]` is **not** silent —
it opens with `browsed peers=1 [fernlet-mesh-122c8b6f8872._fernlet-mesh2._udp.local.]`, the QUIC
service type L-4 could never find advertised; and the audit stream carries
`proximity.transport.quic` records on both nodes. The convergence line:

```
[mesh-quic] accepted fb795f343c2954da sid=68406412-…: tunnel activated, tunnels=1
[mesh-flow]  slots total=1 committed=1 states=[connected]
```

**`stopJoin` appears zero times in any audit stream of any of the four runs** — the L-4 signature
(a `.stopJoin` verdict in the first ~100 ms after `startJoin`) is gone, which is the fix being
observed rather than inferred.

**The tunnel graphs are complete, not spanning.** Three nodes: A↔B, A↔C, B↔C — 3 = N(N−1)/2, every
node holding two, matching fingerprints and `sid`s on both ends of each edge. Four nodes: A↔B, A↔C,
A↔D, B↔C, B↔D, C↔D — 6 = N(N−1)/2, every node holding three. **No node held zero tunnels to any
member, in either run**, so the P3 item-0 star does not reappear at N=4; the 0b link-gate fix
(`mayLinkToDiscoveredPeers`) scales one node further than it had ever been asked to.

Stability and timing: **zero `tunnelEnded`, zero `refused`, zero `dial refused`, zero
`redundantTunnelClosed` on every node of every run.** Heartbeats flow both ways throughout (20 lines
per node over ~150 s at three nodes, 36 over ~170 s at four). Time from the **last** node's launch to
every tunnel live: **2.6 s** (run 1), **3.1 s** (run 2, all three live by `17:38:01.10`), **~3 s**
(run 3), **2.0 s** (run 4). A four-node mesh converges as fast as a pair.

Two notes for the next reader:

* **Run 3, node C logged two consecutive `tunnel activated, tunnels=2` lines.** Not a duplicate: the
  three peers are three distinct fingerprints with three distinct `sid`s, the final count is
  `tunnels=3`, and `redundantTunnelClosed` never fires. The `tunnels=` value is sampled after
  insertion into the link table, and two activations landed inside the same instant — a log-ordering
  artefact of concurrent activation, visible only at N ≥ 4.
* **`[mesh-flow] membership ledger=absent derived=0 barred=0` on every node of every run**, as the
  2026-09-12 correction says it must for a *seeded* harness run. These four runs converge the
  **descriptor** roster (`members=2/3/4` as seeded) and say nothing about the derived one.

**What this unblocks:** L-4 is cleared, so every tier-2 row it blocked is runnable again — P8 item
2's rows (b) and (d), P6's four un-run rows, and P9's acceptance lane. Nothing above was run on
hardware; Lane D is still owed.

### Lane C — P9 item 2: a presence epoch rotating over QUIC (2026-09-19)

**The tier-2 acceptance row is CROSSED.** At a 900 s wall-clock boundary each of two Simulators
minted a fresh instance name and a fresh TLS identity, put the new one on the air, and re-sighted the
other under its new name with the pairwise tag still matching. Nothing of the old posture survives
the boundary: the names and the certificate digests share nothing but the constant `fn-` prefix.

Build `9f78111` (item 2 pass 2; HEAD `6ae7cb2` is its ledger), rebuilt for this lane (`** BUILD
SUCCEEDED **`, zero `error:`, app mtime 21:22:34 after the 21:19:31 build start) and installed fresh
on both. Nodes — **A** `iPhone 17` (`09F57BCA-…A88`, fp `38ce0d54d729c8f5`), **B** `iPhone 17 Pro`
(`454FCC9C-…661B`, fp `fb795f343c2954da`). B's fingerprint is item 0's, unchanged across an
uninstall (keychain-backed); A's is new again — the same asymmetry item 0 recorded.

**Friend seeding took three sessions.** Tags match only for KEPT friends, so the lane ran the P6
item-10b pair recipe (`FERNLET_MESH_AUTO_KEEP_FRIENDS=1`, `FERNLET_MESH_LEAVE_AFTER=40/25`, mesh
`99992222-…`): `[mesh-flow] friends kept=1 vault=1` on both in 80 s. **Not enough** — see finding
**P9-2-B**. A three-node seed meant to give each side a *second* friend **failed** on the
founder-collapse race (`[mesh-quic] refused unknownIdentity … rosterMembers=2`; C stuck at
`awaitingIdentityIntroduction`), so the lane fell back to two PAIR sessions, A↔C (`99994444-…`) then
B↔C (`99995555-…`), **C** = `iPhone 17 Pro Max` (`9BA301C9-…B7`, fp `87684c8a76bb86c7`), 45 s each.
C is only a vault row; it never runs during a presence run.

Presence has no launch-env hook: it was switched on by hand per node at Settings → Nearby friends →
**Presence**, and the switch ignores a `tap` under the simulator tool — a 40 pt `swipe` across it
works (the P8 lesson, re-confirmed). Launches are plain, with no `FERNLET_MESH_*` variable and a
per-Simulator audit stream started **before** each launch, killed by saved PID:

```
xcrun simctl spawn <udid> log stream --level info --predicate 'subsystem == "com.fernlet"' > <log> &
xcrun simctl launch <udid> MBO.Fernlet -completeOnboarding          # A then B, 3 s apart
```

#### Run 1 — the rotation (the acceptance row). Boundary **21:45:00**, launched 21:40, apps on Home.

| Side | `advertised` epoch / name / cert | `rotated` epoch / name / cert | shared bytes | peer key before → after | `tags` | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| **A** | 21:40:03.924 · 1988742 · `fn-419a8f4d0ca9bbab` · `bebe4700683e032d` | 21:45:00.808 · **1988743** · `fn-a63b8386a493a355` · `54bdc74431c7d724` | none past `fn-`; 16/16 hex, longest common substring 1 char | `fn-5c2065d9222ba2c0` → `fn-a036a6b06ce02b3d` | 1 → 1 | **PASS** |
| **B** | 21:40:09.870 · 1988742 · `fn-5c2065d9222ba2c0` · `0162854118df72d4` | 21:45:00.788 · **1988743** · `fn-a036a6b06ce02b3d` · `b28b3ac9f7e0c1b4` | none past `fn-`; 16/16 hex, longest common substring 2 chars | `fn-419a8f4d0ca9bbab` → `fn-a63b8386a493a355` | 1 → 1 | **PASS** |

B rotated **+0.788 s** after the boundary, A **+0.808 s**; each re-sighted the other's NEW
registration at **21:45:02.079**, **1.27 s** after its own rotation, `tags=1` again. Exactly one
`presence.quic.rotated` per side. `stopped`, `redundantTunnelClosed` and `dial refused` are **zero**
here and in every run below.

```
21:45:00.808  presence.quic.rotated certificate=54bdc74431c7d724 epoch=1988743 name=fn-a63b8386a493a355
21:45:02.079  presence.quic.sighted peer=fn-a036a6b06ce02b3d._fernlet-near2._udp.local. tags=1
```

Not to be misread: at 21:45:00.81 each side logs `sighted … tags=0` for BOTH old names, its own
included — the withdrawn registration's empty TXT, plus the own ghost layer 1 drops. No peer lost tags.

#### Runs 2–4 — the heart, the glare attempt, a second rotation. Epochs 1988744 → 1988745, apps on Friends.

| # | What | Verdict | Evidence |
| --- | --- | --- | --- |
| 2 | One heart, A → B, inside a rotated epoch | **PASS (transport half)** | `presence.quic.connected tunnels=1` on **both** at 22:05:23.94/.95; the friend row reads **"Nearby now"**, then **"Sent just now"** on A. The presence heart path emits no audit token at the recipient (only in-memory `recordDiagnostic`), so B's ceremony was not independently confirmed |
| 3 | Glare — both hearts at once | **NOT A GLARE (inconclusive)** | the two taps landed **1.35 s** apart (`connected` at 22:17:44.95 and 22:17:46.30 on both), so each heart took its own tunnel, `tunnels=1` each time and **zero** `redundantTunnelClosed` — the correct answer for sequential dials. One heart did cross **each way**, and presence never stood down |
| 4 | A second rotation, apps still up | **PASS, with a timing surprise** | 1988744 → **1988745**, one `rotated` per side; A `fn-690e71966399dcd2`→`fn-d80ff7dbf3ed6b84`, B `fn-f75171e671f6e4b8`→`fn-d2df908b1566576f`, certs wholly different, re-sighted `tags=2` at 22:15:53.01 — but it fired at **22:15:51.3**, **51 s late** (finding **P9-2-C**) |

#### Three findings

* **P9-2-A — `presence.quic.sighted` logs the peer's advertised instance name.** The line's own
  comment says it names the peer "by its OPAQUE, session-scoped key … and never by the instance name
  it advertises". On the Bonjour path the key is `MeshLinkKey(endpoint.id)` and `endpoint.id` **is**
  the service name, so every sighting reads `peer=fn-<the peer's own advertised name>._fernlet-near2._udp.local.`.
  The linkage window is bounded to one 900 s epoch by the rotation this row just proved, but the
  privacy property `9f78111`'s fix (3) claims does not hold.
  `FernletKit/Sources/ProximityKit/Transport/NetworkPresenceSession.swift:691-715`.
* **P9-2-B — a mutual friend whose ONLY friend is you never becomes nearby, and nothing says so.**
  With A and B each other's sole friend the transport sighted the peer with `tags=1` on both sides
  and no friend ever surfaced. Self-exclusion layer 3 drops any advertisement whose whole token set
  is a subset of our own, and a sole-friend pair's sets are identical by construction — the source
  documents this ("RESIDUAL (bounded, accepted, spec)"), so it is not a new defect. Two Simulators
  are exactly that shape: **every future presence lane run must seed a third friend.** The exclusion
  is invisible too — `recordDiagnostic` only appends to an in-memory array, so nothing records it,
  and the lane inferred the negative from the source rather than from a "Not nearby" row.
  `FernletKit/Sources/ProximityKit/Presence/PresenceManager.swift:501-540`.
* **P9-2-C — the boundary wake drifts with the length of the sleep.** Run 1's rotation, armed ~300 s
  ahead, landed +0.8 s after the boundary; run 4's, armed ~767 s ahead, landed **+51 s** — on BOTH
  Simulators within 0.3 s of each other, which points at the host suspending the two timers together
  rather than at app logic. The epoch NUMBER stayed correct (`floor(unix/900)` read at the wake) and
  both sides were late together so tags still matched, but for 51 s each device kept advertising the
  previous epoch's name and certificate. `PresenceManager.delayToNextEpochBoundary()` arms one long **Fixed at `b3f9de9` (P9-2-C):** the boundary is now a deadline awaited in ≤ 30 s steps (`stepToNextEpochBoundary()`, `maxEpochRotationStepSeconds`), re-checked against the wall clock on every wake, so lateness is bounded by one step's drift; a device measure of the drift is still owed.
  `Task.sleep` per epoch — the wall-clock-deadline family; a device run should re-measure it before
  the drift is written off as a Simulator artefact.

Two smaller notes: the Friends tab's "Looking for nearby friends…" card is the **mesh** session card
and never reflects presence, which shows up two taps in as the friend row's "Nearby now" and heart;
and the "Sent just now" cooldown banner does not clear itself — twelve minutes on it still read
"Sent just now", clearing only when the row was collapsed and re-expanded.

### Lane C — P9 item 3: a recipe share paused and resumed over QUIC (2026-09-20)

**Every tier-2 row the pass-2 verify named is crossed, including the one item 2 could not reach.**
An inbound dial completes; a picture recipe crosses on a real per-transfer stream with matching byte
counts; the pairing goes quiet to a third Fernlet within **1.3 ms** and both sides come back under
postures with no byte in common; a pairing idle for **200 s** still carries a share; and two devices
that dialled each other **17 µs apart** produced a genuine glare that collapsed to one tunnel with
opposite `kept` values and delivered **both** recipes.

Build `ba34491` (item 3 pass 2) plus the DEBUG-only lane harness committed with this section,
rebuilt for the lane (`xcodebuild build-for-testing`, `** TEST BUILD SUCCEEDED **`, zero `error:`,
app dylib stamped 14:10 against a 14:05 source edit) and installed fresh on every node. No
`xcodebuild` ran during any run, a fresh log directory per run, and a per-Simulator audit stream
started **before** each launch and killed by its saved PID.

Nodes — **A** `iPhone 17` (`09F57BCA-…A88`), **B** `iPhone 17 Pro` (`454FCC9C-…661B`),
**C** `iPhone 17 Pro Max` (`9BA301C9-…B7`) — **dark, see finding P9-3-A** — and **D** `iPhone 17e`
(`9A1B8A32-…81D`), booted to replace C as the third Fernlet. All four had been up ~37 h and were
shut down and rebooted before the lane (the ~3 h rendering rule).

#### The harness, and how to rerun

`App/Fernlet/Proximity/Feasibility/RecipeShareLaneHarness.swift` — DEBUG-only, release is a
compiled-out no-op. **It speaks no radio verb**: it writes the two store facts the run policy reads
(`selectedTab = .food`, the nearby-recipe opt-in through its shipping setter) and lets
`FernletStore`'s funnel start the listener through `executeProximityRunActions`, exactly as a tab
change does. Its one manager door is `sendRecipeShare(_:to:)`, the share sheet's own. It reports the
manager's observable surface at 1 Hz, and **prints the policy's verdict beside the radio's account of
itself**, which is the only reason C's darkness was diagnosable at all.

```
SIMCTL_CHILD_FERNLET_RECIPE_LANE=dial|watch            # install + the part this node plays
SIMCTL_CHILD_FERNLET_RECIPE_LANE_LABEL=<token>
SIMCTL_CHILD_FERNLET_RECIPE_LANE_IMAGE_BYTES=350000    # synthesized picture, >= n bytes (cap 512 KiB)
SIMCTL_CHILD_FERNLET_RECIPE_LANE_DIAL_AT=<unix secs>   # the glare instant; honoured to the ms
SIMCTL_CHILD_FERNLET_RECIPE_LANE_SECOND_SHARE_AFTER=200
SIMCTL_CHILD_FERNLET_RECIPE_LANE_LEAVE_AFTER=110       # poll at which it leaves the recipe tab
SIMCTL_CHILD_FERNLET_RECIPE_LANE_RETURN_AFTER=140
xcrun simctl spawn <udid> log stream --level info --predicate 'subsystem == "com.fernlet"' > <log> &
xcrun simctl launch --console-pty <udid> MBO.Fernlet -completeOnboarding > <console> &
```

Scripts: `…/scratchpad/item3lane/{lane,run1,run2,run3,run4,run7}.sh` (`lane.sh` holds the UDIDs and
the stream/launch/kill helpers).

#### The rows

| Row | What | Verdict | Evidence |
| --- | --- | --- | --- |
| **R1** | an inbound dial completes at all | **PASS** | run 2: A `recipe.quic.connected tunnels=1` **13:56:55.293816**, B **13:56:55.297322** — 3.68 s after A's launch. **Zero `helloRefused` on every happy-path run** (1, 2, 3, 7). Verified, not merely connected: the send is gated on `coordinator.state == .connected(peerIdentity)`, and B decrypted a **sealed** `.recipeShare` envelope (`Received recipe share from iPhone 17`), which only follows a completed identity introduction |
| **R2** | the pause is real | **PASS** | run 2: D sighted B `13:56:51.023813` and A `13:56:54.038722` (`recipe=true`, `peers=2`). The pair `paused tunnels=1` at **13:56:55.303929** (both, same µs); **1.3 ms later** D logged `sighted … recipe=false` for BOTH (`.305278`, `.305582`) — the withdrawn registration's empty TXT, item 2's own pattern — and its picker fell to `peers=0` ("iPhone 17 is no longer nearby"). D held no row to dial |
| **R3** | the resume is real | **PASS** | run 2: A left the tab (`stopped` **13:58:46.800983**); B `resumed` **13:58:46.844961** (+44 ms) as `fernlet-mesh-6d9e6a4663be` / cert `e2fbcc7d2d88d277` against the pre-pause `fernlet-mesh-bbea3dba96ee` / `9746c5d93c9d78ba` — **no byte in common past the `fernlet-mesh-` prefix**, either field. D re-sighted B **13:58:48.019821** (+1.17 s). A re-advertised **13:59:17.500169** (`fernlet-mesh-eee297b8a627` / `4377e2f9b8154314`) and D sighted it **13:59:18.590041** (+1.09 s). Run 1 is the same row on the other pair |
| **R4** | a picture recipe on a transfer stream | **PASS** | run 2: `transferStream verb=sent bytes=898715` (A, `13:56:55.438556`) / `verb=received bytes=898715` (B, `.438300`) — **877 KiB, 13× the 64 KiB bulk floor**; B's console `received title=lane-recipe-1 imageBytes=490732`, byte-identical to A's `sending … imageBytes=490732`. Twice more in runs 1 (898242 / 490669) and 7 (898623 / 490833). **Negative half, run 3:** a text-only recipe produced **zero** `transferStream` lines on both sides and still arrived |
| **R5** | glare | **PASS** | run 6: both sides `sending seq=1 at 1789928196.016031` (A) and `…196.016048` (B) — **17 µs apart**. Both outbound tunnels activated at `14:16:36.2278`; then **one `redundantTunnelClosed` per device with opposite `kept`** — B `kept=established` `.259324`, A `kept=incoming` `.261826` — each ending `tunnels=1`. The single `helloRefused` of the whole lane is B refusing the collapsed duplicate (`.259352`). **Both recipes crossed**: each device shows `Sent lane-recipe-1` and `pending=1` |
| **R6** | a pairing survives ≥ 3 min idle | **PASS** | run 3: first share at `14:00:54`, then `sending seq=2 idleSeconds=200` → `Sent lane-recipe-2 to iPhone 17 Pro`, B `pending=2` with `lane-recipe-2`. A's audit stream after `paused` (`14:00:53.919389`) is **empty to the end of the run** (`14:05:16`): no `endTunnel`, no disconnect at ~90 s, no re-dial. The coordinator's 30 s `.sessionHeartbeat` alone holds QUIC's 90 s idle timer open |
| **R7** | no instance-name token reaches the UI | **PASS** | every report line of every node of every run reads `uiToken=false` — the scan covers the picker's rows (`nearbyRecipients[].displayName`) and all 40 "Connection details" lines (`diagnosticEvents[].message`), and `senderToken=false` covers the review sheet's sender. Visual: B's review sheet reads "**lane-recipe-1 / Shared by iPhone 17**" (`item3lane/run7_ui/B-ui.png`) |
| **R8** | does Bonjour `.remove` ever fire on a Simulator | **0 (observational)** | **zero `recipe.quic.registrationWithdrawn` in the whole lane**, including a dedicated **5 min 27 s** idle advertise (run 5, D alone: one `advertised` at `14:09:54.695712`, nothing else to `14:15:22`). FIX-3's republish branch is therefore still tier-1-only code |
| **R9** | cancellation is silent | **PASS** | runs 1 and 2: leaving the tab gives `recipe.quic.stopped` (`13:58:46.800983`), `policy=stop`, diag "Recipe share discovery stopped." — and **no error-level record in the `com.fernlet` stream, zero `browserFailed`, no banner**. Re-entering re-advertises under a fresh name and certificate (`13:59:17.500169`) and re-discovers the peer |

Token census over the whole lane: `sighted` 25, `advertised` 20, `paused` 13, `connected` 13,
`transferStream` 6, `resumed` 3, `stopped` 2, `redundantTunnelClosed` 2, `helloRefused` 1 (the glare
duplicate). **`dialRefused`, `browserFailed`, `registrationWithdrawn`, `transferStreamRefused` and
`transferStreamFailed` are all zero.**

#### Findings

* **P9-3-A — BLOCKER — a configured app lock stops the recipe-share and presence radios forever.**
  C never advertised in 200 s of foreground app on Home and Food: `policy=stop`, zero `recipe.quic.*`
  records, while three Simulators beside it read `policy=foregroundOnly`. The difference is a Fernlet
  Lock configured on that device. `ProximityRunPolicy.recipeShareState`
  (`App/Fernlet/ProximityRunPolicy.swift:486-492`) and `presenceState` (`:475-482`) stop on
  `appLockEngaged`, which is `true` for `FernletLockState.locked` (`:340-344`) — and `.locked` is the
  **resting** state of a configured lock, not "the lock screen is up"
  (`FernletKit/Sources/FernletLock/FernletLockService.swift:115-124`). The only other state is
  `.unlocked(scope:)`, one surface at a time, and every scope (`:98-108`) is a private surface;
  `privateHub` is the Personal tab, where both radios answer `.stop` anyway. So a user who sets a
  lock loses recipe sharing and nearby presence outright, and nothing says why — the picker simply
  never finds anybody. The mesh radios do not read the lock and are unaffected. **Pre-existing** (P7
  item 1's table), not a pass-2 regression, and invisible to tier 1, which asserts exactly this
  mapping. Owner decision: either the input becomes "the lock UI is presented", or the radios key off
  something else.
  **FIXED 2026-09-22** (the owner's call of the device round, ledger
  `Docs/Mesh-Migration-Loop-Ledger-Device-2026-09-22.md` item 3, decision 3: *make it work*). The
  third option was taken — **the fact itself is retired**, not re-projected: the `!appLockEngaged`
  leg is gone from `presenceState` and `recipeShareState`, `ProximityRunPolicy.Input`'s
  `appLockEngaged` field and the `appLockEngaged(_:)` projection are deleted, every feed is retired
  (`FernletApp`'s scene push, `ContentView`'s view helper, `FernletStore`'s `ProximityEdgeFacts`),
  and the policy file no longer imports `FernletLock` at all — so the leg cannot be flipped back
  without a deliberate new input. The reasoning: a scoped lock protects the Private tab, the
  progress photos and the lock settings; it is not a radio switch, and the mesh row — carrying the
  same person's session — never had the leg. The run-policy product drops 23 040 → **11 520** rows
  and the pin moved in `ProximityRunPolicyTests` and `MeshP7RunPolicyAcceptanceTests`; the cell that
  said "the app lock moves presence and recipe only" is replaced by its inverse stated positively
  (`noLockLegSurvivesAndAListenerRunsWheneverItsOwnRuleAllows`: on all 384 opted-in, foreground,
  hard-stop-free presence rows and all 288 recipe rows the listener RUNS). Shown red once against
  the restored old table: the P7 clause failed on the count, on `agrees` and on `inactiveIsForeground`,
  and the new cell failed five ways. The lock-state edge in `ContentView` deliberately SURVIVES —
  it is the view's duress feed (a duress unlock moves the lock state and `isDuressSessionActive`
  together) and the gate's re-entry pass at that instant, so the view-edge count stays 7.
* **P9-3-B — NOTE — the glare loser re-mints its posture mid-collapse.** A emitted `resumed` + a
  fresh `advertised` at `14:16:36.261535/.261551`, then `redundantTunnelClosed`, `connected` and
  `paused` again by `.261918`: the collapse evicts the connection record, which is the gate's resume
  event. Fail-safe and correct at rest, but a glare costs an extra TLS mint and a third instance name,
  and a third Fernlet browsing in that 0.4 ms can sight a name belonging to neither posture.
* **P9-3-C — NOTE — the `transferStream` receive line precedes the send line** by 0.2–1.7 ms in all
  three crossings (`noteTransfer("sent", …)` runs after the write returns). Not a reordering bug; do
  not compute a latency from the pair.
* **P9-3-D — NOTE — a paused radio keeps its picker rows.** The sender's `nearbyRecipients` stayed at
  2 through the pairing. The sheet disables the other rows (`engagedRecipientID`), so the product is
  right — but `peers=2` during a pairing must not be read as "the pause failed"; the pause is proven
  on the other side of the room.
* **P9-3-E — NOTE (lane mechanics) — `store.selectedTab` is the policy's mirror, not the TabView's
  selection.** The write moved the verdict (`.personal` → `stop` → `recipe.quic.stopped`) while the
  visible tab stayed Home. Same for `MeshRejectionMatrixHarness`; a harness that needs the visible tab
  must drive the UI.
* **P9-3-F — NOTE (lane mechanics) — a 1 Hz report cannot see the diagnostics ring.** "Verified …",
  "Secure recipe-share channel opened with …" and "Recipe sharing closed to others while paired with
  …" all land inside one poll. Dump the whole 40-entry ring at the end of a run instead.

Raw logs: `…/scratchpad/item3lane/` — `run1` (pair + picture + stop/return, C dark), `run2` (the
acceptance run: pair + picture + D observing the pause and both resumes), `run3` (text-only + the
200 s settled share), `run6_glare` (the 17 µs glare), `run5_idle` (the 5 min 27 s advertise),
`run7_ui` (the review-sheet screenshots), `probeC` / `probeD` (the dark-device diagnosis); builds in
`item3lane/logs/build{1,2,3}.log`; findings for the fix agent in `item3lane/findings.md`.

### Lane C — the deletion round's item 0: the UNSEEDED pair — founding through the provisional path, then the double-mint re-dial (run 2026-09-22)

**The QUIC first-meeting capability the cutover built is OBSERVED.** Two Simulators with **no**
`FERNLET_MESH_MATRIX_MEMBERS`, **no** `FERNLET_MESH_MATRIX_MESH_ID` and nothing persisted between
them found a mesh through the provisional path over a real QUIC tunnel, converged their derived
rosters to `derived=2` under one epoch head in **1.6 s** from browse, and then — the tunnel killed
between the two commits — re-introduced under the tolerated meshID and converged again **4 s** after
the thaw. This is the stranger-admission design's owed test (vi), the gate the deletion round's
launcher put in front of deleting MultipeerConnectivity, and it passed on the first unseeded launch.
Every correction above that says the path "has never been observed on any radio" is dated by this
section.

Build: `515145b` (the deletion-round launcher, on the cutover round's last plan blob) plus the one
harness fix this lane needed (`MeshFlowDriver`'s commit dedupe, below — committed as the deletion
round's item 0), `xcodebuild build -scheme Fernlet` into a fresh DerivedData, `** BUILD SUCCEEDED **`,
zero `error:`, installed fresh on both nodes. No `xcodebuild` ran during any run (`pgrep -x
xcodebuild` empty), a fresh log directory per run, and a per-Simulator audit stream (`log stream
--level info --predicate 'subsystem == "com.fernlet"'`) started before each launch and killed by
saved PID after it. Nodes — **A** `iPhone 17` (`09F57BCA-…A88`, fp `1b4fd5b9e6f123e5`; the install
had been erased since P9, so the fingerprint is new), **B** `iPhone 17 Pro` (`454FCC9C-…661B`, fp
`fb795f343c2954da`, unchanged since P9). A third Simulator (`iPhone 17 Pro Max`, `9BA301C9-…B7`)
was booted the whole time with a non-matrix Fernlet process another session had left on it; it
never appeared in either node's browse set (`browsed peers=1` on both, every run), because a launch
without `FERNLET_MESH_MATRIX=1` starts no mesh radio.

**The recipe.** Lane C's pair launch with the seed variables **omitted** and the roles set. The
founder role goes on the **lower fingerprint** — `foundsPairwiseMesh(local:peer:)` is `local < peer`,
so that is the side the shipping code keeps when both halves mint, and the harness's founder loop on
the OTHER side would race the yield (its `armFounderLedgerForHarness()` guard is `membershipVerifier
== nil`, which is exactly the yielder's state between `unwindNewbornMesh()` and the grant).

```
# founder (the LOWER fingerprint) — no MESH_ID, no MEMBERS
SIMCTL_CHILD_FERNLET_MESH_MATRIX=1 SIMCTL_CHILD_FERNLET_MESH_CONSOLE_LOG=1 \
SIMCTL_CHILD_FERNLET_MESH_MATRIX_LABEL=unseeded1-founder \
SIMCTL_CHILD_FERNLET_MESH_FLOWS=commit SIMCTL_CHILD_FERNLET_MESH_ROLE=founder \
xcrun simctl launch --console-pty <A-udid> MBO.Fernlet -completeOnboarding
# joiner, 3 s later: the same five variables with LABEL=unseeded1-joiner and ROLE=joiner
```

The banner reads `no descriptor seeded: roster stays empty, every peer verdicts stranger` on both,
and `transport=default(quic)`. `FERNLET_MESH_TRANSPORT` is not set (it is inert since the flip and
retires with the seam in this round).

#### Run 1 — the unseeded founding (`unseeded1-*`, 150 s)

| Check | Required | Result | Evidence |
| --- | --- | --- | --- |
| The roster consulted at the introduction is EMPTY on both sides | `members=0` | **Observed** | audit `mesh.introductionAuthority.legacyRosterFallback members=0` on A and on B, 0.5 ms apart, at the introduction |
| `admitsStrangersProvisionally` answers the introduction | a tunnel where P2's matrix row 1 recorded `refused unknownIdentity … rosterMembers=0` | **Observed** — the same launch shape as row 1, and the introduction ACCEPTED on both sides | A: `[mesh-quic] accepted fb795f343c2954da sid=B6453553-…: tunnel activated, tunnels=1`; B: `accepted 1b4fd5b9e6f123e5 sid=7B49DC16-…: tunnel activated, tunnels=1`. Zero `refused` lines on either node. An accept at `rosterMembers=0` has exactly one path through `MeshChannelIntroductionExchange.receive`: `guard roster.admitsStrangersProvisionally else { return .unknownIdentity }` |
| The identity introduction, then the commit | slot at the gate, then `connected` | **Observed** | both: `committing slot gate=awaitingProximityCommit` → `slots total=1 committed=1 states=[connected]`; `capabilities peer=[activities,…,wire2]` |
| `promoteToMesh` on the first commit — both halves mint | a descriptor on each side, the double mint repaired | **Observed, both halves** | A (committed second): audit `mesh.meshDescriptor.droppedUncommittedSlot` at 23:59:24.03 — B's descriptor arrived while A was still uncommitted (the commit-timing race P8 item 0 named), then A founded and announced its own; B: `mesh.descriptor.yieldedNewbornMesh adopted=5612A710-…` at :24.22, `mesh.session.abandonedNotDurable` (the yield's unwind), `mesh.sessionCeiling.armedFromAdoptedMesh` |
| The admission request, auto-granted | a grant with no owner tap and no harness grant | **Observed — the shipping auto-grant, not the harness** | A: audit `mesh.admissionRequest.autoGrantedFoundingPair` at :24.25, `mesh.membershipLedger.reGossiped frames=2`; B: `[mesh-quic] membershipRecord fernlet.mesh.member-admission.v1 accepted`, audit `mesh.membershipLedger.bootstrapped` :24.26, `mesh.membershipLedger.adopted members=2` :24.32. **The harness fallbacks were silent:** A printed `founder armed=false ledger=present derived=2` (the shipping founding had already produced the ledger by the driver's next poll), no `admitting …` line on A, no `requesting admission` line on B |
| `derived=2` on both, one epoch head | both `[mesh-flow] membership ledger=present derived=2` | **Observed** | both: `membership ledger=present derived=2 barred=0 status=active epochRef=1.19ed1b9595e0352e69fafba0be3b88e0.1b4fd5b9e6f123e5` (A, the lower fingerprint, is the coordinator named inside the ref) |
| Stability | one activation per side, no ends | **Observed** | one `tunnel activated, tunnels=1` per side, zero `tunnelEnded`, heartbeats both ways for the rest of the 150 s |

**Timeline** (audit-stream clocks, both nodes on one host): B browses A 23:59:22.73; A browses B
:23.18; the empty roster consulted on both :23.84; tunnel live :23.85; A drops B's early descriptor
:24.03; B yields :24.22; A auto-grants :24.25; B bootstraps :24.26; B adopts `members=2` :24.32.
**Browse to `derived=2`: 1.6 s.**

One benign ordering artefact, self-healing and worth knowing: B logged `mesh.keyAgreement.rejected
… reason=The record's signer was never admitted to this mesh.` → `mesh.keyAgreement.parked` →
`mesh.keyAgreement.parkedReoffered count=1` — A's key-agreement record reached B before B's ledger
held A's founder admission, was parked, and was re-offered once the ledger was adopted. The audit
names each step; nothing was lost.

#### Run 2 — the double-mint re-dial (`unseeded2-*`): the tunnel killed between the two commits

The design's deadlock (§28.8; the stranger-admission design's third finding) was: both halves mint,
the tunnel drops before `yieldsNewbornMesh` converges them, and the old unconditional meshID equality
refuses every re-dial for the session. The lane produces "the tunnel drops between the two commits"
by **freezing the joiner the instant the founder's driver commits** — a watcher on the founder's
console (`grep -q "committing slot"` at 50 ms) sends `SIGSTOP` to the joiner's process — so the
founder founds alone, then the founder's three missed beats end the tunnel, then `SIGCONT`. Kill by
saved PID; the whole thing is `run2.sh` in the session scratch.

**First attempt — a harness limitation, not the radio.** Freeze at 04:02:29Z; the founder held
`ledger=present derived=1` alone; at 04:03:59Z (+90 s, exactly `intervalSeconds ×
missedBeatsBeforeIdleReap`) the founder logged `tunnelEnded controlStreamEnded … live=true tunnels=0
… NWError error 60` and `slots total=0`; thaw at 04:04:01Z; the joiner logged its own
`tunnelEnded … NWError 61` and `heartbeat datagram refused, falling back … NWError 57`, then
`slots total=0`. **Then both sides re-dialed and re-accepted** — `accepted fb795f343c2954da
sid=655368BA-…` on A, `accepted 1b4fd5b9e6f123e5 sid=6D095D22-…` on B, the same `sid`s as before
because both processes survived — with **A holding a real meshID and a derived roster of one in
which B is a stranger, and B mesh-less (`unboundMeshID`)**. That is the tolerated arm of the meshID
rule firing on both sides: before D-4.3 this exact shape is the matrix's row 4 "Ended" sub-case
(`refused foreignMesh … mesh=00000000-…`). Both slots reached `awaitingProximityCommit` — and
**neither driver committed them**: `PeerSlot.id` is the peer's id, so the re-dialed slot came back
under the same `UUID` with a fresh coordinator, and `MeshFlowDriver`'s once-per-slot `asked:
Set<UUID>` never asked again. Over the 180 s the pair sat there, the joiner dropped nine of the
founder's coordinator beacons — `mesh.groupKey.droppedUncommittedSlot` ×9 — which is Option 1b's
commit gate observed live on a provisional slot. On the product path a user re-commits by dwell or
tap; the harness stood in for the first commit and not the second. **Fix:** the dedupe is keyed on
the coordinator instance (`ObjectIdentifier`) and pruned to the live set each poll (committed with
this section). Rebuilt, reinstalled, re-run.

**Second attempt — PASS.**

| Check | Required | Result | Evidence |
| --- | --- | --- | --- |
| The founder founds ALONE | `derived=1` with the joiner frozen at the gate | **Observed** | A at 04:09:40Z: `committing slot` → `committed=1` → `founder armed=false ledger=present derived=1`; B's last line before the freeze: `slots total=1 committed=0 states=[awaitingProximityCommit]` — whether B's own commit ask had gone out before the freeze is undecidable from the untimestamped console (the run's freeze-instant probe counted 0 `committing slot` lines); what is decidable is that B's audit stream carries no `mesh.keyAgreement.folded` until after the thaw, so B minted for the first time at the re-dial |
| The tunnel dies between the commits | the founder ends it by the heartbeat rule | **Observed** | A at 04:11:10Z (+90 s): `tunnelEnded controlStreamEnded fb795f343c2954da live=true tunnels=0 … NWError error 60`, `slots total=0` |
| Both re-introduce under the tolerated meshID | `accepted` on both, A real-id vs B unbound | **Observed** | after the thaw at 04:11:12Z: B `tunnelEnded … NWError 60` + `heartbeat datagram refused … NWError 57` → `slots total=0`; then A `accepted fb795f343c2954da sid=DE68C433-…: tunnel activated, tunnels=1`, B `accepted 1b4fd5b9e6f123e5 sid=B4697812-…: tunnel activated, tunnels=1`; zero introduction refusals (`refused … as responder`) on either node in the whole run — the one `refused` word in the transcripts is the joiner's `heartbeat datagram refused` fallback line |
| The second commit, the second mint, the convergence | both commit; the joiner mints and yields; auto-grant; `derived=2` | **Observed** | both: `committing slot gate=awaitingProximityCommit` (the fixed driver); B audit: `mesh.descriptor.yieldedNewbornMesh adopted=93C7EE35-…` 04:11:15.94 → `abandonedNotDurable` → `sessionCeiling.armedFromAdoptedMesh` → `membershipLedger.bootstrapped` :15.98 → `adopted members=2` :16.05; A audit: `mesh.admissionRequest.autoGrantedFoundingPair` :15.97, `membershipLedger.reGossiped frames=2` :16.03; both consoles: `membership ledger=present derived=2 barred=0 status=active epochRef=1.86a855f8abb18c57a44137320b47976f.1b4fd5b9e6f123e5` |
| Timing | — | **thaw → `derived=2` in 4 s** | 04:11:12Z → 04:11:16.05Z |

**What this shape is, precisely.** At the re-dial A held a real id and B held `unbound`: B's
pre-freeze commit never landed, so B minted for the first time only at the re-dial commit and then
yielded. The design's strongest deadlock — **both** halves holding different real ids at the
re-dial — was not produced on the lane (it needs the second commit to land inside the sub-second
window before the descriptors cross). It rides the **same arm**: `receive` reads
`guard hello.meshID == localHello.meshID || isProvisionalStranger` and the value of either id plays
no part, so real-vs-unbound and real-vs-real are one code path; the real-vs-real case stays pinned at
tier 1 only (`MeshChannelIntroductionTests`' provisional-stranger cells). Also observed on the way:
the re-dial reused both `sid`s (the processes survived) and both endpoints (the Bonjour instance
names are per session, not per tunnel), so the re-propose budget was charged once per side.

**What this lane still cannot say.** Nothing here ran on hardware — the unseeded first meeting
between two phones is the device round's Lane D founder/joiner row, on this build. And the founder
role is **inert on an unseeded run** (`armed=false`, no `admitting`, no `requesting admission`): the
role exists for the seeded shape, and the unseeded shape needs it only to put the harness's fallback
loops on the side that never yields.

Raw logs: the session scratch `lanec/` — `harvest/`, `run1/`, `run2-first-attempt/`, `run2/`
(`founder.log` / `joiner.log` are the `--console-pty` transcripts, `audit-*.log` the audit
streams, and in the two run-2 directories `events.log` the freeze/end/thaw instants); the scripts
`common.sh`, `harvest.sh`, `run1.sh`, `run2.sh` beside them. The banner quoted above reads
`transport=default(quic)` because that is what the build the lane ran on printed; the deletion
commit made the token the constant `transport=quic`, so a re-run at HEAD prints that.

### Lane C — Option 1b: the display name withheld until commit (run 2026-09-22, owner-calls item 2)

**OBSERVED on both nodes: each phone shows the other's FINGERPRINT at the commit gate and its NAME
only after the commit.** The owner's call of the device round (ledger item 3, decision 1), built at
`e83ec82`: nothing a coordinator sends before its own commit carries the local display name, an
identity built from an introduction carries none whatever the peer sent, and the name is adopted
from the first verified post-commit envelope (plan §28.3; `ProximityKit.md` states the invariant).

Build: `e83ec82` plus the DEBUG harness line it carries (`MeshFlowDriver`'s `slots` summary gained
`peers=[…]` — what the join screen shows per slot, `PeerIdentity.displayNameOrFingerprint` — and the
commit line gained `peer=…`). Debug `build-for-testing` bundle, `strings` confirmed both the kit's
`peer display name disclosed after commit` and the driver's `peers=[`; `pgrep -x xcodebuild` empty
for the run. Both apps **uninstalled and reinstalled** first. Nodes — **A** `iPhone 17`
(`09F57BCA-…A88`, fp `b8e515bb773c3239`, new: the uninstall reminted A's identity) as **founder**
(the lower fingerprint), **B** `iPhone 17 Pro` (`454FCC9C-…661B`, fp `fb795f343c2954da`,
unchanged) as joiner; the deletion round's unseeded recipe exactly (no `MATRIX_MEMBERS`, no
`MATRIX_MESH_ID`, `FLOWS=commit`, joiner 3 s after the founder), 120 s, a per-node audit stream
started before each launch and killed by saved PID. Both banners: `no descriptor seeded: roster
stays empty, every peer verdicts stranger`, `transport=quic`; `browsed peers=1` on both — the
concurrent session's Fernlet process on `iPhone 17 Pro Max` (non-matrix) and its two booted
`Fernlet Reconnect` Simulators (no Fernlet running) never entered either browse set.

| Check | Required | Result | Evidence (console, `[mesh-flow]`) |
| --- | --- | --- | --- |
| A sees B by fingerprint at the gate | `peer=<B's fp>` | **Observed** | `committing slot gate=awaitingProximityCommit peer=fb795f343c2954da`; `slots total=1 committed=0 states=[awaitingProximityCommit] peers=[fb795f343c2954da]` |
| A sees B's name after the commit | `peers=[<B's name>]` | **Observed** | `slots total=1 committed=1 states=[connected] peers=[iPhone 17 Pro]` |
| B sees A by fingerprint at the gate | `peer=<A's fp>` | **Observed** | `committing slot gate=awaitingProximityCommit peer=b8e515bb773c3239`; `… states=[awaitingProximityCommit] peers=[b8e515bb773c3239]` |
| B sees A's name after the commit | `peers=[<A's name>]` | **Observed** | `slots total=1 committed=1 states=[connected] peers=[iPhone 17]` |
| The unseeded founding is unaffected | `derived=2`, one epoch head | **Observed** | both `membership ledger=present derived=2 barred=0 status=active epochRef=1.2c69b90da4da29f39abf9e340ec424fc.b8e515bb773c3239`; audit: `legacyRosterFallback members=0` on both at 14:51:28.78, A `autoGrantedFoundingPair` :29.92, B `yieldedNewbornMesh` :29.89 → `bootstrapped` :29.93 → `adopted members=2` :30.00 (introduction to `derived=2` ≈ 1.2 s) |
| No refusal introduced | zero introduction/tunnel refusals | **Observed** | every audit `refused`/`rejected`/`error` line is a known Simulator or ordering artefact: `mesh.continuation.submitRefused … BGTaskSchedulerErrorDomain Code=1` (a Simulator refuses every submission, P10), `health.changeObservationUnavailable`, `brandedCatalog.odr.unavailable`, and B's `mesh.keyAgreement.rejected … never admitted` — the deletion round's benign park-and-reoffer |

**What this run does not show.** The console lines are un-timestamped poll output, so the gap
between the commit and the disclosure is bounded by the driver's poll (one `slots` line to the
next), not measured; the unit cells pin the mechanism (`ProximityCoordinatorTests`: the name
follows on the first post-commit frame, once, from the verified key). The Simulator's `NIRangingSession`
reports hardware support, so both commits were the driver's stand-in for the 15 cm dwell — the
manual-tap branch and a real UWB dwell are the same `confirmPeerIdentity()` and were not driven
separately. A peer on an OLDER build (which still names itself in its introduction) was not run;
`validIdentityIntroductionMovesToUserConfirmation` pins that its name is ignored until commit.

### Lane D — device ↔ simulator, the PRODUCTION mesh over QUIC (specified 2026-09-01, **run 2026-09-21**)

**The shipping transport has never run on hardware.** Lane A puts the *spike* on a device; Lane C
puts the *production* transport between two Simulators. Nothing has yet put `NetworkMeshSession` on
a physical radio, and everything P2 concluded about the production mesh — the rejection matrix, the
idle-timeout fix, single-tunnel convergence, per-transfer streams, the six app flows — was concluded
on two Simulators sharing one host network stack. This lane is the cheapest run that changes that,
and it is the one that answers the question Lane A's `Fail` row left open.

It is Lane C's harness with one instance moved onto a phone. No new switches, no new code.

**Run it over Wi-Fi, and check that you did.** The 2026-09-01 Lane A run crossed the iPhone-USB
tether without anyone noticing until the addresses were read afterwards, which cost that run every
Wi-Fi and AWDL row it might otherwise have earned. Two minutes of setup avoids repeating it:

1. Xcode → Window → **Devices and Simulators** → select the phone → tick **Connect via network**.
   Wait for the globe icon.
2. **Unplug the cable.** With it attached, `en9` exists and Bonjour will happily prefer it.
3. Mac and phone on the same non-isolated Wi-Fi, no VPN, no client isolation.
4. Confirm afterwards: `ifconfig | grep -c en9` should print `0`, and the run's ready line should
   name a routable or `%en0`-scoped address — never `%en9`.

#### Step 1 — read each side's signing key

`FERNLET_MESH_MATRIX=1` makes each instance print its own identity on launch, and the roster in
step 2 is just those two keys handed to both sides. The Fernlet signing identity is keychain-backed
and stable across launches, so this is done once per install, not once per run.

Simulator side:

```
xcrun simctl install <sim-udid> <DerivedData>/Build/Products/Debug-iphonesimulator/Fernlet.app
SIMCTL_CHILD_FERNLET_MESH_MATRIX=1 \
xcrun simctl launch --console-pty <sim-udid> MBO.Fernlet -completeOnboarding
```

Device side — Xcode → Product → **Scheme → Edit Scheme… → Run → Arguments**, then:

- *Environment Variables*: `FERNLET_MESH_MATRIX` = `1`
- *Arguments Passed On Launch*: `-completeOnboarding`

Run on the device and read Xcode's console. Both sides print one line:

```
[mesh-matrix] identity fingerprint=<16 hex> signingKey=<base64 Ed25519 public key>
```

Copy both `signingKey=` values. That is the whole of "getting the device's key into the Simulator's
roster fixture" — there is no fixture file, no keychain export, and nothing to copy off the phone but
a public key that the harness prints for you.

#### Step 2 — run both sides in one seeded mesh

Pick any UUID for `<mesh-uuid>` and use the **same one on both sides**; likewise the members list,
which is `<device-key>,<sim-key>` in either order on both sides.

Simulator side:

```
SIMCTL_CHILD_FERNLET_MESH_TRANSPORT=quic \
SIMCTL_CHILD_FERNLET_MESH_MATRIX=1 \
SIMCTL_CHILD_FERNLET_MESH_CONSOLE_LOG=1 \
SIMCTL_CHILD_FERNLET_MESH_MATRIX_LABEL=laneD-wifi \
SIMCTL_CHILD_FERNLET_MESH_MATRIX_MESH_ID=<mesh-uuid> \
SIMCTL_CHILD_FERNLET_MESH_MATRIX_MEMBERS=<device-key>,<sim-key> \
SIMCTL_CHILD_FERNLET_MESH_FLOWS=commit,capabilities,chat,photo,shop \
xcrun simctl launch --console-pty <sim-udid> MBO.Fernlet -completeOnboarding
```

Device side — the same seven variables in the scheme's *Environment Variables*, without the
`SIMCTL_CHILD_` prefixes (that prefix is only how `simctl` forwards a variable into a Simulator's
child process; Xcode sets them on the device process directly):

| Variable | Value |
| --- | --- |
| `FERNLET_MESH_TRANSPORT` | `quic` |
| `FERNLET_MESH_MATRIX` | `1` |
| `FERNLET_MESH_CONSOLE_LOG` | `1` |
| `FERNLET_MESH_MATRIX_LABEL` | `laneD-wifi` |
| `FERNLET_MESH_MATRIX_MESH_ID` | `<mesh-uuid>` — identical to the Simulator's |
| `FERNLET_MESH_MATRIX_MEMBERS` | `<device-key>,<sim-key>` — identical to the Simulator's |
| `FERNLET_MESH_FLOWS` | `commit,capabilities,chat,photo,shop` |

Grant **Local Network** access when the phone prompts — the Simulator never shows that prompt, so
this is the first time the lane sees it, and refusing it looks exactly like a dead radio.

Let it run **at least 4 minutes**. Three minutes is the floor for anything meaningful: the first
heartbeat is due at 30 s, the declared idle timeout is 90 s, and the question this lane exists to
answer is what happens *after* one of those expires.

#### What to read out of the two transcripts

Both sides echo under `[mesh-quic]` (the radio) and `[mesh-flow]` (the driver). The rows below are
what to fill in; the first four are Lane C results being re-asked on a physical radio, and the last
two are new questions only this lane can answer.

| Check | Required result | Result | Date |
| --- | --- | --- | --- |
| Wi-Fi path | The ready/activation lines name a routable or `%en0`-scoped address, and `en9` does not exist. This is the row the 2026-09-01 run could not earn | **PASS** — both ends `interface: en0[802.11], uses wifi`, peer addresses `%en0`-scoped link-local; `en9` absent at every preflight; `awdl0` never appears (runs 2–4) | 2026-09-21 |
| Local Network permission | The phone prompts once, and the mesh comes up after it is granted | **PASS, the granted half** — no prompt appeared (the earlier device runs' grant stood, as the 2026-09-02 note predicted) and the mesh came up 6–8 s after launch; "prompts once" is not re-observable on this phone | 2026-09-21 |
| Accepted baseline on hardware | `accepted <fingerprint> sid=…: tunnel activated, tunnels=1` on both sides | **PASS** — `accepted <fp> sid=…: tunnel activated, tunnels=1` on both sides, every run, 6–8 s after the phone's launch, fingerprints and `sid`s matching end to end | 2026-09-21 |
| Tunnel stability | One activation per side and **zero** `tunnelEnded` lines across ≥ 4 minutes, with `idleTimeoutMs=90000 beatSeconds=30` on the `datagramCapacity` line | **PASS** — run 3: one activation per side and **0** `tunnelEnded` across **5 min 8 s**, `idleTimeoutMs=90000 beatSeconds=30` on both `datagramCapacity` lines (run 2: 0 across 3 min 29 s) | 2026-09-21 |
| Heartbeat + datagram flow | `heartbeat sending over datagram` and `heartbeat received over datagram` on both sides at 30 s spacing — the item-15 result, on a physical radio | **PASS** — `heartbeat sending/received over datagram` on both sides at 30 s spacing (9/9 each side in run 3, 6/6 in run 2), zero fallbacks — with `datagramCapacity usable=0` on the line above them | 2026-09-21 |
| App flows | Slot commit, capabilities, chat both ways, a photo on a per-transfer stream, shop catalogue — the item-10 table, on a physical radio | **PASS, in the P6 shape (run 4)** — slot commit, capabilities and the shop catalogue both ways in every run; text and photo need `FERNLET_MESH_ROLE=founder|joiner` + `FLOWS_AFTER` (the routed mint wants a derived roster — see *Run 4* below): with them `chat received=1 sent=1` on both sides and the photo on per-transfer streams both ways, manifests, chunks, custody and recipient receipts drain-admitted. Under the table's seven variables alone (runs 2–3): `noDestinations` on both, by design, no `transfer` line | 2026-09-21 |
| **Reconnect after a real idle timeout** | Kill one side (stop the Xcode run, or `xcrun simctl terminate <sim-udid> MBO.Fernlet`), wait > 90 s, restart it: the survivor's listener accepts the re-dial and a tunnel re-forms | **PASS, twice** — terminate: the survivor saw `controlStreamEnded` in 1 s and re-accepted 5 s after the relaunch; freeze (`SIGSTOP`): `localEviction` at +89 s, re-accepted 2 s after the relaunch. The transport's own `idleTimeout` cause is unreachable — the app's three-missed-beats eviction wins at 90 s | 2026-09-21 |
| **No NECP flow leak** | The survivor's console shows **no** `NECP_CLIENT_ACTION_ADD_FLOW … [17: File exists]` and no `Failed to create connection from listener` after the peer's tunnel ends | **FAIL on the letter, PASS on the consequence** — the exact Lane A signature (`NECP_CLIENT_ACTION_ADD_FLOW … [17: File exists]` → `Failed to create connection from listener`) on the survivor at every re-dial, 2 of 2, but only on the FIRST inbound flow; the next flow 70 ms later formed the tunnel, with zero app-level retries. Present, non-fatal, no production fix | 2026-09-21 |

The last two rows are the point of the lane. They are the residual from Lane A's `Fail`: the probe
could not answer them because it ends its whole run — listener included — on the first tunnel error,
whereas `NetworkMeshSession.endTunnel` ends one tunnel and keeps listening. If they come back clean,
the `EEXIST` cascade is confirmed probe-only and needs no production fix. If the survivor's listener
*does* refuse the re-dial, the fault is real in the shipping transport on a link-local peer-to-peer
path, and the fix candidates are, smallest first: re-listen on a fresh port after a tunnel ends
(`updateDiscoveryInfo` already has the stop-and-recreate shape), or drop `peerToPeerIncluded` from
the listener parameters and keep it only on the dialing side. Do not plan on "cancel the stale
connection" — `NetworkConnection` has no `cancel()` in the iOS 26 API.

#### First run, 2026-09-21 — the production transport on a physical radio

**Environment.** `main` = `08898be` (the P10 close-out), rebuilt for this lane in a fresh worktree DerivedData
(`xcodebuild build -scheme Fernlet -configuration Debug`, once for `platform=iOS,id=<udid>` with automatic
signing and once for the `iPhone 17` Simulator; `** BUILD SUCCEEDED **`, zero `error:`, both), installed fresh
on both nodes. Phone: the owner's **iPhone 17 Pro Max** (`iPhone18,2`, iOS **26.6.1**, fp `5c73ce4c29dc84be`).
Simulator: **iPhone 17** (`09F57BCA-…A88`, iOS 26.5, fp `f94dc321944600d7`). Mac: Xcode **26.5**, Wi-Fi on
`en0` (a CGNAT `100.110.200.0/26`, IPv6 global + link-local). No `xcodebuild` ran during any run. A host
`log stream` for the Simulator's `Fernlet` process (`com.fernlet` + `com.apple.network`) ran as the second
witness on every run; on the phone the second witness is `OS_ACTIVITY_DT_MODE=YES` in the launch environment,
which mirrors the process's own `os_log` — audit contexts included, **in the clear** — into the
`devicectl … --console` transcript.

**How the phone was driven — the runbook's Xcode-scheme step, without Xcode.**

```
xcrun devicectl device process launch --device <coredevice-uuid> --terminate-existing --activate --console \
  --environment-variables '{"OS_ACTIVITY_DT_MODE":"YES","FERNLET_MESH_TRANSPORT":"quic",…}' \
  MBO.Fernlet -- -completeOnboarding
```

Three things about that line cost a launch each to learn. (1) **The `--` is load-bearing:** without it
`devicectl` parses `-completeOnboarding` as its own short flags and dies on `Missing value for '-l <path>'`
before the app starts. (2) **Killing the `--console` process kills the app** — so the phone can only ever be
the *survivor* of a reconnect row, and the Simulator is the side that dies and re-dials. (3) **The wireless
step is not a checkbox any more:** with the cable out the phone read `unavailable` for two minutes and
advertised no `_apple-mobdev2._tcp` / `_remoted._tcp` on the LAN; plugging back in and unplugging again
brought it up as `transportType: localNetwork` within seconds, and every run below was launched over that.
Check it before the run: `xcrun devicectl device info details --device <id> | grep transportType` must say
`localNetwork`, and `ifconfig | grep -c en9` must print `0`.

**A Simulator that shuts itself down.** `09F57BCA` was `Booted` at session start, dropped to `Shutdown`
during the first `simctl install` (`Mach error -308 (ipc/mig) server died`), was rebooted, and was `Shutdown`
again ten minutes later with nothing touching it — the first paired launch went out phone-only against it.
Every run below starts with `simctl list devices | grep <udid> | grep Booted` in the preflight, and
`launch-sim.sh` terminates and relaunches; treat a long-booted Simulator as suspect (§28.2 already says so).

**The runs.** All seeded from the same two keys, each under a fresh mesh id and label; Simulator launched
first, phone 3 s later; witness started before either.

| Run | Label · variables beyond the seven | Window | Tunnels | `tunnelEnded` in window | Heartbeats (sent/recv, datagram) | Reconnect variant |
| --- | --- | --- | --- | --- | --- | --- |
| 2 | `laneD-wifi` · none (the table's seven exactly) | 16:22:15Z → sim killed 16:25:50Z, **3 min 29 s** live | 1 each side, up 6 s after the phone's launch | **0** / **0** | 6/6 · 6/6 | `simctl terminate` the Simulator, 100 s, relaunch |
| 3 | `laneD-wifi-after25` · `FERNLET_MESH_FLOWS_AFTER=25` | 16:28:24Z → 16:33:32Z, **5 min 8 s** live | 1 each side, up 8 s after launch | **0** / **0** | 9/9 · 9/9 | `SIGSTOP` the Simulator's process, 110 s, resume + relaunch |
| 4 | `laneD-wifi-founder` · `FLOWS_AFTER=60`, `FERNLET_MESH_ROLE=founder` (Simulator) / `joiner` (phone) | see below | | | | none — the routed-flow run |

**What crossed, on the physical radio.** Both sides `browsed peers=1` for the other's
`_fernlet-mesh2._udp` name; `accepted <fp> sid=…: tunnel activated, tunnels=1` on both, fingerprints and
`sid`s matching end to end; `datagramCapacity usable=0 requested=1024 required=22 idleTimeoutMs=90000
beatSeconds=30` on both — and, `usable=0` notwithstanding, **every heartbeat went over the datagram
channel both ways at 30 s spacing** with zero `heartbeat datagram refused` fallbacks (item 15's result, on
hardware; the accessor is the one P2 already found misleading). `capabilities peer=[…]` both ways (the
phone advertises `friendState`, `hearts`, `heartsAway` that the fresh Simulator does not); `shop
peerCatalogs=1` both ways. Zero `dial refused`, zero `inbound tunnel refused`, zero `redundantTunnelClosed`.
**The mesh came up without a Local Network prompt** — the grant from the earlier device runs was still in
force, exactly as the 2026-09-02 note predicted — so the "prompts once" half of that row is not re-observed
here; the "comes up after it is granted" half is, in 6–8 s.

**The Wi-Fi path, proven from both ends.** Host witness for the Simulator's process: every QUIC flow reads
`interface: en0[802.11], uses wifi`, peer `fe80::4f5:3025:4e7c:e39%en0` (the phone's link-local, scoped to
the Mac's Wi-Fi); the phone's own `nw_flow_notify` lines read `fe80::1014:f09:7235:7f56%en0.55009 …
interface: en0[802.11]` (the Mac's link-local, scoped to the phone's Wi-Fi). `awdl0` appears **zero** times
on either side — this was infrastructure Wi-Fi, not peer-to-peer — and `ifconfig | grep -c en9` printed `0`
at every preflight. The cable contributed nothing.

**The reconnect rows — both variants, same answer, same surprise.**

- *Terminate* (run 2): the phone saw the Simulator go within a second — `tunnelEnded controlStreamEnded
  f94dc321944600d7 live=true tunnels=0` — kept its listener, and when the Simulator relaunched 100 s later it
  re-accepted (`tunnel activated, tunnels=1`, phone `activated` 1 → 2) **5 s** after the relaunch.
- *Freeze* (run 3, `SIGSTOP` so nothing closes cleanly): the phone ended the tunnel itself at **+89 s** —
  `tunnelEnded localEviction … This peer's slot was evicted locally` — i.e. the app-layer heartbeat eviction
  (three missed 30 s beats) fires at the same instant as the transport's 90 s idle timeout and wins the race,
  so the transport's own `idleTimeout` cause was **not** observed and cannot be on a live-but-silent peer.
  Relaunch at +113 s; re-accepted **2 s** later, phone `activated` 1 → 2.
- **The NECP `EEXIST` from Lane A is real on the shipping transport, and it is absorbed.** Both times, the
  first inbound flow of the re-dial was refused at the phone's listener with the exact 2026-09-01 signature —
  `nw_path_evaluator_create_flow_inner NECP_CLIENT_ACTION_ADD_FLOW … [17: File exists]` →
  `nw_endpoint_flow_failed_with_error` → `nw_connection_create_from_protocol_on_nw_queue [C8] Failed to
  create connection from listener` — and the **next** inbound flow, 70 ms later (`[C9]`), was the one the
  tunnel formed on. The Simulator's transcript shows **zero** `introductionFailed`, zero `gave up`, zero
  `dial refused`: the retry happened below the app (the QUIC client's handshake retransmit reached the
  listener as a fresh flow), so no retry budget was spent. Lane A's probe died on this because it ends its
  listener on the first error; `NetworkMeshSession.endTunnel` keeps listening, and that is the whole
  difference. **No production fix is needed for the cascade; the row is recorded as "present, non-fatal,
  one refused flow per re-dial".**

**The app-flow rows, and the variable the 2026-09-01 table is missing.** Under the seven variables exactly
(run 2) *and* with `FLOWS_AFTER=25` (run 3), `chat outcome=noDestinations` on both sides and
`mesh.routedShare.skipped … reason=noDestinations type=friendPhoto` for the photo — no `transfer` line ever.
This is not a radio result: since P6 both text and photos are **routed** items, the routed mint needs a
**derived roster** (`membershipVerifier?.roster`), and a seeded pair with `FERNLET_MESH_ROLE` unset never
builds one (`membership ledger=absent derived=0` all run, as the P9 item-0 note says a seeded run must).
P6's text run earned `staged` with `ROLE=founder|joiner` **plus** `FLOWS_AFTER`; the Lane D table predates
both. Run 4 is that shape.

**Run 4 — the routed flows, in the P6 shape.** `FERNLET_MESH_ROLE=founder` on the Simulator, `joiner` on
the phone, `FLOWS_AFTER=60` on both (≈ 60 s here: both nodes polled at ≈ 1 Hz, the Simulator being shown by
Simulator.app rather than headless — P6's 0.3 Hz was the headless rate). Tunnel at +6 s. The phone
`requesting admission asked=true` → `membershipRecord fernlet.mesh.member-admission.v1 accepted` →
`membership ledger=present derived=2 barred=0 status=active`; the founder `mesh.membershipLedger.reGossiped
frames=2` at +11 s. At the 60-poll mark (+65 s) both sides `chat outcome=staged` and
`mesh.routedShare.pushed frames=2` (text) then `frames=3` (photo); `chat received=1 sent=1` on both;
`photos received=1` on the Simulator, 21 → 22 on the phone. Per-transfer streams, byte-exact on the far
side: Simulator → phone `transfer sent bytes=474433 stream=1` and `bytes=160623 stream=5`; phone → Simulator
`bytes=474566 stream=4` and `bytes=160715 stream=8`. The Simulator's audit stream drain-admitted
`routed-manifest.v1` ×2, `routed-chunk.v1` ×3, `custody-receipt.v1` ×2, `recipient-receipt.v1` ×2, then
`routedStore.swept` ×2. Transport over the same 5 min 7 s: **0** `tunnelEnded`, 9/9 heartbeats over datagrams
each side, zero NECP lines (no re-dial in this run). P6's text rows 2–5 and 7, on a physical radio, plus the
photo the item-10 table asked for.

**Not run here, still owed.** Anything backgrounded or locked (§15.1 — this was one phone, foreground, on
infrastructure Wi-Fi), AWDL (`awdl0` never carried a flow — the phone and Mac shared a LAN, so
infrastructure won the path race every time; a peer-to-peer-only row needs the Mac off the phone's network),
the Simulator-survivor direction of the reconnect rows (killing the phone's `--console` kills the app, so
the phone was always the survivor), and a real `idleTimeout` cause, which the app's eviction pre-empts.


#### The device round's item 1 — the UNSEEDED first meeting on hardware (run 2026-09-22)

**The QUIC first-meeting capability is OBSERVED on a physical radio.** The owner's phone and a
Simulator, with **no** `FERNLET_MESH_MATRIX_MEMBERS`, **no** `FERNLET_MESH_MATRIX_MESH_ID` and nothing
persisted between them, found a mesh through the provisional path over a real QUIC tunnel on
infrastructure Wi-Fi with the cable out, converged to `derived=2` under one epoch head in about
**1.4 s** from browse, and — the tunnel killed between the two commits — re-introduced under the
tolerated meshID and converged again **≈4 s** after the thaw. This is the hardware half of the
deletion round's item 0 (*Lane C — the deletion round's item 0* above), on the build that has no
MultipeerConnectivity in it. Three runs: run 1 with the harness roles inverted by a script bug
(passed anyway), run 1b with the roles as the recipe says (the record), run 2 the re-dial.

**Environment.** `main` = `d88062c` (the deletion round's close), rebuilt for this lane into a fresh
DerivedData — `xcodebuild build -scheme Fernlet -configuration Debug` once for
`platform=iOS,id=<udid>` with automatic signing (15:14:05Z → 15:15:25Z) and once for the Simulator
(15:17:09Z → 15:18:02Z), `** BUILD SUCCEEDED **`, zero `error:`, both — installed fresh on both nodes
(`devicectl device install app` 15:17:23Z; `simctl install` 15:20:48Z). Phone: the owner's
**iPhone 17 Pro Max** (iOS **26.6.1**, fp `5c73ce4c29dc84be` — unchanged from Lane D and
§15.5, keychain-backed across the reinstall). Simulator: **iPhone 17 Pro** (`454FCC9C-…661B`, iOS 26.5,
fp `fb795f343c2954da` — unchanged since P9 and the deletion round). Mac: Xcode 26.5. The phone on
`transportType: localNetwork` with the cable out (`en9 present = 0` at every preflight), `awdl0` never
carrying a flow. No `xcodebuild` and no `xctrace` during any run (both counted in the preflight).
Witnesses: the phone's `devicectl … --console` transcript with `OS_ACTIVITY_DT_MODE=YES` (the
`[mesh-quic]` / `[mesh-flow]` console AND the audit contexts in the clear, stamped by the phone's
clock); the Simulator's `simctl spawn … log stream --predicate 'subsystem == "com.fernlet"'` (audit,
the Mac's clock); a host `log stream` for the Simulator's `Fernlet` process (`com.apple.network` —
interfaces and NECP). Streams started before each launch and killed by saved PID after it.

**The phone must be unlocked and awake, by the owner's hand.** The first launch of the day, with the
phone locked, was refused by SpringBoard before the app started: `FBSOpenApplicationErrorDomain
error 7 (Locked)` — *"Unable to launch MBO.Fernlet because the device was not, or could not be,
unlocked"*. `devicectl` has no unlock; every run below carries `passcodeRequired=false` in its
preflight because the owner unlocked the phone and kept it awake for the eleven minutes the three
runs took (15:22:13Z preflight → 15:33:24Z window end). The refused launch's transcript is kept as
`lane/harvest/phone-locked-15-18-43Z.txt` (a verbatim copy of the terminal — the second, successful
harvest overwrote `harvest/phone.log`). Add it to the walls: **a locked phone is a refused launch, not a dead radio.**

**The recipe — Lane C's unseeded pair launch with one node moved onto the phone.** The founder role
goes on the **lower fingerprint** (`foundsPairwiseMesh(local:peer:)` is `local < peer`), which here
is the phone (`5c73…` < `fb79…`), and that is also the only workable assignment for the re-dial:
killing the phone's `--console` process kills the app, so the phone can only ever be the survivor and
the Simulator the side that is frozen. Phone side (the Xcode-scheme step, without Xcode):

```
xcrun devicectl device process launch --device <coredevice-uuid> --terminate-existing --activate --console \
  --environment-variables '{"OS_ACTIVITY_DT_MODE":"YES","FERNLET_MESH_MATRIX":"1","FERNLET_MESH_CONSOLE_LOG":"1",
                            "FERNLET_MESH_MATRIX_LABEL":"hw-run1b-founder","FERNLET_MESH_FLOWS":"commit","FERNLET_MESH_ROLE":"founder"}' \
  MBO.Fernlet -- -completeOnboarding
# Simulator, 3 s later: the same five FERNLET_ variables under SIMCTL_CHILD_, LABEL=hw-run1b-joiner, ROLE=joiner
SIMCTL_CHILD_FERNLET_MESH_MATRIX=1 SIMCTL_CHILD_FERNLET_MESH_CONSOLE_LOG=1 SIMCTL_CHILD_FERNLET_MESH_MATRIX_LABEL=hw-run1b-joiner \
SIMCTL_CHILD_FERNLET_MESH_FLOWS=commit SIMCTL_CHILD_FERNLET_MESH_ROLE=joiner \
xcrun simctl launch --console-pty <sim-udid> MBO.Fernlet -completeOnboarding
```

No `FERNLET_MESH_TRANSPORT` — the variable no longer exists (`ec05b0c`); the banner reads
`transport=quic` on both. The banner's second line reads `no descriptor seeded: roster stays empty,
every peer verdicts stranger` on both.

##### Run 1b — the unseeded founding (`hw-run1b-*`, 150 s; phone launched 15:25:27Z, Simulator 15:25:30Z)

| Check | Required | Result | Evidence |
| --- | --- | --- | --- |
| The roster consulted at the introduction is EMPTY on both sides | `members=0` | **Observed** | phone audit `mesh.introductionAuthority.legacyRosterFallback members=0` at 11:25:32.385 (phone clock); Simulator audit the same at 11:25:32.329 (Mac clock) |
| `admitsStrangersProvisionally` answers the introduction on a physical radio | a tunnel where P2's matrix row 1 recorded `refused unknownIdentity … rosterMembers=0` | **Observed — ACCEPTED both ways** | phone: `[mesh-quic] accepted fb795f343c2954da sid=BBC5EE83-…: tunnel activated, tunnels=1`; Simulator: `accepted 5c73ce4c29dc84be sid=57FFABC9-…: tunnel activated, tunnels=1`. Zero introduction refusals on either node (`refused … as responder`, `inbound tunnel refused`, `dial refused` all 0). The one "refused" word in the phone's transcript is libnetwork's `failed with error Connection refused` on a **global-IPv6** candidate flow (`[C4] 2605:ad80:…`), 0.4 ms after the same connection's `[quic] … TLS error (security error 61) (state failed)` — a candidate flow on the routed global-IPv6 path that failed at TLS and then reported refused; the transcript does not name the flow the tunnel formed on. Not an introduction refusal |
| The identity introduction, then the commit | slot at the gate, then `connected` | **Observed** | phone: `committing slot gate=awaitingManualCommit` → `slots total=1 committed=1 states=[connected]`; Simulator: `committing slot gate=awaitingProximityCommit` → `connected`. The two sides sat at **different gates** in every run — the phone's slot at `awaitingManualCommit`, the Simulator's at `awaitingProximityCommit` — and the driver commits either (both are the coordinator's pre-commit states, `ProximityCoordinator.swift:611-612`). Recorded, not interpreted here |
| `promoteToMesh` on the first commit — both halves mint, the double mint repaired | a descriptor on each side, one survives | **Observed — the OTHER arm from the Simulator lane.** The phone (founder, lower fingerprint) committed **first** (`mesh.keyAgreement.folded held=7F746521-…` at :32.854) and, when the Simulator's newborn descriptor arrived, **dropped it and re-announced its own**: `mesh.descriptor.droppedForeignMesh held=7F746521-… offered=EA665D1D-…` + `mesh.descriptor.reannouncedToNewbornPeer` at :33.285. The Simulator: `mesh.meshDescriptor.droppedUncommittedSlot` at :32.998 (the phone's descriptor arrived while the Simulator was still uncommitted — the commit-timing race), then folded its own `EA665D1D-…` at :33.148, then `mesh.descriptor.yieldedNewbornMesh adopted=7F746521-…` at :33.232 → `mesh.session.abandonedNotDurable` → `mesh.sessionCeiling.armedFromAdoptedMesh`. In the Simulator lane's run 1 the LATER committer dropped the early descriptor uncommitted; here the earlier committer dropped the foreign one and re-announced. Both arms end in one mesh, the founder's | 
| The admission request, auto-granted | a grant with no owner tap and no harness grant | **Observed — the shipping auto-grant** | phone audit `mesh.admissionRequest.autoGrantedFoundingPair` :33.325, `mesh.membershipLedger.reGossiped frames=2` :33.425; Simulator `[mesh-quic] membershipRecord fernlet.mesh.member-admission.v1 accepted`, audit `mesh.membershipLedger.bootstrapped` :33.280, `mesh.membershipLedger.adopted members=2` :33.394. **The harness fallbacks were silent:** phone `founder armed=false ledger=present derived=2`, no `admitting …` line; no `requesting admission` on the Simulator |
| `derived=2` on both, one epoch head | both `[mesh-flow] membership ledger=present derived=2` | **Observed** | both consoles: `membership ledger=present derived=2 barred=0 status=active epochRef=1.83eb0a4bce97761e7f307a99fda9361d.5c73ce4c29dc84be` — the phone, the lower fingerprint, is the coordinator named inside the ref |
| Stability | one activation per side, no ends | **Observed** | one `tunnel activated, tunnels=1` per side, **0** `tunnelEnded`, `datagramCapacity usable=0 requested=1024 required=22 idleTimeoutMs=90000 beatSeconds=30` on both, **4/4** heartbeats over datagrams each way in the 150 s window (the console lines are untimestamped; the spacing is the declared `beatSeconds=30`, four beats spanning ≈90 s), zero `heartbeat datagram refused` |
| Wi-Fi path | flows on `en0`, `en9` absent, `awdl0` absent | **Observed** | host witness for the Simulator's process (the dialer in this run): 89 lines `interface: en0[802.11], uses wifi`, `en9` 0, `awdl0` 0 — this run's witness names no peer address. In runs 1 and 2, where the Simulator was the listener, its witness reads `[C1 fe80::4f5:3025:4e7c:e39%en0.… quic, local: fe80::1014:f09:7235:7f56%en0.…]` — the phone's link-local and the Mac's, both `%en0`-scoped |

The Simulator lane's key-agreement artefact reproduced exactly: the Simulator logged
`mesh.keyAgreement.rejected … The record's signer was never admitted to this mesh.` → `parked` →
`parkedReoffered count=1` → `folded` at :33.36–:33.39, the phone's record reaching it before its
ledger held the phone's founder admission. Self-healing, nothing lost.

**Timeline** (each line on the clock of the device that wrote it; the two clocks agree to ≈60 ms on
the roster line both sides log at the same handshake): the Simulator `browsed peers=1` at 11:25:32.00; the phone `browsed peers=1` :32.22; the empty roster consulted on
both :32.33/:32.39; tunnel :32.39; the phone commits :32.85; the Simulator drops the phone's early
descriptor :33.00, folds its own :33.15, yields :33.23; the phone drops the foreign one and
re-announces :33.29, auto-grants :33.33; the Simulator bootstraps :33.28, adopts `members=2` :33.39.
**Browse to `derived=2`: ≈1.4 s** — anchored on the Simulator's browse (:32.00) → the Simulator's `adopted members=2` (:33.39); from the phone's browse (:32.22) it is ≈1.2 s. The phone's own `derived=2` console line is untimestamped, so "on both" is pinned on the Simulator side and read on the phone's. Launch to tunnel: 2.4 s after the Simulator's launch.

**The NECP `EEXIST`, on a FIRST dial this time.** The phone's transcript carries Lane A's exact
signature at the first inbound flow of the run — `nw_path_evaluator_create_flow_inner
NECP_CLIENT_ACTION_ADD_FLOW … [17: File exists]` → `[C2] Failed to create connection from listener`
at 11:25:32.15 — and the next flow, within the same second, formed the tunnel; zero
`introductionFailed`, zero `gave up`, zero `dial refused`. Lane D recorded it only on re-dials
(2 of 2); here it appeared on the first dial of run 1b and on neither dial of runs 1 and 2. Still
present, still non-fatal, still absorbed below the app.

##### Run 1 — the same founding with the harness roles inverted (`hw-unseeded1-*`, 150 s) — passed; recorded because it happened

The lane's own script carried `roles` into a pipeline (`{ preflight; roles; } | tee …`), so the
variables it set died with the subshell and the launch order fell through to the other branch:
the **founder** role went on the **Simulator** (the HIGHER fingerprint — the half the shipping code
makes yield) and the joiner role on the phone. The deletion round declined to run exactly this
configuration because the harness's founder loop on the yielding half could race the yield
(`armFounderLedgerForHarness()` guards on `membershipVerifier == nil`, the yielder's state between
`unwindNewbornMesh()` and the grant). One sample says it did not bite: the same chain crossed —
Simulator `droppedUncommittedSlot` 11:22:22.51, `yieldedNewbornMesh adopted=0BF41BE2-…` :23.17;
phone `droppedForeignMesh` + `reannouncedToNewbornPeer` :23.21, `autoGrantedFoundingPair` :23.28,
`reGossiped frames=2` :23.30; Simulator `bootstrapped` :23.22, `adopted members=2` :23.27; both
`derived=2` under `1.1e1b57f4ef6613049e2f210ab07dcebb.5c73ce4c29dc84be`; **≈1.0 s** from the phone's
browse (:22.25); 0 `tunnelEnded`, 4/4 heartbeats each way, 0 NECP lines. The founder loop on the
yielding Simulator printed `founder armed=false ledger=present derived=2` — the shipping founding had
already produced the ledger by the driver's next poll, so the role stayed inert on this side too.
**Not the record** — run 1b is — but one more data point that the roles are inert on an unseeded run.
The script fix: call the function outside any pipeline (`preflight | tee …; roles | tee -a …; roles
>/dev/null`).

##### Run 2 — the double-mint re-dial on hardware (`hw-unseeded2-*`): the tunnel killed between the two commits

The shape is the Simulator lane's: a watcher on the **phone's** console sends `SIGSTOP` to the
Simulator's process the instant the phone's driver commits (`grep -q "committing slot"` at 50 ms),
so the phone founds alone; the dead tunnel ends; `SIGCONT`; watch the re-dial converge. The
Simulator is the frozen side because it must be (above). Phone launched 15:28:21Z, Simulator
15:28:24Z; **freeze 15:28:26Z** (Mac clock, the watcher) — the watcher counted **0** `committing slot`
and **0** `membership ledger=present` lines on the Simulator's console at that instant, and the
Simulator's audit stream carries no mint and no commit before the thaw (its `legacyRosterFallback
members=0` at 11:28:26.148 is the last mesh line before 11:30:19; the first `keyAgreement.folded` is
at 11:30:22.422), so it minted for the first time at the re-dial.

| Check | Required | Result | Evidence |
| --- | --- | --- | --- |
| The founder founds ALONE | `derived=1` with the joiner frozen at the gate | **Observed** | phone: `committing slot gate=awaitingManualCommit` → `committed=1 states=[connected]` → `founder armed=false ledger=present derived=1 barred=0 status=active`; then `states=[discovering]` while it waited |
| The tunnel dies between the commits | the survivor ends it | **Observed — ended by the TRANSPORT at +111 s** (`controlStreamEnded`, NWError 60: the idle timeout by its token, 111 s against `idleTimeoutMs=90000`) | phone at 11:30:17.25: `tunnelEnded controlStreamEnded fb795f343c2954da live=true tunnels=0 … The outbound QUIC tunnel ended: … (Network.NWError error 60 - Operation timed out)`, `slots total=0`, after **three** unanswered `heartbeat sending over datagram` lines. No `localEviction` line. Compare Lane D's freeze row, where a **beating** link three minutes old saw the app's `tunnelEnded localEviction` at +89 s, and the Simulator lane's run 2, where a link frozen at the commit ended with this same `controlStreamEnded` / error 60 token at +90 s (that record calls it the three-missed-beats rule; the token is the transport's). On hardware the link frozen at its commit outlived `idleTimeoutMs=90000` by ≈21 s before the transport ended it |
| Both re-introduce under the tolerated meshID | `accepted` on both, phone real-id vs Simulator unbound | **Observed** | thaw 15:30:19Z; the Simulator's own `tunnelEnded controlStreamEnded 5c73ce4c29dc84be … error 60` + `heartbeat datagram refused … error 57` → `slots total=0`; then phone `accepted fb795f343c2954da sid=8B5E4693-…: tunnel activated, tunnels=1` and Simulator `accepted 5c73ce4c29dc84be sid=CA836B5D-…` — **the same `sid`s as before the freeze** on both (both processes survived), phone `activated` 1 → 2; zero introduction refusals on either node in the whole run |
| The second commit, the second mint, the convergence | both commit; the joiner mints and yields; auto-grant; `derived=2` | **Observed** | both `committing slot`; Simulator audit: `droppedUncommittedSlot` ×5 (`meshDescriptor`, `registryPayload` ×2, `membershipEvent`, `routedDrain` — the phone's frames landing on the still-uncommitted re-dialed slot, Option 1b's gate live) at 11:30:22.11, `keyAgreement.folded held=4AD03F8E-…` :22.42 (its own mint), `mesh.descriptor.yieldedNewbornMesh adopted=424F5418-…` :22.54 → `abandonedNotDurable` → `armedFromAdoptedMesh` → `membershipLedger.bootstrapped` :22.589 → `adopted members=2` :22.675; phone audit: `mesh.descriptor.droppedForeignMesh held=424F5418-… offered=4AD03F8E-…` + `reannouncedToNewbornPeer` :22.590, `mesh.admissionRequest.autoGrantedFoundingPair` :22.634, `reGossiped frames=2` :22.695; both consoles `membership ledger=present derived=2 barred=0 status=active epochRef=1.2d0a6d89731c3acbba70372ecfd39fcc.5c73ce4c29dc84be`; heartbeats over datagrams both ways for the 180 s that followed |
| Timing | — | **thaw → `derived=2` in ≈4 s** | 15:30:19Z thaw (Mac) → the Simulator's `adopted members=2` at 11:30:22.675 (Mac clock, +3.7 s); both consoles at `derived=2` by the watcher's next poll at 15:30:24Z (+5 s, the poll's granularity) |

**What this shape is, precisely** — the same as the Simulator lane's: at the re-dial the phone held a
real meshID (`424F5418-…`) and the Simulator held `unbound` (its pre-freeze commit never happened),
so real-vs-unbound is what hardware has now shown; the both-real-ids re-dial rides the same arm and
stays tier-1 only. The re-dial reused both `sid`s and both endpoints. The founder ROLE stayed inert
in all three runs (`armed=false` on whichever side carried it; no `admitting`, no `requesting
admission`) — on an unseeded run it exists only to keep the harness's fallback loops off the yielder.

**What the lane also observed — read back after the record was first written (2026-09-22, the same
day): the continued-processing task is GRANTED on the phone, at every first commit.** Every phone
transcript of this lane — and, re-read now, every Lane D transcript of 2026-09-21 — carries the P8 chain
in full: `mesh.continuation.registered event=meshStarted state=idle` → `registered
id=MBO.Fernlet.mesh-continuation.<meshID>` → `submitted event=firstPeerCommitted state=requested` →
`submitted id=…` → **`mesh.continuation.started event=taskStarted state=running`**, 4–7 ms after the
submission (today 11:22:22.569, 11:25:32.873, 11:28:26.725; on 2026-09-21 12:22:22.166, 12:28:32.957,
12:35:57.252 — six of six). `started` is the coordinator's "the system delivered the task and the app
adopted it": the real `SystemContinuationScheduler` conformer registered, submitted a user-started
`.fail` request from the foreground, and had it delivered. In run 2 the task stayed `running` across the
re-dial (`absorbed event=firstPeerCommitted state=running` at 11:30:22.15; the same on 2026-09-21's
run 2 at 12:27:34.06). No `refused`, no `expired`, no `cancelled`, no `completed` in any transcript —
every run ended by `devicectl … terminate`, which leaves no app-side line. So three of §15's tier-3
rows moved today without anyone asking them to: *Registration accepted* — observed; *A `.fail`
submission granted* — **observed, six of six**; *The launch and expiration handlers firing* — the launch
half observed, the expiration half not (no task has yet run to its budget). Both records that said "no
`BGTaskScheduler` grant of any class has been observed on this phone" — this section's first draft and
*Lane B*'s status paragraph — were wrong about the continuation class and are corrected in place; the
companion-refresh class (§15.5) is still ungranted. What the grant does NOT yet say: whether the task
survives the app leaving the foreground, whether the tunnel outlives it, and whether slow progress
keeps it alive for hours — that is §15.3's soak, F9, which the owner has scheduled for the evening of
2026-09-22 (one phone in normal use, the Simulator holding the far end).

**What this lane still cannot say.** Two *phones*: this was one phone and a Simulator sharing the
Mac's network stack on one side, so §15.1's background-and-lock rows, AWDL, Low Power Mode and the
partition walks are untouched (*Lane B*, dated). The Simulator-survivor direction of the re-dial
(the phone frozen or killed) is unreachable while the phone is driven through `--console`.

Raw logs: the session scratch `lane/` — `harvest/` (both identity lines), `run1-inverted/`,
`run1b/`, `run2/` (`phone.log` the devicectl console with the audit mirror, `sim.log` the
`--console-pty` transcript, `audit-sim.log` the Simulator's audit stream, `witness-sim.log` the host
network witness, `run.txt` the preflight and the launch/tunnel/window stamps, `events.log` in run 2
the freeze/end/thaw instants); the scripts `common.sh`, `harvest-phone.sh`, `harvest-sim.sh`,
`run1.sh`, `run2.sh` beside them. Not in the repo.

### Lane B — physical multi-device and background (deferred to P8; see plan §15)

These rows do not gate P1 or P2. They gate **shipping background continuation**, and they are
carried out on 2–4 physical devices per plan §15.1–15.4.

**First hardware datum, and the caveat that comes with it (2026-09-02):** iOS ended the probe's
continued-processing task ≈ **46 s** after it started, shortly after the app was backgrounded, with
the fail-immediately strategy — one sample, see *Lane A — owner runs 2026-09-02* above. It does not
move the **Background operation** row, because the probe **tears its own tunnel down when the task
ends**; answering "does an established connection survive backgrounding?" needs a variant that keeps
the tunnel and keeps logging past task expiry, and building it is part of P8.

**Status at the P8 close-out (2026-09-19).** P8 is BUILT at tier 1 and 1b (plan §14) and **no row in
this table has run on hardware.** One half of one row was earned on the sim lane — the Background
operation row's gate half, P8 item 2 row (a), recorded in that row and in Lane C above. What else
changed is that these rows are now *answerable*: the production coordinator keeps the tunnel when the
task ends, where the probe tore its own down, so the "Background operation" row finally has a binary
that can answer it. Every row below is the owner's devices, P8 launcher item 9, and the device plan
`Docs/Mesh-P7-Physical-Device-Test-Plan-2026-09-18.md` § F is the same list as a checklist.

**Status at the device round (2026-09-22): still no row run — ONE phone was in hand, and every row here needs two
to four, or the owner's hands on the one.** The round ran the one-phone rows it could (the unseeded first meeting,
*Lane D* § *The device round's item 1*; §15.5's read-back, *Lane E*) and names the rest rather than inferring them:
*Four-device topology* — UNREACHABLE, four phones (F7). *Background operation* (F1–F3, F6) — UNREACHABLE as
specified: the transport half needs a second phone to hold the far end while this one backgrounds and locks; a
phone ↔ Simulator variant would answer only the phone's half and needs the owner to lock the phone by hand during
the run — not attempted. *Low Power Mode* (F5) — UNREACHABLE without the owner at the phone for the toggle; the one
empirical Low Power datum on this phone is §15.5 D6's (a refresh submission is accepted under it). *Progress soak*
(F9, F12) — NOT RUN: reachable with one phone and a Simulator holding the far end, but it needs the phone in the
owner's normal use for 3 h / 6 h while it stays on the Mac's Wi-Fi, which this session did not have; **the degraded
ladder stays unchosen.** *Resource budget* — no product budget exists (unchanged). *Continued task* — **OBSERVED, the grant
half** (read back the same day from this and the 2026-09-21 Lane D transcripts: the continued-processing task was granted
and started at every first commit, six of six — *Lane D* § *The device round's item 1*, last paragraph; the running
card was not looked at). *Cancellation*, *Force quit* — NOT RUN: each needs the granted task to end or the app to be
force-quit while it runs; every run so far ended by `devicectl terminate`. *Partition walks* (F7–F8) — UNREACHABLE, three phones.
*Wi-Fi Aware* (F10) — the owner's call, not this session's two days. *QUIC hold on real radios* — NOT RUN: needs the
phone backgrounded with a committed link held, i.e. the same hands as the background row. **P9-2-C** (the presence
boundary-wake drift, not in this table) — NOT RUN: presence has no launch-env hook (a Settings switch on the phone,
by hand), the lane needs a third friend seeded (finding P9-2-B) and a ≥ 767 s arm; not attempted with one phone and
no hands. Every row above keeps its 2026-09-19 status and date below.

| Check | Required result | Result | Date |
| --- | --- | --- | --- |
| Four-device topology | Simultaneous starts and topology changes leave at most one connection per peer pair, at `maxConnections = 4`. | **NOT RUN — owner's devices (P8 item 9).** Unchanged by P8; four devices, plan §15.1, device row F7 | 2026-09-19 |
| Background operation | An established connection survives backgrounding and lock; re-dial via cached endpoint works while backgrounded; a fresh background Bonjour browse is recorded either way (failure is the expected, documentable result). | **Still deferred to P8 / plan §15.1 — and the sim lane cannot stand in for it.** What the sim lane DID earn on 2026-09-19 (P8 item 2, row (a)) is the half above the transport: a real `.background` scene edge drops the pushed `appIsForeground` leg (`mesh.routedAccess.gateChanged … foreground=false`) and holds the routed re-entry down until the foreground push. Whether a **connection** survives that edge is untouched — the sim lane held no connection to survive it (finding L-4), and a Simulator answers `BGTaskSchedulerErrorDomain error 1` to the continuation that would keep the process alive on a device | 2026-09-19 (gate half only; transport half deferred) |
| Low Power Mode | Behaviour on and off is recorded empirically. Apple documents neither direction. | **NOT RUN — owner's devices (P8 item 9).** Unchanged by P8; the empirical answer is the deliverable. Plan §15.1, device row F5 | 2026-09-19 |
| Progress soak | Three-hour and six-hour sessions survive while elapsed-based progress advances. Failure activates the degraded ladder in plan §14, it does not sink the plan. | **NOT RUN — owner's devices (P8 item 9).** *Now answerable:* item 4's ratcheted elapsed-toward-ceiling progress, driven from the poller's tick by item 6. **This row decides the degraded ladder**, which is therefore unchosen. Plan §15.3, device rows F9 and F12. **Scheduled: a 6 h run the evening of 2026-09-22**, one phone in normal use ↔ the Simulator holding the far end, the grant already observed (row above) | 2026-09-19; scheduled 2026-09-22 |
| Resource budget | Battery, peak memory, throughput, and photo-size measurements meet an approved product budget. | **NOT RUN — owner's devices (P8 item 9).** No approved product budget exists yet — that is the owner's, and it gates nothing until §15.3 says the task survives at all. Plan §15.3 | 2026-09-19 |
| Continued task | A user-started request either begins with system activity or reports the `.fail` refusal clearly. | **NOT RUN — owner's devices (P8 item 9).** *Now answerable both ways:* a grant produces the running card, and the four refusal arms (register refused, identifier cap, missing identifier, submission cap) produce the refusal sentence on the Friends card. A Simulator returns error 1 for every submission, so **no grant has been observed anywhere**. Plan §14 | 2026-09-19 |
| Continued task — **the grant half, on the phone** | (same row) | **OBSERVED 2026-09-21 and 2026-09-22, six of six runs** (read back 2026-09-22): `mesh.continuation.registered` → `submitted event=firstPeerCommitted` → `started event=taskStarted state=running` 4–7 ms after the submission on every Lane D and unseeded run; the task stayed `running` across a re-dial. The refusal arms and the running card unobserved; the task's end never observed (every run terminated from the Mac). *Lane D* § *The device round's item 1*, last paragraph | 2026-09-22 |
| Cancellation | Every path stops the probe and completes the task exactly once. | **NOT RUN — owner's devices (P8 item 9).** *Proven at tier 1, unproven on a device:* exactly-once completion is a biconditional over all 48 rows and a 28 080-walk sweep, and a second completion audits as a no-op — but the real `SystemContinuationTaskHandle` conformer is exercised by no test. Plan §14 | 2026-09-19 |
| Force quit | Evidence confirms durable production acknowledgements cannot depend on an expiration callback. | **NOT RUN — owner's devices (P8 item 9).** Unchanged by P8; the claim it tests (durable acknowledgements cannot depend on an expiration callback) is why the routed store's receipts never do. Plan §14 | 2026-09-19 |
| Partition walks | The plan's §10 partition scenarios, physically. | **NOT RUN — owner's devices (P8 item 9).** Unchanged by P8. Plan §15.2, device rows F7–F8 | 2026-09-19 |
| Wi-Fi Aware evaluation | A bounded two-day answer on hardware floor, whether `NetworkConnection` rides over it, and battery profile. Outcome is a recommendation, not a dependency. | **NOT RUN — owner's call (P8 item 9).** Unchanged by P8; a recommendation, not a dependency. Plan §15.4, device row F10 | 2026-09-19 |
| QUIC hold on real radios | `holdCommittedLinks()` on a physical radio: browsing and admission stop, every committed link, its coordinator and the group-key state survive, and the transport's TXT republish is minted on resume rather than through the pause. | **NOT RUN — owner's devices (P8 item 9).** The sim↔sim half was P8 item 2's row (d) and **did not cross** — no committed pair was ever formed on this Mac (finding L-4 above; plan §14.3 finding 19). Evidence to look for: one `mesh.session.linksHeld` / `mesh.session.linksResumed` pair per background hold and foreground return | 2026-09-19 |

### Lane E — the companion refresh (run 2026-09-21, P10 item 8): **registered, and refused at every step after that**

**Purpose.** §27.2 left one question open and explicitly refused to answer it by analogy: a Simulator
refuses a `BGContinuedProcessingTaskRequest` outright (`BGTaskSchedulerErrorDomain` 1, Lane B's
*Continued task* row), but whether it also refuses an **app refresh** — a different task class, with
`fetch` in `UIBackgroundModes` and the identifier permitted in `Info.plist` — was **not** to be
assumed. `SystemCompanionRefreshScheduler` is the one part of the companion-refresh stack no unit
test touches, and this lane is the measurement against it. The answer is recorded here whichever way
it fell, together with the rows only a phone can give.

**Verdict: a Simulator registers the identifier and gets no further.** Registration is accepted.
Submission is refused with the *same* `BGTaskSchedulerErrorDomain` code 1 as the continuation, so
nothing is ever pending; and because nothing is pending, the debugger SPIs that would otherwise
force a delivery and an expiration are refused too, by the framework, for that exact reason. The
whole chain after `register` is a tier-3 row. P8's finding does extend to `BGAppRefreshTask` — but it
is now measured, not assumed.

**Environment.** Xcode 26.5 (build 17F42); runtime iOS 26.5 (23F77); one iPhone 17 Simulator,
`09F57BCA-DF29-4E43-9E06-E363AE688A88`, **shut down, erased and freshly booted at 02:53** so the run
starts from a first install (the standing "a Simulator that has been up for hours stops behaving"
precaution — this one had been up ~12 h). App built from the worktree at commit **`288f501`**,
`xcodebuild build -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17'`,
`** BUILD SUCCEEDED **` / `EXIT=0`; the installed `Fernlet.app` and its binary both carry mtime
`2026-09-21T02:53:29`, which is the build's own end timestamp — i.e. the bundle under test is this
build and not a stale one.

**Reading the audit stream.** As everywhere else in this runbook:

```sh
xcrun simctl spawn <udid> log stream --level debug --predicate 'subsystem == "com.fernlet"' > "$LOG" 2>&1 &
echo $! > stream.pid      # kill by PID at the end; never `pkill -f "log stream"`
```

Two notes worth carrying. **(a)** `FernletAuditLog` logs its context dictionary with
`privacy: .private`, and on the **Simulator** those values come through in the clear — every
`error=…` and `trigger=…` quoted below is real text off the stream, not a reconstruction. On a
**device** they redact to `<private>` unless a debugger is attached or the private-data profile is
installed; see the finding at the end of this section, because it lands on the one device row where
no debugger *can* be attached. **(b)** The framework's own chatter is a second, independent witness
and is worth capturing beside the audit stream:
`log show --predicate 'subsystem == "com.apple.BackgroundTasks"' --style compact`.

#### The rows

| Row | Expected | Observed | Evidence |
| --- | --- | --- | --- |
| **1. Registration** | `BGTaskScheduler.register` accepts `MBO.Fernlet.companion-refresh`; `companionRefresh.registered`, no `registrationRefused` | **Accepted.** Twice, in two separate launches. This is a *positive* event, so the verdict does not rest on the absence of a refusal line | `02:54:35.706514 … [com.fernlet:audit] companionRefresh.registered` (pid 4988), and again `03:01:12.774632 … companionRefresh.registered` (pid 6001). No `companionRefresh.registrationRefused` anywhere in the stream |
| **2. The background-edge submission** | Either `companionRefresh.submitted trigger=background`, or `submitRefused` naming the domain and code | **Refused, every time — `BGTaskSchedulerErrorDomain` code 1.** Three background edges across two processes, three refusals, no acceptance | `02:54:54.744491 … companionRefresh.submitRefused error=Error Domain=BGTaskSchedulerErrorDomain Code=1 "(null)" trigger=background`; the same line again at `02:55:18.139437` (pid 4988) and `03:02:46.826043` (pid 6001) |
| **2b. The request the app actually built** | The refused request carries the identifier and a floor of now + 15 min | **Correct, and this part the Simulator *can* prove.** The framework logs the request it was handed before refusing it | `02:54:54.739 … [com.apple.BackgroundTasks:Framework] submitTaskRequest: <BGAppRefreshTaskRequest: MBO.Fernlet.companion-refresh, earliestBeginDate: 2026-09-21 07:09:54 +0000>` — submitted at 06:54:54 UTC, floor 07:09:54 UTC, exactly `earliestBeginInterval = 15 * 60` |
| **2c. The pending-request guard** | On a second background edge, `edgeFoundARequestAlreadyPending` | **Unreachable here, and correctly so.** A refusal leaves `pendingRequest` nil by design, so the second and third edges re-asked and were refused again rather than short-circuiting. The guard is tier-1 territory on this lane | The second edge at `02:55:18.139437` is another `submitRefused`, not `edgeFoundARequestAlreadyPending`; that event name appears **zero** times in the stream |
| **3. A forced delivery (`_simulateLaunchForTaskWithIdentifier:`)** | The launch handler fires: `taskWasDelivered` → tail submission `trigger=handle` → `runFinished outcome=…` → exactly one completion | **Refused by the framework, for the reason row 2 created.** The SPI is reached and runs — this is not an attachment failure — and then declines because there is no scheduled request to launch. **No `companionRefresh.*` line follows it at all** | `03:01:32.580 … [BackgroundTasks:Framework] Simulating launch for task with identifier MBO.Fernlet.companion-refresh` → `03:01:32.580 … Getting pending task requests` → `03:01:32.585 E … No task request with identifier MBO.Fernlet.companion-refresh has been scheduled`. The audit stream for pid 6001 holds exactly one companion line in that window: the `registered` at `03:01:12` |
| **3b. A forced expiration (`_simulateExpirationForTaskWithIdentifier:`)** | `taskDidExpire` cancels the run and completes the task `false` | **Refused, consistently with 3** — there is no simulated task to expire | `03:02:32.632 … Simulating expiration for task with identifier MBO.Fernlet.companion-refresh` → `03:02:32.633 E … Task with identifier MBO.Fernlet.companion-refresh is not currently being simulated` |
| **4. iOS delivering it on its own** | A backgrounded app is woken within a few minutes of an accepted submission | **Unreachable by construction, not merely unmeasured.** A delivery needs a pending request; row 2 shows no request is ever accepted, so there is nothing for the scheduler to hold, let alone deliver. Confirmed negatively by a soak anyway, so the row is measured and not merely argued | Soak `03:02:45`–`03:12:32` (≈ 10 min), app backgrounded behind Safari with the stream live. The last companion line of the entire run is the `submitRefused` at `03:02:46.826043`; nothing followed it. The app was **still alive** at the end (`ps -o etime -p 6001` → `11:32`), so this is a process that was there to be woken and was not — not one iOS had reclaimed |

#### Driving the SPIs: two ways to waste twenty minutes

`lldb` **does** attach to a Simulator process from the command line — `xcrun lldb --batch -o "process
attach --pid <pid>" -o "expr …" -o detach` — and the refusals above are what it returned, not what it
failed to return. Two conditions are load-bearing, and missing either looks exactly like "the SPI
does not work":

1. **The expression must run all threads** (`expr -l objc -O -a true -u false -t 15000000 -- …`).
   With the default single-thread evaluation the call never returns: the framework hands off to
   another queue that is stopped, and the batch hangs until it is killed.
2. **The app must be in the foreground.** A backgrounded app is suspended by iOS with `SIGSTOP`, and
   that signal lands *inside* the expression:
   `error: Expression execution was interrupted: signal SIGSTOP.` Front the app with
   `xcrun simctl launch <udid> MBO.Fernlet` first. This is its own small trap — the state you most
   want to test the refresh in is the one state you cannot hold the debugger in.

Backgrounding for row 2 is just `xcrun simctl launch <udid> com.apple.mobilesafari`; the `.background`
scene edge fires and `FernletApp.handleScenePhaseChange` calls
`CompanionRefreshCoordinator.shared.appDidEnterBackground()` outside the `case .ready` guard, which is
why the edge fires even on a launch whose store never became ready.

#### Rows a Simulator cannot give

These are the companion refresh's device rows, and they are carried by name into the P10 close-out.
Every one of them is downstream of row 2's refusal — the Simulator does not merely fail to observe
them, it cannot reach the state in which they exist.

1. **A cold background launch by iOS.** The system starting the app *because* a refresh came due,
   with no foreground launch before it. There is no process to attach to, so there is also no way to
   force it; and it is the launch in which `FernletStoreAccess` builds a store with no HealthKit
   service, which is the whole reason item 4's pipeline is shaped the way it is.
2. **A refresh granted and launched by iOS on its own schedule.** Everything after
   `taskWasDelivered` — the tail's `submitNext(trigger: "handle")` before the work, the pipeline
   outcome (`reloaded` / `unchanged` / `scoringContextUnavailable` / `widgetActionsPending` /
   `publishedDespitePendingActions` / `writeFailed`), the WidgetKit timeline reload, and
   exactly-once completion. `companionRefresh.runFinished` has never been emitted on any machine.
3. **The real conformer's expiration handler under a genuine time budget.** Whether
   `SystemCompanionRefreshTaskHandle`'s `expirationHandler` hop reaches `taskDidExpire()` in time to
   cancel an in-flight run, when the budget is the system's and not a test's. Tier 1 proves the
   coordinator's half; the conformer's half is unexercised by any test.
4. **The 15-minute floor honoured.** Row 2b proves the app *asks* for now + 15 min. Whether iOS
   respects that floor, and what it actually grants in practice, is a phone measurement.
5. **Background App Refresh disabled in Settings.** The Simulator has no such switch to flip, and
   this is the setting that produces the refusal a real user can cause — the one
   `companionRefresh.submitRefused` exists to make attributable.
6. **Low Power Mode.** Same shape as Lane B's row: Apple documents neither direction, so the
   empirical answer is the deliverable.

Two smaller rows fall with them, worth naming so nobody looks for them on a Simulator:
`companionRefresh.edgeFoundARequestAlreadyPending` (needs an accepted submission to guard against)
and `companionRefresh.deliveryAbsorbed` (needs two deliveries, and there are none).

#### Finding — the device row with no debugger is the row whose evidence redacts

`FernletAuditLog.log` emits its context with `privacy: .private`. On the Simulator that is moot, and
every value in this section came through in the clear. On a **device** it is not: without a debugger
attached or the private-data profile installed, `companionRefresh.submitRefused` reads
`submitRefused <private>` in a sysdiagnose — the event name survives, the `error=` and `trigger=`
values do not. That collides with row 1 of the list above: a cold background launch by iOS is
precisely the case where no debugger can be attached, so it is precisely the case where the audit
line cannot say *which* refusal happened or *which* trigger asked. Nothing is fixed here — item 8
changes no production code — but whoever runs the device rows should install the private-data
profile on the phone first, or accept that the cold-launch row comes back with redacted context.

#### Device run, 2026-09-21 — P10's eight rows (plan §15.5) on the owner's phone

**Environment.** `main` = `0a85e06` (Lane D's plan addendum), rebuilt for this run (`xcodebuild build -scheme Fernlet
-configuration Debug -destination platform=iOS,id=<udid>`, automatic signing, 16:58:56Z → 17:01:15Z, `** BUILD
SUCCEEDED **`, zero `error:`), installed fresh (STATE.md's 17:02:30Z; devicectl keeps no install log). Phone: the owner's **iPhone 17 Pro Max**, iOS **26.6.1**,
CoreDevice `11FF8B2D…`, `transportType: localNetwork` with the **cable out until ≈17:58Z** (`en9 present = 0` at the
17:02:53Z preflight) and **in, `transportType: wired`, at the 17:59:25Z and 18:43:03Z preflights**. Mac: Xcode 26.5. Same session as Lane D, same recipe: one `xcodebuild` at a
time, the app driven with `xcrun devicectl device process launch … --console --environment-variables
'{"OS_ACTIVITY_DT_MODE":"YES"}' MBO.Fernlet -- -completeOnboarding`, the console transcript kept as the app-side witness.
Charging: **off the charger until ≈17:58** (cable out, the owner's report), **charging from ≈17:58** (cable in, `transportType: wired`); every row below says which.

**The private-data logging profile — built three times, refused three times.** There is no `.mobileconfig` in the
repo, so one was written for the run: one `com.apple.system.logging` payload, served over the LAN with the
`application/x-apple-aspen-config` MIME type and opened in the phone's Safari through `devicectl … launch --payload-url
<url> com.apple.mobilesafari` (the phone fetched each version; the Allow → Settings → Install taps are the owner's).
**iOS 26.6.1 refuses an unsigned profile** — not with the old red "Not Signed" warning, but with *Profile error: the
profile "Fernlet Private Data Logging" has an invalid signature* (v1, the flat `Enable-Private-Data` at the payload's
top level; v2, Apple's documented shape with a `System` dict and per-subsystem `Subsystems`, 17:33Z). v3 (17:45Z) is v2
CMS-signed with the Mac's `Apple Development` identity (`security cms -S -N "<identity>" -i v2 -o v3`; it decodes back
to the plist), which chains to Apple Root CA on the phone. The check for "installed" is not a guess: a 20 s `xctrace`
window carries `<private>` tokens from system processes (`backboardd`, `CoreBrightness`, …) while the profile is off —
**759** lines carry it at 17:13:24Z; the "on" half of the check was never reached, because **the signed v3 was refused
with the same words.** What that
costs, and only that: every row where devicectl launched the app reads in the clear anyway (the `OS_ACTIVITY_DT_MODE`
fact below), and D1's cold launch is witnessed by `xctrace` from its public event names plus `chronod`'s own reload
line — its `outcome=` value is the one thing this run cannot read. The two ways left are the owner's to take, not a
session's: a certificate from an authority the phone already trusts, or a self-signed authority installed and trusted
on the phone (a trust-store change). Stop condition 3, applied to one value.

**How the phone's log was read — three doors tried, one open.**

1. `xcrun devicectl device sysdiagnose` **fails, wired or wireless**: `CoreDeviceCLISupport.DiagnoseError error 0`,
   three tries over Wi-Fi (destination directory pre-created, `--verbose` adds nothing past "Acquired usage
   assertion") and one more at 18:00:44Z with the cable in and `transportType: wired` — the same error, so it is not
   the transport.
2. `/usr/bin/log collect --device-udid <udid>` → `Must be root to collect logs from attached device`. (And `log` is a
   zsh **builtin** — the `/usr/bin/` prefix is load-bearing in a script.)
3. **`xcrun xctrace record --device <udid> --template Logging --all-processes --time-limit <n>` works** over Wi-Fi,
   without root and without a launcher, and is what makes a cold-launch row observable at all. Export with
   `xcrun xctrace export --input <trace> --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-log"]'`; grep the
   XML. Cost: ≈ 13 MB of trace per minute on disk, ≈ 30 MB of XML per minute exported. It **honours redaction** —
   system processes' `%{private}` arguments read `<private>` in the export — so it doubles as the profile check.

Two facts about the two witnesses, both measured here. **`OS_ACTIVITY_DT_MODE=YES` in the launch environment puts the
app's audit contexts in the clear in logd too**, not only in the console mirror: the export of a window spanning the
first submission shows `companionRefresh.submitted trigger=background` with its value while `backboardd` beside it is
redacted. DT_MODE therefore substitutes for the profile on every devicectl-launched row, and on none of the rows where
iOS launches the app itself (D1). And **the console mirror does not carry the BackgroundTasks framework's
`submitTaskRequest:` line** — it carries `[BGSTFramework] updateTaskRequest …` for Core Data's own CloudKit export task
and nothing for ours — so the framework-side witness for every row below is the `xctrace` export.

**The debugger shortcut, on a device.** `xcrun lldb` reaches the phone (`device select <coredevice-id>`, then `device
process attach --pid <pid>`), but the attach is **asynchronous** and `--batch` runs the next command "while the process
is attaching" (an `expr` is refused for that reason, and a `process status` after a six-second sleep hung until killed).
Feeding the commands on **stdin** to a non-batch `lldb` after the `-o` attach works: `expr -a true … (BOOL)true` returned
`YES` with the app in the foreground, and `[[BGTaskScheduler sharedScheduler]
_simulateLaunchForTaskWithIdentifier:@"MBO.Fernlet.companion-refresh"]` ran, returned nothing, and **delivered nothing**
— no `trigger=handle`, no `runFinished`, no framework line in the mirror — with a request pending at the time (this
is the opposite precondition from Lane E's Simulator, where the SPI declined because nothing was pending). Ten minutes,
as budgeted; the rows below rely on the schedule.

**Timeline (UTC).**

| When | What | Evidence |
| --- | --- | --- |
| 17:02:54.663 | Launch (console, DT_MODE), pid 9739; registration accepted | `[audit] companionRefresh.registered` |
| 17:03:39 | Backgrounded by `devicectl … launch --activate com.apple.mobilesafari` | the `.background` scene edge |
| **17:03:40.158** | **Submission ACCEPTED** — the first on any machine | `[audit] companionRefresh.submitted trigger=background`; framework (xctrace): `submitTaskRequest: <BGAppRefreshTaskRequest: MBO.Fernlet.companion-refresh, earliestBeginDate: 2026-09-21 17:18:40 +0000>` — submit + 15:00 to the second; the scheduler's activity `bgRefresh-MBO.Fernlet.companion-refresh:10C5F0` |
| 17:04:38 | Fronted again (`--activate MBO.Fernlet`, no `--terminate-existing`: pid 9739 kept) | — |
| 17:06:39 – 17:12:25 | The lldb probe, three attempts, verdict above | `run1/lldb-simulate-launch{,2,3}.log` |
| 17:11:20.643 | A `.background` edge with a request pending (the app fell to background while lldb held it) | `[audit] companionRefresh.edgeFoundARequestAlreadyPending` — **D7** |
| 17:12:43.594 | The same edge again, Safari re-activated from the Mac at 17:12:42Z | `[audit] companionRefresh.edgeFoundARequestAlreadyPending` — **D7**, twice |
| 17:18:40 | The floor. No grant followed it in the 39 minutes the phone stayed off the charger (≈17:58), screen unlocked | the console carries nothing after 17:33:38 |
| 17:33:38.352 | A third edge, from the Safari activation that opened the v2 profile (something had fronted Fernlet in between — inferred, not logged) | `[audit] companionRefresh.edgeFoundARequestAlreadyPending` — **D7**, three of three, no floor slide |
| 17:57:58.894 | **pid 9739 killed with signal 9** while backgrounded. **Cause unread**: nothing in the trace at that second names a reason; the cable went in within the same minute and the owner was on Settings → Fernlet twenty seconds later, and either would do it (a wired console session lost, or a per-app permission change — iOS SIGKILLs for both). The per-app Background App Refresh switch is on that Settings page, so **D5's toggle will cost the process every time** | console: `App terminated due to signal 9`; trace: `termination reported by launchd ( 11 , 0 , 9 )` |
| 17:58:19.179 | **A launch nobody on the Mac made — and not the refresh either.** `liveactivitiesd`: `Activity authorization for bundleid: MBO.Fernlet changed to: 1` (17:58:17.906, the Live Activities switch) → `Launching process to deliver push token` → `Sending request to open "MBO.Fernlet"`; pid 10146 registered (`companionRefresh.registered <private>` — the empty context renders `<private>` with no DT_MODE, which is how a non-devicectl launch is recognised) and was killed 1.06 s later, between `Preferences … TCCAccessSetInternal service=kTCCServiceFaceID` (17:58:18.699) and `…Camera` (17:58:19.049) for `MBO.Fernlet` — a permission change SIGKILLs the app. Recorded because it is exactly the shape a D1 cold launch would have, from the wrong daemon | trace, 17:58:17.906 → 17:58:20.239 |
| — | The cable was IN at the next preflight (`en9` present, `transportType: wired`): charging from here on | preflight |
| 17:59:26.454 | **Low Power Mode ON** (the owner's report — no log line carries the power state; the per-app Background App Refresh switch greys out under it), cable in, charging: relaunch, pid 10156, registration accepted | `[audit] companionRefresh.registered` |
| **17:59:28.202** | **Submission ACCEPTED under Low Power Mode** — the edge fired by Safari at 17:59:27; floor 18:14:28 | `[audit] companionRefresh.submitted trigger=background` — **D6, the "on" half** |
| 18:04:56.294, 18:05:02.497 | Two more edges with the request pending (the owner fronted Fernlet), under Low Power Mode | `edgeFoundARequestAlreadyPending` — **D7**, five of five |
| before 18:25 | pid 10156 killed with signal 9 again (the owner at the phone; cause not read — see the witness gap below); phone locked at 18:25 | console: `App terminated due to signal 9` |
| 18:27:37 | pid 10605 appeared with no launcher on the Mac, the phone unlocked, Low Power Mode still on — **the owner opening Fernlet** (confirmed by the owner at 18:46). Worth a row because the recording spanning that minute was stopped early to read it, and a `SIGINT` to a background `xctrace` leaves the bundle unreadable (`Document Missing Template Error`) — the first of two Instruments lessons this run paid for. **A pid-appearance poll cannot tell a cold launch from a tap; only the trace can** | `devicectl … processes` poll; the owner |
| 18:28:16 → 18:42:33 | **Witness gap.** The early stop above, then a second session started while the first was finalising (`_lockKPerf: could not lock kperf. Likely another session just started` — the second lesson), then a leftover recorder that had to be killed. No line from the phone for fourteen minutes | `run1/run.txt` |
| 18:42:33 | Recording resumed as sequential 15-minute chunks (`chunks.sh`: each starts only when no `xctrace` is alive) | `c-2.trace` … |
| 18:43:04.280 | Relaunch (console, DT_MODE) so the process that receives the next grant is readable; pid 10752 registered. Low Power Mode on, cable in, charging | `[audit] companionRefresh.registered` |
| **18:43:05.901** | **Submission ACCEPTED**, floor 18:58:05 | `[audit] companionRefresh.submitted trigger=background` |
| ≈18:45 | **Low Power Mode OFF** (the owner), request from 18:43:05 still pending — so D6's delivery half reads "accepted under Low Power Mode, delivered after it?" | the owner, 18:46 |
| 18:47 | **D5's switch cannot be flipped on this phone.** With Low Power Mode off, Settings → General → Background App Refresh → Fernlet is disabled (it only *shows* off while Low Power Mode is on). Submissions are accepted, so refresh is not off for the app — the switch itself is locked, which on an unmanaged phone is what a Screen Time restriction (Content & Privacy Restrictions → Allow Changes → *Background App Activities*) looks like. Not a code finding; the row waits on the owner lifting the restriction | the owner, 18:47 |
| 18:58:05 | The floor. **No grant by the time this record was written**; the app-side witness (console pid 3492) and the framework-side chunks (`c-2` …, 15 min each, no overlap) stay running past the record — see *How to resume* | — |

#### The rows

| Row | Result | Evidence | When (UTC) | Charging | Profile |
| --- | --- | --- | --- | --- | --- |
| **P10-D1** cold background launch | **NOT REACHED** — no grant has come, so no cold launch has been asked for; the setup is written (a devicectl `terminate` after an accepted submission, chunks recording) and the row's outcome VALUE will read `<private>` regardless (profile refused). A `liveactivitiesd` launch at 17:58:19 had the row's exact shape from the wrong daemon | `long1` trace, `window-10146.txt` | — | charging | no |
| **P10-D2** a grant on iOS's own schedule | **NOT REACHED in 1 h 55 min** across three accepted requests (floors 17:18:40, 18:14:28, 18:58:05), screen unlocked or locked, charger off then on, Low Power Mode off, on, off. The scheduler wrote **nothing** naming the activity in 45 min of trace at the captured levels; there is no line to quote for *why*. The overnight window is the next measurement — **read back 2026-09-22: NO GRANT in the overnight window either** (1 h 56 min from the 18:43:05 submit until the phone left the Mac's reach at ≈20:39; see *The overnight window, read back* below) | consoles `run1`, `d6-lpm-on`, `run2`; `long1` | 17:03–18:58 | both | no |
| **P10-D3** the real conformer's expiration handler | **NOT REACHED** — needs D2 | — | — | — | — |
| **P10-D4** the 15-minute floor honoured | **HALF**: the request the app builds carries `earliestBeginDate = submit + 15:00` to the second on a device (`submitTaskRequest: … earliestBeginDate: 2026-09-21 17:18:40 +0000` for a 17:03:40 submit). Whether iOS respects the floor from above is D2's delivery time minus the submit time — **not reached** | `probe.trace` export | 17:03:40 | not charging | no |
| **P10-D5** Background App Refresh off in Settings | **BLOCKED on the phone's own policy**: the per-app switch is disabled with Low Power Mode off (submissions are accepted, so refresh is not off for the app — the switch is locked; a Screen Time *Background App Activities* restriction is the ordinary cause). The refusal it would produce was not observed. Not a code finding | the owner, 18:47 | — | charging | no |
| **P10-D6** Low Power Mode | **HALF, and the empirical half is the surprise: a submission is ACCEPTED under Low Power Mode** (`submitted trigger=background` at 17:59:28 and again at 18:43:05, both with Low Power Mode on — the owner's report; no log line carries the power state), so Low Power Mode does not refuse the *ask*. Whether it withholds the *delivery* is D2's question with one more variable; the 18:43:05 request was still pending when Low Power Mode went off at ≈18:45 | `d6-lpm-on`, `run2` consoles | 17:59:28, 18:43:05 | charging | no |
| **P10-D7** `edgeFoundARequestAlreadyPending` | **EARNED — five times**: 17:11:20.643, 17:12:43.594, 17:33:38.352 (pid 9739), 18:04:56.294, 18:05:02.497 (pid 10156, under Low Power Mode). Every one after an accepted submission, none re-asked, the floor never slid | consoles `run1`, `d6-lpm-on` | 17:11–18:05 | both | no |
| **P10-D8** `deliveryAbsorbed` | **NOT REACHED** — needs two deliveries | — | — | — | — |

**How to resume.** The scratchpad of this session holds the scripts (`launch.sh`, `toggle-row.sh`, `chunks.sh`, `extract.sh`,
`window.py`, `sysdiag.sh`) and STATE.md; they are not in the repo. The shape that works: a devicectl `--console` launch with
`OS_ACTIVITY_DT_MODE=YES` (the app-side witness, values in the clear), plus `chunks.sh <prefix> <n> 15` (the framework-side
witness, sequential 15-minute `xctrace` recordings with no overlap), the phone locked, charging, hands off, **overnight**.
Read a chunk with `extract.sh <trace> <xml>` (the companion and framework lines with UTC) or `window.py <xml> <start-date>
<from> <to>` (every resolved line in a window). When a grant lands: D2 from the console (`trigger=handle` → outcome →
`runFinished`), D4 = its time minus the last `submitted`, D3 only if the run outlives the budget, then `devicectl … terminate`
the app with the tail's request pending and wait again for D1 (names only) and, on a second delivery to a held task, D8.
Never `SIGINT` a background `xctrace`; never start one while another is finalising; never flip anything under Settings →
Fernlet while a run is pending.


#### The overnight window, read back 2026-09-22 — no grant; the window ended by the phone at ≈20:39Z

**Read at 15:10Z on 2026-09-22, before anything touched the phone**: no `xctrace` and no `devicectl`
process was alive on the Mac (`pgrep`), so the recorders had already stopped on their own; the
scratchpad `p10dev/` of the 2026-09-21 session was read as it stood.

**The app-side witness** — `run2/device-console.log`, pid 10752, `companionRefresh.registered`
18:43:04.280Z, `companionRefresh.submitted trigger=background` 18:43:05.901Z, floor 18:58:05Z —
carries **no** `trigger=handle`, **no** `runFinished`, **no** `taskWasDelivered`, **no**
`edgeFoundARequestAlreadyPending` and no termination line. Its last entry is devicectl's own:
`ERROR: An error occurred while communicating with a remote process. (com.apple.dt.CoreDeviceError
error 3) … The connection was invalidated. (com.apple.Mercury.error error 1001)`; the file's mtime is
20:39Z. That console session was on the **wired** transport (the 18:43:03Z preflight in `run2/run.txt`: `en9
present = 1`, `transport = wired`; the session's `STATE.md`: "do not unplug"), so a cable pull does
exactly this.

**The framework-side witness** — the chunks. Readable, with their `--toc` windows: `c-2`
18:42:34–18:57:34Z, `c-3` 18:59:24–19:14:25Z, `night-2` 19:31:19–19:46:19Z, `night-3`
19:47:49–20:02:49Z, `night-4` 20:04:07–20:19:08Z, `night-5` 20:20:19–20:35:20Z; `night-6`
20:36:35–20:39:39Z exported **zero rows**; from `night-7` (20:39:39Z) the recorder reported *Timed
out waiting for device to boot* — the phone unreachable to `xctrace` — and `night-8` … `night-40`
each ended within seconds through 20:43:53Z (`night-9`, 20:40:13.9–20:40:16.2Z, 2.3 s, caught 1 923
rows, none Fernlet's; `night-10`, 20:40:32–20:41:36Z, zero rows). **`c-4` (19:15:45–19:30Z) is unreadable**: the `night` chain was started at 19:09:53Z while the `c`
chain's `c-4` was still **recording**, and `chunks.sh`'s one-recorder gate is a bounded wait — 240 × 5 s —
that falls through and records anyway; 19:09:53Z + 20 min is `night-1 START 19:30:04Z` to the second,
41 s before `c-4`'s own time limit (its log's last line, *Reached specified time limit, ending
recording…*, mtime 19:30:48Z). `night-1` failed on the kperf lock and `c-4` never wrote its bundle. A
**16 min 54 s** gap in the framework witness, 19:14:25.5 (c-3's end) → 19:31:19.3Z (night-2's start),
covered by the console alone. **And the chain never abuts:** every chunk boundary is 71–110 s
un-traced (c-2 → c-3 109.8 s, which contains the 18:58:05Z floor instant; night-2 → -3 89 s; -3 → -4
78 s; -4 → -5 71 s; -5 → -6 76 s) — ≈7 min more beyond the c-4 gap, ≈24 min un-traced in all. The
continuous witness over the whole window is the console.

**In every readable chunk**: `bgRefresh-MBO.Fernlet.companion-refresh:44EF40` appears exactly once,
in `c-2` at 18:43:05.885Z (`Submitting task request activity`, beside `submitTaskRequest:
<BGAppRefreshTaskRequest: MBO.Fernlet.companion-refresh, earliestBeginDate: 2026-09-21 18:58:05
+0000>` — submit + 15:00 to the second, again); **no** `STARTING`, `RUNNING` or `COMPLETED` for it in
any chunk; no `companion-refresh` mention after that second; **no termination of pid 10752** in any
chunk; `dasd` logged nothing naming the activity at the captured levels, for the second day.

**Verdict — D2 NOT REACHED in the overnight window: no grant from 18:43:05Z to at least 20:35:20Z
(the last readable framework minute) and none on the app side until the console died at 20:39:32Z
(the file's mtime) — 1 h 56 min after the submit, 1 h 41 min past the floor.** Across the two device
sessions that is **≈3 h 36 min** of accepted-and-pending time with no delivery — three accepted
requests, each replacing the last (17:03:40 → 17:59:28, 55 min 48 s; 17:59:28 → 18:43:05, 43 min 37 s;
18:43:05 → 20:39:32, 1 h 56 min 27 s; disjoint, 3 h 35 min 52 s in all). The record's first draft said
≈3 h 51 min, adding the first session's 1 h 55 min to this window's 1 h 56 min; the two overlap by
15 min 35 s, and the commit subject of `f8dbcae` still carries the larger number. The window was ended by the **phone**, not by iOS and not by a session:
at ≈20:39Z it left the Mac's reach (the console invalidated and `xctrace` timing out within the same
minute), which is what a pulled cable or a phone carried off the Wi-Fi looks like from the Mac; what
happened at the phone is the owner's to say. At 15:10Z the next day the phone was back on
`localNetwork`, cable out, locked, and **Fernlet was not running** — pid 10752 died somewhere in the
unwitnessed 18½ hours, cause unread, and with it the pending request from 18:43:05Z is unobservable.
D1, D3 and D8 remain not reached (they need a grant); D4, D5, D6 and D7 are unchanged.

**A witness finding that narrows the 2026-09-21 note.** The `c-2` export carries **none** of the
app's own `companionRefresh.*` audit lines — 0 rows matching `companionRefresh` in 511 654 — although
the console mirror shows `registered` (18:43:04.280Z) and `submitted` (18:43:05.901Z) for the same pid, and
although the 2026-09-21 probe-window export (`oslog.xml`) *did* carry `companionRefresh.submitted
trigger=background` in the clear. The app's own rows in `c-2` stop at 18:43:15Z, eleven seconds
after launch; the framework's `submitTaskRequest:` line in the app's process at :05.885 is there.
Why the audit lines reached logd in the probe window and not in this one is not resolved here (a
`--console` session's DT stream diverting the app's log, or the info level not persisting once the
app is backgrounded, are the two candidates). The practical rule: **for a companion-refresh row the
devicectl console is the app-side witness, and the trace is the framework-side witness only** —
`com.apple.BackgroundTasks` in the app's process plus `dasd`. For D1, which has no console, the
trace would show the framework's lines and `runningboardd`'s launch, never the app's audit.

**What §15.5 now says.** After ≈3 h 36 min of pending time on two days with no delivery, D2 moves
from "not reached — the window was short" to **"not reached — a grant has not come in any window
this phone has offered"**. The next measurement is the owner's to arrange, not a session's: a window
of several hours with the phone on the charger, on the Mac's Wi-Fi, untouched, the console launched
wirelessly (not wired — a wired console dies with the cable), or the app relaunched by the owner
with no console at all and the trace as the only witness. Stop condition 3 applied to one row.

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
