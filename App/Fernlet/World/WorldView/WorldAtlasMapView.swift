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
/// - **Zoom** World → Country → State → City (``AtlasZoomLevel``) with the framed control on the right
///   (``WorldAtlasZoomControl``) or a pinch, one level a step. Reduce Motion: no animated zoom.
/// - **Pan** east and west all the way round; north and south clamped, the poles at the edges at World
///   (``WorldViewCamera``). It opens on the person's first home, else their latest fix, else 0°.
/// - **City markers**: a gold square and the name farther out, the framed skyline and name plate from State in;
///   cities closer than 30 pt share one ("Seattle +2"). Tapping one zooms to it; at City it calls
///   `onOpenCity` with the city's token (the city view is wired by the lane).
/// - **The plate** under the host's top chips (``WorldAtlasPlate``), and at City the state names as framed
///   letter-spaced capitals.
/// - **VoiceOver**: the land is decoration, each marker a button, the zoom level one adjustable element.
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
    @State private var dragStart: WorldViewCamera?
    @State private var pinch: CGFloat = 1
    @State private var pinchAnchor = UnitPoint.center
    @State private var blend: CGFloat = 1
    @State private var centreDescription: AtlasZoomDescription?
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
        }
        .task {
            await model.prepare()
            settle()
        }
        .onDisappear { model.stop() }
    }

    // MARK: Layers

    /// The map, the state labels and the markers, scaled together while a pinch or a zoom step runs.
    private func mapLayers(_ camera: WorldViewCamera, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            WorldViewMapCanvas(camera: camera, model: model, generation: generation)
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .simultaneousGesture(pinchGesture(size: size))
            WorldAtlasStateLabels(camera: camera, model: model, generation: model.placeGeneration,
                                  insets: chromeInsets)
            WorldAtlasMarkers(camera: camera, clusters: model.clusters(at: camera.level)) { cluster in
                tap(cluster)
            }
        }
        .scaleEffect(pinch * blend, anchor: pinchAnchor)
        .clipped()
    }

    /// The plate under the host's chips and the zoom control on the right.
    private func controls(_ camera: WorldViewCamera) -> some View {
        ZStack {
            Text(verbatim: WorldAtlasPlate.text(level: camera.level, place: centreDescription?.place,
                                                cities: model.content.cityCount, countries: model.content.countryCount))
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
            WorldAtlasZoomControl(level: camera.level, spokenValue: spokenValue(camera),
                                  onZoomIn: { step(in: true, focus: nil) }, onZoomOut: { step(in: false, focus: nil) })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, chromeInsets.trailing)
                .padding(.bottom, chromeInsets.bottom)
        }
    }

    /// What the map's drawing depends on beyond the camera: the uncovered hexes, the raster, the places.
    private var generation: Int {
        model.placeGeneration &+ (model.raster == nil ? 0 : 1) &+ (model.found.isEmpty ? 0 : 2) &+ (model.roads.roadCount > 0 ? 4 : 0)
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

    /// A one-finger drag pans; the camera clamps and wraps as it goes.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if dragStart == nil { dragStart = camera }
                guard var moved = dragStart else { return }
                moved.pan(by: value.translation)
                camera = moved
            }
            .onEnded { _ in
                dragStart = nil
                settle()
            }
    }

    /// A pinch follows the fingers, then steps one level in or out when it ends far enough.
    private func pinchGesture(size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                pinchAnchor = UnitPoint(x: value.startLocation.x / max(size.width, 1),
                                        y: value.startLocation.y / max(size.height, 1))
                pinch = min(max(value.magnification, 0.5), 2.2)
            }
            .onEnded { value in
                pinch = 1
                if value.magnification > 1.3 { step(in: true, focus: value.startLocation) }
                if value.magnification < 0.77 { step(in: false, focus: value.startLocation) }
            }
    }

    /// Steps one level in or out, keeping the place under `focus` (nil: the centre) still; animated unless
    /// Reduce Motion is on.
    private func step(in zoomingIn: Bool, focus: CGPoint?) {
        guard var moved = camera,
              let target = zoomingIn ? moved.level.zoomedIn : moved.level.zoomedOut else { return }
        moved.setLevel(target, focus: focus)
        camera = moved
        settle()
        guard !reduceMotion else { return }
        if let focus {
            pinchAnchor = UnitPoint(x: focus.x / max(moved.size.width, 1), y: focus.y / max(moved.size.height, 1))
        } else {
            pinchAnchor = .center
        }
        blend = zoomingIn ? 0.7 : 1.4
        withAnimation(.easeOut(duration: 0.3)) { blend = 1 }
    }

    /// A marker's tap: farther out, centre on its city and zoom in a level; at City, open the city.
    private func tap(_ cluster: WorldViewCluster) {
        guard var moved = camera else { return }
        guard moved.level.canZoomIn else {
            onOpenCity(cluster.anchor.token)
            return
        }
        moved.centre(on: WebMercator.geo(x: cluster.anchor.x, y: cluster.anchor.y))
        camera = moved
        step(in: true, focus: nil)
    }

    /// After a move: the place at the centre, and the places of the hexes on screen for the lines.
    private func settle() {
        guard let camera else { return }
        centreDescription = model.content.atlas?.zoomDescription(level: camera.level, centre: camera.centre)
        model.requestPlaces(for: camera.visibleHexes(margin: 3), at: camera.level)
    }
}
