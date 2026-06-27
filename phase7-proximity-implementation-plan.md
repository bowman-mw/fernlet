# Fernlet Phase 7 — Proximity Handshake & Persistent Peer Sessions

**Replaces:** `ImplementationPlan.md` §Phase 7 (the ~25-line outline). This document is the comprehensive plan.

**Status:** In progress — updated 2026-05-25. Sub-phases 7.1–7.8 are implemented and the May 2026 diagnostics/ranging patches are in place: on-demand Connection Inspector presentation, signed NI discovery-token exchange in identity envelopes, inspector distance recording, heartbeat ping/ack RTT measurement, and explicit RSSI fallback status. Engineers should treat this as the source of truth and update `ImplementationPlan.md` to reference this file once it lands.

**Companion documents:**
- `move-refactor-and-trainer-integration-plan.md` §7 — defines the trainer integration that consumes this primitive.
- `apple-fitness-and-healthkit-research.md` §H — research on peer-to-peer iOS APIs.
- `codex-implementation-prompts.md` Phase M6 — Codex prompts that depend on this plan.
- `proximity-handshake-process-map.md` — phase 7 handshake, coordinator data flow, and trainer/friend process map.

**Key change from the original outline:** This plan ships a **Connection Inspector** — passive session recording plus an on-demand live sheet — alongside the proximity primitive itself. The Inspector is how two real phones running Fernlet build confidence in the transport during testing and how engineers diagnose field failures. It is not optional, but it must not auto-present during pairing.

---

## Table of Contents

1. Goals & Non-Goals
2. Architectural Overview
3. Identity Service
4. Envelope Specification
5. MultipeerConnectivity Transport
6. NearbyInteraction Ranging
7. Proximity Coordinator (State Machine)
8. Connection Inspector
9. Failure Modes & Recovery
10. Battery, Background, and Foreground Anchoring
11. Privacy, Consent, and Audit
12. Manual Two-Phone Test Protocol
13. Automated Test Strategy
14. Phased Execution
15. Open Decisions (with resolutions)
16. Mesh Networking — v2 Design
17. Field-Tested Stability Patches (May 2026) & Guide for Future Proximity Consumers
18. Appendix A — File impact summary
19. Appendix B — Wire format reference

---

## 1. Goals & Non-Goals

### 1.1 Goals

- Provide a reusable physical-presence primitive that any feature in Fernlet can consume: trainer-to-client plan transfer (the immediate consumer), future friend-to-friend recipe sharing, multi-user activity joining, etc.
- Make proximity itself a UX-confirmable event — not just RF proximity but "the user explicitly held two phones together" — using `NearbyInteraction` UWB ranging where available and a manual-confirmation fallback when UWB is unavailable.
- Require mutual cryptographic confirmation on every transfer. RF proximity is **not** an access-control primitive; it gates the UX, not the cryptography.
- Keep sessions open across the duration of a workout so live updates flow without re-pairing.
- Run entirely offline. No cloud, no servers, no Apple Push.
- Surface every connection's state and history to engineers via the Connection Inspector during development and TestFlight; gate it behind a setting in App Store builds.

### 1.2 Non-goals

- Cloud-mediated pairing or group sharing. That belongs to `ImplementationPlan.md` §Phase 9.
- Mesh networking in v1. Sessions are strictly 1:1 in v1. A proximity-anchored device mesh (each node holds 2–3 peer connections, no cloud required) is planned as the v2 large-group answer — see §16.
- Replacing AirDrop. AirDrop with a custom `UTType` is the receive-only fallback (see `move-refactor-and-trainer-integration-plan.md` §7.5); it is not the primary path.
- Reproducing Apple's NameDrop UI. NameDrop is wired to Contacts via NFC + AirDrop and is not a developer-accessible API. Fernlet's pairing experience is *inspired* by NameDrop but is its own thing.
- Cross-platform interop with Android, watchOS, macOS in v1. iPhone-to-iPhone only.
- Audio/video real-time streaming. Sessions carry small JSON envelopes and short binary payloads only.

### 1.3 Success criteria

- Two iPhones running Fernlet, physically held tip-to-tip, can complete a full pair → accept → transfer → persistent session → close cycle without the user reading any debug screen.
- A non-Fernlet user nearby cannot eavesdrop, spoof a trainer, or trigger any unsolicited UI on a Fernlet user's device.
- After every pairing session, a `ConnectionSessionLog` is persisted with timing, peer fingerprint, and event trace, browsable from Settings → Developer.
- During testing, the user can open the Connection Inspector live sheet on both phones to inspect live state, distance samples, RTT, envelope metadata, and fallback status.

---

## 2. Architectural Overview

Four layered components, each owns a single concern:

```
┌─────────────────────────────────────────────────────────┐
│                  ProximityCoordinator                    │   ← public surface
│  ┌──────────────────────────────────────────────────┐   │
│  │  State machine: idle → ranging → connected → …    │   │
│  └──────────────────────────────────────────────────┘   │
│         │                │                │              │
│         ▼                ▼                ▼              │
│  ┌────────────┐  ┌────────────┐  ┌────────────────┐    │
│  │  Identity  │  │  Multipeer │  │  NearbyInter-  │    │
│  │   Service  │  │   Session  │  │     action     │    │
│  │  (Crypto)  │  │  (Wi-Fi+BT)│  │  (UWB / RSSI)  │    │
│  └────────────┘  └────────────┘  └────────────────┘    │
│         │                │                │              │
│         └────────────────┼────────────────┘              │
│                          ▼                               │
│                ┌──────────────────────┐                  │
│                │ ConnectionInspector  │                  │
│                │  (passive observer)  │                  │
│                └──────────────────────┘                  │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
                ┌──────────────────────┐
                │   Feature consumers  │
                │ • TrainerProximity   │
                │ • FriendShare (v2)   │
                │ • ActivityJoin (v2)  │
                └──────────────────────┘
```

Key boundaries:

- **`IdentityService`** owns the Ed25519 signing keypair, the X25519 ECDH keypair, and all Keychain access. It does not touch Bluetooth, MCSession, or NearbyInteraction. It exposes pure-function `sign(_:)` / `verify(_:from:)` / `seal(_:to:)` / `open(_:from:)` operations.

- **`MultipeerSession`** wraps a single `MCSession`. It deals with peer discovery, connection lifecycle, and raw byte transfer. It does not know about envelopes, signatures, or proximity — it sees bytes go in, bytes come out, and a finite number of peer states.

- **`NearbyInteraction`** wraps a single `NISession`. It deals with discovery-token generation, peer-token startup, distance updates, and "tap-confirmed" detection (sustained < 5 cm for >= 1 second). On devices without U1/U2 it returns "ranging unavailable"; the coordinator records RSSI fallback mode and requires manual confirmation rather than fabricating a meter estimate.

- **`ProximityCoordinator`** is the orchestrator. It composes the three primitives into a state machine that consumers interact with. It is what `TrainerProximityService` (Phase M6) instantiates.

- **`ConnectionInspector`** subscribes to events from all four lower layers via Combine publishers. It does not affect transport behavior. Disabling it has no behavioral impact on the rest of the system.

### 2.1 Threading model

- All public methods on the four components are `@MainActor`. Internal callbacks from `MCSession`, `NISession`, and BLE arrive on system queues; each wrapper hops to the main actor before mutating state or emitting events.
- The `ConnectionInspector` publishes via a `@Published` snapshot struct that observers (SwiftUI views) read on the main actor.
- Long-running operations (key generation, signature verification, file I/O) run inside `Task.detached` and return to the main actor.

### 2.2 Module/file layout

All new files in the Fernlet target. Tests in FernletTests.

```
Fernlet/
├── Proximity/
│   ├── IdentityService.swift                  # Keypair gen, sign/verify, seal/open
│   ├── FernletIdentityEnvelope.swift          # Wire envelope (signed packet) types
│   ├── MultipeerSession.swift                 # MCSession wrapper
│   ├── NearbyRangingSession.swift             # NISession wrapper + RSSI fallback
│   ├── ProximityCoordinator.swift             # State machine
│   ├── ConnectionInspector.swift              # Live observer + persistence
│   ├── ConnectionInspectorView.swift          # Live overlay/sheet
│   ├── ConnectionInspectorHistoryView.swift   # Past sessions browser
│   └── ConnectionSessionLog.swift             # Persisted record
└── ...

FernletTests/
├── IdentityServiceTests.swift
├── FernletIdentityEnvelopeTests.swift
├── MultipeerSessionTests.swift               # uses MockMultipeerTransport
├── NearbyRangingSessionTests.swift           # uses MockRangingProvider
├── ProximityCoordinatorTests.swift           # uses both mocks
├── ConnectionInspectorTests.swift
└── Mocks/
    ├── MockMultipeerTransport.swift
    ├── MockRangingProvider.swift
    └── MockIdentityService.swift
```

---

## 3. Identity Service

### 3.1 Keys

Fernlet's identity is two CryptoKit keypairs, both stored in the Keychain:

| Purpose | Type | Public-key size | Persistence |
|---|---|---|---|
| Signing | `Curve25519.Signing.PrivateKey` (Ed25519) | 32 B | Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |
| Key agreement | `Curve25519.KeyAgreement.PrivateKey` (X25519) | 32 B | Keychain, same flags |

`AfterFirstUnlock` (not `WhenUnlocked`) is required so that proximity sessions can survive screen-off and the app can keep its `MCSession` alive while the user is mid-workout.

`ThisDeviceOnly` (not synchronizable) is mandatory. Identity is per-device. A user with two iPhones is two trust subjects.

### 3.2 Public API

```swift
@MainActor
final class IdentityService {
    /// Local public key fingerprint, suitable for showing to the user during a pairing confirmation
    /// or for short-display in logs. First 8 hex chars of SHA-256(publicKey).
    var localFingerprint: String { get }

    /// Full local Ed25519 public key bytes (32 B). Send to peers during pairing.
    var localSigningPublicKey: Data { get }

    /// Full local X25519 public key bytes (32 B). Send to peers during pairing for ECDH.
    var localKeyAgreementPublicKey: Data { get }

    /// Ed25519 signature over `data`. Used for every outbound envelope.
    func sign(_ data: Data) throws -> Data

    /// Verify an Ed25519 signature against a known public key.
    static func verify(_ signature: Data, of data: Data, by publicKey: Data) -> Bool

    /// X25519 ECDH → HKDF-SHA256 → ChaCha20-Poly1305 seal. Used for sensitive payloads (e.g., workout
    /// completion notes that may contain pain/injury information).
    func seal(_ plaintext: Data, to peerKeyAgreementPublicKey: Data) throws -> Data

    /// Inverse of seal.
    func open(_ ciphertext: Data, from peerKeyAgreementPublicKey: Data) throws -> Data

    /// Bootstrap on first launch. Idempotent — returns the existing identity if already provisioned.
    func ensureProvisioned() throws

    /// DANGEROUS — wipes identity. Used only for "Reset Fernlet" or factory-reset flows. Wiping
    /// breaks every existing trust relationship.
    func wipe() throws

    /// 8-char fingerprint helper for any public key. Useful for displaying peer fingerprints.
    static func fingerprint(of publicKey: Data) -> String
}
```

### 3.3 Storage details

Use the same `KeychainItem` pattern that `FernletLockService.swift` already establishes. Add a new service name `"com.fernlet.identity"` and these account keys:

