# ``FernletSocial``

Fernlet's social features over ProximityKit's mechanisms: the mesh features the routed mesh engine carries — ``FernletMeshFeatures``, the composition that owns the engine and every feature on it (the session photos and their review, live-session chat, the in-session hearts with the heart ledger, the clothing shop, Group Activities, the moderation report relay, friend-state exchange, the capability list and the vouch list), and ``FernletRoutedTypes``, the routed-type rows those features ride — presence — ``PresenceManager``, which drives ProximityKit's presence radio so kept friends recognize each other nearby by rotating pairwise tags, and delivers in-person hearts over short-lived connections formed on that recognition — recipe sharing — ``ProximityRecipeShareManager``, which sends a recipe to a nearby Fernlet and queues the recipes nearby Fernlets send, over ProximityKit's one-to-one pair session under Fernlet's recipe profile, with the recipe payload's wire types — the heart dead-drop — ``HeartDropService``, the offline "away" hearts that ride an injected public-database transport as sealed blobs under rotating day tags, with its sealer, prekey store, sidecar stores and seal — moderation's device-local records — ``ModerationLedger``, the report rows; ``ModerationBanStore``, the tamper-resistant store-ban clock; and ``ModerationContentHash``, the key a report binds an artwork by — with the ``ClosenessLedger``, the ``FriendStateCache`` and its ``CachedFriendState`` rows, and ``TempMessagePayload``, the parked live-session chat payload.

## Overview

ProximityKit is a drop-in package any app can use (its own repository's since plan step A1.3,
which Fernlet pins at exactly 0.1.0), with nothing Fernlet-specific in its
API (`Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md` §3.2). Fernlet's rules on top of it, its
namespace, trust vault and session policies, live in `FernletConnections`; Fernlet's features live
here, every byte they put on the wire, in the keychain or on disk the one Fernlet shipped (pinned
below). The edge runs `FernletSocial` → ProximityKit, never the reverse, so ProximityKit can never
name a type of this module, and `ProximityNamespaceBoundaryTests` refuses one declared, extended or
aliased there again under its old name, which nothing else would notice. Recipe sharing, the last
Fernlet feature ProximityKit held, is here too, over ProximityKit's one-to-one pair session (plan step
A0.7).

**The mesh features.** ProximityKit's `MeshNetworkManager` is a routed mesh engine: it forms the
session, keeps the membership and the session roster, and carries routed items, and it knows no
feature. Fernlet's mesh features are this module's, composed behind one object and plugged into the
engine through its public seams.

- ``FernletMeshFeatures`` (`Mesh/FernletMeshFeatures.swift`): the composition the app builds once, as
  FernletStore's `meshFeatures`. It asks the host for the device identity once, builds the mesh with
  it, builds each feature over the mesh and the same identity, and installs every engine role a
  feature plays before its initializer returns — the capability provider, the vouch-list exchange,
  nine payload handlers on the engine's payload token door, the activity manager's two mesh seams, the
  chat's and the photos' projection handlers and the hearts' ledger judge under their rows' tokens,
  and, last, the session observer — so no restore, re-entry or radio start sees a mesh without them.
  It owns the mesh and every feature (the app reaches the mesh as `meshFeatures.mesh`); the mesh
  retains only the roles it calls — closures and adapters nested in the features that play them — and
  holds the observer weakly. The observer fans each session moment the engine reports — a slot's
  commit and loss, the search's start and stop, the session's end and this device's leaving it, a
  scope change, a member's removal, a changed access gate and a privacy wipe's start — out to the
  features in one fixed order, whose commit and end legs `FernletFeatureGoldenTests` observes. A registration the mesh refused is audited
  `meshFeatures.registrationRefused` and kept for the test rig, which holds it empty.
- ``FernletSocialHost`` (`FernletSocialHost.swift`): the host the features read — ProximityKit's
  `ProximityHost` refined with the three requirements only these features read (the trusted-peer
  records, the durable trust store and the in-person hearts opt-in, which defaults to on) and the
  heart-eligibility check over them,
  ``FernletSocialHost/isTrustedUnblockedPeer(signingPublicKey:fingerprint:)``. The composition and
  presence take FernletStore as one; ProximityKit asks none of these questions.
