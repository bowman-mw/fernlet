import FernletFoundation
import MapKit
import SwiftUI
import UIKit
import WorldMapStore

/// Phase 1's base map: Apple's map, muted, with every point of interest hidden.
///
/// **The only file in the app that imports MapKit** (`MapAndLocationConfinementBoundaryTests`). MapKit
/// fetches Apple's map tiles for the visible area; with the place lookups below (``ApplePlaceLookup``)
/// and the map widget's still picture of the area around the person (``AppleMapSnapshot``, round 6b)
/// that is the whole of what Apple receives (`Docs/No-Tracking-Wall.md` §4a, "Apple Maps (MapKit)").
/// Fernlet's fog, trails, pins and location are drawn on top by Fernlet and never handed to MapKit.
///
/// MapKit draws its own "Maps" logo and "Legal" link inside the map's layout margins, so the bottom
/// inset lifts them clear of the item bar and they stay visible (MapKit terms). Pitch and rotation are
/// off, so the map stays north-up and flat and Fernlet's layers can place themselves from the visible
/// viewport alone (the whole view's, ``AppleMapGeometry``).
///
/// It is an `MKMapView` (not SwiftUI's `Map`) because only the UIKit map says how its tiles are doing:
/// it reports loading, loaded and failed to the Home's ``WorldTileStatus`` (designs `b1-home-loading`
/// and `b1-home-offline`), when one is in the environment.
struct AppleMutedBaseMap: WorldBaseMap {
    var drawsOwnCredit: Bool { true }

    func makeBody(camera: Binding<WorldCamera>, darkStyle: Bool, bottomInset: CGFloat,
                  onViewport: @escaping (MapViewport) -> Void) -> some View {
        AppleMutedMapView(camera: camera, darkStyle: darkStyle, bottomInset: bottomInset, onViewport: onViewport)
    }
}

extension EnvironmentValues {
    /// Where the base map reports its tiles' progress (the World Home's), or nil for nowhere.
    @Entry var worldTileStatus: WorldTileStatus? = nil
}

/// The `MKMapView` behind ``AppleMutedBaseMap``.
private struct AppleMutedMapView: UIViewRepresentable {
    @Binding var camera: WorldCamera
    let darkStyle: Bool
    let bottomInset: CGFloat
    let onViewport: (MapViewport) -> Void
    @Environment(\.worldTileStatus) private var tileStatus
    /// Reduce Motion: Fernlet's own camera moves (following, Back to Sprout) jump instead of gliding.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> AppleMutedMapCoordinator {
        AppleMutedMapCoordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = configuration
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.showsCompass = false
        map.showsScale = false
        map.showsUserLocation = false
        map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: WorldCamera.distanceRange.lowerBound,
                                                        maxCenterCoordinateDistance: WorldCamera.distanceRange.upperBound)
        map.insetsLayoutMarginsFromSafeArea = false
        let coordinator = context.coordinator
        coordinator.view = self
        coordinator.tileStatus = tileStatus
        coordinator.revision = camera.revision
        // W-15: MapKit reports this jump before `setCamera` returns; the gate holds it past SwiftUI's update.
        coordinator.gate.updating {
            map.delegate = coordinator
            map.setCamera(AppleMapGeometry.mapCamera(for: camera), animated: false)
        }
        return map
    }

    /// Every write to the map happens inside the gate's update stretch (W-15): a style, margin or camera
    /// change MapKit answers at once reports after SwiftUI's update, never during it.
    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.view = self
        coordinator.tileStatus = tileStatus
        coordinator.gate.updating { apply(to: map, coordinator: coordinator) }
    }

    /// The style, the credit's margins and Fernlet's latest camera request. A request MapKit already shows
    /// (a panel closing while the map follows) moves nothing.
    private func apply(to map: MKMapView, coordinator: AppleMutedMapCoordinator) {
        let style: UIUserInterfaceStyle = darkStyle ? .dark : .light
        if map.overrideUserInterfaceStyle != style { map.overrideUserInterfaceStyle = style }
        let margins = AppleMapGeometry.margins(bottomInset: bottomInset)
        if map.layoutMargins != margins { map.layoutMargins = margins }
        let move = AppleMapGeometry.cameraMove(for: camera, applied: coordinator.revision, showing: map.camera)
        coordinator.revision = camera.revision
        guard let move else { return }
        map.setCamera(move, animated: !reduceMotion)
    }

    /// The person moved the map (W-10): a pan that moves the centre takes the new place and stops
    /// following; a pinch or a double-tap zoom keeps following and takes only the new distance (Home
    /// re-centres on the companion at it). Off following, every move is taken whole.
    func adopt(_ map: MKMapView, move: AppleMapGeometry.PersonMove) {
        camera.distance = map.camera.centerCoordinateDistance
        guard move == .pan || !camera.follows else { return }
        let centre = map.camera.centerCoordinate
        camera.center = GeoPoint(centre.latitude, centre.longitude)
        if move == .pan { camera.follows = false }
    }
}

