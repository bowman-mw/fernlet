import FernletUI
import SwiftUI
import WorldMapStore

/// Home's airports over the fog (World-Airports-Spec §2.3, §3, §5; the mockup's `tower()`, `fence()` and
/// `airportMap`), placed from the viewport each frame like the landmarks (``WorldExploreLayer``):
///
/// - **The tower** at each airport's point near the view: grey through the fog with no name before it's found,
///   full colour on a cream halo with its gold-rimmed plate "PDX · Portland" after. Found means the passport holds
///   its token (`visits(of: .airport)`). A plate Sprout would cover moves below Sprout's feet
///   (``WorldLandmarkPlateRule``).
/// - **The dotted fence** round a found airport with our own approved outline, only while the outline spans more
///   than a third of the screen (``WorldAirportSelection/fenceShows(bounds:screen:)``).
/// - **The planes** at a found airport at street zooms (``WorldAirportPlanes``): jets parked at the gates and, about
///   every two minutes, one taking off along the runway; parked only with Reduce Motion.
///
/// The fence and the planes are decoration, hidden from VoiceOver. The tower is one element: "Airport, not found
/// yet", or "Portland International, PDX, airport, found" (a button once the boarding pass is attached:
/// ``onOpenPass``, the pass lane's seam). Nothing in a decoy.
struct WorldAirportLayer: View {
    let store: FernletStore
    let viewport: MapViewport
    let size: CGSize
    /// Where Sprout's feet stand on the screen (a found plate it would cover moves below them).
    var companion: CGPoint? = nil
    /// Opens Sprout's boarding pass for a found airport's tower (§5, `ap-pass`; the pass lane attaches it). Nil
    /// leaves found towers as images.
    var onOpenPass: ((WorldAirport) -> Void)? = nil
    @State private var memo = WorldAirportMemo()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !store.duressSessionActive, let pack = store.worldLocation.flights.airportsShelf.pack() {
            let placed = placedAirports(pack: pack)
            let street = WorldAirportSelection.isStreetZoom(viewport)
            ZStack(alignment: .topLeading) {
                ForEach(placed) { airport in
                    if let fence = airport.fence { WorldAirportFence(points: fence, dark: colorScheme == .dark, size: size) }
                }
                if street {
                    ForEach(placed.filter(\.found)) { airport in
                        WorldAirportPlanes(token: airport.id, tower: airport.point, runway: airport.runway,
                                           dark: colorScheme == .dark)
                    }
                }
                ForEach(placed.filter(\.isOnScreen)) { airport in tower(airport) }
            }
        }
    }

    /// One airport's tower with its plate, its foot on the airport's point (and its plate below Sprout's feet when
    /// Sprout would cover it).
    @ViewBuilder
    private func tower(_ airport: WorldPlacedAirport) -> some View {
        let aside = airport.found
            && companion.map { WorldLandmarkPlateRule.sproutCovers(plate: airport.plate, at: airport.point, feet: $0) } == true
        WorldAirportTowerView(placed: airport, showsPlate: !aside, onOpen: onOpenPass.map { open in { open(airport.airport) } })
            .fixedSize()
            .frame(width: 0, height: 0, alignment: .bottom)
            .position(airport.point)
        if aside, let feet = companion {
            WorldGoldPlate(text: airport.plate)
                .fixedSize()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .position(WorldLandmarkPlateRule.belowFeet(feet, landmark: airport.point, size: size))
        }
    }

    /// The airports near the view, placed on the screen, north first so a southern tower overlaps a northern.
    private func placedAirports(pack: WorldAirports) -> [WorldPlacedAirport] {
        let found = WorldAirportFound.tokens(store)
        return memo.airports(in: pack, near: viewport, size: size).map { airport in
            let point = viewport.screenPoint(for: airport.point, in: size)
            let isFound = found.contains(airport.token)
            let ends = memo.runway(of: airport)
            return WorldPlacedAirport(
                airport: airport, point: point, found: isFound,
                isOnScreen: WorldExploreSelection.isOnScreen(point, size: size),
                fence: isFound ? fence(of: airport) : nil,
                runway: (viewport.screenPoint(for: ends.0, in: size), viewport.screenPoint(for: ends.1, in: size)),
                plate: WorldAirportCopy.plate(airport))
        }
        .sorted { ($0.point.y, $0.id) < ($1.point.y, $1.id) }
    }

    /// The found airport's fence on the screen, when it has our outline and it spans enough of the screen.
    private func fence(of airport: WorldAirport) -> [CGPoint]? {
        guard let ring = WorldAirportSelection.fenceOutline(of: airport) else { return nil }
        let points = ring.prefix(WorldAirports.maxRingPoints).map { viewport.screenPoint(for: $0, in: size) }
        return WorldAirportSelection.fenceShows(bounds: WorldAirportSelection.bounds(of: points), screen: size) ? points : nil
    }
}

