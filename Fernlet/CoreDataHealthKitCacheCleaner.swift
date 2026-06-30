import Foundation
import CoreData
import CloudKitSync
import LocalPersistence
import FernletFoundation
import FernletDomainModel
import HealthKitGateway

// The concrete HealthKit cache cleaner. Lives in the app target (NOT the HealthKitGateway
// module) because it reaches CloudKitSync's `PersistenceController` and LocalPersistence's
// `LocalFernletDatabase` — modules the platform gateway must never depend on. It is installed
// into `HealthKitService.defaultCacheClearer` at app launch (see FernletApp.init) and surfaced
// to the gateway only through the `HealthKitCacheClearing` seam.
struct CoreDataHealthKitCacheCleaner: HealthKitCacheClearing {
    private let controller: PersistenceController

    init(controller: PersistenceController = .shared) {
        self.controller = controller
    }

    func clearHealthKitCachedValues() throws {
        let context = controller.container.viewContext
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        // 1) Per-row DayRecords — the authoritative day store after the per-row split.
        for record in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DayRecord")) {
            guard let payload = record.value(forKey: "payloadData") as? Data,
                  let day = try? decoder.decode(FernletDay.self, from: payload),
                  let stripped = Self.strippedOfHealthCache(day) else { continue }
            record.setValue(try encoder.encode(stripped), forKey: "payloadData")
            record.setValue(Date(), forKey: "updatedAt")
        }

        // 2) The aggregate FernletDatabaseRecord blob still carries a bounded `days` cache that syncs to
        //    iCloud, so it must be stripped too — otherwise opting out of HealthKit would leave clinical
        //    context (sleep/steps/HRV) syncing in the blob even though reads come from the rows above.
        for record in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "FernletDatabaseRecord")) {
            guard let payload = record.value(forKey: "payloadData") as? Data,
                  var database = try? decoder.decode(LocalFernletDatabase.self, from: payload) else { continue }
            var changed = false
            for key in database.days.keys {
                guard let day = database.days[key], let stripped = Self.strippedOfHealthCache(day) else { continue }
                database.days[key] = stripped
                changed = true
            }
            guard changed else { continue }
            let todayKey = database.days.keys.sorted().last ?? FernletDate.dayKey(for: .now)
            database.rebuildDerivedTables(todayKey: todayKey)
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
