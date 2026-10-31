import FernletDomainModel
import Foundation
import WorldMapStore

/// One trip on the Flights page (World-Airports-Spec §8): a flight, or flights joined through one airport, each
/// later leg leaving that airport within ``PassportFlightsModel/maxStop`` of landing (or on the same day where a
/// time is missing). "PDX ✈ HEL ✈ NRT · 21–22 SEP 2026 · 8,940 km · via Helsinki · 2 h 40 min".
nonisolated struct PassportFlightTrip: Equatable, Identifiable, Sendable {
    /// The flights, earliest first (1 to ``PassportFlightsModel/maxLegs``).
    let legs: [PassportFlight]
    /// The great-circle distance flown, in metres (legs whose airports the list doesn't place count 0).
    let metres: Double

    var id: String { legs.map { "\($0.route)@\($0.departure.timeIntervalSince1970)" }.joined(separator: ",") }
    /// The codes in order: from, each stop, to.
    var codes: [String] { (legs.first.map { [$0.from] } ?? []) + legs.map(\.to) }
    var departure: Date { legs.first?.departure ?? .distantPast }
    /// The last landing, when known.
    var arrival: Date? { legs.last?.arrival }
    /// Whether every flight in it came from a file or the calendar (it carries the "Imported" tag).
    var isImported: Bool { legs.allSatisfy { !$0.sources.contains(.fernlet) } }
    /// Each stop's code and how long it lasted, when both times are known and sure.
    var stops: [(code: String, seconds: TimeInterval?)] {
        zip(legs, legs.dropFirst()).map { first, next in (first.to, PassportFlightsModel.stopSeconds(first, next)) }
    }
}

/// One line on a Flights page: a year's heading or a trip.
nonisolated enum PassportFlightsRow: Equatable, Hashable, Sendable {
    case year(Int)
    /// A trip, by its place in ``PassportFlightsModel/trips``.
    case trip(Int)
}

