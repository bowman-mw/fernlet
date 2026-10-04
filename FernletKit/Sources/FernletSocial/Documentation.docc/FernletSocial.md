# ``FernletSocial``

Fernlet's social features over ProximityKit's mechanisms. Today it holds presence — ``PresenceManager``, which drives ProximityKit's presence radio so kept friends recognize each other nearby by rotating pairwise tags, and delivers in-person hearts over short-lived connections formed on that recognition — the heart dead-drop — ``HeartDropService``, the offline "away" hearts that ride an injected public-database transport as sealed blobs under rotating day tags, with its sealer, prekey store, sidecar stores and seal — moderation's device-local records — ``ModerationLedger``, the report rows; ``ModerationBanStore``, the tamper-resistant store-ban clock; and ``ModerationContentHash``, the key a report binds an artwork by — with the ``ClosenessLedger``, the ``FriendStateCache`` and its ``CachedFriendState`` rows, and ``TempMessagePayload``, the parked live-session chat payload.

## Overview

ProximityKit is becoming a drop-in package any app can use, with nothing Fernlet-specific in its
API (`Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md` §3.2). Fernlet's rules on top of it, its
namespace, trust vault and session policies, live in `FernletConnections`; Fernlet's features live
here, moved out of ProximityKit in plan step A0.4 with their bytes unchanged. The edge runs
`FernletSocial` → ProximityKit, never the reverse, so ProximityKit can never name a type of this
module, and `ProximityNamespaceBoundaryTests` refuses one declared, extended or aliased there again
under its old name, which nothing else would notice.

**What it holds.**

- ``PresenceManager`` (`Presence/PresenceManager.swift`): the standing presence radio's owner. It
  advertises only rotating pairwise-DH tags, one for each of the 24 most recently seen kept friends,
  and matches a browsed peer's tags against every eligible friend's over the epoch before and after
  its own, so kept friends recognize each other nearby without connecting; three self-exclusion
  layers drop this device's own ghost advertisements, and a 45-second lost grace smooths a friend's
  epoch restart. The radio it drives wears ProximityKit's `PresenceEpochPosture`, an instance name
  and a TLS identity replaced whole at every 900-second boundary by the manager's one timer, and
  nothing about it is persisted. Hearts: a send dials the tag-matched peer, runs the one-round-trip
  friend handshake under the sealed-introduction rule (the introduction and its acknowledgement are
  sealed to the intended friend's key-agreement key, so a tag-replay forger learns nothing),
  auto-commits, verifies the connected identity is that friend and still heart-eligible, sends one
  sealed heart and tears the connection down; a receive admits only a dialer whose claimed tag
  resolves to a browsed, matched friend and records the heart in the shared heart ledger under its
  5-minute window. The host's in-person hearts opt-in, `ProximityHost.allowNearbyHearts`, gates both
  sides; a heart for a friend who just left goes to the dead-drop through `queueAwayHeart`, and the
  away-delivery consent reaches presence as `heartsAwayEnabledProvider`, read only for the
  not-nearby copy. Every state is memory-only, no diagnostic carries an identity, and the app owns
  the lifecycle (the opt-in setting, scene, tab and lock).
- The presence derivations, `IdentityService` extensions
  (`Presence/IdentityService+PresenceTags.swift`): `presencePairSecret(with:)`, the pair secret both
  friends derive, through ProximityKit's `pairSecret(with:purpose:)` under the salt `.fernlet`
  declares for it (`FernletFeaturePurposes.presencePairV1`), refusing an identity with no
  key-agreement key first (`notProvisioned`) and a malformed friend key then (`invalidKeyData`); and
  `presenceTag(for:epoch:)`, the tag a pair advertises and matches by, keyed by the pair secret over
  `fernlet.presence.epoch.v1` and the epoch's eight big-endian bytes, its first `presenceTagByteCount`
  (8) bytes, 12 base64 characters on the air. The epoch is ProximityKit's presence clock
  (`IdentityService.presenceEpoch(at:)`), the counter the posture rotates on too.
- ``HeartDropService`` (`HeartSharing/HeartDropService.swift`): offline "away" hearts over the
  CloudKit public-database dead-drop. Send: consent, the heart ledger's 5-minute gate (consumed on
  queue), a signed inner envelope, the outer seal to a friend's one-time or signed prekey (forward
  secrecy) or, when none is cached, to the friend's static key, the persisted outbox, the upload.
  Fetch: the expected tags of every kept friend over the whole outbox lifetime in UTC days, the
  open, the durable dedup, the sender-must-be-an-active-friend gate, the envelope's verification,
  the per-sender per-day budget, and the shared heart ledger, whose bubble and glow surface it.
  Cleanup deletes this device's own records past the 14-day outbox lifetime. Every state in which a
  queued heart is not flowing is observable (``HeartDropService/DeliveryProblem``), and the purge seam
  takes this device's records off the public database, which the app runs before the delete-all wipe
  drops the record names that address them. Opt-in through the app's `heartsAwayDelivery` setting,
  off by default.
