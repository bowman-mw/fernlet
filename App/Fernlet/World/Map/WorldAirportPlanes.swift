import SwiftUI
import WorldMapStore

/// A found airport's planes at street zooms (World-Airports-Spec §5; the mockup's `airportMap` gates and `takeoff`):
/// four jets parked nose down in a row under the tower, in the four tail colours, and about every two minutes one
/// moving along a runway (``WorldAirportPlaneSchedule``). Taking off, it rolls along the runway's middle, speeding up,
/// with three white speed marks behind it, then lifts, growing a little as it fades. Landing (owner 2026-11-02), it
/// does the same backwards in time: it comes down shrinking into view, touches down and slows. With Reduce Motion the
/// planes stay parked and nothing moves. Decoration, hidden from VoiceOver and touches.
///
/// **Cheap:** drawn only while the airport is near the view, at street zooms or with its fence showing (the layer's
/// rule); between planes one sleeping task waits for the next, and a plane is one SwiftUI animation (``WorldTakeOffMotion``), no timer.
struct WorldAirportPlanes: View {
    /// The airport's token (its beat in the schedule).
    let token: String
    /// The tower's foot on the screen.
    let tower: CGPoint
    /// The runways' two ends on the screen, longest first.
    let runways: [(CGPoint, CGPoint)]
    let dark: Bool
    /// Whether the jets at the gates draw (street zooms; further out only the plane on the runway does).
    var showsParked = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The plane under way: its progress (animated from 0 to 1 taking off, from 1 to 0 landing), or nil between planes.
    @State private var rolling: Double?
    /// What the plane under way is doing.
    @State private var movement = WorldAirportMovement(runway: 0, isLanding: false, turnedRound: false)

    /// The parked jets: their offsets from the tower's foot and their tails (the mockup's gate colours).
    static let gates: [(dx: CGFloat, tail: Int)] = [(-48, 1), (-16, 2), (16, 0), (48, 3)]
    /// How far under the tower's foot the parked jets' middles sit.
    static let gateDrop: CGFloat = 20
    /// The most take-offs one visit plays (a full day at one airport); a bound for the waiting loop.
    static let maxTakeOffs = 720

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsParked {
                ForEach(Self.gates.indices, id: \.self) { index in
                    WorldSpriteView(sprite: WorldAirportSprites.parkedJet(tail: Self.gates[index].tail), scale: 2.5)
                        .position(x: tower.x + Self.gates[index].dx, y: tower.y + Self.gateDrop)
                }
            }
            if !reduceMotion, let rolling, let path = path(of: movement) {
                WorldTakeOffPlane(dark: dark)
                    .modifier(WorldTakeOffMotion(progress: rolling, start: path.0, end: path.1, isLanding: movement.isLanding))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: reduceMotion) { await runTakeOffs() }
    }

    /// The ends `movement`'s plane runs between, in ``WorldTakeOffMotion``'s order: a landing plays the roll backwards,
    /// so its ends swap to travel the same way as the take-off in its pair.
    private func path(of movement: WorldAirportMovement) -> (CGPoint, CGPoint)? {
        guard runways.indices.contains(movement.runway) else { return runways.first }
        let ends = runways[movement.runway]
        return movement.turnedRound != movement.isLanding ? (ends.1, ends.0) : ends
    }

    /// Waits for each plane on the airport's beat and plays it, until the planes leave the screen (the task is
    /// cancelled) or Reduce Motion is on.
    private func runTakeOffs() async {
        rolling = nil
        guard !reduceMotion else { return }
        // Bounded: at most `maxTakeOffs` planes; the task ends sooner when the airport leaves the view.
        for _ in 0..<Self.maxTakeOffs {
            let beat = WorldAirportPlaneSchedule.nextTakeOff(after: Date(), token: token)
            let next = WorldAirportPlaneSchedule.movement(onBeatAt: beat, token: token, runways: runways.count)
            do {
                try await Task.sleep(for: .seconds(max(0, beat.timeIntervalSinceNow)))
                movement = next
                rolling = next.isLanding ? 1 : 0
                try await Task.sleep(for: .milliseconds(50))
                withAnimation(.linear(duration: WorldAirportPlaneSchedule.rollDuration)) { rolling = next.isLanding ? 0 : 1 }
                try await Task.sleep(for: .seconds(WorldAirportPlaneSchedule.rollDuration + 0.2))
            } catch {
                rolling = nil
                return
            }
            rolling = nil
        }
    }
}

/// The plane taking off: the jet nose right (the mockup's `JET_R`, tail colour 1) at 2.5× with three speed marks
/// trailing behind it (`--ap-mark`, white; #D8DCE2 in dark).
struct WorldTakeOffPlane: View {
    let dark: Bool

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { k in
                Rectangle()
                    .fill(WorldPalette.rgb(dark ? 0xD8DCE2 : 0xFFFFFF).opacity(0.85))
                    .frame(width: CGFloat(12 - k * 3), height: 2)
                    .offset(x: CGFloat(-26 - k * 16), y: CGFloat((k - 1) * 6))
            }
            WorldSpriteView(sprite: WorldAirportSprites.rollingJet(tail: 0), scale: 2.5)
        }
    }
}

/// Moves the plane along its runway as `progress` animates (``WorldAirportPlaneSchedule``): from 0 to 1 taking off,
/// along the runway's middle, speeding up, turned to the runway's heading, then growing and fading as it lifts; from
/// 1 to 0 landing, the same backwards, nose first towards `start`.
/// Animatable, so one linear animation drives the whole roll, and a pan mid-roll keeps it on the runway.
struct WorldTakeOffMotion: ViewModifier, Animatable {
    var progress: Double
    let start: CGPoint
    let end: CGPoint
    var isLanding = false

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let share = WorldAirportPlaneSchedule.runwayShare(progress)
        let point = CGPoint(x: start.x + (end.x - start.x) * share, y: start.y + (end.y - start.y) * share)
        let heading = isLanding ? atan2(Double(start.y - end.y), Double(start.x - end.x)) : atan2(Double(end.y - start.y), Double(end.x - start.x))
        content
            .rotationEffect(.radians(heading))
            .scaleEffect(WorldAirportPlaneSchedule.liftScale(progress))
            .opacity(isLanding ? WorldAirportPlaneSchedule.landingOpacity(progress) : WorldAirportPlaneSchedule.liftOpacity(progress))
            .position(point)
    }
}
