import Foundation
import Testing
@testable import Fernlet

/// Home's riding along and bike-ride note (round 7; `b1-home-car`, `b1-home-bike`): the riding-along
/// plate's place among the notices, the note's line with and without a distance, the companion's line
/// while the note shows, and the car sprite's shape.
@MainActor
struct WorldRideHomeTests {
    /// The notice for a set of facts, driving or not.
    private func notice(_ presence: WorldMapPresence = .precise, tiles: WorldTileState = .ready, long: Bool = false,
                        cells: Int = 500, decoy: Bool = false, walking: Bool = false, driving: Bool) -> WorldMapNoticeKind? {
        WorldMapNoticeKind.make(presence: presence, tiles: tiles, loadingLong: long, liftedCells: cells,
                                isDecoy: decoy, isWalking: walking, isDriving: driving)
    }

    /// While driving the riding-along plate stands in for every other one (offline, approximate, loading,
    /// first day); with location off there is no map and no plate; on foot the order is as before.
    @Test func ridingAlongComesFirstWhileDriving() {
        #expect(notice(driving: true) == .ridingAlong)
        #expect(notice(tiles: .failed, driving: true) == .ridingAlong)
        #expect(notice(.approximate, driving: true) == .ridingAlong)
        #expect(notice(tiles: .loading, long: true, driving: true) == .ridingAlong)
        #expect(notice(cells: 10, driving: true) == .ridingAlong)
        #expect(notice(cells: 10, decoy: true, driving: true) == .ridingAlong)
        #expect(notice(.off, tiles: .failed, driving: true) == nil)
        #expect(notice(tiles: .failed, driving: false) == .offline)
        #expect(notice(cells: 10, driving: false) == .firstDay)
        #expect(notice(driving: false) == nil)
    }

    /// The plate's frozen identifier, and what VoiceOver hears as it appears: both lines.
    @Test func ridingAlongHasItsIdentifierAndAnnouncement() {
        #expect(WorldMapNotice.identifier(.ridingAlong) == "ridingAlong")
        let spoken = WorldMapNotice.announcement(.ridingAlong)
        #expect(spoken == "\(String(localized: WorldNoticeCopy.ridingAlong)). \(String(localized: WorldNoticeCopy.ridingAlongDetail))")
        #expect(String(localized: WorldNoticeCopy.ridingAlong) == "Riding along")
        #expect(String(localized: WorldNoticeCopy.ridingAlongDetail) == "Quick starts and banners pause until you're on foot.")
    }

    /// "Bike ride logged · 4.2 km · 18 min" with a distance (in the region's road unit, as the walk's
    /// note writes it), "Bike ride logged · 18 min" without one.
    @Test func theNoteSaysTheRide() {
        let ride = WorldLoggedRide(id: UUID(), dayKey: "2026-10-29", metres: 4_200, minutes: 18, isKept: true)
        #expect(WorldRideCopy.logged(ride) == "Bike ride logged · \(WorldWalkCopy.distance(4_200)) · 18 min")
        let noDistance = WorldLoggedRide(id: UUID(), dayKey: "2026-10-29", metres: nil, minutes: 18, isKept: true)
        #expect(WorldRideCopy.logged(noDistance) == "Bike ride logged · 18 min")
    }

    /// The companion says "Wheee! That was a ride." while the note shows, and its own line otherwise.
    @Test func theBubbleCheersWhileTheNoteShows() {
        #expect(WorldRideCopy.bubbleLine(noteShowing: true) == "Wheee! That was a ride.")
        #expect(WorldRideCopy.bubbleLine(noteShowing: false) == nil)
    }

    /// The car is the mockup's 14 × 10, every row the same width, every key coloured; Increase Contrast
    /// changes only colours, and on the dark map its outline turns light.
    @Test func theCarIsDrawnAsApproved() {
        let car = WorldSprites.rideCar
        #expect(car.width == 14 && car.height == 10)
        #expect(car.rows.allSatisfy { $0.count == car.width })
        let keys = Set(car.rows.joined()).subtracting(["."])
        #expect(keys.allSatisfy { car.palette[$0] != nil })
        #expect(WorldSprites.rideCar(dark: true, increasedContrast: false) == car)
        let dark = WorldSprites.rideCar(dark: true, increasedContrast: true)
        #expect(dark.rows == car.rows && dark.palette["k"] == 0xF5EFE0)
        #expect(WorldSprites.rideCar(dark: false, increasedContrast: true).palette["k"] == 0x24140B)
    }
}
