# Proximity And Mesh Function Index

This index maps the proximity and mesh subsystem functions to their responsibilities. Use it before adding proximity, mesh, recipe-share, friend-photo, identity, audit, or trust logic so existing behavior is reused instead of duplicated.

**Last refreshed: 2026-08-09.** This pass added the away-hearts dead-drop subsystem, the `ProtectedSidecar` durability primitive, wire2 sealed-payload framing, the QR verification ceremony, and the coach trust/ceremony types (which have no production callers yet).


## Duplication Hotspots

| Need | Prefer Reusing |
| --- | --- |
| Signed peer-to-peer payloads | `FernletIdentityEnvelope.signed(...)`, `FernletIdentityEnvelope.verify(...)`, `canonicalBytes(for:)` |
| Pairwise sealed payloads | `IdentityService.seal(_:to:)`, `IdentityService.open(_:from:)`, `ProximityCoordinator.sendPayload(...)`, `MeshNetworkManager.sendEnvelope(...)`. 2026-08 consolidation: MeshNetworkManager's two duplicated seal+sign+send builders were consolidated into the private `sendEnvelopeCore(_:encodable:sealTo:fingerprint:via:auditSendFailure:)`; keep calling `sendEnvelope(_:encodable:via:sealed:)` / `sendVerifyEnvelope(_:encodable:toKeyAgreementKey:fingerprint:supportsWire2:via:)`, which are now thin wrappers over it. |
| Mesh group-key wrapping | `IdentityService.encryptGroupKey(_:for:)`, `IdentityService.decryptGroupKey(_:)`, `MeshNetworkManager.initiateRotation()` |
| Durable sidecar state (data of record) | `ProtectedSidecar` — classifies absent / deferred / corrupt / loaded and keeps memory authoritative on write failure. Do NOT use `JSONSidecarFile` for data of record: it collapses every read failure to `nil`. |
| Sealing a payload to a peer, with framing | `IdentityService.seal(_:to:)` + `SealedPayloadFormat` (capability-derived, never inferred from bytes) |
| Verifying a human holds a key | `ProximityVerifyQR` + `ProximityVerifySignature.message(...)` — shared transcript, so the friend and coach ceremonies cannot diverge |
| Coach-channel trust | `CoachSessionTrustPolicy` / `CoachSessionContract` — never `FriendSessionTrustPolicy`, whose `isTrustedProximityPeer` returns `true` unconditionally and reads the friend vault |
| Proximity commit gates | `ProximityCommitDetector.ingest(distanceMeters:at:)`, `ProximityCoordinator.commitManualProximity()` |
| Friend mesh lifecycle | `MeshNetworkManager.startJoin()`, `stopJoin()`, `leaveSession()`, `leaveSessionAfterNotifyingPeers()`. 2026-08 consolidation: the three duplicated pending-connection expiry idioms were consolidated into `MeshMultipeerSession.registerPendingConnection(_:)`, and the hand-rolled `withObservationTracking` re-arm loops in the mesh/recipe/presence managers were consolidated into `ObservationLoop.start(on:tracking:onChange:)` (ProximityKit/Engine/ObservationLoop.swift). Local advertised names come from `ProximityHost.resolvedProximityDisplayName` (ProximityKit/PeerDisplayNames.swift), which replaced the three identical private `displayName` vars. |
| Mesh membership/admission | `MeshNetworkManager.allowAdmission(_:)`, `declineAdmission(_:)`, `handleAdmissionRequest(_:)`, `handleAdmissionGrant(_:)`. 2026-08 consolidation: the twin mesh-admission and activity-join confirmation sheets were consolidated into the shared generic `JoinPromptSheet` (Fernlet/JoinPromptSheet.swift, app target), and receive-side peer-name moderation now goes through `ItemNameModeration.moderatedPeerDisplayName(_:)`. |
| Mesh removal | `proposeRemoval(of:)`, `canSecondRemoval(_:)`, `secondRemoval(_:)`, `applyApprovedRemoval(_:)` |
| Friend photos | `MeshNetworkManager.addPhoto(_:)`, `cachePhoto(_:)`, `deletePhoto(_:)`, `syncPhotoManifest(to:)`, `PrivateMediaStore`. 2026-08 consolidation: the three duplicated photo-save catch-ladders and alert blocks were consolidated into `FriendPhotoLibrarySaver.userFacingFailure(for:photoCount:)` + the `photoSaveFailureAlert(_:failure:)` view extension (ProximityKit); the media stores' hand-rolled AES-GCM seal/open now routes through the shared extension on `PrivateMediaKeyProviding` (MediaAtRestCrypto.swift); JSON sidecar state — including the photo-wall preferences store — was consolidated into `JSONSidecarFile` (ProximityKit/Support/JSONSidecarFile.swift). |
| Recipe sharing | `ProximityRecipeShareManager.start()`, `sendRecipeShare(_:to:)`, `proximityCoordinator(_:didReceive:plaintext:from:)` |
| Audit/diagnostics | `ConnectionInspector`, `ConnectionSessionLog`, `TrainerAuditEvent`, `ProximityRecipeShareDiagnostics` |

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
| `currentDiscoveryInfo()` | Builds advertised mesh/fingerprint/name metadata. |
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
| `decryptPhoto(_:nonce:key:)` | AES-GCM decrypts a friend photo payload. |
| `encryptPayload(_:key:)` | Shared AES-GCM wrapper for closed-mode metadata encryption. |
| `decryptPayload(_:nonce:key:)` | Shared AES-GCM wrapper for closed-mode metadata decryption. |
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
| `peer(for:discoveryInfo:)` | Maps `MCPeerID` to stable `MultipeerPeer`, updating discovery info when it changes. |
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

