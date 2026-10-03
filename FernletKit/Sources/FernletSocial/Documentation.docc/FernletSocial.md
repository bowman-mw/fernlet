# ``FernletSocial``

Fernlet's social features over ProximityKit's mechanisms. Today it holds moderation's device-local records — ``ModerationLedger``, the report rows; ``ModerationBanStore``, the tamper-resistant store-ban clock; and ``ModerationContentHash``, the key a report binds an artwork by — with the ``ClosenessLedger``, the ``FriendStateCache`` and its ``CachedFriendState`` rows, and ``TempMessagePayload``, the parked live-session chat payload.

## Overview

ProximityKit is becoming a drop-in package any app can use, with nothing Fernlet-specific in its
API (`Docs/Plan-FernletCoach-ProximityKit-2026-10-01.md` §3.2). Fernlet's rules on top of it, its
namespace, trust vault and session policies, live in `FernletConnections`; Fernlet's features live
here, moved out of ProximityKit in plan step A0.4 with their bytes unchanged. The edge runs
`FernletSocial` → ProximityKit, never the reverse, so ProximityKit can never name a type of this
module.

**What it holds.**

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

Nothing here touches a radio. ProximityKit's mesh manager hands the verified moderation rows and
friend-state payloads it receives to the app's closures, and the app files them in these stores;
every record is device-local and never part of the synced snapshot.

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
`crypto-goldens` CI line, holds to frozen literals the ban evidence's reporter tag, a reported
artwork's content hash, the ban store's two keychain accounts (`selfBan.device` and `peerBan:` ‖ the
peer's fingerprint), the three ledgers' file names (`ModerationLedger.json`, `ClosenessLedger.json`,
`FriendStateCache.json`), each ledger loading a literal file into its state, and two literal ban
records decoding. `PrivacyWipeCoverageTests` discovers the moderation service by the ban store's
`service: String = "com.fernlet.moderation"` default and holds the delete-everything funnel to its
peer-ban clear; the moderation, ban, ban-recovery, closeness, friend-state and session-message suites
hold the behaviour.

**Fernlet's own values, and the host's root.** This is Fernlet's module, so it spells Fernlet's
values itself: the moderation service is the ban store's default, and the ban store names
FernletCrypto's reporter-tag domain. What a host must isolate comes from the caller: each ledger
takes the file it lives in with no default (`fileURL(in:)` names it inside a root), and Fernlet's
`FernletStore` passes its own per-store proximity sidecar root, so one store's "Reset everything"
never reaches another's files. The ban store's audit lines (`storeBan.*`) go to `FernletAuditLog`
directly, its rows through FernletFoundation's `KeychainItem` (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
never synchronizable), the query dictionaries ProximityKit's copy of that mechanism issues too, so a
row written by either reads back through the other. The ledgers' sidecar failures audit through
ProximityKit's `ProximityAudit` (`sidecar.*`, naming the file), which Fernlet's audit bridge forwards
to the same log.

**What it builds on in ProximityKit.** Public API: `IdentityService.fingerprint(of:)`, by which the
ledger buckets reporters and the ban store names a peer's ban, and
`ModerationReportPayload.maxReports`, the most rows one relay delivery may add. One `package` door:
`JSONSidecarFile`, the naive JSON sidecar the three ledgers persist through, which ProximityKit's
activity manager and the mesh's photo-wall preferences still use; `ProximityNamespaceBoundaryTests`
lists its lines with their exit, plan step A0.5, when it moves here with them.

**What is still in ProximityKit.** Fernlet's heart dead-drop and presence, which plan step A0.4
moves here too; the mesh manager's feature parts and the types it builds, decodes or calls (the
clothing shop, activities, chat's session message store, the moderation report relay and its
payload, the heart ledger), until A0.5; and the recipe-share manager, until A0.7.

**Position in the FernletKit graph and the S3 wall.** The target depends on `ProximityKit`; on
`FernletCrypto`, for the ban store's reporter-tag domain; on `FernletDomainModel`, for the
moderation, closeness, friend-state and companion value types the stores keep; and on
`FernletFoundation`, for `KeychainItem`, `MonotonicClock` and `FernletAuditLog`. It imports nothing
else but Foundation, Observation, Security and CryptoKit. Through ProximityKit it reaches
`PrivateMediaStore` transitively, which puts it on the protected side of the S3 wall: the walled
`AIProviders` and `CloudKitSync` targets have no edge to it, and
`S3BoundaryTests.proximityAndCloudSyncDoNotImportEachOther()` holds it to ProximityKit's pair of
rules (nothing here imports CloudKit, and CloudKitSync never imports this module).
`BackgroundRefreshBoundaryTests` forbids the companion refresh handler from importing it, and
`TransportNeutralityBoundaryTests` scans it for MultipeerConnectivity. It has no string catalog: it
localizes nothing, and every string it holds is a token, a file name or an audit event. The ban
store's file is code-owned (`.github/CODEOWNERS`): it holds a keychain service whose self-ban row
outlives every wipe by design, and a hash domain.

**Isolation.** The module is main-actor by default (`defaultIsolation(MainActor.self)` in
`Package.swift`), matching ProximityKit: the ban store and the three ledgers are main-actor
`@Observable` classes, as the main-actor store that owns them and the UI that observes them are,
while the ban record, ``CachedFriendState``, ``ModerationContentHash``, ``TempMessagePayload`` and
the ledgers' persisted shapes are `nonisolated` values, so a decode never hops an actor.

## Topics

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
