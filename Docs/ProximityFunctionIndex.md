# Proximity And Mesh Function Index

This index maps the proximity and mesh subsystem functions to their responsibilities. Use it before adding proximity, mesh, recipe-share, friend-photo, identity, audit, or trust logic so existing behavior is reused instead of duplicated.

**Last refreshed: 2026-08-20.** This pass corrected the `JSONSidecarFile` entry (it documented an
API that was deliberately deleted — see below), added the twenty-one ProximityKit files that had no
section at all (presence, hearts ledger, activities, clothing shop, session messages, moderation,
the `Wire/` payload types, and `CanonicalSignatureSerializer`), and recorded the
localization token/display rule now that ProximityKit carries wire strings that *look* like UI copy.
The 2026-08-09 pass added the away-hearts dead-drop subsystem, the `ProtectedSidecar` durability
primitive, wire2 sealed-payload framing, the QR verification ceremony, and the coach trust/ceremony
types (which still have no production callers).

> **Dangling reference, do not go looking:** twenty source files and test suites in this subsystem
> cite `Docs/Proximity-Mesh-Redesign-2026-07-10.md` for the phase numbering ("Phase 2 friend
> minting", "Phase 5", …). **That document does not exist in this tree.** The phase numbers are still
> meaningful as labels and are used consistently, and
> [Proximity-Security-Followups-2026-08-18.md](Proximity-Security-Followups-2026-08-18.md) stands in
> for the two items it still owed. This index is the surviving map of what those phases built.


## Duplication Hotspots

| Need | Prefer Reusing |
| --- | --- |
| Signed peer-to-peer payloads | `FernletIdentityEnvelope.signed(...)`, `FernletIdentityEnvelope.verify(...)`, `canonicalBytes(for:)` |
| Canonical bytes for anything signed | `CanonicalSignatureSerializer` (ProximityKit/Wire) — `canonicalBytes(for:)` is overloaded for the identity envelope, the mesh admission token, the three Group-Activity types, and a moderation row, each behind its own domain tag. Never hand-roll a signing input and never reach for `JSONEncoder(.sortedKeys)`: that is the pre-WI-6 encoder, kept only as `legacyCanonicalBytes(for:)` to *verify* envelopes minted by peers that predate the change, and never to sign. |
| Wire strings that look like display strings | KEEP THEM ENGLISH. `PayloadSummary.title`/`subtitle`/`extraDetails` are written into the canonical signing bytes by `CanonicalSignatureSerializer.appendCanonical(_:_:)` **and** rendered in the RECEIVER's Connection Inspector — see the localization row below and the doc comment on `FernletIdentityEnvelope.payloadSummary`. |
| A device-local sidecar file's location | `JSONSidecarFile.fileURL(in:name:)` against the owner's `ProximityHost.proximitySupportDirectory` (or, for the sealed heart-drop files, its `HeartDropStorageScope`). There is deliberately **no** argument-less default — see the `Support/JSONSidecarFile.swift` section for why re-adding one would be a regression. |
| Pairwise sealed payloads | `IdentityService.seal(_:to:)`, `IdentityService.open(_:from:)`, `ProximityCoordinator.sendPayload(...)`, `MeshNetworkManager.sendEnvelope(...)`. 2026-08 consolidation: MeshNetworkManager's two duplicated seal+sign+send builders were consolidated into the private `sendEnvelopeCore(_:encodable:sealTo:fingerprint:via:auditSendFailure:)`; keep calling `sendEnvelope(_:encodable:via:sealed:)` / `sendVerifyEnvelope(_:encodable:toKeyAgreementKey:fingerprint:supportsWire2:via:)`, which are now thin wrappers over it. |
| Mesh group-key wrapping | `IdentityService.encryptGroupKey(_:for:)`, `IdentityService.decryptGroupKey(_:)`, `MeshNetworkManager.initiateRotation()` |
| Durable sidecar state (data of record) | `ProtectedSidecar` — classifies absent / deferred / corrupt / loaded and keeps memory authoritative on write failure. Do NOT use `JSONSidecarFile` for data of record: it collapses every read failure to `nil`. |
| Sealing a payload to a peer, with framing | `IdentityService.seal(_:to:)` + `SealedPayloadFormat` (capability-derived, never inferred from bytes) |
| Verifying a human holds a key | `ProximityVerifyQR` + `ProximityVerifySignature.message(...)` — shared transcript, so the friend and coach ceremonies cannot diverge |
| Coach-channel trust | `CoachSessionTrustPolicy` / `CoachSessionContract` — never `FriendSessionTrustPolicy`, whose `isTrustedProximityPeer` returns `true` unconditionally and reads the friend vault |
| Proximity commit gates | `ProximityCommitDetector.ingest(distanceMeters:at:)`, `ProximityCoordinator.commitManualProximity()` |
| Friend mesh lifecycle | `MeshNetworkManager.startJoin()`, `stopJoin()`, `leaveSession()`, `leaveSessionAfterNotifyingPeers()`. 2026-08 consolidation: the three duplicated pending-connection expiry idioms were consolidated into `MeshMultipeerSession.registerPendingConnection(_:)`, and the hand-rolled `withObservationTracking` re-arm loops in the mesh/recipe/presence managers were consolidated into `ObservationLoop.start(on:tracking:onChange:)` (ProximityKit/Engine/ObservationLoop.swift). Local advertised names come from `ProximityHost.resolvedProximityDisplayName` (ProximityKit/PeerDisplayNames.swift), which replaced the three identical private `displayName` vars. |
| Mesh membership/admission | `MeshNetworkManager.allowAdmission(_:)`, `declineAdmission(_:)`, `handleAdmissionRequest(_:)`, `handleAdmissionGrant(_:)`. 2026-08 consolidation: the twin mesh-admission and activity-join confirmation sheets were consolidated into the shared generic `JoinPromptSheet` (App/Fernlet/JoinPromptSheet.swift, app target), and receive-side peer-name moderation now goes through `ItemNameModeration.moderatedPeerDisplayName(_:)`. |
| Mesh removal | `proposeRemoval(of:)`, `canSecondRemoval(_:)`, `secondRemoval(_:)`, `applyApprovedRemoval(_:)` |
| Friend photos | `MeshNetworkManager.addPhoto(_:)`, `cachePhoto(_:)`, `deletePhoto(_:)`, `syncPhotoManifest(to:)`, `PrivateMediaStore`. 2026-08 consolidation: the three duplicated photo-save catch-ladders and alert blocks were consolidated into `FriendPhotoLibrarySaver.userFacingFailure(for:photoCount:)` + the `photoSaveFailureAlert(_:failure:)` view extension (ProximityKit); the media stores' hand-rolled AES-GCM seal/open now routes through the shared extension on `PrivateMediaKeyProviding` (MediaAtRestCrypto.swift); JSON sidecar state — including the photo-wall preferences store — was consolidated into `JSONSidecarFile` (ProximityKit/Support/JSONSidecarFile.swift). |
| Recipe sharing | `ProximityRecipeShareManager.start()`, `sendRecipeShare(_:to:)`, `proximityCoordinator(_:didReceive:plaintext:from:)` |
| Audit/diagnostics | `ConnectionInspector`, `ConnectionSessionLog`, `TrainerAuditEvent`, `ProximityRecipeShareDiagnostics` |
| A string that is both a token and a label | FORK IT — never localize in place. See "Tokens vs. display in ProximityKit" below. |

### Tokens vs. display in ProximityKit

Localization Phase 1 (2026-08-19) split every string in the codebase into exactly one of two jobs,
and ProximityKit is where getting it wrong is most expensive: **a token here is inside a signature.**

* **TOKEN** — persisted `rawValue`s, mesh wire bytes, AI prompt vocabulary, dictionary keys, and
  anything compared with `==`. Tokens are English forever. Persist on the token, sign the token,
  prompt with the token, match against the token.
* **DISPLAY** — what a person reads. Only display localizes.

The types that were forked, repo-wide, are `CareGroup` (`token` / `label`), `MealType`,
`WorkoutType`, `CompanionState` (all three keep a FROZEN `rawValue` and gained a `displayName`),
`MealConfidence` (`token` / `label`, with a `legacyTokens` table for the pre-fork English spellings
already sitting in users' blobs), and the `CoachPlanTokens` vocabularies. In this subsystem the one
to know is `PayloadSummary.title` — it is sender-authored, reads exactly like UI copy ("Recipe
share", "Session ended", "Heartbeat"), and is **frozen English for two independent reasons**:
`CanonicalSignatureSerializer` writes it into the signing bytes, so localizing it makes the same
logical envelope sign differently per locale; and `ProximityCoordinator.recordEnvelope` feeds it to
the *receiving* user's Connection Inspector, so a localized sender would put its own language into
someone else's audit trail. A localized inspector is still possible later — render
`payloadTypeToken` through a receiver-side lookup table instead of showing the sender's string.

The membership records added for plan §8.1 are the same rule one layer down:
`MeshMembershipRecordKind`'s raw values (`fernlet.mesh.member-admission.v1` and its three siblings)
are wire bytes and sealed-context keys, so they are frozen English and have no display half at all —
nothing shows a record kind to a person.

The rule is enforced mechanically by `Tests/FernletTests/LocalizationBoundaryTests.swift` (the
localization wall — sibling of the S3, no-tracking and Power-of-10 walls), which pins the frozen raw
values case by case and grep-walls `String(localized:)` inside `FernletKit/Sources` for the
`bundle: .module` argument a package needs. Every failure it guards is silent: a localized token does
not crash, it just stops matching itself in a language nobody on the team reads.

## Engine

### `ProximityCommitDetector.swift`

| Function | What It Does |
| --- | --- |
| `init(proximityThreshold:dwellSeconds:minimumSamples:)` | Configures a rolling distance-window detector. Defaults to 15 cm, 0.8 seconds, and 3 samples. |
| `ingest(distanceMeters:at:)` | Adds a distance sample, trims samples older than the dwell window, and returns `true` when enough samples average below the threshold for the full dwell time. |
| `reset()` | Clears the rolling sample window. |

### `ObservationLoop.swift`

| Function | What It Does |
| --- | --- |
| `ObservationLoop.start(on:tracking:onChange:)` | The one `withObservationTracking` re-arm loop behind `MeshNetworkManager.startObserving()`, `ProximityRecipeShareManager.startObserving()`, and `PresenceManager.startHeartObserving()`: registers the caller's tracked reads, suspends until Observation reports a change, runs the caller's check on the main actor, and re-arms. Holds the owner weakly (so dealloc ends the loop) and finishes the stream continuation explicitly (so repeated sessions leave no suspended observer tasks). Returns the loop task for the caller's stop path. |

### `ProximityCoordinator.swift`

| Function | What It Does |
| --- | --- |
| `ProximityInspectorRecording` default methods | Provide no-op inspector hooks so coordinator callers can implement only the diagnostics they need. |
| `ProximityInspectorEventRecorder.recordCoordinatorEvent(_:)` | Stores coordinator event strings for lightweight tests or diagnostics. |
| `init(identity:transport:ranging:inspector:payloadHandler:trustPolicy:replayCache:foregroundAnchor:displayName:timeoutSeconds:now:)` | Wires identity, transport, ranging, diagnostics, trust policy, replay cache, foreground anchoring, timeouts, and tap/proximity detectors. |
| `deinit` | Cancels timeout and heartbeat tasks. |
| `attachPayloadHandler(_:)` | Attaches or replaces the payload receiver after construction. |
| `begin(role:mode:)` | Resets transport, prepares identity/session state, starts advertising or browsing, and transitions to discovery. |
| `beginFriendJoin()` | Friend-specific entry point that advertises and browses at the same time. |
| `prepareSession(role:mode:)` | Provisions identity, initializes coordinator state, resets counters/detectors, records audit, and arms the session timeout. |
| `acceptPendingInvite()` | Accepts an inbound invite, stores the transport peer, and either sends a friend identity intro or enters trainer tap confirmation. |
| `rejectPendingInvite()` | Rejects or cancels an invite and returns to idle. |
| `tapToConfirm()` | Completes trainer tap confirmation when the state is waiting for a tap. |
| `confirmPeerIdentity()` | Promotes a verified pending identity to connected, starts heartbeats and foreground anchoring, and records diagnostics. |
| `send(_:)` | Encodes and sends a prebuilt signed envelope over reliable transport while updating state, byte counts, foreground activity, and audit logs. |
| `sendPayload(type:summary:payload:sealed:)` | Builds, optionally seals, signs, and sends an envelope for app payload data. |
| `sealIfNeeded(_:sealed:)` | Pairwise-seals payload bytes to the connected peer's key-agreement public key when requested. |
| `cancel()` | Disables auto-reconnect and ends as user-cancelled. |
| `subscribeToTransport()` | Subscribes to transport state and inbound data publishers. |
| `subscribeToRanging()` | Subscribes to distance and ranging-state publishers. |
| `handleTransportState(_:)` | Main transport state reducer: discovery, invite, connection, disconnection, failure, and friend-mode auto-intro handling. |
| `shouldInviteDiscoveredPeer(_:)` | Chooses one side to invite in friend mode using fingerprints/display names to avoid simultaneous invites. |
| `handleRangingState(_:)` | Updates ranging mode and diagnostics, and falls back to manual commit when UWB invalidates. |
| `handleDistance(_:)` | Records distance samples and drives friend proximity commit or trainer tap confirmation. |
| `commitManualProximity()` | Manually commits a verified peer from proximity/manual waiting states. |
| `finishTapConfirmation(for:)` | Moves to identity introduction after trainer tap confirmation and sends the intro envelope. |
| `sendIdentityIntroduction(to:)` | Sends a signed identity introduction containing ranging capability and optional discovery token. |
| `handleInbound(_:)` | Decodes, trust-filters, verifies, decrypts, logs, and dispatches inbound envelopes. |
| `makeIdentityRangingPayload()` | Encodes local ranging mode and NI discovery token for handshake payloads. |
| `sendIdentityAcknowledgement(to:)` | Sends a signed acknowledgement with local ranging details. |
| `handleHeartbeat(_:plaintext:from:)` | Updates liveness, auto-confirms friend sessions after remote commit, replies to pings, and records RTT from acks. |
| `sendHeartbeatAcknowledgement(for:to:)` | Sends an unreliable signed heartbeat ack. |
| `recordEnvelope(_:direction:byteCount:signatureVerified:)` | Converts envelope traffic into `ConnectionSessionLog.EnvelopeRecord` diagnostics. |
| `updateInspectorPeer(identity:transportPeer:)` | Publishes peer display/fingerprint/key details to the inspector. |
| `updateInspectorTransport(state:disconnected:)` | Updates MCSession state and connected/disconnected timestamps in inspector transport info. |
| `updateInspectorRangingMode(_:)` | Publishes current ranging mode to the inspector. |
| `handleIdentityEnvelope(_:plaintext:from:)` | Validates advertised fingerprint, starts ranging, records peer identity, sends acknowledgement, and routes to friend proximity gate, trusted auto-confirm, or user confirmation. |
| `transitionToProximityGate(peerIdentity:)` | Replaces the short session timeout with a longer proximity timeout and chooses UWB or manual commit state. |
| `startRangingIfPossible(with:from:)` | Starts NearbyInteraction from a peer token, or records RSSI fallback when unsupported/unavailable. |
| `serviceType(for:)` | Maps trainer/friend modes to Multipeer service types. |
| `discoveryInfo(for:mode:)` | Builds advertised discovery metadata for role, fingerprint, name, and capabilities. |
| `transition(to:)` | Sets coordinator state and records state transition audit/inspector events. |
| `fail(_:)` | Cancels timers, marks failed state, records audit, ends inspector session, and stops foreground anchoring. |
| `end(_:)` | Stops ranging/transport/foreground activity, records audit, optionally auto-reconnects friend sessions after transport loss, or marks ended. |
| `startHeartbeatLoop()` | Starts a task that sends heartbeats at state-dependent intervals. |
| `heartbeatInterval` | Returns 0, 3, 10, or 30 seconds based on current transfer/connected state and recent activity. |
| `heartbeatTick()` | Sends heartbeat pings, tracks pending RTT IDs, and ends the session after liveness failures. |
| `armTimeoutIfNeeded()` | Starts the initial timeout task for non-terminal coordinator states. |
| `State.debugLabel` | Converts coordinator states into compact diagnostic labels. |

## Mesh

### `MeshNetworkManager.swift`

| Function | What It Does |
| --- | --- |
| `FriendPhotoWallPost.isCarousel` | Returns true when a post contains more than one photo. |
| `JSONSidecarFile<FriendPhotoWallPreferences>.load()` | Loads persisted wall aggregation/cover/favorite preferences, or `nil` (caller substitutes defaults). Was `FriendPhotoWallPreferencesStore.load()`, now the shared sidecar helper in `Support/JSONSidecarFile.swift`. |
| `JSONSidecarFile<FriendPhotoWallPreferences>.save(_:)` | Persists wall preferences with atomic protected file writes. Was `FriendPhotoWallPreferencesStore.save(_:)`. |
| `init(store:)` | Provisions identity, initializes photo cache/preferences, loads cached photos, and configures mesh session callbacks. |
| `isInSession` | Returns true when a mesh exists or any slot has a committed fingerprint. |
| `filmRemaining` | Returns the remaining session photo quota, capped at zero. |
| `localFingerprint` | Exposes the local identity fingerprint. |
| `sessionParticipants` | Builds a de-duplicated participant list from local identity, current mesh members, or committed pairwise slots while excluding removed members. |
| `leaveSession()` | Clears session photo metadata and leaves the mesh/pairwise session. |
| `leaveSessionAfterNotifyingPeers()` | Sends session-goodbye envelopes to slots before leaving. |
| `finishSessionPhotos(keeping:)` | Finalizes session metadata, deletes unkept session photos from cache state, clears session photos, and persists. |
| `deleteAllSessionPhotos()` | Finishes the session while keeping no photos. |
| `startNewMesh(name:)` | Creates a new open mesh descriptor with the local member and starts discovery. |
| `startJoin()` | Starts proximity-join mode, resets session counters/proposals/photos, opens the session, and starts discovery. |
| `stopJoin()` | Exits proximity-join mode and stops discovery. |
| `leaveMesh()` | Clears mesh/admission/removal/group-key state, resets quotas, and stops discovery. |
| `proposeRemoval(of:)` | Starts removal voting for a non-local participant, or leaves directly for the last pairwise peer. |
| `canSecondRemoval(_:)` | Checks whether local user can second a removal proposal. |
| `secondRemoval(_:)` | Sends a valid removal second and applies/rebroadcasts through the handler. |
| `clearGroupKeyState()` | Cancels rotation/beacon timers and clears current key, ack, epoch, and beacon state. |
| `renameMesh(_:)` | Updates mesh name metadata and broadcasts the descriptor. |
| `setMeshMode(_:)` | Changes open/closed mode, updates discovery info, and broadcasts descriptor. |
| `setSessionOpen(_:)` | Toggles session openness; for closed state, removes uncommitted slots. |
| `addPhoto(_:)` | Enforces 10-shot quota, resizes image data, encrypts when a group key exists, caches locally, and sends to active slots. |
| `allowAdmission(_:)` | Adds an approved requester to the mesh, signs an admission token, optionally wraps current group key, sends grant, and broadcasts descriptor. |
| `declineAdmission(_:)` | Removes a pending admission request. |
| `proximityCoordinator(_:didReceive:plaintext:from:)` | Mesh payload dispatcher for descriptors, admission, photos, manifests, vouchers, removals, encrypted metadata, beacons, key rotation, acks, and goodbye. |
| `vouchLabel(for:)` | Returns a friend-of-friend label from unexpired vouch cache. |
| `block(_:)` | Finds a participant's signing key and blocks it in the store/vault. |
| `sendVouchList(to:)` | Sends this device's non-blocked/non-revoked trusted fingerprints as a temporary vouch list. |
| `displayName` | Delegates to the shared `ProximityHost.resolvedProximityDisplayName` (`PeerDisplayNames.swift`): the proximity display-name setting, trimmed, falling back to the device name. |
| `activeSlots` | Filters slots to active slot kind. |
| `setupMeshSession()` | Installs discovery, channel-ready, disconnect/retry, and invite-acceptance callbacks. |
| `startSearching()` | Starts mesh advertising/browsing and observation. |
| `stopSearching()` | Cancels observation, stops MC session, cancels slot coordinators, clears slots and trust policies. |
| `currentDiscoveryInfo()` | Builds the advertised TXT: version + per-launch session id, plus mesh id/name/member count when the mesh is open. No display name, no fingerprint. |
| `updateDiscoveryInfo()` | Restarts advertiser with current discovery metadata. |
| `handlePeerDiscovered(_:)` | Auto-invites peers during proximity join or into an open mesh when capacity/overflow rules allow. |
| `handleChannelReady(_:)` | Creates a `ProximityCoordinator` and slot for a ready peer channel, then starts friend-mode handshake. |
| `removeSlot(_:)` | Cancels a slot coordinator, removes the slot/trust policy, and reranks. |
| `disconnectSlot(_:)` | Sends goodbye, cancels coordinator, removes slot/trust policy, and reranks. |
| `onSlotConnected(at:identity:)` | Handles first commit, pairwise-to-mesh promotion, descriptor/manifest/vouch sync, and beacon/rotation startup. |
| `promoteToMesh()` | Creates a mesh descriptor after the second proximity commit and broadcasts it to committed slots without restarting discovery. |
| `pendingManualCommits` | Lists slots waiting for manual proximity confirmation. |
| `commitManualProximity(slotID:)` | Triggers manual commit on a specific slot coordinator. |
| `canEvaluateOverflowCandidate(_:)` | Determines whether a temporary sixth slot may be admitted to compare stable distance. |
| `updateDistanceSamples()` | Samples per-slot last known distances, computes stable averages, resolves overflow, and reranks. |
| `resolveOverflowIfPossible()` | Keeps a closer overflow candidate only when it beats the farthest lightweight slot by hysteresis; otherwise disconnects it. |
| `rerankSlots()` | Promotes closest stable slots to active and others to lightweight. |
| `farthestLightweightSlotWithStableDistance(excluding:)` | Finds the farthest stable lightweight slot for overflow decisions. |
| `handleMeshDescriptor(_:from:)` | Merges or accepts a descriptor and sends admission request if local member is absent. |
| `mergeMeshDescriptor(_:incoming:)` | Merges descriptor name/mode by timestamp and appends non-removed new members. |
| `broadcastMeshDescriptor()` | Sends current descriptor to all slots and updates discovery info. |
| `sendMeshDescriptor(to:)` | Sends current descriptor to one slot. |
| `sendAdmissionRequest(for:)` | Broadcasts local join request to known slots. |
| `handleRemovalProposal(_:rebroadcast:)` | Stores an unexpired removal proposal and optionally rebroadcasts it. |
| `handleRemovalSecond(_:senderFingerprint:rebroadcast:)` | Validates seconding rules, deduplicates approval, optionally rebroadcasts, and applies removal. |
| `applyApprovedRemoval(_:)` | Removes/blocks a target locally: leaves if target is local, disconnects target slot, removes mesh member, broadcasts descriptor. |
| `broadcastEnvelope(_:encodable:)` | Sends one encodable payload type to every slot. |
| `handleAdmissionRequest(_:)` | Adds a valid unknown requester to pending admission requests. |
| `handleAdmissionGrant(_:)` | Verifies admission token, unwraps current group key when present, sets joined epoch, and starts beacons. |
| `cachePhoto(_:includeInSession:)` | Inserts a photo into capped cache state, persists full data separately, and optionally tracks it in the active session. |
| `imageData(for:)` | Reads full image data for a cached photo. |
| `thumbnailData(for:)` | Reads or generates thumbnail data for a cached photo. |
| `thumbnailData(forPhotoID:)` | Looks up a cached photo by ID and returns thumbnail data. |
| `hydratedPhotos(_:)` | Returns photos with full image data loaded from disk. |
| `favoritePhotoID(for:)` | Reads favorite photo selection for a session post. |
| `toggleFavorite(photoID:in:)` | Toggles a session favorite photo and persists wall preferences. |
| `photoWallPosts` | Aggregates sessions progressively and returns wall posts. |
| `savedPhotoSessions` | Returns unique saved session metadata sorted newest first. |
| `currentPhotoSessionMetadata()` | Builds or updates active session metadata from current mesh/session participants. |
| `finalizeCurrentPhotoSessionMetadata()` | Applies final participant/session metadata to session photos and cached photos. |
| `progressivelyAggregatePhotoSessions()` | Aggregates older multi-photo sessions once the wall reaches 24 posts. |
| `makePhotoWallPosts()` | Converts cached photos and aggregation preferences into wall post models. |
| `newestUnaggregatedSession()` | Finds the newest multi-photo session not yet aggregated. |
| `photos(in:)` | Returns photos for a session sorted oldest to newest. |
| `persistPhotoWallPreferences()` | Saves wall preferences through the store's `JSONSidecarFile<FriendPhotoWallPreferences>`. |
| `isPhotoFromCurrentSession(_:)` | Checks whether an inbound photo belongs to a current session payload. |
| `syncPhotoManifest(to:)` | Sends current session photo manifest, encrypted as metadata in closed meshes. |
| `handlePhotoManifest(_:from:)` | Requests missing, unblocked, decryptable photos from a peer. |
| `sendRequestedPhotos(_:to:)` | Hydrates and sends requested session photos sealed to a slot. |
| `sendEnvelope(_:encodable:via:sealed:)` | Post-commit send: resolves the slot's verified key-agreement key for a sealed send (returning false when it is missing) and forwards to `sendEnvelopeCore(...)` with send-failure auditing on. |
| `sendVerifyEnvelope(_:encodable:to:via:)` / `sendVerifyEnvelope(_:encodable:toKeyAgreementKey:fingerprint:supportsWire2:via:)` | Pre-commit ceremony send: seals to the identity carried by the gate state (the slot's verified key fields are not populated yet) through `sendEnvelopeCore(...)`, with send-failure auditing off. |
| `sendEnvelopeCore(_:encodable:sealTo:fingerprint:via:auditSendFailure:)` | The shared seal+sign+send core behind both senders above: encodes the payload, optionally seals it (wire2 or legacy; an empty key fails closed instead of downgrading to an unsealed send), signs the envelope, and sends it reliably on the slot channel; returns whether the wire write succeeded. |
| `encryptPhoto(_:key:)` | AES-GCM encrypts image data with the mesh group key and returns ciphertext+tag plus nonce. |
| `decryptPhoto(_:nonce:key:)` | AES-GCM decrypts a friend photo payload. Requires the `FMGP2` marker since crypto-standardization Phase 4 deleted the unprefixed read; an unmarked payload throws `MeshEncryptionError.legacyWireFormat`, which `decryptedIncomingPhoto` names in the trail as `mesh.friendPhoto.droppedLegacyWireFormat` rather than folding into the silent drop that also covers a wrong key. |
| `encryptPayload(_:key:)` | Shared AES-GCM wrapper for closed-mode metadata encryption. |
| `decryptPayload(_:nonce:key:)` | Shared AES-GCM wrapper for closed-mode metadata decryption. Same Phase 4 rule: no `FMGM2` marker ⇒ `MeshEncryptionError.legacyWireFormat`, audited as `mesh.encryptedMetadata.droppedLegacyWireFormat`. |
| `sendEncryptedMetadata(_:encodable:via:)` | Encrypts a control payload into `meshEncryptedMetadata` and sends it. |
| `handleEncryptedMetadata(_:from:slot:)` | Decrypts closed-mode metadata and redispatches supported inner payloads. |
| `isLocalCoordinator()` | Elects coordinator by lowest fingerprint among local and active connected peers. |
| `isElectedCoordinator(_:)` | Checks whether a fingerprint is the currently elected coordinator. |
| `startBeaconLoop()` | Runs a periodic task that broadcasts coordinator beacons or checks liveness. |
| `broadcastCoordinatorBeacon()` | Sends current coordinator, epoch, and next-rotation timestamp to slots. |
| `handleCoordinatorBeacon(_:)` | Validates elected coordinator, clamps next rotation, records beacon, yields or schedules shadow timer. |
| `checkBeaconLiveness()` | Triggers takeover when elected coordinator's beacon has gone silent. |
| `takeOverCoordinator()` | Schedules a recovered rotation time and broadcasts a takeover beacon. |
| `scheduleRotationTimer(fireAt:)` | Schedules the next key rotation if local device is coordinator at fire time. |
| `initiateRotation()` | Coordinator rotation protocol: sync, collect acks, generate new key, wrap per member, broadcast rotation, and apply locally. |
| `handleRotationSync(_:)` | Non-coordinator sync response that waits for drain then sends key ack. |
| `handleKeyRotation(_:)` | Non-coordinator key application from elected coordinator and ack back to coordinator. |
| `handleKeyAck(_:)` | Coordinator-side collection of sync-phase acks. |
| `startObserving()` | Observes slot coordinator states/distances through the shared `ObservationLoop.start(on:tracking:onChange:)` and calls state/distance maintenance after each observed change. |
| `checkCoordinatorStates()` | Commits newly connected slots with verified keys and removes stale uncommitted slots. |
| `injectUITestStateIfNeeded()` | Seeds deterministic mesh/admission state from UI test environment variables. |

### `NetworkMeshFeasibilityProbe.swift` (DEBUG-only)

| Function/Surface | What It Does |
| --- | --- |
| `NetworkMeshFeasibilityProbe.start()` | Explicitly starts the DEBUG Network.framework probe; Simulator uses infrastructure networking, while physical devices retain the peer-to-peer/continued-processing gate. It never starts a real mesh. |
| `NetworkMeshFeasibilityProbe.stop()` | Idempotently closes discovery, QUIC connections, and the test continued task. |
| `MeshProbeChannelIntroduction` | Signs a transcript bound to the active TLS exporter, mesh ID, epoch, identities, and nonces. |
| `NetworkMeshFeasibilityProbeView` | DEBUG Settings UI for observing bounded probe events and validation results. |

### `MeshMultipeerSession.swift`

| Function | What It Does |
| --- | --- |
| `PeerChannelTransport.init(peer:session:)` | Creates a per-peer adapter over the shared mesh MCSession. |
| `PeerChannelTransport.startAdvertising(...)`, `startBrowsing(...)`, `invite(_:)`, `accept(_:)` | No-op lifecycle methods because the shared session owns advertising, browsing, inviting, and accepting. |
| `PeerChannelTransport.send(_:to:mode:)` | Routes data through the shared `MeshMultipeerSession`. |
| `PeerChannelTransport.disconnect()` | Marks the channel idle locally without tearing down the shared MCSession. |
| `PeerChannelTransport.notifyConnected()` | Publishes connected state for the channel. |
| `PeerChannelTransport.notifyDisconnected(reason:)` | Publishes disconnected state for the channel. |
| `PeerChannelTransport.receive(_:)` | Emits an inbound message with byte count and timestamp. |
| `MeshMultipeerSession.init(peerIDStore:)` | Loads or creates a persistent local `MCPeerID`. |
| `start(serviceType:discoveryInfo:)` | Ensures MCSession exists, then starts advertiser and browser. |
| `updateDiscoveryInfo(_:)` | Restarts advertiser with new discovery info. |
| `stop()` | Stops advertiser/browser, disconnects session, and clears channels/caches/pending peers. |
| `invite(_:)` | Invites a peer if not already pending/connected (and not while discovery is paused), opening the connecting window through `registerPendingConnection(_:)`. |
| `send(_:to:mode:)` | Sends data through MCSession and maps failures to transport errors. |
| `prepareChannel(for:)` | Returns or creates the channel adapter for an MC peer. |
| `registerPendingConnection(_:)` | The one copy of the pending-connection expiry idiom: mints an invite token, records it in `pendingConnectionPeers`, and schedules the 31-second self-expiry that removes it unless a newer registration or a connect/disconnect transition already replaced it. Called by `invite(_:)`, the `.connecting` session transition (behind its own nil guard so the window is not refreshed), and the accepted-invitation path. |
| `ensureSession()` | Creates the shared required-encryption MCSession. |
| `startAdvertiser(info:)` | Starts `MCNearbyServiceAdvertiser`. |
| `startBrowser()` | Starts `MCNearbyServiceBrowser`. |
| `peer(for:discoveryInfo:)` | Maps `MCPeerID` to a `PeerHandle`, updating discovery info when it changes. **The `id` is NOT stable**: it is re-minted on every cache miss (a peer lost while holding no channel, or an inbound invitation from an untracked device). The `PeerEndpointKey` it carries *is* stable — that is what `isSameEndpoint(as:)` compares. |
| `session(_:peer:didChange:)` | Routes MC connection state to channel readiness/disconnect callbacks. |
| `session(_:didReceive:fromPeer:)` | Routes inbound bytes to the matching channel. |
| Resource/stream delegate methods | Present but intentionally no-op because this transport only sends data messages. |
| `advertiser(_:didReceiveInvitationFromPeer:withContext:invitationHandler:)` | Applies acceptance policy, prepares channel when accepted, and replies to invitation. |
| `advertiser(_:didNotStartAdvertisingPeer:)` | No-op advertiser failure hook. |
| `browser(_:foundPeer:withDiscoveryInfo:)` | Caches discovery info, maps peer, and notifies discovery callback. |
| `browser(_:lostPeer:)` | Removes cached peer and notifies loss callback. |
| `browser(_:didNotStartBrowsingForPeers:)` | No-op browser failure hook. |

### `MeshPayloads.swift`

| Function | What It Does |
| --- | --- |
| `MeshAdmissionGrantPayload.init(...)` | Creates an admission grant with optional encrypted current group key. |
| `canonicalBytes(for token:)` | Deterministically encodes an admission token with empty signature for signing/verification. |
| `MeshAdmissionToken.signed(...)` | Builds and signs an expiring admission token binding mesh ID, joiner fingerprint, and joiner signing key. |
| `MeshAdmissionToken.verify(joinerSigningPublicKey:now:)` | Validates expiry, joiner key, joiner/admitter fingerprints, and admitter signature. |

### `MeshNameGenerator.swift`

| Function | What It Does |
| --- | --- |
| `generate()` | Returns a random adjective-noun mesh name with safe fallbacks. |

### `MeshSessionTypes.swift`

| Function/Computed Property | What It Does |
| --- | --- |
| `PeerSlot.id` | Uses peer UUID as slot identity. |
| `MeshSessionParticipant.id` | Uses participant fingerprint as identity. |

### `MeshMembershipRecords.swift`

The four signed, immutable, grow-only membership records (plan §8.1/§8.3) and the caps §9 puts on
them. Pure value types: no store, no transport, no clock, and no signature verification — a record's
`signature` is opaque bytes it carries, and the layer that owns the crypto purpose must check it
BEFORE the record reaches a ledger a roster is derived from.

| Type / Function | What It Does |
| --- | --- |
| `MeshMembershipRecordKind` | The frozen wire tokens naming the four records (`fernlet.mesh.member-admission.v1`, `…member-departure.v1`, `…member-removal.v1`, `fernlet.mesh.terminated.v1`). English forever. |
| `MeshMembershipRecord` | What every record exposes so the merge and the roster are written once: mesh id, member fingerprint (the dedup key), `occurredAt`, author, opaque signature, plus the kind token and per-kind cap. |
| `MeshMembershipBounds` | Plan §9's caps in one place — roster 8, 16 records per kind, 1 termination, 8 custodians/voters — reusing `MeshIntroductionRoster`'s own constants rather than restating them. |
| `MeshMembershipRecordOrder.precedes(_:_:)` | The total order sets sort and truncate by: `occurredAt`, then member, then author, then signature bytes. Total by construction, so "keep the earliest N" is the same answer on every device. |
| `SignedAdmissionRecord` | Wraps the existing `MeshAdmissionToken` whole (no second signed-admission format). `signingPublicKey` is what lets a removal name a KEY, not just a fingerprint. The token's `expiresAt` is an admission-time freshness check, never a validity test on the durable record. |
| `SignedDepartureRecord` | Self-signed by the leaver, with a bounded `MeshCustodyHandoffSummary`. Grow-only, so departure is permanent: a re-admission record for the same fingerprint is subtracted straight back out. |
| `SignedRemovalRecord` | A COMPLETED removal only (expired proposals leave no trace), carrying `proposalID` + the quorum's `voterFingerprints` as evidence a partitioned member can re-check. |
| `SignedTerminationRecord` | A final-pair member's end-of-mesh record. `rosterAtSigning` is audit only — the downgrade is judged against the RECEIVER's merged roster. |
| `MeshCustodyHandoffSummary` | Who took custody at a departure, capped at the roster cap and clamped on decode as well as construction. |

### `MeshDerivedRoster.swift`

`roster = admitted − departed − removed`, derived on every read and stored nowhere (plan §8.1).

| Type / Function | What It Does |
| --- | --- |
| `MeshMembershipRecordSet<Record>` | One kind's bounded grow-only set: deduplicated by member (earliest wins), sorted by the total order, capped on init/insert/merge AND decode. |
| `…RecordSet.merging(_:)` / `.inserting(_:)` | Set union. Commutative, associative and idempotent INCLUDING the cap — keeping the earliest *k* of a set is the same answer whether you cap before or after merging, which is what makes convergence independent of who connected first. |
| `MeshMembershipLedger` | The four record sets, their union-merge, and `derivedRoster`. The union-mergeable half of plan §8.1's `MeshSessionContext` (the clock, the routing digest and the persistence story are the store's, not this). |
| `MeshDerivedRoster.init(ledger:)` | The derivation: admitted (earliest 8) − departed − removed, then the termination rule. |
| `…DerivedRoster.quorumThreshold` | ⌊&#124;roster&#124;/2⌋ + 1 (plan §10.4), never zero. |
| `…DerivedRoster.coordinatorFingerprint` | Lowest fingerprint present — the deterministic election plan §8.4 assumes each partition can run alone. |
| `…DerivedRoster.isFinalPair` | Judged on the DERIVED roster, never the connected pair (a 2/2 split of a 4-roster is not two final pairs). |
| `…DerivedRoster.introductionRoster()` | Hands the QUIC transport members AND barred as keys — what makes `MeshIntroductionRoster.barred` a real answer instead of the empty list the live manager falls back to. |
| `applyTermination(_:to:)` (private) | Read-time, not merge-time: a termination from a non-member is ignored; one whose signer sits on a roster larger than two downgrades to that signer's departure. Applying it at merge time would make the union order-dependent. |

## Transport And Ranging

### `PeerHandle.swift` / `MCPeerIDStore.swift`

| Function | What It Does |
| --- | --- |
| `PeerHandle.==` | Treats peers as equal when their per-discovery UUIDs match. |
| `PeerHandle.isSameEndpoint(as:)` | The "same device?" test: `id` OR endpoint key. Use this, never `==`, when matching a stored record (slot, heart connection, recipe pairing, device cap) against a transport event — `==` returns false for a device re-minted between the record being stored and the event arriving. |
| `endpointKey(for:)` | Mints or reuses the stable `PeerEndpointKey` for an `MCPeerID`, bounded FIFO at 64. |
| `mcPeerID(for:)` | Resolves a `PeerHandle` back to its framework peer — the single seam where the MC type is reached. |
| `hash(into:)` | Hashes the generated peer UUID. |
| `FileMCPeerIDStore.init(fileURL:)` | Chooses an explicit or default Application Support archive URL. |
| `load()` | Reads and unarchives a persisted `MCPeerID`. |
| `save(_:)` | Archives and atomically writes an `MCPeerID`. |

### `PeerTransport.swift`

| Function | What It Does |
| --- | --- |
| `PeerTransportState.==` | Equates states and associated peer/invite/error values. |
| `PeerPendingInvite.==` | Equates pending invites by peer, advertised info, and context, ignoring callback closure identity. |
| Protocol methods | Define async advertising, browsing, invite, accept, send, and disconnect capabilities implemented by transports. |

### `RangingProvider.swift`

| Function | What It Does |
| --- | --- |
| `RangingDistance.==` | Equates unknown distances or exact meter/direction tuples. |
| Protocol methods | Define async start/stop and local discovery token retrieval for ranging providers. |

### `NIRangingSession.swift`

| Function | What It Does |
| --- | --- |
| `init(isHardwareSupported:)` | Detects or overrides NearbyInteraction support and publishes RSSI fallback when unsupported. |
| `myDiscoveryToken()` | Returns archived local `NIDiscoveryToken`, waiting briefly for token availability. |
| `start(with:)` | Unarchives peer token, starts `NISession`, and publishes running state. |
| `stop()` | Invalidates session, clears it, and publishes idle state. |
| `getOrCreateSession()` | Reuses or creates an `NISession` and assigns delegate. |
| `session(_:didUpdate:)` | Publishes distance/direction samples or unknown distance. |
| `session(_:didInvalidateWith:)` | Clears invalidated session and publishes invalidated reason. |
| Suspension delegate methods | Present but currently no-op. |

### `ProximityForegroundAnchor.swift`

| Function | What It Does |
| --- | --- |
| `NoopProximityForegroundAnchor.start(peerName:startedAt:)` | Marks foreground anchoring active without ActivityKit. |
| `NoopProximityForegroundAnchor.update(bytesSent:bytesReceived:)` | No-op byte update. |
| `NoopProximityForegroundAnchor.stop()` | Marks foreground anchoring inactive. |
| `ActivityKitProximityForegroundAnchor.start(peerName:startedAt:)` | Requests a Live Activity for an active proximity connection. |
| `ActivityKitProximityForegroundAnchor.update(bytesSent:bytesReceived:)` | Updates Live Activity byte counters when they change. |
| `ActivityKitProximityForegroundAnchor.stop()` | Ends the Live Activity immediately and clears local state. |

## Identity, Wire, Trust, And Audit

### `IdentityService.swift`

| Function | What It Does |
| --- | --- |
| `init(keychainService:)` | Configures the Keychain service namespace. |
| `localFingerprint` | Returns fingerprint of current signing public key, or empty string before provisioning. |
| `localSigningPublicKey` | Returns raw Ed25519 public key, or empty data before provisioning. |
| `localKeyAgreementPublicKey` | Returns raw X25519 public key, or empty data before provisioning. |
| `sign(_:)` | Signs bytes with local Ed25519 private key. |
| `sealedBackupKey()` | Derives the sealed-backup symmetric key from the X25519 private key. |
| `verify(_:of:by:)` | Verifies an Ed25519 signature against raw public key bytes. |
| `seal(_:to:)` | Pairwise-seals payload using ephemeral X25519 ECDH, HKDF-SHA256, and ChaChaPoly. |
| `open(_:from:)` | Opens payloads created by `seal(_:to:)`. Requires the `FPT2` marker since crypto-standardization Phase 4 deleted the pre-marker read (which selected a bare static-key AAD): bytes without it throw `IdentityError.legacyWireFormat` — a peer on an old build, not a forger — rather than being opened under no typed purpose. |
| `encryptGroupKey(_:for:)` | Wraps a 32-byte mesh group key for one recipient with ephemeral X25519 and AES-GCM. |
| `decryptGroupKey(_:)` | Unwraps a group key bundle produced by `encryptGroupKey`. |
| `ensureProvisioned()` | Idempotently loads or creates signing/key-agreement keys and stores public-key caches. |
| `wipe()` | Deletes identity Keychain entries and clears loaded keys. |
| `fingerprint(of:)` | Returns a 16-character lowercase SHA-256 prefix for a public key. |
| `fingerprintsMatch(_:_:)` | Matches 16-character fingerprints and legacy 8-character prefixes. |

### `FernletIdentityEnvelope.swift`

| Function | What It Does |
| --- | --- |
| `canonicalBytes(for envelope:)` | Deterministically encodes an envelope with empty signature for signing/verification. |
| `verify(identityService:replayCache:)` | Validates schema, expiry, signature, recipient, required sealing, replay status, and decrypts payload if sealed. |
| `signed(...)` | Builds and signs a schema-version-1 identity envelope. |

### `PayloadType.swift`

| Function | What It Does |
| --- | --- |
| `PayloadSummary.init(...)` | Creates envelope summary metadata with optional subtitle, item count, date range, and details. |

### `FriendPhotoPayloads.swift`

| Function | What It Does |
| --- | --- |
| `FriendPhotoPayload.init(imageData:...)` | Creates an epoch-0 or already-decrypted photo payload. |
| `FriendPhotoPayload.init(encryptedImageData:nonce:keyEpoch:...)` | Creates an encrypted wire photo payload for epoch 1 or later. |
| `withDecryptedImageData(_:)` | Returns a local-cache copy with decrypted image data and encryption fields cleared. |
| `withSession(_:)` | Returns a copy with updated session metadata. |
| `withoutImageData()` | Returns a metadata-only copy for index persistence. |
| Private full initializer | Reconstructs a payload preserving optional data/encryption fields. |
| `FriendPhotoManifestEntry.init(id:senderFingerprint:keyEpoch:)` | Creates manifest entries; default epoch is 0. |

### `RecipeSharePayloads.swift`

| Function | What It Does |
| --- | --- |
| `ProximityRecipeSharePayload.hasShareNotes` | Checks local notes or saved summary for nonblank share notes. |
| `omittingShareNotes()` | Returns a copy with local notes or saved summary removed. |
| `ProximitySharedRecipe.title` | Returns local or saved recipe title fallback. |
| `ProximitySharedRecipe.servings` | Returns local or saved servings fallback. |
| `ProximitySharedRecipe.ingredientCount` | Returns local or saved ingredient count. |
| `PendingProximityRecipeShare.id` | Uses payload ID as pending-share identity. |

### `ReplayCache.swift`

| Function | What It Does |
| --- | --- |
| `init(dateProvider:)` | Injects a clock for deterministic replay-cache behavior. |
| `recordIfNew(envelopeID:)` | Purges old entries, rejects duplicate IDs, and records new IDs. |
| `purgeIfNeeded()` | Removes entries older than 24 hours and caps cache to 10,000 newest entries. |

### `ProximityTrustVault.swift`

| Function | What It Does |
| --- | --- |
| `init(initialPeers:initialAudit:onChange:)` | Loads normalized trusted peers and initial audit events. |
| `peer(signingPublicKey:)` | Finds trusted peer by signing key. |
| `peer(displayName:)` | Finds most recently seen trusted peer with a display name. |
| `isTrustedProximityPeer(signingPublicKey:)` | Returns true for a non-revoked trusted signing key. |
| `isRevokedProximitySigningKey(_:)` | Checks whether a signing key is revoked. |
| `isBlockedProximitySigningKey(_:)` | Checks whether a signing key is blocked. |
| `isBlockedFingerprint(_:)` | Checks blocked records by canonical or legacy fingerprint match. |
| `trust(_:mode:)` | Adds or updates a trusted peer record and clears revocation. |
| `block(signingPublicKey:)` | Blocks/revokes an existing key or creates a blocked placeholder record. |
| `unblock(signingPublicKey:)` | Clears blocked/revoked flags. |
| `revoke(signingPublicKey:)` | Marks a trusted peer revoked and records audit. |
| `recordTrainerAudit(_:)` | Adds audit event and triggers persistence callback. |
| `apply(peers:audit:)` | Replaces vault state from a stored snapshot. |
| `normalized(_:)` | Upgrades legacy 8-character fingerprints to 16-character fingerprints when key data exists. |
| `recordAuditWithoutSaving(_:)` | Inserts audit event and caps audit log at 500 entries. |

### `FriendSessionTrustPolicy.swift`

| Function | What It Does |
| --- | --- |
| `init(vault:)` | Wraps a `ProximityTrustVault` for friend sessions. |
| `isRevokedProximitySigningKey(_:)` | Delegates revoked-key check to vault. |
| `isBlockedProximitySigningKey(_:)` | Delegates blocked-key check to vault. |
| `isTrustedProximityPeer(signingPublicKey:)` | Always returns true because friend sessions authorize through proximity commit. |
| `recordTrainerAudit(_:)` | Delegates audit recording to vault. |

### `TrainerAuditLog.swift`

| Function | What It Does |
| --- | --- |
| `ProximityTrustedPeerRecord.init(...)` | Creates a persisted trust record with timestamps and optional revoked/blocked flags. |
| `TrainerAuditEvent.init(...)` | Creates an audit event for pairing, state, envelope, revocation, ending, and error diagnostics. |
| `ProximityTrustPolicy` methods | Define trust, revoke/block, and audit hooks consumed by `ProximityCoordinator`. |

### `ConnectionInspector.swift`

| Function | What It Does |
| --- | --- |
| `init(store:now:)` | Loads historical logs from store and injects a clock. |
| `attachStore(_:)` | Attaches store, reloads historical logs, and purges old entries. |
| `beginSession(role:mode:localFingerprint:)` | Starts a live log unless inspector mode is disabled. |
| `recordEvent(_:message:)` | Appends a timestamped event to the live log and trims log size. |
| `recordRangingSample(_:)` | Subsamples distance samples, updates min/max, and records a ranging event. |
| `recordEnvelope(_:)` | Appends envelope record, updates byte counters, and records sent/received event. |
| `recordError(domain:message:recoverable:)` | Appends an error record and event. |
| `updatePeer(_:)` | Updates live peer info. |
| `updateTransport(_:)` | Mutates live transport info through a closure. |
| `updateRangingMode(_:)` | Updates live ranging mode. |
| `endSession(endState:)` | Finalizes live log, inserts into historical logs, caps at 50, and persists. |
| `deleteLogs(at:)` | Deletes historical logs at offsets and persists. |
| `deleteLog(id:)` | Deletes one historical log by ID and persists. |
| `exportAsJSON()` | Encodes historical logs as pretty sorted JSON. |
| `jsonDecoder()` | Returns a JSON decoder for connection log import/preview use. |
| `purgeOld()` | Removes historical logs older than 60 days. |
| `recordCoordinatorEvent(_:)` | Maps coordinator message strings to event kinds and updates derived transport/tap data. |
| `persistHistoricalLogs()` | Writes historical logs back to store. |
| `trimLiveLog()` | Caps live events/envelopes/errors. |
| `kind(for:)` | Classifies coordinator message strings into inspector event kinds. |

### `ConnectionSessionLog.swift`

| Function | What It Does |
| --- | --- |
| `summary` | Computes duration, envelope count, byte count, error count, and end state. |
| `ConnectionSessionLog.init(...)` | Creates a full session log with optional peer/ranging/transport/events/envelopes/errors. |
| `RangingInfo.init(...)` | Creates ranging state and distance summary fields. |
| `DistanceSample.init(timestamp:meters:direction:)` | Stores distance and optional direction vector components. |
| `TransportInfo.averageRttMs` | Computes average recorded RTT. |
| `TransportInfo.init(...)` | Creates transport state, counters, flags, and RTT sample storage. |

### `SealedPayloadFraming.swift`

| Function | What It Does |
| --- | --- |
| `SealedPayloadFormat` | `.legacy` (plaintext sealed as-is) vs `.wire2` (compress + pad inside the AEAD). Chosen from the peer's advertised capabilities, never inferred from the bytes. |
| `SealedPayloadFraming.frame(_:)` | Tags, optionally compresses (above a 128-byte threshold), and pads the body to a 4 KiB bucket so ciphertext length leaks little about content. |
| `SealedPayloadFraming.unframe(_:)` | Reverses the framing, enforcing `maxInflatedByteCount` (16 MiB) so a compression bomb cannot expand unbounded. |
| `SealedPayloadFraming.bucketLength(for:)` | The padding bucket function. |

### `ProximityVerification.swift`

| Function | What It Does |
| --- | --- |
| `ProximityVerifyQR.makeURL(identity:now:)` | Mints this device's signed `fernlet://verify` URL (signing key, key-agreement key, timestamp, random nonce, signature) and returns it with the nonce to match a response against. |
| `ProximityVerifyQR.canonicalBytes(...)` | The domain-tagged (`fernlet.verify.qr.v1`) byte sequence the QR signature covers. |
| `ProximityVerifyQR.parse(...)` / `freshnessWindow` | Parses and validates a scanned URL, rejecting payloads older than the 5-minute window. |
| `ProximityVerifySignature.message(...)` | The challenge/response transcript both ceremonies sign, so the friend and coach paths can never diverge. |

### `CoachSessionTrustPolicy.swift`

**No production callers yet** — the coach session manager is unbuilt (see the coach spec and `Plan-Prekeys-ProtectedLoad-CoachMesh-2026-07-26.md` Increment 10).

| Function | What It Does |
| --- | --- |
| `CoachSessionContract.fernletRole` / `.coachAppRole` | The written-down role split (Fernlet browses, the coach app advertises) so it cannot be gotten backwards. |
| `CoachSessionTrustPolicy.isTrustedProximityPeer(signingPublicKey:)` | Unlike `FriendSessionTrustPolicy` (which returns `true` unconditionally), auto-confirms only an unrevoked, unblocked `.trainer` vault record whose `unknownModeToken` is `nil` — `.trainer` is the decode freeze default, so a record from a newer build must not silently inherit coach privilege. |
| `isRevokedProximitySigningKey(_:)` / `isBlockedProximitySigningKey(_:)` | Read the **coach** vault, not the friend vault. |
| `recordTrainerAudit(_:)` | Coach-channel audit hook. |

### `CoachVerificationCeremony.swift`

**No production callers yet.** Slot-independent by design: the friend QR ceremony is bound to `PeerSlot`s and a coach session has no slot.

| Function | What It Does |
| --- | --- |
| `makeDisplayURL(forPeerSigningKey:)` | Mints the display QR bound to the specific peer being verified, retaining the nonce for the round. |
| `clearDisplay()` | Drops the active display state. |
| `handleChallenge(...)` | Verifies the incoming challenge against the displayed nonce and signs the transcript — sign-after-check ordering is load-bearing. |
| `beginVerification(...)` | Starts a round against a scanned QR, minting the challenge nonce. |
| `handleResponse(...)` | Validates the peer's response; **a wrong-peer response must be dropped without clearing the pending round**, or an attacker could cancel a legitimate ceremony. |

### `Wire/CanonicalSignatureSerializer.swift`

The signing-input serializer for every signed type in the subsystem. Canonical v2 is a positional,
length-prefixed BINARY format — no key names, no locale-dependent number formatting, integers
big-endian, dates floored to whole seconds, `[String: String]` maps sorted by the RAW UTF-8 bytes of
the key. It exists because the original encoder was `JSONEncoder(.sortedKeys)`, whose byte output
Foundation does not guarantee across versions or a non-Apple stack; a one-byte divergence turns a
legitimately-signed envelope into `signatureInvalid`, which is an interoperability fault nobody can
reproduce. This is signing INPUT only — never the wire format, never persisted, never transmitted.
Every declaration in the file is `nonisolated`, so `verify` can run off the main actor over untrusted
bytes. **The field order in each function IS the schema.**

| Function | What It Does |
| --- | --- |
| `canonicalBytes(for: FernletIdentityEnvelope)` | Canonical v2 bytes for an envelope (schema v2+); the `signature` field is excluded, being the output of signing these bytes. Writes `payloadSummary`'s title/subtitle/extraDetails — the reason that summary is frozen English. |
| `canonicalBytes(for: MeshAdmissionToken)` | Canonical v2 bytes for an admission token; `admitterSignature` excluded. |
| `canonicalBytes(for: ActivityDescriptor)` / `(for: ActivityJoinToken)` / `(for: ActivityRosterSnapshot)` | The three Group-Activity signed types. All include the signed `schemaVersion`, so `verify` gates on one encoder rather than dual-verifying forever. |
| `canonicalBytes(for: ModerationLedgerEntry)` | Bytes for a moderation report row (Phase 3b). |
| `legacyCanonicalBytes(for:)` (envelope, token) | The exact pre-WI-6 `JSONEncoder` configuration, retained ONLY to VERIFY signatures minted by in-field peers on older builds. Never used to sign; do not change its configuration — its byte output is a compatibility contract with already-signed data. |
| `CanonicalByteWriter` | The append-only binary writer (`appendByte`/`appendInt64`/`appendUUID`/`appendString`/`appendLengthPrefixed`/`appendDate`, optional presence bytes, byte-ordered maps). |
| `canonicalUTF8Ordered(_:_:)` | Byte-lexicographic key ordering — unambiguous and identical on every stack, unlike `.sortedKeys`' UTF-16 ordering. |

Each signed type gets its **own domain tag** (`fernlet.canonical.<type>.v2`) as the leading
length-prefixed field, so a signature computed over one type can never validate over another. A new
signed type needs a new tag; reusing one is a cross-type forgery seam.

### `Wire/SealedIntroductionEnvelope.swift`

| Type | What It Does |
| --- | --- |
| `SealedIntroductionEnvelope` | A presence-heart identity intro/ack, sealed to the intended friend's key-agreement key. Carries only the ciphertext of a JSON-encoded `FernletIdentityEnvelope` — no cleartext identity — which is what makes a tag-replay forger learn nothing from the handshake. |

### `Wire/ActivityPayloads.swift`

| Type | What It Does |
| --- | --- |
| `ActivityParamsHash.of(_:)` | SHA-256 over the canonical descriptor bytes: the stable identity of an activity's parameters that the signed join token binds. Lives in ProximityKit, not the domain model, so the domain model stays crypto-free (same reasoning as `ModerationContentHash`). |
| `ActivityOfferPayload` | A host advertises a running activity to a committed friend, sealed. Carries the full descriptor (so the joiner can pin the host key + params hash) plus the current roster version — display only; the signed snapshot in the grant is the trust input. |
| `ActivityJoinRequestPayload` | A committed peer asks to join. Deliberately UNSEALED (mirroring `clothingCatalogRequest`): it carries only public keys and a display name, and the host re-validates the claimed fingerprint/signing key against the transport-verified slot and binds the grant to the VERIFIED key, so a spoofable body is harmless. |
| `ActivityJoinGrantPayload` | The host's signed grant: an invitee-key-bound `ActivityJoinToken` plus the roster snapshot at grant time, sealed. The joiner verifies both under the host key it pinned from the offer before considering itself a member. |
| `ActivityRosterSnapshotPayload` | A host-signed roster snapshot on its own, for convergence outside a grant. |
| `ActivitySyncPayload` | A sealed version digest between committed members (`[activityID: versionHeld]`); whichever peer holds the higher VERIFIED version replies with the snapshot, and the reply is rate-limited. Max-version-wins is the whole convergence rule. |
| `isWellFormed` (on each payload) | Format-string + version shape check at the wire boundary, before anything is trusted. |

### `Wire/ClothingSharePayloads.swift`

| Type | What It Does |
| --- | --- |
| `ClothingCatalogPayload` | A peer's current shop on the wire: the capped, deterministically ordered items on offer plus the anonymous designer id and display name, so a buyer can resolve "designed by <friend>" and learn the id→name mapping in person. Ephemeral by design — only items actually purchased persist. |
| `ProximityClothingCatalog` | The received-side holder, kept in memory from receipt through the 1-hour post-session shop window. Keyed by the transport-VERIFIED sender fingerprint so a re-broadcast replaces the prior catalog instead of stacking. The shop is the inverse of recipe-share: the BUYER holds the SELLER's broadcast catalog. |

### `Wire/MessagePayloads.swift`

| Type | What It Does |
| --- | --- |
| `TempMessagePayload` | One session-scoped chat message. Always delivered sealed (`.tempMessage` is in `sealingRequiredTypes`); `id` drives receive-side dedup, and `sentAt` is the sender's clock — display only, never trusted for ordering security. |

### `Wire/TrainerPayloads.swift`

| Type | What It Does |
| --- | --- |
| `TrainerExportPayload` | Wire envelope body for the curated trainer/nutritionist export bundle. The bundle bytes are opaque to ProximityKit — the app owns the allowlist-projected shape — so this type only carries, bounds (`maxBundleBytes` 2 MB, `maxTrainerWireBytes` 4 MB) and shape-checks them. It is the seam the future `fernlet-coach` trainer channel will use; until that ships, the app shares the reviewed bundle as a file. |

### `Trust/FriendMintingReview.swift`

Pure decision logic for the post-session "keep as friend" prompt (mesh redesign Phase 2), kept
view-free so the session-end flows in `ConnectView` / `DisposableCameraView` stay unit-testable.

| Function | What It Does |
| --- | --- |
| `FriendMintingReview.sessionEndReview(hasPhotos:eligibleCandidateCount:)` | Decides which session-end surface to show: the photo review sheet (with keep-as-friend rows embedded), the standalone keep-friends prompt, or nothing. |
| `FriendMintingReview.eligibleCandidates(roster:trustedPeers:)` | Filters the session roster down to peers that may be offered as new friends, computed against the trust vault at PRESENTATION time so a peer trusted or blocked mid-session never reaches the sheet. Blocked excludes (a ban is never re-offered), active excludes (already a friend), **revoked-only does not** — "Removed" is a reversible unfriend, and a fresh verified in-person session re-offers the peer. Entries missing either key are dropped defensively. |

## Photos And Recipe Sharing

### `FriendPhotoImageHelpers.swift`

| Function | What It Does |
| --- | --- |
| `UIImage.resizedForFriendSharing(maxDimension:)` | Downscales images whose largest side exceeds the limit. |
| `UIImage.friendPhotoThumbnailData(maxDimension:)` | Produces a compressed JPEG thumbnail. |

### `PrivateMediaStore.swift` (formerly `MeshPhotoCacheStore.swift`)

| Function | What It Does |
| --- | --- |
| `init(indexURL:keyProvider:)` | Configures index, image, thumbnail directories, ISO-8601 coders, and the at-rest key provider (defaults to the keychain-backed one). |
| `load()` | Loads metadata index, re-saves for cleanup, and returns metadata-only payloads. |
| `save(_:)` | Caps photos to `maxCachedPhotos` (1000, FIFO by recency), validates pixel bounds, **AES-256-GCM-encrypts** full images/thumbnails before writing, writes metadata index, and removes orphan files. |
| `imageData(for:)` | Returns inline image data or reads + decrypts it from disk. |
| `thumbnailData(for:)` | Reads + decrypts an existing thumbnail, or generates/encrypts/stores one from full image data. |
| `hydrated(_:)` | Returns an image-data payload by loading + decrypting image bytes from disk. |
| `openSealed(_:)` | Three-way read of on-disk bytes — `.opened`, `.legacyPlaintext` (a pre-encryption file, recognised by the pixel-bounds check and re-sealed in place on access), or `.unreadable` (no key, or bytes that are neither openable nor a valid image) — so a wrong key or corruption never hands ciphertext back as a photo. |
| `PrivateMediaKeyProviding.gcmSeal(_:)` / `gcmOpen(_:)` / `sealAndWrite(_:to:)` | The shared AES-256-GCM at-rest helpers this store now seals/opens through (`MediaAtRestCrypto.swift`), also used by `MealPhotoStore` and `ProgressPhotoStore`; they replaced the per-store `encrypt(_:)` / `reseal(_:to:)` copies. Each call site keeps its own fail-closed decision. |
| `isWithinSafePixelBounds(_:)` | Rejects decompression-bomb dimensions/area via ImageIO before any decode. |
| `removeOrphanedFiles(keeping:)` | Deletes image/thumbnail files not present in retained IDs (also the per-photo delete mechanism). |

### `PrivateMediaKeyStore.swift`

| Function | What It Does |
| --- | --- |
| `PrivateMediaKeyProviding.mediaKey()` | Supplies the symmetric key for `PrivateMediaStore`; injectable for tests. |
| `KeychainPrivateMediaKeyProvider.mediaKey()` | Loads or generates a 256-bit AES key stored backup-restorable (`kSecAttrAccessibleAfterFirstUnlock`); caches it in memory. |

### `FriendPhotoReviewSheet.swift`

| Function | What It Does |
| --- | --- |
| `FriendPhotoTile.body` | Renders thumbnail tile, selection checkmark, fallback placeholder, and lazy image loading. |
| `FriendPhotoReviewSheet.body` | Renders review grid and delete/save controls. |
| `toggle(_:)` | Toggles a photo ID in the selected set. |
| `FriendPhotoLibrarySaver.save(_:)` | Requests add-only Photos permission and saves selected payload images to the photo library. |
| `FriendPhotoLibrarySaver.userFacingFailure(for:photoCount:)` | Maps a `save(_:)` error onto the shared `PhotoSaveFailure` alert content: the permission denial (the only one offering Open Settings), the singular/plural corruption wording for `NothingSavedError`, or `PhotoSaveFailure.generic`. |
| `View.photoSaveFailureAlert(_:failure:)` | Presents that failure identically at every save surface (session-end review, disconnect review, album carousel): message body, conditional Open Settings button, OK; every button clears the binding. |

### `ProximityRecipeShareManager.swift`

| Function | What It Does |
| --- | --- |
| `ProximityRecipeShareDiagnosticEvent.init(...)` | Creates a timestamped diagnostic event. |
| `ProximityRecipeShareDiagnostics.appending(_:to:maxCount:)` | Appends and caps diagnostics to the newest events. |
| `init(store:)` | Provisions identity and configures recipe-share session callbacks. |
| `start()` | Starts recipe-share discovery/advertising and observation if not already running. |
| `stop()` | Stops discovery/session, cancels tasks, clears recipients/connections/status. |
| `refreshDiscovery()` | Restarts discovery while clearing peer and connection state. |
| `sendRecipeShare(_:to:)` | Starts discovery, queues outgoing payload, reuses verified connection or invites recipient. |
| `dismissRecipeShare(_:)` | Removes a pending inbound share. |
| `dismissRecipeShare(id:)` | Removes a pending inbound share by ID. |
| `proximityCoordinator(_:didReceive:plaintext:from:)` | Accepts valid `recipeShare` envelopes and inserts pending review items. |
| `setupSession()` | Installs recipe-share discovery/lost/channel/disconnect/acceptance callbacks. |
| `discoveryInfo()` | Builds recipe-share discovery metadata. |
| `displayName` | Delegates to the shared `ProximityHost.resolvedProximityDisplayName` (`PeerDisplayNames.swift`), like the mesh and presence managers. |
| `handlePeerDiscovered(_:)` | Filters self/blocked peers and updates sorted nearby recipients. |
| `handlePeerLost(_:)` | Removes lost peer and records diagnostics. |
| `handleChannelReady(_:)` | Creates a coordinator-backed recipe-share connection and starts friend handshake. |
| `startObserving()` | Observes connection coordinator states through the shared `ObservationLoop.start(on:tracking:onChange:)` and calls `checkCoordinatorStates()` after each observed change. |
| `checkCoordinatorStates()` | Captures verified fingerprints/KA keys, ensures recipients, sends pending payloads, and drops stale connections. |
| `ensureRecipient(for:identity:)` | Adds/updates a recipient from verified identity. |
| `sendPendingPayload(via:)` | Encodes, seals, sends queued recipe payload, updates send state, and records diagnostics. |
| `peer(for:)` | Finds a peer from active connection, discovered cache, or session channels. |
| `scheduleStatusClear()` | Resets send state to idle after a short delay. |
| `recordDiagnostic(_:)` | Appends capped diagnostic event. |

### `ProximityRecipeShareSheet.swift`

| Function | What It Does |
| --- | --- |
| `body` | Renders nearby recipient picker, notes toggle, diagnostics, fallback share link, and lifecycle hooks. |
| `searchingView` | Shows initial discovery progress UI. |
| `noNearbyView` | Shows empty discovery UI and search-again action. |
| `diagnosticDetailsCard` | Shows recent connection diagnostic events. |
| `scheduleNoNearbyState()` | Delays empty-state display while discovery has time to find peers. |
| `scheduleDismissAfterSendIfNeeded(_:)` | Auto-dismisses after successful send. |
| `outgoingPayload` | Returns payload with or without notes based on UI toggle. |
| `statusText` | Maps manager send state to UI status text. |

### `ProximityRecipeShareReviewSheet.swift`

| Function | What It Does |
| --- | --- |
| `body` | Renders inbound recipe details, warnings, ingredients, and import/decline actions. |
| `recipeKindLabel` | Labels local versus saved recipe payloads. |
| `recipeKindIcon` | Chooses SF Symbol for recipe kind. |
| `ingredientLines` | Builds display ingredient strings from local or saved payloads. |
| `notesText` | Extracts trimmed notes/summary text. |
| `macrosText` | Summarizes macros when present. |
| `duplicateWarning` | Detects duplicate local recipe or saved recipe by name/source URL. |
| `importShare()` | Imports payload through store, dismisses pending share, or shows import error. |

## Away Hearts (Offline Dead-Drop)

Shipped in the bitchat-adoptions round (Increment 3) and hardened in the prekeys/protected-load round
(Increments 1–7). All crypto lives here on the sealed side of the S3 wall; the injected
`HeartDropTransporting` conformer (`CloudKitSync/HeartDropCloudTransport`) only ever sees a rotating
day tag and ciphertext. Opt-in via `heartsAwayDelivery`, default OFF.

### `HeartSharing/ProximityHeartLedger.swift`

The device-local ledger every heart transport shares — presence, in-session mesh, and the dead-drop
below all rate-limit and de-dupe through this one type, which is why it sits at the top of this
section rather than inside any one of them.

| Function Or Property | What It Does |
| --- | --- |
| `ReceivedHeartRecord` | One received heart. `senderDisplayName` is sanitized at the wire boundary (see `PresenceManager`) before it reaches the ledger, so nothing peer-controlled lands here raw. |
| `canSendHeart(to:)` | The send-side half of the rate model: one heart per friend per 5 minutes, each direction. Owner decision — there is deliberately no daily cap. |
| `recordHeartSent(to:)` | Arms the send window. Consume-on-send: called only AFTER the wire write succeeds, so a failed send does not cost the user their window. |
| `recordReceivedHeart(id:senderDisplayName:senderFingerprint:)` | Records an in-person heart with id-dedup, retention trimming, and the 5-minute receive window. |
| `recordReceivedDropHeart(id:senderDisplayName:senderFingerprint:)` | The dead-drop variant: keeps id-dedup and retention but deliberately neither checks nor arms the 5-minute receive window, because a multi-day pickup batch must not collapse into a single heart. |
| `pendingBubbleHeart` / `dismissBubble(id:)` | The Home bubble's undismissed heart, and its dismissal. |
| `activeGlow(at:)` | The 24-hour health-bar glow decay. |
| `isLoaded` / `retryLoad()` | Sidecar state. Persistence rides a `ProtectedSidecar` (`HeartLedger.json`, `.completeFileProtection`, never synced) and **fails closed while unloaded** — sends are refused and receives are left unrecorded, with the drop record deliberately left on the server for a later pass, rather than a locked-device read being mistaken for "no hearts". |
| `clearAll()` | Wired from reset-everything. Retention is 48 h / 32 hearts. |

### `HeartDropService.swift`

| Function | What It Does |
| --- | --- |
| `queueHeart(to:)` | The entry point: picks a prekey (or the static key), seals, and enqueues — returning a `QueueOutcome` that includes `storageUnavailable` when the sidecar refuses to persist, so nothing is silently dropped. |
| `currentLocalBundle()` / `storePeerBundle(_:friendSigningKey:)` | Gossip the local prekey bundle and cache a peer's; a peer bundle is only ever stored from a verified, signed identity intro. |
| `syncNow(force:)` / `syncOnce()` | Trigger a sync pass; coalesced internally so overlapping calls collapse into one run. |
| `flush(_:)` | Uploads pending drops and **stops and surfaces** when a record name cannot be persisted — the fix for orphaned public-DB records. |
| `fetchIncoming(_:)` / `openIncoming(_:expectedSender:)` | Fetch a friend's tag window and open drops, re-gating wire size before key agreement. |
| `pendingCount(for:)` / `acknowledgeDeliveryProblem()` | Surfacing hooks for the two UI paths. |
| `cleanup(_:)` | Expiry sweep of this device's own uploaded records. |

### `HeartDropSealer.swift`

| Function | What It Does |
| --- | --- |
| `HeartDropSealer.seal(...)` | Builds the versioned wire form `[version][prekeyID (all-zeros = static key)][ciphertext]`. |
| `HeartDropSealer.open(...)` | Opens a drop, **gating payload size before key agreement** (the ordering the coach path still needs to adopt for `TrainerExportPayload`). |

### `HeartPrekeyStore.swift`

| Function | What It Does |
| --- | --- |
| `currentBundle()` | The local bundle of one-time X25519 prekeys plus the X3DH-style signed prekey, minted in batches of 16. |
| `privateKey(forPrekeyID:)` | Resolves a private half for opening; private halves live in one keychain blob (`AfterFirstUnlockThisDeviceOnly`, never synchronizable). |
| `pruneRetainedKeys()` | Ages out keys past the 29-day retention window. |
| `wipeForDeleteAll()` | Delete-all coverage — identity/prekey material must die with the wipe. |

### `HeartDropOutbox.swift`

| Function | What It Does |
| --- | --- |
| `enqueue(_:)` / `hasCapacity(forFriendSigningKey:)` / `hasDailyCapacity(...)` | Bounded, per-friend and per-day admission. |
| `pendingUploads()` / `markUploaded(id:recordName:)` / `recordAttempt(id:)` | The upload cycle; `markUploaded` reports persist failure to the caller rather than swallowing it. |
| `expiredEntries()` / `remove(ids:)` / `removeUnchanged(_:)` | Expiry and compare-and-remove, so a concurrent enqueue is not clobbered. |
| `snapshot()` / `uploadedRecordNames()` | Return **`nil` when the sidecar is unloaded** — never an empty array, which would read as "nothing queued". |
| `retryLoad()` / `acknowledgeDataLoss()` / `wipeForDeleteAll()` | Recovery and wipe hooks. |

### `HeartDropPeerBundleCache.swift`

| Function | What It Does |
| --- | --- |
| `store(bundle:forFriendSigningKey:)` | Caches a gossiped bundle keyed by the sender's full signing key. |
| `consumePrekey(forFriendSigningKey:)` | Consumes a one-time prekey, falling back to the signed prekey and then the static key. |
| `returnPrekey(id:forFriendSigningKey:)` | Returns a prekey when the send that reserved it fails, so a failed send does not burn forward secrecy. |
| `retryLoad()` / `wipeForDeleteAll()` | Recovery and wipe hooks. |

### `ProtectedSidecar.swift`

The durability primitive behind all of the above. Prefer this over `JSONSidecarFile` for any data of record.

| Function | What It Does |
| --- | --- |
| `read()` | Returns the loaded value, or `nil` when the state is absent/deferred/corrupt — the caller must distinguish, not assume empty. |
| `mutate(_:)` | Mutates and persists, returning a `MutateOutcome`; **on write failure memory stays the truth and re-persists** rather than re-reading, which would discard an unpersisted record name. |
| `mutateIfPersisted(_:)` | Fail-closed variant for callers that must not proceed on an unpersisted store. |
| `retryLoad()` / `acknowledgeDataLoss()` / `wipe()` | Recovery from a deferred (device-locked) or corrupt file, and the wipe path. |

### `HeartDropSidecarKey.swift`

| Function | What It Does |
| --- | --- |
| `HeartDropSidecarSeal.make(keychainService:)` | The keychain-backed ChaChaPoly seal for the sidecars at rest — plaintext versions were a timestamped log of who the user sent affection to. Read-back verified; one-way plaintext→sealed migration (that leg SURVIVES — it is the v0 plaintext generation, not the retired ciphertext one); protection class stays `.completeFileProtection`. Requires `FSC2` since crypto-standardization Phase 3: an `FSC1` row is refused as `SidecarSeal.SealError.legacyFormatRetired`, audit-logged before it is thrown so `ProtectedSidecar` quarantines rather than defers forever, and the Phase 2.2 migrator went with the reader it converted through. `legacyMagic` and its `isSealed` clause are KEPT and load-bearing — that predicate is what splits sealed from plaintext-v0, so a marker that stopped classifying would send ciphertext down the plaintext branch into the *corrupt* path. Every caller states its service (via `HeartDropStorageScope`); there is deliberately no argument-less production variant. |

### `HeartDropStorageScope.swift`

| Function | What It Does |
| --- | --- |
| `HeartDropStorageScope(directory:keychainService:)` | One device's heart-drop storage identity. Both halves together because `HeartDropService.wipeForDeleteAll()` destroys both — files on a private root sealed by a shared key survive another store's wipe as ciphertext nothing can open. |
| `HeartDropStorageScope.production` | `Application Support/Fernlet` + `com.fernlet.heartdrop`, the paths and service the stores have always used. Only tests redirect it, and never by unsealing — a scoped store still seals through the real key path. |
| `HeartDropOutbox.fileURL(in:)` / `HeartDropDedupStore.fileURL(in:)` / `HeartDropPeerBundleCache.fileURL(in:)` / `ProximityHeartLedger.fileURL(in:)` | One definition per sidecar of its file name inside a root, so the production default and a scoped root can never disagree. |
| `ModerationLedger.fileURL(in:)` / `FriendStateCache.fileURL(in:)` / `ClosenessLedger.fileURL(in:)` / `ProximityActivityManager.fileURL(in:)` | The same seam for the four `JSONSidecarFile` stores, all cleared by `FernletStore.resetAll` (and `FriendStateCache` also by turning fuzzy-state sharing off). Unsealed, so a root is the whole fix — no keychain half. |
| `JSONSidecarFile.fileURL(in:name:)` | The one definition of the sidecar layout. There is deliberately no argument-less `defaultFileURL(name:)`: every owner states its root, or the omission silently rejoins the process-wide race. |

## Presence And Nearby Friends

The standing `fernlet-near` radio and the two device-local ledgers that hang off it. Everything here
is opt-in and device-local; none of it is ever in the synced snapshot.

### `Presence/PresenceManager.swift`

The presence radio: KEPT friends recognize each other nearby without connecting, and hearts are
delivered over on-demand pairwise connections formed on that recognition.

Privacy posture is the design centre, and it is worth reading before touching anything here. The
advertisement carries ONLY rotating pairwise-DH tags (truncated HMACs of the 15-minute epoch under
per-friend-pair static-static X25519 secrets — `IdentityService.presenceTag`), the `MCPeerID` is
per-start random and never persisted, and all state (nearby set, connections, diagnostics) is
memory-only with no identities in any log line. Matching spans ±1 epoch; three self-exclusion layers
drop our own ghost advertisements; a 45 s lost-grace debounce smooths the epoch advertiser restart.

| Function Or Property | What It Does |
| --- | --- |
| `start()` / `stop()` | Lifecycle, owned by the app (opt-in setting + scene/tab/lock state) — not by this type. |
| `refreshRoster()` | Re-derives the advertised/matched tag set from the current trusted-friend roster. |
| `isReachable(fingerprint:)` | Whether a friend is currently tag-matched nearby. |
| `sendHeart(to:)` | The full in-person send: invite the tag-matched peer, run the 1-RTT friend handshake under the SEALED-INTRODUCTION rule (intro and ack sealed to the intended friend's vault key-agreement key, so a tag-replay forger learns nothing), auto-commit, verify the connected identity IS that friend and is heart-eligible, deliver one sealed `.friendHeart`, then tear down. The teardown is load-bearing: zombie connections must never accumulate toward the 8-peer `MCSession` cap. |
| `heartAffordance(...)` (`nonisolated static`) | The friend row's decision about which heart affordance to show. Takes the away-delivery setting as an explicit parameter rather than reading it off the host, so the affordance and the enforcement cannot drift apart. |
| `queueAwayHeart` / `heartDropBundleProvider` / `onPeerPrekeyBundle` | The dead-drop seams: race-window sends and prekey-bundle gossip are handed to `HeartDropService` (see Away Hearts) instead of being reimplemented here. |
| `proximityCoordinator(_:didReceive:plaintext:from:)` | Receive side. Accepts invitations only from tag-matched peers, and enforces the `allowNearbyHearts` opt-out, the trusted-friend gate, and the shared `ProximityHeartLedger` 5-minute receive window. |
| `wipeIdentityForDeleteAll()` | Delete-all participation. |

Every escaping `Task` captures `[weak self]` — the manager-Task lifetime rule; the owning store holds
this `unowned`.

### `Presence/FriendStateCache.swift`

| Function Or Type | What It Does |
| --- | --- |
| `CachedFriendState` | One friend's shared fuzzy wellbeing state + companion appearance, stamped with the meeting it was captured at, and shown with "as of last time you met" staleness treatment. |
| `record(fingerprint:fuzzyState:appearance:)` | Stores what a verified `.friendState` payload from a committed, vault-trusted friend carried. |
| `state(for:)` | The Friends UI read. |
| `remove(fingerprint:)` / `clearAll()` | Wired from block/revoke and from reset-everything, so a removed friend leaves nothing behind. |

Persistence is a `JSONSidecarFile` in the host's proximity support directory with
`.completeFileProtection`, deliberately **never** in the synced snapshot: a friend's struggling state
is theirs and must not follow this user into iCloud. Entries expire from the UI after 30 days, the
map is bounded at `maxStates` (newest kept), and decode is per-row tolerant so one unknown future
value can never wipe the cache.

### `Presence/ClosenessLedger.swift`

Per-friend in-person interaction counts — the input to the deterministic closeness score and the
close-slot assignment with hysteresis.

| Function Or Property | What It Does |
| --- | --- |
| `recordSession` / `recordPhotoSession` / `recordShareAccepted` / `recordHeartSent` / `recordHeartReceived` | Bump a day-granularity capped counter. No timestamps, no names, no durations — this is a warmth signal, never a who-met-whom surveillance log. |
| `closeness(fingerprint:)` / `closenessMap(for:)` | Derive closeness via `ClosenessMath` over age-bucketed daily counts. |
| `needsDailyEvaluation` / `evaluateSlots(eligibleFingerprints:firstAcceptedAt:)` | Runs at most once per day and persists `slotState`, so hysteresis dwell survives relaunch. |
| `isClose(fingerprint:)` | Slot membership. |
| `remove(fingerprint:)` / `clearAll()` | Wired from block/revoke and reset-everything. |

Same sidecar posture as `FriendStateCache`, never synced; retention is 31 days and at most 64 tracked
friends (least-close dropped). Day keys pin one timezone-stable formatter/calendar pair so bucketing
and diffing always agree.

## Group Activities

### `Activities/ProximityActivityManager.swift`

Hosting, joining, offers, pending join requests, and host-authoritative roster convergence — riding
the friend mesh with **no radio of its own**. Owned by `MeshNetworkManager` as a sub-manager (like
`MeshClothingShop`), which wires in the two seams this type uses instead of touching `MCSession`:
`send` (seal + sign + transmit to one verified fingerprint's committed slot) and
`committedActivityPeerFingerprints`.

Authorization is deliberately independent of the shared handshake: membership is carried by the
host-signed, invitee-key-bound `ActivityJoinToken`, snapshots verify only under the host key PINNED
at join, and roster convergence is max-version-wins.

| Function | What It Does |
| --- | --- |
| `host(...)` / `endHosting(activityID:)` | Start and stop hosting an activity. |
| `removeParticipant(activityID:fingerprint:)` | Host-side removal; bumps the roster version. |
| `receiveOffer(_:fromFingerprint:verifiedHostSigningPublicKey:)` | Ingests an offer and pins the host key it will verify every later snapshot under. |
| `receiveJoinRequest(...)` / `admitJoin(_:)` / `declineJoin(_:)` | Host side of joining. The grant is bound to the TRANSPORT-VERIFIED key, never the claimed one. |
| `requestJoin(_:)` / `receiveGrant(_:fromFingerprint:)` / `leaveJoined(activityID:)` / `dismissOffer(activityID:)` | Joiner side. |
| `receiveSnapshot(_:)` / `receiveSync(_:fromFingerprint:)` / `onPeerCommitted(fingerprint:)` | Convergence: version digests between committed members, higher verified version wins, and a rate-limited reply. Never serves a roster to a non-member. |
| `gcExpired()` / `clearAll()` | Lifetime sweep and reset-everything. |

Receive paths reject oversized or hand-crafted descriptors, and the 7-day lifetime ceiling is
re-enforced here **by rejection rather than clamping** — clamping would rewrite the signed params
hash. Hosted and joined activities persist in a device-local sidecar (`ActivityLedger.json`,
`.completeFileProtection`, never synced) until `expiresAt`; offers and pending joins are memory-only.

## Clothing Shop

### `ClothingSharing/MeshClothingShop.swift`

The friend-mesh clothing shop. It replaced the standalone `fernlet-clothes` radio
(`ProximityClothingShareManager`, deleted): catalogs now ride the friend mesh as `.clothingCatalog`
payloads exchanged pairwise-sealed during the live session, and the shop **opens at session end** as
a 1-hour, memory-only browse window on the Friends tab.

| Function Or Property | What It Does |
| --- | --- |
| `receiveCatalog(...)` | Inbound. The manager dispatches verified `.clothingCatalog` envelopes here from COMMITTED slots only — that committed-slot gate is the security boundary, because the coordinator dispatches known non-core payloads with `connectedIdentity ?? pendingPeerIdentity` and no state gate. Catalogs accumulate for the whole session. |
| `isSharingEnabled` | The payload-layer opt-out. `allowNearbyClothingShares` no longer stops a radio; the app wires `isSharingEnabledProvider` + `localCatalogProvider` (both gating app-side, so `ProximityHost` stays unchanged), the provider returns nil when off, inbound drops when off, and turning it off calls `clearAll()`. |
| `openWindowAtSessionEnd(now:)` | Opens the browse window at the same last-committed-slot-gone moment that promotes `pendingFriendReview`. |
| `beginNewSession()` | Closes the window early on the next session FORMATION — called from the manager's first-slot-commit hook, **never** from `startJoin`/`startNewMesh`, which fire automatically on every Social-tab entry and scene reactivation and must not touch the window. |
| `isWindowOpen(at:)` / `remainingWindowMinutes(at:)` / `cleanupIfExpired(now:)` | Expiry is lazy — pure reads plus a drop, no background timers. |
| `clearAll()` | Reset. |

Buying stays fully local (`FernletStore.buyClothingItem`); this type is pure receive/window state and
never touches coins or the closet. Everything here is memory-only: never persisted, never synced.
Note the asymmetry with `pendingFriendReview` — the review survives search starts *and* session
formations, the shop window survives searches but not formations.

## Session Messages

### `Messaging/SessionMessageStore.swift`

Messages are exchanged ONLY during a live friend session and VANISH at session end — an owner
decision, and a binding one: nothing retained on device, nothing synced, no dead-drop, no offline
queue. This type is the only in-memory holder, and it is deliberately **not `Codable`**, so it is
structurally impossible for a message to enter a `FernletSnapshot` (same technique as
`MeshSessionRosterEntry` / `MeshFriendReviewBatch`).

| Function Or Property | What It Does |
| --- | --- |
| `appendOutgoing(...)` | Local echo for `MeshNetworkManager.sendTempMessage(_:)`, which sanitizes and caps the text before room-broadcasting it sealed to every committed slot advertising the `messages` capability. |
| `receiveIncoming(...)` | Inbound from the manager's `.tempMessage` dispatch (committed-slot gate and blocked-fingerprint drop already applied, mirroring `.friendPhoto`): de-dupes by id, rate-limits per sender, sanitizes, caps. |
| `sanitize(_:)` (`static`) | The one text-coercion point for both directions. |
| `hasUnread` / `beginViewing()` / `endViewing()` / `markAllRead()` | Unread signalling for the Friends tab. |
| `clear()` | Called at EVERY session-end path (the `stopSearching` teardown funnel, `removeSlot`, `disconnectSlot`) and again on the next session formation. Unlike the shop's post-session window, messages do not outlive the session. |

## Moderation

Reported clothing designs. The honest-client half (a self-ban stops this device listing) is
convenience; the load-bearing enforcement is receiver-side.

### `Moderation/ModerationContentHash.swift`

| Function | What It Does |
| --- | --- |
| `ModerationContentHash.of(texture:slot:)` / `of(_ item:)` | SHA-256 over an item's sanitized ARTWORK — never its id, name, or price — so a designer cannot escape a report by relisting the same artwork under a new id. Pure stateless namespace enum, CryptoKit only. |

### `Moderation/ModerationLedger.swift`

Device-local, append-only store of report rows: this device's own reports and retracts, plus peers'
one-hop-verified rows. It is the evidence base `ModerationBanStore.reconcile(...)` reads.

| Function | What It Does |
| --- | --- |
| `recordLocalReport(...)` / `recordLocalRetract(...)` | This device's own rows. Rows carry a deterministic `ModerationLedgerEntry.rowID`, so a repeat report de-dupes and a retract supersedes its report via a higher `reporterSeq`. |
| `ingestForeign(_:)` | Upserts peer rows, keeping the higher-seq row — which makes re-delivery idempotent. |
| `isLocallyReported(contentHash:reporterFingerprint:)` | The shop's hide-reported-items check. |
| `clearAll()` | Reset-everything. |

Bounded MAX-MIN FAIRLY rather than by age (Power-of-10 R3): at most `maxRowsPerReporter` per reporter
fingerprint and `maxRows` overall, and on overflow the per-reporter allowance is lowered uniformly
until it fits — so a flooding reporter is drained down to everyone else's level before a quiet
reporter loses a single row. That is what stops a hostile peer evicting THIS device's own reports,
without the ledger ever needing to know its own signing key. The same rule is applied on the way in
from disk. Persistence is a `.completeFileProtection` JSON sidecar, never synced: who reported whom is
sensitive social data.

### `Moderation/ModerationReportRelay.swift`

| Function Or Type | What It Does |
| --- | --- |
| `SignedModerationReport` | One row plus the reporter's Ed25519 signature over its canonical bytes. |
| `ModerationReportPayload` | The sealed wire bundle of the sender's OWN signed rows (capped at `maxReports` = 32), carrying retractions alongside reports so an undo propagates to peers who already stored the original. |
| `buildPayload(ownReports:identity:)` | Called by `MeshNetworkManager` on slot commit. A reporter hands over only rows they personally signed. |
| `verifiedRows(from:senderSigningKey:now:)` | The `.itemReport` handler's gate: stores only rows the TRANSPORT-VERIFIED sender signed. |

**No transitive relay** is the Sybil defense — each device tallies only over reports it verified
itself. Stateless namespace enum; storage is owned by `ModerationLedger`.

### `Moderation/ModerationBanStore.swift`

The tamper-resistant 30-day store ban for repeatedly-reported designers: self-bans (this device's
shop) and local peer bans (their catalogs are dropped).

| Function Or Property | What It Does |
| --- | --- |
| `applySelfBan(durationDays:...)` / `applyPeerBan(fingerprint:durationDays:...)` | Arm a ban. |
| `isSelfBanned` / `selfBanRemainingSeconds()` / `isPeerBanned(fingerprint:)` | Countdown reads (which also refresh the credited-time record). |
| `selfBanTamperCount()` | How often a clock rollback was detected. |
| `reconcile(rows:localSigningKey:)` | Applies the bans the verified report set warrants, re-arming a served ban only on a NEW qualifying artwork. |

Two survival properties, both deliberate: it survives **app delete + reinstall** (records live in the
Keychain under the dedicated `com.fernlet.moderation` service, ThisDeviceOnly, and are never wiped by
identity resets — the self-ban is keyed to a constant device account, not the identity key), and it
survives **device clock changes** (a credited-time countdown over `mach_continuous_time` plus a
wall-clock high-water ratchet: a rollback voids wall credit and flags tampering, a forward jump
credits almost nothing, and the reboot-gap credit is capped). It is deliberately NOT cleared by
"Reset everything".

## UI Diagnostics

### `ConnectionInspectorView.swift`

| Function | What It Does |
| --- | --- |
| `ConnectionInspectorView.body` | Shows live log detail or no-active-session state. |
| `ConnectionInspectorLogDetailView.body` | Renders log detail sections. |
| `header` | Shows end state, duration, and local fingerprint. |
| `identitySection` | Shows local/peer identity and ranging mode. |
| `distanceSection` | Shows latest/min/max distance, fallback status, and sparkline. |
| `rangingStatusText` | Explains why no distance samples are visible. |
| `transportSection` | Shows MCSession state, bytes, and RTT. |
| `eventsSection` | Shows recent event timeline. |
| `envelopesSection` | Shows recent envelope records. |
| `errorsSection` | Shows recorded errors. |
| `durationText` | Formats session duration. |
| `inspectorRow(_:_:)` | Renders key/value row. |
| `centimeters(_:)` | Formats meters as centimeters. |
| `distanceColor(_:)` | Chooses distance color thresholds. |
| `color(for:)` | Maps event kinds to diagnostic colors. |
| `DistanceSparkline.body` | Draws distance history line. |
| `inspectorPanel()` | Applies shared inspector panel styling. |

### `ConnectionInspectorHistoryView.swift`

| Function | What It Does |
| --- | --- |
| `body` | Renders historical logs list, delete actions, export button, and share sheet. |
| `duration(_:)` | Formats active or completed session duration. |
| `exportLogs()` | Writes historical logs JSON through `FernletStore.writeProtectedExport` into `tmp/DataExports` (so the wipe sweeps it) and presents the share payload; the share-completion handler deletes the file. |
| `ActivityShareView.makeUIViewController(context:)` | Creates a UIKit share sheet for exported logs. |
| `ActivityShareView.updateUIViewController(_:context:)` | No-op representable update. |

## Session And Friend UI

### `UI/KeepFriendsPromptSheet.swift`

The per-participant "keep as a friend?" affordance at session end. One-sided and local-only: keeping
mints a trust-vault record on THIS device only, skipping does nothing, and the peer is never notified
either way.

| Type | What It Does |
| --- | --- |
| `KeepFriendsSection` (internal) | The keep-as-friend rows. Embedded in `FriendPhotoReviewSheet` when the session produced photos; hosted by the sheet below when it didn't. Its row toggles flip membership in a shared kept-fingerprints binding. |
| `KeepFriendsPromptSheet` | The compact standalone prompt for sessions that ended with no photos to review but with eligible candidates. Dismissing without choosing = skip all: the host clears the roster in `onDismiss` and mints only what was toggled. |

Which of the two appears is decided by `FriendMintingReview.sessionEndReview(...)`, and the candidate
list by `FriendMintingReview.eligibleCandidates(...)` — not by the views.

### `UI/FingerprintText.swift`

| Type | What It Does |
| --- | --- |
| `FingerprintText` | A peer's identity fingerprint, rendered identically everywhere one is shown. Fingerprints appear on four surfaces — the friend detail card, the join prompt (where two people read them off each other's screens), the activity roster, and the keep-as-friend rows — and each had hand-rolled its own `.system(.caption, design: .monospaced)`, a system font in an app whose type is entirely bundled. Centralized on the design system's `stat` role (DM Sans Medium, tabular figures) with extra tracking so a hex string still reads character by character. Truncation is MIDDLE, deliberately: the head and tail are what people compare, so a clipped tail would defeat the only thing the string is for. |

## Shared Support

### `ProximityHost.swift`

| Type Or Member | What It Does |
| --- | --- |
| `ProximityHost` | The narrow seam the subsystem uses to reach app-level state, so the mesh / recipe-share / presence managers depend on this protocol instead of the concrete `FernletStore`. Removing that App→Proximity type coupling is what let `Proximity/` become a standalone `ProximityKit` module. The app conforms `FernletStore` to it in `ProximityHostAdapter.swift`. |
| `proximityDisplayName`, `trustedProximityPeers`, `proximityTrustVault`, `isBlockedFingerprint(_:)`, `blockProximityPeer(signingPublicKey:)` | The identity/trust surface the managers consume. |
| `allowNearbyHearts` | The in-person hearts opt-in. `PresenceManager` consults it on BOTH sides (block an outbound heart, drop an inbound one) — the two non-UI homes of the setting. Presence VISIBILITY is a separate setting, so hearts-off + presence-on means a friend still sees you nearby but a heart to you is silently dropped. |
| `heartsAwayDeliveryEnabled` | The away-delivery opt-in, consulted here only for COPY, so a failed send doesn't tell a user who turned away delivery ON that "hearts travel in person for now". Enforcement lives in `HeartDropService.queueHeart`/`syncNow`. |
| `proximitySupportDirectory` | Root for the subsystem's on-disk sidecars (the friend photo-wall cache and its preferences, `HeartLedger.json`, the activity ledger, and the three sealed heart-drop sidecars named by `HeartDropStorageScope`). It comes through the HOST rather than being a constant because it is shared *mutable* on-disk state: deletes re-save the whole index and every manager loads that file at init, so with one process-wide path a manager built in one test reads and overwrites another's wall — a live cross-suite race under the test runner, where XCTest and Swift Testing suites share one process. Routing it through the host means every `MeshNetworkManager(store:)` site inherits its store's isolation for free. |
| `ProximitySupportLayout.defaultDirectory` | `Application Support/Fernlet` — the ONE definition of the production path, and the default the protocol extension hands hosts that do not redirect it. Unchanged from the path the photo cache and heart ledger have always used, so no shipped install is migrated by the seams that made these injectable. |

### `PeerDisplayNames.swift`

| Function | What It Does |
| --- | --- |
| `ProximityHost.resolvedProximityDisplayName` | The local display name a proximity radio advertises: the host's `proximityDisplayName` trimmed, falling back to the device name. One home for the previously identical private `displayName` vars in `MeshNetworkManager`, `ProximityRecipeShareManager`, and `PresenceManager`. |
| `ItemNameModeration.moderatedPeerDisplayName(_:)` | Wire-boundary coercion for a peer-supplied name before it is shown or persisted: `sanitizedName(_:)`, falling back to "A friend" when nothing displayable remains. Replaces the sanitize-or-"A friend" idiom repeated in the heart-receive paths, the vouch-list cache, the session chat store, and the keep-as-friend rows. |

### `Support/JSONSidecarFile.swift`

| Function | What It Does |
| --- | --- |
| `JSONSidecarFile.fileURL(in:name:)` | The ONE definition of the sidecar layout: `<directory>/<name>`. Owners resolve `directory` from their host's `ProximityHost.proximitySupportDirectory`; tests inject their own root. |
| `JSONSidecarFile.load()` | Reads and decodes the sidecar, returning `nil` on any failure (absent, unreadable, or undecodable) — deliberately the naive idiom, so callers substitute their own defaults. Data of record must use `ProtectedSidecar` instead, which classifies read failures. |
| `JSONSidecarFile.save(_:)` | Encodes, creates the parent directory, and writes atomically with `.completeFileProtection`; failures are silently dropped. Unlike `ProtectedSidecar`, it does not exclude the file from backup. |
| `JSONSidecarFile.removeFile()` | Best-effort delete for the clear-all/reset path. |

Shared by `FriendStateCache`, `ClosenessLedger`, `ModerationLedger`, `ProximityActivityManager`, and the mesh photo-wall preferences.

> **Correction (2026-08-20) — this section previously documented a `defaultFileURL(name:)` that was
> deliberately deleted (`02d2ba3`, "put the last four sidecars on the per-store root"), and printed
> the wrong runtime path.** If you read the old text and added a
> convenience default back, or wrote `Application Support/App/Fernlet/…` into anything, undo it.
>
> There is deliberately **no** argument-less default. A process-wide default root is exactly how a
> store rejoins the shared-root race this codebase spent a round eliminating: these sidecars are
> shared *mutable on-disk state* that wipes reach, the test runner puts many stores in one process,
> and a default that silently resolves to the process-wide root would let one store read and
> overwrite another's file — while compiling cleanly, because the omission is invisible. Every owner
> states its root, the same way every heart-drop caller states its `HeartDropStorageScope`. The
> in-source comment where `defaultFileURL(name:)` used to be says so; do not re-add it.
>
> The production root is `Application Support/Fernlet`, defined once in
> `ProximitySupportLayout.defaultDirectory` and reached through
> `ProximityHost.proximitySupportDirectory` (the protocol extension supplies it as the default for
> hosts that do not redirect it; the app's `FernletStore` overrides it with a per-instance root).
> The `App/Fernlet/` that appeared here was a repo-restructure artefact: `9fb86a9` collapsed the
> seven `Fernlet*` roots into `App/`, `Tests/` and `FernletKit/`, and the mechanical path rewrite
> caught this *runtime* path as if it were a *source* path. No shipped install has ever used it.

## Expansion Plan For The Rest Of The App

The rest of the function index should not be one long alphabetical dump. Group it by ownership and duplicate-risk boundaries, so each section answers: "Where should I look before implementing this behavior again?"

| Next Group | Files To Include | Why This Group Belongs Together | Duplicate-Effort Questions |
| --- | --- | --- | --- |
| App shell and shared UI | `FernletApp.swift`, `ContentView.swift`, `FernletUIComponents.swift`, `FernletTheme.swift`, `SettingsSheet.swift`, `SharedSheets.swift` | These files define app entry, tab/sheet routing, theme, reusable controls, and cross-feature sheet patterns. | Are we adding a new view component when a shared Fernlet component already exists? Are sheet/navigation states duplicated in feature views instead of routed through the shell? |
| Store, repositories, persistence *(done — see [StoreRepositoryFunctionIndex.md](StoreRepositoryFunctionIndex.md))* | the `FernletDomainModel` value types (the former `Models.swift`, split across `NutritionModels.swift` / `WorkoutModels.swift` / `WellbeingModels.swift` / `SettingsModel.swift` / `NavigationEnums.swift` / `CompanionModels.swift` in the SPM carve-up), `FernletStore.swift`, `FernletStoreLoader.swift`, `LocalFernletRepository.swift`, `CoreDataFernletRepository.swift`, `Persistence.swift`, `PrivatePersistenceController.swift`, `SnapshotSaveCoordinator.swift`, `StoragePreferences.swift` | This is the core data contract and save/load orchestration. It should be indexed before most feature files because many feature functions delegate here. | Is persistence logic repeated in a view? Is mutation going through `FernletStore` or bypassing it? Are repository snapshot conversions duplicated? |
| Extracted store services *(done — see [StoreRepositoryFunctionIndex.md](StoreRepositoryFunctionIndex.md))* | `AIRetryQueueService.swift`, `DerivedSignalsService.swift`, `DerivedSignalsRebuilder.swift`, `SavedRecipeService.swift`, `PendingWriteBuffer.swift`, `LaunchPreparationService.swift`, `PendingNarrativeBuffer.swift` (the old `BundledFoodSeedingService.swift` is gone — bundled foods are a read-only SQLite store opened lazily by `FoodCatalog`, with no seed step to schedule) | These are sub-services extracted from the store and are common places to accidentally reimplement scheduling, queueing, rebuild, seed, or save behavior. | Is there already a service handling this lifecycle? Are delayed tasks, retry queues, or rebuild windows being duplicated? |
| Lock, privacy, keychain, sealed backup | `FernletLockService.swift`, `FernletLockGate.swift`, `FernletLockView.swift`, `KeychainHelpers.swift`, `PrivacyDataSettingsView.swift`, `SealedBackupService.swift` if present in the project | Security-sensitive code should have its own section because duplicate crypto/keychain flows increase risk. | Are there two passcode/keychain/biometric paths? Is lock gating done through `FernletLockGate`? Are sealed backup and proximity identity sharing helper primitives correctly? |
| Onboarding and startup choice flow | `OnboardingCoordinator.swift`, `OnboardingView.swift`, `OnboardingWelcomeView.swift`, `OnboardingPermissionsView.swift`, `OnboardingStorageChoiceView.swift`, `OnboardingLockSetupView.swift` | Onboarding coordinates profile, storage, permissions, and lock setup. These files share one state machine and should be read together. | Is first-run logic duplicated in app shell/settings? Are permission/storage decisions centralized in the coordinator? |
| Food, nutrition, recipes | `FoodView.swift`, `FoodDataCatalog.swift`, `MealBuilder.swift`, `RecipeWebImporter.swift`, `FoodProductWebImporter.swift`, `RecipeShareCodec.swift`, `SavedRecipe.swift`, `CustomIngredientUpsert.swift`, `DishTemplateLexicon.swift`, `FoundationFoodSelection.swift`, `FoundationDishDecomposition.swift`, `NutritionLabelScanner.swift`, `NutritionLabelCameraSheet.swift` | This cluster owns food search, scan/import, recipes, meal construction, and nutrition parsing. It has high duplication risk because multiple entry points create ingredients/meals/recipes. | Is ingredient normalization already in `CustomIngredientUpsert` or `MealBuilder`? Are recipe import/share formats duplicated? Are scanner/importer parsing paths converging on the same models? |
| Health, movement, activity catalog | `MoveView.swift`, `ActivityPickerSection.swift`, `ActivityTypeCatalog.swift`, `HealthKitService.swift`, `WorkoutHealthKitSync.swift`, `WorkoutExercises.json` consumers | Movement and HealthKit functions overlap around workout types, authorization, imports, and workout logging. | Is HealthKit mapping duplicated outside `ActivityTypeCatalog`? Are workout imports and manual logging using the same normalization/upsert behavior? |
| Journal, cycle, period, intimacy | `JournalView.swift`, `JournalNarrativeRepository.swift`, `PeriodTrackerStore.swift`, `PeriodTrackerView.swift`, `PeriodDayDetailView.swift`, `CyclePredictionEngine.swift`, `LogPeriodSheet.swift`, `LogIntimacySheet.swift`, `IntimacyLogRepository.swift`, `MenstrualNarrativeRepository.swift` | These files share date-based personal history, cycle state, symptoms, predictions, and narrative persistence. | Are date-window calculations duplicated? Is cycle prediction used through `CyclePredictionEngine`? Are narrative repositories split by intent rather than reimplemented storage? |
| AI, memory, audit context | `MemoryAgent.swift`, `AIContextPayload.swift`, `AIAuditLog.swift`, `AIRetryQueueService.swift`, Foundation model helper files | AI context, retry, audit, and memory payloads should be indexed together because errors often come from repeated prompt/context assembly. | Is context assembly duplicated in views? Are retry and audit paths consistently using the existing queue/log types? |
| Social, friends, camera UI | `ConnectView.swift`, `SocialHubView.swift`, `FriendListView.swift`, `JoinPromptSheet.swift` (the shared generic join/admission sheet that replaced `MeshAdmissionPromptSheet.swift` and `ActivityJoinPromptSheet.swift`), `DisposableCameraView.swift` | This sits above the proximity layer already indexed. It owns user-facing session/photo/friend flows and should reference the proximity index instead of restating internals. | Is UI state duplicating `MeshNetworkManager` state? Are friend/block/session actions routed through proximity/trust managers? |
| Cloud and external data | `CloudKitDataService.swift`, importers, repository sync/load helpers | CloudKit, web import, and external product data all handle outside data normalization and error boundaries. | Are remote/local merge rules duplicated? Are web/product importers converging on shared recipe/food models? |
| Tests and mocks | `FernletTests`, `FernletUITests`, proximity mocks | Tests document expected behavior and often contain reusable fakes/harnesses. | Are new tests creating another mock when `Mocks/MockMultipeerTransport.swift` or similar exists? Are edge cases already covered by an adjacent test file? |

### Recommended Order

1. Store, repositories, and extracted store services. This gives the rest of the index a stable data/mutation vocabulary.
2. Food, nutrition, and recipes. This is the largest duplication-risk area after proximity because several features create or import the same domain objects.
3. Lock, privacy, keychain, and sealed backup. Security-sensitive flows should be made explicit before further changes.
4. Health, movement, activity catalog, period, journal, and cycle tracking. These groups share date math, HealthKit, and derived signals.
5. App shell, shared UI, onboarding, and social UI. These are easiest to index once the underlying service responsibilities are clear.
6. Tests and mocks. Add these last as a reference map for where behavior is already verified.

### Indexing Rules For Future Sections

| Rule | Reason |
| --- | --- |
| Start each group with a short duplicate-hotspots table. | A future reader usually needs to know what not to reimplement before reading every function row. |
| Put model computed properties in shorter tables than service methods. | Model summaries are useful, but they should not bury state-changing behavior. |
| Mark private helpers that own policy decisions. | Private does not mean unimportant; helpers often hold deduplication, filtering, date-window, or merge rules. |
| Separate UI rendering helpers from mutation/import/save functions. | This keeps behavioral reuse visible instead of hidden among view body fragments. |
| Link cross-group reuse explicitly. | Example: social UI should point back to proximity functions instead of repeating proximity internals. |
| Prefer one index file per broad subsystem if a section grows past a few hundred lines. | The proximity section is already large; food/recipes and store/persistence may deserve their own function-index docs linked from `FileIndex.md`. |
