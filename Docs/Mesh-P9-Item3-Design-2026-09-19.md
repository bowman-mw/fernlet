# Mesh P9 item 3 — design note (pass 1 survey, written 2026-09-19 at `6ae7cb2`, drafts unbuilt)

> Written by the item 3 pass-1 survey before any code landed. The drafts it describes lived in the session scratchpad (`…/scratchpad/item3p1/drafts/`) and were NOT applied when this note was committed; a Phase-B agent re-reads every target file at HEAD before applying. Two premise corrections to the P9 launcher's item 3 row: the recipe share is ONE sealed frame (no chunks, no offsets — pause/resume is the RADIO's discovery pause), and the recipe radio used the PERSISTENT device-name MCPeerID (not an ephemeral one), so pass 2's posture is an improvement, not a reproduction.

# P9 item 3 pass 1 — recipe share over QUIC: the tier-1 values. DESIGN (Phase A)

## 0. The premise correction (read this first)

The launcher assumes the recipe share is a **chunked transfer with offsets** whose pause/resume the
user drives. **It is not.** At HEAD:

* The payload crosses as **one** sealed frame: `sendPendingPayload` → `coordinator.sendPayload(type:
  .recipeShare, summary:, payload:, sealed: true)` (`ProximityRecipeShareManager.swift:847-880`).
  No chunking, no offsets, no acks the app sees, no resume. `ProximityRecipeSharePayload.maxWireBytes`
  = 1 MiB is the whole ceiling.