- ``HeartDropSealer`` (`HeartSharing/HeartDropSealer.swift`): the drop's outer seal, a versioned
  wire form `[version][prekey id, all-zero for the static key][ephemeral X25519 key][ChaChaPoly]`,
  sealed-sender (the sender's static key is not in the KDF; its signature is inside), whose open
  gates the wire size before any key agreement or inflation.
- ``HeartPrekeyStore`` (`HeartSharing/HeartPrekeyStore.swift`): this device's one-time prekeys in
  bundles of 16 and its medium-term signed prekey, their private halves in one keychain blob
  (`AfterFirstUnlockThisDeviceOnly`, never synchronizable) under `com.fernlet.heartdrop`. The bundle
  it gossips is ProximityKit's wire type `ProximityPrekeyBundle`, which the signed identity
  introduction carries; the store names it `Bundle`, `PrekeyEntry` and `SignedPrekey`.
- ``HeartDropPeerBundleCache`` (`HeartSharing/HeartDropPeerBundleCache.swift`): friends' gossiped
  bundles, stored only from a verified introduction, with this device's per-friend consumption
  marks, capped and LRU-evicted. ``HeartDropOutbox`` and ``HeartDropDedupStore``
  (`HeartSharing/HeartDropOutbox.swift`): the persisted sender-side queue, whose record names are the
  only handle on this device's public-database records, and the durable receive dedup with its
  per-sender per-day budget.
- ``HeartDropSidecarSeal`` (`HeartSharing/HeartDropSidecarKey.swift`), ``HeartDropStorageScope``
  (`HeartSharing/HeartDropStorageScope.swift`) and ``HeartDropSidecarFormatCensus``
  (`HeartSharing/HeartDropSidecarFormatCensus.swift`): the three sidecars' at-rest seal, the scope
  their files and key live in, and the read-only census of their format markers (below).
- The heart-drop derivations, `IdentityService` extensions
  (`HeartSharing/IdentityService+HeartDrop.swift`): `heartDropDayEpoch(at:)`, the UTC day the tags
  rotate on; `heartDropPairSecret(with:)`, the pair secret both friends derive, through ProximityKit's
  `pairSecret(with:purpose:)` under the salt `.fernlet` declares for it
  (`FernletFeaturePurposes.heartDropPairV1`), refusing an identity with no key-agreement key first
  (`notProvisioned`) and a malformed friend key then (`sealFailed`); and `heartDropTag(pairSecret:dayEpoch:senderKeyAgreementPublicKey:)`,
  the day tag a drop is filed under, keyed by the pair secret over `fernlet.heartdrop.day.v1`, the day
  and the sender's key.
- The mesh stores' services beside the heart-drop service, extensions of ProximityKit's two storage
  scopes (`HeartSharing/MeshStorageScopes+HeartDrop.swift`):
  `keychainService(besideHeartDrop:in:)` maps the production heart-drop service to the namespace's
  mesh-session or routed seal-key service and any other service to a sibling of its own, which is how
  the app isolates a test store's mesh keys on the axis it already isolates.
- ``ModerationLedger`` (`Moderation/ModerationLedger.swift`): the append-only report rows, this
  device's own reports and retracts beside peers' one-hop-verified rows, bounded max-min fairly per
  reporter so a flooding peer can never evict this device's own reports. The app files a verified
  relay batch here (`FernletStore.ingestModerationRows`) and hands its rows to the mesh's relay as
  this device's own reports.
- ``ModerationBanStore`` (`Moderation/ModerationBanStore.swift`): the 30-day store ban, self and
  peer, in the keychain under the dedicated `com.fernlet.moderation` service. It survives app delete
  and reinstall and every device clock change (a credited-time countdown over
  `mach_continuous_time` with a wall-clock high-water ratchet), and "Delete everything" clears only
  its peer-ban rows (``ModerationBanStore/clearPeerBansForDeleteAll()``): the self-ban must outlive a
  wipe, or the wipe is a ban-evasion tool.
- ``ModerationContentHash`` (`Moderation/ModerationContentHash.swift`): SHA-256 over an item's
  sanitized artwork, never its id, name or price, so a designer cannot escape a report by relisting
  the same artwork. The app's report, retract and listing checks call it.
- ``ClosenessLedger`` (`Presence/ClosenessLedger.swift`): day-granularity, capped per-friend
  interaction counts, the input to the deterministic closeness score and the close-slot assignment;
  a warmth signal, never a who-met-whom log. The app's mesh, presence and recipe-share hooks record
  into it.
- ``FriendStateCache`` and ``CachedFriendState`` (`Presence/FriendStateCache.swift`): the fuzzy
  wellbeing state and companion appearance a friend shared at the last in-person meeting, shown "as
  of last time you met" for 30 days. The app records each verified `.friendState` payload the mesh
  manager hands it.
- ``TempMessagePayload`` (`Wire/MessagePayloads.swift`): the retired live-session chat payload,
  frozen and parked. Nothing emits or dispatches it (chat rides ProximityKit's routed store); it
  stays decodable so an older peer's frame parks by name, and it is the sealing-required control
  several wire suites make their claims against.

Only presence touches a radio, and only through ProximityKit's presence seam (below). ProximityKit's
mesh manager hands the verified moderation rows and friend-state payloads it receives to the app's
closures, and the app files them in these stores; the mesh manager and presence hand the prekey
bundles their introductions carry to the dead-drop the same way, and the hearts each sends or
receives reach the closeness ledger through the app's closures too. Every record is device-local and
never part of the synced snapshot; the one thing that leaves the device is a sealed drop, through
the transport the app injects (CloudKitSync's `HeartDropCloudTransport`, behind FernletDomainModel's
`HeartDropTransporting`), which sees only rotating day tags and ciphertext.

**The heart sidecars are sealed, and scoped as a pair.** The outbox, the dedup store and the
peer-bundle cache load through ProximityKit's `ProtectedSidecar`, which classifies a read failure so
a locked-device read can never be mistaken for "empty" and overwrite real data, sealed at rest by
``HeartDropSidecarSeal`` under a key that lives under the heart-drop keychain service, so
`HeartDropService.wipeForDeleteAll()` takes files and key together. A scope that moved only the
directory would be cosmetic — another store's wipe still deletes the shared key, and the isolated
file then survives as ciphertext nothing can open, which the outbox quarantines and latches as data
loss. So ``HeartDropStorageScope`` is (directory, keychain service), always both, and scoping is
never unsealing: a store on its own scope still seals through the real ``HeartDropSidecarSeal`` key
path.

Those sealed sidecars are an at-rest format surface, and Phase 3 of the crypto-standardization plan
**deleted its legacy reader**: ``HeartDropSidecarSeal`` requires the `FSC2` marker, and the Phase 2.2
migrator that converted `FSC1` rows went in the same stroke, because it converted *through* the
branch that is now gone and a healer that can no longer heal is worse than either alone. An `FSC1`
file is refused by name — `SidecarSeal.SealError.legacyFormatRetired`, audit-logged before it is
thrown — and `ProtectedSidecar`'s unopenable-sealed policy then quarantines it and latches the data
loss. The `FSC1` marker itself is **kept, and load-bearing**: `SidecarSeal.isSealed` still answers
true for it, and must, because that predicate is what splits a file into "sealed" and "legacy
PLAINTEXT v0 — read it as JSON and re-seal it", so a marker that stopped classifying would send
ciphertext down the plaintext branch, fail to decode, and be handled as *corrupt* —
salvaged-or-discarded, i.e. destroyed. ``HeartDropSidecarFormatCensus`` stays for the same reason: it
classifies by marker bytes, holds no key, and counting rows nothing can open is still the only way to
know they are there. Only the three main rows (outbox, peer bundles, dedup) ever mattered to that
count — the quarantine tombstone is reported and never blocking, because no reader ever opens that
path.

**Store bans answer to their evidence (2026-09-24).** ``ModerationBanStore/reconcile(rows:localSigningKey:)``
runs in both directions. It applies the 30-day ban the one-hop report set warrants, recording the
evidence the ban rests on as `BanEvidence` — reporter TAGS (salted digests under
`FernletCryptoPurpose.Hash.moderationBanReporterTagV1`, never keys, because the self-ban row outlives
"Delete everything"), artwork hashes and report seqs. And it LIFTS an active ban once the reporters
themselves have positively withdrawn enough of that evidence — a relayed `retract` superseding their
report — that what is left no longer reaches the threshold (`ModerationBanRecovery`, counted without
the per-reporter cap so the test is monotone and can only err towards keeping a ban). The invariant
the recovery hangs off: **only a positive withdrawal counts.** An absent row (a wiped ledger, a
reinstall, an evicted row, a blocked or removed reporter), a decayed row and every clock move leave
the evidence where it was, and the self-ban ignores the banned device's own rows, so nothing the
banned person does alone can lift it. A record written without evidence — before this change, or by
the direct `applySelfBan` path — can only serve out. Policy note:
`Docs/Moderation-SelfBan-Recovery-2026-09-23.md`.

**Every byte is the one Fernlet shipped, and pinned.** `FernletFeatureGoldenTests`, on the
`crypto-goldens` CI line, holds to frozen literals presence's two labels, its pair secret from
either side with its missing-key refusal, three consecutive epochs' tags with their wire tokens, the
advertisement a manager over a planted identity publishes and the window of tokens it recognizes,
and the heart-eligibility predicate's three legs as presence's gate answers them; the heart
dead-drop's labels, its pair secret from
either side with its two refusals in their order, the two directions' day tags and the day epoch at
its boundaries, a frozen sealed drop and a frozen sealed sidecar opened through their readers, the
prekey bundle's JSON both ways, the heart-drop keychain service and its two accounts
(`prekeyPrivateHalves`, `sidecarSealKey`), the mesh stores' services derived beside it, and the
production heart-drop scope's folder and service; the ban evidence's reporter tag, a reported
artwork's content hash, the ban store's two keychain accounts (`selfBan.device` and `peerBan:` ‖ the
peer's fingerprint), the three ledgers' file names (`ModerationLedger.json`, `ClosenessLedger.json`,
`FriendStateCache.json`), each ledger loading a literal file into its state, and two literal ban
records decoding. `PrivacyWipeCoverageTests` discovers the heart-drop service by the prekey store's
`keychainService = "com.fernlet.heartdrop"` and the moderation service by the ban store's
`service: String = "com.fernlet.moderation"` default, and holds the delete-everything funnel to the
dead-drop's purge and wipe and the ban store's peer-ban clear, and presence's wipe among the three
identity seams. `HeartDropSidecarFormatCensusTests` pins the sidecars' four file names and markers;
`PresenceTagTests` holds presence's malformed-key refusal and its tags' properties; the presence
manager, presence hearts, presence-over-QUIC, heart-share and P9 acceptance suites, the heart-drop,
app-wiring, protected-sidecar, moderation, ban, ban-recovery, closeness, friend-state and
session-message suites hold the behaviour.

**Fernlet's own values, and the host's root.** This is Fernlet's module, so it spells Fernlet's
values itself: the heart-drop and moderation keychain services are the prekey store's and the ban
store's, the heart-drop and presence pair secrets pass `.fernlet`'s declared salts, the dead-drop,
presence and the ban store name FernletCrypto's sealing salt, day-tag prefix, sidecar authenticated
data, epoch-tag prefix and reporter-tag domain, and presence checks the heart payload's
`fernlet.proximity.heart` format on receipt and advertises Fernlet's hearts capability beside the
namespace's wire2 token. The production heart-drop scope, ``HeartDropStorageScope/production``, is
`ProximityNamespace.fernlet`'s sidecar root with `com.fernlet.heartdrop`, the paths and service the
stores have always used; ``HeartDropService`` defaults to it, and its outbox, dedup store and
peer-bundle cache fall back to that scope's directory when no file is stated. What a host must isolate
comes from the caller: the app hands the service its own scope (its per-store proximity sidecar root
and heart-drop keychain service), and each ledger takes the file it lives in with no default
(`fileURL(in:)` names it inside a root), so one store's "Reset everything" or "Delete everything"
never reaches another's files or keys. The dead-drop's, the ban store's and presence's own audit
lines (`heartdrop.*`, `storeBan.*`, `presence.identity.provisionFailed` and
`presence.posture.mintFailed`) go to `FernletAuditLog` directly; the dead-drop's and the ban store's
rows go through FernletFoundation's `KeychainItem` (each with its `ThisDeviceOnly` class, never
synchronizable), the query dictionaries ProximityKit's copy of that mechanism issues too, so a row
written by either reads back through the other. The sidecars' failures audit through ProximityKit's
`ProximityAudit` (`sidecar.*` for the ledgers, the `heartdrop.*` prefixes the stores pass for the
sealed sidecars), and so does presence's namespace refusal (`presence.identity.namespaceMismatch`,
which ProximityKit's namespace gate writes), which Fernlet's audit bridge forwards to the same log.

**What it builds on in ProximityKit.** Public API: `IdentityService` — its `fingerprint(of:)`, by
which the ledger buckets reporters and the ban store names a peer's ban, and for the dead-drop and
presence its generic `pairSecret(with:purpose:)`, the `staticKeyAgreement(withEphemeralPublicKey:)`
the sealer's static-key fallback opens through, the presence epoch clock, its key-agreement public
key, provisioning and wipe; the signed `FernletIdentityEnvelope` with its `PayloadSummary`;
`SealedPayloadFraming`; `ProtectedSidecar` and `SidecarSeal`; the shared `ProximityHeartLedger`; the
`ProximityPrekeyBundle` wire type; the two mesh storage scopes the derivation extends;
`ModerationReportPayload.maxReports`, the most rows one relay delivery may add; and for presence the
host seam (`ProximityHost`: its namespace, trusted peers and trust store, the hearts setting, the
per-connection trust policy, the resolved display name, the identity presence builds when it is
handed none, `makeProximityIdentity()`, which it checks against its namespace as an injected one, and
the heart-eligibility predicate `isTrustedUnblockedPeer(signingPublicKey:fingerprint:)`), the session
coordinator it builds a heart
connection over (`ProximityCoordinator`, with `ProximityPayloadHandling`, `NIRangingSession`,
`ReplayCache`, `PeerHandle` and the coordinator's prekey-bundle hooks), the `ObservationLoop` it
watches its coordinators through, `ProximityNamespaceGate`'s two manager doors, the peer-name
coercion `ProximityDisplayName.peerDisplayName(_:in:)`, the name display `PeerNameDisplay` (its
identifier filter, which `FernletConnections`' `firstName` runs first) and the recipe-share
diagnostics types its connection log rides. Three groups of `package` doors, each of
which `ProximityNamespaceBoundaryTests` lists with its exit: the presence radio's seam
(`PresenceRadioSession`), its QUIC conformer (`NetworkPresenceSession`), the peer channel a heart
connection runs over (`NetworkPeerChannel`), the epoch posture (`PresenceEpochPosture`) and the TXT
vocabulary (`PresenceAdvertisement`), until A1, when the seam is published as mechanism or wrapped by
a presence engine; the coordinator's typed send and manual commit, which presence's heart delivery
calls, until A0.7; and `JSONSidecarFile`, the naive JSON sidecar the three ledgers persist through,
which ProximityKit's activity manager and the mesh's photo-wall preferences still use, until A0.5,
when it moves here with them.

**What is still in ProximityKit.** The presence radio itself (its seam and QUIC conformer, its epoch
posture and TXT vocabulary), the mechanism presence drives, for good; the mesh manager's
feature parts and the types it builds, decodes or calls (the clothing shop, activities, chat's
session message store, the moderation report relay and its payload, the heart ledger), until A0.5;
and the recipe-share manager, until A0.7. Those Fernlet features join this module when they leave.

**Position in the FernletKit graph and the S3 wall.** The target depends on `ProximityKit`; on
`FernletConnections`, for `FernletFeaturePurposes.heartDropPairV1` and `.presencePairV1`, the
declared salts the heart-drop and presence pair secrets derive under,
`ProximityNamespace.fernlet`, whose sidecar root is the production heart-drop scope's directory, and
the name placeholders, `PeerNameDisplay.firstName` among them, which presence's
`PresenceManager.firstName(of:in:)` delegates to; on
`FernletCrypto`, for the dead-drop's, presence's and the ban store's registry labels; on
`FernletDomainModel`, for the heart, moderation, closeness, friend-state and companion value types
the stores keep, the friend records the dead-drop and presence read, the dead-drop's transport seam,
and the heart payload, payload type and hearts capability presence sends and checks; and on
`FernletFoundation`, for `KeychainItem`, `MonotonicClock`, `FernletAuditLog` and the `FernletDate`
day key a presence heart carries. It imports nothing else but Foundation, Observation, Security and
CryptoKit. Through ProximityKit it reaches
`PrivateMediaStore` transitively, which puts it on the protected side of the S3 wall: the walled
`AIProviders` and `CloudKitSync` targets have no edge to it, and
`S3BoundaryTests.proximityAndCloudSyncDoNotImportEachOther()` holds it to ProximityKit's pair of
rules (nothing here imports CloudKit, and CloudKitSync never imports this module): the dead-drop's
CloudKit transport is injected by the app. `BackgroundRefreshBoundaryTests` forbids the companion
refresh handler from importing it, and `TransportNeutralityBoundaryTests` and the P9 acceptance
battery's zero-lists scan it for MultipeerConnectivity. It has no string catalog: it localizes
nothing, and every string it holds is a token, a file name, an audit event or presence's English
status copy and diagnostics, which no catalog carries. The ban store's file, the `HeartSharing/`
folder and the presence tags' file are code-owned (`.github/CODEOWNERS`): the ban store holds a
keychain service whose self-ban row outlives every wipe by design, and a hash domain; the dead-drop
holds its seals, its keychain service and the derivations every drop in flight depends on; the
presence tags are what every pair of friends recognizes each other by.

**Isolation.** The module is main-actor by default (`defaultIsolation(MainActor.self)` in
`Package.swift`), matching ProximityKit: ``PresenceManager``, the ban store, the three ledgers and
``HeartDropService`` are main-actor `@Observable` classes, and the dead-drop's prekey store, outbox,
dedup store and peer-bundle cache main-actor classes, as the main-actor store that owns them and the
UI that observes them are; presence's pair secret and tag are main-actor members, as the identity
whose key they read is. The ban record, ``CachedFriendState``, ``ModerationContentHash``,
``TempMessagePayload``, the ledgers' persisted shapes, ``HeartDropSealer``, ``HeartDropStorageScope``,
``HeartDropSidecarFormatCensus``, the heart-drop tag statics, the presence tag length, presence's
pure first-name and heart-affordance statics and the mesh-scope derivations are `nonisolated`, so a
decode or a derivation never hops an actor.

## Topics

### Presence and in-person hearts

- ``PresenceManager``

### Away hearts

- ``HeartDropService``
- ``HeartDropSealer``
- ``HeartPrekeyStore``
- ``HeartDropPeerBundleCache``
- ``HeartDropOutbox``
- ``HeartDropDedupStore``

### Heart sidecars at rest

- ``HeartDropSidecarSeal``
- ``HeartDropStorageScope``
- ``HeartDropSidecarFormatCensus``

### Moderation

- ``ModerationLedger``
- ``ModerationBanStore``
- ``ModerationContentHash``

### Closeness and friend state

- ``ClosenessLedger``
- ``FriendStateCache``
- ``CachedFriendState``

### Live-session chat

- ``TempMessagePayload``
