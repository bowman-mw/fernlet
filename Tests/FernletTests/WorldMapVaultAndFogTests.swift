import CryptoKit
import Foundation
import Testing
import FernletCrypto
import WorldMapStore
@testable import Fernlet

/// The World map's sealed location history and the rules for lifting the fog (World app plan step 5a;
/// design page answers 4, 10, 16 and 21).
@MainActor
struct WorldMapVaultAndFogTests {

    nonisolated static let park = GeoPoint(45.5205, -122.6255)

    static func fix(_ point: GeoPoint = park, accuracy: Double = 10, precise: Bool = true) -> WorldFix {
        WorldFix(point: point, accuracy: accuracy, at: Date(timeIntervalSince1970: 1_792_800_000), isPrecise: precise)
    }

    /// Fresh defaults no other test shares.
    static func freshDefaults() -> UserDefaults {
        let name = "world-fog-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: The cell format

    @Test func theCellFormatRoundTripsAndRefusesNonsense() {
        let cells = Set(MercatorHexGrid.cells(around: Self.park, within: 300)
            + MercatorHexGrid.cells(around: GeoPoint(-33.87, 151.21), within: 60))
        let data = FogCellCodec.encode(cells)
        #expect(FogCellCodec.decode(data, limit: 10_000) == cells)
        #expect(data.count < cells.count * 4, "clustered cells should pack to a few bytes each")
        #expect(FogCellCodec.decode(data, limit: cells.count - 1) == nil, "over the limit is refused, not truncated")
        #expect(FogCellCodec.decode(Data([9]) + data.dropFirst(), limit: 10_000) == nil, "an unknown version is refused")
        #expect(FogCellCodec.decode(data + Data([0x80]), limit: 10_000) == nil, "a cut-off number is refused")
        #expect(FogCellCodec.decode(FogCellCodec.encode([]), limit: 0) == [])
    }

    // MARK: The vault

    @Test func theVaultSealsOpensAndRefusesForeignBytes() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        try vault.write(Data("fog".utf8), to: .fog)
        #expect(try vault.read(.fog) == Data("fog".utf8))
        let url = vault.directory.appendingPathComponent(WorldMapVault.File.fog.name)
        let sealed = try Data(contentsOf: url)
        #expect(sealed.starts(with: Data("FWM1".utf8)))
        #expect(!sealed.contains(Data("fog".utf8)), "the file holds ciphertext, not the cells")
        // The fog file moved into the buffer's name must not open as the buffer (its own purpose).
        try sealed.write(to: vault.directory.appendingPathComponent(WorldMapVault.File.pendingFog.name))
        #expect(throws: WorldMapVault.VaultError.unopenable) { try vault.read(.pendingFog) }
        var tampered = sealed
        tampered[tampered.count - 1] ^= 0x01
        try tampered.write(to: url)
        #expect(throws: WorldMapVault.VaultError.unopenable) { try vault.read(.fog) }
        let excluded = try vault.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true, "the map folder must stay out of device backups")
    }

    @Test func aLockedKeyIsAnErrorNotAFreshStart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorldMap-\(UUID().uuidString)")
        let key = SymmetricKey(size: .bits256)
        let writer = WorldMapVault(directory: directory, keys: WorldMapKeys(key: { _ in key }, removeAll: { true }))
        try writer.write(Data("history".utf8), to: .fog)
        let locked = WorldMapVault(directory: directory, keys: WorldMapKeys(
            key: { _ in throw WorldMapVault.VaultError.keyUnavailable }, removeAll: { true }))
        let store = FogCellStore(vault: locked)
        #expect(throws: WorldMapVault.VaultError.keyUnavailable) { try store.load() }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("fog.bin").path),
                "a locked phone must never delete the history it can't read yet")
        #expect(writer.clearAll())
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: The store

    @Test func theStoreLiftsSavesAndDrainsTheLockedPhoneBuffer() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let store = FogCellStore(vault: vault)
        try store.load()
        let near = MercatorHexGrid.cells(around: Self.park, within: 50)
        #expect(store.lift(near) == Set(near).count)
        #expect(store.lift(near) == 0, "a cell lifts once")
        try store.save()
        let later = MercatorHexGrid.cells(around: Self.park.offset(east: 400, north: 0), within: 50)
        try store.appendPending(later)
        let reopened = FogCellStore(vault: vault)
        try reopened.load()
        #expect(reopened.cells == Set(near).union(later))
        #expect(try vault.read(.pendingFog) == nil, "the buffer empties once it is merged")
    }

    @Test func aDamagedStoreStartsFreshInsteadOfStickingAround() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        try vault.write(Data([0x07, 0x01]), to: .fog)
        try Data("not a map".utf8).write(to: vault.directory.appendingPathComponent("fog.bin"))
        let store = FogCellStore(vault: vault)
        try store.load()
        #expect(store.cells.isEmpty)
        #expect(try vault.read(.fog) == nil, "unopenable bytes are removed, not kept as noise")
    }

    @Test func theStoreRefusesPastItsCapRatherThanEvicting() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let store = FogCellStore(vault: vault)
        try store.load()
        let many = (0..<FogCellStore.maxCells).map { HexCell(q: $0, r: 0) }
        #expect(store.lift(many) == FogCellStore.maxCells)
        #expect(store.lift([HexCell(q: -1, r: 1)]) == 0)
        #expect(store.refusedCount == 1 && store.cells.contains(HexCell(q: 0, r: 0)))
    }

    // MARK: The keeper's rules

    static func keeper(defaults: UserDefaults, unlocked: Bool = true) -> (WorldFogKeeper, WorldMapVault) {
        let vault = WorldMapVault.ephemeral()
        let keeper = WorldFogKeeper(vault: vault, defaults: defaults, isProtectedDataAvailable: { unlocked })
        keeper.load()
        return (keeper, vault)
    }

    @Test func onlyPreciseAccurateReadingsLiftAndOnlyWhileTheSettingIsOn() {
        let defaults = Self.freshDefaults()
        let (keeper, vault) = Self.keeper(defaults: defaults)
        defer { _ = vault.clearAll() }
        #expect(keeper.handle(Self.fix(precise: false)) == 0, "approximate location lifts nothing")
        #expect(keeper.handle(Self.fix(accuracy: 200)) == 0, "a vague reading lifts nothing")
        WorldMapPreferences.setUncoverAsYouGo(false, in: defaults)
        #expect(keeper.handle(Self.fix()) == 0, "\"Uncover the map as you go\" off lifts nothing")
        WorldMapPreferences.setUncoverAsYouGo(true, in: defaults)
        #expect(keeper.handle(Self.fix()) > 0)
        #expect(keeper.visibleCells.contains(MercatorHexGrid.cell(containing: Self.park)))
    }

    @Test func theSettingsDefaultToOnAndOffAndTheWipeClearsThem() {
        let defaults = Self.freshDefaults()
        #expect(WorldMapPreferences.uncoverAsYouGo(in: defaults) && !WorldMapPreferences.alwaysLowPower(in: defaults))
        WorldMapPreferences.setUncoverAsYouGo(false, in: defaults)
        WorldMapPreferences.setAlwaysLowPower(true, in: defaults)
        WorldMapPreferences.clearAll(in: defaults)
        #expect(defaults.object(forKey: WorldMapPreferences.Key.uncoverAsYouGo) == nil)
        #expect(defaults.object(forKey: WorldMapPreferences.Key.alwaysLowPower) == nil)
    }

    @Test func aDecoySessionShowsNoHistoryAndLeavesNothingBehind() throws {
        let defaults = Self.freshDefaults()
        let (keeper, vault) = Self.keeper(defaults: defaults)
        defer { _ = vault.clearAll() }
        keeper.handle(Self.fix())
        keeper.flush()
        let history = keeper.visibleCells
        keeper.setDecoy(true)
        #expect(keeper.visibleCells.isEmpty, "the decoy hides the history")
        let elsewhere = Self.park.offset(east: 2_000, north: 0)
        #expect(keeper.handle(Self.fix(elsewhere)) > 0)
        keeper.setDecoy(false)
        #expect(keeper.visibleCells == history, "the decoy's own cells vanish when it ends")
        let reopened = FogCellStore(vault: vault)
        try reopened.load()
        #expect(reopened.cells == history, "nothing from the decoy reached the store")
    }

    @Test func aLockedPhoneBuffersAndTheNextUnlockMerges() throws {
        let defaults = Self.freshDefaults()
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let phone = PhoneLockState()
        let keeper = WorldFogKeeper(vault: vault, defaults: defaults, isProtectedDataAvailable: { phone.unlocked })
        keeper.load()
        #expect(keeper.handle(Self.fix()) == 0)
        #expect(try vault.read(.pendingFog) != nil, "the reading waits in the buffer")
        phone.unlocked = true
        keeper.load()
        #expect(keeper.visibleCells.contains(MercatorHexGrid.cell(containing: Self.park)))
    }

    @Test func theWipeRemovesEveryFileAndForgetsTheCells() throws {
        let defaults = Self.freshDefaults()
        let (keeper, vault) = Self.keeper(defaults: defaults)
        keeper.handle(Self.fix())
        keeper.flush()
        #expect(keeper.clearAll())
        #expect(keeper.visibleCells.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: vault.directory.path))
    }

    @Test func theStoreAndTheRecoveryLockReachTheWipe() throws {
        let store = try RepoRoot.source("App/Fernlet/FernletStore.swift")
        #expect(store.contains("if !worldFog.clearAll() {") && store.contains("WorldMapPreferences.clearAll()"))
        #expect(store.contains("worldFog.setDecoy(duressSessionActive)"), "the fog must follow the decoy flag")
        let content = try RepoRoot.source("App/Fernlet/ContentView.swift")
        let hook = try #require(content.range(of: "lockService.installRecoveryLockPurgeHook {"))
        let hookEnd = try #require(content.range(of: "\n        }\n", range: hook.upperBound..<content.endIndex))
        #expect(content[hook.lowerBound..<hookEnd.upperBound].contains("store.worldFog.clearAll()"))
    }
}

/// Whether the test's phone is unlocked, shared with the keeper's check by reference.
@MainActor
private final class PhoneLockState {
    var unlocked = false
}
