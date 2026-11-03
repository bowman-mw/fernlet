import FernletUI
import SwiftUI
import WorldMapStore

/// The world map's city markers (World-Exploration-Spec §2, the mockup's `exwm` and `cityMarker`), kept off the
/// ground the person found (owner, 2026-11-02): an open gold square on the city, so the hex under it still shows, and
/// a label beside the found ground (``WorldViewLabelPlacement``), tied to the square by a short line when it stands
/// away. Farther out (World, Country) the label is the name on a plate; from State in the city's framed skyline with
/// its name plate under it. A shared marker is named for its biggest city with "+N". Only the markers on screen are
/// drawn.
///
/// Each label is a button: its city's name ("Seattle and 2 more cities" for a shared one), with a hint that it zooms
/// in, or at City that it opens the city. A tap on the square does the same (``WorldAtlasMapView``).
struct WorldAtlasMarkers: View {
    let camera: WorldViewCamera
    let clusters: [WorldViewCluster]
    /// Where the labels stand, by anchor token; a marker with none takes the fallback spot.
    let spots: [String: WorldViewLabelSpot]
    let onTap: (WorldViewCluster) -> Void

    /// How far off screen a marker may stand and still be drawn (its plate reaches in).
    private static let margin: CGFloat = 200

    var body: some View {
        let items = onScreen
        ZStack(alignment: .topLeading) {
            WorldAtlasMarkerPins(items: items)
                .frame(width: camera.size.width, height: camera.size.height)
            ForEach(items) { item in
                marker(item.cluster).worldMapPinned(at: item.label, item.side.alignment)
            }
        }
        .frame(width: camera.size.width, height: camera.size.height, alignment: .topLeading)
    }

    /// Whether this level draws skylines (from State in).
    private var skylines: Bool { camera.level >= .state }

    /// The markers whose city is on screen (within ``margin``), with where. A label's offset grows with the zoom,
    /// so it keeps to the same ground while the found hexes under it grow.
    private var onScreen: [WorldAtlasMarkerItem] {
        let bounds = CGRect(origin: .zero, size: camera.size).insetBy(dx: -Self.margin, dy: -Self.margin)
        let grown = camera.scale / camera.detail.pointsPerMercatorUnit
        let fallback = WorldViewLabelSpot.fallback(skyline: skylines)
        // Bounded: the level's markers (at most WorldViewCluster.maxPins).
        return clusters.compactMap { cluster in
            let point = camera.screenPoint(x: cluster.anchor.x, y: cluster.anchor.y)
            guard bounds.contains(point) else { return nil }
            let spot = spots[cluster.anchor.token] ?? fallback
            return WorldAtlasMarkerItem(cluster: cluster, city: point, side: spot.side,
                                        label: CGPoint(x: point.x + spot.dx * grown, y: point.y + spot.dy * grown))
        }
    }

    /// One marker's label, as a button.
    private func marker(_ cluster: WorldViewCluster) -> some View {
        let name = cluster.others > 0
            ? WorldViewCopy.clusterPlate(name: cluster.anchor.name, others: cluster.others) : cluster.anchor.name
        let spoken = cluster.others > 0
            ? WorldViewCopy.clusterSpoken(name: cluster.anchor.name, others: cluster.others) : cluster.anchor.name
        return Button { onTap(cluster) } label: {
            if skylines {
                VStack(spacing: 2) {
                    WorldCitySkyline(sizeClass: cluster.anchor.sizeClass)
                        .padding(EdgeInsets(top: 3, leading: 4, bottom: 2, trailing: 4))
                        .worldAtlasChip(cornerRadius: 6)
                    plate(name)
                }
            } else {
                plate(name)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: spoken))
        .accessibilityHint(Text(camera.level.canZoomIn ? WorldViewCopy.zoomsIn : WorldViewCopy.opensCity))
        .accessibilityInputLabels([Text(verbatim: cluster.anchor.name)])
        .accessibilityIdentifier("worldAtlas.city.\(cluster.anchor.token)")
    }

    /// A name plate (DM Sans Bold 12 on paper, a 2-pt frame).
    private func plate(_ name: String) -> some View {
        Text(verbatim: name)
            .font(.custom(FernletFontName.dmSansBold, size: 12, relativeTo: .caption))
            .lineLimit(1)
            .fixedSize()
            // Map art: it grows with Larger Text up to xxxLarge, then stays, so markers don't bury the map.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .worldAtlasChip(cornerRadius: 5)
    }
}

/// The state and province names at City (`ex-world-zoom`, approved): small framed labels in letter-spaced capitals,
/// each at the middle of its state's hexes on screen, showing through the fog. Read from the hexes' looked-up places,
/// so a state is named once its hexes are known. Closer in they go: the screen is one state, which the plate names,
/// and the label would sit on the found ground.
struct WorldAtlasStateLabels: View {
    let camera: WorldViewCamera
    let model: WorldViewModel
    /// Read so the labels follow newly looked-up places.
    let generation: Int
    /// The host's chips, which the labels keep clear of.
    let insets: EdgeInsets