- ``FernletRoutedTypes`` (`Mesh/FernletRoutedTypes.swift`): Fernlet's three routed-type rows over the
  namespace's routed types, which the host hands the mesh as `ProximityHost.meshRoutedTypeEntries`
  and the mesh builds its whole registry from: the temporary-message row, the heart row (whose final
  ack is the ledger judgement) and the photo row. Each cap is a formula over its body's constants, and
  the photo row's, `PrivateMediaStore.maxIncomingPhotoBytes` + the photo body's framed header + the
  seal's overhead (10 551 337 bytes), is the widest, so it is the mesh's resident bound for its seal,
  its open and its projection's guard. The one file here that reads a routed type off the namespace.
- ``MeshSessionPhotos`` (`Mesh/MeshSessionPhotos.swift`, with the review's values
  ``MeshFriendReviewBatch``, ``SessionPhotoAnswer`` and ``SessionPhotoAnswerFailure`` in
  `Mesh/MeshSessionReviewTypes.swift` and the routed photo body in `Mesh/MeshRoutedPhotoBody.swift`):
  the friend-photo wall (``FriendPhotoWallPost``) with its preferences and favourites; the sealed
  pending corpus every session photo is held in, taken here or received, until the person answers; the
  film and its quota; the session-end review batch, into which each ending merges the roster the mesh
  drained; the capture (``MeshSessionPhotos/addPhoto(_:)``) and its routed share, minted through the
  engine's origination door under the photo row's token; and the photo row's projection handler — an
  answered photo's tombstone settled before the engine opens anything, then the per-origin quota, the
  sanitised hold and the closeness hook. Chosen photos persist metadata-only in the
  `PrivateMediaStore`-backed wall; unchosen ones only in the pending corpus, under a device-bound key.
  ``MeshSessionPhotos/purgeHeldSessionPhotosForDeleteAll()`` and
  ``MeshSessionPhotos/invalidateEncryptionKeyCaches()`` are its legs of the delete-all funnel.
  ``MeshSessionPhotos/removeReportedPhoto(_:)`` is the photo's half of Report… (App Review guideline
  1.2, 2026-10-15): a held photo is answered as declined, deleted for good as an unticked one is, and a
  wall photo is deleted with its tombstone; reporting the sender is the app's people report.
- ``MeshSessionChat`` (`Messaging/MeshSessionChat.swift`, with ``SessionMessageStore``, the send
  filter and the routed text body in `Messaging/`): the live-session transcript, the 13+ gate
  (`chatAllowedProvider`), the text sender (``MeshSessionChat/sendTempMessage(_:)``, which answers
  ``MeshTextSendOutcome`` and publishes nothing), the per-origin message budget, and the
  temporary-message row's projection handler — the 13+ gate before the engine opens an item, then the
  session liveness the engine computed, the budget and the transcript. **App Review guideline 1.2
  (2026-10-15).** The sender runs the on-device send filter, `SessionMessageFilter`
  (`Messaging/SessionMessageFilter.swift`), over the whole sanitized draft before anything is framed
  or minted, and answers ``MeshTextSendOutcome/filtered`` for a draft holding a word from its short list
  of slurs — stored as SHA-256 digests, because the repository is public, and matched as whole words
  after case, diacritic, substitution and repeated-letter folding. Only this device's own drafts are
  filtered: a received message is not, because its receiver can Report it. Each transcript row
  carries its author's verified signing key (`SessionMessageStore.Message.senderSigningPublicKey`, empty
  for this device's own rows, which `canBeReported` never offers), the key the app's Report… on a
  message names, and ``MeshSessionChat/refreshVisibleTranscript()`` re-folds the view gates at once
  after such a report, so the reported author's rows leave the transcript without waiting for the next
  message. The transcript is memory-only and vanishes: the composition's
  observer drops it at a session's formation, its end and a privacy wipe's start, each right after the
  engine advances its session-content generation, which is what the liveness reads.
- ``MeshSessionHearts`` (`HeartSharing/MeshSessionHearts.swift`): the in-session heart to one
  recipient (``MeshSessionHearts/sendSessionHeart(to:)``), its state and failure vocabulary with their
  auto-clear, the two reachability questions the camera's heart button asks, and the heart row's
  ledger judge: hearts on and the ledger loaded as its readiness, a trusted, unblocked author as its
  admission, decided before any byte is read, and the heart ledger's commit as its judgement, from
  whose `committed` answer the engine mints the ack evidence itself. The ledger is
  ``ProximityHeartLedger`` (`HeartSharing/ProximityHeartLedger.swift`, with its rows
  ``ReceivedHeartRecord`` and its proof ``MeshHeartLedgerProof``), shared with presence and the
  dead-drop; the routed heart body, the ack's proof gate, the merged heart and the commit through the
  ledger sit beside it in `HeartSharing/`.
