// BodyTallyRepositoryTests.swift
// FernletTests
//
// The sealed `BodyTally` store (World bodybuilding spec §7, round 7 piece B1): the value's bounds and
// frozen coding, the round trip under the right key and the refusal under any other, the locked
// (keyless) behaviour, one row per day, the store bound, an undecided row refusing a write, the
// keyless wipe, delete-by-day, the reset purge and the census.
//
// Every test runs on its own in-memory store. `@MainActor` because the view context's
// `performAndWait` runs inline only on the main actor.

import CoreData
import CryptoKit
import Foundation
import Testing
@testable import FernletCrypto
import FernletFoundation
import PrivateHealthStore
import PrivateStoreCore

@MainActor
@Suite(.serialized)
struct BodyTallyRepositoryTests {
    private static let stamp = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func makeController() -> PrivatePersistenceController { PrivatePersistenceController(inMemory: true) }
    private func makeKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    /// Plants raw rows (bypassing the repository) — for the bound, the undecided and the duplicate tests.
    private func plant(_ blobs: [Data], schemaVersion: Int16 = 1, in controller: PrivatePersistenceController) throws {
        let context = controller.container.viewContext
        try context.performAndWait {
            for blob in blobs {
                let row = NSEntityDescription.insertNewObject(forEntityName: "BodyTally", into: context)
                row.setValue(UUID(), forKey: "id")
                row.setValue(schemaVersion, forKey: "schemaVersion")
                row.setValue(blob, forKey: "payloadCiphertext")
            }
            try context.save()
        }
    }

    // MARK: - The value

    @Test func theValueClampsVisitsAndDeduplicatesAndCapsFreeMeals() {
        let ids = (0..<25).map { _ in UUID() }
        let tally = BodyDayTally(dayKey: "2026-10-29", bathroomVisits: 99, freeMealIDs: [ids[0], ids[0]] + ids)
        #expect(tally.bathroomVisits == BodyDayTally.maxBathroomVisits)
        #expect(tally.freeMealIDs.count == BodyDayTally.maxFreeMeals)
        #expect(tally.freeMealIDs == Array(ids.prefix(BodyDayTally.maxFreeMeals)))
        #expect(BodyDayTally(dayKey: "2026-10-29", bathroomVisits: -3).bathroomVisits == 0)
        #expect(tally.addingBathroomVisit() == nil, "a 31st visit must be refused, not wrapped")
        #expect(tally.settingFreeMeal(true, mealID: UUID()) == nil, "a 21st free meal must be refused")
        #expect(tally.settingFreeMeal(true, mealID: ids[0]) == tally, "re-tagging a tagged meal changes nothing")
        #expect(tally.settingFreeMeal(false, mealID: ids[0])?.isFreeMeal(ids[0]) == false)
        #expect(BodyDayTally(dayKey: "2026-10-29").isEmpty)
    }

    @Test(arguments: ["2026-10-29", "2024-02-29", "1999-12-31"])
    func calendarDayKeysAreValid(_ key: String) {
        #expect(BodyDayTally.isValidDayKey(key))
    }

    @Test(arguments: ["", "2026-13-01", "2026-00-10", "2026-10-32", "26-10-29", "2026/10/29", "2026-1-029", "２０２６-10-29"])
    func malformedDayKeysAreRefused(_ key: String) {
        #expect(!BodyDayTally.isValidDayKey(key))
    }

    /// The coding keys are frozen storage tokens, and a decoded value is sanitized like a built one;
    /// a payload whose day key is not a calendar day does not decode at all.
    @Test func theCodingIsFrozenAndTheDecoderSanitizes() throws {
        let meal = UUID()
        let json = """
        {"dayKey":"2026-10-29","bathroomVisits":45,"freeMealIDs":["\(meal.uuidString)","\(meal.uuidString)"],"updatedAt":0}
        """
        let decoded = try JSONDecoder().decode(BodyDayTally.self, from: Data(json.utf8))
        #expect(decoded.bathroomVisits == 30 && decoded.freeMealIDs == [meal])
        let encoded = try JSONEncoder().encode(BodyDayTally(dayKey: "2026-10-29", bathroomVisits: 1, updatedAt: Self.stamp))
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["dayKey", "bathroomVisits", "freeMealIDs", "updatedAt"])
        let bad = Data(#"{"dayKey":"tomorrow","bathroomVisits":1,"freeMealIDs":[],"updatedAt":0}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(BodyDayTally.self, from: bad) }
    }

