import SwiftUI

/// The live map, back to front: the base map behind the seam, Fernlet's fog and trails, the
/// time-of-day wash, then the pins and the companion. Full-bleed under the status and item bars.
///
/// The map is decoration to VoiceOver (design page, "It still reads as a list"): only the
/// companion and the pins are elements.
struct WorldMapStack: View {
    @Bindable var model: WorldShellModel
    let phase: SkyPhase
    /// How far up from the bottom the base map must keep its own credit (above the item bar).
    let creditInset: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                BaseMapLayer(kind: model.baseMap, camera: $model.camera, darkStyle: phase.isDark,
                             bottomInset: creditInset) { model.report($0) }
                    .accessibilityHidden(true)
                if let viewport = model.viewport {
                    FogAndTrailsCanvas(viewport: viewport, lifted: model.lifted, trails: model.visibleTrails,
                                       traces: model.visibleTraces, darkStyle: phase.isDark)
                        .mask { CreditClearance(bottomInset: creditInset) }
                    SkyWash(phase: phase)
                        .mask { CreditClearance(bottomInset: creditInset) }
                    MapPinsLayer(model: model, viewport: viewport, size: proxy.size)
                }
                if model.baseMap == .plain {
                    Text(PlainBaseMap().creditText ?? "")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FernColors.speechInk)
                        .padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                        .background(FernColors.gameCream, in: RoundedRectangle(cornerRadius: 4))
                        .padding(.leading, 12)
                        .padding(.bottom, creditInset + 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// A mask with one small hole over the base map's own credit, so Fernlet's fog and the
/// time-of-day wash never cover Apple's "Maps" logo and "Legal" link (MapKit terms: they stay
/// visible). The hole sits just above the item bar, where the bottom inset puts the credit.
private struct CreditClearance: View {
    let bottomInset: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.addRect(CGRect(origin: .zero, size: proxy.size))
                path.addRoundedRect(in: CGRect(x: 4, y: proxy.size.height - bottomInset - 34, width: 150, height: 36),
                                    cornerSize: CGSize(width: 8, height: 8))
            }
            .fill(style: FillStyle(eoFill: true))
        }
    }
}