- `signingPrivateKey` — `Curve25519.Signing.PrivateKey.rawRepresentation`
- `keyAgreementPrivateKey` — `Curve25519.KeyAgreement.PrivateKey.rawRepresentation`
- `signingPublicKeyCache` — `Curve25519.Signing.PublicKey.rawRepresentation` (cached for fast access without re-deriving from the private key on every sign)
- `keyAgreementPublicKeyCache` — same

Use the `KeychainItem` helpers from `FernletLockService.swift` unmodified — do **not** roll a new wrapper. Pull the helpers up to a shared file (e.g., `KeychainHelpers.swift`) if duplication concerns arise.

### 3.4 Sealing format (for X25519-sealed payloads)

When a payload needs encryption:

1. Generate an ephemeral X25519 keypair `(eskPriv, eskPub)`.
2. Derive a shared secret: `ss = X25519(eskPriv, peerKeyAgreementPublicKey)`.
3. HKDF-SHA256 over `ss`, salt = `"fernlet.proximity.v1"`, info = `senderPublicKey || peerKeyAgreementPublicKey`, output 32 B → `symKey`.
4. Generate a random 12-byte nonce.
5. AEAD: `ciphertext = ChaCha20Poly1305.seal(plaintext, key: symKey, nonce: nonce, aad: senderPublicKey)`.
6. Wire form: `eskPub (32 B) || nonce (12 B) || ciphertext`.

The recipient reverses with their own X25519 private key. The ephemeral pubkey is fresh per message → forward secrecy.

### 3.5 Tests (IdentityServiceTests.swift)

- `ensureProvisionedCreatesIdentityOnFirstCall` — keychain empty before, populated after.
- `ensureProvisionedIsIdempotent` — call twice, public keys identical.
- `signAndVerifyRoundTrip` — sign data, verify with own public key succeeds.
- `verifyRejectsTamperedData` — flip a byte, verify fails.
- `verifyRejectsWrongPublicKey` — verify against a different public key fails.
- `localFingerprintIsStable` — same identity always produces the same fingerprint.
- `localFingerprintIs8HexChars` — `localFingerprint.count == 8` and matches `^[a-f0-9]{8}$`.
- `fingerprintOfDifferentKeysDiffers` — two random keys produce different fingerprints with high probability (compare 100 generated keys, assert all unique).
- `sealOpenRoundTrip` — Alice seals to Bob's pubkey, Bob opens with his privkey, plaintext matches.
- `openRejectsTamperedCiphertext` — flip a byte in ciphertext, `open` throws.
- `openRejectsWrongRecipientKey` — Bob seals to Carol, Eve tries to open with her privkey, fails.
- `wipeRemovesAllKeyMaterial` — after wipe, `ensureProvisioned()` generates a fresh identity with a different fingerprint.

---

## 4. Envelope Specification

The envelope is the single wire format for every payload that crosses between two Fernlet devices. It is defined in `FernletIdentityEnvelope.swift`.

### 4.1 Envelope shape

```swift
struct FernletIdentityEnvelope: Codable, Equatable {
    let schemaVersion: Int                       // 1
    let envelopeID: UUID                         // for replay protection + Inspector log correlation
    let senderSigningPublicKey: Data             // Ed25519 raw, 32 B
    let senderKeyAgreementPublicKey: Data        // X25519 raw, 32 B (for reply-back encryption)
    let senderDisplayName: String                // user-chosen display name (e.g., "Coach Alex")
    let recipientFingerprint: String?            // 8-char fingerprint of intended recipient, nil for broadcast
    let payloadType: PayloadType                 // see enum below
    let payloadEncryption: PayloadEncryption     // .none or .sealedTo(recipientKeyAgreementPublicKey)
    let payloadSummary: PayloadSummary           // human-readable so the recipient can decide whether to accept
    let payload: Data                            // JSON or sealed bytes
    let createdAt: Date
    let expiresAt: Date?                         // optional — if set, recipient must reject after this time
    let signature: Data                          // Ed25519 over (everything except `signature`)
}

enum PayloadType: String, Codable {
    // Handshake
    case identityIntroduction        = "fernlet.identity.intro.v1"
    case identityAcknowledge         = "fernlet.identity.ack.v1"
    // Trainer
    case trainerPlan                 = "fernlet.trainer.plan.v1"
    case trainerPlanDelta            = "fernlet.trainer.plan.delta.v1"
    case workoutCompletion           = "fernlet.workout.completion.v1"
    case workoutLiveUpdate           = "fernlet.workout.live.v1"
    // Session control
    case sessionHeartbeat            = "fernlet.session.ping.v1"
    case sessionGoodbye              = "fernlet.session.bye.v1"
    // Diagnostic (Inspector traffic)
    case inspectorEcho               = "fernlet.diagnostic.echo.v1"
}

enum PayloadEncryption: Codable, Equatable {
    case none
    case sealedTo(recipientKeyAgreementPublicKey: Data)
}

struct PayloadSummary: Codable, Equatable {
    let title: String                           // "May–June Strength Block"
    let subtitle: String?                       // "Coach Alex · Fernlet Gym"
    let itemCount: Int                          // e.g., # of planned workouts
    let dateRange: ClosedRange<Date>?           // for plans
    let extraDetails: [String: String]          // type-specific extras shown in the confirm card
}
```

### 4.2 Signing

The signature covers a canonical JSON encoding of every field except `signature` itself. Use `JSONEncoder` with `.sortedKeys` output and `.iso8601` date strategy so the byte sequence is deterministic.

```swift
func canonicalBytes(for envelope: FernletIdentityEnvelope) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    var envelopeForSigning = envelope
    envelopeForSigning.signature = Data()       // clear the field
    return try! encoder.encode(envelopeForSigning)
}
```

### 4.3 Verification flow

```swift
extension FernletIdentityEnvelope {
    enum VerifyError: Error {
        case schemaVersionUnsupported
        case expired
        case signatureInvalid
        case recipientMismatch
        case payloadDecryptionFailed
        case replayDetected
    }

    func verify(againstLocalKeyAgreementPrivateKey privateKey: Curve25519.KeyAgreement.PrivateKey?,
                identityService: IdentityService,
                seenNonceCache: ReplayCache) throws -> Data {
        guard schemaVersion == 1 else { throw VerifyError.schemaVersionUnsupported }
        if let expiresAt, expiresAt < Date() { throw VerifyError.expired }

        let canon = canonicalBytes(for: self)
        guard IdentityService.verify(signature, of: canon, by: senderSigningPublicKey) else {
            throw VerifyError.signatureInvalid
        }

        if let recipientFingerprint, recipientFingerprint != identityService.localFingerprint {
            throw VerifyError.recipientMismatch
        }

        try seenNonceCache.recordIfNew(envelopeID: envelopeID)
        // ^ throws .replayDetected if envelopeID was already seen in the last 24h

        switch payloadEncryption {
        case .none:
            return payload
        case .sealedTo:
            guard let privateKey else { throw VerifyError.payloadDecryptionFailed }
            return try identityService.open(payload, from: senderKeyAgreementPublicKey)
        }
    }
}
```

### 4.4 ReplayCache

```swift
@MainActor
final class ReplayCache {
    private var seen: [UUID: Date] = [:]
    private let retentionInterval: TimeInterval = 24 * 60 * 60
    private let maxEntries = 10_000

    func recordIfNew(envelopeID: UUID) throws {
        purgeIfNeeded()
        if seen[envelopeID] != nil {
            throw FernletIdentityEnvelope.VerifyError.replayDetected
        }
        seen[envelopeID] = Date()
    }

    private func purgeIfNeeded() {
        let cutoff = Date().addingTimeInterval(-retentionInterval)
        seen = seen.filter { $0.value >= cutoff }
        if seen.count > maxEntries {
            seen = Dictionary(seen.sorted(by: { $0.value > $1.value }).prefix(maxEntries),
                              uniquingKeysWith: { a, _ in a })
        }
    }
}
```

Persist `seen` via the same FernletStore snapshot mechanism so a relaunch doesn't reopen the replay window.

### 4.5 Tests (FernletIdentityEnvelopeTests.swift)

- Codable round-trip for every `PayloadType` and both `PayloadEncryption` variants.
- `signAndVerifyRoundTrip` — Alice constructs and signs an envelope, Bob verifies and recovers the payload.
- `verifyRejectsTamperedPayload` — flip a byte in `payload`, verify throws `.signatureInvalid`.
- `verifyRejectsTamperedSummary` — flip a byte in `payloadSummary.title`, verify throws.
- `verifyRejectsExpiredEnvelope` — `expiresAt = .distantPast`, verify throws `.expired`.
- `verifyRejectsWrongSchemaVersion` — set version to 99, verify throws.
- `verifyRejectsRecipientMismatch` — addressed to a different fingerprint, verify throws.
- `verifyRejectsReplay` — verify same envelope twice, second throws `.replayDetected`.
- `sealedEnvelopeRoundTrips` — encrypt payload to Bob's X25519 pubkey, Bob opens.
- `sealedEnvelopeRejectsWrongRecipient` — Eve tries to verify a sealed envelope addressed to Bob, throws.
- `canonicalBytesAreDeterministic` — two encodings of the same envelope produce identical bytes.
- `canonicalBytesIgnoreSignatureField` — modifying `signature` doesn't change `canonicalBytes`.
- `replayCachePurgesOldEntries` — add an entry, advance the cache's clock 25h, the entry is gone.

---

## 5. MultipeerConnectivity Transport

### 5.1 Service shape

```swift
@MainActor
protocol MultipeerTransport {
    var state: AnyPublisher<MultipeerSession.State, Never> { get }
    var inbound: AnyPublisher<MultipeerSession.InboundMessage, Never> { get }
    var connectedPeers: [MultipeerPeer] { get }

    func startAdvertising(serviceType: String, discoveryInfo: [String: String]) async throws
    func startBrowsing(serviceType: String) async throws
    func invite(_ peer: MultipeerPeer) async throws
    func accept(_ invite: MultipeerSession.PendingInvite) async throws
    func send(_ data: Data, to peer: MultipeerPeer, mode: MCSessionSendDataMode) async throws
    func disconnect() async
}
```

The protocol exists so tests can drop in `MockMultipeerTransport`.

### 5.2 Concrete `MultipeerSession`

Implementation notes:

- **`MCPeerID` persistence:** Save the local `MCPeerID` via `NSKeyedArchiver` to the app's Application Support directory. Reuse it across launches. Reconstructing `MCPeerID(displayName:)` with the same name produces a *different* peer identity and breaks reconnection — this is the long-standing iOS gotcha and must not be reintroduced. Reference: existing community write-ups; tested behavior unchanged from iOS 13 through iOS 26.
- **`serviceType`:** `"fernlet-coach"` for trainer pairing, `"fernlet-friend"` reserved for v2 friend sharing. Service types must be 1–15 chars, lowercase a–z, 0–9, or hyphen.
- **`discoveryInfo`:** advertise:
  - `v` → "1" (schema version)
  - `role` → `"trainer" | "client" | "peer"`
  - `fp` → local 8-char fingerprint
  - `name` → user's display name, truncated to 32 chars
  - `caps` → comma-separated capability list (e.g., `"plan,live,delta"`)
