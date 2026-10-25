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
/// `MKMapRect` alone.
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
        map.delegate = context.coordinator
        context.coordinator.view = self
        context.coordinator.tileStatus = tileStatus
        context.coordinator.revision = camera.revision
        map.setCamera(Self.mapCamera(for: camera), animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.view = self
        coordinator.tileStatus = tileStatus
        map.overrideUserInterfaceStyle = darkStyle ? .dark : .light
        let margins = UIEdgeInsets(top: 0, left: 8, bottom: bottomInset, right: 8)
        if map.layoutMargins != margins { map.layoutMargins = margins }
        guard camera.revision != coordinator.revision else { return }
        coordinator.revision = camera.revision
        map.setCamera(Self.mapCamera(for: camera), animated: true)
    }

    /// MapKit's camera for Fernlet's camera: north-up, flat.
    static func mapCamera(for camera: WorldCamera) -> MKMapCamera {
        let centre = CLLocationCoordinate2D(latitude: camera.center.latitude, longitude: camera.center.longitude)
        return MKMapCamera(lookingAtCenter: centre, fromDistance: camera.distance, pitch: 0, heading: 0)
    }

    /// The visible map rect in normalised Web Mercator (MapKit's map points over the world's size).
    static func viewport(of rect: MKMapRect) -> MapViewport {
        let world = MKMapSize.world
        guard world.width > 0, world.height > 0 else { return MapViewport(minX: 0, minY: 0, width: 0, height: 0) }
        return MapViewport(minX: rect.origin.x / world.width, minY: rect.origin.y / world.height,
                           width: rect.size.width / world.width, height: rect.size.height / world.height)
    }

    /// The person moved the map: Fernlet's camera takes the new place and stops following.
    func adopt(_ map: MKMapView) {
        let centre = map.camera.centerCoordinate
        camera.center = GeoPoint(centre.latitude, centre.longitude)
        camera.distance = map.camera.centerCoordinateDistance
        camera.follows = false
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
/// Apple Maps, the map's own destination:
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
/// progress. Main actor, as MapKit calls it there.
@MainActor
private final class AppleMutedMapCoordinator: NSObject, MKMapViewDelegate {
    /// The view as last updated (its binding and callbacks).
    var view: AppleMutedMapView?
    /// The last camera revision handed to MapKit.
    var revision = 0
    /// Where the tiles' progress goes (the Home's), read from the environment at each update.
    var tileStatus: WorldTileStatus?
    /// Whether the move under way began with the person's finger.
    private var movedByPerson = false

    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        movedByPerson = Self.isTouched(mapView)
    }

    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        view?.onViewport(AppleMutedMapView.viewport(of: mapView.visibleMapRect))
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        view?.onViewport(AppleMutedMapView.viewport(of: mapView.visibleMapRect))
        guard movedByPerson else { return }
        movedByPerson = false
        view?.adopt(mapView)
    }

    func mapViewWillStartLoadingMap(_ mapView: MKMapView) {
        tileStatus?.loading()
    }

    func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
        tileStatus?.loaded()
    }

    func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: any Error) {
        tileStatus?.failed()
    }

    /// Whether a finger is on the map now (one of its gesture recognisers has begun or is moving).
    private static func isTouched(_ mapView: MKMapView) -> Bool {
        let recognisers = (mapView.subviews.first?.gestureRecognizers ?? []) + (mapView.gestureRecognizers ?? [])
        return recognisers.contains { $0.state == .began || $0.state == .changed || $0.state == .ended }
    }
}