/// How Apple's map lays itself out, in the plain values Fernlet's layers read (World build W-12, W-10).
///
/// MapKit keeps its "Maps" logo and "Legal" link inside the view's layout margins, and on iOS 26 its
/// `visibleMapRect` and camera centre describe only the area inside those margins while the tiles fill
/// the whole view. Fernlet's layers cover the whole view, so the viewport is built from the view's own
/// corners through MapKit's projection (`viewport(of:)` for a map view), never from `visibleMapRect`. The
/// camera's centre stays MapKit's (the middle of the area inside the margins), which
/// `WorldMapHome.lookAt(_:distance:)` allows for.
@MainActor
enum AppleMapGeometry {
    /// How far a person's move must carry the map's centre, in points, to count as a pan (a finger that
    /// only rests or jiggles keeps following).
    static let panDistance: CGFloat = 24
    /// How much the camera distance must change, as a share, for a move to count as a zoom.
    static let zoomShare = 0.02

    /// What a move by the person was (W-10).
    enum PersonMove: Equatable {
        /// The distance changed: a pinch, a double-tap or a one-handed zoom. Following stays on.
        case zoom
        /// The centre moved with the distance unchanged. Following stops.
        case pan
        /// Neither, past the thresholds (a resting finger).
        case none
    }

    /// The move from a camera `from` metres up to `to` metres up whose centre moved `centreMoved` points
    /// on screen. A zoom never counts as a pan, even when the fingers also carry the map.
    static func personMove(from: Double, to: Double, centreMoved: CGFloat) -> PersonMove {
        guard from > 0, to > 0 else { return .none }
        if abs(to - from) / from > zoomShare { return .zoom }
        return centreMoved >= panDistance ? .pan : .none
    }

    /// The map's layout margins: the bottom inset lifts MapKit's credit above the item bar.
    static func margins(bottomInset: CGFloat) -> UIEdgeInsets {
        UIEdgeInsets(top: 0, left: 8, bottom: bottomInset, right: 8)
    }

    /// MapKit's camera for Fernlet's camera: north-up, flat.
    static func mapCamera(for camera: WorldCamera) -> MKMapCamera {
        let centre = CLLocationCoordinate2D(latitude: camera.center.latitude, longitude: camera.center.longitude)
        return MKMapCamera(lookingAtCenter: centre, fromDistance: camera.distance, pitch: 0, heading: 0)
    }

    /// The camera to hand MapKit for `camera`, or nil when there is nothing to move (W-15): no request
    /// since revision `applied`, or MapKit's camera (`current`) already shows it, within
    /// ``WorldCamera/stillMetres`` of its centre and its height.
    static func cameraMove(for camera: WorldCamera, applied: Int, showing current: MKMapCamera) -> MKMapCamera? {
        guard camera.revision != applied else { return nil }
        let shown = GeoPoint(current.centerCoordinate.latitude, current.centerCoordinate.longitude)
        let still = shown.distance(to: camera.center) < WorldCamera.stillMetres
            && abs(current.centerCoordinateDistance - camera.distance) < WorldCamera.stillMetres
        return still ? nil : mapCamera(for: camera)
    }

