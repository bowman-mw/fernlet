# ``PrivateStoreCore``

The shared sealed-storage substrate on the protected side of Fernlet's S3 privacy wall: the local-only encrypted Core Data stack and the locked-state pending-narrative buffer.

## Overview

PrivateStoreCore is the layer-2.5 target in FernletKit's dependency DAG (dependencies: `FernletFoundation` and `FernletDomainModel`, nothing else). It exists so that the two sealed layer-3 stores — `PrivateHealthStore` (cycle/intimacy) and `PrivateMemoryStore` (journal/Worry Box) — plus the `FernletLock` service can share one storage substrate without that substrate living in a module the walled consumers can see. The S3 wall is a property of this position in the graph: the `AIProviders` and `CloudKitSync` targets have no dependency edge to this module, so `import PrivateStoreCore` (or naming any type here) from either of them is a hard build error under `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR` (see `Scripts/spm-wall-check.sh`). Moving anything in this module into a target those consumers import would silently widen the wall — do not.

The module has two halves. ``PrivatePersistenceController`` is the sealed Core Data stack: a dedicated `FernletPrivate` store whose `cloudKitContainerOptions` is intentionally never set (it can never mirror to iCloud), protected with `FileProtection.complete`, and honoring the user's `localBackupExcludedFromiOSBackup` preference via the shared `BackupExclusion` helper. Its model is built programmatically — four plain-`NSManagedObject` entities (`MenstrualNarrative`, `JournalNarrative`, `IntimacyLog`, `WorryNarrative`) whose free-form content lives only in `*Ciphertext` binary columns (external-storage-allowed), while ids, day keys, and timestamps stay plaintext by accepted risk (NEW-4: the store is local-only, so exposure is limited to local forensics of "which days have entries"). Note this module stores ciphertext but does not produce it: the ChaChaPoly column sealing happens in the layer-3 repositories under the `FernletLock` content key, which this module never touches.

Because persistent-history tracking is enabled on the store, every save also copies the changed rows — including prior ciphertext — into Core Data's history shadow tables. ``PrivatePersistentHistoryPruner`` is the companion namespace the sealed repositories call after each write (`saveAndPrune(_:)`, or `prune(context:before:)` inside their own do/catch) so a re-sealed or deleted narrative does not linger as a recoverable transaction. Pruning clears the shadow tables only; it does not checkpoint the WAL or vacuum the freelist, so residue there remains possible — but that residue is always ciphertext under a ThisDeviceOnly key on a local-only store.

The second half handles the locked-state write path. When the user logs a cycle event with narrative content while the Fernlet app lock is engaged, there is no unlocked content key to seal it under. `PeriodTrackerStore` packages the narrative as a ``PendingNarrativePayload`` and hands it (through the `PeriodLockContext` seam) to `FernletLockService`, which appends it to its ``PendingNarrativeBuffer``. The buffer JSON-encodes all entries and seals them with ChaChaPoly into a single backup-excluded file under Application Support, using a dedicated 256-bit keychain key (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, this-device-only) that is deliberately separate from the lock's content key so logging works without the user's passcode. On the next successful unlock, `PeriodTrackerStore.drainPendingBuffer(contentKey:)` pulls the payloads back out through the lock service and re-seals each as a real `MenstrualNarrative` row; the buffer's durability invariant is that draining never deletes — the caller purges only after the payloads are durably persisted.

Concurrency: the target compiles nonisolated (no `defaultIsolation(MainActor.self)`), because the nonisolated layer-3 repositories call the controller and pruner directly. ``PrivatePersistenceController/shared`` is `nonisolated(unsafe)` (the container is not `Sendable`), matching its prior app-target behavior, and ``PendingNarrativeBuffer`` is a plain non-`Sendable` class with no internal locking whose correctness relies on the single lock-service-owned instance being driven from the main actor.

## Topics

### Sealed Core Data stack

- ``PrivatePersistenceController``
- ``PrivatePersistentHistoryPruner``

### Locked-state narrative buffering

- ``PendingNarrativeBuffer``
- ``PendingNarrativePayload``
