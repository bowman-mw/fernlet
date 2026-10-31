import FernletUI
import SwiftUI
import WorldMapStore

/// The airports on Your world (World-Airports-Spec §8): each found airport a small ink dot with its code on a
/// paper plate (the tower sprite comes in a later round), and each airport only flown through a 9-pt ring
/// (`.apring`), named only past World or once tapped. A ring is decoration to VoiceOver until it is named; only
/// the marks on screen are drawn, and none takes a touch (the map's tap names a ring).
struct WorldFlightMarks: View {
    let camera: WorldViewCamera
    let flights: WorldFlightMap
    /// The ring tapped to show its code.
    let namedRing: String?

    /// The most marks of each kind drawn at once.
    static let maxOnScreen = 400
    /// The ring's diameter.
    private static let ring: CGFloat = 9
    /// The found dot's diameter.
    private static let dot: CGFloat = 11

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        ZStack(alignment: .topLeading) {
            ForEach(onScreen(flights.rings)) { item in
                let named = camera.level > .world || item.id == namedRing
                mark(item, size: Self.ring, named: named) {
                    Circle().fill(WorldPalette.rgb(WorldFlightInk.edge(dark: dark)))
                        .overlay(Circle().strokeBorder(WorldPalette.rgb(WorldFlightInk.line(dark: dark)), lineWidth: 2.5))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: WorldFlightCopy.ringSpoken(item.cluster)))
                .accessibilityHidden(!named)
            }
            ForEach(onScreen(flights.found)) { item in
                mark(item, size: Self.dot, named: true) {
                    Circle().fill(WorldViewInk.frame).overlay(Circle().strokeBorder(WorldViewInk.paper, lineWidth: 2))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: WorldFlightCopy.foundSpoken(item.cluster)))
            }
        }
        .frame(width: camera.size.width, height: camera.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// One mark standing on its airport: the shape, and its code beside it when `named`.
    private func mark(_ item: WorldAtlasPlaced<WorldFlightAirportMark>, size: CGFloat, named: Bool,
                      @ViewBuilder shape: () -> some View) -> some View {
        HStack(spacing: 3) {
            shape().frame(width: size, height: size)
            if named {
                Text(verbatim: item.cluster.code)
                    .font(.custom(FernletFontName.dmSansBold, size: 12, relativeTo: .caption))
                    .lineLimit(1)
                    .fixedSize()
                    // Map art: it grows with Larger Text up to xxxLarge, then stays, so marks don't bury the map.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .worldAtlasChip(cornerRadius: 5)
            }
        }
        .alignmentGuide(.leading) { _ in size / 2 }
        .alignmentGuide(.top) { d in d[VerticalAlignment.center] }
        .offset(x: item.point.x, y: item.point.y)
    }

    /// The marks on screen, with where, at most ``maxOnScreen``.
    private func onScreen(_ marks: [WorldFlightAirportMark]) -> [WorldAtlasPlaced<WorldFlightAirportMark>] {
        let bounds = CGRect(origin: .zero, size: camera.size).insetBy(dx: -40, dy: -20)
        // Bounded: the marks (WorldFlightArcs.maxMarks), at most maxOnScreen kept.
        let placed = marks.lazy.map { mark in
            WorldAtlasPlaced(id: mark.code, cluster: mark,
                             point: camera.screenPoint(x: Double(mark.mercator.x), y: Double(mark.mercator.y)))
        }
        return Array(placed.filter { bounds.contains($0.point) }.prefix(Self.maxOnScreen))
    }
}

/// A tapped arc's card (spec §8; the mockup's `.aparccard`): the two codes with a small plane between, then
/// "Portland – Mexico City · 2 flights · 3,620 km", on a framed cream card with ✕ top right. VoiceOver hears the
/// line when it opens (the codes are decoration there: the line names the cities).
struct WorldFlightCard: View {
    let arc: WorldFlightArc
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(verbatim: arc.from)
                WorldSpriteView(sprite: WorldSprites.plane, scale: 2, tint: WorldViewInk.text)
                Text(verbatim: arc.to)
            }
            .font(.custom(FernletFontName.dmSansBold, size: 18, relativeTo: .headline))
            .accessibilityHidden(true)
            Text(verbatim: WorldFlightCopy.card(arc))
                .font(.custom(FernletFontName.dmSansMedium, size: 13.5, relativeTo: .footnote))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .padding(.leading, 12)
        .padding(.trailing, 48)
        .overlay(alignment: .topTrailing) { closeButton }
        .worldAtlasChip(cornerRadius: 10, lineWidth: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("worldAtlas.flights.card")
        .onAppear { AccessibilityNotification.Announcement(WorldFlightCopy.card(arc)).post() }
    }

    /// ✕, top right.
    private var closeButton: some View {
        Button(action: onClose) {
            WorldSpriteView(sprite: WorldSprites.xx, scale: 2, tint: WorldViewInk.text)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(WorldCloseButton.label))
        .accessibilityInputLabels([Text(WorldCloseButton.label)])
        .accessibilityIdentifier("worldAtlas.flights.card.close")
    }
}
