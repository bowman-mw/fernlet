import CoreData
import FernletCrypto
import FernletFoundation
import CryptoKit
import Foundation
import FernletDomainModel
import PrivateStoreCore

public nonisolated struct MenstrualNarrative: Identifiable, Codable, Equatable {
    public var id: UUID
    public var hkExternalUUID: String
    public var dateKey: String
    public var note: String?
    public var symptomFlags: [PeriodSymptom]
    public var customSymptomScales: [String: Int]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        hkExternalUUID: String,
        dateKey: String,
        note: String? = nil,
        symptomFlags: [PeriodSymptom] = [],
        customSymptomScales: [String: Int] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.hkExternalUUID = hkExternalUUID
        self.dateKey = dateKey
        self.note = note
        self.symptomFlags = symptomFlags
        self.customSymptomScales = customSymptomScales
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public nonisolated final class MenstrualNarrativeRepository {
    private let context: NSManagedObjectContext
    private let crypto = ColumnCrypto(label: "menstrual-narrative")

    /// Device-local marker for "this install has written cycle narratives at some point", used by the
    /// targeted sealed-backup restore to tell TWO very different empty stores apart:
    ///
    /// - **never populated** (a genuine reinstall / new device) — restoring the sealed backup is the
    ///   whole point, and there is nothing local to lose.
    /// - **emptied by the user** (they deleted their cycle entries) — the cloud backup is stale by
    ///   construction, because `PeriodTrackerStore.deleteEntry` hard-deletes the row and does NOT
    ///   reconcile the sealed backup. Restoring there would silently resurrect notes the user
    ///   deliberately deleted, which is precisely the harm the sealed store exists to prevent.
    ///
    /// A plain row count cannot distinguish them, so this flag carries the missing bit. Deliberately in
    /// **standard (device-local, non-synced) defaults**: iOS drops the app container on uninstall, so a
    /// real reinstall clears it for free — which is exactly the "never populated" semantics we want —
    /// while a delete-all on a live install leaves it SET, so the wipe cannot be undone by a stale cloud
    /// copy. Never cleared once set; it is a one-way "this device has diverged" latch.
    private static let everStoredDefaultsKey = "fernlet.menstrualNarrative.everStored"

    /// Injected so tests get an isolated suite — the latch is process-global otherwise, and one test
    /// writing a narrative would leak "this device has diverged" into every later test in the run.
    private let defaults: UserDefaults

    public var hasEverStoredNarrative: Bool {
        defaults.bool(forKey: Self.everStoredDefaultsKey)
    }

    private func markNarrativeStored() {
        defaults.set(true, forKey: Self.everStoredDefaultsKey)
    }

    public init(controller: PrivatePersistenceController? = nil, defaults: UserDefaults = .standard) {
        self.context = (controller ?? .shared).container.viewContext
        self.defaults = defaults
    }

    public init(context: NSManagedObjectContext, defaults: UserDefaults = .standard) {
        self.context = context
        self.defaults = defaults
    }

    public func insert(_ narrative: MenstrualNarrative, contentKey: SymmetricKey?) throws {
        guard let contentKey else { throw FernletLockError.locked }
        try context.performAndWait {
            let object = NSEntityDescription.insertNewObject(forEntityName: "MenstrualNarrative", into: context)
            try apply(narrative, to: object, contentKey: contentKey, createdAt: narrative.createdAt)
            // Save, then prune history so a re-sealed (updated) row leaves no prior ciphertext in the
            // persistent-history transaction log (best-effort).
            try PrivatePersistentHistoryPruner.saveAndPrune(context)
            // Latch AFTER a successful save, so a failed write never claims this device has diverged.
            markNarrativeStored()
        }
    }

    /// Inserts many narratives in a SINGLE transaction: either all commit or none do. Used by the
    /// sealed-backup RESTORE so a mid-batch failure cannot leave a partially-populated store. A partial
    /// store would otherwise trip the restore no-clobber gate (`narrativeCount() != 0`) on the next
    /// launch and never retry, silently dropping the un-inserted sealed records. On any per-record
    /// failure the whole batch is rolled back and the error rethrown, leaving the store empty so the
    /// next launch re-pulls the full backup.
    public func insertAtomically(_ narratives: [MenstrualNarrative], contentKey: SymmetricKey?) throws {
        guard let contentKey else { throw FernletLockError.locked }
        guard !narratives.isEmpty else { return }
        try context.performAndWait {
            do {
                for narrative in narratives {
                    let object = NSEntityDescription.insertNewObject(forEntityName: "MenstrualNarrative", into: context)
                    try apply(narrative, to: object, contentKey: contentKey, createdAt: narrative.createdAt)
                }
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
            // Prune history after the atomic restore so no per-record transaction lingers in the
            // persistent-history transaction log (best-effort).
            try? PrivatePersistentHistoryPruner.prune(context: context)
            // Latch AFTER the transaction commits. A restore that populates the store also counts as
            // "this device has narratives", so a later delete-everything + un-hide cannot re-pull them.
            markNarrativeStored()
        }
    }

    public func update(_ narrative: MenstrualNarrative, contentKey: SymmetricKey?) throws {
        guard let contentKey else { throw FernletLockError.locked }
        try context.performAndWait {
            let request = request(id: narrative.id)
            guard let object = try context.fetch(request).first else { return }
            let createdAt = object.value(forKey: "createdAt") as? Date ?? narrative.createdAt
            try apply(narrative, to: object, contentKey: contentKey, createdAt: createdAt)
            // Save, then prune history so the prior ciphertext for this row is not retained in the
            // persistent-history transaction log (best-effort).
            try PrivatePersistentHistoryPruner.saveAndPrune(context)
        }
    }

    public func delete(id: UUID) throws {
        try context.performAndWait {
            let request = request(id: id)
            try context.fetch(request).forEach(context.delete)
            try context.save()
            try PrivatePersistentHistoryPruner.prune(context: context)
        }
    }

    /// Drops every stored narrative. Deletes rows WITHOUT decrypting them, so it works while the app is
    /// locked and while cycle tracking is hidden — the property that lets "delete my data" stay
    /// available even when reading that data is not. Mirrors `WorryNarrativeRepository.deleteAll()`.
    public func deleteAll() throws {
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MenstrualNarrative")
            let rows = try context.fetch(request)
            guard !rows.isEmpty else { return }
            rows.forEach(context.delete)
            try context.save()
            try PrivatePersistentHistoryPruner.prune(context: context)
        }
    }

    /// Total number of stored narratives, counted without decrypting (or even faulting in) any rows.
    /// Lets the sealed-backup export size its chunks up front so it never materializes the whole
    /// history at once — see `narratives(offset:limit:contentKey:)`.
    public func narrativeCount() throws -> Int {
        try context.performAndWait {
            try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "MenstrualNarrative"))
        }
    }

    /// A single page of narratives, decrypted, in a stable total order (`dateKey` then the unique
    /// `hkExternalUUID` tiebreaker). Backs the chunked sealed-backup export: paging by
    /// `offset`/`limit` keeps each chunk bounded regardless of how long the cycle history is,
    /// instead of loading every record into memory before sealing. The sort is a *total* order so
    /// successive pages neither overlap nor skip rows. Replaces the former unbounded
    /// `allNarratives` (and avoids the per-day key enumeration that `narratives(in:)` performs,
    /// catastrophic for an unbounded date range).
    public func narratives(offset: Int, limit: Int, contentKey: SymmetricKey?) throws -> [MenstrualNarrative] {
        guard let contentKey, limit > 0 else { return [] }
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MenstrualNarrative")
            request.sortDescriptors = [
                NSSortDescriptor(key: "dateKey", ascending: true),
                NSSortDescriptor(key: "hkExternalUUID", ascending: true)
            ]
            request.fetchOffset = max(0, offset)
            request.fetchLimit = limit
            return try context.fetch(request).compactMap { object in
                do {
                    return try decrypt(object, contentKey: contentKey)
                } catch {
                    return nil
                }
            }
        }
    }

    public func narratives(in dateRange: DateInterval, contentKey: SymmetricKey?) throws -> [MenstrualNarrative] {
        guard let contentKey else { return [] }
        let keys = Self.dateKeys(in: dateRange)
        guard !keys.isEmpty else { return [] }
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MenstrualNarrative")
            request.predicate = NSPredicate(format: "dateKey IN %@", keys)
            request.sortDescriptors = [NSSortDescriptor(key: "dateKey", ascending: true)]
            return try context.fetch(request).compactMap { object in
                do {
                    return try decrypt(object, contentKey: contentKey)
                } catch {
                    return nil
                }
            }
        }
    }

    public func narrative(forHKUUID hkExternalUUID: String, contentKey: SymmetricKey?) throws -> MenstrualNarrative? {
        guard let contentKey else { return nil }
        return try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "MenstrualNarrative")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "hkExternalUUID == %@", hkExternalUUID)
            guard let object = try context.fetch(request).first else { return nil }
            return try decrypt(object, contentKey: contentKey)
        }
    }

    private func apply(_ narrative: MenstrualNarrative, to object: NSManagedObject, contentKey: SymmetricKey, createdAt: Date) throws {
        object.setValue(narrative.id, forKey: "id")
        object.setValue(narrative.hkExternalUUID, forKey: "hkExternalUUID")
        object.setValue(narrative.dateKey, forKey: "dateKey")
        object.setValue(try crypto.sealOptionalString(narrative.note, contentKey: contentKey), forKey: "noteCiphertext")
        object.setValue(try crypto.seal(narrative.symptomFlags.map(\.rawValue), contentKey: contentKey), forKey: "symptomFlagsCiphertext")
        object.setValue(try crypto.seal(narrative.customSymptomScales, contentKey: contentKey), forKey: "customSymptomScalesCiphertext")
        object.setValue(createdAt, forKey: "createdAt")
        object.setValue(Date(), forKey: "updatedAt")
    }

    private func decrypt(_ object: NSManagedObject, contentKey: SymmetricKey) throws -> MenstrualNarrative? {
        guard let id = object.value(forKey: "id") as? UUID,
              let hkExternalUUID = object.value(forKey: "hkExternalUUID") as? String,
              let dateKey = object.value(forKey: "dateKey") as? String else { return nil }
        let symptomRaw: [String] = try crypto.open((object.value(forKey: "symptomFlagsCiphertext") as? Data), contentKey: contentKey) ?? []
        let scales: [String: Int] = try crypto.open((object.value(forKey: "customSymptomScalesCiphertext") as? Data), contentKey: contentKey) ?? [:]
        return MenstrualNarrative(
            id: id,
            hkExternalUUID: hkExternalUUID,
            dateKey: dateKey,
            note: try crypto.openString(object.value(forKey: "noteCiphertext") as? Data, contentKey: contentKey),
            symptomFlags: symptomRaw.compactMap(PeriodSymptom.init(rawValue:)),
            customSymptomScales: scales,
            createdAt: object.value(forKey: "createdAt") as? Date ?? Date(),
            updatedAt: object.value(forKey: "updatedAt") as? Date ?? Date()
        )
    }

    private func request(id: UUID) -> NSFetchRequest<NSManagedObject> {
        let request = NSFetchRequest<NSManagedObject>(entityName: "MenstrualNarrative")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return request
    }

    private static func dateKeys(in interval: DateInterval) -> [String] {
        FernletDate.dayKeys(in: interval)
    }
}