- ``MeshClothingShop`` (`ClothingSharing/MeshClothingShop.swift`, with its mesh wiring in
  `ClothingShopExchange.swift` and ``ClothingCatalogPayload`` and ``ProximityClothingCatalog`` in
  `Wire/ClothingSharePayloads.swift`): catalogs exchanged during the session, once per slot and
  capability-gated, with a request for the peer's so the exchange does not depend on which side
  commits first, and the one-hour browse window after the session; the app's
  `allowNearbyClothingShares` opt-out is payload-layer, through the shop's providers.
- ``ProximityActivityManager`` (`Activities/`, with its payloads in `Wire/ActivityPayloads.swift`:
  ``ActivityOfferPayload``, ``ActivityJoinRequestPayload``, ``ActivityJoinGrantPayload``,
  ``ActivityRosterSnapshotPayload``, ``ActivitySyncPayload`` and ``ActivityParamsHash``): Group
  Activities on the friend mesh, with no radio of their own — host-authoritative rosters, a join token
  the host signs and binds to the invitee's key, host-signed roster snapshots, and a device-local sidecar
  (`ActivityLedger.json`) so a hosted or joined activity survives launches until it expires.
- ``ModerationReportExchange`` (`Moderation/ModerationReportExchange.swift`, with
  ``ModerationReportRelay``, ``ModerationReportPayload`` and ``SignedModerationReport`` in
  `Moderation/ModerationReportRelay.swift`): the one-hop report relay — this device's own signed rows
  handed to a vault-trusted friend at a commit, and such a friend's verified rows handed to the app,
  which files them in ``ModerationLedger``.
- ``FriendStateExchange`` (`Mesh/FriendStateExchange.swift`): the fuzzy friend state's mesh wiring —
  the opt-in that gates its capability, the handler that hands a vault-trusted friend's state to the
  app, which records it in ``FriendStateCache``, and the commit-time send of this device's own.
- ``FernletMeshCapabilities`` and ``FernletVouchList`` (`Mesh/`): the capability tokens the mesh
  advertises, composed from the features' switches in their signed order (photos, the namespace's wire2
  token, then away hearts, the shop, messages, moderation, friend state, activities and hearts, each
  switched one in its place), and the friend vouch list's content — the lists committed peers sent,
  the list this device would send, the receive hygiene and the "Friend of" label the app reads
  (``FernletVouchList/vouchLabel(for:)``).
- The content layer (`Mesh/MeshContentLedger.swift`, `Mesh/MeshContentIngest.swift`): Fernlet's three
  content kinds over ProximityKit's generic union (`MeshContentSet` over `MeshMergeableContent`), the
  ledger that holds them, the photo reassembly's hash validation, the
  gates re-run at the receiving member as a view filter over an unmutated union, and the heart receipt.
- `Wire/FeatureCanonicalBytes.swift`: the activities' and the moderation report's canonical signing
  bytes, written with ProximityKit's public `CanonicalByteWriter` under their FernletCrypto domains,
  and `FernletFeatureSignatures`, the three host labels the join token, the roster snapshot and the
  report row are signed and verified under through ProximityKit's identity, minted with its
  `ProximityCryptographicPurpose.featureSignature(_:framing:)`, each the twin of its registry
  domain until C1.

**Presence and the dead-drop.**

