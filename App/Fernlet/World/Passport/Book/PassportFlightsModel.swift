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
    /// Whether it hasn't left yet (a Flighty file also lists flights still to come): it draws as planned, stays out of
    /// the totals, and becomes an ordinary stub once it has left. A trip under way counts as flown.
    var isPlanned = false

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

/// One year's flights on the Flights page (World-Airports-Spec §8): the trips that left in it, earliest first, and
/// their totals. Its row opens its log inside the book. A trip over New Year belongs to the year it left in.
nonisolated struct PassportFlightYearLog: Equatable, Identifiable, Sendable {
    let year: Int
    let trips: [PassportFlightTrip]
    /// Every flight flown in it, each leg counted.
    let flightCount: Int
    /// How far those flew.
    let metres: Double
    /// Every planned flight in it, each leg counted.
    let plannedCount: Int

    var id: Int { year }

    /// The log of `trips`, all of `year`.
    init(year: Int, trips: [PassportFlightTrip]) {
        self.year = year
        self.trips = trips
        let flown = trips.filter { !$0.isPlanned }
        flightCount = flown.reduce(0) { $0 + $1.legs.count }
        metres = flown.reduce(0) { $0 + $1.metres }
        plannedCount = trips.reduce(0) { $0 + ($1.isPlanned ? $1.legs.count : 0) }
    }
}

