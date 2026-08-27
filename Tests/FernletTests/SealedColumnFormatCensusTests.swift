import CoreData
import CryptoKit
import FernletCrypto
import Foundation
import PrivateStoreCore
import Testing

/// Pins ``SealedColumnFormatCensus`` — the keyless, read-only Phase 0 count of the sealed corpora
/// by at-rest format (Docs/Plan-Crypto-Standardization-2026-08-27.md).
///
/// The whole suite exists because of one failure mode: **a census nobody has proven counts anything
/// is indistinguishable from one that always returns zero**, and Phase 3 deletes the `ColumnCrypto`
/// legacy reader on the strength of a zero. So every bucket here is proven with a byte-exact
/// planted fixture, built from public CryptoKit primitives the way
/// `ColumnCryptoDeviceBindingTests` builds its legacy/v2 blobs — never by asking `ColumnCrypto` to
/// seal, which would let the fixture drift in lockstep with the writer and pin nothing.
///
/// The marker literals (`0x03` / `0x02`) are deliberately re-spelled here rather than read back
/// from ``ColumnCryptoStoredFormat/markerByte``: a test that sources its expectations from the code
/// under test agrees with any future change to that code, including a wrong one. These bytes are
/// at-rest format — changing them orphans real ciphertext — so the test states them independently.
///
/// `.serialized` per the house sealed-store discipline: these build real Core Data stacks (one
/// on-disk, in a UUID scratch directory) and the shared-disk-root flake family is well documented.
@Suite(.serialized)
struct SealedColumnFormatCensusTests {

    // MARK: - Fixtures

