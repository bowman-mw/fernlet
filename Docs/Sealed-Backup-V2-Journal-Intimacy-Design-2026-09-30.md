# Journal and intimacy Sealed backup v2: design (2026-09-30, revision 2)

Status: DESIGN, read-only survey. Nothing here is built. It builds on the reviewed period design
(`r0930/period/design.md`, revision 2): §2.5, §5.3, §9.10, §10.6, §11 (I15, I16, I28 to I30), §13 unit 5,
Q9, Q14 and §15 R2-F1, R2-F3, R2-F4, R2-F12. Revision 2 answers the adversarial review of revision 1
(§15). Every `file:line` is on `claude/r0930-period` at `08914578` unless prefixed `main:` (`a6eec84b`).
The branch tip is now `a270e3b9` (unit 4 fix round 1). Its backup files are byte-identical to
`08914578`; only `FernletStore.swift` lines after `:5850` shift by +4 (`git diff 08914578 a270e3b9`). **Unit
5 has not started**: there is no unit 5 commit, and the worktree's uncommitted edits are unit 4 tests and docs.
Paths are repo-relative. Every file read is
snapshotted in `r0930/backup/src/` (revision 1) and `r0930/backup/v/` (revision 2, at `08914578`).

## 0. The owner's words (verbatim, 2026-09-30)

> "yes, give journal and intimacy the same backup protection"

