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

/// Why ``PersistenceController/compactStoreAfterWipe()`` declined to run.
///
/// Not user-presentable: the wipe funnel turns it into the generic "leftover traces in your local
/// records" line, because the ROWS are already gone by the time this leg runs and only the file's
/// residue pass is affected.
public enum StoreCompactionError: Error {
    /// Another container reload was already in flight. Two concurrent reloads swap the live
    /// container out from under each other, so the compaction refuses rather than racing one.
    case reloadInFlight
}

/// User-presentable failure for when the primary Core Data store cannot be opened.
///
/// Thrown by the app-side startup flow when ``PersistenceController`` reports `didFailToLoad`;
/// the copy stresses that data was not deleted and points at the usual recoveries (device just
/// restarted and still locked, or storage full).
public enum PersistenceStoreLoadError: LocalizedError, Equatable {
    case primaryStoreUnavailable

    /// Package source, so every lookup passes `bundle: .module`: without it the resolution goes to
    /// `Bundle.main`, finds nothing, and silently renders the English `defaultValue` forever.
    public var errorDescription: String? {
        switch self {
        case .primaryStoreUnavailable:
            return String(localized: "persistence.error.primaryStoreUnavailable",
                          defaultValue: "Fernlet couldn't open your local records. Your data was not deleted. Unlock your device if it was just restarted, free up storage if needed, then try again.",
                          bundle: .module,
                          comment: "Shown at startup when the local Core Data store will not open. The second sentence is the reassurance and is the most important half — keep it early and unambiguous; the third lists the two usual causes.")
        }
    }
}

