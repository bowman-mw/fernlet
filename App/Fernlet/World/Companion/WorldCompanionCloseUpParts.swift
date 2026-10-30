import FernletScoring
import FernletUI
import SwiftUI
import WorldMapStore

// What remains of the companion's close-up (`ref-comp-close`), retired in round 7 when tapping Sprout began
// opening its passport (World-Passport-Spec §1): the pet's hearts and what "This is home" opens, both used by
// page 1 of the passport (`PassportSproutPage`).

/// The pet's three pixel hearts: they rise and fade, or, with Reduce Motion, fade where they appear.
struct WorldCloseUpHearts: View {
    let count: Int
    /// The passport photo's size (page 1 of Sprout's passport): hearts at two points a pixel, rising half as far.
    var compact = false
    @State private var isGone = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where each heart starts over the companion's head (x, y), and its pixel scale.
    private static let placements: [(x: CGFloat, y: CGFloat, scale: CGFloat)] = [(-36, 6, 3), (34, -6, 3), (0, -18, 4)]
    /// The same at photo size.
    private static let compactPlacements: [(x: CGFloat, y: CGFloat, scale: CGFloat)] = [(-26, 4, 2), (24, -2, 2), (0, -10, 2)]

    var body: some View {
        ZStack {
            let placements = compact ? Self.compactPlacements : Self.placements
            let rise = WorldCloseUpMotion.heartsRise(reduceMotion: reduceMotion) * (compact ? 0.5 : 1)
            ForEach(0..<min(count, placements.count), id: \.self) { index in
                let place = placements[index]
                WorldSpriteView(sprite: WorldSprites.heartSm, scale: place.scale)
                    .offset(x: place.x, y: place.y - (isGone ? rise : 0))
            }
        }
        .opacity(isGone ? 0 : 1)
        .offset(y: compact ? -8 : -30)
        .onAppear {
            withAnimation(.easeOut(duration: WorldCloseUpMotion.heartsDuration)) { isGone = true }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// What the close-up opens once it has gone (round 7).
nonisolated enum WorldCloseUpAfterClose: Equatable {
    case customize
    case thisIsHome(GeoPoint)
    case manage

    /// The Remember this place sheet "This is home" opens: Home picked, the pin at the person's point
    /// (`ref-comp-home-add`). Nil for the others.
    var placeSheet: WorldPlaceSheetMode? {
        guard case .thisIsHome(let point) = self else { return nil }
        return .remember(start: point, kind: .home)
    }
}