    /// The whole view's area in normalised Web Mercator: its top-left and bottom-right corners through
    /// MapKit's own projection, so a layer placed from it lands on the tiles under it however large the
    /// layout margins are. Empty before the view has a size.
    static func viewport(of map: MKMapView) -> MapViewport {
        let bounds = map.bounds
        guard bounds.width > 0, bounds.height > 0 else { return MapViewport(minX: 0, minY: 0, width: 0, height: 0) }
        let topLeft = MKMapPoint(map.convert(CGPoint(x: bounds.minX, y: bounds.minY), toCoordinateFrom: map))
        let bottomRight = MKMapPoint(map.convert(CGPoint(x: bounds.maxX, y: bounds.maxY), toCoordinateFrom: map))
        return viewport(of: MKMapRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x,
                                      height: bottomRight.y - topLeft.y))
    }

    /// A map rect in normalised Web Mercator (MapKit's map points over the world's size).
    static func viewport(of rect: MKMapRect) -> MapViewport {
        let world = MKMapSize.world
        guard world.width > 0, world.height > 0 else { return MapViewport(minX: 0, minY: 0, width: 0, height: 0) }
        return MapViewport(minX: rect.origin.x / world.width, minY: rect.origin.y / world.height,
                           width: rect.size.width / world.width, height: rect.size.height / world.height)
    }
}

/// The map widget's base picture (owner's Q36, `b4-new-map`, round 6b): Apple's muted map for one area,
/// as a still image, from `MKMapSnapshotter`. The same muted style as the live map, points of interest
/// hidden, north-up and flat, so Fernlet's own layers place themselves on it from the `MapViewport` alone.
///
/// Asked only by the map widget's writer (`WorldWidgetMapWriter`), only while the World Home's map is on
/// screen and following the person, for the area around them that the map is already showing: the same
/// destination, and the same area, as the live map's own tile requests (`Docs/No-Tracking-Wall.md` §4a).
/// Only the rectangle goes to Apple; the places and trails drawn over the picture never do.
enum AppleMapSnapshot {
    /// The muted map of `viewport` at `size` points and `scale` pixels per point, light or `dark`; nil
    /// when the snapshot fails (offline, throttled) or the viewport is unusable.
    static func image(of viewport: MapViewport, size: CGSize, scale: CGFloat, dark: Bool) async -> UIImage? {
        guard viewport.isUsable, size.width > 0, size.height > 0, scale > 0 else { return nil }
        let world = MKMapSize.world
        let options = MKMapSnapshotter.Options()
        options.mapRect = MKMapRect(x: viewport.minX * world.width, y: viewport.minY * world.height,
                                    width: viewport.width * world.width, height: viewport.height * world.height)
        options.size = size
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = configuration
        options.traitCollection = UITraitCollection { traits in
            traits.userInterfaceStyle = dark ? .dark : .light
            traits.displayScale = scale
        }
        do {
            return try await MKMapSnapshotter(options: options).start().image
        } catch {
            FernletAuditLog.log("worldMap.widgetSnapshot.failed", context: ["dark": dark ? "yes" : "no"])
            return nil
        }
    }
}

