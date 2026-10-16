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

**2026-10-02 (ProximityKit plan step A0.2.12):** the "Protocol Namespace" section describes A0.2's end
state rather than its commits: what the host supplies, how each kind of reader takes the namespace,
the column-seal and keychain copies, and the test target's bindings in one table, with no row left
for a static A0.2 deleted. The quick-lookup rows above name the serializer's `in purposes:` overloads.

**2026-10-03 (ProximityKit plan step A0.4):** the features that left ProximityKit for `FernletSocial`
(presence, the heart dead-drop, moderation's ban store, ledger and content hash, the closeness
ledger, the friend-state cache and the parked chat payload) are indexed under "FernletSocial", each
section headed by its path there, and the sealed-backup escrow under "Identity, Wire, Trust, And
Audit", by its app path. What ProximityKit still holds for its later steps keeps its own sections:
"Hearts" the heart ledger, the prekey bundle and the protected sidecar; "Presence And Nearby
Friends" the presence radio presence drives; "Group Activities", "Clothing Shop", "Session Messages"
and "Moderation" what the mesh manager builds, decodes or calls (A0.5); "Photos And Recipe Sharing"
the one-to-one pair session recipe sharing runs over (its feature, `FernletSocial`'s since A0.7.3, is
indexed under "FernletSocial"). The test target's three bindings files are indexed beside the
namespace's readers.

**2026-10-09 (ProximityKit plan step A0.5):** the mesh's features left `MeshNetworkManager` for
`FernletSocial`, composed by `FernletMeshFeatures`, which the app builds and which owns the manager: the
session photos and their review (`MeshSessionPhotos`), the chat (`MeshSessionChat`), the session hearts
(`MeshSessionHearts`), the vouch list's content, the capability list, the friend-state and
moderation-report exchanges, the clothing shop and the activities, with the heart ledger, the session
message store, the moderation relay, the activity and clothing payloads, the features' canonical bytes
and `JSONSidecarFile`. Each is indexed under "FernletSocial" by its path there, and the rows that named
a moved member as the manager's moved with it. "Mesh" indexes the engine's seams those features ride:
the payload token door, `sendFeatureEnvelope`, `originateRoutedItem`, the routed projection handler and
ledger judge, the session observer, the vouch-list exchange and the routed-type rows a host declares
(`ProximityHost.meshRoutedTypeEntries`). ProximityKit's "Hearts" keeps the prekey bundle and the
protected sidecar; presence's radio stays where it was, wrapped by its public presence engine (A1.1), and the recipe-share manager's mechanism
stays as the pair session (A0.7.3).