- ``PresenceManager`` (`Presence/PresenceManager.swift`): the standing presence radio's owner. It
  advertises only rotating pairwise-DH tags, one for each of the 24 most recently seen kept friends,
  and matches a browsed peer's tags against every eligible friend's over the epoch before and after
  its own, so kept friends recognize each other nearby without connecting; three self-exclusion
  layers drop this device's own ghost advertisements, and a 45-second lost grace smooths a friend's
  epoch restart. It drives ProximityKit's presence engine, `ProximityPresenceSession`, which builds
  the radio, wears its epoch posture (an instance name and a TLS identity replaced whole at every
  900-second boundary, when the manager's one timer asks), speaks its TXT record and drops this
  device's ghosts by name; the tags, the matching, the other two self-exclusion layers, the posture
  mint's once-per-epoch budget and its audit row stay here, and nothing about any of it is
  persisted. Hearts: a send dials the tag-matched peer, runs the one-round-trip
  friend handshake under the sealed-introduction rule (the introduction and its acknowledgement are
  sealed to the intended friend's key-agreement key, so a tag-replay forger learns nothing),
  auto-commits, verifies the connected identity is that friend and still heart-eligible, sends one
  sealed heart and tears the connection down; a receive admits only a dialer whose claimed tag
  resolves to a browsed, matched friend and records the heart in the shared heart ledger under its
  5-minute window. The host's in-person hearts opt-in, `FernletSocialHost.allowNearbyHearts`, gates
  both sides; a heart for a friend who just left goes to the dead-drop through `queueAwayHeart`, and
  the away-delivery consent reaches presence as `heartsAwayEnabledProvider`, read only for the
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

**Moderation, closeness and friend state.**

- ``ModerationLedger`` (`Moderation/ModerationLedger.swift`): the append-only report rows, this
  device's own reports and retracts beside peers' one-hop-verified rows, bounded max-min fairly per
  reporter so a flooding peer can never evict this device's own reports. The app files a verified
  relay batch here (`FernletStore.ingestModerationRows`) and hands its rows to the relay as this
  device's own reports.
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
  a warmth signal, never a who-met-whom log. The app's hooks on the mesh features, presence and the
  recipe-share manager record into it.
- ``FriendStateCache`` and ``CachedFriendState`` (`Presence/FriendStateCache.swift`): the fuzzy
  wellbeing state and companion appearance a friend shared at the last in-person meeting, shown "as
  of last time you met" for 30 days. The app records each verified state the friend-state exchange
  hands it.
- ``TempMessagePayload`` (`Wire/MessagePayloads.swift`): the retired live-session chat payload,
  frozen and parked. Nothing emits or dispatches it (chat rides the routed store); it stays
  decodable so an older peer's frame parks by name, and it is the sealing-required control several
  wire suites make their claims against.

Only presence brings a radio up itself, through ProximityKit's public presence engine,
`ProximityPresenceSession` (below); the mesh features ride the engine the composition builds, which
runs the mesh radio. The engine hands every payload
and routed item it receives for a feature to the handler, projection handler or ledger judge
registered for its token, after its own gates; the features hand what the app files (verified
moderation rows, a friend's state) to the app's closures, and the app files them in these stores. The mesh and presence hand the prekey bundles their introductions carry
to the dead-drop the same way, and the hearts each path sends or receives reach the closeness ledger
through the app's closures too. Every record is device-local and never part of the synced snapshot;
the one thing that leaves the device is a sealed drop, through the transport the app injects
(CloudKitSync's `HeartDropCloudTransport`, behind FernletDomainModel's `HeartDropTransporting`),
which sees only rotating day tags and ciphertext.

**The heart sidecars are sealed, and scoped as a pair.** The outbox, the dedup store and the
peer-bundle cache load through ProximityKit's `ProtectedSidecar`, which classifies a read failure so
a locked-device read can never be mistaken for "empty" and overwrite real data, sealed at rest by
``HeartDropSidecarSeal`` under a key that lives under the heart-drop keychain service, so
`HeartDropService.wipeForDeleteAll()` takes files and key together. A scope that moved only the
directory would be cosmetic — another store's wipe still deletes the shared key, and the isolated
file then survives as ciphertext nothing can open, which the outbox quarantines and latches as data
loss. So ``HeartDropStorageScope`` is (directory, keychain service), always both, and scoping is
never unsealing: a store on its own scope still seals through the real ``HeartDropSidecarSeal`` key
path. The heart ledger loads through `ProtectedSidecar` too.

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
records decoding. For the mesh features it holds the advertised capability array in each of the 32
states of its five switches; the routed rows' caps and the resident bound they make; the token each
sender mints under; the routed heart and text bodies' frozen bytes; the activities' and the
moderation report's canonical transcripts and signatures; the feature payloads' JSON; the heart and
activity ledgers' files; the photo wall's files and the proximity root's layout; the keychain role
that seals each photo corpus; the vouch list's lifetime and label; the item report and the friend
state sent at a commit; the camera's hold-failure line; the audit lines the features write; and the
order a session's commit and end run their legs in. `PrivacyWipeCoverageTests` discovers the
heart-drop service by the prekey store's `keychainService = "com.fernlet.heartdrop"` and the
moderation service by the ban store's `service: String = "com.fernlet.moderation"` default, and holds
the delete-everything funnel to the dead-drop's purge and wipe, the ban store's peer-ban clear, the
heart, moderation, friend-state, closeness and activity ledgers' clears, the shop's, the session
photos' purge and key-cache drop, and presence's wipe among the three identity seams.
`HeartDropSidecarFormatCensusTests` pins the sidecars' four file names and markers;
`PresenceTagTests` holds presence's malformed-key refusal and its tags' properties; the presence
manager, presence hearts, presence-over-QUIC, heart-share and P9 acceptance suites, the heart-drop,
app-wiring, protected-sidecar, moderation, ban, ban-recovery, closeness, friend-state and
session-message suites, and the mesh suites on the `mesh-features` line, hold the behaviour.

**Fernlet's own values, and the host's root.** This is Fernlet's module, so it spells Fernlet's
values itself: the heart-drop and moderation keychain services are the prekey store's and the ban
store's, the heart-drop and presence pair secrets pass `.fernlet`'s declared salts, the dead-drop,
presence and the ban store name FernletCrypto's sealing salt, day-tag prefix, sidecar authenticated
data, epoch-tag prefix and reporter-tag domain, the activities and the moderation report frame
their canonical bytes under FernletCrypto's four feature labels and sign the three signed ones under
their host-label twins (`FernletFeatureSignatures`), the mesh features register, send and gate by FernletDomainModel's
`PayloadType` and `ProximityCapability` cases and mint under ``FernletRoutedTypes``' rows over
`.fernlet`'s routed types, and presence checks the heart payload's `fernlet.proximity.heart` format on
receipt and advertises Fernlet's hearts capability beside the namespace's wire2 token. The
production heart-drop scope, ``HeartDropStorageScope/production``, is Fernlet's proximity root,
`FernletConnections`' `FernletProximityStorage.productionDirectory` (`.fernlet`'s folder under
Application Support), with `com.fernlet.heartdrop`, the paths and service the
stores have always used; ``HeartDropService`` defaults to it, and its outbox, dedup store and
peer-bundle cache fall back to that scope's directory when no file is stated. What a host must isolate
comes from the caller: the app hands the service its own scope (its per-store proximity sidecar root
and heart-drop keychain service), each ledger takes the file it lives in with no default
(`fileURL(in:)` names it inside a root), and the session photos and the activity manager file their
stores under the host's proximity root, so one store's "Reset everything" or "Delete everything"
never reaches another's files or keys. The features' audit lines go to `FernletAuditLog` directly:
the dead-drop's, the ban store's and presence's own (`heartdrop.*`, `storeBan.*`,
`presence.identity.provisionFailed` and `presence.posture.mintFailed`), the mesh features' (`mesh.*`,
`activity.*`, `moderation.relay*` and `meshFeatures.registrationRefused`), which
`FernletFeatureGoldenTests` pins wherever a cell can drive one, and the ledgers' sidecar's under
`sidecar.*` — that sidecar,
`JSONSidecarFile` (`Support/JSONSidecarFile.swift`), the naive JSON idiom the activity, moderation,
closeness and friend-state ledgers and the photo wall's preferences persist through, is this module's
own and internal. The dead-drop's and the ban store's rows go through FernletFoundation's
`KeychainItem` (each with its `ThisDeviceOnly` class, never synchronizable), the query dictionaries
ProximityKit's copy of that mechanism issues too, so a row written by either reads back through the
other. The sealed sidecars' failures audit through ProximityKit's `ProximityAudit` (the `heartdrop.*`
prefixes the stores pass), and so does presence's namespace refusal
(`presence.identity.namespaceMismatch`, which ProximityKit's namespace gate writes), which Fernlet's
audit bridge forwards to the same log.

**What it builds on in ProximityKit.** Public API: `IdentityService` — its `fingerprint(of:)`, by
which the ledger buckets reporters and the ban store names a peer's ban, its generic
`pairSecret(with:purpose:)` for the dead-drop and presence, the `staticKeyAgreement(withEphemeralPublicKey:)`
the sealer's static-key fallback opens through, its `sign` and `verify` under the host labels the
activities and the moderation report mint with `ProximityCryptographicPurpose.featureSignature(_:framing:)`,
the presence epoch clock,
its key-agreement public key, provisioning and wipe; the signed `ProximityIdentityEnvelope` with its
`PayloadSummary`; `SealedPayloadFraming`; `ProtectedSidecar` and `SidecarSeal`; the
`ProximityPrekeyBundle` wire type; the two mesh storage scopes the derivation extends; the mesh
engine, `MeshNetworkManager`, and every seam the composition plugs into it — the payload token door
and the captured-slot feature send, the routed origination door and its addressability query, the
routed share refusal it reports, the projection-handler and ledger-judge registrations with their
contracts (`MeshRoutedProjectionHandler`, `MeshRoutedLedgerJudge`, `MeshRoutedBody`,
`MeshRoutedDelivery`), the session observer (`MeshSessionObserver`, with `MeshSlotCommit`,
`MeshSessionEnd` and `MeshScopeChange`), the capability-list provider, the vouch-list exchange
(`MeshVouchListExchange`) and the identity-taking initializer; the routed row and its public column
types (`MeshRoutedTypeEntry`), the body framing (`MeshRoutedItemBodyFormat`, `CanonicalByteWriter`,
`MeshRoutedItemSealFormat.overheadByteCount`) and the generic content union (`MeshContentSet`); and
for presence the host seam (`ProximityHost`: its namespace, the per-connection trust policy and
ranging provider, `makeProximityRangingProvider()`, the resolved display name, the identity presence
builds when it is handed none, `makeProximityIdentity()`, which it checks against its namespace as an
injected one, and the fingerprint block list), the session coordinator it builds a heart connection
over (`ProximityCoordinator`, with `ProximityPayloadHandling`, the host's ranging provider,
`ReplayCache`, `PeerHandle` and the coordinator's prekey-bundle hooks), the `ObservationLoop` it
watches its coordinators through, `ProximityNamespaceGate`'s two manager doors, the peer-name coercion
`ProximityDisplayName.peerDisplayName(_:in:)`, which every feature here re-moderates a peer's name
through, the name display `PeerNameDisplay` (its identifier filter, which `FernletConnections`'
`firstName` runs first). A heart
connection sends and commits through the coordinator's public per-connection API: its token send,
`sendPayload(payloadTypeToken:summary:payload:sealed:)`, under `PayloadType.friendHeart`'s raw value,
and its manual commit, `commitManualProximity()`. Presence reaches the air through ProximityKit's
public presence engine, `ProximityPresenceSession` (plan step A1.1): its six hooks, the posture
rotation and epoch, start and republish with this manager's tags, stop, the dial with a hello tag and
the disconnect, and the `ProximityPeerChannel` it hands a heart connection, whose `notifyConnected()`
the heart door calls once the connection's coordinator has begun. No `package` door is left:
the radio, its seam, the peer channel's concrete type, the posture and the TXT vocabulary are
internal to ProximityKit.

**Recipe sharing.** ``ProximityRecipeShareManager`` (`RecipeSharing/ProximityRecipeShareManager.swift`)
is Fernlet's recipe share over ProximityKit's `ProximityPairSession`, which it builds at construction
under FernletConnections' recipe profile on its host's own namespace
(`ProximityPairProfile.recipeShare(in:)`: the recipe radio's row, the TXT mode `recipe`, the audit
area `recipeShare`). The mechanism is the session's: discovery, the hard two-device cap, the identity
handshake and commit, the status line with its 2.5 s clear, and the send outcome, each published to
the share sheet through this manager's computed reads (`nearbyRecipients`, `sendState`,
`lastShareOutcome`, `engagedRecipientID`), so a view observing the manager re-renders on the session's
writes. `isListening`, the radio's own account of whether it is up, is read through too but not
observed: the app's run-policy seam reads it on each run. What is the recipe's is here: the payload
(``ProximityRecipeSharePayload``, `Wire/RecipeSharePayloads.swift`) and the summary `Recipe share`
over its ingredient count, signed into every recipe envelope and never localized; the inbound rules (it is the session's payload handler: a
1 MiB size gate before decoding, the format and version check, the 512 KiB image drop, the review
clamps, a 3 s per-sender rate limit and an eight-share queue, ``PendingProximityRecipeShare``); and the
English the share sheet shows, rendered from the session's typed status and events by one renderer
whose switches are exhaustive, byte for byte the sentences the sheet renders verbatim. The session's
events and the receive handler's own lines land in the diagnostics ring
(``ProximityRecipeShareDiagnostics``, ``ProximityRecipeShareDiagnosticEvent``), which presence's
connection log rides too. The body grows only by OPTIONAL keys on `version` 1: the saved arm's steps,
the picture, and a multipart recipe's `components` partition on the local arm (the rule is documented
in `FernletDomainModel`'s `RecipeComponentWire.swift`); an older peer's synthesized decode ignores them
and still reads a whole recipe. The "Include notes" strip
(``ProximityRecipeSharePayload/omittingShareNotes()``) withholds a local recipe's steps through
`SharedRecipePayload.withoutSteps()`, which rewrites the partition to match. `FernletFeatureGoldenTests`
group 31 pins the payload's JSON, the pairing's frames, persisted audit rows and status sentences,
the copy's templates and the profile and constants.

**What is still in ProximityKit.** The presence engine, `ProximityPresenceSession`, with the radio it
wraps (its seam and QUIC conformer, its epoch posture and TXT vocabulary), the mechanism presence
drives, the routed mesh engine the mesh features ride, and the one-to-one pair session recipe sharing
runs over, each for good.

**Position in the FernletKit graph and the S3 wall.** The target depends on `ProximityKit`; on
`FernletConnections`, for `FernletFeaturePurposes.heartDropPairV1` and `.presencePairV1`, the
declared salts the heart-drop and presence pair secrets derive under, the recipe share's pair
profile, `ProximityPairProfile.recipeShare(in:)`,
`FernletProximityStorage.productionDirectory`, Fernlet's proximity root, which is the production
heart-drop scope's directory, `ProximityNamespace.fernlet`, whose routed types ``FernletRoutedTypes``
reads, the name placeholders,
`PeerNameDisplay.firstName` among them, which presence's `PresenceManager.firstName(of:in:)`
delegates to, and the signed envelope's typed view (`payloadType`, the typed initializer and the typed
`signed`), which the heart dead-drop signs and reads through and presence, the clothing shop and
recipe sharing read through; on `FernletCrypto`, for the dead-drop's, presence's and the ban store's
registry labels and the activities' and the moderation report's four canonical-bytes domains; on
`FernletDomainModel`, for the heart, moderation, closeness, friend-state and companion value types the stores keep, the friend
records the dead-drop, presence and the session hearts read, the dead-drop's transport seam, the
payload types and capabilities the features register, send and check, the activity, clothing,
photo-session and friend-state values the mesh features carry, and the recipe payload's models
(`SharedRecipePayload`, `RecipeStep`, `Micronutrients`, `SharedRecipeLimits`); on `FernletFoundation`, for
`KeychainItem`, `MonotonicClock`, `FernletAuditLog` and the `FernletDate` day key a presence or
session heart carries; and on `PrivateMediaStore`, for the session photos' friend wall and sealed
pending corpus, their keychain key providers and the capture's resize. It imports nothing else but
Foundation, Observation, Security, CryptoKit and UIKit, whose `UIImage` the capture's resize reads.
So it builds for iOS alone: the native macOS build plan step A0.6 added covers the Mac-ready set
(FernletFoundation, FernletCrypto and FernletDomainModel since plan step A1.3; ProximityKit's own
repository's CI builds it for macOS), not this module, whose photo path (and `PrivateMediaStore`'s encoders under it) would need a UIKit-free
twin, with goldens of its own, before a Mac host could link it.
Its `PrivateMediaStore` edge puts it on the protected side of the S3 wall (ProximityKit, which depends
on nothing, has reached no sealed store since plan step A0.5.10): the walled
`AIProviders` and `CloudKitSync` targets have no edge to it, and
`S3BoundaryTests.proximityAndCloudSyncDoNotImportEachOther()` holds it to ProximityKit's pair of
rules (nothing here imports CloudKit, and CloudKitSync never imports this module): the dead-drop's
CloudKit transport is injected by the app. `BackgroundRefreshBoundaryTests` forbids the companion
refresh handler from importing it, and `TransportNeutralityBoundaryTests` and the P9 acceptance
battery's zero-lists scan it for MultipeerConnectivity. Its one string catalog holds the camera's
hold-failure line, resolved through `FernletSocialCopy` with `bundle: .module`; every other string it
holds is a token, a file name, an audit event or presence's English status copy and diagnostics,
which no catalog carries. Code-owned (`.github/CODEOWNERS`): the ban store's file, which holds a
keychain service whose self-ban row outlives every wipe by design, and a hash domain; the report
relay and the canonical bytes, whose bytes every relayed report's signature covers; the activity
manager and its payloads, whose bytes every grant, roster and activity ledger covers; the JSON
sidecar, whose encoder settings every ledger file already saved depends on; the `HeartSharing/`
folder, which holds the dead-drop's seals, its keychain service and the derivations every drop in
flight depends on, and the heart ledger and the session hearts beside them; the presence tags'
file, which every pair of friends recognizes each other by; and the recipe share's wire file and its
`RecipeSharing/` folder, the payload's format and the summary signed into every recipe envelope.