This answers the follow-up the period design names (period §1 non-goals, §12 "Journal and intimacy backups
keep today's model"). The journal and intimate-log Sealed backups get every part of the period backup v2:
- E1 to E4;
- the compare-and-swap head with writer tag and generation floor;
- the "saved from another iPhone" state with an explicit "Restore it here" or "Replace";
- the id-keyed merge restore, gated by a persisted resolved marker and the reset owner hold;
- a dirty re-export after every change.

They are built on the same code, with the owner's period answers to Q9 and Q14 as the defaults. Revision 2
also fixes defects the review found in that shared machinery. Unit 5 has not been written, so each such fix
goes into the period backup too, through the engine (§4.8, §13 B0).

## 1. Goals and non-goals

Goals
1. **One engine, three adapters.** Period, journal and intimacy exports and restores run through one
   `SealedBackupV2Engine`. The preferred route is for unit 5 to build it in this shape (B0, §13), so that
   nothing is forked or extracted afterwards. Period's record format, keys and tokens do not change. Every
   behaviour change to period is listed in §4.8 as a strict fix.
2. **The journal and intimate-log backups keep up.** Every change to either sealed table marks the payload
   dirty. The next Private visit (any section) exports it behind E1 to E4.
3. **Restore is an id-keyed merge**, never empty-store-only. It never overwrites an entry this iPhone can
   open: a journal entry changed on both sides keeps both versions (§7.3).
4. **Two iPhones never silently overwrite each other's backup** (Q9 default). A clone made from an iPhone
   device backup is "another iPhone" too (§5.5).
5. **After an app-lock reset**, journal and intimacy restore only behind the device-owner check (Q14
   default). That check is the single "Restore Sealed backup" action. Retry never releases the hold.
6. **An interrupted export never damages the previous backup.** Suffix chunks are written under names
   scoped to their set, and the head is the one commit point (§5.2).
7. Every wall holds: S3, no-tracking, Power of 10, localization, doc coverage, the persisted-surface wipe
   wall, and fail-closed hiding at the decrypt seam.
   - **No new `CryptographicPurpose`.** The writer tag reuses `Hash.sealedBackupWriterTagV1`
     (`FernletKit/Sources/FernletCrypto/CryptographicPurpose.swift:479`), so the registry pin stays at 78
     (`Tests/FernletTests/MeshRoutedItemSealTests.swift:515`).
   - **No new CloudKit field.**

Non-goals (each deliberate)
- Merging both iPhones' journals into one backup automatically, with deletions carried across. One iPhone
  owns each slot at a time (Q9). "Restore it here" followed by an export of the union is the manual union
  (§12).
- An atomic compare-and-swap in CloudKit (record change tags) and per-device slots. The head is still
  read-then-write. §5.2 makes the race lose a slot visibly instead of corrupting a set.
- Tombstones (per-id deletion records).
- Worry Box: device-only by design (`Docs/Verifiability.md` §6).
- Tier-two memories (never leave the device, owner decision 2026-09-23).
- Core Memory notes (they ride the synced day blob, `FernletStore.swift:3950-3964`).
- Any change to `SealedBackupRecord`'s fields, the AAD, the chunk size, the head record name or the payload
  raw values. **Changed on purpose:** v2 suffix chunks get set-scoped record names (§5.2). A v1 set keeps its
  names.

## 2. Today, traced

### 2.1 Shared transport and bookkeeping
- **Payload tokens and record names.** The tokens are `journalNarratives` and `intimacyLogs`
  (`FernletKit/Sources/CloudKitSync/SealedBackupRecord.swift:33-47`). Record names are account-global,
  `sealed-backup.<rawValue>[.chunk.N]` (`FernletKit/Sources/CloudKitSync/CloudKitDataService.swift:844-854`).
  - Delete and prune match names whose suffix after `.chunk.` parses as an `Int` (`:642-652`).
  - The set fetch checks only contiguity, chunk count and generation. Salt and signing key are deliberately
    not compared (`:588-609`).
- **`reconcileChunked`** rewrites suffix chunks `n-1…1` **in place**, then the head, then prunes
  (`App/Fernlet/SealedBackupService.swift:301-333`). Each chunk's plaintext is built lazily between saves
  (`:314-323`). The generation is minted and **persisted before the first write**
  (`App/Fernlet/SealedBackupGenerationStore.swift:65-69`), so an aborted upload burns a number.
- **`restoreChunks`** fetches everything, then opens it (`SealedBackupService.swift:384-404`). It rejects
  `generation < lastSeen` as `.staleGeneration` (`:409-417`), which becomes a terminal `.rolledBack`
  (`App/Fernlet/SealedBackupCoordinator.swift:1287-1295`). It then raises `lastSeen` (`:418`).
- **Record authorship.** Every record carries `signingPublicKey`, bound into the AAD
  (`SealedBackupService.swift:138-146`, `:210-218`). The signing key is minted
  `AfterFirstUnlockThisDeviceOnly` (`FernletKit/Sources/ProximityKit/Identity/IdentityService.swift:549-603`),
  so it never travels in a device backup or iCloud Keychain. Delete-all rotates it (`FernletStore.swift:6029-6043`).
- **Escrow modes** (`SealedBackupCoordinator.swift:262-305`).
  - `.forSealing` **mints** a ThisDeviceOnly escrow key when none is present (`IdentityService.swift:881-907`).
  - `.forOpening` never mints (`:913-916`).
  - `open` reports `keyAgreementIdentityMismatch` when the record is tagged with none of this iPhone's escrow
    keys, and `malformedRecord` when it is tagged with one but will not authenticate (`SealedBackupService.swift:166-169`).
  - Delete-all deletes the escrow rows, and iCloud Keychain propagates that deletion to the user's other
    devices (`Docs/PrivacyWipeCoverage.md:505-507`).
- **Content key.** The backup content key is the hub key: `sealedBackupContentKey` returns
  `hubContentKeyProvider?()` (`FernletStore.swift:3533`, `:7184`). It is live only while the Private tab is
  unlocked.
- **Owner hold** (`App/Fernlet/SealedBackupRestoreHold.swift`). The reset funnel sets it
  (`FernletStore.swift:3554-3561`).
  - It holds every ambient restore (`heldForOwner`, `SealedBackupCoordinator.swift:1159-1163`), **but not a
    user-initiated one**: `initiatedByUser` skips it (`:1160`), and Retry passes `userInitiated: true`
    (`:785`, `:816-819`, `:829-831`).
  - It also holds re-uploads of each payload whose pre-reset copy it keeps (`reuploadHeldForOwner`, `:1171-1177`).
- **Persisted per-install state.**
  - The deferral flags live in `StoragePreferences`, a keychain blob stored `AfterFirstUnlockThisDeviceOnly`
    (`FernletKit/Sources/FernletFoundation/StoragePreferences.swift:265`). Every switch defaults to off
    (`:114-128`). A new iPhone, even one set up from a device backup, starts with sync and every backup off.
  - `lastSeen` and the latches live in standard `UserDefaults`, which **travels** in device backups
    (`Docs/PrivacyWipeCoverage.md:136`, `:240`).
  - `currentPreferences()` reads the keychain and decodes on every call, collapsing failures to defaults
    (`StoragePreferences.swift:423-431`).
- **Private store load failure.** A store that fails to load leaves the controller running against an empty
  coordinator: only `didFailToLoad` is set (`FernletKit/Sources/PrivateStoreCore/PrivatePersistenceController.swift:122-127`).
  `isStoreLoaded` exists (`:275`) and `didFailToLoad` resets on heal (`:358`, `:407`, `:480`).

### 2.2 Journal export (v1)
- It runs only on enable, deferral retry, escrow adopt and the launch follow-through, never on a change
  (`SealedBackupCoordinator.swift:418-501`, `:518-563`, `:973-987`, `:854`).
- The guard probes page 1 only (`:663-672`), and an empty journal never exports.
- Chunks page the live table by offset and skip rows that do not decrypt (`JournalNarrativeRepository.swift:439-456`).
- There is no duress check.

### 2.3 Journal restore (v1)
- Targeted restore (`SealedBackupCoordinator.swift:1095-1114`): the owner hold, unless `initiatedByUser`;
  then the latch; then `performRestore`.
- After the network await, `applyRestoredChunks` **re-checks** `count == 0 && !everStored` (`:1381-1391`,
  `:1496-1505`) and **re-reads the live key** at the write (`:1414`). Those two checks are what make a restore
  that resumes after a wipe harmless today.
- The write is `insertAtomically` (`JournalNarrativeRepository.swift:281-302`). `apply` stamps
  `updatedAt = Date()` on every write (`:648`), so restored rows carry restore-time stamps.
- `reinstateJournalEntries` (`FernletStore.swift:7235-7261`) adds a day skeleton for every id the day lacks.
  A failed past-day write is only audited (`:7249-7252`).

### 2.4 Journal writers
- `JournalSealingCoordinator.seal` (`App/Fernlet/JournalSealingCoordinator.swift:148-200`) is an upsert
  (`JournalNarrativeRepository.swift:238-267`). It seals under the journal key while active, otherwise
  under the device key (`:159`).
- `updateSealedNarrative` (`:203-241`).
- `deleteSealed` (`:244-254`): a failed delete leaves an **orphan** row with no skeleton.
- `appendJournalEntry` seals first and writes the skeleton second (`FernletStore.swift:3936-3943`); a failed
  past-day write leaves an orphan too.
- Deactivation empties `sealedJournalIDs` (`JournalSealingCoordinator.swift:126-141`). An edit from Home then
  takes `updateJournal`'s "not sealed" branch (`FernletStore.swift:4018-4026`) and re-seals the row under
  the **device** key with a fresh stamp.
- With iCloud sync on, the other iPhone's skeletons arrive with empty text. Typing into one seals a new
  row under the **same id**.
- `decrypt` returns nil when `FeelingTag(rawValue:)` fails (`JournalNarrativeRepository.swift:655-660`),
  while `classify` counts that row as openable (`:615-629`).
- The fold `reencryptAll` (`:478-508`) runs at Journal activation.

### 2.5 Intimacy (v1)
- Export: `reconcileIntimacyBackup` (`SealedBackupCoordinator.swift:703-744`). Hidden throws `.surfaceHidden`.
  The probe and offset chunks go through the gated `IntimacyLogStore.backupPage`
  (`FernletKit/Sources/PrivateHealthStore/IntimacyLogStore.swift:133`).
- Visibility is `!duress && isIntimateLoggingAllowed && setting` (`FernletStore.swift:1095-1112`), with the
  16+ gate (`AgeGate.intimacy`).
- `resolvedIntimacyStore` builds a **new instance per call** (`SealedBackupCoordinator.swift:340-344`).
- Restore: targeted (`:1126-1148`, hold, visibility, latch), then the empty-store gate (`:1506-1512`), then
  the gated `IntimacyLogStore.restore` (`:143`).
- Writers: `insert` (caps the note at `maxNoteLength` 1 000, `:66-75`), `markSavedToHealthKit` (`:83`) and
  `deleteAll` (`:89`). There is no per-log edit or delete in the app (`App/Fernlet/LogIntimacySheet.swift:208-221`).
- The un-hide settle (`FernletStore.swift:1230-1244`) is held in `intimacyBackupSettleTask`.

### 2.6 Delete-all and the hub settle
- **The hub settle task is unowned.** `requestSealedBackupSettlement` starts `Task { await
  drainSealedBackupSettlements() }`, which nothing holds (`ContentView.swift:1507-1513`).
  - The drain is guarded once, before the sections run (`:1525-1526`).
  - It runs once per section per process: `attemptedSealedBackupSections` (`:117`) is never cleared.
  - It skips Worry Box (`:1508`).
- **Delete-all** (`FernletStore.deleteAllData`, `:5620`) runs in this order:
  1. raises `deleteAllInProgress` (`:5644`);
  2. `stopWritersForWipe` (`:5652`, body `:5747-5764`) cancels only the two un-hide settles and the period writers;
  3. leg 2 deletes the cloud sets of **enabled** payloads (`:5771-5800`), clears every deferral flag
     (`:5813-5815`) and resets `lastSeen` (`:5821-5822`);
  4. leg 3 deletes the sealed rows (`:5662`, journal and intimacy hooks `:5867-5868`);
  5. the identity and escrow rotation (`:5700`);
  6. the preference reset (`:5723`).
- The intimacy leg calls `deleteAll()` on ContentView's `IntimacyLogStore` (`ContentView.swift:1598`).
- The lock gate locks when its view disappears (`FernletKit/Sources/FernletLockUI/FernletLockGate.swift:204`, `:270-303`).

### 2.7 The gaps "the same protection" closes, and the defects the review found
| # | Gap or defect | Fixed by |
| --- | --- | --- |
| G1 | Snapshot refreshed only on enable, retry, adopt, un-hide | dirty re-export (§4.4) |
| G2 | Two iPhones: last writer wins, silently | E2 writer-first compare-and-swap, held state (§5.5) |
| G3 | Restore only into an EMPTY store with a clear latch | merge restore and resolved marker (§4.2, §7.3) |
| G4 | Page-1 probe, offset paging over a live table, partial export | id snapshot and prepare (§4.2 X7) |
| G5 | An empty journal or intimate log never exports | E1: after resolution, empty is real |
| G6 | Restore stamps `updatedAt = now`; last-writer-wins would then lose newer text | keep local, fork different text (§7.3) |
| G7 | Settle once per section per process; Worry Box skipped | once per hub session, any section (§4.5) |
| G8 | No duress check on the journal | engine-wide duress refusal (§4.7) |
| G9 | Delete-all cannot stop a hub-settle restore or export | serial worker, work epoch, quiesce (§4.7) |
| G10 | In-place rewrite: any interruption leaves the only backup unrestorable | set-scoped suffix names, prepare then commit (§5.2) |
| G11 | Burned generations reject the other iPhone's set as `.rolledBack` | generation persisted only on commit (§5.4) |
| G12 | Authorship inferred from `lastSeen`, which travels and counts restores | writer tag (v2) and signing key (v1) (§5.5) |
| G13 | The open path for a head could mint an escrow key | `.forOpening` for every head open; mint rule (§5.6) |

### 2.8 Unit 5's position (verified)
- The period branch has unit 5 unwritten at `a270e3b9`.
- Unit 5's brief (period §13) is period-shaped: `reconcilePeriodBackup`, `markPeriodBackupDirtyIfEnabled`,
  `periodAcceptedHead`, and a pre-pass that is separate from the chunks.
- The store seam unit 5 would drive already exists:
  - `CycleRecordStore.allIDs()` (`FernletKit/Sources/PrivateHealthStore/CycleRecordStore.swift:194`);
  - `backupChunk(ids:)`, which returns a **classified** page (`:174-178`);
  - `restoreMerging` (`:182`);
  - `backupPrePass`, which takes its own snapshot and does not yield (`:147-165`);
  - a **per-instance** `mutationCounter` (`:70-74`).
- So this design does not wait to extract the engine from finished code. It hands unit 5 an amended brief,
  B0 (§13), and falls back to a catch-up unit, B1, only for whatever B0 items unit 5 does not adopt.

## 3. Design in one paragraph

One `SealedBackupV2Engine`, owned by `FernletStore`, runs every Sealed backup pass for the three v2 payloads
on one serial worker, so passes never overlap. Each payload is reached through a small adapter over its own
gated sealed store.

A pass first checks the **gates**:
- not wiping, and the work epoch unchanged;
- not in duress, and the surface visible;
- the hub key live;
- sync and the payload backup on;
- the store loaded.

It re-checks them after every await and immediately before every decrypt and every local write.

A **restore** runs while the per-payload resolved marker is unresolved, or on an explicit "Restore it here".
It never runs under the owner hold. It opens the head under `.forOpening` (never minting), verifies the set
(writer, set id, salt, total, rollback), and merges by id. The merge never deletes and never overwrites an
entry this iPhone can open. The journal keeps both versions when the text differs. Day skeletons are added
for every written entry.

An **export** runs when the payload is dirty, a probe is due, or the user asked for one. Its steps:
- **E1:** the marker is resolved.
- **Owner hold:** the hold does not keep this payload's pre-reset copy.
- **E2:** the head is checked writer-first:
  - an own v2 writer tag, or an own v1 signing key, means own;
  - an accepted stamp means own;
  - anything else is held and named "saved from another iPhone".
- **E3:** the export snapshots ids and seals every chunk in memory. Nothing is written before every row
  has opened.
- **Commit:** suffix chunks are uploaded under names scoped to the new set, then the head, then the head is
  verified and older sets are pruned. An interruption leaves the previous set whole.

The generation is computed above everything this install has seen and is persisted only on commit.
Dirtiness comes from one host epoch that every store instance moves.

In Privacy & Data, explicit actions are in-memory intents ("Restore it here", "Replace", "Restore anyway",
"Start a new backup", "Remove them") that the next Private visit carries out. Nothing is decrypted in
Settings. Delete-all and the app-lock reset stop the worker before they touch the cloud or the stores.

## 4. One engine, three adapters

### 4.1 The adapter (`App/Fernlet/SealedBackupV2Adapter.swift`, new)
```swift
/// One payload's sealed store as the v2 Sealed backup engine sees it.
@MainActor
protocol SealedBackupV2Adapter: AnyObject {
    associatedtype Record: Codable & Sendable
    var payload: SealedBackupPayloadType { get }                 // frozen token
    /// The decrypt seam is open now: period/intimacy = the derived visibility (age gate, setting,
    /// !duress); journal = !duress. Re-read before every decrypt.
    var isSurfaceOpen: Bool { get }
    /// The sealed store is attached: `isStoreLoaded && !didFailToLoad` (R2-F2).
    var isStoreHealthy: Bool { get }
    /// Runs `body` only while the seam is open, else throws the surface's hidden error. Every decrypt
    /// of this payload's BACKUP chunks (probe, E2, restore) runs inside it, so the gate check and the
    /// decrypt are one synchronous step (R1-BR-12).
    func withOpenSeam<T>(_ body: () throws -> T) throws -> T
    /// Keyless, ungated ids of the rows that belong in a backup, in the store's total order
    /// (journal: sealed ids that some day's journals reference, §7.1).
    func snapshotIDs() throws -> [UUID]
    /// One chunk's records, classified, decrypting each id under whichever key opens it NOW (journal:
    /// hub key, then the device key read without minting). A missing row was deleted since the
    /// snapshot. Gated: throws while closed or keyless, never answers empty.
    func classifiedChunk(_ ids: [UUID], hubKey: SymmetricKey) throws -> SealedBackupChunkPage<Record>
    func recordID(_ record: Record) -> UUID
    func decodeV1Chunk(_ data: Data) throws -> [Record]          // a bare JSON array
    /// Atomic id-keyed merge (§7.3, §8.2). Gated; throws while closed.
    func restoreMerging(_ records: [Record], hubKey: SymmetricKey) throws -> SealedBackupMergeResult
    /// Follow-up writes (journal: day skeletons, then hydrate). False when any follow-up write failed:
    /// the restore then stays unresolved and is retried (R1-BR-6).
    func didRestore(_ result: SealedBackupMergeResult) -> Bool
    /// "Remove them": re-classifies `ids` under every key this iPhone holds and deletes only those
    /// still dead (R2-F12). Keyless delete; returns how many went.
    func removeStillDead(_ ids: [UUID], hubKey: SymmetricKey) throws -> Int
}

struct SealedBackupChunkPage<Record> {
    var records: [Record]
    var deadIDs: [UUID]          // opens under no key this iPhone holds
    var needsNewerBuildIDs: [UUID]   // opens, but a plaintext field this build can't read (unknown tag)
    var transientCount: Int      // DeviceBindingID.ReadError, unreadable keychain
}

struct SealedBackupMergeResult {
    var insertedIDs: [UUID]
    var replacedDeadIDs: [UUID]
    var forkedIDs: [UUID]        // journal only (§7.3)
    var changedAnything: Bool
}
```
- **Period** maps onto existing members: `snapshotIDs` = `CycleRecordStore.allIDs()`;
  `classifiedChunk` = `backupChunk(ids:contentKey:)`, already a classified page; `restoreMerging` exists.
  - `withOpenSeam` is a new gated `CycleRecordStore.withBackupSeam`.
  - `isStoreHealthy` reads the store's controller.
  - `backupPrePass` is not used by the engine (R2-F8).
- **Intimacy and journal** members are new; see §7 and §8.

### 4.2 The engine (`App/Fernlet/SealedBackupV2Engine.swift`, new)
```swift
@MainActor final class SealedBackupV2Engine {
    /// Enqueues a pass. Dropped, not queued, while the host's work is blocked (the delete-all bracket).
    /// At most one pending request per payload: a later explicit intent replaces an earlier ambient one.
    func request(_ payloads: [SealedBackupPayloadType], trigger: SealedBackupTrigger)
    /// Delete-all: cancel the worker and wait until it has stopped (§4.7).
    func quiesceForWipe() async
    /// The hub closed: the per-session sets clear (§4.5).
    func hubSessionEnded()
    /// In-memory, observable on FernletStore. Persisted parts are in SealedBackupBookkeeping (§4.3).
    private(set) var status: [SealedBackupPayloadType: SealedBackupV2Status]
}
enum SealedBackupTrigger: Equatable {
    case hubSettle, unhide, retry, ownerRelease         // ambient
    case restoreHere(SealedBackupHeadStamp, ignoringRollback: Bool)
    case replace(SealedBackupHeadStamp)
    case startNew
    case remove([UUID])
}
struct SealedBackupHeadStamp: Equatable { let writer: String; let generation: Int64 }  // "<32 hex>" | "v1"
enum SealedBackupV2Status: Equatable {
    case upToDate
    case waitingForRestore(SealedBackupRestoreOutcome?)   // E1 unresolved; last restore outcome
    case heldForOwner                                      // owner hold keeps this payload's copy
    case heldByAnotherDevice(SealedBackupHeadStamp)        // also persisted (§4.3)
    case waitingForBackupKey                               // a head exists; no escrow key here yet
    case headSealedWithOtherKey                            // head tagged with a key this iPhone lacks
    case headDamaged                                       // tagged with our key, will not authenticate
    case needsNewerFernlet                                 // head envelope or rows this build can't read
    case paused(unopenableIDs: [UUID])
    case tooLarge
    case failed                                            // transient; backed off (§4.5)
}
```
**The worker.** A single `Task`, held by the engine, drains a FIFO that holds at most one pass per payload,
so it is bounded at three passes.
- A pass runs at most two phases: restore, then export.
- No two passes ever run at once, for any payload or trigger. That covers the hub settle, un-hide, the
  follow-through, explicit intents and escrow adopt (R2-F15).
- `FernletStore` owns the engine. ContentView no longer starts an unowned settle Task (§4.5).

**The gates (G).** A pass captures `epoch = host.sealedBackupWorkEpoch` at its start. G holds when all of
these are true:
1. `!host.deleteAllInProgress` and `host.sealedBackupWorkEpoch == epoch`;
2. `!host.duressSessionActive` and `adapter.isSurfaceOpen`;
3. `host.sealedBackupContentKey != nil` (the hub is open now; the key is re-read live every time);
4. iCloud sync on and this payload's backup on, read from the in-memory preferences;
5. `adapter.isStoreHealthy`.

G is checked:
- at the start of a pass;
- **after every await**;
- **immediately before every decrypt**: opening a backup chunk, and decrypting a store row in prepare or merge;
- **immediately before every local write**: merge, skeletons, remove.

A failed G aborts the pass. Nothing is written and nothing is recorded, except a status where one applies:
- a closed hub or a backup that is off records nothing;
- hidden drops the status (§8.1).

**Restore phase (R).** It runs when the marker is unresolved, or for `restoreHere`.
- R1. The owner hold is set → stop, recording nothing. This applies to **every** trigger, explicit ones and
  Retry included (R1-BR-15). Only the owner-checked "Restore Sealed backup" clears the hold (§4.6).
- R2. Ambient spacing (§4.5).
- R3. `makeIdentity(.forOpening)`. With no escrow key, the outcome is `.deferredKeyNotSynced` before any
  network work.
- R4. Fetch the head. Re-check G, the hold, and that the marker is still unresolved or the intent still pending.
- R5. **No head** → `.nothingToRestore`. The marker resolves (under the owner hold too, since there is
  nothing to protect), the observation clears, and the payload is marked dirty.
- R6. Open the head inside `withOpenSeam` and classify it (§5.5).
  - A `restoreHere(stamp)` whose stamp no longer matches the head → back to held with the new stamp.
  - Unopenable heads: no key → `.deferredKeyNotSynced`; a mismatch → `.deferredKeyNotSynced` (§5.6);
    `malformedRecord` → `.notRecognized`.
- R7. Fetch the suffix chunks by the head's set (§5.2). Re-check G.
- R8. Open every suffix chunk inside `withOpenSeam`, synchronously. Verify the set (§5.3). Run the rollback
  check against `lastSeen`, bypassed only for `restoreHere(stamp, ignoringRollback: true)` with that exact
  stamp. Decode, reduce by id, and cap at 100 000 records.
- R9. Re-check G. Then, synchronously, `restoreMerging` with the live hub key, then `didRestore`.
  - If `didRestore` returns false, the outcome is `.deferredTransient`: the marker stays unresolved and the
    rows already merged stay. The next session's merge is idempotent and re-adds the missing skeletons.
- R10. Bookkeeping, only while the epoch is unchanged:
  - accepted head ← the stamp (§4.3); `lastSeen` ← `max(lastSeen, generation)`; marker ← resolved;
    observation ← none;
  - **mark dirty**, record the outcome, and consume the intent.
  - The export phase follows in the same pass and skips spacing, so the union is published at once.

**Export phase (X).** It runs when the payload is dirty, a probe is due, or for `replace`, `startNew` or `remove`.
- X1. **E1**: the marker is resolved, else `.waitingForRestore(lastOutcome)`. `replace` and `startNew` waive
  E1: they are confirmed decisions to write over the cloud copy (§4.6).
- X2. The owner hold keeps this payload's pre-reset copy → `.heldForOwner`. This applies to every trigger.
- X3. For `remove(ids)`: re-check G, then `removeStillDead(ids ∩ the last paused ids)`, then mark dirty.
- X4. Ambient spacing (§4.5). The probe runs only when the payload is clean.
- X5. **E2**: `makeIdentity(.forOpening)`. Fetch the head (metadata and asset). Re-check G. Then:
  - **no head**: if the payload is clean and nothing explicit is pending, **mark dirty** (R1-BR-10);
  - **unchanged**: head generation and salt prefix equal the accepted head's (§4.3). Clean → `.upToDate`,
    and the pass ends **without decrypting anything**. Dirty → continue;
  - **anything else**: classify by §5.5, opening inside `withOpenSeam`. A non-passing classification sets
    the status (and the observation for held) and ends the pass.
- X6. **Escrow for sealing.** A present key is used. If none is present, mint only by the §5.6 rule;
  otherwise `.waitingForBackupKey`.
- X7. **E3, prepare.**
  - Re-check G. Take `snapshotIDs()`. More than 100 000 ids → `.tooLarge`.
  - Compute `g = max(lastSeen, accepted.generation, head.generation) + 1` (not persisted, §5.4), a fresh
    16-byte set tag and a fresh salt.
  - For each chunk of 250 ids: re-check G (re-read the live hub key), call `classifiedChunk`, then seal the
    v2 envelope (§5.1) into a `SealedBackupRecord` held in memory, then `await Task.yield()`.
  - Prepared ciphertext above 64 MB → `.tooLarge`.
  - After the loop: any `transientCount` → `.failed`; any `needsNewerBuildIDs` → `.needsNewerFernlet`; any
    dead → `.paused(dead)`. Nothing has been written.
- X8. **Commit**, inside a `UIApplication.beginBackgroundTask` assertion that ends on return or expiry (R2-F6).
  - Check the epoch and `!Task.isCancelled` before the first save.
  - Save the scoped suffix chunks, then the head. `Task.isCancelled` is checked before each save (only
    delete-all cancels).
  - **Verify**: re-fetch the head and require generation `g` and this pass's salt (R1-BR-3).
  - **Prune** older sets (§5.2), best-effort.
  - Nothing is decrypted in X8.
- X9. Bookkeeping, only while the epoch is unchanged:
  - `lastSeen` ← `max(lastSeen, g)`; accepted head ← (own tag, `g`, salt prefix); observation ← none;
  - the marker ← resolved if it was waived;
  - clear dirty **only if** `host.sealedBackupMutationEpoch(payload)` equals its value at X7's start;
  - status `.upToDate`; consume the intent.
  - A failed verify → `.failed`: dirty stays, and the next E2 decides who holds the slot.

### 4.3 Per-payload bookkeeping (`App/Fernlet/SealedBackupBookkeeping.swift`, new; `init(defaults:)`)
One type for all three payloads.
- It is injectable like `SealedBackupRestoreHold(defaults:)` (R2-F16a). `FernletStore` holds it with
  `@ObservationIgnored`.
- Every accessor is an exhaustive `switch` over the payload, and each arm makes its **own**
  `defaults.set(…, forKey: "<literal>")` / `removeObject(forKey: "<literal>")`. No key is returned and then
  written (R2-F16e; `Tests/FernletTests/PersistedSurfaceWipeBoundaryTests.swift` resolves only literals at the
  call site).

| Payload | Resolved marker (`Bool`) | Accepted head (`String`) | Observed foreign head (`String`) |
| --- | --- | --- | --- |
| periodData | `fernlet.cycleRecord.periodRestoreResolved` (B0/unit 5) | `fernlet.sealedBackup.periodAcceptedHead` (B0/unit 5) | `fernlet.sealedBackup.periodObservedHead` (B0/unit 5) |
| journalNarratives | `fernlet.journalNarrative.restoreResolved` (B3) | `fernlet.sealedBackup.journalAcceptedHead` (B3) | `fernlet.sealedBackup.journalObservedHead` (B3) |
| intimacyLogs | `fernlet.intimacyLog.restoreResolved` (B2) | `fernlet.sealedBackup.intimacyAcceptedHead` (B2) | `fernlet.sealedBackup.intimacyObservedHead` (B2) |

- **Accepted head** = `"<acceptor>:<writer>:<generation>:<salt8>"`.
  - `acceptor` is this install's writer tag (§5.1) at the time it was recorded.
  - `salt8` is the first 8 bytes of the set's salt, in hex. The salt is already a plaintext CloudKit field.
  - **It reads as absent when `acceptor` is not this install's tag**, or when the value does not parse. So
    a value that travelled in a device backup cannot make another iPhone's head look accepted (R1-BR-2).
  - The writer tag is unreadable (`DeviceBindingID` unavailable) → it reads as absent and the export is
    `.failed`.
- **Observed head** = `"<acceptor>:<writer>:<generation>"`. Written when E2 or R6 finds a foreign head.
  Cleared when the head becomes own or accepted. Read by Privacy & Data after a relaunch (R2-F13b) and by
  the turn-off confirmation (R2-F3).
- **Marker.** Unresolved means "this install has not pulled this payload's backup".
  - It resolves only on a restore outcome of `.restored` or `.nothingToRestore` (no head), or when a confirmed
    `replace` or `startNew` commits.
  - **It never resolves because sync or a backup is off** (R1-BR-2, R2-F4). E1 only gates exports, and no
    export runs while either is off.
  - Clearing writes `false`; it never removes the key.
- **Seeding, once, in `FernletStore.init`**, for an absent marker key (the first launch of this build, or
  the first launch after an uninstall):
  - marker ← the latch read with its row-count backfill (`hasEverStoredNarrative` / `hasEverStoredLog`, a
    keyless count);
  - **and** if that payload's backup is enabled, dirty ← true (R1-BR-11). Every install then exports one
    complete v2 set at its first visit, through E2.
  - A key that is present is never re-seeded, so a write later in the process cannot close the restore.
- No new keychain row, file, Core Data entity, CloudKit field or `CryptographicPurpose`.

### 4.4 Dirty marking: one mechanism for all three
```swift
// FernletStore (app). In memory, one store per process: no mutable global.
private var sealedBackupMutationEpochs: [SealedBackupPayloadType: Int] = [:]
func markSealedBackupDirty(_ payload: SealedBackupPayloadType) {
    sealedBackupMutationEpochs[payload, default: 0] &+= 1
    guard !deleteAllInProgress else { return }                     // R2-F10
    recordSealedBackupReuploadDeferred(true, payloadType: payload) // never the enabled switch
}
func sealedBackupMutationEpoch(_ payload: SealedBackupPayloadType) -> Int
```
- **No keychain read** (R2-F14). The flag is set whether the backup is on or off. The export and the UI
  check the switch.
  - The persist hook compares against ContentView's in-memory preferences and writes only on a change
    (`ContentView.swift:1725-1741`), so a burst of writes costs one preferences write.
  - Attaching the hook re-persists any in-memory flag that differs. That catches writers that ran before
    ContentView wired it, such as the launch-time scrub insert.
- **The epoch is the only "did it move" witness**, for all three kinds (R2-F8). Every store instance's hook
  moves it. `CycleRecordStore.mutationCounter` is per instance and is not consulted.
- **One shared payload-to-switch helper.** `StoragePreferences.isSealedBackupEnabled(for:)` is an app-target
  extension. `FernletStore.hasSealedBackup` (`:5578`), `SealedBackupRestoreHold.isBackedUp` (`:100`), the
  engine and Privacy & Data all use it (R2-F14).
- **Period:** the `CycleRecordStore` hook calls `markSealedBackupDirty(.periodData)` on every instance
  (B0/unit 5).
- **Journal:** `JournalSealingContext` gains `sealedJournalStoreDidChange()`. `JournalSealingCoordinator`
  calls it after:
  - `seal` (`:175`);
  - `updateSealedNarrative` (`:224`);
  - `deleteSealed`, success or not (`:246`): the skeleton goes either way, so the export must drop the entry;
  - `migrateExisting…` when anything migrated (`:426`);
  - the scrub when it inserted (`:481-487`).

  The restore merge and Remove mark through the engine. **The fold does not mark**: it changes ciphertext
  only, and the export reads both keys (§7.2).
- **Intimacy:** `IntimacyLogStore.attachMutationHook(_:)` mirrors `CycleRecordStore.swift:95-97`. It fires
  after `insert`, `markSavedToHealthKit`, `deleteAll` (when rows were removed) and `restoreMerging` (when
  something changed).
  - With B2 the app has exactly three construction sites, each hooked: ContentView's instance (`:50`), the
    adapter's (which is ContentView's instance, passed in at wiring), and `SealedPriorEntryStore`'s (which
    receives ContentView's).
  - The per-call instances in `resolvedIntimacyStore` are deleted with the legacy intimacy paths.
  - A grep test pins the allowed construction sites.