**2026-10-11 (ProximityKit plan step A0.8):** ProximityKit has its own package test target,
`ProximityKitTests` (`FernletKit/Tests/ProximityKitTests`), holding the suites that need nothing
but ProximityKit (the fake transport fabric and the peer handle, the membership
records, the routed drain plan, the commit detector and ranging fallback, the replay cache, since
plan step A1.1.2 the namespace's soundness rules, `ProximityNamespaceSoundnessTests`, and since A1.1.4
the epoch model, `MeshSessionIDClaimTests` and the test support's own facts, `PackageTestSupportTests`);
its landing page's "Its tests" says how it runs and what waits for A1. Since A1.1.4 those suites compute
under a test namespace of their own, `.packageTest` (`TestSupport/PackageTestNamespace.swift`), through
`TestSupport/PackageTestBindings.swift`, each one of Fernlet's test bindings
(`Tests/FernletTests/ProximityNamespaceTestBindings.swift`) with `.packageTest` for `.fernlet`, and read
a source through `TestSupport/PackageRoot.swift`, by a path relative to the package root. Since A1.1.5
their keychain is an in-memory store, `TestSupport/PackageKeychainStore.swift`, which
`TestSupport/PackageTestEnvironment.swift` installs once as `ProximityKeychainItem`'s backend before the
first keychain call, held by `PackageKeychainStoreTests`. Since A1.1.6 a package suite can build a
manager unhosted over `TestSupport/PackageTestHost.swift`'s `PackageTestHost`, a `ProximityHost` of
ProximityKit's alone on a scratch root with `.test.` keychain services, and read this module's audit lines
through `TestSupport/PackageAuditCapture.swift`'s `PackageAuditCapture`, scoped by context or by its own
marking, over the bundle's `PackageAuditSink`, which the same installer puts in `ProximityAudit`'s slot;
`PackageTestHostTests` holds both. Since A1.1.7 the namespace wall, `ProximityNamespaceBoundaryTests`,
is a package suite too, on the `proximitykit` line: it reads ProximityKit's sources and its manifest
through `PackageRoot` (`Sources/ProximityKit`, `Package.swift`) and code through the package's copy of
the source walls' lexer, `TestSupport/SwiftSourceLexer.swift`, so it travels with the package; FernletTests
keeps its own copy of the lexer, held to the same fixtures by `SwiftSourceLexerTests`, and, until A1.3
deleted it with the sources, its own walker over ProximityKit's sources, `ProximityKitSources`, which the
feature golden read through. Since A1.1.8
the platform wall's rules over ProximityKit's own code are a package suite too,
`ProximityPlatformNeutralityTests`, on the `proximitykit` line (its imports and platform branches, its
device-name reads, platform directories and host-fact defaults, its two channel-ready doors and
`NIRangingSession`'s one home), walking ProximityKit's sources with the namespace wall's walk; Fernlet's
`ProximityPlatformBoundaryTests` keeps presence's heart door and the Mac build. Since
A1.1.10 two more suites are the package's, on the `proximitykit` line: the keychain door's wall,
`ProximityKeychainDoorTests` (the door declared once, in `ProximityKeychainItem`'s `#if DEBUG` branch,
and named by the package tests' installer alone), and the presence engine's own cells,
`ProximityPresenceSessionTests`, which drive `ProximityPresenceSession` over an in-memory radio. Since
A1.1.13 the package tests' own hygiene is a package suite too, `PackageTestHygieneTests`, on the
`proximitykit` line: what their unhosted bundle cannot serve (rule I9, its location needles the platform
suite's platform-directory list), their imports (rule I11), their own inventory
(`FernletKit/Tests/ProximityKitTests.tsv`: each suite's file and its declared tests) and no extension of
`ProximityHost`, read through the walls' walker, `TestSupport/PackageSwiftFiles.swift`;
`CIGateSelectorBoundaryTests` holds Fernlet's rows of the package's suites to that inventory. Since
A1.1.14 the package tests' tree walls are a package suite too, `PackageTestTreeWallTests`, on the
`proximitykit` line: `ProximityAudit.install(_:)` named by their installer alone, once, and nowhere in
ProximityKit's code (the walker reads ProximityKit's sources too); every session or routed store a test
builds on a scope of its own and `PackageTestHost`'s scopes on its root; ML5 over `MeshNetworkManager`
and `ProximityPairSession`; and no home of a determinism digest. Fernlet's audit install-site wall, store
isolation walls, ML5 and acceptance batteries read Fernlet's trees alone. Since A1.1.15 the source walls
over ProximityKit's own code are a package suite too, `ProximitySourceWallTests`, on the `proximitykit`
line: every read of its `PROXIMITYKIT_*` launch hooks (`injectUITestStateIfNeeded()`'s three UI-test
flags, `MeshTransportDebugHooks.swift`'s three keys) inside `#if DEBUG`, each family at its measured floor, and
no synchronizable keychain row or non-`ThisDeviceOnly` class in its code; Fernlet's hook and key-custody
greps read Fernlet's shipping roots but ProximityKit's folder, and the platform suite's W1 refuses
CloudKit by name in ProximityKit's code, in place of `S3BoundaryTests`' ProximityKit row. Since A1.1.16
the same suite holds a purpose named within reach of every raw cryptographic call in ProximityKit's code
(at least 16 such lines; `IdentityService`, the routed item seal and content-key wrapper,
`ProximityColumnCrypto`, the mesh manager and the TLS identity hold them) and its one escape hatch, the
TLS identity's `x509-self-signature`, pinned with its justification; Fernlet's purpose wall and
escape-hatch census read Fernlet's shipping roots but ProximityKit's folder. Since A1.1.17 the same suite
holds that ProximityKit builds no identity of its own (no `IdentityService` construction anywhere in its
code, no delegation to one of its initializers, `Identity/IdentityService.swift` included), and the
memory-lifecycle wall's ML1-ML4 over ProximityKit's code are a package suite too,
`ProximityMemoryLifecycleTests`, on the `proximitykit` line (the six task holders' deinits,
`ProtectedSidecar`'s observer removal, `ObservationLoop` the one home of `withObservationTracking`, and
the mesh manager's and the pair session's host pins); Fernlet's identity-construction wall and its
ML1-ML4 read Fernlet's shipping roots but ProximityKit's folder. "The test
target" in this index means the app's `FernletTests`, where the bindings and Fernlet's host doubles
live. The fake peer transport, the ranging mock, the membership fixtures, the mesh-message spelling
helper, the test namespace, the epoch fixtures and the source walls' lexer lived in both targets, held
identical but for imports, until A1.3; each is an ordinary `FernletTests` file since.

**2026-10-15 (ProximityKit plan step A1.3):** ProximityKit is a package of its own, consumed at exactly
`0.1.0` from [bowman-mw/proximitykit](https://github.com/bowman-mw/proximitykit), so the 108 sections that
indexed its sources (its engine, mesh and routed mesh, transport and ranging, namespace and gate, identity,
wire, trust and audit, pair session, hearts mechanism, presence engine and shared support) left this index
with them: its repository documents them, through its DocC landing page
(`Sources/ProximityKit/Documentation.docc/ProximityKit.md`) and its doc comments, and its own tests hold
them. This index keeps what this repository holds over it: Fernlet's namespace and its supply
(FernletConnections), the app's and FernletSocial's features, the review screens and the test target's
bindings. A ProximityKit name below (`MeshNetworkManager`, `IdentityService`, `ProximityPairSession`, …) is
its public API at that tag.

> **Dangling reference, do not go looking:** twenty source files and test suites in this subsystem
> cite `Docs/Proximity-Mesh-Redesign-2026-07-10.md` for the phase numbering ("Phase 2 friend
> minting", "Phase 5", …). **That document does not exist in this tree.** The phase numbers are still
> meaningful as labels and are used consistently, and
> [Proximity-Security-Followups-2026-08-18.md](Proximity-Security-Followups-2026-08-18.md) stands in
> for the two items it still owed. This index is the surviving map of what those phases built.


## Duplication Hotspots

| Need | Prefer Reusing |
| --- | --- |
| Signed peer-to-peer payloads | `ProximityIdentityEnvelope.signed(...)`, `ProximityIdentityEnvelope.verify(...)`, `canonicalBytes(for:in:)` |
| Canonical bytes for anything signed | `CanonicalSignatureSerializer` (ProximityKit/Wire) — `canonicalBytes(for:in:)` is overloaded for the identity envelope, the mesh admission token, the membership records and messages, the removal quorum, the key advertisement, the channel introduction and the six routed transcripts, each behind its own domain tag from the `in purposes:` it is handed (ProximityKit plan step A0.2); The three Group-Activity types' and the moderation row's `canonicalBytes(for:)` are FernletSocial's (`Wire/FeatureCanonicalBytes.swift`), written with the same public `CanonicalByteWriter` under FernletCrypto's tags. Never hand-roll a signing input and never reach for `JSONEncoder(.sortedKeys)`: that is the pre-WI-6 encoder, kept only as `legacyCanonicalBytes(for:)` to *verify* envelopes minted by peers that predate the change, and never to sign. |
| Wire strings that look like display strings | KEEP THEM ENGLISH. `PayloadSummary.title`/`subtitle`/`extraDetails` are written into the canonical signing bytes by `CanonicalSignatureSerializer.appendCanonical(_:_:)` **and** rendered in the RECEIVER's Connection Inspector — see the localization row below and the doc comment on `ProximityIdentityEnvelope.payloadSummary`. |
| A device-local sidecar file's location | FernletSocial's `JSONSidecarFile.fileURL(in:name:)` (internal: every store that persists through it is that module's) against the owner's `ProximityHost.proximitySupportDirectory` (or, for FernletSocial's sealed heart-drop files, their `HeartDropStorageScope`). There is deliberately **no** argument-less default — see the `FernletSocial/Support/JSONSidecarFile.swift` section for why re-adding one would be a regression. |
| Pairwise sealed payloads | `IdentityService.seal(_:to:)`, `IdentityService.open(_:from:)`, `ProximityCoordinator.sendPayload(payloadTypeToken:summary:payload:sealed:)` (the coordinator's public token send; a pairing's sealed send to its confirmed peer), `MeshNetworkManager.sendEnvelope(...)`. 2026-08 consolidation: MeshNetworkManager's two duplicated seal+sign+send builders were consolidated into the private `sendEnvelopeCore(_:encodable:sealTo:fingerprint:via:auditSendFailure:)`; keep calling `sendEnvelope(_:encodable:via:sealed:)` (one of the mesh's own frames, by `MeshPayloadRole`), `sendFeatureEnvelope(_:encodable:via:sealed:)` (a host feature's payload, under the token it passes: Fernlet's FernletSocial features pass their `PayloadType` raw values) / `sendVerifyEnvelope(_:encodable:toKeyAgreementKey:fingerprint:supportsWire2:via:)`, which are thin wrappers over it. |
| Mesh group-key wrapping | `IdentityService.encryptGroupKey(_:for:)`, `IdentityService.decryptGroupKey(_:)`, `MeshNetworkManager.initiateRotation(cause:)` |
| A pairwise secret for one of the host's features (the key its rotating tags or drops stand on) | `IdentityService.pairSecret(with:purpose:)` under a `ProximityCryptographicPurpose.featureKeyDerivationSalt(_:)` the host's namespace declares (`ProximityNamespace.FeaturePurposes`; Fernlet's two are `FernletFeaturePurposes`, in FernletConnections). Never re-roll the X25519 → HKDF chain beside it and never derive under a protocol salt: the door refuses any purpose its namespace does not declare (`IdentityError.undeclaredPurpose`), so every salt it derives under was judged by the namespace's soundness verdict. |
| Refusing to act under an unsound namespace, or under an identity of another namespace | `ProximityNamespaceGate.refuseUnsound(_:event:at:)` (reads the namespace's stored `soundness` verdict, writes a named audit line, throws `ProximityNamespaceError`), `checkIdentity(_:isOf:event:)` and `mayStart(identityIsOfNamespace:event:)`. Never re-run a soundness rule at a new door: hold the verdict beside the values you read off the namespace and hand it to the gate. |
| Per-recipient routed content-key wrap | `MeshRoutedContentKeyWrapper.wrap/unwrap/additionalData` (P5 item 1) — the routed sibling of `encryptGroupKey`: the same X25519 → HKDF → AES-GCM chain under the routed purposes with a manifest-binding AAD. Never re-roll the chain (item 10, P6) and never reuse the group-key purposes for it. |
| Splitting or reassembling routed content | `MeshChunker.chunk(of:at:for:identity:)` / `.chunks(of:for:identity:)` and `MeshChunkAssembly` (P5 item 2) — the ONE chunking transport. Chunks are ordinary reliable frames that earn a QUIC transfer stream by size alone (`MeshTransferStreamTable.route(reliableByteCount:)`); do not build a second chunking path, a transfer id, a resume token or an application-visible ack. |
| Hashing routed content | `MeshRoutedContentDigest.contentHash(of:in:)` (the whole sealed blob) / `.chunkHash(of:in:)` (one slice) / `.chunkID(itemID:chunkIndex:in:)` (P5 item 2; the caller's namespace labels since ProximityKit plan step A0.2.6). Never a bare `SHA256.hash` for routed bytes: each digest carries its own `Hash` purpose, which is what stops a one-chunk item's chunk hash being replayable as its item hash. |
| Durable sidecar state (data of record) | `ProtectedSidecar` — classifies absent / deferred / corrupt / loaded and keeps memory authoritative on write failure. Do NOT use `JSONSidecarFile` for data of record: it collapses every read failure to `nil`. |
| Sealing a payload to a peer, with framing | `IdentityService.seal(_:to:)` + `SealedPayloadFormat` (capability-derived, never inferred from bytes) |
| Verifying a human holds a key | `ProximityVerifyQR` + `ProximityVerifySignature.message(...)` — shared transcript, so the friend and coach ceremonies cannot diverge |
| Coach-channel trust | `CoachSessionTrustPolicy` / `CoachSessionContract` (both in `FernletConnections`) — never `FriendSessionTrustPolicy`, whose `isTrustedProximityPeer` returns `true` unconditionally and reads the friend vault |
| Proximity commit gates | `ProximityCommitDetector.ingest(distanceMeters:at:)`, `ProximityCoordinator.commitManualProximity()` (public: the programmatic commit a host's pairing takes with no user step) |
| Whether a heart from or to a peer may be recorded | `FernletSocialHost.isTrustedUnblockedPeer(signingPublicKey:fingerprint:)` (FernletSocial's `FernletSocialHost.swift`): the one heart-eligibility predicate, which presence's gate delegates to and the session hearts' ledger judge (`MeshSessionHearts`) asks. Never re-implement its three legs. |
| Friend mesh lifecycle | `MeshNetworkManager.startJoin()`, `stopJoin()`, `leaveSession()`, `leaveSessionAfterNotifyingPeers()`. 2026-08 consolidation: the three duplicated pending-connection expiry idioms were consolidated into one `registerPendingConnection(_:)` on the MultipeerConnectivity radio — that consolidation retired with the radio in the deletion round (2026-09-22); the QUIC radio's equivalent is `MeshLinkTable`'s dial bookings — and the hand-rolled `withObservationTracking` re-arm loops in the mesh/recipe/presence managers were consolidated into `ObservationLoop.start(on:tracking:onChange:)` (ProximityKit/Engine/ObservationLoop.swift). Local advertised names come from `ProximityHost.resolvedProximityDisplayName` (ProximityKit/PeerDisplayNames.swift), which replaced the three identical private `displayName` vars. |
| Mesh membership/admission | `MeshNetworkManager.allowAdmission(_:)`, `declineAdmission(_:)`, `handleAdmissionRequest(_:)`, `handleAdmissionGrant(_:)`. 2026-08 consolidation: the twin mesh-admission and activity-join confirmation sheets were consolidated into the shared generic `JoinPromptSheet` (App/Fernlet/JoinPromptSheet.swift, app target), and receive-side peer-name moderation goes through `ProximityDisplayName.peerDisplayName(_:in:)`, under the manager's namespace's peer-name policy. |
| Mesh removal | Legacy two-party: `proposeRemoval(of:)`, `canSecondRemoval(_:)`, `secondRemoval(_:)`, `applyApprovedRemoval(_:)`. Signed quorum (P4 item 5, §10.4): `proposeSignedRemoval(of:now:)`, `voteOnSignedRemoval(_:now:)`, `evaluateRemovalQuorum(_:now:)`, `MeshRemovalQuorum` |
| Friend photos | FernletSocial's `MeshSessionPhotos`: `addPhoto(_:)`, `holdSessionPhoto(_:key:live:)` (2026-09-30: every session photo is HELD in the sealed pending corpus until the person's answer; `cachePhoto` is gone), `applyPhotoAnswers(kept:discarded:now:)`, `deletePhoto(_:)`, and the private `shareRoutedPhoto(itemID:addedAt:imageData:session:)` → `MeshNetworkManager.originateRoutedItem(body:typeToken:itemID:audience:now:)` (P5 item 13 replaced `syncPhotoManifest(to:)`'s pull protocol with the routed store), over `PrivateMediaStore`. 2026-08 consolidation: the three duplicated photo-save catch-ladders and alert blocks were consolidated into `FriendPhotoLibrarySaver.userFacingFailure(for:photoCount:)` + the `photoSaveFailureAlert(_:failure:)` view extension (FernletProximityUI); the media stores' hand-rolled AES-GCM seal/open now routes through the shared extension on `PrivateMediaKeyProviding` (PrivateMediaStore's `MediaAtRestCrypto.swift`); JSON sidecar state — including the photo-wall preferences store — was consolidated into `JSONSidecarFile` (`FernletSocial/Support/JSONSidecarFile.swift`). |
| Recipe sharing | FernletSocial's `ProximityRecipeShareManager.start()`, `sendRecipeShare(_:to:)`, `proximityCoordinator(_:didReceive:plaintext:from:)` over ProximityKit's `ProximityPairSession` (`start()`, `send(_:to:)`); the radio's pause/resume contract and the share's state machine are `ProximityPairDiscoveryGate` / `ProximityPairTransfer` (PairSession/ProximityPairTransfer.swift) |
| Audit/diagnostics | `ConnectionInspector`, `ConnectionSessionLog`, `ProximitySessionAudit` (what a coordinator records through its trust policy) → `TrainerAuditEvent` (Fernlet's persisted row, converted by `FernletConnections`' `TrainerAuditEvent.init(_:)`), `ProximityRecipeShareDiagnostics` |
| Lowercase hex for a handful of bytes | `String(format: "%02x", $0)` — the idiom in the five places that already do it (`MeshEpochRef.swift`, `IdentityService.swift` ×2, and FernletSocial's `HeartDropPeerBundleCache.swift` and `IdentityService+HeartDrop.swift`). **Known, deliberate exception:** `PresenceEpochPosture.hexadecimal(_:)` re-implements it privately. Two reasons it stays forked: it encodes the advertised instance name on the main actor at every epoch and `String(format:)` boxes each byte as a `CVarArg` to do it; and the value is held to a whole-FILE grep wall in `PresenceEpochPostureTests` (no second 900, no clock, no device byte, `import Foundation` and nothing else), which only means anything while every byte of the name's construction is visible in that one file. Do not consolidate it away without moving that wall. |
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

The membership records added for plan §8.1 are the same rule one layer down: a record kind's token
(the host namespace's `vocabulary.membershipRecordKinds`; Fernlet's are `fernlet.mesh.member-admission.v1`
and its three siblings, its `PayloadType` tokens) is a wire byte the inventory digest hashes, so it is
frozen English and has no display half at all — nothing shows a record kind to a person.

The rule is enforced mechanically by `Tests/FernletTests/LocalizationBoundaryTests.swift` (the
localization wall — sibling of the S3, no-tracking and Power-of-10 walls), which pins the frozen raw
values case by case and grep-walls `String(localized:)` inside `FernletKit/Sources` for the
`bundle: .module` argument a package needs. Every failure it guards is silent: a localized token does
not crash, it just stops matching itself in a language nobody on the team reads.

## Mesh

### `NetworkMeshFeasibilityProbe.swift` (DEBUG-only)

| Function/Surface | What It Does |
| --- | --- |
| `NetworkMeshFeasibilityProbe.start()` | Explicitly starts the DEBUG Network.framework probe; Simulator uses infrastructure networking, while physical devices retain the peer-to-peer/continued-processing gate. It never starts a real mesh. |
| `NetworkMeshFeasibilityProbe.stop()` | Idempotently closes discovery, QUIC connections, and the test continued task. |
| `MeshProbeChannelIntroduction` | Signs a transcript bound to the active TLS exporter, mesh ID, epoch, identities, and nonces. |
| `NetworkMeshFeasibilityProbeView` | DEBUG Settings UI for observing bounded probe events and validation results. |

## Transport And Ranging

### `App/Fernlet/ProximityLiveActivityReaper.swift` (the app)

Moved from ProximityKit's foreground anchor at plan step A0.6.4, unchanged in behaviour; app target
only, outside the widget's dual-membership set.

| Function | What It Does |
| --- | --- |
| `ProximityLiveActivityReaper.endOrphans()` | Ends every proximity Live Activity a killed previous process stranded, with the content `Ended`, no stale date and `.immediate` dismissal. Called once per launch from `FernletStoreLoader.startIfNeeded()`, before any proximity manager can exist; the only remaining reader of the proximity attributes type. Its `end` call takes no transfer local in the app target. |
| `ProximityConnectionActivityAttributes` | The proximity Live Activity's attributes (`peerName`, `startedAt`; a `ContentState` of `bytesSent`, `bytesReceived` and `status`), kept only for the reaper's enumeration. ActivityKit matches a stranded activity to it by unqualified type name and decodes it against this stored shape, so neither may change. |

## Protocol Namespace

The host-supplied protocol identity, under `ProximityKit/Namespace/` (plan steps A0.2 and A0.3):
ProximityKit reads its 39 protocol labels, radio values, QR scheme, identity and mesh seal-key rows,
storage names and log subsystem off it, byte-identical for Fernlet, and every group of the payload
vocabulary its family carries, the radios' presentation strings and the installation's peer-name policy,
all judged by its soundness rules, and so are the feature salts the host declares in its family
(`FeaturePurposes`), the only salts `IdentityService.pairSecret(with:purpose:)` derives under. The
features' payload and capability tokens are their own — Fernlet's `PayloadType` and
`ProximityCapability` cases, which FernletSocial's features register, send and gate by — and so are
their labels: the activities', the moderation report's and the heart dead-drop's are FernletSocial's and
the sealed-backup escrow's two the app's, with its escrow; the heart dead-drop's keychain service and
the moderation ban store's are FernletSocial's too. ProximityKit refuses an unsound namespace at run
time (`Support/ProximityNamespaceGate.swift`, below). The host hands it in
(`ProximityHost.proximityNamespace`) beside its install binding and audit sink; the column seal and the
keychain mechanism are ProximityKit's own copies. ProximityKit holds no instance and offers no default.
`ProximityNamespaceSoundnessTests` (in ProximityKit's package test target, with its five framing byte
pins over a literal namespace) covers every rule below; `ProximityNamespaceGoldenTests` and
`ProximityVocabularyGoldenTests` pin Fernlet's value and every reader, and `FernletFeatureGoldenTests`
the bytes of Fernlet's features over ProximityKit, in `FernletSocial`, in the app and in ProximityKit;
`ProximityNamespaceBoundaryTests` (in ProximityKit's package test target since A1.1.7, reading its
sources through `PackageRoot`) keeps any namespace, group or purpose from being built outside
`Namespace/`, `FernletCryptoPurpose` out of ProximityKit's code altogether, any `fernlet` literal to an
allowlist naming its exit step, which is empty (its DEBUG launch-environment keys are its own,
`PROXIMITYKIT_*`, since plan step A1.0), Fernlet's domain
vocabulary and records (`PayloadType`, `ProximityCapability`, `ProximityMode`, `ItemNameModeration` and
the persisted proximity records) out of its code, its list of lines empty (the coordinator's session
mode is ProximityKit's own `ProximitySessionMode`, and Fernlet's typed view of the envelope's token
is FernletConnections'), `package` out of its code, its list empty (the presence radio's doors closed
behind its public presence engine at A1.1), and every
type that left ProximityKit for `FernletSocial` or the app out of it (the recipe share's among them),
with the recipe share's three public values it renamed for the one-to-one send and the nine recipe-named types of the pair
session's mechanism renamed with pair names at plan step A1.0: none is declared, extended or aliased there again, and the
namespace's pair-session radio's old name, `recipeShare` (now `pair`), is named nowhere in its code. It holds ProximityKit's target to no dependency at all too (a literal `dependencies: []`, plan step
A1.0): its identity signs and verifies only under its own `ProximityCryptographicPurpose`, a host's
own signature labels minted with `featureSignature(_:framing:)`.
The exact per-file lists in `ProximityNamespaceBoundaryTests` are the one place those numbers live.

### `FernletConnections/FernletProtocolNamespace.swift`

Fernlet's own value, in the `FernletConnections` module, which depends on ProximityKit so ProximityKit
can never name it. The app supplies it as its `ProximityHost.proximityNamespace` and builds every
`IdentityService` from it. `ProximityNamespaceGoldenTests` pins every literal against its frozen
column, every role, soundness and the 40 FernletCrypto twins (38 protocol labels and the two feature
salts).

| Function | What It Does |
| --- | --- |
| `ProximityNamespace.fernlet` | Fernlet's whole protocol identity: `Family.fernlet` with `Installation.fernletApp`. |
| `Family.fernlet`, `Purposes.fernlet`, `Signature.fernlet`, `KeyDerivation.fernlet`, `AEAD.fernlet`, `Hash.fernlet`, `Radios.fernlet` | Fernlet's labels, radio values and `fernlet` QR scheme by group, byte for byte as they shipped, the legacy pair accepted; `Purposes.fernlet` also declares the two feature salts (`feature: .fernlet`, below), `Family.fernlet` carries `Vocabulary.fernlet`, and `Radios.fernlet` the presentation strings `fernlet-mesh-`, `fn-` and `fernlet-mesh`. |
| `Installation.fernletApp` | The Fernlet app's identity and seal-key rows, storage names, log subsystem and peer-name policy. Coach adds an installation of its own beside it in plan step C1. |
| `PeerNames.fernlet` | How the Fernlet app shows a peer's name: at most 24 characters (`ItemNameModeration.maxNameLength`, the cap Fernlet's item names share, read rather than respelled) and the floor "A friend"; `ProximityVocabularyGoldenTests` pins both. |

### `FernletConnections/FernletFeaturePurposes.swift`

Fernlet's feature labels that a ProximityKit door consumes: the two pair-secret salts, one spelling per
label on Fernlet's side. `ProximityNamespaceGoldenTests` holds each declared salt to its frozen literal
and its FernletCrypto twin; `FernletFeatureGoldenTests` pins the door's pair secrets under them.

| Function | What It Does |
| --- | --- |
| `FernletFeaturePurposes.heartDropPairV1`, `.presencePairV1` | The heart dead-drop's and presence's pair-secret salts, `fernlet.heartdrop.v1` and `fernlet.presence.tag.v1`, each minted with `featureKeyDerivationSalt(_:)`: the purposes a caller of `IdentityService.pairSecret(with:purpose:)` passes. Twins of FernletCrypto's `KeyDerivation.heartDropPairV1` and `.presencePairV1`. FernletSocial's `heartDropPairSecret(with:)` passes `heartDropPairV1` and its `presencePairSecret(with:)` `presencePairV1`, each through the door; no code reads either twin. |
| `ProximityNamespace.FeaturePurposes.fernlet` | `.fernlet`'s feature group: the two salts above, in that order, as `heartDropPairV1` and `presencePairV1`, judged in `.fernlet`'s one soundness verdict with the 39 protocol labels. |

### `FernletConnections/FernletPayloadVocabulary.swift`

Fernlet's payload vocabulary, which `Family.fernlet` carries. Payload and capability tokens, the
record kinds and the mesh messages are read off FernletDomainModel's `PayloadType` and
`ProximityCapability`, so each keeps one spelling; the routed types and the session titles are spelled
here alone. ProximityKit reads every group off the namespace.
`ProximityVocabularyGoldenTests` pins every value against its frozen column.

| Function | What It Does |
| --- | --- |
| `Vocabulary.fernlet` | The six groups below, each `.fernlet`. |
| `SessionMessages.fernlet` | The introduction ("Hello"), the acknowledgement ("Identity acknowledged") and the heartbeat ("Heartbeat", answered "Heartbeat ack"), under their `PayloadType` tokens. |
| `PayloadRules.fernlet` | Every `PayloadType` token, and the seventeen whose payload must arrive sealed. |
| `Capabilities.fernlet` | Every `ProximityCapability` token in declaration order, `wire2`, and photos alone for a legacy peer. |
| `MembershipRecordKinds.fernlet`, `RoutedTypes.fernlet` | The four record kinds, each the `PayloadType` token of the frame that carries its record, and the four routed-type tokens, which FernletSocial's `FernletRoutedTypes` builds Fernlet's routed-type rows over (ProximityKit holds them to its soundness rules). |
| `MeshMessages.fernlet` | The mesh engine's thirty messages, each the `PayloadType` token Fernlet's mesh signs and dispatches that frame under; fifteen of them also spell a signature label, and four are the record kinds above. |

### The supply path

How the value reaches ProximityKit: through the host seam, read once per manager, with no default
anywhere. `ProximityNamespaceGoldenTests` pins the identity's keychain read and the namespace
overloads of `sign` and `verify`.

| Function | What It Does |
| --- | --- |
| `ProximityHost.proximityNamespace` | The host's protocol identity: like `proximityInstallBinding`, `makeProximityTrustPolicy()`, `makeProximityRangingProvider()`, `makeProximityIdentity()`, `meshRoutedTypeEntries`, `proximityFallbackDisplayName` and `proximitySupportDirectory`, a requirement the protocol extension **never defaults** (`ProximityHost.swift`'s header names them), so a host that supplies none fails to compile instead of running under another app's identity. |
| `FernletStore.proximityNamespace` (`App/Fernlet/ProximityHostAdapter.swift`) | `nonisolated`, answering `ProximityNamespace.fernlet` (`FernletConnections`): inert value data the store's nonisolated scope properties can read. |
| `MeshNetworkManager.namespace` / `PresenceManager.namespace` / `ProximityPairSession.namespace` | `@ObservationIgnored nonisolated let`, read once from the host in `init`; each builds its radio from it, the presence manager through its engine, `ProximityPresenceSession(namespace:)` (the pair session with its profile, which it checks against it), and the identity each holds by default is its host's `makeProximityIdentity()`, checked against it. |
| `IdentityService.init(namespace:keychainService:provisioningParticipant:)` | The identity's namespace, keychain service and provisioning participant — see `IdentityService.swift` below. Every shipping construction is the app's factory `IdentityService.fernletApp(keychainService:)` (`App/Fernlet/SealedBackupEscrowKey.swift`): ProximityKit builds none, its host door having no default; every app construction uses the factory (`HeartDropService`'s identity has no default, and `FernletStore` passes the factory's), and the store's `makeProximityIdentity()` answers it for the three managers. `KeyCustodyBoundaryTests.everyShippingIdentityIsBuiltByItsHostsDoor` holds every construction in Fernlet's code to that file, and `theStoresManagersHoldIdentitiesCarryingTheEscrowKey` the managers' identities to its escrow key; ProximityKit's own `ProximitySourceWallTests.proximityKitBuildsNoIdentityOfItsOwn` holds its code to none (since A1.1.17). |

### Signed transcripts

Every signed transcript reads its label off the namespace: the identity envelope, the admission
token, the membership records and messages, the removal quorum, the key advertisement, the QUIC
channel introduction, the six routed transcripts and the verify QR, the legacy pair included. Each
reader takes the purposes it already holds: a builder its signing identity's `purposes`, the
envelope's `verify` its `identityService`'s, a verifier its own copy, the manager its stored
`namespace.family.purposes`; the QR's scheme and labels come from the signing identity's namespace
or the caller's, and `CoachVerificationCeremony` and the app's duress flow scan and answer under their
identity's. `ProximityNamespaceGoldenTests` holds each reader to the namespace it is handed (groups 9
and 10).

| Function | What It Does |
| --- | --- |
| `canonicalBytes(for:in:)` (17 types) / `canonicalInventoryDigestBytes(for:in:)` | The serializer's domain from `in purposes:`; see `CanonicalSignatureSerializer.swift` below. The four activity and moderation domains are FernletSocial's (`Wire/FeatureCanonicalBytes.swift`), still under FernletCrypto's tags. |
| `MeshMembershipRecordVerifier.init(...family:)` / `MeshLedgerAdoption.bootstrapVerifier(...in:)` / `adopt(...in:)` / `MeshInventoryDigest.init(meshID:ledger:family:)` / `MeshAdmissionToken.verify(...in:)` | The membership verifiers and helpers that take the labels, each with no default (the first four take the whole family, whose record kinds the inventory digest also needs). The legacy pair is the family's choice: a family with `LegacyV1.refused` verifies no schema-v1 envelope and no pre-WI-6 token. |
| `MeshRoutedManifestVerifier` / `MeshChunkVerifier` / `MeshCustodyReceiptVerifier` / `MeshRecipientReceiptVerifier` / `MeshRoutedInventoryVerifier` / `MeshRoutedDrainAnswerVerifier` / `MeshChannelIntroductionExchange` `init(...purposes:)` | Each keeps its copy of the labels as a trailing `purposes:` with no default and checks every signature (and frames the introduction transcript) under it. |
| `ProximityVerifyQR.parse(_:in:)` / `isValid(_:at:in:)` / `ProximityVerifySignature.message(...in:)` | The QR's scheme and labels from the caller's namespace; see `ProximityVerification.swift` below. The QR host `verify`, the query key `d` and version 1 stay ProximityKit format constants. |

### Hashes, seals, salts and the epoch

The routed hash and id domains, the five AEAD labels, the three HKDF salts and the epoch id's domain
read the namespace. Stateless helpers take a trailing `in purposes:` with no default, the three ids
that hash a label are functions (a decoded value carries no namespace), `MeshChunkVerifier`
re-derives the chunk hash under its own copy, and `IdentityService` reads its own `purposes`. The
manager hands every reader it calls its stored `namespace.family.purposes`; the chunker, the
manifest's wraps and the delivery seam their identity's; the routed store its scope's (see "At rest"
below). `ProximityNamespaceGoldenTests` holds each reader to the namespace it is handed (group 11).

| Function | What It Does |
| --- | --- |
| `MeshRoutedContentDigest.contentHash(of:in:)` / `chunkHash(of:in:)` / `chunkID(itemID:chunkIndex:in:)` / `MeshRoutedContentHasher.init(purposes:)` | The routed digests under `purposes.hash`; see `MeshChunk.swift` and `MeshRoutedContentHasher.swift`. |
| `MeshChunk.chunkID(in:)` / `MeshCustodyReceipt.receiptID(in:)` / `MeshRecipientReceipt.receiptID(in:)` | The three derived ids, functions because a decoded value carries no namespace (`Codable` stays namespace-free). |
| `MeshChunkAssembly.admit(_:in:)` / `completion(against:in:)` | The in-memory reassembler's two hashing verbs. |
| `MeshRoutedItemSealer.seal/open/additionalData(...in:)` / `MeshRoutedContentKeyWrapper.wrap/unwrap/additionalData(...in:)` | The routed seals; the item seal reads `purposes.aead.meshRoutedItemV1`, the wrap `purposes.keyDerivation.meshRoutedContentKeyWrapV1` and `purposes.aead.meshRoutedContentKeyWrapV1`. |
| `MeshEpochRef.minted(...in:)` / `successor(...in:)` / `MeshRotationPolicy.plan(...in:)` | Every epoch id derived under `purposes.hash.meshEpochIDV1`, raw; parsing and decoding an epoch derive nothing. |
| `IdentityService.seal(_:to:format:)` / `open(_:from:format:)` / `encryptGroupKey(_:for:)` / `decryptGroupKey(_:)` | Their salts and AEAD labels come from the identity's `purposes`. |

### The radios

The three radios read their service types, ALPNs, the mesh heartbeat, the TLS exporter label, the
log subsystem and the namespace's soundness verdict off the namespace their manager builds them from,
once, in `init(namespace:)` (the recipe radio in `init(namespace:profile:)`, its service type, ALPN and TXT
mode off its pair profile, which its session checked against that namespace); each `start` refuses an unsound namespace by that verdict. The mesh
radio also keeps a copy of `family.purposes`, under which every channel introduction exchange it
starts frames this side's transcript and checks the peer's, so the manager that signs a tunnel's
introduction and the radio that checks the peer's read one namespace. `ProximityNamespaceGoldenTests`
holds each radio to the namespace it is built from (group 12).

| Function | What It Does |
| --- | --- |
| `NetworkMeshSession.init(namespace:)` | Keeps `serviceType`, `alpn`, `heartbeatDatagram`, `tlsExporterLabel`, `purposes` and `namespaceSoundness` as `nonisolated let`s and a private instance `Logger` (`proximity.transport.quic`); `connectionParameters()` and `listenerParameters(identity:)` are instance methods reading the instance ALPN. |
| `NetworkMeshSession.channelBindingHash(for:exporterLabel:)` | SHA-256 of the connection's TLS exporter secret under the label it is handed, whole (role `.tlsExporterLabel`); its one caller hands it the radio's `tlsExporterLabel`. |
| `NetworkPresenceSession.init(namespace:)` / `NetworkPairSession.init(namespace:profile:)` | Keep `serviceType` and `alpn` from `family.radios.presence` / the profile's `radio` (Fernlet's recipe profile: `family.radios.pair`), the recipe radio also the profile's `advertisementMode`, `namespaceSoundness`, and a private instance `Logger`. |
| `NetworkMeshSession.start(discoveryInfo:)` / `NetworkPresenceSession.start(posture:discoveryInfo:)` / `NetworkPairSession.start(advertisement:)` | Refuse first under an unsound namespace: `ProximityNamespaceGate.refuseUnsound(namespaceSoundness, …, at: .start)` throws and audits `mesh.quic.namespaceUnsound` / `presence.quic.namespaceUnsound` / `recipe.quic.namespaceUnsound` before anything is minted, listened on or advertised. |
| `MeshNetworkManager.init` / `ProximityPairSession.init` / `ProximityPresenceSession.makeRadio` | Build their radio from the stored `namespace` (the pair session with its profile); the presence engine's `makeRadio` is set in its `init`, a closure capturing the `Sendable` value. |

### At rest: names, rows and scopes

The two storage scopes carry the host's namespace and install binding, and the stores, the seal-key
helpers, the host's default scopes and the identity read their names and rows off the namespace: the
mesh stores' file names, chunk directory and seal-key accounts, the production seal-key services and
the identity's four accounts. Since plan step A0.6.6 the root is the host's to state, with no
default; the namespace names only the folder (`installation.storage.directory(under:)`). The routed
store measures under its scope's labels. `ProximityNamespaceGoldenTests` holds each reader to the
namespace it is handed (group 13).

| Function | What It Does |
| --- | --- |
| `MeshSessionStorageScope` / `MeshRoutedStorageScope` `namespace`, `installBinding`, `init(namespace:directory:keychainService:installBinding:)`, `production(for:directory:installBinding:)` | The scopes with the host's namespace and binding; `production(for:directory:installBinding:)` is the namespace's seal-key service on the root its host states (since plan step A0.6, which took the root out of the namespace), the one-line answer for a host with one installation (FernletSocial's `keychainService(besideHeartDrop:in:)` extensions map the production heart-drop service to its service). No longer `Equatable`, since a capability has no equality. The two isolation walls refuse every production spelling in tests, the shorthand `.production(for:directory:installBinding:)` included. |
| `MeshSessionSealKey` / `MeshRoutedSealKey` `forOpen(service:account:)` / `forSeal(service:account:)` | The seal-key reads under the scope namespace's account. |
| `MeshSessionStore.fileName` / `sealKeyAccount`, `MeshRoutedStore.indexFileName` / `chunkDirectoryName` / `sealKeyAccount` | Instance reads of the scope's namespace. |
| `MeshRoutedStore.stagingChunk(_:now:)` / `committingCustody(item:custodian:now:)` / `assembledBlob(item:expecting:)` | Measure under `scope.namespace.family.purposes`: a store holds one source of its labels. |
| `ProximityHost.meshSessionStorage` / `meshRoutedStorage` (extension defaults) | Built from the root the host states (`proximitySupportDirectory`, a requirement with no default since plan step A0.6.6), `proximityNamespace` and `proximityInstallBinding`: the namespace's production scopes on that root, whatever it is (the service named after a host's own root, and the default root itself, left at A0.6.6). A host that keeps more than one installation's files in one process, or a test double on a root of its own that opens a store, states both scopes itself; `MeshRoutedStoreIsolationTests`' scratch-root needle holds every Fernlet test double that states its root to that, and `PackageTestTreeWallTests`' the package tests' `PackageTestHost`. |
| `IdentityService.accounts` / `classifyDeviceIdentityRows(signing:keyAgreement:accounts:)` | The four device rows' accounts, the namespace's `installation.keychain.identity`, under the identity's `keychainService`. |
| `FernletStore.proximityInstallBinding` / `meshSessionStorage` / `meshRoutedStorage` (app) | The adapter answers the host requirement; both scopes pass `namespace: proximityNamespace`, `installBinding: proximityInstallBinding` and derive the service `besideHeartDrop: heartDropKeychainService, in: proximityNamespace`; the store's proximity root defaults to `FernletConnections`' `FernletProximityStorage.productionDirectory`, `.fernlet`'s folder under Application Support (the path it has always used), as does `CryptoFormatCensus.Inputs.production`. |

### The column seal and the install binding

The two sealed mesh stores seal through `ProximityColumnCrypto`, FernletCrypto's `ColumnCrypto` V3
seal copied into ProximityKit byte for byte, under their scope namespace's two column-seal labels and
the install binding their scope carries, which the host injects. They catch the retryable
`ProximityInstallBindingReadError`; neither store nor either scope file imports FernletCrypto.
`ProximityNamespaceGoldenTests` group 14 runs the A0.2.0 column vectors through the copy, opens each
implementation's blobs with the other, compares their refusals pairing by pairing, and holds each
store to its scope's label and binding.

| Function | What It Does |
| --- | --- |
| `ProximityColumnCrypto(purpose:installBinding:)` (`Support/ProximityColumnCrypto.swift`, internal) | The V3 column seal under one `.columnSeal` label and one install binding. `nonisolated`, `Sendable`; stores neither key nor binding. |
| `ProximityColumnCrypto.seal(_:contentKey:)` / `open(_:contentKey:)` | The `Codable` pair the stores use: `JSONEncoder()` output sealed as `0x03` ‖ nonce ‖ ciphertext ‖ tag under the salt-free HKDF-SHA256 column key, `label ‖ binding` as AAD; the open classifies the marker before it reads the binding. |
| `ProximityColumnCrypto.SealedColumnOpenError` / `SealedColumnStrictSealError` / `StoredFormat` | The original's three named open refusals (`retiredFormat`, `emptyBlob`, `installBindingMissing`), its one seal refusal (`bindingUnavailable`) and its marker classifier, without the census helpers. |
| `ProximityColumnCrypto.deriveColumnKey(contentKey:purpose:outputByteCount:)` | The column-key derivation, internal so the golden can pin its known answers. No `deriveColumnKey(info:)`, no `init(label:)`. |
| `ProximityInstallBinding.read(for:)` (`Support/ProximityInstallBinding.swift`) | The host's per-install binding, one synchronous read. `.seal` may mint and answers nil without a durable binding (the seal refuses); `.open` never mints, answers nil only for an absent binding (the open refuses), and throws `ProximityInstallBindingReadError` for a failed read (the open defers). |
| `ProximityInstallBindingReadError(status:)` | The retryable read failure, mirroring `DeviceBindingID.ReadError`'s `status`. |
| `MeshSessionStore` / `MeshRoutedStore` `crypto` (private) | `ProximityColumnCrypto` over `scope.namespace.family.purposes.keyDerivation.meshSessionContextV1` / `.meshRoutedStoreV1` and `scope.installBinding`, built per use like the name reads. |
| `ProximityHost.proximityInstallBinding` | The host's binding, with no default, like `proximityNamespace`; the extension's default scopes carry it. |
| `FernletDeviceBindingAdapter` (`FernletConnections/FernletDeviceBindingAdapter.swift`) | Fernlet's binding: delegates to `DeviceBindingID` at each call (`current()` for `.seal`, `currentForOpen()` for `.open`, `ReadError` translated with its status), so the row, the cache and the task-local test seam stay FernletCrypto's one. |

### The keychain mechanism

FernletFoundation's `KeychainItem` mechanism is copied into ProximityKit member for member as
`ProximityKeychainItem` (`Support/ProximityKeychainItem.swift`, internal, `nonisolated`), and the 18
references in the three key-store files (the identity's rows and the two mesh seal keys) call it;
FernletSocial's stores (the moderation ban store, the heart-drop prekey blob and sidecar seal key) and
the app's sealed-backup escrow (`SealedBackupEscrowKey`) call FernletFoundation's `KeychainItem`
themselves. The stores here call the absence-distinguishing reads, `store` under its default scopes
and the whole-service deletes; the nil-collapsing `load`, the enumerations, the `.synced` / `.local`
scopes and a narrow `replacing:` have no caller here and stay member for member. Only the mechanism came
across; Fernlet's `Account` names, typed overloads, service constants, `loadOrCreateSymmetricKey`
and `updateReportingStatus` stayed behind. Every query is FernletFoundation's for the same call, so
rows written before the copy read back unchanged and a host's own `KeychainItem` still reads and
clears these services. Reach the keychain from ProximityKit through this type, never
`KeychainItem`: `ProximityNamespaceGoldenTests` group 15 fails on ProximityKit code that names it,
holds every query dictionary to the one FernletFoundation's source spells, and checks that the two
read, list and delete each other's rows and fail and audit alike. Since plan step A1.1 every member
reaches the keychain through one backend, handed the dictionary its builder spelled: the system
keychain in every shipping build, and, in a Debug build, whatever ProximityKit's own package tests
installed (an in-memory store, their unhosted bundle having no keychain it may use). ProximityKit's own
package tests (`ProximityKeychainDoorTests`) hold the install door's one caller to their installer and
its declaration to `#if DEBUG`, the region's text pinned; Fernlet's `KeyCustodyBoundaryTests` holds that
no Fernlet file names the door, and Fernlet's hosted tests on the system keychain.

| Function | What It Does |
| --- | --- |
| `ProximityKeychainBackend` (internal protocol, `nonisolated`, `Sendable`) | The funnel's three keychain calls as one seam: `add(_:)`, `copyMatching(_:result:)` and `delete(_:)`, each taking the builder's `[String: Any]` dictionary and answering the `OSStatus` the matching `SecItem` call answers. |
| `ProximityKeychainItem.SystemKeychain` | The system keychain, the only backend a shipping build has: `SecItemAdd(query as CFDictionary, nil)`, `SecItemCopyMatching(query as CFDictionary, &result)`, `SecItemDelete(query as CFDictionary)`, the calls the members made inline before the seam. |
| `ProximityKeychainItem.backend` | The backend every member calls: in a Debug build the installed one, else `SystemKeychain()`; in a Release build always `SystemKeychain()`, with no slot to read. |
| `ProximityKeychainItem.installBackend(_:)` (Debug only) | Replaces the backend for the whole process through a `Mutex` slot the type owns (last install wins). Called only by ProximityKit's package tests' installer, `PackageTestEnvironment`; absent from a Release build. |
| `ProximityKeychainItem.store(_:account:service:accessibility:synchronizable:replacing:)` | Delete-then-add under the caller's class; `synchronizable` defaults to `false`, `replacing` (which variant the delete removes) to `.any`. Refuses an empty account, service or payload with `errSecParam`. Not discardable. |
| `load(account:service:synchronizable:)` / `loadDistinguishingAbsence(account:service:synchronizable:)` | The single-row read: `Data?`, or the three-way `ReadResult` (`found`, `absent`, `unreadable(OSStatus)`) the mint-on-absent stores use to fail closed. An empty name is `nil` / `.unreadable(errSecParam)`. |
| `loadAll(service:synchronizable:)` / `loadAllDistinguishingFailure(service:synchronizable:)` / `enumerationResult(status:matches:)` | Every row under a service, collapsing a failed enumeration into `[]` or reporting it as `EnumerationResult.unreadable`; the classifier is pure, so the statuses a simulator cannot produce are testable. |
| `delete(account:service:synchronizable:)` / `deleteReportingStatus(account:service:synchronizable:)` | One row (or one synchronizable variant of it); not-found is success. `delete` audits any other failure through `ProximityAudit` as `keychain.delete.failed` (`service`, `account`, `status`). |
| `deleteAll(service:)` / `deleteAllReportingStatus(service:)` | Every row under a service, both variants; not-found is success. `deleteAll` audits a failure as `keychain.deleteAll.failed` (`service`, `status`). |
| `SynchronizableScope` (`.any`, `.synced`, `.local`) | Which variant a read or delete matches: `kSecAttrSynchronizableAny`, `true` or `false`. |
| `addQuery` / `readQuery` / `enumerationQuery` / `deleteQuery` / `deleteAllQuery` | The five query dictionaries, each built in one place and issued by every member of its shape, so the golden compares the dictionaries production issues. |

### The test target's bindings (`Tests/FernletTests/ProximityNamespaceTestBindings.swift`)

The call shapes A0.2 to A0.4 took out of ProximityKit, restored for the suites by passing `.fernlet`
(`ProximityNamespace.Purposes.fernlet` where a reader takes the labels and `ProximityNamespace.Family.fernlet`
where it takes the family, which the golden pins equal to `ProximityNamespace.fernlet`'s, `.fernlet`'s
`family.radios` values where a door takes a presentation string, its `family.vocabulary.routedTypes`
where the routed registry takes its routed types, and its `family.vocabulary.capabilities` where a
capability gate takes the host's). A binding restores a call shape, never a value, but for two stated
exceptions: the host doubles' identity door, and the host's platform facts (plan step A0.6), values the
file chooses for the doubles that state none; a test that pins a value names `.fernlet` explicitly.

| Function | What It Does |
| --- | --- |
| `canonicalBytes(for:)` (17 types), `canonicalInventoryDigestBytes(for:)` | The serializer's overloads with `.fernlet`'s labels. |
| `MeshMembershipRecordVerifier.init(meshID:founderSigningPublicKey:ledger:)`, `MeshLedgerAdoption.bootstrapVerifier(meshID:ownAdmission:)` / `adopt(offered:ownAdmission:meshID:)`, `MeshInventoryDigest.init(meshID:ledger:)`, `MeshAdmissionToken.verify(...now:)`, the six routed verifiers' and `MeshChannelIntroductionExchange`'s initializers without `purposes:` | The verifiers and helpers with `.fernlet`'s labels (the first four with `Family.fernlet`, record kinds included). |
| `ProximityVerifyQR.urlScheme` / `parse(_:)` / `isValid(_:at:)`, `ProximityVerifySignature.message(scannerKeyAgreementPublicKey:challengeNonce:qrNonce:)` | The verify QR in `.fernlet`. |
| `MeshRoutedContentDigest.contentHash(of:)` / `chunkHash(of:)` / `chunkID(itemID:chunkIndex:)`, `MeshChunk.chunkID` / `MeshCustodyReceipt.receiptID` / `MeshRecipientReceipt.receiptID` as properties, `MeshRoutedContentHasher.init()`, `MeshChunkAssembly.admit(_:)` / `completion(against:)`, the six item-seal and key-wrap doors, `MeshEpochRef.minted(counter:coordinatorFingerprint:meshID:)` / `successor(coordinatorFingerprint:meshID:)`, `MeshRotationPolicy.plan(...)` | The hashes, seals and epoch under `.fernlet`'s labels. |
| `NetworkMeshSession.init()` / `NetworkPresenceSession.init()` / `NetworkPairSession.init()` | The argument-less radios, built from `.fernlet` (the recipe radio under `ProximityPairProfile.recipeShare(in: .fernlet)`; no `init(namespace:)` comes back, since it would read a row off the caller's namespace). |
| `ProximityPairAdvertisement.mode` / `sessionID(from:)` | The recipe mode and the mode-less session-id read the advertisement spelled for itself before the profile carried the mode: `.recipeShare(in: .fernlet)`'s `advertisementMode`, and `sessionID(from:mode:)` under it. |
| `MeshSessionSealKey.forOpen(service:)` / `forSeal(service:)`, `MeshRoutedSealKey.forOpen(service:)` / `forSeal(service:)` / `keychainAccount`, `IdentityService.classifyDeviceIdentityRows(signing:keyAgreement:)` | The seal-key and identity-row helpers with `.fernlet`'s accounts. |
| `MeshLinkAdvertisement.randomInstanceName()`, `EphemeralMeshTLSIdentity.mint(now:)` / `selfSignedCertificateDER(for:notBefore:notAfter:serial:)`, `PresenceEpochPosture.minted(at:)` / `minted(at:entropy:mintIdentity:)` / `rotated(at:)` / `rotated(at:entropy:mintIdentity:)` / `instanceName(entropy:)`, `ProximityPairPosture.minted(now:)` | The minting doors with `.fernlet`'s instance-name prefixes and common name. |
| `PeerNameDisplay.personName(_:fingerprint:)` / `shown(_:fingerprint:placeholder:)` / `firstName(_:fingerprint:placeholder:)` | The name display, hiding `.fernlet`'s mesh instance-name prefix (`personName` over ProximityKit's filter, `shown` and `firstName` over FernletConnections' placeholders, which the bindings file imports). |
| `MeshRoutedTypeToken.photo` / `tempMessage` / `heart` / `control`, `MeshRoutedManifest.signed(...)` without `types:` | The routed constants, and the mint with the test target's registry over `.fernlet`'s routed types (whose `increment1` shapes are the FernletSocial bindings', below). |
| `ProximityCoordinator.PeerIdentity.supports(_:in:)` / `supports(_:)` and `PeerSlot.supports(_:in:)`, over a `ProximityCapability` | The typed capability gates that left ProximityKit with their last callers (plan steps A0.5.8 and A0.5.10), restored with their own bodies: each asks by the capability's token, as the features do, and `supports(_:)` under `.fernlet`'s capabilities. |
| `MeshNetworkManager.registerPayloadHandler(for:handler:)` | The typed registration over a `PayloadType`, which left ProximityKit with its last caller (plan step A0.5.8): `registerPayloadHandler(forToken: type.rawValue, handler:)`. |
| `ItemNameModeration.moderatedPeerDisplayName(_:)`, `ProximityIdentityEnvelope.sanitizedSenderDisplayName` / `disclosedSenderDisplayName` as properties, `ProximityPairAdvertisedName.publishable(_:)` | The peer-name coercion, the envelope's two sender reads and the advertised recipe name under `.fernlet`'s peer-name policy. |
| `IdentityService.heartDropStaticAgreement(withEphemeralPublicKey:)` | The static key agreement under the spelling the suites were written against: a pure rename of `staticKeyAgreement(withEphemeralPublicKey:)`, which takes no namespace. |
| `ProximityHost.makeProximityIdentity()` (a test-only extension) | The host doubles' identity door, which the requirement does not default: `IdentityService(namespace: proximityNamespace)`, the participant-less identity under the double's own namespace (not `.fernlet` for the golden suites' five), the shape the doubles were written against. Only conformances in the test target see it; the app's `FernletStore` answers for itself, and `ForeignIdentityHost` keeps its own answer. |
| `ProximityHost.proximityFallbackDisplayName` (plan step A0.6.2) / `makeProximityRangingProvider()` (plan step A0.6.3) / `proximitySupportDirectory` (plan step A0.6.6), a test-only extension | The host's platform facts for the doubles that state none, which the requirements do not default, chosen here under the rule's second stated exception: the fallback name `"Test device"`, a generic word naming no device (every double states a non-empty name of its own, so only a cell that empties one reads it); a fresh `NoopRangingProvider()` per connection, which builds no `NISession` (the three cells that fire a channel-ready door, `FernletFeatureGoldenTests`' 31b, 31c and 31d, through group 31's recipe pairing over the recipe radio's in-memory double, range nothing; the coordinator tests take a provider of their own through the managers' test seams); and the root, `proximityNamespace.installation.storage.directory(under: .applicationSupportDirectory)`, the production-shaped folder the doubles always shared, the very path the module's default built for them, on which the default scopes are the namespace's production rows as before (a double on a root of its own that opens a store states both scopes; scratch roots for every double are plan step A1's, before any runs on a Mac). Only conformances in the test target see it; the app's `FernletStore` answers `UIDevice.current.name`, `NIRangingSession()` and its own root for itself, and `ProximityVocabularyGoldenTests`' `PresentationNamespaceHost` takes its fallback from the cell that builds it. |

### The test target's FernletSocial bindings (`Tests/FernletTests/FernletSocialTestBindings.swift`)

The old call shapes of the types that left ProximityKit for FernletSocial, and the shapes that build
from FernletSocial's declarations (Fernlet's routed rows), under the same rule, so the core bindings
file never imports FernletSocial.

| Function | What It Does |
| --- | --- |
| `PresenceManager.firstName(of:)` | The hearts copy's first name, hiding `.fernlet`'s mesh instance-name prefix. |
| `SessionMessageStore.receiveIncoming(id:senderFingerprint:senderSigningPublicKey:senderDisplayName:text:sentAt:seenAt:in:)` | The session message store's ingest under `.fernlet`'s peer-name policy. |
| `MeshRoutedTypeRegistry.increment1(_:)` / `increment1`, `MeshRoutedAckStageTable.increment1(_:)` / `increment1` | The shipping registry and its ack-stage projection as values over Fernlet's host rows (`FernletRoutedTypes.entries`), over the routed types handed in or `.fernlet`'s. |
| `MeshSessionChat.allowIncomingRoutedText(_:from:)` with a manifest | The chat's per-origin message budget in the manifest shape the cells were written against, counted against `MeshRoutedOriginQuotaKey(manifest)`. |
| `ProximityHost.meshRoutedTypeEntries` (a test-only extension) | The host doubles' routed-type rows, which the requirement does not default: Fernlet's host rows over the double's own namespace's routed types. The app's `FernletStore` answers for itself. |
| `PresenceManager.makeSession` / `postureMint` / `presencePosture` / `discoveryInfoForTesting()` / `registerOwnEphemeralPeerNameForTesting(_:)` / `handleDiscoveredPeerForTesting(_:)` / `simulateHeartConnectionTeardownForTesting(peer:ranging:)` / `evaluateConnectedCoordinatorForTesting(_:peer:trustPolicy:intendedFriend:)` | The presence manager's seams that reached what moved into its presence engine at plan step A1.1, each a forwarder to the engine's own (`makeRadio`, `postureMint`, `posture`, `advertisedFields(for:)` over the manager's tags, `registerOwnInstanceNameForTesting(_:)`, `noteDiscoveredForTesting(_:)`, and the manager's two heart seams over `channelForTesting(_:)`). |
| `ProximityRecipeShareManager.init(store:makeSession:identity:)` and one forwarder per pair-session test seam (`makeRetainedConnectionCoordinatorForTesting`, `radioForTesting`, `markRunningForTesting()`, `checkCoordinatorStatesForTesting()`, `transferForTesting`, `finishShareForTesting(_:token:)`, `applyTransferForTesting`, `applyDiscoveryGateForTesting(_:)`, `discoveryInfoForTesting`, `shouldAdmitChannel(for:)`, `channelAdmission(for:)`, `sweepParkedConnections(now:)`, `connectTimeoutSeconds` and the rest) | The recipe-share manager's seam shape over a `ProximityPairSession` built with the test's radio and identity under the recipe profile on the host's OWN namespace, as `init(store:)` builds it: the rule's one stated exception. Each forwarder is the session's own seam. |

### The test target's App bindings (`Tests/FernletTests/FernletAppTestBindings.swift`)

The identity's two old initializers, which need the app's own type to carry Fernlet's custody, under the
same rule, so the core bindings file never imports the app.

| Function | What It Does |
| --- | --- |
| `IdentityService.init()` / `init(keychainService:)` | An identity under `.fernlet` carrying a fresh `SealedBackupEscrowKey`, what every identity the app builds carries, so the suites keep the escrow behaviour they were written against. |

## Identity, Wire, Trust, And Audit

### `App/Fernlet/SealedBackupEscrowKey.swift` (the app)

| Function | What It Does |
| --- | --- |
| `SealedBackupEscrowKey` | Fernlet's sealed-backup escrow key and the identity's provisioning participant, one per identity: Case 1 adopts the canonical escrow present; Cases 2 to 4 decide before the mint (an escrow present is adopted once the mint lands; else a previous build's synced key-agreement key is promoted into its content-addressed synchronized slot BEFORE the mint overwrites the row, audited `identity.escrow.legacyPromoteFailed` and thrown as `keychainWriteFailed` when the write fails, so nothing is minted; else nothing); a wipe drops it. Its WS-1 to WS-4 lifecycle (the sealing mint, the open path's load, the restore candidates, the launch reconcile, the conflict adoption, the v1 and v2 HKDF derivations) moved verbatim from `IdentityService`, over `KeychainItem` and `FernletAuditLog`, each taking the identity's keychain service. |
| `IdentityService.fernletApp(keychainService:)` | The app's one identity factory: `.fernlet`'s identity with a fresh `SealedBackupEscrowKey`. `FernletStore.makeProximityIdentity()` answers it for the three managers, and every other app construction calls it. |
| `IdentityService.localBackupEscrowPublicKey`, `sealedBackupKey()`, `sealedBackupKey(formatVersion:salt:)`, `sealedBackupKeyCandidates()`, `sealedBackupKeyCandidates(formatVersion:salt:)`, `provisionBackupEscrowKeyForSealing()`, `loadBackupEscrowKeyForOpen()`, `reconcileBackupEscrowKey()`, `adoptSyncedBackupEscrowKey()`, `BackupEscrowReconcileOutcome` | The escrow API the app calls through an identity, each forwarding to its participant when that is a `SealedBackupEscrowKey` (a conditional cast) on the identity's keychain service, and answering "no escrow" without one (`Data()`, `notProvisioned`, `[]`, `false`, `.noEscrow`, `nil`). |
| `IdentityService.escrowKeychainAccount(forPublicKey:)` | `nonisolated` and pure: `backupEscrowPrivateKey.k.` + the lowercase hex SHA-256 of the public key, the participant type's own static. |

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

### `FernletConnections/ProximityTrustVault.swift`

Fernlet's trust vault, in the `FernletConnections` module: the records it mints, normalizes and
keeps are Fernlet's, in FernletDomainModel's persisted types, and the app's `FernletStore` owns and
persists it. It conforms to ProximityKit's `ProximityTrustStore`, which the app's host
adapter and every test double hand over as `FernletSocialHost.proximityTrustStore`. Not itself a
`ProximityTrustPolicy`: the session policies beside it wrap it, ask it the questions below and keep
each coordinator audit in it, converted into a `TrainerAuditEvent`.

| Function | What It Does |
| --- | --- |
| `init(initialPeers:initialAudit:onChange:)` | Loads normalized trusted peers and initial audit events. |
| `peer(signingPublicKey:)` | Finds trusted peer by signing key. |
| `peer(displayName:)` | Finds most recently seen trusted peer with a display name. |
| `isTrustedProximityPeer(signingPublicKey:)` | Returns true for a non-revoked trusted signing key. Answers `ProximityTrustStore` for FernletSocial's kept-friend gates (the friend-state and moderation-report exchanges) and the heart-eligibility check (presence and the session hearts). |
| `isRevokedProximitySigningKey(_:)` | Checks whether a signing key is revoked. |
| `isBlockedProximitySigningKey(_:)` | Checks whether a signing key is blocked. Answers `ProximityTrustStore` for presence's heart eligibility. |
| `isBlockedFingerprint(_:)` | Checks blocked records by canonical or legacy fingerprint match. |
| `trust(_:mode:)` | Adds or updates a trusted peer record and clears revocation. |
| `block(signingPublicKey:)` | Blocks/revokes an existing key or creates a blocked placeholder record. |
| `unblock(signingPublicKey:)` | Clears blocked/revoked flags. |
| `revoke(signingPublicKey:)` | Marks a trusted peer revoked and records audit. |
| `recordTrainerAudit(_:)` | Adds audit event and triggers persistence callback. The session policies call it with each coordinator audit, converted (`TrainerAuditEvent.init(_:)`). |
| `apply(peers:audit:)` | Replaces vault state from a stored snapshot. |
| `normalized(_:)` | Upgrades legacy 8-character fingerprints to 16-character fingerprints when key data exists. |
| `recordAuditWithoutSaving(_:)` | Inserts audit event and caps audit log at 500 entries. |

### `FernletConnections/FernletPairProfiles.swift`

| Function | What It Does |
| --- | --- |
| `ProximityPairProfile.recipeShare(in:)` | Fernlet's recipe profile under a namespace: its recipe-share radio row (`_fernlet-recipe2._udp` / `fernlet-recipe-v1` under `.fernlet`), the TXT mode `recipe` and the audit area `recipeShare`, read off the host's own namespace. `FernletFeatureGoldenTests` 31f pins it. |

### `FernletConnections/ProximityIdentityEnvelope+PayloadType.swift`

Fernlet's typed view of the signed envelope's raw payload token (plan step A0.7.4), a `nonisolated`
extension of ProximityKit's `ProximityIdentityEnvelope`: ProximityKit's `verify` parks by the namespace and
its engine reads and signs the raw token; Fernlet's features (the heart dead-drop, presence, the clothing
shop and recipe sharing) and the tests read and sign through this view, with every byte the raw form's.

| Function | What It Does |
| --- | --- |
| `payloadType` / `isUnknownPayloadType` | The `PayloadType` case `payloadTypeToken` spells, or `nil`, and whether it is `nil`; feature dispatch gates on a case, while `verify` parks by the namespace's `payloads.known`, which for Fernlet holds exactly these cases' tokens. |
| `init(schemaVersion:envelopeID:...payloadType:...signature:)` | The typed initializer: the raw initializer with `payloadType.rawValue` as the token. |
| `signed(...payloadType:...)` | `@MainActor`: the raw `signed` with `payloadType.rawValue` as the token, every parameter and default the raw factory's. `ProximityVocabularyGoldenTests`' group 2 signs an envelope for every token through it. |

### `FernletConnections/FriendSessionTrustPolicy.swift`

Fernlet's friend-session rule, in the `FernletConnections` module: what the app's `ProximityHost`
adapter answers for `makeProximityTrustPolicy()`, fresh for each connection the mesh and presence
managers and the pair session open (each retains it, since the coordinator holds its policy `weak`).

| Function | What It Does |
| --- | --- |
| `init(vault:)` | Wraps a `ProximityTrustVault` for friend sessions. |
| `isRevokedProximitySigningKey(_:)` | Delegates revoked-key check to vault. |
| `isBlockedProximitySigningKey(_:)` | Delegates blocked-key check to vault. |
| `isTrustedProximityPeer(signingPublicKey:)` | Always returns true because friend sessions authorize through proximity commit. |
| `recordSessionAudit(_:)` | Converts the coordinator's audit into Fernlet's persisted row (`TrainerAuditEvent.init(_:)`) and keeps it in the vault. |

### `FernletConnections/TrainerAuditEvent+SessionAudit.swift`

Fernlet's one conversion from what ProximityKit's coordinator reports to what Fernlet persists. Both
session policies and the app's `FernletStore` record through it.

| Function | What It Does |
| --- | --- |
| `TrainerAuditEvent.init(_:)` | A `ProximitySessionAudit` as Fernlet's audit row: id, timestamp, peer fields and message unchanged, the kind case for case, the envelope's token read as a `PayloadType` (an unknown token becomes none and nothing is parked, as the envelope's typed view reads it). `nonisolated`. `ProximityVocabularyGoldenTests` holds the result to the frozen row's JSON. |
| `TrainerAuditEvent.Kind.init(_:)` (fileprivate) | ProximityKit's eight kinds onto the persisted kinds of the same names, by an exhaustive switch, so a kind ProximityKit adds fails to compile instead of persisting as another. |

### `FernletDomainModel/ProximityPersistenceRecords.swift`

Fernlet's persisted trust records and audit rows, which its `ProximityTrustVault` keeps and its
snapshot persists. ProximityKit names the trusted-peer record only on the lines
`ProximityNamespaceBoundaryTests` allowlists (the host's trusted-peer list and the features that read
it) and the audit row nowhere.

| Function | What It Does |
| --- | --- |
| `ProximityTrustedPeerRecord.init(...)` | Creates a persisted trust record with timestamps and optional revoked/blocked flags. |
| `TrainerAuditEvent.init(...)` | Creates Fernlet's persisted audit row, as the vault and the app do for their own events; a coordinator's audit arrives as a `ProximitySessionAudit` and is converted by `TrainerAuditEvent.init(_:)` above. |

### `FernletConnections/FernletAuditBridge.swift`

| Function | What It Does |
| --- | --- |
| `FernletAuditBridge.record(_:context:)` | Fernlet's sink: `FernletAuditLog.log(event, context: context)`, unchanged and in line, so every `FernletAuditLog` capture handler sees ProximityKit's lines. `FernletApp.init` installs it first, unconditionally. |

### `ConnectionInspector.swift`

| Function | What It Does |
| --- | --- |
| `init(store:now:)` | Loads historical logs from store and injects a clock. |
| `attachStore(_:)` | Attaches store, reloads historical logs, and purges old entries. |
| `beginSession(role:mode:localFingerprint:)` | Starts a live log unless inspector mode is disabled, with ProximityKit's role mapped onto the log's own `Role`. |
| `recordEvent(_:message:)` | Appends a timestamped event to the live log and trims log size. |
| `recordRangingSample(_:)` | Subsamples ProximityKit's distance samples, converts each kept one, updates min/max, and records a ranging event. |
| `recordEnvelope(_:)` | Appends ProximityKit's envelope record, converted, updates byte counters, and records sent/received event. |
| `recordError(domain:message:recoverable:)` | Appends an error record and event. |
| `updatePeer(_:)` | Updates live peer info from ProximityKit's peer line, converted. |
| `updateTransport(_:)` | Applies one ProximityKit transport event: a state change sets the state, sets the connected stamp only while the session has none and takes every disconnected stamp (both the coordinator's clock readings); a round trip joins the samples, capped at the latest 50. |
| `updateRangingMode(_:)` | Updates live ranging mode, ProximityKit's mapped onto the log's own `RangingMode`. |
| `mutateTransport(_:)` | The one write path for live transport info, shared by `updateTransport(_:)` and the "connected" status lines `recordCoordinatorEvent(_:)` mines. |
| `ConnectionSessionLog.Role`/`.RangingMode`/`.EnvelopeRecord.Direction`/`.EnvelopeRecord`/`.DistanceSample`/`.PeerInfo` `init(_:)` (private) | Convert ProximityKit's report types into the log's own: every field copied unchanged, every enum mapped case for case by an exhaustive switch. |
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
| `Role` / `RangingMode` | The record's own copies of ProximityKit's `ProximityRole` and `ProximityRangingMode`: the same raw values, decoded tolerantly (`browser` and `none` with the token parked). `ProximityVocabularyGoldenTests` holds the spellings equal. |
| `RangingInfo.init(...)` | Creates ranging state and distance summary fields. |
| `DistanceSample.init(timestamp:meters:direction:)` | Stores distance and optional direction vector components. |
| `TransportInfo.averageRttMs` | Computes average recorded RTT. |
| `TransportInfo.init(...)` | Creates transport state, counters, flags, and RTT sample storage. |

### `FernletConnections/CoachSessionTrustPolicy.swift`

Fernlet's coach-channel rules, in the `FernletConnections` module.
**No production callers yet** — the coach session manager is unbuilt (see the coach spec and `Plan-Prekeys-ProtectedLoad-CoachMesh-2026-07-26.md` Increment 10).

| Function | What It Does |
| --- | --- |
| `CoachSessionContract.fernletRole` / `.coachAppRole` | The written-down role split (Fernlet browses, the coach app advertises) so it cannot be gotten backwards. |
| `CoachSessionTrustPolicy.isTrustedProximityPeer(signingPublicKey:)` | Unlike `FriendSessionTrustPolicy` (which returns `true` unconditionally), auto-confirms only an unrevoked, unblocked `.trainer` vault record whose `unknownModeToken` is `nil` — `.trainer` is the decode freeze default, so a record from a newer build must not silently inherit coach privilege. |
| `isRevokedProximitySigningKey(_:)` / `isBlockedProximitySigningKey(_:)` | Read the **coach** vault, not the friend vault. |
| `recordSessionAudit(_:)` | Coach-channel audit hook: converts the coordinator's audit (`TrainerAuditEvent.init(_:)`) and keeps it in the vault. |

### `FernletConnections/TrainerPayloads.swift`

| Type | What It Does |
| --- | --- |
| `TrainerExportPayload` | Wire envelope body for the curated trainer/nutritionist export bundle: payload vocabulary of Fernlet's coach channel, so it lives in the `FernletConnections` module and ProximityKit never names it. The bundle bytes are opaque — the app owns the allowlist-projected shape — so this type only carries, bounds and shape-checks them. Both bounds derive from ProximityKit's `ProximityCoordinator.maxTrainerModeInboundBytes`: `maxTrainerWireBytes` (4 MiB) is that bound and `maxBundleBytes` (2 MiB) half of it. It is the seam the future `fernlet-coach` trainer channel will use; until that ships, the app shares the reviewed bundle as a file. |

### `FernletConnections/FriendMintingReview.swift`

Pure decision logic for the post-session "keep as friend" prompt (mesh redesign Phase 2), kept
view-free so the session-end flows in `ConnectView` / `DisposableCameraView` stay unit-testable.
Fernlet's rule over ProximityKit's session roster, so it lives in the `FernletConnections` module.

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
| `openSealed(_:)` | Four-way read of on-disk bytes — `.opened`, `.legacyPlaintext` (a pre-encryption file, recognised by the pixel-bounds check and re-sealed in place on access), `.noKey`, or `.unopenable` (a key is present and the bytes are neither openable nor a valid image) — so a wrong key or corruption never hands ciphertext back as a photo, and a caller that must not lose a photo can tell "no key right now" from "gone" (`FriendPhotoCorpusFiles.readImage(forID:)`: `.opened` / `.missing` / `.unavailable` / `.unopenable`). |
| `PrivateMediaKeyProviding.gcmSeal(_:)` / `gcmOpen(_:)` / `sealAndWrite(_:to:)` | The shared AES-256-GCM at-rest helpers this store now seals/opens through (`MediaAtRestCrypto.swift`), also used by `MealPhotoStore` and `ProgressPhotoStore`; they replaced the per-store `encrypt(_:)` / `reseal(_:to:)` copies. Each call site keeps its own fail-closed decision. |
| `isWithinSafePixelBounds(_:)` | Rejects decompression-bomb dimensions/area via ImageIO before any decode. |
| `removeOrphanedFiles(keeping:)` | Deletes image/thumbnail files not present in retained IDs (also the per-photo delete mechanism). |

### `PrivateMediaKeyStore.swift`

| Function | What It Does |
| --- | --- |
| `PrivateMediaKeyProviding.mediaKey()` | Supplies the symmetric key for `PrivateMediaStore`; injectable for tests. |
| `KeychainPrivateMediaKeyProvider.mediaKey()` | Loads or generates a 256-bit AES key stored backup-restorable (`kSecAttrAccessibleAfterFirstUnlock`); caches it in memory. |

### `FernletProximityUI/FriendPhotoReviewSheet.swift`

In the `FernletProximityUI` module since ProximityKit plan step A0.1 (2026-10-01), with the other two
screens that left ProximityKit's `UI/` folder; its copy is `FernletProximityUICopy`.

| Function | What It Does |
| --- | --- |
| `FriendPhotoTile.body` | Renders thumbnail tile, selection checkmark, fallback placeholder, and lazy image loading (reloaded when the host's `tileReloadToken` changes). |
| `FriendPhotoReviewSheet.body` | Renders the review grid, the status line (working — saving to Photos or, since U3, ending the session / Keep unavailable / answer failed / unreadable), the opt-in "Also save kept photos to Photos" toggle and the Delete all / Keep selected pair — or, while the scene is not `.active`, an opaque cover INSTEAD of the grid (`friends.review.snapshotCover`), so the app-switcher snapshot never holds a held photo. The app's overlay injects the scene phase; the camera's sheet inherits it. Not interactively dismissible while busy (U3 fix round 1): an answer that has started finishes in front of the person, with its working line and any failure alert. |
| `FriendPhotoReviewSheet.header` | Session photos U3: the title as a VoiceOver heading and, when the host passes `notNow` (the app's overlay), a "Not now" text button (`friends.review.notNow`, disabled while busy) that answers nothing; `EscapePerformsNotNow` makes VoiceOver's escape gesture the same action on that host only, so the camera sheet keeps its own escape (cancel back to the camera). Each tile is labeled "Photo from <name>" through `PeerNameDisplay` (placeholder `.met`, never a fingerprint) with a keep/not-keep hint. |
| `toggle(_:)` | Toggles a photo ID in the selected set. |
| `FriendPhotoLibrarySaver.save(_:)` | Requests add-only Photos permission and saves selected payload images to the photo library. |
| `FriendPhotoLibrarySaver.userFacingFailure(for:photoCount:)` | Maps a `save(_:)` error onto the shared `PhotoSaveFailure` alert content: the permission denial (the only one offering Open Settings), the singular/plural corruption wording for `NothingSavedError`, or `PhotoSaveFailure.generic`. |
| `View.photoSaveFailureAlert(_:failure:)` | Presents that failure identically at every save surface (the session-end overlay, the camera's Develop review, album carousel): message body, conditional Open Settings button, OK; every button clears the binding. |

### `ProximityRecipeShareSheet.swift`

| Function | What It Does |
| --- | --- |
| `body` | An always-present `ZStack` switching between `pickerContent` and `RecipeShareConfirmationPanel`, carrying the lifecycle hooks, the outcome observer, and the success/error haptic. |
| `pickerContent` | Renders nearby recipient picker, notes toggle, status line, diagnostics, fallback share link, and the toolbar Done. |
| `searchingView` | Shows initial discovery progress UI. |
| `noNearbyView` | Shows empty discovery UI and search-again action. |
| `diagnosticDetailsCard` | Shows recent connection diagnostic events. |
| `scheduleNoNearbyState()` | Delays empty-state display while discovery has time to find peers. |
| `send(to:)` | Tells the latch which row a share began for, then calls `sendRecipeShare`. |
| `receive(_:)` | Latches an outcome this sheet began into a confirmation, cross-fades to the panel (no motion under Reduce Motion), announces it, and after a success schedules the radio hand back. Replaces the old auto-dismiss. |
| `retryShare()` | "Try again": re-sends to the same row with the current toggles if it is listed and not locked out, else returns to the picker. |
| `handleDisappear()` | Resets the latch first (a cancelled share raises nothing), then, only while the sheet still holds `RecipeShareRadioCustody`, stops the radio and restarts passive listening behind the opt-in + active-scene + lock gates. A pending post-send hand back is never cancelled here. |
| `startRadioHandBack(after:)` | On a successful send, moves radio custody to a `RecipeShareRadioHandBack` and starts an uncancellable task that, 1.4 s after the send (`RecipeShareRadioHandBack.delay`), stands the radio down for that share only and restarts passive listening when the store's live run-policy verdict, the opt-in and the lock allow it. Captures the manager, store and lock service, so it runs the same whether the panel is still open or was closed inside the window (the drain rule: an early Done must not cut an undrained text frame). |
| `standDown(_:thenListen:)` | Static: stops the manager and, when asked, starts passive listening again (the go-dark-after-share fix), shared by the disappearance and the hand back. |
| `outgoingPayload` | Returns payload with or without notes based on UI toggle. |
| `statusText` | Maps manager send state to the progress line (localized connecting/sending; nothing for `sent`, which the panel owns; the manager's English failure message verbatim, a recorded residual). |

### `RecipeShareConfirmation.swift`

| Function | What It Does |
| --- | --- |
| `RecipeShareConfirmation.init(_:)` | Maps a `ProximityPairSendOutcome` to tone, headline, detail, announcement and `offersRetry`. Exhaustive per cause; "sent" never becomes "delivered", and the success copy says what the other person can do only on the condition that it reached them. |
| `RecipeShareOutcomeLatch.beganShare(to:)` / `receive(_:)` / `retry()` / `reset()` | Latches only the outcome of a share the sheet began, once, for the tapped row; retry clears a failure panel and returns the row; reset forgets everything (appear, disappear). |
| `RecipeShareRadioHandBack.step(currentOutcomeID:listeningWanted:)` | After the delay: leave the radio alone if the manager has moved on to a newer share (or a delete-all), else stop, and listen again only when wanted. |
| `RecipeShareRadioCustody.handOff(afterSendOf:)` / `sheetStopsRadioOnDisappear` | Custody of the radio moves from the sheet to the hand back once, on a successful send; from then on the sheet's disappearance leaves the radio alone. |
| `RecipeShareConfirmationPanel.body` | The confirmation panel: decorative glyph, header-trait heading, detail, and Try again / Done pills, scrolling at AX5. |

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

## FernletSocial

Fernlet's own social features over the proximity stack, in the `FernletSocial` module
(`FernletKit/Sources/FernletSocial/`, ProximityKit plan steps A0.4 and A0.5), which depends on
ProximityKit and never the reverse: the mesh's features, composed by `FernletMeshFeatures` — the session
photos and their review, the live-session chat, the session hearts and the heart ledger, the vouch
list's content, the capability list, the friend-state and moderation-report exchanges, the clothing shop
and the activities — and presence, the heart dead-drop, moderation's device-local records, the closeness
ledger, the friend-state cache and the parked chat payload. The composition owns the mesh engine, rides
its public seams (the payload token door, the captured-slot feature send, the routed origination door,
the projection handlers and ledger judge it registers, the session observer and the vouch-list exchange
it installs) and reads the host through `FernletSocialHost`, ProximityKit's `ProximityHost` refined with
the three requirements only these features read. Presence drives ProximityKit's presence radio through
its public presence engine. Every record is device-local and never synced; a sealed heart drop is the one thing
that leaves the device.

The heart dead-drop (`HeartSharing/`), shipped in the bitchat-adoptions round (Increment 3) and hardened
in the prekeys/protected-load round (Increments 1–7), is the one feature here that leaves the device:
all its crypto lives on the sealed side of the S3 wall, and the injected `HeartDropTransporting`
conformer (`CloudKitSync/HeartDropCloudTransport`) only ever sees a rotating day tag and ciphertext.
Opt-in via `heartsAwayDelivery`, default OFF. It records into the heart ledger (`ProximityHeartLedger`,
below), gossips ProximityKit's `ProximityPrekeyBundle` and loads its sidecars through ProximityKit's
`ProtectedSidecar` (see "Hearts" above).

### `FernletSocial/Mesh/FernletMeshFeatures.swift`

Fernlet's mesh features and the mesh engine they ride: the composition the app builds once
(`FernletStore.meshFeatures`, a lazy initializer) and owns, with `FernletStore.meshNetworkManager` a
read of its `mesh`. It asks the host for the device identity once, builds the manager over it
(`MeshNetworkManager.init(store:identity:)`) and hands the same identity to the features that sign under
it; it registers each feature's handlers through the payload token door, each routed row's projection
handler or ledger judge under the row's token, and installs its capability provider, its vouch-list
exchange and its session observer — a private adapter in which the order between the features' legs at
each moment is written.

| Member | What It Does |
| --- | --- |
| `init(host:)` | The app's composition: one identity from the host's door, the mesh over the host's radio, then the features — the activity manager first (attached to the mesh), the session photos right after it, then the rest. The internal `init(…)` is the test rig's seam (an injected identity, the pending corpus's key provider and a mesh over a fake radio). |
| `mesh` / `capabilities` / `vouchList` / `clothingShop` / `moderation` / `friendState` / `activities` / `chat` / `hearts` / `photos` | The engine and the features, each its own section below. |
| `onFriendSessionCommitted` | Phase 5: a friend session committed with this fingerprint (an in-person meeting) — feeds closeness. Called first at every slot commit, before any other feature's commit leg. |
| `refusedRoutedRegistrations` | The routed registrations the mesh refused while the composition installed its roles, by token: always empty for Fernlet's own rows, which the host declares beside the handlers and the judge; each refusal also writes one `meshFeatures.registrationRefused` line. Internal, for the test rig, which holds it empty. |
| the observer's `meshSlotDidCommit(_:)` | A slot committed: the closeness hook first; on a formation, the shop's new session, the chat transcript's drop and the shop's send tracking cleared (the mesh advanced its session-content generation just before); then the shop's catalog offer to the slot, this device's own moderation reports and its friend state, each send spawned in that order; and, last, the activities this device hosts, offered with a roster version digest. |
| the observer's `meshSessionDidEnd(_:)` | The session ended: first the review promotion (the roster the mesh drained merges into the pending review and the session's unreviewed photos move in with it), then the shop's one-hour browse window over the catalogs it holds, then the chat transcript's drop (messages vanish), then, last, the in-session heart's feedback and in-flight claims. |
| the observer's other moments | `meshSlotDidLeave(slotID:)` and `meshSearchDidStop()` prune the shop's send tracking; `meshPrivacyWipeDidBegin()` drops the chat transcript; `meshSessionWillBegin()`, `meshSessionDidLeave()`, `meshScopeDidChange(_:)`, `meshMemberWasRemoved(fingerprint:)` and `meshRoutedAccessGateDidChange(_:isRising:now:)` are the session photos' legs (a new photo session, the left session's ids forgotten, the film's mesh pin, the removed member's purge from the review, the indexes' re-read on a rising edge). |

### `FernletSocial/FernletSocialHost.swift`

| Type Or Member | What It Does |
| --- | --- |
| `FernletSocialHost` | ProximityKit's `ProximityHost` and the three requirements only Fernlet's features read (plan step A0.5.10, S17). The app's `FernletStore` conforms (`ProximityHostAdapter.swift`), as do the test target's doubles. |
| `trustedProximityPeers` | Every trusted-peer record the host keeps (kept, removed, blocked and reported alike), in the host's persisted type: presence reads a friend's record for its tags, a heart connection's sealing key and a heart sender's filed name, and the vouch list the friends it vouches for. The same records `proximityTrustStore` answers from. |
| `proximityTrustStore` | The host's `ProximityTrustStore`, with **no default**: the friend-state and moderation-report exchanges' kept-friend gates (in and out) and the heart-eligibility check below ask it whether a signing key is a remembered, unrevoked peer and whether it is blocked, at each question. Fernlet's app answers its `ProximityTrustVault` (`FernletConnections`), as every test double answers its own vault. |
| `allowNearbyHearts` | The in-person hearts opt-in, the one hearts setting a host answers (default `true`, for hosts that predate it; the app answers its live setting). Presence consults it on BOTH sides (block an outbound heart, drop an inbound one), the session hearts on their send and in their ledger judge's readiness, and the capability list before it advertises the hearts capability. Presence VISIBILITY is a separate setting, so hearts-off + presence-on means a friend still sees you nearby but a heart to you is silently dropped. The away-delivery consent is no host requirement: the features that read it take a `heartsAwayEnabledProvider` of their own. |
| `isTrustedUnblockedPeer(signingPublicKey:fingerprint:)` (public, a `FernletSocialHost` extension) | The heart-eligibility predicate: the host's trust store remembers the key and has not removed it, does not hold it blocked, and the host's fingerprint block list does not hold the fingerprint, asked in that order and short-circuited. One definition, two callers: `PresenceManager.isHeartEligible(signingPublicKey:fingerprint:in:)` delegates to it for an in-person heart, and the session hearts' ledger judge (`MeshSessionHearts`' `admits(_:)`) asks it with the admission ledger's key. `FernletFeatureGoldenTests` holds each leg to presence's gate. |

### `FernletSocial/Mesh/FernletMeshHost.swift`

| Member | What It Does |
| --- | --- |
| `FernletMeshHost` | The host the mesh features read: the app's `FernletSocialHost`, held `unowned`, its protocol namespace, read once at construction and kept as the features' own copy, and `spawnHostPinned(_:)`, which pins the host for a spawned task's own lifetime — the mesh manager's helper's twin, for the features' spawns. |

### `FernletSocial/Mesh/FernletRoutedTypes.swift`

Fernlet's routed-type rows, declared by the host (plan step A0.5.9, S16): the one FernletSocial file
that reads a routed type off the namespace, so a host of another namespace registers and mints under its
own spellings. Each cap is a formula over its body's constants, never a literal.

| Member | What It Does |
| --- | --- |
| `text` | The temporary-message row (P6 item 4): `.fullRosterAtCreation`, `.durableRecipientStorage`, `.session` scope, capped at `MeshRoutedTextBody.maxSealedBlobByteCount` (9 065 B). |
| `heart` | The heart row (P6 item 6): `.singleRecipient`, `.foregroundDecryptAndLedgerCommit` (the judge row), `.persistent`, capped at `MeshRoutedHeartBody.maxSealedBlobByteCount` (a zero payload term). |
| `photo` | The photo row (P5 item 13, narrowed by P6 item 3): `.fullRosterAtCreation`, `.durableRecipientStorage`, `.persistent`, capped at `PrivateMediaStore.maxIncomingPhotoBytes` + `MeshRoutedPhotoBody.maxFramedHeaderByteCount` + `MeshRoutedItemSealFormat.overheadByteCount` = 10 551 337 B — the widest row, and so the mesh's resident bound. |
| `init(_:)` / `entries` / `entries(_:)` | The rows over the routed types handed in, each token read off them; `entries` is every row, the whole of the mesh's registry (token-keyed, so their order reaches no door and no byte); `entries(_:)` is what a host answers `ProximityHost.meshRoutedTypeEntries` with. |

### `FernletSocial/Mesh/FernletMeshCapabilities.swift`

| Member | What It Does |
| --- | --- |
| `localCapabilities()` | The capability tokens this device advertises in its identity introduction, in their frozen order: photos, the host's wire2 token, then each switched token in place around moderation and activities, hearts last — the mesh's `localCapabilitiesProvider`, advertised verbatim. Reads the shop's gate, the friend-state opt-in, the chat's age gate and the hearts settings. |
| `heartsAwayEnabledProvider` | The away-hearts consent, wired by `FernletStore`: gates the `heartsAway` advertisement, which tells a peer this device's intros carry a prekey bundle and it accepts drops. Nil means not consented, so a list nobody wired never advertises it. |

### `FernletSocial/Mesh/FernletVouchList.swift`

The vouch list's content (plan step A0.5.5, S14): what this device would send a just-committed peer, and
the labels the lists committed peers sent compose. The frame is the engine's
(`MeshNetworkManager.sendVouchList(to:)` and the vouch arm); the composition installs this list's
adapter as the mesh's `vouchListExchange`.

| Member | What It Does |
| --- | --- |
| `vouchLabel(for:)` | Returns a label like "Friend of Aisha" if any unexpired cached voucher lists this fingerprint as trusted. |
| `isVouchListBroadcastEnabled` | Phase 2 gate, OFF: the broadcast disclosed every unblocked trusted fingerprint to all session peers, and friend minting is exactly what would have switched it on. Re-enable only with an explicit consent design for sharing the friend graph. |
| `vouchListPayloadForBroadcast()` / `receiveVouchList(_:senderFingerprint:)` | The send (nil while the gate is off) and the receive: while the gate is off an inbound list is dropped wholesale — no cache write, no label; when on, the cached entry's expiry is capped at the protocol's 2 h TTL and the peer-supplied display name is sanitized under the host's namespace before it is stored or rendered. |
| `makeExchange()` | The `MeshVouchListExchange` adapter the composition installs on the mesh; it holds this list strongly and the list never holds an adapter, so the mesh retaining it forms no cycle. |

### `FernletSocial/Mesh/FriendStateExchange.swift`

The fuzzy friend state's mesh adapter (Phase 4): this device's state and appearance, shared with a
committed friend kept in person while the user opts in, and such a friend's state, handed to the app
(which files it in `FriendStateCache`).

| Member | What It Does |
| --- | --- |
| `registerHandler(on:)` | The `.friendState` handler, through the mesh's payload token door: the committed-slot gate has run; it requires a verified, unblocked, vault-trusted sender and a well-formed payload, then hands it to `onFriendStateReceived`. Sealed (in Fernlet's `payloads.sealingRequired`). Holds the exchange weakly. |
| `offerState(to:peer:)` | The commit-time send, from the composition's observer: this device's state and appearance (`payloadProvider`; nil, opted out, sends nothing) to a committed friend that advertises `friendState` and is vault-trusted, sealed, through the mesh's captured-slot `sendFeatureEnvelope`. |
| `isEnabledProvider` | Whether the user opted into sharing, which gates the advertised `friendState` capability. |

### `FernletSocial/Mesh/MeshSessionPhotos.swift`

The session photos (P5 item 13; held for the person's answer since 2026-09-30; FernletSocial's since
plan step A0.5.11): the wall, the pending corpus and its answers, the film, the review batch, the
capture and its routed share, with the session's moments arriving through the composition's observer.
The live roster and its custody are the engine's, which drains them into the ending.

| Function | What It Does |
| --- | --- |
| `MeshSessionPhotos` | Fernlet's session photos: the friend-photo wall with its preferences and favourites, the sealed pending corpus every session photo is held in until the person answers, the film and its quota, the session-end review batch, the capture and its routed share, and, through a private adapter, the photo row's projection handler. Built by the composition right after the activity manager, over the mesh (held weakly) and `FernletMeshHost`. |
| `FriendPhotoWallPost.isCarousel` | Returns true when a post contains more than one photo. |
| `JSONSidecarFile<FriendPhotoWallPreferences>.load()` / `.save(_:)` | The wall's aggregation, cover and favourite preferences (`MeshPhotoWallPreferences.json`) through the module's shared sidecar helper: `load()` answers `nil` on any failure, so the object substitutes defaults; `save(_:)` writes atomically under `.completeFileProtection`. |
| `filmRemaining` | Returns the remaining session photo quota, capped at zero. |
| `addPhoto(_:)` / `shareRoutedPhoto(itemID:addedAt:imageData:session:)` | Enforces the 10-shot quota, resizes, echoes to this device's own wall **unconditionally** (D-13.8 — both retired send arms cached before any send, so a solo member has always got a wall entry and no error), then frames the bytes as a `MeshRoutedPhotoBody` and hands them to the mesh's routed sender door (`originateRoutedItem(body:typeToken:itemID:audience:now:)`, under the host's photo row's token, behind `isRoutedTypeRegistered(_:)`). **P5 item 13 replaced the transport, not the capture:** the group-key seal and the epoch-0 plaintext broadcast are gone, the destination set is the full roster at creation rather than whichever slots were active, and only a mint that was ATTEMPTED and failed reaches the user (as the frozen `MeshRoutedShareRefusal` token on the mesh's observed `routedShareRefusal`, through its `noteRoutedShareRefusal(_:error:)`; the app forks it into localized copy via `RoutedShareRefusalCopy` — no sentence is composed in the package). **P8 item 0 (c):** the door's third answer is no longer silent — `.skipped(.noDestinations)` increments `photosKeptOnThisPhone` (`noteRoutedPhotoSkip`, audit `mesh.routedShare.skipped`), reset with the session counter, which the app says once as a count (`RoutedShareRefusalCopy.photoKeptNotice(count:)`, the camera's info sheet + film-counter glyph), never as an alert per shot. |
| `holdSessionPhoto(_:key:live:)` | The only way a session photo enters the device, for both producers: refuses by (origin, item id) — tombstoned → `.answered`, held or on the wall → `.alreadyHeld` — and while duress is active or the pending index is deferred; mints a fresh local id on an id collision; stamps a live photo with the session metadata; lists it live (`sessionPhotos`) or awaiting (the batch). Never touches `meshPhotos`. |
| `routedPhotoSettlement(_:)` / `routedCanonicalDispatch(_:delivery:)` / `makeProjector()` | The photo row's projection handler, which the composition registers under the host's photo row's token (plan step A0.5.11, S9). Its pre-open verdict asks `routedPhotoSettlement(_:)` — BEFORE the body is opened and before the quota: a tombstoned (origin, item id) is `refusedForGood` (audited `mesh.routedProjection.photoAlreadyAnswered`), one already held or on the wall is `handedOn` — and its write, the photo arm, runs `allowIncomingRoutedPhoto` → `sanitizedIncomingPhoto` → `holdSessionPhoto` (live iff the mesh's `isSessionLive` and the SIGNED `delivery.meshID` is the current mesh) and the closeness hook for a live photo; `.full`/`.notPersisted` are `refusedForNow` (custody kept). The author is the delivery's, from the signature and the ledger, never an unsigned claim, and the block list was applied before the unwrap. Takes no clock. W2's FernletSocial half pins the arm to its handler's write. |
| `allowIncomingRoutedPhoto(_:from:)` / `routedOriginPhotoQuota` | The incoming per-origin photo budget, keyed on the **item's** mesh from the signed manifest (`MeshRoutedDelivery.quotaKey`) and never on the live one (D-13.23): the legacy counter reset whenever the live mesh changed, which would hand one origin a fresh budget at every later access-gate edge on the routed path. Re-sends of an accepted id are free. Memory-only, and never cleared by a mesh change (D-13.23a). |
| `finishSessionPhotos(keeping:of:)` | The in-camera Develop review's answer, scoped to the ids it snapshotted at Develop and applied wherever each is listed now (2026-09-30 fix round, C-F1/L-F1): of those still held — live in `sessionPhotos` or already moved into the pending batch by door 3's give-up under the open review — the kept are copied to the wall and the rest deleted, through `applyPhotoAnswers(kept:discarded:now:)`. First answer wins; a late arrival the sheet never showed stays listed for the post-session review. Returns the `SessionPhotoAnswer` (not discardable). |
| `finishSessionPhotos(keeping:)` | The whole-live-roll form: `finishSessionPhotos(keeping:of:)` over every listed id, so the list empties and the teardown after it has nothing to promote. |
| `photosAwaitingAnswer(among:)` | What the in-camera Develop review renders: the snapshotted ids still held, live ones first, then the ones the ending moved into the batch. |
| `finishReviewedPhotos(_:keeping:in:)` | The post-session review's answer for a PROMOTED batch's photos (2026-09-30): of the ids the sheet showed and still held, the kept are copied to the wall and the rest deleted, all through `applyPhotoAnswers`. Scoped to what was shown — a photo promoted while the sheet was up stays pending — and a stale batch id answers `.nothing`. Clears the batch once neither half has anything left. Returns the `SessionPhotoAnswer`. |
| `applyPhotoAnswers(kept:discarded:now:)` | **The one answer engine** (2026-09-30), ids are LOCAL ids. Refuses everything unless the routed gate is open (`unavailable`); re-reads deferred indexes; refuses keeps while the wall index cannot be read (`keepUnavailable`) while discards proceed; hydrates kept photos from the pending corpus and commits them with `PrivateMediaStore.commitKept(_:onto:)` (REPLACING `meshPhotos` with the committed wall), so only photos whose bytes landed are `keptOnWall` and the rest stay held (`wallWriteFailed`); a kept photo whose held bytes are GONE (`PendingSessionPhotoStore.readImage(for:)` → `.gone`: missing, or not opening under a present key) is `unreadable` and answered like a discard, while one that cannot be read RIGHT NOW (`.unavailable`: no key, a file read that failed) stays held and the answer says `unavailable` (fix round 1: a ticked photo is never lost to a transient read); then ONE pending index write removes and tombstones every answered photo (a failed write still updates the mirror — `PendingSessionPhotoStore.answering`). Helpers: `keepHeldPhotosOnWall`, `readHeldPhotosForKeep`, `keepFailure(notLanded:unavailable:)`, `commitHeldPhotoAnswers`, `forgetAnsweredHeldPhotos`. |
| `retryDeferredPhotoIndexes(now:)` / `reconcileHeldPhotosIfReady(now:)` | Re-read a wall or pending index that a locked launch could not (at a rising gate edge, and atop every hold and answer); then, once BOTH are readable, drop held entries the wall already has (the answer's crash window) and offer the rest as awaiting — the launch rebuild. A wall still unreadable with protected data AVAILABLE is persistent: the held photos are offered anyway, with keeps refused. |
| `reviewThumbnailData(for:)` / `reviewImageData(for:)` / `heldPhotosCanBeShown` / `wallCanTakeKeeps` / `hasOutstandingPhotoReview` | The review's reads: the only door to pending bytes, gated on the routed access gate (so duress draws nothing); whether held photos may be drawn and answered now (observed mirror); whether Keep can be offered; whether ended-session photos are waiting. Since U3 their reader is the app's `SessionPhotoReviewCoordinator` (the gate's `heldPhotosCanBeShown` leg, the snapshot's `canKeep`, and `blocksDiscovery`'s outstanding leg — the run policy's `sessionPhotoReviewBlocksDiscovery`). |
| `purgeHeldSessionPhotosForDeleteAll()` | Delete-all leg 4d: empties the live roll, the mesh's live roster (`MeshNetworkManager.clearSessionRoster()`, in the same step), the WHOLE batch (candidates too) and the mirror, and removes `PendingSessionPhotos/`. The wall is untouched. |
| `invalidateEncryptionKeyCaches()` | Drops both corpora's cached encryption keys — the wall's (`Role.friendWall`) and the pending corpus's (`Role.pendingSessionPhotos`) — so a post-wipe write cannot use an orphaned key: the app's delete-all funnel calls it right after the mesh's `wipeIdentityForDeleteAll()` and before presence's identity wipe, in the same `do`. The key rows survive. |
| `pendingReviewPhotos` | The pending batch's photos still held — what `ConnectView`'s review offers. |
| `completeFriendReview(_:)` | Answers the batch's CANDIDATE half only: a batch still carrying unanswered photos stays up (entries emptied) and re-presents for them; it clears once no photo is pending. Photos no longer held are dropped here. |
| `promoteEndedSessionIntoPendingReview(drainedRoster:)` | The session-end leg the composition's observer runs first (`meshSessionDidEnd(_:)`; was `promoteSessionToPendingReviewIfSessionEnded()`): when the mesh's `isSessionLive` is false, merges the roster the mesh drained (`MeshSessionEnd.drainedRoster`) into the batch (`promoteRosterIntoPendingReview(_:)`) and MOVES `sessionPhotos` into `batch.photos` (`movePhotosIntoPendingReview()`, which stamps the ended session's metadata first, is capped at the pending corpus's bound, and WRITES NOTHING — both lists are memory projections of the pending index). Candidates and photos are never dropped. |
| `beginNewPhotoSession()` / `forgetPhotoSession()` / `noteScopeChange(_:)` / `dropRemovedMemberFromReview(fingerprint:)` / `applyAccessGate(isRising:now:)` | The observer's other photo legs: a new search resets the film and its mesh pin, moves a photo still listed into the pending review — never dropping it — and only then mints the new photo session's ids; a left session forgets those ids, after the ending stamped its photos with them; a scope change moves the film's mesh pin; an approved removal takes the member out of any unconsumed batch; a changed access gate re-reads the indexes on a rising edge before the re-entry pass the edge owes, and recomputes `heldPhotosCanBeShown`. The gate itself is never copied: every held-photo decision reads the mesh's own `routedAccessGate` (`.closed` with no mesh), which the mesh stores before it logs the change or tells the observer (plan step A0.5.13). |
| `deleteAllSessionPhotos()` | Finishes the session while keeping no photos. |
| `deletePhoto(_:)` | Permanently removes one KEPT photo from the wall: drops it from `meshPhotos`, clears any wall preference that pointed at it, re-saves the index so the store's orphan sweep deletes its files, and tombstones its identity (sender fingerprint + id) for 24 hours so a routed copy still in custody cannot come back. |
| `removeReportedPhoto(_:)` | **App Review guideline 1.2 (2026-10-15)**: the photo's half of Report… — a HELD photo is answered as declined (`applyPhotoAnswers` with it discarded: deleted for good, gone from both memory lists), a wall photo goes through `deletePhoto(_:)` with its tombstone. Answers whether nothing of it is left; reporting the sender is the app's people report. |
| `imageData(for:)` | Reads full image data for a WALL photo (never a held one — see `reviewImageData(for:)`). |
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
| `persistPhotoWallPreferences()` | Saves wall preferences through this object's `JSONSidecarFile<FriendPhotoWallPreferences>`. |
| ~~`cachePhoto(_:includeInSession:)`~~ | **Retired 2026-09-30**: it put every session photo on the wall at capture or receipt. `holdSessionPhoto(_:key:live:)` replaced it for both producers. |
| ~~`isPhotoFromCurrentSession(_:)`~~ | **Retired 2026-09-30** with its last caller: it keyed "live" on the peer-supplied optional `header.session`; the photo arm asks the mesh's `isSessionLive && delivery.meshID == currentMesh?.meshID`, the SIGNED mesh id. |

### `FernletSocial/Mesh/MeshSessionReviewTypes.swift`

| Type | What It Is |
| --- | --- |
| `MeshFriendReviewBatch` | A promoted, unconsumed session-end review (Phase 2): the ended session's keep-as-friend candidates and the photos the user has not yet chosen between (`photos`, metadata-only, newest first, each id its LOCAL id in the pending corpus; none is on the wall). `isEmpty` when nothing is left to answer. Deliberately not `Codable`. |
| `SessionPhotoAnswer` / `SessionPhotoAnswerFailure` | What one answer did, photo by photo (local ids: `keptOnWall`, `discarded`, `unreadable`, `notApplied`, and the `failure`), and why it could not be applied in full: `unavailable` (locked, backgrounded, duress, or an index or a kept photo's bytes not readable right now — those stay held), `keepUnavailable` (the wall's index cannot be read; discards applied) or `wallWriteFailed` (the wall did not take some keeps; they stay held). `nothing` answers a stale batch. |

### `FernletSocial/Mesh/MeshRoutedPhotoBody.swift`

| Type / Function | What It Does |
| --- | --- |
| `MeshRoutedPhotoBody` | A routed photo's plaintext, a `MeshRoutedBody` over ProximityKit's framing: `maxHeaderJSONByteCount` (64 KiB) and the derived `maxFramedHeaderByteCount` — an **allowance, not a refusal**: the point of the number is the photo row's ciphertext cap as a formula. A header past it eats the payload's room and the sealer refuses the whole plaintext by name. `theHeaderAllowanceCoversAMaximalHeader` measures it against the widest well-formed header (32 participants at the shared name bound) rather than asserting it. `routedItemID` is `header.id`. |
| `MeshRoutedPhotoHeader` | `id` (MUST equal the manifest's item id; the engine's opener refuses a body whose id is another), `addedAt`, `senderName`, `session`. Frozen JSON keys; unknown fields ignored on decode (invariant 8). |
| `MeshRoutedPhotoBody.encoded()` | `u64BE(headerJSON.count) ‖ headerJSON ‖ imageData` — the image RAW, never base64. Encoding the whole struct as one `Codable` value would ship the JPEG at 4/3 its size, silently re-scaling `manifest.size`, the chunk count charged against item 9's caps, the per-peer frame budget, the resident bound, and the very number tier 2 exists to measure (D-13.20). |
| `MeshRoutedPhotoBody.init(decoding:)` | Reads the `u64`, **bounds it against the remaining bytes before slicing** (a hostile prefix yields `malformed`, never a trap or a truncated read), decodes the header, and takes the rest as the image — no second length prefix, because the image runs to the end. |

### `FernletSocial/Mesh/MeshContentLedger.swift` / `MeshContentIngest.swift`

P4 item 7's content kinds and their ledger, over ProximityKit's generic `MeshContentSet`
(`MeshContentMerge.swift`), and the ingestion gates re-run at the receiving member. Pure values, nothing
persisted, nothing on the wire. The merged heart is `HeartSharing/MeshMergedHeart.swift`, beside the
heart ledger.

| Type / Function | What It Does |
| --- | --- |
| `MeshMergedPhoto` / `MeshMergedMessage` / `MeshMergedHeart` / `mergeKey` | The three projections, each identified by `mergeKey` = `(senderFingerprint, contentID)` — derived on the protocol so no conformer can weaken it. The photo carries `keyEpoch` through untouched (§21.5's P5 handoff) and a **local** SHA-256 digest, not a wire field. The message carries both clocks — the untrusted `claimedSentAt` and the receiver's `firstSeenAt`. The heart carries **no** receipt field: a peer's receipt is not this member's. |
| `MeshMergedMessage.clamped(_:around:)` / `claimWindow` | The ±10-minute clamp. A claim inside its window is returned unchanged, which is why honest traffic sorts identically at every member; a forged stamp moves at most 10 minutes from where it actually arrived. |
| `MeshContentLedger` | Three sets and nothing else — the content twin of `MeshMembershipLedger`. `merging(_:)` is set union in all three kinds, so an N-way partition tree converges with pairwise merges only. |
| `MeshPhotoReassembly.digest(of:)` / `verdict(reassembled:expecting:)` / `admitting(_:reassembled:into:)` | §10.3's "hash-validated on reassembly". `admitting` returns the set **unchanged** unless the bytes validate, so "silently kept" is not a reachable state; `rejectedEmpty` and `rejectedDigestMismatch` are named, not silent. |
| `MeshContentGates` / `folding(chatAllowed:senders:isRefused:)` / `admits(_:)` | §21.3's decision as a value: the 13+ chat gate and the local block/ban, folded once from the seams that already enforce them (`MeshSessionChat.isChatAllowed`, `ProximityHost.isBlockedFingerprint`, `ModerationBanStore.isPeerBanned`). Local by construction — two members may hold different gates over one union. |
| `MeshContentLedger.visibleTranscript(gates:)` / `visiblePhotos(gates:)` / `visibleHearts(gates:)` / `senders` | The gates as a **view filter over an unmutated union** — same shape as termination-derived-at-read. A blocked sender's message still unions; it simply does not render at the member that blocked them, and re-opening the gate reveals it with no second merge. |
| `MeshHeartReceipt` / `MeshContentLedger.heartReceipt(_:committed:)` | `pending` / `received`, frozen tokens. The union alone answers `pending` for everything. |

### `FernletSocial/Messaging/MeshSessionChat.swift`

The live-session chat (Phase 5; FernletSocial's since plan step A0.5.9): the session transcript
(`sessionMessages`, a `SessionMessageStore`), the 13+ gate, the text sender and, through a private
adapter, the temporary-message row's projection handler.

| Function | What It Does |
| --- | --- |
| `sendTempMessage(_:)` / `noteTextSendOutcome(_:)` / `MeshTextSendOutcome` | **P6 item 4**: the send is the same three lines `MeshSessionPhotos.shareRoutedPhoto` uses — the text row's token (behind the mesh's `isRoutedTypeRegistered(_:)`) → frame a `MeshRoutedTextBody` → the mesh's `originateRoutedItem`, which pushes the item. Order matters: sanitize (500 `Character`s) → `boundedText` (the wire's byte bound) → **re-check emptiness**, because the byte bound can empty a message the Character cap admitted. The byte bound TRUNCATES rather than refuses, and since item 4's fix review it audits `mesh.routedShare.textByteBounded` when it bites: the bounded text is what is minted *and* what the local echo shows, so the user sees a shortened row with no label, and "never a surprise refusal for honest input" is bought with a silent edit. It RETURNS its outcome and publishes nothing on the mesh's `routedShareRefusal`: that observable's one consumer is a `.alert` on the `DisposableCameraView` the chat panel is presented over, and its copy is photo-worded in every arm. No `@discardableResult` — an unread outcome is a message the user believes was sent. `.noDestinations` is visible for text and silent for photos, because destinations are frozen at the mint and there is no offline queue. The legacy per-slot sealed fan-out, the `messages` capability read and the live-slot requirement are all retired with it. |
| `chatAllowedProvider` / `isChatAllowed` | The 13+ age gate (see `AgeAssuranceRecord`): nil means NOT allowed, so a chat nobody wired stays silent. Resolved once per decision point so the four enforcement seams — advertisement, send, projection, view — never disagree; public so the in-session UI withholds the chat affordance from the value the transport enforces. |
| `makeProjector()` (the text row's projection handler) / `routedCanonicalDispatch(…)` | The handler the composition registers under the host's text row's token (plan step A0.5.9, S9). Its `isProjectable` and pre-open verdict are the 13+ gate's legs 4 and 3 — FINAL, and before the unwrap, so a device below the line decrypts nothing — and its write, the text arm (P6 item 4), produces the effects the legacy `.tempMessage` handler produced, through `SessionMessageStore.receiveIncoming`: dedup, the sanitizer, the display-name moderation, the cap and §10.3's ordering all stay in the store, and the arm adds only what the store cannot know — the delivery's `sessionLiveness` (the engine's `transcriptLiveness`) and `allowIncomingRoutedText`. Takes no clock. W2's FernletSocial half pins the arm to its handler's write. |
| `allowIncomingRoutedText(_:from:)` / `routedOriginTextQuota` / `maxTextMessagesPerSenderPerSession` | The TEXT quota (P6 item 4, 200 per origin per mesh) is a **policy act**: it replaces the live-arrival token bucket, which was wrong twice over on a store-and-forward path — a drain answer carries up to 16 items, so a burst allowance of 5 flood-dropped 11 legitimate messages, and a fixed per-item first-seen makes the refill interval zero forever. A per-second rate limit is therefore replaced by a per-session TOTAL; the drain's 16-item answer and its pacing are the rate. Keyed on the item's signed mesh (`MeshRoutedDelivery.quotaKey`), re-sends of an accepted id free, bounded at 1024 keys × 200 ids, and `internal` rather than `private` so its three legs have a behavioural cell (`MeshRoutedTextDeliveryTests.theIncomingTextQuotaRefusesPastItsCapAndIsFreeForAReSend`). |
| `clearTranscript()` | Drops the live transcript (messages vanish): the composition's observer calls it at a session's end, the next formation and a privacy wipe's start, each right after the mesh advanced its session-content generation there, so an item offered before the drop never projects into what follows it. Memory only. |
| `refreshVisibleTranscript()` | Re-folds the transcript's view gates (13+ and the block list) from the live seams and re-derives it: the text arm calls it at every ingest, and the app right after an in-session Report (2026-10-15), so the reported author's rows leave at once. |
| `sendFilterList` / `MeshTextSendOutcome.filtered` | **App Review guideline 1.2 (2026-10-15)**: `sendTempMessage(_:)` runs `SessionMessageFilter.refuses(_:list:)` over the sanitized draft after the empty check and before the frame and mint, answering `.filtered` (not audited). `sendFilterList` is `.shipping` in the app — a test seam for placeholder lists. |

### `FernletSocial/Messaging/MeshRoutedTextBody.swift`

| Type / Function | What It Does |
| --- | --- |
| `MeshRoutedTextBody` / `MeshRoutedTextHeader` | A routed temporary message's plaintext (P6 item 4): the header (`id`, the untrusted `sentAt` claim, `senderName`) and the text RAW, a `MeshRoutedBody` over ProximityKit's framing. `maxTextUTF8ByteCount` is the sanitized maximum's own byte bound (16 × `SessionMessageStore.maxTextLength`, because the product's cap is 500 *Characters*), and `maxSealedBlobByteCount` (9 065 B) the text row's cap as a formula; `boundedText(_:)` and `boundedSenderName(_:)` keep the mint inside its own row. |
| `MeshRoutedItemBodyFormat.maxTextHeaderJSONByteCount` / `maxFramedTextHeaderByteCount` | The text family's header allowance, an extension of ProximityKit's framing beside the family it bounds. |

### `FernletSocial/Messaging/SessionMessageStore.swift`

Messages are exchanged ONLY during a live friend session and VANISH at session end — an owner
decision, and a binding one: nothing retained on device, nothing synced, no dead-drop, no offline
queue. This type is the only in-memory holder, and it is deliberately **not `Codable`**, so it is
structurally impossible for a message to enter a `FernletSnapshot` (same technique as
`MeshSessionRosterEntry` / `MeshFriendReviewBatch`).

| Function Or Property | What It Does |
| --- | --- |
| `appendOutgoing(...)` | The local echo for `MeshSessionChat.sendTempMessage(_:)`, appended **only on `.staged`** since P6 item 4: a photo's echo is unconditional because it is on the user's own wall either way, but a row in a transcript is a claim that the message was sent and the transcript has no failed-row state. Own messages need no clamp — claimed and first-seen are both this device's clock. |
| `receiveIncoming(...)` | Inbound from the text row's projection handler since P6 item 4 (the chat's arm, `MeshSessionChat`; the author is the signed `manifest.originFingerprint` resolved against `admissions − removals`, with the block list applied **before** the unwrap; the legacy `.tempMessage` dispatch and its per-sender token bucket are retired): de-dupes by **`(senderFingerprint, id)`** — the pair, not the id, since item 4's fix review found that keying on the id alone let one admitted member consume another's dedup slot — sanitizes, caps, re-moderates the body's display-name claim under the peer-name policy of the namespace it is handed last (the chat's host's), and answers a three-way `Acceptance`. `seenAt` is required, never defaulted. |
| `sanitize(_:)` (`static`) | The one text-coercion point for both directions. |
| `Message.senderSigningPublicKey` / `Message.canBeReported` | The author's verified signing key, threaded from the projection's `delivery.author` (2026-10-15; empty for this device's own rows) — the key the app's Report… names; `canBeReported` is inbound-and-keyed. |
| `hasUnread` / `beginViewing()` / `endViewing()` / `markAllRead()` | Unread signalling for the Friends tab. |
| `clear()` | Reached only through the chat's `clearTranscript()`, which the composition's session observer calls right after the mesh advances its session-content generation: every session-end path, the next session formation, and the app's delete-all via the mesh's `beginPrivacyWipe()`. Unlike the shop's post-session window, messages do not outlive the session. |

### `FernletSocial/Messaging/SessionMessageFilter.swift`

App Review guideline 1.2 (2026-10-15): the chat's on-device send filter. The list is SHA-256 digests
of each entry's matching form (the repository is public); received messages are not filtered.

| Function Or Type | What It Does |
| --- | --- |
| `refuses(_:list:)` | Whether a draft holds a listed whole word; `.shipping` by default. Empty and whitespace input answers false. |
| `words(in:)` / `word(from:)` / `Word` | The normalization: NFKC, case and diacritic folding, split at every scalar not a letter, digit or `@ $ !`; per word, edge `!` dropped, substitutions undone, runs of a repeated letter collapsed (`hadRepeatedLetter`). Bounded at `maxScannedScalars`. |
| `List` (`anySpelling`, `doubledSpelling`, `init(words:)`, `contains(_:)`, `.shipping`) | The digest sets; a doubled-spelling entry matches only a word that held a repeated letter, so no innocent single-letter spelling collapses onto it. `init(words:)` is for tests' placeholder words only. |
| `entry(for:)` / `digest(of:)` | The extension tool: one word's digest and set; lowercase hex SHA-256 of the form's UTF-8. |

### `FernletSocial/HeartSharing/MeshSessionHearts.swift`

The in-session hearts (TF b19 item 5; on the routed store since P6 item 6; FernletSocial's since plan
step A0.5.10): the send to one recipient, its state and failure vocabulary, the in-flight claims and,
through a private adapter, the heart row's ledger judge.

| Function | What It Does |
| --- | --- |
| `sendSessionHeart(to:)` / `canSendSessionHeart(toFingerprint:)` | One heart over the ROUTED store to one recipient: framed as a `MeshRoutedHeartBody` and originated through the mesh's door with `.recipient(_:)` under the heart row's token. The affordance asks whether the friend is a member this device can ADDRESS — the mesh's `isAddressableRoutedRecipient(_:)` — not whether they are linked. Hearts off, an unloaded ledger, the cooldown and an in-flight claim refuse before any mint. |
| `hasLiveHeartSlot(forFingerprint:)` | Whether a friend holds a LIVE committed slot advertising `hearts`, by the capability's token — the question `canSendSessionHeart` used to answer, kept as its own seam. |
| `SessionHeartState` / `SessionHeartFailure` | The send's observed feedback, and why a heart was not sent as a frozen English token (`heartsOff`, `ledgerUnavailable`, `cooldown`, `alreadySending`, `recipientLeft`, `notReachableYet`, `identityUnconfirmed`, `couldNotSend`, `storageUnreachable`, `holdingAllItCan`); the app forks each into copy (`SessionHeartStatusCopy`). |
| `heartLedger` / `onHeartSent` | The device-local ledger SHARED with presence, set by the app (nil: send and receive no-op), and the closeness hook the app wires, the same one presence feeds. |
| `makeJudge()` (the heart row's ledger judge) | The `MeshRoutedLedgerJudge` the composition registers under the heart row's token (plan step A0.5.10, S10): `isReadyToJudge` is nearby hearts on and the ledger loaded (both reversible, so never a mark); `admits(_:)` is the trust-vault leg, `FernletSocialHost.isTrustedUnblockedPeer` asked with the admission ledger's key, FINAL as `notAFriend`; `judgeRoutedItem(_:delivery:)` is the ONE ledger door (`MeshHeartCommit.commit`), the closeness feed on the gift's first acceptance (above the proof guard, because `commitProof` answers for an already-stored gift and `recordHeartReceived` is not idempotent), and `committed` only when `MeshRoutedHeartAck`'s proof gate holds — else `notYet` (the five-minute cooldown, or a write that has not landed). |
| `resetSessionHeartState()` | Drops the feedback and the in-flight claims: the session ended, the ending's last observer leg. |

### `FernletSocial/HeartSharing/MeshRoutedHeartBody.swift` / `MeshRoutedHeartAck.swift` / `MeshHeartCommit.swift` / `MeshMergedHeart.swift`

| Type / Function | What It Does |
| --- | --- |
| `MeshRoutedHeartBody` / `MeshRoutedHeartHeader` | A routed heart's plaintext — the header and **nothing else** (P6 item 6): the gift id (which IS the manifest's item id, the frozen `itemID == giftID` contract), the sender's claimed day and display name. `maxSealedBlobByteCount` is the heart row's cap as a formula with a zero payload term; `bounded(senderName:)` keeps the mint inside its own row. |
| `MeshRoutedHeartAck` / `init?(outcome:giftID:proof:)` / `init?(outcome:giftID:ledger:)` | The heart's proof that the ledger stands behind THIS gift: judged exactly once **in this outcome** (per-GIFT, because `MeshHeartCommit.commit` is a batch door and a per-pass count would strand both hearts of a two-heart pass) plus the ledger's own `MeshHeartLedgerProof`. The `@MainActor` `ledger:` form asks the ledger synchronously, right after the commit. Built once, in the heart judge's `judgeRoutedItem`; it is the judge's proof gate, not the stage's evidence, which the engine mints from the judge's `committed`. |
| `MeshHeartCommit.commit(_:into:)` / `MeshHeartCommitOutcome` | Drives merged hearts through the **existing** `ProximityHeartLedger` — its id-dedup, its 5-minute per-sender cooldown — rather than a second copy of them. `judgements` is one per distinct gift id: a duplicate that crossed the split is collapsed by the union *before* the ledger sees it, so the cooldown is judged once. **It is a BATCH counter and must never be the exactly-once witness** — `MeshRoutedHeartAck.judgementsForGift` is, and `MeshRoutedAck.swift` forbids `outcome.judgements == 1` by name. P6 item 6's ceremony hands this a ONE-element batch, so the two coincide at every shipping call site: an invariant written against the batch counter is green for an accident of that call site forever, which is why the heart cells count `onHeartJudgedForTesting` firings per gift and carry a fixture-only two-heart batch proving the fields differ. |
| `MeshMergedHeart` | The merged heart kind (a `MeshMergeableContent`): gift id, sender fingerprint and name, and the receiver's `firstSeenAt`; it carries **no** receipt field, because a peer's receipt is not this member's. |

### `FernletSocial/HeartSharing/ProximityHeartLedger.swift`

The device-local ledger every heart transport shares — presence, the session hearts
(`MeshSessionHearts`, over the routed mesh) and the dead-drop all rate-limit and de-dupe through this
one type. Persistence rides ProximityKit's `ProtectedSidecar`.

| Function Or Property | What It Does |
| --- | --- |
| `init(fileURL:now:readData:writeData:)` | Opens the ledger over the file its caller states: `fileURL` has no default, so no ledger lands on a process-wide path (the app passes `fileURL(in:)` of its store's own proximity root, every test a file of its own). |
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

### `FernletSocial/HeartSharing/HeartDropService.swift`

| Function | What It Does |
| --- | --- |
| `queueHeart(to:)` | The entry point: picks a prekey (or the static key), seals, and enqueues — returning a `QueueOutcome` that includes `storageUnavailable` when the sidecar refuses to persist, so nothing is silently dropped. |
| `currentLocalBundle()` / `storePeerBundle(_:friendSigningKey:)` | Gossip the local prekey bundle and cache a peer's; a peer bundle is only ever stored from a verified, signed identity intro. |
| `syncNow(force:)` / `syncOnce()` | Trigger a sync pass; coalesced internally so overlapping calls collapse into one run. |
| `flush(_:)` | Uploads pending drops and **stops and surfaces** when a record name cannot be persisted — the fix for orphaned public-DB records. |
| `fetchIncoming(_:)` / `openIncoming(_:expectedSender:)` | Fetch a friend's tag window and open drops, re-gating wire size before key agreement. |
| `pendingCount(for:)` / `acknowledgeDeliveryProblem()` | Surfacing hooks for the two UI paths. |
| `cleanup(_:)` | Expiry sweep of this device's own uploaded records. |

### `FernletSocial/HeartSharing/HeartDropSealer.swift`

| Function | What It Does |
| --- | --- |
| `HeartDropSealer.seal(...)` | Builds the versioned wire form `[version][prekeyID (all-zeros = static key)][ciphertext]`. |
| `HeartDropSealer.open(...)` | Opens a drop, **gating payload size before key agreement** (the ordering the coach path still needs to adopt for `TrainerExportPayload`). |

### `FernletSocial/HeartSharing/HeartPrekeyStore.swift`

Its `Bundle`, `PrekeyEntry` and `SignedPrekey` are typealiases of ProximityKit's wire type
`ProximityPrekeyBundle` (`Wire/ProximityPrekeyBundle.swift`, under "Hearts") and its two nested
types, so the bundle the store mints is the very type the identity introduction carries, and the
keychain blob (under `com.fernlet.heartdrop`, through FernletFoundation's `KeychainItem`) and the
peer-bundle sidecar hold its JSON.

| Function | What It Does |
| --- | --- |
| `currentBundle()` | The local bundle of one-time X25519 prekeys plus the X3DH-style signed prekey, minted in batches of 16. |
| `privateKey(forPrekeyID:)` | Resolves a private half for opening; private halves live in one keychain blob (`AfterFirstUnlockThisDeviceOnly`, never synchronizable). |
| `pruneRetainedKeys()` | Ages out keys past the 29-day retention window. |
| `wipeForDeleteAll()` | Delete-all coverage — identity/prekey material must die with the wipe. |

### `FernletSocial/HeartSharing/HeartDropOutbox.swift`

| Function | What It Does |
| --- | --- |
| `enqueue(_:)` / `hasCapacity(forFriendSigningKey:)` / `hasDailyCapacity(...)` | Bounded, per-friend and per-day admission. |
| `pendingUploads()` / `markUploaded(id:recordName:)` / `recordAttempt(id:)` | The upload cycle; `markUploaded` reports persist failure to the caller rather than swallowing it. |
| `expiredEntries()` / `remove(ids:)` / `removeUnchanged(_:)` | Expiry and compare-and-remove, so a concurrent enqueue is not clobbered. |
| `snapshot()` / `uploadedRecordNames()` | Return **`nil` when the sidecar is unloaded** — never an empty array, which would read as "nothing queued". |
| `retryLoad()` / `acknowledgeDataLoss()` / `wipeForDeleteAll()` | Recovery and wipe hooks. |

### `FernletSocial/HeartSharing/HeartDropPeerBundleCache.swift`

| Function | What It Does |
| --- | --- |
| `store(bundle:forFriendSigningKey:)` | Caches a gossiped bundle keyed by the sender's full signing key. |
| `consumePrekey(forFriendSigningKey:)` | Consumes a one-time prekey, falling back to the signed prekey and then the static key. |
| `returnPrekey(id:forFriendSigningKey:)` | Returns a prekey when the send that reserved it fails, so a failed send does not burn forward secrecy. |
| `retryLoad()` / `wipeForDeleteAll()` | Recovery and wipe hooks. |

### `FernletSocial/HeartSharing/HeartDropSidecarKey.swift`

| Function | What It Does |
| --- | --- |
| `HeartDropSidecarSeal.make(keychainService:)` | The keychain-backed ChaChaPoly seal for the sidecars at rest — plaintext versions were a timestamped log of who the user sent affection to. Read-back verified; one-way plaintext→sealed migration (that leg SURVIVES — it is the v0 plaintext generation, not the retired ciphertext one); protection class stays `.completeFileProtection`. Requires `FSC2` since crypto-standardization Phase 3: an `FSC1` row is refused as `SidecarSeal.SealError.legacyFormatRetired`, audit-logged before it is thrown so `ProtectedSidecar` quarantines rather than defers forever, and the Phase 2.2 migrator went with the reader it converted through. `legacyMagic` and its `isSealed` clause are KEPT and load-bearing — that predicate is what splits sealed from plaintext-v0, so a marker that stopped classifying would send ciphertext down the plaintext branch into the *corrupt* path. Every caller states its service (via `HeartDropStorageScope`); there is deliberately no argument-less production variant. |

### `FernletSocial/HeartSharing/HeartDropStorageScope.swift`

| Function | What It Does |
| --- | --- |
| `HeartDropStorageScope(directory:keychainService:)` | One device's heart-drop storage identity. Both halves together because `HeartDropService.wipeForDeleteAll()` destroys both — files on a private root sealed by a shared key survive another store's wipe as ciphertext nothing can open. |
| `HeartDropStorageScope.production` | `Application Support/Fernlet` + `com.fernlet.heartdrop`, the paths and service the stores have always used: the directory is `FernletConnections`' `FernletProximityStorage.productionDirectory`, `.fernlet`'s folder under Application Support. Only tests redirect it, and never by unsealing — a scoped store still seals through the real key path. |
| `HeartDropOutbox.fileURL(in:)` / `HeartDropDedupStore.fileURL(in:)` / `HeartDropPeerBundleCache.fileURL(in:)` / `ProximityHeartLedger.fileURL(in:)` | One definition per sidecar of its file name inside a root, so the production default and a scoped root can never disagree. |
| `ModerationLedger.fileURL(in:)` / `FriendStateCache.fileURL(in:)` / `ClosenessLedger.fileURL(in:)` / `ProximityActivityManager.fileURL(in:)` | The same seam for the four `JSONSidecarFile` stores, all FernletSocial's and all cleared by `FernletStore.resetAll` (and `FriendStateCache` also by turning fuzzy-state sharing off). Unsealed, so a root is the whole fix — no keychain half. |
| `JSONSidecarFile.fileURL(in:name:)` | The one definition of the sidecar layout. There is deliberately no argument-less `defaultFileURL(name:)`: every owner states its root, or the omission silently rejoins the process-wide race. |

### `FernletSocial/HeartSharing/HeartDropSidecarFormatCensus.swift`

| Function | What It Does |
| --- | --- |
| `HeartDropSidecarFormatCensus.survey(in:)` (a directory or a `HeartDropStorageScope`) | Read-only census of the four known files (outbox, peer bundles, dedup, the outbox's quarantine), each named by the store that owns it, classified by its four marker bytes alone: `v2Sealed` (`FSC2`), `legacySealed` (`FSC1`), `unsealedOrUnrecognized`, `empty`, `unreadable` (indeterminate, never zero) or `absent`. Reads no keychain row and decodes nothing. |
| `Report.isConclusive` / `isClean` | Conclusive only when every file was read; clean only on positive evidence (nothing legacy, nothing unrecognized, nothing unread). The app's DEBUG crypto-format census and Phase-3 gate readout read it. |

### `FernletSocial/HeartSharing/IdentityService+HeartDrop.swift`

The dead-drop's derivations, as extensions of ProximityKit's `IdentityService` with the names and signatures they always had, so every caller kept its spelling. `FernletFeatureGoldenTests` pins each to known answers.

| Function | What It Does |
| --- | --- |
| `IdentityService.heartDropDayEpoch(at:)` | `floor(unixTime / 86 400)`: the UTC day the day tags rotate on. `nonisolated`. |
| `heartDropPairSecret(with:)` | The pair secret both friends derive: `IdentityService.pairSecret(with:purpose:)` under `FernletFeaturePurposes.heartDropPairV1` (`fernlet.heartdrop.v1`). Throws `notProvisioned` first when the identity holds no key-agreement key, then `sealFailed` for a friend key that is not a raw X25519 key (the error the dead-drop's audit lines name), then the door's own. |
| `IdentityService.heartDropTag(pairSecret:dayEpoch:senderKeyAgreementPublicKey:)` | A drop's record tag: HMAC-SHA256 keyed by the pair secret over `fernlet.heartdrop.day.v1` ‖ be64(day) ‖ the SENDER's key-agreement key, its first 16 bytes as lowercase hex, so a pair's two directions differ. `nonisolated`. |
| `TagCounterBytes.bigEndian(_:)` (internal) | The eight big-endian bytes of a counter, byte-identical to `withUnsafeBytes(of: value.bigEndian)`; FernletSocial's presence tag uses it too. |

### `FernletSocial/HeartSharing/MeshStorageScopes+HeartDrop.swift`

| Function | What It Does |
| --- | --- |
| `MeshSessionStorageScope.keychainService(besideHeartDrop:in:)` / `MeshRoutedStorageScope.keychainService(besideHeartDrop:in:)` | Production heart-drop service in ⇒ the namespace's `meshSessionSealKey` / `meshRoutedSealKey` service out; any isolated heart-drop service ⇒ `<service>.mesh-session` / `<service>.mesh-routed`. This is what lets `FernletStore` DERIVE its two mesh scopes from seams the test walls already enforce instead of adding a fourth injectable one. `nonisolated` (`FernletStore`'s scope properties are). |

### `FernletSocial/Moderation/ModerationReportRelay.swift`

Reported clothing designs. The honest-client half (a self-ban stops this device listing) is convenience;
the load-bearing enforcement is receiver-side: the relay below hands only verified rows on, and the
ledger it feeds, the ban store and the content hash follow.

| Function Or Type | What It Does |
| --- | --- |
| `SignedModerationReport` | One row plus the reporter's Ed25519 signature over its canonical bytes. |
| `ModerationReportPayload` | The sealed wire bundle of the sender's OWN signed rows (capped at `maxReports` = 32), carrying retractions alongside reports so an undo propagates to peers who already stored the original. |
| `buildPayload(ownReports:identity:)` | Called by `ModerationReportExchange` at a slot commit (the composition's observer leg). A reporter hands over only rows they personally signed. |
| `verifiedRows(from:senderSigningKey:now:)` | The `.itemReport` handler's gate: stores only rows the TRANSPORT-VERIFIED sender signed. |

**No transitive relay** is the Sybil defense — each device tallies only over reports it verified
itself. Stateless namespace enum; storage is owned by FernletSocial's `ModerationLedger`.

### `FernletSocial/Moderation/ModerationReportExchange.swift`

| Function | What It Does |
| --- | --- |
| `registerHandler(on:)` | The `.itemReport` handler, through the mesh's payload token door: the committed-slot gate has run; it requires a transport-verified, unblocked, vault-TRUSTED sender (reports count only from friends accepted in person — the Sybil defense), then `verifiedRows` re-checks each row's signature against the sender key and hands the survivors to `onModerationRowsReceived`. Holds the exchange weakly. |
| `offerReports(to:peer:)` | The commit-time send, from the composition's observer: this device's own signed reports (`ownModerationReportsProvider`, through `ModerationReportRelay.buildPayload`) to a committed friend that advertises `moderation` and is vault-trusted, signed with the mesh's identity. |

### `FernletSocial/Moderation/ModerationContentHash.swift`

| Function | What It Does |
| --- | --- |
| `ModerationContentHash.of(texture:slot:)` / `of(_ item:)` | SHA-256 over an item's sanitized ARTWORK — never its id, name, or price — so a designer cannot escape a report by relisting the same artwork under a new id. Pure stateless namespace enum, CryptoKit only. |

### `FernletSocial/Moderation/ModerationLedger.swift`

Device-local, append-only store of report rows: this device's own reports and retracts, plus peers'
one-hop-verified rows. It is the evidence base `ModerationBanStore.reconcile(...)` reads.

| Function | What It Does |
| --- | --- |
| `recordLocalReport(...)` / `recordLocalRetract(...)` | This device's own rows. Rows carry a deterministic `ModerationLedgerEntry.rowID`, so a repeat report de-dupes and a retract supersedes its report via a higher `reporterSeq`. |
| `ingestForeign(_:)` | Upserts peer rows, keeping the higher-seq row — which makes re-delivery idempotent. |
| `isLocallyReported(contentHash:reporterFingerprint:)` | The shop's hide-reported-items check. |
| `clearAll()` | Reset-everything. |

Its file is the one its caller states (`init(fileURL:now:)` has no default; the app passes
`fileURL(in:)` of its per-store proximity sidecar root). Bounded MAX-MIN FAIRLY rather than by age
(Power-of-10 R3): at most `maxRowsPerReporter` per reporter fingerprint and `maxRows` overall, and
on overflow the per-reporter allowance is lowered uniformly
until it fits — so a flooding reporter is drained down to everyone else's level before a quiet
reporter loses a single row. That is what stops a hostile peer evicting THIS device's own reports,
without the ledger ever needing to know its own signing key. The same rule is applied on the way in
from disk. Persistence is a `.completeFileProtection` JSON sidecar, never synced: who reported whom is
sensitive social data.

### `FernletSocial/Moderation/ModerationBanStore.swift`

The tamper-resistant 30-day store ban for repeatedly-reported designers: self-bans (this device's
shop) and local peer bans (their catalogs are dropped).

| Function Or Property | What It Does |
| --- | --- |
| `applySelfBan(durationDays:...)` / `applyPeerBan(fingerprint:durationDays:...)` | Arm a ban. |
| `isSelfBanned` / `selfBanRemainingSeconds()` / `isPeerBanned(fingerprint:)` | Countdown reads (which also refresh the credited-time record). |
| `selfBanTamperCount()` | How often a clock rollback was detected. |
| `reconcile(rows:localSigningKey:)` | Two directions (2026-09-24). Applies the bans the verified report set warrants — re-arming a served ban only on a NEW qualifying artwork — and records the evidence each rests on (`BanEvidence`: salted reporter tags, artwork hashes, seqs). LIFTS an active ban once reporters have POSITIVELY withdrawn enough of it (a `retract` superseding their report) that the rest misses the threshold (`ModerationBanRecovery`, uncapped and monotone). Absence, decay, clock moves and the banned device's own rows never count. |
| `reporterTagger(salt:)` | The salted SHA-256 reporter tag (`FernletCryptoPurpose.Hash.moderationBanReporterTagV1`) — how a wipe-surviving ban record recognizes a reporter's withdrawal without holding their key. |

Two survival properties, both deliberate: it survives **app delete + reinstall** (records live in the
Keychain under the dedicated `com.fernlet.moderation` service, ThisDeviceOnly, and are never wiped by
identity resets — the self-ban is keyed to a constant device account, not the identity key), and it
survives **device clock changes** (a credited-time countdown over `mach_continuous_time` plus a
wall-clock high-water ratchet: a rollback voids wall credit and flags tampering, a forward jump
credits almost nothing, and the reboot-gap credit is capped). It is deliberately NOT cleared by
"Reset everything". Its exits are time served and reporters' withdrawals — see
`Docs/Moderation-SelfBan-Recovery-2026-09-23.md`. Its rows go through FernletFoundation's
`KeychainItem` and its `storeBan.*` audit lines to `FernletAuditLog`.

### `FernletSocial/Presence/PresenceManager.swift`

The presence radio's owner: KEPT friends recognize each other nearby without connecting, and hearts are
delivered over on-demand pairwise connections formed on that recognition. It drives ProximityKit's
presence radio (see "Presence And Nearby Friends" above) through its public presence engine,
`ProximityPresenceSession` (`presenceSession`, built in `init`, its hooks wired there once), and builds
each heart connection's `ProximityCoordinator` over the `ProximityPeerChannel` the engine hands up,
marking the channel connected once the coordinator has begun, and calls the coordinator's public token
send (under `PayloadType.friendHeart`'s raw value) and manual commit it calls; its two own audit lines,
`presence.identity.provisionFailed` and `presence.posture.mintFailed`, go to `FernletAuditLog`.

Privacy posture is the design centre, and it is worth reading before touching anything here. The
advertisement carries ONLY rotating pairwise-DH tags (truncated HMACs of the 15-minute epoch under
per-friend-pair static-static X25519 secrets — `IdentityService.presenceTag`, below), the advertised
instance name and TLS identity are an epoch posture the engine wears, replaced whole at every boundary, and
all state (nearby set, connections, diagnostics) is
memory-only with no identities in any log line. Matching spans ±1 epoch; three self-exclusion layers
drop our own ghost advertisements (the first, by name, is the engine's); a 45 s lost-grace debounce
smooths the epoch advertiser restart.

| Function Or Property | What It Does |
| --- | --- |
| `start()` / `stop()` | Lifecycle, owned by the app (opt-in setting + scene/tab/lock state) — not by this type. `start()` refuses first, with `presence.identity.namespaceMismatch` (at `start`), when `init(store:ledger:identity:)` was handed an identity of another namespace (audited at `construction`): it mints no posture and starts no radio. |
| `spawnHostPinned(_:)` | The mandatory spawn idiom for this manager (P5 item 1a, invariant HP1): reads the `unowned` host synchronously on the main actor and holds it for the operation's own lifetime, so a detached task can never resume against a destroyed host. Spawns whose handle the manager STORES are exempt and stay plain `Task { … }` with a `// host-pin: timer — <reason>` marker — a task-lifetime pin there is a permanent `store → manager → handle → store` cycle (HP2). Enforced by `MemoryLifecycleBoundaryTests` rule ML4. |
| `rotatePosture(at:)` / `rotateEpochIfNeeded()` | The radio's epoch index, advertised instance name and TLS identity are the posture the engine wears, rotated through `presenceSession.rotatePosture(at:)`. Minted when the radio comes up, re-minted WHOLE at every 900 s boundary by the rotation tick the manager already runs — no new timer and no second clock (the engine owns none), since every caller hands the rotation `nowProvider()` and the epoch is always `IdentityService.presenceEpoch(at:)` — and dropped by `stop()`, so a stood-down radio keeps no name and no certificate to come back up under. The engine starts and re-publishes the radio under it (`start(tags:)`, `republish(tags:)`): its QUIC listener's instance name and `sec_identity_t` ARE the posture, so no posture means nothing advertised. Fail-soft, NAMED (`presence.posture.mintFailed`) and BUDGETED: a mint that fails leaves NO posture rather than a stale one, tag derivation is untouched because the epoch still comes from the same clock, and the failed epoch is remembered so the six `refreshRoster()` call sites cannot turn one failure into a keygen and an audit row per refresh — one attempt and one row per epoch, then the boundary retries. |
| `refreshRoster()` | Re-derives the advertised/matched tag set from the current trusted-friend roster — **through** the posture, so a refresh that lands after a boundary rotates the name and the identity with the tags rather than advertising fresh tags under an old identifier. |
| `isReachable(fingerprint:)` | Whether a friend is currently tag-matched nearby. |
| `sendHeart(to:)` | The full in-person send: invite the tag-matched peer, run the 1-RTT friend handshake under the SEALED-INTRODUCTION rule (intro and ack sealed to the intended friend's vault key-agreement key, so a tag-replay forger learns nothing), auto-commit, verify the connected identity IS that friend and is heart-eligible, deliver one sealed `.friendHeart`, then tear down. The teardown is load-bearing: zombie connections must never accumulate toward the radio's four-tunnel cap (`NetworkPresenceSession.maxTunnels`). |
| `heartAffordance(...)` (`nonisolated static`) | The friend row's decision about which heart affordance to show. Takes the away-delivery setting as an explicit parameter rather than reading it off the host, so the affordance and the enforcement cannot drift apart. |
| `queueAwayHeart` / `heartDropBundleProvider` / `onPeerPrekeyBundle` | The dead-drop seams: race-window sends and prekey-bundle gossip (a `ProximityPrekeyBundle`, wired into each heart connection's coordinator as its `introductionPrekeyBundleProvider` / `onIntroductionPrekeyBundle`) are handed to this module's `HeartDropService` (above) instead of being reimplemented here. |
| `heartsAwayEnabledProvider` | The away-delivery consent, wired by the app (`settings.heartsAwayDelivery`), nil reading as off: read only for the not-nearby copy (`notNearbyHeartMessage(firstName:)`), so a failed send does not tell a user who turned away delivery on that hearts travel in person. The host carries no such requirement. |
| `isHeartEligible(signingPublicKey:fingerprint:in:)` / `isHeartEligibleFriend(_:in:)` | Presence's heart gate, delegating to `FernletSocialHost.isTrustedUnblockedPeer(signingPublicKey:fingerprint:)`, which the session hearts' ledger judge asks too. |
| `proximityCoordinator(_:didReceive:plaintext:from:)` | Receive side. Accepts invitations only from tag-matched peers, and enforces the `allowNearbyHearts` opt-out, the trusted-friend gate, and the shared `ProximityHeartLedger` 5-minute receive window. |
| `wipeIdentityForDeleteAll()` | Delete-all participation. |

Every escaping `Task` captures `[weak self]` — the manager-Task lifetime rule; the owning store holds
this `unowned`.

### `FernletSocial/Presence/IdentityService+PresenceTags.swift`

Presence's derivations, as extensions of ProximityKit's `IdentityService` with the names and signatures they always had, so every caller kept its spelling. `FernletFeatureGoldenTests` pins the pair secret and three epochs' tags to known answers; `PresenceTagTests` holds the properties and the malformed-key refusal.

| Function | What It Does |
| --- | --- |
| `presencePairSecret(with:)` | The pair secret both friends derive: `IdentityService.pairSecret(with:purpose:)` under `FernletFeaturePurposes.presencePairV1` (`fernlet.presence.tag.v1`). Throws `notProvisioned` first when the identity holds no key-agreement key, then `invalidKeyData` for a friend key that is not a raw X25519 key, then the door's own. |
| `presenceTag(for:epoch:)` | The rotating tag one friend pair advertises and matches by: HMAC-SHA256 keyed by the pair secret over `fernlet.presence.epoch.v1` ‖ be64(epoch) (through `TagCounterBytes`), its first `presenceTagByteCount` bytes. Both members of a pair derive the same tag for an epoch; the epoch is ProximityKit's `IdentityService.presenceEpoch(at:)`. |
| `IdentityService.presenceTagByteCount` | 8: the truncated tag's length, 12 base64 characters on the air, which keeps a 24-tag roster inside the TXT budget. `nonisolated`. |

### `FernletSocial/Presence/FriendStateCache.swift`

| Function Or Type | What It Does |
| --- | --- |
| `CachedFriendState` | One friend's shared fuzzy wellbeing state + companion appearance, stamped with the meeting it was captured at, and shown with "as of last time you met" staleness treatment. |
| `record(fingerprint:fuzzyState:appearance:)` | Stores what a verified `.friendState` payload from a committed, vault-trusted friend carried. |
| `state(for:)` | The Friends UI read. |
| `remove(fingerprint:)` / `clearAll()` | Wired from block/revoke and from reset-everything, so a removed friend leaves nothing behind. |

Persistence is this module's `JSONSidecarFile`, at the file its caller states
in the app's proximity sidecar root, with `.completeFileProtection`, deliberately **never** in the
synced snapshot: a friend's struggling state
is theirs and must not follow this user into iCloud. Entries expire from the UI after 30 days, the
map is bounded at `maxStates` (newest kept), and decode is per-row tolerant so one unknown future
value can never wipe the cache.

### `FernletSocial/Presence/ClosenessLedger.swift`

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

### `FernletSocial/Activities/ProximityActivityManager.swift`

Hosting, joining, offers, pending join requests, and host-authoritative roster convergence — riding the
friend mesh with **no radio of its own**. Owned by the mesh composition
(`FernletMeshFeatures.activities`), which builds it over the mesh's identity right after the mesh and
attaches it (`attach(to:meshHost:)`, below): its five handlers through the payload token door, and the
two seams this type uses instead of touching a radio — `send` (seal + sign + transmit to one verified
fingerprint's committed slot) and `committedActivityPeerFingerprints`.

Authorization is deliberately independent of the shared handshake: membership is carried by the
host-signed, invitee-key-bound `ActivityJoinToken`, snapshots verify only under the host key PINNED
at join, and roster convergence is max-version-wins.

| Function | What It Does |
| --- | --- |
| `init(store:identity:fileURL:now:)` | Loads the hosted and joined activities from the ledger file its caller states and prunes the expired: `fileURL` has no default, so no manager lands on a process-wide path (the composition passes `fileURL(in:)` of its host's `proximitySupportDirectory`, every test a file of its own). |
| `host(...)` / `endHosting(activityID:)` | Start and stop hosting an activity. |
| `spawnHostPinned(_:)` | The mandatory spawn idiom for this manager (P5 item 1a, invariant HP1): reads the `unowned` host synchronously on the main actor and holds it for the operation's own lifetime, so a detached task can never resume against a destroyed host. This type stores no `Task` handle at all, so every spawn in it goes through the helper. Enforced by `MemoryLifecycleBoundaryTests` rule ML4. |
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

### `FernletSocial/Activities/ProximityActivityManager+Mesh.swift`

| Function | What It Does |
| --- | --- |
| `attach(to:meshHost:)` | Attaches the activity manager to the mesh, once, while the composition builds it: registers the five activity handlers through the payload token door, then sets the two seams the manager uses instead of a radio — a sealed or unsealed send to a verified fingerprint's committed slot (`send`), and the committed peers advertising `activities` (`committedActivityPeerFingerprints`). Both hold the mesh weakly. |

### `FernletSocial/ClothingSharing/MeshClothingShop.swift`

The friend-mesh clothing shop. It replaced the standalone `fernlet-clothes` radio
(`ProximityClothingShareManager`, deleted): catalogs now ride the friend mesh as `.clothingCatalog`
payloads exchanged pairwise-sealed during the live session, and the shop **opens at session end** as
a 1-hour, memory-only browse window on the Friends tab.

| Function Or Property | What It Does |
| --- | --- |
| `receiveCatalog(...)` | Inbound. `ClothingShopExchange`'s handler, registered through the mesh's payload token door, hands verified `.clothingCatalog` envelopes here from COMMITTED slots only — the mesh's committed-slot gate is the security boundary, because the coordinator dispatches known non-core payloads with `connectedIdentity ?? pendingPeerIdentity` and no state gate. Catalogs accumulate for the whole session. |
| `isSharingEnabled` | The payload-layer opt-out. `allowNearbyClothingShares` no longer stops a radio; the app wires `isSharingEnabledProvider` + `localCatalogProvider` (both gating app-side, so `ProximityHost` stays unchanged), the provider returns nil when off, inbound drops when off, and turning it off calls `clearAll()`. |
| `openWindowAtSessionEnd(now:)` | Opens the browse window at the session observer's ending, right after the review promotion that fills `pendingFriendReview`. |
| `beginNewSession()` | Closes the window early on the next session FORMATION — called from the composition's observer at a forming commit (`MeshSlotCommit.formsSession`), **never** at a search start (`startJoin`/`startNewMesh`), which fire automatically on every Social-tab entry and scene reactivation and must not touch the window. |
| `isWindowOpen(at:)` / `remainingWindowMinutes(at:)` / `cleanupIfExpired(now:)` | Expiry is lazy — pure reads plus a drop, no background timers. |
| `clearAll()` | Reset. |

Buying stays fully local (`FernletStore.buyClothingItem`); this type is pure receive/window state and
never touches coins or the closet. Everything here is memory-only: never persisted, never synced.
Note the asymmetry with `pendingFriendReview` — the review survives search starts *and* session
formations, the shop window survives searches but not formations.

### `FernletSocial/ClothingSharing/ClothingShopExchange.swift`

| Function | What It Does |
| --- | --- |
| `registerHandlers(on:)` | The catalog and catalog-request handlers, through the mesh's payload token door: the committed-slot gate has run; a transport-VERIFIED fingerprint is required (catalogs are keyed by it, never a display name) and blocked fingerprints drop silently. Each holds the exchange weakly. |
| `offerCatalog(to:peer:)` / `shouldOfferShopCatalog(to:)` | The commit-time offer, from the composition's observer: our catalog once per slot, pairwise sealed and capability-gated (`shop`), nil provider (sharing off) sends nothing — PLUS a `clothingCatalogRequest` for the peer's, so the exchange does not depend on which side commits first. |
| `pruneShopSendTracking(for:)` / `clearShopSendTracking()` | Slot loss prunes the send tracking so a rejoining friend re-exchanges (a returning peer reuses its old slot id); a stopped search or a new session forgets every slot sent to and every request answered. |

### `FernletSocial/RecipeSharing/ProximityRecipeShareManager.swift`

Fernlet's recipe share over ProximityKit's `ProximityPairSession` (`FernletSocial`'s since ProximityKit plan
step A0.7.3; the mechanism is the session's, indexed under "Photos And Recipe Sharing"). The share
sheet's observables are the session's, read through (`nearbyRecipients`, `sendState`, `lastShareOutcome`,
`engagedRecipientID`), and so is `isListening`, which is not observed: the run-policy seam reads it on each
run. Its own state is the diagnostics ring and the inbound queue.

| Function | What It Does |
| --- | --- |
| `ProximityRecipeShareDiagnosticEvent.init(...)` | Creates a timestamped diagnostic event. |
| `ProximityRecipeShareDiagnostics.appending(_:to:maxCount:)` | Appends and caps diagnostics to the newest events (presence's connection log rides it too). |
| `init(store:)` / `init(pairSession:)` | `init(store:)` builds the pair session over the host under `ProximityPairProfile.recipeShare(in: store.proximityNamespace)`; `init(pairSession:)` (internal) takes a built one and makes this manager its `payloadHandler` and its event sink (`onEvent`, capturing the manager weakly: the manager holds the session), each event rendered by `diagnostic(for:)` and appended synchronously. The test target's `init(store:makeSession:identity:)` restores the seam shape over the session's. |
| `start()` / `stop()` / `refreshDiscovery()` / `wipeIdentityForDeleteAll()` | The pair session's. |
| `sendRecipeShare(_:to:)` | Hands the session `PayloadType.recipeShare`'s token, the summary `Recipe share` over the recipe's ingredient count (DO NOT LOCALIZE: signed into the canonical bytes and shown in the receiver's inspector), the recipe's title as the subject, and an encoder (a default `JSONEncoder`) the session runs when the pairing verifies. |
| `dismissRecipeShare(_:)` / `dismissRecipeShare(id:)` | Removes a pending inbound share. |
| `proximityCoordinator(_:didReceive:plaintext:from:)` | The session's payload handler: accepts `recipeShare` envelopes under a 1 MiB size gate before decoding, the format and version check, the 512 KiB image drop and the review clamps, a 3 s per-sender rate limit (keyed by the raw fingerprint) and an eight-share queue, and records its own four diagnostic lines. |
| `recordDiagnostic(_:)` | Appends a capped diagnostic line: a rendered event, or one of the receive handler's four lines. |
| `sendState` | The public status line the share sheet shows: the session's typed `status` rendered by `sendState(for:)`. |
| `sendState(for:)` / `statusMessage(for:)` / `diagnostic(for:)` | The renderer, at the foot of the file: where the pair session's typed status and events become English (the status line and the diagnostics the session's events add; the receive handler's four diagnostics are its own literals), the frozen sentences the share sheet renders as written. Exhaustive switches with no `default`, so a new `ProximityPairSession.Status.Failure` or `Event` case is a build error until it has its sentence. `FernletFeatureGoldenTests` 31e renders every case with distinct arguments against its frozen sentence and finds none of the forty templates in ProximityKit; 31b and 31d read them in order on each path. |

### `FernletSocial/Wire/RecipeSharePayloads.swift`

| Function | What It Does |
| --- | --- |
| `ProximityRecipeSharePayload.hasShareNotes` | Checks local notes or saved summary for nonblank share notes. |
| `omittingShareNotes()` | Returns a copy with local notes or saved summary removed (a local recipe's steps too). A multipart local recipe's `components` partition is rewritten through `SharedRecipePayload.withoutSteps()` (step counts to zero, steps-only parts dropped), so the stripped share still passes the receiver's strict partition decode. |
| `ProximitySharedRecipe.title` | Returns local or saved recipe title fallback. |
| `ProximitySharedRecipe.servings` | Returns local or saved servings fallback. |
| `ProximitySharedRecipe.ingredientCount` | Returns local or saved ingredient count. |
| `PendingProximityRecipeShare.id` | Uses payload ID as pending-share identity. |

### `FernletSocial/Wire/ActivityPayloads.swift`

| Type | What It Does |
| --- | --- |
| `ActivityParamsHash.of(_:)` | SHA-256 over the canonical descriptor bytes: the stable identity of an activity's parameters that the signed join token binds. Lives in FernletSocial, not the domain model, so the domain model stays crypto-free (same reasoning as `ModerationContentHash`). |
| `ActivityOfferPayload` | A host advertises a running activity to a committed friend, sealed. Carries the full descriptor (so the joiner can pin the host key + params hash) plus the current roster version — display only; the signed snapshot in the grant is the trust input. |
| `ActivityJoinRequestPayload` | A committed peer asks to join. Deliberately UNSEALED (mirroring `clothingCatalogRequest`): it carries only public keys and a display name, and the host re-validates the claimed fingerprint/signing key against the transport-verified slot and binds the grant to the VERIFIED key, so a spoofable body is harmless. |
| `ActivityJoinGrantPayload` | The host's signed grant: an invitee-key-bound `ActivityJoinToken` plus the roster snapshot at grant time, sealed. The joiner verifies both under the host key it pinned from the offer before considering itself a member. |
| `ActivityRosterSnapshotPayload` | A host-signed roster snapshot on its own, for convergence outside a grant. |
| `ActivitySyncPayload` | A sealed version digest between committed members (`[activityID: versionHeld]`); whichever peer holds the higher VERIFIED version replies with the snapshot, and the reply is rate-limited. Max-version-wins is the whole convergence rule. |
| `isWellFormed` (on each payload) | Format-string + version shape check at the wire boundary, before anything is trusted. |

### `FernletSocial/Wire/ClothingSharePayloads.swift`

| Type | What It Does |
| --- | --- |
| `ClothingCatalogPayload` | A peer's current shop on the wire: the capped, deterministically ordered items on offer plus the anonymous designer id and display name, so a buyer can resolve "designed by <friend>" and learn the id→name mapping in person. Ephemeral by design — only items actually purchased persist. |
| `ProximityClothingCatalog` | The received-side holder, kept in memory from receipt through the 1-hour post-session shop window. Keyed by the transport-VERIFIED sender fingerprint so a re-broadcast replaces the prior catalog instead of stacking. The shop is the inverse of recipe-share: the BUYER holds the SELLER's broadcast catalog. |

### `FernletSocial/Wire/FeatureCanonicalBytes.swift`

The canonical signing bytes of Fernlet's mesh features, each under its own FernletCrypto domain tag and
written with ProximityKit's public `CanonicalByteWriter`, whose encodings the engine's goldens freeze;
the three signed ones signed and verified through `IdentityService` under their host labels,
`FernletFeatureSignatures`. Signing INPUT only. Each overload is told apart from the serializer's by
its parameter type alone.

| Function | What It Does |
| --- | --- |
| `canonicalBytes(for: ActivityDescriptor)` / `(for: ActivityJoinToken)` / `(for: ActivityRosterSnapshot)` | The three Group-Activity signed types. All include the signed `schemaVersion`, so `verify` gates on one encoder rather than dual-verifying forever. |
| `canonicalBytes(for: ModerationLedgerEntry)` | Bytes for a moderation report row (Phase 3b). |
| `FernletFeatureSignatures.activityJoinTokenV2`, `.activityRosterSnapshotV2`, `.moderationReportV2` | The labels the join token, the roster snapshot and the report row are signed and verified under, each minted with `ProximityCryptographicPurpose.featureSignature(_:framing:)`, length-prefixed, from the spelling of its FernletCrypto twin, the registry entry its domain tag reads (plan step A1.0). `ProximityNamespaceGoldenTests` holds each pair to the same bytes until C1. |

### `FernletSocial/Wire/MessagePayloads.swift`

| Type | What It Does |
| --- | --- |
| `TempMessagePayload` | One session-scoped chat message, **frozen and parked**: nothing emits or dispatches it since chat rides ProximityKit's routed store, and it stays decodable so an older peer's frame parks by name. Sealed-only (`.tempMessage` is in Fernlet's sealing set, `PayloadRules.fernlet.sealingRequired`); `id` drove receive-side dedup, and `sentAt` was the sender's clock — display only, never trusted for ordering security. |

### `FernletSocial/Support/JSONSidecarFile.swift`

| Function | What It Does |
| --- | --- |
| `JSONSidecarFile.fileURL(in:name:)` | The ONE definition of the sidecar layout: `<directory>/<name>`. Owners resolve `directory` from their host's `ProximityHost.proximitySupportDirectory`; tests inject their own root. |
| `JSONSidecarFile.load()` | Reads and decodes the sidecar, returning `nil` on any failure (absent, unreadable, or undecodable) — deliberately the naive idiom, so callers substitute their own defaults. Data of record must use `ProtectedSidecar` instead, which classifies read failures. |
| `JSONSidecarFile.save(_:)` | Encodes, creates the parent directory, and writes atomically with `.completeFileProtection`; a failure is audit-logged through `FernletAuditLog` (`sidecar.encodeFailed`, `sidecar.createDirectoryFailed`, `sidecar.saveFailed`) and dropped. Unlike `ProtectedSidecar`, it does not exclude the file from backup. |
| `JSONSidecarFile.removeFile()` | Best-effort delete for the clear-all/reset path: an absent file is the expected case, and any other failure is audit-logged (`sidecar.removeFailed`). |

Shared by `ProximityActivityManager`, the session photos' wall preferences (`MeshSessionPhotos`),
`FriendStateCache`, `ClosenessLedger` and `ModerationLedger`: every store that persists through it is
FernletSocial's, so the type and its doors are internal.

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
> states its root, the same way every heart-drop caller states FernletSocial's `HeartDropStorageScope`. The
> in-source comment where `defaultFileURL(name:)` used to be says so; do not re-add it.
>
> The production root is `Application Support/Fernlet`, `.fernlet`'s folder under Application Support
> (`.fernlet` names the folder `Fernlet`), `FernletConnections`' `FernletProximityStorage.productionDirectory`
> since ProximityKit plan step A0.6.6, reached through `ProximityHost.proximitySupportDirectory`, a
> requirement with no default since that step (the app's `FernletStore` answers a per-instance root that
> defaults to that folder). FernletSocial's production heart-drop scope reads the same folder through
> `FernletProximityStorage`.
> The `App/Fernlet/` that appeared here was a repo-restructure artefact: `9fb86a9` collapsed the
> seven `Fernlet*` roots into `App/`, `Tests/` and `FernletKit/`, and the mechanical path rewrite
> caught this *runtime* path as if it were a *source* path. No shipped install has ever used it.

### `FernletSocial/FernletSocialCopy.swift`

| Member | What It Does |
| --- | --- |
| `FernletSocialCopy.Camera.holdFailed` | The capture refusal when this phone could not seal its own copy (no film spent, nothing shared), resolved from FernletSocial's catalog (`proximity.camera.holdFailed`) and published on the mesh's `meshError` for the camera's session alert. |

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
| `transportSection` | Shows the transport session state, bytes, and RTT. |
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

`KeepFriendsPromptSheet.swift` and `FingerprintText.swift` live in the `FernletProximityUI` module
(ProximityKit plan step A0.1, 2026-10-01); `PeerNameDisplay.swift` stays in ProximityKit's `UI/`
folder as the identifier filter, the consumer the namespace's peer-name soundness rule protects, and its
placeholders are FernletConnections' extension of the type (`PeerNameDisplay+Placeholders.swift`, over
that module's catalog), which the app, both screens and FernletSocial's `PresenceManager.firstName(of:in:)`
call. Both screens hand it `.fernlet` (FernletProximityUI depends on FernletConnections for it and for
the placeholders).

### `FernletProximityUI/KeepFriendsPromptSheet.swift`

The per-participant "keep as a friend?" affordance at session end. One-sided and local-only: keeping
mints a trust-vault record on THIS device only, skipping does nothing, and the peer is never notified
either way.

| Type | What It Does |
| --- | --- |
| `KeepFriendsSection` (internal) | The keep-as-friend rows. Embedded in `FriendPhotoReviewSheet` when the session produced photos; hosted by the sheet below when it didn't. Its row toggles flip membership in a shared kept-fingerprints binding. |
| `KeepFriendsPromptSheet` | The compact standalone prompt for sessions that ended with no photos to review but with eligible candidates. Dismissing without choosing = skip all: the host clears the roster in `onDismiss` and mints only what was toggled. |

Which of the two appears is decided by `FriendMintingReview.sessionEndReview(...)`, and the candidate
list by `FriendMintingReview.eligibleCandidates(...)` — not by the views.

### `FernletProximityUI/FingerprintText.swift`

| Type | What It Does |
| --- | --- |
| `FingerprintText` | A peer's identity fingerprint, for the one place a person may deliberately look one up: since 2026-09-29, the friend detail card's collapsed "Safety code" in Friends & Blocks, and nowhere else (the join prompt, the activity roster, the keep-as-friend rows and the connect row used to show it; `PeerNameDisplayTests` now pins that they don't). Centralized on the design system's `stat` role (DM Sans Medium, tabular figures) with extra tracking so a hex string still reads character by character, and spelled out for VoiceOver. Truncation is MIDDLE, deliberately: the head and tail are what people compare, so a clipped tail would defeat the only thing the string is for. |

### `FernletConnections/PeerNameDisplay+Placeholders.swift`

The Fernlet app's half of the name display: a `nonisolated extension` of ProximityKit's `PeerNameDisplay`,
whose phrases are Fernlet's display policy, beside `PeerNames.fernlet`.

| Type Or Member | What It Does |
| --- | --- |
| `PeerNameDisplay.Placeholder` | Which phrase stands in for a person whose name is not known: `.nearby` (the connect path) or `.met` (someone met in an earlier session whose name never arrived). |
| `PeerNameDisplay.shown(_:fingerprint:placeholder:in:)` | `personName` or the localized placeholder: `.nearby` "Someone nearby" (connect rows, participants, join requests, recipe recipients) or `.met` "Someone you met" (keep-as-friend rows, Friends & Blocks). **Display only**: never persisted, never put in a roster, vault row, removal proposal or payload; those keep reading `displayNameOrFingerprint`. |
| `PeerNameDisplay.text(for:)` | The placeholder alone (`FernletConnectionsCopy.Peer`, resolved with `bundle: .module` against FernletConnections' catalog). |
| `PeerNameDisplay.firstName(_:fingerprint:placeholder:in:)` | The first word of `personName` for warm hearts copy ("Aisha" from "Aisha Bloom"), or the WHOLE placeholder when there is no name: the rule runs before the split, so the placeholder never reads "Someone". FernletSocial's `PresenceManager.firstName(of:in:)` delegates to it with `.met` and the namespace it is handed (the manager's own, or the app's `.fernlet`), so every heart sentence built on a trust-vault name (the presence refusals composed in the package, `SessionHeartStatusCopy`, Home's received-heart card) refuses a fingerprint filed as a name. |

### `FernletConnections/FernletConnectionsCopy.swift`

| Type Or Member | What It Does |
| --- | --- |
| `FernletConnectionsCopy.Peer.someoneNearby` / `someoneYouMet` (internal) | The two placeholders, computed `String(localized:defaultValue:bundle:comment:)` lookups of `proximity.peer.someoneNearby` and `proximity.peer.someoneYouMet` with `bundle: .module` against the module's own `Localizable.xcstrings` (a key is a token, so they keep that spelling); `nonisolated`, as the name display is. Display copy only. |

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
| Tests and mocks | `FernletTests`, ProximityKit's `ProximityKitTests`, `FernletUITests`, proximity mocks | Tests document expected behavior and often contain reusable fakes/harnesses. | Are new tests creating another mock when `Mocks/MockMultipeerTransport.swift` or similar exists? Are edge cases already covered by an adjacent test file? Does a helper both unit-test targets need already have a twin held by `CIGateSelectorBoundaryTests`? |

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
