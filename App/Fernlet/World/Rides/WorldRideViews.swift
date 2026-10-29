import FernletUI
import Foundation
import SwiftUI

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
/// - `bike`: the bike note for 4.2 km in 18 min, held on screen (`b1-home-bike`); with `nodistance`, 18 min
///   only. Its Undo only closes it.
enum WorldRideTestScenes {
    /// The scenes asked for (none in release builds).
    static var scenes: Set<String> { UITestSupport.worldHomeScenes }

    /// Whether Home is staged as while driving.
    static var drives: Bool { scenes.contains("car") }

    /// Whether the bike note stays up for the shot.
    static var holdsNote: Bool { scenes.contains("bike") }

    /// Stands the bike note in (`bike`), once.
    static func stage(on rides: WorldRideKeeper, dayKey: String) {
        guard scenes.contains("bike"), rides.loggedRide == nil else { return }
        rides.loggedRide = WorldLoggedRide(id: UUID(uuidString: "7C000000-0000-0000-0000-000000000001") ?? UUID(), dayKey: dayKey,
                                           metres: scenes.contains("nodistance") ? nil : 4_200, minutes: 18, isKept: false)
    }
}