**Isolation.** The module is main-actor by default (`defaultIsolation(MainActor.self)` in
`Package.swift`), matching ProximityKit: ``FernletMeshFeatures``, ``PresenceManager``,
``ProximityRecipeShareManager``, the session photos, chat, hearts, transcript store, clothing shop, activity manager, heart ledger, ban store, the
three ledgers and ``HeartDropService`` are main-actor classes, all but the composition `@Observable`,
and the capability list, the vouch list, the two exchanges and the dead-drop's prekey store, outbox,
dedup store and peer-bundle cache main-actor classes, as the main-actor store that owns them and the
UI that observes them are; presence's pair secret and tag are main-actor members, as the identity
whose key they read is. ``FernletRoutedTypes``, the routed bodies, the review values, the feature
payloads, the recipe payload and its shapes, the diagnostics ring, the ban record, ``CachedFriendState``,
``ModerationContentHash``, ``TempMessagePayload``, the chat's send filter,
the ledgers' persisted shapes, ``HeartDropSealer``, ``HeartDropStorageScope``,
``HeartDropSidecarFormatCensus``, the heart-drop tag statics, the presence tag length, presence's
pure first-name and heart-affordance statics and the mesh-scope derivations are `nonisolated`, so a
decode or a derivation never hops an actor.

