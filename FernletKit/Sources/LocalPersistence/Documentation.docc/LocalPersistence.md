# ``LocalPersistence``

The Foundation-only persistence layer: the local JSON repository, the shared `LocalFernletDatabase` aggregate both backends serialize, and the deterministic derived-table, derived-signal, and Tier-2 memory engines.

## Overview

`LocalPersistence` is a layer-2 module in the FernletKit package. It owns three tightly coupled things: the ``LocalFernletDatabase`` aggregate — the single Codable blob that holds every diary slice (day history, settings, aggregate lists, derived log tables, Tier-2 memories) — the ``LocalFernletRepository`` that persists that blob as one JSON file for the local/no-iCloud storage mode, and the deterministic engines (`rebuildDerivedTables`, ``DerivedSignalFactory``, the internal `TierTwoMemoryEngine`) that recompute derived state from stored days on every save — the last two scoring journal tags through one shared `FeelingTag.moodScore` scale, so their mood math cannot diverge. The engines live here rather than in a scoring module because they are inseparable from the database's derived-table rebuild: both repositories funnel every write through `LocalFernletDatabase.apply(_:maxStoredDays:)` followed by `rebuildDerivedTables(todayKey:recentDays:)`, which regenerates the four log tables and the Tier-2 behavioral memories in one pass. The read side is shared the same way: both assemble the store's `FernletSnapshot` from an already-resolved day plus this module's `FernletSnapshot.assembled(todayKey:day:from:)` slice mapping, with day resolution deliberately left at the call sites because it differs per backend (the blob's own `days` here; the per-row `DayRecord` store with a pre-migration blob fallback in `CloudKitSync`).

The module's position in the dependency graph matters more than its size. It depends only on `FernletFoundation`, `FernletDomainModel`, `FernletScoring`, and `FernletPersistence` (the repository contract), and it is imported by `StoreCore`, `DiaryStore`, the app target — and, critically, by the **walled** `CloudKitSync` module, whose `CoreDataFernletRepository` serializes the very same ``LocalFernletDatabase`` encoding into a Core Data + CloudKit record. That places `LocalPersistence` *outside* the S3 privacy wall: anything added to this module becomes reachable from the iCloud sync path. It must therefore never gain a dependency on any sealed `Private*` store (`PrivateStoreCore`, `PrivateHealthStore`, `PrivateMemoryStore`, `PrivateMediaStore`) — a forbidden edge would be caught as a hard build error by the `DIAGNOSE_MISSING_TARGET_DEPENDENCIES=YES_ERROR` wall check (`Scripts/spm-wall-check.sh`).

Because the blob it defines can end up in iCloud, the module leans on two complementary protections. The *data-side* wall is enforced by type at the write boundary it inherits from `FernletPersistence`: ``LocalFernletRepository/saveSnapshot(_:)`` and ``LocalFernletRepository/updateDay(_:for:todayKey:)`` accept only `SanitizedSnapshot` / `SanitizedDay`, wrappers that can only be minted by the storage privacy strip — so sealed-journal bodies and cycle/intimate health fields are already blanked before any content reaches ``LocalFernletDatabase``. The *durability* protection is fail-closed corruption handling: an unreadable or undecodable database file flips ``LocalFernletRepository`` into read-only recovery mode, in which reads degrade gracefully (fresh or legacy-migrated database) but every save is refused, so a later write can never clobber data that might still be recoverable from disk. The blob itself decodes tolerantly — every key of ``LocalFernletDatabase`` falls back to a default via `decodeIfPresent`, and the derived log records freeze unknown enum tokens instead of throwing — reserving hard decode failure for genuine corruption. A third, at-rest protection (security-hardening Phase 6): when `StoragePreferences.localBackupExcludedFromiOSBackup` is set, the repository flags its own JSON file `isExcludedFromBackup` — at `init` and again after every successful save, because the atomic rewrite replaces the inode the flag lives on — and exposes ``LocalFernletRepository/applyBackupExclusion(excluded:)`` as the explicit both-directions seam for a runtime preference change, so the Privacy & Data toggle's "your local Fernlet data is excluded" copy holds for sync-off users whose entire history is this one file.

Two design invariants keep the derived state cheap and safe. First, derived tables are *disposable*: the ``DailyLogRecord`` / ``MealLogRecord`` / ``WorkoutLogRecord`` / ``JournalLogRecord`` rows and the Tier-2 memories are rebuilt from the source `FernletDay`s on every save, so a frozen or stale row costs nothing. Second, derived state is *bounded* while day storage is not: ``FernletLimits`` caps the recomputable structures (a 370-day window, per-day entry clamps, matching log ceilings, the 14-day signal window), whereas the day history itself is uncapped — per-row `DayRecord` rows on the Core Data path, the single file's `days` dictionary on the local path. ``DayContentSummary`` exists for that split: a counts-only roll-up carried in the blob so iCloud "existing data" detection stays a single-record read after the per-row day split retires the blob's `days` cache. ``DerivedSignalRecord`` values, by contrast, are never persisted at all — `StoreCore`'s `DerivedSignalsRebuilder` recomputes them from ``DerivedSignalFactory`` on demand.

Concurrency is deliberately plain: the target declares no default actor isolation, so everything here is nonisolated with a synchronous API. The engines are stateless namespace enums; ``LocalFernletDatabase`` is a mutable value type handed across actors by copy (declared `@unchecked Sendable`); and ``LocalFernletRepository`` is a value-type facade over a small shared, *unsynchronized* state box (recovery mode, pending legacy cleanup) — correctness relies on call sites confining an instance to a single actor, which in practice is the MainActor store and save coordinator.

## Topics

### The local repository

- ``LocalFernletRepository``

### The persisted aggregate

- ``LocalFernletDatabase``
- ``DayContentSummary``
- ``FernletLimits``

### Derived log tables

- ``DailyLogRecord``
- ``MealLogRecord``
- ``WorkoutLogRecord``
- ``JournalLogRecord``

### Derived signals

- ``DerivedSignalFactory``
- ``DerivedSignalRecord``