## Transport And Ranging

### `MultipeerPeer.swift`

| Function | What It Does |
| --- | --- |
| `MultipeerPeer.==` | Treats peers as equal when their generated UUIDs match. |
| `hash(into:)` | Hashes the generated peer UUID. |
| `FileMCPeerIDStore.init(fileURL:)` | Chooses an explicit or default Application Support archive URL. |
| `load()` | Reads and unarchives a persisted `MCPeerID`. |
| `save(_:)` | Archives and atomically writes an `MCPeerID`. |

### `MultipeerTransport.swift`

| Function | What It Does |
| --- | --- |
| `MultipeerTransportState.==` | Equates states and associated peer/invite/error values. |
| `MultipeerPendingInvite.==` | Equates pending invites by peer, advertised info, and context, ignoring callback closure identity. |
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
| `open(_:from:)` | Opens payloads created by `seal(_:to:)`. |
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
| `HeartDropSidecarSeal.make(keychainService:)` | The keychain-backed ChaChaPoly seal for the sidecars at rest — plaintext versions were a timestamped log of who the user sent affection to. Read-back verified; one-way plaintext→sealed migration; protection class stays `.completeFileProtection`. Every caller states its service (via `HeartDropStorageScope`); there is deliberately no argument-less production variant. |

### `HeartDropStorageScope.swift`

| Function | What It Does |
| --- | --- |
| `HeartDropStorageScope(directory:keychainService:)` | One device's heart-drop storage identity. Both halves together because `HeartDropService.wipeForDeleteAll()` destroys both — files on a private root sealed by a shared key survive another store's wipe as ciphertext nothing can open. |
| `HeartDropStorageScope.production` | `Application Support/Fernlet` + `com.fernlet.heartdrop`, the paths and service the stores have always used. Only tests redirect it, and never by unsealing — a scoped store still seals through the real key path. |
| `HeartDropOutbox.fileURL(in:)` / `HeartDropDedupStore.fileURL(in:)` / `HeartDropPeerBundleCache.fileURL(in:)` / `ProximityHeartLedger.fileURL(in:)` | One definition per sidecar of its file name inside a root, so the production default and a scoped root can never disagree. |

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
| `exportLogs()` | Writes historical logs JSON to a temporary file and presents share payload. |
| `ActivityShareView.makeUIViewController(context:)` | Creates a UIKit share sheet for exported logs. |
| `ActivityShareView.updateUIViewController(_:context:)` | No-op representable update. |

