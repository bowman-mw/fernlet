import FernletDomainModel
import FernletScoring
import FernletUI
import SwiftUI

/// The boarding hop on screen (owner's storyboard v2, page UABPFeySzGuLEisj7bMKn3): the open scene's sky, the
/// runway, Sprout's plane side-on (``WorldSideJetSprite``), the steps, Sprout in its own look with its suitcase,
/// and at the window the in-flight view handing over, all moved by ``WorldBoardingHopTimeline``. The camera's zoom
/// into Sprout's window is drawn inside the canvas, so the pixels stay sharp at every size.
///
/// **Interaction:** a tap anywhere on it skips to the end (a quick fade). **Accessibility:** one image labelled
/// with the line VoiceOver heard as it started, with a Skip action; Reduce Motion holds the end moment still for a
/// second and fades.
struct WorldBoardingHopScene: View {
    var store: FernletStore
    let play: WorldBoardingHopPlay
    let layout: WorldFlyingLayout
    var bodySignal: CompanionBodySignal?
    var isNight: Bool
    let onSkip: () -> Void
    let onFinish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long a skip's fade takes.
    static let skipFade = 0.25

    var body: some View {
        let now = WorldCompanionLook.current(store: store, at: play.start, night: .map, bodySignal: bodySignal, mapNight: isNight)
        let tint = WorldBoardingHopArt.tint(of: now)
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let frame = WorldBoardingHopTimeline.frame(play.direction, at: timeline.date.timeIntervalSince(play.start),
                                                       reduceMotion: reduceMotion)
            let fade = play.skippedAt.map { 1 - WorldBoardingHopTimeline.ramp(timeline.date.timeIntervalSince($0), 0, Self.skipFade) } ?? 1
            GeometryReader { proxy in
                let stage = WorldBoardingHopStage(size: proxy.size, layout: layout)
                ZStack(alignment: .topLeading) {
                    WorldOffScenePalette.skyGradient
                    Canvas { context, _ in WorldBoardingHopPainter.paint(frame, stage: stage, tint: tint, in: context) }
                    if let feet = frame.sprout { sprout(now, feet: stage.parked.offsetBy(feet)) }
                    if frame.flightView > 0 { flightView.opacity(frame.flightView) }
                }
            }
            .opacity(frame.opacity * fade)
        }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(perform: onSkip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: play.line))
        .accessibilityAddTraits(.isImage)
        .accessibilityAction(named: Text(WorldBoardingHopCopy.skip), onSkip)
        .task(id: play.skippedAt) { await waitOut() }
    }

    /// Sprout at its pixel size here, its feet on `feet`, its suitcase trailing behind it.
    private func sprout(_ now: WorldCompanionNow, feet: CGPoint) -> some View {
        let scale = WorldBoardingHopTimeline.pixel
        let size = WorldCompanionSprite.size(scale: scale)
        let trailing: CGFloat = play.direction == .boarding ? 1 : -1
        return ZStack(alignment: .topLeading) {
            WorldSpriteView(sprite: WorldAirportSprites.suitcase, scale: scale)
                .position(x: feet.x + trailing * 28, y: feet.y - CGFloat(WorldAirportSprites.suitcase.height) * scale / 2)
            WorldCompanionSprite(now: now, isActive: true, pixelScale: scale)
                .position(x: feet.x, y: feet.y - (size.height + scale) / 2)
        }
    }

    /// The in-flight view as Home draws it in the air (``WorldFlyingScene`` over the open scene's sky), for the
    /// hand-over at the window.
    private var flightView: some View {
        ZStack(alignment: .bottom) {
            WorldOffScenePalette.skyGradient
            WorldFlyingScene(store: store, bodySignal: bodySignal, isActive: false, isNight: isNight)
        }
    }

    /// Waits out the scene (or a skip's fade), then says it has finished.
    private func waitOut() async {
        let left: Double
        if let skipped = play.skippedAt {
            left = Self.skipFade - Date().timeIntervalSince(skipped)
        } else {
            left = WorldBoardingHopTimeline.length(reduceMotion: reduceMotion) - Date().timeIntervalSince(play.start)
        }
        do {
            try await Task.sleep(for: .seconds(max(0, left)))
        } catch {
            return
        }
        onFinish()
    }
}