/// Owner of the app's synced Core Data stack: an `NSPersistentCloudKitContainer` built from a
/// programmatic, cloud-safe-only model.
///
/// Every CloudKitSync repository reads and writes through this controller's `container`. The
/// managed object model is assembled in code (no `.xcdatamodeld`) and contains ONLY
/// non-sensitive entities — the aggregate blob, saved recipes, custom items, coin and milestone
/// ledgers, and day rows; the sealed entities (`MenstrualNarrative`, `JournalNarrative`) live in
/// the protected-side `PrivatePersistenceController` and are never modeled here (S3).
///
/// Behavior and invariants:
/// - **CloudKit is opt-in twice**: mirroring options are configured only when the stored
///   preference enables sync AND an iCloud account is present; ``shared`` additionally forces
///   sync OFF at cold launch, and the app calls `reload(with:)` once the real preferences are
///   known.
/// - **Reload swaps containers wholesale**: `reload(with:)` saves and resets the old view
///   context, stands up and loads a new container, then detaches the old stores; subscribers
///   learn of the swap via a synthesized remote-change notification.
/// - **No-account resilience**: a CloudKit "no account" load error (code 134400) never fails the
///   store — CloudKit options are dropped and the load is retried local-only, since the SQLite
///   store itself is healthy.
/// - **Protection and backup**: stores use `FileProtectionType.complete`, persistent history and
///   remote-change notifications are always on, and iOS-backup exclusion follows the user's
///   preference (including the CloudKit `_SUPPORT` sidecar directory).
/// - **Local-only history prune**: when a store loads WITHOUT CloudKit mirroring (sync off, or no
///   iCloud account) nothing consumes the persistent-history log, so every successful load deletes
///   history older than ``localOnlyHistoryRetention`` (7 days) on a background context — best-effort,
///   audit-logged on failure, never on a mirrored store (its delegate owns that history).
/// - **DEBUG schema deploy**: the `INITIALIZE_CLOUDKIT_SCHEMA` launch argument (see
///   ``CloudKitSchemaDeploy``) pushes the model to the CloudKit development schema against a
///   throwaway scratch store on a background queue — compiled out of Release entirely.
///
/// `@Observable` and explicitly `nonisolated`; ``shared`` is a `nonisolated(unsafe)`
/// process-wide singleton and `reload(with:)` is `@MainActor`. Remote CloudKit pushes surface
/// through `remoteChangePublisher`, which ``CoreDataFernletRepository`` uses to invalidate its
/// caches.
@Observable
nonisolated public final class PersistenceController {
    /// Process-wide controller. Boots with the keychain-persisted preferences but FORCES iCloud
    /// sync off — the app decides when to enable mirroring via `reload(with:)` once
    /// onboarding/consent state is known.
    ///
    /// `@MainActor` rather than `nonisolated(unsafe)` (R9): every consumer — the repositories'
    /// no-argument inits, the app's reload path, the store facade — is already MainActor-isolated,
    /// working on `container.viewContext`, so the isolation the compiler now checks is the isolation
    /// the type always had by convention. `preview` next to it is isolated the same way.
    @MainActor public static let shared: PersistenceController = {
        var startupPreferences = StoragePreferencesStore.currentPreferences()
        startupPreferences.iCloudSyncEnabled = false
        return PersistenceController(preferences: startupPreferences)
    }()

    /// In-memory controller for SwiftUI previews and tests (plain `NSPersistentContainer`, no
    /// CloudKit, `/dev/null`-backed store).
    @MainActor
    public static let preview: PersistenceController = {
        let result = PersistenceController(inMemory: true, preferences: StoragePreferences(iCloudSyncEnabled: false))
        return result
    }()

    /// True while `reload(with:)` is swapping containers (observable, so UI can reflect it).
    public private(set) var isReloading = false

    /// The live persistent container. Replaced wholesale by `reload(with:)` — never cache the
    /// old value across a reload.
    @ObservationIgnored public private(set) var container: NSPersistentContainer
    /// Latched true when the initial store load failed for a reason other than the recoverable
    /// no-account case; cleared by a successful `reload(with:)`.
    public private(set) var didFailToLoad = false
    /// Fires when iCloud pushes a remote change to the local store, and once after each
    /// successful `reload(with:)` so subscribers re-read from the new container.
    @ObservationIgnored public let remoteChangePublisher: AnyPublisher<Notification, Never>
    #if DEBUG
    /// Test hook: overrides the store URL used by the next `reload(with:)`. DEBUG-only (R6) — a
    /// shipping build must not expose a way to redirect the next store load.
    @ObservationIgnored public var reloadStoreURLOverrideForTesting: URL?

    /// DEBUG-only: overrides ``localOnlyHistoryRetention`` for the next `reload(with:)`, so a test can
    /// prove the load path prunes un-consumed history (a real 7-day window is untestable — persistent
    /// history cannot be backdated). Instance state, not a static (R6). Absent from Release.
    @ObservationIgnored public var localOnlyHistoryRetentionOverrideForTesting: TimeInterval?
    #endif

    /// The history-retention window the next `reload(with:)` uses — the DEBUG test override when set,
    /// otherwise ``localOnlyHistoryRetention``. One accessor so the `#if DEBUG` fork lives in one place.
    private var reloadHistoryRetention: TimeInterval {
        #if DEBUG
        return localOnlyHistoryRetentionOverrideForTesting ?? Self.localOnlyHistoryRetention
        #else
        return Self.localOnlyHistoryRetention
        #endif
    }

    /// The store URL the next `reload(with:)` uses — the DEBUG test override when set, otherwise
    /// the controller's own. One accessor so the `#if DEBUG` fork lives in a single place.
    private var reloadStoreURL: URL? {
        #if DEBUG
        return reloadStoreURLOverrideForTesting ?? storeURL
        #else
        return storeURL
        #endif
    }

    private let inMemory: Bool
    private let storeURL: URL?
    /// When non-nil, overrides the real `FileManager.ubiquityIdentityToken` check. Injected by tests
    /// so CloudKit configuration logic can be exercised without a real iCloud account present.
    private let iCloudAvailabilityOverride: Bool?
    @ObservationIgnored private let remoteChangeSubject = PassthroughSubject<Notification, Never>()
    @ObservationIgnored private var remoteChangeCancellable: AnyCancellable?

    /// Builds and synchronously loads the stack.
    ///
    /// - Parameters:
    ///   - inMemory: use a plain in-memory container (previews/tests; avoids the
    ///     `NSPersistentCloudKitContainer` main-actor load-completion deadlock).
    ///   - preferences: decides CloudKit mirroring and backup exclusion at load time.
    ///   - storeURL: optional explicit store location (tests).
    ///   - iCloudAvailable: overrides the real ubiquity-token check (tests).
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
            inMemory: inMemory,
            historyRetention: Self.localOnlyHistoryRetention
        )
        configureViewContext(for: configuration.container)
        bindRemoteChanges(to: configuration.container)
        #if DEBUG
        // DEBUG-only, launch-argument-gated CloudKit schema deploy (see
        // Docs/CloudKit-Schema-Deploy.md). Compiled out of Release builds entirely.
        Self.initializeCloudKitSchemaIfRequested(inMemory: inMemory)
        #endif
    }

    /// The ordinary reload — every caller outside the wipe funnel. Forwards without compaction.
    ///
    /// Kept as a distinct overload (not a default on `compacting:`) because a defaulted extra
    /// parameter cannot witness a protocol requirement: the app target's
    /// `PrivacyPersistenceReloading` conformance resolves against exactly this signature.
    @MainActor
    public func reload(with preferences: StoragePreferences) async throws {
        try await reload(with: preferences, compacting: false)
    }

    /// Rebuilds the whole stack under new preferences (the sync-toggle path): saves and resets
    /// the old view context, loads a fresh container, swaps it in, detaches the old stores, and
    /// notifies subscribers via a synthesized remote-change event.
    ///
    /// - Parameters:
    ///   - preferences: the preferences the fresh container is configured from.
    ///   - compacting: one-shot SQLite compaction for ``compactStoreAfterWipe()`` — see that
    ///     method and ``configure(_:inMemory:preferences:storeURL:iCloudAvailabilityOverride:compacting:)``.
    ///     Never set by the ordinary sync-toggle path (use ``reload(with:)``).
    /// - Throws: the store-load error when the new container cannot load (the old container has
    ///   already been locked; `didFailToLoad` is not set by a failed reload).
    @MainActor
    public func reload(with preferences: StoragePreferences, compacting: Bool) async throws {
        FernletAuditLog.log("persistence.reload.started", context: [
            "iCloudSync": preferences.iCloudSyncEnabled ? "enabled" : "disabled",
            "compacting": compacting ? "true" : "false"
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
                storeURL: reloadStoreURL,
                iCloudAvailabilityOverride: iCloudAvailabilityOverride,
                compacting: compacting
            )
            try await Self.loadPersistentStoresAsync(
                for: configuration.container,
                preferences: preferences,
                inMemory: inMemory,
                historyRetention: reloadHistoryRetention
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

    /// Removes the deleted-row residue from the synced store's FILE, after "delete everything" has
    /// dropped every row from it. The main-store counterpart of
    /// `PrivatePersistenceController.rebuildStore()`, and deliberately **not** the same mechanism.
    ///
    /// Why not a destroy-and-re-add. The sealed store is local-only, so destroying its file loses
    /// nothing but the file. This store is mirrored by `NSPersistentCloudKitContainer`, and the
    /// mirror's export queue is *persistent history inside this very file*: at the moment the wipe
    /// finishes, the deletes it just made may not have reached the server yet. Destroying the file
    /// would throw that queue away — the server copy would survive with nothing left able to
    /// address it, and the fresh, empty store would then IMPORT it all back down. A wipe that
    /// resurrects the data is far worse than the residue this method exists to remove, so a destroy
    /// is banned here, not merely avoided.
    ///
    /// What it does instead, both through the ordinary reload path so the CloudKit mirror is
    /// re-established by a real `loadPersistentStores` (a hand-rolled `addPersistentStore` would
    /// leave sync silently dead for the session):
    /// 1. `journal_mode=DELETE` checkpoints the `-wal` into the database file and removes it. In WAL
    ///    mode the main file still holds the PRE-delete page images, so this is the step that makes
    ///    the file itself reflect the deletes.
    /// 2. `NSSQLiteManualVacuumOption` then rebuilds the file, so the freed pages carrying those old
    ///    row images are not copied forward. VACUUM preserves logical content — rows, persistent
    ///    history, and the mirror's metadata all survive it, which is exactly why it is safe here.
    ///
    /// A second reload restores WAL journalling for the rest of the session.
    ///
    /// - Important: honest limits, same as the sealed rebuild — this removes the *logical* residue.
    ///   It cannot promise the underlying flash blocks are gone (APFS copy-on-write and
    ///   wear-levelling), and it does not vacuum the app-group or sealed stores, which have their
    ///   own legs. Rows still queued for export are preserved on purpose, so a wiped device that is
    ///   offline finishes deleting the server copy when it next has a network.
    /// - Throws: ``StoreCompactionError/reloadInFlight``, or the load error from the compaction
    ///   reload. The container is only swapped on success, so a throw leaves the app on its old,
    ///   working store with the rows already gone — the caller reports it rather than the wipe
    ///   claiming residue it did not remove.
    @MainActor
    public func compactStoreAfterWipe() async throws {
        // An in-memory (`/dev/null`) store has no file and no residue; tests take this path.
        guard !inMemory else { return }
        // Never a second concurrent reload: two of them swap `container` out from under each other
        // and can leave two coordinators over one file. The wipe funnel orders this leg BEFORE the
        // preference reset precisely so the app's own preference-driven reload cannot be in flight
        // here; this guard is what makes any other arrival safe rather than corrupting.
        guard !isReloading else { throw StoreCompactionError.reloadInFlight }
        let preferences = StoragePreferencesStore.currentPreferences()
        try await reload(with: preferences, compacting: true)
        do {
            try await reload(with: preferences)
        } catch {
            // The compaction landed — the residue is gone. All that failed is the return to WAL
            // journalling, which costs write throughput until the next launch re-loads normally.
            // Named rather than discarded (R7), but NOT rethrown: failing the wipe here would
            // report a privacy failure that did not happen.
            FernletAuditLog.log("persistence.compact.journalRestoreFailed", context: [
                "errorType": "\(type(of: error))"
            ])
        }
    }

    /// The live container's first (only) store description.
    public var activeStoreDescription: NSPersistentStoreDescription? {
        container.persistentStoreDescriptions.first
    }

    /// On-disk URL of the active store, if any.
    public var activeStoreURL: URL? {
        activeStoreDescription?.url
    }

    private static func makeContainer(
        inMemory: Bool,
        preferences: StoragePreferences,
        storeURL: URL?,
        iCloudAvailabilityOverride: Bool? = nil,
        compacting: Bool = false
    ) -> (container: NSPersistentContainer, storeDescription: NSPersistentStoreDescription) {
        // Use plain NSPersistentContainer for in-memory stores — NSPersistentCloudKitContainer
        // dispatches its loadPersistentStores completion via the main actor on iOS 26+, which
        // deadlocks when the caller is already holding the main actor synchronously (e.g. tests).
        let container: NSPersistentContainer = inMemory
            ? NSPersistentContainer(name: "Fernlet", managedObjectModel: makeManagedObjectModel())
            : NSPersistentCloudKitContainer(name: "Fernlet", managedObjectModel: makeManagedObjectModel())
        let storeDescription = container.persistentStoreDescriptions.first ?? NSPersistentStoreDescription()
        configure(storeDescription, inMemory: inMemory, preferences: preferences, storeURL: storeURL, iCloudAvailabilityOverride: iCloudAvailabilityOverride, compacting: compacting)
        container.persistentStoreDescriptions = [storeDescription]
        return (container, storeDescription)
    }

    /// - Parameter compacting: adds the one-shot SQLite options ``compactStoreAfterWipe()`` needs.
    ///   Both are applied while the store is being added and neither survives the load, so the
    ///   ordinary path is unaffected.
    private static func configure(
        _ storeDescription: NSPersistentStoreDescription,
        inMemory: Bool,
        preferences: StoragePreferences,
        storeURL: URL?,
        iCloudAvailabilityOverride: Bool? = nil,
        compacting: Bool = false
    ) {
        storeDescription.setOption(FileProtectionType.complete as NSString, forKey: NSPersistentStoreFileProtectionKey)
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        storeDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        storeDescription.shouldMigrateStoreAutomatically = true
        storeDescription.shouldInferMappingModelAutomatically = true
        if compacting {
            // Order matters and is why both ride the SAME load: the pragma is applied when the
            // connection opens (checkpointing the `-wal` into the file and removing it), so the
            // vacuum that follows rebuilds a file that already reflects the deletes.
            storeDescription.setOption(["journal_mode": "DELETE"] as NSDictionary, forKey: NSSQLitePragmasOption)
            storeDescription.setOption(true as NSNumber, forKey: NSSQLiteManualVacuumOption)
        }

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
        inMemory: Bool,
        historyRetention: TimeInterval
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
                            finishSuccessfulLoad(
                                container: container,
                                preferences: preferences,
                                storeDescription: retryDescription,
                                inMemory: inMemory,
                                historyRetention: historyRetention
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
                finishSuccessfulLoad(
                    container: container,
                    preferences: preferences,
                    storeDescription: storeDescription,
                    inMemory: inMemory,
                    historyRetention: historyRetention
                )
                endSignpost()
            }
        }
        return loadFailed
    }

    private static func loadPersistentStoresAsync(
        for container: NSPersistentContainer,
        preferences: StoragePreferences,
        inMemory: Bool,
        historyRetention: TimeInterval
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
                                finishSuccessfulLoad(
                                    container: container,
                                    preferences: preferences,
                                    storeDescription: retryDescription,
                                    inMemory: inMemory,
                                    historyRetention: historyRetention
                                )
                                continuation.resume()
                            }
                        }
                        return
                    }
                    continuation.resume(throwing: error)
                    return
                }

                finishSuccessfulLoad(
                    container: container,
                    preferences: preferences,
                    storeDescription: storeDescription,
                    inMemory: inMemory,
                    historyRetention: historyRetention
                )
                continuation.resume()
            }
        }
    }

    /// Every successful store load (first load, no-account retry, and both reload variants) funnels
    /// here: backup exclusion, then the local-only history prune.
    private static func finishSuccessfulLoad(
        container: NSPersistentContainer,
        preferences: StoragePreferences,
        storeDescription: NSPersistentStoreDescription,
        inMemory: Bool,
        historyRetention: TimeInterval
    ) {
        applyBackupExclusionIfNeeded(
            preferences: preferences,
            storeDescription: storeDescription,
            inMemory: inMemory
        )
        // Persistent history is always ON (remote-change notifications need it), but only an
        // NSPersistentCloudKitContainer mirroring delegate ever CONSUMES and trims it. On a store
        // loaded without CloudKit options (sync off — the cold-launch default and the local-only
        // user's steady state — or no iCloud account) nothing does, so the ATRANSACTION/ACHANGE
        // tables grew for the life of the install. Prune everything older than the retention
        // window; the in-memory `/dev/null` store records nothing durable and is skipped.
        guard !inMemory, storeDescription.cloudKitContainerOptions == nil else { return }
        pruneUnconsumedHistory(before: Date().addingTimeInterval(-historyRetention), in: container)
    }

    /// Retention window for persistent history on a store loaded WITHOUT CloudKit mirroring (R2 — a
    /// named bound). Seven days keeps recent transactions available across a sync-off→on
    /// transition (the mirroring delegate treats an expired token by re-exporting, a one-time cost).
    static let localOnlyHistoryRetention: TimeInterval = 7 * 24 * 60 * 60

    /// Best-effort delete of persistent history older than `cutoff`, on a background context so the
    /// load path never stalls. A prune failure must not fail the store load, so it is audit-logged and
    /// never thrown (R7).
    private static func pruneUnconsumedHistory(before cutoff: Date, in container: NSPersistentContainer) {
        let context = container.newBackgroundContext()
        context.perform {
            do {
                try context.execute(NSPersistentHistoryChangeRequest.deleteHistory(before: cutoff))
            } catch {
                FernletAuditLog.log("persistence.historyPruneFailed", context: ["error": "\(error)"])
            }
        }
    }

    #if DEBUG
    /// DEBUG-only: runs the local-only history pruner against the CURRENT container with an explicit
    /// cutoff, so a test can prove history is recorded and then removed without waiting out the
    /// retention window. Absent from Release.
    public func pruneUnconsumedHistoryForTesting(before cutoff: Date) {
        Self.pruneUnconsumedHistory(before: cutoff, in: container)
    }
    #endif

    #if DEBUG
    /// One-shot latch so a second flagged, non-inMemory `PersistenceController` init in the same
    /// process cannot push the schema twice. This is a lazily-initialized `static let`, not a
    /// mutable flag: Swift runs a static's initializer exactly once per process, atomically, so
    /// the "runs once" property is a language mechanism rather than a convention (R6/R9 — no
    /// mutable global and no `nonisolated(unsafe)` opt-out).
    private static let schemaDeployOnce: Void = { performCloudKitSchemaDeploy() }()

    /// Named upper bound on the scratch-store load wait inside the deploy (R2).
    private static let schemaDeployLoadTimeoutSeconds = 60.0

    /// DEBUG-only, launch-argument-gated CloudKit schema deploy.
    ///
    /// When the app is launched with the `INITIALIZE_CLOUDKIT_SCHEMA` argument, this pushes the
    /// Core Data model to the CloudKit **development** schema for `iCloud.MBO.Fernlet` via
    /// `NSPersistentCloudKitContainer.initializeCloudKitSchema(options:)`. Promotion of that
    /// schema to production is an owner action in the CloudKit console — code cannot do it. See
    /// Docs/CloudKit-Schema-Deploy.md for the full ritual.
    ///
    /// The whole method is wrapped in `#if DEBUG`, so it is compiled out of Release builds — the
    /// deploy is impossible to trigger in a shipping binary. It runs against a throwaway scratch
    /// store and forces CloudKit options on, so it works regardless of the user's iCloud toggle
    /// (`PersistenceController.shared` forces sync off at cold launch) and never touches the real
    /// store. The schema push targets the container identifier's Development environment; the
    /// local store is only scratch space for the dummy objects `initializeCloudKitSchema` creates
    /// and rolls back.
    ///
    /// The entire throwaway-store flow (create → load → push → tear down) runs on a background
    /// dispatch queue, never the main thread. `initializeCloudKitSchema` is a synchronous,
    /// network-bound call and the load completion is delivered on the main actor on iOS 26+, so
    /// running it inline at launch would freeze the main thread (and could trip a device launch
    /// watchdog). Owning the container entirely inside the background closure also keeps the
    /// non-`Sendable` `NSPersistentCloudKitContainer` from ever crossing an isolation boundary.
    private static func initializeCloudKitSchemaIfRequested(inMemory: Bool) {
        guard CloudKitSchemaDeploy.isRequested(arguments: ProcessInfo.processInfo.arguments) else { return }
        guard !inMemory else {
            FernletAuditLog.log("cloudkit.schema.initialize.skipped", context: ["reason": "in-memory-store"])
            return
        }
        // Touching the once-latch runs the deploy on the FIRST reach and is a no-op on every
        // later one. `Void` carries no failure information, so this is a legal `_ =` discard.
        _ = schemaDeployOnce
    }

    /// The deploy itself — the body the ``schemaDeployOnce`` latch runs exactly once.
    private static func performCloudKitSchemaDeploy() {
        FernletAuditLog.log("cloudkit.schema.initialize.started")
        print("[Fernlet] INITIALIZE_CLOUDKIT_SCHEMA: pushing the Core Data model to the CloudKit DEVELOPMENT schema for container iCloud.MBO.Fernlet…")

        // Run the whole deploy off the main thread. The container is created and torn down inside
        // this closure so it never crosses an isolation boundary; the store load completion is
        // dispatched to the main actor on iOS 26+, and we wait for it from this background queue
        // (never the main thread), so the wait cannot deadlock.
        DispatchQueue.global(qos: .userInitiated).async {
            let container = NSPersistentCloudKitContainer(name: "Fernlet", managedObjectModel: makeManagedObjectModel())
            let scratchURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("CloudKitSchemaDeploy-\(UUID().uuidString).sqlite")
            let description = container.persistentStoreDescriptions.first ?? NSPersistentStoreDescription()
            description.url = scratchURL
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: "iCloud.MBO.Fernlet")
            container.persistentStoreDescriptions = [description]

            let loadSemaphore = DispatchSemaphore(value: 0)
            var loadError: Error?
            container.loadPersistentStores { _, error in
                loadError = error
                loadSemaphore.signal()
            }
            // Bounded wait (R2): a store the mirroring delegate cannot open would otherwise park
            // this queue for the process lifetime with no signal at all.
            guard loadSemaphore.wait(timeout: .now() + Self.schemaDeployLoadTimeoutSeconds) == .success else {
                FernletAuditLog.log("cloudkit.schema.initialize.failed", context: ["stage": "loadTimeout"])
                print("[Fernlet] ❌ CloudKit schema deploy: scratch store load timed out")
                cleanUpScratchStore(container: container, scratchURL: scratchURL)
                return
            }

            if let loadError {
                FernletAuditLog.log("cloudkit.schema.initialize.failed", context: [
                    "stage": "load",
                    "errorType": "\(type(of: loadError))"
                ])
                print("[Fernlet] ❌ CloudKit schema deploy FAILED to load scratch store: \(loadError)")
                cleanUpScratchStore(container: container, scratchURL: scratchURL)
                return
            }
            do {
                try container.initializeCloudKitSchema(options: [])
                FernletAuditLog.log("cloudkit.schema.initialize.succeeded")
                print("[Fernlet] ✅ CloudKit schema initialized in DEVELOPMENT. Next: verify the record types in the CloudKit console, then promote Development → Production (owner action in the console UI). See Docs/CloudKit-Schema-Deploy.md.")
            } catch {
                FernletAuditLog.log("cloudkit.schema.initialize.failed", context: [
                    "stage": "initialize",
                    "errorType": "\(type(of: error))"
                ])
                print("[Fernlet] ❌ CloudKit schema initialization FAILED: \(error). Ensure the simulator is signed into iCloud and the scheme's CloudKit environment is Development.")
            }
            cleanUpScratchStore(container: container, scratchURL: scratchURL)
        }
    }

    /// Detach the throwaway store from its coordinator (stopping its CloudKit mirroring delegate)
    /// and delete all three SQLite files. Detaching first is what stops the mirroring delegate from
    /// continuing to mirror into a store whose backing file we then remove; deleting `-wal`/`-shm`
    /// alongside the `.sqlite` avoids leaving sidecars behind in the temp dir.
    private static func cleanUpScratchStore(container: NSPersistentCloudKitContainer, scratchURL: URL) {
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            do {
                try coordinator.remove(store)
            } catch {
                print("[Fernlet] CloudKit schema deploy: failed to detach scratch store: \(error)")
            }
        }
        let fileManager = FileManager.default
        for path in [scratchURL.path, scratchURL.path + "-wal", scratchURL.path + "-shm"] {
            guard fileManager.fileExists(atPath: path) else { continue }
            do {
                try fileManager.removeItem(at: URL(fileURLWithPath: path))
            } catch {
                // Best-effort cleanup still names its failure (R7) — matching the detach
                // reporting above; a left-behind scratch file is harmless but not invisible.
                print("[Fernlet] CloudKit schema deploy: failed to delete scratch file \(path): \(error)")
            }
        }
    }
    #endif

    private static func applyBackupExclusionIfNeeded(
        preferences: StoragePreferences,
        storeDescription: NSPersistentStoreDescription,
        inMemory: Bool
    ) {
        guard inMemory == false, let storeURL = storeDescription.url else { return }
        // includeSupportDir: true — none of the synced model's attributes opt into
        // `allowsExternalBinaryDataStorage` today, but `NSPersistentCloudKitContainer` provisions a
        // sibling `.<StoreName>_SUPPORT/` directory for mirroring metadata and may externalize asset
        // payloads there, so we exclude it to match the sealed store and close the latent omission.
        // Excluding a directory that does not exist yet just logs harmlessly.
        BackupExclusion.apply(
            storeURL: storeURL,
            excluded: preferences.localBackupExcludedFromiOSBackup,
            includeSupportDir: true
        )
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

    /// Builds the programmatic model holding only the cloud-safe entities; sealed entities are
    /// modeled solely by the protected-side `PrivatePersistenceController`.
    private static func makeManagedObjectModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        // Only cloud-safe, non-sensitive entities belong here.
        // Sealed entities (MenstrualNarrative, JournalNarrative) live in PrivatePersistenceController.
        model.entities = [
            makeFernletDatabaseRecordEntity(),
            makeSavedRecipeRecordEntity(),
            makeCustomItemRecordEntity(),
            makeCoinLedgerRecordEntity(),
            makeMilestoneLedgerRecordEntity(),
            makeDayRecordEntity()
        ]
        return model
    }

    private static func makeFernletDatabaseRecordEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "FernletDatabaseRecord"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            CoreDataModelBuilding.makeAttribute("recordID", type: .stringAttributeType),
            CoreDataModelBuilding.makeAttribute("payloadData", type: .binaryDataAttributeType),
            CoreDataModelBuilding.makeAttribute("updatedAt", type: .dateAttributeType)
        ]
        return entity
    }

    private static func makeSavedRecipeRecordEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "SavedRecipeRecord"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            CoreDataModelBuilding.makeAttribute("idString", type: .stringAttributeType),
            CoreDataModelBuilding.makeAttribute("sourceURLString", type: .stringAttributeType),
            CoreDataModelBuilding.makeAttribute("name", type: .stringAttributeType),
            CoreDataModelBuilding.makeAttribute("ingredientsText", type: .stringAttributeType),
            CoreDataModelBuilding.makeAttribute("summary", type: .stringAttributeType),
            CoreDataModelBuilding.makeAttribute("servings", type: .integer64AttributeType, defaultValue: 1),
            CoreDataModelBuilding.makeAttribute("protein", type: .integer64AttributeType, defaultValue: 0),
            CoreDataModelBuilding.makeAttribute("carbs", type: .integer64AttributeType, defaultValue: 0),
            CoreDataModelBuilding.makeAttribute("fat", type: .integer64AttributeType, defaultValue: 0),
            CoreDataModelBuilding.makeAttribute("micronutrientsJSON", type: .stringAttributeType),
            CoreDataModelBuilding.makeAttribute("savedAt", type: .dateAttributeType),
            // STEP 0 (Docs/AI-Feature-Expansion-2026-07-23.md §9.1): the full structured
            // `RecipeDefinition` (structured ingredients, real source, optional webImport) as a
            // versioned JSON blob — the same `idString + payloadData` shape as DayRecord / CoinLedger /
            // CustomItem / Milestone. Additive-only: the typed columns above are NEVER removed or
            // retyped (CloudKit's mirrored schema is append-only, and un-updated paired devices keep
            // writing legacy-shape rows forever). Writers populate BOTH; readers prefer this and fall
            // back to the legacy columns. Plain binary, not external storage (CloudKit rejects external
            // storage at store load) — one recipe is far under CloudKit's per-field budget. Adding an
            // optional attribute is a lightweight inferred migration covered by the store options above
            // (shouldMigrateStoreAutomatically / shouldInferMappingModelAutomatically). NOTE: this new
            // attribute must go through the STEP 0c CloudKit prod-schema deploy ritual
            // (Docs/CloudKit-Schema-Deploy.md) before any shipping build writes it.
            CoreDataModelBuilding.makeAttribute("payloadData", type: .binaryDataAttributeType)
        ]
        return entity
    }

    private static func makeCustomItemRecordEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "CustomItemRecord"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            CoreDataModelBuilding.makeAttribute("idString", type: .stringAttributeType),
            // The whole CustomizationItem (incl. palette-indexed pixel grid) as JSON. Plain binary, NOT
            // external storage: NSPersistentCloudKitContainer rejects `allowsExternalBinaryDataStorage`
            // at store load (see the makeContainer note above), and a palette-indexed texture is ~1 KB —
            // far under CloudKit's per-field budget — so inline binary is both required and sufficient.
            CoreDataModelBuilding.makeAttribute("payloadData", type: .binaryDataAttributeType),
            CoreDataModelBuilding.makeAttribute("createdAt", type: .dateAttributeType)
        ]
        return entity
    }

    private static func makeCoinLedgerRecordEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "CoinLedgerRecord"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            // `idString` is the ledger entry's stable id (e.g. "earn:2026-06-29"). On ONE device the
            // repository upserts by it, so a re-mint is a no-op. CloudKit does NOT collapse rows by this
            // attribute (it mirrors by record identity, and NSPersistentCloudKitContainer can't enforce
            // uniqueness), so two devices can produce two rows with the same idString — `CoinEconomy`
            // collapses those by id when aggregating. That application-level dedup is what makes coins
            // idempotent and double-grant-free across devices.
            CoreDataModelBuilding.makeAttribute("idString", type: .stringAttributeType),
            // The CoinLedgerEntry as JSON (plain binary, tens of bytes — far under CloudKit's budget).
            CoreDataModelBuilding.makeAttribute("payloadData", type: .binaryDataAttributeType),
            CoreDataModelBuilding.makeAttribute("createdAt", type: .dateAttributeType)
        ]
        return entity
    }

    private static func makeMilestoneLedgerRecordEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "MilestoneLedgerRecord"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            // `idString` is the milestone event's deterministic id (e.g. "event:journal:<uuid>").
            // Same dedup story as CoinLedgerRecord: one device upserts by it; across devices CloudKit
            // can hold duplicate-id rows and `MilestoneEconomy` collapses them when aggregating.
            CoreDataModelBuilding.makeAttribute("idString", type: .stringAttributeType),
            // The MilestoneLedgerEntry as JSON (plain binary, tens of bytes).
            CoreDataModelBuilding.makeAttribute("payloadData", type: .binaryDataAttributeType),
            CoreDataModelBuilding.makeAttribute("createdAt", type: .dateAttributeType)
        ]
        return entity
    }

    private static func makeDayRecordEntity() -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = "DayRecord"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            // `dateKey` ("YYYY-MM-DD") is the day's stable logical id — the repository upserts by it so a
            // re-save of the same day on one device is a no-op. Like CustomItem/CoinLedger, CloudKit does
            // NOT collapse rows by this attribute (it mirrors by record identity), so two devices can
            // produce two rows for one dateKey; `DayRecordRepository` collapses those on load by max
            // `updatedAt` (a dict read can't hold two rows for one key) and self-heals the duplicate.
            CoreDataModelBuilding.makeAttribute("dateKey", type: .stringAttributeType),
            // One FernletDay (already privacy-sanitized at the write boundary) as JSON. Plain binary, not
            // external storage (CloudKit rejects external storage at store load) — a single day is far
            // under CloudKit's per-field budget, which is exactly why per-day rows remove the 370 cap.
            CoreDataModelBuilding.makeAttribute("payloadData", type: .binaryDataAttributeType),
            // Per-day last-writer-wins stamp: lets a same-day cross-device conflict resolve by recency and
            // gives a future mesh-sync a max(updatedAt) union key.
            CoreDataModelBuilding.makeAttribute("updatedAt", type: .dateAttributeType)
        ]
        return entity
    }
}
