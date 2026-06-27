import CoreData
import FernletFoundation
import Testing
import FernletDomainModel
import PrivateStoreCore
@testable import Fernlet

/// Proves that sealed entities (MenstrualNarrative, JournalNarrative) are isolated in the
/// non-CloudKit private store and can never appear in the CloudKit-mirrored cloud store.
/// Addresses SEC-3 from the architecture audit (Fernlet-Review-and-Plan-Updates.md).
struct SealedStoreConfigTests {

    private let sealedEntityNames = ["MenstrualNarrative", "JournalNarrative", "IntimacyLog"]
    private let cloudEntityNames = ["FernletDatabaseRecord", "SavedRecipeRecord"]

    // MARK: - Cloud model exclusion

    @Test func sealedEntitiesAbsentFromCloudModel() {
        let cloudModel = PersistenceController(inMemory: true).container.managedObjectModel
        for name in sealedEntityNames {
            #expect(
                cloudModel.entitiesByName[name] == nil,
                "Sealed entity '\(name)' must not appear in the CloudKit-mirrored model"
            )
        }
    }

    @Test func cloudEntitiesPresentInCloudModel() {
        let cloudModel = PersistenceController(inMemory: true).container.managedObjectModel
        for name in cloudEntityNames {
            #expect(
                cloudModel.entitiesByName[name] != nil,
                "Cloud entity '\(name)' must be present in the cloud model"
            )
        }
    }

    // MARK: - Private store isolation

    @Test func sealedEntitiesPresentInPrivateModel() {
        let privateModel = PrivatePersistenceController(inMemory: true).container.managedObjectModel
        for name in sealedEntityNames {
            #expect(
                privateModel.entitiesByName[name] != nil,
                "Sealed entity '\(name)' must be present in the private (non-CloudKit) model"
            )
        }
    }

    @Test func cloudEntitiesAbsentFromPrivateModel() {
        let privateModel = PrivatePersistenceController(inMemory: true).container.managedObjectModel
        for name in cloudEntityNames {
            #expect(
                privateModel.entitiesByName[name] == nil,
                "Cloud entity '\(name)' must not appear in the private store model"
            )
        }
    }

    /// The private store must never have CloudKit container options — not even when iCloud is enabled.
    @Test func privateStoreNeverHasCloudKitOptions() {
        let controller = PrivatePersistenceController(inMemory: true)
        let storeDesc = controller.container.persistentStoreDescriptions.first
        #expect(
            storeDesc?.cloudKitContainerOptions == nil,
            "PrivatePersistenceController store must never have CloudKit container options"
        )
    }

    @Test func privateStoreTracksHistorySoDeletionCanPruneIt() {
        let controller = PrivatePersistenceController(inMemory: true)
        let storeDesc = controller.container.persistentStoreDescriptions.first
        #expect(storeDesc?.options[NSPersistentHistoryTrackingKey] as? NSNumber == true)
    }

    /// Cloud store must use NSPersistentCloudKitContainer (not plain NSPersistentContainer)
    /// so that iCloud mirroring is available when the user opts in.
    @Test func cloudContainerIsCloudKitContainer() {
        let controller = PersistenceController(inMemory: false, preferences: StoragePreferences(), iCloudAvailable: false)
        #expect(controller.container is NSPersistentCloudKitContainer)
    }

    /// Private container must be a plain NSPersistentContainer — not NSPersistentCloudKitContainer.
    @Test func privateContainerIsNotCloudKitContainer() {
        let controller = PrivatePersistenceController(inMemory: true)
        #expect(!(controller.container is NSPersistentCloudKitContainer))
    }
}
