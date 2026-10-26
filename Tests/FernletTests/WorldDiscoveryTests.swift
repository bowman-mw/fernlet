import CoreLocation
import Foundation
import MapKit
import Testing
import UIKit
import WorldMapStore
@testable import Fernlet

/// The "world discovery" round (2026-10-26, issue desk W-09, W-10, W-12, W-13 and refinements 12–13): the map's
/// layers on Apple's tiles under the credit's margin, the companion's stance, pinch versus pan, Back to
/// Sprout's geometry, background mapping's saves and switch, and place lookups only where the person stops.
@MainActor
struct WorldDiscoveryTests {
    private static let here = GeoPoint(45.5205, -122.6255)
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    // MARK: W-12, the viewport

    /// An iPhone 17's map with Home's credit inset, north-up and flat, at `camera`.
    private static func map(camera: WorldCamera, height: CGFloat = 874, inset: CGFloat = 112) -> MKMapView {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 402, height: height))
        map.insetsLayoutMarginsFromSafeArea = false
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.layoutMargins = AppleMapGeometry.margins(bottomInset: inset)
        map.setCamera(AppleMapGeometry.mapCamera(for: camera), animated: false)
        map.layoutIfNeeded()
        return map
    }

    private static func coordinate(_ point: GeoPoint) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }

    /// With the 112-pt credit margin, MapKit's own projection (`convert`) and the viewport the layers draw
    /// from agree within a point everywhere on the view: the fog, the trails and the companion sit on the
    /// tiles under them. MapKit's camera centre is the middle of the area above the margin, which is why the
    /// old `visibleMapRect` viewport stretched every layer.
    @Test func theLayersLandOnTheTilesUnderTheCreditMargin() {
        #expect(WorldMapHome.creditInset == 112)
        for distance in [600.0, 1_700.0, 5_000.0] {
            let map = Self.map(camera: WorldCamera(center: Self.here, distance: distance))
            let viewport = AppleMapGeometry.viewport(of: map)
            let size = map.bounds.size
            #expect(viewport.isUsable)
            let centre = map.convert(Self.coordinate(Self.here), toPointTo: map)
            #expect(abs(centre.y - (size.height - 112) / 2) <= 2, "MapKit's centre sits above the margin: \(centre.y)")
            let points = [Self.here, Self.here.offset(east: 0, north: -300), Self.here.offset(east: 120, north: 250),
                          viewport.geo(at: CGPoint(x: 10, y: 10), in: size),
                          viewport.geo(at: CGPoint(x: size.width - 10, y: size.height - 10), in: size)]
            for point in points {
                let mapKit = map.convert(Self.coordinate(point), toPointTo: map)
                let ours = viewport.screenPoint(for: point, in: size)
                #expect(abs(mapKit.x - ours.x) <= 1 && abs(mapKit.y - ours.y) <= 1,
                        "at \(distance) m: MapKit \(mapKit), layers \(ours)")
            }
        }
    }

    /// Following, the companion stands about 58% of the way down the whole map (the approved Home), at
    /// every zoom, now that the layers are drawn on the whole view.
    @Test func theCompanionStandsAboutFiftyEightPercentDown() {
        for distance in [600.0, 1_700.0, 4_000.0] {
            let camera = WorldCamera(center: WorldMapHome.lookAt(Self.here, distance: distance), distance: distance)
            let map = Self.map(camera: camera)
            let stance = map.convert(Self.coordinate(Self.here), toPointTo: map).y / map.bounds.height
            let metres = AppleMapGeometry.viewport(of: map).height / WebMercator.unitsPerMetre(at: Self.here.latitude)
            #expect(stance > 0.555 && stance < 0.605, "stance \(stance); the map is \(metres / distance) × the distance tall")
        }
    }

    // MARK: W-10, pinch keeps following

    /// A zoom (the distance changes) keeps following even when the fingers carry the map; only a pan that
    /// moves the centre stops it; a resting finger does neither.
    @Test func onlyAPanThatMovesTheCentreStopsFollowing() {
        #expect(AppleMapGeometry.personMove(from: 1_700, to: 900, centreMoved: 80) == .zoom)
        #expect(AppleMapGeometry.personMove(from: 1_700, to: 3_400, centreMoved: 0) == .zoom)
        #expect(AppleMapGeometry.personMove(from: 1_700, to: 1_701, centreMoved: 120) == .pan)
        #expect(AppleMapGeometry.personMove(from: 1_700, to: 1_700, centreMoved: 6) == .none)
        #expect(AppleMapGeometry.personMove(from: 0, to: 1_700, centreMoved: 200) == .none)
    }

    /// Back to Sprout's auto re-follow reads whether Sprout is on the visible map from the last viewport;
    /// before the first, nothing is shown.
    @Test func theMapGeometryKnowsWhatIsOnScreen() {
        let geometry = WorldMapGeometry()
        #expect(!geometry.shows(Self.here))
        let size = CGSize(width: 402, height: 874)
        geometry.viewport = MapViewport.around(Self.here, heightMetres: 1_000, size: size)
        geometry.size = size
        #expect(geometry.shows(Self.here))
        #expect(geometry.shows(Self.here.offset(east: 0, north: 400)))
        #expect(!geometry.shows(Self.here.offset(east: 0, north: 600)))
        #expect(!geometry.shows(Self.here.offset(east: 300, north: 0)))
    }

    // MARK: W-09, background mapping

    /// A reading delivered while the app isn't active is written at once (iOS may end the suspended app
    /// before 40 cells); one in front waits for the next save as before.
    @Test func backgroundReadingsAreSavedAtOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: "WorldDiscoveryTests.\(UUID().uuidString)"))
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let keeper = WorldFogKeeper(vault: vault, defaults: defaults, isProtectedDataAvailable: { true })
        keeper.load()
        let front = WorldFix(point: Self.here, accuracy: 10, at: Self.now, isPrecise: true)
        #expect(keeper.handle(front) > 0)
        let unsaved = WorldFogKeeper(vault: vault, defaults: defaults, isProtectedDataAvailable: { true })
        unsaved.load()
        #expect(unsaved.visibleCells.isEmpty, "in front, the cells wait for the next save")
        let behind = WorldFix(point: Self.here.offset(east: 400, north: 0), accuracy: 10, at: Self.now, isPrecise: true)
        #expect(keeper.handle(behind, saveNow: true) > 0)
        let saved = WorldFogKeeper(vault: vault, defaults: defaults, isProtectedDataAvailable: { true })
        saved.load()
        #expect(saved.visibleCells.contains(MercatorHexGrid.cell(containing: behind.point)))
        #expect(saved.visibleCells.contains(MercatorHexGrid.cell(containing: Self.here)), "and everything before it")
    }

    /// Allowing Always while Fernlet runs (iOS's prompt, or later in iOS's Settings) turns background mapping
    /// on; the answer read at start, or any other change, never does.
    @Test func allowingAlwaysLaterTurnsBackgroundMappingOn() {
        #expect(WorldLocationSource.turnsOnBackgroundMapping(from: .whileUsing, to: .always))
        #expect(WorldLocationSource.turnsOnBackgroundMapping(from: .denied, to: .always))
        #expect(!WorldLocationSource.turnsOnBackgroundMapping(from: .always, to: .always))
        #expect(!WorldLocationSource.turnsOnBackgroundMapping(from: .always, to: .whileUsing))
        #expect(!WorldLocationSource.turnsOnBackgroundMapping(from: .notAsked, to: .whileUsing))
    }

    /// A batch of readings is handed on whole, oldest first, not only the last.
    @Test func everyReadingInABatchIsHandedOn() {
        let first = CLLocation(coordinate: Self.coordinate(Self.here), altitude: 0, horizontalAccuracy: 8, verticalAccuracy: 5,
                               timestamp: Self.now)
        let second = CLLocation(coordinate: Self.coordinate(Self.here.offset(east: 30, north: 0)), altitude: 0,
                                horizontalAccuracy: 12, verticalAccuracy: 5, timestamp: Self.now.addingTimeInterval(20))
        let fixes = WorldLocationSource.fixes(from: [first, second], precise: true)
        #expect(fixes.count == 2)
        #expect(fixes.map(\.at) == [Self.now, Self.now.addingTimeInterval(20)])
        #expect(fixes.last?.accuracy == 12 && fixes.allSatisfy(\.isPrecise))
    }

    // MARK: W-13, look up where the person stops

    /// Staying within 50 m for three minutes, or slower than walking for a minute, is a stop; driving is not.
    @Test func aStopIsStayingOrSlow() {
        var watch = WorldStopWatch()
        let arrived = watch.observe(Self.here, at: Self.now)
        #expect(!arrived)
        #expect(watch.timeToStop(at: Self.now.addingTimeInterval(60)) == 120)
        let soon = watch.observe(Self.here.offset(east: 20, north: 0), at: Self.now.addingTimeInterval(40))
        #expect(!soon)
        let stayed = watch.observe(Self.here.offset(east: 10, north: 10), at: Self.now.addingTimeInterval(181))
        #expect(stayed)

        var slow = WorldStopWatch()
        let start = Self.here.offset(east: 500, north: 0)
        let first = slow.observe(start, at: Self.now)
        let second = slow.observe(start.offset(east: 30, north: 0), at: Self.now.addingTimeInterval(40))
        let third = slow.observe(start.offset(east: 60, north: 0), at: Self.now.addingTimeInterval(80))
        #expect(!first && !second)
        #expect(third, "below walking for a minute")

        var driving = WorldStopWatch()
        var everStopped = false
        for step in 0..<60 {
            let reading = Self.here.offset(east: Double(step) * 150, north: 0)
            if driving.observe(reading, at: Self.now.addingTimeInterval(Double(step) * 10)) { everStopped = true }
        }
        #expect(!everStopped)
    }

    /// A drive past a pharmacy and a café looks nothing up and never raises "Remember this place"; stopping
    /// at the restaurant at the end learns it with one lookup.
    @Test func aDriveThenAStopLearnsTheStopAndPassingByRaisesNothing() async throws {
        let lookup = DiscoveryLookup(answer: [NearbyPlace(name: "Corner Pharmacy", kind: .refused, metres: 20)])
        let keeper = WorldPlacesKeeper(vault: WorldMapVault.ephemeral(), lookup: lookup, remembersPlaces: { true },
                                       remembersEatingOut: { true })
        var at = Self.now
        for step in 0..<40 {
            let reading = WorldFix(point: Self.here.offset(east: Double(step) * 140, north: 0), accuracy: 10, at: at, isPrecise: true)
            #expect(!(await keeper.handleForeground(reading, now: at)))
            #expect(keeper.refusedSpot == nil, "never mid-drive")
            at.addTimeInterval(10)
        }
        #expect(lookup.calls == 0, "no lookup along the road")

        lookup.answer = [NearbyPlace(name: "Hoshi Noodle Bar", kind: .allowed(.foodAndDrink), metres: 8, placeID: "I-hoshi")]
        let restaurant = Self.here.offset(east: 40 * 140 + 60, north: 0)
        let arrived = WorldFix(point: restaurant, accuracy: 10, at: at, isPrecise: true)
        #expect(!(await keeper.handleForeground(arrived, now: at)), "just arrived")
        let settled = at.addingTimeInterval(WorldStopWatch.stayTime + 1)
        #expect(await keeper.handleForeground(WorldFix(point: restaurant.offset(east: 8, north: 4), accuracy: 10, at: settled,
                                                       isPrecise: true), now: settled))
        #expect(lookup.calls == 1)
        let state = try keeper.store.deviceState()
        #expect(state.newPlaces.map(\.placeID) == ["I-hoshi"])
        #expect(keeper.eatingVisit?.placeID == "I-hoshi", "the eating visit starts at the stop")
    }
}

extension WorldPlacesKeeper {
    /// The person arrives at `fix` and stays three minutes (W-13): a reading on arrival, then one at `now`.
    /// Whether the second noted a visit.
    func stayed(at fix: WorldFix, until now: Date) async -> Bool {
        _ = await handleForeground(fix, now: now.addingTimeInterval(-WorldStopWatch.stayTime))
        return await handleForeground(fix, now: now)
    }
}

/// A lookup whose answer a test can change, counting how often it is asked.
@MainActor
private final class DiscoveryLookup: WorldPlaceLooking {
    var answer: [NearbyPlace]?
    private(set) var calls = 0

    init(answer: [NearbyPlace]?) {
        self.answer = answer
    }

    func nearbyPlaces(around point: GeoPoint) async -> [NearbyPlace]? {
        calls += 1
        return answer
    }

    func placeName(for placeID: String) async -> WorldPlaceName? {
        nil
    }

    func forgetNames() {}
}
