# ``PrivateHealthStore``

The sealed (S3) cycle and intimacy store — the layer-3 module where menstrual-cycle and
intimate-activity data is read, written, encrypted at rest, and gated behind the hide/lock
privacy seams.

## Overview

PrivateHealthStore owns Fernlet's most sensitive health data and the discipline around it. **Since
the cutover (period-data design 2026-09-30, unit 4) every cycle entry is ONE sealed ``CycleRecord``**
— the day, a clinical block (flow level, basal body temperature with its unit, cervical mucus,
ovulation test, cycle-start and intermenstrual-bleeding flags) and a narrative block (note, symptom
flags, custom symptom scales) — stored as one ChaChaPoly blob in the local-only private Core Data
store (`PrivatePersistenceController` in `PrivateStoreCore`). That record is the source of truth in
both passcode modes and whatever the Health switches say (the owner's Option B). Apple Health is an
optional MIRROR: a copy of the clinical block is written only while the user's cycle sharing is on,
every sample stamped with the record id twice (`HKMetadataKeyExternalUUID` and the frozen
``FernletCycleRecordMirror/recordIDKey``, `"FernletCycleRecordID"`). Intimacy notes stay in their own
sealed table. Nothing here ever syncs.

On the S3 wall, this module sits firmly on the **protected side**. Its `Package.swift` entry
depends only downward (`PrivateStoreCore`, `FernletCrypto`, `FernletFoundation`,
`FernletDomainModel`), and the walled `AIProviders` and `CloudKitSync` targets have no dependency
edge to it — `import PrivateHealthStore` from either is a hard build error under
`DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR`. That is also why the RAW cycle vocabulary
(``CyclePhase``, ``PeriodFlowLevel``, ``CycleDayEntry``, ``PeriodSymptom``, …) is declared here
rather than in `FernletDomainModel`: `AIProviders` imports the domain model, so exposing the raw
types there would defeat the abstraction. The one sanctioned egress is the `PeriodContextBridge`
module (layer 4), which converts phases and predictions into the abstract period signals the
scoring layer consumes. Beyond the bridge, the modules that *are* allowed to depend on this one are the platform
gateways: `HealthKitGateway` (whose `HealthKitService` conforms to the
``PeriodHealthKitServicing`` seam declared here) and `FernletLock` (whose `FernletLockService`
conforms to ``PeriodLockContext``). Both seams are owned by this module precisely so it never
names those modules back — all edges point inward.

Two `@MainActor` stores are the only sanctioned funnels. ``PeriodTrackerStore`` (observable)
publishes per-day ``CycleDayEntry`` values — Fernlet's records for the day plus Apple Health's
samples for it, read-only, split into Fernlet's own copies with no record here
(``CycleDayEntry/fernletHealthSamples``) and other apps' (``CycleDayEntry/otherHealthSamples``) — with
today's ``CyclePhase`` and a ``CyclePrediction``, and routes every write; ``IntimacyLogStore`` plays the
same role for intimacy notes. Both carry the module's load-bearing invariant: `isVisible`, a
lazily-read, fail-closed (`{ false }` by default) closure gate enforced **at the decrypt/seal seam,
not in view code**, and the period store installs the SAME gate on the ``CycleRecordStore`` it
composes. While hidden, the stores are inert — reads return nothing and decrypt nothing
(``PeriodTrackerStore/loadEntries(unlockedContentKey:)`` refuses *before* the Health read, because
the samples are the larger exposure, and scrubs resident plaintext on the way out), and writes, the
drain and the legacy import throw ``PeriodTrackingHiddenError`` / no-op. Deletes are deliberately
ungated: hiding must never block "delete my data."

The write paths (§6.3). **Save** seals FIRST — ``CycleRecordStore/insert(_:contentKey:)`` with the hub
key, or the pending buffer while the Private tab is closed (either passcode mode; nothing is ever
dropped) — and only then mirrors to Apple Health through ``PeriodHealthKitServicing`` while cycle
sharing is on; a Health refusal is reported in ``PeriodLogOutcome`` and the entry stays saved, and a
seal or buffer failure throws with no Health call. **Edit** (``PeriodTrackerStore/editRecord(_:with:unlockedContentKey:)``)
updates the record IN PLACE under the same id — the delete-then-recreate hazard of the old
two-store split is gone — then deletes and rewrites Fernlet's mirror with sharing on, or removes
Fernlet's older copy with sharing off (owner question Q1; ``PeriodLogOutcome/HealthCopy/removedStaleCopy``
only when a sample was really deleted). An edit that leaves an UNKNOWN block empty leaves it unknown,
and an edit (or an emptied edit, ``PeriodTrackerStore/deleteRecord(_:)``) of a record whose stored
clinical block is unknown never deletes from Apple Health: Fernlet never mirrored such a record, so
every Fernlet sample carrying its id is that block's not-yet-imported source, not a stale copy.
**Delete** (``PeriodTrackerStore/deleteDay(_:)``) removes Fernlet's rows FIRST, keyless, then its
Health copies; Health refusing is ``PeriodDeleteOutcome/HealthCopy/stillInHealth(_:)``, never a throw
that would make a day undeletable in Fernlet. The mirror delete reports the sample kinds Apple Health
refused (``CycleMirrorDeletion``, ``CycleMirrorSampleKind``) instead of throwing them, because HealthKit
says "denied" both for access never granted and for access taken away after a copy was written; a
refusal is reported only for a kind the record's copy could hold, and — unless the record was built
from Fernlet's own Health samples — only while cycle sharing is on. The record's origin is what says
"built from Fernlet's own Health samples", so it follows the clinical block once that block is known:
a flow the user adds to a legacy note-only day makes the record `logged`, and a note-only record that
fill-on-read, the import or "Keep in Fernlet" completes from its samples takes that block's origin. With sharing on an edit's rewrite
is always attempted after a refusal, so a partial grant never silently removes the day. A day holding only Fernlet's Health copies offers "Keep
in Fernlet" (``PeriodTrackerStore/keepHealthOnlyDay(_:contentKey:)``) and "Delete from Apple Health".
**Load** reads Health only while the cycle capability is on, rechecks visibility and the live key
after that await, completes a record whose clinical block is unknown from its own Fernlet samples
(fill-on-read), and hides a Fernlet sample group only when its record's clinical block is known.
**The legacy import** (``PeriodTrackerStore/runLegacyImportIfNeeded(contentKey:)``, §8) moves the
pre-cutover history into records in two separately tracked halves (``CycleLegacyImportLedger``): every
openable ``MenstrualNarrative`` becomes a narrative-only record under its legacy external id, retired
in the same save; Fernlet's own UNMARKED Health samples become clinical-only records — only once
every cycle type has been asked about, through a read that throws rather than answering an empty "not
asked". Ids are deterministic (``CycleLegacyIdentity``) and every write is ``CycleRecord/merged(_:_:)``,
so the halves, the drain and the Sealed backup restore commute and re-running changes nothing — a
v1 backup's narrative becomes the same narrative-only record (``CycleRecord/init(legacyNarrative:origin:)``,
origin `restored`) as the import's. A narrative that will not open is left, named on the Cycle page's card, and removed only on
its tap. Every write that follows an await rechecks the writer epoch, which "Delete everything" moves
(``PeriodTrackerStore/cancelBackgroundWriters()``), and the wipe and the app-lock reset set both import
halves done.

