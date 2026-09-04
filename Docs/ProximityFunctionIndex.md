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
| Canonical bytes for anything signed | `CanonicalSignatureSerializer` (ProximityKit/Wire) — `canonicalBytes(for:)` is overloaded for the identity envelope, the mesh admission token, the three Group-Activity types, a moderation row, the routed manifest (P5 item 1) and the routed chunk (P5 item 2), each behind its own domain tag. Never hand-roll a signing input and never reach for `JSONEncoder(.sortedKeys)`: that is the pre-WI-6 encoder, kept only as `legacyCanonicalBytes(for:)` to *verify* envelopes minted by peers that predate the change, and never to sign. |
| Wire strings that look like display strings | KEEP THEM ENGLISH. `PayloadSummary.title`/`subtitle`/`extraDetails` are written into the canonical signing bytes by `CanonicalSignatureSerializer.appendCanonical(_:_:)` **and** rendered in the RECEIVER's Connection Inspector — see the localization row below and the doc comment on `FernletIdentityEnvelope.payloadSummary`. |
| A device-local sidecar file's location | `JSONSidecarFile.fileURL(in:name:)` against the owner's `ProximityHost.proximitySupportDirectory` (or, for the sealed heart-drop files, its `HeartDropStorageScope`). There is deliberately **no** argument-less default — see the `Support/JSONSidecarFile.swift` section for why re-adding one would be a regression. |
| Pairwise sealed payloads | `IdentityService.seal(_:to:)`, `IdentityService.open(_:from:)`, `ProximityCoordinator.sendPayload(...)`, `MeshNetworkManager.sendEnvelope(...)`. 2026-08 consolidation: MeshNetworkManager's two duplicated seal+sign+send builders were consolidated into the private `sendEnvelopeCore(_:encodable:sealTo:fingerprint:via:auditSendFailure:)`; keep calling `sendEnvelope(_:encodable:via:sealed:)` / `sendVerifyEnvelope(_:encodable:toKeyAgreementKey:fingerprint:supportsWire2:via:)`, which are now thin wrappers over it. |
| Mesh group-key wrapping | `IdentityService.encryptGroupKey(_:for:)`, `IdentityService.decryptGroupKey(_:)`, `MeshNetworkManager.initiateRotation(cause:)` |
| Per-recipient routed content-key wrap | `MeshRoutedContentKeyWrapper.wrap/unwrap/additionalData` (P5 item 1) — the routed sibling of `encryptGroupKey`: the same X25519 → HKDF → AES-GCM chain under the routed purposes with a manifest-binding AAD. Never re-roll the chain (item 10, P6) and never reuse the group-key purposes for it. |
| Splitting or reassembling routed content | `MeshChunker.chunk(of:at:for:identity:)` / `.chunks(of:for:identity:)` and `MeshChunkAssembly` (P5 item 2) — the ONE chunking transport. Chunks are ordinary reliable frames that earn a QUIC transfer stream by size alone (`MeshTransferStreamTable.route(reliableByteCount:)`); do not build a second chunking path, a transfer id, a resume token or an application-visible ack. |
| Hashing routed content | `MeshRoutedContentDigest.contentHash(of:)` (the whole sealed blob) / `.chunkHash(of:)` (one slice) / `.chunkID(itemID:chunkIndex:)` (P5 item 2). Never a bare `SHA256.hash` for routed bytes: each digest carries its own registered `Hash` purpose, which is what stops a one-chunk item's chunk hash being replayable as its item hash. |
| Durable sidecar state (data of record) | `ProtectedSidecar` — classifies absent / deferred / corrupt / loaded and keeps memory authoritative on write failure. Do NOT use `JSONSidecarFile` for data of record: it collapses every read failure to `nil`. |
| Sealing a payload to a peer, with framing | `IdentityService.seal(_:to:)` + `SealedPayloadFormat` (capability-derived, never inferred from bytes) |
| Verifying a human holds a key | `ProximityVerifyQR` + `ProximityVerifySignature.message(...)` — shared transcript, so the friend and coach ceremonies cannot diverge |
| Coach-channel trust | `CoachSessionTrustPolicy` / `CoachSessionContract` — never `FriendSessionTrustPolicy`, whose `isTrustedProximityPeer` returns `true` unconditionally and reads the friend vault |
| Proximity commit gates | `ProximityCommitDetector.ingest(distanceMeters:at:)`, `ProximityCoordinator.commitManualProximity()` |
| Friend mesh lifecycle | `MeshNetworkManager.startJoin()`, `stopJoin()`, `leaveSession()`, `leaveSessionAfterNotifyingPeers()`. 2026-08 consolidation: the three duplicated pending-connection expiry idioms were consolidated into `MeshMultipeerSession.registerPendingConnection(_:)`, and the hand-rolled `withObservationTracking` re-arm loops in the mesh/recipe/presence managers were consolidated into `ObservationLoop.start(on:tracking:onChange:)` (ProximityKit/Engine/ObservationLoop.swift). Local advertised names come from `ProximityHost.resolvedProximityDisplayName` (ProximityKit/PeerDisplayNames.swift), which replaced the three identical private `displayName` vars. |
| Mesh membership/admission | `MeshNetworkManager.allowAdmission(_:)`, `declineAdmission(_:)`, `handleAdmissionRequest(_:)`, `handleAdmissionGrant(_:)`. 2026-08 consolidation: the twin mesh-admission and activity-join confirmation sheets were consolidated into the shared generic `JoinPromptSheet` (App/Fernlet/JoinPromptSheet.swift, app target), and receive-side peer-name moderation now goes through `ItemNameModeration.moderatedPeerDisplayName(_:)`. |
| Mesh removal | Legacy two-party: `proposeRemoval(of:)`, `canSecondRemoval(_:)`, `secondRemoval(_:)`, `applyApprovedRemoval(_:)`. Signed quorum (P4 item 5, §10.4): `proposeSignedRemoval(of:now:)`, `voteOnSignedRemoval(_:now:)`, `evaluateRemovalQuorum(_:now:)`, `MeshRemovalQuorum` |
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
| `leaveSessionAfterNotifyingPeers()` / `leaveSessionAfterNotifyingPeers(clock:)` | Ends the session and tears down transport. **No longer sends `.sessionGoodbye`** (P3 item 3): the legacy frame is parsed, never emitted. Since P4 item 6 (plan §10.6) the ending is `MeshDevelopmentPlan`'s: a merged roster larger than two departs with the custodians the branch view says are reachable, a genuine final pair signs the termination. The `clock:` form injects the instant the 15-second handoff window opens and the instant it closes, so the bound is asserted on a test clock rather than by timing a real send. |
| `developmentPlan(startedAt:)` / `recordDevelopmentHandoffOutcome(_:finishedAt:)` | Derive plan §10.6's decision from the merged derived roster plus the branch view, and record how the bounded handoff ended (`lastDevelopmentPlan`, `lastDevelopmentHandoffOutcome`). Memory-only: a decision, not a fact about membership — the durable half is the sealed ending mark. |
| `prepareMembershipLedger(meshID:founderSigningPublicKey:)` | Arms the verified ledger at mesh creation, rooted in the founder's key. Idempotent per mesh; a different mesh id replaces it, because records never cross meshes. |
| `dispatchMembershipEventPayload(_:plaintext:decoder:slot:)` | Decodes `.meshMemberAdmission` / `.meshMemberDeparture` / `.meshMemberRemoval` / `.meshTerminated` / `.meshInventoryDigest` / `.meshEpochHeads` on a COMMITTED slot, buffers for adoption when this device is still on its bootstrap ledger, else inserts through `MeshMembershipRecordVerifier`, commits durably, then hands the roster move to `applyRosterMove(_:from:)`. |
| `decodeMembershipFrame(_:plaintext:decoder:)` | Static, pure: one frame → the record it carries, with the type's own clamps applied. Split from insertion because a bootstrap joiner takes the same decode down the adoption path. |
| `insertMembershipRecord(_:type:)` | Offers a decoded record to the verifier. Returns the record **only** when it was ACCEPTED — a refused record must not be able to end anybody's session. |
| `applyRosterMove(_:from:)` | What a durable, roster-moving record means for this device: a removal naming it (§8.2 `removed`), a termination the merged roster agrees with (`terminationVerified`), or an ordinary roster change that rotates. |
| `bufferedForAdoption(_:from:)` / `attemptLedgerAdoption(ownAdmission:meshID:)` | The joiner's convergence half (P3 item 7). Records from the admitting peer accumulate in `pendingAdoptionLedger` until `MeshLedgerAdoption.adopt` proves the chain from the offered root to this device's admitter; the rebase is durable before it counts. |
| `armJoinerLedger(_:)` / `seedFounderAdmission(meshID:)` | The two doors a ledger is armed through — a verified grant on the joiner, a self-admission on the founder. Both leave this device on its own derived roster, which is what makes the vote site's local insert succeed on any member. |
| `sendEpochHeads(to:)` / `receiveEpochHeads(_:)` | Plan §10.3's **epoch** half of the union exchange (P4 item 3): sign and send this device's live branch head(s) as `fernlet.mesh.epoch-heads.v1`, and fold a verified peer's set. A member on no epoch sends nothing. Receiving folds through `foldEpochHeads(_:)` and then asks `requestMergeRotationForDivergentHeads()`; nothing is adopted from a head set — a head is a name, and the resolution is always the successor a coordinator mints. |
| `requestMergeRotationForDivergentHeads()` | **The mint** (P4 item 3): asks `requestRotation(cause: .merge)` when `MeshEpochAcceptance.isDivergent(_:)` sees two heads at one counter among the unresolved set. It asks rather than mints, so a merge that also moved the roster still rotates once (the second request coalesces into the first's 2 s window). Gated on this device still being a non-terminated member, after `applyMergedRosterVerdict(from:)` has run. |
| `rotationBasisHead` / `unresolvedEpochHeads` / `presentedEpochHeads()` | `max` for plan §10.3's `max + 1` (highest of the sealed heads and the keyring's), the heads at or above this device's own counter — which is what stops an already-reconciled merge re-asking forever — and the set a head frame carries. |
| `sendInventoryDigest(to:)` / `reGossipRecords(to:)` | Plan §10.5's two halves: ask what a peer holds, and answer a differing digest with a bounded re-gossip of the existing frames (≤ `maxReGossipFrames`, once per peer per session). The ask now takes a **recipient set** — P4 item 2 passes the committed peers on every reconnect, and an empty set is "nobody to ask", not "ask everybody". A digest that MATCHES concludes the merge. |
| `recordGrantedAdmission(_:)` / `emitAdmissionRecord(_:)` | The admitter's side: file the admission durably before the grant is answered, then broadcast `member-admission.v1` to the other members so the joiner reaches every derived roster — and therefore the next epoch's key distribution. |
| `applyVerifiedTermination()` | A verified termination the merged roster agrees with: §8.2's `terminationVerified` edge — ending mark, teardown, permanent rejoin bar. A termination the roster downgrades never reaches here; `MeshDerivedRoster` has already turned it into its signer's departure. |
| `applyVerifiedSelfRemoval()` | A verified removal naming this device: `.removed` writes the ending mark and the permanent rejoin bar, then `leaveSession()` — the same teardown the legacy `.meshRemovalSecond` path takes, so both paths end in one state. No rotation: a non-member has no key to hand out. |
| `epochRef` (`MeshIntroductionAuthority`) | The **held** keyring's head as a canonical string (P3 item 5 — item 4 re-derived it on every read, so a descriptor merge could rename this device's epoch with no rotation behind it). Empty when this device holds no key, which is a named branch of the acceptance rule, not a wildcard. |
| `epochCoordinatorFingerprint` | The lowest fingerprint of `presentedRotationRoster()` — the ledger's derived roster once it knows one, else the **gossiped descriptor** members plus self (never `activeSlots`). The coordinator source and the presented roster must move together or members stop agreeing on `epochID`. |
| `emitMembershipEvent(_:)` / `emitRemovalRecord(_:)` | **The emission seams.** The first mints and sends what it names (departure, termination); the second broadcasts an ALREADY-minted removal, because re-minting at send time could bind a different voter list from the one that was filed. |
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
| `allowAdmission(_:)` | Adds an approved requester to the mesh descriptor, then hands the wire work to `grantAdmission(to:meshID:)`. |
| `grantAdmission(to:meshID:)` / `wrappedKeyForGrant(to:)` | Signs the admission token, wraps the group key to the slot's handshake-verified KA key, **files the admission record durably**, then sends the grant and broadcasts the descriptor. The filing precedes the answer (plan §3.6). |
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
| `requestRotation(cause:)` | **The one entry point to rotation** (P3 item 5, plan §8.3): timer, roster change and merge all pass through `MeshRotationTriggerQueue`, which coalesces a burst and refuses re-entry. The coordinator check happens at fire time, not here. |
| `armRotationDebounce(firingAt:)` / `runDebouncedRotation()` / `rearmDeferredRotation()` | The single armed window (cancel-and-replace), the claim-then-rotate step, and the re-arm for a trigger that arrived mid-rotation. |
| `initiateRotation(cause:)` | Coordinator rotation, in the order that matters: plan the epoch, drain for acks, **persist the head**, then distribute. A `terminate` plan ends the session; a blocked save abandons the rotation. |
| `plannedRotation()` / `presentedRotationRoster()` / `fullRotationRoster()` | The successor plan through `MeshRotationPolicy` + `MeshEpochAcceptance` — counted up from `rotationBasisHead`, i.e. `max + 1` over the FOLDED heads rather than `own + 1` (P4 item 3) — and the roster it is presented against — the full one (derived roster, else descriptor members + self), **intersected with the branch** while partitioned (P4 item 1, plan §10.2). The branch scoping lives here, once, so the presented roster and `epochCoordinatorFingerprint` cannot drift apart. |
| `drainForRotation(closingEpoch:)` | Steps 1–2: announce the closing epoch, re-arm the 15-minute timer, collect drain acks. Returns nil when cancelled mid-drain, so nothing is distributed. |
| `distributeRotation(_:cause:acked:closingEpoch:)` | Step 3: mint the key, wrap it **only** for `MeshRotationPolicy.recipients`, broadcast with the `cause` token, adopt locally. |
| `wrappedGroupKey(_:for:)` | Pairwise wraps for each recipient with a handshake-verified KA key — never the descriptor's gossiped value. |
| `adoptEpoch(_:key:)` / `clearEpochKeyring()` / `epochRef(counter:coordinatorFingerprint:)` | Move the held `MeshEpochKeyring` onto an adopted epoch (a keyring refusal is logged, never fatal), drop it with its key, and re-derive a peer's named ref from bytes both sides already share. |
| `terminateForExhaustedEpochs()` | Plan §8.4's counter cap: mark and persist the ending, then emit `terminated.v1` and end the session. Never a trap. |
| `recordRotationBlock(_:)` / `lastRotationBlockReason` / `lastRotationCause` | Frozen-English diagnostics: a rotation that did not happen is audited and readable, never swallowed. |
| `persistSessionContext(addingEpochHead:terminating:)` | **The single save seam** for `MeshSessionContext` — item 6 extended the cadence here rather than adding a second writer over a five-state load. Durable before acknowledged: false blocks the caller, always. |
| `sessionContextIdentity` (private) | The mesh a context is written for: the live descriptor, or — during a launch restore — the context just loaded, which is what lets an expiry found at launch be written back. |
| `applySessionEvent(_:)` | Offers one event to `MeshSessionStateMachine` and performs the effects **in order**, abandoning the rest at the first failure. That ordering is durable-before-acknowledged made mechanical. |
| `performSessionEffects(_:for:)` / `performSessionEffect(_:for:)` | The effect performer: stage a mark, save, begin a merge, start/stop the radios, arm/clear the idle window, offer a resume. Only a failed save returns false. |
| `stageEnding(from:)` / `barRejoin(reason:)` / `rejoinRefusal(for:)` | The ending mark and the rejoin bar are one fact, staged together and re-derived from the sealed file at launch — a developed, departed or terminated mesh is refused at both doors (descriptor adoption and admission grant). |
| `startSessionCeiling(hardDeadline:startedAt:)` / `sessionCeilingVerdict(now:monotonicElapsed:)` | Arm and read the dual-bound ceiling. The monotonic origin is a `ContinuousClock` instant; tests pass elapsed seconds instead of waiting. |
| `enforceSessionCeiling(now:monotonicElapsed:)` | At either bound: mark terminated, persist, **await** `terminated.v1`, end the session. A refused save abandons the emit. |
| `evaluateIdleLapse(now:)` | Plan §8.2's 30-minute window as a value, evaluated on demand — no timer, nothing to spin. |
| `evaluatePartition(now:)` / `evaluatePartition(reachable:now:)` | Plan §10.2's partition detection, evaluated **on demand** in the same idiom — no new timer; P7 wires the one poller. Re-derives `branchView`, raises `linksLost` / `linksRestored`, and **mints nothing**: the derived roster does not move. |
| `reachableRosterFingerprints()` / `presence(of:)` / `branchView` | Who this device can reach (self + committed active slots), one member's `MeshMemberPresence`, and the branch snapshot itself — memory-only, never sealed, cleared with the session. |
| `noteExternalHeartbeat(from:at:)` | Pushes the idle window out for a **current member's** authenticated heartbeat, so a live branch of ≥ 2 stays alive while a partition of one runs to `localIdleStop`. Own fingerprint and non-members are refused. |
| `restoreSessionContextAtLaunch(now:)` / `retrySessionRestoreIfPending(now:)` | The durable half: five load states → seven outcomes, a bounded retry for the two retryable ones, a quarantine for a corrupt file, and **no writer** for any of the three token-less states. |
| `resumeSessionAfterLapse(mergingLedger:peerEpochHead:)` | Idle-lapse resume = partition heal = the merge path. Wraps the offer and hands it to `mergeReconnected(_:entry:)`; never a fresh session, never a silent re-key. |
| `restoreMembershipLedger(from:)` | P4 item 2's fourth reconnect entry: puts the sealed ledger back after a process death through `MeshLedgerAdoption.adopt` (a **re-verification** from the ledger's own self-admitted root), so a relaunched member merges FROM something instead of dropping every frame `droppedNoLedger`. Arms `pendingMergeEntry = .processRestart`. Schema stays 2. |
| `recordVerifiedAdmissionDurably()` / `joinDurably()` | **The join-ack gate**: no epoch adopted, no key unwrapped, no beacon started and no "joined" shown until the context is on the disk. |
| `commitVerifiedRecord(rollingBackTo:type:)` | Keeps a verified record only if the context containing it was sealed — otherwise the verifier snapshot is restored, so "verified" and "remembered" stay the same set. |
| `resetSessionStateMachine(keepingTerminalState:)` / `abandonUnpersistedSession()` | Clear the run-scoped halves (a terminal state survives until a new session starts), and unwind a founding whose context could not be sealed. |
| `sendMembershipEvent(_:custodyHandoff:)` / `emitMembershipEvent(_:)` | Mint, sign and broadcast `member-departure.v1` / `terminated.v1`. The async form is awaited by `leaveSessionAfterNotifyingPeers()`, which would otherwise race its own teardown. A departure carries the leaver's `MeshCustodyHandoffSummary` (custodians named, item count still zero — P5 owns the content). **A termination is gated on `MeshDevelopmentPlan.permitsTermination(_:)`** (P4 item 6): a device whose own merged roster is larger than two refuses to sign one, logged rather than silent. No ledger at all still may — the ceiling and the epoch-counter cap end sessions that never had one. |
| `sendRemovalRecord(_:)` / `emitRemovalRecord(_:)` | Broadcast a completed `member-removal.v1` to every member EXCEPT the one it removes (plan §8.3). |
| `membershipEventRecipients(excluding:)` | Who a membership frame about a fingerprint may reach — `MeshRotationPolicy.recipients` reused verbatim, so the set that gets the new key and the set that is told why cannot drift apart. The subject is excluded here, not by the caller's ordering. |
| `emitApprovedRemovalRecord(_:)` | The legacy two-party path's completion. Since P4 item 5 it is a one-line call onto `mintAndFileRemoval(target:proposalID:voterFingerprints:)`. |
| `mintAndFileRemoval(target:proposalID:voterFingerprints:)` | **The one body both quorum paths end in** (P4 item 5): sign a `member-removal.v1`, file it through the verifier, seal it, and only then announce it (plan §3.6). A record the store could not seal is rolled back and never announced. |
| `proposeSignedRemoval(of:now:)` / `voteOnSignedRemoval(_:now:)` | The signed quorum's two local entries (P4 item 5, plan §10.4). Mint, count locally, broadcast to every member except the target, then re-evaluate. Additive beside the frozen unsigned `proposeRemoval(of:)` / `secondRemoval(_:)`. |
| `receiveSignedRemovalProposal(_:now:)` / `receiveSignedRemovalVote(_:now:)` | Verify the signer through `MeshMembershipRecordVerifier`, then hand the live state to `MeshRemovalQuorum`. Two questions, two calls: "a member signed this" and "it is still live and they may vote". |
| `evaluateRemovalQuorum(_:now:)` | Re-derives ⌊&#124;roster&#124;/2⌋ + 1 on **this** device's merged roster at this instant; on completion closes the proposal, mints the permanent record and rotates `.membership`. Guarded by `approvedRemovalProposalIDs`, so one proposal mints at most one record however many late votes arrive. |
| `dispatchRemovalQuorumPayload(_:plaintext:decoder:slot:)` | The wire door for `removal-proposal.v1` / `removal-vote.v1`. COMMITTED slot required; the sender is deliberately **not** required to be the author, because these frames carry their own signature and a partitioned quorum wants relaying. |
| `mergeMembershipLedger(_:)` | **The one merge path** (P4 item 2, plan §10.3): verify-then-insert another ledger, raise a `merge` rotation when the derived roster moves — **after** the merged ledger is durable, rolled back if it is not — and apply what the merged roster says about this device. |
| `mergeReconnected(_:entry:)` | The named front door onto it. All four reconnects (blip / partition heal / idle-lapse resume / process restart) arrive here with a `MeshMergeOffer`; folds the peer's epoch heads first (durable before acknowledged), then merges the records. `mergeApplicationCount` / `lastMergeEntry` are the observable seam behind "there is exactly one path". |
| `applyMergedRosterVerdict(from:)` | The merge-path counterpart of `applyRosterMove(_:from:)`: a departure/removal that happened in the other branch arrives only as a merged record, so a terminated mesh ends and a device that **was** a member and no longer is ejects. A ledger growing from empty is never mistaken for an ejection. |
| `beginMergeExchange(entry:)` / `concludeMerge()` / `abandonMergeExchange()` | The merge window. Opens on `beginMerge` (and on the `peerCommitted` self-edge — the blip and item 1's partial heal), asks every committed peer with the existing signed inventory digest, and closes on a peer digest that **matches** local inventory. Splitting again abandons it. While it is open, arriving records go through the merge path, so a whole re-gossip mints ONE `.merge` epoch. |
| `openBlipMergeIfReconnected(_:from:peer:)` | The self-edge half of the window: **reconnect ≡ merge, admission ≠ reconnect.** Opens a merge only when the committing peer was ALREADY on the derived roster; a new member's first commit keeps its own `.membership` rotation, and a commit that names no peer opens nothing. `applySessionEvent(_:committedPeer:)` carries the fingerprint beside the event — the state machine's alphabet stays free of membership. |
| `refreshBranchViewAfterMerge()` | A merge moves the roster underneath the branch-view snapshot, so a member whose departure record arrived in the union would keep answering `present`. Re-derives the view against the same reachable set — **no detector, no event, no clock**: a merge is not a reachability change. |
| `foldEpochHeads(_:)` | Seals a reconnecting peer's heads into `epochHeads` through the single `persistSessionContext(addingEpochHead:)` writer. Same-counter divergent heads **coexist** until `requestMergeRotationForDivergentHeads()` mints the successor that retires them (P4 item 3); it counts nothing itself — the overflow past the cap of 8 is named in `droppedEpochHeadCount` **at the writer, after the seal** (`recordDroppedEpochHeads(_:)`), because the set the cap can bite is the set being written (plan §21.3). Never silently truncated. |
| `rotateIfRosterChanged(from:)` | The roster-change trigger. A refused record, or one that moves no roster, spends no rotation. |
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
| `SignedRemovalProposal` / `SignedRemovalVote` | The signed live quorum (P4 item 5, §10.4, tokens `fernlet.mesh.removal-proposal.v1` / `…removal-vote.v1`). Two objects, not one: the proposal is the only thing that binds `proposalID → (mesh, target, proposer)` under one signature, so a vote cannot re-point somebody else's proposal at another member. Never records, never sealed. |
| `MeshRemovalQuorum` / `MeshRemovalOpenProposal` | The in-memory tally. Pure: `now` and `roster` are parameters, signatures are the verifier's. Expiry is measured from the receiver's own `firstSeenAt`, so no stamp on the wire decides anything; the signed stamp is only bounded by §10.3's ±10 minutes. `prune(at:)` DELETES — expiry leaves no tombstone. |
| `MeshRemovalQuorumBounds` / `MeshRemovalQuorumRejection` / `MeshRemovalQuorumVerdict` | The five-minute window and the ±10-minute clamp; twelve named live refusals (kept separate from `MeshMembershipRecordRejection`, which is about records reaching a ledger); and the verdict — `unknown` / `expired` / `pending(required:counted:)` / `complete(voterFingerprints:)`, recomputed on every read. |
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
| `…DerivedRoster.introductionRoster(additionalBarred:)` | Hands the QUIC transport members AND barred as keys. **The shipping answer from P3 item 7**: `MeshNetworkManager.roster` is this function, so a peer with a verified removal or departure refuses as `barredMember` by name. `additionalBarred` only ever adds a refusal (the two-node lane's chaos hook). |
| `MeshNetworkManager.legacyIntroductionRoster()` | The pre-records fallback: the gossiped descriptor's members, logged once as `mesh.introductionAuthority.legacyRosterFallback`. Reachable only with an empty ledger — tests and pre-P3 interop. |
| `MeshLedgerAdoption.isBootstrap(_:selfFingerprint:)` / `bootstrapVerifier(meshID:ownAdmission:)` / `adopt(offered:ownAdmission:meshID:)` | The joiner's ledger, pure. Bootstrap roots at the admitter's key; adopt rebases onto the offered ledger's own root once it is proven to admit this device's admitter under exactly the key its token names. |
| `applyTermination(_:to:)` (private) | Read-time, not merge-time: a termination from a non-member is ignored; one whose signer sits on a roster larger than two downgrades to that signer's departure. Applying it at merge time would make the union order-dependent. |

### `MeshMembershipEvents.swift`

The membership events that MOVE (plan §8.3, §10.5). Record kind, `PayloadType` and crypto domain
share one frozen English spelling per event, so a grep for the token finds every layer.

| Type / Function | What It Does |
| --- | --- |
| `MeshMembershipEventFormat` | Widths and caps every frame is checked against BEFORE a signature is verified: 64-byte signature, 32-byte digest, 64-char fingerprint ceiling. |
| `MeshRecordIdentity` | One record's kind + the four fields of its total order, so the digest is computed over a kind-tagged flattening of all four sets rather than four separate hashes. |
| `MeshInventoryDigest` | Counts + SHA-256 over the sorted identities, under `Hash.meshInventoryDigestV1`. A pure function of the record SET — a hint that decides whether a full record exchange is worth its bytes, never an authority. |
| `MeshMemberDeparturePayload` / `MeshMemberRemovalPayload` / `MeshTerminationPayload` | The three record frames. Each carries the signed record and nothing else — a second unsigned copy of the same fact is a second thing that can disagree, and the receiver re-derives quorum from its own roster anyway. The removal's voter list is clamped to §9's cap on decode as well as on init. |
| `MeshInventoryDigestPayload` | The signed digest message: digest + sender + `sentAt` + signature, with `isWellFormed` checked on untrusted bytes first. |
| `SignedDepartureRecord.signed(…)` / `SignedTerminationRecord.signed(…)` / `SignedRemovalRecord.signed(…)` | `@MainActor` minting factories over `IdentityService`, mirroring `MeshAdmissionToken.signed`. Verification stays `nonisolated`. |
| `MeshInventoryDigestPayload.signed(…)` | Computes this device's digest for a ledger and signs it. |
| `MeshEpochHeadsPayload` | The signed `fernlet.mesh.epoch-heads.v1` message (P4 item 3): mesh + head set (clamped to `MeshSessionContextSchema.maxEpochHeads`) + sender + `sentAt` + signature, `isWellFormed` first. Carries no key and no record; `sentAt` is bound into the signature and read by nothing that decides anything, which is what makes the merge's minter provably clock-free. |
| `MeshEpochHeadsPayload.signed(…)` | Signs this device's live head set under `Signature.meshEpochHeadsV1`. |
| `MeshMembershipGoodbyeInterop` | The legacy `fernlet.session.bye.v1` rule: **parsed, never emitted**, and `departureRecord(forGoodbyeFrom:)` is ALWAYS nil — an unsigned frame must not be able to subtract a member from a signed roster (disconnect ≠ removal, §8.2). |
| `MeshLegacyGoodbyeOutcome` | One case, `.disconnected`. The strongest statement an unsigned goodbye can support. |

### `MeshMembershipRecordVerifier.swift`

The verify-then-insert seam item 1 deliberately left open. Nothing that derives a roster may insert
without coming through here: the sets are capped at sixteen and keep the EARLIEST records, so junk
with a low timestamp crowds a real removal out on every device it reaches.

| Type / Function | What It Does |
| --- | --- |
| `MeshMembershipRecordRejection` | Ten named refusals + frozen-English `diagnosticDescription`. A bare boolean is how "signed by a stranger" and "three votes short" become one indistinguishable non-update. |
| `insert(_: SignedAdmissionRecord)` | Verifies under the token's own `meshAdmissionTokenV2` domain (one admission format, not two); the admitter must be a current member, or the founder when the ledger is empty. `expiresAt` is NOT re-applied — it gates admission, not a durable record. |
| `insert(_: SignedDepartureRecord)` | Self-signed by the leaver; the key comes from that member's admission record, never from the departure. |
| `insert(_: SignedRemovalRecord)` | Re-checks plan §10.4's ⌊&#124;roster&#124;/2⌋ + 1 against THIS device's merged roster via `MeshDerivedRoster.quorumThreshold`; distinct eligible voters only, target excluded. |
| `insert(_: SignedTerminationRecord)` | Requires a CURRENT member — a departed, removed or unknown signer cannot end a mesh it is not in. Whether it terminates or downgrades stays `MeshDerivedRoster`'s read-time decision. |
| `merge(_:)` | Imports a peer's ledger ONE RECORD AT A TIME through the same door, so a peer that forged one record cannot import all of them. |
| `verify(_: MeshEpochHeadsPayload)` | The same five checks under the head set's own domain (P4 item 3). A verified set that DIVERGES is the signal, not an error — but an unattributable one is refused, because the heads decide the counter a merge mints at. |
| `verify(_: SignedRemovalProposal)` / `verify(_: SignedRemovalVote)` | The same five checks under the quorum's two domains (P4 item 5). **Quorum is NOT checked here** — a proposal carries one vote and the arithmetic belongs to `MeshRemovalQuorum`, re-derived on the roster of the moment. The target is refused as a signer in both, so "the target cannot vote" is enforced twice.
| `verify(_: MeshInventoryDigestPayload)` / `matchesLocalInventory(_:)` | Verifies a peer's digest, then answers whether it matches. A DIFFERING verified digest is the signal, not an error. |
| `admittedSigningKey(for:)` (private) | The single lookup that turns "well-formed" into "signed by somebody entitled to sign it". |

### `MeshEpochRef.swift`

Plan §8.4's epoch model. A Lamport counter, a derived per-minting id, and the minting coordinator's
fingerprint — canonical, deterministic, and short enough to ride the introduction's existing 96-char
`epochRef` field (no wire framing moved).

| Type / Function | What It Does |
| --- | --- |
| `MeshEpochBounds` | Plan §8.4's numbers in one place: counter cap 4096, keyring 3 predecessors, 5-minute grace, the 32/16 hex widths, the frozen derivation domain `fernlet.mesh.epoch.v1`. |
| `MeshEpochRef` | `counter` + `epochID` + `coordinatorFingerprint`. Two branches at ONE counter are two distinct values — the representability plan §8.4 needs. |
| `MeshEpochRef.minted(counter:coordinatorFingerprint:meshID:)` | Derives `epochID` as SHA-256(domain ‖ meshID ‖ counter ‖ coordinator) truncated to 16 bytes, so every member of a branch computes the same id with no wire change. Returns nil over the cap or on a non-canonical fingerprint. |
| `…successor(coordinatorFingerprint:meshID:)` | `counter + 1`, or **nil at the cap** — the documented "rotation refused; the session must end" answer. Never traps. |
| `…canonicalString` / `init(canonical:)` / `isCanonical(_:)` | `"<counter>.<32 hex>.<16 hex>"`, canonical in both directions (no leading zeros, no uppercase) so two devices sign byte-identical strings. The parse is strict and every refusal is named. |
| `MeshEpochRefParseError` | Five named refusals, including `counterOverCap(_:)` which carries what it saw. |
| `MeshEpochRefOrder.precedes(_:_:)` | Total order for head sets: counter, then coordinator, then epoch id. Deterministic truncation, NOT a ranking of "better" epochs. |
| `Codable` (single value) | Encodes as the canonical string, so a persisted `epochHeads` entry is validated on decode instead of carried as an opaque token. |

### `MeshEpochKeyring.swift`

The bounded keyring: current + ≤ 3 predecessors, ≤ 5 minutes each. **Memory-only, forever** —
`MeshEpochRef`s persist, keys never do.

| Type / Function | What It Does |
| --- | --- |
| `MeshEpochKeyring.init(head:key:)` | There is no empty keyring; a device with no group key holds none, which is what its `epochRef` reports as "no epoch". |
| `rotate(to:key:at:)` | Moves the head and starts the old one's grace window. Throws `MeshEpochKeyringRotationRefusal` (`staleCounter` / `alreadyCurrent` / `divergentBranch`) and leaves the ring untouched — a divergent branch never supersedes. **Item 5's rotation entry point.** |
| `key(for:at:)` / `canOpen(_:at:)` | Head first, then a predecessor still inside grace. After grace, nil — there is no other holder of the bytes and no "try it anyway". |
| `openableEpochs(at:)` / `prune(at:)` | Diagnostic surface and memory hygiene. The clock is injected everywhere; nothing here reads `Date()`. |

### `MeshEpochAcceptance.swift`

Plan §8.4's acceptance rule as two pure decisions. Authentication happens before either is asked.

| Type / Function | What It Does |
| --- | --- |
| `rotationVerdict(local:presented:presentedRoster:presenterFingerprint:)` | The plan verbatim: presenter must be the deterministic coordinator (lowest fingerprint) of the roster it presents, and the counter must strictly advance. **Continuity is never required** — 5 → 9 is accepted. |
| `MeshEpochIntroductionVerdict` | `converge` / `malformed` / `reconcile(local:peer:)`. P4 item 3 replaced the blanket `divergent` refusal with `reconcile`: the merge that reconciles two branches runs OVER the tunnel the old rule tore down, so refusing it was a deadlock. Admitted only when `MeshIntroductionAuthority.mayReconcileDivergentEpochs` says a merge can run, and only on the QUIC introduction — the roster, mesh-ID and malformed checks are unchanged and still downstream. |
| `MeshEpochRotationVerdict` | `accept` / `coexist` / `reject`. `coexist` is the answer a boolean cannot give: two partitions at one counter are both correct until a merge mints a greater successor. |
| `MeshEpochRotationRefusal` | Five named refusals + frozen-English diagnostics. |
| `isDivergent(_:)` / `highestHead(_:)` | Whether a head set holds two mintings at one counter — the question a merge asks — and the head its `max + 1` counts from. Pure, bounded by `MeshMergeOffer.maxFoldedHeads`, and free of any tie-break: `highestHead` contributes a number, never a winner. |
| `mergedHeads(_:adding:limit:)` | How coexistence becomes a persisted state: both divergent heads survive, duplicates collapse, the oldest fall off by `MeshEpochRefOrder` so every device drops the same ones. |
| `introductionVerdict(local:peer:)` | The **strict** gate (plan §20.1). Junk is `malformed` even opposite an empty side; equality is equality of the whole ref, so two branches that both rendered `"7"` are now seen; the joiner that holds no key is a named branch, not a short-circuit. |

### `MeshRotationPolicy.swift`

P3 item 5 (plan §8.3): when a rotation happens and who the new key is for. Pure, clock-injected, and
owned by nothing that sends, seals or sleeps.

| Type / Function | What It Does |
| --- | --- |
| `MeshKeyRotationCause` | The frozen English wire token on `MeshKeyRotationPayload`: `timer` / `membership` / `merge`. Absent (or unknown) decodes as `timer` — the only rotation older builds performed. |
| `MeshRotationTriggerBounds` | The 2-second coalescing window, and the cause ranking (`merge` > `membership` > `timer`) used when a burst collapses. |
| `MeshRotationTriggerQueue` | `request` / `claim` / `finish` / `reset`. One trigger fires one rotation; a burst inside the window fires one; a trigger raised mid-rotation is deferred and re-armed, never dropped or run concurrently. |
| `MeshRotationTriggerOutcome` | `scheduled` / `coalesced` / `queuedBehindInFlight` — three answers because the caller arms a task, leaves one armed, or arms nothing. |
| `MeshRotationPolicy.plan(head:coordinatorFingerprint:meshID:presentedRoster:)` | The successor, through `MeshEpochAcceptance`. `terminate` at the counter cap; named `refuse` otherwise. |
| `MeshRotationPolicy.recipients(acked:selfFingerprint:derivedRoster:locallyRemoved:)` | **The exclusion rule.** Removed and departed members get no key; the set narrows to the derived roster once one exists. Subtractive on purpose — a positive rule over the still-empty ledger would distribute to nobody. |
| `MeshRotationPlan` / `MeshRotationRefusal` | Rotate / terminate / refuse, with frozen-English diagnostics. |

### `MeshFrameReplayWindow.swift`

Replay protection moved OFF epochs (plan §8.4). Knows nothing about epochs, which is the point.

| Type / Function | What It Does |
| --- | --- |
| `admit(frameID:from:meshID:expiresAt:now:)` | Per-**authenticated**-sender dedup by frame id, with the frame's own expiry and an explicit mesh id. Only `admitted` records anything. |
| `MeshFrameReplayVerdict` | `admitted` / `replayed` / `expired` / `foreignMesh` / `senderWindowFull`. |
| bounds | 8 senders (the roster cap) × 64 ids, and the cap **refuses rather than evicts** — an LRU would let a flood of fresh frames erase the history an attacker wants to replay into. |
| `forget(senderFingerprint:)` | What a departure or removal does, so a re-admitted member starts with a clean window. |

### `MeshSessionStateMachine.swift`

P3 item 6 (plan §8.2): the session lifecycle as a pure, total function. Ten states, eighteen events,
an ordered effect list, and a named refusal for every non-edge — never a trap, because most of these
events arrive from the wire.

| Type / Function | What It Does |
| --- | --- |
| `MeshSessionState` | `idle` / `joining` / `activeForeground` / `continuingInBackground` / `partitioned` / `localIdleStop` / `handingOff` / `departed` / `terminated` / `expired`. `partitioned` and `localIdleStop` are states in which this device is **still a member**. |
| `MeshSessionEvent` | Every edge label plus the two the prose adds: the ceiling (`hardDeadlineReached`) and the launch restore (`contextRestored`). `terminationReason` is the ONE place an ending's reason is decided, so the mark written and the line logged cannot disagree. |
| `MeshSessionEffect` | What the owner must do, in order. `persistContext` precedes every announcement; there is deliberately **no emit effect** — a membership frame must be awaited before the transport is torn down. |
| `MeshSessionTransition` / `MeshSessionTransitionRejection` | `moved(to:effects:)` or `rejected(_)`, with five named rules (`sessionAlreadyEnded`, `noSessionYet`, `sessionAlreadyStarted`, `eventNotApplicableInState`, `restoreOnlyFromIdle`). |
| `MeshSessionStateMachine.transition(from:on:)` | The total function. The ended check runs first (the permanent rejoin bar), then the restore and the ceiling — handled once each so seven per-state copies cannot drift — then one function per state. |

### `MeshBranchPresence.swift`

P4 item 1 (plan §10.2): what a device can **see**, held apart from what it can **prove**. Nothing
here reaches `MeshMembershipLedger`, and nothing here is `Codable` — presence is never sealed and
`MeshSessionContextSchema.current` stays at 2.

| Type / Function | What It Does |
| --- | --- |
| `MeshMemberPresence` | `present` / `temporarilyDisconnected` — frozen English tokens, logged verbatim, never localized. Presence, **never a record**. |
| `MeshBranchView.init(roster:reachable:selfFingerprint:)` | Splits the derived roster into present and `temporarilyDisconnected`, and **copies** `memberCount`, `quorumThreshold` and `isFinalPair` through unchanged — the three answers a partition must not move (§10.2/§10.4/§10.6). |

### `MeshDevelopmentPlan.swift`

P4 item 6 (plan §10.6): what "the user developed the mesh" means while it is split, as one pure
value derived before anything is signed.

| Function / property | Behavior |
| --- | --- |
| `MeshDevelopmentEnding` | `departure` or `termination`, plus the frozen wire token and the two session events each implies (`departureRequested`/`departureSent`, `terminationRequested(.finalPairTermination)`/`terminationSent`). Frozen English; never display copy. |
| `MeshDevelopmentPlan.init(roster:branch:selfFingerprint:startedAt:)` | The ending comes from the **merged derived roster** (`isFinalPair`); the custodians come from the **branch view** (`presentFingerprints − self`). The connected-peer count is not a member of the type, so the mistake §10.6 forbids cannot be made at a call site. No ledger ⇒ departure; no branch view ⇒ every roster member assumed reachable. |
| `handoffDeadline` / `handoffHasExpired(at:)` / `handoffOutcome(finishedAt:)` | §10.6's 15-second window as a deadline and a pure comparison — no timer, no sleep. `completed` / `noReachableCustodian` / `windowExpired` are all named answers; the unreachable branch is never in the target set, so nothing waits on it. |
| `handoffSummary` | The `MeshCustodyHandoffSummary` the departure record carries: custodians named, `handedOffItemCount` zero until P5's routed store has something to hand over. |
| `permitsTermination(_:)` | The **issuance** gate: only a merged roster of two or fewer may sign a `terminated.v1`. A nil/empty roster is permitted — the ceiling and the counter cap end sessions with no ledger. Receivers never depend on it: `MeshDerivedRoster` downgrades a wrongly-issued termination at read. |
| `branchCoordinatorFingerprint` / `isLocalBranchCoordinator` | The lowest fingerprint **present** — what scopes a branch's 15-minute rotation to itself, and why two branches' same-counter epochs are distinct refs that `coexist`. |
| `isPartitioned` / `isAlone` / `branchMemberCount` / `presence(of:)` | Whether any member is out of reach, whether this is a partition of one (nobody to heartbeat, so the 30-minute window runs), the branch size, and one member's presence (nil for a fingerprint the roster does not name). |
| `MeshPartitionVerdict` | `unchanged` / `linksLost` / `linksRestored`, with `sessionEvent` naming the edge each raises. |
| `MeshPartitionDetector.verdict(previous:current:)` | The pure edge-detector: only *entering* a partition raises `linksLost`, only a *full* heal raises `linksRestored`. A deepening split is already partitioned; a partial heal leaves the branch a branch and lets the returning peer take `peerCommitted` into the merge path. No clock, so no timestamp can manufacture or hide a partition. |

### `MeshContentMerge.swift` / `MeshContentIngest.swift`

P4 item 7 (plan §10.3, §21.3): the **content** half of the merge — ID-keyed union, deterministic
re-derivation, and the ingestion gates re-run at the receiving member. Pure values, nothing
persisted (`MeshSessionContext` schema stays 2), nothing on the wire. P5 owns the routed store and
the drain; this file owns only the rules.

| Type / Function | What It Does |
| --- | --- |
| `MeshMergeableContent` | What one merged content kind must expose: `contentID` (the UUID the union keys on), `senderFingerprint`, `orderingInstant`, a content-derived `mergeTiebreak`, and `setCapacity`. |
| `MeshContentOrder.precedes(_:_:)` | The one total order: `(orderingInstant, senderFingerprint, contentID, mergeTiebreak)` ascending — §10.3's stated transcript order verbatim, plus a last resort that can only break a tie the first three cannot. |
| `MeshContentSet<Item>` | The ID-keyed set: dedup by id (the order-least copy wins), sort, keep the newest `setCapacity` — the same bound every live surface applies. `merging(_:)` is commutative, associative and idempotent, at the cap as well as below it. Deliberately **not** `Codable`. |
| `MeshMergedPhoto` / `MeshMergedMessage` / `MeshMergedHeart` | The three projections. The photo carries `keyEpoch` through untouched (§21.5's P5 handoff) and a **local** SHA-256 digest, not a wire field. The message carries both clocks — the untrusted `claimedSentAt` and the receiver's `firstSeenAt`. The heart carries **no** receipt field: a peer's receipt is not this member's. |
| `MeshMergedMessage.clamped(_:around:)` / `claimWindow` | The ±10-minute clamp. A claim inside its window is returned unchanged, which is why honest traffic sorts identically at every member; a forged stamp moves at most 10 minutes from where it actually arrived. |
| `MeshContentLedger` | Three sets and nothing else — the content twin of `MeshMembershipLedger`. `merging(_:)` is set union in all three kinds, so an N-way partition tree converges with pairwise merges only. |
| `MeshPhotoReassembly.digest(of:)` / `verdict(reassembled:expecting:)` / `admitting(_:reassembled:into:)` | §10.3's "hash-validated on reassembly". `admitting` returns the set **unchanged** unless the bytes validate, so "silently kept" is not a reachable state; `rejectedEmpty` and `rejectedDigestMismatch` are named, not silent. |
| `MeshContentGates` / `folding(chatAllowed:senders:isRefused:)` / `admits(_:)` | §21.3's decision as a value: the 13+ chat gate and the local block/ban, folded once from the seams that already enforce them (`MeshNetworkManager.isChatAllowed`, `ProximityHost.isBlockedFingerprint`, `ModerationBanStore.isPeerBanned`). Local by construction — two members may hold different gates over one union. |
| `MeshContentLedger.visibleTranscript(gates:)` / `visiblePhotos(gates:)` / `visibleHearts(gates:)` / `senders` | The gates as a **view filter over an unmutated union** — same shape as termination-derived-at-read. A blocked sender's message still unions; it simply does not render at the member that blocked them, and re-opening the gate reveals it with no second merge. |
| `MeshHeartReceipt` / `MeshContentLedger.heartReceipt(_:committed:)` | `pending` / `received`, frozen tokens. The union alone answers `pending` for everything. |
| `MeshHeartCommit.commit(_:into:)` / `MeshHeartCommitOutcome` | Drives merged hearts through the **existing** `ProximityHeartLedger` — its id-dedup, its 5-minute per-sender cooldown — rather than a second copy of them. `judgements` is one per distinct gift id: a duplicate that crossed the split is collapsed by the union *before* the ledger sees it, so the cooldown is judged once. |

### `MeshDeliveryTarget.swift`

P4 item 8 (plan §10.1, launcher §5(c)): **who content is for**, held apart from **how far each copy
has got** — the vocabulary P5's `MeshRoutedManifest` expresses its destination set in. Pure value,
no clock, nothing persisted (`MeshSessionContext` schema stays 2), nothing on the wire. P5 persists
targets inside its routed store; this file owns only the rule.

| Type / Function | What It Does |
| --- | --- |
| `MeshDeliveryTarget.init(contentID:roster:selfFingerprint:)` | Captures the destination set = **full derived roster at creation time − self**. The parameter is a `MeshDerivedRoster`, so a branch view or a reachable set cannot be passed by mistake; there is no other initializer and **no method removes a destination**. `init(for:roster:selfFingerprint:)` is the one-call form for a `MeshMergeableContent` item. |
| `MeshDeliveryState` | The stored, merged half: `pending` / `custodied(by:)` / `delivered`, a three-rung monotone ladder. `delivered` is terminal (§11's final ack — hearts only after foreground decrypt + ledger commit); `custodied` says on its own that **custody ≠ delivery**. `later(_:_:)` is the max under that order, with the least custodian fingerprint as a deterministic tiebreak (not a preference). |
| `MeshDeliveryDisposition` | The read-time answer: the three states plus `departed`, which is **derived against the current roster**, never stored — same shape as the termination downgrade, so a departure/removal unioning in closes a destination with nothing rewritten. Grow-only records make the closure permanent, which is why the drain may stop rather than back off. `isOutstanding` / `isClosed` are the buckets P5 branches on. |
| `MeshDeliveryStateToken` / `MeshDeliveryRefusal` | Frozen English tokens: `pending`/`custodied`/`delivered`/`departed`, and `notADestination`/`alreadyDelivered`/`wouldRegress`/`differentContent`/`destinationSetMismatch`. Logged verbatim, never localized; §18.2's display copy forks separately. |
| `advancing(_:to:)` → `MeshDeliveryOutcome` | Moves one destination up the ladder on the receipt as evidence — never on elapsed time. Re-applying the current state is idempotent; anything backwards is **refused by name**. |
| `merging(_:)` → `MeshDeliveryOutcome` | Per-destination **max** — commutative, associative, idempotent, so two members that learned different receipts converge losing neither. A destination-set (or content-id) mismatch is refused by name rather than unioned or intersected: either would invent or drop a recipient. |
| `outstanding(in:)` / `closed(in:)` / `isFullyDelivered(in:)` | §11's "destinations lacking a `MeshRecipientReceipt`", the roster-closed set, and the complement. A target whose every destination departed is fully delivered vacuously — the answer that lets P5 retire the item. |
| `outstandingReachable(from:in:)` / `outstandingUnreachable(from:in:)` | The two existing seams as **derivations, not duplicates**: for a fresh target the first equals `MeshDevelopmentPlan.handoffTargets` and the second equals `MeshBranchView.temporarilyDisconnectedFingerprints`. Neither type was modified. Reachability filters the *work*, never the destination set. |

### `MeshRoutedManifest.swift`

P5 item 1 (plan §11): the origin-signed description of one routed item, and the per-recipient
content-key wrap that rides inside it. Pure values, no clock; the only mint takes a
`MeshDeliveryTarget`, so the destination set is the full roster at creation and never the connected
set. Deliberately NOT in this file: persistence and its wipe row (item 3), dispatch/emission (item
6), chunks (item 2) and the item seal under `AEAD.meshRoutedItemV1` (item 6 / P6 — item 2 chunks an
opaque blob and deliberately does not seal), the type-token registry (item
11), receipts (items 3/4).

| Type / Function | What It Does |
| --- | --- |
| `MeshRoutedManifestFormat` | The frozen widths and caps every manifest is checked against BEFORE its signature is verified: 64-byte signature, 32-byte hash, 64-byte token/fingerprint ceilings, 7 destinations (roster cap − origin), 256 MiB `size` (the relay cache's whole budget — item 9 reuses it), 32/12/48-byte wrap fields, 32-byte content key, and the 20-minute development grace. |
| `MeshRecipientKeyWrap` | One destination's copy of the content key: recipient fingerprint + ephemeral X25519 public key (32) + GCM nonce (12) + sealed key (48 = 32 ciphertext ‖ 16 tag). Lives inside the manifest and is bound into the origin's signature; never on the wire alone. `isWellFormed` is a width check. |
| `MeshRoutedManifest` | The record: `meshID`, `itemID` (= `MeshDeliveryTarget.contentID` = the replay window's per-sender frame id; the routed store's union key is the PAIR `(originFingerprint, itemID)` — both signed — because any admitted member can mint under its own key reusing another origin's id, and an id already held under a different origin is refused at the store door in item 3/6, never here), `originFingerprint`, `typeToken`, `contentHash`, `size`, `createdAt`, `expiresAt` (= `hardDeadline` + grace), `destinations` (`MeshDeliveryTarget.destinations` verbatim), `keyWraps` (one per destination, same order), `signature`. Both lists are clamped to the destination cap and BOTH instants are floored to whole seconds on the memberwise init AND on decode, so an over-cap list is unrepresentable and a relay's sub-second re-encoding cannot extend liveness or produce a manifest `!=` the origin's that still verifies. Carries no epoch, branch, custody or first-seen. |
| `isWellFormed` / `isLive(at:)` | Width/count check on untrusted bytes before the signature; liveness `now <= expiresAt` under an injected clock (the `MeshFrameReplayWindow.admit` predicate). |
| `expiry(afterHardDeadline:)` / `floored(_:)` | The ONE expiry formula and the ONE finite-guarded floor, shared by the mint and the verifier. Both return `Date`s — no reader may `Int64(_:)` either instant, because an admitted origin can sign `1e300` and `appendDate` saturates rather than traps. |
| `MeshRoutedManifestPayload` | The `fernlet.mesh.routed-manifest.v1` frame: the manifest and nothing else. Signed, NOT sealed (not in `sealingRequiredTypes`) so a custodian can re-broadcast it verbatim; the wraps are the confidentiality. Registered here, dispatched from item 6. |
| `MeshRoutedManifestMintError` | Why the mint refused, by name: `noDestinations`, `tooManyDestinations` (unreachable through `MeshDeliveryTarget`'s only initializer — the derived roster caps at 8, so a target names at most 7; kept so the mint states its own bound), `originIsADestination`, `invalidTypeToken`, `invalidContentHash`, `invalidSize`, `invalidContentKey`, `missingRecipientKey(fingerprint:)`. A manifest that cannot be built for the WHOLE destination set is not built at all. |
| `MeshRoutedManifest.signed(meshID:target:typeToken:contentHash:size:createdAt:hardDeadline:contentKey:recipientKeys:identity:)` | `@MainActor` mint: validates, mints one wrap per destination from the caller-supplied handshake-verified X25519 keys (a missing key refuses the whole mint), floors both instants, signs `canonicalBytes(for:)` under `Signature.meshRoutedManifestV1`, and returns a copy built from the CLAMPED unsigned fields so signed bytes == wire bytes. The signer is always the origin. |

### `MeshRoutedManifestVerifier.swift`

P5 item 1 (plan §11): the one door a received manifest passes through. Public material only, so it
runs on a locked device over ciphertext-only custody; `nonisolated`, no clock. Deliberately NOT
here: a roster check (a DEPARTED origin's content stays valid — leaving is not a retraction — so
departures are never consulted), a destination lookup in the ledger (D12: destinations are trusted
on the origin's signature, bounded by expiry and the relay caps), and any dispatch. Deliberately
HERE: the removal check — a quorum-REMOVED origin (plan §10.4) is refused by name, because removal
is the mesh's moderation act and the group-key rotation that enforces it on live traffic cannot
reach a per-recipient static-key wrap (D14).

| Type / Function | What It Does |
| --- | --- |
| `MeshRoutedManifestRejection` | Frozen English tokens: `foreignMesh`, `malformed`, `unknownTypeToken`, `originNotAdmitted`, `originRemoved`, `originKeyMismatch`, `signatureInvalid`, `wrapsDoNotMatchDestinations`, `destinationSetInvalid`, `expiryMismatch`. Logged verbatim, never localized. |
| `MeshRoutedManifestVerifier(meshID:hardDeadline:ledger:acceptedTypeTokens:)` | Bound to one session: the mesh, its signed ceiling, the merged membership ledger, and the routed-type tokens this build will hold or forward (D13 — item 1's callers pass a fixture set, item 11 the registry's; empty means accept nothing). |
| `verify(_:)` | Ten guards in order: mesh → shape → type token accepted → admitted key (from `ledger.admissions`, by the manifest's OWN origin, never the envelope's sender) → origin not in `ledger.removals` (the same set `MeshDerivedRoster` subtracts; departures untouched) → key/fingerprint agreement → signature under `Signature.meshRoutedManifestV1` → wraps ≡ destinations → distinct set without the origin → `expiresAt` == own `hardDeadline` + grace (`Date` equality through `floored`; no `Int64` anywhere). Returns the named rejection or nil. |

### `MeshRoutedContentKeyWrapper.swift`

P5 item 1 (plan §11, invariant §3.3): the per-recipient content-key wrap and its inverse —
`IdentityService.encryptGroupKey` primitive for primitive with the routed purposes and a
binding-carrying AAD. `nonisolated` and static: the recipient's private key never enters the file.
Deliberately NOT here: the item seal (item 6 / P6 — item 2 chunks an opaque blob), any key from
descriptor gossip or the trust vault.

| Type / Function | What It Does |
| --- | --- |
| `MeshRoutedWrapBinding` | What a wrap is bound to besides its recipient: `meshID`, `itemID`, `originFingerprint`. Part of the AEAD's authenticated data, so a wrap cannot be transplanted between manifests, meshes or origins. |
| `MeshRoutedKeyWrapError` | `invalidRecipientKey(fingerprint:)`, `invalidContentKey`, `notAddressedToMe`, `malformed`, `openFailed` — one token for every CryptoKit refusal on purpose (distinguishing them would be an oracle). Frozen English diagnostics. |
| `makeContentKey()` | 32 random bytes from the platform CSPRNG, as `Data` (no pointer API; item 6 / P6 builds the `SymmetricKey` at the seal — item 2 chunks an opaque blob and never sees a key). Minted BEFORE the item is sealed and hashed. |
| `wrap(contentKey:recipientFingerprint:recipientKeyAgreementPublicKey:binding:)` | Fresh ephemeral X25519 + fresh GCM nonce per wrap → HKDF-SHA256 (salt `KeyDerivation.meshRoutedContentKeyWrapV1`, info eph ‖ recipient) → AES-256-GCM over the 32-byte key with `additionalData` authenticated. Public keys only. |
| `unwrap(_:binding:localFingerprint:localKeyAgreementPublicKey:staticAgreement:)` | The inverse, refusing `notAddressedToMe` and `malformed` before any key agreement; the DH is a closure into `IdentityService.heartDropStaticAgreement(withEphemeralPublicKey:)` (the `HeartDropSealer.open` shape), whose own error propagates. Everything CryptoKit refuses is `openFailed`. |
| `additionalData(binding:recipientFingerprint:)` | `AEAD.meshRoutedContentKeyWrapV1.data` (raw prefix) ‖ meshID ‖ itemID ‖ lp(origin) ‖ lp(recipient). Frozen wire-bearing bytes, pinned by an independently derived golden. |

### `MeshChunk.swift`

P5 item 2 (plan §11): one origin-signed slice of a routed item's ciphertext, plus the two
domain-tagged digests and the derived chunk id the routed family hashes under. Pure values, no
clock; the payload is EXCLUDED from the signed transcript and bound through `chunkHash`.
Deliberately NOT in this file: persistence (item 3, with its wipe row), dispatch/emission and the
item seal (item 6 / P6 — item 2 chunks an opaque blob), any relay hop, custody transfer, hop count
or TTL (item 8 / increment 2), the type-token registry (item 11), backpressure (item 9).

| Type / Function | What It Does |
| --- | --- |
| `MeshChunkFormat` | Frozen widths and caps: 64-byte signature, two 32-byte hashes and the 64-byte fingerprint ceiling (all reused from `MeshRoutedManifestFormat`), `maxChunkPayloadBytes` = 256 KiB (**the only new magic number**, named so tier 2 can re-measure pacing without touching the wire shape), `maxChunkCount` = 1024 **derived** from `maxContentByteCount`, and `maxChunksInFlightPerPeer` = 3. |
| `MeshChunkFormat.maxChunkCount` | 256 MiB / 256 KiB. Its doc names the coincidence item 9 must not collapse: 1024 routed *items* (plan §9) and 1024 *chunks in one maximal item* are two different caps that happen to be equal. |
| `MeshChunkFormat.maxChunksInFlightPerPeer` | `MeshTransferStreamTable.maxConcurrentOutbound - 1` — **one slot of headroom** in a budget every reliable frame ≥ 64 KiB shares (friend photos above all), not a throughput target and not a guarantee: nothing reserves a slot, and `openOutbound` returning nil is indistinguishable from "sub-floor". The safe number is a tier-2 measurement; this is the v1 placeholder item 6 must not re-derive. |
| `MeshChunkFormat.chunkCount(forSize:)` | `ceil(size / 256 KiB)`, nil for zero or above the content cap. The single definition the mint, the verifier, the assembler and `expectedPayloadByteCount` all share. The cap guard runs first, so a hostile `size` cannot overflow the ceil. |
| `MeshRoutedContentDigest` | `contentHash(of:)` (the whole sealed blob, `Hash.meshRoutedContentV1`), `chunkHash(of:)` (one slice, `Hash.meshRoutedChunkV1`) and `chunkID(itemID:chunkIndex:)` (`Hash.meshRoutedChunkIDV1`, first 16 bytes as a `UUID`). Two domains because untagged, a ONE-chunk item's item hash and chunk hash would be the same 32 bytes. The domain prefix is writer-produced and the body is streamed into `SHA256()`, so a 256 KiB payload is never copied to be hashed. |
| `MeshChunk` | The record: `meshID`, `itemID`, `originFingerprint`, `contentHash` (the manifest's, copied), `chunkIndex`, `chunkCount`, `chunkHash`, `expiresAt` (the manifest's formula, never restated), `payload`, `signature`. Carries no `createdAt`, no `size`, no type token, no epoch/branch/partition, no custodian/hop/TTL and no explicit id. Both doors floor `expiresAt`; nothing is clamped — an over-long payload FAILS `isWellFormed` rather than being trimmed. |
| `isWellFormed` / `isLive(at:)` | Widths and counts on untrusted bytes before the signature; liveness `now <= expiresAt` under an injected clock. |
| `MeshChunk.chunkID` | The derived replay-window id (item 12 keys on it). Deterministic; equal across a retransmission, different per index or item, origin-free on purpose because `MeshFrameReplayWindow.admit` already separates by sender. Not an RFC-4122 UUID — a 128-bit dedup key with `UUID`'s shape. **Its doc gives item 12 the wiring's shape, not the whole wiring:** `MeshFrameReplayWindow.maxFramesPerSender` is 64 and the window refuses rather than evicts, while `maxChunkCount` is 1024, so an item above 16 MiB would hit `senderWindowFull` on its 65th chunk — item 12 sizes a P5 window (or a per-item chunk bitmap) first, and keys the sender axis on the ORIGIN. |
| `MeshChunk.expectedPayloadByteCount(index:count:size:)` | The ONE chunk-boundary rule: every index but the last is exactly 256 KiB, the last is the remainder; nil for an out-of-range index or a `count` that disagrees with the size. |
| `MeshChunkPayload` | The `fernlet.mesh.routed-chunk.v1` frame: the chunk and nothing else. Signed, NOT sealed (not in `sealingRequiredTypes`) — the payload is already ciphertext and a custodian must re-broadcast verbatim. Registered in item 2, dispatched from item 6. |

### `MeshChunkVerifier.swift`

P5 item 2: the one door a received chunk passes before the routed store may hold its bytes. Public
material only (signature + SHA-256 + ledger, never a content key), so it runs on a locked device
over ciphertext-only custody. **The manifest is optional**: chunks ride streams that are not ordered
against the control stream, so a chunk that arrives first is verified and parked.

| Type / Function | What It Does |
| --- | --- |
| `MeshChunkRejection` | Frozen English tokens: `foreignMesh`, `malformed`, `originNotAdmitted`, `originRemoved`, `originKeyMismatch`, `signatureInvalid`, `chunkHashMismatch`, `expiryMismatch`, `manifestMismatch`, `chunkCountMismatch`, `payloadLengthMismatch`. Logged verbatim, never localized. |
| `MeshChunkVerifier(meshID:hardDeadline:ledger:manifest:)` | Bound to one session and, optionally, one **already-verified** manifest — the type never re-verifies it and it is the only authority on `itemID`, `originFingerprint`, `contentHash` and `size`. |
| `verify(_:)` | Eleven guards: mesh → shape → admitted key (from `ledger.admissions`, by the chunk's OWN origin) → origin not in `ledger.removals` (departures never consulted) → key/fingerprint agreement → signature → **then** the chunk hash (so a hash mismatch names a payload swapped under an authentic chunk) → expiry equality → and, with a manifest, the identity **triple** `(itemID, originFingerprint, contentHash)`, the chunk count and the payload length. Dropping the origin leg of the triple would let an admitted member squat another origin's item id under its own valid signature. |

### `MeshChunker.swift`

P5 item 2: the mint, and the only place a chunk signature is produced. `nonisolated` type,
`@MainActor` on the two mint functions only (`IdentityService` is main-actor isolated). Deliberately
NOT here: any send path, envelope, queue or pacer (item 6), any forwarding or custody transfer (item
8), any content-key handling — the blob is opaque.

| Type / Function | What It Does |
| --- | --- |
| `MeshChunkMintError` | `emptyBlob`, `sizeMismatch(blobByteCount:manifestSize:)`, `contentHashMismatch`, `notTheOrigin(origin:)`, `tooManyChunks(size:)` (unreachable while a well-formed manifest bounds `size` AND the blob really is that size — kept because the bound belongs where the growth is), `indexOutOfRange(index:count:)`. Frozen English diagnostics; never `LocalizedError`. |
| `chunk(of:at:for:identity:)` | The primitive: mints exactly ONE signed chunk, so item 6 can stream a large item at `blob + one chunk` of peak memory. Slices into a FRESH `Data` (never a `SubSequence` sharing indices), hashes the slice, signs the transcript, and rebuilds from the unsigned value's own fields so signed bytes == wire bytes. |
| `chunks(of:for:identity:)` | The bounded run: `for index in 0..<count`, `count ≤ 1024`. Never a `while`. Derives the guard chain **once per item** and mints through the private `mint(of:at:count:for:identity:)` — re-entering the validating primitive per index would cost `count + 1` whole-blob SHA-256 passes (1025 over 256 MiB for a maximal item, on the main actor) for a chain whose every clause but the index is loop-invariant. |
| `mint(of:at:count:for:identity:)` | Private: one chunk over an ALREADY-validated `(blob, manifest, origin)` plus the derived count — the loop body, and the whole mint apart from the guard chain. Re-checks only the index, the one clause that is not loop-invariant. No door into the mint skips validation. |
| `validated(blob:manifest:origin:)` | The guard chain and the derived count, run **once per item** (its content-hash clause is a pass over the whole blob). Refuses to mint for a manifest this device did not originate — a custodian is a courier, not a co-signer. Pure and `nonisolated`. |

### `MeshChunkAssembly.swift`

P5 item 2: the receive-side reassembler — a bounded value that collects one item's chunks in any
order and decides once whether the ciphertext is whole. **Every input returns a verdict; nothing is
silently dropped.** Chunk bytes live in MEMORY here; item 3 re-backs the byte custody with its
sealed sidecar and reuses this verdict logic unchanged. Deliberately NOT here: any capacity verdict
— the assembly's own bound IS 1024 × 256 KiB = `maxContentByteCount`, so plan §11's aggregate
256 MiB / 1024-**item** backpressure is a seam item 9 adds in FRONT of `admit`/`forChunk`, and its
accounting must include parked, manifest-less chunks.

| Type / Function | What It Does |
| --- | --- |
| `MeshChunkRefusal` | Frozen English tokens: `foreignItem`, `countMismatch`, `indexOutOfRange`, `conflictingChunk`, `chunkHashMismatch`, `sizeOverflow`, `payloadLengthMismatch`, `notBound`, `sizeMismatch`, `contentHashMismatch`. Never user copy — item 9 owns the visible backpressure failure. |
| `MeshChunkAdmission` / `MeshChunkBinding` / `MeshChunkCompletion` | `admitted(received:expected:)` / `duplicate(received:)` (a retransmission is a **no-op, not an error**) / `refused(_:)`; `bound` / `refused(_:)`; `complete(blob:)` / `incomplete(received:expected:)` / `refused(_:)`. |
| `forManifest(_:)` / `forChunk(_:)` | An assembly already bound to the manifest's size, or an UNBOUND one for a chunk that arrived first (the parked case). Both take a value their verifier already accepted. |
| `admit(_:)` | Identity triple → count → index → duplicate/conflict → chunk hash (re-checked because this is the boundary item 3 gates durable custody on) → size overflow → length rule (bound: exactly what `expectedPayloadByteCount` fixes; unbound: interior chunks are exactly 256 KiB and the last is 1 … 256 KiB, checked at the door rather than left to the verifier's precondition). **Duplicate vs conflict is decided on the signed transcript plus the payload, never on `==`:** CryptoKit's Ed25519 signing is hedged, so an honest re-mint (item 6 streams without retaining, item 8 transfers custody) differs only in the 64-byte signature, and `conflictingChunk` is an integrity claim about content. |
| `bind(to:)` | Cross-checks the triple and the derived count, re-validates every already-held chunk's length against the now-known size in one bounded loop, and refuses **without mutating** if any fails. Idempotent. |
| `completion(against:)` | `notBound` while unbound; `foreignItem` for another manifest; `incomplete` at the first gap (never a partial blob); `sizeMismatch` / `contentHashMismatch`; else `complete(blob:)`. **`complete` is NECESSARY, NEVER SUFFICIENT for a custody receipt**: it is a verdict over in-memory bytes, so the order is durable → complete → receipt, and durability is item 3's separate gate (plan §3.6). |

### `MeshChunkAdmissionRule.swift`

P5 item 3 (C13): the two chunk-set decisions, extracted so the IN-MEMORY reassembler and the DURABLE
store reach them through one function each. Item 2's `MeshChunkAssemblyTests` pass unmodified beside
the extraction, which is the regression proof. Pure; nothing here reads a clock, a file or a payload.

| Type / Function | What It Does |
| --- | --- |
| `MeshChunkDescriptor` | Exactly the eight fields `canonicalBytes(for: MeshChunk)` writes, in that order — so descriptor equality and transcript equality are the same statement. `Codable`: the routed index persists one per held chunk file. The payload and the signature are absent by design. |
| `MeshChunkSetShape` | The state one decision reads: identity triple, chunk count, `boundSize` (nil ⇒ parked), bytes held, the descriptor at the incoming index, and every held slot's payload length. Built from a chunk map on one side and from index records on the other. |
| `MeshChunkAdmissionRule.verdict(for:payloadHash:in:receivedCount:)` | The one PER-CHUNK decision, in item 2's order: `foreignItem` → `countMismatch` → `indexOutOfRange` → duplicate/`conflictingChunk` → `chunkHashMismatch` → `sizeOverflow` → `payloadLengthMismatch`. The duplicate check is `descriptor(held) == descriptor(chunk) && payloadHash == held.chunkHash` — equivalent to item 2's transcript-plus-payload comparison, and it still answers `conflictingChunk` for a chunk whose payload does not hash to its own declared `chunkHash`. |
| `MeshChunkAdmissionRule.bindingVerdict(for:in:)` | The one BINDING decision, in `MeshChunkAssembly.bind(to:)`'s order: identity triple ⇒ `foreignItem`; derived count ≠ the set's ⇒ `countMismatch`; any held slot the manifest's size makes the wrong length ⇒ `payloadLengthMismatch`. Mutates nothing, so a refusal leaves the parked set exactly as it was — on both sides. |

### `MeshCustodyReceipt.swift`

P5 item 3 (plan §11, §3.6): a custodian's signed statement that it durably holds one routed item's
COMPLETE ciphertext. **Custody is not delivery**, and the receipt says nothing about the custodian
being able to read what it holds.

| Type / Function | What It Does |
| --- | --- |
| `MeshCustodyReceiptFormat` | Three widths, all **reused** from `MeshRoutedManifestFormat`: 64-byte signature, 32-byte content hash, 64-byte fingerprint ceiling. |
| `MeshCustodyReceipt` | mesh, item, the item's ORIGIN (the subject), `contentHash`, the CUSTODIAN (the signer), the durable custody instant and the item's expiry. No key epoch, branch, hop count, TTL, destination set, chunk index or schema integer — the `.v1` in the domain IS the version. Both doors floor both instants; nothing is clamped, and the two fingerprints are width-checked in `isWellFormed` so an over-long one is a cheap `malformed` rather than a `signatureInvalid`. |
| `MeshCustodyReceipt.receiptID` | `UUID(SHA-256(lp(Hash.meshCustodyReceiptIDV1) ‖ uuid(itemID) ‖ lp(origin) ‖ lp(custodian))[0..<16])`. **Derived, never a wire field**, and it excludes both the hedged signature and `custodiedAt`, so a re-mint of the same claim is the same id. The frame id item 12 admits. |
| `MeshCustodyReceipt.signed(witness:manifest:identity:)` | The ONLY mint, and it takes a `MeshCustodyDurabilityWitness` — which only a returned durable write produces. `meshID` and `expiresAt` come off the manifest, `custodiedAt` off the witness. Refuses `notTheCustodian`, `witnessForAnotherItem`, `contentHashMismatch`, `originIsSelf`, `itemExpired`. There is no factory that signs somebody else's receipt. |
| `MeshCustodyReceiptPayload` | The wire frame, `PayloadType.meshCustodyReceipt`. Signed and UNSEALED so members can forward it verbatim and converge on delivery state (plan §3.2). |

### `MeshCustodyReceiptVerifier.swift`

P5 item 3: the one door a received receipt passes through. The signing key is resolved by the
**custodian** fingerprint from the admission ledger, never from the envelope sender.

| Type / Function | What It Does |
| --- | --- |
| `MeshCustodyReceiptRejection` | Nine frozen English tokens: `foreignMesh`, `malformed`, `custodianIsOrigin`, `custodianNotAdmitted`, `custodianRemoved`, `custodianKeyMismatch`, `expiryMismatch`, `signatureInvalid`, `manifestMismatch`. |
| `verify(_:)` | mesh → shape → custodian ≠ origin → admitted key → not removed → key/fingerprint agreement → expiry equality (`hardDeadline + grace`, D6) → signature → (only with a manifest) the identity **triple**. D14 holds: a **departed** custodian's receipt still verifies; a **quorum-removed** one's does not. |

### `MeshRoutedStoreKey.swift`

P5 item 3: where one device's sealed routed custody lives, and the key row that seals it.

| Type / Function | What It Does |
| --- | --- |
| `MeshRoutedStorageScope` | Directory **and** keychain service in one value, because isolating one without the other isolates nothing. `productionKeychainService` is `com.fernlet.mesh-routed` — its **own** service, not a lodger under the mesh-session one: one fate per service is the only arrangement a service-wide delete can express honestly. |
| `MeshRoutedStorageScope.keychainService(besideHeartDrop:)` | Production in ⇒ production out; any isolated heart-drop service ⇒ a distinct sibling. This is what lets `FernletStore` DERIVE the scope from seams the test walls already enforce instead of adding a fourth injectable one. |
| `MeshRoutedSealKey.forOpen(service:)` / `forSeal(service:)` | Three-way outcomes. `forOpen` never mints (a fresh key opens nothing); `forSeal` mints only on a **definitive** absence, and read-back-verifies, because sealing against an unverified key writes ciphertext nothing can ever open. Accessibility `AfterFirstUnlockThisDeviceOnly`, `synchronizable: false`. |
| `MeshRoutedSealKey.wipe(service:)` | Deletes every row under the service. The file half is `MeshRoutedStore.wipeForDeleteAll(scope:)`; both halves always go together. |

### `MeshRoutedIndex.swift`

P5 item 3: the sealed CATALOGUE — what this device holds for other people, how far each destination's
copy has got, and which sealed payload file backs each chunk. No I/O, no crypto, no clock.

| Type / Function | What It Does |
| --- | --- |
| `MeshRoutedIndexSchema` | Version **2** since P5 item 4 (the two durable ack fields), its **own** from day one (`MeshSessionContext` stays at 2). Older or newer is `corrupt`, never migrated — a schema-1 file would otherwise be reinterpreted into a record whose `deliveredAt`/`recipientReceipts` the next save silently drops. The at-rest **token** does not move: it is the key-derivation domain. |
| `MeshRoutedStoreFormat` | `maxItems` 1024; `maxContentBytes` = `MeshRoutedManifestFormat.maxContentByteCount` (**reused** — moving it moves a WIRE bound, because `MeshChunkFormat.maxChunkCount` is derived from it); `maxChunksPerItem` = `MeshChunkFormat.maxChunkCount`; `maxHeldChunkFiles` 4096 (file count is not bounded by bytes); `maxReceiptsPerItem` = the roster cap. |
| `MeshRoutedIndexDecodingError` | `unsupportedSchemaVersion(_:)` and `capacityExceeded(_:)`. At rest a cap violation is a **refusal**, never a clamp: clamping would silently drop a durable record whose payload files stay on disk, possibly one a receipt was already emitted for. |
| `MeshRoutedItemKey` | The union key — the **signed pair** `(originFingerprint, itemID)` (D11). An item id alone lets an admitted member squat another origin's id under its own key and have it verify. |
| `MeshRoutedChunkDescriptor` | The chunk's transcript fields, its payload length and the **opaque** `<uuid>.chunk` file name. A mirror, not a binding: the seal's AAD carries no file name, so every read compares the opened chunk against this. |
| `MeshRoutedDeliveryProgress` / `MeshRoutedDeliveryRecord` | The persisted half of `MeshDeliveryTarget`: the sparse progress map only. `pending` is an absence; `departed` is never encoded and is refused on decode. The destination set is NOT stored — it comes back from the origin's signed manifest. |
| `MeshRoutedItemRecord` | Key, content hash, chunk count, expiry, the manifest stored **whole** (nil ⇒ parked), receiver-local `firstSeenAt`, `custodiedAt` (written once, cleared by a repair), `deliveredAt` (P5 item 4 — written once and **never** cleared by a repair, because an acknowledgement already given is a fact), the held descriptors, the delivery record, other members' custody receipts, and `recipientReceipts` — peers' AND this device's own, hard-decoded so a schema-2 record missing the key is corrupt rather than "no receipts held". |
| `MeshRoutedIndex` (delivery, P5 item 4) | `itemsFullyDelivered(at:in:)` (every destination delivered or departed — **not** a reclaim list: a recipient's own inbox copy is fully delivered while it is still the only copy of the content), `itemsReclaimableAsCustodian(at:in:for:)` (fully delivered AND this device is not a destination — item 9's reclaim input, since the consumed-locally signal does not exist yet) and `itemsAwaitingLocalAck(at:for:)` (this device is a destination and its OWN receipt is not stored — deliberately not conditioned on the ack instant, completeness or custody, because each would hide a state a retry must reach). |
| `MeshRoutedIndex` | The ordered records plus the counters item 9 reads (`itemCount`, `totalContentBytesHeld`, `heldChunkFileCount`), `firstSeenAt(of:)`, `heldChunkIndices(of:)`, and item 6/8's enumeration: `outstandingDestinations(for:in:)`, `outstandingReachable`/`outstandingUnreachable`, `outstandingItems(at:in:)`, `itemsAwaitingHandoff(at:in:)` and `handoffCandidateCount(at:in:)` (a **candidate** count — `handedOffItemCount` is filled after the transfers). Plus `itemsWithUnrestorableDelivery(at:)`: every enumerator above skips an item whose stored delivery map will not restore, so that item is **named** here rather than silently dropped from all of them (`MeshRoutedItemRef.deliveryRestoreRefused` is the same fact per item; a parked item is not one — it has no signed set to fail to restore). |

### `MeshRoutedStore.swift`

P5 item 3: the sealed sidecar's floor, mirroring `MeshSessionStore` method for method — and the only
file in the routed store that names `ColumnCrypto`.

| Type / Function | What It Does |
| --- | --- |
| `MeshRoutedSealRefusal` / `MeshRoutedDeferral` / `MeshRoutedCorruption` | Siblings of P3's, with **identical frozen rawValues** (a test asserts the sets are equal). Separate types because `MeshSessionSealRefusal.summary` hard-codes "mesh session context". |
| `MeshRoutedLoad` | Five states; only `loaded` and `absent` vend a `LoadToken`, whose initializer is `fileprivate` to this file — so no verb, in any other file, can mint one. |
| `load()` | File before custody (a missing index answers `absent` without consulting the keychain), emptiness before key, a read error is never absence, and `ColumnCrypto`'s three error families stay apart: binding READ error ⇒ defer, binding absent ⇒ refuse, wrong BYTES ⇒ corrupt. Read-only: the sweeps are explicit calls. |
| `save(_:token:)` | Seals and writes atomically at `.completeFileProtectionUntilFirstUserAuthentication`. **No write-side deferral for the install binding** — `DeviceBindingID.current()` collapses unavailable and read-error into nil, so the seal refuses, fail-closed. |
| `readChunkFile(expecting:contentKey:)` | Opens one payload file and compares all eight descriptor fields **and** the payload length against the slot's stored descriptor. Not redundant: the AAD is purpose ‖ install only, so every blob authenticates in any slot. Missing/unauthentic ⇒ repair; unreadable ⇒ defer, repair nothing. |
| `quarantineCorruptIndex(_:)` | The only route from `corrupt` to a writer. Moves the bytes aside rather than deleting them, and its contract requires the caller to spend the returned token on `sweepingOrphanChunkFiles()` first — after a quarantine every payload file is an orphan. |
| `wipeForDeleteAll(scope:)` | Index + quarantine sibling + the whole chunk directory + the keychain row, together. A missing file counts as success. |

### `MeshRoutedCustody.swift`

P5 item 3: the custody verbs items 4/6/8/9/10/11 call. Three outcome channels, no fourth, and
nothing silent.

| Type / Function | What It Does |
| --- | --- |
| `MeshRoutedUnavailability` | `deferred` / `corrupt` / `refused` / `notWritten`, each with a frozen `logToken`. `isRetryable` is true for all but `corrupt` — the SAME answer `MeshSessionRestoreOutcome.isRetryable` gives its own refusal, because the dominant cause here is the pre-first-unlock window that self-heals on unlock. Bounded by `MeshRoutedRetryBounds.maxAttempts` (reused from P3). |
| `MeshRoutedStoreRefusal` | Fifteen frozen tokens: the four capacity refusals, `duplicateItemID`, `manifestMismatch`, `unknownItem`, `itemExpired`, `chunkCountMismatch`, `heldChunkLengthMismatch`, `notADestination`, `chunkFileMismatch`, `capacityReceipts`, plus P5 item 4's `capacityRecipientReceipts` (two evidence arrays with two signer roles want two log tokens) and `unknownTypeToken` (plan §11's "unknown type tokens are rejected, not forwarded", answered at the ack seam). |
| `admittingManifest(_:now:)` | Binds a parked set through `MeshChunkAdmissionRule.bindingVerdict`, stamps `firstSeenAt` if new, creates the delivery record. Reserves **both** budgets — bytes and file slots — from the manifest's known chunk count, so an item that could never be finished is refused now rather than half-staged. |
| `stagingChunk(_:now:)` | Verdict through the shared rule, then the file, then the index — never the reverse. A failed index save removes the file this call just wrote and audits either way. The file cap is checked against `max(index, directory)`, so an orphan cannot hide from the cap that bounds it. |
| `recordingCustodyTransfer(item:for:receipt:now:)` | Advances each named destination to `custodied(by: receipt.custodianFingerprint)` and stores the receipt as evidence in **one** index write. There is no `to custodian:` parameter: the custodian IS the signer, so the durable state and the signature cannot disagree. Writes nothing on any refusal. |
| `forwardableManifest(item:)` / `forwardableChunk(item:index:)` | The origin's stored, signed objects **verbatim**, one chunk resident at a time. A slot mismatch answers `chunkFileMismatch` and emits nothing. |
| `sweepingExpired(now:)` / `sweepingOrphanChunkFiles()` / `dropping(item:reason:)` | On demand, never on a timer (P7 owns the poller). The orphan sweep's loop is bounded by **2 ×** `maxHeldChunkFiles` and reports `sweptToCeiling`, because a directory that got over the cap is exactly what orphans produce. |

### `MeshRoutedCustodyCommit.swift`

P5 item 3: **one type and one function, on purpose.** `MeshCustodyDurabilityWitness`'s initializer is
`fileprivate`, and `fileprivate` is FILE scope — so the only way to hold a witness is to have
completed the verb beside it, and `MeshCustodyReceipt.signed` takes one as a parameter. That is plan
§3.6 in the type system rather than in a comment. The mirror-image gate is `LoadToken`'s own
`fileprivate` init in `MeshRoutedStore.swift`, so this file cannot mint a write token either: two
gates, two files, neither able to open the other's door. Moving the type would widen the gate with no
compile error, which is what the grep-wall in `MeshRoutedStoreIsolationTests` exists to notice.

| Type / Function | What It Does |
| --- | --- |
| `MeshCustodyDurabilityWitness` | Origin, item, the re-measured content hash, the custodian, and the STORED `custodiedAt` — not this pass's instant, so a re-mint's canonical bytes are byte-identical. |
| `committingCustody(item:custodian:now:)` | **Always** re-streams every chunk file in index order through `MeshRoutedContentHasher`, compares each opened chunk against its slot's descriptor, and gates on size then content hash before any witness exists. Writes `custodiedAt` once. **Idempotent means "does not refuse", never "skips the check"**: an item whose file went away answers `incomplete`, mints nothing, and has its `custodiedAt` cleared. A failed stamp write mints no witness and reports the store's own `unavailability(from:)` classification — a refused seal is not an absent file (§19.5), so this writer flattens nothing the others keep apart. |

### `MeshRoutedAck.swift`

P5 item 4: plan §11's acknowledgement stages as VALUES — the column item 11 registers and item 14
drives. No store extension, so tier 1 can build a stage with no disk root; no acceptance decision, so
nothing here is a registry.

| Type / Function | What It Does |
| --- | --- |
| `MeshRoutedAckStage` | `immediate` / `durableRecipientStorage` / `foregroundDecryptAndLedgerCommit` — plan §11's three clauses, frozen English and **never on the wire**. Deliberately unordered and rankless: a heart is not "further along" than a photo, and the monotone ladder is `MeshDeliveryState`'s. |
| `MeshRoutedTypeToken` | The frozen `fernlet.mesh.routed-type.<kind>.v1` spellings: `photo`, `tempMessage`, `heart` (for which `itemID` **is** the gift id) and `control` — **reserved, not registered**, because a token nothing mints opens a door with no handler behind it. |
| `MeshRoutedAckStageRow` / `MeshRoutedAckStageTable` | One row per type, keyed by the wire `String` because the token only ever exists as one at rest. `.increment1` is the three registered types; `stage(for:)` answers **nil** for anything else, and nil is a refusal at every door. Injected, never global — and a source wall keeps shipping code on the one value. |
| `MeshRoutedHeartAck` | The heart's evidence: this gift judged exactly once **in this outcome** (per-GIFT, because `MeshHeartCommit.commit` is a batch door and a per-pass count would strand both hearts of a two-heart pass) plus the ledger's own `MeshHeartLedgerProof`. The `@MainActor` form asks the ledger synchronously, right after the commit. |
| `MeshRoutedAckEvidence` / `MeshRoutedAckShortfall` / `MeshRoutedDeliveryCommitOutcome` | `.none` for the stages whose condition the store reads for itself; four named shortfalls (`itemIncomplete`, `custodyNotCommitted`, `ledgerJudgementMissing`, `evidenceForAnotherItem`), each written on nothing; and the acknowledged/unsatisfied answer. |

### `MeshRecipientReceipt.swift`

P5 item 4: a DESTINATION's signed statement that one routed item reached it, finally. The custody
receipt's shape with the signer's role changed — and the ack STAGE is deliberately not a field.

| Type / Function | What It Does |
| --- | --- |
| `MeshRecipientReceiptFormat` | The three widths, **reused** from the routed family, never restated. |
| `MeshRecipientReceipt` | mesh, item, the origin (SUBJECT), content hash, the recipient (SIGNER), the durable ack instant, expiry, signature. No stage, no epoch, no hop count, no chunk index or partial marker — destination-final is whole-item — and no schema integer: the `.v1` in the domain IS the version. Both doors floor the instants; nothing is clamped, so an over-long fingerprint stays a cheap `malformed`. |
| `receiptID` | `UUID(SHA-256(lp(Hash.meshRecipientReceiptIDV1) ‖ uuid(itemID) ‖ lp(origin) ‖ lp(recipient))[0..<16])` — derived, never a wire field, stable across a re-mint (the signature and `receivedAt` are excluded), and **one per `(recipient, item)`**. Item 12's frame id. |
| `signed(witness:manifest:identity:)` | Takes a `MeshRecipientDeliveryWitness`, so no argument list mints a receipt for an acknowledgement no durable write returned. `meshID`/`expiresAt` come off the MANIFEST and `receivedAt` off the WITNESS. Five reachable refusals; no `notADestination` and no `ackStageUnsatisfied`, both of which the store door already refused before a witness existed. |

### `MeshRecipientReceiptVerifier.swift`

P5 item 4: the receive-side door. `MeshCustodyReceiptVerifier`'s shape with one extra leg.

| Type / Function | What It Does |
| --- | --- |
| `MeshRecipientReceiptRejection` | Ten frozen tokens. `notADestination` is the leg custody has no analogue for: a courier need not be a recipient, but a signer the origin never addressed is claiming to close a destination that does not exist. |
| `verify(_:)` | mesh → shape → recipient-is-origin → admitted key (by the RECEIPT's fingerprint, never the envelope sender) → not quorum-removed (**D14: a departed recipient's receipt still verifies**) → key/fingerprint → expiry EQUALITY → signature → (manifest held) the identity triple → (manifest held) the destination leg. Public material only, so it verifies on a locked device; no clock. |

### `MeshRoutedDeliveryCommit.swift`

P5 item 4: **one type and one function, on purpose** — the delivery twin of
`MeshRoutedCustodyCommit.swift`, with the same two-`fileprivate`-gates-in-two-files arrangement.

| Type / Function | What It Does |
| --- | --- |
| `MeshRecipientDeliveryWitness` | Origin, item, content hash, the recipient, the STORED ack instant, and the stage that was satisfied (audit surface only, never on the wire). `fileprivate` init, so this file is the only construction site. |
| `committingDelivery(item:recipient:stages:evidence:now:)` | Resolves the stage from the record's own origin-signed `typeToken` through the injected table, checks the stage's precondition, stamps `deliveredAt` **once**, and only then mints the witness. Writes **no** delivery rung — not this device's and certainly not a peer's — because `recipient:` is a caller's word and `delivered` is terminal. A record whose ack instant is already stamped does not need fresh stage evidence: the ledger cannot be asked twice, which is what makes the crash window recoverable. |

### `MeshRoutedDeliveryIngest.swift`

P5 item 4: the observer-side doors. Kept out of the commit file so that file's one-verb property —
what makes `fileprivate` a real gate — stays true.

| Type / Function | What It Does |
| --- | --- |
| `recordingRecipientReceipt(item:receipt:now:)` | **The only writer of a `delivered` rung in the whole store**, and it advances exactly one destination: the receipt's own signer. No `for destinations:` parameter, deliberately — that would let one member's receipt mark somebody else delivered. Re-checks the identity triple, the mesh, the destination set and capacity; stores the receipt replace-by-signer in the SAME index write; writes nothing on any refusal; no expiry gate (a receipt for an expired item is still evidence). |
| `forwardableRecipientReceipts(item:)` | The stored bytes verbatim, in signer order, **including this device's own** — the deliberate difference from custody, because a heart's final-ack condition is a one-shot ledger judgement the ledger refuses to repeat. |

### `MeshRoutedInventory.swift`, `MeshRoutedInventoryBuilder.swift`, `MeshRoutedInventoryVerifier.swift`

P5 item 5: the ROUTED CONTENT digest — what a device advertises it is holding, so the drain knows what
to ask for and what to offer. **Not** `MeshInventoryDigest`, which summarises a MEMBERSHIP ledger under
`fernlet.mesh.inventory-digest.v1`; this is `fernlet.mesh.routed-inventory-digest.v1`, and the two wire
spellings share a stem on purpose, so the Swift value-type names are the separation that holds.

| Type / Function | What It Does |
| --- | --- |
| `MeshRoutedInventoryFormat` | Every bound **reused**: 1024 entries (the store's item cap), 16 referenced members (the ADMISSION cap, not the roster's — a departed custodian must still be nameable), 9 custody signers per entry (8 stored + this device's never-stored own) and 8 recipient signers (this device's own is stored), the 128-byte widest bitmap, the shared fingerprint and signature widths. |
| `MeshRoutedInventoryEntry` | One held item: `originIndex` into the member table + `itemID` (D11's signed pair), `holdsManifest` (false ⇒ parked, advertised never hidden), `chunkCount`, `heldChunks` — the **exact** held set as a bitmap in a frozen bit order, with a hard trailing-zero rule — and the two signer index lists. `heldChunkCount`/`isComplete` are DERIVED popcounts, never stored. `missingChunks(against:)` / `chunksHeldBeyond(_:)` are the ask and offer directions, both over the two entries' overlap in this entry's index space. |
| `MeshRoutedInventory` | mesh + minimal member table + canonically ordered entries. `isWithinCaps` → `.overCapacity`, five `isWellFormed` clauses → `.malformed` (members ascending and MINIMAL, indices in range and ascending, chunk counts in 1…1024, canonical bitmaps, entries strictly increasing). Nothing is clamped, sorted or repaired at either door — `==` is set equality only because a non-canonical value is refused. No rollup hash: the list IS the digest. |
| `MeshRoutedInventoryPayload` | The advertiser-signed frame — inventory, `senderFingerprint`, floored `sentAt` (bound into the signature), signature. Carries its **own** shape check for the two scalars no door clamps. `signed(meshID:index:sentAt:identity:)` derives and signs, with no `Date()` default anywhere — and takes **no `selfFingerprint`**: `identity.localFingerprint` is the sole spelling of "this device", so a caller cannot mint a valid digest whose custody self-claim names a member that never held the item. |
| `MeshRoutedInventory.init?(meshID:index:selfFingerprint:at:)` | The builder: one bounded pass for the member table, one for the entries, over a **loaded** index. Filters on `isLive(at:)` only — parked, fully-delivered and unrestorable-delivery items are all advertised, because every delivery enumerator drops one of those classes. Custody self-rule: this device appears iff `isCustodied` **and** the item is not its own. Nil only past the member cap; the mint turns that into `MeshRoutedInventoryMintError.tooManyReferencedMembers`. |
| `MeshRoutedInventoryVerifier` | mesh → caps → shape (the PAYLOAD's) → admitted key by the payload's own fingerprint → not quorum-removed → key/fingerprint agreement → Ed25519. Public material only, so it runs on a locked device. D14: a departed advertiser still verifies; departures are never consulted. A verified digest that DIFFERS is not a rejection. |

### `MeshRoutedInventoryDelta.swift`

P5 item 5: the pure comparison. **All the drain's policy lives here**, so item 6 implements none of
its own; no clock, no I/O, no store.

| Type / Function | What It Does |
| --- | --- |
| `MeshRoutedInventoryReceiptRef` | `(key, signer, kind)` with the signer a **resolved fingerprint** — member tables are minimal per digest, so an index-wise comparison across two tables silently yields both false forwards and false gaps. |
| `MeshRoutedChunkGap` | `(key, chunkCount, missing)` where `missing` is a canonical bitmap over THIS device's count, never all-zero, and never carrying a bit above the two sides' overlap: a peer's larger count claim is neither believed nor asked for. `missingIndices()` expands on demand, one item at a time. |
| `between(local:remote:offerableToPeer:)` | The six lists, in canonical order. Four are pure functions of the two digests; only the two OFFER lists take the entitlement set, whose two honest sources (a destination with work outstanding; a custodian chosen at departure) are both rooted in the origin's signed manifest. Returns **nil** for a foreign-mesh pair — never an empty delta, which would read as matched. |
| `ask` / `offer` | The two request lists and the two offer lists as **distinct keys in canonical order**, not concatenations: one key satisfies both an ask rule and a chunk rule whenever it is held parked against an un-parked peer that is ahead, so a concatenation would name it twice and order it manifests-then-chunks. Item 6 paces sends off these. |
| `isQuiescent` / `converged(local:peerReportsQuiescent:)` | `isQuiescent` is strictly LOCAL ("nothing I know I owe or need") and is true for a device holding nothing, against every peer — so item 7's predicate is the **pair** form, with the peer's bit carried on the drain's answer. |

### `MeshRoutedContentHasher.swift`

P5 item 3: the streaming sibling of `MeshRoutedContentDigest.contentHash(of:)` — the same domain, fed
one chunk file at a time so 256 MiB is never resident. One domain, two shapes; never a second domain.

| Type / Function | What It Does |
| --- | --- |
| `MeshRoutedContentHasher` | `init()` seeds with `lp(Hash.meshRoutedContentV1)` exactly as the one-shot does; `update(_:)` feeds a slice in index order; `finalized()` is the 32-byte digest. A test pins the agreement across several split points. |

### `MeshSessionCeiling.swift`

Plan §8.2's 6-hour ceiling, guarded at **both** bounds.

| Type / Function | What It Does |
| --- | --- |
| `MeshSessionCeiling.init(hardDeadline:startedAt:)` | Reads the wall clock ONCE and turns it into a monotonic budget, clamped to `0 ... 6 h` — so a descriptor claiming a deadline days out buys nothing extra. |
| `verdict(now:monotonicElapsed:)` | Monotonic bound first (a clock set backwards cannot lengthen a session), then the signed absolute ± 120 s skew (what a forward jump trips). Returns the tighter remaining time. |
| `MeshSessionCeilingBound` / `MeshSessionCeilingVerdict` | Which bound ended it, and its durable `MeshSessionTerminationReason`. |

### `MeshSessionRestore.swift`

The launch-time classifier: five load states → seven outcomes, none of which lets a token-less state
write.

| Type / Function | What It Does |
| --- | --- |
| `MeshSessionRestore.outcome(for:selfFingerprint:now:)` | `absent` → no session; `deferred`/`refused` → retryable, logged apart; `corrupt` → quarantine; `loaded` → a recorded ending first, then the ceiling, then resumable. |
| `MeshSessionRestoreOutcome` | Seven cases with `disposition`, `isRetryable`, `context` and a frozen-English `logToken`. `expired` is the one that must WRITE. |
| `MeshSessionRestoredDisposition` | What the state machine sees: `none` / `resumable` / `terminated` / `departed` / `expired`. |
| `MeshSessionRestoreBounds.maxAttempts` | Three: enough to cross a first-unlock boundary, small enough that a permanently refusing custody costs three reads rather than a loop. |
| `MeshSessionRejoinBar` | The permanent bar (mesh id + reason), re-derived from the sealed context at every launch — a bar that lived only in memory would be lifted by a force-quit. |

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
| `canonicalBytes(for: MeshRoutedManifest)` | P5 item 1: domain ‖ meshID ‖ itemID ‖ origin ‖ typeToken ‖ lp(hash) ‖ size ‖ createdAt ‖ expiresAt ‖ count-prefixed destinations ‖ count-prefixed wraps (recipient, eph, nonce, sealedKey); `signature` excluded. Field order is the schema. |
| `canonicalBytes(for: MeshChunk)` | P5 item 2: domain ‖ meshID ‖ itemID ‖ origin ‖ lp(contentHash) ‖ u64(chunkIndex) ‖ u64(chunkCount) ‖ lp(chunkHash) ‖ expiresAt. **Both `payload` and `signature` excluded** — the payload is bound THROUGH `chunkHash`, so a 256 KiB slice costs 32 transcript bytes with the same authenticity. Field order is the schema. |
| `canonicalBytes(for: MeshCustodyReceipt)` | P5 item 3: domain ‖ meshID ‖ itemID ‖ origin ‖ lp(contentHash) ‖ custodian ‖ custodiedAt ‖ expiresAt; `signature` excluded. **Two fingerprints in two fixed positions** — the item's ORIGIN (the subject) and the CUSTODIAN (the signer) — so a receipt cannot be re-read as being about the signer's own item, and one lifted onto another origin's item fails the signature. No destination set, no chunk index, no partial count: a receipt exists only for a COMPLETE item. Field order is the schema. |
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
| `MeshHeartLedgerProof` / `commitProof(for:)` | P5 item 4: the ledger's own answer, **read-only**, to "did the write land and is this gift in what was stored?" — non-nil only when the sidecar state is `.ready` (memory and disk agree) and the gift is in the STORED received hearts. The proof's initializer is `fileprivate` to this file, so a routed heart receipt cannot be minted on a caller-supplied `Bool` for a gift the ledger never stored. No write path, no second receive path, no rule re-derived. |
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
