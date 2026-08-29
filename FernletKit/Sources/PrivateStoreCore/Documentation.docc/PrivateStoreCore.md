# ``PrivateStoreCore``

The shared sealed-storage substrate on the protected side of Fernlet's S3 privacy wall: the local-only encrypted Core Data stack and the locked-state pending-narrative buffer.

## Overview

PrivateStoreCore is the layer-2.5 target in FernletKit's dependency DAG (dependencies: `FernletFoundation` and `FernletDomainModel`, nothing else). It exists so that the two sealed layer-3 stores — `PrivateHealthStore` (cycle/intimacy) and `PrivateMemoryStore` (journal/Worry Box) — plus the `FernletLock` service can share one storage substrate without that substrate living in a module the walled consumers can see. The S3 wall is a property of this position in the graph: the `AIProviders` and `CloudKitSync` targets have no dependency edge to this module, so `import PrivateStoreCore` (or naming any type here) from either of them is a hard build error under `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR` (see `Scripts/spm-wall-check.sh`). Moving anything in this module into a target those consumers import would silently widen the wall — do not.

The module has two halves. ``PrivatePersistenceController`` is the sealed Core Data stack: a dedicated `FernletPrivate` store whose `cloudKitContainerOptions` is intentionally never set (it can never mirror to iCloud), protected with `FileProtection.complete`, and honoring the user's `localBackupExcludedFromiOSBackup` preference via the shared `BackupExclusion` helper. Its model is built programmatically — four plain-`NSManagedObject` entities (`MenstrualNarrative`, `JournalNarrative`, `IntimacyLog`, `WorryNarrative`) whose free-form content lives only in `*Ciphertext` binary columns (external-storage-allowed), while ids, day keys, and timestamps stay plaintext by accepted risk (NEW-4: the store is local-only, so exposure is limited to local forensics of "which days have entries"). Every attribute is minted through `FernletFoundation`'s package-scope `CoreDataModelBuilding` factory — the one copy the synced `CloudKitSync` controller builds its programmatic model with too. Note this module stores ciphertext but does not produce it: the ChaChaPoly column sealing happens in the layer-3 repositories under the `FernletLock` content key, which this module never touches.

Because persistent-history tracking is enabled on the store, every save also copies the changed rows — including prior ciphertext — into Core Data's history shadow tables. ``PrivatePersistentHistoryPruner`` is the companion namespace the sealed repositories call after each write (`saveAndPrune(_:)`, or `prune(context:before:)` inside their own do/catch) so a re-sealed or deleted narrative does not linger as a recoverable transaction. Pruning clears the shadow tables only; it does not checkpoint the WAL or vacuum the freelist, so residue there remains possible — but that residue is always ciphertext under a ThisDeviceOnly key on a local-only store. ``PrivateRowPlumbing`` sits beside the pruner as the one shared copy of the keyless bulk-delete sequence (fetch → delete → save → rethrowing prune) the four repositories' `deleteAll()` methods route through.

### Deletion: what each layer honestly promises

Bulk deletion of sealed data is a **two-step contract**, and the two steps promise different things. Being precise about which is which is the point — the confirm dialog's language is derived from it.

1. **Row-delete** — ``PrivatePersistenceController/purgeEncryptedEntities()`` (all four entities under one save) or the repositories' `deleteAll()` via ``PrivateRowPlumbing``, each followed by a history prune. This removes the rows and the transaction log. It does **not** checkpoint the WAL or vacuum the freelist, so the prior ciphertext can linger in `-wal` frames and freed pages until SQLite reuses them. That residue is class-key-protected (`FileProtection.complete`, so its class key is evicted while the device is locked) and key-bound (ChaChaPoly under the lock's content key, on a store that never syncs) — but "row-deleted" is not "erased", and documentation must not say it is.
2. **Store rebuild** — ``PrivatePersistenceController/rebuildStore()``. The store is torn off the coordinator, `destroyPersistentStore(at:ofType:options:)` removes the sqlite plus `-wal`/`-shm`, the `.FernletPrivate_SUPPORT` external-blob directory is deleted, and an empty store is re-added under the same description (`FileProtection.complete`, history tracking, backup-exclusion preference re-applied). This removes the *logical* residue. It cannot promise the underlying flash blocks are gone: APFS copy-on-write and wear-levelling may keep them until overwritten — no user-space code can guarantee physical erasure, which is exactly why the honest claim stops at "logical".

