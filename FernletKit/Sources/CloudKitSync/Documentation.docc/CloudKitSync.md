# ``CloudKitSync``

Fernlet's iCloud-synced persistence layer: the Core Data + CloudKit repository stack, the per-row synced stores, direct-CloudKit detection/deletion/sealed-backup services, and the heart-drop public-database transport.

## Overview

CloudKitSync is the Layer 6 "walled consumer" of the FernletKit package graph — everything in the
app that talks to iCloud lives here. Its dependency list (`FernletPersistence`, `LocalPersistence`,
`FernletFoundation`, `FernletDomainModel`) deliberately **omits every `Private*` store**: the synced
blob must never be able to name a sealed type, so this module sits *outside* the S3 privacy wall by
construction. That omission is a hard build error, not a convention — the build runs with
`DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR` (see `Scripts/spm-wall-check.sh`), so a forbidden
`import PrivateHealthStore` fails to compile. Where sync must *touch* sealed data it does so only
opaquely: sealed Core Data entity names appear as string literals (for deletion sweeps), and sealed
backups travel as ciphertext-only ``SealedBackupRecord`` envelopes whose crypto lives app-side, and
the user's own photos as ciphertext-only ``SealedPhotoRecord`` envelopes (one per photo id, plus a
sealed per-corpus manifest) — this module moves the bytes and never holds a key that opens them.

The stack has three tiers. At the bottom, ``PersistenceController`` owns the
`NSPersistentCloudKitContainer`, built from a **programmatic, cloud-safe-only model** (aggregate
blob, saved recipes, custom items, coin and milestone ledgers, day rows — never a sealed entity).
CloudKit mirroring is opt-in twice: the stored preference must enable it *and* an iCloud account
must be present, and the `shared` singleton forces sync off at cold launch until the app reloads
with real preferences. Persistent history is always on (remote-change notifications need it), but
only a mirroring delegate ever consumes it — so a store loaded *without* CloudKit options prunes
history older than `PersistenceController.localOnlyHistoryRetention` (7 days) on every successful
load, best-effort on a background context; a mirrored store is never pruned by the app. On top of it, ``CoreDataFernletRepository`` implements the app's
`FernletRepository` contract by splitting state between a single aggregate blob record (settings,
memories, recipes, derived tables) and the per-row `DayRecord` store — one CloudKit record per day,
which is what removed the old 370-day cap and lets different-day edits from different devices merge
per record. It also owns the one-time legacy-JSON migration, the blob→row day backfill (which
re-sanitizes every legacy day so cycle/intimate content never reaches a synced row), and a
read-only-recovery latch that refuses all saves after a failed fetch/decode so a transient error
can never be persisted over real data.

Beside the day store sit the sibling per-row repositories — ``CoinLedgerRepository``,
``MilestoneLedgerRepository``, ``CustomItemRepository``, and ``SavedRecipeRepository`` — all
sharing one discipline: **upsert-only writes** (a store only ever touches the rows it is handed, so
a stale in-memory set on one device can never clobber rows synced in from another) and one JSON
coder configuration — `RowPayloadCoders` (sorted keys + ISO-8601 whole-second dates), imported
from `FernletFoundation`, which is where it lives rather than here so the local-only blob file in
`LocalPersistence` encodes under the same configuration. The coin-ledger, milestone-ledger, and
custom-item stores are thin wrappers over one internal load/upsert engine (`AppendOnlyRowStore`,
parameterized by entity name and labels); the engine deliberately has no delete method, so each
repository's deletion policy stays visible on the repository type itself.
Because CloudKit mirrors by record identity rather than by logical id, two devices can produce
duplicate rows for one logical key; only ``DayRecordRepository`` collapses duplicates itself (most
recent `updatedAt` wins, with a deliberately tie-conservative self-heal that makes a mutual
cross-device wipe impossible) — the ledgers and items are union-merged by their aggregation
services instead. ``MilestoneLedgerRepository``'s one delete is `deleteAll()`, the
delete-everything wipe path (added 2026-08-20, when the wipe stopped keeping the milestone trail —
reversing the earlier survive-a-reset rule); its protocol still exposes no delete, so only the
app's deletion funnel, which narrows to the concrete type, can reach it.

The third tier is direct CloudKit, bypassing the Core Data mirror. ``CloudKitDataService`` handles
what `NSPersistentCloudKitContainer` cannot: counting the data already in an iCloud account (feeding
``MultiDeviceSyncWarning``'s pure three-way classification of the "your devices will drift" banner),
performing the confirmed, audited delete-everything sweep, and reading/writing chunked sealed
backups. ``HeartDropCloudTransport`` is the app's only *public*-database use — a pseudonymous
dead-drop ferry for heart drops with per-chunk fetch budgeting so one hostile writer cannot starve
other friends' tags. Finally, ``CloudKitSchemaDeploy`` is the launch-argument seam for the
DEBUG-only, developer-run CloudKit schema push.

Concurrency: the target compiles with `defaultIsolation(MainActor.self)`, so nearly everything here
is MainActor-isolated and all Core Data work runs on the view context; the deliberate exceptions
are `nonisolated` statics/value types and ``HeartDropCloudTransport`` (`@unchecked Sendable` over
two immutable, documented-thread-safe CloudKit references). Remote CloudKit pushes flow from
``PersistenceController``'s remote-change publisher through ``CoreDataFernletRepository``'s cache
invalidation up to the store layer.

## Topics

### Synced persistence core

- ``PersistenceController``
- ``PersistenceStoreLoadError``
- ``CoreDataFernletRepository``

### Per-row synced stores

- ``DayRecordRepository``
- ``CoinLedgerRepository``
- ``MilestoneLedgerRepository``
- ``CustomItemRepository``
- ``SavedRecipeRepository``
- ``LegacySavedRecipeJSONRepository``

### Cloud data detection and deletion

- ``CloudKitDataService``
- ``CloudKitAccountStatusProviding``
- ``CloudKitRecordDatabase``
- ``ExistingDataSummary``
- ``MultiDeviceSyncWarning``
- ``DeletionConfirmation``
- ``DeletionResult``
- ``CloudKitDataServiceError``

### Sealed backups

- ``SealedBackupRecord``
- ``SealedBackupPayloadType``
- ``SealedBackupError``

### Own-photo escrow route

One record per photo id (`sealed-photo.<corpus>.<photoId>`) plus a sealed manifest written last as
the commit marker. A **separate namespace** from ``SealedBackupPayloadType`` on purpose: delete-all
and the settings toggles iterate that type's `allCases`, and photos must not be routed through the
chunked path, which rewrites its whole set on every change.

Each ``SealedPhotoManifest`` entry carries a `hashVersion` beside its digest (crypto-standardization
Phase 1): `2` means the digest was *proven* to be the current domain-separated pre-image by a pass
that read the plaintext, and an absent field decodes as `1` — legacy **or** merely unproven — so
pre-marker manifests keep decoding and their entries are never silently promoted. Only the rungs
that actually read bytes stamp `2`; carried-forward entries propagate whatever version was recorded,
which is what lets the computed `minimumEntryHashVersion` stand as the per-corpus zero-legacy proof.

- ``SealedPhotoCorpus``
- ``SealedPhotoSlot``
- ``SealedPhotoManifest``
- ``SealedPhotoRecord``

### Heart drops (public database)

- ``HeartDropCloudTransport``

### Developer tooling

- ``CloudKitSchemaDeploy``
