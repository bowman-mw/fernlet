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
    /// Whether Dark Mode is on: the map and the fog go dark with it. Night alone keeps the light map
    /// under its tint (``WorldSkyWash``).
    var darkMode = false
    /// How far up from the bottom the base map keeps its own credit (above the item bar).
    let creditInset: CGFloat
    /// Whether the base map's tiles failed (no signal): plain parchment covers it, credit and all, and the
    /// layers draw on that (`b1-home-offline`). The map stays underneath, so it can come back with signal
    /// and pans still reach it.
    var veiled = false
    /// The land under the fog (``WorldTerrain``); nil draws today's nature fog.
    var terrain: WorldTerrain? = nil
    /// Drawn over the map in the same coordinate space; receives the current viewport.
    @ViewBuilder let overlay: (MapViewport, CGSize) -> Overlay
    /// Where the caller reads the last viewport back without redrawing (Home: whether Sprout left the
    /// visible map); nil for none.
    var geometry: WorldMapGeometry? = nil
    @State private var viewport: MapViewport?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                BaseMapLayer(kind: kind, camera: $camera, darkStyle: isDark, bottomInset: creditInset) { reported in
                    guard reported.isUsable else { return }
                    viewport = reported
                    geometry?.viewport = reported
                    geometry?.size = proxy.size
                }
                .accessibilityHidden(true)
                if veiled {
                    (isDark ? WorldPalette.nightPlainGround : WorldPalette.plainGround)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if let viewport {
                    Group {
                        WorldGroundLayer(viewport: viewport, ground: ground, darkStyle: isDark, terrain: terrain)
                        WorldSkyWash(phase: phase, darkMode: isDark)
                    }
                    .mask { WorldMapCreditClearance(bottomInset: creditInset, active: kind == .appleMuted && !veiled) }
                    overlay(viewport, proxy.size)
                }
            }
        }
        .ignoresSafeArea()
    }

    /// Whether the map draws dark: in Dark Mode only (night is a tint, `b1-home-night`).
    private var isDark: Bool { darkMode }
}

/// The map's last viewport and size as the base map reported them, held for reading only: not
/// observed, so writing it on every frame of a move redraws nothing (``WorldMapStack/geometry``).
@MainActor
final class WorldMapGeometry {
    /// The last usable viewport, nil before the first.
    var viewport: MapViewport?
    /// The map's size when it was reported.
    var size: CGSize = .zero

    /// Whether `point` falls on the visible map now; false before the first viewport.
    func shows(_ point: GeoPoint) -> Bool {
        guard let viewport, viewport.isUsable, size.width > 0, size.height > 0 else { return false }
        return CGRect(origin: .zero, size: size).contains(viewport.screenPoint(for: point, in: size))
    }
}

/// A mask with one small hole over the base map's own credit, so Fernlet's fog and wash never cover
/// Apple's "Maps" logo and "Legal" link (MapKit terms: they stay visible). The hole sits just above the
/// item bar, where the bottom inset puts the credit, a little larger than the credit and feathered, so
/// the fog thins around it instead of stopping at a hard box. With no credit to keep clear, it masks
/// nothing.
struct WorldMapCreditClearance: View {
    let bottomInset: CGFloat
    let active: Bool

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                // Past the edges, so the feathering never thins the fog along the screen's sides.
                path.addRect(CGRect(origin: .zero, size: proxy.size).insetBy(dx: -12, dy: -12))
                if active {
                    // The map ignores the safe area, so the inset alone places the credit: its
                    // bottom edge sits on the inset, inside MapKit's own small margin.
                    path.addRoundedRect(in: CGRect(x: 2, y: proxy.size.height - bottomInset - 40, width: 128, height: 44),
                                        cornerSize: CGSize(width: 10, height: 10))
                }
            }
            .fill(style: FillStyle(eoFill: true))
            .blur(radius: active ? 3 : 0)
        }
    }
}