/// Phase 1's place lookup (``WorldPlaceLooking``; World build step 5c and round 5). Two requests, both to
/// Apple Maps, the map's own destination, and one hand-off to Apple's Maps app:
///
/// - **What is near** (``nearbyPlaces(around:)``): Apple's points of interest within 300 m of where the
///   person stands (a park's one point can be that far from someone inside it), asked in the foreground
///   while the map is on screen, to decide a stop or a solo photo's place. Only the point goes to Apple, as
///   the map's own tile requests for that area already do. What comes back is turned into Fernlet's own
///   kinds here and dropped once the device has decided; only an allowed place's reference
///   (`MKMapItem.identifier`) is kept.
/// - **A kept place's name again** (``placeName(for:)``): while Places is open, each place the person
///   returns to that has a reference is asked for by it (`MKMapItemRequest`); its name and kind are held in
///   memory only (`names`), never written (Apple's terms: the identifier may be kept, the place's data
///   only cached for a while), and forgotten with the wipes. Offline, nothing is named.
/// - **Open in Apple Maps** (``openInMaps(placeID:)``, round 6b, form answer 53): on the person's tap on a
///   kept place, the same request by its reference, and the item it returns opened in Maps, which shows
///   the name and address itself. Nothing that comes back is kept.
///
/// The kinds: food and drink (restaurant, café, bakery, brewery, winery, distillery, food market,
/// nightlife), gyms (fitness centre), parks (park, national park), beaches and campgrounds (campground,
/// RV park) are allowed; hospitals and pharmacies are refused; a park's outdoor amenities and anything Apple
/// gives no category (a lake, a trail) are features, which never block a park (round 6); everything else is
/// "other". Every name still goes through the refused words (`PlaceClassifier`). "Nothing here" is an answer (an empty list);
/// any other failure is none (nil).
final class ApplePlaceLookup: WorldPlaceLooking {
    /// How far around the point the lookup reaches, in metres.
    static let radius = 300.0
    /// The most places one answer keeps.
    static let maxPlaces = 40
    /// Names asked for again, by reference: in memory only, at most `PlaceLog.maxPlaces` of them.
    private var names: [String: WorldPlaceName] = [:]

    func nearbyPlaces(around point: GeoPoint) async -> [NearbyPlace]? {
        guard point.isValid else { return nil }
        let centre = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        let request = MKLocalPointsOfInterestRequest(center: centre, radius: Self.radius)
        request.pointOfInterestFilter = .includingAll
        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.prefix(Self.maxPlaces).map { item in
                let at = item.location.coordinate
                return NearbyPlace(name: item.name ?? "", kind: Self.kind(of: item.pointOfInterestCategory),
                                   metres: point.distance(to: GeoPoint(at.latitude, at.longitude)),
                                   placeID: item.identifier?.rawValue)
            }
        } catch let error as MKError where error.code == .placemarkNotFound {
            return []
        } catch {
            return nil
        }
    }

    func placeName(for placeID: String) async -> WorldPlaceName? {
        if let known = names[placeID] { return known }
        guard let identifier = MKMapItem.Identifier(rawValue: placeID) else { return nil }
        let item: MKMapItem
        do {
            item = try await MKMapItemRequest(mapItemIdentifier: identifier).mapItem
        } catch {
            // Offline, throttled or gone: nothing is named; the page falls back to the person's own name.
            return nil
        }
        guard let shown = WorldPlaceName.shown(name: item.name ?? "", kind: Self.kind(of: item.pointOfInterestCategory)) else {
            return nil
        }
        if names.count >= PlaceLog.maxPlaces { names.removeAll() }
        names[placeID] = shown
        return shown
    }

    func forgetNames() {
        names.removeAll()
    }

    func openInMaps(placeID: String) async -> Bool {
        guard let identifier = MKMapItem.Identifier(rawValue: placeID) else { return false }
        do {
            // The same request as the name refresh; the item goes straight to Maps and is not kept.
            let item = try await MKMapItemRequest(mapItemIdentifier: identifier).mapItem
            return item.openInMaps()
        } catch {
            return false   // offline, throttled or gone: the page says Maps couldn't find it
        }
    }

    /// Fernlet's kind for one of Apple's categories. A place Apple gives no category (a lake, a pond, a
    /// trail) and the outdoor amenities a park holds are features (round 6): they never block a park, and
    /// alone they keep nothing.
    static func kind(of category: MKPointOfInterestCategory?) -> NearbyPlace.Kind {
        guard let category else { return .feature }
        if featureCategories.contains(category) { return .feature }
        switch category {
        case .restaurant, .cafe, .bakery, .brewery, .winery, .distillery, .foodMarket, .nightlife: return .allowed(.foodAndDrink)
        case .fitnessCenter: return .allowed(.gym)
        case .park, .nationalPark: return .allowed(.park)
        case .beach: return .allowed(.beach)
        case .campground, .rvPark: return .allowed(.campground)
        case .hospital, .pharmacy: return .refused
        default: return .other
        }
    }

    /// The outdoor amenities a park, beach or campground holds or stands beside (World build round 6).
    static let featureCategories: Set<MKPointOfInterestCategory> = [
        .restroom, .parking, .publicTransport, .evCharger, .landmark, .nationalMonument, .marina, .hiking, .fishing,
        .kayaking, .swimming, .surfing, .skatePark, .skating, .soccer, .tennis, .basketball, .baseball, .volleyball,
        .golf, .miniGolf, .rockClimbing,
    ]
}