    /// The most labels drawn at once.
    static let maxLabels = 8
    /// The fewest of a state's hexes on screen that earn it a label.
    static let minHexes = 12
    /// The closest zoom that draws them.
    static let maxZoom = 3.5

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(labels) { label in
                Text(verbatim: label.cluster)
                    .font(.custom(FernletFontName.dmSansBold, size: 12, relativeTo: .caption))
                    .tracking(12 * 0.14)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .worldAtlasChip(cornerRadius: 4)
                    .worldMapPinned(at: label.point, .center)
            }
        }
        .frame(width: camera.size.width, height: camera.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Each named state on screen and the middle of its hexes there, the most hexes first.
    private var labels: [WorldAtlasPlaced<String>] {
        guard camera.level == .city, camera.zoom <= Self.maxZoom else { return [] }
        let detail = camera.detail
        let safe = CGRect(x: 24, y: insets.top + 40, width: camera.size.width - 48,
                          height: camera.size.height - insets.top - 100)
        var sums: [String: (name: String, x: Double, y: Double, count: Int)] = [:]
        // Bounded: the hexes on screen (WorldViewCamera.maxVisibleHexes).
        for hex in camera.visibleHexes(margin: 0) {
            guard let known = model.place(of: hex.cell, at: detail), let place = known,
                  let token = place.regionToken, let names = place.regionNames else { continue }
            let point = camera.screenPoint(x: hex.x, y: hex.y)
            guard safe.contains(point) else { continue }
            let sum = sums[token] ?? (name: WorldViewNames.pick(names), x: 0, y: 0, count: 0)
            sums[token] = (name: sum.name, x: sum.x + Double(point.x), y: sum.y + Double(point.y), count: sum.count + 1)
        }
        return sums.filter { $0.value.count >= Self.minHexes }
            .sorted { $0.value.count > $1.value.count }
            .prefix(Self.maxLabels)
            .map { entry in
                let sum = entry.value
                return WorldAtlasPlaced(id: entry.key, cluster: sum.name,
                                        point: CGPoint(x: sum.x / Double(sum.count), y: sum.y / Double(sum.count)))
            }
    }
}

/// One city marker on screen: its cluster, where the city is, and where its label touches.
struct WorldAtlasMarkerItem: Identifiable {
    /// The cluster.
    let cluster: WorldViewCluster
    /// The city, on screen.
    let city: CGPoint
    /// Which way the label hangs from `label`.
    let side: WorldViewLabelSpot.Side
    /// The point the label touches, on screen.
    let label: CGPoint

    /// The anchor city's token.
    var id: String { cluster.anchor.token }
}

/// The open gold squares on the cities and the lines from them to their labels, in one drawing that takes no touch
/// and is decoration to VoiceOver (each label carries its city).
struct WorldAtlasMarkerPins: View {
    let items: [WorldAtlasMarkerItem]

    /// A square's side: a little more than a hex, so the hex shows inside it.
    static let square: CGFloat = 13
    /// How far a label stands before a line ties it to its city.
    static let lineFrom: CGFloat = 12

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            var lines = Path(), squares = Path()
            // Bounded: the markers on screen.
            for item in items {
                let rect = CGRect(x: item.city.x - Self.square / 2, y: item.city.y - Self.square / 2,
                                  width: Self.square, height: Self.square)
                squares.addRoundedRect(in: rect, cornerSize: CGSize(width: 3, height: 3))
                let dx = item.label.x - item.city.x, dy = item.label.y - item.city.y, length = hypot(dx, dy)
                guard length > Self.lineFrom else { continue }
                // From the square's edge, so the hex inside it stays clear.
                let edge = Self.square / 2 / max(abs(dx), abs(dy))
                lines.move(to: CGPoint(x: item.city.x + dx * edge, y: item.city.y + dy * edge))
                lines.addLine(to: item.label)
            }
            context.stroke(lines, with: .color(WorldViewInk.paper), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            context.stroke(lines, with: .color(WorldViewInk.frame), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            context.stroke(squares, with: .color(WorldViewInk.frame), lineWidth: 4)
            context.stroke(squares, with: .color(WorldViewInk.markerGold), lineWidth: 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension WorldViewLabelSpot.Side {
    /// The guide of the label that touches its point on this side.
    var alignment: Alignment {
        switch self {
        case .right: .leading
        case .upRight: .bottomLeading
        case .up: .bottom
        case .upLeft: .bottomTrailing
        case .left: .trailing
        case .downLeft: .topTrailing
        case .down: .top
        case .downRight: .topLeading
        }
    }
}

/// Something the world map draws at a screen point: an airport mark, an arc's VoiceOver button or a state label.
struct WorldAtlasPlaced<Item>: Identifiable {
    /// A stable ID (the city's or the state's token).
    let id: String
    /// What is drawn.
    let cluster: Item
    /// Where, on screen.
    let point: CGPoint
}