Orthogonal to visibility is the **content key**, supplied per call by `FernletLockService` and
never retained here. The repositories — ``CycleRecordRepository``, the legacy
``MenstrualNarrativeRepository`` and ``IntimacyLogRepository`` — derive per-column subkeys from it via
`ColumnCrypto`, fail closed on writes (`FernletLockError.locked`),
degrade reads to empty results without a key, skip rows whose ciphertext fails to authenticate,
and best-effort prune Core Data persistent history after every mutation so superseded ciphertext
does not linger in the transaction log. Their keyless `deleteAll()` sweeps route through
`PrivateStoreCore`'s shared `PrivateRowPlumbing.deleteRows` sequence, whose history prune is
rethrown rather than best-effort — removing the ciphertext from the log is part of a delete's
promise. When an entry is logged *while the Private tab is closed* — with or without a passcode —
the whole record detours through the device-key `PendingNarrativeBuffer` (via ``PeriodLockContext``,
as a v2 payload) and is sealed the next time the tab opens by
``PeriodTrackerStore/drainPendingBuffer(contentKey:)`` — one merge write, so a partial drain re-drains
without duplicates, and a v1 narrative payload from before the cutover becomes a narrative-only record
under its legacy id. The drain is itself visibility-gated, because the buffer's device key is
invisible to content-key withholding. Nothing is ever dropped (§6.3): a buffer that refuses, or a
store with no seam wired, throws instead.
``MenstrualNarrativeRepository`` and — since the 2026-08-10 backup-coverage work —
``IntimacyLogRepository`` each own a one-way "ever stored" divergence latch (the cycle one no longer
gates any restore since the period backup v2: it is read once, as the seed of the app's period restore
marker, and kept for the legacy reader) (device-local,
non-synced `UserDefaults`, injected so tests get isolation) plus the paged/atomic
fetch-and-restore surface the app-side `SealedBackupCoordinator` uses: a keyless row count, a
paged reader in a *total* order (`dateKey`/`eventDate` then the unique id, so successive export
chunks never overlap or skip), and an all-or-nothing `insertAtomically`. Every mutation — deletes
included — sets the latch, so a sealed-backup restore can never resurrect rows the user
deliberately deleted, and the latch deliberately survives "delete everything" so the wipe cannot
be undone by a stale cloud copy. `clearDivergenceLatch()` (on both repositories, and ungated on
``IntimacyLogStore``) is the one way back, for when the key the rows spoke for is provably gone: the
app's "entries this iPhone can't open" check and its app-lock reset funnel (period-data design
2026-09-30, §4.9, §9.21).