/// The boarding hop's geometry in a scene `size` big, in points: the runway, where the plane parks and where it
/// cruises, and where the in-flight view's glass stands for the hand-over at the window. Pure.
nonisolated struct WorldBoardingHopStage: Equatable, Sendable {
    let size: CGSize
    let layout: WorldFlyingLayout

    /// The plane's size on screen.
    static let planeSize = CGSize(width: CGFloat(WorldSideJetSprite.width) * WorldBoardingHopTimeline.pixel,
                                  height: CGFloat(WorldSideJetSprite.height) * WorldBoardingHopTimeline.pixel)

    /// The runway's top edge.
    var groundY: CGFloat { size.height - 58 }

    /// The parked plane's top-left corner, its wheels a little into the tarmac.
    var parked: CGPoint { CGPoint(x: 16, y: groundY + 2 - Self.planeSize.height) }

    /// The cruising plane's top-left corner, centred across the scene.
    var level: CGPoint { CGPoint(x: ((size.width - Self.planeSize.width) / 2).rounded(), y: (size.height * 0.22).rounded()) }

    /// The plane's top-left corner in `frame`.
    func plane(_ frame: WorldBoardingHopFrame) -> CGPoint {
        let ground = CGPoint(x: parked.x + frame.roll, y: parked.y)
        return WorldBoardingHopTimeline.lerp(ground, level, Double(frame.climb))
    }

    /// The middle of Sprout's window on the plane whose top-left corner is `plane`.
    func window(_ plane: CGPoint) -> CGPoint {
        let half = CGFloat(WorldSideJetSprite.windowSize) / 2
        return CGPoint(x: plane.x + (CGFloat(WorldSideJetSprite.sproutWindow.x) + half) * WorldBoardingHopTimeline.pixel,
                       y: plane.y + (CGFloat(WorldSideJetSprite.sproutWindow.y) + half) * WorldBoardingHopTimeline.pixel)
    }

    /// The middle of Sprout's glass in the in-flight view (``WorldFlyingScene``, standing on the scene's foot).
    var glass: CGPoint {
        let tubeTop = size.height - layout.lowerCloudDrop - WorldFlyingClouds.size.height - layout.tubeHeight
        return CGPoint(x: WorldFlyingLayout.sproutX, y: tubeTop + layout.glassTop + layout.glassSize.height / 2)
    }

    /// How far the window is scaled at full zoom: until it is as wide as the in-flight view's glass.
    var fullZoom: CGFloat {
        max(1, layout.glassSize.width / (CGFloat(WorldSideJetSprite.windowSize) * WorldBoardingHopTimeline.pixel))
    }
}

extension CGPoint {
    /// This point moved by `offset`'s x and y.
    nonisolated func offsetBy(_ offset: CGPoint) -> CGPoint {
        CGPoint(x: x + offset.x, y: y + offset.y)
    }
}

