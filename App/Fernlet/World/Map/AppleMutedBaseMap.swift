import MapKit
import SwiftUI
import UIKit
import WorldMapStore

/// Phase 1's base map: Apple's map, muted, with every point of interest hidden.
///
/// **The only file in the app that imports MapKit** (`MapAndLocationConfinementBoundaryTests`). MapKit
/// fetches Apple's map tiles for the visible area; that is the whole of what Apple receives
/// (`Docs/No-Tracking-Wall.md` §4a, "Apple Maps (MapKit)"). Fernlet's fog, trails, pins and location
/// are drawn on top by Fernlet and never handed to MapKit.
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

/// Phase 1's place lookup (``WorldPlaceLooking``; World build step 5c): Apple's points of interest within
/// 80 m of where the person stands, asked in the foreground while the map is on screen, for a visit's
/// kind and name or a solo photo's refused-place check. Only the point goes to Apple, as the map's own
/// tile requests for that area already do (`Docs/No-Tracking-Wall.md` §4a); what comes back is turned into
/// Fernlet's own kinds here and nothing of it is stored but the decision (the MapKit terms).
///
/// The kinds: food and drink (restaurant, café, bakery, brewery, winery, distillery, food market,
/// nightlife), gyms (fitness centre), parks (park, national park), beaches and campgrounds (campground,
/// RV park) are allowed; hospitals and pharmacies are refused; everything else is "other", and its name
/// still goes through the refused words (`PlaceClassifier`). "Nothing here" is an answer (an empty list);
/// any other failure is none (nil).
struct ApplePlaceLookup: WorldPlaceLooking {
    /// How far around the point the lookup reaches, in metres.
    static let radius = 80.0
    /// The most places one answer keeps.
    static let maxPlaces = 25

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
                                   metres: point.distance(to: GeoPoint(at.latitude, at.longitude)))
            }
        } catch let error as MKError where error.code == .placemarkNotFound {
            return []
        } catch {
            return nil
        }
    }

    /// Fernlet's kind for one of Apple's categories.
    static func kind(of category: MKPointOfInterestCategory?) -> NearbyPlace.Kind {
        guard let category else { return .other }
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
