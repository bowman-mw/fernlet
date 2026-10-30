import FernletUI
import SwiftUI
import WorldMapStore

/// The small world map on page 2 of Sprout's passport (World-Passport-Spec §5, `ps-world`; the passport
/// mockup's `worldPreview()`): the whole world, 274 × 112 pt, from the atlas's land in hex fog, what the person
/// found lit up, a yellow marker on each found city, and an "Open the map ›" chip.
///
/// One button to VoiceOver, "Your world map. Opens full screen."; `onOpen` opens ``WorldYourWorldPage``.
struct WorldAtlasPreview: View {
    let source: WorldAtlasMapView.Source
    let onOpen: () -> Void

    @State private var field: WorldPreviewField?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .topLeading) {
                map
                ForEach(0..<(field?.dots.count ?? 0), id: \.self) { index in
                    let dot = field?.dots[index] ?? .zero
                    RoundedRectangle(cornerRadius: 2)
                        .fill(WorldViewInk.markerGold)
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(WorldViewInk.frame, lineWidth: 2))
                        .frame(width: 9, height: 9)
                        .offset(x: dot.x - 4.5, y: dot.y - 4.5)
                }
                openChip
                    .frame(width: WorldPreviewField.width, height: WorldPreviewField.height, alignment: .bottomTrailing)
            }
            .frame(width: WorldPreviewField.width, height: WorldPreviewField.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(WorldViewInk.frame, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(WorldViewCopy.previewSpoken))
        .accessibilityInputLabels([Text(WorldViewCopy.openMap)])
        .accessibilityIdentifier("worldAtlas.preview")
        .task { await build() }
    }

    /// The hexes, in one path per colour.
    private var map: some View {
        let dark = colorScheme == .dark
        let hexes = field?.hexes ?? []
        return Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(WorldPalette.rgb(dark ? 0x25303A : 0xBFD3DF)))
            let corners = WorldPreviewField.cornerOffsets
            var paths: [UInt32: (path: Path, edge: UInt32)] = [:]
            // Bounded: the field's few thousand hexes.
            for hex in hexes {
                let ink = WorldViewInk.hex(land: hex.land, found: hex.found, dark: dark)
                var entry = paths[ink.fill] ?? (path: Path(), edge: ink.edge)
                entry.path.addLines(corners.map { CGPoint(x: hex.x + $0.x, y: hex.y + $0.y) })
                entry.path.closeSubpath()
                paths[ink.fill] = entry
            }
            for (fill, entry) in paths {
                context.fill(entry.path, with: .color(WorldPalette.rgb(fill)))
                context.stroke(entry.path, with: .color(WorldPalette.rgb(entry.edge)), lineWidth: WorldViewInk.hexEdgeWidth)
            }
        }
        .frame(width: WorldPreviewField.width, height: WorldPreviewField.height)
        .accessibilityHidden(true)
    }

    /// "Open the map ›", bottom right.
    private var openChip: some View {
        HStack(spacing: 5) {
            Text(WorldViewCopy.openMap)
                .font(.custom(FernletFontName.dmSansBold, size: 12.5, relativeTo: .caption))
                .fixedSize(horizontal: false, vertical: true)
            WorldSpriteView(sprite: WorldSprites.chevR, scale: 2, tint: WorldViewInk.text)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .worldAtlasChip(cornerRadius: 6)
        .frame(maxWidth: WorldPreviewField.width - 12, alignment: .trailing)
        .padding(6)
        .accessibilityHidden(true)
    }

    /// Builds the field off the main actor, once.
    private func build() async {
        guard field == nil else { return }
        let content: WorldViewContent
        switch source {
        case .store(let store): content = .live(store: store)
        case .content(let fixed): content = fixed
        }
        field = await Task.detached(priority: .userInitiated) {
            WorldPreviewField(atlas: content.atlas, cells: content.liftedCells, pins: content.pins)
        }.value
    }
}

