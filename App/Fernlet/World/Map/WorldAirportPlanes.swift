import SwiftUI
import WorldMapStore

/// A found airport's planes at street zooms (World-Airports-Spec §5; the mockup's `airportMap` gates and `takeoff`):
/// four jets parked nose down in a row under the tower, in the four tail colours, and about every two minutes one
/// taking off along the runway (``WorldAirportPlaneSchedule``): it rolls along the runway's middle, speeding up,
/// with three white speed marks behind it, then lifts, growing a little as it fades. With Reduce Motion the planes
/// stay parked and nothing takes off. Decoration, hidden from VoiceOver and touches.
///
/// **Cheap:** drawn only while the airport is near the view at street zooms (the layer's rule); between take-offs
/// one sleeping task waits for the next, and a take-off is one SwiftUI animation (``WorldTakeOffMotion``), no timer.
struct WorldAirportPlanes: View {
    /// The airport's token (its beat in the schedule).
    let token: String
    /// The tower's foot on the screen.
    let tower: CGPoint
    /// The runway's two ends on the screen.
    let runway: (CGPoint, CGPoint)
    let dark: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The take-off under way: its progress (animated from 0 to 1), or nil between take-offs.
    @State private var rolling: Double?

    /// The parked jets: their offsets from the tower's foot and their tails (the mockup's gate colours).
    static let gates: [(dx: CGFloat, tail: Int)] = [(-48, 1), (-16, 2), (16, 0), (48, 3)]
    /// How far under the tower's foot the parked jets' middles sit.
    static let gateDrop: CGFloat = 20
    /// The most take-offs one visit plays (a full day at one airport); a bound for the waiting loop.
    static let maxTakeOffs = 720

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Self.gates.indices, id: \.self) { index in
                WorldSpriteView(sprite: WorldAirportSprites.parkedJet(tail: Self.gates[index].tail), scale: 2.5)
                    .position(x: tower.x + Self.gates[index].dx, y: tower.y + Self.gateDrop)
            }
            if !reduceMotion, let rolling {
                WorldTakeOffPlane(dark: dark)
                    .modifier(WorldTakeOffMotion(progress: rolling, start: runway.0, end: runway.1))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: reduceMotion) { await runTakeOffs() }
    }

    /// Waits for each take-off on the airport's beat and plays it, until the planes leave the screen (the task is
    /// cancelled) or Reduce Motion is on.
    private func runTakeOffs() async {
        rolling = nil
        guard !reduceMotion else { return }
        // Bounded: at most `maxTakeOffs` take-offs; the task ends sooner when the airport leaves the view.
        for _ in 0..<Self.maxTakeOffs {
            let wait = WorldAirportPlaneSchedule.nextTakeOff(after: Date(), token: token).timeIntervalSinceNow
            do {
                try await Task.sleep(for: .seconds(max(0, wait)))
                rolling = 0
                try await Task.sleep(for: .milliseconds(50))
                withAnimation(.linear(duration: WorldAirportPlaneSchedule.rollDuration)) { rolling = 1 }
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

/// Moves the taking-off plane along its runway as `progress` animates from 0 to 1 (``WorldAirportPlaneSchedule``):
/// along the runway's middle, speeding up, turned to the runway's heading, then growing and fading as it lifts.
/// Animatable, so one linear animation drives the whole roll, and a pan mid-roll keeps it on the runway.
struct WorldTakeOffMotion: ViewModifier, Animatable {
    var progress: Double
    let start: CGPoint
    let end: CGPoint

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let share = WorldAirportPlaneSchedule.runwayShare(progress)
        let point = CGPoint(x: start.x + (end.x - start.x) * share, y: start.y + (end.y - start.y) * share)
        content
            .rotationEffect(.radians(atan2(Double(end.y - start.y), Double(end.x - start.x))))
            .scaleEffect(WorldAirportPlaneSchedule.liftScale(progress))
            .opacity(WorldAirportPlaneSchedule.liftOpacity(progress))
            .position(point)
    }
}
