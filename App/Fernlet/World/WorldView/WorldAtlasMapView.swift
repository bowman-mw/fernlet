import FernletUI
import SwiftUI
import WorldMapStore

/// The world map (World-Exploration-Spec §2, "The world view" `ex-world` draft 3 and "The closest zoom"
/// `ex-world-zoom` draft 2), as a reusable component: it fills the space it is given, and its host gives
/// it a frame (round 7: the page around it is held for Sprout's passport redesign).
///
/// - **The map** is drawn from the bundled atlas (``WorldViewMapCanvas``), no MapKit and no network: faint
///   land and sea under the fog, the hexes the person uncovered in full, country lines from Country and state
///   lines from State on the hex edges, the major roads the person crossed in amber on the uncovered hexes from
///   Country in (``WorldRoadStyle``), and no county lines (answer 13).
/// - **Zoom** is free from World to a little past City (owner, 2026-11-02): a pinch follows the fingers and the map
///   stays where they leave it; the framed control on the right (``WorldAtlasZoomControl``) glides to the
///   next stop along World → Country → State → City (``AtlasZoomLevel``) and on in. Hexes step in half levels
///   (``AtlasZoomDetail``). Reduce Motion:
///   the control jumps instead of gliding, and the hexes don't fade.
/// - **Pan** east and west all the way round; north and south clamped, the poles at the edges at World
///   (``WorldViewCamera``). It opens on the person's first home, else their latest fix, else 0°.
/// - **City markers**: an open gold square on the city and the name beside the found ground, the framed skyline
///   and name plate from State in (``WorldAtlasMarkers``); cities closer than 30 pt share one ("Seattle +2").
///   Tapping one zooms to it; at City it calls `onOpenCity` with the city's token.
/// - **The plate** under the host's top chips (``WorldAtlasPlate``), and at City the state names as framed
///   letter-spaced capitals.
/// - **Flights** (World-Airports-Spec §8, screen 22): every route one dotted great-circle arc
///   (``WorldFlightArcsLayer``), rings for airports only flown through and labelled dots for found ones
///   (``WorldFlightMarks``); a tap on an arc opens its card (``WorldFlightCard``), and the plate adds
///   "6 airports · 53 flights". Only this full-screen page draws them (Home never shows arcs).
/// - **Found airports** show their grounds as blue hexes, with their real runways from City in
///   (``WorldViewAirportTiles``).
/// - **VoiceOver**: the land is decoration, each marker a button, each arc on screen a button
///   (``WorldFlightArcButtons``), the zoom level one adjustable element.
struct WorldAtlasMapView: View {
    /// Where the map's data comes from.
    enum Source {
        /// The person's passport and fog (``WorldViewContent/live(store:)``).
        case store(FernletStore)
        /// Fixed content (the DEBUG demo, tests).
        case content(WorldViewContent)
    }

    let source: Source
    /// The level it opens at.
    var initialLevel: AtlasZoomLevel = .world
    /// Where it opens; nil opens on the content's start (home).
    var initialCentre: GeoPoint?
    /// Room the host's chips take, so the plate sits under the top ones and the zoom control clears the
    /// bottom (the mockup: the plate at 116 pt, the control 220 pt from the bottom of an 874-pt phone).
    var chromeInsets = EdgeInsets(top: 116, leading: 14, bottom: 220, trailing: 14)
    /// Opens a city's view from a marker at City (its frozen token).
    var onOpenCity: (String) -> Void = { _ in }

