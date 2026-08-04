import CoreData
import FernletCrypto
import FernletFoundation
import CryptoKit
import Foundation
import FernletDomainModel
import PrivateStoreCore

/// One cycle-day narrative: the note, symptom flags, and custom symptom scales attached to a logged
/// period event.
///
/// The plaintext half of a `MenstrualNarrative` row in the sealed private store. HealthKit holds
/// the clinical samples (flow, temperature, and so on); this type carries what Fernlet adds on top.
/// At rest, ``note``, ``symptomFlags``, and ``customSymptomScales`` exist only as ChaChaPoly
/// ciphertext columns decrypted by ``MenstrualNarrativeRepository``, while `id`,
/// ``hkExternalUUID``, ``dateKey``, and the timestamps stay plaintext for querying. `Codable` so
/// the app-side sealed-backup export can serialize decrypted records into its re-encrypted chunks.
public nonisolated struct MenstrualNarrative: Identifiable, Codable, Equatable {
    public var id: UUID
    /// `HKMetadataKeyExternalUUID` of the HealthKit samples this narrative annotates — the join key
    /// ``PeriodTrackerStore`` matches on. Still minted (uniquely) for narrative-only events that
    /// have no backing sample.
    public var hkExternalUUID: String
    /// Canonical `yyyy-MM-dd` day key — the indexed plaintext column date-range fetches filter on.
    public var dateKey: String
    /// The user's free-text note, sealed at rest; `nil` when nothing was written.
    public var note: String?
    /// Built-in symptoms flagged for the day, sealed at rest.
    public var symptomFlags: [PeriodSymptom]
    /// User-defined symptom name to intensity value, sealed at rest.
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

/// Sealed at-rest CRUD for cycle-day narratives, plus the device-local "ever stored" divergence
/// latch the sealed-backup restore depends on.
///
/// The persistence layer beneath ``PeriodTrackerStore``: notes, symptom flags, and custom symptom
/// scales are sealed with `ColumnCrypto` (label `"menstrual-narrative"`) into
/// `PrivatePersistenceController`'s local-only store, joined to HealthKit samples by the plaintext
/// `hkExternalUUID` column. The app-side `SealedBackupCoordinator` is the other caller: it exports
/// via the paged ``narratives(offset:limit:contentKey:)`` / ``narrativeCount()`` pair, restores via
/// ``insertAtomically(_:contentKey:)``, and consults ``hasEverStoredNarrative`` so a restore can
/// never resurrect narratives the user deliberately deleted.
///
/// Key discipline mirrors ``IntimacyLogRepository``: the content key is passed per call and never
/// retained; writes fail closed (`FernletLockError.locked`), reads degrade to `[]`/`nil` without a
/// key, rows whose ciphertext fails to authenticate are skipped, and deletes work without the key
/// so wipes survive lock and hide. Every mutation best-effort prunes Core Data persistent history
/// so superseded ciphertext does not linger in the transaction log — and every mutation (deletes
/// included) sets the one-way divergence latch.
///
/// A `nonisolated` final class: all Core Data access is serialized through the view context's
/// `performAndWait`, so it is callable from any executor.
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

    /// Reads the latch, BACKFILLING it from the row count first: installs whose narratives predate the
    /// latch (it ships later than the store) have rows but no defaults bit, and without the backfill an
    /// upgrading user who then deleted their entries would read as "never populated" — re-opening the
    /// resurrection this latch exists to close. A count error leaves the latch unread and un-backfilled
    /// (return the raw bit): claiming divergence on an error would wrongly block a genuine reinstall's
    /// restore forever, and the restore path's own no-clobber count check still refuses a populated store.
    ///
    /// The backfill covers a populated-at-read store; `update`/`delete`/`deleteAll` latch too, so the
    /// upgrade window closes on the FIRST mutation even if nothing read the latch while rows existed.
    /// The one unreachable sliver: a user who emptied their store entirely on a pre-latch build has no
    /// device-local bit left to distinguish them from a fresh reinstall — for them the (stale) cloud
    /// backup is restorable until `PeriodTrackerStore.deleteEntry` learns to reconcile it (tracked).
    public var hasEverStoredNarrative: Bool {
        if defaults.bool(forKey: Self.everStoredDefaultsKey) { return true }
        guard let count = try? narrativeCount(), count > 0 else { return false }
        markNarrativeStored()
        return true
    }

    private func markNarrativeStored() {
        defaults.set(true, forKey: Self.everStoredDefaultsKey)
    }

    /// Creates a repository on a sealed-store stack.
    ///
    /// - Parameters:
    ///   - controller: The private persistence stack to use; `nil` selects the shared
    ///     `PrivatePersistenceController`.
    ///   - defaults: Suite holding the divergence latch; tests inject an isolated suite.
    public init(controller: PrivatePersistenceController? = nil, defaults: UserDefaults = .standard) {
        self.context = (controller ?? .shared).container.viewContext
        self.defaults = defaults
    }

    /// Creates a repository on an explicit managed-object context — the seam tests use to run
    /// against an in-memory store.
    public init(context: NSManagedObjectContext, defaults: UserDefaults = .standard) {
        self.context = context
        self.defaults = defaults
    }

    /// Seals and stores one narrative, prunes persistent history (best-effort), and sets the
    /// divergence latch — only after a successful save.
    ///
    /// - Important: Fails closed — throws `FernletLockError.locked` when `contentKey` is `nil`.
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

    /// Re-seals an existing narrative in place (matched by `id`, preserving the stored `createdAt`),
    /// prunes the superseded ciphertext from persistent history, and sets the divergence latch. A
    /// missing row is a silent no-op; a `nil` key throws `FernletLockError.locked`.
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
            // An update proves a row existed — latch even when the ORIGINAL insert predates the latch
            // (an upgrading install), so a later empty store still reads as "diverged", not "fresh".
            markNarrativeStored()
        }
    }

    /// Deletes one narrative by `id` without decrypting it, prunes persistent history, and — when a
    /// row was actually removed — sets the divergence latch (see the inline rationale).
    public func delete(id: UUID) throws {
        try context.performAndWait {
            let request = request(id: id)
            let rows = try context.fetch(request)
            guard !rows.isEmpty else { return }
            rows.forEach(context.delete)
            try context.save()
            try PrivatePersistentHistoryPruner.prune(context: context)
            // The deletion itself is the proof this device diverged from the cloud snapshot: the row it
            // just removed may predate the latch (pre-upgrade data never latched on insert), and the
            // sealed backup is NOT reconciled by deletes — so without latching here, deleting the last
            // entry would leave an empty, unlatched store that a later un-hide "restores" the deleted
            // notes into. Latch only when something was actually deleted.
            markNarrativeStored()
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
            // Same reasoning as `delete(id:)`: emptying the store is divergence, and the rows it just
            // dropped may never have latched (pre-upgrade inserts). Non-empty guaranteed by the guard.
            markNarrativeStored()
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

    /// Decrypted narratives whose `dateKey` falls inside `dateRange`, ascending by day.
    ///
    /// Enumerates the range into explicit day keys for an indexed `IN` predicate, so keep ranges
    /// bounded (the store's 240-day load window is the intended caller) — unbounded walks belong to
    /// the paged ``narratives(offset:limit:contentKey:)``. Returns `[]` without a key; rows that
    /// fail to decrypt are skipped.
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

    /// The decrypted narrative joined to one HealthKit external UUID, or `nil` when absent or the
    /// store is locked (`contentKey == nil`). First match wins if duplicates ever exist.
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

    /// Writes one narrative into a managed object, sealing the three sensitive columns.
    /// `createdAt` is caller-supplied so updates preserve the original creation date while
    /// `updatedAt` is always stamped now.
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

    /// Rehydrates one managed object into a ``MenstrualNarrative``, decrypting the sealed columns.
    /// Returns `nil` when the required plaintext fields are missing; throws when decryption fails;
    /// unknown symptom raw values are dropped rather than failing the row.
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

    /// Fetch request for a single row by `id`.
    private func request(id: UUID) -> NSFetchRequest<NSManagedObject> {
        let request = NSFetchRequest<NSManagedObject>(entityName: "MenstrualNarrative")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return request
    }

    /// Enumerates the interval into canonical day keys via `FernletDate`.
    private static func dateKeys(in interval: DateInterval) -> [String] {
        FernletDate.dayKeys(in: interval)
    }
}
