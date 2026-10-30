// BodyTallyStoreTests.swift
// FernletTests
//
// The app's sealed body-tally funnel (`BodyTallyStore`, World bodybuilding spec §5–§7, round 7
// piece B1) and its `FernletStore` API: taps counted under the journal device key whatever the
// Private tab's state, the limits answered gently, nothing silent on failure, the decoy reading and
// keeping nothing, the cache never outliving a wipe, and every wipe path — Reset app lock, the
// duress wipe, Delete everything's key delete, the keyless wipe leg — clearing the tallies.
//
// Every test owns an in-memory sealed store and a scoped keychain service standing in for
// `com.fernlet.journal`, so no test touches the simulator's real journal device key.

import CoreData
import CryptoKit
import Foundation
import Testing
import FernletFoundation
import FernletLock
import PrivateHealthStore
import PrivateStoreCore
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct BodyTallyStoreTests {
    private static let day = "2026-10-29"

    /// A funnel on its own in-memory store and keychain service, plus a cleanup.
    private struct Fixture {
        let controller = PrivatePersistenceController(inMemory: true)
        let service = "com.fernlet.journal.test.bodytally.\(UUID().uuidString)"

        @MainActor
        func makeStore() -> BodyTallyStore { BodyTallyStore(controller: controller, deviceKeyService: service) }

        var repository: BodyTallyRepository { BodyTallyRepository(controller: controller) }

        var deviceKeyExists: Bool {
            if case .found = KeychainItem.loadDistinguishingAbsence(account: KeychainItem.Account.deviceJournalKey.rawValue, service: service) {
                return true
            }
            return false
        }

        func cleanup() { KeychainItem.deleteAll(service: service) }
    }

    // MARK: - Counting

    /// The Bathroom tile: one tap adds one, hold-to-fix sets the count, zero leaves no row. The first
    /// tap mints the journal device key exactly as a closed-tab journal write would — no Private key
    /// is involved, so a tap counts while the Private tab is closed or locked.
    @Test func tapsCountAndHoldToFixSetsTheCount() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        #expect(!fixture.deviceKeyExists)
        #expect(store.addBathroomVisit(on: Self.day, isDecoy: false) == .saved)
        #expect(fixture.deviceKeyExists, "the first tap seals under the journal device key")
        #expect(store.addBathroomVisit(on: Self.day, isDecoy: false) == .saved)
        #expect(store.tally(on: Self.day, isDecoy: false)?.bathroomVisits == 2)
        #expect(store.setBathroomVisits(5, on: Self.day, isDecoy: false) == .saved)
        #expect(store.setBathroomVisits(5, on: Self.day, isDecoy: false) == .unchanged)
        #expect(store.tally(on: Self.day, isDecoy: false)?.bathroomVisits == 5)
        #expect(store.setBathroomVisits(0, on: Self.day, isDecoy: false) == .saved)
        #expect(store.tally(on: Self.day, isDecoy: false) == nil)
        #expect(try fixture.repository.rowCount() == 0, "an emptied day is no row")
    }

    /// A second funnel on the same store and key reads what the first wrote — the rows, not memory.
    @Test func theTalliesAreReadFromTheSealedStore() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        fixture.makeStore().addBathroomVisit(on: Self.day, isDecoy: false)
        #expect(fixture.makeStore().tally(on: Self.day, isDecoy: false)?.bathroomVisits == 1)
    }

    @Test func theLimitsAreAnsweredGently() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        store.setBathroomVisits(BodyDayTally.maxBathroomVisits, on: Self.day, isDecoy: false)
        #expect(store.addBathroomVisit(on: Self.day, isDecoy: false) == .atLimit)
        for _ in 0..<BodyDayTally.maxFreeMeals {
            #expect(store.setFreeMeal(true, mealID: UUID(), on: Self.day, isDecoy: false) == .saved)
        }
        #expect(store.setFreeMeal(true, mealID: UUID(), on: Self.day, isDecoy: false) == .atLimit)
        #expect(store.lastWriteFailure == nil, "a limit is not a failure")
    }

    @Test func aFreeMealIsTaggedAndUntagged() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let meal = UUID()
        #expect(store.setFreeMeal(true, mealID: meal, on: Self.day, isDecoy: false) == .saved)
        #expect(store.tally(on: Self.day, isDecoy: false)?.isFreeMeal(meal) == true)
        #expect(store.setFreeMeal(true, mealID: meal, on: Self.day, isDecoy: false) == .unchanged)
        #expect(store.setFreeMeal(false, mealID: meal, on: Self.day, isDecoy: false) == .saved)
        #expect(store.tally(on: Self.day, isDecoy: false) == nil)
    }

    @Test func aRangeReadReturnsOnlyItsDays() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        for day in ["2026-09-30", "2026-10-01", "2026-10-15", "2026-10-31", "2026-11-01"] {
            store.addBathroomVisit(on: day, isDecoy: false)
        }
        #expect(Set(store.tallies(from: "2026-10-01", through: "2026-10-31", isDecoy: false).keys) == ["2026-10-01", "2026-10-15", "2026-10-31"])
        #expect(store.tallies(from: "2026-10-31", through: "2026-10-01", isDecoy: false).isEmpty, "a reversed range is empty")
        #expect(store.tallies(from: "October", through: "2026-10-31", isDecoy: false).isEmpty)
    }

    /// A write that cannot land is never silent: it returns the failure and sets the observable
    /// `lastWriteFailure`, which the next landed write clears.
    @Test func aFailedWriteIsReportedAndTheNextLandedWriteClearsIt() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        #expect(store.addBathroomVisit(on: "not a day", isDecoy: false) == .failed(.invalidDay))
        #expect(store.lastWriteFailure == .invalidDay)
        #expect(store.addBathroomVisit(on: Self.day, isDecoy: false) == .saved)
        #expect(store.lastWriteFailure == nil)
    }

    /// The token moves on every change and not on a write that changed nothing.
    @Test func theChangeTokenMovesOnlyOnChanges() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        let start = store.changeToken
        store.setBathroomVisits(2, on: Self.day, isDecoy: false)
        #expect(store.changeToken == start + 1)
        store.setBathroomVisits(2, on: Self.day, isDecoy: false)
        #expect(store.changeToken == start + 1)
        store.deleteTally(on: Self.day, isDecoy: false)
        #expect(store.changeToken == start + 2)
        #expect(store.tally(on: Self.day, isDecoy: false) == nil)
    }

    // MARK: - Decoy

    /// A decoy reads nothing real and keeps nothing: no row, and not even a minted device key.
    @Test func aDecoyReadsNothingAndKeepsNothing() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        #expect(store.addBathroomVisit(on: Self.day, isDecoy: true) == .droppedInDecoy)
        #expect(store.setFreeMeal(true, mealID: UUID(), on: Self.day, isDecoy: true) == .droppedInDecoy)
        #expect(store.deleteTally(on: Self.day, isDecoy: true) == .droppedInDecoy)
        #expect(!fixture.deviceKeyExists)
        #expect(try fixture.repository.rowCount() == 0)

        store.setBathroomVisits(3, on: Self.day, isDecoy: false)
        #expect(store.allTallies(isDecoy: true).isEmpty)
        #expect(store.tally(on: Self.day, isDecoy: true) == nil)
        #expect(store.tallies(from: Self.day, through: Self.day, isDecoy: true).isEmpty)
        #expect(store.tally(on: Self.day, isDecoy: false)?.bathroomVisits == 3, "the real tally is untouched by the decoy")
    }

    /// The `FernletStore` API passes the duress flag: in a decoy every read is empty and every write
    /// is dropped before the shared funnel is touched (its token does not move).
    @Test func theAppStoreAPIIsInertInADecoy() {
        let store = makeTestStore()
        store.duressSessionActive = true
        defer { store.duressSessionActive = false }
        let token = store.bodyTallyChangeToken
        #expect(store.addBathroomVisit(on: Self.day) == .droppedInDecoy)
        #expect(store.setBathroomVisits(4, on: Self.day) == .droppedInDecoy)
        #expect(store.setFreeMeal(true, mealID: UUID(), on: Self.day) == .droppedInDecoy)
        #expect(store.deleteBodyTally(on: Self.day) == .droppedInDecoy)
        #expect(store.bathroomVisits(on: Self.day) == 0)
        #expect(!store.isFreeMeal(UUID(), on: Self.day))
        #expect(store.bodyTallies(from: "2026-10-01", through: "2026-10-31").isEmpty)
        #expect(store.bodyTallyChangeToken == token)
    }

    // MARK: - The cache never outlives a wipe

    @Test func aPurgeUnderneathTheCacheIsNeverShown() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        store.setBathroomVisits(3, on: Self.day, isDecoy: false)
        #expect(store.tally(on: Self.day, isDecoy: false) != nil)
        try fixture.controller.purgeEncryptedEntities()
        #expect(store.tally(on: Self.day, isDecoy: false) == nil, "the cache outlived a purge")
    }

    @Test func aDestroyedDeviceKeyShowsNothing() {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        store.setBathroomVisits(3, on: Self.day, isDecoy: false)
        // Delete everything's leg 11 deletes exactly this account.
        KeychainItem.delete(for: .deviceJournalKey, service: fixture.service)
        #expect(store.allTallies(isDecoy: false).isEmpty, "rows under a destroyed key were shown from the cache")
    }

    // MARK: - Wipe paths

    /// The keyless wipe leg (`deleteAllBodyTalliesForWipe`'s body) works in a decoy and with no key.
    @Test func theKeylessWipeLegWorksWithoutAKey() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let store = fixture.makeStore()
        store.setBathroomVisits(3, on: Self.day, isDecoy: false)
        fixture.cleanup()
        #expect(store.deleteAll())
        #expect(try fixture.repository.rowCount() == 0)
    }

    /// Reset app lock: the lock's purge walks `sealedEntityNames` and its key sweep takes the journal
    /// device key — the tallies are both deleted and crypto-erased.
    @Test func resetAppLockClearsTheTalliesAndTheirKey() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let lock = FernletLockService(
            keychainService: "com.fernlet.lock.test.bodytally.\(UUID().uuidString)",
            sealedContentKeyServices: [fixture.service],
            narrativeBufferScope: uniqueNarrativeBufferScope(),
            cryptoProvider: FakeLockCryptoProvider(),
            privatePersistenceController: fixture.controller
        )
        try await lock.configure(credential: .pin6("135790"), grantingScope: .privateHub)
        let store = fixture.makeStore()
        #expect(store.addBathroomVisit(on: Self.day, isDecoy: false) == .saved)
        lock.lock(reason: .manual)

        try lock.reset()

        #expect(try fixture.repository.rowCount() == 0)
        #expect(!fixture.deviceKeyExists)
        #expect(store.tally(on: Self.day, isDecoy: false) == nil)
    }

    /// The duress WIPE: its synchronous key sweep takes the journal device key, so every tally is
    /// unopenable at once (the rows themselves go with the purge that follows, `deleteAllData`).
    @Test func theDuressWipeCryptoErasesTheTallies() async throws {
        let harness = LockTestHarness()
        defer { harness.cleanup() }
        let service = harness.makeService()
        try await service.configure(credential: .pin6("123456"), grantingScope: .privateHub)
        try await service.configureDuress(pin: "654321", mode: .silentWipe, current: "123456")
        let controller = PrivatePersistenceController(inMemory: true)
        let store = BodyTallyStore(controller: controller, deviceKeyService: harness.sealedContentKeyServiceID)
        #expect(store.addBathroomVisit(on: Self.day, isDecoy: false) == .saved)
        service.lock(reason: .manual)

        _ = try await service.unlock(passcode: "654321", for: .privateHub)

        #expect(store.allTallies(isDecoy: false).isEmpty, "a tally still opens after the duress wipe")
        #expect(try BodyTallyRepository(controller: controller).rowCount() == 1, "the rows wait for the purge; only their key is gone")
    }
}
