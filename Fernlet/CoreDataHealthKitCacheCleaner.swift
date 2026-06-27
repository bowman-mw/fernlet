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
    func clearHealthKitCachedValues() throws {
        let controller = PersistenceController.shared
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "FernletDatabaseRecord")
        let records = try context.fetch(request)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        for record in records {
            guard let payload = record.value(forKey: "payloadData") as? Data else { continue }
            var database = try decoder.decode(LocalFernletDatabase.self, from: payload)
            var changed = false
            for key in database.days.keys {
                guard var day = database.days[key], let context = day.healthContext else { continue }
                if let healthSleepHours = context.body?.sleepHours,
                   let sleep = day.sleep,
                   sleep.note.isEmpty,
                   sleep.hours == healthSleepHours {
                    day.sleep = nil
                }
                day.healthContext = nil
                database.days[key] = day
                changed = true
            }
            if changed {
                let todayKey = database.days.keys.sorted().last ?? FernletDate.dayKey(for: .now)
                database.rebuildDerivedTables(todayKey: todayKey)
                record.setValue(try encoder.encode(database), forKey: "payloadData")
                record.setValue(Date(), forKey: "updatedAt")
            }
        }
        if context.hasChanges {
            try context.save()
        }
    }
}