/// The preview's hexes and markers (the passport mockup's `worldPreview`): a flat world, 360° across 274 pt from
/// 168°W, 84°N on the top edge; 2.3-pt hexes, land where the atlas puts land at the centre, lit where a lifted
/// fog cell falls or within 5 pt of a found city; one marker per found city, none within 7 pt of another.
nonisolated struct WorldPreviewField: Sendable {
    /// The preview's width in points.
    static let width: CGFloat = 274
    /// Its height in points.
    static let height: CGFloat = 112
    /// A hex's centre-to-corner radius in points.
    static let radius = 2.3
    /// The longitude on the left edge.
    static let westLongitude = -168.0
    /// The latitude on the top edge.
    static let topLatitude = 84.0
    /// How near a found city a hex lights up, in points.
    static let cityGlow = 5.0
    /// How near two markers may stand, in points.
    static let markerSpacing = 7.0
    /// The most markers drawn.
    static let maxMarkers = 64

    /// One hex: its centre in points and its colours' inputs.
    struct Hex: Sendable {
        let x: Double, y: Double, land: Bool, found: Bool
    }

    /// Every hex.
    let hexes: [Hex]
    /// The markers' centres.
    let dots: [CGPoint]

    /// Points a degree spans.
    static var pointsPerDegree: Double { Double(width) / 360 }
    /// A hex's width, flat side to flat side.
    static var across: Double { radius * 3.0.squareRoot() }

    /// A hex's corners as offsets from its centre (pointy-top).
    static var cornerOffsets: [CGPoint] {
        (0..<6).map { index in
            let angle = (60 * Double(index) + 30) * .pi / 180
            return CGPoint(x: radius * cos(angle), y: radius * sin(angle))
        }
    }

    /// Where `point` is on the preview.
    static func position(of point: GeoPoint) -> CGPoint {
        let east = WorldViewCamera.wrap((point.longitude - westLongitude) / 360) * 360
        return CGPoint(x: east * pointsPerDegree, y: (topLatitude - point.latitude) * pointsPerDegree)
    }

    /// The row and column of the hex nearest `position`.
    static func hexKey(_ position: CGPoint) -> Int {
        let row = Int((Double(position.y) / (1.5 * radius)).rounded())
        let shift = row & 1 == 1 ? across / 2 : 0
        let col = Int(((Double(position.x) - shift) / across).rounded())
        return row * 1_000 + col
    }

    /// The field over `atlas` (nil: all sea) with `cells` lifted and `pins` found. Bounded: the preview's
    /// hexes, at most ``WorldViewHexGrid/maxLiftedCells`` cells, and the pins.
    init(atlas: WorldAtlas?, cells: [HexCell], pins: [WorldViewCityPin]) {
        var lit = Set<Int>()
        for cell in cells.prefix(WorldViewHexGrid.maxLiftedCells) {
            lit.insert(Self.hexKey(Self.position(of: MercatorHexGrid.centreGeo(of: cell))))
        }
        let cities = pins.prefix(WorldViewCluster.maxPins).map { Self.position(of: WebMercator.geo(x: $0.x, y: $0.y)) }
        var hexes: [Hex] = []
        let rows = Int((Double(Self.height) + Self.radius) / (1.5 * Self.radius)) + 1
        let cols = Int((Double(Self.width) + Self.across) / Self.across) + 1
        for row in 0..<rows {
            for col in 0..<cols {
                let x = Double(col) * Self.across + (row & 1 == 1 ? Self.across / 2 : 0), y = Double(row) * 1.5 * Self.radius
                let point = GeoPoint(Self.topLatitude - y / Self.pointsPerDegree, Self.westLongitude + x / Self.pointsPerDegree)
                let near = cities.contains { hypot(Double($0.x) - x, Double($0.y) - y) < Self.cityGlow }
                hexes.append(Hex(x: x, y: y, land: atlas?.isLand(at: WorldPreviewField.wrapped(point)) ?? false,
                                 found: near || lit.contains(row * 1_000 + col)))
            }
        }
        var dots: [CGPoint] = []
        for city in cities where dots.count < Self.maxMarkers {
            guard !dots.contains(where: { hypot(Double($0.x - city.x), Double($0.y - city.y)) < Self.markerSpacing }) else { continue }
            dots.append(city)
        }
        self.hexes = hexes
        self.dots = dots
    }

    /// `point` with its longitude brought into -180...180.
    static func wrapped(_ point: GeoPoint) -> GeoPoint {
        GeoPoint(point.latitude, WorldViewCamera.wrap((point.longitude + 180) / 360) * 360 - 180)
    }
}
