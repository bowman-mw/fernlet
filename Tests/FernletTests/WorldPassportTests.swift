import CryptoKit
import FernletCrypto
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// The World passport (round 7, ideas 4 and B; owner 2026-10-29): first visits only, by kind, in a fixed order;
/// the earliest date kept on a restore's merge; the caps; the sealed file; the decoy; the wipe; and the
/// discovery stream Sprout's lines will read.
@MainActor
struct WorldPassportTests {
    nonisolated static let t1 = Date(timeIntervalSince1970: 1_792_800_000.25)
    nonisolated static let t2 = Date(timeIntervalSince1970: 1_792_886_400.5)
    nonisolated static let t3 = Date(timeIntervalSince1970: 1_792_972_800)

    nonisolated static let portlandPoint = GeoPoint(45.5205, -122.6255)
    nonisolated static let caribbeanPoint = GeoPoint(15.0, -75.0)
    nonisolated static let pacificPoint = GeoPoint(0.0, -140.0)
    nonisolated static let southPoint = GeoPoint(-65.0, 140.0)

    nonisolated static let portlandCity = AtlasCity(token: "Q6106", countryCode: "US", size: .city, population: 650_000,
                                                    point: portlandPoint, names: AtlasCityNames(english: "Portland"))
    nonisolated static let caribbeanSea = AtlasSea(token: "Q1247", parentOcean: .atlantic,
                                                   names: AtlasCityNames(english: "Caribbean Sea"))

    nonisolated static let portland = AtlasVisit(countryCode: "US", sovereignCode: "US", continent: .northAmerica,
                                                 city: portlandCity, terrain: .temperateForest)
    nonisolated static let caribbean = AtlasVisit(sea: caribbeanSea, terrain: .water)
    nonisolated static let pacific = AtlasVisit(ocean: .pacific, terrain: .water)
    nonisolated static let antarctica = AtlasVisit(continent: .antarctica, ocean: .southern, terrain: .ice)

    /// A stand-in atlas: a visit per point, else open water.
    nonisolated struct FakeAtlas: AtlasVisitResolving {
        let visits: [GeoPoint: AtlasVisit]

        func visit(at point: GeoPoint) -> AtlasVisit {
            visits[point] ?? AtlasVisit(terrain: .water)
        }
    }

    /// The fake atlas with the four test places.
    nonisolated static let atlas = FakeAtlas(visits: [portlandPoint: portland, caribbeanPoint: caribbean,
                                                      pacificPoint: pacific, southPoint: antarctica])

    /// A keeper over `vault` with the fake atlas.
    static func keeper(_ vault: WorldMapVault) -> WorldAtlasKeeper {
        WorldAtlasKeeper(vault: vault, openAtlas: { Self.atlas })
    }

    // MARK: First visits

    /// Each kind counts once, in the fixed order; a sea is its own entry, never its ocean; Antarctica's
    /// continent comes with the Southern Ocean.
    @Test func firstVisitsOnlyOfEachKindInTheFixedOrder() {
        var book = PassportBook()
        #expect(book.record(Self.portland, at: Self.t1).map(\.kind) == [.country, .continent, .city, .terrain])
        #expect(book.record(Self.portland, at: Self.t2).isEmpty, "a place counts once")
        #expect(book.firstVisit(.city, token: "Q6106") == Self.t1)
        #expect(book.record(Self.caribbean, at: Self.t2).map(\.kind) == [.sea, .terrain])
        #expect(book.firstVisit(.ocean, token: AtlasOcean.atlantic.rawValue) == nil, "the Caribbean is not the Atlantic")
        #expect(book.record(Self.pacific, at: Self.t3) == [AtlasDiscovery(kind: .ocean, token: "pacific", at: Self.t3)])
        #expect(book.record(Self.antarctica, at: Self.t3).map(\.token) == ["antarctica", "southern", "ice"])
        let everything = AtlasVisit(countryCode: "PT", continent: .europe, ocean: .atlantic, sea: Self.caribbeanSea,
                                    city: Self.portlandCity, terrain: .shrubland, landmarks: ["laurelhurstPark"])
        #expect(PassportBook().newDiscoveries(in: everything, at: Self.t1).map(\.kind) == AtlasDiscoveryKind.allCases)
        #expect(book.count(of: .terrain) == 3 && book.count(of: .ocean) == 2 && book.count(of: .sea) == 1)
        #expect(book.discoveries.first?.kind == .country && book.discoveries.count == 10)
    }