- **`MCSessionSendDataMode`:** use `.reliable` for envelopes (signed plan transfers must not lose bytes). Use `.unreliable` for live workout heartbeats where loss is tolerable.
- **`maximumNumberOfPeers`:** 1 for v1. Reject extra invitations until v2.
- **Encryption preference:** pass `.optional` when initializing `MCSession`. **Do not use `.required` with a nil `securityIdentity`.** When `.required` is used without supplying a custom certificate identity, MPC attempts an internal TLS handshake on channels 2–5 that silently fails ("Not in connected state, so giving up for participant on channel [2/3/4/5]"). The session may still establish on channel 1 but becomes unreliable. Fernlet's own `FernletIdentityEnvelope` layer already provides end-to-end signing and encryption for all sensitive payloads, making MPC-level TLS redundant. `.optional` lets the OS decide (it still encrypts when possible) and eliminates the multi-channel handshake failure.

### 5.3 Connection state machine (MultipeerSession.State)

```swift
extension MultipeerSession {
    enum State: Equatable {
        case idle
        case advertising
        case browsing
        case discovered([MultipeerPeer])              // browsing found peers, not yet invited
        case awaitingPeerAcceptance(MultipeerPeer)    // we invited, waiting
        case awaitingLocalAcceptance(PendingInvite)   // peer invited us
        case connecting(MultipeerPeer)
        case connected(MultipeerPeer)
        case disconnected(reason: String)
        case failed(MultipeerError)
    }

    struct PendingInvite {
        let peer: MultipeerPeer
        let advertisedInfo: [String: String]          // the peer's discoveryInfo
        let context: Data?                            // the peer-supplied context, if any
        let respond: (Bool) -> Void                   // the system's accept-handler closure
    }

    enum MultipeerError: Equatable, Error {
        case wifiUnavailable
        case bluetoothUnavailable
        case peerIDLoadFailed
        case sessionRejected
        case sessionTimeout
        case sendFailed(reason: String)
        case unexpectedState
    }

    struct InboundMessage {
        let peer: MultipeerPeer
        let data: Data
        let receivedAt: Date
        let bytesReceived: Int
    }
}

struct MultipeerPeer: Hashable, Identifiable {
    let id: UUID                                       // stable across launches; tied to persisted MCPeerID
    let displayName: String
    let discoveryInfo: [String: String]?
    let advertisedFingerprint: String?                 // from discoveryInfo["fp"]; useful as a hint
    fileprivate let underlying: MCPeerID
}
```

### 5.4 Tests (MultipeerSessionTests.swift)

Direct testing of `MCSession` itself is impossible without two real devices. Test the orchestration logic on top of `MultipeerTransport`:

- `discoveryInfoIncludesFingerprintAndRole`
- `startAdvertisingPublishesAdvertisingState`
- `startBrowsingPublishesBrowsingState`
- `discoveringAPeerEmitsDiscoveredState`
- `peerLossEmitsDiscoveredStateWithReducedList`
- `acceptingAnInviteTransitionsToConnecting`
- `inboundMessagePublishesWithCorrectBytes`
- `disconnectTransitionsToIdle`
- `peerIDPersistsAcrossInit` — create a session, save peer ID, kill, re-create, peer ID is the same `Data` archive bytes.

---

## 6. NearbyInteraction Ranging

### 6.1 Service shape

```swift
@MainActor
protocol RangingProvider {
    var distance: AnyPublisher<RangingDistance, Never> { get }
    var state: AnyPublisher<RangingState, Never> { get }
    var isHardwareSupported: Bool { get }            // U1/U2 chip present?

    func start(with peerToken: Data) async throws
    func stop() async
    func myDiscoveryToken() async throws -> Data
}

enum RangingDistance: Equatable {
    case unknown
    case meters(Double, direction: simd_float3?)
}

enum RangingState: Equatable {
    case idle
    case running
    case invalidated(reason: String)
    case fallback(rssiOnly: Bool)                    // U1/U2 unavailable; manual/RSSI fallback status
}
```

### 6.2 NearbyInteraction wrapper

- Configure `NISession.delegate` on the main actor.
- Get the local discovery token from `session.discoveryToken`, archive it to `Data` with `NSKeyedArchiver(requiringSecureCoding: true)`.
- Receive the peer token inside the signed `identityIntroduction` / `identityAcknowledge` payload, then unarchive with `NSKeyedUnarchiver(requiringSecureCoding: true, fromData:)`.
- Create `NINearbyPeerConfiguration(peerToken:)`, call `session.run(_:)`.
- On `nearbyObjectsDidUpdate`, take the first object's `distance` and `direction` (when available) and publish.
- iOS 18.4 added Live-Activity-gated background ranging. v1 of this plan does **not** rely on background ranging — keep both phones foregrounded during pairing.

### 6.3 "Tap confirmed" detection

A tap is detected when:

- `distance.meters` < 0.05 (5 cm) for **at least 1.0 second of continuous samples**, AND
- The number of samples received in that window is ≥ 3 (NISession publishes roughly 10 Hz; require empirical density to avoid one-off blips).

When detected, the coordinator transitions from `.ranging` to `.tapConfirmed`.

```swift
final class TapConfirmedDetector {
    private var window: [(timestamp: Date, distance: Double)] = []
    private let proximityThreshold = 0.05
    private let dwellSeconds = 1.0
    private let minimumSamples = 3

    func ingest(distanceMeters: Double, at timestamp: Date) -> Bool {
        window.append((timestamp, distanceMeters))
        let cutoff = timestamp.addingTimeInterval(-dwellSeconds)
        window.removeAll { $0.timestamp < cutoff }
        guard window.count >= minimumSamples else { return false }
        return window.allSatisfy { $0.distance < proximityThreshold }
    }

    func reset() { window.removeAll() }
}
```

### 6.4 Fallback: RSSI/manual proximity

On devices without U1/U2 (iPhone X and earlier, iPad models without UWB), Fernlet records `rangingMode: "rssi"` and requires the user to manually confirm with a button tap. The current `MultipeerConnectivity` transport does not expose usable RSSI values, so Fernlet does not display or persist a fabricated meter estimate in fallback mode.

This fallback is intentionally weaker than UWB. Documentation, audit records, and the Connection Inspector should make that explicit so the trainer knows the proximity assertion was looser.

### 6.5 Tests (NearbyRangingSessionTests.swift)

- `tapConfirmedDetectorTrueWhenSustainedClose` — feed 1.5 seconds of 0.04-m samples, returns true at ≥ 1.0 second mark.
- `tapConfirmedDetectorFalseWhenBrief` — 0.5 seconds of close samples, returns false.
- `tapConfirmedDetectorFalseWhenFar` — 1.5 seconds of 0.2-m samples, returns false.
- `tapConfirmedDetectorRequiresMinimumSamples` — feed only 2 samples in a 1-second window, returns false.
- `tapConfirmedDetectorResetClearsWindow` — confirm true, call reset, single new sample returns false.
- `tokenArchiveRoundTrip` — archive a known `NIDiscoveryToken` to Data, unarchive, equality holds (use a real `NISession` on hardware tests; mock the token shape for unit tests).
- `fallbackToRSSIWhenHardwareUnsupported` — instantiate with `isHardwareSupported = false`, state publishes `.fallback(rssiOnly: true)`.

---

## 7. Proximity Coordinator (State Machine)

### 7.1 Public API

```swift
@MainActor
final class ProximityCoordinator: ObservableObject {
    enum Role { case advertiser, browser }                  // browser invites, advertiser accepts
    enum Mode { case trainer, friend }                      // determines service type and discoveryInfo

    @Published private(set) var state: State = .idle

    init(identity: IdentityService,
         transport: MultipeerTransport,
         ranging: RangingProvider,
         inspector: ConnectionInspector,
         replayCache: ReplayCache)

    func begin(role: Role, mode: Mode) async

    /// Convenience for the friend-sharing flow: starts advertising AND browsing simultaneously
    /// so either phone can initiate. Uses service type "fernlet-friend". Internally calls
    /// begin(role: .browser, mode: .friend) after cleaning up any stale transport.
    func beginFriendJoin() async

    func acceptPendingInvite() async
    func rejectPendingInvite() async
    func tapToConfirm() async                                // manual override on RSSI fallback
    func confirmPeerIdentity() async                         // user confirms after seeing fingerprint
    func sendPayload(type: PayloadType, summary: PayloadSummary, payload: Data) async throws
    func cancel() async
}

extension ProximityCoordinator {
    enum State: Equatable {
        case idle
        case starting
        case discovering                                     // advertising or browsing
        case peerInRange(peer: MultipeerPeer, distance: RangingDistance)
        case pendingInvite(MultipeerSession.PendingInvite)
        case awaitingTapConfirmation(peer: MultipeerPeer)
        case awaitingIdentityIntroduction(peer: MultipeerPeer)
        case awaitingUserConfirmation(peer: PeerIdentity)    // show the confirm card
        case connected(peer: PeerIdentity)
        case transferring(peer: PeerIdentity, progress: Double)
        case ended(reason: EndReason)
        case failed(reason: String)
    }

    struct PeerIdentity: Equatable, Identifiable {
        let id: UUID
        let displayName: String
        let signingPublicKey: Data
        let keyAgreementPublicKey: Data
        let fingerprint: String                              // 8-char
        let rangingMode: RangingMode
        let firstSeenAt: Date
    }

    enum RangingMode: String, Codable { case uwb, rssi, none }

    enum EndReason: Equatable {
        case userCancelled
        case peerCancelled
        case timeout
        case verificationFailed
        case transportLost
        case completedSuccessfully
    }
}
```

### 7.2 State transition table

| From | Event | To |
|---|---|---|
| `idle` | `begin(role:mode:)` | `starting` |
| `starting` | transport advertising/browsing started | `discovering` |
| `discovering` | transport discovers a peer (browser) | `peerInRange(peer, distance: .unknown)` |
| `discovering` | transport receives invite (advertiser) | `pendingInvite(invite)` |
| `peerInRange` | ranging distance updates | `peerInRange(peer, distance: newValue)` |
| `peerInRange` | browser calls `invite(peer)` | `awaitingTapConfirmation(peer)` |
| `pendingInvite` | `acceptPendingInvite()` | `awaitingTapConfirmation(peer)` |
| `pendingInvite` | `rejectPendingInvite()` | `idle` |
| `awaitingTapConfirmation` | `TapConfirmedDetector.ingest` returns true OR `tapToConfirm()` called | `awaitingIdentityIntroduction(peer)` |
| `awaitingIdentityIntroduction` | receive `identityIntroduction` envelope from peer (new/unknown peer) | `awaitingUserConfirmation(peer)` |
| `awaitingIdentityIntroduction` | receive `identityIntroduction` from previously-trusted peer (friend mode) | `connected(peer)` (auto-confirmed, skips user card) |
| `awaitingUserConfirmation` | `confirmPeerIdentity()` | `connected(peer)` |
| `awaitingUserConfirmation` | `rejectPendingInvite()` | `ended(.userCancelled)` |
| `connected` | `send(envelope)` | `transferring(peer, 0.0)` |
| `transferring` | bytes sent | `transferring(peer, progress)` |
| `transferring` | transfer complete | `connected(peer)` |
| any | `cancel()` | `ended(.userCancelled)` |
| any | transport `.disconnected`, `autoReconnect == false` | `ended(.transportLost)` |
| any | transport `.disconnected`, `autoReconnect == true` (friend mode) | `discovering` → `beginFriendJoin()` (after 2s delay) |
| any | 30s timeout in pre-`connected` state | `ended(.timeout)` |
| any | verify fails on a received envelope | `failed(reason)` |

