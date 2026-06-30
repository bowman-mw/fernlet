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
        // Days live in per-row DayRecords now (no longer the blob's `days`), so strip the HealthKit cache
        // row by row. Each row holds one FernletDay; clear its `healthContext` (and any sleep that came
        // straight from HealthKit). Derived tables recompute from rows on the next save.
        let context = PersistenceController.shared.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "DayRecord")
        let records = try context.fetch(request)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        for record in records {
            guard let payload = record.value(forKey: "payloadData") as? Data,
                  var day = try? decoder.decode(FernletDay.self, from: payload),
                  let healthContext = day.healthContext else { continue }
            if let healthSleepHours = healthContext.body?.sleepHours,
               let sleep = day.sleep,
               sleep.note.isEmpty,
               sleep.hours == healthSleepHours {
                day.sleep = nil
            }
            day.healthContext = nil
            record.setValue(try encoder.encode(day), forKey: "payloadData")
            record.setValue(Date(), forKey: "updatedAt")
        }
        if context.hasChanges {
            try context.save()
        }
    }
}
