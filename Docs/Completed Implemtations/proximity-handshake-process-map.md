# Fernlet Proximity Handshake Process Map

This map describes the phase 7 proximity primitive as implemented through the May 2026 proximity diagnostics and ranging updates.

## 1. Actors and roles

| Concept | Trainer implementation | Friend implementation |
|---|---|---|
| `ProximityCoordinator.Mode` | `.trainer` | `.friend` |
| Service type | `fernlet-coach` | `fernlet-friend` |
| Discovery role | Client usually advertises; trainer app browses and invites | Either user can advertise or browse; initiator browses and invites |
| Discovery metadata role | `trainer` or `client` | `peer` |
| Capability hint | `plan,live,delta` | `share` |
| Primary payloads after pairing | trainer plans, deltas, workout completion, live updates | recipes, workout summaries, friend shares |
| Consent copy | Trainer-specific disclosure and fingerprint confirmation | Symmetric peer confirmation and item-specific share summary |

Both modes use the same cryptographic envelope, replay cache, ranging gate, heartbeat, inspector log, and transfer path. Mode only changes discovery metadata, service type, and feature-level payload semantics.

## 2. Handshake flow

```text
User opens pairing UI
        |
        v
ProximityCoordinator.begin(role, mode)
        |
        +-- IdentityService.ensureProvisioned()
        +-- ConnectionInspector.beginSession(...)
        +-- Heartbeat loop starts at setup interval (5s)
        |
        v
Multipeer starts advertising or browsing
        |
        v
Discovery
        |
        +-- Browser sees peer -> .peerInRange(.unknown) -> invite(peer)
        +-- Advertiser receives invite -> .pendingInvite(invite)
        |
        v
MCSession connected / invite accepted
        |
        v
.awaitingTapConfirmation(peer)
        |
        +-- Pre-identity distance samples, when available, feed TapConfirmedDetector
        |       close distance < 5 cm for >= 1s and >= 3 samples
        |
        +-- RSSI/manual fallback: user taps manual confirmation
        |
        v
.awaitingIdentityIntroduction(peer)
        |
        +-- Local device sends signed identityIntroduction envelope
        |       payload = IdentityRangingPayload(rangingMode, optional NI discovery token)
        +-- Peer verifies identity, starts NIRangingSession if a UWB token is present,
        |       and replies with signed identityAcknowledge carrying its own token
        |
        v
Envelope verification and ranging startup
        |
        +-- Verify schema, expiry, signature, recipient fingerprint, replay ID
        +-- Confirm advertised fingerprint matches signing public key fingerprint
        |
        v
.awaitingUserConfirmation(peerIdentity)
        |
        +-- User accepts -> .connected(peerIdentity)
        +-- User rejects/cancels -> .ended(.userCancelled)
        |
        v
Connected session
        |
        +-- Foreground anchor starts (ActivityKit when available; no-op fallback otherwise)
        +-- Heartbeat interval becomes stable idle (30s)
        +-- Feature envelopes can flow
        +-- ConnectionInspector records events, envelope metadata, bytes, errors
```

## 3. Data collected by `ProximityCoordinator`

The coordinator does not collect feature payload contents. It collects only the state and metadata needed to authenticate, maintain, and diagnose the proximity session.