## Topics

### The mesh composition

- ``FernletMeshFeatures``
- ``FernletSocialHost``
- ``FernletRoutedTypes``
- ``FernletMeshCapabilities``
- ``FernletVouchList``

### Session photos and their review

- ``MeshSessionPhotos``
- ``FriendPhotoWallPost``
- ``MeshFriendReviewBatch``
- ``SessionPhotoAnswer``
- ``SessionPhotoAnswerFailure``

### Live-session chat

- ``MeshSessionChat``
- ``MeshTextSendOutcome``
- ``SessionMessageStore``
- ``TempMessagePayload``

### In-session hearts and the heart ledger

- ``MeshSessionHearts``
- ``ProximityHeartLedger``
- ``ReceivedHeartRecord``
- ``MeshHeartLedgerProof``

### Clothing shop

- ``MeshClothingShop``
- ``ClothingCatalogPayload``
- ``ProximityClothingCatalog``

### Group Activities

- ``ProximityActivityManager``
- ``ActivityParamsHash``
- ``ActivityOfferPayload``
- ``ActivityJoinRequestPayload``
- ``ActivityJoinGrantPayload``
- ``ActivityRosterSnapshotPayload``
- ``ActivitySyncPayload``
- ``FernletFeatureSignatures``

### Presence and in-person hearts

- ``PresenceManager``

### Recipe sharing

- ``ProximityRecipeShareManager``
- ``ProximityRecipeSharePayload``
- ``ProximitySharedRecipe``
- ``ProximitySharedRecipeKind``
- ``SharedSavedRecipePayload``
- ``PendingProximityRecipeShare``
- ``ProximityRecipeShareDiagnostics``
- ``ProximityRecipeShareDiagnosticEvent``

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
- ``ModerationReportExchange``
- ``ModerationReportRelay``
- ``ModerationReportPayload``
- ``SignedModerationReport``

### Closeness and friend state

- ``ClosenessLedger``
- ``FriendStateCache``
- ``CachedFriendState``
- ``FriendStateExchange``