/// The boarding hop's pixel art beyond the plane: the steps, the clouds' rows, the runway's colours, and the
/// plane's three looks as colour runs (drawn once each).
nonisolated enum WorldBoardingHopArt {
    /// The airstairs, 12 × 12, rising to the left to the door's sill.
    static let steps = WorldSprite(
        rows: ["kkkk........", "kffk........", "kkkkkk......", "kffffk......", "kkkkkkkk....", "kffffffk....",
               "kkkkkkkkkk..", "kffffffffk..", "kkkkkkkkkkkk", "kffffffffffk", "kk........kk", "kk........kk"],
        palette: ["k": WorldSprite.ink, "f": 0xB7BEC4])
    static let parkedRuns = WorldSideJetSprite.colourRuns(of: WorldSideJetSprite.parked)
    static let rollingRuns = WorldSideJetSprite.colourRuns(of: WorldSideJetSprite.rolling)
    static let flyingRuns = WorldSideJetSprite.colourRuns(of: WorldSideJetSprite.flying)
    static let stepRuns = WorldSideJetSprite.colourRuns(of: steps)
    /// The tarmac and its centre dashes.
    static let tarmac: UInt32 = 0x8C8F8A
    static let tarmacDark: UInt32 = 0x4F534F
    static let dash: UInt32 = 0xF6F1E4
    /// Sprout's window glows in the body colour of Sprout's own look when the window doesn't say otherwise.
    static let fallbackTint: UInt32 = 0xD2973B

    /// The plane's runs for `frame`'s look.
    static func runs(for frame: WorldBoardingHopFrame) -> [WorldSpriteColourRun] {
        if frame.doorOpen { return parkedRuns }
        return frame.gearDown ? rollingRuns : flyingRuns
    }

    /// The colour at the middle of Sprout's body in `now`'s look: what shows in its window from outside.
    @MainActor
    static func tint(of now: WorldCompanionNow) -> UInt32 {
        let grid = WorldCompanionPainter.paint(state: now.state, look: now.look, pose: WorldCompanionPose())
        return grid.frameColor(x: 12, y: 14) ?? fallbackTint
    }
}

/// Draws one moment of the boarding hop into a canvas (``WorldBoardingHopFrame`` on a ``WorldBoardingHopStage``):
/// the zoom first, then the clouds, the runway, the steps, the plane with Sprout's window, its speed marks and the
/// touch-down puff. Every shape is a hard-edged rectangle.
enum WorldBoardingHopPainter {
    /// Hard edges for every fill.
    static let crisp = FillStyle(antialiased: false)