/// Which airports count as found on Home: the passport's airport visits (an empty passport in a decoy, the DEBUG
/// demo passport when a screenshot asks), plus, under a DEBUG airport scene, the scene's airport (display only).
enum WorldAirportFound {
    /// The found airports' tokens.
    @MainActor
    static func tokens(_ store: FernletStore) -> Set<String> {
        guard !store.duressSessionActive else { return [] }
        var found = Set(WorldExploreState.book(store).visits(of: .airport).keys)
        if UITestSupport.airportHomeScene != nil {
            let flights = store.worldLocation.flights
            if let token = flights.currentAirport ?? flights.layoverAirport { found.insert(token) }
        }
        return found
    }
}

/// One airport placed on the screen.
struct WorldPlacedAirport: Identifiable {
    let airport: WorldAirport
    /// Its point on the screen (the tower's foot).
    let point: CGPoint
    let found: Bool
    /// Whether its tower is near enough the screen to draw.
    let isOnScreen: Bool
    /// Its fence's points on the screen, when the fence shows.
    let fence: [CGPoint]?
    /// Its runway's two ends on the screen.
    let runway: (CGPoint, CGPoint)
    /// "PDX · Portland".
    let plate: String
    var id: String { airport.token }
}

/// An airport's tower on the map (the mockup's `tower()`, `.exbig`): the 13 × 17 sprite at 3× with its one-pixel
/// halo and a small drop shadow; found, its plate under it. Found it is one element ("Portland International, PDX,
/// airport, found"), a button when ``onOpen`` is given; not found, "Airport, not found yet", letting pans through.
struct WorldAirportTowerView: View {
    let placed: WorldPlacedAirport
    /// Whether the found plate sits under the art (false: the layer draws it below Sprout's feet).
    var showsPlate = true
    /// Opens the boarding pass; nil leaves the found tower an image.
    let onOpen: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if placed.found, let onOpen {
            Button(action: onOpen) { content }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: WorldAirportCopy.spokenTower(placed.airport)))
                .accessibilityInputLabels([Text(verbatim: placed.airport.code), Text(verbatim: WorldAirportCopy.name(placed.airport))])
                .accessibilityIdentifier("world.airport.found")
        } else {
            content
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(placed.found ? Text(verbatim: WorldAirportCopy.spokenTower(placed.airport)) : Text(WorldAirportCopy.notFound))
                .accessibilityAddTraits(.isImage)
                .accessibilityIdentifier(placed.found ? "world.airport.found" : "world.airport.notFound")
        }
    }

    private var content: some View {
        VStack(spacing: 3) {
            WorldSpriteView(sprite: WorldAirportSprites.tower(found: placed.found, dark: colorScheme == .dark), scale: 3)
                .shadow(color: WorldPalette.rgb(0x281408).opacity(0.3), radius: 0, x: 0, y: 2)
            if placed.found { WorldGoldPlate(text: placed.plate).opacity(showsPlate ? 1 : 0) }
        }
    }
}

/// A found airport's outline as a dotted fence (§2.3, the mockup's `fence()`): a light edge (#FFF6E2, dark #1D2228)
/// 7 pt wide with round joins at 80 % under an ink line (#4A2E1C, dark #F3E6C8) 3 pt wide, dashed 5 5. It reads on
/// grass, streets and fog. Decoration, hidden from VoiceOver.
struct WorldAirportFence: View {
    /// The outline's points on the screen.
    let points: [CGPoint]
    let dark: Bool
    let size: CGSize

    var body: some View {
        Canvas { context, _ in
            var path = Path()
            path.addLines(points)
            path.closeSubpath()
            context.stroke(path, with: .color(WorldPalette.rgb(dark ? 0x1D2228 : 0xFFF6E2).opacity(0.8)),
                           style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(WorldPalette.rgb(dark ? 0xF3E6C8 : 0x4A2E1C)),
                           style: StrokeStyle(lineWidth: 3, lineJoin: .round, dash: [5, 5]))
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