Both steps are **keyless by absolute invariant**: no `contentKey()`, no decrypt, no re-wrap anywhere in either path. Every deletion path in Fernlet must remain reachable while the app is locked and while a sensitive surface is hidden, so deleting data must never require the ability to read it. (This is why the rejected design — re-minting the content key after the purge — is not the baseline: re-wrapping needs the passcode-derived key, which a locked wipe does not have.) Order is fixed as row-delete → rebuild, so a failed rebuild still leaves the rows gone.

Only **destroying the content key** is an *instant* honest erase of the logical content, regardless of physical residue. That gives two tiers of promise:

| Path | Key | Honest claim |
| --- | --- | --- |
| `FernletLockService.reset()` (Settings → Reset app lock) | Destroyed, every key that seals a byte here — `KeychainItem.deleteAll(service:)` over the lock service, `SecureEnclaveContentKeyWrap.deleteKey` for the SE wrap outside it, and the same sweep over `sealedContentKeyServices` (`com.fernlet.journal`) for the journal/Worry Box device fallback keys that seal rows while the lock is closed | **Fully honest**: crypto-erased *and* the file rebuilt |
| `FernletStore.deleteAllData` ("Delete everything") | Kept by design — the app-lock keychain is a documented survivor, because losing your data must not silently un-lock the app | **Bounded-honest**: no live ciphertext, and any residue is class-key-protected and key-bound. Not "crypto-erased" — do not write that |

`reset()` is therefore the seam the **Phase-7 duress WIPE** reuses verbatim: destroy the keys (`KeychainItem.deleteAll` over the lock service AND over `sealedContentKeyServices`, plus `SecureEnclaveContentKeyWrap.deleteKey`), purge the rows, then ``PrivatePersistenceController/rebuildStore()``. Nothing new is needed at this layer for it, and the rebuild's keyless invariant is what makes it usable from a duress unlock where no real content key is ever produced.

The rebuild's other invariant is that it never leaves the process **storeless**, because that state is worse than the residue it exists to remove: every sealed write fails, and a journal seal that fails deliberately keeps its PLAINTEXT in the synced days blob. Three independent failure points are handled accordingly — a failed detach skips the destroy/re-add and leaves the old store attached, a failed destroy still re-adds, and a failed re-add retries once, sets ``PrivatePersistenceController/didFailToLoad``, logs, and is healed by ``PrivatePersistenceController/reloadStoreIfNeeded()`` on the next foreground. Any save that lands in that window throws ``PrivatePersistenceController/RebuildError/storeUnavailable`` through `saveSealed()` instead of tripping Core Data's uncatchable "no persistent stores" exception.

One documented asymmetry: `deleteAllData` deletes the journal and Worry Box device keys but keeps the locked-note buffer key (`com.fernlet.narrative-buffer`), whose buffer FILE it purges. Under this baseline the surviving key is what would keep any buffer-file residue openable; deleting it would be the symmetric fix. It is a flagged owner call, tracked in `Docs/PrivacyWipeCoverage.md`, not something to change here in passing.

