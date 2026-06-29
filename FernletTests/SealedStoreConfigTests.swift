import CoreData
import FernletFoundation
import Testing
import FernletDomainModel
import PrivateStoreCore
import CloudKitSync
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

    // MARK: - Backup exclusion (shared BackupExclusion helper + corrected default)

    /// When excluded, the shared helper flags the store file AND the `_SUPPORT` external-binary dir
    /// (sealed columns use `allowsExternalBinaryDataStorage`, so large blobs spill there).
    @Test func backupExclusionAppliesToStoreAndSupportDir() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storeURL = tempDir.appendingPathComponent("FernletPrivate.sqlite")
        try Data("stub".utf8).write(to: storeURL)
        let supportDir = tempDir.appendingPathComponent(".FernletPrivate_SUPPORT", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)

        BackupExclusion.apply(storeURL: storeURL, excluded: true, includeSupportDir: true)

        #expect(try storeURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try supportDir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    /// When NOT excluded (the default), the helper clears the flag so local data stays recoverable.
    @Test func backupExclusionClearsFlagWhenNotExcluded() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storeURL = tempDir.appendingPathComponent("FernletPrivate.sqlite")
        try Data("stub".utf8).write(to: storeURL)

        BackupExclusion.apply(storeURL: storeURL, excluded: false, includeSupportDir: true)

        #expect(try storeURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true)
    }

    /// Regression guard for finding #1: the DEFAULT must be NOT-excluded, so the sealed store (which has
    /// no cloud recovery) is recoverable via same-device backup unless the user opts into exclusion.
    @Test func defaultStoragePreferencesDoesNotExcludeLocalBackup() {
        #expect(StoragePreferences().localBackupExcludedFromiOSBackup == false)
    }
}