### 4.5 When passes run, and how often
- **The hub settle.** ContentView calls `store.requestSealedBackupHubSettle()` when the first Private
  section of a hub session appears, **any section, Worry Box included**.
  - The store's held task waits 300 ms. It then checks that the Private tab is selected and the hub is
    unlocked, and calls `engine.request([.periodData, .intimacyLogs, .journalNarratives], .hubSettle)`.
  - Every payload runs at every hub session, not just on its own section: the hub key is the same on every
    section (period R2-F1), so the journal no longer waits for the Journal section (R1-BR-16).
  - Payloads not yet on v2 during staging keep their legacy routes.
- **Per hub session.** `hubSessionEnded()` is called from `handleLockStateChange` when the hub locks
  (`ContentView.swift:329`). It clears the attempted sets that replace `attemptedSealedBackupSections`.
- **Exports.** An automatic export of a payload runs at most once per hub session, and only when the payload
  is dirty.
  - After a **failed** automatic attempt, the next waits at least 15 minutes (in-memory clock, injected in tests).
  - Explicit intents and the restore follow-through skip both limits.
  - A successful export followed by a new change exports at the next hub session, whenever that is (Q-B5).
- **Probes.** On a clean visit (backup on, E1 resolved, not dirty), the export phase runs E2 only: at most
  once per hub session, and at least 15 minutes after the last probe. When the head metadata matches the
  accepted head, nothing is decrypted.
- **Ambient restores.** At most once per hub session. A **failed** ambient restore waits at least 15
  minutes before the next attempt (R2-F5), so a stuck restore does not re-download the set on every unlock.
- **Un-hide** (intimacy). The held un-hide settle calls `engine.request([.intimacyLogs], .unhide)`. It does
  work only if the hub is open; otherwise the next hub settle does.
- **Escrow adopt** (WS-3). The adopt marks every enabled v2 payload dirty and nothing more. The next hub
  settle exports through E2, which treats a head sealed under the replaced key with this install's signing
  key as own (§5.5).
- **Launch and Retry.** Nothing can run with the hub closed, so:
  - the launch pass and its follow-through no longer touch v2 payloads;
  - Retry calls `engine.request(v2 payloads, .retry)`, which is ambient (honours the hold and E1) and a
    no-op while the hub is closed.
  - `showsRetryRestore` stops OR-ing in the v2 deferral flags (R2-F9).
- **Cost.**
  - One prepare decrypts every snapshot row once, in yielded 250-row chunks, and holds sealed chunks in
    memory (bounded at 100 000 records and 64 MB, the same order as what a restore already holds).
  - Clean visits normally decrypt nothing.
  - Every loop is bounded by a count fixed before it starts: snapshot ids, at most 400 chunks, at most 3
    queued passes, at most 3 head-existence checks (Power of 10 R2).

### 4.6 Explicit actions are intents
Privacy & Data lives in Settings, where the hub is closed. So an explicit action changes no persisted
bookkeeping at tap time: it records an **in-memory intent** on `FernletStore`, and the next hub settle in
this process carries it out.
- The row then says "Open Private to finish." If the process ends first, the intent is gone and the row shows
  its button again. Losing an intent is always safe: nothing has happened yet.
- Every intent honours the owner hold and the gates.

| Action (shown when) | Intent | What the next settle does |
| --- | --- | --- |
| Restore it here (`.heldByAnotherDevice(s)`) | `restoreHere(s, ignoringRollback: false)` | R with the marker untouched: merge the head if it is still `s`; accepted ← `s`; dirty; the follow-through export then passes E2. A terminal outcome or a changed head returns to the held state with both buttons (R1-BR-4) |
| Replace it with this iPhone's … (`.heldByAnotherDevice(s)`, or `.waitingForRestore(.rolledBack)`) | `replace(s)` | X with E1 waived and E2 passing for exactly `s`; if the head moved since, held again |
| Restore anyway (`.waitingForRestore(.rolledBack)`, stamp known) | `restoreHere(s, ignoringRollback: true)` | R merge of exactly `s` despite the rollback check (a merge cannot delete) |
| Start a new backup (`.waitingForBackupKey`, `.headSealedWithOtherKey`, `.headDamaged`, `.waitingForRestore(.deferredKeyNotSynced / .notRecognized)`) | `startNew` | X with E1 and E2 waived; mints an escrow key if none (§5.6); writes over the unopenable set |
| Remove them (`.paused(ids)`) | `remove(ids)` | X3: re-classify under every key; delete only ids still dead **and** shown; dirty; export |
| Restore Sealed backup (owner hold; unit 5, behind `.deviceOwnerAuthentication`) | hold released, persisted; `engine.request(all, .ownerRelease)` | ambient merges of every enabled, visible payload whose marker the reset cleared |

The hold release happens **on the tap**, after the device-owner check. Period §5.3 releases it only after a
non-retryable restore outcome, but that restore needs the hub key, which Settings never holds. Releasing on
the tap is safe:
- the owner has just confirmed;
- the reset left every marker unresolved, so E1 still blocks every export until that payload's merge has run.

This changes the period text, so it is listed in §4.8 with a period test (R2-F7).