The second half handles the locked-state write path. When the user logs a cycle event with narrative content while the Fernlet app lock is engaged, there is no unlocked content key to seal it under. `PeriodTrackerStore` packages the narrative as a ``PendingNarrativePayload`` and hands it (through the `PeriodLockContext` seam) to `FernletLockService`, which appends it to its ``PendingNarrativeBuffer``. The buffer JSON-encodes all entries and seals them with ChaChaPoly into a single backup-excluded file, using a dedicated 256-bit keychain key (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, this-device-only) that is deliberately separate from the lock's content key so logging works without the user's passcode. The buffer's whole identity — file directory and key service — is the ``PendingNarrativeStorageScope`` given at init, one value so the two halves can never be isolated independently; `.production` resolves to the shipped `Application Support/Fernlet` + `com.fernlet.narrative-buffer`, and tests build throwaway scopes so a parallel suite's reset cannot purge another's buffered notes. On the next successful unlock, `PeriodTrackerStore.drainPendingBuffer(contentKey:)` pulls the payloads back out through the lock service and re-seals each as a real `MenstrualNarrative` row; the buffer's durability invariant is that draining never deletes — the caller purges only after the payloads are durably persisted.

Phase 3 of the crypto-standardization plan **deleted this surface's legacy reader**, and the Phase 2.4 format migrator that healed for it went in the same stroke: its whole job was converting the pre-`91c3956` bare-box file into `FNB2`+AAD *through* the branch that is now gone, so a migrator left standing could no longer heal anything. `FNB2` is therefore required on read as well as write, and a non-empty file without it is refused by name as ``PendingNarrativeBufferError/legacyUnprefixedFormat`` — audit-logged, never opened under no domain, and never deleted (bytes that will not open may really be "sealed under a key this device lost"). ``PendingNarrativeBufferFormatCensus`` **stays**: it classifies by marker bytes and holds no key, so it is a counter, not a reader, and it is still the whole of the Phase-3 gate reading for this surface — an absent file is an *earned* zero, because the surface is transient and only `saveEntries` — which always writes v2 — can re-create it.

Phase 2.6 added the **last** Class-A migrator, and the largest: ``SealedColumnFormatMigrator``, which converts the four sealed entities' seven ciphertext columns from legacy (unprefixed, no AAD) and v2 (binding-only AAD) to v3 (purpose + binding AAD) in bounded keyed passes. Like its siblings the scan **is** the census — ``SealedColumnFormatCensus``'s own classification, paging, `autoreleasepool`, refault and row-budget discipline, so the counter and the converter cannot disagree — and the open is the shipping reader's own dispatch, so its tallies are proven *by open* rather than inferred from a marker byte. It runs behind the **private-hub unlock**, and the content key arrives by **injection**: this module cannot import `FernletLock` (the existing edge runs the other way), so the migrator takes a key-vending closure re-called per page, which the app target wires to the lock service's `.privateHub` decrypt seam. That closure answering nil is how a re-lock stops the sweep fail-closed at the next page boundary — no second lock-state protocol, no key custody of its own, and **zero new dependency edges**.

Concurrency: the target compiles nonisolated (no `defaultIsolation(MainActor.self)`), because the nonisolated layer-3 repositories call the controller and pruner directly. ``PrivatePersistenceController/shared`` is `nonisolated(unsafe)` (the container is not `Sendable`), matching its prior app-target behavior, and ``PendingNarrativeBuffer`` is a plain non-`Sendable` class with no internal locking whose correctness relies on the single lock-service-owned instance being driven from the main actor.

## Topics

### Sealed Core Data stack

- ``PrivatePersistenceController``
- ``PrivatePersistentHistoryPruner``
- ``PrivateRowPlumbing``

### Locked-state narrative buffering

- ``PendingNarrativeBuffer``
- ``PendingNarrativePayload``
- ``PendingNarrativeStorageScope``

### At-rest format census (Phase 0)

- ``SealedColumnFormatCensus``
- ``SealedColumnIdentifier``
- ``SealedEntityColumns``
- ``SealedColumnFormatTally``
- ``SealedColumnReadOutcome``
- ``SealedColumnFormatCensusResult``
- ``PendingNarrativeBufferFormatCensus``

### Buffer errors

- ``PendingNarrativeBufferError``

### Sealed-column format migration (Phase 2.6)

- ``SealedColumnFormatMigrator``
- ``SealedColumnMigrationResult``
- ``SealedColumnMigrationTally``
- ``SealedColumnNotAttemptedReason``
- ``SealedColumnMigrationProgressEvent``
- ``SealedColumnMigrationLatch``
