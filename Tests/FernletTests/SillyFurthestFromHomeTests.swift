import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// "Furthest from home" (Refinements group 12, owner-approved 2026-10-26): worked out from the map's
/// lifted cells against the homes, hidden until a trip, the companion's pacer given only a coarse step,
/// and its stamp drawn.
@MainActor
struct SillyFurthestFromHomeTests {
    private static let home = GeoPoint(45.5229, -122.6265)

    /// The furthest lifted cell from the nearest home, in metres (to a cell's width); nil without a home
    /// or a cell.
    @Test func theFurthestCellFromTheNearestHome() throws {
        let far = Self.home.offset(east: 0, north: 12_000)
        let cells: Set<HexCell> = [MercatorHexGrid.cell(containing: Self.home), MercatorHexGrid.cell(containing: far)]
        let metres = try #require(SillyFurthestFromHome.meters(cells: cells, homes: [Self.home]))
        #expect(abs(metres - 12_000) < 60)
        let second = far.offset(east: 0, north: 1_000)
        let nearer = try #require(SillyFurthestFromHome.meters(cells: cells, homes: [Self.home, second]))
        #expect(nearer < 1_100, "each cell counts from its nearest home")
        #expect(SillyFurthestFromHome.meters(cells: cells, homes: []) == nil)
        #expect(SillyFurthestFromHome.meters(cells: [], homes: [Self.home]) == nil)
    }

    /// Hidden until the map reaches 5 km from home; the tally takes the input as given, never negative.
    @Test func itAppearsOnATrip() {
        var tally = SillyStatsTally()
        #expect(!SillyStatsEngine.isRevealed(.furthestFromHome, in: tally))
        tally.furthestFromHomeMeters = 4_900
        #expect(!SillyStatsEngine.isRevealed(.furthestFromHome, in: tally))
        tally.furthestFromHomeMeters = 5_000
        #expect(SillyStatsEngine.isRevealed(.furthestFromHome, in: tally))
        let inputs = SillyStatsTallier.Inputs(days: [], todayKey: "2026-10-31", bottleOunces: 16, healthSteps: nil, pats: 0,
                                              unitlessLoadIsPounds: false, furthestFromHomeMeters: 8_400_000)
        #expect(SillyStatsTallier.tally(inputs).furthestFromHomeMeters == 8_400_000)
        let unknown = SillyStatsTallier.Inputs(days: [], todayKey: "2026-10-31", bottleOunces: 16, healthSteps: nil, pats: 0,
                                               unitlessLoadIsPounds: false)
        #expect(SillyStatsTallier.tally(unknown).furthestFromHomeMeters == 0)
    }

    /// The pacer sees how many times the distance has doubled past a kilometre, not the distance.
    @Test func thePacerGetsOnlyACoarseStep() {
        var tally = SillyStatsTally()
        tally.furthestFromHomeMeters = 5_000
        #expect(SillyStatsEngine.value(.furthestFromHome, in: tally) == 2)
        tally.furthestFromHomeMeters = 7_900
        #expect(SillyStatsEngine.value(.furthestFromHome, in: tally) == 2, "a little further says nothing new")
        tally.furthestFromHomeMeters = 10_000
        #expect(SillyStatsEngine.value(.furthestFromHome, in: tally) == 3)
        tally.furthestFromHomeMeters = 500
        #expect(SillyStatsEngine.value(.furthestFromHome, in: tally) == 0)
    }

    /// The card's words and the stamp's.
    @Test func itsWordsAndStamp() {
        var tally = SillyStatsTally()
        tally.furthestFromHomeMeters = 10_018_750
        let english = Locale(identifier: "en_US")
        let text = SillyStatsCopy.text(for: .furthestFromHome, tally: tally, locale: english)
        #expect(text.title == "Furthest from home")
        #expect(text.detail.contains("50%"), "half of the way to the other side of the world: \(text.detail)")
        #expect(SillyStampCopy.name(for: .furthestFromHome, locale: english) == "Far Afield")
        #expect(WorldStampArt.sprite(for: .furthestFromHome) == WorldStampArt.signpost)
    }
}