### 7.3 Handshake sequence (envelope-level)

Once `MCSession` is connected and the tap is confirmed, the initiating side sends `identityIntroduction`; the receiver verifies it and replies with `identityAcknowledge`. Both handshake envelopes can carry an `IdentityRangingPayload`:

```swift
struct IdentityRangingPayload: Codable {
    let rangingMode: String          // "uwb" or "rssi"
    let discoveryToken: Data?        // archived NIDiscoveryToken when UWB is available
}
```

```text
A -> B: FernletIdentityEnvelope(payloadType: .identityIntroduction, payload: IdentityRangingPayload)
B -> A: FernletIdentityEnvelope(payloadType: .identityAcknowledge, payload: IdentityRangingPayload)
```

Each side verifies the introduction signature against the `senderSigningPublicKey` in the envelope itself (trust-on-first-use), confirms the fingerprint matches what was advertised in `discoveryInfo["fp"]`, starts `NIRangingSession` when a peer UWB token is present, and presents the confirm card. After both sides tap Accept, the connection moves to `.connected` and feature-level traffic (trainer plans, live updates) flows.

A trainer plan can be sent immediately after `identityAcknowledge` — the protocol does not require a separate "session start" step.

### 7.4 Tests (ProximityCoordinatorTests.swift)

All tests use `MockMultipeerTransport`, `MockRangingProvider`, and a real `IdentityService` against an in-memory keychain shim.

- `beginAsBrowserStartsBrowsing` → transport receives `startBrowsing` call.
- `beginAsAdvertiserStartsAdvertising` → transport receives `startAdvertising` call.
- `peerDiscoveryUpdatesState` — simulate a discovered peer, assert state.
- `acceptInviteMovesToAwaitingTap` — simulate an invite, accept, assert.
- `rejectInviteReturnsToIdle`.
- `rangingTapConfirmationMovesToIdentityIntroduction` — feed simulated ranging samples that should trigger the detector.
- `rssiFallbackRequiresManualTap` — instantiate with `isHardwareSupported = false`, simulate connection, assert state stays in `awaitingTapConfirmation` until `tapToConfirm()` is called manually.
- `identityIntroductionWithRangingTokenStartsRanging` — feed a signed identity payload with a UWB token, assert `RangingProvider.start(with:)` and inspector mode `.uwb`.
- `unsupportedRangingRecordsRssiFallback` — unsupported provider records `.rssi` mode and fallback event without starting ranging.
- `validIdentityIntroductionMovesToUserConfirmation` — feed a valid signed `identityIntroduction`, assert state contains a `PeerIdentity` with the correct fingerprint.
- `tamperedIdentityIntroductionTransitionsToFailed` — flip a byte in the signature, assert `.failed`.
- `confirmPeerIdentityMovesToConnected`.
- `cancelAtAnyStateMovesToEndedUserCancelled` — parameterized over every state.
- `transportLossMovesToEndedTransportLost`.
- `thirtySecondTimeoutInDiscoveringMovesToEndedTimeout` — virtual clock advance.
- `connectedToTransferringOnSend` — send an envelope, state shows progress.
- `transferCompletionReturnsToConnected`.
- `replayedEnvelopeTransitionsToFailed` — verify the same `envelopeID` twice through the coordinator, second fails.
- `coordinatorEmitsConnectionInspectorEvents` — install a real `ConnectionInspector`, run a happy-path sequence, assert events were captured.

### 7.5 Friend Mode Session Behavior

Friend mode (`.friend`) diverges from trainer mode in several ways. These differences are implemented entirely inside `ProximityCoordinator` and are invisible to the transport layer.

#### Symmetric advertising + browsing
In friend mode both phones simultaneously advertise **and** browse (`"fernlet-friend"` service type). When one phone discovers the other as a browser, it invites immediately. If both discover each other at the same time, a tiebreaker is applied: the peer whose fingerprint sorts lexicographically lower sends the invite; the other accepts.

#### Trusted peer auto-confirmation
When an `identityIntroduction` envelope arrives and the coordinator is in `.friend` mode, it calls `trustPolicy?.isTrustedProximityPeer(fingerprint:)` before presenting a confirmation card. If the fingerprint is in the trust store (previously accepted, not revoked), the coordinator calls `confirmPeerIdentity()` automatically — the user sees no card and the connection advances directly to `.connected`. This requires that:
- `ProximityTrustPolicy` is the protocol governing trust (defined in `TrainerAuditLog.swift`).
- Any consumer that stores trust records (e.g., `FernletStore`) must implement `isTrustedProximityPeer(fingerprint:) -> Bool`.

#### Auto-reconnect on transport loss
When `confirmPeerIdentity()` runs in friend mode, the coordinator sets `autoReconnect = true` and resets `heartbeatSendFailures = 0`. This flag is cleared only by an explicit `cancel()` call (i.e., the user tapping Disconnect). When the coordinator reaches `end(.transportLost)` with `autoReconnect == true`, it:
1. Ends the current Inspector session with `endState: "reconnecting"`.
2. Transitions state to `.discovering`.
3. Sleeps 2 seconds (to let the transport fully tear down).
4. Calls `beginFriendJoin()` to restart advertising and browsing.

This loop continues indefinitely until `cancel()` is called. Engineers adding new proximity features should **not** set `autoReconnect` outside friend mode — trainer mode ends when the transfer completes and does not need auto-reconnect.

#### Transport cleanup before restart
Both `begin(role:mode:)` and `beginFriendJoin()` call `await transport.disconnect()` before re-initializing the MCSession. Skipping this step causes the OS to hold a stale `MCSession` reference, producing duplicate peer discoveries and "already connected" assertion failures.

#### Heartbeat 3-strike tolerance
A single heartbeat `send` failure is non-fatal. The coordinator requires **three consecutive** `heartbeatSendFailures` before calling `end(.transportLost)`. Each successful heartbeat resets the counter to zero. This prevents spurious disconnections from momentary BLE interference.

#### `isSessionLive` guard
MPC's browser fires `lostPeer` callbacks after a connection is established (when the peer stops advertising). Without a guard, `discoveredPeers` becoming empty causes a `.discovered([])` event that transitions the coordinator back to `.discovering` even while `connected`. The `isSessionLive` computed property returns `true` for states `.connected`, `.transferring`, `.awaitingIdentityIntroduction`, and `.awaitingUserConfirmation`. Discovery events (`peerInRange`, `pendingInvite`) are ignored when `isSessionLive == true`.

---

## 8. Connection Inspector

This is the **distinguishing deliverable** of the phase. It exists because two-phone testing without diagnostics is opaque and slow. The Inspector makes every transport event legible during testing and creates a persistent forensic record for debugging field issues.

### 8.1 Behavioral spec

- **Activation modes** (configured via a new entry in `FernletSettings`):
  - `disabled` — Inspector code paths still record events to memory but never present UI and never persist to disk. App Store default.
  - `passive` — Inspector records and persists session logs to disk, but does not present UI automatically. The user can browse logs from Settings → Developer → Connection History.
  - `live` — In addition to passive, the Inspector is accessible via a manual antenna button (⌗) in the feature header. **The inspector does NOT auto-present a sheet anymore.** Earlier versions auto-presented whenever a coordinator transitioned out of `.idle` in `.live` mode, but this was removed because the sheet appearance interrupted the auto-reconnect flow (the sheet's `isPresented` binding competed with the coordinator's state transitions). The user opens the Inspector by tapping the antenna icon; it stays open or closed based solely on user action.
- **Overlay placement:** A bottom sheet at detent `.medium`, layered above the active pairing UI. Stays on top across navigation transitions. Tappable to expand to `.large`. Dismissible via swipe-down or X button.
- **Performance:** Updates published at most 4 Hz to avoid SwiftUI churn during ranging updates that arrive at ~10 Hz.

### 8.2 Captured data

Each pairing session produces a `ConnectionSessionLog`:

```swift
struct ConnectionSessionLog: Identifiable, Codable, Equatable {
    let id: UUID
    var startedAt: Date
    var endedAt: Date?
    var role: ProximityCoordinator.Role
    var mode: ProximityCoordinator.Mode
    var localFingerprint: String
    var peer: PeerInfo?
    var ranging: RangingInfo
    var transport: TransportInfo
    var events: [Event]
    var envelopes: [EnvelopeRecord]
    var errors: [ErrorRecord]
    var summary: Summary { /* computed */ }

    struct PeerInfo: Codable, Equatable {
        let displayName: String
        let advertisedFingerprint: String?
        let confirmedFingerprint: String?
        let signingPublicKey: Data?
        let firstSeenAt: Date
        let lastSeenAt: Date
    }

    struct RangingInfo: Codable, Equatable {
        let mode: ProximityCoordinator.RangingMode      // uwb / rssi / none
        var samples: [DistanceSample]                   // capped at 600 samples (~1 min @ 10 Hz)
        var tapConfirmedAt: Date?
        var minDistanceMeters: Double?
        var maxDistanceMeters: Double?
    }

    struct DistanceSample: Codable, Equatable {
        let timestamp: Date
        let meters: Double
        let directionX: Float?
        let directionY: Float?
        let directionZ: Float?
    }

    struct TransportInfo: Codable, Equatable {
        var mcSessionState: String                       // "notConnected"/"connecting"/"connected"
        var connectedAt: Date?
        var disconnectedAt: Date?
        var bytesSent: Int
        var bytesReceived: Int
        var bluetoothActive: Bool
        var wifiActive: Bool
        var rttSamplesMs: [Double]                       // from heartbeat ping/pong
        var averageRttMs: Double? { /* computed */ }
    }

    struct Event: Codable, Equatable, Identifiable {
        var id: UUID = UUID()
        let timestamp: Date
        let kind: Kind
        let message: String
        enum Kind: String, Codable {
            case stateTransition
            case peerDiscovered
            case peerLost
            case rangingUpdated
            case tapConfirmed
            case inviteSent
            case inviteReceived
            case inviteAccepted
            case inviteRejected
            case identityIntroductionSent
            case identityIntroductionReceived
            case identityVerified
            case identityRejected
            case userConfirmed
            case envelopeSent
            case envelopeReceived
            case envelopeVerified
            case envelopeRejected
            case heartbeatSent
            case heartbeatReceived
            case sessionEnded
            case error
        }
    }

    struct EnvelopeRecord: Codable, Equatable, Identifiable {
        var id: UUID = UUID()
        let envelopeID: UUID
        let direction: Direction
        let payloadType: String
        let payloadByteCount: Int
        let timestamp: Date
        let signatureVerified: Bool?
        let encrypted: Bool
        let summary: String                              // payload.summary.title
        enum Direction: String, Codable { case sent, received }
    }

    struct ErrorRecord: Codable, Equatable, Identifiable {
        var id: UUID = UUID()
        let timestamp: Date
        let domain: String                               // "ranging", "multipeer", "envelope", "coordinator"
        let message: String
        let recoverable: Bool
    }

    struct Summary {
        let durationSeconds: TimeInterval?
        let totalEnvelopes: Int
        let totalBytes: Int
        let errorCount: Int
        let endState: String
    }
}
```

### 8.3 ConnectionInspector class