    /// `frame` on `stage`, Sprout's window glowing `tint`.
    static func paint(_ frame: WorldBoardingHopFrame, stage: WorldBoardingHopStage, tint: UInt32, in base: GraphicsContext) {
        var context = base
        let plane = stage.plane(frame)
        if frame.zoom > 0 {
            let scale = pow(stage.fullZoom, frame.zoom)
            let share = stage.fullZoom > 1 ? (scale - 1) / (stage.fullZoom - 1) : 0
            let window = stage.window(plane), glass = stage.glass
            context.translateBy(x: window.x + (glass.x - window.x) * share, y: window.y + (glass.y - window.y) * share)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -window.x, y: -window.y)
        }
        clouds(frame, stage: stage, in: context)
        runway(frame, stage: stage, in: context)
        if frame.steps > 0 {
            var steps = context
            steps.opacity = frame.steps
            let sill = WorldBoardingHopTimeline.sill
            draw(WorldBoardingHopArt.stepRuns, at: stage.parked.offsetBy(CGPoint(x: sill.x + 4, y: sill.y + 2)), in: steps)
        }
        jet(frame, at: plane, tint: tint, in: context)
    }

    /// The plane at `origin`, pitched by `frame.tilt` about its middle, with its window, marks and puff.
    private static func jet(_ frame: WorldBoardingHopFrame, at origin: CGPoint, tint: UInt32, in base: GraphicsContext) {
        var context = base
        let size = WorldBoardingHopStage.planeSize, pixel = WorldBoardingHopTimeline.pixel
        context.translateBy(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        context.rotate(by: .degrees(frame.tilt))
        context.translateBy(x: -size.width / 2, y: -size.height / 2)
        draw(WorldBoardingHopArt.runs(for: frame), at: .zero, in: context)
        if frame.windowLit {
            let window = WorldSideJetSprite.sproutWindow, side = CGFloat(WorldSideJetSprite.windowSize) * pixel
            let glass = CGRect(x: CGFloat(window.x) * pixel, y: CGFloat(window.y) * pixel, width: side, height: side)
            context.fill(Path(glass), with: .color(WorldPalette.rgb(tint)), style: crisp)
        }
        // Bounded: at most three marks.
        for mark in 0..<min(frame.marks, 3) {
            let rect = CGRect(x: 8 - CGFloat(mark) * 16, y: 70 + CGFloat(mark - 1) * 7, width: CGFloat(12 - mark * 3), height: 2)
            context.fill(Path(rect), with: .color(WorldFlyingPalette.cloud.opacity(0.9)), style: crisp)
        }
        guard frame.puff > 0 else { return }
        var puff = context
        puff.opacity = frame.puff
        // Bounded: the puff's three bits.
        for (dx, dy) in [(-10.0, 0.0), (-2.0, -2.0), (6.0, 0.0)] {
            puff.fill(Path(CGRect(x: 120 + dx, y: 96 + dy, width: 6, height: 4)), with: .color(WorldFlyingPalette.cloud), style: crisp)
        }
    }

    /// The runway along the scene's foot, sliding down as the plane climbs, its dashes running past.
    private static func runway(_ frame: WorldBoardingHopFrame, stage: WorldBoardingHopStage, in context: GraphicsContext) {
        let width = stage.size.width, top = stage.groundY + frame.climb * stage.size.height
        guard top < stage.size.height else { return }
        let below = max(stage.size.height - top - 20, 0)
        context.fill(Path(CGRect(x: 0, y: top - 4, width: width, height: 4)), with: .color(WorldOffScenePalette.grassLight), style: crisp)
        context.fill(Path(CGRect(x: 0, y: top, width: width, height: 20)),
                     with: .color(WorldPalette.adaptive(light: WorldBoardingHopArt.tarmac, dark: WorldBoardingHopArt.tarmacDark)), style: crisp)
        context.fill(Path(CGRect(x: 0, y: top + 20, width: width, height: below)), with: .color(WorldOffScenePalette.grass), style: crisp)
        let phase = frame.dashes.truncatingRemainder(dividingBy: 24)
        // Bounded: one dash every 24 pt across at most 2,000 pt.
        for index in 0..<min(Int(width / 24) + 2, 84) {
            let dash = CGRect(x: CGFloat(index) * 24 - phase, y: top + 9, width: 10, height: 2)
            context.fill(Path(dash), with: .color(WorldPalette.rgb(WorldBoardingHopArt.dash)), style: crisp)
        }
    }

    /// Two small clouds high in the sky, drifting back as the plane runs and sinking below it as it climbs.
    private static func clouds(_ frame: WorldBoardingHopFrame, stage: WorldBoardingHopStage, in context: GraphicsContext) {
        let width = stage.size.width, span = width + 60, scale = WorldFlyingClouds.scale
        let places: [(x: CGFloat, y: CGFloat)] = [(width * 0.08, 22), (width * 0.66, 50)]
        // Bounded: two clouds, five rows of sixteen each.
        for place in places {
            let drifted = (place.x - frame.dashes * 0.25).truncatingRemainder(dividingBy: span)
            let x = drifted < -60 ? drifted + span : drifted
            let y = place.y + frame.climb * stage.size.height * 0.55
            for (row, keys) in WorldFlyingClouds.rows.enumerated() {
                for (column, key) in keys.enumerated() where key != "." {
                    let rect = CGRect(x: x + CGFloat(column) * scale, y: y + CGFloat(row) * scale, width: scale, height: scale)
                    context.fill(Path(rect), with: .color(key == "c" ? WorldFlyingPalette.cloudShade : WorldFlyingPalette.cloud), style: crisp)
                }
            }
        }
    }

    /// `runs` at ``WorldBoardingHopTimeline/pixel`` points a pixel, their top-left at `origin`.
    private static func draw(_ runs: [WorldSpriteColourRun], at origin: CGPoint, in context: GraphicsContext) {
        let pixel = WorldBoardingHopTimeline.pixel
        // Bounded: one fill a run, at most one a pixel of a 64 × 160 sprite.
        for run in runs {
            let rect = CGRect(x: origin.x + CGFloat(run.x) * pixel, y: origin.y + CGFloat(run.y) * pixel,
                              width: CGFloat(run.length) * pixel, height: pixel)
            context.fill(Path(rect), with: .color(WorldPalette.rgb(run.colour)), style: crisp)
        }
    }
}
