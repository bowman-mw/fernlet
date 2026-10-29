import FernletUI
import Foundation
import SwiftUI
import WorldMapStore

/// The companion riding along in its small red car (`b1-home-car`, round 7), drawn around the companion
/// rather than inside its painter: the companion at half the car's pixel sits in the open seat behind the
/// windshield, the car in front of its lower edge, the wheels on the person's spot. Off, the companion as
/// it always stands.
///
/// The car is decoration: the companion inside it keeps its one button and everything it says.
struct WorldRideCar: ViewModifier {
    /// Whether the person is driving now (``WorldRideKeeper/isDriving``).
    let isRiding: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if isRiding {
            VStack(spacing: -Self.seatDepth) {
                content.offset(x: Self.riderShift)
                WorldSpriteView(sprite: WorldSprites.rideCar(dark: colorScheme == .dark, increasedContrast: contrast == .increased),
                                scale: Self.carScale)
                    .zIndex(1)
            }
        } else {
            content
        }
    }

    /// The riding companion's points per sprite pixel: half the car's, as the mockup draws it.
    static let riderScale: CGFloat = 2
    /// The car's points per sprite pixel (a 14 × 10 car: 56 × 40 pt).
    static let carScale: CGFloat = 4
    /// How far the companion's frame sits down into the car: its feet behind the windshield's lower row.
    static let seatDepth: CGFloat = 12
    /// How far right of the car's middle the seat is (the car's columns 6 to 11).
    static let riderShift: CGFloat = 8
}

/// What the companion rides along in on Home (round 7; Refinements group 19): the car while the person
/// drives (`b1-home-car`), the bike while they ride one (`ref-ride-home`). Both hold the same things back
/// (the blue button, the tag, the card, the root's banners and stamps, the hint, the bubble); only the
/// drawing, the plate's title and what VoiceOver hears differ.
enum WorldRideVehicle {
    case car
    case bike

    /// The vehicle for what the ride keeper says (``WorldRideKeeper/isDriving``, ``WorldRideKeeper/isCycling``):
    /// nil on foot. The two never hold at once; driving would win.
    static func current(isDriving: Bool, isCycling: Bool) -> WorldRideVehicle? {
        if isDriving { return .car }
        return isCycling ? .bike : nil
    }

    /// The riding companion's points per sprite pixel.
    var riderScale: CGFloat {
        switch self {
        case .car: WorldRideCar.riderScale
        case .bike: WorldRideBike.riderScale
        }
    }
}

/// The companion on its red bike (Refinements group 19, `ref-ride-home`), drawn around the companion as
/// the car is: the companion at 1.6 pt a pixel, its body's top-left corner 4 pt in from and 25 pt above
/// the bike's (the mockup's placement), sitting over the saddle; the bike's bottom centre on the person's
/// spot, as the car's wheels are. Off, the companion as it always stands.
///
/// The bike is decoration: the companion on it keeps its one button, named for the ride ("Sprout, riding
/// a bike", ``WorldRideCopy/bikeRider(name:)``). Nothing on it moves beyond the companion's own breath.
struct WorldRideBike: ViewModifier {
    /// Whether the person is on a bike now (``WorldRideKeeper/isCycling``).
    let isRiding: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if isRiding {
            VStack(alignment: .leading, spacing: -Self.seatOverlap) {
                content
                    .padding(.leading, Self.riderInset)
                    .zIndex(1)
                WorldSpriteView(sprite: WorldSprites.rideBike(dark: colorScheme == .dark, increasedContrast: contrast == .increased),
                                scale: Self.bikeScale)
            }
        } else {
            content
        }
    }

    /// The riding companion's points per sprite pixel, as the mockup draws it.
    static let riderScale: CGFloat = 1.6
    /// The bike's points per sprite pixel (a 20 × 11 bike: 60 × 33 pt).
    static let bikeScale: CGFloat = 3
    /// How far in from the bike's left edge the companion's body starts.
    static let riderInset: CGFloat = 4
    /// How far above the bike's top edge the companion's body starts.
    static let riderRise: CGFloat = 25
    /// How far the companion's frame reaches down over the bike: its body's height less ``riderRise``
    /// (the frame's top row of padding sits above the body, so the body's top lands ``riderRise`` up).
    static var seatOverlap: CGFloat { WorldCompanionSprite.size(scale: riderScale).height - riderRise }
}

/// The bike ride's line so far on Home's ground (Refinements group 19, `ref-ride-line`): the ride keeper's
/// readings (``WorldRideKeeper/ridePoints``) while a ride is under way, drawn as a saved line is, in the walk
/// line's green, under the companion. Decoration to VoiceOver, as a walk's line is.
enum WorldRideLine {
    /// The points to draw: the readings while cycling, once there are two to join; none on foot, in a car
    /// or in a decoy (no ride is drawn or kept there).
    static func drawn(isCycling: Bool, readings: [RoutePoint], isDecoy: Bool) -> [GeoPoint] {
        guard isCycling, !isDecoy, readings.count >= 2 else { return [] }
        return readings.map(\.point)
    }
}