/// The map's delegate: the viewport on every move, the person's pans written back, and the tiles'
/// progress. Main actor, as MapKit calls it there. Every report goes through ``gate`` (W-15), so one raised
/// while SwiftUI makes or updates the map view waits for the next main-queue turn.
@MainActor
private final class AppleMutedMapCoordinator: NSObject, MKMapViewDelegate {
    /// The view as last updated (its binding and callbacks).
    var view: AppleMutedMapView?
    /// The last camera revision handed to MapKit.
    var revision = 0
    /// Where the tiles' progress goes (the Home's), read from the environment at each update.
    var tileStatus: WorldTileStatus?
    /// Holds the reports raised inside `makeUIView` and `updateUIView` until SwiftUI's update is over.
    let gate = WorldMapReportGate()
    /// Whether the move under way began with the person's finger.
    private var movedByPerson = false
    /// Where the map's centre was, and how far up its camera, when that move began.
    private var startCentre = CLLocationCoordinate2D()
    private var startDistance = 0.0

    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        movedByPerson = Self.isTouched(mapView)
        startCentre = mapView.centerCoordinate
        startDistance = mapView.camera.centerCoordinateDistance
    }

    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        report(mapView)
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        report(mapView)
        guard movedByPerson else { return }
        movedByPerson = false
        let then = mapView.convert(startCentre, toPointTo: mapView)
        let now = mapView.convert(mapView.centerCoordinate, toPointTo: mapView)
        let move = AppleMapGeometry.personMove(from: startDistance, to: mapView.camera.centerCoordinateDistance,
                                               centreMoved: hypot(now.x - then.x, now.y - then.y))
        gate.send(.camera) { [weak self, weak mapView] in
            guard let mapView else { return }
            self?.view?.adopt(mapView, move: move)
        }
    }

    /// Hands the layers the whole view's viewport (W-12), never `visibleMapRect`'s inset one.
    private func report(_ mapView: MKMapView) {
        gate.report(AppleMapGeometry.viewport(of: mapView)) { [weak self] viewport in self?.view?.onViewport(viewport) }
    }

    func mapViewWillStartLoadingMap(_ mapView: MKMapView) {
        gate.send(.tiles) { [weak self] in self?.tileStatus?.loading() }
    }

    func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
        gate.send(.tiles) { [weak self] in self?.tileStatus?.loaded() }
    }

    func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: any Error) {
        gate.send(.tiles) { [weak self] in self?.tileStatus?.failed() }
    }

    /// Whether a finger is on the map now (one of its gesture recognisers has begun or is moving).
    private static func isTouched(_ mapView: MKMapView) -> Bool {
        let recognisers = (mapView.subviews.first?.gestureRecognizers ?? []) + (mapView.gestureRecognizers ?? [])
        return recognisers.contains { $0.state == .began || $0.state == .changed || $0.state == .ended }
    }
}
