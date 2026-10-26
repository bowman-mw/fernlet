import SwiftUI

/// The companion on the map: the pixel sprite at the shell's pixel size (3 pt per pixel, 60 × 66 pt,
/// on iPhone 17), breathing at its state's tempo.
///
/// Breathing swaps between two frames every `breathTempo` seconds, so the pixels stay crisp
/// instead of scaling (Reduce Motion holds the first frame, as `CompanionView` pauses its clock).
/// While walking or riding, the caller supplies the step and the frame follows it instead.
struct PixelCompanionView: View {
    let state: ShellCompanionState
    let ride: CompanionRide
    let outfit: Outfit
    var walking = false
    var step = 0
    var settled = false
    var facingLeft = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shellMetrics) private var metrics

    var body: some View {
        TimelineView(.periodic(from: .now, by: state.breathTempo)) { timeline in
            let beat = Int(timeline.date.timeIntervalSinceReferenceDate / state.breathTempo)
            let pose = CompanionPose(breathIn: !reduceMotion && !walking && beat % 2 == 1,
                                     walking: walking, step: reduceMotion ? 0 : step, settled: settled)
            PixelGridView(grid: PixelCompanionPainter.paint(state: state, ride: ride, outfit: outfit, pose: pose), scale: metrics.pixel)
                .scaleEffect(x: facingLeft ? -1 : 1, y: 1)
        }
        .frame(width: CGFloat(PixelGrid.width) * metrics.pixel, height: CGFloat(PixelGrid.height) * metrics.pixel)
        .accessibilityHidden(true)
    }
}

/// Draws a ``PixelGrid`` with hard edges, plus the soft one-pixel ground shadow under it.
struct PixelGridView: View {
    let grid: PixelGrid
    var scale: CGFloat = 2

    var body: some View {
        Canvas { context, _ in
            context.fill(Path(CGRect(x: 4 * scale, y: 21 * scale, width: 12 * scale, height: scale)),
                         with: .color(Color(.sRGB, red: 0.157, green: 0.086, blue: 0.031, opacity: 0.28)))
            for y in 0..<PixelGrid.height {
                for x in 0..<PixelGrid.width {
                    guard let hex = grid.color(x: x, y: y) else { continue }
                    let rect = CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale)
                    context.fill(Path(rect), with: .color(FernColors.rgb(hex)))
                }
            }
        }
        .frame(width: CGFloat(PixelGrid.width) * scale, height: CGFloat(PixelGrid.height) * scale)
    }
}