    /// A token that is empty, has a space or is too long is never kept.
    @Test func badTokensAreNeverKept() {
        var book = PassportBook()
        let city = AtlasCity(token: "two words", countryCode: "US", size: .town, population: 10, point: Self.portlandPoint,
                             names: AtlasCityNames(english: "Nowhere"))
        let visit = AtlasVisit(countryCode: "", city: city, terrain: .desert)
        #expect(book.record(visit, at: Self.t1).map(\.kind) == [.terrain])
        #expect(!PassportBook.isValidToken(String(repeating: "Q", count: 65), of: .city))
        #expect(!PassportBook.isValidToken("atlantis", of: .continent))
    }

    // MARK: Restore

    /// A restore merges by token, keeping the earliest date, and moves nothing later.
    @Test func aRestoreMergesByTokenKeepingTheEarliestDate() {
        var here = PassportBook()
        _ = here.record(Self.portland, at: Self.t2)
        var restored = PassportBook()
        _ = restored.record(Self.portland, at: Self.t1)
        _ = restored.record(Self.caribbean, at: Self.t3)
        #expect(here.merge(restored) == 6, "four moved earlier; the sea and water are new")
        #expect(here.firstVisit(.country, token: "US") == Self.t1)
        #expect(here.firstVisit(.sea, token: "Q1247") == Self.t3)
        #expect(here.merge(restored) == 0, "merging twice changes nothing")
        var later = PassportBook()
        _ = later.record(Self.portland, at: Self.t3)
        #expect(here.merge(later) == 0 && here.firstVisit(.city, token: "Q6106") == Self.t1)
    }

    // MARK: Caps

    /// Past a cap a first visit is refused and counted; nothing earlier is evicted.
    @Test func capsRefuseAndCountRatherThanEvict() {
        var book = PassportBook()
        let cap = PassportBook.cap(for: .city)
        #expect(cap == 20_000 && PassportBook.cap(for: .country) == 300 && PassportBook.cap(for: .sea) == 250)
        #expect(PassportBook.cap(for: .continent) == 7 && PassportBook.cap(for: .ocean) == 5)
        #expect(PassportBook.cap(for: .terrain) == 20)
        for index in 0..<cap {
            let city = AtlasCity(token: "Q\(index)", countryCode: "US", size: .town, population: 1, point: Self.portlandPoint,
                                 names: AtlasCityNames(english: "Town"))
            _ = book.record(AtlasVisit(city: city, terrain: .grassland), at: Self.t1)
        }
        #expect(book.count(of: .city) == cap)
        let extra = AtlasCity(token: "Q-extra", countryCode: "US", size: .town, population: 1, point: Self.portlandPoint,
                              names: AtlasCityNames(english: "Extra"))
        #expect(book.record(AtlasVisit(city: extra, terrain: .grassland), at: Self.t2).isEmpty)
        #expect(book.refusedCount == 1 && book.firstVisit(.city, token: "Q0") == Self.t1)
        var other = PassportBook()
        _ = other.record(AtlasVisit(city: extra, terrain: .desert), at: Self.t2)
        #expect(book.merge(other) == 1, "the desert is new; the city is refused")
        #expect(book.refusedCount == 2 && book.count(of: .city) == cap)
    }

    // MARK: Bytes

