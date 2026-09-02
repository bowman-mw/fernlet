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
members-only. It is on QUIC. **It is not on MC — which is the shipping default**
(`MeshTransportFactory.shippingDefault`): an MC invitation carries no identity, and the identity
introduction one layer up is gated on revoked/blocked keys, not on the roster. Four findings, all
fixed in the same change:

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

**Logging note.** `browsed peers=` prints nearby Bonjour instance names at `.notice` with
`privacy: .public`, matching the precedent set by `accepted`/`datagramCapacity`. It is acceptable
only because the QUIC radio is DEBUG-only today. **Downgrade it (and its neighbours) before QUIC
ships.**

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

The seams below are the smallest thing that opens it, and each one stands in for exactly one step:

| Seam | Where | What it stands in for | What stays shipping code |
| --- | --- | --- | --- |
| `FERNLET_MESH_ROLE=founder\|joiner` | `MeshMatrixDebugOptions` / `MeshFlowDriver` | which membership shape the node plays | everything below |
| `MeshNetworkManager.armFounderLedgerForHarness()` | DEBUG extension, `MeshNetworkManager.swift` | `startNewMesh`'s **id mint** and its `startSearching()` restart (which would re-mint the Bonjour name and drop the tunnel) | `prepareMembershipLedger` + `seedFounderAdmission` + `persistSessionContext` — the shipping founding, on the id the seeded descriptor already names. It also collapses the seeded two-member descriptor to what `startNewMesh` would have produced: the founder alone |
| `MeshNetworkManager.requestAdmissionForHarness()` | same | the *trigger* only — a joiner whose seeded descriptor already lists it never gets the `handleMeshDescriptor` trigger | `sendAdmissionRequest(for:)`, the shipping emitter, and the whole grant path after it |
| `FERNLET_MESH_LEAVE_AFTER=<seconds>` | `MeshFlowDriver` | a user tapping Leave | `leaveSessionAfterNotifyingPeers()` verbatim |
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

### Lane D — device ↔ simulator, the PRODUCTION mesh over QUIC (specified 2026-09-01, not yet run)

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
| Wi-Fi path | The ready/activation lines name a routable or `%en0`-scoped address, and `en9` does not exist. This is the row the 2026-09-01 run could not earn | — | — |
| Local Network permission | The phone prompts once, and the mesh comes up after it is granted | — | — |
| Accepted baseline on hardware | `accepted <fingerprint> sid=…: tunnel activated, tunnels=1` on both sides | — | — |
| Tunnel stability | One activation per side and **zero** `tunnelEnded` lines across ≥ 4 minutes, with `idleTimeoutMs=90000 beatSeconds=30` on the `datagramCapacity` line | — | — |
| Heartbeat + datagram flow | `heartbeat sending over datagram` and `heartbeat received over datagram` on both sides at 30 s spacing — the item-15 result, on a physical radio | — | — |
| App flows | Slot commit, capabilities, chat both ways, a photo on a per-transfer stream, shop catalogue — the item-10 table, on a physical radio | — | — |
| **Reconnect after a real idle timeout** | Kill one side (stop the Xcode run, or `xcrun simctl terminate <sim-udid> MBO.Fernlet`), wait > 90 s, restart it: the survivor's listener accepts the re-dial and a tunnel re-forms | — | — |
| **No NECP flow leak** | The survivor's console shows **no** `NECP_CLIENT_ACTION_ADD_FLOW … [17: File exists]` and no `Failed to create connection from listener` after the peer's tunnel ends | — | — |

The last two rows are the point of the lane. They are the residual from Lane A's `Fail`: the probe
could not answer them because it ends its whole run — listener included — on the first tunnel error,
whereas `NetworkMeshSession.endTunnel` ends one tunnel and keeps listening. If they come back clean,
the `EEXIST` cascade is confirmed probe-only and needs no production fix. If the survivor's listener
*does* refuse the re-dial, the fault is real in the shipping transport on a link-local peer-to-peer
path, and the fix candidates are, smallest first: re-listen on a fresh port after a tunnel ends
(`updateDiscoveryInfo` already has the stop-and-recreate shape), or drop `peerToPeerIncluded` from
the listener parameters and keep it only on the dialing side. Do not plan on "cancel the stale
connection" — `NetworkConnection` has no `cancel()` in the iOS 26 API.

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
