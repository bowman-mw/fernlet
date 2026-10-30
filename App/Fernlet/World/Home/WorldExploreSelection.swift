import CoreGraphics
import Foundation
import WorldMapStore

/// What Home draws of the atlas's cities and landmarks for one viewport (World-Exploration-Spec §2): which
/// landmarks stand near the view, whether the view is "zoomed out a step" (the city markers) or "zoomed in on a
/// city" (the city view's plate), and which of the passport's cities are near it. Pure and bounded; the caller
/// memoises the answers (``WorldExploreMemo``).
enum WorldExploreSelection {
    /// The camera height from which Home counts as "zoomed out a step" and the city markers show, in metres.
    /// Home opens at 1,700 m; the approved zoomed-out Home (`nf-far`, under `ex-zoomed`) draws the hexes at
    /// half their size, which is twice the height, 3,400 m. The step sits between the two (their geometric
    /// mean, about 2,400 m), so Home's own zoom never shows a marker and a pinch out of one step always does.
    /// Home's range stays `WorldCamera.distanceRange` (300…7,000 m): Home zooms only to your area.
    static let cityMarkerDistance = 2_400.0
    /// The most landmarks drawn at once (the nearest kept).
    static let maxLandmarks = 40
    /// The most city markers drawn at once (the nearest kept).
    static let maxCities = 24
    /// How far past the screen's edge art is still drawn, in points (the tallest art is about 90 pt).
    static let edgeMargin: CGFloat = 120

    /// The camera height the viewport shows, in metres (the inverse of `PlainBaseMap.heightPerDistance`).
    static func cameraDistance(of viewport: MapViewport) -> Double {
        guard viewport.isUsable else { return 0 }
        let metres = viewport.height / WebMercator.unitsPerMetre(at: viewport.center.latitude)
        return metres / PlainBaseMap.heightPerDistance
    }

    /// Whether the viewport is zoomed out a step from Home's own zoom: the city markers show.
    static func isZoomedOut(_ viewport: MapViewport) -> Bool {
        cameraDistance(of: viewport) >= cityMarkerDistance
    }

    /// How far from the viewport's centre to look for things to draw, in metres: half the screen's diagonal
    /// plus ``edgeMargin``, at most `WorldLandmarks.maxSearchMetres`.
    static func searchMetres(_ viewport: MapViewport, size: CGSize) -> Double {
        let perMetre = viewport.pointsPerMetre(at: viewport.center.latitude, in: size)
        guard perMetre > 0, perMetre.isFinite else { return 0 }
        let points = Double(hypot(size.width, size.height) / 2 + edgeMargin)
        return min(points / perMetre, WorldLandmarks.maxSearchMetres)
    }

    /// The landmarks to draw near the viewport: within ``searchMetres(_:size:)``, nearest first, at most
    /// ``maxLandmarks``.
    static func landmarks(in list: WorldLandmarks, near viewport: MapViewport, size: CGSize) -> [AtlasLandmark] {
        guard viewport.isUsable, !list.isEmpty else { return [] }
        let reach = searchMetres(viewport, size: size)
        guard reach > 0 else { return [] }
        return Array(list.landmarks(near: viewport.center, withinMetres: reach).prefix(maxLandmarks))
    }

    /// The passport's cities near `centre`, within `metres`, nearest first, at most ``maxCities``: each city
    /// token the book holds, looked up in `atlas` (a token the atlas no longer has is left out). Bounded: one
    /// pass over at most `PassportBook.cap(for: .city)` tokens.
    static func cities(in book: PassportBook, atlas: WorldAtlas, near centre: GeoPoint, withinMetres metres: Double) -> [AtlasCity] {
        guard centre.isValid, metres > 0 else { return [] }
        var near: [(city: AtlasCity, metres: Double)] = []
        for token in book.visits(of: .city).keys.prefix(PassportBook.cap(for: .city)) {
            guard let city = atlas.city(token: token) else { continue }
            guard abs(city.point.latitude - centre.latitude) * GeoPoint.metresPerDegree <= metres else { continue }
            let distance = centre.distance(to: city.point)
            if distance <= metres { near.append((city, distance)) }
        }
        let ordered = near.sorted { ($0.metres, $0.city.token) < ($1.metres, $1.city.token) }
        return ordered.prefix(maxCities).map(\.city)
    }

