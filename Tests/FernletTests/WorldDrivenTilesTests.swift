import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Driven, not walked (owner 2026-11-09: "driven should be mostly transparent but still there, then you fully unlock
/// when you walk"): a drive's new cells are see-through, walking or riding through one clears it for good, what was
/// uncovered before stays clear, the passport and city card still count a drive, the week's corner needs walking, a
/// drive while the phone is locked waits in its own buffer, and a decoy keeps its own.
@MainActor
struct WorldDrivenTilesTests {
    private static let here = GeoPoint(45.5205, -122.6255)
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// A reading at `point`.
    private static func fix(_ point: GeoPoint) -> WorldFix {
        WorldFix(point: point, accuracy: 8, at: now, isPrecise: true)
    }

    /// A fog keeper over `vault`, its own settings, and a lock the test turns.
    private static func keeper(_ vault: WorldMapVault, unlocked: LockFlag) throws -> WorldFogKeeper {
        let defaults = try #require(UserDefaults(suiteName: "WorldDrivenTilesTests.\(UUID().uuidString)"))
        let keeper = WorldFogKeeper(vault: vault, defaults: defaults, isProtectedDataAvailable: { unlocked.isOn })
        keeper.load()
        return keeper
    }

    /// The store keeps, saves, reopens, buffers and hands over its cells, and a walk takes them out.
    @Test func theDrivenStoreKeepsItsCells() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let store = DrivenFogStore(vault: vault)
        #expect(store.add([HexCell(q: 1, r: 1)]) == 0, "nothing before load")
        try store.load()
        let lane = (0..<5).map { HexCell(q: $0, r: 0) }
        #expect(store.add(lane) == 5 && store.add(lane) == 0)
        #expect(store.remove([HexCell(q: 0, r: 0), HexCell(q: 9, r: 9)]) == 1)
        try store.save()
        let reopened = DrivenFogStore(vault: vault)
        try reopened.load()
        #expect(reopened.cells == Set(lane.dropFirst()))
        try reopened.appendPending([HexCell(q: 7, r: 7)])
        #expect(try reopened.takePending() == [HexCell(q: 7, r: 7)] && (try reopened.takePending()).isEmpty)
    }

    /// A drive's new cells are driven; walking part of the lane clears that part; driving over walked ground keeps
    /// it clear; every cell still counts as uncovered.
    @Test func aDriveIsSeeThroughUntilWalked() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = try Self.keeper(vault, unlocked: LockFlag(true))
        let walkedFirst = Self.here.offset(east: 600, north: 0)
        keeper.handle(Self.fix(walkedFirst))
        let walkedCircle = Set(MercatorHexGrid.cells(around: walkedFirst, within: WorldFogKeeper.liftRadius))
        let road = (0...8).map { Self.here.offset(east: Double($0) * 100, north: 0) }
        for point in road { keeper.handle(Self.fix(point), thinLine: true) }
        #expect(!keeper.drivenCells.isEmpty && keeper.drivenCells.isSubset(of: keeper.visibleCells))
        #expect(keeper.drivenCells.isDisjoint(with: walkedCircle), "ground walked before stays clear")
        let start = MercatorHexGrid.cell(containing: road[0])
        #expect(keeper.drivenCells.contains(start))
        keeper.handle(Self.fix(road[0]))
        #expect(!keeper.drivenCells.contains(start) && keeper.visibleCells.contains(start), "walked is walked")
        keeper.flush()
        let reopened = try Self.keeper(vault, unlocked: LockFlag(true))
        #expect(reopened.drivenCells == keeper.drivenCells && reopened.visibleCells == keeper.visibleCells)
    }

    /// The week's corner never counts a cell only driven past as reached: a driven cell near home may still be the
    /// corner to walk into, which a walked one never is.
    @Test func theCornerNeedsWalking() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = try Self.keeper(vault, unlocked: LockFlag(true))
        for step in 0...20 { keeper.handle(Self.fix(Self.here.offset(east: Double(step) * 40, north: 300)), thinLine: true) }
        let driven = keeper.drivenCells
        #expect(!driven.isEmpty)
        if let corner = keeper.currentCorner(home: Self.here, now: Self.now) {
            #expect(!keeper.visibleCells.subtracting(driven).contains(corner), "a walked cell is never the corner")
        }
    }

    /// A drive with the phone locked waits in its own buffer; a walk meanwhile over a cell driven before clears it;
    /// at the unlock the drive joins the fog, driven, except where walked.
    @Test func aLockedDriveMergesAtTheUnlock() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let lock = LockFlag(true)
        let keeper = try Self.keeper(vault, unlocked: lock)
        keeper.handle(Self.fix(Self.here), thinLine: true)
        let drivenBefore = MercatorHexGrid.cell(containing: Self.here)
        #expect(keeper.drivenCells.contains(drivenBefore))
        keeper.flush()
        lock.isOn = false
        let away = Self.here.offset(east: 2_000, north: 0)
        keeper.handle(Self.fix(away), thinLine: true)
        keeper.handle(Self.fix(Self.here))
        #expect(!keeper.visibleCells.contains(MercatorHexGrid.cell(containing: away)), "nothing shows while locked")
        lock.isOn = true
        keeper.load()
        #expect(keeper.visibleCells.contains(MercatorHexGrid.cell(containing: away)))
        #expect(keeper.drivenCells.contains(MercatorHexGrid.cell(containing: away)), "the locked drive is driven")
        #expect(!keeper.drivenCells.contains(drivenBefore), "walked while locked is walked")
    }

    /// A decoy's drive is its own, in memory only, and goes with the decoy; the history's comes back.
    @Test func aDecoyKeepsItsOwnDrive() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = try Self.keeper(vault, unlocked: LockFlag(true))
        keeper.handle(Self.fix(Self.here), thinLine: true)
        let history = keeper.drivenCells
        keeper.setDecoy(true)
        #expect(keeper.drivenCells.isEmpty)
        let elsewhere = Self.here.offset(east: 3_000, north: 0)
        keeper.handle(Self.fix(elsewhere), thinLine: true)
        #expect(keeper.drivenCells.contains(MercatorHexGrid.cell(containing: elsewhere)))
        keeper.handle(Self.fix(elsewhere))
        #expect(!keeper.drivenCells.contains(MercatorHexGrid.cell(containing: elsewhere)))
        keeper.setDecoy(false)
        #expect(keeper.drivenCells == history)
        _ = keeper.clearAll()
        #expect(keeper.drivenCells.isEmpty, "the wipe forgets the driven cells")
    }

    /// The map draws a driven cell as see-through fog unless it is kept clear round a home or a place, and at 30 %.
    @Test func theMapDrawsDrivenCellsSeeThrough() {
        let cell = HexCell(q: 3, r: 4), home = HexCell(q: 5, r: 5)
        let clearing = NatureFogClearing(lifted: [cell, home], uncovered: [home], driven: [cell, home])
        #expect(clearing.isDriven(cell) && clearing.isClear(cell) && !clearing.isVeiled(cell))
        #expect(!clearing.isDriven(home), "a home's circle stays clear")
        #expect(!NatureFogClearing(lifted: [cell]).isDriven(cell))
        #expect(NatureFogDrawer.drivenOpacity == 0.3 && NatureFogDrawer.veilOpacity == 0.5)
    }
}

/// Whether the test's phone is unlocked, which the test turns.
@MainActor
private final class LockFlag {
    var isOn: Bool
    init(_ isOn: Bool) { self.isOn = isOn }
}
