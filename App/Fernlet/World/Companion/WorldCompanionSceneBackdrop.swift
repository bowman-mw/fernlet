import SwiftUI
import FernletDomainModel

/// The pixel scene behind the companion off the map (G8, the owner's picks on 2026-11-15): Customize's
/// previews and the passport's photo. It fills its frame with hard-edged cells of one size, anchored at the
/// bottom centre so the ground stays under the companion's feet; extra width or height is cropped.
///
/// The scene follows the map's day (``WorldSceneLight``) and dims a little in dark mode. Decorative: the
/// slot's page names the scene in words.
struct WorldCompanionSceneBackdrop: View {
    let kind: WorldCompanionSceneKind
    var light = WorldSceneLight.day
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let cells = WorldCompanionScene.paint(kind, light: light, dark: colorScheme == .dark)
        Canvas { context, size in
            guard let cells else { return }
            let width = WorldCompanionScene.width, height = WorldCompanionScene.height
            let cell = max(size.width / CGFloat(width), size.height / CGFloat(height))
            let originX = (size.width - cell * CGFloat(width)) / 2, originY = size.height - cell * CGFloat(height)
            for y in 0..<height {
                for x in 0..<width {
                    // A hair over each cell, so no seam shows between neighbours at fractional sizes.
                    let rect = CGRect(x: originX + CGFloat(x) * cell, y: originY + CGFloat(y) * cell, width: cell + 0.5, height: cell + 0.5)
                    context.fill(Path(rect), with: .color(WorldPalette.rgb(cells[y * width + x])))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

extension WorldSceneLight {
    /// The scene's light for the companion's pose: night while it sleeps, dusk while it winds down.
    init(_ pose: WorldCompanionPose) {
        self = pose.asleep ? .night : (pose.drowsy ? .dusk : .day)
    }
}