**Sealed cycle records (period-data design 2026-09-30, §5–§6).** Each entry is one self-contained
``CycleRecord``, sealed as ONE blob in the `CycleRecord` entity: the day, a clinical block and a narrative block
(each `nil` = UNKNOWN, present-but-empty = "none"), no plaintext date, day key or HealthKit id beside
it. Its Codable is a frozen, tolerant at-rest format (`"v": 2`; enums as raw values; dates as seconds
since 2001) shared by the sealed column, the pending buffer's v2 payload and the backup chunks.
``CycleRecord/merged(_:_:)`` is the one merge rule every path uses — each block taken WHOLE by its
clock, so a flag the user cleared never returns from an older copy and a temperature always travels
with its unit; commutative, idempotent and associative. Its origin is the copy that speaks most
strongly for the clinical block (`CycleRecord.combinedOrigin(_:_:)`): a block built from Fernlet's
Health samples first, then any known block over an unknown one, else the stored copy's. ``CycleRecordRepository`` is the sealed CRUD
under `FernletCryptoPurpose.KeyDerivation.cycleRecordV1`, with ONE write path,
``CycleRecordRepository/upsertMerged(_:retiringNarrativeIDs:contentKey:)`` (insert absent ids, merge
openable ones, replace dead ones, refuse the whole call over an undecided row, retire legacy narratives
in the same save), a post-decrypt id check (the AAD does not bind the row id, so a moved blob is dead),
classified pages, keyless count/ids/deletes, and a 20 000-record bound. ``CycleRecordStore`` is its
gated `@MainActor` funnel with the same inert-while-hidden contract as ``IntimacyLogStore`` plus a
mutation hook and counter for the backup's dirty flag. Its sealed-backup seam (pre-pass, chunk,
restore) never answers empty for want of a key either: visible but keyless, each throws
`FernletLockError.locked`, because an empty chunk is a legitimate "deleted mid-export" answer and a
keyless one must not look like it. ``PeriodTrackerStore`` composes one (public as
``PeriodTrackerStore/recordStore``, where the app installs the backup's mutation hook); the app also
constructs one for the keyless count and delete, and its `SealedBackupCoordinator` one for the period
backup — the Sealed backup v2 engine's period adapter (journal and intimacy Sealed backup v2 design
2026-09-30, §4.1): its snapshot is ``CycleRecordStore/allIDs()``, its chunks
``CycleRecordStore/backupChunk(ids:contentKey:)``, its restore
``CycleRecordStore/restoreMerging(_:contentKey:)`` (an id-keyed merge that never deletes or regresses
an openable record), and every decrypt of a period BACKUP chunk runs inside
``CycleRecordStore/withBackupSeam(_:)``, so the gate check and the decrypt are one synchronous step.
``CycleRecordStore/isStoreHealthy`` (the sealed store is attached) is one of the engine's gates: a
controller whose store failed to load can never export an empty set over the cloud copy. The engine
owns the snapshot and the prepare; ``CycleRecordStore/backupPrePass(contentKey:)`` is not on its path.

The intimacy backup still goes through ``IntimacyLogStore``, never the raw repository — the app
target is grep-walled against constructing ``IntimacyLogRepository`` so no call site can read or
write around the hard gate. The funnel's sealed-backup seam splits gating per member: the row count
and the latch are UNGATED (they decrypt nothing, and a hidden store reading as "empty" would let a
restore write in behind the gate), while the paged export and the restore insert are GATED and
throw rather than degrading to `[]` — a silently-empty export would replace the user's cloud backup
with nothing. Above that, the coordinator skips the payload entirely while hidden: a hidden
reconcile is a silent no-op, never a preference flip, because turning the preference off would
delete the iCloud backup and make hiding destructive.

