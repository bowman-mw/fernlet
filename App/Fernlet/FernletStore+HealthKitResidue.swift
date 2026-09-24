import Foundation
import CloudKitSync
import DiaryStore
import FernletFoundation
import FernletPersistence

/// The app-side half of "HealthKit information is not stored in iCloud" (owner decision
/// 2026-09-23, App Review 5.1.3(ii)): recording today's HealthKit residue on this device, and the
/// one-time scrub of HealthKit values out of rows an older build synced.
///
/// The strip itself lives in `FernletPersistence` and runs on every synced write; the overlay that
/// gives the values back on read lives in `DiaryStore`. What is left for the facade is WHEN today's
/// residue is recorded: at the HealthKit ingestion points only (`updateHealthContext` and the
/// workout-sync upsert/removal) — never on an ordinary save. That is deliberate: after a HealthKit
/// opt-out the in-memory day still holds the readings until relaunch, and a save-time capture would
/// write them straight back into the cache the opt-out just emptied. Ingestion stops with the
/// opt-out, so the cache stays empty.
extension FernletStore {
    /// Records today's HealthKit residue — the values the synced save is about to strip — in this
    /// device's cache. A failed write is audited; nothing leaks either way (the strip does not
    /// depend on it), the cost is today's readings missing after a relaunch until the next refresh.
    func captureTodayHealthKitResidue() {
        guard deviceHealthResidueStore.record(day.healthKitResidue, for: todayKey) else {
            PersistenceFailureAudit.record("healthResidue.captureToday.failed")
            return
        }
    }

    /// The one-time launch scrub: rewrites every `DayRecord` row and the aggregate blob that an
    /// older build left HealthKit values in, so they leave iCloud without waiting for each day to be
    /// edited. When `captureEnabled`, each scrubbed day's values are kept in this device's cache
    /// first, so this device's history keeps its HealthKit context.
    ///
    /// Runs once per device (the marker lives in the device cache, so a wipe or an opt-out re-arms
    /// it — harmless, the scrub is idempotent). Skipped, and retried next launch, while the
    /// repository is in read-only recovery or the scrub fails; a local-JSON repository has no
    /// iCloud copy to scrub and is marked done.
    ///
    /// - Parameter captureEnabled: Whether HealthKit is currently enabled. Pass the live master
    ///   toggle: with HealthKit off, values found in old rows are discarded, never cached — the
    ///   opt-out's promise covers them too.
    func scrubLegacySyncedHealthKitValuesIfNeeded(captureEnabled: Bool) {
        let cache = deviceHealthResidueStore
        guard !cache.legacySyncedRowsScrubbed else { return }
        guard let coreData = diary.repository as? CoreDataFernletRepository else {
            markLegacyScrubCompleted(in: cache)
            return
        }
        guard !coreData.isInReadOnlyRecovery else { return }
        let cleaner = CoreDataHealthKitCacheCleaner(controller: coreData.persistenceController, residueStore: cache)
        do {
            try cleaner.scrubSyncedHealthKitValues(capturingInto: captureEnabled ? cache : nil)
        } catch {
            FernletAuditLog.log("healthResidue.legacyScrub.failed", context: ["errorType": "\(type(of: error))"])
            return
        }
        markLegacyScrubCompleted(in: cache)
        // The scrub wrote around the repository's memo; drop it so the next read sees the scrubbed
        // rows (the invalidation's reload re-overlays today from the cache).
        coreData.invalidateCache()
    }

    /// Records the scrub marker, auditing a failure (the cost is one more idempotent pass).
    private func markLegacyScrubCompleted(in cache: any DeviceHealthResidueStoring) {
        guard cache.markLegacySyncedRowsScrubbed() else {
            PersistenceFailureAudit.record("healthResidue.legacyScrubMark.failed")
            return
        }
    }
}