/// The Flights pages (World-Airports-Spec §8, screens 11 and 23): every flight the passport keeps, Fernlet's own and
/// imported, joined into trips, earliest first under year headings, ``tripsPerPage`` a page, so a long history
/// runs over several pages. The header's totals count every flight; layovers are totalled under the stubs.
///
/// A value built from the passport's flights (`book.flights`, empty in a decoy) and the airport list's points.
/// Bounded by ``PassportBook/maxFlights``.
nonisolated struct PassportFlightsModel: Equatable, Sendable {
    let trips: [PassportFlightTrip]
    /// The pages' rows; at least one page (an empty one says "No flights yet").
    let pages: [[PassportFlightsRow]]
    /// Every flight, counted once.
    let flightCount: Int
    let totalMetres: Double
    /// The stops with a known length, and their total.
    let layoverCount: Int
    let layoverSeconds: TimeInterval

    /// Trips on one page.
    static let tripsPerPage = 6
    /// The most flights joined into one trip.
    static let maxLegs = 4
    /// The longest stop a trip joins through (spec §9.2: a stop over 20 hours isn't shown).
    static let maxStop: TimeInterval = 20 * 3_600

    /// The pages for `flights`, placing airports by `point` and dating by `calendar`.
    init(flights: [PassportFlight], point: (String) -> GeoPoint?, calendar: Calendar = .current) {
        let sorted = flights.prefix(PassportBook.maxFlights).sorted { $0.departure < $1.departure }
        let trips = Self.trips(sorted, calendar: calendar).map { legs in
            PassportFlightTrip(legs: legs, metres: legs.reduce(0) { $0 + Self.metres($1, point: point) })
        }
        self.trips = trips
        pages = Self.pages(trips, calendar: calendar)
        flightCount = sorted.count
        totalMetres = trips.reduce(0) { $0 + $1.metres }
        let stops = trips.flatMap { $0.stops.compactMap(\.seconds) }
        layoverCount = stops.count
        layoverSeconds = stops.reduce(0, +)
    }

    /// No flights at all.
    var isEmpty: Bool { trips.isEmpty }

    /// The trips on page `index` (from 0), with their year headings.
    func rows(onPage index: Int) -> [PassportFlightsRow] {
        pages.indices.contains(index) ? pages[index] : []
    }

    /// The point halfway along the great circle from `a` to `b` (where Your world opens on a tapped stub).
    static func midpoint(_ a: GeoPoint, _ b: GeoPoint) -> GeoPoint {
        let radians = Double.pi / 180
        func vector(_ p: GeoPoint) -> (Double, Double, Double) {
            let lat = p.latitude * radians, lon = p.longitude * radians
            return (cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
        }
        let (ax, ay, az) = vector(a), (bx, by, bz) = vector(b)
        let x = ax + bx, y = ay + by, z = az + bz
        guard abs(x) + abs(y) + abs(z) > 1e-9 else { return a }
        return GeoPoint(atan2(z, (x * x + y * y).squareRoot()) / radians, atan2(y, x) / radians)
    }

    /// The page (from 0) a trip is on.
    func page(ofTrip index: Int) -> Int { index / Self.tripsPerPage }

    // MARK: Building

    /// `sorted` joined into trips: a flight joins the one before when it leaves where that one landed, isn't the
    /// way straight back, and leaves within ``maxStop`` of its landing (on the same day where a time is missing).
    static func trips(_ sorted: [PassportFlight], calendar: Calendar) -> [[PassportFlight]] {
        var trips: [[PassportFlight]] = []
        // Bounded: at most maxFlights flights.
        for flight in sorted {
            if let last = trips.last, last.count < maxLegs, let previous = last.last,
               joins(previous, flight, first: last[0], calendar: calendar) {
                trips[trips.count - 1].append(flight)
            } else {
                trips.append([flight])
            }
        }
        return trips
    }

    /// Whether `next` continues the trip `previous` ended (that began at `first`'s airport).
    private static func joins(_ previous: PassportFlight, _ next: PassportFlight, first: PassportFlight,
                              calendar: Calendar) -> Bool {
        guard previous.to == next.from, next.to != previous.from, next.to != first.from else { return false }
        guard let landed = previous.arrival, !previous.timesUnsure, !next.timesUnsure else {
            return calendar.isDate(previous.departure, inSameDayAs: next.departure)
        }
        let gap = next.departure.timeIntervalSince(landed)
        return gap > 0 && gap <= maxStop
    }

    /// How long the stop between `first` and `next` lasted, when both times are known, sure and believable.
    static func stopSeconds(_ first: PassportFlight, _ next: PassportFlight) -> TimeInterval? {
        guard let landed = first.arrival, !first.timesUnsure, !next.timesUnsure else { return nil }
        let gap = next.departure.timeIntervalSince(landed)
        return gap > 0 && gap <= maxStop ? gap : nil
    }

    /// One flight's great-circle distance, or 0 where either airport isn't placed.
    private static func metres(_ flight: PassportFlight, point: (String) -> GeoPoint?) -> Double {
        guard let from = point(flight.from), let to = point(flight.to) else { return 0 }
        return from.distance(to: to)
    }

    /// The trips, ``tripsPerPage`` a page, each page and each new year opening with its year's heading.
    static func pages(_ trips: [PassportFlightTrip], calendar: Calendar) -> [[PassportFlightsRow]] {
        guard !trips.isEmpty else { return [[]] }
        var pages: [[PassportFlightsRow]] = []
        // Bounded: at most maxFlights trips.
        for start in stride(from: 0, to: trips.count, by: tripsPerPage) {
            var rows: [PassportFlightsRow] = []
            var year: Int?
            for index in start ..< min(start + tripsPerPage, trips.count) {
                let tripYear = calendar.component(.year, from: trips[index].departure)
                if tripYear != year { rows.append(.year(tripYear)) }
                year = tripYear
                rows.append(.trip(index))
            }
            pages.append(rows)
        }
        return pages
    }
}

/// The Flights page's numbers in words: distances and stop lengths.
nonisolated enum PassportFlightsText {
    /// "24,850 km" / "24.850 km": rounded to 10 km, grouped by threes ("." in Spanish, as the spec's §12 asks).
    static func kilometres(_ metres: Double, language: FernletLanguage = .app) -> String {
        let rounded = Int((max(metres, 0) / 10_000).rounded()) * 10
        return grouped(rounded, separator: language == .spanish ? "." : ",") + " km"
    }

    /// `value` with its thousands grouped by `separator`.
    static func grouped(_ value: Int, separator: String) -> String {
        let digits = Array(String(max(value, 0)))
        var out = ""
        // Bounded: an Int has at most 19 digits.
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out += separator }
            out.append(digit)
        }
        return out
    }

    /// "2 h 40 min", "45 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((max(seconds, 0) / 60).rounded())
        let hours = minutes / 60, rest = minutes % 60
        return hours > 0 ? "\(hours) h \(rest) min" : "\(rest) min"
    }

    /// The trip's days: "20 AUG 2026", or "2–3 SEP 2026" when it lands on a later day, or "31 AUG – 1 SEP 2026".
    static func days(of trip: PassportFlightTrip, calendar: Calendar = .current, language: FernletLanguage = .app) -> String {
        let first = trip.departure
        guard let last = trip.arrival, !calendar.isDate(first, inSameDayAs: last) else {
            return PassportDates.short(first, calendar: calendar, language: language)
        }
        let start = calendar.dateComponents([.day, .month, .year], from: first)
        let end = calendar.dateComponents([.month, .year], from: last)
        guard start.month == end.month, start.year == end.year else {
            return PassportBookDates.shortDay(first, calendar: calendar, language: language) + " – "
                + PassportDates.short(last, calendar: calendar, language: language)
        }
        return "\(start.day ?? 1)–" + PassportDates.short(last, calendar: calendar, language: language)
    }
}