### 4.7 Stopping: delete-all, reset, duress, hide, hub close (the concurrency contract)
| Event | What the engine does |
| --- | --- |
| **Delete-all** (and the duress silent wipe through `duressPurgeHook`) | `deleteAllInProgress` is raised first (`FernletStore.swift:5644`), so `request` drops new work and G fails. `stopWritersForWipe` moves `sealedBackupWorkEpoch` and cancels the worker. **The funnel then awaits `engine.quiesceForWipe()` before leg 2.** A pass resuming from any await fails G before it decrypts or writes: no merge, no skeleton, no chunk, no head, no bookkeeping (R1-BR-1). The un-hide settle task is cancelled as today. |
| **App-lock reset** (`handleAppLockResetCompleted`, synchronous) | Moves `sealedBackupWorkEpoch` before clearing bookkeeping. A suspended restore fails G (epoch, and the hold just set) at R4/R7/R9 and writes nothing. A prepare fails G at its next chunk. A commit **already past its first save** finishes uploading ciphertext it sealed before the reset: that is the newest pre-reset history, the copy the hold exists to keep, and aborting would leave the set incomplete. Its X9 bookkeeping is skipped (the epoch moved). |
| **Duress session begins** | G fails at the next check: no decrypt, merge or prepare. A commit past its first save finishes uploading ciphertext prepared before the session (no local effect, nothing shown). |
| **Hide** (intimacy or period) | Same as duress for that payload; the seam closes. The intimacy status is dropped. |
| **Hub closes** | G fails at the next check. A restore never decrypts or writes with the hub closed (the live key is re-read at R9). A prepare aborts at its next chunk with nothing written. A commit continues: it decrypts nothing and needs no hub key (R2-F6). |

`sealedBackupWorkEpoch` is an in-memory `Int` on `FernletStore`, moved only by `stopWritersForWipe` and the
reset funnel.

BV15 pins every row of this table. That includes a restore suspended in a fake CloudKit fetch and then
resumed after `deleteAllData`, and after `reset()`: it must land no row, no skeleton, no chunk, no head and
no bookkeeping.

### 4.8 Engine behaviour that also changes period (each a strict fix; every item has a period test)
1. Gates first: visibility, duress and key before any network work or head open. Then G after every await
   and before every decrypt and every local write (R1-BR-12).
2. Duress refusal for every pass.
3. Delete-all and reset stop the worker as in §4.7 (R1-BR-1).
4. `isStoreHealthy` before the snapshot and before every restore write (R2-F2).
5. Head opens use `.forOpening` only; the mint rule is §5.6 (R2-F1, R1-BR-7).
6. Restore classification: a mismatch is a wait, not a terminal `.notRecognized` (§5.6).
7. E2 is writer-first. A v1 head's authorship comes from its AAD-bound signing key, never from `lastSeen`.
   This replaces period §9.10's seed rule (R1-BR-9, R1-BR-13).
8. The accepted head is install-bound, carries a salt prefix, and is kept by delete-all (R2-F11).
9. Generation: computed, persisted only on commit, and the rollback floor counts only commits (R1-BR-4).
10. Envelope `writer` and `set` in every chunk, set-scoped suffix names, the set verification and the
    post-commit verify (R1-BR-3, R1-BR-8, R2-F6).
11. Prepare then commit, with every chunk sealed before the first save, inside a background-task assertion
    (R2-F6, R1-BR-8).
12. One serial worker (R2-F15).
13. The marker never resolves because sync or a backup is off. No head resolves it, even under the hold (R1-BR-2, R2-F4).
14. "Restore it here" leaves the marker alone (R1-BR-4).
15. Retry is ambient (R1-BR-15).
16. The hold is released on the owner-checked tap (§4.6, R2-F7).
17. No head while on and resolved → dirty (R1-BR-10).
18. Spacing: once per hub session, with a 15-minute backoff after failures, restores included (R2-F5).
19. The host epoch is the only dirty witness (R2-F8).
20. The observed head is persisted (R2-F13).
21. Turning off on a foreign slot keeps it (R2-F3).
22. Every hub session settles every payload, on any section (R1-BR-16).
23. Once-only init seeding also marks dirty (R1-BR-11). For period, that is unit 5 lifting the U2/U4 freeze.

## 5. Format, cloud layout, generation, E2

### 5.1 Envelope v2 (shared with period)
- Head (chunk 0): `{"v":2,"writer":"<32 hex>","set":"<32 hex>","total":N,"records":[R…]}`.
- Chunk *i* ≥ 1: `{"v":2,"writer":"<32 hex>","set":"<32 hex>","records":[R…]}`.
- **Writer tag.** `writer` = the first 16 bytes of `SHA256(Hash.sealedBackupWriterTagV1 ‖ DeviceBindingID.current())`,
  in hex (period §9.10). `DeviceBindingID` is ThisDeviceOnly and is kept by delete-all (`Docs/PrivacyWipeCoverage.md:237`).
- **Set tag.** `set` = 16 CSPRNG bytes per pass, in hex. It is not a hash, so no purpose is needed.
- **Records.** `R` is the existing `Codable` record. Its synthesized `CodingKeys` become **frozen tokens**:
  - `JournalNarrative`: `id, dayKey, tag, entryDate, text, emotions, createdAt, updatedAt`;
  - `IntimacyLog`: `id, dayKey, eventDate, note, healthKitExternalUUID, createdAt, updatedAt`;
  - `CycleRecord`: as unit 3 froze it.
- Record crypto, AAD, salt derivation and chunk size are unchanged. The writer and set tags travel only
  inside the escrow-sealed plaintext, except that the set tag also appears in suffix record names (§5.2).
  Both are random-looking, per-install or per-set values with no content.

### 5.2 Cloud layout: set-scoped suffix chunks (R1-BR-3, R1-BR-8, R2-F6, R2-F15)
- **Names.** The head keeps its name, `sealed-backup.<payload>`. A v2 suffix chunk is
  `sealed-backup.<payload>.chunk.<i>.<set>`. A v1 set keeps `sealed-backup.<payload>.chunk.<i>`.
- **Write order.** A pass writes its suffix chunks under **its own** names, and nothing else can write
  those names. It then saves the head, the one record both phones share. **The head save is the only
  commit point.**
  - An export interrupted before the head (offline, killed, background expiry, delete-all cancellation, an
    abort) leaves the previous head and its whole set untouched and restorable. The new chunks become
    orphans.
  - Two iPhones exporting at once can no longer interleave chunks. Whichever head lands last owns the slot,
    and its set is complete. The other phone's verify fails, and its next E2 shows the held state.
- **Read.** Fetch the head, open it, then:
  - v2 envelope: fetch `chunk.1.<set>…chunk.<n-1>.<set>` by name;
  - bare array (v1): fetch `chunk.1…` as today.

  `maxFetchedChunkCount` (400) still bounds the fan-out before any id is built.
- **Prune**, after the head commits and verifies (best-effort; a failure leaves orphans for the next commit):
  - delete every suffix record of the payload that is not in the committed set and whose `generation`
    metadata is below `g`;
  - delete every unscoped (v1) suffix chunk.

  A concurrent set at the same `g` survives one round, so a prune never deletes the chunks of a head that
  is still landing.
- **Delete.** Turning a backup off and delete-all delete by prefix. The name matcher in
  `sealedBackupRecordIDs` (`CloudKitDataService.swift:642-652`) learns the `chunk.<i>.<set>` form.
  **Without that, scoped chunks would survive delete-all.** A `DeleteAllDataTests` case pins it.
- **CloudKitSync changes** (no sealed import; the S3 wall holds):
  - `saveSealedBackup(_:setTag:)`;
  - `sealedBackupSuffixChunks(payloadType:chunkCount:setTag:)`;
  - `pruneSealedBackupSets(payloadType:keepingSetTag:belowGeneration:)`;
  - the matcher.

  The existing `sealedBackupChunks` stays for v1 sets.
- **Older builds.** A build before this one reads a v2 head as a decode failure (`.deferredTransient`) and
  never writes it. A shipped build can still write a v1 set over the head. The v2 reader then sees a v1 head:
  own by signing key (§5.5) when it was this iPhone, otherwise held.

### 5.3 Restore-side set verification (v2 sets)
All of these are required before decoding records:
- every chunk's envelope `writer` and `set` equal the head's;
- the `set` equals the record-name tag it was fetched under;
- every chunk's CloudKit `keySalt` equals the head's;
- the decoded record total equals the head's `total`;
- contiguity, chunk count and generation, as `sealedBackupChunks` checks today.

The checks fail closed as `.deferredTransient`. A set mixing v1 and v2 chunks fails closed the same way. An
attacker who splices a chunk from another set at the same generation is caught by the authenticated `set`.

### 5.4 Generation and rollback (R1-BR-4, R2-F16d)
- **Generation.** A v2 set is written at `g = max(lastSeen, accepted.generation, head.generation) + 1`,
  computed after E2. **Nothing is persisted before the upload.**
  - `lastSeen` (the existing key) is raised only by a verified commit (X9) or an accepted restore (R10).
  - Burned mints therefore never raise the rollback floor. Restoring the other iPhone's set can no longer
    fail `.rolledBack` because this phone aborted uploads.
- **Why burning is no longer needed.** `mintNext` persisted first because a crash after an upload could
  reuse a generation already in the cloud, and a substitution of the earlier set would then pass the
  rollback check. Here, E2 reads the head before computing `g`, so a landed head is always exceeded. A
  reused `g` can only meet orphan chunks of an uncommitted set, which have a different authenticated `set`
  (§5.3).
- **The photo route** (`recordAcceptedPhoto` then `mintNextPhoto`, `SealedBackupGenerationStore.swift:121-138`)
  is unchanged. Its burn-on-failure is the R1-BR-4 defect, so the chunked route does not copy it.
- **The rollback check** keeps its form (`generation ≥ lastSeen`). "Restore anyway" bypasses it only for
  exactly the stamp the user saw.
- **Transition residual.** An install whose `lastSeen` already holds a burned v1 mint can still see one
  `.rolledBack`. "Restore anyway" and "Replace" are both offered (§4.6).

### 5.5 E2 head classification (export X5 and restore R6)
| Head | Classified as |
| --- | --- |
| none | export: pass; floor from `lastSeen` and the accepted head. Restore: `.nothingToRestore` |
| metadata (generation, salt prefix) equals the accepted head | own, unchanged: no decrypt |
| opens; v2 and `writer` == this install's tag | **own** (R1-BR-13), including a head this install wrote whose save landed but was never recorded, or one surviving a failed delete-all delete (R2-F11) |
| opens; stamp == accepted head (install-bound) | accepted: pass |
| opens; v1 and its AAD-bound `signingPublicKey` == this install's signing key | **own v1** (R1-BR-9). A clone or another iPhone has a different, device-only signing key, so a travelled `lastSeen` or a restored set can never make another phone's set look like ours |
| opens; trigger `replace(s)` and stamp == `s` | pass (explicit) |
| opens; anything else | `.heldByAnotherDevice(stamp)`, persisted as the observation |
| opens; envelope `v` above 2, or an unknown envelope shape | `.needsNewerFernlet` (never overwritten automatically) |
| does not open; no escrow key on this iPhone | `.waitingForBackupKey` |
| `keyAgreementIdentityMismatch`; the record's `signingPublicKey` == this install's | own, sealed under an escrow key this iPhone has since replaced (WS-3 adopt): pass, and overwritten under the current key. This rests on unauthenticated metadata, which is acceptable: forging it gains only that this iPhone replaces a set it cannot open |
| `keyAgreementIdentityMismatch`, while `sealedBackupEscrowConflict` | `.waitingForBackupKey`, with the escrow-conflict banner as the only prompt |
| `keyAgreementIdentityMismatch`, otherwise | `.headSealedWithOtherKey`, retried every session (the key is usually still syncing) |
| `malformedRecord` (tagged with our key, will not authenticate) | `.headDamaged` |
| trigger `startNew` | pass for every unopenable case above |

### 5.6 The escrow-key mint rule (R2-F1, R1-BR-7)
- Every head open (R3, X5, probe) uses `.forOpening` and never mints.
- The engine mints (`provisionBackupEscrowKeyForSealing`) only:
  - at X6, **when no enabled v2 payload has a head in iCloud**. This is checked by head-existence fetches,
    with no decrypt and at most three;
  - or for an explicit `startNew`.
- On a new iPhone whose old backups exist, the engine therefore never creates a divergent local key while
  the synced one is on its way. Exports wait (`.waitingForBackupKey`) instead.
- **Restore**: a mismatch is `.deferredKeyNotSynced`, which is retryable. It is no longer the terminal
  `.notRecognized`, because a locally minted key beside a synced key that has not arrived reads exactly
  like a mismatch. `.notRecognized` is kept for `malformedRecord`.
- **No copy points at the delete switch.** The way out of an unopenable head is the explicit, confirmed
  "Start a new backup" (§10.1).

## 6. Each period-v2 part, applied per kind

| Part | Journal (`journalNarratives`) | Intimate logs (`intimacyLogs`) |
| --- | --- | --- |
| E1 marker | `fernlet.journalNarrative.restoreResolved`; seeded once at init | `fernlet.intimacyLog.restoreResolved`; seeded once at init |
| E2 | writer-first (§5.5); accepted `…journalAcceptedHead` | the same, with `…intimacyAcceptedHead`; opened only inside the gated seam (§8.1) |
| Held state | "Your journal backup was saved from another iPhone…" | the same for intimate logs, only while visible and never in duress |
| Snapshot | sealed ids ∩ ids some day's journals reference (§7.1) | `IntimacyLogStore.allIDs()` |
| Chunks | `JournalNarrativeRepository.backupRecords(ids:hubKey:deviceKey:)` (§7.2) | gated `IntimacyLogStore.backupChunk(ids:contentKey:)` |
| Surface open | `!duress` (no hide switch exists) | derived visibility (16+ gate, setting, `!duress`) |
| Restore | merge: keep local, fork different text, replace dead (§7.3); then skeletons | merge: keep local, fill a missing Health link, replace dead (§8.2); through the gated funnel; never writes HealthKit |
| Ambient restore | `!resolved && !restoreAwaitsOwner`, G | the same, plus visible |
| After reset | only after "Restore Sealed backup" (Q14); one action covers all three | the same |
| Dirty | `JournalSealingCoordinator` writes (§4.4), merges, Remove | insert, mark-saved, delete-all, merge |
| v1 accepted on restore | `[JournalNarrative]` bare array | `[IntimacyLog]` bare array |

