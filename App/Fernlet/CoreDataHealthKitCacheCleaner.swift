import Foundation
import CoreData
import CloudKitSync
import LocalPersistence
import FernletFoundation
import FernletDomainModel
import FernletPersistence
import HealthKitGateway

/// The concrete HealthKit cache cleaner behind the HealthKit opt-out — and the machinery of the
/// one-time scrub of HealthKit values out of the rows written before the storage strip existed.
///
/// Lives in the app target (NOT the HealthKitGateway module) because it reaches CloudKitSync's
/// `PersistenceController` and LocalPersistence's `LocalFernletDatabase` — modules the platform
/// gateway must never depend on. It is installed into `HealthKitService.defaultCacheClearer` at
/// app launch (see `FernletApp.init`) and surfaced to the gateway only through the
/// `HealthKitCacheClearing` seam.
///
/// Since 2026-09-23 no synced write carries a HealthKit value (the storage strip in
/// `FernletPersistence` removes the context, HealthKit sleep hours and imported workouts from
/// every day, and the HealthKit scoring contexts from every stored score), so the values Fernlet
/// caches live in this device's `DeviceHealthResidueStoring` cache instead. Opting out therefore
/// does two things: ``clearHealthKitCachedValues()`` scrubs whatever HealthKit value an older build
/// (this device's, or another device's, synced in) left in a `DayRecord` row or the aggregate blob,
/// and then empties the device-local cache. The scrub keeps the user's own values — typed sleep
/// hours, the sleep quality and note, Fernlet-logged workouts — through the same shared strip.
///
/// It is FAIL-CLOSED: any undecodable row/blob, or a device cache that will not clear, throws
/// ``CacheClearError`` so the opt-out reports failure and can be retried instead of silently
/// "succeeding" with HealthKit data left behind.
struct CoreDataHealthKitCacheCleaner: HealthKitCacheClearing {
    /// A row or the aggregate blob could not be decoded, or the device cache could not be cleared,
    /// so the opt-out cannot prove the HealthKit cache is gone.
    ///
    /// Thrown to keep the opt-out FAIL-CLOSED: `HealthKitService.disableIntegration` catches it, logs
    /// `healthkit.disable.failed`, leaves `healthKitMasterEnabled` ON, and lets the user retry — rather than
    /// silently "succeeding" while HealthKit data (sleep/steps/HRV, imported workouts) stays in the
    /// CloudKit-synced record or on the device. Undecodable here means a corrupt payload or a forward-schema
    /// payload written by a newer build on another device and synced in; both are exactly the cases we must
    /// not skip. Every row of the `DayRecord` entity — and of `FernletDatabaseRecord` — is a serialized value
    /// of a single type, so there is no benign "unrelated record" a decode failure could represent.
    enum CacheClearError: Error {
        case undecodableDayRow
        case undecodableDatabaseBlob
        case deviceCacheNotCleared
    }

    private let controller: PersistenceController
    private let residueStore: any DeviceHealthResidueStoring

    /// - Parameters:
    ///   - controller: The Core Data stack to scrub; `nil` resolves the shared one.
    ///   - residueStore: The device-local HealthKit cache the opt-out empties; `nil` resolves the
    ///     production file (the same instance the launch-path store reads, so the clear is seen).
    ///   Both are deliberately `nil`-defaulted rather than `= .shared` / `= .production`: those are
    ///   `@MainActor`, and a default-argument expression is evaluated in the CALLER's isolation, which
    ///   is nonisolated. Resolving in the body — which carries this type's own isolation — is the
    ///   supported form.
    init(controller: PersistenceController? = nil, residueStore: (any DeviceHealthResidueStoring)? = nil) {
        self.controller = controller ?? .shared
        self.residueStore = residueStore ?? FileDeviceHealthResidueStore.production
    }

    /// The HealthKit opt-out: scrubs every synced row and the blob, then empties the device cache.
    func clearHealthKitCachedValues() throws {
        try scrubSyncedHealthKitValues(capturingInto: nil)
        guard residueStore.clearAll() else { throw CacheClearError.deviceCacheNotCleared }
    }

    /// Removes every HealthKit-derived value from the synced `DayRecord` rows and the aggregate blob,
    /// optionally recording each scrubbed day's residue into `capture` first.
    ///
    /// The opt-out passes nil (the values are being discarded); the one-time launch scrub passes
    /// this device's cache so the history it strips from iCloud is kept here. A day whose only
    /// content was HealthKit's has its row deleted, exactly as a save would (no empty rows).
    ///
    /// - Parameter capture: Where to keep what is scrubbed; nil discards it.
    func scrubSyncedHealthKitValues(capturingInto capture: (any DeviceHealthResidueStoring)?) throws {
        let context = controller.container.viewContext
        let strippedAnyRow = try scrubDayRows(in: context, capturingInto: capture)
        try scrubAggregateBlob(in: context, strippedAnyRow: strippedAnyRow, capturingInto: capture)
        if context.hasChanges {
            try context.save()
        }
    }

