import FernletUI
import SwiftUI
import WorldMapStore

/// The world map's plate words (World-Exploration-Spec §2): the counts ("4 cities, 3 countries found") at
/// World and Country and at sea; from State in, the place at the view's centre ("Oregon · United States"), or
/// the country alone where the pack names no state there.
nonisolated enum WorldAtlasPlate {
    /// The plate at `level` for the place `place` at the view's centre, with the passport's counts; with any
    /// flights the counts gain a second line, "6 airports · 53 flights" (World-Airports-Spec §8).
    static func text(level: AtlasZoomLevel, place: AtlasPlaceName?, cities: Int, countries: Int,
                     airports: Int = 0, flights: Int = 0) -> String {
        guard level.showsPlaceName, let place else {
            let found = WorldViewCopy.found(cities: cities, countries: countries)
            guard flights > 0 else { return found }
            return found + "\n" + WorldFlightCopy.plate(airports: airports, flights: flights)
        }
        let country = WorldViewNames.country(place.countryCode)
        guard let names = place.regionNames else { return country }
        return WorldViewCopy.place(region: WorldViewNames.pick(names), country: country)
    }
}

/// A framed paper chip as the world map draws them (`kit-explore.css`: cream paper, a 2-pt ink frame, a
/// 2-pt shade under it). The paper stays cream in dark mode, as drawn, so its bark text keeps 11:1.
struct WorldAtlasChip: ViewModifier {
    var cornerRadius: CGFloat = 12
    var lineWidth: CGFloat = 2

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        content
            .foregroundStyle(WorldViewInk.text)
            .background(WorldViewInk.paper, in: shape)
            .overlay(shape.strokeBorder(WorldViewInk.frame, lineWidth: lineWidth))
            .background { shape.fill(WorldViewInk.shade).offset(y: 2) }
    }
}

extension View {
    /// Frames this as one of the world map's paper chips.
    func worldAtlasChip(cornerRadius: CGFloat = 12, lineWidth: CGFloat = 2) -> some View {
        modifier(WorldAtlasChip(cornerRadius: cornerRadius, lineWidth: lineWidth))
    }
}

/// The world map's zoom control on the right (World-Exploration-Spec §2; the mockup's `exzc`): **+**, the
/// level's name and **−** in one framed column; + is dimmed at City and − at World.
///
/// To VoiceOver the level is **one adjustable element** ("Zoom level", valued "City, Oregon, United States"):
/// swipe up or down to change it. + and − stay buttons, named "Zoom in" and "Zoom out", for Voice Control.
struct WorldAtlasZoomControl: View {
    let level: AtlasZoomLevel
    /// The spoken value: the level and the place (``WorldViewCopy/zoomValue(_:)``).
    let spokenValue: String
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            stepButton("+", enabled: level.canZoomIn, label: WorldViewCopy.zoomIn, id: "worldAtlas.zoom.in", action: onZoomIn)
            Text(WorldViewCopy.level(level))
                .font(.custom(FernletFontName.dmSansBold, size: 11.5, relativeTo: .caption2))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 3)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .top) { WorldViewInk.frame.frame(height: 2) }
                .overlay(alignment: .bottom) { WorldViewInk.frame.frame(height: 2) }
                .accessibilityElement()
                .accessibilityLabel(Text(WorldViewCopy.zoomLevel))
                .accessibilityValue(Text(verbatim: spokenValue))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: if level.canZoomIn { onZoomIn() }
                    case .decrement: if level.canZoomOut { onZoomOut() }
                    @unknown default: break
                    }
                }
                .accessibilityIdentifier("worldAtlas.zoom.level")
            stepButton("−", enabled: level.canZoomOut, label: WorldViewCopy.zoomOut, id: "worldAtlas.zoom.out",
                       action: onZoomOut)
        }
        .frame(minWidth: 50)
        .fixedSize()
        .worldAtlasChip(cornerRadius: 12)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// A + or − button, 50 × 44 pt at least, dimmed and disabled at the ladder's end.
    private func stepButton(_ glyph: String, enabled: Bool, label: LocalizedStringResource, id: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: glyph)
                .font(.custom(FernletFontName.dmSansBold, size: 24, relativeTo: .title2))
                .foregroundStyle(enabled ? WorldViewInk.text : WorldViewInk.dimmed)
                .frame(minWidth: 50, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(Text(label))
        .accessibilityInputLabels([Text(label)])
        .accessibilityIdentifier(id)
    }
}