## Shared Support

### `PeerDisplayNames.swift`

| Function | What It Does |
| --- | --- |
| `ProximityHost.resolvedProximityDisplayName` | The local display name a proximity radio advertises: the host's `proximityDisplayName` trimmed, falling back to the device name. One home for the previously identical private `displayName` vars in `MeshNetworkManager`, `ProximityRecipeShareManager`, and `PresenceManager`. |
| `ItemNameModeration.moderatedPeerDisplayName(_:)` | Wire-boundary coercion for a peer-supplied name before it is shown or persisted: `sanitizedName(_:)`, falling back to "A friend" when nothing displayable remains. Replaces the sanitize-or-"A friend" idiom repeated in the heart-receive paths, the vouch-list cache, the session chat store, and the keep-as-friend rows. |

### `Support/JSONSidecarFile.swift`

| Function | What It Does |
| --- | --- |
| `JSONSidecarFile.defaultFileURL(name:)` | Builds the production sidecar path (`Application Support/Fernlet/<name>`). |
| `JSONSidecarFile.load()` | Reads and decodes the sidecar, returning `nil` on any failure (absent, unreadable, or undecodable) — deliberately the naive idiom, so callers substitute their own defaults. Data of record must use `ProtectedSidecar` instead, which classifies read failures. |
| `JSONSidecarFile.save(_:)` | Encodes, creates the parent directory, and writes atomically with `.completeFileProtection`; failures are silently dropped. Unlike `ProtectedSidecar`, it does not exclude the file from backup. |
| `JSONSidecarFile.removeFile()` | Best-effort delete for the clear-all/reset path. |

Shared by `FriendStateCache`, `ClosenessLedger`, `ModerationLedger`, `ProximityActivityManager`, and the mesh photo-wall preferences.

## Expansion Plan For The Rest Of The App

The rest of the function index should not be one long alphabetical dump. Group it by ownership and duplicate-risk boundaries, so each section answers: "Where should I look before implementing this behavior again?"

| Next Group | Files To Include | Why This Group Belongs Together | Duplicate-Effort Questions |
| --- | --- | --- | --- |
| App shell and shared UI | `FernletApp.swift`, `ContentView.swift`, `FernletUIComponents.swift`, `FernletTheme.swift`, `SettingsSheet.swift`, `SharedSheets.swift` | These files define app entry, tab/sheet routing, theme, reusable controls, and cross-feature sheet patterns. | Are we adding a new view component when a shared Fernlet component already exists? Are sheet/navigation states duplicated in feature views instead of routed through the shell? |
| Store, repositories, persistence | `Models.swift`, `FernletStore.swift`, `FernletStoreLoader.swift`, `LocalFernletRepository.swift`, `CoreDataFernletRepository.swift`, `Persistence.swift`, `PrivatePersistenceController.swift`, `SnapshotSaveCoordinator.swift`, `StoragePreferences.swift` | This is the core data contract and save/load orchestration. It should be indexed before most feature files because many feature functions delegate here. | Is persistence logic repeated in a view? Is mutation going through `FernletStore` or bypassing it? Are repository snapshot conversions duplicated? |
| Extracted store services | `AIRetryQueueService.swift`, `DerivedSignalsService.swift`, `DerivedSignalsRebuilder.swift`, `SavedRecipeService.swift`, `BundledFoodSeedingService.swift`, `LaunchPreparationService.swift`, `PendingNarrativeBuffer.swift` | These are sub-services extracted from the store and are common places to accidentally reimplement scheduling, queueing, rebuild, seed, or save behavior. | Is there already a service handling this lifecycle? Are delayed tasks, retry queues, or rebuild windows being duplicated? |
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