* The **only** pause/resume in this subsystem is the radio's: `session.pauseDiscovery()` at
  `registerConnection` (`:608`) and `session.resumeDiscovery()` at `finalizeConnectionRemovals`
  (`:720-723`). It **is** shipped and user-visible: while paired the radio goes quiet so a third
  Fernlet can neither see nor invite this one ("Recipe sharing closed to others while paired with
  X."), and it reopens on manager-level record eviction ("Recipe sharing reopened to nearby
  Fernlets."). Five cells in `ProximityRecipeShareCapTests` pin it.
* Plan §17.1's words are "preserving pause/resume semantics" — the discovery semantics, which is
  what a naive QUIC swap loses.

So pass 1 settles **the pause/resume contract** and **the exchange's state machine**, not a chunking
protocol that does not exist. Pass 1 adds no chunk frames; §7 says what pass 2 needs instead.

## 1. Survey — every MC-backed surface in the recipe radio

| Surface | HEAD | Pass 1 | Pass 2 |
| --- | --- | --- | --- |
| `serviceType = "fernlet-recipe"` | `:119` | untouched | `_fernlet-recipe2._udp` + plist + no-tracking row |
| `session = MeshMultipeerSession()` | `:104` | untouched | `makeSession` factory → `NetworkRecipeShareSession` |
| `start(serviceType:discoveryInfo:)` | `:181` | untouched | `start(posture:advertisement:)`, throws |
| `discoveryInfo()` v/sid/name/mode | `:408-415` | **`name` bounded in BYTES** (§5) | becomes the TXT record |
| `invite(peer)` | `:287` | untouched | `dial(peer, helloSID:)` |
| `shouldAcceptInvitation` gate | `:377-389` | untouched | `resolveDialer` + the same three gates |
| `onPeerChannelReady` → `PeerChannelTransport` | `:368`, `:549` | untouched | `NetworkPeerChannel` |
| `onPeerDisconnected` / `onPeerLost` | `:365-376` | untouched | same hooks |
| `onTransportError` → self-stop | `:390-405` | untouched | keep; QUIC start failures only |
| `hasPendingConnections(besides:)` | `:279`, `:388` | untouched | connecting-window equivalent |
| `disconnectPeer` (best-effort kick) | `:558`, `:670`, `:828` | untouched | `endTunnel` (not best-effort) |
| **`pauseDiscovery()`** | `:608` | **through `RecipeShareDiscoveryGate`** | same call, QUIC radio |
| **`resumeDiscovery()` / `isDiscoveryPaused`** | `:720-723` | **through the gate** | same |
| self-exclusion by `sid` | `:449` | untouched | by instance name (as presence) |
| ephemeral peer id | **NOT used** — default `MeshMultipeerSession()` = the *persistent* device-name `MCPeerID` | untouched | per-`start()` fresh name + TLS identity |
| the send itself | `:847-880` | **through `RecipeShareTransfer`** | unchanged above the transport |

## 2. The values (one new file, `RecipeSharing/RecipeShareTransfer.swift`)

### 2a. `RecipeShareDiscoveryGate` — the pause/resume contract as a table

`verdict(for: Event, radio: Radio) -> Verdict`, `Radio = (isRunning, isPaused, connectionCount)`.

| Event | isRunning | isPaused | connections | Verdict | Why |
| --- | --- | --- | --- | --- | --- |
| `connectionRegistered` | any | false | ≥1 | **pause** | the one pause site |
| `connectionRegistered` | any | true | ≥1 | unchanged | idempotent |
| `connectionRegistered` | any | any | 0 | unchanged | unreachable; refuse rather than close a radio holding nothing |
| `connectionsEvicted` | true | true | 0 | **resume** | the one resume site — keyed on RECORD eviction, never on a transport disconnect |
| `connectionsEvicted` | true | true | ≥1 | unchanged | another pairing is held |
| `connectionsEvicted` | false | true | 0 | unchanged | a stopped radio must not advertise |
| `connectionsEvicted` | true | false | 0 | unchanged | never paused |
| `refreshRequested` | any | any | any | unchanged | refresh is refused while paired, and otherwise stop()+start() resets the flag in the radio |
| `transportErrorWhileListening` | any | any | any | unchanged | the manager `stop()`s; the flag resets in the radio's teardown |
| `stopped` | any | any | any | unchanged | same |

### 2b. `RecipeShareTransfer` — the exchange, with an exactly-once completion oracle

Phases `connecting → verified → sending → {sent | failed | cancelled}`; `sent/failed/cancelled` are
terminal. Events: `peerVerified`, `sendBegan(wireByteCount:)`, `sendCompleted`, `sendFailed`,
`cancelled`, `discoveryPaused`, `discoveryResumed`. `apply(_:) -> Bool` (false = refused).

| from \ event | peerVerified | sendBegan | sendCompleted | sendFailed | cancelled |
| --- | --- | --- | --- | --- | --- |
| connecting | verified | **refused** (the seal is the handshake) | **refused** | failed | cancelled |
| verified | verified (idempotent) | sending | **refused** | failed | cancelled |
| sending | sending (idempotent) | **refused** (once-only start) | sent, `completionCount += 1` | failed | cancelled |
| sent / failed / cancelled | refused | refused | **refused** | refused | refused |

**The load-bearing row:** `discoveryPaused` / `discoveryResumed` are accepted in **every** phase and
move the phase **not at all** — they only set `radioIsQuiet`. Closing the door to new peers is not
pausing a transfer in flight; a pass-2 session that implemented "pause" as "stand the connection
down" would break a send that MC keeps alive, and nobody would attribute it to the transport.

**Oracle:** `completionCount ∈ {0,1}` and `phase == .sent ⟺ completionCount == 1`, over an
exhaustive bounded walk of every event sequence of length ≤ 4 (P8's coordinator oracle shape).

**Route projection:** `route: MeshTransferRoute?` — nil until `sendBegan`, then
`MeshTransferStreamTable.route(reliableByteCount:)`. A text-only recipe (a few KiB) is
`.controlStream`; a recipe with a picture (`maxImageBytes` 512 KiB) is `.transferStream`. The count
is the **plaintext** the manager encodes and the sealed frame is larger, so the projection is a
floor, never an over-estimate. **This is the biggest pass-2 hazard: the recipe radio needs a
per-transfer-stream acceptor, which `NetworkPresenceSession` deliberately has none of.**

### 2c. `RecipeShareAdvertisedName` — the advertised name, bounded in BYTES

`publishable(_:)` = `ItemNameModeration.sanitizedName` (24 Characters, control/ZWSP/bidi out) then
drop trailing Characters, bounded by 24 iterations, until `utf8.count <= 64`
(`MeshLinkAdvertisement.maxFieldValueLength`). Today `discoveryInfo()` caps at 32 **Characters**
(`:412`); 24 CJK characters are 72 bytes and 24 emoji far more. `MeshLinkAdvertisement` **drops**
an over-long value rather than truncating it, so the naive pass-2 binding ships a picker that shows
`fernlet-mesh-ab12cd34ef56` instead of the user's name for every such user. The receiver already
re-caps at 24 Characters (`moderatedPeerDisplayName`), so this narrows the wire to what is rendered.
*Deliberate, stated behaviour narrowing in pass 1 — the one call site is `discoveryInfo()`.*

## 3. The seam

Pass 1 adds **no radio protocol**, matching item 2's own split (`PresenceRadioSession` landed in pass
2, `d7342f3` added only the value plus the manager's consult point). The manager's consult points:
`registerConnection`, `finalizeConnectionRemovals` (gate), `sendRecipeShare`,
`checkCoordinatorStates`, `sendPendingPayload`, `stop`, `refreshDiscovery`, `armConnectTimeout`
(transfer). No new radio verb — `FernletStore.executeProximityRunActions` stays the one home. No
timer. No edge-triggered listener seam: `isListening` stays `isRunning`, the radio's own level
account. No persisted surface, no keychain write, no new primitive call, no new display string.

## 4. Wire frames — pass 2's, specified here, NOT built here

* **`RecipeShareAdvertisement` (TXT)** — `v=1`, `sid=<UUID, 36>`, `name=<≤64 bytes, §2c>`,
  `mode=recipe`. Every entry ≤ 255 bytes (DNS-SD); the whole record is ~145 bytes at worst. Build it
  through `MeshLinkAdvertisement.publishedFields` (which already drops empty and over-long values).
* **`RecipeShareDialHello`** — `{v: 1, sid: <the dialer's own advertised sid>}`, length-framed with
  `NetworkMeshWire.header`, `maxEncodedBytes` ≈ 96. QUIC has no invitation carrying a browsed peer,
  so the dialer must name itself; `sid` is already on the air in its own TXT, so the hello discloses
  nothing new (the `PresenceDialHello` argument, minus tags).
* **Rejection matrix** (all refuse *before* any channel or handle exists): missing/≠1 `v`; absent or
  malformed `sid`; a `sid` no browse result carries; our OWN `sid` (self-dial); a hello over
  `maxEncodedBytes`; a second hello on one connection; a frame over
  `NetworkMeshSession.maxInboundWireBytes`; a stream that is not stream 0 when no transfer budget
  is free; an inbound connection while a pairing is held (the hard 2-device cap's four layers).

## 5. Posture — the decision

**Do NOT reuse `PresenceEpochPosture`.** It carries an `epoch` and anchors its certificate to
`IdentityService.presenceEpochStart`; a recipe radio that mints one per `start()` would wear a type
whose whole contract is "rotates every 900 s" while rotating on a tab visit — a silent mismatch. The
shape the recipe radio needs already exists and is the **mesh session's own**:
`NetworkMeshSession.start()` mints `MeshLinkAdvertisement.randomInstanceName()` + a fresh
`EphemeralMeshTLSIdentity.mint()` per start. Pass 2 copies that. **The bound: one instance name and
one certificate per Food-tab visit; no rotation timer (the one-timer wall).** No 900 s rotation
should follow in pass 2 — the radio's lifetime is the visit, and a timer would be a second one.

Residual to state in pass 2, not hide: an ephemeral instance name does **not** make a recipe
advertiser unlinkable — the TXT still carries the user's chosen `name` on purpose (the picker shows
it). What it removes is `UIDevice.current.name`, which today's persistent `MCPeerID` puts on the air
and the user never chose. Also mint `sid` per `start()` once self-exclusion moves to the instance
name (today `sid` is per app launch and links every Food-tab visit in that launch).

## 6. Files (Phase B) / drafts (Phase A)

| Draft | Repo path |
| --- | --- |
| `drafts/RecipeShareTransfer.swift` | `FernletKit/Sources/ProximityKit/RecipeSharing/RecipeShareTransfer.swift` (new) |
| `drafts/RecipeShareTransferTests.swift` | `Tests/FernletTests/RecipeShareTransferTests.swift` (new) |
| `drafts/manager.patch.md` | `FernletKit/Sources/ProximityKit/RecipeSharing/ProximityRecipeShareManager.swift` |
| `drafts/docs.patch.md` | `Docs/FileIndex.md`, `Docs/ProximityFunctionIndex.md`, `…/Documentation.docc/ProximityKit.md` |

## 7. What pass 2 binds

`NetworkRecipeShareSession.swift` on `_fernlet-recipe2._udp` (ALPN `fernlet-recipe-v1`), a
`RecipeShareRadioSession` protocol + `makeSession` factory on the manager, the Info.plist
`NSBonjourServices` row, the `NoTrackingBoundaryTests.permittedLocalLinkFiles` entry and the
`Docs/No-Tracking-Wall.md` §4c row — in the same commit. It replaces: the MC advertiser/browser, the
invitation gate (→ `resolveDialer` + dial hello), `hasPendingConnections`, the `MCPeerID` peer map
(→ `MeshSessionIdentityMap`), `PeerChannelTransport` (→ `NetworkPeerChannel`), and
`pauseDiscovery`/`resumeDiscovery` (→ the QUIC listener stand-down/re-mint). It must **add** what
presence did not need: a per-transfer-stream acceptor (§2b) and `MeshTransferStreamTable`.
`TransportNeutralityBoundaryTests`' permit list is untouched until item 4.
