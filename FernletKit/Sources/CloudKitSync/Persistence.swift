//
//  Persistence.swift
//  Fernlet
//
//  Created by Michael Bowman on 5/16/26.
//

import Combine
import FernletFoundation
import CoreData
import Foundation
import Observation
import FernletDomainModel

public enum PersistenceStoreLoadError: LocalizedError, Equatable {
    case primaryStoreUnavailable

    public var errorDescription: String? {
        switch self {
        case .primaryStoreUnavailable:
            return "Fernlet couldn't open your local records. Your data was not deleted. Unlock your device if it was just restarted, free up storage if needed, then try again."
        }
    }
}

@Observable
nonisolated public final class PersistenceController {
    nonisolated(unsafe) public static let shared: PersistenceController = {
        let data = KeychainItem.load(for: .storagePreferences, service: KeychainItem.storagePreferencesService)
        var startupPreferences = data.flatMap { try? JSONDecoder().decode(StoragePreferences.self, from: $0) } ?? StoragePreferences()
        startupPreferences.iCloudSyncEnabled = false
        return PersistenceController(preferences: startupPreferences)
    }()

    @MainActor
    public static let preview: PersistenceController = {
        let result = PersistenceController(inMemory: true, preferences: StoragePreferences(iCloudSyncEnabled: false))
        return result
    }()

    public private(set) var isReloading = false

    @ObservationIgnored public private(set) var container: NSPersistentContainer
    public private(set) var didFailToLoad = false
    /// Fires when iCloud pushes a remote change to the local store.
    @ObservationIgnored public let remoteChangePublisher: AnyPublisher<Notification, Never>
    @ObservationIgnored public var reloadStoreURLOverrideForTesting: URL?

    private let inMemory: Bool
    private let storeURL: URL?
    /// When non-nil, overrides the real `FileManager.ubiquityIdentityToken` check. Injected by tests
    /// so CloudKit configuration logic can be exercised without a real iCloud account present.
    private let iCloudAvailabilityOverride: Bool?
    @ObservationIgnored private let remoteChangeSubject = PassthroughSubject<Notification, Never>()
    @ObservationIgnored private var remoteChangeCancellable: AnyCancellable?

    public init(
        inMemory: Bool = false,
        preferences: StoragePreferences = StoragePreferences(),
        storeURL: URL? = nil,
        iCloudAvailable: Bool? = nil
    ) {
        self.inMemory = inMemory
        self.storeURL = storeURL
        self.iCloudAvailabilityOverride = iCloudAvailable
        self.remoteChangePublisher = remoteChangeSubject.eraseToAnyPublisher()

        let configuration = Self.makeContainer(inMemory: inMemory, preferences: preferences, storeURL: storeURL, iCloudAvailabilityOverride: iCloudAvailable)
        self.container = configuration.container
        self.didFailToLoad = Self.loadPersistentStores(
            for: configuration.container,
            preferences: preferences,
            inMemory: inMemory
        )
        configureViewContext(for: configuration.container)
        bindRemoteChanges(to: configuration.container)
    }

    @MainActor
    public func reload(with preferences: StoragePreferences) async throws {
        FernletAuditLog.log("persistence.reload.started", context: [
            "iCloudSync": preferences.iCloudSyncEnabled ? "enabled" : "disabled"
        ])
        let start = Date()
        isReloading = true
        defer {
            isReloading = false
            let duration = Date().timeIntervalSince(start)
            if duration > 3 {
                print("[Fernlet] Persistence reload took \(String(format: "%.2f", duration)) seconds")
            }
        }

        do {
            let oldContainer = container
            let oldContext = oldContainer.viewContext
            try saveAndLockViewContext(oldContext)

            let configuration = Self.makeContainer(
                inMemory: inMemory,
                preferences: preferences,
                storeURL: reloadStoreURLOverrideForTesting ?? storeURL,
                iCloudAvailabilityOverride: iCloudAvailabilityOverride
            )
            try await Self.loadPersistentStoresAsync(
                for: configuration.container,
                preferences: preferences,
                inMemory: inMemory
            )
            configureViewContext(for: configuration.container)

            container = configuration.container
            didFailToLoad = false
            bindRemoteChanges(to: configuration.container)
            do {
                try removePersistentStores(from: oldContainer.persistentStoreCoordinator)
            } catch {
                print("[Fernlet] Failed to remove old persistent stores after reload swap: \(error)")
            }
            remoteChangeSubject.send(Notification(
                name: .NSPersistentStoreRemoteChange,
                object: configuration.container.persistentStoreCoordinator
            ))
            FernletAuditLog.log("persistence.reload.completed")
        } catch {
            FernletAuditLog.log("persistence.reload.failed", context: ["errorType": "\(type(of: error))"])
            throw error
        }
    }

    public var activeStoreDescription: NSPersistentStoreDescription? {
        container.persistentStoreDescriptions.first
    }

    public var activeStoreURL: URL? {
        activeStoreDescription?.url
    }

    private static func makeContainer(
        inMemory: Bool,
        preferences: StoragePreferences,
        storeURL: URL?,
        iCloudAvailabilityOverride: Bool? = nil
    ) -> (container: NSPersistentContainer, storeDescription: NSPersistentStoreDescription) {
        // Use plain NSPersistentContainer for in-memory stores — NSPersistentCloudKitContainer
        // dispatches its loadPersistentStores completion via the main actor on iOS 26+, which
        // deadlocks when the caller is already holding the main actor synchronously (e.g. tests).
        let container: NSPersistentContainer = inMemory
            ? NSPersistentContainer(name: "Fernlet", managedObjectModel: makeManagedObjectModel())
            : NSPersistentCloudKitContainer(name: "Fernlet", managedObjectModel: makeManagedObjectModel())
        let storeDescription = container.persistentStoreDescriptions.first ?? NSPersistentStoreDescription()
        configure(storeDescription, inMemory: inMemory, preferences: preferences, storeURL: storeURL, iCloudAvailabilityOverride: iCloudAvailabilityOverride)
        container.persistentStoreDescriptions = [storeDescription]
        return (container, storeDescription)
    }

    private static func configure(
        _ storeDescription: NSPersistentStoreDescription,
        inMemory: Bool,
        preferences: StoragePreferences,
        storeURL: URL?,
        iCloudAvailabilityOverride: Bool? = nil
    ) {
        storeDescription.setOption(FileProtectionType.complete as NSString, forKey: NSPersistentStoreFileProtectionKey)
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        storeDescription.shouldMigrateStoreAutomatically = true
        storeDescription.shouldInferMappingModelAutomatically = true

        if inMemory {
            storeDescription.url = URL(fileURLWithPath: "/dev/null")
            storeDescription.cloudKitContainerOptions = nil
        } else {
            if let storeURL {
                storeDescription.url = storeURL
            }
            // Only enable CloudKit when an iCloud account is present. Attempting to
            // configure CloudKit without an account causes NSCloudKitMirroringDelegate
            // to spam error logs and triggers a "account info cache" performance fault.
            // iCloudAvailabilityOverride lets tests exercise this path without a real account.
            let iCloudAvailable = iCloudAvailabilityOverride ?? (FileManager.default.ubiquityIdentityToken != nil)
            storeDescription.cloudKitContainerOptions = (preferences.iCloudSyncEnabled && iCloudAvailable)
                ? NSPersistentCloudKitContainerOptions(containerIdentifier: "iCloud.MBO.Fernlet")
                : nil
        }
    }

    // NSCocoaErrorDomain 134400 = CKAccountStatusNoAccount — CloudKit can't sync but
    // the local SQLite store is healthy. Never destroy data for this error.
    private static let cloudKitNoAccountErrorCode = 134400

    private static func loadPersistentStores(
        for container: NSPersistentContainer,
        preferences: StoragePreferences,
        inMemory: Bool
    ) -> Bool {
        var loadFailed = false
        let signpostID = StartupTiming.begin("PersistenceController.loadPersistentStores")
        func endSignpost() {
            StartupTiming.end("PersistenceController.loadPersistentStores", signpostID: signpostID)
        }

        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                print("[Fernlet] Persistent store failed to load: \(error), \(error.userInfo)")

                // CloudKit "no account" — store is fine, just disable CloudKit and retry.
                if error.domain == NSCocoaErrorDomain && error.code == cloudKitNoAccountErrorCode {
                    storeDescription.cloudKitContainerOptions = nil
                    container.loadPersistentStores { retryDescription, retryError in
                        if let retryError {
                            loadFailed = true
                            print("[Fernlet] Local-only fallback load failed: \(retryError)")
                        } else {
                            applyBackupExclusionIfNeeded(
                                preferences: preferences,
                                storeDescription: retryDescription,
                                inMemory: inMemory
                            )
                        }
                        endSignpost()
                    }
                    return
                }

                loadFailed = true
                endSignpost()
                return
            } else {
                applyBackupExclusionIfNeeded(
                    preferences: preferences,
                    storeDescription: storeDescription,
                    inMemory: inMemory
                )
                endSignpost()
            }
        }
        return loadFailed
    }

    private static func loadPersistentStoresAsync(
        for container: NSPersistentContainer,
        preferences: StoragePreferences,
        inMemory: Bool
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { storeDescription, error in
                if let error {
                    let nsError = error as NSError
                    // CloudKit "no account" — disable CloudKit and retry without throwing.
                    if nsError.domain == NSCocoaErrorDomain && nsError.code == cloudKitNoAccountErrorCode {
                        storeDescription.cloudKitContainerOptions = nil
                        container.loadPersistentStores { retryDescription, retryError in
                            if let retryError {
                                continuation.resume(throwing: retryError)
                            } else {
                                applyBackupExclusionIfNeeded(
                                    preferences: preferences,
                                    storeDescription: retryDescription,
                                    inMemory: inMemory
                                )
                                continuation.resume()
                            }
                        }
                        return
                    }
                    continuation.resume(throwing: error)
                    return
                }

                applyBackupExclusionIfNeeded(
                    preferences: preferences,
                    storeDescription: storeDescription,
                    inMemory: inMemory
                )
                continuation.resume()
            }
        }
    }

    private static func applyBackupExclusionIfNeeded(
        preferences: StoragePreferences,
        storeDescription: NSPersistentStoreDescription,
        inMemory: Bool
    ) {
        guard inMemory == false, let storeURL = storeDescription.url else { return }
        let excluded = preferences.localBackupExcludedFromiOSBackup
        let sidecarURLs = [storeURL,
                           URL(fileURLWithPath: storeURL.path + "-wal"),
                           URL(fileURLWithPath: storeURL.path + "-shm")]
        for url in sidecarURLs {
            do {
                try (url as NSURL).setResourceValue(excluded, forKey: URLResourceKey.isExcludedFromBackupKey)
            } catch {
                print("[Fernlet] Failed to set backup exclusion (\(excluded)) for \(url.lastPathComponent): \(error)")
            }
        }
    }

    private func configureViewContext(for container: NSPersistentContainer) {
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    private func bindRemoteChanges(to container: NSPersistentContainer) {
        remoteChangeCancellable = NotificationCenter.default
            .publisher(for: .NSPersistentStoreRemoteChange, object: container.persistentStoreCoordinator)
            .sink { [remoteChangeSubject] notification in
                remoteChangeSubject.send(notification)
            }
    }

    @MainActor
    private func saveAndLockViewContext(_ context: NSManagedObjectContext) throws {
        try context.performAndWait {
            if context.hasChanges {
                try context.save()
            }
            context.reset()
        }
    }

    private func removePersistentStores(from coordinator: NSPersistentStoreCoordinator) throws {
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
    }

    private static func makeManagedObjectModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        // Only cloud-safe, non-sensitive entities belong here.
        // Sealed entities (MenstrualNarrative, JournalNarrative) live in PrivatePersistenceController.
        model.entities = [
            makeFernletDatabaseRecordEntity(),
            makeSavedRecipeRecordEntity()
        ]
        return model
    }

    private static func makeFernletDatabaseRecordEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "FernletDatabaseRecord"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            makeAttribute("recordID", type: .stringAttributeType),
            makeAttribute("payloadData", type: .binaryDataAttributeType),
            makeAttribute("updatedAt", type: .dateAttributeType)
        ]
        return entity
    }

    private static func makeSavedRecipeRecordEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "SavedRecipeRecord"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            makeAttribute("idString", type: .stringAttributeType),
            makeAttribute("sourceURLString", type: .stringAttributeType),
            makeAttribute("name", type: .stringAttributeType),
            makeAttribute("ingredientsText", type: .stringAttributeType),
            makeAttribute("summary", type: .stringAttributeType),
            makeAttribute("servings", type: .integer64AttributeType, defaultValue: 1),
            makeAttribute("protein", type: .integer64AttributeType, defaultValue: 0),
            makeAttribute("carbs", type: .integer64AttributeType, defaultValue: 0),
            makeAttribute("fat", type: .integer64AttributeType, defaultValue: 0),
            makeAttribute("micronutrientsJSON", type: .stringAttributeType),
            makeAttribute("savedAt", type: .dateAttributeType)
        ]
        return entity
    }

    private static func makeAttribute(
        _ name: String,
        type: NSAttributeType,
        defaultValue: Any? = nil,
        allowsExternalBinaryDataStorage: Bool = false
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = true
        attribute.defaultValue = defaultValue
        attribute.allowsExternalBinaryDataStorage = allowsExternalBinaryDataStorage
        return attribute
    }
}