```swift
@MainActor
final class ConnectionInspector: ObservableObject {
    @Published private(set) var liveLog: ConnectionSessionLog?       // current in-flight session, if any
    @Published private(set) var historicalLogs: [ConnectionSessionLog] = []

    private let store: FernletStore
    private var sessionStart: Date?
    private var sampleSubsamplingCounter = 0
    private let sampleSubsamplingStride = 3                          // keep every 3rd ranging sample → ~3.3 Hz

    init(store: FernletStore) { ... }

    /// Begin a new session log. Called by ProximityCoordinator on transition out of .idle.
    func beginSession(role: ProximityCoordinator.Role,
                      mode: ProximityCoordinator.Mode,
                      localFingerprint: String)

    /// Append an event to the live log.
    func recordEvent(_ kind: ConnectionSessionLog.Event.Kind, message: String)

    /// Append a ranging sample. Subsamples internally to ~3 Hz.
    func recordRangingSample(_ sample: ConnectionSessionLog.DistanceSample)

    /// Append an envelope record.
    func recordEnvelope(_ record: ConnectionSessionLog.EnvelopeRecord)

    /// Append an error.
    func recordError(domain: String, message: String, recoverable: Bool)

    /// Update peer info as it is learned.
    func updatePeer(_ peer: ConnectionSessionLog.PeerInfo)

    /// Update transport metrics.
    func updateTransport(_ block: (inout ConnectionSessionLog.TransportInfo) -> Void)

    /// Close the current session and move it to historicalLogs. Persists to disk.
    func endSession(endState: String)

    /// Export the historical logs as a JSON Data blob for the user to share.
    func exportAsJSON() throws -> Data

    /// Remove logs older than 60 days. Called on app launch.
    func purgeOld()
}
```

### 8.4 Persistence

Persist `historicalLogs` (capped at last 50 sessions) inside `FernletSnapshot` so the existing repository abstraction handles disk I/O. Add `connectionSessionLogs: [ConnectionSessionLog] = []` to `FernletSnapshot`, decoded with `decodeIfPresent ?? []` for legacy snapshots.

Rationale for using FernletSnapshot rather than a separate file:
- Same storage choice (local-only vs. CloudKit) as the rest of the app.
- Same encryption-at-rest properties under the Fernlet lock.
- Backup behavior consistent with user expectations.

Counter-argument: Inspector logs may contain peer public keys, which are sensitive. They are not, however, secret — public keys are designed to be public. Display names and fingerprints are also non-secret. Storing inside the encrypted snapshot is correct.

### 8.5 Live overlay UI (`ConnectionInspectorView`)

A SwiftUI view that subscribes to `ConnectionInspector.liveLog` and renders five sections:

1. **Header:** session state label (e.g., "Awaiting confirmation"), elapsed time, local fingerprint, peer fingerprint (if known).
2. **Identity row:** local display name, peer display name, ranging mode (UWB / RSSI / None), peer first-seen timestamp.
3. **Distance gauge:** current distance in cm, color-coded (green < 5 cm, yellow 5–30 cm, red > 30 cm), with a sparkline of the last 30 seconds of samples.
4. **Transport stats:** bytes sent/received, average RTT, MC session state, BT/Wi-Fi flags.
5. **Event log:** reverse-chronological list of `Event`s, each with timestamp, color-coded by kind. Limited to last 50 events visible; "Show all" button expands to full session.

```swift
struct ConnectionInspectorView: View {
    @ObservedObject var inspector: ConnectionInspector
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let log = inspector.liveLog {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SessionHeader(log: log)
                    IdentityCard(log: log)
                    DistanceGauge(samples: log.ranging.samples)
                    TransportCard(transport: log.transport)
                    EventLog(events: log.events)
                    EnvelopeLog(envelopes: log.envelopes)
                    if !log.errors.isEmpty {
                        ErrorLog(errors: log.errors)
                    }
                }
                .padding(20)
            }
            .background(Color.parchment)
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .padding(16)
            }
        } else {
            VStack { Text("No active session").foregroundStyle(Color.slate) }
        }
    }
}
```

The view is presented as a `.sheet(isPresented:)` from a root-level view modifier installed in `ContentView`:

```swift
.sheet(isPresented: $store.showConnectionInspector) {
    ConnectionInspectorView(inspector: store.connectionInspector)
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled)        // do not block underlying pairing UI
}
```

`store.showConnectionInspector` is toggled by the user tapping the antenna (⌗) button in the feature header. It is never toggled automatically by the coordinator. Features that embed a proximity connection should add this button pattern when `connectionInspectorMode != .disabled`:

```swift
if store.settings.connectionInspectorMode != .disabled {
    HeaderActionButton(systemImage: "antenna.radiowaves.left.and.right") {
        store.showConnectionInspector = true
    }
}
```

### 8.6 Historical browser UI (`ConnectionInspectorHistoryView`)

A list view rendered under Settings → Developer:

- One row per session log, sorted reverse-chronological.
- Row content: date+time, peer display name, duration, endState, error badge if any errors present.
- Tap row → detail view showing the same five sections as the live view, but read-only.
- Toolbar action: "Export all" → presents an `ActivityViewController` (`UIActivityViewController`) with a JSON file named `fernlet-connection-logs-{date}.json`.
- Per-row swipe action: "Delete".

### 8.7 Activation policy in code

Add to `FernletSettings`:

```swift
enum ConnectionInspectorMode: String, Codable, CaseIterable {
    case disabled
    case passive
    case live
}

var connectionInspectorMode: ConnectionInspectorMode = .live    // default to live in TestFlight/dev
```

For App Store builds, override the default to `.passive` at app launch using a compile-time flag (`#if !DEBUG && !TESTFLIGHT`).

The user can change the mode at any time from Settings → Developer → Connection Inspector. Default for App Store users is `.passive` (logs still recorded, just no automatic UI). Power users who want diagnostics can opt into `.live`.

### 8.8 Privacy considerations for the Inspector

- Logs contain peer display names and public keys. These are non-secret. The Inspector does **not** record envelope payload contents — only metadata (type, byte count, signature-verified bool). Payload contents (e.g., the actual trainer plan JSON) never enter the log.
- Logs do not survive a Fernlet factory reset. `IdentityService.wipe()` also wipes `connectionSessionLogs`.
- Export is a deliberate user action through the share sheet — Fernlet never sends logs anywhere automatically.

### 8.9 Tests (ConnectionInspectorTests.swift)

- `beginSessionCreatesLiveLog`.
- `recordEventAppendsToLiveLog`.
- `recordRangingSampleSubsamplesAtCorrectRate` — feed 30 samples in 1 second, assert only 10 are retained (after 3× subsampling).
- `recordEnvelopeNeverIncludesPayloadBytes` — assert `EnvelopeRecord.payloadByteCount` is recorded but no payload field exists on the type.
- `endSessionMovesLogToHistorical`.
- `historicalLogsCappedAt50` — feed 60 sessions, assert oldest 10 are dropped.
- `purgeOldRemovesLogsOlderThan60Days` — insert a log dated 70 days ago, run purge, assert removed.
- `exportAsJSONRoundTripsToCodable` — export, decode, equality.
- `disabledModeDoesNotPersist` — set mode to `.disabled`, run a session, assert `historicalLogs` is unchanged after `endSession`.
- `liveModeDoesNotAutoToggleShowConnectionInspector` — set mode to `.live`, simulate coordinator transition out of idle, assert `store.showConnectionInspector` remains `false` (inspector is purely on-demand; auto-present was removed to avoid competing with auto-reconnect flow).
- `passiveModeDoesNotAutoShowInspector`.
- `replayCachePersistsAcrossSnapshotRoundTrip` — encode `FernletSnapshot` containing logs, decode, assert logs preserved.
- `oldSnapshotWithoutLogsDecodesWithEmptyArray` — legacy JSON without `connectionSessionLogs` key decodes successfully.

---

## 9. Failure Modes & Recovery

| Failure | Detection | Recovery |
|---|---|---|
| User backgrounds the app pre-`connected` | `UIApplication.willResignActiveNotification` | Tear down MCSession + NISession. Show "Pairing cancelled" on resume. |
| User backgrounds the app post-`connected` | Same | Keep MCSession alive for 30s; expect reconnect on foreground. After 30s tear down with `.transportLost`. |
| Bluetooth disabled | `CBCentralManager.state` | Surface "Turn on Bluetooth to pair" with deep link to Settings. |
| Wi-Fi disabled | `NWPathMonitor` | Surface "Turn on Wi-Fi for faster pairing — Bluetooth-only will be slower." Continue with BT only. |
| Peer rejects invite | `MCSession.peer(_:didChange:)` to `.notConnected` immediately after invite | `.ended(.peerCancelled)` |
| Envelope verification fails | `verify()` throws | `.failed(reason:)` with the specific `VerifyError`; record to error log. |
| Replay detected (envelopeID reused) | `ReplayCache.recordIfNew` throws | `.failed(.replayDetected)`. Audit log includes the offending envelopeID. |
| NISession invalidated mid-session | `niSession(_:didInvalidateWith:)` | Fall back to RSSI-only if possible; if not, require user to re-tap. |
| MCSession peer state goes `.notConnected` after `.connected` | Delegate callback | `.ended(.transportLost)`; if a transfer was mid-flight, mark partial. |
| 30-second timeout in any pre-`connected` state | Per-state countdown timer | `.ended(.timeout)`. |
| Local key material missing (Keychain failure) | `IdentityService.ensureProvisioned()` throws | Surface fatal error. Do not silently regenerate — that would silently break trust with every existing peer. |

Recovery from `.failed` is always: dismiss the pairing UI, return to `.idle`, write a `ConnectionSessionLog` with `endState == "failed"`, and let the user retry from scratch.

---

## 10. Battery, Background, and Foreground Anchoring

### 10.1 Battery profile

- MCSession with both Wi-Fi and BT active: ~5–10% per hour on iPhone 15-class hardware. Acceptable for a 60-minute workout session.
- NISession active: ~2% additional per hour. Only active during pairing (first ~15 seconds), so the cost is minor.
- Inspector live UI subscribed to ranging samples: < 1% additional per hour at 4-Hz sampling.

### 10.2 Foreground anchoring

The most common failure mode for long peer sessions is iOS suspending the app after backgrounding. Mitigations, in order of preference:

1. **Live Activity (ActivityKit).** When a proximity session enters `.connected`, automatically start a Live Activity titled "Connected to {peer name}" with elapsed time, transferred-bytes counter, and an "End session" button. The Live Activity counts as in-use foreground equivalent, preventing suspension. Apple does not officially document Live Activities as preventing suspension, but in practice the app-process gets adequate runtime to keep `MCSession` alive.

2. **HKWorkoutSession.** If the consumer feature is `TrainerProximityService` and a workout is active, the existing `HKWorkoutSession` from Phase M8 acts as the foreground anchor. This is the strongest guarantee — workout sessions are explicitly designed by Apple to keep apps alive.

3. **Background mode declaration.** Declare `bluetooth-central` and `bluetooth-peripheral` in `Info.plist > UIBackgroundModes`. This grants short bursts of background time when BLE activity is detected, useful for finishing an in-flight transfer if the user briefly backgrounds.