## 7. Journal specifics

### 7.1 What a journal backup contains (R1-BR-6)
- The snapshot is the sealed ids **that some day's `journals` still reference**. Those come from
  `loadAllDaysFromRepository()` plus the in-memory today and `previousJournals`, intersected with
  `JournalNarrativeRepository.allIDs()`.
- An **orphan** sealed row (no skeleton anywhere) is never exported, so it can never come back through a
  restore.
  - A failed `deleteSealed` leaves such a row, so the user's delete reaches the backup at the next export.
  - With iCloud sync on, an entry deleted on the other iPhone loses its skeleton here too, so this phone's
    export drops it as well.
- **Decision for orphans from a failed past-day append** (`FernletStore.swift:3936-3943`): they are not
  exported either. Such an entry is already invisible on this iPhone, and nothing distinguishes it from a
  failed delete without a new persisted surface. The row stays on the device, encrypted, as today (§12
  item 9).
- **Orphans a restore creates** (a failed skeleton write in `didRestore`) are retried, not dropped. The
  restore stays unresolved, so E1 blocks the export until a later session's idempotent merge has added
  every skeleton.

### 7.2 Reading rows for a backup (R1-BR-16, R1-BR-8, R2-F12)
New `JournalNarrativeRepository.backupRecords(ids:hubKey:deviceKey:) -> JournalBackupPage`. Per id, in one
`id IN` fetch of at most 250:
- **Missing** row → deleted since the snapshot: absent from the page.
- **Opens** under the hub key, or else under the device key → a record.
- The device key is read **without minting**, through `KeychainItem.loadDistinguishingAbsence`. The helper
  moves out of `SealedPriorEntryStore.deviceKey` (`App/Fernlet/PrivateHubOpenCoordinator.swift:406-415`) into
  a shared one. An unreadable keychain counts as transient.
- **Opens, but a plaintext field this build cannot read** (an unknown `FeelingTag`, a missing `dayKey` or
  `entryDate`) → `needsNewerBuildIDs`. It is never dead, because a newer build would show it. Missing key is
  not the same as unknown value.
- **Refuses** under both keys, with neither read transient → dead.
- `DeviceBindingID.ReadError` → transient.

What this changes:
- **The fold is no longer a backup precondition.** Rows still under the device key export as they are. A
  hub-key entry edited from Home (back under the device key, §2.4) stays in the backup, so a prepare no
  longer throws when the user edits mid-export.
- The fold keeps its job, key custody, and still runs at Journal activation. `.waitingForFold` is gone.

### 7.3 The journal merge (R1-BR-5)
New `JournalNarrativeRepository.upsertMerged(_ incoming: [JournalNarrative], hubKey:, deviceKey:) throws ->
SealedBackupMergeResult` is the only restore write. `insertAtomically` stays for nothing else and is deleted
in B3.
- **Reduce the incoming batch by id**: on a duplicate id the later `updatedAt` wins, and a tie goes to the
  content order. A set built from one snapshot has unique ids; this only guards against hostile sets.
- **Then, per incoming record**, against the local row with that id:

  | Local row | Result |
  | --- | --- |
  | absent | **insert**, keeping the incoming `createdAt` and `updatedAt` (`apply` gains a stamp parameter; user writes keep stamping now) |
  | opens (hub or device key), same text and emotions | nothing; a tag or date difference alone also leaves the local row as it is |
  | opens, **different text or emotions** | **keep local**. Add the incoming copy as a **new entry**: fresh random id, the incoming `dayKey`, `entryDate`, tag, text, emotions and stamps. Skip it when any row on that `dayKey` already has equal text and emotions, decrypted under the hub or device key |
  | dead (opens under neither key; nothing transient) | **replace** with the incoming record and its stamps |
  | transient or needs-newer-build | the whole merge throws (`.deferredTransient`) |

- **Never** deletes a row, modifies a local row that opens, or uses `updatedAt` to choose between two texts.
  Restore-time stamps from v1 restores, the same-id typing path with sync on, and clock skew therefore cannot
  lose text.
- **Idempotent.** A second merge of the same set changes nothing: a fork's equal content is found on its day.
- One save, rolled back on any throw. History is pruned best-effort. The latch is set after the commit.
- **Bounded.** Inserts plus forks ≤ the incoming count (≤ 100 000). The same-day content check reads only the
  rows of the days the conflicts are on.
- Forks are new entries, so they mark the journal dirty. The union, both versions included, is published by
  the follow-through export.

### 7.4 Day skeletons
- `didRestore` calls `reinstateJournalEntries` (`FernletStore.swift:7235-7261`) for every inserted,
  replaced and forked id. It returns whether every day write succeeded.
  - `reinstateJournalEntries` gains a `Bool` result; its existing audit line stays.
  - It adds a skeleton only for ids the day lacks and never edits an existing skeleton.
- A journal restore may now run on any Private section. Hydration still happens when the Journal section
  activates (`refreshAfterSnapshotApply`).
- Tag-only mood check-ins are never sealed (`JournalSealingCoordinator.swift:154`). They live in the day
  blob, as today.
- **"Can't open" card.** The promise of the §4.9 card (`ContentView.sealedBackupRestoresAfterRemoval`,
  `:509-518`) drops its "journal store empties on removal" condition. A merge restore runs whatever stays behind.

### 7.5 Tier-two memory and summaries: none carried
The journal backup carries exactly `JournalNarrative` rows. Nothing else is carried:
- tier-two memories never leave the device (owner decision 2026-09-23), and `SealedBackupContext` exposes
  none (`SealedBackupCoordinator.swift:48-50`);
- Core Memory notes ride the synced day blob and are not re-derived from restored entries.

### 7.6 Duress, for the journal specifically
- The journal's `isSurfaceOpen` is `!duressSessionActive`, and G re-checks duress before every decrypt and
  every write.
- Privacy & Data shows no journal held, paused, waiting or catch-up row, and offers no backup action, during
  the session.
- Silent wipe: delete-all (§4.7). Recovery-lock: no hub key, so nothing runs.

## 8. Intimacy specifics

### 8.1 Gates at the decrypt seam (16+ age gate, visibility, duress)
- Every intimacy read, write and backup call goes through `IntimacyLogStore`. The app never constructs
  `IntimacyLogRepository` (grep-walled in `SensitiveSurfaceGateTests`).
- **New gated members**, mirroring `CycleRecordStore.swift:142-184`: `backupChunk(ids:contentKey:)`,
  `restoreMerging(_:contentKey:)` and **`withBackupSeam(_:)`**. The backup-chunk **opens** in R6, R8 and X5
  run inside `withBackupSeam`, so the escrow decrypt of intimate notes happens behind the funnel's own gate
  (R1-BR-12).
  - Each throws `IntimacyTrackingHiddenError` while hidden and `FernletLockError.locked` with no key.
  - None of them ever answers empty.
- **Ungated**, because they decrypt nothing: `allIDs()`, `backupLogCount()`, `hasEverStoredLog`,
  `clearDivergenceLatch()`, `deleteAll()`.
- The visibility closure is `FernletStore.isIntimacyTrackingVisible`: `!duress`, the 16+ gate (fail closed
  until attested) and the setting.
- **Hidden**, for any of the three reasons, means:
  - no head fetch, probe, prepare, chunk or restore;
  - the switch and the cloud copy are untouched (hiding never deletes);
  - dirty, the marker, the accepted head and the observation stay as they are;
  - **no held, paused, waiting or catch-up row names intimacy** (R2-F16c). The switch row's existing
    "unavailable while … turned off. Your existing backup is kept." line stays (`PrivacyDataSettingsView.swift:755`);
  - the in-memory status is dropped.
- A commit already past its first save when the user hides intimacy finishes uploading ciphertext sealed
  while visible (§4.7). That decrypts nothing. Aborting it would leave the set incomplete, which is a
  deletion in effect, and hiding never deletes.

### 8.2 The intimacy merge
New `IntimacyLogRepository.upsertMerged(_:contentKey:) -> SealedBackupMergeResult`, reached only through
`IntimacyLogStore.restoreMerging`:
- absent → insert, keeping the incoming stamps, with the note capped at `maxNoteLength` (1 000) before sealing;
- present and opens → **keep local**; if the local `healthKitExternalUUID` is nil, take the incoming one. A
  link is never dropped;
- dead (does not open under the hub key) → replace;
- transient → throw.

There is no per-log edit in the app, so two different notes under one id can only come from corruption or a
hostile set; the local copy wins. The atomicity, idempotence and latch rules are the same as §7.3. Intimacy
rows are hub-key-only from their first write (`LogIntimacySheet.swift:208`).

### 8.3 Health-mirrored intimacy samples
- The backup carries only the sealed `IntimacyLog`: date, note and Health link. **The export never reads
  HealthKit. A restore never writes HealthKit** (restoring is not a user save).
- On a new iPhone, a restored log's link points at a sample that may or may not arrive through iCloud
  Health. The calendar's per-day `max` merge (`CycleTrackerView.swift:~708-712`) shows one event either way.
- Health-only intimacy events never enter the sealed store or a backup.

### 8.4 Why intimacy lands first
Intimacy has no device key, no skeletons, no forks and no per-log edit. Its adapter is the smallest test of
the engine against a gated store, so it lands as B2, ahead of the journal (B3).

## 9. Delete-all, duress, reset, new key, turn off, wipe wall

| Event | Cloud set | Marker | Accepted head | Observed head | Dirty flag | Latch | `lastSeen` |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Delete-all (`deleteAllData`) | worker quiesced (§4.7), then every **enabled** payload's set deleted, **including a slot the other iPhone owns** (§12 item 2); the escrow key goes too, and that propagates | **kept** | **kept** (R2-F11: a set surviving a failed delete is then overwritten by the next export, which finishes the wipe) | cleared | cleared, and hooks cannot re-set it (R2-F10) | kept | cleared (existing) |
| App-lock reset (`handleAppLockResetCompleted`) | kept; held for the owner (Q14) | `false` | cleared | cleared | unchanged (held) | cleared | kept |
| §4.9 new-key coordinator (`clearBackupBookkeeping`) | untouched | `false` | cleared | cleared | unchanged | cleared | kept |
| Duress silent wipe | as delete-all | kept | kept | cleared | cleared | kept | cleared |
| Duress recovery-lock | untouched; nothing runs (no hub key) | untouched | untouched | untouched | untouched | untouched | untouched |
| Hide intimacy | untouched | untouched | untouched | untouched | untouched | untouched | untouched |
| Turn off, slot own or unknown | deleted; `forgetPreResetCopy` | untouched | cleared | cleared | cleared | untouched | kept |
| Turn off, slot observed as another iPhone's (R2-F3) | **kept** (not this iPhone's backup) | untouched | untouched | kept | cleared | untouched | kept |

- **`SealedPriorEntryStore`.** `hasBackupBookkeeping` (`PrivateHubOpenCoordinator.swift:381-384`) also counts
  a `true` marker, a present accepted head and a present observation. `clearBackupBookkeeping` (`:392-396`)
  clears all three for journal and intimacy (and period, B0).
- **The reset purge** runs inside `FernletLockService.reset` through the keyless controller purge, not
  through any store instance, so no mutation hook fires during it. A test pins this.
- **Wipe wall, in the same commit as each key** (B2 for intimacy, B3 for journal, B0/unit 5 for period):
  - a `Docs/PrivacyWipeCoverage.md` disposition row for each of the six new keys, giving the delete-all
    column above and the other exits. The accepted head is **kept** by delete-all, with the reason; it holds
    two install tags, a counter and a salt prefix, no content;
  - their `PersistedSurfaceWipeBoundaryTests` manifest entries;
  - a correction to the latch row (`:240`): "latches no longer gate the journal and intimacy restores; they
    seed the markers once".
- **Delete-all scope.** `setSealedBackupEnabled(false, …, deletingAnySlot: true)` keeps delete-all's leg 2
  deleting every enabled payload's set whoever wrote it. The user's switch passes `false` and keeps a
  foreign slot.

## 10. Privacy & Data, copy, localization, accessibility

### 10.1 Rows (inside the existing backup banner, `PrivacyDataSettingsView.swift:1024-1041`)
- Each journal row shows only when its status holds and `!duress`. Each intimacy row also needs intimacy
  visible.
- The rows are new sentences under new keys. Spliced `displayNoun` sentences are not reused: they cannot
  agree in gender or case in fr, de or es.
- **After a relaunch.** Statuses are in memory, so after a relaunch the row is derived from persisted
  state, in this order:
  1. the owner hold;
  2. an unresolved marker (the waiting row);
  3. a persisted observation (the held row, with its buttons);
  4. the dirty flag (the catch-up line).

  The first visit refines it (R2-F13b).

