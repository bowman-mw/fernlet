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
Deletes are deliberately ungated: hiding must never block "delete my data."

Orthogonal to visibility is the **content key**, supplied per call by `FernletLockService` and
never retained here. The repositories — ``MenstrualNarrativeRepository`` and
``IntimacyLogRepository`` — derive per-column subkeys from it via `ColumnCrypto` (HKDF labels
`"menstrual-narrative"` and `"intimacy-log"`), fail closed on writes (`FernletLockError.locked`),
degrade reads to empty results without a key, skip rows whose ciphertext fails to authenticate,
and best-effort prune Core Data persistent history after every mutation so superseded ciphertext
does not linger in the transaction log. Their keyless `deleteAll()` sweeps route through
`PrivateStoreCore`'s shared `PrivateRowPlumbing.deleteRows` sequence, whose history prune is
rethrown rather than best-effort — removing the ciphertext from the log is part of a delete's
promise. When a narrative is logged *while locked*, it detours through the device-key
`PendingNarrativeBuffer` (via ``PeriodLockContext``) and is re-sealed on
the next unlock by ``PeriodTrackerStore/drainPendingBuffer(contentKey:)`` — which is itself
visibility-gated, because the buffer's device key is invisible to content-key withholding.
``MenstrualNarrativeRepository`` additionally owns the one-way "ever stored" divergence latch and
the paged/atomic fetch-and-restore surface the app-side `SealedBackupCoordinator` uses, so a
sealed-backup restore can never resurrect narratives the user deliberately deleted.

Prediction is pure computation layered on top: ``CyclePredictionEngine`` is a stateless,
`nonisolated` fitter that detects periods from observed flow days, rejects implausible or
suspected-missed-log intervals, and blends a recency-weighted median with an EWMA into a
``CyclePrediction`` plus a day-by-day ``PredictedFlowDay`` forecast. It runs only downstream of
both gates (a keyless or hidden load produces no prediction), and it degrades to `nil` rather
than guessing when history is thin.

Concurrency: the target builds with `defaultIsolation(MainActor.self)` because the two stores are
`@MainActor` (``PeriodTrackerStore`` is `@Observable`). Everything else opts out — the value
types, enums, seam-adjacent DTOs, and the two repositories are explicitly `nonisolated` (the
repositories serialize all Core Data access through `performAndWait` on the view context), and
the prediction engine is `nonisolated` pure math callable from any executor.

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

- ``CyclePhase``
- ``PeriodFlowLevel``
- ``PeriodSymptom``
- ``PeriodTemperatureUnit``
- ``CervicalMucusQuality``
- ``OvulationTestResult``

### Seams to Neighboring Modules

- ``PeriodHealthKitServicing``
- ``PeriodLockContext``
