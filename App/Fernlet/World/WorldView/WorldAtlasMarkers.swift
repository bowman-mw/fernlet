import FernletUI
import SwiftUI
import WorldMapStore

/// The world map's city markers (World-Exploration-Spec §2, the mockup's `exwm` and `cityMarker`): farther
/// out (World, Country) a gold square with the name on a plate beside it, the square on the city; from State
/// in the city's framed skyline with its name plate under it, standing on the city. A shared marker is named
/// for its biggest city with "+N". Only the markers on screen are drawn.
///
/// Each marker is a button: its city's name ("Seattle and 2 more cities" for a shared one), with a hint that
/// it zooms in, or at City that it opens the city.
struct WorldAtlasMarkers: View {
    let camera: WorldViewCamera
    let clusters: [WorldViewCluster]
    let onTap: (WorldViewCluster) -> Void

    /// How far off screen a marker may stand and still be drawn (its plate reaches in).
    private static let margin: CGFloat = 140

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(onScreen) { item in
                marker(item.cluster)
                    .alignmentGuide(.leading) { d in skylines ? d.width / 2 : Self.squareHalf }
                    .alignmentGuide(.top) { d in skylines ? d.height : d[VerticalAlignment.center] }
                    .offset(x: item.point.x, y: item.point.y - (skylines ? 4 : 0))
            }
        }
        .frame(width: camera.size.width, height: camera.size.height, alignment: .topLeading)
    }

    /// Half the far marker's square: the square's centre stands on the city.
    private static let squareHalf: CGFloat = 6

    /// Whether this level draws skylines (from State in).
    private var skylines: Bool { camera.level >= .state }

    /// The markers whose city is on screen (within ``margin``), with where.
    private var onScreen: [WorldAtlasPlaced<WorldViewCluster>] {
        let bounds = CGRect(origin: .zero, size: camera.size).insetBy(dx: -Self.margin, dy: -Self.margin)
        // Bounded: the level's markers (at most WorldViewCluster.maxPins).
        return clusters.compactMap { cluster in
            let point = camera.screenPoint(x: cluster.anchor.x, y: cluster.anchor.y)
            return bounds.contains(point) ? WorldAtlasPlaced(id: cluster.anchor.token, cluster: cluster, point: point) : nil
        }
    }

    /// One marker, as a button.
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
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(WorldViewInk.markerGold)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(WorldViewInk.frame, lineWidth: 2))
                        .frame(width: Self.squareHalf * 2, height: Self.squareHalf * 2)
                    plate(name)
                }
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

/// The state and province names at the closest zoom (`ex-world-zoom`, approved): small framed labels in
/// letter-spaced capitals, each at the middle of its state's hexes on screen, showing through the fog. Read
/// from the hexes' looked-up places, so a state is named once its hexes are known.
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
                    .alignmentGuide(.leading) { d in d.width / 2 }
                    .alignmentGuide(.top) { d in d.height / 2 }
                    .offset(x: label.point.x, y: label.point.y)
            }
        }
        .frame(width: camera.size.width, height: camera.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Each named state on screen and the middle of its hexes there, the most hexes first.
    private var labels: [WorldAtlasPlaced<String>] {
        guard camera.level == .city else { return [] }
        let safe = CGRect(x: 24, y: insets.top + 40, width: camera.size.width - 48,
                          height: camera.size.height - insets.top - 100)
        var sums: [String: (name: String, x: Double, y: Double, count: Int)] = [:]
        // Bounded: the hexes on screen (WorldViewCamera.maxVisibleHexes).
        for hex in camera.visibleHexes(margin: 0) {
            guard let known = model.place(of: hex.cell, at: camera.level), let place = known,
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

/// Something the world map draws at a screen point: a marker's cluster, or a state label's name.
struct WorldAtlasPlaced<Item>: Identifiable {
    /// A stable ID (the city's or the state's token).
    let id: String
    /// What is drawn.
    let cluster: Item
    /// Where, on screen.
    let point: CGPoint
}
