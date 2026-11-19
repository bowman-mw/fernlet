import CryptoKit
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Release review F3 (2026-11-18): a World map file that exists but can't be read right now (file protection with the
/// phone locked, or before the first unlock after a restart) is never removed. Each store reports "try again after
/// unlock" (`WorldMapVault.VaultError.isTryAgainLater`), the file is still there afterwards, and a later read with the
/// phone unlocked returns what was saved. A file whose bytes really are bad is still removed, as before.
@MainActor
struct WorldVaultLockedReadTests {
    /// A disk whose reads fail, by file name, the way a locked phone's file protection fails them.
    @MainActor
    final class LockedDisk {
        /// The file names whose reads fail now.
        var locked: Set<String> = []

        /// The vault's reader over this disk.
        var reader: WorldMapVault.FileReader {
            { [self] url in
                guard !locked.contains(url.lastPathComponent) else { throw CocoaError(.fileReadNoPermission) }
                return try Data(contentsOf: url)
            }
        }
    }

    /// One folder and one set of keys, read through a disk the test can lock.
    @MainActor
    struct Fixture {
        let disk = LockedDisk()
        let vault: WorldMapVault

        init() {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorldMapLocked-\(UUID().uuidString)")
            vault = WorldMapVault(directory: directory, keys: .ephemeral(), readFile: disk.reader)
        }

        /// Fails reads of `files` until ``unlock()``.
        func lock(_ files: WorldMapVault.File...) {
            disk.locked = Set(files.map(\.name))
        }

        /// Lets every read through again.
        func unlock() {
            disk.locked = []
        }

        /// The raw sealed bytes of `file` on disk, or nil when it is gone.
        func raw(_ file: WorldMapVault.File) -> Data? {
            FileManager.default.contents(atPath: vault.directory.appendingPathComponent(file.name).path)
        }
    }

