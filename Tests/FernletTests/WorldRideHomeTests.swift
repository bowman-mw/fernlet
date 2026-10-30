import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Home's riding along and bike-ride note (round 7; `b1-home-car`, `b1-home-bike`) and the bike ride on
/// Home (Refinements group 19; `ref-ride-home`, `ref-ride-line`): the riding-along plates' place among the
/// notices, the note's line with and without a distance, the companion's line while the note shows, the
/// car's and the bike's sprites, the companion's seat on the bike, its name on VoiceOver, and the ride's
/// line so far.
@MainActor
struct WorldRideHomeTests {
    /// The notice for a set of facts, driving, cycling or neither.
    private func notice(_ presence: WorldMapPresence = .precise, tiles: WorldTileState = .ready, long: Bool = false,
                        cells: Int = 500, decoy: Bool = false, walking: Bool = false, driving: Bool,
                        cycling: Bool = false) -> WorldMapNoticeKind? {
        WorldMapNoticeKind.make(presence: presence, tiles: tiles, loadingLong: long, liftedCells: cells,
                                isDecoy: decoy, isWalking: walking, isDriving: driving, isCycling: cycling)
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

    /// On a bike the bike's plate stands where the car's does, before every other one; the car's wins if
    /// both were ever said at once.
    @Test func theBikesPlateComesFirstWhileCycling() {
        #expect(notice(driving: false, cycling: true) == .ridingAlongBike)
        #expect(notice(tiles: .failed, driving: false, cycling: true) == .ridingAlongBike)
        #expect(notice(.approximate, driving: false, cycling: true) == .ridingAlongBike)
        #expect(notice(tiles: .loading, long: true, driving: false, cycling: true) == .ridingAlongBike)
        #expect(notice(cells: 10, driving: false, cycling: true) == .ridingAlongBike)
        #expect(notice(.off, driving: false, cycling: true) == nil)
        #expect(notice(driving: true, cycling: true) == .ridingAlong)
    }

    /// The bike's plate: "Riding along" under its own key, the car's line under it, its own identifier, and
    /// VoiceOver hears "Riding along on your bike" with the line.
    @Test func theBikesPlateSaysRidingAlongOnYourBike() {
        #expect(WorldMapNotice.identifier(.ridingAlongBike) == "ridingAlongBike")
        #expect(String(localized: WorldNoticeCopy.ridingAlongBike) == "Riding along")
        #expect(WorldNoticeCopy.ridingAlongBike.key == "worldNotice.ridingAlong.bike")
        #expect(String(localized: WorldNoticeCopy.ridingAlongBikeSpoken) == "Riding along on your bike")
        let spoken = WorldMapNotice.announcement(.ridingAlongBike)
        #expect(spoken == "Riding along on your bike. Quick starts and banners pause until you're on foot.")
    }

    /// The companion rides the car while driving, the bike while cycling, nothing on foot, at the riding
    /// scale each mockup draws.
    @Test func theVehicleFollowsTheRide() {
        #expect(WorldRideVehicle.current(isDriving: true, isCycling: false) == .car)
        #expect(WorldRideVehicle.current(isDriving: false, isCycling: true) == .bike)
        #expect(WorldRideVehicle.current(isDriving: false, isCycling: false) == nil)
        #expect(WorldRideVehicle.current(isDriving: true, isCycling: true) == .car)
        #expect(WorldRideVehicle.car.riderScale == 2 && WorldRideVehicle.bike.riderScale == 1.6)
    }

    /// The bike is the mockup's 20 × 11 with its three keys (ink, the car's red, grey spokes); Increase
    /// Contrast changes only colours, as the car's does.
    @Test func theBikeIsDrawnAsApproved() {
        let bike = WorldSprites.rideBike
        #expect(bike.width == 20 && bike.height == 11)
        #expect(bike.rows.allSatisfy { $0.count == bike.width })
        #expect(bike.palette == ["k": 0x4A2E1C, "R": 0xC8553D, "g": 0x9C9A92])
        #expect(Set(bike.rows.joined()).subtracting(["."]) == ["k", "R", "g"])
        #expect(bike.palette["R"] == WorldSprites.rideCar.palette["R"])
        #expect(WorldSprites.rideBike(dark: true, increasedContrast: false) == bike)
        let dark = WorldSprites.rideBike(dark: true, increasedContrast: true)
        #expect(dark.rows == bike.rows && dark.palette["k"] == 0xF5EFE0 && dark.palette["g"] == 0x9C9A92)
        #expect(WorldSprites.rideBike(dark: false, increasedContrast: true).palette["k"] == 0x24140B)
    }

    /// The companion's body sits 4 pt in from and 25 pt above the bike's top-left corner: its frame (the
    /// body plus one row of padding on top) reaches down over the bike by the body's height less 25.
    @Test func theCompanionSitsOnTheSaddle() {
        let scale = WorldRideBike.riderScale
        let frameHeight = WorldCompanionSprite.size(scale: scale).height + scale
        let bikeTop = frameHeight - WorldRideBike.seatOverlap
        #expect(abs(scale - bikeTop + 25) < 0.001)
        #expect(WorldRideBike.riderInset == 4 && WorldRideBike.bikeScale == 3)
    }

    /// VoiceOver names the companion and its bike as one: "Sprout, riding a bike".
    @Test func theRiderIsNamed() {
        #expect(WorldRideCopy.bikeRider(name: "Sprout") == "Sprout, riding a bike")
    }

    /// The ride's line is drawn while cycling once two readings join, never on foot, in a car or a decoy.
    @Test func theRideLineDrawsOnlyWhileCycling() {
        let here = GeoPoint(45.5205, -122.6255)
        let readings = [RoutePoint(here.offset(east: 0, north: -100)), RoutePoint(here)]
        #expect(WorldRideLine.drawn(isCycling: true, readings: readings, isDecoy: false) == readings.map(\.point))
        #expect(WorldRideLine.drawn(isCycling: false, readings: readings, isDecoy: false).isEmpty)
        #expect(WorldRideLine.drawn(isCycling: true, readings: Array(readings.prefix(1)), isDecoy: false).isEmpty)
        #expect(WorldRideLine.drawn(isCycling: true, readings: readings, isDecoy: true).isEmpty)
    }

    /// The DEBUG `cycling` scene's ride ends where the person stands, a reading every 20 m or so, and is
    /// absent unless the scene is asked for (never under the test runner).
    @Test func theStagedRideEndsAtThePerson() {
        let here = GeoPoint(45.5205, -122.6255)
        let ride = WorldRideTestScenes.stagedRide(endingAt: here, corners: [(-143, 145), (-143, -106), (0, -106), (0, 0)])
        #expect(ride.last?.point == here)
        #expect(ride.count > 20 && ride.count < 60)
        #expect(WorldRideTestScenes.stagedRide(endingAt: here) == nil)
        #expect(WorldRideTestScenes.clearing(along: ride.map(\.point)).isEmpty)
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