/// The note that a bike ride logged itself (`b1-home-bike`, round 7): "Bike ride logged · 4.2 km · 18 min"
/// with Undo, the walk's note in every other way (``WorldLoggedNote``). It shows while the store's
/// ``WorldRideKeeper/loggedRide`` is set, and only counts down while Home is in front: a ride that ended
/// under a panel or with the app away waits there until Home is seen. VoiceOver hears the line as the
/// note's window begins, as it hears the walk's; Undo removes the ride's workout. The first time a ride's
/// note is seen it plays ``FernletFeedbackEvent/done`` (owner 2026-10-29), a logged meal's haptic, through
/// the app's Haptics setting; it carries no sound.
struct WorldRideNote: View {
    var store: FernletStore
    /// Whether Home is what the person sees, with the app active.
    let isFrontmost: Bool
    /// The ride whose haptic has played, so Home coming back to the front doesn't play it again.
    @State private var feltRide: UUID?

    var body: some View {
        if let ride = store.worldLocation.rides.loggedRide {
            WorldLoggedNote(line: Text(verbatim: WorldRideCopy.logged(ride)), identifier: .ride) { undo(ride) }
                .padding(.horizontal, 16)
                .padding(.bottom, WorldWalkToast.bottomLift)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
                .task(id: HoldKey(ride: ride.id, isFrontmost: isFrontmost)) { await hold(ride) }
        }
    }

    /// What restarts the note's window: a new ride, or Home coming to the front.
    private struct HoldKey: Equatable {
        let ride: UUID
        let isFrontmost: Bool
    }

    /// Speaks the note, holds it for its window (four seconds, or the assistive one), then lets it go.
    private func hold(_ ride: WorldLoggedRide) async {
        guard isFrontmost else { return }
        FernletAnnouncer.system.announce(.success, resolved: WorldRideCopy.logged(ride))
        if feltRide != ride.id {
            feltRide = ride.id
            FernletFeedback.system.play(.done)
        }
        // DEBUG screenshots (`bike`) keep the note up; the scene list is empty in release builds.
        guard !WorldRideTestScenes.holdsNote else { return }
        let window = FernletDismissalWindow.system.window(standard: .seconds(4), assistive: FernletDismissalWindow.assistiveActionWindow)
        do {
            try await Task.sleep(for: window)
        } catch {
            return
        }
        let rides = store.worldLocation.rides
        if rides.loggedRide?.id == ride.id { rides.loggedRide = nil }
    }

    /// The note's Undo: the ride's workout goes (in a decoy, nothing was kept and the note only closes).
    private func undo(_ ride: WorldLoggedRide) {
        store.worldLocation.rides.loggedRide = nil
        guard store.undoWorldBikeRide(ride) else { return }
        FernletAnnouncer.system.announce(.status, resolved: String(localized: WorldRideCopy.undone))
    }
}

/// Riding along's and the bike note's words (`b1-home-car`, `b1-home-bike`, round 7). The riding-along
/// plate's lines are the notice plates' (``WorldNoticeCopy``).
nonisolated enum WorldRideCopy {
    static let undone = LocalizedStringResource("worldRide.undone", defaultValue: "Bike ride removed.",
                                                comment: "World Home, VoiceOver: said after the bike-ride note's Undo removed the ride")
    static let bubble = LocalizedStringResource("worldRide.bubble", defaultValue: "Wheee! That was a ride.",
                                                comment: "World Home: the companion's speech bubble while the note that a bike ride logged itself shows")

    /// What VoiceOver calls the companion on its bike, one image: "Sprout, riding a bike".
    static func bikeRider(name: String) -> String {
        String(localized: "worldRide.bikeRider", defaultValue: "\(name), riding a bike",
               comment: "World Home, VoiceOver: the companion and its bike during a bike ride, one image; the companion's name")
    }

    /// The note's line: "Bike ride logged · 4.2 km · 18 min", or "Bike ride logged · 18 min" when the
    /// readings gave no distance (a ride found afterwards in the motion history).
    static func logged(_ ride: WorldLoggedRide) -> String {
        guard let metres = ride.metres else {
            return String(localized: "worldRide.logged.noDistance", defaultValue: "Bike ride logged · \(ride.minutes) min",
                          comment: "World Home: the note after a bike ride logged itself, without a distance; its minutes")
        }
        let distance = WorldWalkCopy.distance(metres)
        return String(localized: "worldRide.logged", defaultValue: "Bike ride logged · \(distance) · \(ride.minutes) min",
                      comment: "World Home: the note after a bike ride logged itself; its distance and minutes")
    }

    /// The companion's line while the bike note shows ("Wheee! That was a ride."), else nil: the map's own
    /// line, or the companion's, as before.
    static func bubbleLine(noteShowing: Bool) -> String? {
        noteShowing ? String(localized: bubble) : nil
    }
}

