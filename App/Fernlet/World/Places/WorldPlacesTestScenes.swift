import Foundation
import WorldMapStore

/// DEBUG screenshot stand-ins for round 6's places (`FERNLET_UI_TEST_WORLD_HOME`, read only through
/// `UITestSupport.worldHomeScenes`, which is empty in release builds): display only, nothing is written.
///
/// - `homes`: a home where the person stands (and `hotel`: a hotel stay 260 m away instead of the home's
///   presence), `asleep`: the z's by the house, `greeting`: Sprout's welcome-home line.
/// - `places`: a favourite place to eat with three photos, a gym and a café with one, round the person.
/// - `restaurant`: the blue button's card at a favourite place to eat (`b1-qs-food`).
/// - `refused`: "Remember this place" where the person stands (`ref-tag-home`).
/// - `where`: a day of Where you've been with Home left and got back (`ref-home-where`).
/// - `tagSheet`, `homeSheet`, `photoSheet`: the Remember this place / Put on the map sheet, open.
enum WorldPlacesTestScenes {
    /// The scenes asked for (none in release builds).
    static var scenes: Set<String> { UITestSupport.worldHomeScenes }

    /// Where the stand-ins stand before a reading (the shots' simulated location).
    static let laurelhurst = GeoPoint(45.5205, -122.6255)

    /// The blue button's card at Hoshi Noodle Bar, as `b1-qs-food` draws it.
    static let restaurant = WorldQuickStartContext.EatingOut(id: UUID(uuidString: "6C000000-0000-0000-0000-000000000001") ?? UUID(),
                                                             name: "Hoshi Noodle Bar", meals: 4, usual: "tonkotsu ramen")

    /// With `home` a home where the person stands; with `hotel` a stay at the Ace (where the person stands
    /// when there is no home, else 1.5 km east).
    static func homes(at point: GeoPoint, home hasHome: Bool, hotel: Bool) -> HomeBook {
        let home = HomePlace(id: UUID(uuidString: "6C000000-0000-0000-0000-000000000002") ?? UUID(), kind: .home, label: "Home", point: point)
        let ace = HomePlace(id: UUID(uuidString: "6C000000-0000-0000-0000-000000000003") ?? UUID(), kind: .hotel, label: "Ace Hotel",
                            point: hasHome ? point.offset(east: 1_500, north: 0) : point)
        var presence = HomePresence.unknown
        presence.atID = hasHome ? home.id : ace.id
        return HomeBook(homes: hasHome ? [home] : [], hotel: hotel ? ace : nil, pastHotels: [], presence: presence)
    }

    /// Hoshi (three photos), Full gym and Café Lune (one photo) round `point`, as `ref-places-map` draws them.
    static func markers(near point: GeoPoint) -> [WorldMapMarker] {
        let photo = { (n: Int) in UUID(uuidString: "6C000000-0000-0000-0000-0000000001\(String(format: "%02d", n))") ?? UUID() }
        let hoshi = point.offset(east: 90, north: 110), lune = point.offset(east: 70, north: -110)
        return [
            WorldMapMarker(id: photo(90), kind: .eatingPlace(placeID: "I-test-hoshi"), name: "Hoshi", point: hoshi,
                           photos: WorldPhotoPlace(id: photo(1), point: hoshi, photoIDs: [photo(1), photo(2), photo(3)])),
            WorldMapMarker(id: photo(91), kind: .space, name: "Full gym", point: point.offset(east: -100, north: 60)),
            WorldMapMarker(id: photo(92), kind: .eatingPlace(placeID: "I-test-lune"), name: "Café Lune", point: lune,
                           photos: WorldPhotoPlace(id: photo(4), point: lune, photoIDs: [photo(4)])),
        ]
    }

    /// A Friday-like day of Where you've been: Home left at 8:40, a place at 12:10, a walk at 17:30, Home
    /// again at 18:20, on today's date.
    static func log(home: UUID, now: Date, calendar: Calendar = .current) -> PlaceLog {
        let day = calendar.startOfDay(for: now)
        let at = { (hour: Int, minute: Int) in day.addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60)) }
        // Apple's reference stands in, so the place offers Open in Apple Maps (form answer 53; a fake one finds nothing).
        let hoshi = PlaceRecord(label: "Hoshi Noodle Bar", placeID: "I-hoshi", point: GeoPoint(45.5203, -122.6273), visits: 4)
        let park = PlaceRecord(label: "Oak Park", point: GeoPoint(45.5190, -122.6380), visits: 3)
        let stops = [PlaceStop(kind: .leftHome, at: at(8, 40), placeID: home), PlaceStop(kind: .visit, at: at(12, 10), placeID: hoshi.id),
                     PlaceStop(kind: .walk, at: at(17, 30), metres: 1_000), PlaceStop(kind: .cameHome, at: at(18, 20), placeID: home)]
        return PlaceLog(places: [hoshi, park], stops: stops)
    }
}