    @State private var model = WorldViewModel()
    @State private var camera: WorldViewCamera?
    /// The zoom the control is gliding to, and the glide.
    @State private var glideTarget: Double?
    @State private var glide: Task<Void, Never>?
    @State private var centreDescription: AtlasZoomDescription?
    /// The flight arc whose card shows, and the ring named by a tap.
    @State private var flightPick = WorldFlightPick()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                if let camera {
                    mapLayers(camera, size: size)
                    controls(camera)
                } else {
                    WorldPalette.rgb(WorldViewInk.sea(dark: false)).accessibilityHidden(true)
                }
            }
            .frame(width: size.width, height: size.height)
            .onAppear { start(size: size) }
            .onChange(of: size) { _, newSize in camera?.resize(to: newSize) }
            .onChange(of: camera?.detail) { settle() }
        }
        .task {
            await model.prepare()
            settle()
        }
        .onDisappear {
            glide?.cancel()
            model.stop()
        }
    }

    // MARK: Layers

    /// The map, the flights, the state labels and the markers. The pan and the pinch sit on the whole stack, so a
    /// finger that lands on a label moves the map too.
    private func mapLayers(_ camera: WorldViewCamera, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            WorldViewMapCanvas(camera: camera, model: model, generation: generation)
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .simultaneousGesture(SpatialTapGesture().onEnded { tapMap(at: $0.location) })
            if !flights.arcs.isEmpty {
                WorldFlightArcsLayer(camera: camera, arcs: flights.arcs, picked: flightPick.arc)
            }
            WorldAtlasStateLabels(camera: camera, model: model, generation: model.placeGeneration,
                                  insets: chromeInsets)
            if !flights.rings.isEmpty || !flights.found.isEmpty {
                WorldFlightMarks(camera: camera, flights: flights, namedRing: flightPick.ring)
            }
            WorldAtlasMarkers(camera: camera, clusters: model.clusters(at: camera.detail),
                              spots: model.labelSpots(at: camera.detail)) { cluster in
                tap(cluster)
            }
            if !flights.arcs.isEmpty {
                WorldFlightArcButtons(camera: camera, arcs: flights.arcs) { flightPick = WorldFlightPick(arc: $0.id) }
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .gesture(WorldMapPanRecognizer(onMove: pan(by:), onEnd: settle))
        .gesture(WorldMapPinchRecognizer(onPinch: pinch(by:at:), onEnd: settle))
    }

    /// The plate under the host's chips and the zoom control on the right.
    private func controls(_ camera: WorldViewCamera) -> some View {
        ZStack {
            Text(verbatim: WorldAtlasPlate.text(level: camera.level, place: centreDescription?.place,
                                                cities: model.content.cityCount, countries: model.content.countryCount,
                                                airports: model.content.flights.airportCount,
                                                flights: model.content.flights.flightCount))
                .font(.custom(FernletFontName.dmSansBold, size: 13, relativeTo: .footnote))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .worldAtlasChip(cornerRadius: 8)
                .accessibilityIdentifier("worldAtlas.plate")
                .padding(.horizontal, chromeInsets.leading + 30)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, chromeInsets.top)
            WorldAtlasZoomControl(level: camera.level, canZoomIn: camera.canZoomIn, canZoomOut: camera.canZoomOut,
                                  spokenValue: spokenValue(camera),
                                  onZoomIn: { step(in: true) }, onZoomOut: { step(in: false) })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, chromeInsets.trailing)
                .padding(.bottom, chromeInsets.bottom)
            if let arc = pickedArc {
                WorldFlightCard(arc: arc) { flightPick.arc = nil }
                    .id(arc.id)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, max(chromeInsets.bottom - 88, 16))
            }
        }
    }

    /// The flights Your world draws (World-Airports-Spec §8; none in a decoy).
    private var flights: WorldFlightMap { model.content.flights }

    /// The arc whose card shows.
    private var pickedArc: WorldFlightArc? {
        guard let id = flightPick.arc else { return nil }
        return flights.arcs.first { $0.id == id }
    }

    /// A tap on the map: a city's square acts like its label; else it names a ring, opens an arc's card, or closes
    /// the card.
    private func tapMap(at point: CGPoint) {
        guard let camera else { return }
        // Bounded: the level's markers (at most WorldViewCluster.maxPins).
        let city = model.clusters(at: camera.detail).first { cluster in
            let spot = camera.screenPoint(x: cluster.anchor.x, y: cluster.anchor.y)
            return hypot(Double(spot.x - point.x), Double(spot.y - point.y)) <= WorldFlightInk.ringReach
        }
        if let city { tap(city); return }
        guard !flights.arcs.isEmpty || !flights.rings.isEmpty else { return }
        flightPick = WorldFlightPick.at(point, camera: camera, flights: flights, current: flightPick)
    }

    /// What the map's drawing depends on beyond the camera: the uncovered hexes, the raster, the places.
    private var generation: Int {
        model.placeGeneration &+ (model.raster == nil ? 0 : 1) &+ (model.found.isEmpty ? 0 : 2) &+ (model.roads.roadCount > 0 ? 4 : 0)
            &+ (model.airportCells.isEmpty ? 0 : 8)
    }

    /// The zoom level's spoken value.
    private func spokenValue(_ camera: WorldViewCamera) -> String {
        WorldViewCopy.zoomValue(centreDescription ?? AtlasZoomDescription(level: camera.level, place: nil))
    }

    // MARK: Moving

    /// Loads the content and places the camera, once.
    private func start(size: CGSize) {
        guard camera == nil else { return }
        switch source {
        case .store(let store): model.load(.live(store: store))
        case .content(let content): model.load(content)
        }
        camera = WorldViewCamera(level: initialLevel, centre: initialCentre ?? model.content.start ?? GeoPoint(0, 0),
                                 size: size)
        settle()
    }

    /// The fingers moved: the map moves with them, and any glide stops.
    private func pan(by moved: CGSize) {
        stopGlide()
        camera?.pan(by: moved)
    }

    /// The fingers spread by `ratio` round `focus`: the map zooms by exactly that, the place between them staying
    /// between them.
    private func pinch(by ratio: CGFloat, at focus: CGPoint) {
        guard ratio > 0, var moved = camera else { return }
        stopGlide()
        moved.setZoom(moved.zoom + log(Double(ratio)) / log(AtlasZoomLevel.stepRatio), focus: focus)
        camera = moved
    }

    /// + or −: glides to the next level along, from where any glide under way is heading.
    private func step(in zoomingIn: Bool) {
        guard let camera else { return }
        move(toZoom: WorldViewCamera.steppedZoom(from: glideTarget ?? camera.zoom, in: zoomingIn))
    }

    /// A marker's tap: farther out, glide to its city and in to the next level; from City in, open the city.
    private func tap(_ cluster: WorldViewCluster) {
        guard let camera else { return }
        guard camera.level.canZoomIn else {
            onOpenCity(cluster.anchor.token)
            return
        }
        move(toZoom: WorldViewCamera.steppedZoom(from: camera.zoom, in: true),
             centre: WebMercator.geo(x: cluster.anchor.x, y: cluster.anchor.y))
    }

    /// Stops the glide where it is.
    private func stopGlide() {
        glide?.cancel()
        glide = nil
        glideTarget = nil
    }

    /// Goes to `target`, and to `centre` if given: a third of a second's glide, or at once under Reduce Motion.
    private func move(toZoom target: Double, centre: GeoPoint? = nil) {
        stopGlide()
        guard let start = camera else { return }
        let path = WorldViewCamera.Glide(from: start, toZoom: target, centre: centre)
        guard !reduceMotion else {
            camera = path.camera(at: 1)
            settle()
            return
        }
        glideTarget = target
        glide = Task { @MainActor in
            // Bounded: frameCount frames.
            for frame in 1...WorldViewCamera.Glide.frameCount {
                do {
                    try await Task.sleep(for: .milliseconds(WorldViewCamera.Glide.frameMilliseconds))
                } catch {
                    return
                }
                camera = path.camera(at: Double(frame) / Double(WorldViewCamera.Glide.frameCount))
            }
            glideTarget = nil
            settle()
        }
    }

    /// After a move: the place at the centre, and the places of the hexes on screen for the lines.
    private func settle() {
        guard let camera else { return }
        centreDescription = model.content.atlas?.zoomDescription(level: camera.level, centre: camera.centre)
        model.requestPlaces(for: camera.visibleHexes(margin: 3), at: camera.detail)
    }
}
