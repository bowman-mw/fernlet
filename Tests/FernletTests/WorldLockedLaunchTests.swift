import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// The locked launch (owner 2026-11-09, "Fix it next"): when iOS relaunches a closed Fernlet with the phone locked, the
/// store can't load, so the map's location starts before it from background mapping's marker, buffers what it lifts,
/// and hands over to the store once the phone unlocks; the refused load retries at the unlock by itself.
@MainActor
struct WorldLockedLaunchTests {
    private static let here = GeoPoint(45.5205, -122.6255)
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// A fresh folder for a marker.
    private static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorldLockedLaunchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The marker is an empty file, never backed up, that comes and goes with the switch; setting it twice is fine.
    @Test func theMarkerFollowsTheSwitch() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!WorldMapPreferences.backgroundMappingMarked(in: folder))
        WorldMapPreferences.setBackgroundMarker(true, in: folder)
        WorldMapPreferences.setBackgroundMarker(true, in: folder)
        #expect(WorldMapPreferences.backgroundMappingMarked(in: folder))
        let url = try #require(WorldMapPreferences.backgroundMarkerURL(in: folder))
        #expect(try Data(contentsOf: url).isEmpty)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        WorldMapPreferences.setBackgroundMarker(false, in: folder)
        #expect(!WorldMapPreferences.backgroundMappingMarked(in: folder))
        #expect(WorldMapPreferences.backgroundMarkerName == "WorldMapBackground.on")
    }

    /// Nothing starts without the marker or with the phone unlocked; with both, one source starts once, its car book
    /// learns nothing, and the hand-over gives it up exactly once.
    @Test func theHolderStartsOnceAndHandsOverOnce() {
        let marker = MarkerFlag()
        let vault = WorldMapVault.ephemeral()
        let holder = WorldLockedMappingHolder(isMarked: { marker.isOn }, vault: { vault })
        holder.startIfLocked(protectedData: false)
        #expect(holder.source == nil, "no marker")
        marker.isOn = true
        holder.startIfLocked(protectedData: true)
        #expect(holder.source == nil, "the phone allowed the store")
        holder.startIfLocked(protectedData: false)
        let started = holder.source
        #expect(started != nil && holder.start() === started)
        #expect(started?.cars.isDecoy == true, "the car book learns nothing before the store")
        #expect(holder.handOver() === started && holder.source == nil && holder.handOver() == nil)
    }

    /// A reading the early source hears goes into the locked-phone buffer, and the store's fog keeper finds it at its
    /// load.
    @Test func whatTheEarlySourceLiftsWaitsInTheBuffer() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let holder = WorldLockedMappingHolder(isMarked: { true }, vault: { vault })
        let source = try #require(holder.start())
        source.deliver(WorldFix(point: Self.here, accuracy: 8, at: Self.now, isPrecise: true, speed: 1))
        let later = WorldFogKeeper(vault: vault, isProtectedDataAvailable: { true })
        later.load()
        #expect(later.visibleCells.contains(MercatorHexGrid.cell(containing: Self.here)))
    }

    /// The store takes the early source as its own instead of building a second location manager, and only once.
    @Test func theStoreAdoptsTheEarlySource() throws {
        let marker = try #require(WorldMapPreferences.backgroundMarkerURL())
        let wasMarked = FileManager.default.fileExists(atPath: marker.path)
        WorldMapPreferences.setBackgroundMarker(true)
        defer { if !wasMarked { WorldMapPreferences.setBackgroundMarker(false) } }
        let early = try #require(WorldLockedMapping.shared.start())
        let store = makeTestStore()
        #expect(store.worldLocation === early)
        #expect(WorldLockedMapping.shared.source == nil)
        #expect(makeTestStore().worldLocation !== early, "a second store builds its own")
    }

    /// Only a load the locked phone refused retries at the unlock by itself.
    @Test func onlyALockedRefusalRetriesAtTheUnlock() {
        #expect(FernletStoreLoader.wasRefusedWhileLocked(.failed(ExchangeIntentServiceError.deviceLocked)))
        #expect(!FernletStoreLoader.wasRefusedWhileLocked(.failed(ExchangeIntentServiceError.storeUnavailable)))
        #expect(!FernletStoreLoader.wasRefusedWhileLocked(.preparing))
    }
}

/// Whether a test's marker is there, which the test turns on part-way.
@MainActor
private final class MarkerFlag {
    var isOn = false
}