    /// Whether `body` throws a "try again after unlock" error.
    static func throwsTryAgain(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            return false
        } catch {
            return WorldMapVault.isTryAgainLater(error)
        }
    }

    // MARK: The vault

    /// A read failure on a file that exists is "the file can't be read right now", never "unopenable".
    @Test func aFailedReadIsFileUnavailableAndKeepsTheFile() throws {
        let fixture = Fixture()
        defer { _ = fixture.vault.clearAll() }
        try fixture.vault.write(Data("kept".utf8), to: .fog)
        let sealed = fixture.raw(.fog)
        fixture.lock(.fog)
        #expect(throws: WorldMapVault.VaultError.fileUnavailable) { try fixture.vault.read(.fog) }
        #expect(WorldMapVault.VaultError.fileUnavailable.isTryAgainLater && WorldMapVault.VaultError.keyUnavailable.isTryAgainLater)
        #expect(!WorldMapVault.VaultError.unopenable.isTryAgainLater && !WorldMapVault.isTryAgainLater(CocoaError(.fileReadCorruptFile)))
        #expect(fixture.raw(.fog) == sealed)
        fixture.unlock()
        #expect(try fixture.vault.read(.fog) == Data("kept".utf8))
    }

    // MARK: The passport

    /// A locked passport throws "try again", stays on disk, and reads back whole after unlock.
    @Test func aLockedPassportIsKept() throws {
        let fixture = Fixture()
        defer { _ = fixture.vault.clearAll() }
        let first = PassportStore(vault: fixture.vault)
        try first.load()
        let found = try first.record(WorldPassportTests.portland, at: WorldPassportTests.t1)
        #expect(!found.isEmpty)
        let sealed = fixture.raw(.passport)
        fixture.lock(.passport)
        let locked = PassportStore(vault: fixture.vault)
        #expect(Self.throwsTryAgain { try locked.load() })
        #expect(!locked.isLoaded && fixture.raw(.passport) == sealed, "the file is untouched")
        fixture.unlock()
        try locked.load()
        #expect(locked.book == first.book && !locked.book.isEmpty)
    }

    /// A passport whose bytes really don't open is still removed and the book starts fresh.
    @Test func aCorruptPassportIsStillRemoved() throws {
        let fixture = Fixture()
        defer { _ = fixture.vault.clearAll() }
        try fixture.vault.write(Data([0x01]), to: .passport)
        try Data("FWM1 noise, not a sealed box".utf8).write(to: fixture.vault.directory.appendingPathComponent("passport.bin"))
        let store = PassportStore(vault: fixture.vault)
        try store.load()
        #expect(store.isLoaded && store.book.isEmpty)
        #expect(fixture.raw(.passport) == nil, "bad bytes are removed, as before")
    }

    // MARK: The fog and its buffer

    /// A locked fog store or locked buffer throws "try again"; both files stay and merge after unlock.
    @Test func aLockedFogAndBufferAreKept() throws {
        let fixture = Fixture()
        defer { _ = fixture.vault.clearAll() }
        let first = FogCellStore(vault: fixture.vault)
        try first.load()
        first.lift([HexCell(q: 1, r: 1)])
        try first.save()
        try first.appendPending([HexCell(q: 2, r: 2)])
        fixture.lock(.fog, .pendingFog)
        #expect(Self.throwsTryAgain { try FogCellStore(vault: fixture.vault).load() })
        fixture.lock(.pendingFog)
        let store = FogCellStore(vault: fixture.vault)
        #expect(Self.throwsTryAgain { try store.load() }, "the buffer can't be read: the drain waits")
        #expect(Self.throwsTryAgain { try store.appendPending([HexCell(q: 3, r: 3)]) }, "never an append over a buffer it can't read")
        #expect(fixture.raw(.fog) != nil && fixture.raw(.pendingFog) != nil)
        fixture.unlock()
        #expect(try store.drainPending() == 1)
        #expect(store.cells == [HexCell(q: 1, r: 1), HexCell(q: 2, r: 2)])
    }

    // MARK: The driven fog and its buffer

    /// A locked driven store or buffer throws "try again"; both stay and read back after unlock.
    @Test func aLockedDrivenFogAndBufferAreKept() throws {
        let fixture = Fixture()
        defer { _ = fixture.vault.clearAll() }
        let first = DrivenFogStore(vault: fixture.vault)
        try first.load()
        first.add([HexCell(q: 4, r: 4)])
        try first.save()
        try first.appendPending([HexCell(q: 5, r: 5)])
        fixture.lock(.drivenFog, .pendingDriven)
        let store = DrivenFogStore(vault: fixture.vault)
        #expect(Self.throwsTryAgain { try store.load() })
        #expect(Self.throwsTryAgain { _ = try store.pending() })
        #expect(fixture.raw(.drivenFog) != nil && fixture.raw(.pendingDriven) != nil)
        fixture.unlock()
        try store.load()
        #expect(store.cells == [HexCell(q: 4, r: 4)])
        #expect(try store.pending() == [HexCell(q: 5, r: 5)])
    }

    // MARK: Frequent roads and their buffer

    /// A locked frequent-roads counter or buffer throws "try again"; both stay and read back after unlock.
    @Test func aLockedWornWaysAndBufferAreKept() throws {
        let fixture = Fixture()
        defer { _ = fixture.vault.clearAll() }
        let first = WornWayStore(vault: fixture.vault)
        try first.load()
        first.record([HexCell(q: 6, r: 6)], kind: .road, on: 10)
        try first.save()
        try first.appendPending([HexCell(q: 7, r: 7)], kind: .road, on: 11)
        fixture.lock(.wornWays, .pendingWornWays)
        let store = WornWayStore(vault: fixture.vault)
        #expect(Self.throwsTryAgain { try store.load() })
        #expect(Self.throwsTryAgain { _ = try store.pending() })
        #expect(fixture.raw(.wornWays) != nil && fixture.raw(.pendingWornWays) != nil)
        fixture.unlock()
        try store.load()
        #expect(store.tallies == first.tallies)
        #expect(try store.pending().count == 1)
    }

    // MARK: Kept trips, the corner and walk lines

    /// A locked trip piece throws "try again" and stays; once readable, bytes that don't decode are removed as before.
    @Test func aLockedTripPieceIsKeptAndABadOneStillGoes() throws {
        let fixture = Fixture()
        defer { _ = fixture.vault.clearAll() }
        try fixture.vault.write(Data("not trips".utf8), to: .wornTrips(chunk: 0))
        fixture.lock(.wornTrips(chunk: 0))
        #expect(Self.throwsTryAgain { try WornTripStore(vault: fixture.vault).load() })
        #expect(fixture.raw(.wornTrips(chunk: 0)) != nil)
        fixture.unlock()
        #expect(try fixture.vault.read(.wornTrips(chunk: 0)) == Data("not trips".utf8))
        try WornTripStore(vault: fixture.vault).load()
        #expect(fixture.raw(.wornTrips(chunk: 0)) == nil, "a piece that doesn't decode is still removed")
    }

    /// A locked corner throws "try again", stays, and reads back after unlock.
    @Test func aLockedCornerIsKept() throws {
        let fixture = Fixture()
        defer { _ = fixture.vault.clearAll() }
        let state = FogCornerState(weekStart: Date(timeIntervalSince1970: 1_800_000_000), cell: HexCell(q: 8, r: 8))
        try FogCornerStore(vault: fixture.vault).save(state)
        fixture.lock(.corner)
        #expect(Self.throwsTryAgain { _ = try FogCornerStore(vault: fixture.vault).load() })
        #expect(fixture.raw(.corner) != nil)
        fixture.unlock()
        #expect(try FogCornerStore(vault: fixture.vault).load() == state)
    }

    /// A locked walk line throws "try again", stays, and reads back after unlock.
    @Test func aLockedWalkLineIsKept() throws {
        let fixture = Fixture()
        defer { _ = fixture.vault.clearAll() }
        let routes = WorldRouteStore(vault: fixture.vault)
        let id = UUID()
        #expect(try routes.save([RoutePoint(GeoPoint(45.52, -122.62)), RoutePoint(GeoPoint(45.53, -122.63))], for: id))
        let saved = try routes.route(for: id)
        let file = try #require(try fixture.vault.fileNames(withPrefix: "", limit: 10).first)
        fixture.disk.locked = [file]
        #expect(Self.throwsTryAgain { _ = try routes.route(for: id) })
        let names = try fixture.vault.fileNames(withPrefix: "", limit: 10)
        #expect(names == [file])
        fixture.unlock()
        #expect(saved != nil)
        #expect(try routes.route(for: id) == saved)
    }

    // MARK: Road trips

    /// A locked road trip book or line piece throws "try again", stays, and reads back after unlock.
    @Test func aLockedRoadTripIsKept() throws {
        let fixture = Fixture()
        defer { _ = fixture.vault.clearAll() }
        let store = RoadTripStore(vault: fixture.vault)
        let trip = RoadTripCoreTests.trip()
        let book = RoadTripBook(version: RoadTripBook.currentVersion, trips: [trip])
        #expect(store.saveBook(book))
        #expect(store.saveChunk(RoadTripCoreTests.points(3), chunk: 0, of: trip.id))
        let line = try store.readChunk(0, of: trip.id)
        let piece = WorldMapVault.File.roadTripLine(trip: trip.id, chunk: 0)
        fixture.lock(.roadTrips, piece)
        #expect(Self.throwsTryAgain { _ = try store.readBook() })
        #expect(Self.throwsTryAgain { _ = try store.readChunk(0, of: trip.id) })
        #expect(fixture.raw(.roadTrips) != nil && fixture.raw(piece) != nil)
        fixture.unlock()
        #expect(try store.readBook() == book.validated())
        #expect(line.count == 3)
        #expect(try store.readChunk(0, of: trip.id) == line)
    }
}
