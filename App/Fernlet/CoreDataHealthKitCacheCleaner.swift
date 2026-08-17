import Foundation
import CoreData
import CloudKitSync
import LocalPersistence
import FernletFoundation
import FernletDomainModel
import HealthKitGateway

/// The concrete HealthKit cache cleaner behind the HealthKit opt-out.
///
/// Lives in the app target (NOT the HealthKitGateway module) because it reaches CloudKitSync's
/// `PersistenceController` and LocalPersistence's `LocalFernletDatabase` — modules the platform
/// gateway must never depend on. It is installed into `HealthKitService.defaultCacheClearer` at
/// app launch (see `FernletApp.init`) and surfaced to the gateway only through the
/// `HealthKitCacheClearing` seam.
///
/// `clearHealthKitCachedValues()` strips cached health context from every per-row `DayRecord`
/// (preserving user-authored sleep) and rebuilds the aggregate blob's derived tables from the
/// stripped rows so no HealthKit-derived value keeps syncing to iCloud after opt-out. It is
/// FAIL-CLOSED: any undecodable row/blob throws ``CacheClearError`` so the opt-out reports
/// failure and can be retried instead of silently "succeeding" with clinical data left behind.
struct CoreDataHealthKitCacheCleaner: HealthKitCacheClearing {
    /// A row or the aggregate blob could not be decoded, so the scrub cannot prove the HealthKit cache is
    /// gone.
    ///
    /// Thrown to keep the opt-out FAIL-CLOSED: `HealthKitService.disableIntegration` catches it, logs
    /// `healthkit.disable.failed`, leaves `healthKitMasterEnabled` ON, and lets the user retry — rather than
    /// silently "succeeding" while clinical data (sleep/steps/HRV, cycle/intimate-derived values) stays in the
    /// CloudKit-synced record. Undecodable here means a corrupt payload or a forward-schema payload written by
    /// a newer build on another device and synced in; both are exactly the cases we must not skip. Every row of
    /// the `DayRecord` entity — and of `FernletDatabaseRecord` — is a serialized value of a single type, so
    /// there is no benign "unrelated record" a decode failure could represent that we could safely tolerate.
    enum CacheClearError: Error {
        case undecodableDayRow
        case undecodableDatabaseBlob
    }

    private let controller: PersistenceController

    /// - Parameter controller: The Core Data stack to scrub; `nil` resolves the shared one.
    ///   Deliberately `nil`-defaulted rather than `= .shared`: `PersistenceController.shared` is
    ///   `@MainActor`, and a default-argument expression is evaluated in the CALLER's isolation, which
    ///   is nonisolated. Resolving in the body — which carries this type's own isolation — is the
    ///   supported form.
    init(controller: PersistenceController? = nil) {
        self.controller = controller ?? .shared
    }

    func clearHealthKitCachedValues() throws {
        let context = controller.container.viewContext
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        // 1) Per-row DayRecords — the authoritative day store after the per-row split.
        var strippedAnyRow = false
        for record in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DayRecord")) {
            guard let payload = record.value(forKey: "payloadData") as? Data else { continue }
            // Fail CLOSED on a decode failure: we cannot prove this row is free of HealthKit cache, so we must
            // not let the opt-out report success. `strippedOfHealthCache == nil` is the *benign* case (the day
            // decoded but has no healthContext to strip) and legitimately skips.
            let day: FernletDay
            do {
                day = try decoder.decode(FernletDay.self, from: payload)
            } catch {
                throw CacheClearError.undecodableDayRow
            }
            guard let stripped = Self.strippedOfHealthCache(day) else { continue }
            record.setValue(try encoder.encode(stripped), forKey: "payloadData")
            record.setValue(Date(), forKey: "updatedAt")
            strippedAnyRow = true
        }

        // 2) The aggregate FernletDatabaseRecord blob carries a bounded derived cache — `dailyLogs` and the
        //    other log tables, plus the `dayContentSummary` roll-up, plus (on un-migrated stores) its own
        //    `days` map — all of which sync to iCloud. That derived cache is rebuilt here from the
        //    authoritative, now-stripped DayRecord rows loaded above. On a *migrated* store the blob's `days`
        //    is already empty, so the previous "only rebuild if a blob `day` changed" guard skipped the
        //    rebuild entirely and left stale HealthKit-derived sleep hours in `dailyLogs`/`dayContentSummary`
        //    syncing to iCloud after opt-out. `loadRecent` runs on the same view context, so it observes the
        //    pending row edits from step 1.
        let recentDays = DayRecordRepository(controller: controller)
            .loadRecent(limit: FernletLimits.derivedLogWindowDays)
            .map { ($0.date, $0) }
            .sorted { $0.0 < $1.0 }   // oldest-first, as rebuildDerivedTables(recentDays:) expects
        for record in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "FernletDatabaseRecord")) {
            guard let payload = record.value(forKey: "payloadData") as? Data else { continue }
            // Fail CLOSED: an undecodable blob may still carry HealthKit-derived cache (`dailyLogs`,
            // `dayContentSummary`, or an un-migrated `days` map) that would keep syncing to iCloud, so a decode
            // failure must throw rather than silently leave the blob untouched and report a successful opt-out.
            var database: LocalFernletDatabase
            do {
                database = try decoder.decode(LocalFernletDatabase.self, from: payload)
            } catch {
                throw CacheClearError.undecodableDatabaseBlob
            }
            // Strip any residual health cache still held in an un-migrated blob's own `days` map.
            var blobDaysChanged = false
            for key in database.days.keys {
                guard let day = database.days[key], let stripped = Self.strippedOfHealthCache(day) else { continue }
                database.days[key] = stripped
                blobDaysChanged = true
            }
            // A migrated store must always rebuild from rows — its blob derived tables can be stale even when
            // this pass stripped nothing new. A clean un-migrated blob (no rows and no blob-day change) is
            // left untouched to avoid a needless synced write.
            guard database.daysMigratedToRows || strippedAnyRow || blobDaysChanged else { continue }
            if database.daysMigratedToRows {
                let todayKey = recentDays.last?.0 ?? FernletDate.dayKey(for: .now)
                database.rebuildDerivedTables(todayKey: todayKey, recentDays: recentDays)
                database.dayContentSummary = DayContentSummary(days: recentDays.map(\.1))
            } else {
                let todayKey = database.days.keys.sorted().last ?? FernletDate.dayKey(for: .now)
                database.rebuildDerivedTables(todayKey: todayKey)
                database.dayContentSummary = DayContentSummary(days: Array(database.days.values))
            }
            record.setValue(try encoder.encode(database), forKey: "payloadData")
            record.setValue(Date(), forKey: "updatedAt")
        }

        if context.hasChanges {
            try context.save()
        }
    }

    /// Returns the day with its HealthKit cache cleared, or nil when there is nothing to clear (no
    /// `healthContext`). Drops only sleep that came straight from HealthKit; a user-authored sleep entry
    /// (any note, or a different hours value) is preserved.
    private static func strippedOfHealthCache(_ day: FernletDay) -> FernletDay? {
        guard let healthContext = day.healthContext else { return nil }
        var stripped = day
        if let healthSleepHours = healthContext.body?.sleepHours,
           let sleep = day.sleep,
           sleep.note.isEmpty,
           sleep.hours == healthSleepHours {
            stripped.sleep = nil
        }
        stripped.healthContext = nil
        return stripped
    }
}
