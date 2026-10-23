import SwiftUI
import WorldMapStore

/// The live map, back to front: the base map behind the seam, Fernlet's ground layer (fog and lines),
/// the time-of-day wash, then whatever the caller lays on top (the companion and pins, in later steps).
/// Full-bleed under the status bar and item bar.
///
/// The map is decoration to VoiceOver (design page, "It still reads as a list"): only what the caller
/// adds on top can be an element. The fog and wash never cover the base map's own credit
/// (``WorldMapCreditClearance``).
struct WorldMapStack<Overlay: View>: View {
    let kind: BaseMapKind
    @Binding var camera: WorldCamera
    let ground: WorldGround
    let phase: CompanionDayPhase
    /// How far up from the bottom the base map keeps its own credit (above the item bar).
    let creditInset: CGFloat
    /// Drawn over the map in the same coordinate space; receives the current viewport.
    @ViewBuilder let overlay: (MapViewport, CGSize) -> Overlay
    @State private var viewport: MapViewport?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                BaseMapLayer(kind: kind, camera: $camera, darkStyle: phase.isDarkMap, bottomInset: creditInset) { reported in
                    guard reported.isUsable else { return }
                    viewport = reported
                }
                .accessibilityHidden(true)
                if let viewport {
                    Group {
                        WorldGroundLayer(viewport: viewport, ground: ground, darkStyle: phase.isDarkMap)
                        WorldSkyWash(phase: phase)
                    }
                    .mask { WorldMapCreditClearance(bottomInset: creditInset, active: kind == .appleMuted) }
                    overlay(viewport, proxy.size)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// A mask with one small hole over the base map's own credit, so Fernlet's fog and wash never cover
/// Apple's "Maps" logo and "Legal" link (MapKit terms: they stay visible). The hole sits just above the
/// item bar, where the bottom inset puts the credit. With no credit to keep clear, it masks nothing.
struct WorldMapCreditClearance: View {
    let bottomInset: CGFloat
    let active: Bool

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.addRect(CGRect(origin: .zero, size: proxy.size))
                if active {
                    path.addRoundedRect(in: CGRect(x: 4, y: proxy.size.height - bottomInset - 34, width: 150, height: 36),
                                        cornerSize: CGSize(width: 8, height: 8))
                }
            }
            .fill(style: FillStyle(eoFill: true))
        }
    }
}
