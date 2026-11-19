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
        #expect(try reopened.pending() == [HexCell(q: 7, r: 7)])
        #expect(try reopened.pending() == [HexCell(q: 7, r: 7)], "reading the buffer leaves it until it is cleared")
        #expect(reopened.clearPending())
        #expect(try reopened.pending().isEmpty)
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

    // MARK: The drive widget (owner's pick 2026-11-13, the CarPlay small widget)

    /// The tally starts a drive with its first reading, hands a moving count over at most every five minutes (with a
    /// heartbeat every twenty when nothing moves), and ends it at a reading on foot.
    @Test func theDriveTallyHandsOverSparingly() {
        var tally = WorldDriveTally()
        let at = { (seconds: TimeInterval) in Self.now.addingTimeInterval(seconds) }
        let every = WorldDriveWidget.writeEvery, beat = WorldDriveWidget.heartbeat
        let nothingToEnd = tally.note(driving: false, newTiles: 0, at: at(0))
        let started = tally.note(driving: true, newTiles: 3, at: at(0))
        let tooSoon = tally.note(driving: true, newTiles: 4, at: at(60))
        let seven = tally.state?.tiles
        let moved = tally.note(driving: true, newTiles: 1, at: at(every))
        let still = tally.note(driving: true, newTiles: 0, at: at(every * 2))
        let heartbeat = tally.note(driving: true, newTiles: 0, at: at(every + beat))
        let ended = tally.note(driving: false, newTiles: 0, at: at(3_600))
        let last = tally.state
        let next = tally.note(driving: true, newTiles: 0, at: at(7_200))
        #expect(!nothingToEnd && started && !tooSoon && seven == 7, "no drive to end; the first reading starts one")
        #expect(moved && !still && heartbeat, "a moving count every five minutes, a still one every twenty")
        #expect(ended && last?.isDriving == false && last?.tiles == 8)
        #expect(next && tally.state?.tiles == 0, "the next drive counts afresh")
    }

    /// The keeper counts a drive's new tiles (none for ground walked or driven before, also while the phone is locked
    /// once the history was read), writes the widget's file with a count and two times only, and the wipe and a decoy
    /// delete it.
    @Test func theKeeperCountsADrivesNewTilesForTheWidget() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let unlocked = LockFlag(true)
        let keeper = try Self.keeper(vault, unlocked: unlocked)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorldDriveWidget-\(UUID().uuidString)")
        defer { _ = try? FileManager.default.removeItem(at: folder) }
        var reloads = 0
        keeper.driveWidget = WorldDriveWidgetKeeper(file: WorldDriveWidgetFile(directory: folder)) { reloads += 1 }
        keeper.handle(Self.fix(Self.here))
        let road = (0...4).map { Self.here.offset(east: Double($0) * 100, north: 0) }
        for point in road { keeper.handle(Self.fix(point), thinLine: true) }
        let counted = try #require(keeper.driveWidget.state)
        #expect(counted.isDriving && counted.tiles > 0 && counted.tiles == keeper.drivenCells.count, "walked ground isn't new")
        let file = WorldDriveWidgetFile(directory: folder)
        #expect(file.read()?.isDriving == true && reloads == 1, "the first reading hands the drive over")
        let data = try Data(contentsOf: file.fileURL)
        let keys = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(Set(keys) == ["version", "tiles", "startedAt", "updatedAt", "isDriving"], "a count and two times only")

        unlocked.isOn = false
        let before = counted.tiles
        let locked = (5...7).map { Self.here.offset(east: Double($0) * 100, north: 0) }
        for point in locked { keeper.handle(Self.fix(point), thinLine: true) }
        for point in locked { keeper.handle(Self.fix(point), thinLine: true) }
        let lockedCount = try #require(keeper.driveWidget.state?.tiles)
        #expect(lockedCount > before, "while locked, counted against the history read before")
        let again = lockedCount
        keeper.handle(Self.fix(locked[2]), thinLine: true)
        #expect(keeper.driveWidget.state?.tiles == again, "a cell counts once while locked")

        unlocked.isOn = true
        keeper.handle(Self.fix(Self.here))
        #expect(keeper.driveWidget.state?.isDriving == false, "a reading on foot ends it")
        #expect(file.read()?.isDriving == false)
        keeper.setDecoy(true)
        #expect(!FileManager.default.fileExists(atPath: file.fileURL.path) && keeper.driveWidget.state == nil, "a decoy shows Sprout")
        keeper.handle(Self.fix(Self.here.offset(east: 3_000, north: 0)), thinLine: true)
        #expect(keeper.driveWidget.state == nil, "a decoy's drive counts nothing")
        keeper.setDecoy(false)
        keeper.handle(Self.fix(Self.here.offset(east: 5_000, north: 0)), thinLine: true)
        #expect(file.read() != nil)
        #expect(keeper.clearAll() && !FileManager.default.fileExists(atPath: file.fileURL.path), "the wipe deletes it")
    }

    /// The widget reads what the app writes: the same kind, file name and keys, small only, and Sprout redacts.
    @Test func theDriveWidgetAndTheAppAgree() throws {
        let widget = try RepoRoot.source("App/FernletWidgets/DriveWidget.swift")
        let bundle = try RepoRoot.source("App/FernletWidgets/FernletWidgetsBundle.swift")
        #expect(bundle.contains("static let drive = \"\(WorldDriveWidget.kind)\"") && bundle.contains("FernletDriveWidget()"))
        #expect(widget.contains("static let fileName = \"\(WorldDriveWidget.fileName)\""))
        for field in ["var version: Int", "var tiles: Int", "var startedAt: Date", "var updatedAt: Date", "var isDriving: Bool"] {
            #expect(widget.contains(field), "the widget's twin lost \(field)")
        }
        #expect(widget.contains(".supportedFamilies([.systemSmall])") && widget.contains(".privacySensitive()"))
    }

    // MARK: Inside an airport, only walking clears (owner 2026-11-02, decided 2026-11-13)

    /// Inside an airport's grounds a reading faster than walking (the plane train, a people mover, the airport's
    /// roads) lifts nothing and joins no lane across; walking there lifts as anywhere.
    @Test func insideAnAirportOnlyWalkingClears() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = try Self.keeper(vault, unlocked: LockFlag(true))
        var train = WorldFix(point: Self.here, accuracy: 8, at: Self.now, isPrecise: true, speed: 12)
        train.atAirport = true
        #expect(WorldFogKeeper.ridesThroughAirport(train))
        #expect(keeper.handle(train) == 0 && keeper.visibleCells.isEmpty, "the plane train lifts nothing")
        var road = WorldFix(point: Self.here.offset(east: 400, north: 0), accuracy: 8, at: Self.now, isPrecise: true, speed: 12)
        road.atAirport = true
        #expect(keeper.handle(road, thinLine: true) == 0 && keeper.visibleCells.isEmpty, "nor a car on its roads")
        var walk = WorldFix(point: Self.here.offset(east: 800, north: 0), accuracy: 8, at: Self.now, isPrecise: true, speed: 1.3)
        walk.atAirport = true
        #expect(!WorldFogKeeper.ridesThroughAirport(walk) && keeper.handle(walk) > 0, "a concourse walked clears")
        var outside = train
        outside.atAirport = false
        #expect(!WorldFogKeeper.ridesThroughAirport(outside), "outside the grounds a drive lifts as ever")
    }

    /// Walking about on a moving ferry's deck or down a train's aisle (2026-11-15, transit investigation X1): Motion's
    /// confident walking ends the drive and, while it says walking, speed alone starts none, yet the readings still go by
    /// at 30 km/h. The stretch replays through the real ride watch into the keeper, as the app hands readings on (the
    /// watch first, then the fog with its answer): no walked cell clears out on the water.
    @Test func walkingOnAMovingFerryClearsNoWalkedFog() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = try Self.keeper(vault, unlocked: LockFlag(true))
        var watch = WorldRideWatch()
        watch.usesMotion = true
        let speed = 30.0 / 3.6
        func at(_ second: Double) -> Date { Self.now.addingTimeInterval(second) }
        func read(_ second: Double) {
            let fix = WorldFix(point: Self.here.offset(east: speed * second, north: 0), accuracy: 10, at: at(second),
                               isPrecise: true, speed: speed)
            _ = watch.observe(fix)
            keeper.handle(fix, thinLine: watch.isDriving)
        }
        // Under way: the coprocessor says automotive, and the drive starts.
        _ = watch.observe([WorldMotionSample(kind: .automotive, isConfident: true, at: at(0))], through: at(5))
        for second in stride(from: 0.0, through: 290, by: 5) {
            read(second)
            if second.truncatingRemainder(dividingBy: 30) == 0 { _ = watch.observe([], through: at(second)) }
        }
        #expect(watch.isDriving, "the ferry under way reads as a drive")
        // The person gets up and walks the deck for ten minutes: confident walking, the boat still at 30 km/h.
        _ = watch.observe([WorldMotionSample(kind: .walking, isConfident: true, at: at(300))])
        for second in stride(from: 300.0, through: 900, by: 5) { read(second) }
        let deck = Self.here.offset(east: speed * 600, north: 0)
        let walked = keeper.visibleCells.subtracting(keeper.drivenCells)
        let deckCircle = Set(MercatorHexGrid.cells(around: deck, within: WorldFogKeeper.liftRadius))
        #expect(!watch.isDriving, "Motion's walking ended the drive (the defect's first half)")
        #expect(walked.isDisjoint(with: deckCircle), "no walked fog clears over the water at 30 km/h")
        #expect(walked.isEmpty, "nothing on the crossing is walked: \(walked.count) walked cells")
        #expect(keeper.drivenCells.contains(MercatorHexGrid.cell(containing: deck)), "the crossing shows as driven")
        // Ashore, a run below a car's speed still clears the walked circle.
        let shore = Self.here.offset(east: 0, north: 2_000)
        let run = WorldFix(point: shore, accuracy: 8, at: at(1_000), isPrecise: true, speed: 4)
        #expect(!WorldFogKeeper.ridesOffADrive(run) && keeper.handle(run) > 0)
        #expect(!keeper.drivenCells.contains(MercatorHexGrid.cell(containing: shore)), "a run is walked")
    }
}

/// Whether the test's phone is unlocked, which the test turns.
@MainActor
private final class LockFlag {
    var isOn: Bool
    init(_ isOn: Bool) { self.isOn = isOn }
}