| Status | Journal copy | Intimate-log copy | Controls |
| --- | --- | --- | --- |
| `.heldByAnotherDevice` | "Your journal backup was saved from another iPhone. Backing up this iPhone would replace it." | "Your intimate log backup was saved from another iPhone. Backing up this iPhone would replace it." | "Restore it here", "Replace it with this iPhone's journal" / "…intimate logs" |
| Restore-it-here confirm | "Add the journal backup to this iPhone? Its entries are added here. If an entry was changed on both iPhones, you'll see both versions. Entries deleted since that backup was made may come back. After this, this iPhone backs up your journal, and your other iPhone will show that its backup was replaced." | "Add the intimate log backup to this iPhone? Its logs are added here. After this, this iPhone backs up your intimate logs, and your other iPhone will show that its backup was replaced." | "Restore" / "Cancel" |
| Replace confirm | "Replace the journal backup with this iPhone's journal? Entries that are only in the backup won't be in it anymore. If your other iPhone still has them, they stay on that iPhone." | "Replace the intimate log backup with this iPhone's logs? Logs that are only in the backup won't be in it anymore. If your other iPhone still has them, they stay on that iPhone." | "Replace" (destructive role) / "Cancel" |
| After any action tap | "Open Private to finish." (announced once) | same | none |
| `.waitingForRestore` (not yet attempted, or retryable) | "Your journal backup will be added to this iPhone the next time you open Private. New entries are backed up after that." | "Your intimate log backup will be added to this iPhone the next time you open Private. New logs are backed up after that." | none |
| `.waitingForRestore(.deferredKeyNotSynced)` | "Your journal backup is waiting for its key from iCloud Keychain. Make sure iCloud Keychain is on. New entries aren't backed up until it arrives." | the intimate-log equivalent | "Start a new backup" |
| `.waitingForRestore(.rolledBack)` | "The journal backup in iCloud is older than one this iPhone has already seen, so it wasn't added." | the intimate-log equivalent | "Restore anyway", "Replace it with this iPhone's journal" |
| `.waitingForBackupKey` | "Your journal backup is waiting for its key from iCloud Keychain. Make sure iCloud Keychain is on." | the intimate-log equivalent | "Start a new backup" |
| `.headSealedWithOtherKey` | "Your journal backup was saved with a key this iPhone doesn't have yet. It usually arrives through iCloud Keychain." | the intimate-log equivalent | "Start a new backup" |
| `.headDamaged` | "The journal backup in iCloud is damaged and can't be opened." | the intimate-log equivalent | "Start a new backup" |
| Start-new confirm | "Start a new journal backup from this iPhone? The current one can't be opened here. If another iPhone can still open it, it will be replaced. Only do this if you've reset iCloud Keychain, no longer have the iPhone that made it, or it's damaged." | the intimate-log equivalent | "Start new backup" (destructive role) / "Cancel" |
| `.needsNewerFernlet` | "Some journal entries or the journal backup need a newer version of Fernlet. Update Fernlet to keep backing up your journal." | the intimate-log equivalent | none |
| `.paused` | "Some journal entries can't be opened on this iPhone, so your journal backup is paused." | "Some intimate logs can't be opened on this iPhone, so your intimate log backup is paused." | "Remove them" → confirm: "Remove N entries this iPhone can't open? They'll be checked again first, and only entries that still can't be opened are removed. This can't be undone." |
| `.tooLarge` | "Your journal is too large for Sealed backup." | the intimate-log equivalent | none |
| `.failed` | "Your journal backup didn't finish. It will try again when you next open Private." | the intimate-log equivalent | none |
| Catch-up (dirty, marker resolved, no observation, not held, no other status) | "Your newest journal entries will be added to Sealed backup the next time you open Private." | "Your newest intimate logs will be added to Sealed backup the next time you open Private." | none (Q-B4) |
| Owner hold | unit 5's single "Your app lock was reset… Restore your Sealed backup?" row and "Restore" action covers all three kinds | | |

- **The catch-up line is true when shown** (R1-BR-14, R2-F13c). Every payload settles at every hub
  session, on any section. A successful export has no time spacing. A failed one shows `.failed` instead.
  - **Sync off, or this backup off:** no row. The switches speak for themselves (R2-F13d).
- **Turn-off confirmations** (new keys; R2-F3, R1-BR-10):
  - **slot own or unknown:** "Turn off Sealed backup for journal entries? This permanently deletes the journal
    backup from iCloud, for every iPhone that uses it. If you lose or replace this iPhone, your journal can't
    be recovered." Button "Turn off".
  - **slot observed as another iPhone's:** "Stop backing up this iPhone's journal? The journal backup saved
    from your other iPhone stays in iCloud." Button "Stop". No delete runs.
  - Intimate-log equivalents for both.
- **Delete-all dialog**: one added sentence, shown when any sealed backup switch is on: "Sealed backups in
  iCloud are deleted for every iPhone that uses them." (§12 item 2).
- **Retry.** The "Retry restore" condition (`PrivacyDataSettingsView.swift:1316-1323`) stops OR-ing in a v2
  payload's deferral flag: the intimacy half in B2 and the journal half in B3 (R2-F9).
- **Public-copy voice:** plain, "I" not "we" where a person speaks, no em dashes, and never "locked",
  "protected" or "secured" about the no-passcode state.

### 10.2 Localization
- Every new string goes in the app catalog (`App/Fernlet/Localizable.xcstrings`) through
  `String(localized:defaultValue:comment:)`, with dotted keys such as
  `privacy.sealedBackup.journal.heldByAnotherDevice`.
- Views take `LocalizedStringKey`, never `String`.
- Run `Scripts/sync-string-catalogs.sh`, then `--check`. **The catalog commit goes last in each unit**:
  another session holds uncommitted edits to the catalog in the primary checkout.
- **Frozen tokens** (`LocalizationBoundaryTests` canaries and `SealedBackupFormatPinTests`):
  - the six new defaults keys and the value grammars `"<acceptor>:<writer>:<generation>:<salt8>"`,
    `"<acceptor>:<writer>:<generation>"` and `"v1"`;
  - the envelope keys `v`, `writer`, `set`, `total`, `records`;
  - the suffix name form `chunk.<i>.<set>`;
  - the three records' coding keys (§5.1);
  - the payload raw values;
  - the new accessibility identifiers.

### 10.3 Accessibility
- Each status row is one element (`.accessibilityElement(children: .combine)`), using
  `fernletWrappingText`. Colour is never the only signal.
- Buttons are at least 44 pt (`fernletTapTarget`), with hints:
  - **Restore it here:** "Adds the backup's entries to this iPhone the next time you open Private."
  - **Replace:** "Backs up this iPhone over the backup in iCloud."
  - **Restore anyway:** "Adds the older backup's entries to this iPhone."
  - **Start a new backup:** "Replaces a backup this iPhone can't open."
  - **Remove them:** "Checks the entries again, then deletes those that still can't be opened."
- Destructive role on Replace, Start a new backup and Remove. "Open Private to finish." is announced once
  through `FernletAnnouncer` and never contains entry text.
- Identifiers: `privacy.sealedBackup.journal.heldByAnotherDevice`, `.restoreHere`, `.replace`,
  `.restoreAnyway`, `.startNew`, `.waitingForRestore`, `.waitingForBackupKey`, `.headSealedWithOtherKey`,
  `.headDamaged`, `.needsNewerFernlet`, `.paused`, `.removeUnopenable`, `.failed`, and the same set under
  `privacy.sealedBackup.intimacy.*`. The existing `privacy.sealedBackup.journalDeferred` and
  `intimacyDeferred` identifiers are kept for the catch-up line.

## 11. Invariants (each testable; test home in brackets)

| # | Invariant | Test home |
| --- | --- | --- |
| BV1 | One engine. Every v2 export reaches the chunk upload only through `SealedBackupV2Engine`. The grep pin is an **allowlist that shrinks per unit**: legacy `reconcileChunked` callers allowed for journal and intimacy until B3 and B2 delete them (R2-F9). The period envelope bytes are pinned | `SealedBackupV2EngineTests`, `SealedBackupFormatPinTests` |
| BV2 | Order: nothing is fetched, opened, decrypted or written unless G holds; then E1, then the owner hold, then E2, then E3. No head is opened before G | `SealedBackupV2EngineTests` (fake adapter, mock CloudKit, call log); a mutation moving G after E2 goes red |
| BV3 | G is re-checked after every await and immediately before every decrypt and local write. Flipping visibility, duress, hub lock or the epoch while a fake fetch is suspended means no `open`, merge, skeleton or chunk call happens (R1-BR-12) | `SealedBackupV2EngineTests`, `SealedBackupIntimacyV2Tests` |
| BV4 | E2: an export never replaces a head that is not own (v2 writer tag, or v1 signing key), accepted (install-bound) or explicitly replaced for exactly its stamp. A travelled accepted head reads as absent | `SealedBackupV2EngineTests` |
| BV5 | Prepare: every chunk is sealed before the first save. Any dead row pauses, any needs-newer row stops and any transient row fails, all with nothing written. A row moving from the hub key to the device key mid-export does not abort it (R1-BR-8) | `SealedBackupV2EngineTests`, `SealedBackupJournalV2Tests` |
| BV6 | Commit atomicity: cancelling or failing at any save before the head leaves the previous head and set restorable byte for byte. Two concurrent passes, with interleaved fake saves, leave one complete set, and the loser's verify fails (R1-BR-3, R2-F6) | `SealedBackupV2EngineTests` (mock CloudKit) |
| BV7 | Restore verification: chunks whose writer, set or salt differ from the head's, or whose total differs, fail closed. Mixed v1/v2 fails closed | `SealedBackupChunkTests` |
| BV8 | Generation: `g = max(lastSeen, accepted, head) + 1`; `lastSeen` moves only on a verified commit or an accepted restore. An aborted export leaves `lastSeen` unchanged (R1-BR-4) | `SealedBackupV2EngineTests`, `SealedBackupRollbackTests` |
| BV9 | Every journal and intimacy mutation path in §4.4 moves the epoch and sets the flag, without a keychain read. Nothing writes an enabled switch. The flag clears only after a verified commit with an unchanged epoch. During delete-all the flag is not set | `SealedBackupJournalV2Tests`, `SealedBackupIntimacyV2Tests`, `JournalSealingCoordinatorTests`, `DeleteAllDataTests` |
| BV10 | After a mutation and a hub session with G holding, the cloud set's ids equal the snapshot ids (journal: referenced sealed ids; intimacy: all ids) | mock-CloudKit end-to-end tests |
| BV11 | Journal merge: inserts absent ids with their stamps; never modifies an openable local row; forks a different text unless an equal one exists that day; replaces dead rows; defers on transient or needs-newer rows; never deletes; atomic; idempotent | `JournalNarrativeRepositoryTests` |
| BV12 | Intimacy merge: keep local, fill a missing link, replace dead rows, cap the note at 1 000, never drop a link; atomic; idempotent | `IntimacyLogRepositoryTests` |
| BV13 | The marker resolves only on `.restored`, `.nothingToRestore`, or a committed `replace` or `startNew`; **never** because sync or a backup is off. Clone end to end: a device-backup clone with a travelled `lastSeen`, accepted head and marker, the backup off at the first settle, then turned on → a merge restore runs and no head the clone did not write is replaced (R1-BR-2) | `SealedBackupRestoreTests` |
| BV14 | The marker is seeded once at `FernletStore.init` from the latch with its count backfill. An enabled backup is marked dirty in the same step. A later write never seeds | `SealedBackupRestoreTests` (injected defaults suite) |
| BV15 | Delete-all and reset: the worker is quiesced before leg 2. A restore or export suspended in a fake fetch and resumed after `deleteAllData`, or after the reset funnel, lands no row, skeleton, chunk, head or bookkeeping. After delete-all every deferral flag is false whatever the hooks did, and the marker and accepted head are kept. A scoped set is deleted completely | `DeleteAllDataTests`, `SealedBackupV2EngineTests` |
| BV16 | Owner hold: no restore of any trigger (Retry, Restore it here, ambient) runs while `restoreAwaitsOwner`. Only the owner-checked release clears it (R1-BR-15) | `SealedBackupRestoreTests`, `PrivacyDataSettings` view-model test |
| BV17 | Intimacy hidden (setting, under 16, duress): the probe, prepare, chunk, open and restore throw at `IntimacyLogStore`; nothing is decrypted; the switch, cloud copy, marker, accepted head, observation and dirty flag are untouched; no held, paused, waiting or catch-up row names intimacy | `SensitiveSurfaceGateTests`, `SealedBackupIntimacyV2Tests`, UI test |
| BV18 | Duress: no pass decrypts or writes for any kind, and no backup row or action is shown | `DuressDecoyAndWipeTests`, `SealedBackupV2EngineTests` |
| BV19 | The intimacy restore never writes HealthKit and the export never reads it | `SealedBackupIntimacyV2Tests` (spy HealthKit service) |
| BV20 | No engine path mints an escrow key before E2 has found no head for every enabled payload, except an explicit Start new. Every head open is `.forOpening` (R2-F1) | `SealedBackupV2EngineTests` (spy identity) |
| BV21 | The snapshot and restore write require `isStoreHealthy`. A storeless controller writes nothing to iCloud (R2-F2) | `SealedBackupV2EngineTests`, one per adapter |
| BV22 | Explicit actions decrypt nothing in Settings and persist nothing at tap time (except the owner release). Remove deletes only ids still dead and shown (R2-F12) | `SealedBackupV2EngineTests`, `JournalNarrativeRepositoryTests` |
| BV23 | Spacing: at most one automatic export, probe and ambient restore per payload per hub session; 15 minutes after a failure. Explicit actions and the follow-through skip it | `SealedBackupV2EngineTests` (injected clock) |
| BV24 | Every engine loop is bounded by a count fixed before it starts. Over 100 000 records or 64 MB prepared → `.tooLarge`, nothing written | `SealedBackupV2EngineTests`, `Scripts/power-of-10-scan.py` |
| BV25 | A journal restore adds a skeleton for every inserted, replaced or forked id the day lacks, and never edits one. A failed skeleton write leaves the marker unresolved (R1-BR-6) | `SealedBackupRestoreTests` |
| BV26 | An orphan sealed journal row is never exported | `SealedBackupJournalV2Tests` |
| BV27 | Turning off with a foreign observation deletes nothing. Delete-all deletes every enabled payload's set | `SealedBackupPayloadCoverageTests`, `DeleteAllDataTests` |
| BV28 | No new `CryptographicPurpose`; the registry pin stays 78 | `MeshRoutedItemSealTests`, `CryptographicDomainSeparationTests` |
| BV29 | Each new persisted key has its wipe row and manifest entry in the commit that adds it | `PersistedSurfaceWipeBoundaryTests`, `PrivacyWipeCoverageTests` |
| BV30 | Frozen tokens are unchanged (§10.2) | `LocalizationBoundaryTests`, `SealedBackupFormatPinTests` |