| Data | Source | Use |
|---|---|---|
| Local signing public key and fingerprint | `IdentityService` | Advertised discovery metadata, signed envelopes, local inspector log |
| Local key-agreement public key | `IdentityService` | Included in envelopes so peers can send sealed payloads |
| Peer display name | Multipeer peer / identity envelope | Confirmation UI and inspector log |
| Peer advertised fingerprint | Multipeer discovery info | Compared with the verified identity envelope fingerprint |
| Peer signing public key | Identity envelope | Signature verification and displayed fingerprint |
| Peer key-agreement public key | Identity envelope | Future sealed payload replies |
| NI discovery token | Signed identity introduction/acknowledgement payload | Starts `NIRangingSession` after identity verification when both devices support UWB |
| Ranging mode | `RangingProvider` capability/state | Logs whether proximity was UWB, RSSI fallback, or none |
| Distance samples | `RangingProvider.distance` | Tap-confirmation gate, inspector latest/min/max distance, and distance chart |
| Transport peer and state | `MultipeerTransport.state` | Drives state transitions and transport-loss detection |
| Inbound envelope metadata | `MultipeerTransport.inbound` | Verification, replay protection, inspector envelope metadata |
| Bytes sent/received | Encoded envelope sizes and inbound message size | Inspector transport counters and foreground anchor updates |
| Heartbeat timestamps | Sent/received `sessionHeartbeat` ping/ack envelopes | Half-open connection detection and average RTT measurement |
| Session lifecycle events | Coordinator transitions | Inspector event log and historical troubleshooting |

## 4. Heartbeat and foreground anchoring

```text
begin()
  -> heartbeat loop active; setup interval = 5s

connected
  -> foreground anchor starts
  -> stable idle interval = 30s

send(feature envelope)
  -> state = transferring
  -> heartbeat interval = 3s during transfer
  -> on completion, cooldown interval = 10s for 30s
  -> then back to stable idle interval = 30s

heartbeat tick
  -> send signed sessionHeartbeat ping envelope with unreliable mode
  -> receiver replies with signed sessionHeartbeat ack envelope
  -> sender records ack round-trip time in ConnectionSessionLog.transport.rttSamplesMs
  -> if connected and last inbound heartbeat is older than 3 current intervals
       end session as .transportLost
```

The ActivityKit anchor is best-effort. It starts only when the platform and user settings allow Live Activities. The heartbeat path remains the authoritative liveness check, and the ping/ack path is also the source of the inspector's average RTT. The Connection Inspector records sessions passively and opens only when the user taps the inspector button; pairing no longer auto-presents the inspector sheet.

## 5. Trainer process

```text
Client app: advertiser, mode .trainer
Trainer app: browser, mode .trainer

Client advertises:
  v=1, role=client, fp=<client fingerprint>, caps=plan,live,delta

Trainer browses fernlet-coach and invites client
Both devices tap-confirm and exchange identity/ranging-token envelopes
Client sees trainer disclosure before accepting
Connected session carries trainerPlan, trainerPlanDelta, workoutLiveUpdate, workoutCompletion
```

Trainer mode is asymmetric at the feature layer: the trainer sends plans and deltas, while the client can send workout completions and live updates. The proximity handshake itself stays mutual and symmetric.

## 6. Friend process

```text
User A: advertiser or browser, mode .friend
User B: opposite role, mode .friend

Advertiser publishes:
  v=1, role=peer, fp=<fingerprint>, caps=share

Browser invites over fernlet-friend
Both devices tap-confirm and exchange identity/ranging-token envelopes
Both users confirm peer fingerprint and item summary
Connected session carries friend-share payloads such as recipes or workout summaries
```

Friend mode is symmetric: either peer can initiate, either peer can send supported share payloads, and consent should focus on the specific item being shared rather than trainer permissions.

## 7. Failure exits

| Failure | Detection | End state |
|---|---|---|
| User cancels | `cancel()` | `.ended(.userCancelled)` |
| Peer disconnects | Multipeer `.disconnected` | `.ended(.transportLost)` |
| Pairing stalls | 30s pre-connected timeout | `.ended(.timeout)` |
| Signature, recipient, replay, or fingerprint fails | Envelope verification | `.failed(reason:)` |
| Heartbeats missed | Last inbound heartbeat older than 3 intervals | `.ended(.transportLost)` |
| Send fails mid-transfer | Transport send error | `.ended(.transportLost)` |

Every exit closes the foreground anchor, stops heartbeat work, stops ranging, and ends the active inspector session when one exists. RSSI fallback is logged as a mode, but the current MultipeerConnectivity transport does not expose RSSI values, so the inspector shows fallback status rather than a fabricated meter estimate.