/// DEBUG screenshot scenes for riding along and the bike note (round 7), from `FERNLET_UI_TEST_WORLD_HOME`
/// (none in release builds). Display only: nothing is detected or logged.
/// - `car`: Home as while driving (`b1-home-car`).
/// - `cycling`: Home as on a bike ride, with a short ride line so far ending at the person and the fog
///   drawn clear along it, as a ride's readings would lift it (`ref-ride-home`); nothing is written.
/// - `bike`: the bike note for 4.2 km in 18 min, held on screen (`b1-home-bike`); with `nodistance`, 18 min
///   only. Its Undo only closes it.
/// - `keptride`: Home's saved lines are the finished ride's kept line through the person (`ref-ride-line`),
///   its fog drawn clear; display only, nothing saved.
enum WorldRideTestScenes {
    /// The scenes asked for (none in release builds).
    static var scenes: Set<String> { UITestSupport.worldHomeScenes }

    /// Whether Home is staged as while driving.
    static var drives: Bool { scenes.contains("car") }

    /// Whether Home is staged as on a bike ride.
    static var cycles: Bool { scenes.contains("cycling") }

    /// The staged ride so far (`cycling`), ending at `here`: the mockup's line, up a street, across and back
    /// down to the person, about 650 m, a reading every 20 m or so. Nil when the scene isn't asked for.
    static func stagedRide(endingAt here: GeoPoint) -> [RoutePoint]? {
        guard cycles else { return nil }
        return stagedRide(endingAt: here, corners: stagedCorners)
    }

    /// The mockup's corners east and north of the person, in metres (its points at about 1.1 m each).
    private static let stagedCorners: [(east: Double, north: Double)] = [(-143, 145), (-143, -106), (0, -106), (0, 0)]

    /// Readings along `corners` from `here`, about every 20 m (at most 40 a leg), ending on `here`.
    static func stagedRide(endingAt here: GeoPoint, corners: [(east: Double, north: Double)]) -> [RoutePoint] {
        var readings: [RoutePoint] = []
        for (from, to) in zip(corners, corners.dropFirst()) {
            let length = max(abs(to.east - from.east), abs(to.north - from.north))
            let steps = min(max(1, Int(length / 20)), 40)
            for step in 0..<steps {
                let share = Double(step) / Double(steps)
                readings.append(RoutePoint(here.offset(east: from.east + (to.east - from.east) * share,
                                                       north: from.north + (to.north - from.north) * share)))
            }
        }
        readings.append(RoutePoint(here))
        return readings
    }

    /// The fog the staged line's readings would have lifted (`cycling`), drawn clear and never written: the
    /// walk's clearing round each one. Empty when the scene isn't asked for.
    static func clearing(along line: [GeoPoint]) -> Set<HexCell> {
        guard cycles || keepsRide else { return [] }
        return Set(line.prefix(200).flatMap { MercatorHexGrid.cells(around: $0, within: WorldFogKeeper.liftRadius) })
    }

    /// Whether Home's saved lines are staged as the finished ride's kept line.
    static var keepsRide: Bool { scenes.contains("keptride") }

    /// The mockup's finished ride (`ref-ride-line`), east and north of the person in metres: the ride so far,
    /// then on up the street and back across, so the person stands on it.
    private static let keptCorners: [(east: Double, north: Double)] = [(-143, 145), (-143, -106), (0, -106), (0, 167), (-143, 167)]

    /// The staged saved lines (`keptride`): the finished ride's kept line through `here`. Nil when the scene
    /// isn't asked for.
    static func keptRideLines(around here: GeoPoint) -> [[GeoPoint]]? {
        guard keepsRide, let last = keptCorners.last else { return nil }
        let line = stagedRide(endingAt: here, corners: keptCorners).dropLast().map(\.point)
        return [line + [here.offset(east: last.east, north: last.north)]]
    }

    /// Whether the bike note stays up for the shot.
    static var holdsNote: Bool { scenes.contains("bike") }

    /// Stands the bike note in (`bike`), once.
    static func stage(on rides: WorldRideKeeper, dayKey: String) {
        guard scenes.contains("bike"), rides.loggedRide == nil else { return }
        rides.loggedRide = WorldLoggedRide(id: UUID(uuidString: "7C000000-0000-0000-0000-000000000001") ?? UUID(), dayKey: dayKey,
                                           metres: scenes.contains("nodistance") ? nil : 4_200, minutes: 18, isKept: false)
    }
}