## 12. Consequences, stated plainly
1. **Backups follow deletions.** Once this iPhone has resolved its restore, deleting entries (all of them
   included) reaches the cloud copy at the next Private visit. That is period's answer, reused.
2. **One iPhone per slot, per kind (Q9 reused).** The journal, intimate-log and cycle slots are
   independent. The other phone shows "saved from another iPhone" and writes only after "Replace".
   - "Restore it here" then publishes the union, and that phone takes the slot.
   - **Deletions are not carried across**: entries deleted on one phone can come back through the other's
     backup on an explicit restore, and the confirmation says so.
   - Turning a backup off on the phone that does not own the slot keeps the other phone's backup.
   - **"Delete everything" deletes every enabled Sealed backup, whichever iPhone it came from, and the
     escrow key.** The key deletion reaches the other iPhone through iCloud Keychain. That was already true;
     the dialog now says it.
3. **The race between two iPhones is visible, not corrupting.** The head is still read-then-write, and the
   window is the whole export: the head fetch, the prepare and the uploads. Because each set writes its own
   chunk names and the head is the only commit point, the phone that loses keeps a complete set in the cloud
   (the winner's), fails its verify, and shows the held state at its next visit.
4. **Interrupted exports cost nothing.** Going offline, being killed or being cancelled before the head save
   leaves the previous backup restorable. The window that remains is a head save that landed with no reply
   (the verify catches it next session) and a failed prune (orphans, deleted by the next commit). Neither
   makes a backup unrestorable.
5. **A journal entry changed on both iPhones shows up twice after a restore**: once with each text. Nothing
   is overwritten on the strength of a timestamp.
6. **A new iPhone waits for its key.** Until iCloud Keychain delivers the escrow key, restores and exports
   wait, and no local key is minted while any backup exists in iCloud. Without iCloud Keychain the wait
   never ends. "Start a new backup" is the explicit, confirmed way out.
7. **The journal backs up at every Private visit**, any section, including entries written from Home and
   still under the device key. The fold remains for key custody.
8. **Restoring needs iCloud Keychain** across devices (period §9.10 item 1), unchanged.
9. **An entry whose day write failed** when it was first written, or when its delete failed (an orphan
   sealed row), is not in the backup. It is equally invisible on this iPhone today.
10. **Cost.** One full decrypt and seal per changed payload per visit, in yielded chunks. Clean visits
    usually decrypt nothing. The prepared set is held in memory up to 64 MB.
11. **Older builds** cannot read a v2 set (a retryable error, never a write) but can write a v1 set over it.
    The v2 phone then treats that set as its own by signing key, or as held.
12. **Transition.** An install whose `lastSeen` already holds a burned v1 generation may see one "older than
    one this iPhone has already seen". "Restore anyway" and "Replace" are both offered.

## 13. Staged implementation

Shared procedure for every unit:
- Build in a fresh worktree off the finished period branch, with its own `-derivedDataPath`. Never build in
  the primary checkout.
- New stored properties on package types (`IntimacyLogStore`, `CycleRecordStore`) need a **clean** build.
- Run suites one at a time, never the full suite. Check the exit code and that `Test case` lines appear.
- Run `Scripts/power-of-10-scan.py`, `Scripts/doc-coverage-scan.py`, `Scripts/spm-wall-check.sh` and
  `Scripts/sync-string-catalogs.sh --check`.
- Update the touched modules' DocC landing pages (CloudKitSync, PrivateMemoryStore, PrivateHealthStore, the
  app), `Docs/FileIndex.md` and `Docs/StoreRepositoryFunctionIndex.md`.
- The catalog commit goes last.
- `Docs/FernletSpecificationV3.md` has uncommitted edits by another session: merge them, never clobber.

### B0: the unit 5 brief amendment (no code here; hand it to the period workflow before unit 5 starts)
Unit 5 has not started, so this is the cheap moment (R2-F7). The amendment asks unit 5 to build its period
backup v2 **in the engine's shape**:
- `SealedBackupV2Engine`, `SealedBackupV2Adapter` and `SealedBackupBookkeeping` (§4.1 to §4.3), with
  `CycleRecordBackupAdapter` as the only adapter;
