> **CLOSED 2026-07-19 — SHIPPED.** The per-row `DayRecord` split is on `main` (`CloudKitSync/DayRecordRepository.swift`, migration gate `daysMigratedToRows` in `CoreDataFernletRepository.swift`); the header's "planned, not started" no longer applies. Live tracker: [RemainingWork-2026-07-19.md](../RemainingWork-2026-07-19.md).

# Per-Row Day Storage Split — Plan (remove the 370-day cap)

**Status:** planned, not started. Separate effort from the coin ledger (which already decoupled coins
from the cap). Owner asked to pursue this as the architecturally-correct fix to the day-storage cap.

## Problem

The entire day history is serialized into **one** Core Data record (`FernletDatabaseRecord.payloadData`,
the whole `LocalFernletDatabase` blob) and synced as a single CloudKit record. To keep that blob under
CloudKit's ~1 MB per-record limit it is capped at `FernletLimits.maxStoredDays = 370` and pruned
oldest-first ([LocalFernletRepository.swift:378](../../FernletKit/Sources/LocalPersistence/LocalFernletRepository.swift);
prune at [CoreDataFernletRepository.swift:193](../../FernletKit/Sources/CloudKitSync/CoreDataFernletRepository.swift)
and `LocalFernletDatabase.apply`). Consequences:

- Hard ~1-year retention ceiling; older days are silently dropped.
- Every save/load encodes/decodes the *whole* history (slow main-actor decode flagged in the 2026-06-12
  review); a remote change reloads everything.
- A verbose user can still approach the 1 MB limit within the window and degrade sync.

Nothing depends on exactly 370 (scoring uses a 14-day window, `FernletLimits.signalWindowDays`; cycle
math is detection-based; "year-ago" cards use 365/180/90/30 lookbacks). So the cap is purely a blob-size
band-aid, not a product constraint.

## Goal

Store each day as its **own** Core Data row (and therefore its own CloudKit record), so history scales
linearly, sync conflicts are per-day, I/O touches only changed days, and the cap can be removed (or
raised far beyond a year). The settings/aggregate state stays in the existing small record.

## Approach (incremental, each step compiles + ships)

### Phase 0 — Seam audit
Inventory every reader/writer of `LocalFernletDatabase.days` and `FernletRepository` (`loadSnapshot`,
`loadAllDays`, `updateDay`, `saveSnapshot`, `loadDay`, derived-table builders). The repository protocol
is already day-granular at the edges (`updateDay`, `loadDay`) — lean on that.

### Phase 1 — New per-day entity, dual-write
Add a `DayRecord` Core Data entity (`dateKey` unique, `payloadData` = one `FernletDay` JSON, `updatedAt`)
registered in `makeManagedObjectModel()` + `CloudKitDataService.allRecordTypes`, mirroring
`CustomItemRecord`. Keep the existing blob as the source of truth; **also** write each touched day to its
`DayRecord`. No read path changes yet (safe, reversible).

### Phase 2 — Migrate + read from rows
On first launch, fan the existing blob's `days` into `DayRecord` rows (idempotent, keyed by `dateKey`).
Switch `loadAllDays`/`loadDay`/`updateDay` to the per-row store; build derived tables from a fetch instead
of `days.suffix(370)`. The blob keeps only the small non-day aggregate (settings, retryQueue, logs,
audit). Conflict resolution becomes per-day (union-merge by `dateKey`, like `CustomItemRecord`), removing
the whole-blob last-writer-wins merge in `mergingRemoteDays`.

### Phase 3 — Drop the cap
Remove `maxStoredDays` pruning (or raise it to a sanity bound, e.g. 10 years) once rows are the source of
truth. Optionally add age/size-aware archival later, but it's no longer forced by the 1 MB limit.

### Phase 4 — Remove the legacy blob `days`
After a migration window, stop writing `days` into the aggregate blob; delete the field on next schema
bump. Keep a one-time backfill guard for users who skipped Phase 2.

## Risks / watch-items

- **Migration correctness:** the blob→rows fan-out must be idempotent and crash-safe (resume if
  interrupted). Gate with a `daysMigratedToRows` flag; never delete the blob `days` until rows verified.
- **CloudKit record count:** thousands of small records is fine, but initial migration uploads many rows —
  throttle/batch like the sealed-backup chunker (250/batch).
- **Privacy wall:** `DayRecord` holds the same already-sanitized day payload as today's blob; the
  `SanitizedDay` strip still applies at the write boundary. No new sealed data crosses the wall.
- **Derived tables / signals:** `DerivedSignalsService` and the daily/meal/workout/journal log builders
  read `days.suffix(370)`; re-point them at a bounded fetch (e.g. last N days) so they don't load all rows.
- **Coins:** unaffected — the coin ledger is its own per-row store and already independent of day storage.

## Estimate

~2–3 focused increments (entity+dual-write; migrate+read; cap removal+cleanup) with careful migration
testing. Until it lands, the cap stays at 370; coins are already safe regardless.
