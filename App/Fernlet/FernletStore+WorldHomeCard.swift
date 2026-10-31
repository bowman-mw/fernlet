import FernletDomainModel
import FernletFoundation
import Foundation
import WorldMapStore

/// The blue button's card at a home or the hotel (`ref-home-blue` draft 2, owner-approved 2026-10-26;
/// Refinements group 12): where the person stands, the workout space they set up at that home, the latest
/// loop from their door, and the room workout at a hotel. The card's rules are ``WorldQuickStart``'s.
///
/// Everything is read on this iPhone: the homes and hotel from the places file's device side (none in a
/// decoy, ``worldHomes``), the space pins from their sealed store, and the loops from the walks' and runs'
/// lines sealed under "Save new routes" (``WorldRouteStore``). **A loop from the door is not a new record**:
/// it is a saved line whose start and end both lie near a home, picked out when the card opens, so it goes
/// with its walk, with Delete all stored routes and with every wipe, and nothing about it is kept anywhere
/// else. Nothing here leaves the phone.
extension FernletStore {
    /// How near a home a workout space's pin must be to be that home's space, in metres (a pin set in the
    /// garden or the garage still counts; the space match itself is ``SpacePinStore/matchRadius``).
    static let worldHomeSpaceRadius = 150.0

    /// The home or the hotel of the stay that `fix` stands at (the close-up's own reading,
    /// ``WorldCloseUpPlace``), or nil away, without a reading, or in a decoy.
    func worldQuickStartBase(at fix: WorldFix?) -> WorldQuickStartContext.Base? {
        switch WorldCloseUpPlace.at(fix, book: worldHomes, decoy: duressSessionActive) {
        case .home(let name): WorldQuickStartContext.Base(name: name, isHotel: false)
        case .hotel(let name): WorldQuickStartContext.Base(name: name, isHotel: true)
        case .away, .unknown: nil
        }
    }

    /// The workout space the person set up at the home `fix` stands at: the one they stand at
    /// (`spaceID`), else the nearest whose pin lies within ``worldHomeSpaceRadius`` of that home. Nil at a
    /// hotel, away from a home, with no such space, or in a decoy.
    func worldHomeSpace(at fix: WorldFix?, standingAt spaceID: UUID?) -> WorldQuickStartContext.Space? {
        guard !duressSessionActive, let fix, let home = worldHomes.base(near: fix.point), home.kind == .home else { return nil }
        let id = spaceID ?? worldSpaceMarkers(near: nil)
            .filter { $0.point.distance(to: home.point) <= Self.worldHomeSpaceRadius }
            .min { $0.point.distance(to: home.point) < $1.point.distance(to: home.point) }?.id
        guard let id, let location = settings.workoutLocations.first(where: { $0.id == id }) else { return nil }
        return Self.quickStartSpace(location)
    }

    /// The latest loop from the person's door (`ref-home-blue`): among the walks and runs of the last
    /// ``worldSavedLineDays`` days (at most ``worldSavedLineWalksPerDay`` a day, newest first), the first whose
    /// saved line starts and ends near one of the homes (``WorldLoopRule``). Only while "Save new routes" is
    /// on, never at a hotel's, and nil in a decoy or without a home.
    func worldLoopFromDoor(now: Date = Date(), defaults: UserDefaults = .standard) -> WorldSavedLine? {
        let homes = worldHomes.homes.map(\.point)
        guard !duressSessionActive, !homes.isEmpty, WorldMapPreferences.saveNewRoutes(in: defaults) else { return nil }
        for offset in 0..<Self.worldSavedLineDays {
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: now) else { continue }
            let key = FernletDate.dayKey(for: date)
            let outings = (key == todayKey ? day : loadDay(for: key)).workouts
                .filter { Self.savedLineKind(of: $0) != nil }
                .sorted { $0.completedAt > $1.completedAt }
                .prefix(Self.worldSavedLineWalksPerDay)
            for outing in outings {
                guard let kind = Self.savedLineKind(of: outing), let route = worldRoute(for: outing.id) else { continue }
                let points = route.map(\.point)
                guard WorldLoopRule.isLoop(points, metres: WorldRouteCodec.length(of: route), homes: homes) else { continue }
                return WorldSavedLine(workoutID: outing.id, points: points, metres: WorldRouteCodec.length(of: route),
                                      walks: 1, kind: kind)
            }
        }
        return nil
    }

    /// Prepares "Suggest a room workout" at a hotel: the room space (no equipment) becomes the active one,
    /// added the first time with nothing to set up, so Move's suggestion is built from bodyweight alone.
    /// Nothing in a decoy (a decoy has no hotel).
    func prepareRoomWorkout() {
        guard !duressSessionActive else { return }
        var locations = settings.workoutLocations
        if !locations.contains(where: { $0.id == Self.worldRoomSpaceID }) {
            let name = String(localized: "worldQuickStart.roomSpace", defaultValue: "Hotel room",
                              comment: "The workout space the hotel's room workout adds: no equipment (Spanish: Habitación de hotel)")
            locations.append(WorkoutLocation(id: Self.worldRoomSpaceID, name: name, ownedEquipment: []))
            setWorkoutLocations(locations, activeID: Self.worldRoomSpaceID)
            return
        }
        if settings.activeWorkoutLocationID != Self.worldRoomSpaceID { setActiveWorkoutLocation(Self.worldRoomSpaceID) }
    }

    /// The room space's fixed id, so a second hotel stay reuses it rather than adding another (spelled
    /// through the byte initializer, as the built-in spaces are).
    static let worldRoomSpaceID = UUID(uuid: (0x52, 0x4F, 0x4F, 0x4D, 0x00, 0x00, 0x40, 0x00,
                                              0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01))
}

/// When a saved walk or run is a loop from the door (`ref-home-blue` draft 2): it starts and ends within
/// ``doorRadius`` of the same home and is at least ``minimumMetres`` long (a few steps in the garden are not
/// a loop). Plain values, so the rule is tested without a store.
nonisolated enum WorldLoopRule {
    /// How near a home a loop starts and ends, in metres (the approved "within ~150 m").
    static let doorRadius = 150.0
    /// The shortest loop, in metres.
    static let minimumMetres = 300.0

    /// Whether the line `points` (`metres` long) is a loop from one of `homes`.
    static func isLoop(_ points: [GeoPoint], metres: Double, homes: [GeoPoint]) -> Bool {
        guard metres >= minimumMetres, let start = points.first, let end = points.last else { return false }
        return homes.contains { start.distance(to: $0) <= doorRadius && end.distance(to: $0) <= doorRadius }
    }
}
