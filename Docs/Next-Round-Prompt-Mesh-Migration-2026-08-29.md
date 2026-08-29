# Next-Round Prompt — ProximityKit Network Migration: P0 close-out + P1

**Written:** 2026-08-29, at the crypto-standardization round boundary (main = `2764e7d`).
**Plan:** [Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md](Plan-ProximityKit-Network-Migration-2026-08-27.md) — the authority. This file is only the launcher.
**Scope of the session this prompt starts:** finish **P0**, then build **P1 (transport neutrality)**. **Stop at the P1 boundary.**

One phase family per session, deliberately: a self-paced loop does not compact between phases, so a
session that runs P0→P3 arrives at the hard part with no room. Hand off at the boundary instead.

---

## How to start

Open a fresh session in the repo and paste:

> Read `Docs/Next-Round-Prompt-Mesh-Migration-2026-08-29.md` and execute it. Verify §1 before changing
> anything, then do §2 (P0 remainder) and §3 (P1). Stop at the P1 boundary and write the P2 handoff.

---

## 1. Verify before you change anything

This repo has landed a test-unbuildable `main` twice in recent rounds (`91c3956`, and again at
`282fbd4`), each time because a round committed without building the **test** target. Do not stack
onto a red HEAD — you will spend the session debugging someone else's commit and blame your own.

```bash
git -C . log --oneline -5
git -C . status --porcelain
xcodebuild build-for-testing -project App/Fernlet.xcodeproj -scheme Fernlet \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

- The build must succeed **before** your first edit. If it is red, fix that first as its own commit,
  or report and stop. Check the real exit status — a piped `xcodebuild` reports the pipe's status,
  not the compiler's, and a failed build has been mistaken for a green one here before.
- **Concurrent sessions share this working tree and DerivedData.** At the time of writing, two
  spawned sessions were in flight (see §5). If `git status` shows hunks you did not make — a churned
  `App/Fernlet/Localizable.xcstrings` especially — they belong to another session. Do not commit,
  revert, or `git add -A` over them. Commit your own work with explicit pathspecs.
- Never run two `xcodebuild` invocations against shared DerivedData at once.

---

## 2. P0 — what is left

Already landed (do not redo): the feasibility spike and its runbook and tests, the three Info.plist
keys, the string-catalog sync, and the `FileIndex`/`ProximityFunctionIndex` entries.

**(a) Register the production crypto purposes** — plan §5.2. Reserve them now, in one review, rather
than one per phase:

- `fernlet.mesh.channel-introduction.v1` — the production successor to the probe's transcript purpose
- `fernlet.mesh.tls-exporter.v1` — the exporter label
- the P5 content-key wrap and manifest-signature purposes

Also move the probe's bare exporter label — a string literal at
`App/Fernlet/Proximity/Feasibility/NetworkMeshFeasibilityProbe.swift:148`
(`"fernlet.mesh.probe.tls-exporter.v1"`) — into `CryptographicPurpose.swift` beside the already-registered
`meshProbeChannelIntroductionV1`. Keep the probe's purposes distinct from the production ones: the
existing comment explains why (the spike must not become a signing oracle for the shipping protocol).

**(b) Update [Docs/No-Tracking-Wall.md](No-Tracking-Wall.md) §4c** — it still describes the proximity
layer as MultipeerConnectivity + NearbyInteraction over the `_fernlet-*` types. Add the
Network.framework/QUIC `_fernlet-mesh2._udp` service and document the three Info.plist keys
(`NSLocalNetworkUsageDescription`, the Bonjour type, the `BGTaskSchedulerPermittedIdentifiers`
wildcard) and that they ship in Release while the probe itself compiles out.

**(c) Close the runbook gate** — [Docs/Mesh-Network-Feasibility-Runbook.md](Mesh-Network-Feasibility-Runbook.md)
line ~121. The table today has only *Check* and *Required result* columns: there is nowhere to record
what actually happened. Add **Result** and **Date** columns; fill the device↔simulator lane (discovery,
QUIC connect, control stream, datagram, channel binding), which is what the spike was built to prove;
and mark the locked / background / Low Power Mode / soak / battery rows **"deferred to P8 — see plan
§15"** rather than leaving them blank. A blank cell reads as untested; a deferred cell reads as scheduled.

**(d) Probe upkeep for later phases** — raise `maxConnections` from 2 to 4 behind the existing DEBUG
toggle (the runbook's own four-device step is impossible at 2), and add the counters P8's gate will
need to the bounded event ring: bytes in/out, connect and reconnect timestamps,
`ProcessInfo.thermalState`, and `isLowPowerModeEnabled`. Nothing else in the probe grows.

---

## 3. P1 — transport neutrality (the session's real work)

Plan §6. **Behavior-neutral by construction**: remove MultipeerConnectivity types from the shared
protocol surface so P2 can add a QUIC transport *beside* MC, with the other three radios untouched.

Target surface:

```swift
public enum PeerDeliveryMode { case reliable, bestEffort }

public struct PeerHandle: Hashable, Sendable {
    public let id: UUID              // stable per discovery, == PeerSlot.id (preserves QR/admission keying)
    public let displayHint: String   // advertised instance name, display only — never identity
}

