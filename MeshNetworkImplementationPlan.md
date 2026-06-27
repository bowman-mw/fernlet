# Mesh Network Implementation Plan

Status: Historical implementation plan. The friend-mesh path, group encryption, security hardening, single-Join redesign, and proximity-folder consolidation have landed. Trainer connection work remains deferred.
Scope: friend mesh for nearby photo sharing, plus historical trainer-led mesh design notes. The live path builds on `MeshMultipeerSession`, `ProximityCoordinator`, `IdentityService`, and `FernletStore`.

> ## Current implementation note
> Sections below preserve the original staged design and may use historical names. The live friend-photo path routes through `Proximity/Mesh/MeshNetworkManager.swift`, `Proximity/Transport/MeshMultipeerSession.swift`, and `Proximity/Photos/MeshPhotoCacheStore.swift`. The legacy concrete `MultipeerSession`, standalone `FriendPhotoSharingService`, `FriendPhotoCacheStore`, and `MeshLobbyView` have been deleted. Wire payloads now live under `Proximity/Wire/`. Trainer transport remains intentionally deferred.

---

## 1. Goals

The current proximity stack is one-to-one. We need it to be one-to-many for two distinct cases:

1. **Friend mesh** — symmetric, up to 20 people, share photos and attachments. Anyone can rename, anyone can toggle open/closed, no creator or admin role. Ephemeral; nothing persists across app sessions beyond a 1–2 hour rejoin window.
2. **Trainer mesh** — asymmetric (one instructor, many clients). Only the instructor sends content to clients; clients send completions/responses back to the instructor only. Clients do not see each other's traffic.

Both modes run on the same transport core but diverge at the orchestration and routing layer.

---

## 2. Non-goals for v1

These are explicitly out of scope:

- Persistent mesh sessions across app restarts.
- Friend-of-friend labeling driven by real-time vouching while the mutual friend is present (the mutual friend introduces in person; no software help needed). A minimal cached-vouch mechanism is included for the absent-friend case, marked as Phase 2 below.
- Trainer-to-trainer mesh (trainers remain hub-and-spoke).
- Cloud-backed group sharing — defer until local mesh is stable, per spec §0.
- Forwarding of attachments through multi-hop routing beyond the existing manifest/request pattern. Direct multicast at send time is sufficient.
- Tamper-resistant photo provenance (defending against malicious forwarders within your friend set). Trust your friends not to lie about who originally took a photo; revisit only if abuse emerges.
- Mesh-level moderation (kicking members from the mesh). Members handle bad actors by blocking individually and toggling the mesh closed.

---

## 3. Architecture overview

Five layers, bottom to top:

1. **Transport** — `MeshMultipeerSession` owns one `MCSession`, one advertiser, one browser. Routes per-peer state and inbound messages to per-peer `PeerChannelTransport` adapters that conform to the existing `MultipeerTransport` protocol.
2. **Per-peer handshake** — existing `ProximityCoordinator`, instantiated once per peer slot. Does identity exchange, NI discovery-token exchange, tap confirmation, heartbeat RTT sampling, and fallback-mode logging.
3. **Mesh orchestration** — `MeshNetworkManager` owns the slot table (3 active + 2 lightweight = 5 transport peers max), routes outbound photos and attachments to all non-blocked active peers, filters inbound by block list, broadcasts and gossips mesh control messages.
4. **Social control plane** — `MeshSession` domain model (mesh ID, name, mode, member roster). `MeshAdmissionToken` for automatic rejoin. Name generator for initial silly names.
5. **UI and trust persistence** — `MeshLobbyView` (entry point), `FriendListView`, modified `FriendPhotoShareView`. `FernletStore` gets block methods and a `MeshNetworkManager` property.

Slot capacity (3 active + 2 lightweight = 5 transport-connected peers max) reflects the practical iOS UWB concurrency ceiling. Active slots use `NISession` when both peers exchange valid discovery tokens. Lightweight slots record RSSI/manual fallback mode via `RangingProvider.fallback(rssiOnly: true)` and carry only heartbeats and manifests, not photos; the current `MultipeerConnectivity` transport does not expose RSSI values for meter estimates.

Logical mesh roster size is decoupled from transport slots. A mesh may have up to 20 members in its roster; at any moment 0–5 of them are wire-connected to the local device. Photos route only to currently-connected active peers; absent members catch up when they reconnect via the manifest/request flow that already exists in `FriendPhotoSharingService`.

---

## 4. Wire protocol additions

### 4.1 New `PayloadType` cases

Add to `FernletIdentityEnvelope.PayloadType` in `FernletIdentityEnvelope.swift`:

```
case meshDescriptor        = "fernlet.mesh.descriptor.v1"
case meshAdmissionGrant    = "fernlet.mesh.admission.grant.v1"
case meshAdmissionToken    = "fernlet.mesh.admission.token.v1"
case meshAdmissionRequest  = "fernlet.mesh.admission.request.v1"
case meshStateChange       = "fernlet.mesh.state.v1"
case meshFriendVouchList   = "fernlet.mesh.vouch.v1"  // Phase 2; reserve now
case trainerAttachment     = "fernlet.trainer.attachment.v1"  // for trainer file send
```

All envelopes continue to be signed by the sender via the existing factory. Mesh-control envelopes are typically broadcast (`recipientFingerprint == nil`).

### 4.2 Mesh descriptor payload

The mesh descriptor is the canonical mesh definition. Any current member can re-broadcast it to newcomers. It is signed *inside the payload* by the device that last renamed/changed-state-of the mesh, so provenance survives gossip.

```swift
struct MeshDescriptor: Codable, Equatable {
    let meshID: UUID
    var name: String
    var mode: MeshMode               // .open or .closed
    var members: [MeshMember]        // current roster
    var nameSetAt: Date              // for rename last-write-wins
    var nameSetBy: String            // fingerprint
    var modeSetAt: Date              // for mode change last-write-wins
    var modeSetBy: String            // fingerprint
    var createdAt: Date
}

struct MeshMember: Codable, Equatable {
    let fingerprint: String
    var displayName: String
    let signingPublicKey: Data
    let keyAgreementPublicKey: Data
    let joinedAt: Date
}

enum MeshMode: String, Codable, Equatable {
    case open    // broadcasts, accepts new members
    case closed  // not broadcast, locked roster
}
```

Conflict resolution: when a device receives a descriptor with a name or mode that differs from its local copy, it takes the one with the later `nameSetAt` / `modeSetAt`. Ties broken by `nameSetBy` / `modeSetBy` lexicographically.

### 4.3 Admission token payload

Signed token issued by any current member to a new joiner. Used for automatic rejoin within 1–2 hours.

```swift
struct MeshAdmissionToken: Codable, Equatable {
    let meshID: UUID
    let joinerFingerprint: String
    let admitterFingerprint: String
    let grantedAt: Date
    let expiresAt: Date              // grantedAt + 2 hours
    let admitterSigningPublicKey: Data
    let admitterSignature: Data      // Ed25519 over canonical bytes with signature zeroed
}
```

Token verification mirrors envelope verification: canonical-JSON encode with signature zeroed, verify Ed25519 against `admitterSigningPublicKey`, check expiry. The admitter's public key must match either a current mesh member or a locally-trusted peer.

### 4.4 Photo payload provenance

Modify `FriendPhotoPayload` in `FriendPhotoShareView.swift` to embed original sender's fingerprint and public key. This enables block enforcement when photos arrive via the manifest/request gossip path rather than directly from the original sender.

```swift
struct FriendPhotoPayload: Codable, Equatable, Identifiable {
    let id: UUID
    let imageData: Data
    let addedAt: Date
    let senderName: String
    let senderFingerprint: String          // NEW — set at addPhotoData time
    let senderSigningPublicKey: Data       // NEW — set at addPhotoData time
}
```

Backward compatibility: decode old payloads where these fields are absent by treating them as legacy (no block enforcement, accept as before). Use `decodeIfPresent` semantics for the two new fields.

When the same pattern is applied to other attachment types later (workout files, recipe shares), use the same two-field convention.

### 4.5 Mesh state change payload

For renames, mode toggles, and explicit leaves. Body is just the updated `MeshDescriptor`. The descriptor's `nameSetAt`/`modeSetAt` timestamps drive last-write-wins. The outer envelope's signature gives authenticity for the change attempt.

```swift
struct MeshStateChangePayload: Codable, Equatable {
    let descriptor: MeshDescriptor
}
```

### 4.6 Admission request and grant payloads

Used in open meshes when a stranger asks to join. Broadcast among current members; first member to approve admits the stranger.

```swift
struct MeshAdmissionRequestPayload: Codable, Equatable {
    let meshID: UUID
    let requesterFingerprint: String
    let requesterDisplayName: String
    let requesterSigningPublicKey: Data
    let requesterKeyAgreementPublicKey: Data
}

struct MeshAdmissionGrantPayload: Codable, Equatable {
    let meshID: UUID
    let requesterFingerprint: String
    let token: MeshAdmissionToken
}
```

When a member taps "Allow" on the prompt, they sign and issue a `MeshAdmissionToken` for the requester, then broadcast a `meshAdmissionGrant`. All other members dismiss their prompts on receipt.

Rate limit: the same requester fingerprint cannot trigger fresh prompts in the same mesh for 5 minutes after a rejection.

### 4.7 Trainer attachment payload

Asymmetric trainer mesh needs a way for the instructor to send files to all clients. Defined separately from friend photos so trainer mode does not silently inherit photo-cache UI:

```swift
struct TrainerAttachmentPayload: Codable, Equatable, Identifiable {
    let id: UUID
    let kind: TrainerAttachmentKind
    let data: Data
    let senderName: String
    let senderFingerprint: String
    let sentAt: Date
}

enum TrainerAttachmentKind: String, Codable {
    case workoutPlan
    case nutritionNote
    case media
}
```

---

## 5. Transport layer

### 5.1 `MeshMultipeerSession`

New file: `MeshMultipeerSession.swift`.

Owns one `MCSession`, one `MCNearbyServiceAdvertiser`, one `MCNearbyServiceBrowser`. Replaces neither — `MultipeerSession` stays in place for 1:1 trainer mode and any other 1:1 callers.

Responsibilities:

- Start advertising and browsing on a single service type (`fernlet-friend` for friend mesh; `fernlet-coach-mesh` for trainer mesh).
- Maintain a map `[MCPeerID: PeerChannelTransport]`.
- On `MCSessionDelegate` callbacks, look up or create the per-peer `PeerChannelTransport` and forward the event to it.
- On advertiser delegate invitation, check with `MeshNetworkManager` whether to accept (slot capacity, block list, mesh open/closed state) before invoking the invitation handler.
- Expose lifecycle methods: `start(serviceType:discoveryInfo:)`, `stop()`, and `disconnect(peer:)` (best-effort; iOS doesn't provide per-peer disconnect on `MCSession`, so this sends a `sessionGoodbye` envelope and removes the local channel).

The advertiser's `discoveryInfo` for friend mesh includes:

```
v        = "1"
role     = "peer"
fp       = local fingerprint
name     = local display name (capped 32 chars)
mesh     = mesh ID (UUID string) if currently in a mesh
meshName = mesh name if mesh.mode == .open
```

For closed meshes, omit `mesh` and `meshName` entirely. The closed mesh is invisible to non-members.

### 5.2 `PeerChannelTransport`

New file (can live in the same `MeshMultipeerSession.swift`).

A per-peer adapter conforming to the existing `MultipeerTransport` protocol. One instance per peer slot. Wraps `MeshMultipeerSession` so an unchanged `ProximityCoordinator` can drive identity verification for its specific peer.

```swift
@MainActor
final class PeerChannelTransport: MultipeerTransport {
    private weak var session: MeshMultipeerSession?
    let peer: MultipeerPeer
    
    private let stateSubject = CurrentValueSubject<MultipeerSession.State, Never>(.idle)
    private let inboundSubject = PassthroughSubject<MultipeerSession.InboundMessage, Never>()
    
    var state: AnyPublisher<MultipeerSession.State, Never> { stateSubject.eraseToAnyPublisher() }
    var inbound: AnyPublisher<MultipeerSession.InboundMessage, Never> { inboundSubject.eraseToAnyPublisher() }
    var connectedPeers: [MultipeerPeer] { /* just this.peer if connected, else [] */ }
    
    // Feed methods called by MeshMultipeerSession when MCSession events arrive for this peer
    func feedState(_ s: MultipeerSession.State) { stateSubject.send(s) }
    func feedInbound(_ msg: MultipeerSession.InboundMessage) { inboundSubject.send(msg) }
    
    // MultipeerTransport conformance
    func startAdvertising(serviceType: String, discoveryInfo: [String: String]) async throws {
        // No-op. MeshMultipeerSession handles advertising centrally.
    }
    func startBrowsing(serviceType: String) async throws {
        // No-op.
    }
    func invite(_ peer: MultipeerPeer) async throws {
        try await session?.invite(peer)
    }
    func accept(_ invite: MultipeerSession.PendingInvite) async throws {
        invite.respond(true)
        stateSubject.send(.connecting(invite.peer))
    }
    func send(_ data: Data, to peer: MultipeerPeer, mode: MCSessionSendDataMode) async throws {
        try await session?.send(data, to: peer, mode: mode)
    }
    func disconnect() async {
        await session?.disconnect(peer: peer)
    }
}
```

Key invariant: each transport instance only ever sees events relating to its own peer. The mesh session does the filtering.

### 5.3 `ProximityCoordinator` (unchanged)

The existing coordinator works as-is when wrapped per-peer. A few flow points to verify during implementation:

- `begin(role:mode:)` calls `transport.disconnect()` first — this becomes a no-op on `PeerChannelTransport` (only this peer's channel resets). Fine.
- The fingerprint tiebreaker in `shouldInviteDiscoveredPeer` continues to decide which side initiates. The losing side waits in `peerInRange`. When the winning side's invite arrives at the advertiser delegate, route it to the *existing* `PeerChannelTransport` for that peer (look it up by `MCPeerID`); the coordinator already handles `.awaitingLocalAcceptance` correctly from there.
- `autoReconnect` in friend mode triggers `beginFriendJoin()` after `.transportLost`. In the mesh, this still works but should be intercepted by `MeshNetworkManager` so reconnects use the admission token rather than starting a fresh handshake.

---

## 6. Mesh orchestration: `MeshNetworkManager`

New file: `MeshNetworkManager.swift`.

`@MainActor` `ObservableObject`. Owns the slot table, the current `MeshDescriptor` (if any), the cached `MeshAdmissionToken` (if rejoining), and the published state the UI binds against.

### 6.1 Published properties

```swift
@Published private(set) var slots: [PeerSlot]                  // ordered by distance
@Published private(set) var currentMesh: MeshDescriptor?       // nil = not in a mesh
@Published private(set) var pendingAdmissionRequests: [MeshAdmissionRequestPayload]
@Published private(set) var lobbyMeshes: [LobbyMeshSummary]    // visible open meshes nearby
@Published private(set) var lobbyIndividuals: [LobbyIndividual]
@Published private(set) var meshError: String?
```

`PeerSlot` bundles the peer's `ProximityCoordinator`, `PeerChannelTransport`, last known distance, current allocation (`.active` or `.lightweight`), and a `subscribers` `Set<AnyCancellable>` for coordinator state observation.

### 6.2 Slot allocation rules

Cap at 5 transport-connected peers total. Among peers with UWB samples, the 3 nearest by `lastKnownDistance` are `.active` (UWB ranging on, full payload routing). The remaining 2 are `.lightweight` (manual/RSSI fallback mode, heartbeats and manifests only).

Phase 1 implementation: until UWB distance data arrives (after post-identity NI token exchange and `NIRangingSession.start(with:)`), treat the first 3 connected slots as active and the next 2 as lightweight. Once distance measurements stabilize (5 samples over 10 seconds), rerank. Peers without UWB samples stay eligible for lightweight slots only; do not invent meter estimates from RSSI fallback state.

Promotion: a lightweight slot becomes active when one of the 3 actives goes farther away than the lightweight does, by more than a 20% hysteresis margin (prevents thrashing).

Demotion: when promoting, the displaced active slot becomes lightweight (don't disconnect it — just stop UWB ranging and switch its routing class).

Overflow: when a 6th peer is discovered while at capacity, ignore them in Phase 1. Phase 2 may evict the most-distant lightweight slot if the newcomer is closer than it (by hysteresis margin). Mark this as a follow-up.

### 6.3 Inbound routing

`MeshMultipeerSession` forwards inbound `MultipeerSession.InboundMessage` to the appropriate `PeerChannelTransport`. The transport publishes to its `ProximityCoordinator`. The coordinator decodes the envelope, verifies the signature, checks the replay cache, starts UWB when identity intro/ack payloads include peer NI tokens, records heartbeat RTT from ping/ack envelopes, and either handles built-in control messages internally or forwards feature payloads through `ProximityPayloadHandling`.

`MeshNetworkManager` conforms to `ProximityPayloadHandling` and is attached as the payload handler on every coordinator. On `proximityCoordinator(_:didReceive:plaintext:from:)`:

1. **Block check first**: if `store.isBlockedFingerprint(envelope.senderFingerprint)`, drop silently. No audit log entry visible to the sender. Do not forward to downstream consumers.
2. Dispatch by payload type:
   - `meshDescriptor` and `meshStateChange` → merge into `currentMesh` using last-write-wins on timestamps. If `currentMesh == nil` (we just joined), set it.
   - `meshAdmissionRequest` → append to `pendingAdmissionRequests`. UI shows a prompt sheet. (Only when in open mesh; ignore in closed.)
   - `meshAdmissionGrant` → if our local pending-request matches, treat ourselves as admitted: cache the token in keychain, switch to "in mesh" state. Other members on receipt dismiss their local prompts for that requester.
   - `meshAdmissionToken` → received from a rejoining peer. Verify the token's `admitterSignature` against either current roster or trusted peers. If valid and unexpired, admit; broadcast updated `meshDescriptor` with the rejoiner appended.
   - `friendPhoto` / `friendPhotoManifest` / `friendPhotoRequest` → forward to `FriendPhotoSharingService`. Service handles dedup and caching as today.
   - `trainerAttachment` → forward to trainer surface (see §10).
   - `meshFriendVouchList` → Phase 2; cache for future friend-of-friend labeling.

### 6.4 Outbound routing

Two send methods:

```swift
func broadcast(_ envelope: FernletIdentityEnvelope) async
func sendToActives(_ envelope: FernletIdentityEnvelope) async
```

`broadcast` sends to all currently-connected peers (active + lightweight). Used for mesh control plane: descriptor, state change, admission requests/grants.

`sendToActives` sends only to active slots. Used for photos and attachments. Filters out blocked fingerprints before sending.

Both methods iterate the slot table and call each `PeerSlot.coordinator.send(envelope)`. Errors per peer are collected into `meshError` but do not abort the broadcast.

### 6.5 Mesh creation, join, leave

`startNewMesh(name: String? = nil)` — generates a `MeshDescriptor` with a fresh UUID, a name from the silly-name generator (if `name` is nil), `mode = .open`, and `members = [selfMember]`. Starts `MeshMultipeerSession.start(serviceType: "fernlet-friend", discoveryInfo: ...)`. As peers join, `currentMesh.members` grows; the manager broadcasts the updated descriptor.

`joinMesh(_ summary: LobbyMeshSummary)` — connects to the nearest member of the target mesh (the one whose advertised `mesh` UUID matches). After identity verification, exchanges an admission request → grant → cache token → adopt the mesh descriptor received from the admitter.

`leaveMesh()` — sends `sessionGoodbye` to all peers, stops the mesh session, clears `currentMesh` and `pendingAdmissionRequests`, and **deletes all photos and attachments associated with the mesh from `FriendPhotoCacheStore`** (see §9 on closed-mode deletion semantics; the same wipe runs on any leave for simplicity, but the user can also pre-save photos via the existing review sheet).

`renameMesh(_ newName: String)` — only allowed in open mode. Constructs a new `MeshDescriptor` with `name = newName`, `nameSetAt = now`, `nameSetBy = localFingerprint`. Broadcasts as `meshStateChange`.

`setMeshMode(_ mode: MeshMode)` — same pattern. When toggling to `.closed`, immediately stop broadcasting `mesh`/`meshName` in `discoveryInfo` and refuse all new invitations. When toggling back to `.open`, resume broadcasting.

### 6.6 Automatic rejoin

When `ProximityCoordinator` reports `.transportLost`, `MeshNetworkManager` checks: do we have an unexpired `MeshAdmissionToken` for the mesh we just dropped from? If yes:

1. Keep `MeshMultipeerSession` running with the same discoveryInfo (so other members see us as still part of the mesh).
2. On any peer reappearing in the lobby that advertises the same `mesh` UUID, automatically invite them.
3. After identity verification, send the cached `meshAdmissionToken`. The receiving peer verifies and re-admits without prompting.
4. If no admission token is presented within the timeout, or if the token is rejected, fall back to lobby state and surface the failure non-modally.

Token TTL is `grantedAt + 2 hours`. After expiry, the rejoin path fails and the user has to re-request to join. No persistent state is kept across app launches.

### 6.7 Proximity-join and disposable-camera session (Life-tab redesign)

**Proximity-join** replaces the lobby browse model for the Connect surface. Calling `startJoin()` advertises + browses `fernlet-friend`, auto-invites every peer that connects, and gates commitment on a **15 cm / 0.8 s** dwell via `ProximityCommitDetector` (UWB) or an on-screen confirm (non-UWB). The manager drives shape automatically: one committed peer = pairwise (no `MeshDescriptor`); two or more = call `promoteToMesh()` in-place. Uncommitted channels have a 25 s TTL. `isInSession` is a computed property that returns `true` when `currentMesh != nil` or any slot has `fingerprint != nil`.

**Disposable-camera session** (`DisposableCameraView`): When `isInSession` is true, `ConnectView` shows a full-screen camera body with a small live `AVCaptureSession` viewfinder, a film counter (`filmRemaining = max(0, 27 − photosAddedThisSession)`), a shutter that is inert unless armed, and a right-side thumbwheel `DragGesture` that re-arms between shots. Each capture feeds `addPhoto(_:)` unchanged — normalization, quota enforcement (27 per sender), encryption, and broadcast all apply. Photos taken/received during the session are tracked in `sessionPhotos: [FriendPhotoPayload]`. On "Develop", `FriendPhotoReviewSheet` is presented; on save or discard, `leaveSession()` clears `sessionPhotos` and calls `leaveMesh()`.

`leaveSession()` is the unified leave for both pairwise and mesh; `leaveMesh()` still works directly for the non-Connect paths.

---

## 7. Naming the mesh

New file: `MeshNameGenerator.swift`.

Generates a random two-word name like "purple-otter" or "sleepy-volcano." Bundle two short word lists (~80 adjectives, ~80 nouns) as Swift arrays. The function signature:

```swift
enum MeshNameGenerator {
    static func generate() -> String  // e.g., "purple-otter"
}
```

Convention: lowercase, hyphen-separated, max 30 characters. Always two words. Adjective first.

When a user renames, accept any string up to 60 characters trimmed of whitespace. Reject empty strings (revert to current name).

---

## 8. Open versus closed mode

The single switch determines visibility and admission. There is no creator, no admin, no special privilege.

**Open**:
- `discoveryInfo` includes `mesh` and `meshName`. Mesh appears in nearby lobbies.
- Stranger requests to join trigger a `meshAdmissionRequest` broadcast.
- Every current member receives a prompt sheet (see §11.3). First member to tap "Allow" admits; others' prompts dismiss.
- Decline path: any member tapping "Decline" broadcasts a soft signal; rate limits prevent re-prompting from the same fingerprint for 5 minutes.

**Closed**:
- `discoveryInfo` omits `mesh` and `meshName`. The mesh is invisible to anyone not already in it.
- No admission flow runs. No prompts appear anywhere.
- Members can still rejoin via cached admission token if they drop briefly.
- Renames still work among existing members.

Mode toggle is open to anyone in the mesh. Last-write-wins by timestamp.

Closed mode is the "we are out and about and don't want random taps" mode. The expected flow: start the mesh open, gather your group, toggle closed. Going back to open re-broadcasts.

---

## 9. Block model and content provenance

### 9.1 Block as a unified action

Per your decision, blocking removes from friends. Implement as a single transition. In `TrainerAuditLog.swift`, add to `ProximityTrustedPeerRecord`:

```swift
var blockedAt: Date?
```

A peer is *blocked* when `blockedAt != nil`. The existing `revokedAt` field stays as-is — `revokedAt` means the key was rotated/wiped; `blockedAt` is a social action. Both result in dropping envelopes from that key.

### 9.2 `FernletStore` methods

Add to `FernletStore.swift`:

```swift
func blockProximityPeer(fingerprint: String) {
    batchSnapshotPersistence {
        if let i = trustedProximityPeers.firstIndex(where: { $0.fingerprint == fingerprint }) {
            trustedProximityPeers[i].blockedAt = Date()
            // blockedAt also implies not-a-friend-anymore per spec
            trustedProximityPeers[i].revokedAt = Date()
        }
        // ... audit log entry
    }
}

func unblockProximityPeer(fingerprint: String) { /* clear both fields */ }

func isBlockedFingerprint(_ fingerprint: String) -> Bool {
    trustedProximityPeers.contains { $0.fingerprint == fingerprint && $0.blockedAt != nil }
}

func isBlockedProximitySigningKey(_ publicKey: Data) -> Bool {
    isBlockedFingerprint(IdentityService.fingerprint(of: publicKey))
}
```

Unblock restores neither friendship nor key validity automatically. The user must re-handshake to re-friend.

### 9.3 Block enforcement points

Three places enforce the block list:

1. **`MeshMultipeerSession` advertiser delegate** — refuse invitations whose discoveryInfo `fp` is blocked. Do not surface as a prompt.
2. **`ProximityCoordinator.handleInbound`** — alongside the existing `isRevokedProximitySigningKey` check, drop envelopes where `isBlockedProximitySigningKey(envelope.senderSigningPublicKey)` is true. Do not record receipt in the audit log (silent drop).
3. **`MeshNetworkManager` payload handler** — additional defense for payload-embedded provenance (photos, attachments). Check `senderFingerprint` on `FriendPhotoPayload` and `TrainerAttachmentPayload` against the block list before passing to consumers.
4. **`MeshNetworkManager.sendToActives`** — filter the destination slot list before transmitting. A blocked peer who is somehow still wire-connected receives nothing further.

Outbound symmetry: when blocking, also break the live transport connection to that peer (call `disconnect(peer:)` on the mesh session). This guarantees the constraint "blocked users cannot send nor receive."

### 9.4 Photo provenance

Augment `FriendPhotoPayload` with the two fields shown in §4.4. Set both at `addPhotoData` time using the local `IdentityService`. Preserve through forwarding (the manifest/request flow already preserves the payload; nothing else changes).

`FriendPhotoSharingService.proximityCoordinator(_:didReceive:plaintext:from:)` adds a block check on the decoded `FriendPhotoPayload.senderFingerprint` before caching.

### 9.5 Cache cap

Bump `FriendPhotoCacheStore` cap from 50 to 200. The cap stays a hard FIFO at 200 (sorted by `addedAt` descending). With a 20-person mesh and an implicit per-person quota of 10, 200 is the worst-case ceiling.

No per-sender enforcement at the receiving device — the cap is global and FIFO. Per-sender quota can be enforced at the sending device (sender's UI declines to add more than 10 to a single mesh session).

---

## 10. Trainer mesh (asymmetric)

Trainer mesh runs on the same transport core but with different routing rules. Use a separate service type `fernlet-coach-mesh` to keep it distinct from the friend mesh and from 1:1 trainer mode (which keeps service type `fernlet-coach`).

### 10.1 Topology

Hub-and-spoke. The instructor is the hub. Each client is a spoke. Clients do not see each other on the wire — the instructor advertises and accepts; clients browse and invite the instructor only.

For an instructor connected to N clients, the instructor's `MeshMultipeerSession` may have N transport peers, all in active or lightweight slots per the same 3+2 rules. Distance ranking still applies (closest clients get UWB ranging).

For a client, the mesh session has exactly one peer: the instructor. Slot rules are trivial.

### 10.2 Routing rules

`MeshNetworkManager` exposes a `role: TrainerMeshRole?` property — `.instructor`, `.client`, or `nil` for friend mesh.

When `role == .instructor`:
- `sendTrainerAttachment(_ payload: TrainerAttachmentPayload)` broadcasts to all client slots.
- Inbound `workoutCompletion` and `workoutLiveUpdate` payloads from any client are routed to the trainer surface.

When `role == .client`:
- The send path is restricted to envelopes addressed to the instructor's fingerprint only.
- Inbound `trainerAttachment` and `trainerPlan` / `trainerPlanDelta` are routed to the local plan store.
- Inbound traffic from any other client (which shouldn't happen given hub-and-spoke advertising, but defense in depth) is dropped.

### 10.3 Discovery info for trainer mesh

Instructor:
```
v        = "1"
role     = "instructor"
fp       = local fingerprint
name     = display name
class    = mesh ID (UUID string)
className = mesh name if mode == .open
```

Client (browse-only, doesn't advertise the class):
```
v        = "1"
role     = "client"
fp       = local fingerprint
name     = display name
```

Clients only invite peers whose advertised `role == "instructor"`. Instructors only accept invites from peers with `role == "client"`.

### 10.4 UI shape

Defer trainer-mesh UI work to its own phase. For v1 of this plan, implement the routing primitives only. The existing trainer 1:1 UI continues to work unchanged.

---

## 11. UI specs

### 11.1 `MeshLobbyView`

New file: `MeshLobbyView.swift`. Replaces the current "Connection" controls section in `FriendPhotoShareView` as the entry point.

States:

- **Not searching** — call-to-action button "Find friends" and "Start new mesh." Tap "Find friends" begins discovery (`MeshNetworkManager.startLobby()`).
- **Searching, no results** — spinner + "Looking for friends nearby."
- **Searching, with results** — two sections:
  - "Open meshes nearby" — each row shows mesh name, member count, and a stacked badge area:
    - "X friends here" (count of mesh members in your friends list)
    - One small avatar/name per friend present (max 3 visible, "+N more" overflow)
  - "Friends nearby" — individuals not currently in a mesh. Each row: name, "Friend" or "Stranger" badge.
- **In a mesh** — switches to the mesh detail layout (§11.2).

Row actions:
- Tap a mesh → join (sends an admission request).
- Tap a friend nearby → invite them into a fresh open mesh (or your current mesh).
- Tap a stranger nearby → invite them into a fresh open mesh.

### 11.2 Mesh detail (inside `FriendPhotoShareView`)

When `MeshNetworkManager.currentMesh != nil`, show:

- Mesh name as a tappable label (tap to rename if open mode; sheet with text field).
- Open/closed segmented control. Toggling broadcasts a state change.
- Member roster as a horizontal scrolling list of avatars with display names underneath. Each member's badge:
  - "You" (the local user)
  - "Friend" (in your trusted peers list)
  - "Friend of Aisha" (Phase 2, cached vouch matches)
  - "Stranger" (otherwise)
- Per-member tap → action sheet: "Block."
- Photo grid as today, fed from `FriendPhotoSharingService.sharedPhotos`.
- "Add pictures" button (existing `PhotosPicker`).
- "Leave mesh" button at the bottom. Confirmation alert mentions "All photos in this mesh will be deleted unless you save them first."

### 11.3 `MeshAdmissionPromptSheet`

Modal sheet shown when `pendingAdmissionRequests` is non-empty (open mesh only). Shows one request at a time; subsequent requests queue.

Content:
- "X wants to join Y" where X is the requester's display name and Y is the mesh name.
- Fingerprint shown small (helps users verify with the requester in person).
- "Friend of Aisha" badge if applicable (Phase 2).
- Two buttons: "Allow" and "Decline."

Allowing constructs a `MeshAdmissionToken` signed by the local user, broadcasts the `meshAdmissionGrant`, and adds the requester to the local mesh roster (which then propagates via descriptor broadcast).

Declining broadcasts a soft signal so other members' prompts don't auto-dismiss. The requester is shown "your join request was declined" in their lobby. Rate limit re-requests from the same fingerprint to once per 5 minutes per mesh.

### 11.4 `FriendListView`

New file: `FriendListView.swift`. Reached from `SettingsSheet` ("Friends" section) and from `SocialHubView` (a "Friends" tab).

Top of view:
- Search field (filters by display name and fingerprint).
- Segmented control: "All / Friends / Blocked / Inactive (no contact in 30d)."
- Sort menu: "Recently active / Name / First met."

Each row:
- Display name.
- Fingerprint (small, monospace).
- Last seen (relative date).
- Badge: "Friend" or "Blocked."

Row tap → detail view with:
- Full peer record fields.
- "Block" button if not blocked.
- "Unblock" button if blocked.
- "Remove" button (sets `revokedAt`; future handshakes require fresh confirmation).

Blocking shows a confirmation: "Blocking X will hide their content from you and yours from them. They may still see your device name nearby. This will also remove them from your friends list."

### 11.5 `SocialHubView` change

Add a new section case to `SocialHubSection`:

```swift
case friends = "Friends"
case mesh = "Meshes"
```

The "Friends" tab opens `FriendListView`. The "Meshes" tab opens the new `MeshLobbyView` and, when in a mesh, the mesh detail view. The existing single `FriendPhotoShareView` collapses into "Meshes."

### 11.6 `SettingsSheet` change

In the existing `Section("Friends")` block in `SettingsSheet.swift`, add a `NavigationLink("Friends and blocks")` row that pushes `FriendListView`.

---

## 12. File-by-file plan

### 12.1 New files

| File | Purpose |
| --- | --- |
| `MeshMultipeerSession.swift` | Shared MCSession + advertiser + browser. Per-peer event routing. Contains `PeerChannelTransport`. |
| `MeshNetworkManager.swift` | Slot allocation, distance ranking, routing, admission flow, mesh lifecycle. |
| `MeshSession.swift` | `MeshDescriptor`, `MeshMember`, `MeshMode` value types. Pure data. |
| `MeshAdmissionToken.swift` | Token struct + sign and verify helpers. |
| `MeshNameGenerator.swift` | Two-word silly-name generator. Bundled word lists as Swift arrays. |
| `MeshLobbyView.swift` | Lobby UI: nearby meshes, nearby friends, join/start actions. |
| `MeshAdmissionPromptSheet.swift` | Modal shown to mesh members when a stranger requests to join. |
| `FriendListView.swift` | Trusted-peer management UI with search, filter, sort, block/unblock/remove. |

### 12.2 Modified files

| File | Change |
| --- | --- |
| `FernletIdentityEnvelope.swift` | Add new `PayloadType` cases (§4.1). |
| `TrainerAuditLog.swift` | Add `blockedAt: Date?` to `ProximityTrustedPeerRecord`. Initializer and `init(from decoder:)` use default value for backward compat. |
| `FernletStore.swift` | Add `blockProximityPeer`, `unblockProximityPeer`, `isBlockedFingerprint`, `isBlockedProximitySigningKey`. Add `meshNetworkManager` property (lazy, initialized when first accessed). |
| `LocalFernletRepository.swift` | Decoders use `decodeIfPresent` for `blockedAt` to handle pre-migration snapshots. No other changes needed since `ProximityTrustedPeerRecord` is already persisted. |
| `ProximityCoordinator.swift` | Add a single block-check line in `handleInbound` next to the existing revoked-key check. No state-machine changes. |
| `FriendPhotoShareView.swift` | Split `FriendPhotoSharingService` to delegate transport to `MeshNetworkManager` rather than owning a single `ProximityCoordinator`. Add `senderFingerprint` and `senderSigningPublicKey` to `FriendPhotoPayload`. Bump cache cap to 200. Add block-check on inbound photos. The view itself defers most state to `MeshLobbyView`/mesh detail; this file becomes thinner. |
| `SocialHubView.swift` | Add `friends` and `mesh` cases to `SocialHubSection`. Wire to `FriendListView` and `MeshLobbyView`. |
| `SettingsSheet.swift` | Add `NavigationLink("Friends and blocks")` to the `Friends` section. |
| `FileIndex.md` | Add entries for new files. |

### 12.3 Files explicitly not touched

| File | Reason |
| --- | --- |
| `MultipeerSession.swift` | Stays the 1:1 transport implementation. Used by trainer 1:1 mode. |
| `ProximityCoordinator.swift` state machine | Works correctly per-peer when fed via `PeerChannelTransport`; keep identity intro/ack NI-token exchange and heartbeat RTT handling enabled for every peer slot. |
| `IdentityService.swift` | No changes. |
| `NIRangingSession.swift` | One ranging instance per active slot. Hardware concurrency limit (~3) already aligns with our active-slot cap. |
| `ReplayCache.swift` | Shared cache across all coordinators in a mesh is fine since envelope IDs are UUIDs. |

---

## 13. Phasing

Three phases. Phase 1 ships a working friend mesh. Phase 2 adds polish and the deferred friend-of-friend feature. Phase 3 adds application-layer group encryption for photos (see §17).

### 13.1 Phase 1 (target: friend mesh works end-to-end)

In order:

1. **Wire protocol additions** — new `PayloadType` cases, `MeshDescriptor`, `MeshAdmissionToken`, photo payload provenance fields. Compiles, unit tests for canonical encoding of new structs.
2. **Transport core** — `MeshMultipeerSession` + `PeerChannelTransport`. Unit tests that delegate callbacks route correctly to per-peer channels.
3. **`MeshNetworkManager` skeleton** — slot table, basic start/stop, no distance ranking yet. Phase 1a uses connect-order-wins for slot allocation; distance ranking is Phase 1b.
4. **Mesh creation and join (open mode only)** — silly-name generator, mesh descriptor exchange, admission request/grant flow, admission token issuance.
5. **Block model** — `blockedAt` field, store methods, enforcement at the four points listed in §9.3.
6. **Photo routing through mesh** — refactor `FriendPhotoSharingService` to use `MeshNetworkManager.sendToActives`. Preserve existing manifest/request semantics. Verify dedup works with multiple concurrent senders.
7. **Closed mode toggle** — invisible advertising, refuse new invitations. UI toggle.
8. **Rename** — broadcast `meshStateChange`, last-write-wins reconciliation.
9. **Automatic rejoin** — cached admission token, reuse on reconnect within 2 hours.
10. **UI: `MeshLobbyView`, mesh detail, `MeshAdmissionPromptSheet`, `FriendListView`**.
11. **Distance ranking and lightweight-slot promotion/demotion (Phase 1b)** — only after the rest is stable.

### 13.2 Phase 2 (polish + deferred)

Phase 2 is not ready to start until these Phase 1/1b gates are complete and verified:

- `MeshMultipeerSession.start` can run with an explicit service type. Friend mesh uses `fernlet-friend`; trainer mesh uses `fernlet-coach-mesh`.
- Closed friend meshes omit mesh identifiers from `discoveryInfo`, and admission prompts are suppressed while closed.
- Slot records include UWB distance samples and stable active/lightweight ranking. Overflow eviction depends on real distance data; do not implement it against connect order.
- Photo manifests carry per-photo sender provenance so blocked-origin photos can be filtered before request.
- There are interaction tests for two-device join, manifest/request sync, blocked-origin forwarding, closed-mode advertising, and admission-token rejoin.

Once those gates are green, implement Phase 2 in this order:

1. **Trainer mesh routing primitives** — add `TrainerMeshRole` (`.instructor`, `.client`), parameterize the mesh service type, and add routing sinks for `trainerAttachment`, `trainerPlan`, `trainerPlanDelta`, `workoutCompletion`, and `workoutLiveUpdate`. Instructor fans out attachments/plans to client slots; clients send completions/live updates only to the instructor fingerprint and drop any non-instructor traffic. New trainer mesh UI remains deferred.
2. **Friend-of-friend labels via cached vouches** — define `MeshFriendVouchListPayload` as a privacy-bounded list of currently trusted fingerprints, exchanged only after a successful trusted handshake. Cache by voucher fingerprint with an expiry (default: 2 hours, matching admission tokens), never persist across app launches, and use only for labels such as "Friend of Aisha." Do not auto-admit based on vouches.
3. **Overflow eviction** — when at 5 slots and a newly discovered peer has enough recent UWB samples to compare, evict the most-distant lightweight slot only if the newcomer is closer by the existing 20% hysteresis margin. Send `sessionGoodbye` before removing the local channel. If the newcomer has no UWB samples, keep the current Phase 1 behavior and ignore them.
4. **Per-sender quota on send** — enforce a local UI limit of 10 photos added by this device per `currentMesh.meshID` session. Reset the counter on `leaveMesh()` or when `currentMesh` changes. This is a sender-side guard only; receivers continue using the global FIFO cache cap.

---

## 14. Behavior specifications and edge cases

### 14.1 Two devices both starting a mesh in the same airspace

If both Alice and Bob independently tap "Start new mesh" within seconds of each other, both will be advertising distinct `mesh` UUIDs with distinct names. Each sees the other in the lobby as a separate mesh. No merge logic. Either one can tap the other's mesh and join, abandoning their own.

If a third user Carlos opens the lobby, he sees both meshes and picks one. Standard behavior.

### 14.2 Concurrent renames

Alice renames to "river-trip" at t=10s. Bob renames to "morning-walk" at t=11s. The later-timestamped change wins everywhere; ties break lexicographically on `nameSetBy` fingerprint. All devices converge within one descriptor-broadcast round trip.

### 14.3 Concurrent mode toggle

Same rule. If Alice toggles to closed at t=10s and Bob toggles to open at t=11s, the mesh ends up open. Last-write-wins.

### 14.4 Splitting and rejoining

If three members are in a mesh and Alice walks out of range, the remaining two stay connected. Alice's local `currentMesh` shows the mesh still active (no transport peers). When she walks back into range within 2 hours, her cached admission token re-admits her automatically; the descriptor updates everywhere.

After 2 hours, the token expires. Alice's device clears `currentMesh`. To rejoin she taps the mesh in the lobby and requests admission again.

### 14.5 Member count exceeds 20

Hard refuse new admissions when `currentMesh.members.count >= 20`. The admission request sheet shows the requester but the "Allow" action surfaces a banner: "Mesh is full." Decline-only. No silent drop — the requester needs to know.

### 14.6 Blocking someone who is in the mesh with you

Local effect: the blocked peer's wire connection is dropped immediately. Their `senderFingerprint` is added to the block list. All cached photos from them are removed from local cache.

Remote effect on the blocked party: their device detects transport loss to you and either reconnects (if mesh allows) or doesn't (if you're the only path). They do not receive a notification that you blocked them.

Other mesh members: unaffected. They still see content from the blocked peer (since they haven't blocked them).

### 14.7 Lossy delivery

Mesh control plane envelopes (descriptor, state change) use `.reliable` send mode. Heartbeats use `.unreliable`. Photo content uses `.reliable`. Manifests use `.reliable`. This matches the existing `ProximityCoordinator.sendPayload` defaults.

---

## 15. Testing recommendations

Prioritize integration tests over unit tests for this work; the bugs will be in the interactions.

- **Two-device mesh creation** — Alice creates, Bob joins, descriptors converge, photo flows in both directions.
- **Three-device mesh with one transient disconnect** — Carlos joins, Bob walks away for 30 seconds, Bob reappears, automatic rejoin via cached token succeeds, no prompt shown.
- **Blocked sender forwarding** — Alice blocks Carlos. Bob (not blocked) caches one of Carlos's photos. Bob's manifest reaches Alice. Alice does not request Carlos's photo (block check on the manifest payload's photo IDs requires tagging the manifest with per-photo provenance — see implementation note below).
- **Open-to-closed toggle while a stranger is mid-admission-request** — toggling closed should cancel any pending admission requests and stop further prompts.
- **Concurrent renames** — simulate two devices renaming within 100ms of each other; assert eventual consistency.
- **Mesh full** — 20 members, 21st requests join, all members see "mesh full" non-modal banner.
- **Token expiry** — cached admission token >2h old is rejected; user must re-request to join.

Implementation note on the manifest + block case: the current manifest is just `[UUID]`. For block filtering on manifests, extend the manifest payload to be `[(UUID, senderFingerprint)]` so the requester can pre-filter blocked-origin photo IDs before requesting them. This is a small wire change worth including in Phase 1.

---

## 16. Open items for implementer to flag, not guess

These are not blockers — note them and proceed with the documented default, but flag them in PR description so the product owner can confirm:

1. **Silly name word lists** — implementer picks the seed words. Aim for warm/friendly tone consistent with Fernlet's gentle voice (no aggressive, edgy, or trendy slang; nothing referencing specific brands, public figures, or potentially distressing topics). 80 adjectives + 80 nouns gives 6,400 combinations; collisions are tolerable.
2. **Block confirmation copy** — the suggested text in §11.4 is a starting point; the voice should match the rest of Fernlet's tone-of-voice guidelines (see spec §1 axioms).
3. **Empty-state copy for the lobby** ("Looking for friends nearby") — same voice consideration.
4. **`MeshNetworkManager` instantiation site** — recommended: lazy property on `FernletStore`, created on first access from a view. Alternative: top-level injection in `FernletApp.swift`. Pick whichever fits the existing dependency-injection conventions.
5. **UI for trainer mesh** — Phase 2. Get the routing primitives in first; the UI lands in a follow-up plan.

---

## 17. Phase 3: Group symmetric encryption for photos

### Phase 3 — Pre-Ship Review Issues (address during Phase 3 implementation)

Five issues identified in the 2026-05-28 architecture audit; fix these within Phase 3 before it ships. Phase 3 and Phase 4 should be implemented together so confidentiality ships alongside the trust and transport fixes.

1. **Roster keys are trusted from gossip.** Key wrapping in Step 3 (§17.7) uses `member.keyAgreementPublicKey` from `currentMesh.members`, and the descriptor is last-write-wins from any member. A malicious member could broadcast a descriptor swapping another member's KA key and capture that member's wrapped group key. **Fix:** bind each member's KA key to the value verified during handshake (`ProximityCoordinator.PeerIdentity.keyAgreementPublicKey`), not to descriptor gossip. Reject rotation key-wraps for a member whose roster KA key ≠ handshake-verified KA key.

2. **Coordinator-election griefing.** A low-fingerprint member can claim coordinator and broadcast a far-future `nextRotationAt` to stall rotations or announce bogus epochs. **Fix:** honor a beacon only if its `coordinatorFingerprint` equals the locally-computed election winner among verified connected members; ignore beacons from non-elected fingerprints; clamp `nextRotationAt` to within one expected window of now.

3. **Ack-timeout exclusion is a soft DoS vector.** A slow-but-legitimate member missing the 10-second ack window is excluded and forced to re-admit. This is acceptable behavior — document it in code and UI, and consider a longer grace period for known-good members.

4. **Epoch-0 photos are unencrypted on the wire.** Solo/pre-rotation photos (§17.2/§17.11) are sent without encryption. Document this clearly: closed mode does **not** retroactively protect epoch-0 content.

5. **Phase 3 does not fix SEC-1/2/6.** Group encryption adds confidentiality but inherits fingerprint-keyed trust (SEC-1), optional transport encryption unless changed (SEC-2), and no friend proximity gate (SEC-6). Implement Phase 4 concurrently — Phase 3 alone is not sufficient hardening.

---

Phase 3 adds application-layer encryption using a shared group key. All photos are always encrypted regardless of mesh mode. When the mesh is closed, manifest entries, member identities, and state-change payloads are also encrypted, making the session opaque to any observer who cannot hold the current key. The key rotates on a 15-minute interval driven by a coordinator beacon that is integrated with the mesh heartbeat, so any member can take over the rotation schedule if the coordinator drops. New members who join cannot decrypt photos or metadata from epochs before they arrived. No previous-epoch key is ever shared with a late joiner.

### 17.1 Gates before starting Phase 3

- Phase 2 is fully shipped and stable.
- `IdentityService` provisions key agreement keys (`localKeyAgreementPublicKey`) on every device and can perform X25519 ECDH via the new helpers in §17.4.
- All existing mesh-photo tests pass with plaintext payloads (no regressions from the encoding change in §17.2).

### 17.2 Threat model and scope

Application-layer encryption limits the blast radius of a compromised key to a 15-minute window. It does not provide cryptographic forward secrecy per-message (no Double Ratchet), but it prevents a peer who records ciphertext and later obtains an old key from reading more than one rotation window of content.

**What is always encrypted (both open and closed mode):**
- Photo image data (`FriendPhotoPayload.encryptedImageData`) — AES-256-GCM with the current group key.

**What is additionally encrypted when the mesh is closed:**
- Photo manifest entries (`FriendPhotoManifestPayload`) — the list of photo IDs and sender fingerprints is encrypted, so an observer cannot enumerate what photos exist or who sent them.
- Member identities and roster (`MeshDescriptor.members`, `MeshStateChangePayload`) — display names, fingerprints, and public keys are encrypted in transit among established members.
- Admission grant payloads (`MeshAdmissionGrantPayload`) — the group key handoff and token are encrypted.

The encryption wrapper in closed mode uses the `meshEncryptedMetadata` payload type (see §17.3). The outer `FernletIdentityEnvelope` still carries the sender fingerprint and a generic payload type indicator so recipients know to attempt decryption; the inner plaintext payload type is only revealed after successful decryption.

**What is never encrypted (regardless of mode):**
- The initial identity handshake (`friendIdIntro`, `friendIdAck`) — the joining peer does not yet have the group key when these are exchanged. These payloads are signed (authenticity guaranteed) but not confidential.
- `meshAdmissionRequest` — the stranger requesting to join does not have the key yet; members must be able to read the request to decide whether to admit.
- The `meshCoordinatorBeacon` (see §17.6) — timer state must be readable by any peer, including those in mid-join.
- A currently-active member who has the current key can always see plaintext content — this is by design; encryption does not defend against trusted insiders.
- Photos from before the first rotation of a session (solo member, no peers yet) are sent at epoch 0 and flagged as unencrypted in the payload.

### 17.3 New wire protocol additions

Add to `FernletIdentityEnvelope.PayloadType`:

```
case meshKeyRotation       = "fernlet.mesh.key.rotation.v1"
case meshKeyAck            = "fernlet.mesh.key.ack.v1"
case meshRotationSync      = "fernlet.mesh.rotation.sync.v1"
case meshEncryptedMetadata = "fernlet.mesh.encrypted.meta.v1"
case meshCoordinatorBeacon = "fernlet.mesh.coordinator.beacon.v1"
```

`meshEncryptedMetadata` is a generic wrapper used in closed mode. Its payload is an AES-256-GCM ciphertext whose plaintext, once decrypted, is a standard JSON-encoded payload with an inner `payloadType: String` field that identifies the real content. This hides which kind of control message was sent from anyone who cannot hold the group key.

`meshCoordinatorBeacon` carries the coordinator's timer state and is broadcast periodically (every ~20 seconds). It is never encrypted so that any peer — including those mid-join — can track the rotation schedule.

New payload structs (add to `MeshNetworkManager.swift` or a new `MeshEncryption.swift`):

```swift
// Broadcast by the coordinator once per rotation.
// perMember maps each member's fingerprint to their pairwise-encrypted copy
// of the 32-byte new key (X25519 ECDH shared secret → AES-256-GCM wrap).
struct MeshKeyRotationPayload: Codable, Equatable {
    let newEpoch: Int
    let perMember: [String: Data]      // fingerprint → encrypted key bundle
    let rotationInitiatedAt: Date
    let coordinatorFingerprint: String
}

// Each member sends this after successfully unwrapping and caching the new key.
struct MeshKeyAckPayload: Codable, Equatable {
    let epoch: Int
    let memberFingerprint: String
}

// Coordinator broadcasts this before generating a new key.
// Members drain in-flight photo exchanges before responding with a MeshKeyAckPayload
// for the closing epoch (signalling "ready for rotation").
struct MeshRotationSyncPayload: Codable, Equatable {
    let closingEpoch: Int
}

// Broadcast by the coordinator every ~20 seconds, piggybacked on the mesh heartbeat
// cycle. Never encrypted — any peer can read it to track the rotation schedule.
// Non-coordinators use lastBeaconAt + nextRotationAt to estimate takeover timing.
struct MeshCoordinatorBeaconPayload: Codable, Equatable {
    let coordinatorFingerprint: String
    let currentEpoch: Int
    let nextRotationAt: Date    // absolute wall-clock timestamp of the planned rotation
    let sentAt: Date            // lets receivers correct for transit latency
}

// Closed-mode wrapper: inner payload is AES-256-GCM ciphertext over a JSON object
// that contains "payloadType": String and "payload": Data (base64).
// Decryption reveals the real payload type and content without changing call sites.
struct MeshEncryptedMetadataPayload: Codable, Equatable {
    let ciphertext: Data   // GCM ciphertext + 16-byte tag
    let nonce: Data        // 12-byte random nonce
    let keyEpoch: Int      // epoch of the key used; drop silently if epoch mismatch
}
```

Modify `FriendPhotoPayload` in `FriendPhotoShareView.swift`:

```swift
struct FriendPhotoPayload: Codable, Equatable, Identifiable {
    let id: UUID
    let imageData: Data?               // non-nil only for epoch-0 unencrypted photos
    let encryptedImageData: Data?      // AES-256-GCM ciphertext + 16-byte tag
    let nonce: Data?                   // 12-byte random GCM nonce
    let keyEpoch: Int                  // 0 = unencrypted legacy; ≥1 = encrypted
    let addedAt: Date
    let senderName: String
    let senderFingerprint: String?
    let senderSigningPublicKey: Data?
}
```

Backward compatibility: use `decodeIfPresent` for all new fields. An old payload with only `imageData` present is treated as epoch 0 and displayed without decryption.

Modify `FriendPhotoManifestEntry`:

```swift
struct FriendPhotoManifestEntry: Codable, Equatable {
    let id: UUID
    let senderFingerprint: String
    let keyEpoch: Int   // NEW — receiver skips requesting photos from epochs it cannot decrypt
}
```

Modify `MeshAdmissionGrantPayload`:

```swift
struct MeshAdmissionGrantPayload: Codable, Equatable {
    let meshID: UUID
    let requesterFingerprint: String
    let token: MeshAdmissionToken
    let encryptedCurrentKey: Data?   // NEW — pairwise-wrapped current group key for joiner
    let currentKeyEpoch: Int         // NEW — joiner sets localJoinedEpoch to this value
}
```

### 17.4 Key agreement and encryption helpers

Add to `IdentityService`:

```swift
// X25519 ECDH: combine local private key with peer's public key to get a shared secret.
func deriveSharedSecret(with peerKeyAgreementPublicKey: Data) throws -> Data

// Wrap a 32-byte group key for one recipient.
// Flow: ECDH shared secret → HKDF-SHA256 (32 bytes) → AES-256-GCM encrypt(key).
// Returns a self-contained bundle: ephemeral public key || nonce || ciphertext || tag.
func encryptGroupKey(_ key: Data, for recipientPublicKey: Data) throws -> Data

// Unwrap a bundle received from any sender.
func decryptGroupKey(_ bundle: Data) throws -> Data
```

Static photo encrypt/decrypt (no `IdentityService` involvement — they only use the symmetric key):

```swift
// Returns ciphertext+tag (appended). Nonce is separately stored in the payload.
static func encryptPhoto(_ imageData: Data, key: MeshGroupKey) throws -> (ciphertext: Data, nonce: Data)
static func decryptPhoto(_ ciphertext: Data, nonce: Data, key: MeshGroupKey) throws -> Data
```

Use AES-256-GCM via CryptoSwift (`AES(key:blockMode:padding:)` with `.GCM`). Generate a fresh 12-byte random nonce per photo via `SecRandomCopyBytes`.

### 17.5 Group key state in `MeshNetworkManager`

```swift
struct MeshGroupKey {
    let epoch: Int
    let keyBytes: Data   // 32 bytes
    let activeSince: Date
}
```

Add to `MeshNetworkManager`:

```swift
@ObservationIgnored private var currentGroupKey: MeshGroupKey?
@ObservationIgnored private var rotationTimer: Timer?        // fires only when local device is coordinator
@ObservationIgnored private var beaconTimer: Timer?          // fires every ~20s to broadcast or check beacon
@ObservationIgnored private var pendingRotationAcks: Set<String> = []  // fingerprints
@ObservationIgnored private var localJoinedEpoch: Int = 0
@ObservationIgnored private var lastBeaconReceivedAt: Date?  // watchdog for coordinator liveness
@ObservationIgnored private var lastKnownNextRotationAt: Date?  // from most recent beacon
```

The key is never written to disk or keychain. It lives only for the current app session. If the app is backgrounded and killed, the in-memory key is lost; on rejoin, the member receives the current key for the epoch at that moment and sets `localJoinedEpoch` accordingly.

### 17.6 Coordinator election and beacon-driven timer

**Election rule:** The fingerprint that sorts lexicographically smallest among the local device and all currently-connected active-slot peers is the coordinator. Re-evaluate on every `handleChannelReady`, `removeSlot`, and `setMeshMode` call.

**Coordinator beacon:** Every ~20 seconds the coordinator broadcasts a `MeshCoordinatorBeaconPayload` containing its fingerprint, the current epoch, the absolute timestamp of the next planned rotation, and `sentAt`. All peers — including those mid-join — update `lastBeaconReceivedAt` and `lastKnownNextRotationAt` on receipt. The beacon is never encrypted so it is universally readable.

The beacon serves two purposes:
1. **Timer synchronisation** — any peer that becomes coordinator can read `lastKnownNextRotationAt` from the most-recent beacon and schedule its own `rotationTimer` to fire at exactly that timestamp, continuing the existing cycle rather than restarting the 15-minute clock from zero.
2. **Liveness watchdog** — non-coordinator devices run a `beaconTimer` that fires every 30 seconds and checks `lastBeaconReceivedAt`. If no beacon has arrived in 45 seconds (beacon interval × 2 + margin), the coordinator is presumed lost.

**Coordinator takeover on liveness failure:**
1. The watchdog fires. The local device computes the current eligible coordinator (lowest fingerprint among connected active-slot peers + self). If that is the local device, it promotes itself.
2. It broadcasts its own beacon immediately, claiming the coordinator role with `nextRotationAt = lastKnownNextRotationAt ?? now + 15min`. If `lastKnownNextRotationAt` is in the past (rotation was missed), set `nextRotationAt = now + 1min` to recover quickly.
3. It sets `rotationTimer` to fire at the claimed `nextRotationAt`.
4. Other peers observe the new beacon fingerprint and update their internal coordinator state without any additional signalling. Ties (two peers both promote simultaneously) are broken by the election rule: the peer with the smallest fingerprint wins. The loser sees the winner's beacon arrive and cancels its own timer.

**Coordinator takeover on mid-rotation failure:**
If the coordinator disconnects during Steps 1–3 of §17.7 (after sending `meshRotationSync` but before distributing `MeshKeyRotationPayload`), the next coordinator:
- Waits up to 5 seconds for any stragglers to finish their acks.
- Generates a new key for the same `closingEpoch + 1` and distributes it. Members who already acked for the old coordinator's sync are still marked ready; the new coordinator trusts those acks.
- Broadcasts its own beacon for the next rotation interval.

### 17.7 Rotation protocol (15-minute cycle)

The rotation timer fires at the `nextRotationAt` timestamp broadcast in the coordinator's beacon (§17.6). All members know this timestamp; the coordinator is simply the one who acts on it.

**Step 1 — Sync broadcast** (coordinator)

When the rotation timer fires, broadcast `MeshRotationSyncPayload(closingEpoch: currentGroupKey?.epoch ?? 0)` to all connected slots. Immediately also broadcast an updated `MeshCoordinatorBeaconPayload` with `nextRotationAt = now + 15min` so all peers update their watchdog and timer state before any disruption.

Each receiving member:
1. Completes any pending outbound `friendPhotoRequest` payloads.
2. Waits until no new inbound `friendPhotoRequest` arrives for 3 seconds.
3. Responds with `MeshKeyAckPayload(epoch: closingEpoch, memberFingerprint: localFingerprint)` — this signals "I have all photos I'm going to receive for this epoch; ready for new key."

**Step 2 — Collect ready acks** (coordinator, 10-second timeout)

Coordinator collects acks from the fingerprints of all currently active-slot peers. Members who do not ack within 10 seconds are excluded from the new key distribution — they must disconnect and re-admit to rejoin the encrypted session. Proceed with whoever acked.

**Step 3 — Generate and distribute new key** (coordinator)

- Generate 32 cryptographically random bytes.
- For each acked member fingerprint, look up their `keyAgreementPublicKey` from `currentMesh.members` and call `IdentityService.encryptGroupKey(newKey, for: member.keyAgreementPublicKey)`.
- Also wrap the key for the local device using `IdentityService.encryptGroupKey(newKey, for: identity.localKeyAgreementPublicKey)` (self-encrypt so the same code path applies uniformly; the coordinator then immediately unwraps its own copy).
- Broadcast `MeshKeyRotationPayload(newEpoch: epoch+1, perMember: [...], rotationInitiatedAt: now, coordinatorFingerprint: localFingerprint)`.

**Step 4 — Members apply new key**

On receipt of `MeshKeyRotationPayload`:
1. Look up `perMember[localFingerprint]`. If absent, the member was excluded — they log a non-modal warning and initiate a rejoin.
2. `IdentityService.decryptGroupKey(bundle)` → 32-byte key.
3. Set `currentGroupKey = MeshGroupKey(epoch: newEpoch, keyBytes: key, activeSince: now)`.
4. If mesh mode is `.closed`, all subsequent outbound control payloads (manifests, descriptors, state changes) are wrapped in `MeshEncryptedMetadataPayload` using the new key (see §17.10).
5. All new outbound photos use the new key immediately.
6. Send `MeshKeyAckPayload(epoch: newEpoch, memberFingerprint: localFingerprint)` back to the coordinator.

**Step 5 — Rotation complete** (coordinator)

After receiving epoch-N+1 acks from all expected members (or 10-second timeout), discard the old epoch's key from memory. The `rotationTimer` was already rescheduled in Step 1; no further action needed.

### 17.8 New joiner key handoff

When a member is admitted via `allowAdmission(_:)`:
1. Encrypt the current group key pairwise for the joiner using their `requesterKeyAgreementPublicKey`.
2. Populate `encryptedCurrentKey` and `currentKeyEpoch` in `MeshAdmissionGrantPayload`.
3. Send the grant.

On the joiner's side in `handleAdmissionGrant(_:)`:
1. Unwrap `encryptedCurrentKey` → 32-byte key.
2. Set `currentGroupKey = MeshGroupKey(epoch: grant.currentKeyEpoch, ...)`.
3. Set `localJoinedEpoch = grant.currentKeyEpoch`.

The joiner never requests or receives any key for epochs before `localJoinedEpoch`. This is the mechanism that enforces "new joiners cannot read old photos."

If `currentGroupKey` is nil at admission time (solo member, rotation not yet started), set `encryptedCurrentKey = nil` and `currentKeyEpoch = 0`. The joiner starts at epoch 0 and receives unencrypted epoch-0 photos normally.

### 17.9 Changes to `addPhoto`

```swift
func addPhoto(_ data: Data) {
    // ... existing mesh-change check and quota guard ...

    guard let image = UIImage(data: data),
          let normalized = image.resizedForFriendSharing().jpegData(compressionQuality: 0.82) else { return }

    let photo: FriendPhotoPayload
    if let key = currentGroupKey {
        guard let (ciphertext, nonce) = try? Self.encryptPhoto(normalized, key: key) else { return }
        photo = FriendPhotoPayload(
            encryptedImageData: ciphertext, nonce: nonce, keyEpoch: key.epoch,
            senderName: displayName, senderFingerprint: identity.localFingerprint,
            senderSigningPublicKey: identity.localSigningPublicKey
        )
    } else {
        // Epoch 0: solo member or rotation not yet started. Send unencrypted.
        photo = FriendPhotoPayload(
            imageData: normalized, keyEpoch: 0,
            senderName: displayName, senderFingerprint: identity.localFingerprint,
            senderSigningPublicKey: identity.localSigningPublicKey
        )
    }
    cachePhoto(photo)
    photosAddedThisSession += 1
    for slot in activeSlots {
        Task { [weak self] in await self?.sendEnvelope(.friendPhoto, encodable: photo, via: slot) }
    }
}
```

### 17.10 Closed-mode metadata encryption

When `currentMesh.mode == .closed` and a `currentGroupKey` is established, all outbound control payloads except identity handshakes, admission requests, and coordinator beacons are wrapped before sending:

```swift
func sendEncryptedMetadata<T: Encodable>(
    _ payloadType: PayloadType,
    encodable: T,
    via slot: PeerSlot
) async {
    guard let key = currentGroupKey,
          let innerData = try? JSONEncoder().encode(encodable) else { return }
    let inner = EncryptedMetadataInner(payloadType: payloadType.rawValue, payload: innerData)
    guard let innerJSON = try? JSONEncoder().encode(inner),
          let (ciphertext, nonce) = try? Self.encryptPayload(innerJSON, key: key) else { return }
    let wrapper = MeshEncryptedMetadataPayload(
        ciphertext: ciphertext, nonce: nonce, keyEpoch: key.epoch
    )
    await sendEnvelope(.meshEncryptedMetadata, encodable: wrapper, via: slot)
}

struct EncryptedMetadataInner: Codable {
    let payloadType: String
    let payload: Data
}
```

On receipt of `meshEncryptedMetadata`:
1. Check `wrapper.keyEpoch == currentGroupKey?.epoch`. If not, drop silently (stale key or epoch mismatch — the sender will resync after the next rotation).
2. Decrypt with `Self.decryptPayload(ciphertext, nonce: nonce, key: currentGroupKey!)`.
3. Decode `EncryptedMetadataInner` from the plaintext.
4. Re-dispatch by looking up `PayloadType(rawValue: inner.payloadType)` and handling as if the payload arrived unencrypted.

Payloads affected in closed mode: `friendPhotoManifest`, `friendPhotoRequest`, `meshDescriptor`, `meshStateChange`, `meshAdmissionGrant`. The `meshAdmissionRequest` remains unencrypted (the requester has no key). `meshKeyRotation`, `meshKeyAck`, `meshRotationSync`, and `meshCoordinatorBeacon` are also sent unencrypted (they are part of the key establishment protocol itself).

In open mode, all of these are sent as plaintext via `sendEnvelope` as today.

### 17.11 Changes to manifest filtering

**Outbound manifest** (`syncPhotoManifest`): add `keyEpoch` to each `FriendPhotoManifestEntry`. No filtering on the sender side — senders always list all photos they hold; the receiver decides what to request.

**Inbound manifest handling** (`handlePhotoManifest`): skip requesting any entry whose `keyEpoch < localJoinedEpoch`. The receiver does not have the decryption key for those epochs and never will.

```swift
let missing = manifest.entries
    .filter { !haveIDs.contains($0.id) }
    .filter { !store.isBlockedFingerprint($0.senderFingerprint) }
    .filter { $0.keyEpoch >= localJoinedEpoch }   // NEW — epoch guard
    .map(\.id)
```

**Inbound photo handling** (`proximityCoordinator(_:didReceive:...)`): on receipt of `friendPhoto`, attempt decryption if `keyEpoch > 0`. If decryption fails (wrong key, corrupt data), drop silently and do not cache.

```swift
case .friendPhoto:
    if let payload = try? decoder.decode(FriendPhotoPayload.self, from: plaintext) {
        if let fp = payload.senderFingerprint, store.isBlockedFingerprint(fp) { return }
        if payload.keyEpoch > 0 {
            guard let key = currentGroupKey, key.epoch == payload.keyEpoch,
                  let ct = payload.encryptedImageData, let nonce = payload.nonce,
                  let decrypted = try? Self.decryptPhoto(ct, nonce: nonce, key: key) else { return }
            cachePhoto(payload.withDecryptedImageData(decrypted))
        } else {
            cachePhoto(payload)   // epoch 0: unencrypted, accept as-is
        }
    }
```

`withDecryptedImageData(_:)` is a simple copy-on-write helper that returns a new `FriendPhotoPayload` with `imageData` set to the decrypted bytes and `encryptedImageData`/`nonce` cleared.

### 17.12 `PeerSlot` addition

Add `joinedEpoch: Int = 0` to `PeerSlot`. Set it from the peer's `MeshMember.joinedAt` timestamp cross-referenced against the epoch-start-date log (a `[(epoch: Int, since: Date)]` array stored on `MeshNetworkManager`). This allows the coordinator to know which epoch each active-slot peer joined at during manifest sync, though in Phase 3 the primary use is on the receiving side via `localJoinedEpoch`.

### 17.12 File changes for Phase 3

| File | Change |
| --- | --- |
| `FernletIdentityEnvelope.swift` | Add `meshKeyRotation`, `meshKeyAck`, `meshRotationSync` payload type cases. |
| `Proximity/Wire/FriendPhotoPayloads.swift` | Add `encryptedImageData`, `nonce`, `keyEpoch` to `FriendPhotoPayload`; add `keyEpoch` to `FriendPhotoManifestEntry`; add `withDecryptedImageData` helper. |
| `Proximity/Identity/IdentityService.swift` | Add `deriveSharedSecret`, `encryptGroupKey`, `decryptGroupKey`. |
| `MeshNetworkManager.swift` | Add `MeshGroupKey` struct; group key state properties; `rotationTimer`; coordinator election; `encryptPhoto`/`decryptPhoto` static helpers; updated `addPhoto`, `handlePhotoManifest`, `syncPhotoManifest`, `proximityCoordinator(_:didReceive:...)`; rotation protocol handlers for `meshRotationSync`, `meshKeyRotation`, `meshKeyAck`. |
| `MeshAdmissionToken.swift` | Add `encryptedCurrentKey: Data?` and `currentKeyEpoch: Int` to `MeshAdmissionGrantPayload`. |
| `Proximity/MultipeerSession.swift` (or `MeshNetworkManager.swift`) | Add `joinedEpoch: Int` to `PeerSlot`. |

New file: **`MeshEncryptionTests.swift`** — unit tests (see §17.13).

### 17.13 Phase 3 testing priorities

- **Encrypt/decrypt round-trip** — generate a `MeshGroupKey`, encrypt a known image, decrypt it, assert byte equality.
- **Epoch filtering on manifest** — member with `localJoinedEpoch = 3` calls `handlePhotoManifest` containing entries from epochs 1, 2, 3, 4; assert only epochs ≥ 3 are requested.
- **Joiner receives no old keys** — `handleAdmissionGrant` with `currentKeyEpoch = 5`; assert `localJoinedEpoch == 5` and no key for epochs < 5 is ever stored.
- **Rotation state machine** — coordinator collects sync acks, generates a new key, distributes pairwise; simulate one member timing out; assert excluded member does not appear in `perMember`; assert coordinator advances epoch.
- **Key isolation** — a member holding only epoch-5 key cannot decrypt an epoch-4 ciphertext (decryption throws / returns nil, not garbage).
- **Epoch-0 backward compat** — payload with `imageData` non-nil and `keyEpoch == 0` is cached and displayed without any decryption attempt; no crash when `currentGroupKey` is nil.
- **Rotation on membership change** — blocking a member triggers immediate re-election; if local device becomes coordinator, it starts the rotation sequence.

---

---

## 18. Phase 4: Mesh/Proximity Security Hardening

**Goal:** fold the cross-cutting proximity security fixes (from the 2026-05-28 architecture audit) into the mesh code paths and close the Phase 3 review issues. Implement Phase 3 and Phase 4 together so confidentiality ships alongside trust and transport fixes.

### 18.1 Dependencies

Phase 3 may be in progress concurrently. Phase S1 from `ImplementationPlan.md` defines the 1:1 proximity fixes; this phase applies those same fixes to the mesh paths and adds mesh-specific hardening.

### 18.2 Tasks

**Full-key trust — closes SEC-1:**
- Re-key trust, block, and revoke decisions in `ProximityTrustVault` / `FernletStore` on the **full 32-byte Ed25519 signing public key**. The 8-char fingerprint becomes display-only; lengthen user-facing display to ≥16 hex characters.
- In `ProximityCoordinator.handleIdentityEnvelope`, require `storedPeer.signingPublicKey == envelope.senderSigningPublicKey` before any auto-confirm.
- Apply the same full-key check in `MeshNetworkManager` when processing identity-intro/ack envelopes for mesh peers.

**Required transport encryption — closes SEC-2:**
- Set `encryptionPreference: .required` on `MeshMultipeerSession`'s `MCSession`.
- Verify the same change on `MultipeerSession` (1:1 path).

**Sealed 1:1 payloads — closes SEC-2 for 1:1:**
- Friend photos and trainer attachments sent via 1:1 `MultipeerSession` must use `payloadEncryption: .sealedTo(recipientKeyAgreementPublicKey:)` via `IdentityService.seal/open`. The mesh path is protected by Phase 3 group key; this closes the 1:1 gap.

**Friend proximity gate — closes SEC-6:**
- Friend handshakes must not auto-complete on transport connect alone.
- Require UWB ≤-threshold tap when `NIRangingSession.isHardwareSupported`, or an explicit user confirmation prompt on non-UWB devices.
- Apply to both `MultipeerSession` (1:1 friend mode) and mesh admission for new friends.

**Envelope expiry — closes SEC-7:**
- Set `expiresAt` on all outbound envelopes. Bind photo/attachment envelopes to the current session/epoch.

**Close Phase 3 review issues:**
- Bind group-key wrapping to handshake-verified KA keys, not descriptor gossip (Review Issue 1).
- Harden coordinator beacon validation: ignore beacons from non-elected fingerprints; clamp `nextRotationAt` to within one window (Review Issue 2).
- Document epoch-0 plaintext behavior in UI and code (Review Issue 4).

### 18.3 New tests

- **Fingerprint-collision rejection:** a crafted keypair with the same 8-char fingerprint as a trusted peer is not auto-confirmed and cannot rejoin via a cached admission token. The full public key comparison must differ and fail.
- **Non-elected beacon ignored:** simulate two devices both claiming coordinator simultaneously; assert the device with the higher fingerprint cancels its `rotationTimer` on receipt of the winner's beacon.
- **Roster-key-swap rejected:** coordinator receives a descriptor that swaps a member's KA key; assert the wrapped group key for that member is built using the handshake-verified key, not the swapped descriptor key.
- **Required transport:** assert `MeshMultipeerSession` initializes its `MCSession` with `encryptionPreference: .required`; assert `MultipeerSession` does the same.
- **Blocked key cannot rejoin:** a blocked fingerprint's device is rejected even with a valid unexpired admission token.

### 18.4 Exit criteria

- A crafted fingerprint-collision key is rejected and cannot be auto-confirmed or rejoin via admission token.
- A non-elected member cannot drive rotation timing or claim coordinator beacons.
- A poisoned roster descriptor cannot redirect a group-key wrap to an attacker-controlled KA key.
- Mesh and 1:1 sessions are transport-encrypted-required; 1:1 sensitive payloads are sealed at the app layer.
- Friend handshakes require a proximity confirmation or explicit user confirmation step — never auto-proceed on transport connect alone.

---

End of plan.