- `CycleRecordStore.withBackupSeam`, and `isStoreHealthy` on the store;
- the host epoch as the dirty witness (`markSealedBackupDirty(.periodData)` from every `CycleRecordStore`
  instance's hook);
- every §4.8 item;
- the §5 envelope, cloud layout, generation and E2 table;
- the period accepted head in the install-bound grammar, and the period observation key with its wipe row;
- the hold release on tap.

It also amends period I15 (the marker never resolves because sync or a backup is off), I16 (the prepare
replaces the pre-pass; chunks sealed before the first save), I29 (the host epoch) and I30 (writer-first;
signing key for v1).

**If unit 5 adopts B0 in full, B1 is empty.**

### B1: engine catch-up (conditional)
B1 covers only the B0 items unit 5 did not adopt. If unit 5 built period-shaped functions, B1 moves them
into the engine.
- **Gate:** period **assertions** unchanged; call sites and test helpers may be renamed (R2-F7). Every
  §4.8 item it lands carries its own period test.
- **Files:** `App/Fernlet/SealedBackupV2Engine.swift`, `SealedBackupV2Adapter.swift`,
  `SealedBackupBookkeeping.swift`, `CycleRecordBackupAdapter.swift` (new); `SealedBackupCoordinator.swift`,
  `SealedBackupService.swift`, `SealedBackupGenerationStore.swift`, `FernletStore.swift`, `ContentView.swift`;
  `FernletKit/Sources/CloudKitSync/CloudKitDataService.swift` (§5.2);
  `FernletKit/Sources/PrivateHealthStore/CycleRecordStore.swift`.
- **Tests:** `SealedBackupV2EngineTests` (BV1 to BV8, BV15, BV18, BV20, BV21, BV23, BV24),
  `SealedBackupChunkTests` (BV7), `SealedBackupRollbackTests` (BV8), `DeleteAllDataTests` (BV15, scoped
  delete), `SealedBackupFormatPinTests`.

### B2: intimate logs on v2
- **App:**
  - `IntimacyBackupAdapter.swift` (new);
  - `SealedBackupCoordinator.swift`: the intimacy enable, retry, adopt, launch arm, targeted restore and
    un-hide route to the engine. Deleted: the intimacy arms of `mayReuploadFromLocalStore` and
    `isEmptyStoreForRestore`, `reconcileIntimacyBackup`, and `resolvedIntimacyStore`'s per-call instances;
  - `ContentView.swift`: the store hook, and the adapter built over ContentView's instance;
  - `FernletStore.swift`: intimacy marker seeding and dirty seeding at init; the un-hide settle through the
    engine; the reset-funnel additions;
  - `PrivateHubOpenCoordinator.swift`: intimacy bookkeeping;
  - `PrivacyDataSettingsView.swift`: intimacy rows, turn-off confirmations, the **intimacy half of the Retry
    predicate** (R2-F9), and the visibility and duress guards.
- **FernletKit:** `IntimacyLogRepository` (`allIDs`, classified `logs(ids:)`, `upsertMerged`) and
  `IntimacyLogStore` (`allIDs`, `backupChunk`, `restoreMerging`, `withBackupSeam`, `attachMutationHook`).
- **Docs:** `Docs/PrivacyWipeCoverage.md` (three rows) and the manifest, in the same commit as the keys.
- **Tests:**
  - **Rewritten cases in `SealedBackupPayloadCoverageTests`:** `intimacyRestoreRefusesAPopulatedStore` →
    `intimacyRestoreMergesIntoAPopulatedStore`; `reuploadIsRefusedFromAnEmptyIntimacyStoreAndAllowedFromAPopulatedOne`
    → E1 and empty-after-resolution.
  - **New `SealedBackupIntimacyV2Tests`** (mock CloudKit): v1 restore, own v1 by signing key, two-phone
    held/Replace/Restore it here, merge, dirty from insert and mark-saved, hidden/under-16/duress at every
    seam with a suspended fetch (BV3, BV17), no HealthKit (BV19), delete-all and reset bookkeeping, un-hide.
  - `IntimacyLogRepositoryTests` (BV12); `SensitiveSurfaceGateTests` (gate, hook, the construction-site
    grep); `LocalizationBoundaryTests`; `PrivacyDataSettingsUITests` (held row; absent while hidden).
- **Risks:**
  - An unhooked instance. Covered by the construction-site grep and a test that writes through each instance.

### B3: journal on v2, and the doc sweep
- **App:**
  - `JournalBackupAdapter.swift` (new; §7.1 snapshot, §7.2 reads, merge, skeletons);
  - `JournalSealingCoordinator.swift` (`sealedJournalStoreDidChange` calls) and `JournalSealingContext`;
  - `FernletStore.swift`: the conformance, journal marker and dirty seeding, and `reinstateJournalEntries`'s
    `Bool` result;
  - `SealedBackupCoordinator.swift`: the journal arms route to the engine. `reconcileJournalBackup`, the
    journal arms of `mayReuploadFromLocalStore` and `isEmptyStoreForRestore`, and the launch arm are deleted;
  - `ContentView.swift`: the hub settle on any section, and the simplified `sealedBackupRestoresAfterRemoval`;
  - `PrivateHubOpenCoordinator.swift`: bookkeeping, and the device-key helper moved to a shared one;
  - `PrivacyDataSettingsView.swift`: journal rows, turn-off confirmations, the journal half of the Retry
    predicate, and the delete-all sentence.
- **FernletKit:** `JournalNarrativeRepository` (`allIDs`, `backupRecords(ids:hubKey:deviceKey:)`,
  `upsertMerged` with the stamp-preserving `apply`, `delete(ids:)` reuse; `insertAtomically` deleted).
- **Docs:**
  - `Docs/PrivacyWipeCoverage.md` (three rows, and the latch-row correction);
  - `Docs/Verifiability.md` (the "device-key journal rows" and "no-lock installs" gaps closed);
  - `Docs/FernletSpecificationV3.md`, § Encrypted Sealed Backup (merged with the other session's edits);
  - the period design's §12 "journal and intimacy keep today's model" note, marked superseded;
  - the PrivateMemoryStore landing page ("the latch blocks resurrection" becomes "the resolved marker");
  - the indexes.
- **Tests:**
  - **Rewritten:** the journal cases of `SealedBackupPayloadCoverageTests` (e.g.
    `journalEnableFromAnEmptyStoreDefersInsteadOfClobberingTheCloudBackup` → E1 first, empty after
    resolution), `SealedBackupRestoreTests`, and **`SealedBackupRestoreOutcomeTests.restoreOutcomeRecordsSkippedOnPopulatedStore`**
    (journal `.skippedStoreNotEmpty` no longer exists; it becomes a merge-into-populated case, R2-F16b).
  - **New `SealedBackupJournalV2Tests`:**
    - a Home device-key entry exports at the next visit on any section, without the fold;
    - an edit from Home during a suspended prepare does not abort it (BV5);
    - orphans are never exported (BV26);
    - dead rows pause; Remove re-classifies;
    - an unknown tag gives needs-newer, never dead;
    - merge into surviving device-key rows;
    - the same-id different-text fork (BV11);
    - restore marks dirty and the union exports;
    - duress (BV18);
    - a mutation mid-export keeps dirty;
    - over 100 000 → `.tooLarge`.
  - `JournalNarrativeRepositoryTests` (BV11, the classified read), `JournalSealingCoordinatorTests` (hooks),
    `PastDayJournalSealingTests` (scrub hook), UI test for the journal held row.
- **Risks:**
  - The journal is the most-written table. Watch main-actor time once on the owner's phone with Instruments.
  - The fork rule produces visible duplicates after two-phone edits; that is the owner question Q-B6.

## 14. Owner questions (the build proceeds on the recommended default)

1. **Q-B1 (reuses Q9): two iPhones, one slot per kind.** The journal backup and the intimate-log backup
   each belong to one iPhone at a time. The other shows "saved from another iPhone" and replaces it only if
   you choose. Turning the backup off on the iPhone that doesn't own it leaves the other iPhone's backup in
   iCloud. "Delete everything" still deletes every Sealed backup and the key that opens it, for both iPhones.
   Default: **yes, per kind**, with the delete-all dialog saying so.
2. **Q-B2 (reuses Q14): after an app-lock reset**, journal and intimate logs restore only after Face ID or
   the iPhone passcode in Privacy & Data, through the same single "Restore Sealed backup" action as cycle
   history. Retry never skips that. Default: **yes, one action for all three.**
3. **Q-B3: entries the backup can't open.** That backup pauses. "Remove them" checks the entries again when
   you next open Private and removes only those that still can't be opened. Entries that need a newer
   Fernlet are never removed. Default: **yes.**
4. **Q-B4: the "catch-up" line.** "Your newest journal entries will be added to Sealed backup the next time
   you open Private." It is shown only when that is true. Default: **yes.**
5. **Q-B5: how often.** Once per Private visit when something changed, on any section. After a failed
   attempt, wait 15 minutes. Default: **yes.**
6. **Q-B6: a journal entry changed on both iPhones.** When a restore brings in a different text for an entry
   this iPhone already has, keep both as separate entries. The alternative keeps only this iPhone's text and
   drops the other silently. Default: **keep both.**
7. **Q-B7: a backup this iPhone can never open** (iCloud Keychain off or reset, or the backup is damaged).
   Offer "Start a new backup", which replaces it after a clear warning. Nothing happens automatically.
   Default: **yes.**

## 15. Review resolution (revision 1 → 2)

Every finding was checked against `claude/r0930-period` at `08914578`; the tip `a270e3b9` has the same
backup files. Verdicts:
- **Confirmed:** the defect is real and the fix the finding suggests was adopted.
- **Confirmed, different fix:** the defect is real and is fixed another way, for the reason given.
- **Partly rebutted:** part of the suggestion was not adopted, with the evidence for keeping the design as it is.

| Finding | Verdict | What was verified | What changed |
| --- | --- | --- | --- |
| R1-BR-1 delete-all/reset race with an in-flight restore and follow-through export | Confirmed | Unowned settle Task (`ContentView.swift:1507-1513`). `stopWritersForWipe` cancels only the un-hide settles (`FernletStore.swift:5747-5764`). v1 was safe only because `applyRestoredChunks` re-checks `count == 0 && !latch` after the await (`SealedBackupCoordinator.swift:1381-1391`, `:1496-1512`) and re-reads the live key (`:1414`). Revision 1 dropped both and kept a captured key | §4.2 G re-checked after every await and before every decrypt and write, with the live hub key re-read. §4.7: one serial worker owned by the store; `deleteAllInProgress` drops work; the work epoch is moved by the wipe and the reset; the funnel awaits `quiesceForWipe()` before leg 2. BV15 covers restores and follow-through exports, resumed after `deleteAllData` and after reset |
| R1-BR-2 sync-off resolution; travelled `lastSeen`; clone overwrite | Confirmed; one sub-fix partly rebutted | Preferences are `AfterFirstUnlockThisDeviceOnly` with every switch off (`StoragePreferences.swift:114-128`, `:265`). `lastSeen` is in standard defaults (`Docs/PrivacyWipeCoverage.md:136`). Revision 1's seed was keyed on `lastSeen` | No resolution while sync or a backup is off (§4.3). v1 authorship by the AAD-bound device-only signing key (§5.5). Install-bound accepted head. Replace copy no longer claims the other iPhone exists (§10.1). Clone end-to-end test (BV13). **Not adopted:** resetting `lastSeen` in the §4.9 coordinator and the reset funnel. It no longer decides authorship; it is only the rollback floor, and a travelled floor can only refuse sets older than ones the source iPhone saw |
| R1-BR-3 same-generation sets interleave | Confirmed, plus a stronger fix | `sealedBackupChunks` compares only count and generation (`CloudKitDataService.swift:588-609`). AAD per record (`SealedBackupService.swift:138-146`) | `writer` and `set` in every chunk, with salt and total checks (§5.3). **Set-scoped suffix names** (§5.2), so interleaving is impossible and the loser keeps the winner's complete set. Serial worker. Post-commit head verify. §12 item 3 restates the window as the whole export |
| R1-BR-4 burned generations dead-end "Restore it here" | Confirmed | `mintNext` persists before the upload (`SealedBackupGenerationStore.swift:65-69`). The terminal `.rolledBack` (`SealedBackupCoordinator.swift:1287-1295`) | Generation computed, persisted only on commit (§5.4). "Restore it here" leaves the marker; a terminal outcome returns to held. "Restore anyway" and "Replace" are offered for `.rolledBack` |
| R1-BR-5 the newest text replaced by an older one | Confirmed, different fix | `apply` stamps `Date()` (`JournalNarrativeRepository.swift:648`), including via `insertAtomically` (`:288`). `seal` upserts (`:238-267`). The not-sealed branch (`FernletStore.swift:4018-4026`) | No last-writer-wins: keep local, add a different text as a separate entry unless an equal one exists that day (§7.3), with an idempotence proof. The confirmation names it. Q-B6 |
| R1-BR-6 orphan rows exported and resurrected | Confirmed | `deleteSealed` leaves an orphan (`JournalSealingCoordinator.swift:244-254`). `reinstateJournalEntries` adds every missing id (`FernletStore.swift:7235-7261`). Append orphans (`:3936-3943`) | Snapshot = sealed ids ∩ referenced skeleton ids (§7.1). A failed `didRestore` keeps the restore unresolved. Append orphans: decided, not exported (§12 item 9). Confirmation reworded |
| R1-BR-7 E2 could mint; `.headNotRecognized` lumps a missing key with corruption | Confirmed | `.forSealing` mints (`IdentityService.swift:881-907`) and is prepared first (`SealedBackupCoordinator.swift:434`). Mismatch vs malformed (`SealedBackupService.swift:166-169`) | See R2-F1 |
| R1-BR-8 an export aborted after its first chunk; Home edits make aborts routine | Confirmed | Lazy chunk between saves (`SealedBackupService.swift:314-331`). Device-key re-seal after deactivation (`FernletStore.swift:4018-4026`, `JournalSealingCoordinator.swift:159`) | Prepare then commit: every chunk sealed before the first save. The chunk read is total (hub, then device key; missing = deleted) (§7.2). Scoped names keep the old set intact. §12 item 4 states what remains |
| R1-BR-9 another phone's v1 set accepted as own | Confirmed | `recordAccepted` on every restore (`SealedBackupService.swift:418`) | Authorship never inferred from `lastSeen`. v1 uses the record's `signingPublicKey` (device-only key). **Not adopted:** "treat every v1 head as foreign plus a one-time merge". The signing key gives authenticated authorship with no resurrection trade-off |
| R1-BR-10 a vanished head never triggers a re-export | Confirmed | Record names are account-global (`CloudKitDataService.swift:844-854`) | No head while on and resolved → dirty, exported in the same pass (§4.2 X5). Turning off on a held phone keeps the other phone's backup. Confirmations name it |
| R1-BR-11 nothing triggers the first v2 export | Confirmed | v1 snapshots refreshed only on enable, retry, adopt and un-hide | Init seeding marks enabled backups dirty once (§4.3) |
| R1-BR-12 gates checked only before the network await | Confirmed | Fetch-then-open with no gate (`SealedBackupService.swift:385-404`). Duress flips visibility (`FernletStore.swift:1095-1112`) | G after every await and before every decrypt. `withOpenSeam`, with `IntimacyLogStore.withBackupSeam` putting the intimacy decrypt in the funnel (§8.1). BV3 suspended-fetch test |
| R1-BR-13 an own head shown as "another iPhone" | Confirmed | A save can land while the client sees a failure; the prune after the head can throw (`SealedBackupService.swift:324-332`) | Writer-first E2 (§5.5). Own heads are never shown as another iPhone's. Not adopted: "merge-restore an own head newer than remembered". Its content is this iPhone's own store at that moment, so merging could only bring back entries deleted since |
| R1-BR-14 the catch-up line promises a blocked backup | Confirmed | Revision 1's table had no `.waitingForRestore` row | `.waitingForRestore` rows per outcome. The catch-up line is shown only when the next visit can export (§10.1) |
| R1-BR-15 Retry skips the owner hold | Confirmed | `heldForOwner` returns false for `initiatedByUser` (`SealedBackupCoordinator.swift:1159-1160`). Retry passes `userInitiated: true` (`:785`, `:816-819`) | Retry is an ambient engine trigger. The hold stops every restore trigger; only the owner-checked release clears it. BV16 |
| R1-BR-16 folding before export is unnecessary | Confirmed, adopted | The fold only re-seals (`JournalNarrativeRepository.swift:478-508`). A device-key read without minting exists (`PrivateHubOpenCoordinator.swift:406-415`). Reset purges device-key rows too | Journal rows are read under the hub or device key (§7.2). Every payload settles at every hub session, any section (§4.5). `.waitingForFold` removed; the fold is custody only |
| R2-F1 head open could mint; the remedy deletes a valid backup | Confirmed | As R1-BR-7; turning off deletes by record name (`PrivacyDataSettingsView.swift:1803-1812`) | Every head open uses `.forOpening`; mint only when no enabled payload has a head, or on Start new (§5.6, BV20). New statuses `.waitingForBackupKey`, `.headSealedWithOtherKey`, `.headDamaged`; the escrow conflict defers to its banner. No copy points at the delete switch. WS-3 adopt marks dirty, and E2 treats own-signing heads sealed under a replaced key as own |
| R2-F2 a storeless controller exports an empty set | Confirmed; belt-and-braces partly rebutted | Load failure keeps an empty coordinator (`PrivatePersistenceController.swift:122-127`); `isStoreLoaded` (`:275`); `didFailToLoad` resets on heal | `isStoreHealthy` in G before the snapshot and every restore write (BV21). **Not adopted:** "refuse an empty export unless the in-memory epoch moved since the last export". The epoch does not survive a relaunch, so it would stall every real "delete all entries" that spans one. The direct check reads the coordinator's own store list |
| R2-F3 turning off deletes the other phone's slot | Confirmed | `PrivacyDataSettingsView.swift:1803-1815`; delete by record name (`SealedBackupCoordinator.swift:451-452`) | Turning off with a foreign observation keeps the cloud copy. Own or unknown deletes, with copy saying it is for every iPhone. Delete-all's reach is stated in §9, §12 and Q-B1, and in a new dialog sentence |
| R2-F4 resolution at the first Private open on a new iPhone | Confirmed | As R1-BR-2 | Same fix as R1-BR-2: no sync-off or backup-off resolution, so the restore is automatic whatever the order of the switches |
| R2-F5 terminal outcomes stuck behind E1; refetch every unlock | Confirmed | Period §9.10 keeps `.rolledBack` and `.notRecognized` unresolved | "Restore anyway", "Replace" and "Start a new backup" for terminal outcomes (§4.6). Waiting copy. Catch-up hidden while unresolved. Failed ambient restores back off 15 minutes (BV23). A mismatch is now a retryable wait (§5.6) |
| R2-F6 frequent full rewrites interrupted by lock or background | Confirmed, plus a stronger fix | The gate locks on disappear (`FernletLockGate.swift:204`, `:270-303`); in-place rewrite (`SealedBackupService.swift:301-333`) | Set-scoped names make an interruption harmless (§5.2). The commit runs inside `beginBackgroundTask`. Nothing is decrypted after the hub closes: the prepare aborts and the commit uploads ciphertext only (§4.7). BV6. §12 item 4 restated |
| R2-F7 reuse planned as extraction from unwritten code | Confirmed | Branch tip `a270e3b9` has no unit 5 commit; the worktree's uncommitted edits are unit 4 tests and docs; the backup files are identical to `08914578` | B0: the unit 5 brief amendment, so unit 5 builds the engine shape. B1 is conditional, with its gate relaxed to "period assertions unchanged, call sites may be renamed". The hold-release change is listed in §4.8 item 16 with a period test |
| R2-F8 the per-instance counter and the pre-pass mapping | Confirmed | `mutationCounter` per instance (`CycleRecordStore.swift:70-74`); `backupPrePass` takes its own snapshot without yielding (`:147-165`); `backupChunk(ids:)` already returns a classified page (`:174-178`) | The host epoch is the only witness (§4.4). The engine owns the snapshot; the period adapter is `allIDs()` plus `backupChunk(ids:)`; `backupPrePass` is not used |
| R2-F9 units cannot land green in order | Confirmed | Legacy `reconcileChunked` callers (`SealedBackupCoordinator.swift:676`, `:731`); the Retry predicate ORs the deferral flags (`PrivacyDataSettingsView.swift:1316-1323`) | BV1 is a shrinking allowlist. The probe is only for v2 payloads. The intimacy half of the Retry predicate moves to B2 |
| R2-F10 delete-all re-dirties intimacy | Confirmed | Flags cleared in leg 2 (`FernletStore.swift:5813-5815`); rows deleted in leg 3 (`:5867`) through ContentView's instance (`ContentView.swift:1598`); preferences reset last (`:5723`) | `markSealedBackupDirty` sets no flag while `deleteAllInProgress`. BV15 asserts every flag is false after the funnel. The reset purge fires no hooks (§9) |
| R2-F11 a set surviving a failed delete is shown as another iPhone's and offered back | Confirmed | `generationStore.reset` in delete-all (`FernletStore.swift:5821-5822`); revision 1 also cleared the accepted head there | The accepted head is kept by delete-all, so the next export overwrites the survivor. Writer-first E2 calls such a head own |
| R2-F12 Remove deletes a stale list; unknown tag counted dead | Confirmed | `decrypt` returns nil on an unknown tag (`JournalNarrativeRepository.swift:655-660`) while `classify` counts it openable (`:615-629`); the §4.9 coordinator re-surveys before deleting (`PrivateHubOpenCoordinator.swift:191-193`) | Remove is an intent re-classified at the next settle; it deletes only ids still dead and shown. Unknown tags and undecodable plaintext count as needs-newer, never dead. Copy drops "No one can open them" |
| R2-F13 copy accuracy | Confirmed | Revision 1 §10.1 | (a) every payload settles at every hub session, so "next time you open Private" is true; (b) observed head persisted (§4.3); (c) catch-up shown only when true; (d) sync off and backup off show no row; (e) the Restore-it-here confirmation says this iPhone takes over the slot |
| R2-F14 a keychain read on every write; early writers lost | Confirmed | `currentPreferences()` reads and decodes the keychain (`StoragePreferences.swift:423-431`) | No preferences read; the flag is set unconditionally; attaching the hook re-persists; one shared payload-to-switch helper (§4.4) |
| R2-F15 no single-flight | Confirmed | Un-hide settle (`FernletStore.swift:1230-1244`) and the Cycle settle both drive intimacy | One serial worker for every payload and trigger (§4.2). §12 item 3 restated |
| R2-F16 testability and reuse | Confirmed (a, b, c, e); (d) partly rebutted | `SealedBackupRestoreHold(defaults:)` precedent; `SealedBackupRestoreOutcomeTests.swift:69` pins journal `.skippedStoreNotEmpty`; the existing "unavailable while … turned off" line (`PrivacyDataSettingsView.swift:755`) | `SealedBackupBookkeeping(defaults:)`. The outcome test is added to B3's rewrite list. BV17 reworded to "no held, paused, waiting or catch-up row". One literal `set` per switch arm. **(d) not adopted:** the photo route persists its mint before the upload, which is the burn R1-BR-4 objects to; the chunked route computes and persists on commit, and set ids cover the reuse case (§5.4) |