    /// The found city the view is in (the city view, `ex-city-view`): the atlas's city at `centre`, when the
    /// passport holds it; nil anywhere else, and for a city not found yet.
    static func foundCity(at centre: GeoPoint, atlas: WorldAtlas, book: PassportBook) -> AtlasCity? {
        guard centre.isValid, let city = atlas.city(at: centre) else { return nil }
        return book.firstVisit(.city, token: city.token) == nil ? nil : city
    }

    /// Whether a thing at `point` on screen is close enough to the screen to draw (within ``edgeMargin``).
    static func isOnScreen(_ point: CGPoint, size: CGSize) -> Bool {
        CGRect(origin: .zero, size: size).insetBy(dx: -edgeMargin, dy: -edgeMargin).contains(point)
    }
}

/// The last answers of ``WorldExploreSelection`` for Home's moving viewport, kept so a pan's every frame reads
/// them from memory: each is asked again only when the view's centre moves more than a fifth of the search
/// reach, the reach changes by more than a fifth, or the passport's counts change. Not observed (writing it
/// redraws nothing).
@MainActor
final class WorldExploreMemo {
    /// A query's key: the centre and reach it was asked for, and the book's counts then.
    private struct Asked: Equatable {
        let centre: GeoPoint
        let metres: Double
        let found: Int
    }

    private var landmarksAsked: Asked?
    private var landmarks: [AtlasLandmark] = []
    private var citiesAsked: Asked?
    private var cities: [AtlasCity] = []
    private var cityAsked: Asked?
    private var city: AtlasCity?

    /// ``WorldExploreSelection/landmarks(in:near:size:)``, from memory while the view stays near.
    func landmarks(in list: WorldLandmarks, near viewport: MapViewport, size: CGSize) -> [AtlasLandmark] {
        guard viewport.isUsable else { return [] }
        let asked = Asked(centre: viewport.center, metres: WorldExploreSelection.searchMetres(viewport, size: size), found: list.all.count)
        if let landmarksAsked, Self.isNear(asked, landmarksAsked) { return landmarks }
        landmarks = WorldExploreSelection.landmarks(in: list, near: viewport, size: size)
        landmarksAsked = asked
        return landmarks
    }

    /// The passport's cities near the view (``WorldExploreSelection/cities(in:atlas:near:withinMetres:)``), from
    /// memory while the view stays near and the book holds as many cities.
    func cities(in book: PassportBook, atlas: WorldAtlas, near viewport: MapViewport, size: CGSize) -> [AtlasCity] {
        guard viewport.isUsable else { return [] }
        let asked = Asked(centre: viewport.center, metres: WorldExploreSelection.searchMetres(viewport, size: size),
                          found: book.count(of: .city))
        if let citiesAsked, Self.isNear(asked, citiesAsked) { return cities }
        cities = WorldExploreSelection.cities(in: book, atlas: atlas, near: asked.centre, withinMetres: asked.metres)
        citiesAsked = asked
        return cities
    }

    /// The found city the view is in (``WorldExploreSelection/foundCity(at:atlas:book:)``), asked again when the
    /// centre moves ``cityRecheckMetres`` or the book's city count changes.
    func foundCity(at centre: GeoPoint, atlas: WorldAtlas, book: PassportBook) -> AtlasCity? {
        let asked = Asked(centre: centre, metres: Self.cityRecheckMetres * 5, found: book.count(of: .city))
        if let cityAsked, Self.isNear(asked, cityAsked) { return city }
        city = WorldExploreSelection.foundCity(at: centre, atlas: atlas, book: book)
        cityAsked = asked
        return city
    }

    /// How far the view's centre moves before the city it is in is asked again, in metres.
    static let cityRecheckMetres = 150.0

    /// Whether `new` may be answered with `old`'s answer.
    private static func isNear(_ new: Asked, _ old: Asked) -> Bool {
        guard new.found == old.found, old.metres > 0 else { return false }
        guard abs(new.metres - old.metres) <= old.metres / 5 else { return false }
        return new.centre.distance(to: old.centre) <= old.metres / 5
    }
}
