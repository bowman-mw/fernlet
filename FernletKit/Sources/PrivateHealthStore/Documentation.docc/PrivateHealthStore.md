# ``PrivateHealthStore``

The sealed (S3) cycle and intimacy store — the layer-3 module where menstrual-cycle and
intimate-activity data is read, written, encrypted at rest, and gated behind the hide/lock
privacy seams.

## Overview

PrivateHealthStore owns Fernlet's most sensitive health data and the discipline around it. Every
cycle event is split across two stores by design: the clinical facts (flow level, basal body
temperature, cervical mucus, ovulation tests, cycle-start and intermenstrual-bleeding flags) are
written to HealthKit as ordinary samples, while everything Fernlet adds on top — free-text notes,
symptom flags, custom symptom scales, intimacy notes — is sealed into the local-only private
Core Data store (`PrivatePersistenceController` in `PrivateStoreCore`) as ChaChaPoly ciphertext
columns. The two halves are joined by a plaintext `hkExternalUUID` column that matches the
`HKMetadataKeyExternalUUID` stamped onto the samples. HealthKit holds the clinical record; this
module holds the narrative, and the narrative never syncs anywhere.

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
joins HealthKit samples with sealed narratives into per-day ``CycleDayEntry`` values, publishes
today's ``CyclePhase`` and a ``CyclePrediction``, and routes writes; ``IntimacyLogStore`` plays
the same role for intimacy notes. Both carry the module's load-bearing invariant: `isVisible`, a
lazily-read, fail-closed (`{ false }` by default) closure gate enforced **at the decrypt/seal
seam, not in view code**. While hidden, the stores are inert — reads return nothing and decrypt
nothing (``PeriodTrackerStore/loadEntries(unlockedContentKey:)`` refuses *before* the HealthKit
read, because unencrypted flow samples are the larger exposure, and scrubs resident plaintext on
the way out), and writes throw ``PeriodTrackingHiddenError`` / ``IntimacyTrackingHiddenError``.
Deletes are deliberately ungated: hiding must never block "delete my data." The same split holds
on the HealthKit side since 2026-09-23: the gateway refuses a cycle-sample WRITE while Fernlet's
Health sharing for cycle tracking is off, but lets Fernlet delete its own samples. Because an edit
is delete-then-recreate, ``PeriodTrackerStore/editEvent(_:replacingEntry:unlockedContentKey:)``
asks ``PeriodHealthKitServicing/checkPeriodEventWriteAllowed(_:)`` BEFORE it deletes anything —
the visibility gate's rule ("never delete what you cannot rewrite") applied to the sharing gate,
and since 2026-09-30 to Apple Health's own share grant for each type the rewrite writes. The read
seam, ``PeriodHealthKitServicing/loadPeriodEvents(in:)``, answers empty where nothing is readable
(no Health, or a type Fernlet was never asked to read), so sealed note-only entries still load
with cycle sharing off.

Orthogonal to visibility is the **content key**, supplied per call by `FernletLockService` and
never retained here. The repositories — ``MenstrualNarrativeRepository`` and
``IntimacyLogRepository`` — derive per-column subkeys from it via `ColumnCrypto` (HKDF labels
`"menstrual-narrative"` and `"intimacy-log"`), fail closed on writes (`FernletLockError.locked`),
degrade reads to empty results without a key, skip rows whose ciphertext fails to authenticate,
and best-effort prune Core Data persistent history after every mutation so superseded ciphertext
does not linger in the transaction log. Their keyless `deleteAll()` sweeps route through
`PrivateStoreCore`'s shared `PrivateRowPlumbing.deleteRows` sequence, whose history prune is
rethrown rather than best-effort — removing the ciphertext from the log is part of a delete's
promise. When a narrative is logged *while the Private tab is closed* — with or without a passcode
— it detours through the device-key `PendingNarrativeBuffer` (via ``PeriodLockContext``) and is
re-sealed the next time the tab opens by ``PeriodTrackerStore/drainPendingBuffer(contentKey:)`` —
which is itself visibility-gated, because the buffer's device key is invisible to content-key
withholding. Nothing is ever dropped (period-data design 2026-09-30, §6.3): the seam no longer asks
whether a passcode exists, because every install now has a hub key to drain into (opened by a
passcode or by the no-passcode tap), so ``PeriodLogResult`` has no "dropped" case and a buffer that
refuses, or a store with no seam wired, throws instead.
``MenstrualNarrativeRepository`` and — since the 2026-08-10 backup-coverage work —
``IntimacyLogRepository`` each own a one-way "ever stored" divergence latch (device-local,
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

**Sealed cycle records (period-data design 2026-09-30, §5–§6; landed inert).** The cycle history is
moving from "clinical facts in HealthKit, narrative here" to one self-contained ``CycleRecord`` per
entry, sealed as ONE blob in the `CycleRecord` entity: the day, a clinical block and a narrative block
(each `nil` = UNKNOWN, present-but-empty = "none"), no plaintext date, day key or HealthKit id beside
it. Its Codable is a frozen, tolerant at-rest format (`"v": 2`; enums as raw values; dates as seconds
since 2001) shared by the sealed column, the pending buffer's v2 payload and the backup chunks.
``CycleRecord/merged(_:_:)`` is the one merge rule every path uses — each block taken WHOLE by its
clock, so a flag the user cleared never returns from an older copy and a temperature always travels
with its unit; commutative, idempotent and associative. ``CycleRecordRepository`` is the sealed CRUD
under `FernletCryptoPurpose.KeyDerivation.cycleRecordV1`, with ONE write path,
``CycleRecordRepository/upsertMerged(_:retiringNarrativeIDs:contentKey:)`` (insert absent ids, merge
openable ones, replace dead ones, refuse the whole call over an undecided row, retire legacy narratives
in the same save), a post-decrypt id check (the AAD does not bind the row id, so a moved blob is dead),
classified pages, keyless count/ids/deletes, and a 20 000-record bound. ``CycleRecordStore`` is its
gated `@MainActor` funnel with the same inert-while-hidden contract as ``IntimacyLogStore`` plus a
mutation hook and counter for the backup's dirty flag. Its sealed-backup seam (pre-pass, chunk,
restore) never answers empty for want of a key either: visible but keyless, each throws
`FernletLockError.locked`, because an empty chunk is a legitimate "deleted mid-export" answer and a
keyless one must not look like it. Nothing reads records yet: the app constructs a
store only for the keyless count and delete (the "entries this iPhone can't open" check and "Delete
everything"); the cutover makes records the source of truth.

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
format for the `symptomFlagsCiphertext` column — and they are also the KEYS of
`customSymptomScalesCiphertext` — and both are read back with
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
- ``PeriodLogResult``
- ``PeriodTrackingHiddenError``

### Sealed Cycle Narratives

- ``MenstrualNarrative``
- ``MenstrualNarrativeRepository``

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
- ``PeriodLockContext``
