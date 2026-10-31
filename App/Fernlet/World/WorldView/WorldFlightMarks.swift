import FernletUI
import SwiftUI
import WorldMapStore

/// The airports on Your world (World-Airports-Spec §8): each found airport its tower (the mockup's `apTower` at 2×,
/// `worldArcs`' `mark`, ringed in cream so it reads on fog and sea in both modes) standing on the airport with its
/// code on a paper plate beside its foot, and each airport only flown through a 9-pt ring (`.apring`), named only
/// past World or once tapped. A ring is decoration to VoiceOver until it is named; only
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
    /// The tower's points per pixel.
    private static let towerScale: CGFloat = 2

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
                towerMark(item)
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
            if named { codePlate(item.cluster.code) }
        }
        .alignmentGuide(.leading) { _ in size / 2 }
        .alignmentGuide(.top) { d in d[VerticalAlignment.center] }
        .offset(x: item.point.x, y: item.point.y)
    }

    /// A found airport: its tower standing on the airport (its foot on the point), the code's plate beside the foot.
    private func towerMark(_ item: WorldAtlasPlaced<WorldFlightAirportMark>) -> some View {
        let sprite = WorldFlightTower.sprite, width = CGFloat(sprite.width) * Self.towerScale
        return HStack(alignment: .bottom, spacing: 3) {
            WorldSpriteView(sprite: sprite, scale: Self.towerScale)
            codePlate(item.cluster.code)
        }
        .alignmentGuide(.leading) { _ in width / 2 }
        .alignmentGuide(.top) { d in d[VerticalAlignment.bottom] - Self.towerScale }
        .offset(x: item.point.x, y: item.point.y)
    }

    /// The code on a paper plate (DM Sans Bold 12), growing with Larger Text up to xxxLarge.
    private func codePlate(_ code: String) -> some View {
        Text(verbatim: code)
            .font(.custom(FernletFontName.dmSansBold, size: 12, relativeTo: .caption))
            .lineLimit(1)
            .fixedSize()
            // Map art: it grows with Larger Text up to xxxLarge, then stays, so marks don't bury the map.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .worldAtlasChip(cornerRadius: 5)
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

/// A found airport's tower on Your world: the mockup's `K.SPR.apTower` (9 × 8, one ink), with a one-pixel cream
/// halo round it (the mockup's `haloed()`), so the ink tower reads on fog, land and sea by day and by night.
nonisolated enum WorldFlightTower {
    /// The tower's rows, key for key (`k` is ink).
    static let rows = ["..kkkkk..", ".k.....k.", ".kkkkkkk.", "...k.k...", "...k.k...", "...k.k...", "..kk.kk..",
                       ".kkkkkkk."]
    /// The halo's paper (the plates' `#FFF6E2`).
    static let halo: UInt32 = 0xFFF6E2

    /// The haloed tower: ink, and `O` (cream) on every clear pixel touching the ink, one pixel all round.
    static let sprite = WorldSprite(rows: haloed(rows), palette: ["k": WorldSprite.ink, "O": halo])

    /// `rows` padded by one clear pixel all round, every clear pixel next to (or corner to corner with) ink made
    /// `O`. Bounded by the sprite's size.
    static func haloed(_ rows: [String]) -> [String] {
        let width = (rows.first?.count ?? 0) + 2
        let blank = String(repeating: ".", count: width)
        let padded = [blank] + rows.map { "." + $0 + "." } + [blank]
        let grid = padded.map(Array.init)
        return grid.indices.map { y in
            String(grid[y].indices.map { x -> Character in
                guard grid[y][x] == "." else { return grid[y][x] }
                let near = (-1 ... 1).contains { dy in
                    (-1 ... 1).contains { dx in
                        let row = y + dy, col = x + dx
                        return grid.indices.contains(row) && grid[row].indices.contains(col) && grid[row][col] != "."
                    }
                }
                return near ? "O" : "."
            })
        }
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