4. **MCSession heartbeat — variable rate.** The heartbeat interval adapts to session activity rather than ticking at a fixed rate:

   | Phase | Interval | Rationale |
   |---|---|---|
   | Discovery / connection setup | 5 s | Fast feedback during the critical pairing window |
   | Stable idle (connected, no data flow) | 30 s | Battery-friendly; peer is confirmed alive, network is stable |
   | Active transfer (plan, photo, file sharing) | 3 s | Detect loss mid-transfer before the user sees a hang |
   | Post-transfer cooldown (30 s window) | 10 s | Ramp back down gradually |

   Each heartbeat is a signed `sessionHeartbeat` ping envelope containing an ID and timestamp. The receiver replies with a signed ack envelope referencing that ID; the sender records the elapsed milliseconds in `ConnectionSessionLog.transport.rttSamplesMs`, which drives the inspector's average RTT. If **three consecutive heartbeats** are missed at whatever the current interval is, declare `.transportLost`. This is the only mechanism that detects a half-open connection (where one side died silently without a clean `.notConnected` callback).

5. **ActivityKit update deduplication.** `ActivityKitProximityForegroundAnchor.update(bytesSent:bytesReceived:)` is called on every inbound or outbound message event. Without deduplication, a 10-photo session produced 23+ `Activity.update()` calls, all with identical state, generating console noise and unnecessary IPC. The anchor stores `lastBytesSent` and `lastBytesReceived` (initialized to -1 so the first call always fires) and skips the update if neither value changed. Any future contributor modifying the anchor must preserve this guard.

### 10.3 Tests for lifecycle

UI tests are impractical for backgrounding behavior. Hand-test via the Manual Test Protocol §12.

Unit tests in `MultipeerSessionTests.swift`:
- `heartbeatUsesDiscoveryIntervalDuringSetup` — virtual clock advances during connection setup; assert 5 s intervals.
- `heartbeatSlowsToIdleIntervalWhenStable` — after 60 s of no data flow; assert 30 s intervals.
- `heartbeatAcceleratesDuringTransfer` — trigger a transfer; assert interval drops to 3 s.
- `threeMissedHeartbeatsTriggersTransportLost` — at any interval, three consecutive misses → `.transportLost`.

---

## 11. Privacy, Consent, and Audit

### 11.1 Consent before any data leaves

- Pairing requires affirmative user action on both devices: open the pairing sheet, hold phones together (tap-confirm), and tap Accept on the confirmation card. No background pairing. No "trusted devices" list that bypasses this on subsequent sessions — every session begins with discovery and explicit user intent.

- **Confirmation before connecting with any new peer.** When the coordinator transitions to `.awaitingLocalAcceptance`, it checks whether the advertising peer's fingerprint (`discoveryInfo["fp"]`) has been seen before. For a **first-time peer**, a prominent pre-invite dialog is shown *before* accepting the MCSession connection:

  > **Unknown device wants to connect**
  > **"Coach Alex's iPhone"** (`fp: a3f829b4`)
  > This is the first time you've seen this device. Only accept if you physically see someone nearby who told you their name.
  > [ Reject ] [ Accept ]

  For **returning peers** (fingerprint previously accepted and stored), this dialog is skipped and the connection proceeds directly to the tap-confirmation step. This is the primary defense against a malicious nearby device fishing for connections.

- Trust-on-first-use is the default. Once a peer's public key is seen and accepted, subsequent pairings with the same key skip the pre-invite dialog. If the key changes for a previously-seen display name, surface a strong warning: "This trainer's key has changed since you last paired. Either they reinstalled Fernlet, or someone is impersonating them. Reject if uncertain."

### 11.2 Disclosure on first pairing

The confirmation card on first pairing with a trainer shows:

> Accept plan from **Coach Alex**?
>
> Coach Alex will be able to:
> - Send you planned workouts
> - Receive your completed workout summaries (sets, reps, weight, duration, your effort rating)
> - See when you swap their plan for another trainer's
>
> Coach Alex will *not* see:
> - Your journal, period, sleep, or mood data
> - Notes you mark as `#private` or `[SENSITIVE]`
> - Any data from before today
>
> Fingerprint: `a3f829b4`
> [ Reject ]   [ Accept ]

The fingerprint is the 8-char SHA-256 prefix of the trainer's public key. Trainer apps display the same fingerprint to the trainer on their end. A trainer reading the same fingerprint as the client sees confirms the connection is authentic.

### 11.3 Audit log integration

Every proximity event writes to the `TrainerAuditLog` (defined in `codex-implementation-prompts.md` M7.1). The Inspector's `ConnectionSessionLog` is the *technical* trace; the `TrainerAuditEvent` log is the *user-facing* trace. Both exist; they have different audiences.

### 11.4 Revocation

When a user revokes a trainer (Settings → Trainers → Revoke), the trainer's public key is added to a local revocation list. Any future envelope signed by that key is dropped at the verification layer with `.failed(reason: "revokedKey")`. The revocation is local; the trainer's app does not know they've been revoked unless they try to send a plan and observe the failure.

---

## 12. Manual Two-Phone Test Protocol

This protocol exists because automated tests cannot exercise the actual MCSession + NISession stack. Manual two-phone testing is mandatory for sign-off on each phase.

### 12.1 Test environment

- Two iPhones, both supported devices (iPhone 11 or later for UWB; iPhone X or earlier for RSSI-fallback testing).
- Both running the same TestFlight build of Fernlet.
- Both with Bluetooth and Wi-Fi on.
- Connection Inspector mode set to `.live` on both.
- Pre-recorded video setup (so reviewers can observe Inspector overlays).

### 12.2 Happy path

1. Phone A: Settings → Trainers → "Pair with new trainer" → opens pairing sheet (role: client/advertiser).
2. Phone B: same path, but pick role: trainer/browser.
3. Hold phones tip-to-tip.
4. Open the Inspector manually on both phones with the antenna button if live diagnostics are needed. `state = discovering` → `peerInRange` / `awaitingTapConfirmation` should appear quickly; UWB distance samples populate after identity/ranging-token exchange.
5. Both phones automatically transition to `awaitingUserConfirmation` when UWB tap confirmation succeeds, or after manual confirmation in fallback mode. The fingerprints displayed on both devices must match (same 8 chars, same order).
6. Both phones tap Accept.
7. **Inspector observation:** Both phones' state → `connected`. Bytes sent/received counter starts incrementing as identity envelopes flow. Average RTT populates within 10 seconds.
8. Phone B sends a test trainer plan.
9. **Inspector observation:** Phone A shows `envelopeReceived` event with `signatureVerified: true`. Phone A's Move tab shows the new "Today's plans" card.
10. Both phones close the pairing sheet.
11. Phone A: Settings → Developer → Connection History → confirm a `ConnectionSessionLog` entry exists with the expected duration, peer info, and event trace.

### 12.3 Failure paths to verify

For each, observe the Inspector to confirm the failure is captured cleanly:

- Phone B rejects the confirmation card → Phone A shows `.ended(.peerCancelled)`.
- Phone A backgrounds during pairing → Phone B sees `.ended(.transportLost)` within 30 seconds.
- Phones held more than 30 cm apart for 30 seconds → both show `.ended(.timeout)`.
- Phone B's Fernlet is force-quit during a transfer → Phone A sees `.ended(.transportLost)` and the partial plan is not persisted.
- Inspector toggle: set mode to `.passive` on Phone A, repeat happy path → no overlay appears, but `Connection History` shows the session afterward.
- Inspector toggle: set mode to `.disabled` on Phone A, repeat happy path → no overlay, no history entry.

### 12.4 Performance assertions

During the happy path, observe and record (in the test report):
- Time from "hold together" to first `state = peerInRange` (target: < 2 seconds).
- Time from `peerInRange` to `tapConfirmed` (target: < 1.5 seconds).
- Time from `tapConfirmed` to `awaitingUserConfirmation` (target: < 1 second).
- Average RTT in `connected` state (target: < 100 ms over Wi-Fi Direct, < 300 ms over Bluetooth-only).
- Battery delta on Phone A across a 60-minute connected session (target: < 12%).

### 12.5 Diagnostic export

At the end of any failed test, the tester exports `Settings → Developer → Connection History → Export all` and attaches the JSON file to the test report. This becomes the artifact engineers debug against.

---

## 13. Automated Test Strategy

Automated tests cannot exercise real MCSession or NISession, but they cover the orchestration. Coverage targets:

- IdentityService: 100% statement coverage (it's pure crypto + Keychain).
- FernletIdentityEnvelope: 100% statement coverage including every verify-error branch.
- MultipeerSession via MockMultipeerTransport: 90%+.
- NearbyRangingSession via MockRangingProvider: 90%+ (the TapConfirmedDetector is pure logic and gets 100%).
- ProximityCoordinator: 90%+ across all state transitions.
- ConnectionInspector: 100% of recording paths, all activation-mode branches.

### 13.1 Mock layer

Three protocol-conformant mocks live in `FernletTests/Mocks/`:

- `MockMultipeerTransport` — exposes `simulateDiscovery(peer:)`, `simulateInvite(peer:)`, `simulateInboundData(_:)`, `simulateDisconnection()`. Tests drive the mock and assert on coordinator state.
- `MockRangingProvider` — exposes `simulateDistanceSample(meters:)`. Tests feed sequences and observe TapConfirmedDetector behavior.
- `MockIdentityService` — backed by in-memory storage rather than Keychain. Otherwise identical surface.

### 13.2 Property-based tests

For the envelope layer, add property-based tests using a small handwritten generator:

- For 100 random `FernletIdentityEnvelope` instances, signing and verifying always succeeds.
- For 100 random instances, any single-byte flip in `payload`, `payloadSummary.title`, `createdAt`, or `senderSigningPublicKey` always causes verification to fail.
- For 100 random `(payload, recipientKeyAgreementPublicKey)` pairs, seal-then-open always round-trips.

Use a simple `RandomGenerator` helper in the test target (not a full QuickCheck-style framework) to keep dependencies light.

### 13.3 Snapshot tests

Use the existing snapshot testing pattern (if present in `FernletTests`) for the Connection Inspector SwiftUI views. Snapshots cover:
- Empty live log.
- Live log with peer, ranging samples, and events but no envelopes.
- Live log with all sections populated.
- Historical log row in the list view.

---

## 14. Phased Execution

Each sub-phase is independently shippable, builds on the previous, and is testable through manual two-phone protocol §12.

| Sub-phase | Title | Files | Exit criteria |
|---|---|---|---|
| ✅ 7.1 | Identity Service | `Proximity/IdentityService.swift`, `KeychainHelpers.swift` (refactored) | **COMPLETE 2026-05-24** — 13/13 tests passing. `FernletLockService` unchanged. |
| ✅ 7.2 | Envelope spec + ReplayCache | `Proximity/FernletIdentityEnvelope.swift`, `Proximity/ReplayCache.swift` | **COMPLETE 2026-05-24** — 15/15 tests passing. Sign/verify/seal/open/replay-block all exercised. |
| ✅ 7.3 | MultipeerSession wrapper | `Proximity/MultipeerSession.swift`, `Mocks/MockMultipeerTransport.swift` | **COMPLETE 2026-05-24** — 9/9 tests passing. Two-phone live test pending manual sign-off. |
| ✅ 7.4 | NearbyInteraction wrapper + TapConfirmedDetector + RSSI fallback | `Proximity/NIRangingSession.swift` (contains `TapConfirmedDetector`), `Mocks/MockRangingProvider.swift` | **COMPLETE 2026-05-24** — 7/7 tests passing. `NISession.deviceCapabilities` used on iOS 16+. Two-phone tap-confirm test pending. |
| ✅ 7.5 | ProximityCoordinator state machine | `Proximity/ProximityCoordinator.swift` | **COMPLETE 2026-05-24** — 16/16 coordinator tests passing. Two-phone happy path §12.2 still pending manual sign-off. |
| ✅ 7.6 | ConnectionInspector (live overlay + historical) | `Proximity/ConnectionInspector.swift`, `Proximity/ConnectionInspectorView.swift`, `Proximity/ConnectionInspectorHistoryView.swift`, `Proximity/ConnectionSessionLog.swift` | **COMPLETE 2026-05-24** — 13/13 inspector tests passing. Manual overlay/history sign-off still pending two-phone testing. |
| ✅ 7.7 | Battery & foreground anchoring (Live Activity + variable heartbeats) | `Proximity/ProximityCoordinator.swift`, `Proximity/ProximityForegroundAnchor.swift` | **COMPLETE 2026-05-24** — 5 heartbeat/anchor cases added to `ProximityCoordinatorTests` (21/21 coordinator tests passing). A 60-minute two-phone battery run still pending manual sign-off. |
| ✅ 7.8 | Disclosure + revocation + audit-log integration | `Proximity/TrainerProximityService.swift`, `Proximity/TrainerAuditLog.swift`, `Proximity/ProximityCoordinator.swift`, `FernletStore.swift` persistence hooks | **COMPLETE 2026-05-24** — disclosure card includes peer fingerprint and permission boundaries; accepted peers persist as trust records; revoked signing keys fail subsequent envelopes with `revokedKey`; trainer audit events capture coordinator state transitions and trust decisions. |

### 14.1 Dependencies on other phases

- 7.1 depends on the existing Keychain helpers in `FernletLockService.swift` being refactored to a shared file. This refactor is one prompt's worth of work and should not break the existing lock tests.
- 7.6 depends on `FernletStore` already having a `@Published var connectionInspector: ConnectionInspector` plumbed through. This requires a one-line addition in 7.5 when the coordinator is wired.
- 7.7 depends on M8.2 (Live Activity for live workouts) — they share `FernletWorkoutActivityAttributes`. If 7.7 lands before M8.2, ship a smaller standalone `FernletProximityActivityAttributes` that 7.7 owns, then unify with M8.2 later.

---

## 15. Open Decisions (with resolutions)

### Resolved

1. **Service-type naming.** ✅ **RESOLVED** — Two separate service types:
   - `"fernlet-coach"` — trainer pairing. The trainer side runs a **separate, dedicated trainer app** (not the Fernlet client app). The client app advertises; the trainer app browses. This means the Fernlet client will never appear as a trainer in someone else's coach pairing sheet.
   - `"fernlet-friend"` — friend sharing. Both sides run the **same Fernlet app**. Either user can initiate. Scoped to recipe, workout summary, and plan sharing between personal users.
   Keeping the two service types distinct prevents trainer-mode pairing sheets from discovering friend-mode advertisers and vice versa. The `discoveryInfo["role"]` field is informational only (shown in the Inspector), not a security boundary.

2. **Heartbeat interval.** ✅ **RESOLVED** — Variable rate, not a fixed interval. See §10.2 table:
   - 5 s during discovery/connection setup
   - 30 s during stable idle
   - 3 s during active transfer
   - 10 s during post-transfer cooldown (30 s window)
   Three consecutive misses at the current interval triggers `.transportLost`.

3. **Maximum session duration.** ✅ **RESOLVED** — No hard cutoff. Surface a **soft prompt** at 90 minutes:
   > "Still working out? Your session with Coach Alex is 90 minutes old. [ Keep going ] [ End session ]"
   The user chooses. If no response within 5 minutes, keep the session alive (do not terminate silently). A workout that is still receiving live heartbeats is by definition still active.

4. **Malicious peer / unknown peer confirmation.** ✅ **RESOLVED** — Show a prominent pre-invite dialog for any peer whose fingerprint has not been previously accepted (see §11.1). Returning peers (known fingerprint) skip the dialog and proceed directly to tap-confirmation. Key-change warnings remain for returning peers whose key differs from the stored one.

### Still open

5. **Inspector activation in production builds.** Default `.passive` (recording only, no UI) or `.disabled` (nothing)? **Recommendation:** `.passive`. The user can opt into `.live` if they're debugging a problem and reporting to support. Logs are tiny (< 50 KB per session).

6. **Inspector overlay placement.** Sheet (default) vs. floating window via the iOS 16+ system-level overlay APIs. **Recommendation:** sheet for v1; system overlay deferred to v2.

7. **NIDiscoveryToken backwards compatibility.** Apple's docs note tokens are not stable across NISession invalidations. Fernlet discards and regenerates every session, so this is not a problem in practice — document it in code comments on `myDiscoveryToken()`.

8. **Both devices advertising simultaneously (invite race).** Both will discover each other and see an invite-or-be-invited race. **Recommendation:** in the coordinator, when in `.discovering` (advertising mode) and an invite arrives from a peer already seen in the browser, prefer accepting their invite if it arrives within 2 seconds; otherwise send an outgoing invite.

9. **Revocation list pruning.** How many revoked keys do we store before pruning? **Recommendation:** unbounded for v1 — a list of 32-byte public keys is tiny.

10. **Mesh networking rollout.** See §16 for the v2 design. The open question is when to schedule 7.9 (mesh layer) — depends on real-world group size data from v1 trainer sessions.

---

## 16. Mesh Networking — v2 Design

### 16.1 Problem statement

v1 caps each `ProximityCoordinator` at one peer (the `MCSession` `maximumNumberOfPeers = 1` setting). The original plan deferred large-group scenarios to cloud (Phase 9). The new direction: **avoid cloud entirely** for groups physically in the same space by building a proximity-anchored P2P mesh.

Use case: a trainer runs a group class with 8–15 participants. All are in the same gym. They don't need a server — they're standing 5 metres apart.

### 16.2 Architecture

Each device runs a **MeshNode** that manages up to 2–3 simultaneous `MCSession` connections (one per direct peer). The mesh self-organises based on physical proximity:

```
        [Coach]
       /        \
  [Alice]      [Bob]
    |               |
  [Carol]     [Dave]
    \               /
      [Eve]——[Frank]
```

- Coach pairs with Alice and Bob (the two closest, e.g. UWB-confirmed < 1 m).
- Alice pairs with Coach and Carol. Bob pairs with Coach and Dave.
- Envelopes destined for the whole group carry a `meshTTL: Int` field and a `meshRouteID: UUID` in their header. Each node forwards to its connected peers that have not yet seen the `meshRouteID`, then decrements `meshTTL`. At `meshTTL == 0` the envelope is not forwarded further.
- There is no global routing table. Discovery is purely local: each node connects to the nearest 2–3 devices it can find using the standard `MultipeerSession` discovery flow.

### 16.3 Constraints

| Constraint | Value | Rationale |
|---|---|---|
| Max direct connections per node | 2–3 | `MCSession` supports up to 8 but battery and CPU cost scale linearly; 2–3 keeps a healthy mesh while staying well within budget |
| `meshTTL` initial value | 6 | Supports up to ~6 hops, covering a realistic chain of 7 nodes before the message dies |
| Envelope deduplication window | 5 minutes | `meshRouteID` tracked in a per-node `ReplayCache`-style set; entries expire after 5 min |
| Group size practical limit | ~20 devices | At 3 connections/node, a connected mesh of 20 fits within 7 hops with a well-formed graph. For larger groups, fall back to cloud (Phase 9). |

### 16.4 New types (v2)

```swift
// Added to FernletIdentityEnvelope (schema version 2):
var meshTTL: Int?          // nil for 1:1 sessions; set by originating node for mesh
var meshRouteID: UUID?     // deduplication key; set once, never modified in transit

// New file: Proximity/MeshNode.swift
@MainActor
final class MeshNode: ObservableObject {
    let maxPeers: Int = 3
    private var coordinators: [UUID: ProximityCoordinator] = [:]   // one per direct peer
    func join(role: ProximityCoordinator.Role, mode: ProximityCoordinator.Mode) async
    func broadcast(_ envelope: FernletIdentityEnvelope) async throws
    func leave() async
}
```

### 16.5 Implementation sub-phase

This is **sub-phase 7.9**, dependent on 7.5 (coordinator) being stable. Schedule after real-world v1 data shows groups larger than 1:1 are needed.

Exit criteria:
- `MeshNodeTests.swift` passes: message propagated across a simulated 5-node graph with correct TTL decrement and deduplication.
- Manual test: 4 iPhones in the same room, one sends a plan envelope, all four receive it within 3 seconds.

---

## 17. Field-Tested Stability Patches (May 2026) & Guide for Future Proximity Consumers

This section documents changes made after the initial implementation and landing of sub-phases 7.1–7.8, based on two-phone testing of the friend-sharing feature. Engineers adding new proximity-based features should read this section before starting.

### 17.1 Summary of patches applied

| Area | Root cause | Fix |
|---|---|---|
| MPC "giving up on channel [2/3/4/5]" | `.required` encryption with nil security identity triggers mandatory TLS handshake on channels 2–5 that always fails | Changed to `.optional` in `MultipeerSession.ensureSession()` |
| Random disconnection after connect | MPC browser fires `lostPeer` after session established when peer stops advertising; coordinator re-entered `.discovering` | Added `isSessionLive` guard — discovery events are no-ops while in `connected`, `transferring`, `awaitingIdentityIntroduction`, `awaitingUserConfirmation` |
| Single heartbeat failure causes teardown | One `send` error in a heartbeat loop ended the session | Require 3 consecutive failures (`heartbeatSendFailures >= 3`) before calling `end(.transportLost)` |
| Friends not remembered between sessions | `handleIdentityEnvelope` always went to `.awaitingUserConfirmation` even for known fingerprints | Added `isTrustedProximityPeer(fingerprint:)` to `ProximityTrustPolicy`; in friend mode, auto-confirm if fingerprint matches a non-revoked trust record |
| No auto-reconnect on transport loss | Session ended permanently on any transport disconnect | `autoReconnect` flag (set on `confirmPeerIdentity` in friend mode, cleared by `cancel()`) causes `end(.transportLost)` to loop back via `beginFriendJoin()` after 2s |
| Stale MCSession on restart | Transport not cleaned up before re-initializing | `begin()` and `beginFriendJoin()` now call `await transport.disconnect()` first |
| 23+ redundant ActivityKit updates per photo session | `update()` called on every message regardless of whether bytes changed | Added `lastBytesSent`/`lastBytesReceived` guards with initial value -1 in `ActivityKitProximityForegroundAnchor` |
| Inspector auto-present blocked auto-reconnect | `beginSession()` set `store.showConnectionInspector = true` in `.live` mode, competing with reconnect flow | Removed auto-present from `beginSession()`; inspector is now on-demand via antenna button in feature header |
| Inspector distance and RTT blank | Coordinator updated `lastKnownDistance` but did not record inspector samples; heartbeat had no ack timing | Coordinator now records `RangingDistance.meters` into `ConnectionSessionLog.ranging.samples`; heartbeat ping/ack records `transport.rttSamplesMs` |
| UWB never started in production | Identity handshake did not exchange `NIDiscoveryToken` payloads or call `ranging.start(with:)` | Signed identity intro/ack payloads now carry `IdentityRangingPayload`; coordinator starts UWB when peer token is present and logs RSSI/manual fallback otherwise |
| CloudKit `updateTaskRequest` spam | `scheduleSnapshotSave()` used a one-tick boolean debounce allowing rapid consecutive `context.save()` calls | Replaced with a 1-second `Task`-based debounce (`snapshotSaveTask`) that cancels previous pending saves |

### 17.2 Guide for new proximity feature builders

If you are building a new feature that uses `ProximityCoordinator` (e.g., a new payload type, a new sharing flow), read these requirements:

#### Required: Implement `ProximityTrustPolicy` if you need trust checking
If your feature operates in friend mode and needs to auto-confirm previously-trusted peers, your service class or store must implement:

```swift
protocol ProximityTrustPolicy: AnyObject {
    func isRevokedProximitySigningKey(_ publicKey: Data) -> Bool
    func isTrustedProximityPeer(fingerprint: String) -> Bool
    func recordTrainerAudit(_ event: TrainerAuditEvent)
}
```

Pass it to `ProximityCoordinator(trustPolicy:)`. Without this, every reconnection will show a confirmation card even for known friends.

#### Required: Register as a `ProximityPayloadHandling` consumer
Receiving custom payloads requires conforming to `ProximityPayloadHandling` and attaching to the coordinator:

```swift
protocol ProximityPayloadHandling: AnyObject {
    func proximityCoordinator(
        _ coordinator: ProximityCoordinator,
        didReceive envelope: FernletIdentityEnvelope,
        plaintext: Data,
        from peer: ProximityCoordinator.PeerIdentity?
    )
}

// In your service init:
coordinator.attachPayloadHandler(self)
```

The `didReceive` callback fires for **all** payload types including built-ins (heartbeat, identity intro). Always check `envelope.payloadType` before processing.

#### Required: Add a new `PayloadType` case for custom payloads
Do not reuse existing payload type strings. Add a new case to `PayloadType` in `FernletIdentityEnvelope.swift`:

```swift
case friendPhoto = "fernlet.friend.photo.v1"
case myNewFeature = "fernlet.myfeature.thing.v1"
```

Reverse-DNS `"fernlet."` prefix, short descriptive segment, `.vN` suffix. Never reuse a string — once a type string is shipped it is part of the wire format (see Appendix B).

#### Required: Add antenna button to feature header
Any view that hosts a proximity session must expose the inspector button when inspector mode is not disabled:

```swift
if store.settings.connectionInspectorMode != .disabled {
    HeaderActionButton(systemImage: "antenna.radiowaves.left.and.right") {
        store.showConnectionInspector = true
    }
}
```

#### Do not auto-reconnect in trainer mode
The `autoReconnect` flag is a friend-mode concern. Trainer sessions are one-shot: they connect, transfer, and end. Setting `autoReconnect` in trainer mode would cause the coordinator to restart advertising indefinitely after the trainer closes the session.

#### Do not set `autoReconnect` from outside the coordinator
The flag is managed internally by `confirmPeerIdentity()` and `cancel()`. Consumers observe `coordinator.state` and call `disconnect()` or `cancel()` to stop reconnection.

#### Use `sendPayload(type:summary:payload:)` for outbound data
Do not construct `FernletIdentityEnvelope` manually in consumer code. The coordinator wraps your payload in a signed envelope with correct expiry and replay protection:

```swift
try await coordinator.sendPayload(
    type: .myNewFeature,
    summary: PayloadSummary(title: "My thing", itemCount: 1),
    payload: encodedData
)
```

#### Inspector is on-demand only
Do not call `store.showConnectionInspector = true` from coordinator event callbacks. The user opens it manually. Automatic presentation interferes with auto-reconnect and overlaps pairing UI.

#### Snapshot save debounce
`FernletStore` debounces snapshot saves by 1 second. If your feature writes to the store frequently (e.g., appending received photos), this is already handled. Do not call `performSnapshotSave()` directly — always go through `scheduleSnapshotSave()`. If you need a synchronous flush before an operation (e.g., app termination), call `store.flushPendingSnapshotSave()`.

---

## Appendix A — File-by-file impact summary

| File | Status | Change |
|---|---|---|
| `FernletLockService.swift` | ✅ Modified | Extract `KeychainItem` helpers into `KeychainHelpers.swift`; otherwise unchanged. |
| `KeychainHelpers.swift` | ✅ NEW | Shared Keychain accessors used by both `FernletLockService` and `IdentityService`. |
| `Proximity/IdentityService.swift` | ✅ NEW | Ed25519 + X25519 identity, sign/verify/seal/open. |
| `Proximity/FernletIdentityEnvelope.swift` | ✅ NEW | Envelope struct + verify error enum + canonical encoder. |
| `Proximity/ReplayCache.swift` | ✅ NEW | UUID-based replay detection with 24h retention. |
| `Proximity/MultipeerSession.swift` | ✅ NEW + patched | MCSession wrapper, peer-ID persistence, discovery, transfer. **Patch (2026-05-24):** Changed `encryptionPreference` from `.required` to `.optional` to prevent TLS channel handshake failures. |
| `Mocks/MockMultipeerTransport.swift` | ✅ NEW | Test mock conforming to `MultipeerTransport`. |
| `Proximity/NIRangingSession.swift` | ✅ NEW | NISession wrapper + `TapConfirmedDetector` (embedded class) + RSSI fallback. Uses `NISession.deviceCapabilities` on iOS 16+, falls back to `NISession.isSupported` on older OS. |
| `Mocks/MockRangingProvider.swift` | ✅ NEW | Test mock conforming to `RangingProvider`. |
| `ProximityCoordinator.swift` | ✅ NEW + patched | State machine composing the three primitives. **Patches (2026-05-24/25):** Added `isSessionLive` guard; `beginFriendJoin()` API; `autoReconnect` flag + loop in `end(.transportLost)`; 3-strike heartbeat failure counter; heartbeat ping/ack RTT sampling; signed NI token exchange in identity intro/ack; trusted peer auto-confirmation via `ProximityTrustPolicy`; transport cleanup before session restart; `pendingPeerIdentity` tracking. |
| `ConnectionInspector.swift` | ✅ NEW + patched | Observer + session log persistence. **Patches (2026-05-24/25):** Removed auto-present from `beginSession()` — inspector is now on-demand only; added ranging-mode updates and distance/RTT recording support. |
| `ConnectionInspectorView.swift` | ✅ NEW + patched | Live inspector sheet. **Patch (2026-05-25):** Shows explicit UWB waiting/RSSI fallback copy when no distance samples are available. |
| `ConnectionInspectorHistoryView.swift` | ✅ NEW | Past sessions browser. |
| `ConnectionSessionLog.swift` | ✅ NEW | Persistent record types. |
| `Proximity/ProximityForegroundAnchor.swift` | ✅ NEW + patched | ActivityKit/no-op foreground anchor abstraction for connected sessions. **Patch (2026-05-24):** Added `lastBytesSent`/`lastBytesReceived` deduplication to `update()` to prevent redundant ActivityKit calls. |
| `Models.swift` (or `FernletSettings.swift`) | ✅ Modified | Add `ConnectionInspectorMode` and `connectionInspectorMode` to `FernletSettings`. |
| `LocalFernletRepository.swift` | ✅ Modified | Extend `FernletSnapshot` with `connectionSessionLogs: [ConnectionSessionLog]`. |
| `CoreDataFernletRepository.swift` | ✅ Modified | Mirror snapshot extension. |
| `FernletStore.swift` | ✅ Modified | Add `@Published var connectionInspector: ConnectionInspector`; wire persistence and live presentation. **Patch (2026-05-24):** Added `isTrustedProximityPeer(fingerprint:)` implementing `ProximityTrustPolicy`; replaced one-tick boolean snapshot debounce with 1-second `Task`-based debounce (`snapshotSaveTask`); added `flushPendingSnapshotSave()`. |
| `SettingsSheet.swift` | ✅ Modified | Add "Connection Inspector" toggle under Developer section; add "Connection History" link. |
| `ContentView.swift` | ✅ Modified | Install the inspector sheet modifier at the root. |
| `Proximity/FriendPhotoShareView.swift` | ✅ NEW + patched | Friend-to-friend photo sharing UI and `FriendPhotoSharingService`. **Patch (2026-05-24):** Added manual antenna button in header for on-demand inspector access; replaced previously absent inspector trigger. |
| `Proximity/TrainerAuditLog.swift` | ✅ Modified | **Patch (2026-05-24):** Added `isTrustedProximityPeer(fingerprint:)` to `ProximityTrustPolicy` protocol, required for trusted-peer auto-confirmation. |
| `Info.plist` | ✅ Modified | Added `NSLocalNetworkUsageDescription`, `NSBonjourServices` (`_fernlet-coach._tcp`, `_fernlet-coach._udp`), `UIBackgroundModes` (`bluetooth-central`, `bluetooth-peripheral`), and `NSNearbyInteractionUsageDescription`. |
| `Docs/proximity-handshake-process-map.md` | ✅ NEW | Process map for handshake, coordinator data collection, and trainer/friend differences. |
| `IdentityServiceTests.swift` | NEW | Tests per §3.5. |
| `FernletIdentityEnvelopeTests.swift` | NEW | Tests per §4.5. |
| `MultipeerSessionTests.swift` | NEW | Tests per §5.4. |
| `NearbyRangingSessionTests.swift` | NEW | Tests per §6.5. |
| `ProximityCoordinatorTests.swift` | NEW | Tests per §7.4. |
| `ConnectionInspectorTests.swift` | ✅ NEW | Tests per §8.9. |
| `FileIndex.md` | Modified | New rows for every new file. |
| `ImplementationPlan.md` | Modified | Replace §Phase 7 with a one-paragraph summary that points to this document. |

---

## Appendix B — Wire format reference

For external (trainer-app) consumers writing the other side of the protocol, the canonical wire format is:

```
ENVELOPE_JSON_BYTES :=
    UTF-8 JSON encoding of FernletIdentityEnvelope
    using JSONEncoder(.sortedKeys, .withoutEscapingSlashes)
    with dateEncodingStrategy = .iso8601

WIRE_PACKET :=
    big-endian uint32 length prefix
    || ENVELOPE_JSON_BYTES

SIGNATURE_INPUT :=
    UTF-8 JSON encoding of envelope with `signature: ""` cleared,
    sorted keys, ISO-8601 dates

SIGNATURE := Ed25519.sign(SIGNATURE_INPUT, senderSigningPrivateKey)
```

Multipeer Connectivity's `send(_:toPeers:with:)` API does its own framing; the length prefix above is for any future non-MC transports (BLE GATT, TCP socket) that might consume the envelope. For MC transports the prefix is omitted.

For sealed payloads (`payloadEncryption == .sealedTo`), the `payload` field contains:

```
SEALED_PAYLOAD :=
    senderEphemeralX25519PublicKey (32 B)
    || ChaCha20Poly1305 nonce (12 B)
    || ChaCha20Poly1305 ciphertext (variable)
    || ChaCha20Poly1305 tag (16 B)

  where:
    sharedSecret = X25519(senderEphemeralPrivateKey, recipientX25519PublicKey)
    symmetricKey = HKDF-SHA256(
                       ikm:  sharedSecret,
                       salt: "fernlet.proximity.v1",
                       info: senderSigningPublicKey || recipientX25519PublicKey,
                       L:    32
                   )
    ciphertext, tag = ChaCha20Poly1305.seal(
                          plaintext: payloadJSON,
                          key:       symmetricKey,
                          nonce:     randomNonce,
                          aad:       senderSigningPublicKey
                      )
```

This format is intentionally simple and stable. Schema version 1 is locked. Future schema versions will be additive (new optional fields) or backward-incompatible (new `schemaVersion: 2`), never silently breaking.
