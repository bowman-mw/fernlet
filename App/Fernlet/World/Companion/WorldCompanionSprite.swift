import SwiftUI
import FernletDomainModel

/// The companion's pixel sprite (``WorldCompanionPainter``) at the theme's pixel size, breathing at
/// its band's tempo by swapping two frames, so the pixels stay crisp instead of scaling. Reduce
/// Motion holds the first frame, and the clock pauses while the map is covered, as Home's companion
/// pauses its own. The soft ground shadow sits under the feet; Increase Contrast darkens the outline.
///
/// It lays out at the body's 20 × 22 footprint, so the feet stay where they always stood; the 24 × 24
/// item frame round it (72 × 72 pt on the map) spills past that footprint where a drawn piece reaches
/// (W-07, draft 2).
struct WorldCompanionSprite: View {
    let state: CompanionState
    let look: WorldCompanionLook
    var settled = false
    var asleep = false
    /// Winding down at night: closed eyes in the band's colour (``WorldCompanionPose/drowsy``).
    var drowsy = false
    /// Whether the map is on screen; off, the breath stops ticking.
    var isActive = true
    /// Points per sprite pixel; nil takes the theme's (3). The open scene with location off draws it
    /// larger (`b1-home-denied`, draft 4).
    var pixelScale: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.worldTheme) private var theme

    /// The sprite's layout size: the body's 20 × 22 footprint (3 pt per pixel: 60 × 66 pt).
    static func size(scale: CGFloat) -> CGSize {
        CGSize(width: CGFloat(WorldCompanionGrid.width) * scale, height: CGFloat(WorldCompanionGrid.height) * scale)
    }

    /// The sprite for one picture of the companion (``WorldCompanionNow``).
    init(now: WorldCompanionNow, settled: Bool = false, isActive: Bool = true, pixelScale: CGFloat? = nil) {
        self.init(state: now.state, look: now.look, settled: settled, asleep: now.pose.asleep, drowsy: now.pose.drowsy,
                  isActive: isActive, pixelScale: pixelScale)
    }

    /// The sprite for a fixed state and look (a friend's companion, the location intro).
    init(state: CompanionState, look: WorldCompanionLook, settled: Bool = false, asleep: Bool = false, drowsy: Bool = false,
         isActive: Bool = true, pixelScale: CGFloat? = nil) {
        self.state = state
        self.look = look
        self.settled = settled
        self.asleep = asleep
        self.drowsy = drowsy
        self.isActive = isActive
        self.pixelScale = pixelScale
    }

    var body: some View {
        let scale = pixelScale ?? theme.spriteScale
        TimelineView(.animation(minimumInterval: state.animationTempo, paused: reduceMotion || !isActive)) { timeline in
            let beat = Int(timeline.date.timeIntervalSinceReferenceDate / state.animationTempo)
            let pose = WorldCompanionPose(breathIn: !reduceMotion && isActive && beat % 2 == 1, settled: settled, asleep: asleep,
                                          drowsy: drowsy)
            WorldCompanionCanvas(grid: WorldCompanionPainter.paint(state: state, look: look, pose: pose,
                                                                   increasedContrast: contrast == .increased),
                                 scale: scale)
        }
        .frame(width: Self.size(scale: scale).width, height: Self.size(scale: scale).height)
        .accessibilityHidden(true)
    }
}

/// Draws a ``WorldCompanionGrid``'s whole 24 × 24 item frame with hard edges, over the design's soft
/// one-pixel ground shadow under the feet.
///
/// ``Footprint/body`` lays it out at the body's 20 × 22 footprint with the frame spilling past it
/// evenly (the map, the Today card, anywhere the feet must not move); ``Footprint/frame`` lays out the
/// whole frame (a preview box that must hold every drawn piece).
struct WorldCompanionCanvas: View {
    /// How much room it takes in its layout.
    enum Footprint {
        /// The body's 20 × 22 cells; the frame spills one cell above and below and two each side.
        case body
        /// The whole 24 × 24 frame.
        case frame
    }

    let grid: WorldCompanionGrid
    let scale: CGFloat
    var footprint = Footprint.body

    /// The whole frame's size at `scale` (3 pt per pixel: 72 × 72 pt; up close, 240 × 240 pt).
    static func frameSize(scale: CGFloat) -> CGSize {
        CGSize(width: CGFloat(WorldCompanionGrid.frameWidth) * scale, height: CGFloat(WorldCompanionGrid.frameHeight) * scale)
    }

    var body: some View {
        let frame = Self.frameSize(scale: scale)
        let layout = footprint == .frame ? frame : WorldCompanionSprite.size(scale: scale)
        Canvas { context, _ in
            let originX = CGFloat(WorldCompanionGrid.frameX), originY = CGFloat(WorldCompanionGrid.frameY)
            context.fill(Path(CGRect(x: (originX + 5) * scale, y: (originY + 21) * scale, width: 10 * scale, height: scale)),
                         with: .color(Color(.sRGB, red: 40 / 255, green: 22 / 255, blue: 8 / 255, opacity: 0.28)))
            for y in 0..<WorldCompanionGrid.frameHeight {
                for x in 0..<WorldCompanionGrid.frameWidth {
                    guard let hex = grid.frameColor(x: x, y: y) else { continue }
                    context.fill(Path(CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale)),
                                 with: .color(WorldPalette.rgb(hex)))
                }
            }
        }
        .frame(width: frame.width, height: frame.height)
        .frame(width: layout.width, height: layout.height)
    }
}
