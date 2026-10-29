import FernletCrypto
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// The weekly "one new corner" (round 7, spec §5, owner's option 1): the pick (a fogged patch, a walk away,
/// the nearest band, the week's stable hash), Monday weeks, the bearing VoiceOver reads, the sealed state,
/// and the keeper's week, reach, lapse, decoy and wipe.
@MainActor
struct WorldCornerNudgeTests {
    nonisolated static let home = GeoPoint(45.5205, -122.6255)

    /// UTC Gregorian, so the tests' weeks don't move with the Mac's time zone.
    nonisolated static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar
    }

    /// 2026-10-29 12:00 UTC, a Thursday.
    nonisolated static var thursday: Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 12)) ?? Date(timeIntervalSince1970: 1_793_275_200)
    }

    /// 2026-10-26 00:00 UTC, that week's Monday.
    nonisolated static var monday: Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: 26)) ?? Date(timeIntervalSince1970: 1_792_972_800)
    }

    nonisolated static let week: TimeInterval = 7 * 24 * 60 * 60

    /// Every cell within `metres` of `point`.
    nonisolated static func disc(_ point: GeoPoint, _ metres: Double) -> Set<HexCell> {
        Set(MercatorHexGrid.disc(around: point, radius: metres))
    }

    /// Metres from home to `cell`'s centre.
    nonisolated static func metres(_ cell: HexCell) -> Double {
        home.distance(to: MercatorHexGrid.centreGeo(of: cell))
    }

    /// A keeper over `vault` in UTC weeks.
    static func keeper(_ vault: WorldMapVault) -> WorldCornerNudgeKeeper {
        WorldCornerNudgeKeeper(vault: vault, calendar: Self.utc)
    }

    // MARK: Weeks

    /// A week starts on Monday 00:00 in the calendar's zone, even for a calendar whose own week starts on
    /// Sunday, and the same week has the same index in any time zone.
    @Test func weeksStartOnMondayAndKeepTheirIndexAcrossZones() {
        #expect(FogCornerNudge.weekStart(for: Self.thursday, calendar: Self.utc) == Self.monday)
        var sunday = Self.utc
        sunday.firstWeekday = 1
        #expect(FogCornerNudge.weekStart(for: Self.thursday, calendar: sunday) == Self.monday)
        #expect(FogCornerNudge.weekStart(for: Self.monday, calendar: Self.utc) == Self.monday)
        let index = FogCornerNudge.weekIndex(of: Self.monday)
        for zone in ["America/Los_Angeles", "Pacific/Auckland", "Pacific/Kiritimati", "Pacific/Pago_Pago"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone) ?? Self.utc.timeZone
            let start = FogCornerNudge.weekStart(for: Self.thursday, calendar: calendar)
            #expect(FogCornerNudge.weekIndex(of: start) == index, "\(zone)")
        }
        #expect(FogCornerNudge.weekIndex(of: Self.monday.addingTimeInterval(Self.week)) == index + 1)
    }

    // MARK: The pick

    /// The same week always picks the same cell, from any day of it.
    @Test func sameWeekSamePick() {
        let first = FogCornerNudge.pick(home: Self.home, revealed: [], weekStart: Self.monday)
        let start = FogCornerNudge.weekStart(for: Self.thursday, calendar: Self.utc)
        #expect(first != nil)
        #expect(FogCornerNudge.pick(home: Self.home, revealed: [], weekStart: start) == first)
    }

    /// Weeks differ by the week's hash, and a new week passes over last week's corner when it can.
    @Test func nextWeekPicksADifferentCellWhenItCan() throws {
        let weeks = (0..<8).compactMap { index in
            FogCornerNudge.pick(home: Self.home, revealed: [], weekStart: Self.monday.addingTimeInterval(Double(index) * Self.week))
        }
        #expect(weeks.count == 8)
        #expect(Set(weeks).count > 1, "the week's hash moves the pick")
        let this = try #require(FogCornerNudge.pick(home: Self.home, revealed: [], weekStart: Self.monday))
        let next = FogCornerNudge.weekStart(for: Self.thursday.addingTimeInterval(Self.week), calendar: Self.utc)
        let moved = FogCornerNudge.pick(home: Self.home, revealed: [], weekStart: next, avoiding: this)
        #expect(moved != nil && moved != this)
    }

    /// With every fog cell revealed but one patch, avoiding it still gives it: "when possible".
    @Test func theOnlyPatchIsPickedEvenWhenAvoided() throws {
        let middle = MercatorHexGrid.cell(containing: Self.home.offset(east: 400, north: 0))
        let patch = Set([middle] + MercatorHexGrid.neighbours(of: middle))
        let revealed = Self.disc(Self.home, 1_100).subtracting(patch)
        let this = try #require(FogCornerNudge.pick(home: Self.home, revealed: revealed, weekStart: Self.monday))
        #expect(this == middle, "a ring cell has only three fogged neighbours")
        #expect(FogCornerNudge.pick(home: Self.home, revealed: revealed, weekStart: Self.monday, avoiding: this) == this)
    }

    /// The nearest band wins: with nothing revealed, the corner is 120 to 220 m away, never nearer.
    @Test func theNearestBandAWalkAwayWins() throws {
        let cell = try #require(FogCornerNudge.pick(home: Self.home, revealed: [], weekStart: Self.monday))
        #expect(Self.metres(cell) >= FogCornerNudge.minimumMetres)
        #expect(Self.metres(cell) < FogCornerNudge.minimumMetres + FogCornerNudge.bandMetres)
        // With the near ground walked, the corner moves out to the next fog.
        let walked = Self.disc(Self.home, 500)
        let further = try #require(FogCornerNudge.pick(home: Self.home, revealed: walked, weekStart: Self.monday))
        #expect(Self.metres(further) > 450 && Self.metres(further) <= FogCornerNudge.searchMetres)
        #expect(!walked.contains(further))
    }

    /// Fog only at the doorstep (within 110 m) is no corner: a walk, not the doorstep.
    @Test func nothingWithin120Metres() {
        let doorstep = Self.disc(Self.home, 110)
        let revealed = Self.disc(Self.home, 1_100).subtracting(doorstep)
        #expect(FogCornerNudge.pick(home: Self.home, revealed: revealed, weekStart: Self.monday) == nil)
    }

    /// A single fogged cell, or two side by side, among revealed ground is a gap, not a patch.
    @Test func aOneCellGapIsNotAPatch() throws {
        let all = Self.disc(Self.home, 1_100)
        let gap = MercatorHexGrid.cell(containing: Self.home.offset(east: 0, north: 300))
        #expect(!FogCornerNudge.isFoggedPatch(gap, in: all.subtracting([gap])))
        #expect(FogCornerNudge.pick(home: Self.home, revealed: all.subtracting([gap]), weekStart: Self.monday) == nil)
        let pair = try #require(MercatorHexGrid.neighbours(of: gap).first)
        #expect(FogCornerNudge.pick(home: Self.home, revealed: all.subtracting([gap, pair]), weekStart: Self.monday) == nil)
        // Four of six neighbours fogged is a patch; three is not.
        let ring = MercatorHexGrid.neighbours(of: gap)
        #expect(FogCornerNudge.isFoggedPatch(gap, in: Set(ring.prefix(2))))
        #expect(!FogCornerNudge.isFoggedPatch(gap, in: Set(ring.prefix(3))))
        #expect(!FogCornerNudge.isFoggedPatch(gap, in: [gap]), "a revealed cell is never a corner")
    }

    /// Everything within 1 km walked: no corner.
    @Test func allRevealedWithinOneKilometreGivesNil() {
        let revealed = Self.disc(Self.home, FogCornerNudge.searchMetres)
        #expect(FogCornerNudge.pick(home: Self.home, revealed: revealed, weekStart: Self.monday) == nil)
    }

    /// A home off the globe, or a week that is not a date, picks nothing.
    @Test func anInvalidHomeOrWeekPicksNothing() {
        #expect(FogCornerNudge.pick(home: GeoPoint(.nan, 0), revealed: [], weekStart: Self.monday) == nil)
        #expect(FogCornerNudge.pick(home: GeoPoint(95, 0), revealed: [], weekStart: Self.monday) == nil)
        #expect(FogCornerNudge.pick(home: Self.home, revealed: [], weekStart: Date(timeIntervalSince1970: .infinity)) == nil)
    }

    /// Bounded: the home disc never exceeds the examined cap, at the equator, at 45° or at 60°, and a pick in
    /// the far north still lies within 1 km.
    @Test func bounded() throws {
        for latitude in [0.0, 45.0, 60.0, 70.0] {
            let point = GeoPoint(latitude, 10)
            #expect(MercatorHexGrid.disc(around: point, radius: FogCornerNudge.searchMetres).count <= FogCornerNudge.maxExamined)
            let cell = try #require(FogCornerNudge.pick(home: point, revealed: [], weekStart: Self.monday))
            #expect(point.distance(to: MercatorHexGrid.centreGeo(of: cell)) <= FogCornerNudge.searchMetres)
        }
    }

    // MARK: The bearing

    /// The eight frozen tokens, each for a corner 300 m that way, with the distance.
    @Test func bearingTokensForTheEightDirections() {
        #expect(CompassPoint.allCases.map(\.rawValue) == ["n", "ne", "e", "se", "s", "sw", "w", "nw"])
        for (index, point) in CompassPoint.allCases.enumerated() {
            let angle = Double(index) * 45 * .pi / 180
            let target = Self.home.offset(east: 300 * sin(angle), north: 300 * cos(angle))
            let bearing = FogCornerNudge.bearingAndDistance(from: Self.home, to: MercatorHexGrid.cell(containing: target))
            #expect(bearing.compass == point)
            #expect(abs(bearing.metres - 300) < 25)
        }
        let here = FogCornerNudge.bearingAndDistance(from: MercatorHexGrid.centreGeo(of: HexCell(q: 5, r: 5)), to: HexCell(q: 5, r: 5))
        #expect(here.compass == .n && here.metres < 0.01)
    }

    // MARK: The sealed state

    /// The state's 18 bytes round-trip through an ephemeral vault, under its frozen name and purpose; damaged
    /// or foreign bytes are refused.
    @Test func theSealedRoundTripThroughAnEphemeralVault() throws {
        #expect(WorldMapVault.File.corner.name == "corner.bin")
        #expect(WorldMapVault.File.corner.purpose == FernletCryptoPurpose.AEAD.worldMapCornerV1)
        #expect(FernletCryptoPurpose.AEAD.worldMapCornerV1.rawValue == "fernlet.world-map.corner.aead.v1")
        let state = FogCornerState(weekStart: Self.monday, cell: HexCell(q: -12_345, r: 67_890), reached: true)
        #expect(state.encoded().count == 18)
        #expect(FogCornerState(data: state.encoded()) == state)
        #expect(FogCornerState(data: Data(state.encoded().dropLast())) == nil)
        var badFlag = state.encoded()
        badFlag[17] = 2
        #expect(FogCornerState(data: badFlag) == nil)
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let store = FogCornerStore(vault: vault)
        #expect(try store.load() == nil)
        try store.save(state)
        #expect(try FogCornerStore(vault: vault).load() == state)
        let raw = try Data(contentsOf: vault.directory.appendingPathComponent("corner.bin"))
        #expect(raw.starts(with: Data("FWM1".utf8)) && raw.count > 18, "sealed, not plain")
    }

    /// An unopenable file is removed and reads as no corner; a key that can't be read is an error, and the
    /// file is left alone.
    @Test func anUnopenableFileIsRemovedAndALockedKeyIsAnError() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        try vault.write(Data("not a corner".utf8), to: .corner)
        #expect(try FogCornerStore(vault: vault).load() == nil)
        #expect(try vault.read(.corner) == nil, "a sealed file that is not a corner is removed")
        try FogCornerStore(vault: vault).save(FogCornerState(weekStart: Self.monday, cell: HexCell(q: 1, r: 2)))
        let locked = WorldMapVault(directory: vault.directory, keys: WorldMapKeys(
            key: { _ in throw WorldMapVault.VaultError.keyUnavailable }, removeAll: { true }))
        #expect(throws: WorldMapVault.VaultError.keyUnavailable) { try FogCornerStore(vault: locked).load() }
        #expect(Self.keeper(locked).current(home: Self.home, revealed: [], now: Self.thursday) == nil)
        #expect(try FogCornerStore(vault: vault).load()?.cell == HexCell(q: 1, r: 2), "never written over")
    }

    // MARK: The keeper

    /// No home, no nudge, and nothing written.
    @Test func noHomeNoNudge() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = Self.keeper(vault)
        #expect(keeper.current(home: nil, revealed: [], now: Self.thursday) == nil)
        #expect(keeper.corner == nil)
        #expect(try vault.read(.corner) == nil)
    }

    /// The week's pick is saved and a relaunch (a new keeper) shows the same one, from the file.
    @Test func theWeeksPickSurvivesARelaunch() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let cell = try #require(Self.keeper(vault).current(home: Self.home, revealed: [], now: Self.thursday))
        #expect(try FogCornerStore(vault: vault).load() == FogCornerState(weekStart: Self.monday, cell: cell))
        let relaunched = Self.keeper(vault)
        #expect(relaunched.current(home: Self.home, revealed: [], now: Self.monday.addingTimeInterval(3_600)) == cell)
        #expect(relaunched.corner == cell)
        // The file, not a fresh pick: a kept corner no pick would choose is still the one shown.
        let kept = MercatorHexGrid.cell(containing: Self.home.offset(east: 700, north: 0))
        try FogCornerStore(vault: vault).save(FogCornerState(weekStart: Self.monday, cell: kept))
        #expect(Self.keeper(vault).current(home: Self.home, revealed: [], now: Self.thursday) == kept)
    }

    /// Walking into the corner marks it reached: it goes at once, stays gone that week, and the file says so.
    @Test func reachedWhenLifted() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = Self.keeper(vault)
        let cell = try #require(keeper.current(home: Self.home, revealed: [], now: Self.thursday))
        keeper.noteRevealed([HexCell(q: 0, r: 0)])
        #expect(keeper.corner == cell, "another lift leaves it")
        keeper.noteRevealed([cell])
        #expect(keeper.corner == nil)
        #expect(keeper.current(home: Self.home, revealed: [cell], now: Self.thursday) == nil)
        #expect(try FogCornerStore(vault: vault).load()?.reached == true)
        // Lifted while the keeper wasn't told (a locked-phone buffer drained): the history says so.
        let other = WorldMapVault.ephemeral()
        defer { _ = other.clearAll() }
        let fresh = Self.keeper(other)
        let second = try #require(fresh.current(home: Self.home, revealed: [], now: Self.thursday))
        #expect(Self.keeper(other).current(home: Self.home, revealed: [second], now: Self.thursday) == nil)
        #expect(try FogCornerStore(vault: other).load()?.reached == true)
    }

    /// Not walked into, the corner lapses: next week shows a new one (and a reached one gives way too).
    @Test func lapsesNextWeek() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = Self.keeper(vault)
        let cell = try #require(keeper.current(home: Self.home, revealed: [], now: Self.thursday))
        let nextWeek = Self.thursday.addingTimeInterval(Self.week)
        let next = try #require(keeper.current(home: Self.home, revealed: [], now: nextWeek))
        #expect(next != cell)
        #expect(try FogCornerStore(vault: vault).load() == FogCornerState(weekStart: Self.monday.addingTimeInterval(Self.week), cell: next))
        keeper.noteRevealed([next])
        #expect(keeper.current(home: Self.home, revealed: [next], now: nextWeek.addingTimeInterval(Self.week)) != nil)
    }

    /// A home moved more than 1 km away gets a corner of its own.
    @Test func aMovedHomeGetsItsOwnCorner() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = Self.keeper(vault)
        _ = try #require(keeper.current(home: Self.home, revealed: [], now: Self.thursday))
        let moved = Self.home.offset(east: 5_000, north: 0)
        let cell = try #require(keeper.current(home: moved, revealed: [], now: Self.thursday))
        #expect(FogCornerNudge.isCorner(cell, of: moved))
    }

    /// Everything near home walked: no corner, and nothing written.
    @Test func allWalkedGivesNoCorner() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = Self.keeper(vault)
        let revealed = Self.disc(Self.home, FogCornerNudge.searchMetres)
        #expect(keeper.current(home: Self.home, revealed: revealed, now: Self.thursday) == nil)
        #expect(keeper.current(home: Self.home, revealed: revealed, now: Self.thursday) == nil, "remembered, not repicked")
        #expect(try vault.read(.corner) == nil)
    }

    /// A decoy shows no corner and keeps nothing: no file read or written, and leaving shows the real one.
    @Test func aDecoyKeepsNothing() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = Self.keeper(vault)
        keeper.setDecoy(true)
        #expect(keeper.isDecoy)
        #expect(keeper.current(home: Self.home, revealed: [], now: Self.thursday) == nil)
        #expect(try vault.read(.corner) == nil)
        keeper.setDecoy(false)
        let cell = try #require(keeper.current(home: Self.home, revealed: [], now: Self.thursday))
        keeper.setDecoy(true)
        #expect(keeper.corner == nil)
        keeper.noteRevealed([cell])
        #expect(try FogCornerStore(vault: vault).load()?.reached == false, "a decoy's walk reaches nothing")
        keeper.setDecoy(false)
        #expect(keeper.current(home: Self.home, revealed: [], now: Self.thursday) == cell)
    }

    /// The wipe empties it: the file goes and no corner shows until the next pick.
    @Test func clearAllEmpties() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = Self.keeper(vault)
        _ = try #require(keeper.current(home: Self.home, revealed: [], now: Self.thursday))
        #expect(keeper.clearAll())
        #expect(keeper.corner == nil)
        #expect(try vault.read(.corner) == nil)
        #expect(!FileManager.default.fileExists(atPath: vault.directory.appendingPathComponent("corner.bin").path))
    }
}
