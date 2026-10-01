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
sealed here, and hydrated back for display. ``JournalNarrativeRepository`` is also the Sealed
backup's journal payload source (`journalNarratives`), on the app's v2 engine since unit B3 of the
journal and intimacy Sealed backup v2 design (2026-09-30, §7): a keyless ``JournalNarrativeRepository/allIDs()``
snapshot in a *total* order (`entryDate` then the unique `id`) — with the keyless
``JournalNarrativeRepository/ids(onDays:)`` for the days whose stored day row will not decode, every
entry on which the snapshot keeps — a classified chunk read
(``JournalNarrativeRepository/backupRecords(ids:hubKey:deviceKey:)`` → ``JournalBackupPage``) that
opens each entry under the hub key OR the journal device key (``JournalBackupDeviceKey``, read by the
app without minting) — so an entry written from Home and not folded yet is backed up as it is — and
sorts the rest into dead, needs-a-newer-build (an unknown feeling tag is never dead) and undecided;
and the id-keyed MERGE restore (``JournalNarrativeRepository/upsertMerged(_:hubKey:deviceKey:)`` →
``JournalNarrativeMergeResult``): absent entries inserted with their own stamps — unless an entry
on their day already IS them (the same words and the same creation stamp: the other iPhone's fork of
this iPhone's own entry coming back, since a fork keeps the stamps of the entry it copies), so
"Restore it here" on both iPhones settles at both versions, neither doubled — an entry that opens
never modified, a backup entry whose words differ added beside the local one as its own entry
unless an equal one is already on its day, dead rows replaced, never a delete, one atomic save,
idempotent. It replaced the empty-store-only `insertAtomically`, so entries that survived under the
device key no longer block a restore. The one-way "ever stored" divergence latch (device-local,
non-synced `UserDefaults`, injected so tests get isolation) no longer gates a restore: it seeds the
app's journal restore MARKER once, which is what now stops a stale cloud copy from resurrecting
entries the user deleted. Because the day blob holds only the entry SKELETON, the restore is paired
with a host hook that rebuilds those skeletons from the keyless ``JournalNarrativeRepository/skeletons(ids:)``
(``JournalNarrativeSkeleton``: id, day, tag, date — never the words); without it a sync-off device
reset would restore rows nothing renders. Worry Box notes never touch
the synced blob at all — they are write-once, device-only, excluded from `SealedBackup`, and support a bulk
device-key → user-key migration (``WorryStoring/reencryptAll(from:to:)``) because
`WorryBoxService` lets the user write worries before any app lock exists.

Concurrency: this target sets no `defaultIsolation(MainActor.self)` — both repositories are plain
nonisolated `final class`es whose every operation runs synchronously inside
`NSManagedObjectContext.performAndWait` on the sealed store's view context, so they can be called
from the nonisolated contexts that own them without cross-actor hops. Because that closure is
`@Sendable`, both are `Sendable` too: all-`let` state over the SDK-`Sendable` context and the
stateless `ColumnCrypto` value (``WorryNarrativeRepository`` fully compiler-checked;
``JournalNarrativeRepository`` `@unchecked` solely for its un-annotated but thread-safe
`UserDefaults` latch — the invariant is spelled out on the type). The value types
(``JournalNarrative``, ``WorryNarrative``) are plain `Equatable`, `Sendable` structs;
``JournalNarrative`` is additionally `Codable` so the sealed-backup export can serialize
decrypted rows into its re-encrypted chunks.

**Both tables are folded whole, and both can be classified without a key (period-data design
2026-09-30, §4.9, §9.17).** While the Private tab is closed — with or without a passcode — journal
and Worry Box entries seal under their device keys; when it opens, the app folds EVERY such row under
the tab's content key through `reencryptAll(from:to:)` (bounded pages, rows that do not open under
the old key skipped, never deleted). The journal's fold used to cover only today and the in-memory
recent days, so an older entry written from Home stayed out of the hub; it is now on
``JournalNarrativeStoring`` like the worry one. For the app's "entries this iPhone can't open" check
both repositories answer `openability(under:)` — ids only, sorted into openable, dead and undecided
(``SealedRowOpenability``; an install-binding read that did not answer decides nothing) — and delete
exactly a named id list keylessly (`delete(ids:)`). The journal's divergence latch is one-way for
every writer and for "delete everything", and is cleared only by `clearDivergenceLatch()`, once the
key the rows spoke for is provably gone.

## Topics

### Journal narratives

- ``JournalNarrative``
- ``JournalNarrativeStoring``
- ``JournalNarrativeRepository``
- ``SealedRowOpenability``

### Journal Sealed backup

- ``JournalBackupDeviceKey``
- ``JournalBackupPage``
- ``JournalNarrativeMergeResult``
- ``JournalNarrativeSkeleton``
- ``JournalNarrativeRepositoryError``

### Worry Box

- ``WorryNarrative``
- ``WorryStoring``
- ``WorryNarrativeRepository``