public protocol PeerTransport: AnyObject {
    func send(_ frame: Data, to peer: PeerHandle, mode: PeerDeliveryMode) async throws
    func disconnect(_ peer: PeerHandle) async
    func pauseDiscovery()            // preserved contract: invite-while-paused fails loudly
    func resumeDiscovery()
}
```

Order of work:

1. Replace `MCSessionSendDataMode` in `MultipeerTransport` with `PeerDeliveryMode`, mapping inside
   `MeshMultipeerSession` (`.reliable → .reliable`, `.bestEffort → .unreliable`). This one change drops
   the MC import from `ProximityCoordinator.swift` and `MultipeerTransport.swift` outright.
2. Introduce `PeerHandle` and migrate the ~40 `MultipeerPeer` signature sites.
   `MeshMultipeerSession` keeps its `MCPeerID ↔ id` map **private**. `FileMCPeerIDStore` stays (P9 retires it),
   including its delete-all seam.
3. Rename the protocol family to neutral names (`PeerTransportState`, `PeerPendingInvite`,
   `InboundPeerFrame`). The MC conformer remains the only implementation.
4. Build the deterministic **fake transport**: an in-memory `PeerTransport` with scriptable
   connect/disconnect/latency/**partition** schedules and an **injectable clock — no wall-clock sleeps**.
   Build this well: it is the foundation of the §16.2 partition suite, and this repo has a documented
   flake family caused by wait helpers without deadline floors.

**Acceptance:** the entire existing proximity suite passes unchanged through the new abstraction over
the MC adapter, plus a golden test proving frames are byte-identical to before. If a wire byte moves,
you have left P1's scope.

**Explicit non-goals — leaving these undone is correct:** no Network.framework code (P2); no session-state
persistence (P3 — and note the invariant it reverses is documented and owner-approved, but not yet); no
changes to the presence/recipe/coach radios beyond the mechanical rename; no touching `sessionGoodbye`
(its `"Session ended"` body sits inside signed bytes — P3 parks it).

---

## 4. Constraints that will bite

**The crypto round changed the sealing rules under this plan.** `ColumnCrypto` is now a single
generation (V3) and **refuses to seal** when no `DeviceBindingID` is available —
`SealedColumnStrictSealError.bindingUnavailable`, owner decision D4 — instead of writing a legacy blob.
The V2 and unprefixed **read** paths are deleted; those formats survive only as classification cases in
`ColumnCryptoStoredFormat` so a refusal can name what it refused.

Not a P1 problem, but record it in the plan when you reach P3/P5: the sealed `MeshSessionContext`
(§8.1) and routed store (§11) **cannot be written before first unlock**. The plan's four-state sidecar
model needs a fifth consideration — "seal refused" is distinct from "deferred because protected data is
unavailable" — and background custody must not assume it can seal. This interacts directly with the
plan's durable-before-acknowledged invariant (§3.6): if you cannot seal, you must not acknowledge.

Other walls, all enforced mechanically:

- **No-tracking:** `NWConnection`/`NWBrowser` are banned markers; the new `NetworkConnection`/
  `NetworkListener`/`NetworkBrowser` names pass through a **gap** in the marker list. Plan §7.4 closes
  that gap deliberately in P2 — do not quietly rely on it before then.
- **Power of 10:** ≤ 60 code lines per function/`body`, bounded loops, no `!`/`try!`/`as!`/`fatalError`,
  no swallowed `try?`, warnings-as-errors. Run the scanner before every commit.
- **Localization:** display text as `LocalizedStringKey` (a `String` parameter silently opts a call site
  out); wire tokens, `rawValue`s, and accessibility identifiers stay frozen English forever.
- **Persisted-surface wipe wall:** any new `UserDefaults` key needs a disposition row in the same commit.
- **DocC:** every new type carries a `///` comment; zero undocumented declarations is the enforced baseline.

---

## 5. State of the tree at handoff

- `main = 2764e7d`, **12 commits ahead of `origin/main`, not pushed.** Pushing is the owner's call.
- The crypto standardization round is **complete** (census → migrators → deletions → walls → review).
- Two spawned sessions were running when this was written. Confirm what landed before you start:
  - **ExchangeIntentServiceError localization** — expect a churned `App/Fernlet/Localizable.xcstrings`.
  - **"V2 device-bound blob test coverage"** — **this task is stale.** It was spawned on 2026-08-27, before
    the crypto round deleted the V2 read path. There is no V2 open path left to cover; a V2 blob must now
    be *refused*. If that session produced anything that re-adds a V2 reader, do not merge it.

---

## 6. Verification gauntlet — before every commit

```bash
python3 Scripts/power-of-10-scan.py
python3 Scripts/doc-coverage-scan.py
Scripts/sync-string-catalogs.sh --check
xcodebuild build-for-testing -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild test-without-building -project App/Fernlet.xcodeproj -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:FernletTests
```

Plus `Scripts/spm-wall-check.sh` once anything wall-relevant moves (the pre-push hook runs it anyway).
The full suite takes ~7 minutes; run it in batches and check the exit code, not a grep for "passed".

---

## 7. Close-out

1. Mark the P0 items and P1 as **BUILT** in the plan, with landing SHAs — the crypto plan's per-phase
   `**BUILT**` markers and boundary commits are the format to copy.
2. Write a memory note: what landed, what surprised you, what the next session must not re-derive.
3. Commit in logical units with explicit pathspecs (never `git add -A` in a shared tree). Do not push
   unless the owner asks.
4. Write the **P2 handoff block** at the bottom of the plan. P2 needs things this session does not:
   two physical iOS 26.5+ devices, TN3213 open alongside, and the §7.2 decisions about the ephemeral
   per-mesh TLS identity and `prohibitedInterfaceTypes = [.cellular]`.