    /// Step 1: the per-row `DayRecord`s — the authoritative day store after the per-row split.
    ///
    /// - Returns: Whether any row changed (so the blob's row-derived tables need a rebuild).
    private func scrubDayRows(
        in context: NSManagedObjectContext,
        capturingInto capture: (any DeviceHealthResidueStoring)?
    ) throws -> Bool {
        let decoder = Self.makeDecoder()
        let encoder = Self.makeEncoder()
        var strippedAnyRow = false
        for record in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DayRecord")) {
            guard let payload = record.value(forKey: "payloadData") as? Data else { continue }
            // Fail CLOSED on a decode failure: we cannot prove this row is free of HealthKit values, so
            // the opt-out must not report success. A day that decodes clean legitimately skips.
            let day: FernletDay
            do {
                day = try decoder.decode(FernletDay.self, from: payload)
            } catch {
                throw CacheClearError.undecodableDayRow
            }
            guard day.carriesHealthKitValues else { continue }
            Self.captureResidue(of: day, into: capture)
            let stripped = day.strippingHealthKitValues()
            if stripped.hasLoggedContent {
                record.setValue(try encoder.encode(stripped), forKey: "payloadData")
                record.setValue(Date(), forKey: "updatedAt")
            } else {
                context.delete(record)
            }
            strippedAnyRow = true
        }
        return strippedAnyRow
    }

    /// Step 2: the aggregate `FernletDatabaseRecord` blob carries a bounded derived cache — `dailyLogs`
    /// and the other log tables, plus the `dayContentSummary` roll-up, plus (on un-migrated stores) its
    /// own `days` map — and the `dailyScores` history, all of which sync to iCloud. The scores lose their
    /// HealthKit contexts; the derived cache is rebuilt from the authoritative, now-stripped `DayRecord`
    /// rows. On a *migrated* store the blob's `days` is already empty, so the rebuild must run anyway
    /// (a "only if a blob day changed" guard once left stale HealthKit sleep hours in `dailyLogs`).
    /// `loadRecent` runs on the same view context, so it observes the pending row edits from step 1.
    private func scrubAggregateBlob(
        in context: NSManagedObjectContext,
        strippedAnyRow: Bool,
        capturingInto capture: (any DeviceHealthResidueStoring)?
    ) throws {
        let decoder = Self.makeDecoder()
        let encoder = Self.makeEncoder()
        for record in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "FernletDatabaseRecord")) {
            guard let payload = record.value(forKey: "payloadData") as? Data else { continue }
            // Fail CLOSED: an undecodable blob may still carry HealthKit-derived cache that would keep
            // syncing to iCloud, so a decode failure must throw rather than report a successful opt-out.
            var database: LocalFernletDatabase
            do {
                database = try decoder.decode(LocalFernletDatabase.self, from: payload)
            } catch {
                throw CacheClearError.undecodableDatabaseBlob
            }
            let blobChanged = Self.scrubBlobDaysAndScores(&database, capturingInto: capture)
            // A clean un-migrated blob (no rows and no blob change) is left untouched to avoid a needless
            // synced write; a migrated store always rebuilds from rows.
            guard database.daysMigratedToRows || strippedAnyRow || blobChanged else { continue }
            rebuildRowDerivedState(&database)
            record.setValue(try encoder.encode(database), forKey: "payloadData")
            record.setValue(Date(), forKey: "updatedAt")
        }
    }

    /// Strips an un-migrated blob's own `days` map (capturing first) and the stored scores'
    /// HealthKit contexts. Returns whether anything changed.
    private static func scrubBlobDaysAndScores(
        _ database: inout LocalFernletDatabase,
        capturingInto capture: (any DeviceHealthResidueStoring)?
    ) -> Bool {
        var changed = false
        for key in database.days.keys {
            guard let day = database.days[key], day.carriesHealthKitValues else { continue }
            captureResidue(of: day, into: capture)
            database.days[key] = day.strippingHealthKitValues()
            changed = true
        }
        let scores = FernletSnapshot.storedDailyScores(database.dailyScores)
        if scores != database.dailyScores {
            database.dailyScores = scores
            changed = true
        }
        return changed
    }

    /// Rebuilds the blob's derived tables and content summary from the (stripped) rows on a migrated
    /// store, or from its own (stripped) `days` map on an un-migrated one.
    private func rebuildRowDerivedState(_ database: inout LocalFernletDatabase) {
        if database.daysMigratedToRows {
            let recentDays = DayRecordRepository(controller: controller)
                .loadRecent(limit: FernletLimits.derivedLogWindowDays)
                .map { ($0.date, $0) }
                .sorted { $0.0 < $1.0 }   // oldest-first, as rebuildDerivedTables(recentDays:) expects
            let todayKey = recentDays.last?.0 ?? FernletDate.dayKey(for: .now)
            database.rebuildDerivedTables(todayKey: todayKey, recentDays: recentDays)
            database.dayContentSummary = DayContentSummary(days: recentDays.map(\.1))
        } else {
            let todayKey = database.days.keys.sorted().last ?? FernletDate.dayKey(for: .now)
            database.rebuildDerivedTables(todayKey: todayKey)
            database.dayContentSummary = DayContentSummary(days: Array(database.days.values))
        }
    }

    /// Keeps a scrubbed day's HealthKit values on this device, when a cache was given. An entry this
    /// device already recorded (its own, fresher reading) is never overwritten by a synced-in copy.
    private static func captureResidue(of day: FernletDay, into capture: (any DeviceHealthResidueStoring)?) {
        guard let capture, let residue = day.healthKitResidue, capture.residue(for: day.date) == nil else { return }
        if !capture.record(residue, for: day.date) {
            PersistenceFailureAudit.record("healthResidue.scrubCapture.failed")
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