/// The Flights page (World-Airports-Spec §8, screens 11 and 23; owner 2026-11-02, option A): every flight the passport
/// keeps, Fernlet's own and imported, joined into trips and grouped by the year they left, newest year first. The book
/// gains one page however many flights it holds: a history that fits one page (``tripsOnOnePage``) shows its stubs
/// under year headings, and a longer one lists its years, each opening its own log. The header's totals count every
/// flight flown and name the planned ones apart (``PassportFlightTrip/isPlanned``); layovers flown are totalled under
/// the list.
///
/// A value built from the passport's flights (`book.flights`, empty in a decoy) and the airport list's points.
/// Bounded by ``PassportBook/maxFlights``.
nonisolated struct PassportFlightsModel: Equatable, Sendable {
    let trips: [PassportFlightTrip]
    /// The years with flights, newest first.
    let years: [PassportFlightYearLog]
    /// Every flight flown, counted once.
    let flightCount: Int
    /// How far those flew.
    let totalMetres: Double
    /// Every planned flight, counted once.
    let plannedCount: Int
    /// The stops flown with a known length, and their total.
    let layoverCount: Int
    let layoverSeconds: TimeInterval

    /// The most trips the page shows as stubs itself; past this it lists the years.
    static let tripsOnOnePage = 6
    /// The most flights joined into one trip.
    static let maxLegs = 4
    /// The longest stop a trip joins through (spec §9.2: a stop over 20 hours isn't shown).
    static let maxStop: TimeInterval = 20 * 3_600

    /// The page for `flights` at `now`, placing airports by `point` and dating by `calendar`.
    init(flights: [PassportFlight], point: (String) -> GeoPoint?, calendar: Calendar = .current, now: Date = Date()) {
        let sorted = flights.prefix(PassportBook.maxFlights).sorted { $0.departure < $1.departure }
        let trips = Self.trips(sorted, calendar: calendar).map { legs in
            PassportFlightTrip(legs: legs, metres: legs.reduce(0) { $0 + Self.metres($1, point: point) },
                               isPlanned: (legs.first?.departure ?? now) > now)
        }
        self.trips = trips
        years = Self.years(trips, calendar: calendar)
        let flown = trips.filter { !$0.isPlanned }
        flightCount = flown.reduce(0) { $0 + $1.legs.count }
        plannedCount = sorted.count - flightCount
        totalMetres = flown.reduce(0) { $0 + $1.metres }
        let stops = flown.flatMap { $0.stops.compactMap(\.seconds) }
        layoverCount = stops.count
        layoverSeconds = stops.reduce(0, +)
    }

    /// No flights at all.
    var isEmpty: Bool { trips.isEmpty }

    /// Whether the page lists the years rather than showing the stubs itself.
    var listsYears: Bool { trips.count > Self.tripsOnOnePage }

    /// The log of `year`, or nil when no flight left in it.
    func log(ofYear year: Int) -> PassportFlightYearLog? {
        years.first { $0.year == year }
    }

    /// `year`'s place in ``years``, from 0, or nil when no flight left in it.
    func position(ofYear year: Int) -> Int? {
        years.firstIndex { $0.year == year }
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

    /// One flight's great-circle distance on the sphere (``WorldFlightArcs/kilometres(_:_:)``, the arcs' own;
    /// `GeoPoint.distance(to:)` is a flat local projection), or 0 where either airport isn't placed.
    private static func metres(_ flight: PassportFlight, point: (String) -> GeoPoint?) -> Double {
        guard let from = point(flight.from), let to = point(flight.to) else { return 0 }
        return WorldFlightArcs.kilometres(from, to) * 1_000
    }

    /// `trips` grouped by the year each left, newest year first, each year's trips keeping their order.
    static func years(_ trips: [PassportFlightTrip], calendar: Calendar) -> [PassportFlightYearLog] {
        var byYear: [Int: [PassportFlightTrip]] = [:]
        // Bounded: at most maxFlights trips.
        for trip in trips {
            byYear[calendar.component(.year, from: trip.departure), default: []].append(trip)
        }
        return byYear.keys.sorted(by: >).map { PassportFlightYearLog(year: $0, trips: byYear[$0] ?? []) }
    }
}

/// The Flights page's numbers in words: distances and stop lengths.
nonisolated enum PassportFlightsText {
    /// "24,850 km" / "24.850 km": rounded to 10 km, grouped by threes ("." in Spain's Spanish, as the spec's §12
    /// asks; "," in English and Mexico's Spanish).
    static func kilometres(_ metres: Double, separator: String = FernletLanguage.appThousandsSeparator) -> String {
        let rounded = Int((max(metres, 0) / 10_000).rounded()) * 10
        return grouped(rounded, separator: separator) + " km"
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

    /// The trip's days in its year's log, whose header gives the year: "20 AUG", "2–3 SEP", "31 AUG – 1 SEP"; a trip
    /// that lands in the next year keeps its years ("31 DEC 2025 – 1 JAN 2026").
    static func daysInYear(of trip: PassportFlightTrip, calendar: Calendar = .current, language: FernletLanguage = .app) -> String {
        daysInYear(from: trip.departure, to: trip.arrival, calendar: calendar, language: language)
    }

    /// The days from `first` to `last` (nil: one day) in a year's log, as ``daysInYear(of:calendar:language:)`` writes
    /// them (also the Road trips page's, World-RoadTrip-Spec PR 4).
    static func daysInYear(from first: Date, to last: Date?, calendar: Calendar = .current, language: FernletLanguage = .app) -> String {
        guard let last, !calendar.isDate(first, inSameDayAs: last) else {
            return PassportBookDates.shortDay(first, calendar: calendar, language: language)
        }
        let start = calendar.dateComponents([.day, .month, .year], from: first)
        let end = calendar.dateComponents([.month, .year], from: last)
        guard start.year == end.year else {
            return PassportDates.short(first, calendar: calendar, language: language) + " – "
                + PassportDates.short(last, calendar: calendar, language: language)
        }
        let lastDay = PassportBookDates.shortDay(last, calendar: calendar, language: language)
        guard start.month == end.month else {
            return PassportBookDates.shortDay(first, calendar: calendar, language: language) + " – " + lastDay
        }
        return "\(start.day ?? 1)–" + lastDay
    }

    /// The trip's days: "20 AUG 2026", or "2–3 SEP 2026" when it lands on a later day, or "31 AUG – 1 SEP 2026".
    static func days(of trip: PassportFlightTrip, calendar: Calendar = .current, language: FernletLanguage = .app) -> String {
        days(from: trip.departure, to: trip.arrival, calendar: calendar, language: language)
    }

    /// The days from `first` to `last` (nil: one day), as ``days(of:calendar:language:)`` writes them (also the Road
    /// trips page's, World-RoadTrip-Spec PR 4).
    static func days(from first: Date, to last: Date?, calendar: Calendar = .current, language: FernletLanguage = .app) -> String {
        guard let last, !calendar.isDate(first, inSameDayAs: last) else {
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