    /// Fixed key for the fixture blobs. Nothing in the census ever decrypts, so the key's only job
    /// is to make CryptoKit produce real, well-formed sealed boxes.
    private static let fixtureKey = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))

    /// The at-rest marker bytes, spelled independently of the production constants (see the suite
    /// note). `0x03` is the current device-bound format; `0x02` is its pre-purpose predecessor.
    private static let v3MarkerByte: UInt8 = 0x03
    private static let v2MarkerByte: UInt8 = 0x02

    /// Bound on nonce redraws when hunting for a first byte with a particular property. A ChaChaPoly
    /// nonce is uniform, so P(no hit in 8192 draws) for one specific byte value is
    /// (255/256)^8192 ≈ 1e-14 — the same budget `ColumnCryptoDeviceBindingTests` uses.
    private static let maxNonceDraws = 8192

    /// A byte-exact LEGACY blob: bare ChaChaPoly `combined` (nonce ‖ ciphertext ‖ tag), no version
    /// prefix and no AAD — the shape `ColumnCrypto` wrote before device binding existed, and the
    /// shape it *still* writes today whenever `DeviceBindingID.current()` is `nil` (the fail-open
    /// the plan's Phase 3 closes). Redrawn until the first byte is neither marker, so this fixture
    /// is unambiguously in the definitely-legacy bucket.
    private func legacyBlob(_ plaintext: String = "written before binding existed") throws -> Data {
        for _ in 0..<Self.maxNonceDraws {
            let combined = try ChaChaPoly.seal(Data(plaintext.utf8), using: Self.fixtureKey).combined
            if combined.first != Self.v3MarkerByte && combined.first != Self.v2MarkerByte {
                return combined
            }
        }
        throw FixtureFailure.couldNotDrawNonce
    }

    /// A LEGACY blob whose first (nonce) byte happens to equal `marker` — the ~1-in-256 collision
    /// that makes the marked buckets upper bounds rather than exact counts.
    private func collidingLegacyBlob(marker: UInt8) throws -> Data {
        for _ in 0..<Self.maxNonceDraws {
            let combined = try ChaChaPoly.seal(Data("nonce collision".utf8), using: Self.fixtureKey).combined
            if combined.first == marker { return combined }
        }
        throw FixtureFailure.couldNotDrawNonce
    }

    /// A version-marked blob: `marker ‖ combined`, sealed with AAD the way the device-bound formats
    /// are. The census never opens it, so the AAD's exact contents are irrelevant — the layout is
    /// what is under test.
    private func markedBlob(marker: UInt8, plaintext: String = "device bound") throws -> Data {
        let combined = try ChaChaPoly.seal(
            Data(plaintext.utf8),
            using: Self.fixtureKey,
            authenticating: Data("fixture-aad".utf8)
        ).combined
        return Data([marker]) + combined
    }

    private enum FixtureFailure: Error {
        /// 8192 uniform draws missed the target byte — effectively impossible, so treat it as a
        /// broken fixture rather than retrying forever (R2: the redraw loop is bounded).
        case couldNotDrawNonce
    }

    // MARK: - Planting

    /// Inserts one `WorryNarrative` row per blob. The simplest sealed entity — exactly one
    /// ciphertext column — so a row count and a classification count are the same number and the
    /// bucket assertions cannot be confounded.
    private func plantWorryRows(_ blobs: [Data?], in controller: PrivatePersistenceController) throws {
        let context = controller.container.viewContext
        try context.performAndWait {
            for blob in blobs {
                let row = NSEntityDescription.insertNewObject(forEntityName: "WorryNarrative", into: context)
                row.setValue(UUID(), forKey: "id")
                row.setValue(Date(), forKey: "createdAt")
                row.setValue(blob, forKey: "textCiphertext")
            }
            try context.save()
        }
    }

    /// Inserts one `JournalNarrative` row per `text` blob, leaving `emotionsCiphertext` `nil` — a
    /// real shape (an entry with no emotion chips) and the per-column proof that an unsealed column
    /// is counted as empty rather than folded into a format bucket.
    private func plantJournalRows(_ blobs: [Data?], in controller: PrivatePersistenceController) throws {
        let context = controller.container.viewContext
        try context.performAndWait {
            for blob in blobs {
                let row = NSEntityDescription.insertNewObject(forEntityName: "JournalNarrative", into: context)
                row.setValue(UUID(), forKey: "id")
                row.setValue("2026-08-27", forKey: "dayKey")
                row.setValue("good", forKey: "tag")
                row.setValue(Date(), forKey: "entryDate")
                row.setValue(Date(), forKey: "createdAt")
                row.setValue(Date(), forKey: "updatedAt")
                row.setValue(blob, forKey: "textCiphertext")
            }
            try context.save()
        }
    }

    private func makeController() -> PrivatePersistenceController {
        PrivatePersistenceController(inMemory: true)
    }

    /// A scratch directory for an ON-DISK sealed store — the only way to express the read-only
    /// proof, which is about real files. UUID-named per the shared-disk-root discipline.
    private static func makeScratchStoreDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fernlet-column-census-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func worryTextColumn() -> SealedColumnIdentifier {
        SealedColumnIdentifier(entityName: "WorryNarrative", attributeName: "textCiphertext")
    }

    private func journalTextColumn() -> SealedColumnIdentifier {
        SealedColumnIdentifier(entityName: "JournalNarrative", attributeName: "textCiphertext")
    }

    private func journalEmotionsColumn() -> SealedColumnIdentifier {
        SealedColumnIdentifier(entityName: "JournalNarrative", attributeName: "emotionsCiphertext")
    }

    // MARK: - The buckets

    // MARK: THE LOAD-BEARING TEST: a byte-exact legacy blob (bare `combined`, no prefix) is counted
    // as definitely-legacy. This is the number Phase 3's "census = 0" gate watches; if it did not
    // count, the gate would read zero on a corpus full of legacy rows and a reader would be deleted.
    @Test func aPlantedLegacyBlobIsCountedAsDefinitelyLegacy() throws {
        let controller = makeController()
        let blob = try legacyBlob()
        try plantWorryRows([blob], in: controller)

        let census = try SealedColumnFormatCensus.run(controller: controller)

        let tally = census.tally(for: worryTextColumn())
        #expect(tally.unprefixed == 1, "the planted legacy blob was not counted as definitely-legacy")
        #expect(tally.v3Marked == 0)
        #expect(tally.v2Marked == 0)
        #expect(tally.emptyOrNil == 0)
        #expect(tally.indeterminate == 0)
        #expect(census.definitelyLegacy == 1)
        #expect(census.rowsScanned == 1)
        #expect(census.rowsAvailable == 1)
        #expect(!census.truncated)
    }

    // MARK: Marked blobs land in their own buckets, per generation — a v3 row and a v2 row in the
    // same column must not collapse into one "not legacy" number, since Phase 2.6 migrates BOTH
    // v2 → v3 and legacy → v3 and needs to know how much of each is out there.
    @Test func markedBlobsAreCountedInTheirOwnGenerationBuckets() throws {
        let controller = makeController()
        let v3 = try markedBlob(marker: Self.v3MarkerByte)
        let v2 = try markedBlob(marker: Self.v2MarkerByte)
        try plantJournalRows([v3, v2], in: controller)

        let census = try SealedColumnFormatCensus.run(controller: controller)

        let text = census.tally(for: journalTextColumn())
        #expect(text.v3Marked == 1)
        #expect(text.v2Marked == 1)
        #expect(text.unprefixed == 0)
        #expect(census.definitelyLegacy == 0)
        // Both rows left `emotionsCiphertext` unsealed: a per-column census, not a per-row one.
        let emotions = census.tally(for: journalEmotionsColumn())
        #expect(emotions.emptyOrNil == 2)
        #expect(emotions.total == 2)
        #expect(census.rowsScanned == 2)
    }

    // MARK: THE AMBIGUITY PIN. A legacy blob whose first nonce byte happens to be 0x03 is counted
    // as v3Marked, NOT as legacy — because a byte-only classifier cannot tell it from a real v3
    // blob (the shipping reader disambiguates by attempted decrypt, which a keyless census must
    // not do). This test exists to make that under-count DELIBERATE and visible: it is exactly why
    // `definitelyLegacy` is a lower bound, why the marked buckets are upper bounds, and why
    // `definitelyLegacy == 0` is necessary but NOT sufficient proof that legacy rows are gone.
    // If someone "fixes" this by decrypting to classify, this test is the alarm.
    @Test func aLegacyBlobCollidingWithTheV3MarkerIsCountedInTheUpperBoundBucket() throws {
        let controller = makeController()
        let collided = try collidingLegacyBlob(marker: Self.v3MarkerByte)
        // It really is a legacy blob: bare combined, nonce(12) + ciphertext + tag(16), no prefix.
        #expect(collided.count == 12 + "nonce collision".utf8.count + 16)
        #expect(collided.first == Self.v3MarkerByte)
        try plantWorryRows([collided], in: controller)

        let census = try SealedColumnFormatCensus.run(controller: controller)

        let tally = census.tally(for: worryTextColumn())
        #expect(tally.v3Marked == 1, "the collided blob must land in the v3 UPPER-BOUND bucket")
        #expect(tally.unprefixed == 0, "a byte-only census cannot see through a nonce collision")
        // The honest pair of numbers a caller must report together: an exact zero for
        // definitely-legacy, and an upper bound of one that says the zero is not a proof.
        #expect(census.definitelyLegacy == 0)
        #expect(census.legacyUpperBound == 1)
    }

    // MARK: The same collision on the v2 marker, so both ambiguous buckets are pinned rather than
    // one being pinned and the other assumed to behave the same way.
    @Test func aLegacyBlobCollidingWithTheV2MarkerIsCountedInTheUpperBoundBucket() throws {
        let controller = makeController()
        let collided = try collidingLegacyBlob(marker: Self.v2MarkerByte)
        try plantWorryRows([collided], in: controller)

        let census = try SealedColumnFormatCensus.run(controller: controller)

        #expect(census.tally(for: worryTextColumn()).v2Marked == 1)
        #expect(census.definitelyLegacy == 0)
        #expect(census.legacyUpperBound == 1)
    }

    // MARK: An unsealed column is not a format. `nil` and zero-length Data both count as
    // empty-or-nil and NEITHER inflates the legacy number — an empty column read as "legacy" would
    // keep the Phase 3 gate permanently non-zero on a store that has nothing to migrate.
    @Test func emptyAndNilColumnsAreCountedSeparatelyFromAnyFormat() throws {
        let controller = makeController()
        try plantWorryRows([nil, Data()], in: controller)

        let census = try SealedColumnFormatCensus.run(controller: controller)

        let tally = census.tally(for: worryTextColumn())
        // One bucket for both, deliberately: whether Core Data hands a zero-length blob back as
        // `Data()` or as NULL is a storage detail, and neither is a sealed value.
        #expect(tally.emptyOrNil == 2)
        #expect(tally.unprefixed == 0)
        #expect(tally.v3Marked == 0)
        #expect(tally.v2Marked == 0)
        #expect(census.definitelyLegacy == 0)
        #expect(census.legacyUpperBound == 0)
    }

    // MARK: An empty store reports zeroes for every censused column — a real answer, and the shape
    // the Phase 3 gate is looking for. Every one of the seven columns must be present in the
    // result, so "no key for this column" can never be mistaken for "zero legacy in this column".
    @Test func anEmptyStoreReportsAZeroTallyForAllSevenColumns() throws {
        let census = try SealedColumnFormatCensus.run(controller: makeController())

        #expect(census.columns.count == 7)
        for column in SealedColumnFormatCensus.censusedColumns {
            #expect(census.columns[column] == SealedColumnFormatTally(), "\(column) is missing from the census")
        }
        #expect(census.rowsScanned == 0)
        #expect(census.rowsAvailable == 0)
        #expect(!census.truncated)
    }

    // MARK: - Drift proofing

    // MARK: The census table is hand-written, so it can silently fall behind the model. This
    // independently enumerates every model attribute whose name ends in "Ciphertext" and demands
    // an exact match — a fifth sealed entity or an eighth ciphertext column fails HERE instead of
    // going quietly un-censused and letting a legacy row hide from the Phase 3 gate.
    @Test func theCensusTableCoversExactlyTheModelsCiphertextColumns() {
        let model = PrivatePersistenceController(inMemory: true).container.managedObjectModel
        var discovered: Set<SealedColumnIdentifier> = []
        for entity in model.entities {
            guard let entityName = entity.name else { continue }
            for attributeName in entity.attributesByName.keys where attributeName.hasSuffix("Ciphertext") {
                discovered.insert(SealedColumnIdentifier(entityName: entityName, attributeName: attributeName))
            }
        }

        #expect(discovered == Set(SealedColumnFormatCensus.censusedColumns))
        #expect(discovered.count == 7, "the sealed store should have exactly 7 ciphertext columns")
        // And the production guard agrees with the independent enumeration.
        #expect(throws: Never.self) {
            try SealedColumnFormatCensus.verifyTable(matches: model)
        }
    }

    // MARK: A table entry the model does not have must FAIL, never silently contribute zero — "the
    // column has no legacy rows" and "the column was not counted" are the same number and opposite
    // meanings, and the plan says to stop when a count cannot be produced.
    @Test func aModelMissingTheCensusedEntitiesIsRefusedRatherThanCountedAsZero() throws {
        let empty = NSManagedObjectModel()
        empty.entities = []

        let thrown = #expect(throws: SealedColumnFormatCensus.Failure.self) {
            try SealedColumnFormatCensus.verifyTable(matches: empty)
        }
        let failure = try #require(thrown)
        guard case let .tableDoesNotMatchModel(missing, unlisted) = failure else {
            Issue.record("expected a table/model mismatch")
            return
        }
        #expect(missing.count == 7, "every censused column should be reported missing")
        #expect(unlisted.isEmpty)
    }

    // MARK: The other drift direction: a ciphertext column the model HAS and the table does not is
    // also a refusal. Without this, adding an eighth column would just quietly shrink the census.
    @Test func aCiphertextColumnMissingFromTheTableIsRefused() throws {
        let doctored = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "WorryNarrative"
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = [
            Self.binaryAttribute("textCiphertext"),
            Self.binaryAttribute("shadowCiphertext")
        ]
        doctored.entities = [entity]

        let thrown = #expect(throws: SealedColumnFormatCensus.Failure.self) {
            try SealedColumnFormatCensus.verifyTable(matches: doctored)
        }
        let failure = try #require(thrown)
        guard case let .tableDoesNotMatchModel(_, unlisted) = failure else {
            Issue.record("expected a table/model mismatch")
            return
        }
        #expect(unlisted.contains(SealedColumnIdentifier(entityName: "WorryNarrative", attributeName: "shadowCiphertext")))
    }

    private static func binaryAttribute(_ name: String) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = .binaryDataAttributeType
        attribute.isOptional = true
        return attribute
    }

    // MARK: - Bounds

    // MARK: Truncation is REPORTED, never silent. A census that stopped at its cap has counted a
    // subset, so its zero proves nothing; the flag is what stops a partial reading being presented
    // as a clean one. The counts must still be internally consistent with the rows it did reach.
    @Test func hittingTheRowCapTruncatesLoudlyWithConsistentCounts() throws {
        let controller = makeController()
        let blobs: [Data?] = try (0..<5).map { _ -> Data? in try legacyBlob() }
        try plantWorryRows(blobs, in: controller)

        let capped = try SealedColumnFormatCensus.run(controller: controller, rowCap: 2)
        #expect(capped.truncated, "a capped census must say it is incomplete")
        #expect(capped.rowsScanned == 2)
        #expect(capped.rowsAvailable == 5)
        #expect(capped.rowCap == 2)
        #expect(capped.total.total == 2, "one classification per scanned row on a single-column entity")
        #expect(capped.tally(for: worryTextColumn()).unprefixed == 2)

        // And an uncapped run over the same store is complete and sees all five.
        let full = try SealedColumnFormatCensus.run(controller: controller)
        #expect(!full.truncated)
        #expect(full.rowsScanned == 5)
        #expect(full.tally(for: worryTextColumn()).unprefixed == 5)
    }

    // MARK: The paging loop must not drop or double-count rows at a page boundary — the whole
    // memory-bounded design is worthless if a small page size changes the answer. Seven rows over
    // a page size of two exercises three full pages plus a partial one.
    @Test func aSmallPageSizeProducesTheSameCountsAsOnePage() throws {
        let controller = makeController()
        let blobs: [Data?] = try (0..<7).map { _ -> Data? in try legacyBlob() }
        try plantWorryRows(blobs, in: controller)

        let paged = try SealedColumnFormatCensus.run(controller: controller, pageSize: 2)
        let single = try SealedColumnFormatCensus.run(controller: controller, pageSize: 64)

        #expect(paged.tally(for: worryTextColumn()).unprefixed == 7)
        #expect(paged.columns == single.columns, "page size must not change the census")
        #expect(paged.rowsScanned == single.rowsScanned)
        #expect(!paged.truncated)
    }

    // MARK: THE UNFULFILLABLE-FAULT PIN. A row that could not be faulted in answers `nil` for every
    // attribute and marks itself deleted (Core Data's `shouldDeleteInaccessibleFaults`, on by
    // default) — silently, with no throw at the call site. Judged BEFORE the read the row looks
    // perfectly healthy, so every one of its columns would be counted `.empty`: a confident pile of
    // clean zeros for a corpus nobody actually read, handed straight to the gate that DELETES the
    // legacy reader. Judged after, it is `indeterminate`.
    //
    // The race itself (a device auto-locking mid-scan, a concurrent `rebuildStore()`/delete-all)
    // is not deterministically constructible from outside the scan, so this drives the
    // discriminator directly — with a REAL deleted managed object, which is constructible exactly.
    @Test func aRowThatCouldNotBeReadIsIndeterminateNotEmpty() throws {
        let controller = makeController()
        try plantWorryRows([try legacyBlob()], in: controller)
        let context = controller.container.viewContext
        let live: NSManagedObject = try context.performAndWait {
            let rows = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorryNarrative"))
            return try #require(rows.first)
        }
        // `isDeleted` is exactly the flag `shouldDeleteInaccessibleFaults` raises on a row whose
        // fault could not be fulfilled. The row must be SAVED before `delete(_:)`: deleting an
        // object that was inserted in the same cycle merely unregisters it (there is nothing in
        // the store to delete at the next save), and `isDeleted` stays false on it — only a
        // persisted object marked for deletion carries the flag this fixture exists to plant.
        let pendingDeletion: NSManagedObject = try context.performAndWait {
            let doomed = NSEntityDescription.insertNewObject(forEntityName: "WorryNarrative", into: context)
            doomed.setValue(UUID(), forKey: "id")
            doomed.setValue(Date(), forKey: "createdAt")
            try context.save()
            context.delete(doomed)
            return doomed
        }
        // The other half of the discriminator: a row with no context at all, which is what a row
        // detached by a store teardown is left as.
        let entity = try #require(controller.container.managedObjectModel.entitiesByName["WorryNarrative"])
        let detached = NSManagedObject(entity: entity, insertInto: nil)
        defer { context.performAndWait { context.rollback() } }

        // The fixtures really are the two inaccessible states, and `live` really is not one.
        #expect(pendingDeletion.isDeleted, "the delete fixture is not marked deleted")
        #expect(detached.managedObjectContext == nil, "the detached fixture still has a context")
        #expect(!live.isDeleted && live.managedObjectContext != nil)

        // THE ASSERTION: the same `nil` means opposite things depending on the row it came from.
        // An unfulfillable fault answers nil for every attribute, so a pre-read readability check
        // would have counted every one of those columns as a clean `.empty`.
        #expect(SealedColumnFormatCensus.classify(value: nil, readFrom: pendingDeletion) == .indeterminate)
        #expect(SealedColumnFormatCensus.classify(value: nil, readFrom: detached) == .indeterminate)
        #expect(SealedColumnFormatCensus.classify(value: nil, readFrom: live) == .classified(.empty))
        // And a row that vanished does not get to look migrated either: bytes from an inaccessible
        // row are worth nothing, however convincing their marker byte.
        let marked = try markedBlob(marker: Self.v3MarkerByte)
        #expect(SealedColumnFormatCensus.classify(value: marked, readFrom: pendingDeletion) == .indeterminate)
        #expect(SealedColumnFormatCensus.classify(value: marked, readFrom: live) == .classified(.v3Marked))
        // A live row holding something that is not bytes is a model/type drift, not an empty column.
        #expect(SealedColumnFormatCensus.classify(value: "not bytes", readFrom: live) == .indeterminate)
        let legacy = try legacyBlob()
        #expect(SealedColumnFormatCensus.classify(value: legacy, readFrom: live) == .classified(.unprefixed))
    }

    // MARK: A store that is not attached to the coordinator produces NO number — the plan's "if any
    // count cannot be produced, stop". `run` checks this twice, before and after the scan; the
    // second check is what covers a store torn off mid-scan, whose faults then fail silently and
    // whose (all-indeterminate) tallies must not be reported at all.
    @Test func anUnloadedStoreIsRefusedRatherThanCountedAsZero() throws {
        let controller = makeController()
        try plantWorryRows([try legacyBlob()], in: controller)
        let coordinator = controller.container.persistentStoreCoordinator
        let attached = coordinator.persistentStores
        #expect(!attached.isEmpty, "the fixture never had a store to detach")
        for store in attached {
            try coordinator.remove(store)
        }

        #expect(!controller.isStoreLoaded)
        #expect(throws: SealedColumnFormatCensus.Failure.storeUnavailable) {
            try SealedColumnFormatCensus.run(controller: controller)
        }
    }

    // MARK: A census with no bound is not a census. Nonsense bounds are refused up front rather
    // than being clamped to something the caller did not ask for.
    @Test func nonPositiveBoundsAreRefused() throws {
        let controller = makeController()
        #expect(throws: SealedColumnFormatCensus.Failure.invalidBounds(pageSize: 0, rowCap: 10)) {
            try SealedColumnFormatCensus.run(controller: controller, pageSize: 0, rowCap: 10)
        }
        #expect(throws: SealedColumnFormatCensus.Failure.invalidBounds(pageSize: 10, rowCap: 0)) {
            try SealedColumnFormatCensus.run(controller: controller, pageSize: 10, rowCap: 0)
        }
    }

    // MARK: - Read-only proof

    // MARK: THE READ-ONLY PROOF, on a real on-disk store. A census is allowed to read the sealed
    // corpora while the app is locked precisely because it writes nothing; if it could write, it
    // would be a second mutator of data nobody can decrypt to repair.
    //
    // What is asserted, and why it is layered this way: the `-wal` and `-shm` sidecars are
    // deliberately EXCLUDED from the byte comparison, because SQLite touches its shared-memory
    // index on pure reads and a fresh read connection can extend those files without any logical
    // write happening — asserting on them would be a flake, not a proof. The main `.sqlite` file
    // must be byte-identical; on top of that, every planted ciphertext is re-fetched and compared
    // byte-for-byte (a read that goes THROUGH the WAL, so a logical write hiding in a WAL frame
    // would show up here), the view context is proven to have no pending changes, and the census
    // itself throws `censusDirtiedTheContext` internally if its own context ends up dirty. Together
    // those cover the file, the log, and the in-memory state.
    @Test func theCensusWritesNothingToAnOnDiskSealedStore() throws {
        let directory = try Self.makeScratchStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("FernletPrivate.sqlite")
        let controller = PrivatePersistenceController(storeURL: storeURL)
        let planted: [Data?] = [try legacyBlob(), try markedBlob(marker: Self.v3MarkerByte), nil]
        try plantWorryRows(planted, in: controller)

        let sqliteBefore = try Data(contentsOf: storeURL)
        let blobsBefore = try Self.storedWorryBlobs(in: controller)
        // Two of the three planted rows carry bytes; the third is a `nil` column, which the
        // snapshot helper drops on both sides of the comparison.
        #expect(blobsBefore.count == 2)

        let census = try SealedColumnFormatCensus.run(controller: controller)
        #expect(census.rowsScanned == 3)
        #expect(census.tally(for: worryTextColumn()).unprefixed == 1)
        #expect(census.tally(for: worryTextColumn()).v3Marked == 1)
        #expect(census.tally(for: worryTextColumn()).emptyOrNil == 1)

        #expect(
            !controller.container.viewContext.hasChanges,
            "the census left unsaved changes on the live view context"
        )
        #expect(try Self.storedWorryBlobs(in: controller) == blobsBefore, "a stored ciphertext changed")
        #expect(try Data(contentsOf: storeURL) == sqliteBefore, "the sealed store file changed during a read-only census")
    }

    /// Every `WorryNarrative.textCiphertext` value, sorted for a stable comparison.
    ///
    /// `refreshAllObjects()` first, and it is load-bearing: without it the second snapshot would
    /// be served from the view context's already-registered objects — an in-memory comparison that
    /// would agree with itself no matter what happened on disk. Faulting everything out forces the
    /// values to be re-read through the store (and so through any WAL frames), which is the read a
    /// "nothing was written" claim actually needs. `nil` columns drop out of `compactMap` on both
    /// snapshots alike, so the two are still like-for-like.
    private static func storedWorryBlobs(in controller: PrivatePersistenceController) throws -> [Data] {
        let context = controller.container.viewContext
        return try context.performAndWait {
            context.refreshAllObjects()
            let request = NSFetchRequest<NSManagedObject>(entityName: "WorryNarrative")
            let rows = try context.fetch(request)
            let blobs = rows.compactMap { $0.value(forKey: "textCiphertext") as? Data }
            return blobs.sorted { $0.lexicographicallyPrecedes($1) }
        }
    }

    // MARK: Running the census twice returns the same answer — the second pass is a no-op in the
    // same sense `OwnPhotoKeyMigrationTests.secondPassIsANoOp` means it: a read-only pass that
    // "helpfully" rewrote anything would show up as a different second reading.
    @Test func aSecondCensusReturnsAnIdenticalReading() throws {
        let controller = makeController()
        try plantWorryRows([try legacyBlob(), try markedBlob(marker: Self.v2MarkerByte)], in: controller)

        let first = try SealedColumnFormatCensus.run(controller: controller)
        let second = try SealedColumnFormatCensus.run(controller: controller)

        #expect(first == second)
        #expect(first.tally(for: worryTextColumn()).unprefixed == 1)
        #expect(first.tally(for: worryTextColumn()).v2Marked == 1)
    }

    // MARK: - The classifier itself

    // MARK: The marker semantics live in exactly one place, and these are its terms: `0x03` and
    // `0x02` are markers, everything else is unprefixed legacy, and no bytes at all is `empty`.
    // Pinned directly (not only through the census) because the census is one consumer and the
    // classifier is the authority the migrators in Phase 2.6 will also use.
    @Test func theClassifierPinsTheMarkerSemantics() throws {
        #expect(ColumnCryptoStoredFormat.classify(nil) == .empty)
        #expect(ColumnCryptoStoredFormat.classify(Data()) == .empty)
        #expect(ColumnCryptoStoredFormat.classify(Data([Self.v3MarkerByte, 0x00])) == .v3Marked)
        #expect(ColumnCryptoStoredFormat.classify(Data([Self.v2MarkerByte, 0x00])) == .v2Marked)
        #expect(ColumnCryptoStoredFormat.classify(Data([0x00])) == .unprefixed)
        #expect(ColumnCryptoStoredFormat.classify(Data([0x04])) == .unprefixed)
        let realLegacyBlob = try legacyBlob()
        #expect(ColumnCryptoStoredFormat.classify(realLegacyBlob) == .unprefixed)

        // The bound semantics, stated as code: exactly one bucket is exact.
        #expect(ColumnCryptoStoredFormat.unprefixed.isDefinitelyLegacy)
        #expect(!ColumnCryptoStoredFormat.v3Marked.isDefinitelyLegacy)
        #expect(ColumnCryptoStoredFormat.v3Marked.isMarkerAmbiguous)
        #expect(ColumnCryptoStoredFormat.v2Marked.isMarkerAmbiguous)
        #expect(!ColumnCryptoStoredFormat.empty.isMarkerAmbiguous)
        #expect(ColumnCryptoStoredFormat.v3Marked.markerByte == Self.v3MarkerByte)
        #expect(ColumnCryptoStoredFormat.v2Marked.markerByte == Self.v2MarkerByte)
        #expect(ColumnCryptoStoredFormat.unprefixed.markerByte == nil)
    }
}