    // MARK: - Round trip and keys

    @Test func aTallyRoundTripsAndOneDayKeepsOneRow() throws {
        let repo = BodyTallyRepository(controller: makeController())
        let key = makeKey()
        let first = BodyDayTally(dayKey: "2026-10-29", bathroomVisits: 2, updatedAt: Self.stamp)
        #expect(try repo.save(first, key: key))
        let second = BodyDayTally(dayKey: "2026-10-29", bathroomVisits: 3, freeMealIDs: [UUID()], updatedAt: Self.stamp)
        #expect(try repo.save(second, key: key))
        #expect(try repo.save(second, key: key) == false, "an identical write changes nothing on disk")
        try repo.save(BodyDayTally(dayKey: "2026-10-30", bathroomVisits: 1, updatedAt: Self.stamp), key: key)
        let page = try repo.allTallies(key: key)
        #expect(page.tallies["2026-10-29"] == second)
        #expect(page.tallies.count == 2 && page.deadCount == 0 && page.transientCount == 0)
        #expect(try repo.rowCount() == 2, "one row per day")
    }

    /// The row holds no plaintext day: neither the day key nor the count is readable from the columns.
    @Test func theStoredRowCarriesNoPlaintextDayOrCount() throws {
        let controller = makeController()
        try BodyTallyRepository(controller: controller).save(BodyDayTally(dayKey: "2026-10-29", bathroomVisits: 7), key: makeKey())
        let context = controller.container.viewContext
        let stored = try context.performAndWait {
            try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "BodyTally")).first?.value(forKey: "payloadCiphertext") as? Data
        }
        let blob = try #require(stored)
        #expect(blob.first == 0x03, "a V3 device-bound ColumnCrypto blob")
        #expect(blob.range(of: Data("2026-10-29".utf8)) == nil)
    }

    @Test func aWrongKeyOpensNothingAndCountsTheRowDead() throws {
        let repo = BodyTallyRepository(controller: makeController())
        try repo.save(BodyDayTally(dayKey: "2026-10-29", bathroomVisits: 2), key: makeKey())
        let page = try repo.allTallies(key: makeKey())
        #expect(page.tallies.isEmpty)
        #expect(page.deadCount == 1 && page.transientCount == 0)
        // A write under the other key cannot see the dead row, so it stores a row of its own.
        try repo.save(BodyDayTally(dayKey: "2026-10-29", bathroomVisits: 1), key: makeKey())
        #expect(try repo.rowCount() == 2)
    }

    /// Without a key (the store's "locked" answer): reads are empty, writes and keyed deletes throw
    /// `locked`, and the keyless count and wipe still work.
    @Test func withoutAKeyReadsAreEmptyAndWritesThrowLocked() throws {
        let repo = BodyTallyRepository(controller: makeController())
        try repo.save(BodyDayTally(dayKey: "2026-10-29", bathroomVisits: 2), key: makeKey())
        #expect(try repo.allTallies(key: nil) == BodyTallyPage())
        #expect(throws: FernletLockError.locked) { try repo.save(BodyDayTally(dayKey: "2026-10-29", bathroomVisits: 1), key: nil) }
        #expect(throws: FernletLockError.locked) { _ = try repo.delete(dayKey: "2026-10-29", key: nil) }
        #expect(try repo.rowCount() == 1)
        #expect(try repo.deleteAll())
        #expect(try repo.rowCount() == 0)
        #expect(try repo.deleteAll() == false, "an empty store deletes nothing")
    }

    @Test func anEmptyTallyDeletesTheDayAndAMalformedDayIsRefused() throws {
        let repo = BodyTallyRepository(controller: makeController())
        let key = makeKey()
        try repo.save(BodyDayTally(dayKey: "2026-10-29", bathroomVisits: 2), key: key)
        #expect(try repo.save(BodyDayTally(dayKey: "2026-10-29"), key: key))
        #expect(try repo.rowCount() == 0, "an empty day is no row at all")
        #expect(try repo.save(BodyDayTally(dayKey: "2026-10-29"), key: key) == false)
        #expect(throws: BodyTallyRepositoryError.invalidDayKey) {
            try repo.save(BodyDayTally(dayKey: "yesterday", bathroomVisits: 1), key: key)
        }
    }

    @Test func deleteByDayRemovesOnlyThatDay() throws {
        let repo = BodyTallyRepository(controller: makeController())
        let key = makeKey()
        try repo.save(BodyDayTally(dayKey: "2026-10-29", bathroomVisits: 2), key: key)
        try repo.save(BodyDayTally(dayKey: "2026-10-30", bathroomVisits: 4), key: key)
        #expect(try repo.delete(dayKey: "2026-10-29", key: key) == 1)
        #expect(try repo.delete(dayKey: "2026-10-29", key: key) == 0)
        #expect(Set(try repo.allTallies(key: key).tallies.keys) == ["2026-10-30"])
    }

    // MARK: - Bounds and undecided rows

    @Test func theStoreRefusesANewDayPastItsBound() throws {
        let controller = makeController()
        try plant(Array(repeating: Data([0x03, 0x00]), count: BodyTallyRepository.maxStoredRows), in: controller)
        let repo = BodyTallyRepository(controller: controller)
        #expect(throws: BodyTallyRepositoryError.storeFull(limit: BodyTallyRepository.maxStoredRows)) {
            try repo.save(BodyDayTally(dayKey: "2026-10-29", bathroomVisits: 1), key: makeKey())
        }
        #expect(try repo.rowCount() == BodyTallyRepository.maxStoredRows, "nothing was written")
    }

    /// A row a newer build wrote is undecided — never dead — so a write that might overwrite it is
    /// refused with nothing written, and a read reports it as transient.
    @Test func aNewerBuildsRowRefusesTheWriteAndReadsAsTransient() throws {
        let controller = makeController()
        try plant([Data([0x03, 0x01, 0x02])], schemaVersion: Int16(BodyDayTally.schemaVersion + 1), in: controller)
        let repo = BodyTallyRepository(controller: controller)
        let key = makeKey()
        #expect(try repo.allTallies(key: key).transientCount == 1)
        #expect(throws: BodyTallyRepositoryError.undecidedRows(count: 1)) {
            try repo.save(BodyDayTally(dayKey: "2026-10-29", bathroomVisits: 1), key: key)
        }
        #expect(try repo.rowCount() == 1)
    }

    /// Two rows that open to one day read as the later one, and the next write leaves one row.
    @Test func duplicateRowsOfADayReduceToTheLaterAndAWriteHealsThem() throws {
        let controller = makeController()
        let key = makeKey()
        let crypto = ColumnCrypto(purpose: FernletCryptoPurpose.KeyDerivation.bodyTallyV1)
        let older = BodyDayTally(dayKey: "2026-10-29", bathroomVisits: 1, updatedAt: Self.stamp)
        let newer = BodyDayTally(dayKey: "2026-10-29", bathroomVisits: 5, updatedAt: Self.stamp.addingTimeInterval(60))
        try plant([try crypto.seal(newer, contentKey: key), try crypto.seal(older, contentKey: key)], in: controller)
        let repo = BodyTallyRepository(controller: controller)
        #expect(try repo.allTallies(key: key).tallies["2026-10-29"] == newer)
        try repo.save(BodyDayTally(dayKey: "2026-10-29", bathroomVisits: 6), key: key)
        #expect(try repo.rowCount() == 1)
    }

    // MARK: - The sealed store's shared lists

    /// The reset purge and the passcode setup's prior-data count both walk `sealedEntityNames`, so a
    /// body tally is purged by the reset and counted before a fresh key is minted.
    @Test func theResetPurgeAndThePriorDataCountIncludeBodyTallies() throws {
        let controller = makeController()
        let repo = BodyTallyRepository(controller: controller)
        try repo.save(BodyDayTally(dayKey: "2026-10-29", bathroomVisits: 1), key: makeKey())
        #expect(try controller.sealedRowCount() == 1)
        try controller.purgeEncryptedEntities()
        #expect(try repo.rowCount() == 0)
    }

    /// A tally sealed by the production repository is censused in the v3 bucket of its one column.
    @Test func aSealedBodyTallyIsCensusedAsVersionThree() throws {
        let controller = makeController()
        try BodyTallyRepository(controller: controller).save(BodyDayTally(dayKey: "2026-10-29", bathroomVisits: 1), key: makeKey())
        let census = try SealedColumnFormatCensus.run(controller: controller)
        let column = SealedColumnIdentifier(entityName: "BodyTally", attributeName: "payloadCiphertext")
        #expect(census.tally(for: column).v3Marked == 1)
        #expect(census.definitelyLegacy == 0)
    }
}
