import SwiftUI
import FernletDomainModel

/// The companion's pixel sprite (``WorldCompanionPainter``) at the theme's pixel size, breathing at
/// its band's tempo by swapping two frames, so the pixels stay crisp instead of scaling. Reduce
/// Motion holds the first frame, and the clock pauses while the map is covered, as Home's companion
/// pauses its own. The soft ground shadow sits under the feet.
struct WorldCompanionSprite: View {
    let state: CompanionState
    let look: WorldCompanionLook
    var settled = false
    var asleep = false
    /// Whether the map is on screen; off, the breath stops ticking.
    var isActive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.worldTheme) private var theme

    /// The sprite's size at the map's pixel scale (3 pt per pixel: 60 × 66 pt).
    static func size(scale: CGFloat) -> CGSize {
        CGSize(width: CGFloat(WorldCompanionGrid.width) * scale, height: CGFloat(WorldCompanionGrid.height) * scale)
    }

    var body: some View {
        let scale = theme.spriteScale
        TimelineView(.animation(minimumInterval: state.animationTempo, paused: reduceMotion || !isActive)) { timeline in
            let beat = Int(timeline.date.timeIntervalSinceReferenceDate / state.animationTempo)
            let pose = WorldCompanionPose(breathIn: !reduceMotion && isActive && beat % 2 == 1, settled: settled, asleep: asleep)
            WorldCompanionCanvas(grid: WorldCompanionPainter.paint(state: state, look: look, pose: pose), scale: scale)
        }
        .frame(width: Self.size(scale: scale).width, height: Self.size(scale: scale).height)
        .accessibilityHidden(true)
    }
}

/// Draws a ``WorldCompanionGrid`` with hard edges, over the design's soft one-pixel ground shadow.
struct WorldCompanionCanvas: View {
    let grid: WorldCompanionGrid
    let scale: CGFloat

    var body: some View {
        Canvas { context, _ in
            context.fill(Path(CGRect(x: 5 * scale, y: 21 * scale, width: 10 * scale, height: scale)),
                         with: .color(Color(.sRGB, red: 40 / 255, green: 22 / 255, blue: 8 / 255, opacity: 0.28)))
            for y in 0..<WorldCompanionGrid.height {
                for x in 0..<WorldCompanionGrid.width {
                    guard let hex = grid.color(x: x, y: y) else { continue }
                    context.fill(Path(CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale)),
                                 with: .color(WorldPalette.rgb(hex)))
                }
            }
        }
    }
}