    /// The versioned bytes round-trip exactly, and a wrong version, an over-cap kind, a bad token or nonsense
    /// is refused whole.
    @Test func theBytesRoundTripAndRefuseNonsense() throws {
        var book = PassportBook()
        _ = book.record(Self.portland, at: Self.t1)
        _ = book.record(Self.caribbean, at: Self.t2)
        let data = try book.encoded()
        #expect(try PassportBook(data: data) == book)
        #expect(try PassportBook(data: data).firstVisit(.country, token: "US") == Self.t1)
        #expect(try PassportBook(data: book.encoded()) == PassportBook(data: data), "the same book, the same bytes")
        #expect(throws: PassportBook.BookError.unsupportedVersion(2)) { try PassportBook(data: Self.json(["version": 2])) }
        let seas = Dictionary(uniqueKeysWithValues: (0...250).map { ("Q\($0)", 1.0) })
        #expect(throws: PassportBook.BookError.overCap(.sea)) {
            try PassportBook(data: Self.json(["version": 1, "sea": seas]))
        }
        #expect(throws: PassportBook.BookError.badToken(.continent)) {
            try PassportBook(data: Self.json(["version": 1, "continent": ["atlantis": 1.0]]))
        }
        #expect(throws: PassportBook.BookError.malformed) { try PassportBook(data: Data("not a passport".utf8)) }
        #expect(try PassportBook(data: Self.json(["version": 1])).isEmpty)
    }

    /// JSON bytes for `object`.
    static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: The sealed store

    /// The passport is sealed in the vault and reads back the same; the file holds no token in the clear.
    @Test func thePassportSealsAndReadsBack() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let store = PassportStore(vault: vault)
        try store.load()
        #expect(try store.record(Self.portland, at: Self.t1).count == 4)
        #expect(try store.record(Self.portland, at: Self.t2).isEmpty)
        let reopened = PassportStore(vault: vault)
        try reopened.load()
        #expect(reopened.book == store.book && reopened.book.firstVisit(.city, token: "Q6106") == Self.t1)
        let raw = try Data(contentsOf: vault.directory.appendingPathComponent("passport.bin"))
        #expect(raw.range(of: Data("northAmerica".utf8)) == nil && raw.range(of: Data("Q6106".utf8)) == nil)
        #expect(WorldMapVault.File.passport.purpose == FernletCryptoPurpose.AEAD.worldMapPassportV1)
        #expect(FernletCryptoPurpose.AEAD.worldMapPassportV1.rawValue == "fernlet.world-map.passport.aead.v1")
    }

    /// An unopenable file, or a sealed one that is not a passport, is removed and the passport starts fresh.
    @Test func anUnopenableFileIsRemoved() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        try vault.write(Data("not a passport".utf8), to: .passport)
        let store = PassportStore(vault: vault)
        try store.load()
        #expect(store.book.isEmpty && store.isLoaded)
        #expect(try vault.read(.passport) == nil, "a sealed file that is not a passport is removed")
        try vault.write(Data([0x01]), to: .passport)
        try Data("noise".utf8).write(to: vault.directory.appendingPathComponent("passport.bin"))
        try PassportStore(vault: vault).load()
        #expect(try vault.read(.passport) == nil, "unopenable bytes are removed, not kept as noise")
    }

    /// A key that can't be read is an error, never a fresh start; a failed save leaves the book as it was.
    @Test func aLockedKeyIsAnErrorAndAFailedSaveKeepsNothing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorldMap-\(UUID().uuidString)")
        let key = SymmetricKey(size: .bits256)
        let writer = WorldMapVault(directory: directory, keys: WorldMapKeys(key: { _ in key }, removeAll: { true }))
        defer { _ = writer.clearAll() }
        let first = PassportStore(vault: writer)
        try first.load()
        _ = try first.record(Self.portland, at: Self.t1)
        let locked = WorldMapVault(directory: directory, keys: WorldMapKeys(
            key: { _ in throw WorldMapVault.VaultError.keyUnavailable }, removeAll: { true }))
        #expect(throws: WorldMapVault.VaultError.keyUnavailable) { try PassportStore(vault: locked).load() }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("passport.bin").path))
        let empty = WorldMapVault(directory: directory.appendingPathComponent("none"), keys: WorldMapKeys(
            key: { _ in throw WorldMapVault.VaultError.keyUnavailable }, removeAll: { true }))
        let store = PassportStore(vault: empty)
        try store.load()
        #expect(throws: WorldMapVault.VaultError.keyUnavailable) { try store.record(Self.portland, at: Self.t1) }
        #expect(store.book.isEmpty, "nothing is reported or kept that is not on disk")
    }

    // MARK: The keeper

    /// A decoy shows an empty passport, reads no fix and keeps nothing; leaving it shows the person's again.
    @Test func aDecoyShowsNothingAndKeepsNothing() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = Self.keeper(vault)
        keeper.observe(point: Self.portlandPoint, at: Self.t1)
        #expect(keeper.book.count(of: .country) == 1)
        keeper.setDecoy(true)
        #expect(keeper.book.isEmpty)
        #expect(throws: WorldAtlasKeeper.BackupRefusal.decoy) { try keeper.bookForBackup() }
        keeper.observe(point: Self.caribbeanPoint, at: Self.t2)
        #expect(keeper.book.isEmpty)
        #expect(throws: WorldAtlasKeeper.BackupRefusal.decoy, "a decoy restores nothing") {
            try keeper.restore(PassportBook())
        }
        keeper.setDecoy(false)
        #expect(keeper.book.count(of: .country) == 1 && keeper.book.count(of: .sea) == 0)
        let reopened = PassportStore(vault: vault)
        try reopened.load()
        #expect(reopened.book.count(of: .sea) == 0, "the decoy's fix was never written")
    }

    /// The wipe forgets the passport and removes its file; a new keeper starts empty.
    @Test func clearAllEmptiesThePassport() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = Self.keeper(vault)
        keeper.observe(point: Self.portlandPoint, at: Self.t1)
        #expect(try vault.read(.passport) != nil)
        #expect(keeper.clearAll())
        #expect(keeper.book.isEmpty)
        #expect(try vault.read(.passport) == nil)
        let fresh = Self.keeper(vault)
        fresh.load()
        #expect(fresh.book.isEmpty)
        keeper.observe(point: Self.portlandPoint, at: Self.t2)
        #expect(keeper.book.firstVisit(.country, token: "US") == Self.t2, "after a wipe the passport starts again")
    }

    /// Each first visit is announced once, after it is saved, never in a decoy; a fix close to the last is skipped.
    @Test func discoveriesAreAnnouncedOnceAndNeverInADecoy() async {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = Self.keeper(vault)
        let stream = keeper.discoveries()
        keeper.observe(point: Self.portlandPoint, at: Self.t1)
        keeper.observe(point: Self.portlandPoint.offset(east: 120, north: 0), at: Self.t2)
        keeper.observe(point: Self.portlandPoint, at: Self.t2)
        keeper.setDecoy(true)
        keeper.observe(point: Self.pacificPoint, at: Self.t2)
        keeper.setDecoy(false)
        keeper.observe(point: Self.caribbeanPoint, at: Self.t3)
        keeper.observe(point: Self.caribbeanPoint.offset(east: 10, north: 0), at: Self.t3)
        keeper.endDiscoveries()
        var heard: [AtlasDiscovery] = []
        for await discovery in stream.prefix(32) { heard.append(discovery) }
        #expect(heard.map(\.kind) == [.country, .continent, .city, .terrain, .terrain, .sea])
        #expect(heard.map(\.token) == ["US", "northAmerica", "Q6106", "temperateForest", "water", "Q1247"])
        #expect(!heard.contains { $0.token == "pacific" }, "a decoy's fix announces nothing")
    }

    /// Without an atlas the passport records nothing, and the atlas is asked for once.
    @Test func withoutAnAtlasNothingIsRecordedAndTheOpenerRunsOnce() {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        var opens = 0
        let keeper = WorldAtlasKeeper(vault: vault, openAtlas: {
            opens += 1
            return nil
        })
        keeper.observe(point: Self.portlandPoint, at: Self.t1)
        keeper.observe(point: Self.caribbeanPoint, at: Self.t2)
        #expect(keeper.book.isEmpty && opens == 1)
        var handed = 0
        let opener = WorldAtlasKeeper.bundledPack(in: Bundle(for: BundleProbe.self)) { _ in
            handed += 1
            return Self.atlas
        }
        #expect(opener() == nil && handed == 0, "a bundle with no pack opens nothing")
    }

    /// A restore through the keeper merges, saves and shows the earliest dates, announcing nothing.
    @Test func aRestoreThroughTheKeeperMergesAndSaves() async throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = Self.keeper(vault)
        let stream = keeper.discoveries()
        keeper.observe(point: Self.portlandPoint, at: Self.t2)
        var restored = PassportBook()
        _ = restored.record(Self.portland, at: Self.t1)
        _ = restored.record(Self.antarctica, at: Self.t3)
        try keeper.restore(restored)
        #expect(keeper.book.firstVisit(.country, token: "US") == Self.t1)
        #expect(keeper.book.firstVisit(.continent, token: "antarctica") == Self.t3)
        let reopened = PassportStore(vault: vault)
        try reopened.load()
        #expect(try reopened.book == keeper.book && keeper.bookForBackup() == keeper.book)
        keeper.endDiscoveries()
        var heard = 0
        for await _ in stream.prefix(32) { heard += 1 }
        #expect(heard == 4, "only the observed fix's four first visits; the restore announces none")
    }

    /// The sealed backup's hook (the store marks the passport's own backup owed): it runs when a first visit is
    /// saved and when the wipe removes the passport, never for a fix that found nothing new, a decoy's fix or
    /// a restore.
    @Test func thePassportChangedHookRunsForSavedFirstVisitsAndTheWipeOnly() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        // A second Portland fix past the spacing, which the fake answers as Portland again (nothing new).
        let nextDoor = Self.portlandPoint.offset(east: 120, north: 0)
        var visits = Self.atlas.visits
        visits[nextDoor] = Self.portland
        let atlas = FakeAtlas(visits: visits)
        let keeper = WorldAtlasKeeper(vault: vault, openAtlas: { atlas })
        var changes = 0
        keeper.onPassportChanged = { changes += 1 }
        keeper.observe(point: Self.portlandPoint, at: Self.t1)
        #expect(changes == 1, "a saved first visit")
        keeper.observe(point: nextDoor, at: Self.t2)
        #expect(changes == 1, "nothing new was found")
        keeper.setDecoy(true)
        keeper.observe(point: Self.pacificPoint, at: Self.t2)
        keeper.setDecoy(false)
        #expect(changes == 1, "a decoy's fix changes nothing")
        var restored = PassportBook()
        _ = restored.record(Self.antarctica, at: Self.t3)
        try keeper.restore(restored)
        #expect(changes == 1, "a restore marks the passport's backup owed itself")
        #expect(try keeper.bookForBackup().count(of: .continent) == 2)
        #expect(keeper.clearAll())
        #expect(changes == 2, "the wipe drops the backup's copy at the next export")
    }

    /// While the passport can't be read (the phone locked), the backup gets an error, never an empty book
    /// that would be written over the one in iCloud.
    @Test func aLockedPassportIsRefusedToTheBackupNeverEmpty() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorldMap-\(UUID().uuidString)")
        let key = SymmetricKey(size: .bits256)
        let writer = WorldMapVault(directory: directory, keys: WorldMapKeys(key: { _ in key }, removeAll: { true }))
        defer { _ = writer.clearAll() }
        Self.keeper(writer).observe(point: Self.portlandPoint, at: Self.t1)
        let locked = WorldMapVault(directory: directory, keys: WorldMapKeys(
            key: { _ in throw WorldMapVault.VaultError.keyUnavailable }, removeAll: { true }))
        let keeper = Self.keeper(locked)
        #expect(throws: WorldAtlasKeeper.BackupRefusal.unreadable) { try keeper.bookForBackup() }
        #expect(throws: WorldMapVault.VaultError.keyUnavailable) { try keeper.restore(PassportBook()) }
        #expect(try Self.keeper(writer).bookForBackup().count(of: .country) == 1, "the passport is still there")
    }
}

/// A class whose bundle (the test bundle) holds no atlas pack.
private final class BundleProbe {}