One invariant *inside* those sealed columns is easy to mistake for a display concern, and it is
the most destructive thing on this page to get wrong. ``PeriodSymptom``'s raw values ARE the storage
format for a record's narrative block (and for the legacy `symptomFlagsCiphertext` column) — and they
are also the KEYS of its custom symptom scales — and both are read back with
`compactMap(PeriodSymptom.init(rawValue:))`, which silently DROPS whatever it cannot parse. Unlike
the day blob, this path has no `EnumDecodeCompat` freeze/park channel, and deliberately so:
parking an unrecognized token means persisting it somewhere the app can read it later, and the whole
reason this column is sealed is that a symptom name is exactly the kind of plaintext that must not
sit beside the ciphertext. Lossy-but-sealed is the chosen trade, and the token freeze is what makes
it safe. So renaming, re-spelling, or **localizing** a case does not throw, does not log, and raises
no "some data could not be read" banner — it makes every symptom the user ever logged disappear from
her encrypted cycle history, permanently and unrecoverably, with the ciphertext still on disk
holding values nothing can name any more. ``PeriodSymptom/title`` is the display half; the raw value
is frozen English forever. ``PeriodTrackerStore/drainPendingBuffer(contentKey:)`` decodes the
locked-path buffer through the same lossy `compactMap`, so it is bound by the same freeze.
`Tests/FernletTests/LocalizationBoundaryTests` pins the nine literal raw values as a canary; this
page did not state the invariant at all until 2026-08-20, so a localization pass that read only the
landing page would have had nothing here to stop it.

Prediction is pure computation layered on top: ``CyclePredictionEngine`` is a stateless,
`nonisolated` fitter that detects periods from observed flow days, rejects implausible or
suspected-missed-log intervals, and blends a recency-weighted median with an EWMA into a
``CyclePrediction`` plus a day-by-day ``PredictedFlowDay`` forecast. It runs only downstream of
both gates (a keyless or hidden load produces no prediction), and it degrades to `nil` rather
than guessing when history is thin.

Concurrency: the target builds with `defaultIsolation(MainActor.self)` because the two stores are
`@MainActor` (``PeriodTrackerStore`` is `@Observable`). Everything else opts out — the value
types, enums, seam-adjacent DTOs, and the two repositories are explicitly `nonisolated` (the
repositories serialize all Core Data access through `performAndWait` on the view context — whose
closure is `@Sendable`, which is why the repositories are `Sendable`: all-`let` state, the
SDK-`Sendable` context, and the thread-safe `UserDefaults` latch, `@unchecked` only for that last
un-annotated Foundation type, and why ``MenstrualNarrative``/``IntimacyLog`` are `Sendable` value
types), and the prediction engine is `nonisolated` pure math callable from any executor.

## Topics

### Cycle Tracking

- ``PeriodTrackerStore``
- ``CycleDayEntry``
- ``UserLoggedCycleEvent``
- ``PeriodLogOutcome``
- ``PeriodDeleteOutcome``
- ``PeriodTrackingHiddenError``
- ``CycleHealthSamples``
- ``FernletCycleRecordMirror``
- ``CycleMirrorDeletion``
- ``CycleMirrorSampleKind``

### The Legacy Import

- ``CycleLegacyImportLedger``
- ``CycleLegacyIdentity``

### Sealed Cycle Narratives (legacy)

- ``MenstrualNarrative``
- ``MenstrualNarrativeRepository``
- ``MenstrualNarrativeClassification``

### Sealed Cycle Records

- ``CycleRecord``
- ``CycleClinicalFields``
- ``CycleNarrativeFields``
- ``CycleRecordOrigin``
- ``CycleRecordDecodingError``
- ``CycleRecordRepository``
- ``CycleRecordPage``
- ``CycleRecordUpsertResult``
- ``CycleRecordRepositoryError``
- ``CycleRecordStore``
- ``CycleRecordBackupPrePass``

### Intimacy Logs

- ``IntimacyLogStore``
- ``IntimacyLog``
- ``IntimacyLogRepository``
- ``IntimacyTrackingHiddenError``

### Cycle Prediction

- ``CyclePredictionEngine``
- ``CyclePrediction``
- ``PredictedFlowDay``
- ``PredictedFlowLevel``

### Raw Cycle Vocabulary

Raw values in this section are storage and HealthKit-correlation tokens, not copy. ``PeriodSymptom``
in particular is FROZEN — see the sealed-column note in the Overview before touching it.

- ``CyclePhase``
- ``PeriodFlowLevel``
- ``PeriodSymptom``
- ``PeriodTemperatureUnit``
- ``CervicalMucusQuality``
- ``OvulationTestResult``

### Seams to Neighboring Modules

- ``PeriodHealthKitServicing``
- ``PeriodHealthCopyErrorClassifying``
- ``PeriodLockContext``
