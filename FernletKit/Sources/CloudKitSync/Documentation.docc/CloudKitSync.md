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
sealed per-corpus manifest), and the recovery code's sealed escrow keys as ciphertext-only
``RecoveryEscrowRecord``s — this module moves the bytes and never holds a key that opens them.

The stack has three tiers. At the bottom, ``PersistenceController`` owns the
`NSPersistentCloudKitContainer`, built from a **programmatic, cloud-safe-only model** (aggregate
blob, saved recipes, custom items, coin and milestone ledgers, day rows, Core memories — never a
sealed entity).
CloudKit mirroring is opt-in twice: the stored preference must enable it *and* an iCloud account
must be present, and the `shared` singleton forces sync off at cold launch until the app reloads
with real preferences. Persistent history is always on (remote-change notifications need it), but
only a mirroring delegate ever consumes it — so a store loaded *without* CloudKit options prunes
history older than `PersistenceController.localOnlyHistoryRetention` (7 days) on every successful
load, best-effort on a background context; a mirrored store is never pruned by the app. On top of it, ``CoreDataFernletRepository`` implements the app's
`FernletRepository` contract by splitting state between a single aggregate blob record (settings,
recipes, derived tables) and the per-row `DayRecord` store — one CloudKit record per day,
which is what removed the old 370-day cap and lets different-day edits from different devices merge
per record. One diary structure is deliberately in NEITHER: the Tier-2 behavioral memories (owner
decision 2026-09-23, "Tier 2 sensitive notes shouldn't be backed up to iCloud at all") live in
LocalPersistence's device-local, backup-excluded `TierTwoMemoryStore` sidecar, which the repository
shares with its legacy repository, refreshes after each successful save and purges with the rest
(since 2026-10-18 the app may install `tierTwoRefresher`, which takes over that refresh and puts
this device's HealthKit residue back into the window first; the repository hands the stripped window
out and never receives a HealthKit value) —
nothing in this module serializes them, so the mirror has nothing to export. The repository also
owns the one-time legacy-JSON migration, the blob→row day backfill (which
re-sanitizes every legacy day so neither sealed journal text nor any HealthKit-derived value — the
health context, HealthKit's sleep hours, Apple Health workout imports — reaches a synced row;
since 2026-09-23 HealthKit information is not stored in iCloud at all), and a
read-only-recovery latch that refuses all saves after a failed fetch/decode so a transient error
can never be persisted over real data. Its day history has a twin that says what it could not
read: `loadAllDays()` serves what it could read (a failed `DayRecord` fetch reads as no days, an
undecodable row as a missing day), while `loadAllDaysWithUnreadable()` names the day of every row
``DayRecordRepository/loadAllWithUnreadable()`` could not decode and does not account for every row
under read-only recovery, after a failed fetch or with a row that has no date key — and never serves
a memo installed from such a read — so the journal Sealed backup's snapshot never mistakes a broken
day store for entries that are gone, and keeps every entry on a day it could not read instead of
stopping over a row nothing heals. It exposes its `persistenceController` so the app's
one-time scrub of HealthKit values out of rows written by older builds (and the HealthKit opt-out
cleaner) operate on the SAME store it reads, never on `PersistenceController.shared` by
assumption.

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
``CustomItemRepository`` and ``SavedRecipeRepository`` SOFT-delete (G9-1): `delete(ids:)` writes a
separate, content-free tombstone row (`idString = "tombstone:" + uuid`, payload `id` + `deletedAt` +
`format`) and hard-deletes the live row in one save, through the internal `RowTombstones` helper.
The tombstone is its own CloudKit record, so another phone's stale edit of the live item (which
upserts the plain-uuid row) cannot overwrite it; reads hide every tombstoned id and heal a live row
that came back, and upserts skip tombstoned ids. Tombstones are kept for good (no pruning) and
`deleteAll()` removes them with everything else. A tombstone from a later build (higher `format`)
is still honoured as a delete and never rewritten. Pre-G9 builds drop tombstone rows on read (their
payload does not decode as an item; for recipes the `idString` is not a UUID and `name` is nil).
``MemoryRecordRepository`` (G9-3, owner call M1 = A) gives Core memories (`MemoryNote`) the same
soft delete, one `MemoryRecord` row per memory (`idString`, `payloadData`, `updatedAt`; the engine
is told to sort and stamp by `updatedAt`). ``CoreDataFernletRepository`` writes the blob's `memories`
EMPTY: a save upserts only the memories whose bytes changed and soft-deletes only the ids it KNOWS
(served on a load or written this process) that the snapshot no longer holds, so a stale snapshot
never deletes a memory another phone added after this phone's last load. Whenever a loaded blob still
holds memories (the first launch after the update, or an older build writing its list back), they are
copied into rows with `adoptMissing` (never over an existing row, never over a tombstone) and the blob
is emptied only after the rows saved. `LocalFernletRepository` keeps memories in its file. The
`MemoryRecord` entity needs the owner's CloudKit production schema deploy before a shipping build
syncs it. The Tier-2 refresh reads the synced settings' "Let Fernlet remember" switch and learn-from
date (`TierTwoLearning`, passed to ``CoreDataFernletRepository/tierTwoRefresher``), and
`purgeTierTwoMemories()` deletes the device-local sidecar alone ("Forget patterns").
Because CloudKit mirrors by record identity rather than by logical id, two devices can produce
duplicate rows for one logical key. Days avoid the problem by construction since G9-1
(Docs/G9-Data-Integrity-Recovery-Plan-2026-11-15.md, Part 1): each device writes ONLY its own
``DayRecordRepository`` row per day (the row's `deviceKey`, a random per-install id), so two devices
never write the same CloudKit record and CloudKit's whole-record last-writer-wins cannot drop what
the other device logged. Every element of a day (each meal, workout, planned workout, journal stub,
planned meal and recipe, hygiene tick, care task, sleep, water) carries a stamp inside the row
payload — when, by which device, and whether that write removed it — and a read takes, per element,
the newest stamp across the day's rows, so a later deletion beats an earlier entry and a later edit
beats an earlier value, identically on every device. Deletions are tombstones kept for good (owner
call S4 = C; an id and a time, no content), an emptied day keeps a row of tombstones, a copy that
never saw an entry cannot delete it, and reads never write or delete. Pre-G9 rows, and rows in a
newer row format, are read as legacy rows (every element live at the row's `updatedAt`) and never
rewritten. The ledgers and items are union-merged by their aggregation services
instead. ``MilestoneLedgerRepository``'s one delete is `deleteAll()`, the
delete-everything wipe path (added 2026-08-20, when the wipe stopped keeping the milestone trail —
reversing the earlier survive-a-reset rule); its protocol still exposes no delete, so only the
app's deletion funnel, which narrows to the concrete type, can reach it.

The two ledger repositories also carry each ledger's **pending reset boundary** (2026-09-24,
tracker §3.6): the wipe's marker, held from before the rows are deleted until its append to the
synced store lands, so a process death cannot lose the boundary. It lives in
``PersistenceController/localDefaults`` — a ``StoreLocalDefaults`` that is `UserDefaults.standard`
for the default on-disk store and a per-controller ``InMemoryStoreLocalDefaults`` for every
in-memory or explicit-URL one — so it is device-local, never mirrored, and scoped exactly like the
store it protects: a test or preview store can neither write production defaults nor read another
store's boundary. Each repository spells its own key as a literal at its call sites
(`fernlet.coinLedger.pendingResetBoundaries`, `fernlet.milestoneLedger.pendingResetBoundaries`),
which is what lets the persisted-surface wipe wall see them; the encoding is shared.

The third tier is direct CloudKit, bypassing the Core Data mirror. ``CloudKitDataService`` handles
what `NSPersistentCloudKitContainer` cannot: counting the data already in an iCloud account (feeding
``MultiDeviceSyncWarning``'s pure four-way classification of the "your devices will drift" banner)
and asking which sealed backups it holds — ``SealedBackupPresence``, each payload's head and each
photo corpus's manifest fetched by name with nothing downloaded or opened
(``CloudKitDataService/sealedBackupPresence()``), which detection carries beside its counts so a new
iPhone, whose backup switches all start off, can offer the restore, and which "delete everything"
asks so it deletes what is there whatever the switches say (bug confirmation 2026-10-15 §2),
performing the confirmed, audited delete-everything sweep, and reading/writing chunked sealed
backups. A sealed backup's head keeps the bare name `sealed-backup.<payload>`; a v1 set's suffix
chunks are `…chunk.<i>`, and a Sealed backup v2 set's are scoped to their set,
`…chunk.<i>.<set>` (journal and intimacy Sealed backup v2 design 2026-09-30, §5.2), so a set is
written under names only it ever writes and the head is the one commit point: an interrupted export
never damages the set the head still points at. ``CloudKitDataService/saveSealedBackup(_:setTag:)``,
``CloudKitDataService/sealedBackupSuffixChunks(payloadType:chunkCount:setTag:)`` and
``CloudKitDataService/pruneSealedBackupSets(payloadType:keepingSetTag:belowGeneration:)`` (which keeps
any other set at or above the bound — the engine passes one above the head its compare-and-swap
read, so a concurrent export numbered above that head keeps its chunks while its head is still
landing on another iPhone — and never deletes the set the head in iCloud names right now) and
``CloudKitDataService/sealedBackupSuffixIsPresent(payloadType:chunkCount:setTag:)`` (the commit's
verify that every suffix chunk of its set is still there, fetched by record ID through
``CloudKitRecordDatabase/existingRecordIDs(_:)`` — no field or asset downloaded, and never a query, so a
chunk saved a moment ago is not missed by a lagging index) are that layout's mechanism, and the
record-name matcher behind a disable and delete-everything knows both suffix forms, so a v2 set is
deleted completely. The module still never opens a record. ``HeartDropCloudTransport`` is the app's only *public*-database use — a pseudonymous
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
- ``StoreLocalDefaults``
- ``InMemoryStoreLocalDefaults``

### Per-row synced stores

- ``DayRecordRepository``
- ``CoinLedgerRepository``
- ``MilestoneLedgerRepository``
- ``CustomItemRepository``
- ``SavedRecipeRepository``
- ``LegacySavedRecipeJSONRepository``
- ``MemoryRecordRepository``

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

### Recovery code escrow (G9-2)

One record per (recovery key, escrow key), named
`recovery-escrow.<sha256hex(recoveryPublicKey)>.<hex(escrowPublicKeyHash)>`: an escrow private key
sealed with HPKE to the recovery code's public key, plus that public key and the date the code was
made. Opaque here like the sealed backups: the code, the HPKE and every key live in FernletCrypto and
the app, which this module never imports. "Make a new code" deletes the old code's records by name
prefix (``CloudKitDataService/deleteRecoveryEscrowRecords(keeping:)``), and both delete-everything
sweeps include the type.

- ``RecoveryEscrowRecord``

### Heart drops (public database)

- ``HeartDropCloudTransport``

### Developer tooling

- ``CloudKitSchemaDeploy``
