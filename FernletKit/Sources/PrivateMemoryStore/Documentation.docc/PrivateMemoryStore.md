# ``PrivateMemoryStore``

The sealed journal and Worry Box store: column-encrypted, local-only persistence for the user's free-text memories on the protected side of the S3 privacy wall.

## Overview

PrivateMemoryStore is the layer-3 "sealed memory" module of FernletKit. It holds the two
repositories that keep the user's written thoughts encrypted at rest in the local-only private
Core Data store: ``JournalNarrativeRepository`` for daily journal entries and
``WorryNarrativeRepository`` for Worry Box notes. Both persist into the sealed
`PrivatePersistenceController` stack owned by `PrivateStoreCore` — a store that is never attached
to iCloud — and both seal their sensitive columns with `FernletCrypto`'s `ColumnCrypto`
(ChaCha20-Poly1305 under an HKDF-derived per-column subkey; labels `"journal-narrative"` and
`"worry-box"` keep the two ciphertext families isolated even under the same content key).

The module's position in the package graph is its security contract. Its dependencies are
`PrivateStoreCore`, `FernletCrypto`, `FernletFoundation`, and `FernletDomainModel` — nothing
above it. It is one of the sealed `Private*` targets that the walled consumers (`AIProviders`
and `CloudKitSync`) must never import: the `Package.swift` dependency DAG omits any edge from
those targets to this one, `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR` turns a forbidden
`import PrivateMemoryStore` into a hard build error (see `Scripts/spm-wall-check.sh`), and
`Tests/FernletTests/S3BoundaryTests` is the complementary grep-wall. Deliberately NOT here: the memory
"gatekeeper" `MemoryAgent` and the `AIAuditLog` sink live in the `AIContext` module, because they
are AI-facing control plane — placing them in this sealed module would have forced an
`AIProviders` → `Private*` wall violation.

Key handling is uniform and fail-closed. Neither repository ever stores key material: callers
pass the content key per call, and it originates from `FernletLockService` (the `FernletLock`
module), which exposes it only while the private area is unlocked. With a `nil` key, writes throw
`FernletLockError.locked` and reads return empty — but deletion never needs a key (rows are
dropped without being decrypted), so releasing a worry or running the full "delete all data"
reset works even while the app is locked. Reads skip individual rows that fail to decrypt rather
than blanking the whole result, and every mutation prunes the store's persistent-history log via
`PrivatePersistentHistoryPruner` so superseded ciphertext does not linger in the transaction log
(best-effort after upserts and re-seals; rethrown after deletes, which run through
`PrivateStoreCore`'s shared `PrivateRowPlumbing.deleteRows` sequence).

The two repositories differ in lifecycle, on purpose. Journal narratives are the sealed half of a
strip/hydrate cycle driven by the app's `JournalSealingCoordinator` (through the
``JournalNarrativeStoring`` seam): journal text is stripped out of the synced snapshot blob,
sealed here, and hydrated back for display. Since the 2026-08-10 backup-coverage work
``JournalNarrativeRepository`` is also a `SealedBackup` payload source (`journalNarratives`): it
owns a one-way "ever stored" divergence latch (device-local, non-synced `UserDefaults`, injected
so tests get isolation) plus a keyless row count, a paged reader in a *total* order (`entryDate`
then the unique `id`, so successive export chunks never overlap or skip), and an all-or-nothing
`insertAtomically` used by restore. Every mutation — deletes included — sets the latch, so a
restore can never resurrect entries the user deliberately deleted. Because the day blob holds only
the entry SKELETON, journal restore is paired with a host hook that rebuilds those skeletons;
without it a sync-off device reset would restore rows nothing renders. Worry Box notes never touch
the synced blob at all — they are write-once, device-only, excluded from `SealedBackup`, and support a bulk
device-key → user-key migration (``WorryStoring/reencryptAll(from:to:)``) because
`WorryBoxService` lets the user write worries before any app lock exists.

Concurrency: this target sets no `defaultIsolation(MainActor.self)` — both repositories are plain
nonisolated `final class`es whose every operation runs synchronously inside
`NSManagedObjectContext.performAndWait` on the sealed store's view context, so they can be called
from the nonisolated contexts that own them without cross-actor hops. The value types
(``JournalNarrative``, ``WorryNarrative``) are plain `Equatable` structs; ``JournalNarrative`` is
additionally `Codable` so the sealed-backup export can serialize decrypted rows into its
re-encrypted chunks.

## Topics

### Journal narratives

- ``JournalNarrative``
- ``JournalNarrativeStoring``
- ``JournalNarrativeRepository``

### Worry Box

- ``WorryNarrative``
- ``WorryStoring``
- ``WorryNarrativeRepository``
